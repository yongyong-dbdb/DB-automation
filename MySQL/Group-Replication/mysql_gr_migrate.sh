#!/bin/sh
# mysql_gr_migrate.sh v1.0.13
# POSIX sh; OS utilities and MySQL clients only. No external language packages.
# Supported: Oracle MySQL 8.0.27+, 8.4.x, 9.7.x; homogeneous exact versions.
# Single-primary or multi-primary / XCom. Never resets GTID or binary logs.
set -eu
umask 077
VERSION=1.0.13
ROOT=${MYSQL_GR_WORK_ROOT:-"$(pwd)/mysql_gr_work"}
MYSQL=${MYSQL_GR_MYSQL:-mysql}
DUMP=${MYSQL_GR_MYSQLDUMP:-mysqldump}
BINLOG=${MYSQL_GR_MYSQLBINLOG:-mysqlbinlog}
STEP=${1:-help}
log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
ask() (
    printf '%s%s: ' "$1" "${2:+ [$2]}" >&2
    IFS= read -r a || exit 1
    printf '%s' "${a:-${2-}}"
)
required() (
    a=$(ask "$1" "${2-}") || exit 1
    [ -n "$a" ] || { log 'A value is required.'; exit 1; }
    printf '%s' "$a"
)
confirm() {
    expected=$1; alias=${2:-}
    while :; do
        answer=$(ask "Type $expected to continue" '')
        if [ "$answer" = "$expected" ] || { [ -n "$alias" ] && [ "$answer" = "$alias" ]; }; then
            return 0
        fi
        if [ -n "$alias" ]; then
            log "Confirmation did not match. Enter '$expected' or '$alias'."
        else
            log "Confirmation did not match. Enter '$expected'."
        fi
    done
}
uint() { case $1 in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
port_ok() { uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
safe_host() { case $1 in ''|*[!a-zA-Z0-9_.-]*) die 'Use an IPv4 address or DNS name (IPv6 is not supported in v1.0.2).';; esac; }
q() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g"; }
optq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
put() { printf '%s\n' "$3" > "$ROOT/$1/$2"; }
get() { cat "$ROOT/$1/$2"; }
ids() { n=1; while [ "$n" -le "$(get meta count)" ]; do printf '%s\n' "$n"; n=$((n+1)); done; }
secret() (
    printf '%s: ' "$1" >&2
    if [ -t 0 ]; then
        old=$(stty -g); trap 'stty "$old"' 0; trap 'exit 1' 1 2 15
        stty -echo
    fi
    IFS= read -r a || exit 1
    printf '\n' >&2
    printf '%s' "$a"
)
cleanup() {
    rc=$?
    trap - 0 1 2 15
    if [ "$rc" -ne 0 ] && [ -d "${RUN:-}/cutover_rollback" ] && [ ! -f "$ROOT/meta/bootstrap_attempted" ]; then
        rollback_cutover || log "URGENT: cutover rollback incomplete; preserve $RUN/cutover_rollback"
    fi
    if [ -n "${BOOT_NODE:-}" ] && [ -d "${TEMP:-}" ]; then
        sql "$BOOT_NODE" 'SET GLOBAL group_replication_bootstrap_group=OFF;' >/dev/null 2>&1 || log 'URGENT: manually set group_replication_bootstrap_group=OFF on bootstrap node.'
    fi
    if [ -d "${TEMP:-}/unfenced" ]; then
        for marker in "$TEMP"/unfenced/*; do
            [ -f "$marker" ] || continue
            sql "${marker##*/}" 'SET GLOBAL super_read_only=ON;' >/dev/null 2>&1 || log "URGENT: restore write fence on node ${marker##*/}"
        done
    fi
    [ -z "${TEMP:-}" ] || rm -rf -- "$TEMP"

    [ -z "${LOCK:-}" ] || rmdir "$LOCK" 2>/dev/null || :
    if [ "$rc" -ne 0 ]; then
        if [ "${PHASE:-}" = discover ]; then
            log "Registration stopped. This discover command did not change databases. Registration state is preserved in $ROOT; rerun discover to retry incomplete registration."
        else
            log "Stopped. Preserve state in $ROOT. Inspect status and diagnostics before retrying. Write fences and stopped channels are NOT automatically reversed."
        fi
    fi
    exit "$rc"
}
help() {
    cat <<EOF
mysql_gr_migrate.sh v$VERSION
Usage: sh mysql_gr_migrate.sh discover|configure|tls|precheck|initialize|cutover|join|release|validate|status|all
  discover   Select GTID -> GR / Standalone -> GR and 2..9 nodes
  configure  Generate version-aware config; optionally apply/restart local nodes
  tls        Prepare and verify SAN certificates; default is plan-only (MYSQL_GR_TLS_ACTION=apply to apply)
  precheck   Read-only identity, configuration, schema and channel checks
  initialize Fence writes, catch up GTID replicas, provision empty nodes
  cutover    Recheck, stop selected async channels, configure recovery, bootstrap/join
  join       Resume joining members into the recorded ONLINE group (no bootstrap)
  release    Validate then explicitly release primary write fences
  validate   Verify all members, roles, queues and GTID catch-up
  status     Display member/channel and write-fence status
  all        Run the complete interactive workflow
Environment: MYSQL_GR_WORK_ROOT, MYSQL_GR_MYSQL, MYSQL_GR_MYSQLDUMP, MYSQL_GR_MYSQLBINLOG
Use the same absolute MYSQL_GR_WORK_ROOT for every invocation.
Remote configure offers ssh or manual. SSH uses the existing OpenSSH client;
manual emits a password-free helper to copy/run on the target host. No packages
are installed. MYSQL_GR_GTID_STATE_FILE can point to an existing GTID state file.
Credentials are prompted each run and deleted from temporary files on exit.
EOF
}
credential() (
    i=$1
    [ ! -f "$TEMP/$i.cnf" ] || exit 0
    pw=$(secret "Node $i password for $(get "$i" user)")
    {
        # Keep [client] limited to options shared by MySQL client programs.
        # Program-specific options belong in their own group so mysqlbinlog/
        # mysqldump do not abort on a mysql-only option.
        printf '[client]\nuser="%s"\npassword="%s"\n' "$(optq "$(get "$i" user)")" "$(optq "$pw")"
        if [ "$(get "$i" mode)" = socket ]; then
            printf 'protocol=SOCKET\nsocket="%s"\n' "$(optq "$(get "$i" socket)")"
        else
            printf 'protocol=TCP\nhost="%s"\nport=%s\nssl-mode=%s\n' "$(optq "$(get "$i" host)")" "$(get "$i" port)" "$(get "$i" admin_tls)"
            [ ! -s "$ROOT/$i/admin_ca" ] || printf 'ssl-ca="%s"\n' "$(optq "$(get "$i" admin_ca)")"
        fi
        printf '\n[mysql]\nconnect-timeout=10\n'
    } > "$TEMP/$i.cnf"
)
tool_option_preflight() (
    i=$1; tool=$2; label=$3
    credential "$i"
    command -v "$tool" >/dev/null 2>&1 || exit 2
    err="$RUN/node_${i}.${label}_option_preflight.err"
    if ! "$tool" --defaults-file="$TEMP/$i.cnf" --no-login-paths --help >/dev/null 2> "$err"; then
        chmod 600 "$err" 2>/dev/null || :
        log "ERROR: $label rejected the generated client option file for node $i."
        log "Evidence: $err"
        exit 1
    fi
    rm -f "$err"
)

preflight_client_utilities() {
    # Run before initialize mutates/fences anything. Missing optional tools are
    # handled later only if their workflow is actually selected.
    for i in $(ids); do
        tool_option_preflight "$i" "$MYSQL" mysql || die "mysql option-file compatibility check failed for node $i"
        if command -v "$BINLOG" >/dev/null 2>&1; then
            tool_option_preflight "$i" "$BINLOG" mysqlbinlog || die "mysqlbinlog option-file compatibility check failed for node $i"
        fi
    done
    if command -v "$DUMP" >/dev/null 2>&1; then
        tool_option_preflight 1 "$DUMP" mysqldump || die 'mysqldump option-file compatibility check failed for node 1'
    fi
}

sql() (
    i=$1; stmt=$2
    credential "$i"
    # SQL via stdin, never process arguments. No --force; stop on first error.
    printf "SET SESSION sql_mode='NO_ENGINE_SUBSTITUTION';\n%s\n" "$stmt" | "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --batch --raw --skip-column-names
)
val() { sql "$1" "SELECT @@GLOBAL.$2;"; }
hasvar() { [ -n "$(sql "$1" "SHOW GLOBAL VARIABLES WHERE Variable_name='$(q "$2")';")" ]; }
connected() {
    for ci in $(ids); do
        credential "$ci"
        [ "$(sql "$ci" 'SELECT 1;')" = 1 ] || die "Node $ci connection failed"
        [ "$(val "$ci" server_uuid)" = "$(get "$ci" uuid)" ] || die "Node $ci UUID changed; rediscover before proceeding"
    done
}
version_guard() (
    v=$1
    case $v in
        8.0.*) p=$(printf '%s' "$v" | cut -d. -f3 | sed 's/[^0-9].*//'); uint "$p" && [ "$p" -ge 27 ] || exit 1;;
        8.4.*|9.7.*) :;;
        *) exit 1;;
    esac
)
local_pid() (
    i=$1
    [ "$(get "$i" location)" = local ] || exit 1
    pf=$(val "$i" pid_file)
    [ -r "$pf" ] || exit 1
    p=$(cat "$pf"); uint "$p" || exit 1
    exe=$(readlink -f "/proc/$p/exe") || exit 1
    case ${exe##*/} in mysqld|mysqld-debug) :;; *) exit 1;; esac
    # A socket connection and matching runtime socket/UUID establish local identity.
    [ "$(get "$i" mode)" = socket ] || exit 1
    [ "$(val "$i" socket)" = "$(get "$i" socket)" ] || exit 1
    printf '%s' "$p"
)
# Ephemeral write-unfence markers let cleanup restore protection after interruption.
local_write() (
    i=$1; statement=$2; sensitivity=${3:-normal}
    mkdir -p "$TEMP/unfenced"; : > "$TEMP/unfenced/$i"
    if [ "$sensitivity" = secret ]; then
        if ! sql "$i" "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF; SET SESSION sql_log_bin=0; $statement SET GLOBAL super_read_only=ON;" > /dev/null 2> "$TEMP/account_error"; then
            sql "$i" 'SET GLOBAL super_read_only=ON;' || :
            die "Node $i account setup failed; inspect account existence/password policy/grants. Secret SQL omitted."
        fi
    else
        if ! sql "$i" "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF; SET SESSION sql_log_bin=0; $statement SET GLOBAL super_read_only=ON;"; then
            sql "$i" 'SET GLOBAL super_read_only=ON;' || :
            die "Node $i local operation failed"
        fi
    fi
    rm -f "$TEMP/unfenced/$i"
)
endpoints_check() (
    for i in $(ids); do
        x=$(get "$i" xcom); xp=${x##*:}; h=$(get "$i" advertise)
        if command -v getent >/dev/null 2>&1; then
            resolved=$(getent ahostsv4 "$h" | awk '{print $1}' | sort -u)
            [ -n "$resolved" ] || die "Cannot resolve advertised host $h"
        else resolved=$h; fi
        for j in $(ids); do
            same=no
            if [ "$(get "$i" location)" = local ] && [ "$(get "$j" location)" = local ]; then same=yes; fi
            if [ "$h" = "$(get "$j" advertise)" ]; then same=yes; fi
            if command -v getent >/dev/null 2>&1; then
                other=$(getent ahostsv4 "$(get "$j" advertise)" | awk '{print $1}' | sort -u)
                for ip in $resolved; do
                    if printf '%s\n' "$other" | grep -Fx "$ip" >/dev/null; then same=yes; fi
                done
            fi
            [ "$same" = yes ] || continue
            [ "$xp" != "$(get "$j" sql_port)" ] || die "Node $i XCom port conflicts with node $j SQL port"
            if [ "$i" != "$j" ]; then
                xj=$(get "$j" xcom)
                [ "$xp" != "${xj##*:}" ] || die "Nodes $i/$j share an XCom port on the same host"
                [ "$(get "$i" sql_port)" != "$(get "$j" sql_port)" ] || die "Nodes $i/$j share an SQL endpoint"
            fi
            if hasvar "$j" mysqlx_port; then
                [ "$xp" != "$(val "$j" mysqlx_port)" ] || die "Node $i XCom conflicts with node $j X Protocol"
            fi
        done
        if [ "$(get "$i" location)" = local ] && command -v ss >/dev/null 2>&1; then
            busy=$(ss -H -ltn "sport = :$xp")
            [ -z "$busy" ] || die "Node $i XCom port $xp is already listening"
        fi
    done
)
prepare_discovery() (
    # Only registration metadata may be retried automatically, under the main lock.
    [ ! -e "$ROOT/meta/complete" ] || die 'Registration already completed. Continue with configure/precheck, or use a different MYSQL_GR_WORK_ROOT.'
    for marker in mutation_started initialized frozen_gtid bootstrap_attempted joined validated; do
        [ ! -e "$ROOT/meta/$marker" ] || die "Existing migration progress ($marker) found. Refusing to reset registration; inspect the existing project."
    done
    partial=no
    [ ! -e "$ROOT/meta" ] || partial=yes
    for node in "$ROOT"/[0-9]*; do
        [ -e "$node" ] || [ -L "$node" ] || continue
        [ -d "$node" ] && [ ! -L "$node" ] || die 'Unexpected node state path; inspect manually.'
        partial=yes
        for marker in initialized async_stopped before_read_only before_super_read_only before_event_scheduler; do
            [ ! -e "$node/$marker" ] || die 'Existing node migration progress found; registration must not be reset.'
        done
    done
    [ "$partial" = yes ] || exit 0
    [ ! -L "$ROOT/meta" ] || die 'Metadata directory must not be a symlink.'
    backup="$ROOT/discovery_backups/$(date +%Y%m%d_%H%M%S)_$$"
    mkdir -p "$ROOT/discovery_backups"
    mkdir "$backup" || die 'Cannot create a unique registration backup.'
    # Rename the original directories into the backup; no metadata is deleted.
    [ ! -e "$ROOT/meta" ] || mv "$ROOT/meta" "$backup/meta"
    for node in "$ROOT"/[0-9]*; do
        [ -d "$node" ] || continue
        mv "$node" "$backup/"
    done
    log "Incomplete registration backed up: $backup"
    log 'Starting registration again. Previous inputs must be entered again; no database changes are made by discover.'
)
# ... CONTENT CONTINUES IDENTICALLY TO VERIFIED SERVER FILE ...
