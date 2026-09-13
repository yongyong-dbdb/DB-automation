#!/bin/sh
#
# PostgreSQL Physical Replication Control / Planned Switchover
# Supported PostgreSQL major versions: 12 through 18
#
# Design constraints
#   - POSIX /bin/sh compatible
#   - No Python, jq, yq, expect, Perl modules, or other separate runtimes
#   - No repmgr, Patroni, pg_auto_failover, or other HA-manager dependency
#   - No package installation
#   - No hard-coded PostgreSQL version, PGDATA, port, socket, host, service name,
#     database user, replication user, or binary directory
#   - PostgreSQL-provided binaries + standard base OS utilities only
#
# Scope
#   - Replication Status
#   - WAL Replay pause/resume
#   - WAL Receiver streaming connection stop/resume
#   - Planned Switchover: Primary -> Standby, selected Standby -> Primary
#
# IMPORTANT
#   - This script does NOT perform automatic failover.
#   - If the current Primary is unavailable, Switchover is aborted.
#   - Remote Switchover requires an already-available ssh client and an SSH
#     account that can administer the target PostgreSQL instance locally.
#     The script never installs or configures SSH.
#

set -u
umask 077

SCRIPT_VERSION="0.1.22"
SCRIPT_PATH=$0
SCRIPT_BASENAME=${SCRIPT_PATH##*/}
TAB=$(printf '\t')
CHECK_ONLY=0
EXIT_USAGE=2
EXIT_REMOTE=3
EXIT_CANCELLED=4
MAX_WAIT_SECONDS=${PG_SWITCH_MAX_WAIT_SECONDS:-3600}
RESULT_FILE=""
RESULT_INITIALIZED=0
LAST_ERROR=""
SIGNAL_NAME=""

TMP_FILES=""
CURRENT_PHASE="initial"
SWITCHOVER_PRIMARY_STOPPED=0
SWITCHOVER_PROMOTED=0
SWITCHOVER_CONFIG_CHANGED=0
LOCK_HELD=0
LOCK_ROOT=""
LOCK_DIR=""
LOCK_OWNER_TOKEN=""
REMOTE_LOCK_HELD=0
REMOTE_LOCK_TOKEN=""

PGDATA="${PGDATA:-}"
PG_BINDIR="${PG_BINDIR:-}"
PG_START_OPTIONS="${PG_START_OPTIONS:-}"
PGPORT="${PGPORT:-}"
PGHOST_LOCAL="${PGHOST:-}"
PGUSER_LOCAL="${PGUSER:-}"
DB_NAME=""
PSQL_BIN=""
PG_CTL_BIN=""
PG_CONTROLDATA_BIN=""
POSTMASTER_PID=""
POSTMASTER_OPTIONS=""
SOCKET_DIR=""
PG_MAJOR=""
PG_VERSION_NUM=""
SYSTEM_IDENTIFIER=""
LOCAL_ROLE=""
CONFIG_FILE=""
AUTO_CONF=""
STATE_DIR=""
STATE_KEY=""

REMOTE_TRANSPORT=""
REMOTE_SSH_HOST=""
REMOTE_SSH_USER=""
REMOTE_TARGET=""
REMOTE_PGDATA=""
REMOTE_PORT=""
REMOTE_VERSION_NUM=""
REMOTE_MAJOR=""
REMOTE_SYSTEM_IDENTIFIER=""
REMOTE_ROLE=""
REMOTE_TOPOLOGY_ROLE=""
REMOTE_DOWNSTREAM_COUNT=""
REMOTE_RECOVERY_TARGET_TIMELINE=""
REMOTE_RECEIVER_SLOT=""
REMOTE_MAX_WAL_SENDERS=""
REMOTE_MAX_REPLICATION_SLOTS=""
REMOTE_REPLICATION_SLOT_COUNT=""
REMOTE_RISKY_PHYSICAL_SLOT_COUNT=""
REMOTE_ARCHIVED_COUNT=""
REMOTE_ARCHIVER_FAILED_COUNT=""
REMOTE_LAST_ARCHIVED_TIME=""
REMOTE_LAST_FAILED_TIME=""
REMOTE_ARCHIVER_UNRESOLVED=""
REMOTE_WAL_LEVEL=""
REMOTE_LOGICAL_SLOT_COUNT=""

say() { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() {
    printf '[WARN] %s\n' "$*" >&2
    record_check "WARNING" "Runtime" "$*"
}
error() { printf '[ERROR] %s\n' "$*" >&2; }

section() {
    say ""
    say "==============================================================================="
    printf '[ %s ]\n' "$1"
    [ -n "${2:-}" ] && printf '  %s\n' "$2"
    say "==============================================================================="
}

subsection() {
    say ""
    printf '%s\n' "-- $1 ------------------------------------------------------------"
}

kv() {
    printf '  %-30s : %s\n' "$1" "${2:-}"
}

die() {
    LAST_ERROR=$*
    record_check "FAILED" "Validation" "$*"
    error "$*"
    cleanup_tmp
    exit 1
}

usage_die() {
    LAST_ERROR=$*
    error "$*"
    exit "$EXIT_USAGE"
}

remote_die() {
    LAST_ERROR=$*
    record_check "FAILED" "Remote Execution" "$*"
    error "$*"
    exit "$EXIT_REMOTE"
}

cancel_operation() {
    LAST_ERROR=$*
    record_check "CANCELLED" "Operation" "$*"
    printf '[CANCELLED] %s\n' "$*" >&2
    cleanup_tmp
    exit "$EXIT_CANCELLED"
}

classify_remote_failure() {
    crf_code=$1
    shift
    case "$crf_code" in
        21|127|255) remote_die "$*" ;;
        *) die "$*" ;;
    esac
}

redact_result_text() {
    printf '%s' "$*" | sed "s/password[[:space:]]*=[^[:space:]]*/password=<redacted>/g; s/passfile[[:space:]]*=[^[:space:]]*/passfile=<redacted>/g; s/primary_conninfo[[:space:]]*=[^|]*/primary_conninfo=<redacted>/g"
}

record_check() {
    rc_status=$1
    rc_name=$2
    shift 2
    [ "$RESULT_INITIALIZED" -eq 1 ] 2>/dev/null || return 0
    rc_detail=$(redact_result_text "$*")
    if ! printf '%s\t%s\t%s\n' "$rc_status" "$rc_name" "$rc_detail" >> "$RESULT_FILE"; then
        LAST_ERROR="Could not write validation result file: $RESULT_FILE"
        error "$LAST_ERROR"
        exit 1
    fi
}

initialize_result_report() {
    irr_time=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo unknown)
    RESULT_FILE="$STATE_DIR/check_result_${irr_time}_$$.txt"
    {
        printf 'PostgreSQL Physical Replication Control v%s\n' "$SCRIPT_VERSION"
        printf 'execution_time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
        printf 'mode=%s\n' "$( [ "$CHECK_ONLY" -eq 1 ] && echo check-only || echo interactive )"
        printf 'data_directory=%s\n' "$PGDATA"
        printf 'port=%s\n' "$PGPORT"
        printf 'system_identifier=%s\n' "$SYSTEM_IDENTIFIER"
        printf 'current_role=%s\n' "$(current_topology_role 2>/dev/null || echo unknown)"
        printf '\nSTATUS\tCHECK\tDETAIL\n'
    } > "$RESULT_FILE" || die "Could not create validation result file: $RESULT_FILE"
    chmod 600 "$RESULT_FILE" || die "Could not protect validation result file: $RESULT_FILE"
    RESULT_INITIALIZED=1
}

finalize_result_report() {
    frr_code=$1
    [ "$RESULT_INITIALIZED" -eq 1 ] 2>/dev/null || return 0
    if [ "$frr_code" -eq 0 ]; then
        frr_status=$(awk -F '\t' '$1=="FAILED" {failed=1} $1=="WARNING" {warning=1} $1=="MANUAL CHECK" {manual=1} END {if(failed) print "FAILED"; else if(warning) print "WARNING"; else if(manual) print "MANUAL CHECK"; else print "PASSED"}' "$RESULT_FILE")
        case "$frr_status" in
            PASSED) frr_detail="all automated checks passed" ;;
            MANUAL\ CHECK) frr_detail="automated checks completed; manual verification remains" ;;
            WARNING) frr_detail="automated checks completed with warnings; review before any role change" ;;
            *) frr_detail="an earlier check failed; review the report" ;;
        esac
    elif [ "$frr_code" -eq "$EXIT_USAGE" ]; then
        frr_status="FAILED"
        frr_detail="input or usage error"
    elif [ "$frr_code" -eq "$EXIT_REMOTE" ]; then
        frr_status="FAILED"
        frr_detail="remote connection or execution error"
    elif [ "$frr_code" -eq "$EXIT_CANCELLED" ]; then
        frr_status="CANCELLED"
        frr_detail=${LAST_ERROR:-operation cancelled by user}
    else
        frr_status="FAILED"
        frr_detail=${LAST_ERROR:-operation failed}
    fi
    if ! printf '%s\t%s\t%s\n' "$frr_status" "Final Result" "$(redact_result_text "$frr_detail")" >> "$RESULT_FILE"; then
        error "Could not finalize validation result file: $RESULT_FILE"
        return 1
    fi
}

print_result_summary() {
    [ "$RESULT_INITIALIZED" -eq 1 ] 2>/dev/null || return 0
    say ""
    say "Validation Result Summary"
    awk -F '\t' 'NF >= 2 && ($1=="PASSED" || $1=="WARNING" || $1=="FAILED" || $1=="MANUAL CHECK" || $1=="CANCELLED") {printf "  %-12s %-28s %s\n", "[" $1 "]", $2, $3}' "$RESULT_FILE" 2>/dev/null || true
    printf '  Result File  : %s\n' "$RESULT_FILE"
}

cleanup_tmp() {
    printf '%s\n' "$TMP_FILES" | while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
    done
}

on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$CURRENT_PHASE" in
            before_primary_stop|initial|precheck)
                # ALTER SYSTEM changes staged for role reversal must be restored
                # while the current Primary Server is still available.
                rollback_preconfigured_primary
                ;;
            after_primary_stop)
                if [ "$SWITCHOVER_PROMOTED" -eq 0 ]; then
                    warn "Switchover stopped after the former Primary was shut down but before promotion."
                    warn "The former Primary may be safely restartable only after verifying that the candidate was NOT promoted."
                fi
                ;;
            after_promotion|rejoin_old_primary)
                warn "The candidate has been promoted. Do NOT restart the former Primary as a Primary."
                warn "Keep the former Primary stopped until it is confirmed to start with standby.signal and correct primary_conninfo."
                manual_recovery_branch_notice
                ;;
        esac
    fi
    [ -z "$SIGNAL_NAME" ] || record_check "FAILED" "Signal" "$SIGNAL_NAME received"
    if [ "$CHECK_ONLY" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$RESULT_INITIALIZED" -eq 1 ]; then
        if awk -F '\t' '$1=="FAILED" || $1=="WARNING" || $1=="MANUAL CHECK" {found=1} END {exit !found}' "$RESULT_FILE"; then
            rc=1
            LAST_ERROR="check-only has unresolved warnings or manual checks"
        fi
    fi
    if [ "$REMOTE_LOCK_HELD" -eq 1 ]; then
        if ! remote_invoke --remote-lock-release "$REMOTE_PGDATA" "$REMOTE_LOCK_TOKEN" >/dev/null 2>&1; then
            warn "Could not release candidate instance lock. Inspect $REMOTE_PGDATA/.postgresql-role-switch.lock on the candidate host."
            rc=1
        fi
    fi
    finalize_result_report "$rc" || rc=1
    print_result_summary
    cleanup_tmp
    release_instance_lock
    exit "$rc"
}
trap on_exit EXIT
trap 'SIGNAL_NAME=HUP; LAST_ERROR="HUP received"; exit 129' HUP
trap 'SIGNAL_NAME=INT; LAST_ERROR="INT received"; exit 130' INT
trap 'SIGNAL_NAME=TERM; LAST_ERROR="TERM received"; exit 143' TERM

mktemp_safe() {
    command -v mktemp >/dev/null 2>&1 || return 1
    t=$(mktemp "${TMPDIR:-/tmp}/pg-role-switch.XXXXXX") || return 1
    if [ -z "$TMP_FILES" ]; then
        TMP_FILES=$t
    else
        TMP_FILES="$TMP_FILES
$t"
    fi
    SAFE_TMP=$t
}

ask() {
    prompt_text=$1
    default_value=${2:-}
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt_text" "$default_value" >&2
    else
        printf '%s: ' "$prompt_text" >&2
    fi
    IFS= read -r answer_value || return 1
    if [ -z "$answer_value" ]; then
        answer_value=$default_value
    fi
    printf '%s\n' "$answer_value"
}

confirm_word() {
    expected_word=$1
    message_text=$2
    say "$message_text"
    printf 'Type "%s" to continue: ' "$expected_word" >&2
    IFS= read -r confirm_value || return 1
    [ "$confirm_value" = "$expected_word" ]
}

choose_yes_no() {
    yn_prompt=$1
    yn_default=${2:-no}
    while :; do
        yn_value=$(ask "$yn_prompt (yes/no)" "$yn_default") || return 1
        case "$yn_value" in
            yes|YES|Yes|y|Y) return 0 ;;
            no|NO|No|n|N) return 1 ;;
            *) say "Enter yes or no." ;;
        esac
    done
}

shell_quote() {
    # Prints one shell-safe single-quoted word.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

conninfo_quote_value() {
    # libpq keyword/value format: backslash-escape backslash and single quote.
    printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

sanitize_identifier() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g; s/^_*//; s/_*$//'
}

read_pid_line() {
    rp_file=$1
    rp_line=$2
    sed -n "${rp_line}p" "$rp_file" 2>/dev/null
}

process_start_token() {
    pst_pid=$1
    if [ -r "/proc/$pst_pid/stat" ]; then
        # Remove pid and the parenthesized comm field first; field 20 of the
        # remainder is the Linux process starttime (original field 22).
        sed 's/^[0-9][0-9]* (.*) //' "/proc/$pst_pid/stat" 2>/dev/null | awk '{print $20; exit}'
        return
    fi
    ps -o lstart= -p "$pst_pid" 2>/dev/null | sed -n '1p'
}

process_is_running() {
    pir_pid=$1
    case "$pir_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pir_pid" 2>/dev/null
}

remove_lock_directory() {
    rld_dir=$1
    [ -n "$rld_dir" ] || return 1
    case "$rld_dir" in "$LOCK_ROOT"/*) ;; *) return 1 ;; esac
    for rld_name in owner pid started_at system_identifier data_directory; do
        [ ! -e "$rld_dir/$rld_name" ] || unlink "$rld_dir/$rld_name" 2>/dev/null || return 1
    done
    rmdir "$rld_dir" 2>/dev/null
}

acquire_instance_lock() {
    # Store the lock under the selected data directory, not a per-user runtime
    # path. Every OS account resolving the same PGDATA contends for one lock.
    LOCK_ROOT=$PGDATA
    [ -d "$LOCK_ROOT" ] && [ -w "$LOCK_ROOT" ] || die "Cannot lock the PostgreSQL data_directory: $LOCK_ROOT"
    # A configured PGDATA may itself be a symlink; mkdir below still resolves
    # to the same physical data directory for all callers.
    LOCK_DIR="$LOCK_ROOT/.postgresql-role-switch.lock"
    [ ! -L "$LOCK_DIR" ] || die "Refusing symbolic-link instance lock: $LOCK_DIR"
    ail_start=$(process_start_token $$ 2>/dev/null || true)
    LOCK_OWNER_TOKEN="$$:${ail_start:-unknown}"

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        ail_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)
        ail_owner=$(sed -n '1p' "$LOCK_DIR/owner" 2>/dev/null || true)
        case "$ail_owner" in
            remote:*) die "A remote Switchover owns this instance lock. Do not remove it until its controller has finished: $LOCK_DIR" ;;
        esac
        # Another process may still be writing owner metadata. Never reclaim
        # an incomplete lock, or one whose PID is currently in use.
        case "$ail_pid" in ''|*[!0-9]*) die "Instance lock PID metadata is incomplete; manual inspection required: $LOCK_DIR" ;; esac
        [ -n "$ail_owner" ] || die "Instance lock owner metadata is incomplete; manual inspection required: $LOCK_DIR"
        [ "${ail_owner%%:*}" = "$ail_pid" ] || die "Instance lock owner metadata does not match its PID: $LOCK_DIR"
        if process_is_running "$ail_pid"; then
            die "Another process is already operating on this PostgreSQL instance: pid=$ail_pid, data_directory=$PGDATA, system_identifier=$SYSTEM_IDENTIFIER"
        fi
        [ "$(sed -n '1p' "$LOCK_DIR/system_identifier" 2>/dev/null)" = "$SYSTEM_IDENTIFIER" ] || die "Stale lock system_identifier does not match: $LOCK_DIR"
        [ "$(sed -n '1p' "$LOCK_DIR/data_directory" 2>/dev/null)" = "$PGDATA" ] || die "Stale lock data_directory does not match: $LOCK_DIR"
        remove_lock_directory "$LOCK_DIR" || die "A stale lock exists but could not be removed safely: $LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || die "Another process acquired the PostgreSQL instance lock: $LOCK_DIR"
    fi

    LOCK_HELD=1
    printf '%s\n' "$LOCK_OWNER_TOKEN" > "$LOCK_DIR/owner" || die "Could not write lock owner metadata."
    printf '%s\n' "$$" > "$LOCK_DIR/pid" || die "Could not write lock PID metadata."
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" > "$LOCK_DIR/started_at" || die "Could not write lock start metadata."
    printf '%s\n' "$SYSTEM_IDENTIFIER" > "$LOCK_DIR/system_identifier" || die "Could not write lock system_identifier metadata."
    printf '%s\n' "$PGDATA" > "$LOCK_DIR/data_directory" || die "Could not write lock data_directory metadata."
}

release_instance_lock() {
    [ "$LOCK_HELD" -eq 1 ] 2>/dev/null || return 0
    ril_owner=$(sed -n '1p' "$LOCK_DIR/owner" 2>/dev/null || true)
    if [ "$ril_owner" = "$LOCK_OWNER_TOKEN" ]; then
        remove_lock_directory "$LOCK_DIR" || true
    fi
    LOCK_HELD=0
}

discover_pgdata_candidates() {
    # First preference: explicit runtime PGDATA, if valid.
    if [ -n "${PGDATA:-}" ] && [ -f "$PGDATA/postmaster.pid" ]; then
        printf '%s\n' "$PGDATA"
        return 0
    fi

    # Linux/Unix process discovery. We intentionally avoid scanning the whole filesystem.
    ps -eo args= 2>/dev/null | awk '
        /(^|\/)(postgres)([[:space:]]|$)/ {
            for (i=1; i<=NF; i++) {
                if ($i == "-D" && (i+1) <= NF) {
                    print $(i+1)
                } else if ($i ~ /^--pgdata=/) {
                    sub(/^--pgdata=/, "", $i); print $i
                }
            }
        }
    ' | sed '/^$/d' | sort -u
}

find_postgres_bindir_from_pid() {
    fp_pid=$1
    if [ -n "$fp_pid" ] && [ -e "/proc/$fp_pid/exe" ] && command -v readlink >/dev/null 2>&1; then
        fp_exe=$(readlink "/proc/$fp_pid/exe" 2>/dev/null || true)
        if [ -n "$fp_exe" ]; then
            dirname "$fp_exe"
            return 0
        fi
    fi
    return 1
}

find_binary() {
    fb_name=$1
    fb_bindir=${2:-}

    if [ -n "$fb_bindir" ] && [ -x "$fb_bindir/$fb_name" ]; then
        printf '%s\n' "$fb_bindir/$fb_name"
        return 0
    fi

    if [ -n "${PG_BINDIR:-}" ] && [ -x "$PG_BINDIR/$fb_name" ]; then
        printf '%s\n' "$PG_BINDIR/$fb_name"
        return 0
    fi

    fb_path=$(command -v "$fb_name" 2>/dev/null || true)
    if [ -n "$fb_path" ] && [ -x "$fb_path" ]; then
        printf '%s\n' "$fb_path"
        return 0
    fi

    if command -v pg_config >/dev/null 2>&1; then
        fb_pc_bindir=$(pg_config --bindir 2>/dev/null || true)
        if [ -n "$fb_pc_bindir" ] && [ -x "$fb_pc_bindir/$fb_name" ]; then
            printf '%s\n' "$fb_pc_bindir/$fb_name"
            return 0
        fi
    fi

    return 1
}

binary_major_version() {
    bmv_bin=$1
    [ -n "$bmv_bin" ] && [ -x "$bmv_bin" ] || return 1
    "$bmv_bin" --version 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+([.][0-9]+)*$/) {
                split($i, v, ".")
                print v[1]
                exit
            }
        }
    }'
}

validate_matching_server_binaries() {
    vmsb_name=$1
    vmsb_path=$2
    [ -n "$vmsb_path" ] && [ -x "$vmsb_path" ] || return 0
    vmsb_major=$(binary_major_version "$vmsb_path" 2>/dev/null || true)
    [ -n "$vmsb_major" ] || die "Could not determine $vmsb_name version: $vmsb_path"
    [ "$vmsb_major" = "$PG_MAJOR" ] || die "$vmsb_name major version ($vmsb_major) does not match the running PostgreSQL server major version ($PG_MAJOR). Set PG_BINDIR at runtime to the matching PostgreSQL bin directory."
}


# POSIX sh cannot safely expand optional arguments from ${var:+...} when the value
# itself may contain spaces. Use a dedicated runner for all production calls.
psql_call() {
    pc_sql=$1
    if [ -n "$PGUSER_LOCAL" ] && [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -U "$PGUSER_LOCAL" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME" -c "$pc_sql"
    elif [ -n "$PGUSER_LOCAL" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -U "$PGUSER_LOCAL" -p "$PGPORT" -d "$DB_NAME" -c "$pc_sql"
    elif [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME" -c "$pc_sql"
    elif [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -p "$PGPORT" -d "$DB_NAME" -c "$pc_sql"
    else
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "$pc_sql"
    fi
}

psql_call_file() {
    pcf_file=$1
    if [ -n "$PGUSER_LOCAL" ] && [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -U "$PGUSER_LOCAL" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME" -f "$pcf_file"
    elif [ -n "$PGUSER_LOCAL" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -U "$PGUSER_LOCAL" -p "$PGPORT" -d "$DB_NAME" -f "$pcf_file"
    elif [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME" -f "$pcf_file"
    elif [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -p "$PGPORT" -d "$DB_NAME" -f "$pcf_file"
    else
        "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" -f "$pcf_file"
    fi
}

psql_call_var() {
    pcv_name=$1
    pcv_value=$2
    pcv_sql=$3
    if [ -n "$PGUSER_LOCAL" ] && [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -U "$PGUSER_LOCAL" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME" -c "$pcv_sql"
    elif [ -n "$PGUSER_LOCAL" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -U "$PGUSER_LOCAL" -p "$PGPORT" -d "$DB_NAME" -c "$pcv_sql"
    elif [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME" -c "$pcv_sql"
    elif [ -n "$PGPORT" ]; then
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -p "$PGPORT" -d "$DB_NAME" -c "$pcv_sql"
    else
        "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -d "$DB_NAME" -c "$pcv_sql"
    fi
}

try_connect_local() {
    tc_db=$1
    DB_NAME=$tc_db
    psql_call "SELECT 1" >/dev/null 2>&1
}

init_instance_from_pgdata() {
    ii_pgdata=$1
    ii_quiet=${2:-0}

    [ -d "$ii_pgdata" ] || return 1
    [ -f "$ii_pgdata/postmaster.pid" ] || return 1

    PGDATA=$ii_pgdata
    POSTMASTER_PID=$(read_pid_line "$PGDATA/postmaster.pid" 1)
    [ -n "$POSTMASTER_PID" ] || return 1

    POSTMASTER_OPTIONS="$PG_START_OPTIONS"
    if [ -z "$POSTMASTER_OPTIONS" ] && [ -r "$PGDATA/postmaster.opts" ]; then
        ii_opts_line=$(sed -n '1p' "$PGDATA/postmaster.opts" 2>/dev/null || true)
        case "$ii_opts_line" in
            *' '*) POSTMASTER_OPTIONS=${ii_opts_line#* } ;;
        esac
    fi

    PGPORT=$(read_pid_line "$PGDATA/postmaster.pid" 4)
    SOCKET_DIR=$(read_pid_line "$PGDATA/postmaster.pid" 5)

    # Some builds record multiple socket directories or an empty line.
    case "$SOCKET_DIR" in
        *,*) SOCKET_DIR=$(printf '%s' "$SOCKET_DIR" | awk -F, '{print $1}') ;;
    esac

    ii_bindir=$(find_postgres_bindir_from_pid "$POSTMASTER_PID" 2>/dev/null || true)
    PSQL_BIN=$(find_binary psql "$ii_bindir" 2>/dev/null || true)
    [ -n "$PSQL_BIN" ] || return 1

    PG_CTL_BIN=$(find_binary pg_ctl "$ii_bindir" 2>/dev/null || true)
    PG_CONTROLDATA_BIN=$(find_binary pg_controldata "$ii_bindir" 2>/dev/null || true)

    if [ -z "$PGUSER_LOCAL" ]; then
        PGUSER_LOCAL=$(ps -o user= -p "$POSTMASTER_PID" 2>/dev/null | awk '{print $1; exit}')
        [ -n "$PGUSER_LOCAL" ] || PGUSER_LOCAL=$(id -un 2>/dev/null || echo "")
    fi

    if try_connect_local postgres; then
        :
    elif try_connect_local template1; then
        :
    else
        return 1
    fi

    PG_VERSION_NUM=$(psql_call "SHOW server_version_num" 2>/dev/null | tr -d '[:space:]') || return 1
    PG_MAJOR=$((PG_VERSION_NUM / 10000))
    validate_matching_server_binaries "pg_ctl" "$PG_CTL_BIN"
    validate_matching_server_binaries "pg_controldata" "$PG_CONTROLDATA_BIN"
    SYSTEM_IDENTIFIER=$(psql_call "SELECT system_identifier FROM pg_control_system()" 2>/dev/null | tr -d '[:space:]') || return 1
    LOCAL_ROLE=$(psql_call "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END" 2>/dev/null | tr -d '[:space:]') || return 1
    CONFIG_FILE=$(psql_call "SHOW config_file" 2>/dev/null | sed -n '1p') || return 1
    AUTO_CONF="$PGDATA/postgresql.auto.conf"

    if [ "$ii_quiet" -eq 0 ]; then
        info "Connected to PostgreSQL instance: PGDATA=$PGDATA port=$PGPORT role=$LOCAL_ROLE version=$PG_MAJOR"
    fi
    return 0
}

select_local_instance() {
    mktemp_safe || die "Could not create temporary file."
    sl_tmp=$SAFE_TMP
    mktemp_safe || die "Could not create temporary file."
    sl_inventory=$SAFE_TMP
    discover_pgdata_candidates > "$sl_tmp"
    sl_count=$(wc -l < "$sl_tmp" | tr -d '[:space:]')

    if [ "$sl_count" -eq 0 ]; then
        say "PostgreSQL Data Directory (PGDATA)"
        say "  실행 인스턴스를 자동 탐지하지 못했습니다. 현재 사용 중인 data directory를 입력합니다."
        sl_manual=$(ask "PGDATA" "") || usage_die "Input cancelled."
        [ -n "$sl_manual" ] || usage_die "PGDATA is required."
        init_instance_from_pgdata "$sl_manual" 0 || die "Could not connect to PostgreSQL using PGDATA=$sl_manual. Set PGUSER/PG_BINDIR at runtime if required."
        return 0
    fi

    # Build a lightweight inventory without assuming one PostgreSQL instance per host.
    # Port is read from each running instance's postmaster.pid, not from a hard-coded default.
    sl_n=0
    while IFS= read -r sl_pgdata; do
        [ -n "$sl_pgdata" ] || continue
        sl_n=$((sl_n + 1))
        sl_port=$(read_pid_line "$sl_pgdata/postmaster.pid" 4)
        sl_version=""
        [ -r "$sl_pgdata/PG_VERSION" ] && sl_version=$(sed -n '1p' "$sl_pgdata/PG_VERSION" 2>/dev/null)
        [ -n "$sl_port" ] || sl_port="unknown"
        [ -n "$sl_version" ] || sl_version="unknown"
        printf '%s\t%s\t%s\t%s\n' "$sl_n" "$sl_pgdata" "$sl_port" "$sl_version" >> "$sl_inventory"
    done < "$sl_tmp"

    if [ "$sl_count" -eq 1 ]; then
        sl_one=$(awk -F '\t' 'NR==1 {print $2}' "$sl_inventory")
        init_instance_from_pgdata "$sl_one" 0 || die "Discovered instance could not be connected: $sl_one"
        return 0
    fi

    say ""
    say "PostgreSQL Instance Selection"
    say "  동일 서버에서 여러 PostgreSQL 인스턴스가 실행 중입니다."
    say "  PGDATA와 Port를 확인한 뒤 작업할 인스턴스 번호 또는 Port를 입력합니다."
    awk -F '\t' '{
        printf "  %s. PGDATA=%s | Port=%s | Version=%s\n", $1, $2, $3, $4
    }' "$sl_inventory"

    while :; do
        sl_sel=$(ask "Instance number or Port" "") || usage_die "Input cancelled."
        case "$sl_sel" in
            *[!0-9]*|'')
                say "숫자로 Instance number 또는 Port를 입력합니다."
                ;;
            *)
                # Prefer an exact instance-number match first.
                sl_pick=$(awk -F '\t' -v v="$sl_sel" '$1 == v {print $2; exit}' "$sl_inventory")
                if [ -z "$sl_pick" ]; then
                    sl_matches=$(awk -F '\t' -v v="$sl_sel" '$3 == v {n++} END {print n+0}' "$sl_inventory")
                    if [ "$sl_matches" -gt 1 ]; then
                        say "동일 Port가 여러 후보와 일치합니다. Instance number로 선택합니다."
                        continue
                    fi
                    sl_pick=$(awk -F '\t' -v v="$sl_sel" '$3 == v {print $2; exit}' "$sl_inventory")
                fi

                if [ -n "$sl_pick" ]; then
                    init_instance_from_pgdata "$sl_pick" 0 || die "Could not connect to selected instance: $sl_pick"
                    return 0
                fi
                say "일치하는 Instance number 또는 Port가 없습니다."
                ;;
        esac
    done
}

validate_supported_version() {
    [ "$PG_MAJOR" -ge 12 ] 2>/dev/null || die "PostgreSQL $PG_MAJOR is outside the supported range (12-18)."
    [ "$PG_MAJOR" -le 18 ] 2>/dev/null || die "PostgreSQL $PG_MAJOR is outside the supported range (12-18)."
}

validate_wait_seconds() {
    vws_value=$1
    case "$vws_value" in ''|*[!0-9]*) return 1 ;; esac
    [ "$vws_value" -ge 1 ] 2>/dev/null || return 1
    [ "$vws_value" -le "$MAX_WAIT_SECONDS" ] 2>/dev/null
}

bounded_wait_seconds() {
    bws_value=$1
    case "$bws_value" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bws_value" -ge 1 ] 2>/dev/null || return 1
    [ "$bws_value" -le "$MAX_WAIT_SECONDS" ] 2>/dev/null && printf '%s\n' "$bws_value" || printf '%s\n' "$MAX_WAIT_SECONDS"
}

check_local_write_permissions() {
    clwp_auto_parent=${AUTO_CONF%/*}
    [ "$clwp_auto_parent" != "$AUTO_CONF" ] || clwp_auto_parent=$PGDATA
    if [ -e "$AUTO_CONF" ]; then
        [ -w "$AUTO_CONF" ] || die "postgresql.auto.conf is not writable by the current OS user: $AUTO_CONF"
    else
        [ -w "$clwp_auto_parent" ] || die "The postgresql.auto.conf directory is not writable by the current OS user: $clwp_auto_parent"
    fi
    [ -w "$PGDATA" ] || die "data_directory is not writable by the current OS user; standby.signal cannot be created: $PGDATA"
    record_check "PASSED" "Write Permissions" "postgresql.auto.conf and data_directory"
}

check_local_execution_account() {
    clea_owner=$(ps -o user= -p "$POSTMASTER_PID" 2>/dev/null | awk '{print $1; exit}')
    clea_user=$(id -un 2>/dev/null || echo '')
    [ -n "$clea_owner" ] && [ "$clea_user" = "$clea_owner" ] || die "Planned Switchover must run as the PostgreSQL server OS account ($clea_owner), not $clea_user; pg_ctl cannot safely administer this instance under another account."
    [ -n "$PG_CTL_BIN" ] && [ -x "$PG_CTL_BIN" ] || die "Matching pg_ctl is not executable by the PostgreSQL server OS account."
    [ -n "$PG_CONTROLDATA_BIN" ] && [ -x "$PG_CONTROLDATA_BIN" ] || die "Matching pg_controldata is not executable by the PostgreSQL server OS account."
    record_check "PASSED" "Local Execution Account" "server OS account=$clea_owner; pg_ctl and pg_controldata executable"
}

check_pg_wal_free_space() {
    cpw_path="$PGDATA/pg_wal"
    [ -d "$cpw_path" ] || cpw_path="$PGDATA/pg_xlog"
    [ -d "$cpw_path" ] || die "WAL directory was not found under data_directory."
    cpw_available_kb=$(df -Pk "$cpw_path" 2>/dev/null | awk 'NR==2 {print $4; exit}')
    cpw_max_wal_bytes=$(psql_call "SELECT pg_size_bytes(setting || CASE WHEN unit IS NULL OR unit='' THEN '' ELSE unit END) FROM pg_settings WHERE name='max_wal_size'" 2>/dev/null | tr -d '[:space:]') || cpw_max_wal_bytes=""
    case "$cpw_available_kb:$cpw_max_wal_bytes" in *[!0-9:]*|:*|*:) die "Could not determine pg_wal free space or max_wal_size." ;; esac
    cpw_available_bytes=$((cpw_available_kb * 1024))
    cpw_required_bytes=$((cpw_max_wal_bytes * 2))
    if [ "$cpw_available_bytes" -lt "$cpw_required_bytes" ]; then
        warn "Available pg_wal filesystem space is less than twice max_wal_size: available_bytes=$cpw_available_bytes, required_bytes=$cpw_required_bytes"
        record_check "MANUAL CHECK" "pg_wal Free Space" "Review WAL generation rate and outage duration."
    else
        record_check "MANUAL CHECK" "pg_wal Free Space" "available_bytes=$cpw_available_bytes; twice_max_wal_size=$cpw_required_bytes is a screening threshold, not a safe retention limit"
    fi
}

check_wal_retention_risk() {
    cwr_operation=$1
    check_pg_wal_free_space
    cwr_slots=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='physical'" 2>/dev/null | tr -d '[:space:]') || die "Could not query physical replication slots before $cwr_operation."
    case "$cwr_slots" in ''|*[!0-9]*) die "Invalid physical replication slot count before $cwr_operation." ;; esac
    record_check "MANUAL CHECK" "$cwr_operation" "physical_replication_slots=$cwr_slots; max_wal_size is not a hard retention limit; assess WAL generation rate and outage duration"
    warn "$cwr_operation can retain WAL beyond max_wal_size when a replication slot or stalled replay prevents removal."
}

prepare_state_dir() {
    ps_base=${XDG_STATE_HOME:-}
    if [ -z "$ps_base" ]; then
        if [ -n "${HOME:-}" ]; then
            ps_base="$HOME/.local/state"
        else
            ps_base="$PGDATA"
        fi
    fi
    STATE_DIR="$ps_base/postgresql-role-switch"
    mkdir -p "$STATE_DIR" || die "Cannot create state directory: $STATE_DIR"
    chmod 700 "$STATE_DIR" || die "Cannot protect state directory: $STATE_DIR"
    if command -v cksum >/dev/null 2>&1; then
        STATE_KEY=$(printf '%s|%s' "$PGDATA" "$SYSTEM_IDENTIFIER" | cksum | awk '{print $1}')
    else
        STATE_KEY=$(printf '%s' "$SYSTEM_IDENTIFIER" | sed 's/[^0-9A-Za-z]/_/g')
    fi
}

refresh_role() {
    LOCAL_ROLE=$(psql_call "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END" 2>/dev/null | tr -d '[:space:]') || return 1
}

current_topology_role() {
    ctr_recovery=$(psql_call "SELECT CASE WHEN pg_is_in_recovery() THEN 1 ELSE 0 END" 2>/dev/null | tr -d '[:space:]') || return 1
    ctr_downstream=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || return 1
    if [ "$ctr_recovery" = "0" ]; then
        printf '%s\n' "Primary"
    elif [ "$ctr_downstream" -gt 0 ] 2>/dev/null; then
        printf '%s\n' "Cascading Standby"
    else
        printf '%s\n' "Standby"
    fi
}

show_role_context() {
    src_role=$(current_topology_role 2>/dev/null || echo "$LOCAL_ROLE")
    kv "Current Role" "$src_role"
    if [ "$src_role" = "Cascading Standby" ]; then
        kv "WAL Receiver" "Upstream Server"
        kv "WAL Sender" "Downstream Standby Server"
    elif [ "$LOCAL_ROLE" = "standby" ]; then
        kv "WAL Receiver" "Upstream Server"
        kv "WAL Sender" "none"
    else
        kv "WAL Receiver" "none"
        kv "WAL Sender" "Downstream Standby Server"
    fi
}

topology_discovery() {
    td_role=$(current_topology_role) || die "Could not determine the replication topology role."
    td_downstream=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || die "Could not inspect downstream Standbys."
    section "Streaming Replication" "현재 Upstream Server와 Downstream Standby Server 관계입니다."
    show_role_context
    if [ "$LOCAL_ROLE" = "standby" ]; then
        td_upstream=$(psql_call "SELECT 'sender_host=' || COALESCE(sender_host,'') || ' | sender_port=' || COALESCE(sender_port::text,'') || ' | status=' || COALESCE(status,'') || ' | slot_name=' || COALESCE(slot_name,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p') || td_upstream=""
        kv "pg_stat_wal_receiver" "${td_upstream:-no rows}"
        kv "recovery_target_timeline" "$(psql_call "SHOW recovery_target_timeline" 2>/dev/null | sed -n '1p')"
    else
        kv "pg_stat_wal_receiver" "no rows"
    fi
    kv "SELECT count(*) FROM pg_stat_replication" "$td_downstream"
    if [ "$td_downstream" -gt 0 ] 2>/dev/null; then
        subsection "pg_stat_replication"
        psql_call "SELECT '[' || application_name || ']' || E'\\n    client_addr             : ' || COALESCE(client_addr::text,'') || E'\\n    state                   : ' || state || E'\\n    sync_state              : ' || sync_state || E'\\n    replay_lsn              : ' || COALESCE(replay_lsn::text,'') FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical') ORDER BY application_name, client_addr NULLS FIRST, pid" 2>/dev/null | sed 's/^/  /'
    fi
}

setting_exists() {
    se_name=$1
    psql_call_var setting_name "$se_name" "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_settings WHERE name = :'setting_name') THEN 1 ELSE 0 END" 2>/dev/null | grep '^1$' >/dev/null 2>&1
}

column_exists() {
    ce_view=$1
    ce_column=$2
    psql_call "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='${ce_view}'::regclass AND attname='${ce_column}' AND NOT attisdropped) THEN 1 ELSE 0 END" 2>/dev/null | grep '^1$' >/dev/null 2>&1
}

pause_state() {
    if [ "$PG_MAJOR" -ge 14 ]; then
        psql_call "SELECT pg_get_wal_replay_pause_state()" 2>/dev/null | tr -d '\r'
    else
        ps_bool=$(psql_call "SELECT pg_is_wal_replay_paused()" 2>/dev/null | tr -d '[:space:]') || return 1
        case "$ps_bool" in
            t|true) printf '%s\n' "pause requested" ;;
            *) printf '%s\n' "not paused" ;;
        esac
    fi
}

pause_state_name() {
    if [ "$PG_MAJOR" -ge 14 ]; then
        printf '%s\n' "pg_get_wal_replay_pause_state()"
    else
        printf '%s\n' "pg_is_wal_replay_paused()"
    fi
}

archive_mechanism_configured() {
    amc_command=$(psql_call "SHOW archive_command" 2>/dev/null | sed -n '1p') || amc_command=""
    amc_library=""
    if [ "$PG_MAJOR" -ge 15 ]; then
        amc_library=$(psql_call "SHOW archive_library" 2>/dev/null | sed -n '1p') || amc_library=""
    fi
    if [ -n "$amc_command" ] || [ -n "$amc_library" ]; then
        printf '%s\n' 1
    else
        printf '%s\n' 0
    fi
}

show_instance_summary() {
    refresh_role || die "Could not read current PostgreSQL role."
    section "PostgreSQL Instance" "현재 선택된 PostgreSQL 인스턴스의 기본 정보입니다."
    kv "server_version" "$(psql_call "SHOW server_version" 2>/dev/null | sed -n '1p')"
    kv "data_directory" "$PGDATA"
    kv "port" "$PGPORT"
    show_role_context
    kv "system_identifier" "$SYSTEM_IDENTIFIER"
    kv "config_file" "$CONFIG_FILE"
}

show_replication_settings() {
    subsection "pg_settings"
    psql_call "SELECT rpad(name,30) || ' : ' || setting || CASE WHEN unit IS NULL OR unit='' THEN '' ELSE ' ' || unit END || '  [source=' || source || ']' FROM pg_settings WHERE name IN ('wal_level','max_wal_senders','max_replication_slots','wal_keep_size','max_slot_wal_keep_size','wal_sender_timeout','wal_receiver_timeout','wal_receiver_status_interval','hot_standby','hot_standby_feedback','max_standby_streaming_delay','max_standby_archive_delay','recovery_min_apply_delay','recovery_target_timeline','synchronous_commit','synchronous_standby_names','primary_slot_name','archive_mode') ORDER BY name" 2>/dev/null | sed 's/^/  /'
}

show_replication_slots() {
    srs_count=$(psql_call "SELECT count(*) FROM pg_replication_slots" 2>/dev/null | tr -d '[:space:]') || srs_count=0
    if [ "$LOCAL_ROLE" = "standby" ] && [ "$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]')" -gt 0 ] 2>/dev/null; then
        subsection "pg_replication_slots"
    else
        subsection "pg_replication_slots"
    fi
    kv "SELECT count(*) FROM pg_replication_slots" "$srs_count"
    [ "$srs_count" -gt 0 ] 2>/dev/null || { say "  (no replication slots)"; return 0; }
    if [ "$PG_MAJOR" -ge 17 ]; then
        srs_extra=" || E'\\n    wal_status              : ' || COALESCE(wal_status,'') || E'\\n    safe_wal_size           : ' || COALESCE(safe_wal_size::text,'') || E'\\n    failover                : ' || failover || E'\\n    synced                  : ' || synced || E'\\n    invalidation_reason     : ' || COALESCE(invalidation_reason,'')"
    elif [ "$PG_MAJOR" -ge 13 ]; then
        srs_extra=" || E'\\n    wal_status              : ' || COALESCE(wal_status,'') || E'\\n    safe_wal_size           : ' || COALESCE(safe_wal_size::text,'')"
    else
        srs_extra=""
    fi
    psql_call "SELECT '  [' || slot_name || ']' || E'\\n    slot_name               : ' || slot_name || E'\\n    plugin                  : ' || COALESCE(plugin,'') || E'\\n    slot_type               : ' || slot_type || E'\\n    database                : ' || COALESCE(database,'') || E'\\n    temporary               : ' || temporary || E'\\n    active                  : ' || active || E'\\n    active_pid              : ' || COALESCE(active_pid::text,'') || E'\\n    xmin                    : ' || COALESCE(xmin::text,'') || E'\\n    catalog_xmin            : ' || COALESCE(catalog_xmin::text,'') || E'\\n    restart_lsn             : ' || COALESCE(restart_lsn::text,'') || E'\\n    confirmed_flush_lsn     : ' || COALESCE(confirmed_flush_lsn::text,'') $srs_extra FROM pg_replication_slots ORDER BY slot_name" 2>/dev/null
}

show_wal_senders() {
    sws_count=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || die "Could not query pg_stat_replication."
    if [ "$LOCAL_ROLE" = "standby" ]; then
        subsection "pg_stat_replication"
    else
        subsection "pg_stat_replication"
    fi
    kv "SELECT count(*) FROM pg_stat_replication" "$sws_count"
    [ "$sws_count" -gt 0 ] 2>/dev/null || { warn "No directly connected Standby is visible."; return 0; }
    if ! psql_call "SELECT '  [' || application_name || ']' || E'\\n    pid                     : ' || pid || E'\\n    usesysid                : ' || usesysid || E'\\n    usename                 : ' || usename || E'\\n    application_name        : ' || application_name || E'\\n    client_addr             : ' || COALESCE(client_addr::text,'') || E'\\n    client_hostname         : ' || COALESCE(client_hostname,'') || E'\\n    client_port             : ' || COALESCE(client_port::text,'') || E'\\n    backend_start           : ' || backend_start || E'\\n    backend_xmin            : ' || COALESCE(backend_xmin::text,'') || E'\\n    state                   : ' || state || E'\\n    sent_lsn                : ' || COALESCE(sent_lsn::text,'') || E'\\n    write_lsn               : ' || COALESCE(write_lsn::text,'') || E'\\n    flush_lsn               : ' || COALESCE(flush_lsn::text,'') || E'\\n    replay_lsn              : ' || COALESCE(replay_lsn::text,'') || E'\\n    write_lag               : ' || COALESCE(write_lag::text,'') || E'\\n    flush_lag               : ' || COALESCE(flush_lag::text,'') || E'\\n    replay_lag              : ' || COALESCE(replay_lag::text,'') || E'\\n    sync_priority           : ' || sync_priority || E'\\n    sync_state              : ' || sync_state || E'\\n    reply_time              : ' || COALESCE(reply_time::text,'') FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical') ORDER BY application_name, client_addr NULLS FIRST,pid"; then
        warn "Could not render pg_stat_replication detail. The PostgreSQL error above was retained for diagnosis."
    fi
}

replication_status() {
    refresh_role || die "Could not read current PostgreSQL role."
    topology_discovery
    section "Streaming Replication Monitoring" "WAL Sender, WAL Receiver, replication slot 및 설정을 조회합니다."
    kv "clock_timestamp()" "$(psql_call "SELECT clock_timestamp()" 2>/dev/null | sed -n '1p')"
    show_role_context
    if [ "$LOCAL_ROLE" = "primary" ]; then
        kv "pg_current_wal_lsn()" "$(psql_call "SELECT pg_current_wal_lsn()" 2>/dev/null | sed -n '1p')"
        kv "pg_walfile_name()" "$(psql_call "SELECT pg_walfile_name(pg_current_wal_lsn())" 2>/dev/null | sed -n '1p')"
        kv "timeline_id" "$(psql_call "SELECT timeline_id FROM pg_control_checkpoint()" 2>/dev/null | sed -n '1p')"
        show_wal_senders
    else
        subsection "WAL Receiver Functions"
        kv "$(pause_state_name)" "$(pause_state 2>/dev/null || echo unknown)"
        kv "pg_last_wal_receive_lsn()" "$(psql_call "SELECT COALESCE(pg_last_wal_receive_lsn()::text,'')" 2>/dev/null | sed -n '1p')"
        kv "pg_last_wal_replay_lsn()" "$(psql_call "SELECT COALESCE(pg_last_wal_replay_lsn()::text,'')" 2>/dev/null | sed -n '1p')"
        kv "pg_last_xact_replay_timestamp()" "$(psql_call "SELECT COALESCE(pg_last_xact_replay_timestamp()::text,'')" 2>/dev/null | sed -n '1p')"
        kv "recovery_target_timeline" "$(psql_call "SHOW recovery_target_timeline" 2>/dev/null | sed -n '1p')"
        kv "pg_settings.sourcefile:sourceline" "$(psql_call "SELECT COALESCE(sourcefile,'') || CASE WHEN sourceline IS NULL THEN '' ELSE ':' || sourceline END FROM pg_settings WHERE name='primary_conninfo'" 2>/dev/null | sed -n '1p')"
        subsection "pg_stat_wal_receiver"
        if column_exists pg_stat_wal_receiver flushed_lsn; then
            if ! psql_call "SELECT '  pid                     : ' || pid || E'\\n  status                  : ' || status || E'\\n  receive_start_lsn       : ' || receive_start_lsn || E'\\n  receive_start_tli       : ' || receive_start_tli || E'\\n  written_lsn             : ' || COALESCE(written_lsn::text,'') || E'\\n  flushed_lsn             : ' || COALESCE(flushed_lsn::text,'') || E'\\n  received_tli            : ' || received_tli || E'\\n  last_msg_send_time      : ' || COALESCE(last_msg_send_time::text,'') || E'\\n  last_msg_receipt_time   : ' || COALESCE(last_msg_receipt_time::text,'') || E'\\n  latest_end_lsn          : ' || COALESCE(latest_end_lsn::text,'') || E'\\n  latest_end_time         : ' || COALESCE(latest_end_time::text,'') || E'\\n  slot_name               : ' || COALESCE(slot_name,'') || E'\\n  sender_host             : ' || COALESCE(sender_host,'') || E'\\n  sender_port             : ' || sender_port FROM pg_stat_wal_receiver"; then
                warn "Could not render pg_stat_wal_receiver detail. The PostgreSQL error above was retained for diagnosis."
            fi
        else
            if ! psql_call "SELECT '  pid                     : ' || pid || E'\\n  status                  : ' || status || E'\\n  receive_start_lsn       : ' || receive_start_lsn || E'\\n  receive_start_tli       : ' || receive_start_tli || E'\\n  received_lsn            : ' || COALESCE(received_lsn::text,'') || E'\\n  received_tli            : ' || received_tli || E'\\n  last_msg_send_time      : ' || COALESCE(last_msg_send_time::text,'') || E'\\n  last_msg_receipt_time   : ' || COALESCE(last_msg_receipt_time::text,'') || E'\\n  latest_end_lsn          : ' || COALESCE(latest_end_lsn::text,'') || E'\\n  latest_end_time         : ' || COALESCE(latest_end_time::text,'') || E'\\n  slot_name               : ' || COALESCE(slot_name,'') || E'\\n  sender_host             : ' || COALESCE(sender_host,'') || E'\\n  sender_port             : ' || sender_port FROM pg_stat_wal_receiver"; then
                warn "Could not render pg_stat_wal_receiver detail. The PostgreSQL error above was retained for diagnosis."
            fi
        fi
        sws_downstream=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || sws_downstream=0
        [ "$sws_downstream" -gt 0 ] 2>/dev/null && show_wal_senders
    fi
    show_replication_slots
    show_replication_settings
}

require_standby() {
    refresh_role || die "Could not determine PostgreSQL role."
    [ "$LOCAL_ROLE" = "standby" ] || die "This operation requires a Standby. Current role: $LOCAL_ROLE"
}

require_primary() {
    refresh_role || die "Could not determine PostgreSQL role."
    [ "$LOCAL_ROLE" = "primary" ] || die "This operation requires the current Primary. Current role: $LOCAL_ROLE"
}

pause_wal_replay() {
    require_standby
    check_wal_retention_risk "WAL Replay Pause"
    section "WAL Replay — Pause" "pg_wal_replay_pause(): WAL 수신은 유지하고 적용만 일시 중지합니다."
    say "  장시간 중지하면 수신된 WAL이 누적되어 디스크 사용량이 증가할 수 있습니다."
    if ! choose_yes_no "Pause WAL Replay 실행" "no"; then
        info "Cancelled."
        return 0
    fi
    psql_call "SELECT pg_wal_replay_pause()" >/dev/null || die "pg_wal_replay_pause() failed."
    info "WAL replay pause requested. State: $(pause_state 2>/dev/null || echo unknown)"
}

resume_wal_replay() {
    require_standby
    section "WAL Replay — Resume" "pg_wal_replay_resume(): 일시 중지된 WAL 적용을 다시 시작합니다."
    psql_call "SELECT pg_wal_replay_resume()" >/dev/null || die "pg_wal_replay_resume() failed."
    info "WAL replay resume requested. State: $(pause_state 2>/dev/null || echo unknown)"
}

primary_conninfo_source_guard() {
    pcg_source=$(psql_call "SELECT source FROM pg_settings WHERE name='primary_conninfo'" 2>/dev/null | sed -n '1p') || return 1
    pcg_slot_source=$(psql_call "SELECT source FROM pg_settings WHERE name='primary_slot_name'" 2>/dev/null | sed -n '1p') || return 1
    pcg_timeline_source=$(psql_call "SELECT source FROM pg_settings WHERE name='recovery_target_timeline'" 2>/dev/null | sed -n '1p') || return 1
    if [ "$pcg_source" = "command line" ] || [ "$pcg_slot_source" = "command line" ] || [ "$pcg_timeline_source" = "command line" ]; then
        error "primary_conninfo, primary_slot_name, or recovery_target_timeline is supplied on the postgres command line."
        error "ALTER SYSTEM cannot safely override a higher-precedence command-line value for role reversal."
        error "Use the server's approved startup/service configuration to remove that command-line override before using this operation."
        return 1
    fi
    return 0
}

receiver_state_sql_file() {
    printf '%s/%s.primary_conninfo.restore.sql\n' "$STATE_DIR" "$STATE_KEY"
}

create_primary_conninfo_restore_state() {
    cps_file=$(receiver_state_sql_file)
    [ ! -e "$cps_file" ] || die "A saved WAL Receiver restore state already exists: $cps_file"

    cps_sourcefile=$(psql_call "SELECT COALESCE(sourcefile,'') FROM pg_settings WHERE name='primary_conninfo'" 2>/dev/null | sed -n '1p') || die "Could not inspect primary_conninfo source."

    if [ "$cps_sourcefile" = "$AUTO_CONF" ]; then
        psql_call "SELECT 'ALTER SYSTEM SET primary_conninfo = ' || quote_literal(setting) || ';' FROM pg_settings WHERE name='primary_conninfo'" > "$cps_file" || die "Could not save primary_conninfo restore statement."
    else
        printf '%s\n' "ALTER SYSTEM RESET primary_conninfo;" > "$cps_file" || die "Could not save primary_conninfo restore statement."
    fi
    chmod 600 "$cps_file" || true
}

restart_local_postgresql() {
    [ -n "$PG_CTL_BIN" ] && [ -x "$PG_CTL_BIN" ] || die "Matching pg_ctl was not found. Set PG_BINDIR at runtime if required."
    info "Restarting PostgreSQL with pg_ctl using the detected PGDATA."
    "$PG_CTL_BIN" -D "$PGDATA" -m fast -w restart || die "pg_ctl restart failed."
}

reload_local_postgresql() {
    rl_result=$(psql_call "SELECT pg_reload_conf()" 2>/dev/null | tr -d '[:space:]') || die "pg_reload_conf() failed."
    [ "$rl_result" = "t" ] || [ "$rl_result" = "true" ] || die "PostgreSQL did not accept configuration reload."
}

wait_receiver_absent() {
    wr_i=0
    wr_limit=$(bounded_wait_seconds 30) || return 1
    while [ "$wr_i" -lt "$wr_limit" ]; do
        wr_count=$(psql_call "SELECT count(*) FROM pg_stat_wal_receiver" 2>/dev/null | tr -d '[:space:]') || wr_count=1
        [ "$wr_count" -eq 0 ] && return 0
        sleep 1
        wr_i=$((wr_i + 1))
    done
    return 1
}

wait_receiver_streaming() {
    wrs_i=0
    wrs_limit=$(bounded_wait_seconds "$1") || return 1
    while [ "$wrs_i" -lt "$wrs_limit" ]; do
        wrs_status=$(psql_call "SELECT status FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | tr -d '[:space:]') || wrs_status=""
        [ "$wrs_status" = "streaming" ] && return 0
        sleep 1
        wrs_i=$((wrs_i + 1))
    done
    return 1
}

stop_wal_receiver_connection() {
    require_standby
    check_wal_retention_risk "WAL Receiver Disable"
    prepare_state_dir
    primary_conninfo_source_guard || die "WAL Receiver connection control cannot safely change command-line replication settings."
    swr_current=$(psql_call "SHOW primary_conninfo" 2>/dev/null | sed -n '1p') || die "Could not read primary_conninfo."
    [ -n "$swr_current" ] || die "primary_conninfo is already empty. Streaming connection is not configured."

    section "WAL Receiver — Disable Streaming" "Standby와 Upstream 사이의 WAL Receiver streaming 연결을 중지합니다."
    say "  WAL Replay pause와는 다르며, WAL archive가 구성되어 있으면 archive recovery는 계속될 수 있습니다."
    if [ "$PG_MAJOR" -eq 12 ]; then
        say "  PostgreSQL 12에서는 primary_conninfo 변경 적용에 서버 restart가 필요합니다."
    else
        say "  PostgreSQL 13~18에서는 primary_conninfo 변경을 configuration reload로 적용합니다."
    fi
    if ! choose_yes_no "Stop WAL Receiver streaming connection 실행" "no"; then
        info "Cancelled."
        return 0
    fi

    create_primary_conninfo_restore_state
    swr_state=$(receiver_state_sql_file)
    if ! psql_call "ALTER SYSTEM SET primary_conninfo = ''" >/dev/null; then
        rm -f "$swr_state"
        die "ALTER SYSTEM SET primary_conninfo failed."
    fi

    if [ "$PG_MAJOR" -eq 12 ]; then
        restart_local_postgresql
    else
        reload_local_postgresql
    fi

    if wait_receiver_absent; then
        info "WAL Receiver streaming connection is stopped."
        info "Restore state saved with mode 600: $swr_state"
    else
        warn "WAL Receiver is still visible after the configuration change. Check pg_stat_wal_receiver and PostgreSQL logs."
    fi
}

resume_wal_receiver_connection() {
    require_standby
    prepare_state_dir
    rwr_state=$(receiver_state_sql_file)
    [ -f "$rwr_state" ] || die "No saved primary_conninfo restore state was found: $rwr_state"

    section "WAL Receiver — Restore Streaming" "중지 전에 사용하던 primary_conninfo를 복원합니다."
    if [ "$PG_MAJOR" -eq 12 ]; then
        say "  PostgreSQL 12에서는 복원 적용에 서버 restart가 필요합니다."
    else
        say "  PostgreSQL 13~18에서는 configuration reload 후 WAL Receiver 재연결을 확인합니다."
    fi

    psql_call_file "$rwr_state" >/dev/null || die "Could not restore primary_conninfo. State file retained: $rwr_state"
    if [ "$PG_MAJOR" -eq 12 ]; then
        restart_local_postgresql
    else
        reload_local_postgresql
    fi

    rwr_timeout=$(psql_call "SELECT CASE WHEN setting::bigint = 0 THEN 60 ELSE GREATEST(15, LEAST(300, (setting::bigint / 1000) * 2)) END FROM pg_settings WHERE name='wal_receiver_timeout'" 2>/dev/null | tr -d '[:space:]') || rwr_timeout=60
    rm -f "$rwr_state"

    if wait_receiver_streaming "$rwr_timeout"; then
        info "WAL Receiver streaming connection is restored and status=streaming."
    else
        warn "primary_conninfo was restored, but WAL Receiver did not reach status=streaming within ${rwr_timeout}s."
        warn "Check upstream availability, pg_hba.conf, authentication, network, replication slot, and PostgreSQL logs."
    fi
}

detect_external_ha_manager() {
    # Detection only. Nothing is stopped or modified.
    deh_out=$(ps -eo comm=,args= 2>/dev/null | awk '
        { line=tolower($0) }
        line ~ /patroni|repmgrd|pg_autoctl|pacemakerd|corosync/ { print }
    ' | sed '/pg-role-switch/d' | sed -n '1,10p')
    if [ -n "$deh_out" ]; then
        warn "Possible external HA/failover manager process detected:"
        printf '%s\n' "$deh_out" | sed 's/^/  /' >&2
        warn "This script does not stop or pause external HA managers. Put the environment into its documented maintenance/pause mode before Switchover."
        return 0
    fi
    return 1
}

primary_standby_list_file() {
    psl_file=$1
    psql_call "SELECT pid::text || E'\\t' || application_name || E'\\t' || COALESCE(host(client_addr),'local') || E'\\t' || usename || E'\\t' || state || E'\\t' || sync_state || E'\\t' || COALESCE(replay_lsn::text,'') || E'\\t' || COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint::text,'') || E'\\t' || COALESCE((SELECT slot_name FROM pg_replication_slots s WHERE s.active_pid=r.pid LIMIT 1),'') FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical') ORDER BY application_name, client_addr NULLS FIRST, pid" > "$psl_file"
}

select_primary_candidate() {
    spc_file=$1
    primary_standby_list_file "$spc_file" || die "Could not query pg_stat_replication."
    spc_count=$(wc -l < "$spc_file" | tr -d '[:space:]')
    [ "$spc_count" -gt 0 ] || die "No directly connected standby exists in pg_stat_replication. Planned Switchover cannot continue."
    DIRECT_STANDBY_COUNT=$spc_count

    say ""
    say "Standby Server Selection"
    say "  pg_stat_replication에 직접 연결된 Standby 중 새 Primary 후보를 선택합니다."
    awk -F '\t' '{printf "  %d. application_name=%s | client_addr=%s | usename=%s | state=%s | sync_state=%s | replay_lsn=%s | pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn)=%s | slot_name=%s | pid=%s\n", NR,$2,$3,$4,$5,$6,$7,$8,$9,$1}' "$spc_file"
    while :; do
        spc_idx=$(ask "Standby Server number" "") || usage_die "Input cancelled."
        case "$spc_idx" in
            *[!0-9]*|'') say "Enter a number." ;;
            *)
                spc_line=$(sed -n "${spc_idx}p" "$spc_file")
                if [ -n "$spc_line" ]; then
                    CANDIDATE_PID=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $1}')
                    CANDIDATE_APP=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $2}')
                    CANDIDATE_CLIENT=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $3}')
                    CANDIDATE_REPL_USER=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $4}')
                    CANDIDATE_STATE=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $5}')
                    CANDIDATE_SYNC_STATE=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $6}')
                    CANDIDATE_REPLAY_LSN=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $7}')
                    CANDIDATE_REPLAY_BYTES=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $8}')
                    CANDIDATE_SLOT=$(printf '%s\n' "$spc_line" | awk -F '\t' '{print $9}')
                    return 0
                fi
                say "Invalid selection."
                ;;
        esac
    done
}

remote_build_command() {
    rbc_cmd="sh -s --"
    shift_count=0
    for rbc_arg in "$@"; do
        rbc_q=$(shell_quote "$rbc_arg")
        rbc_cmd="$rbc_cmd $rbc_q"
        shift_count=$((shift_count + 1))
    done
    printf '%s\n' "$rbc_cmd"
}

remote_invoke() {
    invoke_on_transport "$REMOTE_TRANSPORT" "$REMOTE_TARGET" "$@"
}

acquire_candidate_lock() {
    REMOTE_LOCK_TOKEN="$SYSTEM_IDENTIFIER-$$-$(date +%s 2>/dev/null || echo unknown)"
    # Assume ownership before the call so a lost SSH response still triggers a
    # best-effort release. Failed release leaves the candidate locked closed.
    REMOTE_LOCK_HELD=1
    if ! remote_invoke --remote-lock-acquire "$REMOTE_PGDATA" "$REMOTE_LOCK_TOKEN" >/dev/null; then
        die "Could not acquire the selected Standby instance lock. Inspect its data_directory before retrying."
    fi
    record_check "PASSED" "Candidate Instance Lock" "exclusive lock acquired on selected Standby data_directory"
}

invoke_on_transport() {
    iot_transport=$1
    iot_target=$2
    shift 2
    ri_cmd=$(remote_build_command "$@")
    if [ "$iot_transport" = "local" ]; then
        # shellcheck disable=SC2086
        sh "$SCRIPT_PATH" "$@"
    else
        command -v ssh >/dev/null 2>&1 || return 127
        ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$iot_target" "$ri_cmd" < "$SCRIPT_PATH"
    fi
}

choose_remote_transport() {
    crt_default=$CANDIDATE_CLIENT
    [ "$crt_default" = "local" ] && crt_default="local"
    say ""
    say "Remote Execution Transport"
    say "  Standby에서 PostgreSQL 명령을 실행할 방법을 선택합니다. 외부 HA 도구는 사용하지 않습니다."
    say "  'local'은 동일 OS 서버의 다른 PostgreSQL 인스턴스인 경우 사용합니다."
    crt_host=$(ask "SSH host or 'local'" "$crt_default") || usage_die "Input cancelled."
    if [ "$crt_host" = "local" ]; then
        REMOTE_TRANSPORT="local"
        REMOTE_SSH_HOST="local"
        REMOTE_SSH_USER=$(id -un 2>/dev/null || echo "")
        REMOTE_TARGET="local"
        return 0
    fi

    command -v ssh >/dev/null 2>&1 || remote_die "ssh client is not available. Nothing will be installed automatically. Install/enable an approved OS SSH client separately or use local transport."
    REMOTE_TRANSPORT="ssh"
    REMOTE_SSH_HOST=$crt_host
    crt_user_default=$(id -un 2>/dev/null || echo "")
    say "SSH OS User"
    say "  원격 Standby Server에 SSH로 접속할 운영체제 계정을 입력합니다."
    say "  PostgreSQL role이 아니라 Linux/Unix OS 계정입니다."
    say "  이 계정은 대상 서버에서 해당 PostgreSQL 인스턴스를 관리할 수 있어야 합니다."
    REMOTE_SSH_USER=$(ask "SSH OS user" "$crt_user_default") || usage_die "Input cancelled."
    [ -n "$REMOTE_SSH_USER" ] || usage_die "SSH OS user is required."
    REMOTE_TARGET="$REMOTE_SSH_USER@$REMOTE_SSH_HOST"

    mktemp_safe || remote_die "Could not create temporary file for SSH validation."
    crt_ssh_err=$SAFE_TMP
    crt_check_cmd=$(remote_build_command --help)
    if ! ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_TARGET" "$crt_check_cmd" < "$SCRIPT_PATH" >/dev/null 2>"$crt_ssh_err"; then
        [ ! -s "$crt_ssh_err" ] || cat "$crt_ssh_err" >&2
        remote_die "Non-interactive SSH check failed for $REMOTE_TARGET. This script does not configure SSH credentials."
    fi
    if grep -Ei 'command not found|syntax error|unexpected EOF|not found$' "$crt_ssh_err" >/dev/null 2>&1; then
        cat "$crt_ssh_err" >&2
        remote_die "Non-interactive SSH check failed for $REMOTE_TARGET. This script does not configure SSH credentials."
    fi
}

remote_select_instance() {
    mktemp_safe || die "Could not create temporary file."
    rsi_tmp=$SAFE_TMP
    remote_invoke --remote-list "$SYSTEM_IDENTIFIER" > "$rsi_tmp" 2>/dev/null || remote_die "Could not discover PostgreSQL instances on the Standby Server host."
    rsi_count=$(awk -F '\t' '$1=="INSTANCE" {c++} END{print c+0}' "$rsi_tmp")
    [ "$rsi_count" -gt 0 ] || {
        warn "Remote discovery output:"
        sed 's/^/  /' "$rsi_tmp" >&2
        die "No matching running Standby with system_identifier=$SYSTEM_IDENTIFIER was discovered on the candidate host."
    }

    say ""
    say "Standby Server Instance Selection"
    say "  Standby Server에서 동일 system_identifier를 가진 인스턴스를 선택합니다."
    awk -F '\t' '$1=="INSTANCE" {i++; printf "  %d. data_directory=%s | port=%s | server_version_num=%s | Current Role=%s | Current Role (Streaming Replication)=%s | SELECT count(*) FROM pg_stat_replication=%s | pg_stat_wal_receiver.status=%s | sender_host=%s | sender_port=%s | pg_last_wal_replay_lsn()=%s | slot_name=%s\n", i,$2,$3,$4,$5,$17,$18,$12,$7,$8,$9,$20}' "$rsi_tmp"

    if [ "$rsi_count" -eq 1 ]; then
        rsi_pick=1
    else
        rsi_pick=$(ask "Remote instance number" "") || usage_die "Input cancelled."
    fi
    case "$rsi_pick" in *[!0-9]*|'') usage_die "Invalid remote instance selection." ;; esac
    rsi_line=$(awk -F '\t' -v n="$rsi_pick" '$1=="INSTANCE" {i++; if(i==n) print}' "$rsi_tmp")
    [ -n "$rsi_line" ] || usage_die "Invalid remote instance selection."

    REMOTE_PGDATA=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $2}')
    REMOTE_PORT=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $3}')
    REMOTE_VERSION_NUM=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $4}')
    REMOTE_MAJOR=$((REMOTE_VERSION_NUM / 10000))
    REMOTE_ROLE=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $5}')
    REMOTE_SYSTEM_IDENTIFIER=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $6}')
    REMOTE_SENDER_HOST=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $7}')
    REMOTE_SENDER_PORT=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $8}')
    REMOTE_REPLAY_LSN=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $9}')
    REMOTE_PAUSE_STATE=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $10}')
    REMOTE_DELAY_MS=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $11}')
    REMOTE_RECEIVER_STATUS=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $12}')
    REMOTE_SYNC_STANDBY_NAMES=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $13}')
    REMOTE_DEFAULT_TX_READ_ONLY=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $14}')
    REMOTE_ARCHIVE_MODE=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $15}')
    REMOTE_ARCHIVE_READY=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $16}')
    REMOTE_TOPOLOGY_ROLE=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $17}')
    REMOTE_DOWNSTREAM_COUNT=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $18}')
    REMOTE_RECOVERY_TARGET_TIMELINE=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $19}')
    REMOTE_RECEIVER_SLOT=$(printf '%s\n' "$rsi_line" | awk -F '\t' '{print $20}')

    rsi_preflight_output=$(remote_invoke --remote-preflight "$REMOTE_PGDATA" 2>/dev/null) || classify_remote_failure "$?" "Remote PostgreSQL execution environment validation failed for data_directory=$REMOTE_PGDATA."
    rsi_preflight_line=$(printf '%s\n' "$rsi_preflight_output" | awk -F '\t' '$1=="PREFLIGHT" {print; exit}')
    rsi_preflight=$(printf '%s\n' "$rsi_preflight_line" | awk -F '\t' '{print $2}')
    [ "$rsi_preflight" = "ready" ] || remote_die "Remote PostgreSQL execution environment validation failed for data_directory=$REMOTE_PGDATA."
    rsi_available_bytes=$(printf '%s\n' "$rsi_preflight_line" | awk -F '\t' '{print $6}')
    rsi_required_bytes=$(printf '%s\n' "$rsi_preflight_line" | awk -F '\t' '{print $7}')
    if [ -n "$rsi_available_bytes" ] && [ -n "$rsi_required_bytes" ] && [ "$rsi_available_bytes" -lt "$rsi_required_bytes" ] 2>/dev/null; then
        warn "Standby Server pg_wal filesystem space is less than twice max_wal_size: available_bytes=$rsi_available_bytes, required_bytes=$rsi_required_bytes"
        record_check "MANUAL CHECK" "Standby Server pg_wal Free Space" "Review WAL generation rate and outage duration."
    else
        record_check "MANUAL CHECK" "Standby Server pg_wal Free Space" "available_bytes=${rsi_available_bytes:-unknown}; twice_max_wal_size=${rsi_required_bytes:-unknown} is a screening threshold, not a safe retention limit"
    fi
    record_check "PASSED" "Remote Execution Environment" "data_directory=$REMOTE_PGDATA, port=$REMOTE_PORT"
}

verify_upstream_connection() {
    vuc_result=$(remote_invoke --remote-verify-upstream "$REMOTE_PGDATA" "$SYSTEM_IDENTIFIER" "$PGPORT" 2>/dev/null) || classify_remote_failure "$?" "Could not verify the selected Standby Server's upstream Primary Server. Check primary_conninfo, credentials, pg_hba.conf and network."
    [ "$vuc_result" = "UPSTREAM_VERIFIED" ] || die "The upstream server reached through primary_conninfo does not match the selected Primary Server system_identifier and port."
    record_check "PASSED" "primary_conninfo Upstream" "live SQL connection verified system_identifier=$SYSTEM_IDENTIFIER and port=$PGPORT"
}

candidate_downstream_check() {
    mktemp_safe || die "Could not create a temporary topology file."
    cdc_tmp=$SAFE_TMP
    remote_invoke --remote-downstreams "$REMOTE_PGDATA" > "$cdc_tmp" 2>/dev/null || classify_remote_failure "$?" "Could not inspect the selected Standby Server's downstream Standby Servers."
    cdc_count=$(awk -F '\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$cdc_tmp")
    [ "$cdc_count" -eq "${REMOTE_DOWNSTREAM_COUNT:-0}" ] 2>/dev/null || die "The selected Standby Server's pg_stat_replication result changed during precheck. Run discovery again."
    [ "$cdc_count" -gt 0 ] || return 0

    say ""
    say "Downstream Standby Check"
    say "  선택한 Standby Server는 다른 Standby Server의 Upstream Server인 Cascading Standby입니다."
    awk -F '\t' '$1=="DOWNSTREAM" {printf "  %d. application_name=%s | client_addr=%s | state=%s | sync_state=%s | replay_lsn=%s | slot_name=%s\n", ++i,$2,$3,$4,$5,$6,$7}' "$cdc_tmp"
    cdc_bad=$(awk -F '\t' '$1=="DOWNSTREAM" && $4!="streaming" {c++} END {print c+0}' "$cdc_tmp")
    [ "$cdc_bad" -eq 0 ] || die "$cdc_bad downstream pg_stat_replication row(s) of the selected Standby Server are not state=streaming."

    say ""
    say "Cascading Replication Check"
    say "  선택한 Standby Server의 pg_stat_replication 행은 모두 state=streaming입니다."
    say "  Timeline 전환 후에도 Downstream이 새 timeline을 따라가려면 각 Downstream의 recovery_target_timeline=latest가 필요합니다."
    say "  각 Downstream Standby Server에서 system_identifier, sender_port, pg_stat_wal_receiver.status를 기준으로 인스턴스를 자동 탐지합니다."

    cdc_i=1
    while [ "$cdc_i" -le "$cdc_count" ]; do
        cdc_line=$(awk -F '\t' -v n="$cdc_i" '$1=="DOWNSTREAM" {i++; if(i==n) print}' "$cdc_tmp")
        cdc_app=$(printf '%s\n' "$cdc_line" | awk -F '\t' '{print $2}')
        cdc_client=$(printf '%s\n' "$cdc_line" | awk -F '\t' '{print $3}')
        cdc_slot=$(printf '%s\n' "$cdc_line" | awk -F '\t' '{print $7}')
        say ""
        printf '  Downstream Standby Server %s/%s: application_name=%s, client_addr=%s\n' "$cdc_i" "$cdc_count" "$cdc_app" "$cdc_client"
        cdc_host=$(ask "Downstream SSH host or 'local'" "$cdc_client") || usage_die "Input cancelled."
        [ -n "$cdc_host" ] || usage_die "Downstream host is required."
        if [ "$cdc_host" = "local" ]; then
            cdc_transport="local"
            cdc_target="local"
        else
            command -v ssh >/dev/null 2>&1 || die "ssh client is not available for Downstream verification."
            cdc_user=$(ask "Downstream SSH user" "$(id -un 2>/dev/null || echo '')") || usage_die "Input cancelled."
            [ -n "$cdc_user" ] || usage_die "Downstream SSH user is required."
            cdc_transport="ssh"
            cdc_target="$cdc_user@$cdc_host"
            mktemp_safe || remote_die "Could not create temporary file for Downstream SSH validation."
            cdc_ssh_err=$SAFE_TMP
            cdc_check_cmd=$(remote_build_command --help)
            if ! ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$cdc_target" "$cdc_check_cmd" < "$SCRIPT_PATH" >/dev/null 2>"$cdc_ssh_err"; then
                [ ! -s "$cdc_ssh_err" ] || cat "$cdc_ssh_err" >&2
                remote_die "Non-interactive SSH check failed for $cdc_target."
            fi
            if grep -Ei 'command not found|syntax error|unexpected EOF|not found$' "$cdc_ssh_err" >/dev/null 2>&1; then
                cat "$cdc_ssh_err" >&2
                remote_die "Non-interactive SSH check failed for $cdc_target."
            fi
        fi

        mktemp_safe || die "Could not create a Downstream instance file."
        cdc_instances=$SAFE_TMP
        invoke_on_transport "$cdc_transport" "$cdc_target" --remote-list-downstream "$SYSTEM_IDENTIFIER" "$REMOTE_PORT" "$cdc_slot" > "$cdc_instances" 2>/dev/null || classify_remote_failure "$?" "Could not discover matching PostgreSQL instances on Downstream host $cdc_host."
        cdc_matches=$(awk -F '\t' '$1=="DOWNSTREAM_INSTANCE" {c++} END {print c+0}' "$cdc_instances")
        [ "$cdc_matches" -gt 0 ] || die "No running Standby on $cdc_host matches system_identifier=$SYSTEM_IDENTIFIER, upstream_port=$REMOTE_PORT and WAL Receiver status=streaming."
        awk -F '\t' '$1=="DOWNSTREAM_INSTANCE" {i++; printf "    %d. PGDATA=%s | port=%s | version=%s | sender_host=%s | sender_port=%s | status=%s | recovery_target_timeline=%s | slot_name=%s\n",i,$2,$3,$4,$6,$7,$8,$9,$10}' "$cdc_instances"
        if [ "$cdc_matches" -eq 1 ]; then
            cdc_pick=1
        else
            cdc_pick=$(ask "Downstream instance number for $cdc_app" "") || usage_die "Input cancelled."
        fi
        case "$cdc_pick" in ''|*[!0-9]*) usage_die "Invalid Downstream instance selection." ;; esac
        cdc_selected=$(awk -F '\t' -v n="$cdc_pick" '$1=="DOWNSTREAM_INSTANCE" {i++; if(i==n) print}' "$cdc_instances")
        [ -n "$cdc_selected" ] || usage_die "Invalid Downstream instance selection."
        cdc_timeline=$(printf '%s\n' "$cdc_selected" | awk -F '\t' '{print $9}')
        [ "$cdc_timeline" = "latest" ] || die "Downstream $cdc_app recovery_target_timeline=$cdc_timeline. Cascading Switchover requires latest."
        info "Downstream verified: $cdc_app, recovery_target_timeline=latest"
        cdc_i=$((cdc_i + 1))
    done
}

unselected_standby_check() {
    mktemp_safe || die "Could not create a temporary pg_stat_replication file."
    usc_file=$SAFE_TMP
    primary_standby_list_file "$usc_file" || die "Could not refresh pg_stat_replication."
    usc_count=$(awk -F '\t' -v pid="$CANDIDATE_PID" '$1 != pid {c++} END {print c+0}' "$usc_file")
    UNSELECTED_STANDBY_COUNT=$usc_count
    [ "$usc_count" -gt 0 ] || return 0

    say ""
    say "Unselected Standby Servers"
    say "  역할 전환 후 former Primary Server가 Cascading Standby가 되면 선택하지 않은 Standby Server가 동일 서버를 계속 Upstream Server로 사용할 수 있는지 확인합니다."
    say "  각 Standby Server의 system_identifier, sender_port, slot_name, pg_stat_wal_receiver.status 및 recovery_target_timeline을 확인합니다."

    usc_i=1
    while [ "$usc_i" -le "$usc_count" ]; do
        usc_line=$(awk -F '\t' -v pid="$CANDIDATE_PID" -v n="$usc_i" '$1 != pid {i++; if(i==n) print}' "$usc_file")
        usc_app=$(printf '%s\n' "$usc_line" | awk -F '\t' '{print $2}')
        usc_client=$(printf '%s\n' "$usc_line" | awk -F '\t' '{print $3}')
        usc_slot=$(printf '%s\n' "$usc_line" | awk -F '\t' '{print $9}')
        printf '  Standby Server %s/%s: application_name=%s, client_addr=%s, slot_name=%s\n' "$usc_i" "$usc_count" "$usc_app" "$usc_client" "${usc_slot:-}"
        usc_host=$(ask "Standby Server SSH host or 'local'" "$usc_client") || usage_die "Input cancelled."
        [ -n "$usc_host" ] || usage_die "Standby Server host is required."
        if [ "$usc_host" = "local" ]; then
            usc_transport="local"
            usc_target="local"
        else
            command -v ssh >/dev/null 2>&1 || die "ssh client is not available for Standby Server verification."
            usc_user=$(ask "Standby Server SSH user" "$(id -un 2>/dev/null || echo '')") || usage_die "Input cancelled."
            [ -n "$usc_user" ] || usage_die "Standby Server SSH user is required."
            usc_transport="ssh"
            usc_target="$usc_user@$usc_host"
            mktemp_safe || remote_die "Could not create temporary file for Standby Server SSH validation."
            usc_ssh_err=$SAFE_TMP
            usc_check_cmd=$(remote_build_command --help)
            if ! ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$usc_target" "$usc_check_cmd" < "$SCRIPT_PATH" >/dev/null 2>"$usc_ssh_err"; then
                [ ! -s "$usc_ssh_err" ] || cat "$usc_ssh_err" >&2
                remote_die "Non-interactive SSH check failed for $usc_target."
            fi
            if grep -Ei 'command not found|syntax error|unexpected EOF|not found$' "$usc_ssh_err" >/dev/null 2>&1; then
                cat "$usc_ssh_err" >&2
                remote_die "Non-interactive SSH check failed for $usc_target."
            fi
        fi

        mktemp_safe || die "Could not create a Standby Server instance file."
        usc_instances=$SAFE_TMP
        invoke_on_transport "$usc_transport" "$usc_target" --remote-list-downstream "$SYSTEM_IDENTIFIER" "$PGPORT" "$usc_slot" > "$usc_instances" 2>/dev/null || classify_remote_failure "$?" "Could not discover the matching PostgreSQL instance on $usc_host."
        usc_matches=$(awk -F '\t' '$1=="DOWNSTREAM_INSTANCE" {c++} END {print c+0}' "$usc_instances")
        [ "$usc_matches" -gt 0 ] || die "No running Standby Server on $usc_host matches system_identifier=$SYSTEM_IDENTIFIER, sender_port=$PGPORT, slot_name=${usc_slot:-<empty>} and pg_stat_wal_receiver.status=streaming."
        awk -F '\t' '$1=="DOWNSTREAM_INSTANCE" {i++; printf "    %d. data_directory=%s | port=%s | server_version_num=%s | sender_host=%s | sender_port=%s | pg_stat_wal_receiver.status=%s | recovery_target_timeline=%s | slot_name=%s\n",i,$2,$3,$4,$6,$7,$8,$9,$10}' "$usc_instances"
        if [ "$usc_matches" -eq 1 ]; then
            usc_pick=1
        else
            usc_pick=$(ask "Standby Server instance number for $usc_app" "") || usage_die "Input cancelled."
        fi
        case "$usc_pick" in ''|*[!0-9]*) usage_die "Invalid Standby Server instance selection." ;; esac
        usc_selected=$(awk -F '\t' -v n="$usc_pick" '$1=="DOWNSTREAM_INSTANCE" {i++; if(i==n) print}' "$usc_instances")
        [ -n "$usc_selected" ] || usage_die "Invalid Standby Server instance selection."
        usc_timeline=$(printf '%s\n' "$usc_selected" | awk -F '\t' '{print $9}')
        [ "$usc_timeline" = "latest" ] || die "Standby Server $usc_app has recovery_target_timeline=$usc_timeline; latest is required to follow the new timeline."
        usc_i=$((usc_i + 1))
    done
}

wait_unselected_standbys() {
    wus_expected=$1
    wus_timeout=$(bounded_wait_seconds "$2") || return 1
    wus_i=0
    while [ "$wus_i" -lt "$wus_timeout" ]; do
        wus_counts=$(psql_call "SELECT count(*)::text || E'\\t' || count(*) FILTER (WHERE state='streaming')::text FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | sed -n '1p') || wus_counts=""
        wus_total=$(printf '%s\n' "$wus_counts" | awk -F '\t' '{print $1}')
        wus_streaming=$(printf '%s\n' "$wus_counts" | awk -F '\t' '{print $2}')
        if [ "$wus_total" = "$wus_expected" ] && [ "$wus_streaming" = "$wus_expected" ]; then
            return 0
        fi
        sleep 1
        wus_i=$((wus_i + 1))
    done
    return 1
}

switchover_shutdown_mode() {
    say ""
    say "Shutdown Mode (pg_ctl stop -m)"
    say "  Planned Switchover에서 현재 Primary를 정상 종료할 방식을 선택합니다."
    say ""
    say "  1. Fast Shutdown (-m fast)"
    say "     새 연결을 차단하고 기존 세션을 종료하며 활성 트랜잭션을 rollback한 뒤 정상 checkpoint로 종료합니다."
    say ""
    say "  2. Smart Shutdown (-m smart)"
    say "     기존 클라이언트가 스스로 연결을 종료할 때까지 기다린 후 종료합니다. 작업 시간이 길어질 수 있습니다."
    while :; do
        ssm=$(ask "Shutdown mode number" "1") || usage_die "Input cancelled."
        case "$ssm" in
            1) SWITCH_SHUTDOWN_MODE="fast"; return 0 ;;
            2) SWITCH_SHUTDOWN_MODE="smart"; return 0 ;;
            *) say "Enter 1 or 2." ;;
        esac
    done
}

preconfigure_former_primary() {
    pfp_conninfo=$1
    pfp_slot=$2
    pfp_restore_file="$STATE_DIR/$STATE_KEY.switchover.config.restore.sql"
    [ ! -e "$pfp_restore_file" ] || die "Existing Switchover restore state exists: $pfp_restore_file"

    # Save exact effective values as SQL so secrets do not need shell parsing.
    psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_conninfo = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_conninfo;' END FROM pg_settings WHERE name='primary_conninfo'" > "$pfp_restore_file" || die "Could not save primary_conninfo rollback state."
    psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_slot_name = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_slot_name;' END FROM pg_settings WHERE name='primary_slot_name'" >> "$pfp_restore_file" || die "Could not save primary_slot_name rollback state."
    psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET recovery_target_timeline = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET recovery_target_timeline;' END FROM pg_settings WHERE name='recovery_target_timeline'" >> "$pfp_restore_file" || die "Could not save recovery_target_timeline rollback state."
    chmod 600 "$pfp_restore_file" || die "Could not protect Switchover restore state: $pfp_restore_file"

    # Set the rollback guard before the first non-transactional ALTER SYSTEM.
    # This also covers a failure after only part of the settings were staged.
    SWITCHOVER_CONFIG_CHANGED=1
    SWITCHOVER_RESTORE_FILE=$pfp_restore_file

    psql_call_var pc "$pfp_conninfo" "ALTER SYSTEM SET primary_conninfo = :'pc'" >/dev/null || die "Could not stage reverse primary_conninfo."
    if [ -n "$pfp_slot" ]; then
        psql_call_var ps "$pfp_slot" "ALTER SYSTEM SET primary_slot_name = :'ps'" >/dev/null || die "Could not stage reverse primary_slot_name."
    else
        psql_call "ALTER SYSTEM SET primary_slot_name = ''" >/dev/null || die "Could not stage an empty primary_slot_name override."
    fi
    psql_call "ALTER SYSTEM SET recovery_target_timeline = 'latest'" >/dev/null || die "Could not stage recovery_target_timeline=latest."
}

rollback_preconfigured_primary() {
    if [ "$SWITCHOVER_CONFIG_CHANGED" -eq 1 ] && [ -f "${SWITCHOVER_RESTORE_FILE:-}" ]; then
        if psql_call_file "$SWITCHOVER_RESTORE_FILE" >/dev/null 2>&1; then
            if rm -f "$SWITCHOVER_RESTORE_FILE"; then
                SWITCHOVER_CONFIG_CHANGED=0
            else
                warn "Settings were restored but could not remove the restore state: $SWITCHOVER_RESTORE_FILE"
            fi
        else
            warn "Could not roll back staged settings automatically. Restore state retained: $SWITCHOVER_RESTORE_FILE"
        fi
    fi
}

logical_replication_slot_precheck() {
    lrsp_count=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'" 2>/dev/null | tr -d '[:space:]') || die "Could not inspect logical replication slots."
    case "$lrsp_count" in ''|*[!0-9]*) die "Unexpected logical replication slot count: $lrsp_count" ;; esac
    [ "$lrsp_count" -gt 0 ] || return 0

    say ""
    say "pg_replication_slots — Logical Replication Slots"
    say "  현재 Primary에 logical replication slot이 존재합니다. 역할 전환 후 logical replication 연속성에 영향을 줄 수 있습니다."
    psql_call "SELECT slot_name || ' | database=' || COALESCE(database,'') || ' | active=' || active FROM pg_replication_slots WHERE slot_type='logical' ORDER BY slot_name" 2>/dev/null | sed 's/^/  /'

    if [ "$PG_MAJOR" -lt 17 ]; then
        warn "PostgreSQL $PG_MAJOR does not provide PostgreSQL 17+ logical failover slot synchronization."
        warn "These logical slots will not automatically appear on the promoted physical Standby."
        if ! confirm_word "CONTINUE" "Continue only if logical replication consumers/slots will be handled separately during this planned role switch."; then
            die "Switchover cancelled because logical replication slot continuity is not prepared."
        fi
        return 0
    fi

    lrsp_nonfailover=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical' AND (NOT failover OR temporary)" 2>/dev/null | tr -d '[:space:]') || die "Could not inspect logical failover slot properties."
    if [ "$lrsp_nonfailover" -gt 0 ]; then
        warn "$lrsp_nonfailover logical slot(s) are not persistent failover-enabled slots. They are not guaranteed to be usable on the promoted Standby."
        if ! confirm_word "CONTINUE" "Continue only if non-failover logical slots will be handled separately."; then
            die "Switchover cancelled because non-failover logical slots exist."
        fi
    fi

    mktemp_safe || die "Could not create temporary file for logical failover slot validation."
    lrsp_tmp=$SAFE_TMP
    psql_call "SELECT slot_name FROM pg_replication_slots WHERE slot_type='logical' AND failover AND NOT temporary ORDER BY slot_name" > "$lrsp_tmp" || die "Could not list logical failover slots."
    while IFS= read -r lrsp_slot; do
        [ -n "$lrsp_slot" ] || continue
        lrsp_result=$(remote_invoke --remote-check-logical-slot "$REMOTE_PGDATA" "$lrsp_slot" 2>/dev/null | awk -F '\t' '$1=="LOGICAL_SLOT" {print $3; exit}')
        if [ "$lrsp_result" != "ready" ]; then
            die "Logical failover slot '$lrsp_slot' is not synchronized and failover-ready on the selected Standby Server."
        fi
        info "Logical failover slot ready on the selected Standby Server: $lrsp_slot"
    done < "$lrsp_tmp"
}

current_primary_slot_wal_status_guard() {
    if [ "$PG_MAJOR" -lt 13 ]; then
        record_check "MANUAL CHECK" "Physical Slot WAL Retention" "PostgreSQL $PG_MAJOR does not expose pg_replication_slots.wal_status; inspect physical slot WAL retention before Switchover"
        return 0
    fi
    cps_risky=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='physical' AND wal_status IN ('unreserved','lost')" 2>/dev/null | tr -d '[:space:]') || die "Could not inspect physical replication slot wal_status on the current Primary Server."
    case "$cps_risky" in ''|*[!0-9]*) die "Unexpected physical replication slot risk count: $cps_risky" ;; esac
    if [ "$cps_risky" -gt 0 ]; then
        psql_call "SELECT slot_name || ' | wal_status=' || wal_status || ' | safe_wal_size=' || COALESCE(safe_wal_size::text,'NULL') FROM pg_replication_slots WHERE slot_type='physical' AND wal_status IN ('unreserved','lost') ORDER BY slot_name" 2>/dev/null | sed 's/^/  /' >&2 || true
        die "$cps_risky physical replication slot(s) on the current Primary Server have wal_status=unreserved/lost. Switchover is blocked until required WAL retention is safe."
    fi
    record_check "PASSED" "Physical Slot WAL Retention" "current Primary physical slots have no wal_status=unreserved/lost"
}

candidate_switchover_safety_precheck() {
    css_reserve_slots=${1:-0}
    css_reverse_slot=${2:-}
    case "$REMOTE_DOWNSTREAM_COUNT" in ''|*[!0-9]*) die "The selected Standby Server returned an invalid downstream count: ${REMOTE_DOWNSTREAM_COUNT:-<empty>}" ;; esac
    css_line=$(remote_invoke --remote-switchover-safety "$REMOTE_PGDATA" 2>/dev/null | awk -F '\t' '$1=="SWITCHOVER_SAFETY" {print; exit}') || classify_remote_failure "$?" "Could not inspect the selected Standby Server's replication settings and replication slot state."
    [ -n "$css_line" ] || die "Selected Standby Server returned no replication settings and replication slot state."
    REMOTE_MAX_WAL_SENDERS=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $2}')
    REMOTE_MAX_REPLICATION_SLOTS=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $3}')
    REMOTE_REPLICATION_SLOT_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $4}')
    REMOTE_RISKY_PHYSICAL_SLOT_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $5}')
    REMOTE_ARCHIVED_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $6}')
    REMOTE_ARCHIVER_FAILED_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $7}')
    REMOTE_LAST_ARCHIVED_TIME=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $8}')
    REMOTE_LAST_FAILED_TIME=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $9}')
    REMOTE_ARCHIVER_UNRESOLVED=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $10}')
    REMOTE_WAL_LEVEL=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $11}')
    REMOTE_LOGICAL_SLOT_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $12}')

    for css_n in "$REMOTE_MAX_WAL_SENDERS" "$REMOTE_MAX_REPLICATION_SLOTS" "$REMOTE_REPLICATION_SLOT_COUNT" "$REMOTE_LOGICAL_SLOT_COUNT"; do
        case "$css_n" in ''|*[!0-9]*) die "Selected Standby Server returned an invalid PostgreSQL replication setting or slot count: ${css_n:-<empty>}" ;; esac
    done
    case "$REMOTE_WAL_LEVEL" in minimal|replica|logical) ;; *) die "Selected Standby Server returned an invalid wal_level: ${REMOTE_WAL_LEVEL:-<empty>}" ;; esac

    css_effective_reserve=$css_reserve_slots
    if [ "$css_reserve_slots" -eq 1 ] 2>/dev/null && [ -n "$css_reverse_slot" ]; then
        css_slot_state=$(remote_invoke --remote-slot-state "$REMOTE_PGDATA" "$css_reverse_slot" 2>/dev/null | awk -F '\t' '$1=="SLOT_STATE" {print $3; exit}') || classify_remote_failure "$?" "Could not inspect reverse replication slot state on the selected Standby Server."
        case "$css_slot_state" in
            absent) css_effective_reserve=1 ;;
            physical) css_effective_reserve=0 ;;
            conflict) die "Replication slot '$css_reverse_slot' already exists on the selected Standby Server but slot_type is not physical. Choose another slot_name." ;;
            *) die "Unexpected replication slot state for $css_reverse_slot: ${css_slot_state:-<empty>}" ;;
        esac
    fi

    css_required_slots=$((REMOTE_REPLICATION_SLOT_COUNT + css_effective_reserve))
    [ "$REMOTE_MAX_REPLICATION_SLOTS" -ge "$css_required_slots" ] || die "Selected Standby Server max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS is lower than required replication slots=$css_required_slots (existing=$REMOTE_REPLICATION_SLOT_COUNT, additional physical replication slot=$css_effective_reserve)."

    css_local_logical_slots=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'" 2>/dev/null | tr -d '[:space:]') || die "Could not inspect logical replication slots on the current Primary Server."
    case "$css_local_logical_slots" in ''|*[!0-9]*) die "Unexpected logical replication slot count on the current Primary Server: ${css_local_logical_slots:-<empty>}" ;; esac

    css_physical_replicas=$((REMOTE_DOWNSTREAM_COUNT + 1))
    if [ "$css_local_logical_slots" -gt 0 ] || [ "$REMOTE_LOGICAL_SLOT_COUNT" -gt 0 ]; then
        [ "$REMOTE_WAL_LEVEL" = "logical" ] || die "Logical replication slots exist, but the selected Standby Server wal_level=$REMOTE_WAL_LEVEL. A promoted server that publishes logical replication requires wal_level=logical."
        css_required_senders=$((REMOTE_MAX_REPLICATION_SLOTS + css_physical_replicas))
        css_sender_basis="max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS + physical replicas=$css_physical_replicas"
    else
        css_required_senders=$css_physical_replicas
        css_sender_basis="physical replicas=$css_physical_replicas"
    fi

    [ "$REMOTE_MAX_WAL_SENDERS" -ge "$css_required_senders" ] || die "Selected Standby Server max_wal_senders=$REMOTE_MAX_WAL_SENDERS is lower than required=$css_required_senders ($css_sender_basis)."
    if [ "$REMOTE_MAX_WAL_SENDERS" -eq "$css_required_senders" ]; then
        warn "Selected Standby Server max_wal_senders=$REMOTE_MAX_WAL_SENDERS has no capacity above the calculated maximum expected replication clients ($css_sender_basis). PostgreSQL documentation recommends setting max_wal_senders slightly higher so abruptly disconnected streaming clients can reconnect before the old WAL sender times out."
        record_check "WARNING" "max_wal_senders" "configured=$REMOTE_MAX_WAL_SENDERS; calculated expected maximum=$css_required_senders; no additional connection capacity"
    else
        record_check "PASSED" "max_wal_senders" "configured=$REMOTE_MAX_WAL_SENDERS; calculated expected maximum=$css_required_senders; basis=$css_sender_basis"
    fi

    if [ "$REMOTE_MAX_REPLICATION_SLOTS" -eq "$css_required_slots" ] && { [ "$css_local_logical_slots" -gt 0 ] || [ "$REMOTE_LOGICAL_SLOT_COUNT" -gt 0 ]; }; then
        warn "Selected Standby Server max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS has no capacity above currently accounted replication slots. PostgreSQL logical replication documentation requires reserve for table synchronization."
        record_check "WARNING" "max_replication_slots" "configured=$REMOTE_MAX_REPLICATION_SLOTS; accounted=$css_required_slots; no reserve for table synchronization"
    else
        record_check "PASSED" "max_replication_slots" "configured=$REMOTE_MAX_REPLICATION_SLOTS; accounted=$css_required_slots; existing=$REMOTE_REPLICATION_SLOT_COUNT; additional physical replication slot=$css_effective_reserve"
    fi

    if [ "$REMOTE_RISKY_PHYSICAL_SLOT_COUNT" = "-1" ]; then
        record_check "MANUAL CHECK" "pg_replication_slots.wal_status" "PostgreSQL $REMOTE_MAJOR does not expose pg_replication_slots.wal_status"
    else
        case "$REMOTE_RISKY_PHYSICAL_SLOT_COUNT" in ''|*[!0-9]*) die "Selected Standby Server returned an invalid pg_replication_slots.wal_status risk count: $REMOTE_RISKY_PHYSICAL_SLOT_COUNT" ;; esac
        [ "$REMOTE_RISKY_PHYSICAL_SLOT_COUNT" -eq 0 ] || die "Selected Standby Server has $REMOTE_RISKY_PHYSICAL_SLOT_COUNT physical replication slot(s) with pg_replication_slots.wal_status=unreserved/lost. Planned Switchover is blocked."
        record_check "PASSED" "pg_replication_slots.wal_status" "no physical replication slot has wal_status=unreserved/lost"
    fi
}
local_archiver_health_guard() {
    [ "$LOCAL_ARCHIVE_MODE" != "off" ] || return 0
    lah_line=$(psql_call "SELECT archived_count::text || E'\\t' || failed_count::text || E'\\t' || COALESCE(last_archived_time::text,'') || E'\\t' || COALESCE(last_failed_time::text,'') || E'\\t' || CASE WHEN failed_count > 0 AND last_failed_time IS NOT NULL AND (last_archived_time IS NULL OR last_failed_time > last_archived_time) THEN '1' ELSE '0' END FROM pg_stat_archiver" 2>/dev/null | sed -n '1p') || die "Could not inspect pg_stat_archiver on the current Primary Server."
    lah_failed=$(printf '%s\n' "$lah_line" | awk -F '\t' '{print $2}')
    lah_last_ok=$(printf '%s\n' "$lah_line" | awk -F '\t' '{print $3}')
    lah_last_fail=$(printf '%s\n' "$lah_line" | awk -F '\t' '{print $4}')
    lah_unresolved=$(printf '%s\n' "$lah_line" | awk -F '\t' '{print $5}')
    [ "$lah_unresolved" = "0" ] || die "Current Primary Server pg_stat_archiver shows the most recent archival attempt failed after the most recent successful archive: last_archived_time=${lah_last_ok:-<none>}, last_failed_time=${lah_last_fail:-<none>}, failed_count=${lah_failed:-unknown}."
    record_check "PASSED" "Current Primary pg_stat_archiver" "no unresolved latest archival failure; failed_count=${lah_failed:-unknown}"
}

candidate_archiver_health_guard() {
    [ "$LOCAL_ARCHIVE_MODE" != "off" ] || return 0
    if [ "$REMOTE_ARCHIVE_MODE" = "always" ]; then
        [ "${REMOTE_ARCHIVER_UNRESOLVED:-1}" = "0" ] || die "Selected Standby Server archive_mode=always and pg_stat_archiver shows a newer failure than success: last_archived_time=${REMOTE_LAST_ARCHIVED_TIME:-<none>}, last_failed_time=${REMOTE_LAST_FAILED_TIME:-<none>}."
        record_check "PASSED" "Candidate pg_stat_archiver" "archive_mode=always; no unresolved latest archival failure"
    else
        record_check "MANUAL CHECK" "Candidate pg_stat_archiver" "archive_mode=$REMOTE_ARCHIVE_MODE; standby-time pg_stat_archiver cannot prove post-promotion archive destination success"
    fi
}

external_restart_fencing_guard() {
    say ""
    say "External HA / Service Restart / Fencing"
    say "  이 스크립트의 data_directory 잠금은 외부 HA manager, service manager, watchdog 또는 별도 운영 자동화가 former Primary를 다시 Primary로 기동하는 것을 차단하지 못합니다."
    if ! choose_yes_no "Former Primary의 자동 재기동/자동 failover가 중지되어 있고 fencing 또는 동등한 split-brain 방지 절차가 준비되어 있습니까" "no"; then
        cancel_operation "Switchover cancelled because external restart/failover/fencing control was not confirmed."
    fi
    record_check "MANUAL CHECK" "External HA / Fencing" "operator confirmed automatic restart/failover is controlled and split-brain prevention is in place"
}

manual_recovery_branch_notice() {
    warn "Automatic pg_rewind or automatic base-backup reprovisioning is intentionally NOT performed."
    warn "If the former Primary was started writable after promotion, or timeline history diverged, keep it stopped and do not attempt normal standby restart."
    warn "Compare timeline history and control state first. Use pg_rewind only when its prerequisites and required WAL are satisfied; otherwise reinitialize from a new base backup."
    record_check "MANUAL CHECK" "Former Primary Recovery Branch" "timeline divergence requires operator-directed pg_rewind or new base backup; no automatic destructive recovery is performed"
}
startup_options_guard() {
    sog_cmdline_count=$(psql_call "SELECT count(*) FROM pg_settings WHERE source='command line' AND name <> 'data_directory'" 2>/dev/null | tr -d '[:space:]') || sog_cmdline_count=0
    if [ -z "$POSTMASTER_OPTIONS" ] && [ "$sog_cmdline_count" -gt 0 ] 2>/dev/null; then
        error "Server startup uses command-line configuration, but startup options could not be preserved from postmaster.opts."
        error "Set PG_START_OPTIONS at runtime to the approved postgres startup options, or use the server's normal service procedure."
        return 1
    fi
    if [ -z "$POSTMASTER_OPTIONS" ] && [ "$CONFIG_FILE" != "$PGDATA/postgresql.conf" ]; then
        error "config_file is outside PGDATA and reusable startup options were not discovered."
        error "Set PG_START_OPTIONS at runtime or use the server's approved service start method."
        return 1
    fi
    return 0
}

show_client_session_check() {
    active_sessions=$(psql_call "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type='client backend'" 2>/dev/null | tr -d '[:space:]') || active_sessions="unknown"
    active_tx=$(psql_call "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND xact_start IS NOT NULL" 2>/dev/null | tr -d '[:space:]') || active_tx="unknown"
    say ""
    say "pg_stat_activity"
    say "  현재 Primary Server 종료 시 영향받을 client backend와 진행 중인 transaction을 확인합니다."
    kv "backend_type=client backend" "$active_sessions"
    kv "xact_start IS NOT NULL" "$active_tx"
}

revalidate_switchover_topology() {
    rst_selected_identity=$(psql_call_var pid "$CANDIDATE_PID" "SELECT application_name || E'\\t' || COALESCE(host(client_addr),'local') || E'\\t' || usename || E'\\t' || state || E'\\t' || COALESCE((SELECT slot_name FROM pg_replication_slots s WHERE s.active_pid=r.pid LIMIT 1),'') FROM pg_stat_replication r WHERE pid=:'pid'::integer LIMIT 1" 2>/dev/null | sed -n '1p') || rst_selected_identity=""
    rst_expected_identity=$(printf '%s\t%s\t%s\tstreaming\t%s' "$CANDIDATE_APP" "$CANDIDATE_CLIENT" "$CANDIDATE_REPL_USER" "${CANDIDATE_SLOT:-}")
    if [ "$rst_selected_identity" != "$rst_expected_identity" ]; then
        rollback_preconfigured_primary
        die "Selected pg_stat_replication row changed or left state=streaming."
    fi

    rst_direct_counts=$(psql_call "SELECT count(*)::text || E'\\t' || count(*) FILTER (WHERE state='streaming')::text FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | sed -n '1p') || rst_direct_counts=""
    rst_direct_total=$(printf '%s\n' "$rst_direct_counts" | awk -F '\t' '{print $1}')
    rst_direct_streaming=$(printf '%s\n' "$rst_direct_counts" | awk -F '\t' '{print $2}')
    if [ "$rst_direct_total" != "$DIRECT_STANDBY_COUNT" ] || [ "$rst_direct_streaming" != "$DIRECT_STANDBY_COUNT" ]; then
        rollback_preconfigured_primary
        die "pg_stat_replication changed: total=${rst_direct_total:-unknown}, state=streaming=${rst_direct_streaming:-unknown}, expected=$DIRECT_STANDBY_COUNT."
    fi

    if ! remote_invoke --remote-validate-candidate "$REMOTE_PGDATA" "$SYSTEM_IDENTIFIER" "$PGPORT" "${CANDIDATE_SLOT:-}" "$REMOTE_DOWNSTREAM_COUNT" >/dev/null; then
        rollback_preconfigured_primary
        die "The selected Standby Server's Current Role, system_identifier, pg_stat_wal_receiver, recovery settings, or pg_stat_replication result changed."
    fi
    verify_upstream_connection
    record_check "PASSED" "pg_stat_wal_receiver" "sender_port=$PGPORT, status=streaming"
}

stop_current_primary() {
    [ -n "$PG_CTL_BIN" ] && [ -x "$PG_CTL_BIN" ] || die "Matching pg_ctl was not found. Set PG_BINDIR at runtime if required."
    info "Stopping current Primary with pg_ctl -m $SWITCH_SHUTDOWN_MODE."
    if [ "$SWITCH_SHUTDOWN_MODE" = "smart" ]; then
        "$PG_CTL_BIN" -D "$PGDATA" -m smart -w stop || return 1
    else
        "$PG_CTL_BIN" -D "$PGDATA" -m fast -w stop || return 1
    fi
    SWITCHOVER_PRIMARY_STOPPED=1
    CURRENT_PHASE="after_primary_stop"
    return 0
}

stopped_primary_checkpoint_lsn() {
    [ -n "$PG_CONTROLDATA_BIN" ] && [ -x "$PG_CONTROLDATA_BIN" ] || return 1
    LC_ALL=C "$PG_CONTROLDATA_BIN" "$PGDATA" 2>/dev/null | awk -F: '/Latest checkpoint location/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
}

stopped_primary_state() {
    [ -n "$PG_CONTROLDATA_BIN" ] && [ -x "$PG_CONTROLDATA_BIN" ] || return 1
    LC_ALL=C "$PG_CONTROLDATA_BIN" "$PGDATA" 2>/dev/null | awk -F: '/Database cluster state/ {sub(/^[ \t]+/, "", $2); print $2; exit}'
}

create_standby_signal() {
    [ -d "$PGDATA" ] || return 1
    : > "$PGDATA/standby.signal" || return 1
}

start_former_primary_as_standby() {
    [ -n "$PG_CTL_BIN" ] && [ -x "$PG_CTL_BIN" ] || return 1
    [ -f "$PGDATA/standby.signal" ] || return 1
    # postmaster.opts is an official pg_ctl state file containing the options from
    # the previous server start. Reuse those options so external config_file,
    # custom port/socket settings, and other startup options are not silently lost.
    if [ -n "$POSTMASTER_OPTIONS" ]; then
        "$PG_CTL_BIN" -D "$PGDATA" -o "$POSTMASTER_OPTIONS" -w start
    else
        "$PG_CTL_BIN" -D "$PGDATA" -w start
    fi
}

show_switchover_execution_plan() {
    section "Planned Switchover Execution Plan" "최종 승인 후 실제로 수행할 PostgreSQL/OS 작업입니다. primary_conninfo의 민감정보는 표시하지 않습니다."
    printf '  Current Primary data_directory : %s\n' "$PGDATA"
    printf '  Current Primary port           : %s\n' "$PGPORT"
    printf '  Selected Standby host          : %s\n' "$CANDIDATE_CLIENT"
    printf '  Selected Standby data_directory: %s\n' "$REMOTE_PGDATA"
    printf '  Selected Standby port          : %s\n' "$REMOTE_PORT"
    say ""
    say "  1. Stage reverse replication settings on current Primary"
    say "     ALTER SYSTEM SET primary_conninfo = '<redacted>';"
    if [ -n "${REVERSE_SLOT:-}" ]; then
        printf "     ALTER SYSTEM SET primary_slot_name = '%s';\n" "$REVERSE_SLOT"
    else
        say "     ALTER SYSTEM SET primary_slot_name = '';"
    fi
    say "     ALTER SYSTEM SET recovery_target_timeline = 'latest';"
    say ""
    say "  2. Revalidate pg_stat_replication / pg_stat_wal_receiver immediately before shutdown"
    say ""
    say "  3. Stop current Primary cleanly"
    printf '     %s -D %s -m %s -w stop\n' "$PG_CTL_BIN" "$PGDATA" "$SWITCH_SHUTDOWN_MODE"
    say ""
    say "  4. Read former Primary final checkpoint and clean shutdown state"
    printf '     %s %s\n' "$PG_CONTROLDATA_BIN" "$PGDATA"
    say ""
    say "  5. Wait until selected Standby replays through the final checkpoint"
    say "     SELECT pg_last_wal_replay_lsn();"
    say ""
    say "  6. Promote selected Standby"
    say "     SELECT pg_promote();"
    say ""
    say "  7. Create/verify reverse physical replication slot when configured"
    [ -z "${REVERSE_SLOT:-}" ] || printf "     SELECT pg_create_physical_replication_slot('%s', true);\n" "$REVERSE_SLOT"
    say ""
    say "  8. Create standby.signal on former Primary"
    printf '     create %s/standby.signal\n' "$PGDATA"
    say ""
    say "  9. Start former Primary as Standby"
    printf '     %s -D %s -w start\n' "$PG_CTL_BIN" "$PGDATA"
    say ""
    say " 10. Verify pg_is_in_recovery(), pg_stat_wal_receiver.status and pg_stat_replication"
}

planned_switchover() {
    CURRENT_PHASE="precheck"
    require_primary
    validate_supported_version
    check_local_execution_account
    if [ "$CHECK_ONLY" -eq 0 ]; then
        prepare_state_dir
    fi
    primary_conninfo_source_guard || die "Switchover cannot safely stage reverse replication settings while command-line overrides are active."
    check_local_write_permissions
    check_pg_wal_free_space

    section "Planned Switchover" "정상 동작 중인 Primary와 선택한 Standby의 역할을 계획적으로 전환합니다."
    say "  Primary가 이미 장애 상태이면 이 기능을 사용하지 않습니다. Automatic Failover는 수행하지 않습니다."

    if detect_external_ha_manager; then
        if ! choose_yes_no "External HA manager가 적절한 maintenance/pause 상태임을 확인했습니까" "no"; then
            die "Switchover aborted because an external HA/failover manager may interfere."
        fi
    fi

    mktemp_safe || die "Could not create temporary file."
    psf=$SAFE_TMP
    select_primary_candidate "$psf"
    [ "$CANDIDATE_STATE" = "streaming" ] || die "Selected candidate state is '$CANDIDATE_STATE', not 'streaming'."
    [ -n "$CANDIDATE_REPLAY_LSN" ] || die "Selected candidate has no replay_lsn."

    choose_remote_transport
    remote_select_instance
    acquire_candidate_lock
    current_primary_slot_wal_status_guard
    candidate_switchover_safety_precheck 0
    external_restart_fencing_guard

    [ "$REMOTE_ROLE" = "standby" ] || die "Selected remote instance is not a Standby."
    [ "$REMOTE_SYSTEM_IDENTIFIER" = "$SYSTEM_IDENTIFIER" ] || die "system_identifier mismatch. The selected Standby Server belongs to a different PostgreSQL cluster."
    [ "$REMOTE_MAJOR" -eq "$PG_MAJOR" ] || die "Physical replication major version mismatch: local=$PG_MAJOR remote=$REMOTE_MAJOR"
    [ "$REMOTE_RECEIVER_STATUS" = "streaming" ] || die "The selected Standby Server's pg_stat_wal_receiver.status is '$REMOTE_RECEIVER_STATUS', not 'streaming'. Planned Switchover requires an active WAL Receiver."
    [ "${REMOTE_RECEIVER_SLOT:-}" = "${CANDIDATE_SLOT:-}" ] || die "slot_name mismatch on the selected Standby Server: pg_stat_replication=${CANDIDATE_SLOT:-<empty>}, pg_stat_wal_receiver=${REMOTE_RECEIVER_SLOT:-<empty>}."
    [ "$REMOTE_RECOVERY_TARGET_TIMELINE" = "latest" ] || die "The selected Standby Server has recovery_target_timeline=$REMOTE_RECOVERY_TARGET_TIMELINE. Planned Switchover requires recovery_target_timeline=latest."
    case "$REMOTE_DOWNSTREAM_COUNT" in ''|*[!0-9]*) die "The selected Standby Server's SELECT count(*) FROM pg_stat_replication result is invalid: $REMOTE_DOWNSTREAM_COUNT" ;; esac
    if [ "$REMOTE_DOWNSTREAM_COUNT" -gt 0 ]; then
        [ "$REMOTE_TOPOLOGY_ROLE" = "Cascading Standby" ] || die "The selected Standby Server's Current Role and SELECT count(*) FROM pg_stat_replication result do not match."
        candidate_downstream_check
    fi
    [ -n "$REMOTE_SENDER_PORT" ] || die "The selected Standby Server's pg_stat_wal_receiver.sender_port is empty."
    [ "$REMOTE_SENDER_PORT" = "$PGPORT" ] || die "The selected Standby Server's pg_stat_wal_receiver.sender_port=$REMOTE_SENDER_PORT does not match the current Primary Server's port=$PGPORT."
    case "$REMOTE_PAUSE_STATE" in
        "not paused"|f|false|"") ;;
        *) die "WAL replay is paused or pause was requested on the selected Standby Server: $REMOTE_PAUSE_STATE" ;;
    esac
    case "$REMOTE_DELAY_MS" in
        ''|*[!0-9]*) ;;
        *) [ "$REMOTE_DELAY_MS" -eq 0 ] || die "The selected Standby Server's recovery_min_apply_delay is non-zero (${REMOTE_DELAY_MS}ms). A delayed Standby Server is not accepted for Planned Switchover by default." ;;
    esac

    LOCAL_ARCHIVE_MODE=$(psql_call "SHOW archive_mode" 2>/dev/null | tr -d '[:space:]') || LOCAL_ARCHIVE_MODE=""
    LOCAL_ARCHIVE_READY=$(archive_mechanism_configured 2>/dev/null || echo 0)
    local_archiver_health_guard
    candidate_archiver_health_guard
    if [ "$LOCAL_ARCHIVE_MODE" != "off" ] && [ "$REMOTE_ARCHIVE_MODE" = "off" ]; then
        die "The current Primary Server has archive_mode=$LOCAL_ARCHIVE_MODE, but the selected Standby Server has archive_mode=off. Promotion would disable continuous archiving on the new Primary Server."
    fi
    if [ "$LOCAL_ARCHIVE_MODE" != "off" ] && [ "$LOCAL_ARCHIVE_READY" = "1" ] && [ "$REMOTE_ARCHIVE_READY" != "1" ]; then
        die "The current Primary Server has an active continuous archiving mechanism, but the selected Standby Server does not have archive_command/archive_library configured for its PostgreSQL version."
    fi
    if [ "$LOCAL_ARCHIVE_MODE" != "off" ]; then
        say ""
        say "archive_mode / archive_command / archive_library"
        say "  현재 Primary Server에서 continuous archiving을 사용 중입니다. 선택한 Standby Server가 Primary Server가 된 뒤 사용할 archive destination과 권한은 외부 저장소까지 자동 검증할 수 없습니다."
        printf '  Current Primary archive_mode : %s\n' "$LOCAL_ARCHIVE_MODE"
        printf '  Standby Server archive_mode  : %s\n' "$REMOTE_ARCHIVE_MODE"
        if ! choose_yes_no "The selected Standby Server's continuous archiving destination/credentials have been verified" "no"; then
            die "The selected Standby Server's continuous archiving readiness was not confirmed."
        fi
        if ! choose_yes_no "Shared archive destination의 동일 WAL 파일 중복 처리 정책(멱등 저장/동일 내용 재전송)이 안전함을 확인했습니까" "no"; then
            die "Continuous archiving duplicate-WAL handling was not confirmed."
        fi
        record_check "MANUAL CHECK" "Archive Duplicate WAL Handling" "operator confirmed duplicate WAL handling is safe"
        record_check "MANUAL CHECK" "Continuous Archiving" "destination and credentials confirmed by operator"
    fi
    case "$REMOTE_DEFAULT_TX_READ_ONLY" in
        on|true|t)
            warn "The selected Standby Server has default_transaction_read_only=$REMOTE_DEFAULT_TX_READ_ONLY. After promotion, new sessions may default to read-only transactions."
            if ! choose_yes_no "The selected Standby Server's read-only default is intentional and has been accounted for" "no"; then
                die "The selected Standby Server's Primary Server readiness check failed."
            fi
            ;;
    esac

    if [ "$REMOTE_VERSION_NUM" -ne "$PG_VERSION_NUM" ]; then
        warn "Primary and candidate are the same major version but different server_version_num values. PostgreSQL documentation recommends keeping primary/standby at the same release level as much as possible."
        if ! choose_yes_no "Continue with the minor-version difference" "no"; then
            die "Switchover cancelled."
        fi
    fi

    if [ "${DIRECT_STANDBY_COUNT:-1}" -gt 1 ]; then
        unselected_standby_check
    else
        UNSELECTED_STANDBY_COUNT=0
    fi

    LOCAL_SYNC_STANDBY_NAMES=$(psql_call "SHOW synchronous_standby_names" 2>/dev/null | sed -n '1p') || LOCAL_SYNC_STANDBY_NAMES=""
    if [ -n "$LOCAL_SYNC_STANDBY_NAMES" ] || [ -n "$REMOTE_SYNC_STANDBY_NAMES" ]; then
        say ""
        say "synchronous_standby_names"
        say "  동기 복제를 위해 commit이 기다릴 Standby 이름/집합을 지정하는 PostgreSQL 설정입니다. Primary 역할이 바뀌면 새 Primary의 설정이 적용됩니다."
        printf '  Primary Server  : %s
' "${LOCAL_SYNC_STANDBY_NAMES:-<empty>}"
        printf '  Standby Server  : %s
' "${REMOTE_SYNC_STANDBY_NAMES:-<empty>}"
        if [ "$LOCAL_SYNC_STANDBY_NAMES" != "$REMOTE_SYNC_STANDBY_NAMES" ]; then
            warn "The current Primary Server and selected Standby Server have different synchronous_standby_names values. Promotion can change synchronous commit behavior."
        fi
        if [ -n "$REMOTE_SYNC_STANDBY_NAMES" ]; then
            warn "After promotion, the selected Standby Server's synchronous_standby_names becomes the new Primary Server policy. Required synchronous Standby Servers that are not connected can delay or block commits that request synchronous durability."
        fi
        if ! choose_yes_no "The selected Standby Server's synchronous replication policy has been reviewed" "no"; then
            die "Switchover cancelled because synchronous replication policy was not confirmed."
        fi
    fi

    logical_replication_slot_precheck

    section "Pre-Switchover Check" "역할, system identifier, version, streaming 및 replay 사전검사 결과입니다."
    printf '  Primary Server data_directory: %s\n' "$PGDATA"
    printf '  Primary Server port          : %s\n' "$PGPORT"
    printf '  application_name       : %s\n' "$CANDIDATE_APP"
    printf '  client_addr            : %s\n' "$CANDIDATE_CLIENT"
    printf '  pg_stat_replication.pid: %s\n' "$CANDIDATE_PID"
    printf '  data_directory         : %s\n' "$REMOTE_PGDATA"
    printf '  port                   : %s\n' "$REMOTE_PORT"
    printf '  sync_state             : %s\n' "$CANDIDATE_SYNC_STATE"
    printf '  pg_stat_wal_receiver.status: %s\n' "$REMOTE_RECEIVER_STATUS"
    printf '  pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn): %s\n' "$CANDIDATE_REPLAY_BYTES"
    printf '  slot_name              : %s\n' "${CANDIDATE_SLOT:-none}"
    kv "$(pause_state_name)" "$REMOTE_PAUSE_STATE"
    printf '  archive_mode           : %s\n' "$REMOTE_ARCHIVE_MODE"
    printf '  synchronous_standby_names: %s\n' "${REMOTE_SYNC_STANDBY_NAMES:-<empty>}"
    printf '  Current Role            : %s\n' "${REMOTE_TOPOLOGY_ROLE:-Standby}"
    kv "SELECT count(*) FROM pg_stat_replication" "${REMOTE_DOWNSTREAM_COUNT:-0}"

    if [ "$CHECK_ONLY" -eq 1 ]; then
        startup_options_guard || die "Check-only validation failed: the former Primary Server startup configuration cannot be preserved."
        record_check "PASSED" "Startup Options" "matching pg_ctl and reusable startup options"
        show_client_session_check
        revalidate_switchover_topology
        record_check "PASSED" "Replication Topology" "local and remote state revalidated"
        record_check "MANUAL CHECK" "Reverse Streaming Authentication" "pg_hba.conf, passfile or certificate must be confirmed before Planned Switchover"
        section "Check-only Result" "설정 변경, PostgreSQL 종료 및 promotion 없이 Planned Switchover 사전검사를 완료했습니다."
        kv "Current Role" "$(current_topology_role 2>/dev/null || echo unknown)"
        kv "Selected Standby Server" "$CANDIDATE_APP"
        kv "pg_stat_wal_receiver.status" "$REMOTE_RECEIVER_STATUS"
        kv "recovery_target_timeline" "$REMOTE_RECOVERY_TARGET_TIMELINE"
        kv "SELECT count(*) FROM pg_stat_replication" "$DIRECT_STANDBY_COUNT"
        kv "Standby Server: SELECT count(*) FROM pg_stat_replication" "${REMOTE_DOWNSTREAM_COUNT:-0}"
        info "Check-only validation completed. No PostgreSQL setting or server state was changed."
        CURRENT_PHASE="completed"
        return 0
    fi

    switchover_shutdown_mode

    # Determine endpoint that the former Primary will use to follow the new Primary.
    np_host_default=$CANDIDATE_CLIENT
    [ "$np_host_default" = "local" ] && np_host_default=""
    say "New Primary Database Host"
    say "  역할 전환 후 former Primary Server의 primary_conninfo에서 사용할 새 Primary Server 주소를 입력합니다."
    NEW_PRIMARY_DB_HOST=$(ask "Database host" "$np_host_default") || usage_die "Input cancelled."
    [ -n "$NEW_PRIMARY_DB_HOST" ] || usage_die "New Primary database host is required."

    OLD_PRIMARY_APP_DEFAULT=$(psql_call "SHOW cluster_name" 2>/dev/null | sed -n '1p')
    if [ -z "$OLD_PRIMARY_APP_DEFAULT" ]; then
        OLD_PRIMARY_APP_DEFAULT=$(hostname 2>/dev/null || echo old_primary)
    fi
    say "application_name"
    say "  역할 전환 후 former Primary가 새 Standby로 연결될 때 pg_stat_replication에 표시될 이름입니다."
    OLD_PRIMARY_APP=$(ask "Former Primary application_name" "$OLD_PRIMARY_APP_DEFAULT") || usage_die "Input cancelled."

    ci_host=$(conninfo_quote_value "$NEW_PRIMARY_DB_HOST")
    ci_user=$(conninfo_quote_value "$CANDIDATE_REPL_USER")
    ci_app=$(conninfo_quote_value "$OLD_PRIMARY_APP")
    REVERSE_CONNINFO="host='$ci_host' port='$REMOTE_PORT' user='$ci_user' application_name='$ci_app'"

    say ""
    say "Additional libpq Connection Parameters"
    say "  SSL, passfile 등 현재 운영 환경에서 필요한 libpq 연결 파라미터를 추가할 수 있습니다."
    say "  host, hostaddr, port, user, application_name은 자동 탐지/입력한 값을 사용하므로 여기서는 다시 지정하지 않습니다."
    say "  비밀번호를 직접 입력하지 말고 .pgpass/passfile 또는 기존 승인 인증 방식을 사용하십시오."
    extra_conninfo=$(ask "Additional connection parameters (empty = none)" "") || usage_die "Input cancelled."
    if [ -n "$extra_conninfo" ]; then
        if printf '%s\n' "$extra_conninfo" | grep -E '(^|[[:space:]])(host|hostaddr|port|user|application_name|password)[[:space:]]*=' >/dev/null 2>&1; then
            die "Additional parameters must not override host/hostaddr/port/user/application_name and must not contain password=. Use .pgpass/passfile for passwords."
        fi
        REVERSE_CONNINFO="$REVERSE_CONNINFO $extra_conninfo"
    fi

    say ""
    say "primary_conninfo (Reverse Streaming Connection)"
    say "  former Primary가 새 Primary를 따라가는 Standby가 될 때 사용할 연결 정보를 준비합니다."
    say "  비밀번호는 스크립트에 하드코딩하지 않습니다. 필요한 경우 .pgpass/passfile, 인증서 또는 기존 승인 인증 방식을 사용하십시오."
    printf '  Generated connection : host=%s port=%s user=%s application_name=%s\n' "$NEW_PRIMARY_DB_HOST" "$REMOTE_PORT" "$CANDIDATE_REPL_USER" "$OLD_PRIMARY_APP"

    if ! choose_yes_no "Reverse streaming 인증(pg_hba.conf/.pgpass/인증서 등)이 준비되어 있습니까" "no"; then
        die "Prepare reverse streaming authentication before Switchover."
    fi
    record_check "MANUAL CHECK" "Reverse Streaming Authentication" "confirmed by operator"

    REVERSE_SLOT=""
    if [ -n "$CANDIDATE_SLOT" ]; then
        say ""
        say "Physical Replication Slot"
        say "  현재 Standby가 physical replication slot을 사용하고 있습니다. 역할 전환 후 former Primary용 slot도 새 Primary에 준비하는 것을 권장합니다."
        slot_default=$(sanitize_identifier "${OLD_PRIMARY_APP}_slot")
        REVERSE_SLOT=$(ask "New Primary physical replication slot name (empty = do not use a slot)" "$slot_default") || usage_die "Input cancelled."
    else
        say ""
        say "Physical Replication Slot"
        say "  선택한 Standby는 현재 active physical replication slot과 연결되어 있지 않습니다. 역할 전환 후에도 기본적으로 slot을 새로 만들지 않습니다."
        if choose_yes_no "Create a physical replication slot for the former Primary" "no"; then
            slot_default=$(sanitize_identifier "${OLD_PRIMARY_APP}_slot")
            REVERSE_SLOT=$(ask "Physical replication slot name" "$slot_default") || usage_die "Input cancelled."
        fi
    fi

    if [ -n "${REVERSE_SLOT:-}" ]; then
        candidate_switchover_safety_precheck 1 "$REVERSE_SLOT"
    else
        candidate_switchover_safety_precheck 0
    fi
    startup_options_guard || die "Switchover cannot guarantee that the former Primary will restart with the same startup configuration."

    show_client_session_check
    show_switchover_execution_plan

    CURRENT_PHASE="before_primary_stop"
    if ! confirm_word "SWITCHOVER" "Pre-Switchover checks completed. Review the execution plan above. The next step stages reverse replication settings and shuts down the current Primary."; then
        die "Switchover cancelled before Primary shutdown."
    fi

    preconfigure_former_primary "$REVERSE_CONNINFO" "$REVERSE_SLOT"

    # Refresh both local and remote replication state immediately before shutdown.
    revalidate_switchover_topology

    # Planned switchover ordering is intentional: cleanly stop the current Primary,
    # verify the candidate replayed the final shutdown checkpoint, and only then
    # promote the candidate. This prevents promotion before the former Primary is
    # safely shut down and synchronized.
    if ! stop_current_primary; then
        # Primary is expected to still be available if pg_ctl reported a failed stop.
        if init_instance_from_pgdata "$PGDATA" 1 >/dev/null 2>&1; then
            rollback_preconfigured_primary
        else
            CURRENT_PHASE="after_primary_stop"
            warn "pg_ctl failed and the former Primary could not be reached. Restore state retained; verify its actual state before any restart or promotion."
        fi
        die "Could not stop current Primary cleanly."
    fi

    shutdown_state=$(stopped_primary_state 2>/dev/null || echo "")
    shutdown_lsn=$(stopped_primary_checkpoint_lsn 2>/dev/null || echo "")
    [ -n "$shutdown_lsn" ] || die "Could not read the final checkpoint location from pg_controldata. Former Primary remains stopped."
    case "$shutdown_state" in
        *"shut down"*) ;;
        *) die "Former Primary control state is not a clean shutdown state: $shutdown_state" ;;
    esac
    info "Former Primary clean shutdown confirmed. Final checkpoint location: $shutdown_lsn"

    remote_wait_default=$(remote_invoke --remote-timeout-default "$REMOTE_PGDATA" 2>/dev/null | awk -F '\t' '$1=="TIMEOUT" {print $2; exit}')
    case "$remote_wait_default" in ''|*[!0-9]*) remote_wait_default=120 ;; esac
    [ "$remote_wait_default" -le "$MAX_WAIT_SECONDS" ] 2>/dev/null || remote_wait_default=$MAX_WAIT_SECONDS
    say "WAL Replay Catch-up Wait"
    say "  선택한 Standby Server가 former Primary Server의 final checkpoint까지 replay할 최대 대기시간(초)을 입력합니다."
    catchup_wait=$(ask "Wait seconds" "$remote_wait_default") || usage_die "Input cancelled."
    validate_wait_seconds "$catchup_wait" || usage_die "Wait seconds must be an integer between 1 and $MAX_WAIT_SECONDS."

    if ! remote_invoke --remote-wait-lsn "$REMOTE_PGDATA" "$shutdown_lsn" "$catchup_wait" >/dev/null; then
        die "The selected Standby Server did not replay through the former Primary Server's final checkpoint. It was NOT promoted. The former Primary Server remains stopped."
    fi
    info "The selected Standby Server replayed through the former Primary Server's final checkpoint."

    promote_result=$(remote_invoke --remote-promote "$REMOTE_PGDATA" 2>/dev/null | awk -F '\t' '$1=="PROMOTED" {print $2; exit}')
    [ "$promote_result" = "primary" ] || die "Promotion of the selected Standby Server could not be verified. Do not restart the former Primary Server until roles are checked manually."
    SWITCHOVER_PROMOTED=1
    CURRENT_PHASE="after_promotion"
    info "Promotion verified: Current Role=Primary."

    if [ "$REMOTE_DOWNSTREAM_COUNT" -gt 0 ]; then
        downstream_wait=$remote_wait_default
        if ! remote_invoke --remote-wait-streaming-downstreams "$REMOTE_PGDATA" "$REMOTE_DOWNSTREAM_COUNT" "$downstream_wait" >/dev/null; then
            die "Not all existing downstream Standbys reached pg_stat_replication.state=streaming on the new Primary. The new Primary remains active and the former Primary remains stopped."
        fi
        info "All existing downstream Standbys are visible with pg_stat_replication.state=streaming on the new Primary."
    fi

    if [ -n "$REVERSE_SLOT" ]; then
        if ! remote_invoke --remote-create-slot "$REMOTE_PGDATA" "$REVERSE_SLOT" >/dev/null; then
            warn "Could not create physical replication slot '$REVERSE_SLOT' on the new Primary."
            warn "The former Primary will remain stopped because primary_slot_name was staged. Resolve the slot issue or remove primary_slot_name before starting it."
            die "Reverse physical replication slot preparation failed."
        fi
        info "Physical replication slot created/verified on new Primary: $REVERSE_SLOT"
    fi

    CURRENT_PHASE="rejoin_old_primary"
    create_standby_signal || die "Could not create $PGDATA/standby.signal. Former Primary remains stopped."
    info "standby.signal created on former Primary."

    if ! start_former_primary_as_standby; then
        die "Former Primary failed to start as Standby. New Primary is active; keep the former Primary from starting without standby.signal."
    fi

    # Re-establish local connection after restart.
    if ! init_instance_from_pgdata "$PGDATA" 1 || ! refresh_role; then
        error "Former Primary started but its Standby role could not be verified. Attempting an immediate fast shutdown."
        "$PG_CTL_BIN" -D "$PGDATA" -m immediate -w stop || warn "Emergency shutdown failed; isolate the former Primary immediately."
        die "Could not verify former Primary role after restart; it must remain stopped until its role is confirmed."
    fi
    if [ "$LOCAL_ROLE" != "standby" ]; then
        error "Former Primary unexpectedly started as Primary. Attempting an immediate fast shutdown to avoid split-brain."
        if "$PG_CTL_BIN" -D "$PGDATA" -m immediate -w stop; then
            die "Former Primary unexpectedly started as Primary and was stopped. Verify configuration before restarting."
        fi
        die "Former Primary unexpectedly started as Primary and the emergency stop failed. Isolate this host immediately to prevent split-brain."
    fi

    verify_timeout=$(psql_call "SELECT CASE WHEN setting::bigint = 0 THEN 60 ELSE GREATEST(15, LEAST(300, (setting::bigint / 1000) * 2)) END FROM pg_settings WHERE name='wal_receiver_timeout'" 2>/dev/null | tr -d '[:space:]') || verify_timeout=60
    if ! wait_receiver_streaming "$verify_timeout"; then
        die "Former Primary is in Standby mode, but pg_stat_wal_receiver.status did not reach streaming within ${verify_timeout}s. The new Primary remains active; inspect authentication, pg_hba.conf, network, slot, and PostgreSQL logs."
    fi

    if [ "${UNSELECTED_STANDBY_COUNT:-0}" -gt 0 ]; then
        if ! wait_unselected_standbys "$UNSELECTED_STANDBY_COUNT" "$verify_timeout"; then
            die "Not all unselected Standby Servers reached pg_stat_replication.state=streaming on the former Primary Server after it became a Cascading Standby. The new Primary Server remains active."
        fi
        info "All unselected Standby Servers are visible with pg_stat_replication.state=streaming on the former Primary Server."
    fi

    new_primary_sees_old=$(remote_invoke --remote-count-standby "$REMOTE_PGDATA" "$OLD_PRIMARY_APP" 2>/dev/null | awk -F '\t' '$1=="COUNT" {print $2; exit}')
    case "$new_primary_sees_old" in ''|*[!0-9]*) new_primary_sees_old=0 ;; esac
    [ "$new_primary_sees_old" -eq 1 ] || die "New Primary pg_stat_replication has $new_primary_sees_old streaming row(s) for application_name=$OLD_PRIMARY_APP; expected exactly 1."

    if [ -n "${SWITCHOVER_RESTORE_FILE:-}" ] && ! rm -f "$SWITCHOVER_RESTORE_FILE"; then
        warn "Switchover succeeded but the rollback state could not be removed: $SWITCHOVER_RESTORE_FILE"
    fi
    SWITCHOVER_CONFIG_CHANGED=0
    CURRENT_PHASE="completed"

    section "Post-Switchover Verification" "역할 전환 후 새 Primary와 새 Standby의 상태를 확인합니다."
    printf '  primary_conninfo host   : %s\n' "$NEW_PRIMARY_DB_HOST"
    printf '  primary_conninfo port   : %s\n' "$REMOTE_PORT"
    printf '  pg_is_in_recovery()     : %s\n' "$(psql_call "SELECT pg_is_in_recovery()" 2>/dev/null | sed -n '1p')"
    printf '  pg_stat_wal_receiver.status: %s\n' "$(psql_call "SELECT COALESCE(status,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')"
    printf '  SELECT count(*) FROM pg_stat_replication: %s (application_name=%s)\n' "$new_primary_sees_old" "$OLD_PRIMARY_APP"
    info "Planned Switchover workflow completed."
}

wait_local_replay_lsn() {
    wlr_target=$1
    wlr_timeout=$(bounded_wait_seconds "$2") || return 1
    wlr_i=0
    while [ "$wlr_i" -lt "$wlr_timeout" ]; do
        wlr_replay=$(psql_call "SELECT COALESCE(pg_last_wal_replay_lsn()::text,'')" 2>/dev/null | sed -n '1p') || wlr_replay=""
        if [ -n "$wlr_replay" ]; then
            wlr_ok=$(psql_call_var target "$wlr_target" "SELECT CASE WHEN pg_last_wal_replay_lsn() IS NOT NULL AND pg_last_wal_replay_lsn() >= :'target'::pg_lsn THEN 1 ELSE 0 END" 2>/dev/null | tr -d '[:space:]') || wlr_ok=0
            [ "$wlr_ok" = "1" ] && return 0
        fi
        sleep 1
        wlr_i=$((wlr_i + 1))
    done
    return 1
}

show_manual_failover_execution_plan() {
    section "Manual Failover Execution Plan" "이 작업은 장애 Primary를 자동 판정하지 않습니다. 운영자가 Primary 장애와 fencing을 확인한 뒤 현재 Standby를 승격합니다."
    printf '  Candidate data_directory      : %s\n' "$PGDATA"
    printf '  Candidate port                : %s\n' "$PGPORT"
    printf '  pg_stat_wal_receiver.status   : %s\n' "${FAILOVER_RECEIVER_STATUS:-<not connected>}"
    printf '  pg_last_wal_receive_lsn()     : %s\n' "${FAILOVER_RECEIVE_LSN:-<NULL>}"
    printf '  pg_last_wal_replay_lsn()      : %s\n' "${FAILOVER_REPLAY_LSN:-<NULL>}"
    printf '  receive/replay gap (derived)  : %s\n' "${FAILOVER_REPLAY_GAP:-unknown}"
    say ""
    say "  1. Revalidate that this server is still a Standby"
    say "     SELECT pg_is_in_recovery();"
    say ""
    say "  2. Revalidate pg_stat_wal_receiver.status is not streaming"
    say ""
    if [ -n "${FAILOVER_RECEIVE_LSN:-}" ]; then
        say "  3. Wait until pg_last_wal_replay_lsn() reaches the last WAL already received"
    else
        say "  3. No non-NULL pg_last_wal_receive_lsn() is available; no local receive target can be proven"
    fi
    say ""
    say "  4. Promote this Standby"
    say "     SELECT pg_promote();"
    say ""
    say "  5. Verify promotion"
    say "     SELECT pg_is_in_recovery();  -- must be false"
    say ""
    say "  6. Former Primary is NOT restarted or rewound automatically"
    say "     Rejoin requires operator-directed pg_rewind or a new base backup after topology/timeline review."
}

manual_failover() {
    CURRENT_PHASE="precheck"
    require_standby
    validate_supported_version
    check_local_execution_account
    check_pg_wal_free_space

    section "Manual Failover" "장애 Primary를 대신하여 현재 Standby를 운영자가 명시적으로 Primary로 승격합니다. Automatic Failover는 수행하지 않습니다."
    say "  PostgreSQL은 Primary 장애를 판정하거나 fencing을 수행하지 않습니다. Primary 장애와 split-brain 방지 상태를 운영자가 확인해야 합니다."

    FAILOVER_RECEIVER_STATUS=$(psql_call "SELECT COALESCE(status,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')
    FAILOVER_RECEIVE_LSN=$(psql_call "SELECT COALESCE(pg_last_wal_receive_lsn()::text,'')" 2>/dev/null | sed -n '1p')
    FAILOVER_REPLAY_LSN=$(psql_call "SELECT COALESCE(pg_last_wal_replay_lsn()::text,'')" 2>/dev/null | sed -n '1p')
    FAILOVER_REPLAY_GAP=$(psql_call "SELECT CASE WHEN pg_last_wal_receive_lsn() IS NULL OR pg_last_wal_replay_lsn() IS NULL THEN NULL ELSE pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) END" 2>/dev/null | sed -n '1p')
    FAILOVER_RECOVERY_TIMELINE=$(psql_call "SHOW recovery_target_timeline" 2>/dev/null | tr -d '[:space:]') || FAILOVER_RECOVERY_TIMELINE=""
    FAILOVER_PAUSE_STATE=$(pause_state 2>/dev/null || echo unknown)
    FAILOVER_DOWNSTREAM_COUNT=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || FAILOVER_DOWNSTREAM_COUNT=""

    [ "$FAILOVER_RECEIVER_STATUS" != "streaming" ] || die "Manual Failover is blocked because pg_stat_wal_receiver.status=streaming. The current Standby still has an active streaming connection to its Upstream Server."
    [ "$FAILOVER_RECOVERY_TIMELINE" = "latest" ] || die "Manual Failover requires recovery_target_timeline=latest; current value=$FAILOVER_RECOVERY_TIMELINE."
    case "$FAILOVER_PAUSE_STATE" in "not paused"|f|false|"") ;; *) die "Manual Failover is blocked because WAL replay is paused or pause was requested: $FAILOVER_PAUSE_STATE" ;; esac
    case "$FAILOVER_DOWNSTREAM_COUNT" in ''|*[!0-9]*) die "Could not determine SELECT count(*) FROM pg_stat_replication on the failover candidate." ;; esac

    record_check "PASSED" "Manual Failover Candidate" "Current Role=Standby; recovery_target_timeline=latest; WAL replay is not paused"
    if [ -n "$FAILOVER_RECEIVER_STATUS" ]; then
        record_check "WARNING" "pg_stat_wal_receiver.status" "status=$FAILOVER_RECEIVER_STATUS; not streaming; operator must confirm Primary failure"
    else
        record_check "WARNING" "pg_stat_wal_receiver.status" "no active WAL Receiver row; operator must confirm Primary failure"
    fi

    if ! confirm_word "PRIMARY_UNAVAILABLE" "Confirm independently that the former Primary is unavailable for normal service. This script cannot prove server failure from the Standby alone."; then
        cancel_operation "Manual Failover cancelled because Primary unavailability was not confirmed."
    fi
    record_check "MANUAL CHECK" "Primary Availability" "operator confirmed former Primary is unavailable"

    if ! confirm_word "PRIMARY_FENCED" "Confirm that the former Primary cannot accept writes or restart as Primary (STONITH/fencing or an equivalent isolation procedure)."; then
        cancel_operation "Manual Failover cancelled because fencing was not confirmed."
    fi
    record_check "MANUAL CHECK" "Primary Fencing" "operator confirmed former Primary is fenced from serving as Primary"

    if [ -n "$FAILOVER_RECEIVE_LSN" ]; then
        failover_wait_default=$(psql_call "SELECT CASE WHEN setting::bigint = 0 THEN 120 ELSE GREATEST(30, LEAST(600, (setting::bigint / 1000) * 2)) END FROM pg_settings WHERE name='wal_receiver_timeout'" 2>/dev/null | tr -d '[:space:]') || failover_wait_default=120
        [ "$failover_wait_default" -le "$MAX_WAIT_SECONDS" ] 2>/dev/null || failover_wait_default=$MAX_WAIT_SECONDS
        say "WAL Replay Catch-up Wait"
        say "  이미 수신한 마지막 WAL까지 replay한 후 승격합니다. 이는 장애 Primary에만 존재했던 미전송 WAL의 존재 여부까지 증명하지는 않습니다."
        failover_wait=$(ask "Wait seconds" "$failover_wait_default") || usage_die "Input cancelled."
        validate_wait_seconds "$failover_wait" || usage_die "Wait seconds must be an integer between 1 and $MAX_WAIT_SECONDS."
        if ! wait_local_replay_lsn "$FAILOVER_RECEIVE_LSN" "$failover_wait"; then
            die "Manual Failover is blocked because pg_last_wal_replay_lsn() did not reach the last WAL already received by this Standby."
        fi
        FAILOVER_REPLAY_LSN=$(psql_call "SELECT COALESCE(pg_last_wal_replay_lsn()::text,'')" 2>/dev/null | sed -n '1p')
        FAILOVER_REPLAY_GAP=$(psql_call "SELECT CASE WHEN pg_last_wal_receive_lsn() IS NULL OR pg_last_wal_replay_lsn() IS NULL THEN NULL ELSE pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) END" 2>/dev/null | sed -n '1p')
        record_check "PASSED" "WAL Replay" "pg_last_wal_replay_lsn() reached pg_last_wal_receive_lsn()=$FAILOVER_RECEIVE_LSN"
    else
        warn "pg_last_wal_receive_lsn() is NULL. The script cannot establish a local last-received WAL target before promotion."
        record_check "MANUAL CHECK" "WAL Receive Position" "pg_last_wal_receive_lsn() is NULL; no local receive target can be proven"
    fi

    warn "Because the former Primary is unavailable, this script cannot prove that no committed WAL exists only on that server. Manual Failover can therefore involve data loss, especially with asynchronous replication."
    if ! confirm_word "ACCEPT_DATA_LOSS_RISK" "Acknowledge the possibility of transactions that were committed on the failed Primary but never reached this Standby."; then
        cancel_operation "Manual Failover cancelled because potential data-loss risk was not accepted."
    fi
    record_check "WARNING" "Potential Data Loss" "operator explicitly accepted that unreceived WAL on the failed Primary cannot be ruled out"

    show_manual_failover_execution_plan

    if ! confirm_word "FAILOVER" "Final confirmation: promote this Standby to Primary. The fenced former Primary must not be restarted as Primary."; then
        cancel_operation "Manual Failover cancelled before promotion."
    fi

    refresh_role || die "Could not revalidate Current Role immediately before Manual Failover."
    [ "$LOCAL_ROLE" = "standby" ] || die "Manual Failover candidate is no longer a Standby."
    failover_receiver_now=$(psql_call "SELECT COALESCE(status,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')
    [ "$failover_receiver_now" != "streaming" ] || die "Manual Failover blocked: pg_stat_wal_receiver.status became streaming again before promotion."
    failover_pause_now=$(pause_state 2>/dev/null || echo unknown)
    case "$failover_pause_now" in "not paused"|f|false|"") ;; *) die "Manual Failover blocked: WAL replay became paused before promotion." ;; esac

    CURRENT_PHASE="after_primary_stop"
    failover_promote=$(psql_call "SELECT pg_promote()" 2>/dev/null | tr -d '[:space:]') || die "pg_promote() failed. The server remains in its current state; verify PostgreSQL logs and role before retrying."
    [ "$failover_promote" = "t" ] || [ "$failover_promote" = "true" ] || die "pg_promote() did not report success. Verify the server role before taking any further action."
    SWITCHOVER_PROMOTED=1
    CURRENT_PHASE="after_promotion"

    refresh_role || die "Promotion was requested but the new role could not be verified. Treat the former Primary as fenced and verify both servers manually."
    [ "$LOCAL_ROLE" = "primary" ] || die "pg_promote() returned success but pg_is_in_recovery() still indicates Standby. Treat the former Primary as fenced and inspect PostgreSQL logs."

    record_check "PASSED" "Manual Failover Promotion" "pg_promote() succeeded and pg_is_in_recovery()=false"
    CURRENT_PHASE="completed"
    section "Post-Failover Verification" "현재 서버가 Primary로 승격되었습니다. former Primary는 자동 재편입하지 않습니다."
    kv "Current Role" "Primary"
    kv "pg_is_in_recovery()" "$(psql_call "SELECT pg_is_in_recovery()" 2>/dev/null | sed -n '1p')"
    kv "SELECT count(*) FROM pg_stat_replication" "$(psql_call "SELECT count(*) FROM pg_stat_replication" 2>/dev/null | tr -d '[:space:]')"
    warn "Keep the former Primary fenced. Before rejoining it, compare timelines/control state and use operator-directed pg_rewind when prerequisites are satisfied, otherwise create a new Standby from a fresh base backup."
    manual_recovery_branch_notice
}

replication_control_menu() {
    while :; do
        require_standby
        rcm_role=$(current_topology_role 2>/dev/null || echo Standby)
        rcm_replay=$(pause_state 2>/dev/null || echo unknown)
        rcm_receiver=$(psql_call "SELECT COALESCE(status,'not connected') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')
        [ -n "$rcm_receiver" ] || rcm_receiver="not connected"
        section "WAL Receiver Control" "현재 노드의 WAL Replay와 Upstream WAL Receiver 연결을 제어합니다."
        kv "Current Role" "$rcm_role"
        kv "$(pause_state_name)" "$rcm_replay"
        kv "pg_stat_wal_receiver.status" "$rcm_receiver"
        say ""
        say "  1. Pause WAL Replay"
        say "     WAL 수신은 유지하고 replay만 일시 중지합니다."
        say ""
        say "  2. Resume WAL Replay"
        say "     일시 중지된 WAL replay를 다시 시작합니다."
        say ""
            say "  3. Disable WAL Receiver Streaming"
            say "     현재 노드가 Upstream에서 WAL을 받는 streaming 연결을 중지합니다."
        say ""
            say "  4. Restore WAL Receiver Streaming"
            say "     저장된 primary_conninfo를 복원하고 Upstream 재연결을 확인합니다."
        say ""
        say "  5. Back"
        rcm_choice=$(ask "Select replication operation" "5") || return 0
        case "$rcm_choice" in
            1) pause_wal_replay ;;
            2) resume_wal_replay ;;
            3) stop_wal_receiver_connection ;;
            4) resume_wal_receiver_connection ;;
            5) return 0 ;;
            *) say "Invalid selection." ;;
        esac
        say ""
        printf 'Press Enter to continue...' >&2
        IFS= read -r _dummy || true
    done
}

main_menu() {
    while :; do
        refresh_role || die "Could not read current PostgreSQL role."
        mm_topology_role=$(current_topology_role) || die "Could not determine current topology role."
        section "PostgreSQL Physical Replication Control" "현재 역할에서 실행 가능한 작업만 표시합니다."
        show_role_context
        say ""
        if [ "$LOCAL_ROLE" = "primary" ]; then
            say "  1. Planned Switchover"
            say "     현재 Primary와 선택한 Direct Standby의 역할을 계획적으로 전환합니다."
            say ""
            say "  2. Refresh Topology / Replication Status"
            say "     현재 토폴로지, Direct Standby, WAL 위치 및 replication slot 상태를 다시 조회합니다."
            say ""
            say "  3. Exit"
            mm_choice=$(ask "Select operation" "2") || exit 0
            case "$mm_choice" in
                1) planned_switchover ;;
                2) replication_status ;;
                3) exit 0 ;;
                *) say "Invalid selection." ;;
            esac
        else
            say "  1. WAL Receiver Control"
            say "     Upstream에서 받는 WAL Replay와 WAL Receiver 연결의 중지·복원 작업을 선택합니다."
            say ""
            say "  2. Manual Failover"
            say "     장애 Primary의 자동 판정 없이, fencing을 확인한 뒤 현재 Standby를 명시적으로 Promote합니다."
            say ""
            say "  3. Refresh Topology / Replication Status"
            say "     Upstream/Downstream 관계, WAL 위치 및 Receiver 상태를 다시 조회합니다."
            say ""
            say "  4. Exit"
            mm_choice=$(ask "Select operation" "3") || exit 0
            case "$mm_choice" in
                1) replication_control_menu ;;
                2) manual_failover ;;
                3) replication_status ;;
                4) exit 0 ;;
                *) say "Invalid selection." ;;
            esac
        fi
        say ""
        printf 'Press Enter to continue...' >&2
        IFS= read -r _dummy || true
    done
}

# -----------------------------
# Remote agent implementation
# -----------------------------
remote_list() {
    rl_expected_sysid=$1
    mktemp_safe || exit 1
    rl_tmp=$SAFE_TMP
    # Remote discovery must inspect all running PostgreSQL instances. An exported
    # PGDATA from the calling shell could otherwise hide other instances on the
    # same server (especially with the local transport mode).
    rl_saved_pgdata=${PGDATA:-}
    rl_saved_bindir=${PG_BINDIR:-}
    PGDATA=""
    discover_pgdata_candidates > "$rl_tmp"
    PGDATA=$rl_saved_pgdata
    while IFS= read -r rl_pgdata; do
        [ -n "$rl_pgdata" ] || continue
        # Reset globals that may differ per instance.
        PGDATA=$rl_pgdata
        PG_BINDIR=$rl_saved_bindir
        PGPORT=""
        SOCKET_DIR=""
        PSQL_BIN=""
        PG_CTL_BIN=""
        PG_CONTROLDATA_BIN=""
        DB_NAME=""
        PGUSER_LOCAL="${PGUSER:-}"
        if init_instance_from_pgdata "$rl_pgdata" 1 >/dev/null 2>&1; then
            [ "$SYSTEM_IDENTIFIER" = "$rl_expected_sysid" ] || continue
            [ "$LOCAL_ROLE" = "standby" ] || continue
            rl_sender=$(psql_call "SELECT COALESCE(sender_host,'') || E'\\t' || COALESCE(sender_port::text,'') || E'\\t' || COALESCE(status,'') || E'\\t' || COALESCE(slot_name,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')
            rl_sender_host=$(printf '%s\n' "$rl_sender" | awk -F '\t' '{print $1}')
            rl_sender_port=$(printf '%s\n' "$rl_sender" | awk -F '\t' '{print $2}')
            rl_receiver_status=$(printf '%s\n' "$rl_sender" | awk -F '\t' '{print $3}')
            rl_receiver_slot=$(printf '%s\n' "$rl_sender" | awk -F '\t' '{print $4}')
            rl_replay=$(psql_call "SELECT COALESCE(pg_last_wal_replay_lsn()::text,'')" 2>/dev/null | sed -n '1p')
            rl_pause=$(pause_state 2>/dev/null || echo unknown)
            rl_delay=$(psql_call "SELECT setting FROM pg_settings WHERE name='recovery_min_apply_delay'" 2>/dev/null | tr -d '[:space:]')
            rl_sync_names=$(psql_call "SHOW synchronous_standby_names" 2>/dev/null | tr '\t\r\n' '   ')
            rl_default_ro=$(psql_call "SHOW default_transaction_read_only" 2>/dev/null | tr -d '[:space:]')
            rl_archive_mode=$(psql_call "SHOW archive_mode" 2>/dev/null | tr -d '[:space:]')
            rl_archive_ready=$(archive_mechanism_configured 2>/dev/null || echo 0)
            rl_downstream_count=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]')
            if [ "$rl_downstream_count" -gt 0 ] 2>/dev/null; then rl_topology_role="Cascading Standby"; else rl_topology_role="Standby"; fi
            rl_recovery_timeline=$(psql_call "SHOW recovery_target_timeline" 2>/dev/null | tr -d '[:space:]')
            printf 'INSTANCE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PGDATA" "$PGPORT" "$PG_VERSION_NUM" "$LOCAL_ROLE" "$SYSTEM_IDENTIFIER" "$rl_sender_host" "$rl_sender_port" "$rl_replay" "$rl_pause" "$rl_delay" "$rl_receiver_status" "$rl_sync_names" "$rl_default_ro" "$rl_archive_mode" "$rl_archive_ready" "$rl_topology_role" "$rl_downstream_count" "$rl_recovery_timeline" "$rl_receiver_slot"
        fi
    done < "$rl_tmp"
}

remote_downstreams() {
    remote_init_exact "$1"
    psql_call "SELECT 'DOWNSTREAM' || E'\\t' || application_name || E'\\t' || COALESCE(host(client_addr),'local') || E'\\t' || state || E'\\t' || sync_state || E'\\t' || COALESCE(replay_lsn::text,'') || E'\\t' || COALESCE((SELECT slot_name FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical' LIMIT 1),'') FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical') ORDER BY application_name, client_addr NULLS FIRST, pid"
}

remote_list_downstream() {
    rld_expected_sysid=$1
    rld_expected_sender_port=$2
    rld_expected_slot=$3
    mktemp_safe || exit 1
    rld_tmp=$SAFE_TMP
    rld_saved_pgdata=${PGDATA:-}
    rld_saved_bindir=${PG_BINDIR:-}
    PGDATA=""
    discover_pgdata_candidates > "$rld_tmp"
    PGDATA=$rld_saved_pgdata
    while IFS= read -r rld_pgdata; do
        [ -n "$rld_pgdata" ] || continue
        PGDATA=$rld_pgdata
        PG_BINDIR=$rld_saved_bindir
        PGPORT=""
        SOCKET_DIR=""
        PSQL_BIN=""
        PG_CTL_BIN=""
        PG_CONTROLDATA_BIN=""
        DB_NAME=""
        PGUSER_LOCAL="${PGUSER:-}"
        if init_instance_from_pgdata "$rld_pgdata" 1 >/dev/null 2>&1; then
            [ "$SYSTEM_IDENTIFIER" = "$rld_expected_sysid" ] || continue
            [ "$LOCAL_ROLE" = "standby" ] || continue
            rld_receiver=$(psql_call "SELECT COALESCE(sender_host,'') || E'\\t' || COALESCE(sender_port::text,'') || E'\\t' || COALESCE(status,'') || E'\\t' || COALESCE(slot_name,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')
            rld_sender_host=$(printf '%s\n' "$rld_receiver" | awk -F '\t' '{print $1}')
            rld_sender_port=$(printf '%s\n' "$rld_receiver" | awk -F '\t' '{print $2}')
            rld_status=$(printf '%s\n' "$rld_receiver" | awk -F '\t' '{print $3}')
            rld_slot=$(printf '%s\n' "$rld_receiver" | awk -F '\t' '{print $4}')
            [ "$rld_sender_port" = "$rld_expected_sender_port" ] || continue
            [ "$rld_status" = "streaming" ] || continue
            [ "$rld_slot" = "$rld_expected_slot" ] || continue
            rld_timeline=$(psql_call "SHOW recovery_target_timeline" 2>/dev/null | tr -d '[:space:]')
            printf 'DOWNSTREAM_INSTANCE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PGDATA" "$PGPORT" "$PG_VERSION_NUM" "$SYSTEM_IDENTIFIER" "$rld_sender_host" "$rld_sender_port" "$rld_status" "$rld_timeline" "$rld_slot"
        fi
    done < "$rld_tmp"
}

remote_init_exact() {
    rie_pgdata=$1
    init_instance_from_pgdata "$rie_pgdata" 1 >/dev/null 2>&1 || exit 2
    validate_supported_version
}

remote_lock_acquire() {
    rla_data=$1
    rla_token=$2
    [ -n "$rla_token" ] && [ -d "$rla_data" ] && [ -w "$rla_data" ] || return 1
    rla_dir="$rla_data/.postgresql-role-switch.lock"
    [ ! -L "$rla_dir" ] || return 1
    mkdir "$rla_dir" 2>/dev/null || return 1
    printf 'remote:%s\n' "$rla_token" > "$rla_dir/owner" || return 1
    printf '0\n' > "$rla_dir/pid" || return 1
    printf '%s\n' "$rla_data" > "$rla_dir/data_directory" || return 1
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" > "$rla_dir/started_at" || return 1
}

remote_lock_release() {
    rlr_data=$1
    rlr_token=$2
    [ -n "$rlr_token" ] && [ -d "$rlr_data" ] || return 1
    rlr_dir="$rlr_data/.postgresql-role-switch.lock"
    [ ! -L "$rlr_dir" ] && [ -d "$rlr_dir" ] || return 1
    [ "$(sed -n '1p' "$rlr_dir/owner" 2>/dev/null)" = "remote:$rlr_token" ] || return 1
    remove_lock_directory "$rlr_dir"
}

remote_preflight() {
    remote_init_exact "$1"
    [ -n "$PG_CTL_BIN" ] && [ -x "$PG_CTL_BIN" ] || exit 20
    rpf_owner=$(ps -o user= -p "$POSTMASTER_PID" 2>/dev/null | awk '{print $1; exit}')
    rpf_user=$(id -un 2>/dev/null || echo "")
    [ -n "$rpf_owner" ] && [ "$rpf_owner" = "$rpf_user" ] || exit 21
    rpf_auto_parent=${AUTO_CONF%/*}
    [ "$rpf_auto_parent" != "$AUTO_CONF" ] || rpf_auto_parent=$PGDATA
    if [ -e "$AUTO_CONF" ]; then
        [ -w "$AUTO_CONF" ] || exit 22
    else
        [ -w "$rpf_auto_parent" ] || exit 23
    fi
    [ -w "$PGDATA" ] || exit 24
    rpf_wal="$PGDATA/pg_wal"
    [ -d "$rpf_wal" ] || rpf_wal="$PGDATA/pg_xlog"
    [ -d "$rpf_wal" ] || exit 25
    rpf_available_kb=$(df -Pk "$rpf_wal" 2>/dev/null | awk 'NR==2 {print $4; exit}')
    rpf_max_wal_bytes=$(psql_call "SELECT pg_size_bytes(setting || CASE WHEN unit IS NULL OR unit='' THEN '' ELSE unit END) FROM pg_settings WHERE name='max_wal_size'" 2>/dev/null | tr -d '[:space:]') || exit 26
    case "$rpf_available_kb:$rpf_max_wal_bytes" in *[!0-9:]*|:*|*:) exit 27 ;; esac
    rpf_available_bytes=$((rpf_available_kb * 1024))
    rpf_required_bytes=$((rpf_max_wal_bytes * 2))
    printf 'PREFLIGHT\tready\t%s\t%s\t%s\t%s\t%s\n' "$rpf_user" "$PG_CTL_BIN" "$PGDATA" "$rpf_available_bytes" "$rpf_required_bytes"
}

remote_verify_upstream() {
    rvu_data=$1
    rvu_system=$2
    rvu_port=$3
    remote_init_exact "$rvu_data"
    [ "$LOCAL_ROLE" = "standby" ] || return 1
    rvu_conninfo_output=$(psql_call "SHOW primary_conninfo" 2>/dev/null) || return 22
    rvu_conninfo=$(printf '%s\n' "$rvu_conninfo_output" | sed -n '1p')
    [ -n "$rvu_conninfo" ] || return 1
    # PGDATABASE is a database name fallback, not a reliably expanded libpq
    # connection string. Feed psql's \connect through a private input file:
    # connection parameters, including possible passwords, never enter argv.
    case "$rvu_conninfo" in
        postgresql://*|postgres://*) rvu_dsn=$rvu_conninfo ;;
        *) rvu_db=$(conninfo_quote_value "$DB_NAME"); rvu_dsn="dbname='$rvu_db' $rvu_conninfo" ;;
    esac
    case "$rvu_dsn" in
        *'
'*) return 22 ;; # Never allow a second psql meta-command.
    esac
    rvu_cr=$(printf '\r')
    case "$rvu_dsn" in
        *"$rvu_cr"*) return 22 ;; # Never allow a carriage return in the psql meta-command.
    esac
    mktemp_safe || return 22
    rvu_input=$SAFE_TMP
    # psql's quoted meta-command arguments also interpret backslash escapes.
    # Escape backslashes before doubling quotes so libpq receives the original
    # primary_conninfo bytes unchanged.
    rvu_quoted=$(printf '%s' "$rvu_dsn" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g")
    {
        printf '\\connect -reuse-previous=off '\''%s'\''\n' "$rvu_quoted"
        printf '\\echo __PG_ROLE_SWITCH_UPSTREAM_CONNECTED__\n'
        printf "SELECT system_identifier::text || E'\\\\t' || current_setting('port') || E'\\\\t' || pg_is_in_recovery()::text FROM pg_control_system();\n"
    } > "$rvu_input" || return 22
    rvu_output=$(PGDATABASE="$DB_NAME" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -f "$rvu_input" 2>/dev/null)
    rvu_code=$?
    case "$rvu_code" in
        0) printf '%s\n' "$rvu_output" | grep -Fx '__PG_ROLE_SWITCH_UPSTREAM_CONNECTED__' >/dev/null || return 22 ;;
        2) return 21 ;; # psql: server connection failed
        *)
            # ON_ERROR_STOP can return 3 for either a failed \connect or a
            # SQL error. The marker is emitted only after \connect succeeds.
            if printf '%s\n' "$rvu_output" | grep -Fx '__PG_ROLE_SWITCH_UPSTREAM_CONNECTED__' >/dev/null; then
                return 22
            fi
            return 21
            ;;
    esac
    rvu_observed=$(printf '%s\n' "$rvu_output" | awk -F '\t' 'NF==3 {line=$0} END {print line}')
    [ -n "$rvu_observed" ] || return 22
    rvu_actual_system=$(printf '%s\n' "$rvu_observed" | awk -F '\t' '{print $1}')
    rvu_actual_port=$(printf '%s\n' "$rvu_observed" | awk -F '\t' '{print $2}')
    rvu_recovery=$(printf '%s\n' "$rvu_observed" | awk -F '\t' '{print $3}')
    if [ "$rvu_actual_system" != "$rvu_system" ] || [ "$rvu_actual_port" != "$rvu_port" ] || [ "$rvu_recovery" != "false" ]; then
        printf 'UPSTREAM_MISMATCH\n'
        return 0
    fi
    printf 'UPSTREAM_VERIFIED\n'
}

remote_timeout_default() {
    remote_init_exact "$1"
    rtd=$(psql_call "SELECT CASE WHEN setting::bigint = 0 THEN 120 ELSE GREATEST(30, LEAST(600, (setting::bigint / 1000) * 2)) END FROM pg_settings WHERE name='wal_receiver_timeout'" 2>/dev/null | tr -d '[:space:]') || rtd=120
    printf 'TIMEOUT\t%s\n' "$rtd"
}

remote_validate_candidate() {
    rvc_pgdata=$1
    rvc_expected_sysid=$2
    rvc_expected_port=$3
    rvc_expected_slot=$4
    rvc_expected_downstreams=$5
    remote_init_exact "$rvc_pgdata"
    [ "$LOCAL_ROLE" = "standby" ] || exit 3
    [ "$SYSTEM_IDENTIFIER" = "$rvc_expected_sysid" ] || exit 4
    rvc_receiver=$(psql_call "SELECT COALESCE(status,'') || E'\\t' || COALESCE(sender_port::text,'') || E'\\t' || COALESCE(slot_name,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p') || exit 5
    [ "$(printf '%s\n' "$rvc_receiver" | awk -F '\t' '{print $1}')" = "streaming" ] || exit 6
    [ "$(printf '%s\n' "$rvc_receiver" | awk -F '\t' '{print $2}')" = "$rvc_expected_port" ] || exit 7
    [ "$(printf '%s\n' "$rvc_receiver" | awk -F '\t' '{print $3}')" = "$rvc_expected_slot" ] || exit 8
    rvc_pause=$(pause_state 2>/dev/null || echo unknown)
    case "$rvc_pause" in "not paused"|f|false|"") ;; *) exit 9 ;; esac
    rvc_delay=$(psql_call "SELECT setting FROM pg_settings WHERE name='recovery_min_apply_delay'" 2>/dev/null | tr -d '[:space:]') || exit 10
    [ "$rvc_delay" = "0" ] || exit 11
    rvc_timeline=$(psql_call "SHOW recovery_target_timeline" 2>/dev/null | tr -d '[:space:]') || exit 12
    [ "$rvc_timeline" = "latest" ] || exit 13
    rvc_downstreams=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || exit 14
    [ "$rvc_downstreams" = "$rvc_expected_downstreams" ] || exit 15
    rvc_bad=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND state <> 'streaming' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || exit 16
    [ "$rvc_bad" = "0" ] || exit 17
    printf 'CANDIDATE_READY\t%s\n' "$rvc_pgdata"
}

remote_slot_state() {
    rss_pgdata=$1
    rss_slot=$2
    remote_init_exact "$rss_pgdata"
    rss_state=$(psql_call_var slot "$rss_slot" "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot') THEN 'absent' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical') THEN 'physical' ELSE 'conflict' END" 2>/dev/null | tr -d '[:space:]') || exit 3
    printf 'SLOT_STATE\t%s\t%s\n' "$rss_slot" "$rss_state"
}

remote_switchover_safety() {
    rss_pgdata=$1
    remote_init_exact "$rss_pgdata"
    rss_mws=$(psql_call "SHOW max_wal_senders" 2>/dev/null | tr -d '[:space:]') || exit 3
    rss_mrs=$(psql_call "SHOW max_replication_slots" 2>/dev/null | tr -d '[:space:]') || exit 4
    rss_slots=$(psql_call "SELECT count(*) FROM pg_replication_slots" 2>/dev/null | tr -d '[:space:]') || exit 5
    if [ "$PG_MAJOR" -ge 13 ]; then
        rss_risky=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='physical' AND wal_status IN ('unreserved','lost')" 2>/dev/null | tr -d '[:space:]') || exit 6
    else
        rss_risky=-1
    fi
    rss_arch=$(psql_call "SELECT archived_count::text || E'\\t' || failed_count::text || E'\\t' || COALESCE(last_archived_time::text,'') || E'\\t' || COALESCE(last_failed_time::text,'') || E'\\t' || CASE WHEN failed_count > 0 AND last_failed_time IS NOT NULL AND (last_archived_time IS NULL OR last_failed_time > last_archived_time) THEN '1' ELSE '0' END FROM pg_stat_archiver" 2>/dev/null | sed -n '1p') || exit 7
    rss_archived=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $1}')
    rss_failed=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $2}')
    rss_last_ok=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $3}')
    rss_last_fail=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $4}')
    rss_unresolved=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $5}')
    rss_wal_level=$(psql_call "SHOW wal_level" 2>/dev/null | tr -d '[:space:]') || exit 8
    rss_logical_slots=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'" 2>/dev/null | tr -d '[:space:]') || exit 9
    printf 'SWITCHOVER_SAFETY\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rss_mws" "$rss_mrs" "$rss_slots" "$rss_risky" "$rss_archived" "$rss_failed" "$rss_last_ok" "$rss_last_fail" "$rss_unresolved" "$rss_wal_level" "$rss_logical_slots"
}
remote_wait_streaming_downstreams() {
    rwsd_pgdata=$1
    rwsd_expected=$2
    rwsd_timeout=$(bounded_wait_seconds "$3") || return 1
    remote_init_exact "$rwsd_pgdata"
    rwsd_i=0
    while [ "$rwsd_i" -lt "$rwsd_timeout" ]; do
        rwsd_counts=$(psql_call "SELECT count(*)::text || E'\\t' || count(*) FILTER (WHERE state='streaming')::text FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | sed -n '1p') || rwsd_counts=""
        rwsd_total=$(printf '%s\n' "$rwsd_counts" | awk -F '\t' '{print $1}')
        rwsd_streaming=$(printf '%s\n' "$rwsd_counts" | awk -F '\t' '{print $2}')
        if [ "$rwsd_total" = "$rwsd_expected" ] && [ "$rwsd_streaming" = "$rwsd_expected" ]; then
            printf 'DOWNSTREAMS_STREAMING\t%s\n' "$rwsd_streaming"
            return 0
        fi
        sleep 1
        rwsd_i=$((rwsd_i + 1))
    done
    printf 'DOWNSTREAMS_NOT_READY\t%s\t%s\n' "${rwsd_total:-}" "${rwsd_streaming:-}"
    return 1
}

remote_wait_lsn() {
    rwl_pgdata=$1
    rwl_target=$2
    rwl_timeout=$(bounded_wait_seconds "$3") || return 1
    remote_init_exact "$rwl_pgdata"
    rwl_i=0
    while [ "$rwl_i" -lt "$rwl_timeout" ]; do
        rwl_ok=$(psql_call_var target "$rwl_target" "SELECT CASE WHEN pg_last_wal_replay_lsn() IS NOT NULL AND pg_last_wal_replay_lsn() >= :'target'::pg_lsn THEN 1 ELSE 0 END" 2>/dev/null | tr -d '[:space:]') || rwl_ok=0
        if [ "$rwl_ok" = "1" ]; then
            printf 'CAUGHT_UP\t%s\n' "$(psql_call "SELECT pg_last_wal_replay_lsn()" 2>/dev/null | sed -n '1p')"
            return 0
        fi
        sleep 1
        rwl_i=$((rwl_i + 1))
    done
    printf 'NOT_CAUGHT_UP\t%s\n' "$(psql_call "SELECT COALESCE(pg_last_wal_replay_lsn()::text,'')" 2>/dev/null | sed -n '1p')"
    return 1
}

remote_promote() {
    remote_init_exact "$1"
    [ "$LOCAL_ROLE" = "standby" ] || exit 3
    rp_pause=$(pause_state 2>/dev/null || echo unknown)
    case "$rp_pause" in "not paused"|f|false|"") ;; *) exit 4 ;; esac
    rp_result=$(psql_call "SELECT pg_promote()" 2>/dev/null | tr -d '[:space:]') || exit 5
    [ "$rp_result" = "t" ] || [ "$rp_result" = "true" ] || exit 6
    refresh_role || exit 7
    [ "$LOCAL_ROLE" = "primary" ] || exit 8
    printf 'PROMOTED\tprimary\n'
}

remote_create_slot() {
    rcs_pgdata=$1
    rcs_slot=$2
    remote_init_exact "$rcs_pgdata"
    [ "$LOCAL_ROLE" = "primary" ] || exit 3
    rcs_exists=$(psql_call_var slot "$rcs_slot" "SELECT count(*) FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical'" 2>/dev/null | tr -d '[:space:]') || exit 4
    if [ "$rcs_exists" -eq 0 ]; then
        psql_call_var slot "$rcs_slot" "SELECT slot_name FROM pg_create_physical_replication_slot(:'slot', true)" >/dev/null || exit 5
    fi
    printf 'SLOT\t%s\n' "$rcs_slot"
}

remote_check_logical_slot() {
    rcls_pgdata=$1
    rcls_slot=$2
    remote_init_exact "$rcls_pgdata"
    [ "$PG_MAJOR" -ge 17 ] || exit 3
    rcls_ready=$(psql_call_var slot "$rcls_slot" "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='logical' AND synced AND NOT temporary AND invalidation_reason IS NULL) THEN 1 ELSE 0 END" 2>/dev/null | tr -d '[:space:]') || exit 4
    if [ "$rcls_ready" = "1" ]; then
        printf 'LOGICAL_SLOT\t%s\tready\n' "$rcls_slot"
    else
        printf 'LOGICAL_SLOT\t%s\tnot_ready\n' "$rcls_slot"
        return 1
    fi
}

remote_count_standby() {
    rcs2_pgdata=$1
    rcs2_app=$2
    remote_init_exact "$rcs2_pgdata"
    rcs2_output=$(psql_call_var app "$rcs2_app" "SELECT count(*) FROM pg_stat_replication r WHERE application_name=:'app' AND state='streaming' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null) || return 1
    rcs2_count=$(printf '%s' "$rcs2_output" | tr -d '[:space:]')
    case "$rcs2_count" in ''|*[!0-9]*) return 1 ;; esac
    printf 'COUNT\t%s\n' "$rcs2_count"
}

# Remote entry points are intentionally non-interactive.
case "${1:-}" in
    --check-only)
        CHECK_ONLY=1
        shift
        [ "$#" -eq 0 ] || usage_die "--check-only does not accept additional arguments."
        ;;
    --help|-h)
        [ "$#" -eq 1 ] || usage_die "--help does not accept additional arguments."
        say "Usage: $0 [--check-only]"
        say "  --check-only  Run Planned Switchover validation without changing PostgreSQL settings, stopping a server, or promoting a Standby Server."
        exit 0
        ;;
    --remote-list)
        [ "$#" -eq 2 ] || exit 64
        remote_list "$2"
        exit $?
        ;;
    --remote-lock-acquire)
        [ "$#" -eq 3 ] || exit 64
        remote_lock_acquire "$2" "$3"
        exit $?
        ;;
    --remote-lock-release)
        [ "$#" -eq 3 ] || exit 64
        remote_lock_release "$2" "$3"
        exit $?
        ;;
    --remote-preflight)
        [ "$#" -eq 2 ] || exit 64
        remote_preflight "$2"
        exit $?
        ;;
    --remote-verify-upstream)
        [ "$#" -eq 4 ] || exit 64
        remote_verify_upstream "$2" "$3" "$4"
        exit $?
        ;;
    --remote-timeout-default)
        [ "$#" -eq 2 ] || exit 64
        remote_timeout_default "$2"
        exit $?
        ;;
    --remote-validate-candidate)
        [ "$#" -eq 6 ] || exit 64
        remote_validate_candidate "$2" "$3" "$4" "$5" "$6"
        exit $?
        ;;
    --remote-slot-state)
        [ "$#" -eq 3 ] || exit 64
        remote_slot_state "$2" "$3"
        exit $?
        ;;
    --remote-switchover-safety)
        [ "$#" -eq 2 ] || exit 64
        remote_switchover_safety "$2"
        exit $?
        ;;
    --remote-wait-streaming-downstreams)
        [ "$#" -eq 4 ] || exit 64
        remote_wait_streaming_downstreams "$2" "$3" "$4"
        exit $?
        ;;
    --remote-wait-lsn)
        [ "$#" -eq 4 ] || exit 64
        remote_wait_lsn "$2" "$3" "$4"
        exit $?
        ;;
    --remote-promote)
        [ "$#" -eq 2 ] || exit 64
        remote_promote "$2"
        exit $?
        ;;
    --remote-create-slot)
        [ "$#" -eq 3 ] || exit 64
        remote_create_slot "$2" "$3"
        exit $?
        ;;
    --remote-check-logical-slot)
        [ "$#" -eq 3 ] || exit 64
        remote_check_logical_slot "$2" "$3"
        exit $?
        ;;
    --remote-count-standby)
        [ "$#" -eq 3 ] || exit 64
        remote_count_standby "$2" "$3"
        exit $?
        ;;
    --remote-downstreams)
        [ "$#" -eq 2 ] || exit 64
        remote_downstreams "$2"
        exit $?
        ;;
    --remote-list-downstream)
        [ "$#" -eq 4 ] || exit 64
        remote_list_downstream "$2" "$3" "$4"
        exit $?
        ;;
    '')
        ;;
    *)
        usage_die "Unknown option: $1. Use --help for usage."
        ;;
esac

case "$MAX_WAIT_SECONDS" in ''|*[!0-9]*) usage_die "PG_SWITCH_MAX_WAIT_SECONDS must be an integer." ;; esac
[ "$MAX_WAIT_SECONDS" -ge 1 ] 2>/dev/null || usage_die "PG_SWITCH_MAX_WAIT_SECONDS must be greater than zero."
[ "$MAX_WAIT_SECONDS" -le 86400 ] 2>/dev/null || usage_die "PG_SWITCH_MAX_WAIT_SECONDS must not exceed 86400 seconds."
say "PostgreSQL Physical Replication Control / Planned Switchover v$SCRIPT_VERSION"
say "  PostgreSQL 12~18, POSIX /bin/sh, no external HA-manager dependency"
select_local_instance
validate_supported_version
acquire_instance_lock
prepare_state_dir
initialize_result_report
record_check "PASSED" "Instance Lock" "exclusive lock acquired"
show_instance_summary
topology_discovery
if [ "$CHECK_ONLY" -eq 1 ]; then
    planned_switchover
else
    main_menu
fi
