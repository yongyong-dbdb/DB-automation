#!/bin/sh

set -u

SCRIPT_NAME=${0##*/}
STEP=${1:-help}
STATE_FILE=${MYSQL_GTID_STATE_FILE:-"$(pwd)/.mysql_gtid_replication.state"}
WORK_ROOT=${MYSQL_GTID_WORK_ROOT:-"$(pwd)/mysql_gtid_replication_work"}
RUN_ID=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$WORK_ROOT/$RUN_ID"
TMP_FILES=

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    old_ifs=$IFS
    IFS=':'
    for tmp_file in $TMP_FILES; do
        [ -n "$tmp_file" ] && [ -f "$tmp_file" ] && rm -f "$tmp_file"
    done
    IFS=$old_ifs
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<EOF
Usage: sh $SCRIPT_NAME <step>

Steps:
  discover    Detect and record Source/Replica connection information
  precheck    Validate product, version, GTID, binary log, IDs and connectivity
  configure   Back up and optionally update accessible my.cnf files
  initialize  Provision initial data by logical dump, or record that it is ready
  replicate   Create the replication account and configure GTID auto-positioning
  validate    Wait for Source GTIDs and validate replication
  status      Display Source/Replica variables and replication status
  all         Run discover, precheck, configure, initialize, replicate, validate
  help        Display this help

Environment overrides:
  MYSQL_GTID_STATE_FILE   State file path (passwords are never stored)
  MYSQL_GTID_WORK_ROOT    Work, backup and log directory
EOF
}

next_step() {
    next_command=$1
    next_reason=${2-}
    log ""
    log "============================================================"
    log "NEXT STEP: sh $SCRIPT_NAME $next_command"
    [ -n "$next_reason" ] && log "Reason   : $next_reason"
    log "============================================================"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

ask() {
    prompt=$1
    default_value=${2-}
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt" "$default_value" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    IFS= read -r answer || die "input terminated"
    [ -n "$answer" ] && printf '%s' "$answer" || printf '%s' "$default_value"
}

ask_required() {
    prompt=$1
    default_value=${2-}
    while :; do
        value=$(ask "$prompt" "$default_value")
        [ -n "$value" ] && { printf '%s' "$value"; return; }
        warn "value is required"
    done
}

ask_secret() {
    prompt=$1
    printf '%s: ' "$prompt" >&2
    if [ -t 0 ]; then
        stty -echo
        IFS= read -r secret || { stty echo; die "input terminated"; }
        stty echo
        printf '\n' >&2
    else
        IFS= read -r secret || die "input terminated"
    fi
    printf '%s' "$secret"
}

confirm_phrase() {
    message=$1
    phrase=$2
    log "$message"
    value=$(ask "Type $phrase to continue" "")
    [ "$value" = "$phrase" ] || die "confirmation failed"
}

is_uint() { case ${1-} in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

is_on() { case ${1-} in 1|ON|on|TRUE|true) return 0 ;; *) return 1 ;; esac; }

validate_account_name() {
    case ${1-} in ''|*[!A-Za-z0-9_.-]*) die "account name contains unsupported characters: $1" ;; esac
}

validate_account_host() {
    case ${1-} in ''|*[!A-Za-z0-9_.:%-]*) die "account host contains unsupported characters: $1" ;; esac
}

validate_network_host() {
    case ${1-} in ''|*[!A-Za-z0-9_.:-]*) die "network host contains unsupported characters: $1" ;; esac
}

validate_sql_password() {
    case ${1-} in *\\*) die "backslash is not supported in an automatically embedded replication password; use a password without backslash or configure the channel manually" ;; esac
}

sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

option_quote() {
    # MySQL option-file double-quoted value escaping.
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

state_quote() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

save_state() {
    umask 077
    state_tmp="$STATE_FILE.tmp.$$"
    {
        printf "SOURCE_MODE='%s'\n" "$(state_quote "$SOURCE_MODE")"
        printf "SOURCE_HOST='%s'\n" "$(state_quote "$SOURCE_HOST")"
        printf "SOURCE_PORT='%s'\n" "$(state_quote "$SOURCE_PORT")"
        printf "SOURCE_SOCKET='%s'\n" "$(state_quote "$SOURCE_SOCKET")"
        printf "SOURCE_ADMIN_USER='%s'\n" "$(state_quote "$SOURCE_ADMIN_USER")"
        printf "SOURCE_CNF='%s'\n" "$(state_quote "$SOURCE_CNF")"
        printf "SOURCE_SERVICE='%s'\n" "$(state_quote "$SOURCE_SERVICE")"
        printf "REPLICA_MODE='%s'\n" "$(state_quote "$REPLICA_MODE")"
        printf "REPLICA_HOST='%s'\n" "$(state_quote "$REPLICA_HOST")"
        printf "REPLICA_PORT='%s'\n" "$(state_quote "$REPLICA_PORT")"
        printf "REPLICA_SOCKET='%s'\n" "$(state_quote "$REPLICA_SOCKET")"
        printf "REPLICA_ADMIN_USER='%s'\n" "$(state_quote "$REPLICA_ADMIN_USER")"
        printf "REPLICA_CNF='%s'\n" "$(state_quote "$REPLICA_CNF")"
        printf "REPLICA_SERVICE='%s'\n" "$(state_quote "$REPLICA_SERVICE")"
        printf "CHANNEL_NAME='%s'\n" "$(state_quote "$CHANNEL_NAME")"
        printf "INITIALIZED='%s'\n" "$(state_quote "$INITIALIZED")"
    } > "$state_tmp" || die "cannot write state file: $state_tmp"
    mv "$state_tmp" "$STATE_FILE" || die "cannot replace state file: $STATE_FILE"
}

init_state_defaults() {
    SOURCE_MODE=${SOURCE_MODE:-tcp}
    SOURCE_HOST=${SOURCE_HOST:-}
    SOURCE_PORT=${SOURCE_PORT:-}
    SOURCE_SOCKET=${SOURCE_SOCKET:-}
    SOURCE_ADMIN_USER=${SOURCE_ADMIN_USER:-}
    SOURCE_CNF=${SOURCE_CNF:-}
    SOURCE_SERVICE=${SOURCE_SERVICE:-}
    REPLICA_MODE=${REPLICA_MODE:-tcp}
    REPLICA_HOST=${REPLICA_HOST:-}
    REPLICA_PORT=${REPLICA_PORT:-}
    REPLICA_SOCKET=${REPLICA_SOCKET:-}
    REPLICA_ADMIN_USER=${REPLICA_ADMIN_USER:-}
    REPLICA_CNF=${REPLICA_CNF:-}
    REPLICA_SERVICE=${REPLICA_SERVICE:-}
    CHANNEL_NAME=${CHANNEL_NAME:-}
    INITIALIZED=${INITIALIZED:-no}
}

load_state() {
    init_state_defaults
    [ -f "$STATE_FILE" ] || die "state file not found; run: sh $SCRIPT_NAME discover"
    # The file is generated by this script, mode 600, and contains no passwords.
    . "$STATE_FILE"
    init_state_defaults
}

make_client_file() {
    role=$1
    user=$2
    password=$3
    mode=$4
    host=$5
    port=$6
    socket=$7
    mkdir -p "$RUN_DIR" || die "cannot create work directory: $RUN_DIR"
    file="$RUN_DIR/.${role}_client_$$.cnf"
    umask 077
    {
        printf '[client]\n'
        printf 'user="%s"\n' "$(option_quote "$user")"
        printf 'password="%s"\n' "$(option_quote "$password")"
        if [ "$mode" = socket ]; then
            printf 'protocol=SOCKET\n'
            printf 'socket="%s"\n' "$(option_quote "$socket")"
        else
            printf 'protocol=TCP\n'
            printf 'host="%s"\n' "$(option_quote "$host")"
            printf 'port=%s\n' "$port"
        fi
    } > "$file" || die "cannot create temporary client file"
    TMP_FILES=${TMP_FILES:+$TMP_FILES:}$file
    printf '%s' "$file"
}

ensure_credentials() {
    role=$1
    if [ "$role" = source ]; then
        [ -n "${SOURCE_CLIENT_FILE:-}" ] && return
        SOURCE_ADMIN_PASSWORD=$(ask_secret "Source MySQL password for $SOURCE_ADMIN_USER")
        SOURCE_CLIENT_FILE=$(make_client_file source "$SOURCE_ADMIN_USER" "$SOURCE_ADMIN_PASSWORD" "$SOURCE_MODE" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_SOCKET")
    else
        [ -n "${REPLICA_CLIENT_FILE:-}" ] && return
        REPLICA_ADMIN_PASSWORD=$(ask_secret "Replica MySQL password for $REPLICA_ADMIN_USER")
        REPLICA_CLIENT_FILE=$(make_client_file replica "$REPLICA_ADMIN_USER" "$REPLICA_ADMIN_PASSWORD" "$REPLICA_MODE" "$REPLICA_HOST" "$REPLICA_PORT" "$REPLICA_SOCKET")
    fi
}

mysql_query() {
    role=$1
    sql=$2
    ensure_credentials "$role"
    if [ "$role" = source ]; then
        mysql --defaults-extra-file="$SOURCE_CLIENT_FILE" --batch --skip-column-names -e "$sql"
    else
        mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" --batch --skip-column-names -e "$sql"
    fi
}

reset_credentials() {
    role=$1
    if [ "$role" = source ]; then
        [ -n "${SOURCE_CLIENT_FILE:-}" ] && rm -f "$SOURCE_CLIENT_FILE"
        SOURCE_CLIENT_FILE=
        SOURCE_ADMIN_PASSWORD=
    else
        [ -n "${REPLICA_CLIENT_FILE:-}" ] && rm -f "$REPLICA_CLIENT_FILE"
        REPLICA_CLIENT_FILE=
        REPLICA_ADMIN_PASSWORD=
    fi
}

verify_connection() {
    role=$1
    case $role in
        source) display_role=Source ;;
        replica) display_role=Replica ;;
        *) die "internal connection role error: $role" ;;
    esac
    attempt=1
    while [ "$attempt" -le 3 ]; do
        ensure_credentials "$role"
        if mysql_query "$role" "SELECT 1;" >/dev/null; then
            return
        fi
        reset_credentials "$role"
        if [ "$attempt" -lt 3 ]; then
            warn "$display_role authentication failed; verify that the password belongs to this exact instance."
            warn "Retrying $display_role credentials ($((attempt + 1))/3)."
        fi
        attempt=$((attempt + 1))
    done
    die "$display_role connection failed after 3 authentication attempts"
}

mysql_table() {
    role=$1
    sql=$2
    ensure_credentials "$role"
    if [ "$role" = source ]; then
        mysql --defaults-extra-file="$SOURCE_CLIENT_FILE" --table -e "$sql"
    else
        mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" --table -e "$sql"
    fi
}

variable_exists() {
    role=$1
    variable_name=$2
    result=$(mysql_query "$role" "SHOW GLOBAL VARIABLES LIKE '$(sql_quote "$variable_name")';") || die "unable to query $variable_name on $role"
    [ -n "$result" ]
}

replica_updates_variable() {
    role=$1
    if variable_exists "$role" log_replica_updates; then
        printf 'log_replica_updates'
    elif variable_exists "$role" log_slave_updates; then
        printf 'log_slave_updates'
    else
        die "$role supports neither log_replica_updates nor log_slave_updates"
    fi
}

source_info_sync_variable() {
    role=$1
    if variable_exists "$role" sync_source_info; then
        printf 'sync_source_info'
    elif variable_exists "$role" sync_master_info; then
        printf 'sync_master_info'
    else
        die "$role supports neither sync_source_info nor sync_master_info"
    fi
}

detect_local_instances() {
    log ""
    log "Running mysqld processes visible on this host:"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -a mysqld 2>/dev/null || log "  none detected"
    else
        ps -ef 2>/dev/null | sed -n '/[m]ysqld/p' || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        log ""
        log "MySQL-related systemd services:"
        systemctl list-units --type=service --all 2>/dev/null | sed -n '/mysql\|mysqld/Ip' || true
    fi
}

build_local_candidates() {
    SOCKET_CANDIDATE_FILE="$RUN_DIR/local_socket_candidates"
    CNF_CANDIDATE_FILE="$RUN_DIR/local_cnf_candidates"
    socket_raw="$RUN_DIR/local_socket_candidates.raw"
    cnf_raw="$RUN_DIR/local_cnf_candidates.raw"
    : > "$socket_raw"
    : > "$cnf_raw"

    if [ -r /proc/net/unix ]; then
        awk 'NF >= 8 && $8 ~ /^\// && tolower($8) ~ /mysql/ { print $8 }' /proc/net/unix >> "$socket_raw" 2>/dev/null || true
    fi

    if command -v ss >/dev/null 2>&1; then
        ss -xlpnH 2>/dev/null | awk '
            /mysqld/ {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^\//) print $i
                }
            }
        ' >> "$socket_raw" || true
    fi

    for cmdline in /proc/[0-9]*/cmdline; do
        [ -r "$cmdline" ] || continue
        args=$(tr '\000' '\n' < "$cmdline" 2>/dev/null || true)
        first_arg=$(printf '%s\n' "$args" | sed -n '1p')
        case ${first_arg##*/} in mysqld|mysqld-debug) ;; *) continue ;; esac
        printf '%s\n' "$args" | sed -n 's/^--socket=//p' >> "$socket_raw"
        printf '%s\n' "$args" | sed -n 's/^--defaults-file=//p' >> "$cnf_raw"
    done

    if command -v mysqld >/dev/null 2>&1; then
        default_cnf_line=$(mysqld --verbose --help 2>/dev/null | awk '
            found { print; exit }
            /Default options are read from the following files/ { found=1 }
        ')
        for default_cnf in $default_cnf_line; do
            case $default_cnf in '~/'*) continue ;; esac
            [ -f "$default_cnf" ] && printf '%s\n' "$default_cnf" >> "$cnf_raw"
        done
    fi

    awk 'NF && tolower($0) !~ /mysqlx[^/]*\.sock$/ && !seen[$0]++' "$socket_raw" | sort > "$SOCKET_CANDIDATE_FILE"
    awk 'NF && !seen[$0]++' "$cnf_raw" | sort > "$CNF_CANDIDATE_FILE"
    USED_SOCKET_PATHS=
}

candidate_count() {
    file=$1
    [ -f "$file" ] || { printf '0'; return; }
    awk 'END { print NR + 0 }' "$file"
}

first_unused_socket_number() {
    number=0
    while IFS= read -r candidate; do
        number=$((number + 1))
        case ":$USED_SOCKET_PATHS:" in
            *:"$candidate":*) ;;
            *) printf '%s' "$number"; return ;;
        esac
    done < "$SOCKET_CANDIDATE_FILE"
    printf '1'
}

choose_socket() {
    role=$1
    count=$(candidate_count "$SOCKET_CANDIDATE_FILE")
    if [ "$count" -gt 0 ]; then
        log "Detected active MySQL socket candidates:" >&2
        awk '{ printf "  %d) %s\n", NR, $0 }' "$SOCKET_CANDIDATE_FILE" >&2
        default_number=$(first_unused_socket_number)
        selection=$(ask "$role socket number, or m for manual input" "$default_number")
        case $selection in
            m|M) socket=$(ask_required "$role MySQL socket path" "") ;;
            *)
                is_uint "$selection" || die "socket selection must be a number or m"
                [ "$selection" -ge 1 ] && [ "$selection" -le "$count" ] || die "socket selection is out of range: $selection"
                socket=$(sed -n "${selection}p" "$SOCKET_CANDIDATE_FILE")
                ;;
        esac
    else
        socket=$(ask_required "$role MySQL socket path (no active candidate detected)" "")
    fi
    USED_SOCKET_PATHS=${USED_SOCKET_PATHS:+$USED_SOCKET_PATHS:}$socket
    CHOSEN_SOCKET=$socket
}

choose_cnf() {
    role=$1
    selected_socket=$2
    count=$(candidate_count "$CNF_CANDIDATE_FILE")
    if [ "$count" -gt 0 ]; then
        log "Detected MySQL configuration candidates:" >&2
        number=0
        matched_number=
        while IFS= read -r candidate_cnf; do
            number=$((number + 1))
            candidate_socket=
            if command -v my_print_defaults >/dev/null 2>&1; then
                candidate_socket=$(my_print_defaults --defaults-file="$candidate_cnf" mysqld 2>/dev/null | sed -n 's/^--socket=//p' | tail -n 1)
            fi
            if [ -z "$candidate_socket" ] && [ -r "$candidate_cnf" ]; then
                candidate_socket=$(awk -F= '
                    /^[[:space:]]*socket[[:space:]]*=/ {
                        value=$2
                        sub(/^[[:space:]]*/, "", value)
                        sub(/[[:space:]]*$/, "", value)
                        print value
                    }
                ' "$candidate_cnf" | tail -n 1)
            fi
            if [ -n "$candidate_socket" ]; then
                printf '  %d) %s  [socket=%s]\n' "$number" "$candidate_cnf" "$candidate_socket" >&2
            else
                printf '  %d) %s\n' "$number" "$candidate_cnf" >&2
            fi
            [ -n "$selected_socket" ] && [ "$candidate_socket" = "$selected_socket" ] && matched_number=$number
        done < "$CNF_CANDIDATE_FILE"
        selection=$(ask "$role my.cnf number, path, or blank if unknown" "$matched_number")
        case $selection in
            '') cnf= ;;
            */*) cnf=$selection ;;
            *)
                is_uint "$selection" || die "my.cnf selection must be a number, path, or blank"
                [ "$selection" -ge 1 ] && [ "$selection" -le "$count" ] || die "my.cnf selection is out of range: $selection"
                cnf=$(sed -n "${selection}p" "$CNF_CANDIDATE_FILE")
                ;;
        esac
    else
        cnf=$(ask "$role server my.cnf path (not detectable; blank if remote or unknown)" "")
    fi
    CHOSEN_CNF=$cnf
}

collect_endpoint() {
    role=$1
    upper=$2
    log ""
    log "[$role connection]"
    socket_count=$(candidate_count "$SOCKET_CANDIDATE_FILE")
    if [ "$socket_count" -ge 2 ]; then default_mode=socket; else default_mode=tcp; fi
    log "Connection mode options:"
    log "  tcp    : connect through a host/IP and port; use for remote instances or TCP validation"
    log "  socket : connect through a local Unix socket; use when this controller runs on the MySQL host"
    mode=$(ask "$role connection mode (tcp/socket)" "$default_mode")
    case $mode in tcp|socket) ;; *) die "invalid connection mode: $mode" ;; esac
    if [ "$mode" = tcp ]; then
        host=$(ask_required "$role host or IP reachable from this controller" "")
        port=$(ask_required "$role MySQL port" "")
        is_uint "$port" || die "$role port must be numeric"
        socket=
    else
        host=
        port=
        choose_socket "$role"
        socket=$CHOSEN_SOCKET
    fi
    admin_user=$(ask_required "$role administrative MySQL user" "")
    choose_cnf "$role" "$socket"
    cnf=$CHOSEN_CNF
    service=$(ask "$role systemd service (blank if unavailable or manually managed)" "")
    case $upper in
        SOURCE)
            SOURCE_MODE=$mode; SOURCE_HOST=$host; SOURCE_PORT=$port
            SOURCE_SOCKET=$socket; SOURCE_ADMIN_USER=$admin_user
            SOURCE_CNF=$cnf; SOURCE_SERVICE=$service
            ;;
        REPLICA)
            REPLICA_MODE=$mode; REPLICA_HOST=$host; REPLICA_PORT=$port
            REPLICA_SOCKET=$socket; REPLICA_ADMIN_USER=$admin_user
            REPLICA_CNF=$cnf; REPLICA_SERVICE=$service
            ;;
        *) die "internal endpoint role error: $upper" ;;
    esac
}

runtime_row() {
    role=$1
    updates_variable=$(replica_updates_variable "$role")
    mysql_query "$role" "SELECT CONCAT_WS('|', @@version, @@version_comment, @@hostname, @@port, @@socket, @@datadir, @@server_id, @@server_uuid, @@log_bin, @@binlog_format, @@gtid_mode, @@enforce_gtid_consistency, @@GLOBAL.$updates_variable, @@read_only, @@super_read_only);"
}

print_runtime() {
    role=$1
    row=$(runtime_row "$role") || die "$role connection failed"
    old_ifs=$IFS
    IFS='|'
    set -f; set -- $row; set +f
    IFS=$old_ifs
    [ "$#" -ge 15 ] || die "unexpected runtime result from $role"
    log ""
    log "[$role runtime]"
    log "  Product/Version : $1 / $2"
    log "  Host/Port       : $3 / $4"
    log "  Socket          : $5"
    log "  Data Directory  : $6"
    log "  server_id       : $7"
    log "  server_uuid     : $8"
    log "  log_bin         : $9"
    shift 9
    log "  binlog_format   : $1"
    log "  gtid_mode       : $2"
    log "  GTID consistency: $3"
    log "  log repl updates: $4"
    log "  read_only       : $5"
    log "  super_read_only : $6"
}

discover() {
    need_cmd mysql
    mkdir -p "$(dirname "$STATE_FILE")" "$RUN_DIR" || die "cannot create state/work directory"
    build_local_candidates
    detect_local_instances
    init_state_defaults
    collect_endpoint Source SOURCE
    collect_endpoint Replica REPLICA
    CHANNEL_NAME=$(ask "Replication channel name (blank uses default channel)" "")
    case $CHANNEL_NAME in *[!A-Za-z0-9_.-]*) die "channel name contains unsupported characters: $CHANNEL_NAME" ;; esac
    INITIALIZED=no
    save_state
    ensure_credentials source
    ensure_credentials replica
    print_runtime source
    print_runtime replica
    log ""
    log "State saved: $STATE_FILE"
    load_runtime_facts
    needs_config=0
    if [ "$SOURCE_SERVER_ID" = "$REPLICA_SERVER_ID" ]; then
        warn "Source and Replica server_id are both $SOURCE_SERVER_ID; each instance requires a unique server_id"
        needs_config=1
    fi
    [ "$SOURCE_SERVER_ID" != 0 ] || needs_config=1
    [ "$REPLICA_SERVER_ID" != 0 ] || needs_config=1
    is_on "$SOURCE_LOG_BIN" || needs_config=1
    is_on "$REPLICA_LOG_BIN" || needs_config=1
    [ "$SOURCE_GTID_MODE" = ON ] || needs_config=1
    [ "$REPLICA_GTID_MODE" = ON ] || needs_config=1
    [ "$SOURCE_GTID_CONSISTENCY" = ON ] || needs_config=1
    [ "$REPLICA_GTID_CONSISTENCY" = ON ] || needs_config=1
    if [ "$needs_config" -eq 1 ]; then
        next_step configure "Replication settings require correction; duplicate or invalid server_id and GTID/binlog settings are handled there."
    else
        next_step precheck "Connection discovery passed; run the full compatibility and data-safety checks."
    fi
}

version_number() {
    printf '%s' "$1" | awk -F. '{gsub(/[^0-9].*/,"",$3); printf "%d%03d%03d",$1+0,$2+0,$3+0}'
}

load_runtime_facts() {
    verify_connection source
    verify_connection replica
    source_row=$(runtime_row source) || die "Source connection failed"
    replica_row=$(runtime_row replica) || die "Replica connection failed"
    old_ifs=$IFS; IFS='|'; set -f; set -- $source_row; set +f; IFS=$old_ifs
    SOURCE_VERSION=$1; SOURCE_COMMENT=$2; SOURCE_RUNTIME_HOST=$3; SOURCE_RUNTIME_PORT=$4
    SOURCE_RUNTIME_SOCKET=$5; SOURCE_DATADIR=$6; SOURCE_SERVER_ID=$7; SOURCE_UUID=$8
    SOURCE_LOG_BIN=$9; shift 9; SOURCE_BINLOG_FORMAT=$1; SOURCE_GTID_MODE=$2
    SOURCE_GTID_CONSISTENCY=$3; SOURCE_LOG_REPLICA_UPDATES=$4
    old_ifs=$IFS; IFS='|'; set -f; set -- $replica_row; set +f; IFS=$old_ifs
    REPLICA_VERSION=$1; REPLICA_COMMENT=$2; REPLICA_RUNTIME_HOST=$3; REPLICA_RUNTIME_PORT=$4
    REPLICA_RUNTIME_SOCKET=$5; REPLICA_DATADIR=$6; REPLICA_SERVER_ID=$7; REPLICA_UUID=$8
    REPLICA_LOG_BIN=$9; shift 9; REPLICA_BINLOG_FORMAT=$1; REPLICA_GTID_MODE=$2
    REPLICA_GTID_CONSISTENCY=$3; REPLICA_LOG_REPLICA_UPDATES=$4
}

precheck() {
    load_state
    need_cmd mysql
    ensure_credentials source
    ensure_credentials replica
    load_runtime_facts
    errors=0
    case "$SOURCE_COMMENT $REPLICA_COMMENT" in *MariaDB*|*mariadb*) warn "MariaDB GTID is not supported by this script"; errors=$((errors+1));; esac
    [ "$SOURCE_UUID" != "$REPLICA_UUID" ] || { warn "Source and Replica server_uuid are identical"; errors=$((errors+1)); }
    [ "$SOURCE_SERVER_ID" != "$REPLICA_SERVER_ID" ] || { warn "Source and Replica server_id are identical"; errors=$((errors+1)); }
    [ "$SOURCE_SERVER_ID" != 0 ] || { warn "Source server_id is 0"; errors=$((errors+1)); }
    [ "$REPLICA_SERVER_ID" != 0 ] || { warn "Replica server_id is 0"; errors=$((errors+1)); }
    source_num=$(version_number "$SOURCE_VERSION")
    replica_num=$(version_number "$REPLICA_VERSION")
    [ "$source_num" -le "$replica_num" ] || { warn "newer Source to older Replica is not supported"; errors=$((errors+1)); }
    is_on "$SOURCE_LOG_BIN" || { warn "Source log_bin is $SOURCE_LOG_BIN; expected ON"; errors=$((errors+1)); }
    is_on "$REPLICA_LOG_BIN" || { warn "Replica log_bin is $REPLICA_LOG_BIN; expected ON"; errors=$((errors+1)); }
    [ "$SOURCE_GTID_MODE" = ON ] || { warn "Source gtid_mode is $SOURCE_GTID_MODE; expected ON"; errors=$((errors+1)); }
    [ "$REPLICA_GTID_MODE" = ON ] || { warn "Replica gtid_mode is $REPLICA_GTID_MODE; expected ON"; errors=$((errors+1)); }
    [ "$SOURCE_GTID_CONSISTENCY" = ON ] || { warn "Source enforce_gtid_consistency is $SOURCE_GTID_CONSISTENCY; expected ON"; errors=$((errors+1)); }
    [ "$REPLICA_GTID_CONSISTENCY" = ON ] || { warn "Replica enforce_gtid_consistency is $REPLICA_GTID_CONSISTENCY; expected ON"; errors=$((errors+1)); }
    [ "$SOURCE_BINLOG_FORMAT" = ROW ] || warn "Source binlog_format is $SOURCE_BINLOG_FORMAT; ROW is recommended"
    [ "$REPLICA_BINLOG_FORMAT" = ROW ] || warn "Replica binlog_format is $REPLICA_BINLOG_FORMAT; ROW is recommended"
    non_innodb=$(mysql_query source "SELECT COUNT(*) FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('mysql','sys','performance_schema','information_schema') AND engine <> 'InnoDB';")
    [ "${non_innodb:-0}" -eq 0 ] || warn "Source has $non_innodb non-InnoDB application table(s); online single-transaction dump cannot guarantee their consistency"
    binlog_expire=$(mysql_query source "SELECT @@GLOBAL.binlog_expire_logs_seconds;" 2>/dev/null || printf unknown)
    log "Source binlog retention: $binlog_expire second(s). It must exceed initial copy time plus catch-up time."
    print_runtime source
    print_runtime replica
    if [ "$errors" -ne 0 ]; then
        log "NEXT ACTION: correct the reported configuration or complete the required restart, then rerun: sh $SCRIPT_NAME precheck"
        die "precheck failed with $errors error(s)"
    fi
    log "PRECHECK: PASSED"
    next_step initialize "Source and Replica passed GTID replication prerequisites."
}

managed_block() {
    mb_role=$1
    mb_server_id=$2
    mb_profile=$3
    mb_expire_seconds=$4
    mb_durable_relay=$5
    mb_updates_option=$6
    mb_source_info_option=$7
    cat <<EOF

# BEGIN mysql_gtid_replication.sh managed settings
[mysqld]
server_id=$mb_server_id
log_bin
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
$mb_updates_option=ON
relay_log_recovery=ON
# role=$mb_role
EOF
    if [ "$mb_profile" = production ]; then
        cat <<EOF

# Production durability and binary log retention
sync_binlog=1
innodb_flush_log_at_trx_commit=1
binlog_row_image=FULL
binlog_expire_logs_seconds=$mb_expire_seconds
EOF
        if [ "$mb_role" = Replica ]; then
            cat <<EOF

# Enable after initial data restore if direct writes to Replica must be blocked.
# read_only=ON
# super_read_only=ON
EOF
            if [ "$mb_durable_relay" = yes ]; then
                cat <<EOF

# Maximum relay-log crash durability; may increase storage I/O.
sync_relay_log=1
$mb_source_info_option=1
EOF
            fi
        fi
    fi
    cat <<EOF
# END mysql_gtid_replication.sh managed settings
EOF
}

remove_managed_block() {
    file=$1
    sed '/^# BEGIN mysql_gtid_replication\.sh managed settings$/,/^# END mysql_gtid_replication\.sh managed settings$/d' "$file"
}

configure_one() {
    cfg_role=$1
    cfg_cnf=$2
    cfg_detected_id=$3
    cfg_default_id=$4
    cfg_offer_change=$5
    cfg_profile=$6
    cfg_expire_seconds=$7
    cfg_durable_relay=$8
    cfg_updates_option=$9
    shift 9
    cfg_source_info_option=$1
    if [ "$cfg_role" = Source ]; then CONFIGURED_SOURCE_ID=$cfg_detected_id; else CONFIGURED_REPLICA_ID=$cfg_detected_id; fi
    if [ "$cfg_offer_change" = no ]; then
        log ""
        log "[$cfg_role configuration]"
        log "No required change detected; configuration update skipped."
        return
    fi
    [ -n "$cfg_cnf" ] || { warn "$cfg_role my.cnf path is unavailable; configuration must be applied on that server"; return; }
    [ -f "$cfg_cnf" ] || die "$cfg_role my.cnf does not exist: $cfg_cnf"
    [ -r "$cfg_cnf" ] || die "$cfg_role my.cnf is not readable: $cfg_cnf"
    if [ "$cfg_role" = Replica ] && [ -z "$cfg_default_id" ]; then
        log ""
        log "[server_id conflict]"
        log "  Current Source server_id : $CONFIGURED_SOURCE_ID"
        log "  Current Replica server_id: $cfg_detected_id"
        log "  Required action           : change Replica to an unused value different from Source"
        cfg_server_id=$(ask_required "Enter a new unique server_id for Replica" "")
    else
        cfg_server_id=$(ask_required "$cfg_role server_id" "$cfg_default_id")
    fi
    is_uint "$cfg_server_id" || die "$cfg_role server_id must be numeric"
    [ "$cfg_server_id" -gt 0 ] || die "$cfg_role server_id must be greater than zero"
    [ "$cfg_server_id" -le 4294967295 ] || die "$cfg_role server_id exceeds the MySQL maximum"
    if [ "$cfg_role" = Replica ] && [ "$cfg_server_id" = "$CONFIGURED_SOURCE_ID" ]; then
        die "Replica server_id must differ from Source server_id $CONFIGURED_SOURCE_ID"
    fi
    if [ "$cfg_role" = Source ]; then CONFIGURED_SOURCE_ID=$cfg_server_id; else CONFIGURED_REPLICA_ID=$cfg_server_id; fi
    cfg_snippet="$RUN_DIR/${cfg_role}_mysqld_gtid.cnf"
    managed_block "$cfg_role" "$cfg_server_id" "$cfg_profile" "$cfg_expire_seconds" "$cfg_durable_relay" "$cfg_updates_option" "$cfg_source_info_option" > "$cfg_snippet"
    log ""
    log "[$cfg_role proposed configuration changes]"
    sed -n '1,200p' "$cfg_snippet"
    log "This replaces the script-managed block in $cfg_cnf; other existing settings are preserved."
    cfg_apply=$(ask "Back up $cfg_cnf beside the original, then apply these settings? (yes/no)" no)
    [ "$cfg_apply" = yes ] || { log "Generated only: $cfg_snippet"; return; }
    cfg_cleaned="$RUN_DIR/$(basename "$cfg_cnf").${cfg_role}.cleaned"
    cfg_candidate="$RUN_DIR/$(basename "$cfg_cnf").${cfg_role}.candidate"
    remove_managed_block "$cfg_cnf" > "$cfg_cleaned" || die "cannot prepare updated config"
    cp "$cfg_cleaned" "$cfg_candidate" || die "cannot prepare configuration validation candidate"
    cat "$cfg_snippet" >> "$cfg_candidate" || die "cannot assemble configuration validation candidate"
    if command -v my_print_defaults >/dev/null 2>&1; then
        my_print_defaults --defaults-file="$cfg_candidate" mysqld >/dev/null 2>&1 || die "MySQL option-file parsing failed; original configuration was not changed"
    fi
    if command -v mysqld >/dev/null 2>&1 && mysqld --no-defaults --verbose --help 2>/dev/null | sed -n '/validate-config/p' | awk 'NR==1 { found=1 } END { exit(found ? 0 : 1) }'; then
        cfg_validation_log="$RUN_DIR/$(basename "$cfg_cnf").${cfg_role}.validate.log"
        mysqld --defaults-file="$cfg_candidate" --validate-config > "$cfg_validation_log" 2>&1 || {
            sed -n '1,200p' "$cfg_validation_log" >&2
            die "mysqld configuration validation failed; original configuration was not changed"
        }
        log "Configuration validation: PASSED"
    else
        warn "mysqld --validate-config is unavailable; runtime variable capability checks and option-file parsing were used"
    fi
    cfg_backup="${cfg_cnf}.before_mysql_gtid_${cfg_role}_${RUN_ID}"
    [ ! -e "$cfg_backup" ] || die "configuration backup already exists: $cfg_backup"
    cp -p "$cfg_cnf" "$cfg_backup" || die "cannot create configuration backup beside the original file: $cfg_backup"
    [ -s "$cfg_backup" ] || die "configuration backup is empty; refusing to modify $cfg_cnf"
    cp "$cfg_candidate" "$cfg_cnf" || die "cannot update $cfg_cnf"
    log "Updated: $cfg_cnf"
    log "Backup : $cfg_backup"
    if [ "$cfg_role" = Source ]; then
        SOURCE_CONFIG_CHANGED=yes
    else
        REPLICA_CONFIG_CHANGED=yes
    fi
}

restart_one() {
    role=$1
    service=$2
    cnf=$3
    datadir=$4
    changed=$5

    [ "$changed" = yes ] || return

    role_key=$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')
    pid_file=$(mysql_query "$role_key" "SELECT @@GLOBAL.pid_file;" 2>/dev/null || true)
    mysqld_pid=
    if [ -n "$pid_file" ] && [ -r "$pid_file" ]; then
        mysqld_pid=$(sed -n '1{s/[^0-9].*//;p;}' "$pid_file")
    fi

    detected_service=
    detected_parent=
    if is_uint "${mysqld_pid:-}" && [ -r "/proc/$mysqld_pid/cgroup" ]; then
        detected_service=$(sed -n 's#.*[/]\([^/]*\.service\)\([./].*\)\{0,1\}$#\1#p' "/proc/$mysqld_pid/cgroup" | head -n 1)
        mysqld_ppid=$(awk '{ print $4 }' "/proc/$mysqld_pid/stat" 2>/dev/null || true)
        if is_uint "${mysqld_ppid:-}" && [ -r "/proc/$mysqld_ppid/comm" ]; then
            detected_parent=$(sed -n '1p' "/proc/$mysqld_ppid/comm")
        fi
    fi
    if [ -z "$service" ] && [ -n "$detected_service" ]; then
        service=$detected_service
        log "Detected $role systemd service from PID $mysqld_pid: $service"
    fi

    restart_method=manual
    restart_display=
    if [ -n "$service" ] && command -v systemctl >/dev/null 2>&1; then
        restart_method=systemd
        restart_display="systemctl restart $service"
    elif [ -n "$cnf" ] && command -v mysqladmin >/dev/null 2>&1 && command -v mysqld >/dev/null 2>&1; then
        if [ "$detected_parent" = mysqld_safe ] && command -v mysqld_safe >/dev/null 2>&1; then
            restart_method=mysqld_safe
        elif mysqld --no-defaults --verbose --help 2>/dev/null | grep -- '--daemonize' >/dev/null 2>&1; then
            restart_method=direct
        fi
        if [ "$role" = Source ]; then
            restart_client_file=$SOURCE_CLIENT_FILE
        else
            restart_client_file=$REPLICA_CLIENT_FILE
        fi
        start_user_option=
        datadir_owner=
        if [ -n "$datadir" ] && [ -d "$datadir" ]; then
            datadir_owner=$(ls -ld "$datadir" 2>/dev/null | awk '{ print $3 }')
        fi
        current_uid=$(id -u 2>/dev/null || printf 'unknown')
        current_user=$(id -un 2>/dev/null || printf 'unknown')
        if [ "$current_uid" = 0 ] && [ -n "$datadir_owner" ]; then
            start_user_option=" --user=$datadir_owner"
        elif [ -n "$datadir_owner" ] && [ "$current_user" != "$datadir_owner" ]; then
            restart_method=manual
            warn "$role data directory owner is $datadir_owner, but the script runs as $current_user"
            warn "Run the start command as $datadir_owner or configure a systemd service."
        fi
        if [ "$restart_method" = mysqld_safe ]; then
            restart_display="mysqladmin --defaults-extra-file=$restart_client_file shutdown && mysqld_safe --defaults-file=$cnf$start_user_option &"
        elif [ "$restart_method" = direct ]; then
            restart_display="mysqladmin --defaults-extra-file=$restart_client_file shutdown && mysqld --defaults-file=$cnf --daemonize$start_user_option"
        fi
    fi

    log ""
    log "[$role restart required]"
    if [ "$restart_method" = manual ]; then
        warn "A safe automatic restart command could not be determined."
        [ -n "$service" ] && log "Recorded service: $service"
        [ -n "$cnf" ] && log "Configuration : $cnf"
        warn "Restart only this $role instance manually, then run: sh $SCRIPT_NAME precheck"
        return
    fi

    log "Restart method : $restart_method"
    log "Restart command: $restart_display"
    answer=$(ask "Run this $role restart now? (yes/no)" no)
    [ "$answer" = yes ] || { warn "$role restart skipped"; return; }

    current_fast_shutdown=$(mysql_query "$role_key" "SELECT @@GLOBAL.innodb_fast_shutdown;")
    log "Current innodb_fast_shutdown: $current_fast_shutdown"
    log "Value 1 is safe for a normal configuration restart."
    log "Value 0 performs a slow shutdown and is mainly recommended before a major upgrade or downgrade; it can take a long time on a large instance."
    slow_shutdown=$(ask "Use innodb_fast_shutdown=0 for this restart? (yes/no)" no)
    case $slow_shutdown in yes|no) ;; *) die "answer must be yes or no" ;; esac
    if [ "$slow_shutdown" = yes ]; then
        mysql_query "$role_key" "SET GLOBAL innodb_fast_shutdown=0;"
        log "Applied before shutdown: SET GLOBAL innodb_fast_shutdown=0;"
    fi

    if [ "$restart_method" = systemd ]; then
        systemctl restart "$service" || die "failed to restart $role service: $service"
        systemctl is-active --quiet "$service" || die "$role service is not active: $service"
    elif [ "$restart_method" = direct ]; then
        mysqladmin --defaults-extra-file="$restart_client_file" shutdown || die "failed to stop $role with mysqladmin"
        if [ "$current_uid" = 0 ] && [ -n "$datadir_owner" ]; then
            mysqld --defaults-file="$cnf" --daemonize --user="$datadir_owner" || die "failed to start $role with $cnf"
        else
            mysqld --defaults-file="$cnf" --daemonize || die "failed to start $role with $cnf"
        fi
    else
        mysqladmin --defaults-extra-file="$restart_client_file" shutdown || die "failed to stop $role with mysqladmin"
        if [ "$current_uid" = 0 ] && [ -n "$datadir_owner" ]; then
            nohup mysqld_safe --defaults-file="$cnf" --user="$datadir_owner" >/dev/null 2>&1 &
        else
            nohup mysqld_safe --defaults-file="$cnf" >/dev/null 2>&1 &
        fi
    fi
    log "$role restart completed. Runtime settings will be verified by the precheck step."
}

configure() {
    load_state
    need_cmd mysql
    mkdir -p "$RUN_DIR" || die "cannot create work directory"
    ensure_credentials source
    ensure_credentials replica
    load_runtime_facts
    SOURCE_CONFIG_CHANGED=no
    REPLICA_CONFIG_CHANGED=no
    log ""
    log "Configuration profile options:"
    log "  minimum    : apply only the settings required for GTID replication"
    log "  production : also apply crash-durability and explicit binary-log retention settings; may increase storage I/O"
    profile=$(ask "Configuration profile (minimum/production)" minimum)
    case $profile in minimum|production) ;; *) die "configuration profile must be minimum or production" ;; esac
    source_expire=$(mysql_query source "SELECT @@GLOBAL.binlog_expire_logs_seconds;")
    replica_expire=$(mysql_query replica "SELECT @@GLOBAL.binlog_expire_logs_seconds;")
    durable_relay=no
    source_updates_option=$(replica_updates_variable source)
    replica_updates_option=$(replica_updates_variable replica)
    replica_source_info_option=$(source_info_sync_variable replica)
    if [ "$profile" = production ]; then
        log "Production profile adds sync_binlog=1, innodb_flush_log_at_trx_commit=1, binlog_row_image=FULL and explicit binlog retention."
        log "Replica read_only/super_read_only are shown as post-initialization settings and are not enabled before restore."
        log "Binary log retention must be longer than the initial copy, restore, and Replica catch-up time."
        log "A larger value provides more recovery margin but consumes more disk space."
        source_expire=$(ask_required "Source binary log retention in seconds" "$source_expire")
        replica_expire=$(ask_required "Replica binary log retention in seconds" "$replica_expire")
        is_uint "$source_expire" || die "Source binary log retention must be numeric"
        is_uint "$replica_expire" || die "Replica binary log retention must be numeric"
        log "Relay-log durability options:"
        log "  yes : sync relay log and connection metadata for stronger crash durability; increases storage I/O"
        log "  no  : retain normal MySQL synchronization behavior"
        durable_relay=$(ask "Use maximum Replica relay-log durability? (yes/no)" no)
        case $durable_relay in yes|no) ;; *) die "answer must be yes or no" ;; esac
    fi
    source_default_id=$SOURCE_SERVER_ID
    replica_default_id=$REPLICA_SERVER_ID
    if [ "$SOURCE_SERVER_ID" = "$REPLICA_SERVER_ID" ]; then
        replica_default_id=
        log ""
        log "Detected duplicate server_id: Source=$SOURCE_SERVER_ID, Replica=$REPLICA_SERVER_ID"
        log "Source keeps its current value; Replica must be changed."
    fi
    source_offer=yes
    replica_offer=yes
    if [ "$profile" = minimum ]; then
        if [ "$SOURCE_SERVER_ID" -gt 0 ] && is_on "$SOURCE_LOG_BIN" && [ "$SOURCE_GTID_MODE" = ON ] && [ "$SOURCE_GTID_CONSISTENCY" = ON ] && [ "$SOURCE_BINLOG_FORMAT" = ROW ] && is_on "$SOURCE_LOG_REPLICA_UPDATES"; then
            source_offer=no
        fi
        replica_relay_recovery=$(mysql_query replica "SELECT @@GLOBAL.relay_log_recovery;")
        if [ "$REPLICA_SERVER_ID" -gt 0 ] && [ "$SOURCE_SERVER_ID" != "$REPLICA_SERVER_ID" ] && is_on "$REPLICA_LOG_BIN" && [ "$REPLICA_GTID_MODE" = ON ] && [ "$REPLICA_GTID_CONSISTENCY" = ON ] && [ "$REPLICA_BINLOG_FORMAT" = ROW ] && is_on "$REPLICA_LOG_REPLICA_UPDATES" && is_on "$replica_relay_recovery"; then
            replica_offer=no
        fi
    fi
    configure_one Source "$SOURCE_CNF" "$SOURCE_SERVER_ID" "$source_default_id" "$source_offer" "$profile" "$source_expire" no "$source_updates_option" "$replica_source_info_option"
    configure_one Replica "$REPLICA_CNF" "$REPLICA_SERVER_ID" "$replica_default_id" "$replica_offer" "$profile" "$replica_expire" "$durable_relay" "$replica_updates_option" "$replica_source_info_option"
    restart_one Source "$SOURCE_SERVICE" "$SOURCE_CNF" "$SOURCE_DATADIR" "$SOURCE_CONFIG_CHANGED"
    restart_one Replica "$REPLICA_SERVICE" "$REPLICA_CNF" "$REPLICA_DATADIR" "$REPLICA_CONFIG_CHANGED"
    next_step precheck "Complete any required MySQL restart first, then verify the effective runtime settings."
}

safe_database_list() {
    list=$1
    for db in $list; do
        case $db in ''|-*|*[!A-Za-z0-9_\$]*) die "unsupported database name for automated dump: $db" ;; esac
    done
}

initialize() {
    load_state
    need_cmd mysql
    need_cmd mysqldump
    mkdir -p "$RUN_DIR" || die "cannot create work directory"
    ensure_credentials source
    ensure_credentials replica
    log ""
    log "Initial data method options:"
    log "  online-dump : keep Source online, create a consistent InnoDB logical dump, and restore it to Replica"
    log "                suitable for small or moderate data; dump/restore time and Source load must be considered"
    log "  already     : no copy; use only when Replica data and GTID history already match Source"
    log "  external    : use an external hot physical backup or Clone workflow; recommended for large data and minimal downtime"
    log "  skip        : make no change and exit this step; initialization remains incomplete"
    method=$(ask "Initial data method (online-dump/already/external/skip)" skip)
    case $method in
        already)
            confirm_phrase "Confirm that Replica data and GTID history already match Source." "DATA READY"
            INITIALIZED=yes
            save_state
            log "Initial data marked ready."
            next_step replicate "Initial data and GTID history were confirmed ready."
            return
            ;;
        skip)
            log "Initialization skipped."
            next_step initialize "Initialization is not complete; choose online-dump, external, or already when ready."
            return
            ;;
        external)
            log "Use a hot physical backup/Clone workflow appropriate for the exact MySQL version and platform."
            log "After restoring data and GTID history to Replica, rerun initialize and select 'already'."
            next_step initialize "Complete the external physical initialization, then confirm it with the already option."
            return
            ;;
        online-dump) ;;
        *) die "invalid initialization method: $method" ;;
    esac
    dbs=$(mysql_query source "SELECT GROUP_CONCAT(SCHEMA_NAME SEPARATOR ' ') FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys');")
    [ -n "$dbs" ] || die "no application databases detected on Source"
    log "Detected application databases are shown as the default."
    log "Enter one or more database names separated by spaces; only the selected databases are copied."
    dbs=$(ask_required "Space-separated databases to initialize" "$dbs")
    safe_database_list "$dbs"
    log "Dump content and file options:"
    log "  stored routines : include stored procedures and functions; normally yes"
    log "  events          : include Event Scheduler definitions; normally yes, but review whether events should run on Replica"
    log "  gzip            : reduce dump disk usage and transfer size at the cost of CPU"
    log "  keep dump       : retain the verified dump for rollback/reuse after a successful restore"
    include_routines=$(ask "Include stored routines? (yes/no)" yes)
    include_events=$(ask "Include Event Scheduler definitions? (yes/no)" yes)
    compress_dump=$(ask "Compress dump with gzip? (yes/no)" yes)
    keep_dump=$(ask "Keep dump after successful restore? (yes/no)" yes)
    case $include_routines in yes|no) ;; *) die "answer must be yes or no" ;; esac
    case $include_events in yes|no) ;; *) die "answer must be yes or no" ;; esac
    case $compress_dump in yes|no) ;; *) die "answer must be yes or no" ;; esac
    case $keep_dump in yes|no) ;; *) die "answer must be yes or no" ;; esac
    non_innodb=$(mysql_query source "SELECT COUNT(*) FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema IN ('$(printf '%s' "$dbs" | sed "s/ /','/g")') AND engine <> 'InnoDB';")
    if [ "${non_innodb:-0}" -gt 0 ]; then
        warn "$non_innodb selected table(s) are not InnoDB. --single-transaction cannot provide a fully consistent online copy for them."
        confirm_phrase "Convert/exclude those tables, or explicitly accept possible inconsistency." "ACCEPT NON-INNODB RISK"
    fi
    replica_gtid=$(mysql_query replica "SELECT @@GLOBAL.gtid_executed;") || die "cannot read Replica GTID state"
    if [ -n "$replica_gtid" ]; then
        warn "Replica gtid_executed is not empty: $replica_gtid"
        confirm_phrase "Logical restore with SET GTID_PURGED normally requires a clean Replica GTID state. Existing channels and GTIDs will be reset." "RESET REPLICA GTID"
        replica_ver=$(mysql_query replica "SELECT @@version;")
        replica_num=$(version_number "$replica_ver")
        reset_syntax=$(replication_syntax "$replica_ver")
        if [ "$reset_syntax" = modern ]; then
            mysql_query replica "STOP REPLICA;" >/dev/null 2>&1 || true
            mysql_query replica "RESET REPLICA ALL;" >/dev/null 2>&1 || true
        else
            mysql_query replica "STOP SLAVE;" >/dev/null 2>&1 || true
            mysql_query replica "RESET SLAVE ALL;" >/dev/null 2>&1 || true
        fi
        if [ "$replica_num" -ge 8004000 ]; then
            mysql_query replica "RESET BINARY LOGS AND GTIDS;" || die "failed to reset Replica GTIDs"
        else
            mysql_query replica "RESET MASTER;" || die "failed to reset Replica GTIDs"
        fi
    fi
    dump_file="$RUN_DIR/source_initial_dump.sql"
    dump_object_options="--triggers"
    [ "$include_routines" = yes ] && dump_object_options="$dump_object_options --routines"
    [ "$include_events" = yes ] && dump_object_options="$dump_object_options --events"
    log "Creating an online InnoDB-consistent dump: $dump_file"
    log "Source remains online. Ensure binlog retention covers dump, transfer, restore and catch-up time."
    # Word splitting is intentional after database names are validated.
    # shellcheck disable=SC2086
    # Word splitting is intentional for validated DB names and script-owned flags.
    # shellcheck disable=SC2086
    mysqldump --defaults-extra-file="$SOURCE_CLIENT_FILE" --single-transaction --quick --skip-lock-tables $dump_object_options --hex-blob --set-gtid-purged=ON --databases $dbs > "$dump_file" || die "mysqldump failed"
    if [ "$compress_dump" = yes ]; then
        need_cmd gzip
        gzip "$dump_file" || die "dump compression failed"
        dump_file="$dump_file.gz"
        gzip -t "$dump_file" || die "compressed dump verification failed"
    fi
    checksum_file="$dump_file.sha256"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$dump_file" > "$checksum_file"; fi
    confirm_phrase "The selected databases will be restored to Replica. Existing objects can be replaced by statements contained in the dump." "RESTORE REPLICA"
    if [ "$compress_dump" = yes ]; then
        gzip -dc "$dump_file" | mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" || die "Replica restore failed"
    else
        mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" < "$dump_file" || die "Replica restore failed"
    fi
    if [ "$keep_dump" = no ]; then
        rm -f "$dump_file" "$checksum_file"
        log "Dump removed after successful restore."
    fi
    INITIALIZED=yes
    save_state
    log "Initial data restore completed."
    next_step replicate "Initial data and GTID history are ready on Replica."
}

channel_clause() {
    if [ -n "$CHANNEL_NAME" ]; then
        printf " FOR CHANNEL '%s'" "$(sql_quote "$CHANNEL_NAME")"
    fi
}

replication_syntax() {
    version=$1
    num=$(version_number "$version")
    if [ "$num" -ge 8000023 ]; then printf modern; else printf legacy; fi
}

replicate() {
    load_state
    [ "$INITIALIZED" = yes ] || die "initial data is not marked ready; run initialize"
    ensure_credentials source
    ensure_credentials replica
    source_ver=$(mysql_query source "SELECT @@version;")
    replica_ver=$(mysql_query replica "SELECT @@version;")
    syntax=$(replication_syntax "$replica_ver")
    log ""
    log "Replication account input:"
    log "  user : dedicated MySQL account used only by the Replica I/O thread"
    log "  host : Replica IP or the narrowest permitted host pattern as evaluated by Source"
    repl_user=$(ask_required "Replication user" "")
    repl_host=$(ask_required "Replication account host allowed on Source (Replica IP or restricted pattern)" "")
    validate_account_name "$repl_user"
    validate_account_host "$repl_host"
    q_user=$(sql_quote "$repl_user")
    q_host=$(sql_quote "$repl_host")
    source_connect_host=$(ask_required "Source host/IP reachable from Replica" "$SOURCE_HOST")
    validate_network_host "$source_connect_host"
    source_connect_port=$(ask_required "Source port reachable from Replica" "${SOURCE_PORT:-$SOURCE_RUNTIME_PORT}")
    is_uint "$source_connect_port" || die "Source replication port must be numeric"
    q_source_host=$(sql_quote "$source_connect_host")
    log "Replication transport options:"
    log "  tls   : encrypt replication credentials and traffic; recommended for production"
    log "  plain : no TLS encryption; use only on a separately protected network"
    transport=$(ask "Replication transport (tls/plain)" tls)
    case $transport in
        tls)
            log "TLS certificate verification options:"
            log "  yes : verify that the Source certificate matches its identity; recommended when CA/hostname are configured correctly"
            log "  no  : encrypt traffic without Source identity verification"
            verify_tls=$(ask "Verify Source certificate identity? (yes/no)" yes)
            case $verify_tls in yes|no) ;; *) die "answer must be yes or no" ;; esac
            log "Provide the CA file installed on Replica, or leave blank to use the Replica's configured trust settings."
            ca_file=$(ask "CA certificate path on Replica (blank uses its configured trust settings)" "")
            case $ca_file in *[!A-Za-z0-9_./:-]*) die "CA path contains unsupported characters: $ca_file" ;; esac
            if [ "$syntax" = modern ]; then
                transport_options=", SOURCE_SSL=1"
                [ -n "$ca_file" ] && transport_options="$transport_options, SOURCE_SSL_CA='$(sql_quote "$ca_file")'"
                [ "$verify_tls" = yes ] && transport_options="$transport_options, SOURCE_SSL_VERIFY_SERVER_CERT=1"
            else
                transport_options=", MASTER_SSL=1"
                [ -n "$ca_file" ] && transport_options="$transport_options, MASTER_SSL_CA='$(sql_quote "$ca_file")'"
                [ "$verify_tls" = yes ] && transport_options="$transport_options, MASTER_SSL_VERIFY_SERVER_CERT=1"
            fi
            ;;
        plain)
            warn "Plain replication transport does not protect replication credentials or traffic from network interception."
            confirm_phrase "Use only on a separately protected network." "ALLOW PLAIN REPLICATION"
            if [ "$syntax" = modern ]; then transport_options=", GET_SOURCE_PUBLIC_KEY=1"; else transport_options=", GET_MASTER_PUBLIC_KEY=1"; fi
            ;;
        *) die "invalid replication transport: $transport" ;;
    esac

    if [ "$transport" = tls ]; then
        account_tls_clause=" REQUIRE SSL"
    else
        account_tls_clause=
    fi
    log ""
    log "[minimum Source privilege for the replication connection account]"
    log "CREATE USER '$q_user'@'$q_host' IDENTIFIED BY '<REPLICATION_PASSWORD>'$account_tls_clause;"
    log "GRANT REPLICATION SLAVE ON *.* TO '$q_user'@'$q_host';"
    log ""
    log "Only REPLICATION SLAVE is granted to the replication connection account."
    log "Replication account action options:"
    log "  create   : create the account now on Source and grant only REPLICATION SLAVE"
    log "  existing : use an account already created with the required minimum privilege"
    log "  sql-only : print the minimum-privilege SQL without changing Source; recommended when a separate DBA grants accounts"
    account_action=$(ask "Replication account action (create/existing/sql-only)" sql-only)
    case $account_action in
        create)
            log "The Source administrative account must be allowed to CREATE USER and grant REPLICATION SLAVE."
            confirm_phrase "The displayed minimum-privilege account will be created on Source." "CREATE REPLICATION USER"
            repl_password=$(ask_secret "New replication user password")
            validate_sql_password "$repl_password"
            q_pass=$(sql_quote "$repl_password")
            mysql_query source "CREATE USER '$q_user'@'$q_host' IDENTIFIED BY '$q_pass'$account_tls_clause; GRANT REPLICATION SLAVE ON *.* TO '$q_user'@'$q_host';" || die "cannot create/grant replication account; choose sql-only for DBA execution or existing for a prepared account"
            ;;
        existing)
            log "No CREATE USER or GRANT statement will be executed."
            repl_password=$(ask_secret "Existing replication user password")
            validate_sql_password "$repl_password"
            q_pass=$(sql_quote "$repl_password")
            ;;
        sql-only)
            log "No account or replication channel was changed."
            log "Have a Source DBA execute the displayed SQL, then rerun replicate and select existing."
            next_step replicate "After the DBA creates the account, rerun and select existing."
            return
            ;;
        *) die "invalid replication account action: $account_action" ;;
    esac

    clause=$(channel_clause)
    existing=$(mysql_query replica "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME='$(sql_quote "$CHANNEL_NAME")';")
    if [ "${existing:-0}" -gt 0 ]; then
        confirm_phrase "A replication channel already exists and will be reset: ${CHANNEL_NAME:-default}" "RESET CHANNEL"
        if [ "$syntax" = modern ]; then
            mysql_query replica "STOP REPLICA$clause;" >/dev/null 2>&1 || true
            mysql_query replica "RESET REPLICA ALL$clause;" || die "cannot reset existing Replica channel"
        else
            mysql_query replica "STOP SLAVE$clause;" >/dev/null 2>&1 || true
            mysql_query replica "RESET SLAVE ALL$clause;" || die "cannot reset existing Replica channel"
        fi
    fi
    if [ "$syntax" = modern ]; then
        mysql_query replica "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$q_source_host', SOURCE_PORT=$source_connect_port, SOURCE_USER='$q_user', SOURCE_PASSWORD='$q_pass', SOURCE_AUTO_POSITION=1$transport_options$clause; START REPLICA$clause;" || die "cannot configure/start GTID replication"
    else
        mysql_query replica "CHANGE MASTER TO MASTER_HOST='$q_source_host', MASTER_PORT=$source_connect_port, MASTER_USER='$q_user', MASTER_PASSWORD='$q_pass', MASTER_AUTO_POSITION=1$transport_options$clause; START SLAVE$clause;" || die "cannot configure/start GTID replication"
    fi
    unset repl_password q_pass
    log "GTID replication channel started: ${CHANNEL_NAME:-default}"
    next_step validate "The replication channel has started; verify GTID catch-up and thread status."
}

show_replica_status() {
    load_state
    ensure_credentials replica
    replica_ver=$(mysql_query replica "SELECT @@version;")
    syntax=$(replication_syntax "$replica_ver")
    clause=$(channel_clause)
    if [ "$syntax" = modern ]; then
        mysql_table replica "SHOW REPLICA STATUS$clause\G"
    else
        mysql_table replica "SHOW SLAVE STATUS$clause\G"
    fi
}

status() {
    load_state
    ensure_credentials source
    ensure_credentials replica
    print_runtime source
    print_runtime replica
    log ""
    log "[replication status]"
    show_replica_status
    log ""
    log "STATUS COMPLETE: review receiver/applier thread state and replication errors above."
}

validate() {
    load_state
    ensure_credentials source
    ensure_credentials replica
    source_gtid=$(mysql_query source "SELECT @@GLOBAL.gtid_executed;") || die "cannot read Source GTIDs"
    timeout=$(ask "Seconds to wait for Replica to apply Source GTIDs" 60)
    is_uint "$timeout" || die "timeout must be numeric"
    wait_result=$(mysql_query replica "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(sql_quote "$source_gtid")',$timeout);") || die "GTID wait failed"
    case $wait_result in 0) ;; 1) die "Replica did not apply all Source GTIDs within $timeout seconds" ;; *) die "unexpected GTID wait result: $wait_result" ;; esac
    replica_gtid=$(mysql_query replica "SELECT @@GLOBAL.gtid_executed;")
    subset=$(mysql_query replica "SELECT GTID_SUBSET('$(sql_quote "$source_gtid")','$(sql_quote "$replica_gtid")');")
    [ "$subset" = 1 ] || die "Source GTID set is not a subset of Replica gtid_executed"
    replica_ver=$(mysql_query replica "SELECT @@version;")
    syntax=$(replication_syntax "$replica_ver")
    clause=$(channel_clause)
    if [ "$syntax" = modern ]; then status_sql="SHOW REPLICA STATUS$clause"; else status_sql="SHOW SLAVE STATUS$clause"; fi
    status_row=$(mysql_query replica "$status_sql") || die "cannot read replication status"
    [ -n "$status_row" ] || die "replication status is empty"
    log "VALIDATION: PASSED"
    log "Source GTID set is present on Replica."
    show_replica_status
    next_step status "Validation passed; use status for subsequent operational checks."
}

run_all() {
    discover
    configure
    precheck || die "fix configuration/restart failures before continuing"
    initialize
    replicate
    validate
}

case $STEP in
    discover) discover ;;
    precheck) precheck ;;
    configure) configure ;;
    initialize) initialize ;;
    replicate) replicate ;;
    validate) validate ;;
    status) status ;;
    all) run_all ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown step: $STEP" ;;
esac
