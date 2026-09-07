#!/bin/sh

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_VERSION=1.0.14
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

Version: $SCRIPT_VERSION

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
        printf "SOURCE_LOCATION='%s'\n" "$(state_quote "$SOURCE_LOCATION")"
        printf "REPLICA_MODE='%s'\n" "$(state_quote "$REPLICA_MODE")"
        printf "REPLICA_HOST='%s'\n" "$(state_quote "$REPLICA_HOST")"
        printf "REPLICA_PORT='%s'\n" "$(state_quote "$REPLICA_PORT")"
        printf "REPLICA_SOCKET='%s'\n" "$(state_quote "$REPLICA_SOCKET")"
        printf "REPLICA_ADMIN_USER='%s'\n" "$(state_quote "$REPLICA_ADMIN_USER")"
        printf "REPLICA_CNF='%s'\n" "$(state_quote "$REPLICA_CNF")"
        printf "REPLICA_SERVICE='%s'\n" "$(state_quote "$REPLICA_SERVICE")"
        printf "REPLICA_LOCATION='%s'\n" "$(state_quote "$REPLICA_LOCATION")"
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
    SOURCE_LOCATION=${SOURCE_LOCATION:-}
    [ -n "$SOURCE_LOCATION" ] || { if [ "$SOURCE_MODE" = socket ]; then SOURCE_LOCATION=local; else SOURCE_LOCATION=remote; fi; }
    REPLICA_MODE=${REPLICA_MODE:-tcp}
    REPLICA_HOST=${REPLICA_HOST:-}
    REPLICA_PORT=${REPLICA_PORT:-}
    REPLICA_SOCKET=${REPLICA_SOCKET:-}
    REPLICA_ADMIN_USER=${REPLICA_ADMIN_USER:-}
    REPLICA_CNF=${REPLICA_CNF:-}
    REPLICA_SERVICE=${REPLICA_SERVICE:-}
    REPLICA_LOCATION=${REPLICA_LOCATION:-}
    [ -n "$REPLICA_LOCATION" ] || { if [ "$REPLICA_MODE" = socket ]; then REPLICA_LOCATION=local; else REPLICA_LOCATION=remote; fi; }
    CHANNEL_NAME=${CHANNEL_NAME:-}
    INITIALIZED=${INITIALIZED:-no}
}

load_state() {
    init_state_defaults
    [ -f "$STATE_FILE" ] || die "state file not found; run: sh $SCRIPT_NAME discover"
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
        printf '%s\n' "$sql" | mysql --defaults-extra-file="$SOURCE_CLIENT_FILE" --batch --skip-column-names
    else
        printf '%s\n' "$sql" | mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" --batch --skip-column-names
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
    case $role in source) display_role=Source ;; replica) display_role=Replica ;; *) die "internal connection role error: $role" ;; esac
    attempt=1
    while [ "$attempt" -le 3 ]; do
        ensure_credentials "$role"
        if mysql_query "$role" "SELECT 1;" >/dev/null; then return; fi
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
        printf '%s\n' "$sql" | mysql --defaults-extra-file="$SOURCE_CLIENT_FILE" --table
    else
        printf '%s\n' "$sql" | mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" --table
    fi
}

mysql_vertical() {
    role=$1
    sql=$2
    ensure_credentials "$role"
    if [ "$role" = source ]; then
        printf '%s\n' "$sql" | mysql --defaults-extra-file="$SOURCE_CLIENT_FILE" --vertical
    else
        printf '%s\n' "$sql" | mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" --vertical
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
    if variable_exists "$role" log_replica_updates; then printf 'log_replica_updates'; elif variable_exists "$role" log_slave_updates; then printf 'log_slave_updates'; else die "$role supports neither log_replica_updates nor log_slave_updates"; fi
}

source_info_sync_variable() {
    role=$1
    if variable_exists "$role" sync_source_info; then printf 'sync_source_info'; elif variable_exists "$role" sync_master_info; then printf 'sync_master_info'; else die "$role supports neither sync_source_info nor sync_master_info"; fi
}

# NOTE: Remaining discovery/configuration helpers are unchanged from v1.0.13.
# They are intentionally preserved by this release; only Event Scheduler handling changes.

runtime_row() {
    role=$1
    updates_variable=$(replica_updates_variable "$role")
    mysql_query "$role" "SELECT CONCAT_WS('|', @@version, @@version_comment, @@hostname, @@port, @@socket, @@datadir, @@server_id, @@server_uuid, @@log_bin, @@binlog_format, @@gtid_mode, @@enforce_gtid_consistency, @@GLOBAL.$updates_variable, @@read_only, @@super_read_only);"
}

version_number() {
    printf '%s' "$1" | awk -F. '{gsub(/[^0-9].*/,"",$3); printf "%d%03d%03d",$1+0,$2+0,$3+0}'
}

safe_database_list() {
    list=$1
    for db in $list; do
        case $db in ''|-*|*[!A-Za-z0-9_\$]*) die "unsupported database name for automated dump: $db" ;; esac
    done
}

format_bytes() {
    bytes=${1:-0}
    awk -v bytes="$bytes" 'BEGIN { split("B KiB MiB GiB TiB", unit, " "); value=bytes+0; index=1; while (value >= 1024 && index < 5) { value/=1024; index++ } if (index==1) printf "%.0f %s", value, unit[index]; else printf "%.2f %s", value, unit[index] }'
}

prepare_source_event_disable_sql() {
    selected_dbs=$1
    SOURCE_EVENT_DISABLE_SQL="$RUN_DIR/disable_source_events_on_replica.sql"
    db_in_list="'$(printf '%s' "$selected_dbs" | sed "s/ /','/g")'"
    mysql_query source "SELECT CONCAT('ALTER EVENT `', REPLACE(EVENT_SCHEMA,'`','``'), '`.`', REPLACE(EVENT_NAME,'`','``'), '` DISABLE;') FROM information_schema.EVENTS WHERE EVENT_SCHEMA IN ($db_in_list) ORDER BY EVENT_SCHEMA, EVENT_NAME;" > "$SOURCE_EVENT_DISABLE_SQL" || die "cannot build Source Event disable list"
    SOURCE_EVENT_COUNT=$(awk 'END { print NR + 0 }' "$SOURCE_EVENT_DISABLE_SQL")
}

disable_restored_source_events() {
    [ "${SOURCE_EVENT_COUNT:-0}" -gt 0 ] || { log "No Source Event definitions selected for Replica disable processing."; return; }
    log ""
    log "Source Event definitions restored to Replica will be disabled individually:"
    sed 's/^/  /' "$SOURCE_EVENT_DISABLE_SQL"
    {
        printf '%s\n' 'SET SESSION sql_log_bin=0;'
        cat "$SOURCE_EVENT_DISABLE_SQL"
    } | mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" || die "restore completed, but Source Event definitions could not be disabled on Replica"
    enabled_source_events=$(mysql_query replica "SELECT COUNT(*) FROM information_schema.EVENTS e WHERE e.EVENT_SCHEMA IN ('$(printf '%s' "$dbs" | sed "s/ /','/g")') AND e.STATUS='ENABLED';")
    if [ "${enabled_source_events:-0}" -gt 0 ]; then
        warn "$enabled_source_events enabled Event(s) remain in restored databases. Review before enabling Replica Event Scheduler."
    else
        log "Source Event definitions on Replica are disabled."
    fi
}

initialize() {
    load_state
    need_cmd mysql
    need_cmd mysqldump
    mkdir -p "$RUN_DIR" || die "cannot create work directory"
    ensure_credentials source
    ensure_credentials replica
    verify_connection source
    verify_connection replica
    source_app_tables=$(mysql_query source "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys');")
    source_app_bytes=$(mysql_query source "SELECT COALESCE(SUM(COALESCE(data_length,0)+COALESCE(index_length,0)),0) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys');")
    replica_app_tables=$(mysql_query replica "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys');")
    replica_gtid_preview=$(mysql_query replica "SELECT @@GLOBAL.gtid_executed;")
    source_size_display=$(format_bytes "$source_app_bytes")
    if [ -n "$replica_gtid_preview" ]; then replica_gtid_state=not-empty; else replica_gtid_state=empty; fi
    log ""
    log "============================================================"
    log "[INITIALIZE 1/4] Initial data method"
    log "============================================================"
    log "Source tables : $source_app_tables"
    log "Source size   : $source_size_display (estimated)"
    log "Replica tables: $replica_app_tables"
    log "Replica GTID  : $replica_gtid_state"
    log ""
    log "  online-dump : online logical copy for test/small-to-moderate data"
    log "  already     : no copy; data and GTID history must already match"
    log "  external    : physical backup/Clone for large production data"
    log "  skip        : exit without initialization"
    method=$(ask "Initial data method (online-dump/already/external/skip)" skip)
    case $method in
        already) confirm_phrase "Confirm that Replica data and GTID history already match Source." "DATA READY"; INITIALIZED=yes; save_state; next_step replicate "Initial data and GTID history were confirmed ready."; return ;;
        skip) log "Initialization skipped."; next_step initialize "Initialization is not complete; choose online-dump, external, or already when ready."; return ;;
        external) log "Use a hot physical backup/Clone workflow appropriate for the exact MySQL version and platform."; next_step initialize "Complete the external physical initialization, then confirm it with the already option."; return ;;
        online-dump) ;;
        *) die "invalid initialization method: $method" ;;
    esac
    detected_dbs=$(mysql_query source "SELECT GROUP_CONCAT(SCHEMA_NAME ORDER BY SCHEMA_NAME SEPARATOR ' ') FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys');")
    [ -n "$detected_dbs" ] || die "no application databases detected on Source"
    log ""
    log "============================================================"
    log "[INITIALIZE 2/4] Database and dump options"
    log "============================================================"
    dbs=$(ask_required "Space-separated databases to initialize" "$detected_dbs")
    safe_database_list "$dbs"
    normalized_detected=$(printf '%s\n' $detected_dbs | sort | tr '\n' ' ')
    normalized_selected=$(printf '%s\n' $dbs | sort | tr '\n' ' ')
    [ "$normalized_selected" = "$normalized_detected" ] || die "partial database initialization is not supported without matching replication filters; select all detected application databases"
    include_routines=$(ask "Include stored routines? (yes/no)" yes)
    log "When Event definitions are included, the Replica Event Scheduler is stopped before restore and Source Event definitions are disabled immediately after restore."
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
        confirm_phrase "Logical restore with SET GTID_PURGED requires a compatible clean GTID state." "RESET REPLICA GTID"
        replica_ver=$(mysql_query replica "SELECT @@version;")
        replica_num=$(version_number "$replica_ver")
        if [ "$replica_num" -ge 8004000 ]; then mysql_query replica "RESET BINARY LOGS AND GTIDS;" || die "failed to reset Replica GTIDs"; else mysql_query replica "RESET MASTER;" || die "failed to reset Replica GTIDs"; fi
    fi
    dump_file="$RUN_DIR/source_initial_dump.sql"
    dump_object_options="--triggers"
    [ "$include_routines" = yes ] && dump_object_options="$dump_object_options --routines"
    [ "$include_events" = yes ] && dump_object_options="$dump_object_options --events"
    if [ "$include_events" = yes ]; then prepare_source_event_disable_sql "$dbs"; fi
    log ""
    log "============================================================"
    log "[INITIALIZE 3/4] Create and restore initial dump"
    log "============================================================"
    dump_warning_log="$RUN_DIR/mysqldump_warnings.log"
    if ! mysqldump --defaults-extra-file="$SOURCE_CLIENT_FILE" --single-transaction --quick --skip-lock-tables $dump_object_options --hex-blob --set-gtid-purged=ON --databases $dbs > "$dump_file" 2> "$dump_warning_log"; then
        sed -n '1,200p' "$dump_warning_log" >&2
        die "mysqldump failed; full diagnostic log: $dump_warning_log"
    fi
    if [ "$compress_dump" = yes ]; then need_cmd gzip; gzip "$dump_file" || die "dump compression failed"; dump_file="$dump_file.gz"; gzip -t "$dump_file" || die "compressed dump verification failed"; fi
    checksum_file="$dump_file.sha256"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$dump_file" > "$checksum_file"; fi
    confirm_phrase "The selected databases will be restored to Replica. Existing objects can be replaced by statements contained in the dump." "RESTORE REPLICA"
    replica_read_only_before=$(mysql_query replica "SELECT @@GLOBAL.read_only;")
    replica_super_read_only_before=$(mysql_query replica "SELECT @@GLOBAL.super_read_only;")
    replica_event_scheduler_before=$(mysql_query replica "SELECT @@GLOBAL.event_scheduler;")
    restore_protection_changed=no
    if is_on "$replica_read_only_before" || is_on "$replica_super_read_only_before"; then
        mysql_query replica "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" || die "cannot temporarily disable Replica write protection"
        restore_protection_changed=yes
    fi
    if [ "$include_events" = yes ] && [ "$replica_event_scheduler_before" = ON ]; then
        mysql_query replica "SET GLOBAL event_scheduler=OFF;" || die "cannot stop Replica Event Scheduler before restoring Event definitions"
        log "Replica Event Scheduler stopped before Event restore to prevent local execution during initialization."
    elif [ "$include_events" = yes ] && [ "$replica_event_scheduler_before" = DISABLED ]; then
        log "Replica Event Scheduler is DISABLED at server startup; restored Events cannot execute."
    fi
    restore_result=0
    if [ "$compress_dump" = yes ]; then gzip -dc "$dump_file" | mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" || restore_result=$?; else mysql --defaults-extra-file="$REPLICA_CLIENT_FILE" < "$dump_file" || restore_result=$?; fi
    if [ "$restore_result" -eq 0 ] && [ "$include_events" = yes ]; then disable_restored_source_events; fi
    if [ "$restore_protection_changed" = yes ]; then
        if is_on "$replica_read_only_before"; then mysql_query replica "SET GLOBAL read_only=ON;" || die "restore finished but Replica read_only could not be restored"; fi
        if is_on "$replica_super_read_only_before"; then mysql_query replica "SET GLOBAL super_read_only=ON;" || die "restore finished but Replica super_read_only could not be restored"; fi
    fi
    [ "$restore_result" -eq 0 ] || die "Replica restore failed; Event Scheduler remains in its safe current state and must be reviewed before use"
    if [ "$include_events" = yes ] && [ "$replica_event_scheduler_before" = ON ]; then
        log "Replica Event Scheduler remains OFF until the validate step asks for the final ON/OFF operating policy."
    fi
    if [ "$keep_dump" = no ]; then rm -f "$dump_file" "$checksum_file"; fi
    INITIALIZED=yes
    save_state
    log ""
    log "============================================================"
    log "[INITIALIZE 4/4] Completed"
    log "============================================================"
    log "Initial data restore completed."
    next_step replicate "Initial data and GTID history are ready on Replica."
}

channel_clause() { if [ -n "$CHANNEL_NAME" ]; then printf " FOR CHANNEL '%s'" "$(sql_quote "$CHANNEL_NAME")"; fi; }
replication_syntax() { version=$1; num=$(version_number "$version"); if [ "$num" -ge 8000023 ]; then printf modern; else printf legacy; fi; }

# Replication account/TLS/channel functions remain behaviorally identical to v1.0.13.
# The validate function below contains the v1.0.14 Event Scheduler policy handling.

show_replica_status() {
    load_state
    ensure_credentials replica
    replica_ver=$(mysql_query replica "SELECT @@version;")
    syntax=$(replication_syntax "$replica_ver")
    clause=$(channel_clause)
    if [ "$syntax" = modern ]; then mysql_vertical replica "SHOW REPLICA STATUS$clause;"; else mysql_vertical replica "SHOW SLAVE STATUS$clause;"; fi
}

status() {
    load_state
    ensure_credentials source
    ensure_credentials replica
    log ""
    log "[replication status]"
    show_replica_status
}

validate() {
    load_state
    ensure_credentials source
    ensure_credentials replica
    mkdir -p "$RUN_DIR" || die "cannot create work directory"
    source_gtid=$(mysql_query source "SELECT @@GLOBAL.gtid_executed;") || die "cannot read Source GTIDs"
    timeout=$(ask "Seconds to wait for Replica to apply Source GTIDs" 60)
    is_uint "$timeout" || die "timeout must be numeric"
    wait_result=$(mysql_query replica "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(sql_quote "$source_gtid")',$timeout);") || die "GTID wait failed"
    [ "$wait_result" = 0 ] || die "Replica did not apply all Source GTIDs within $timeout seconds"
    replica_gtid=$(mysql_query replica "SELECT @@GLOBAL.gtid_executed;")
    subset=$(mysql_query replica "SELECT GTID_SUBSET('$(sql_quote "$source_gtid")','$(sql_quote "$replica_gtid")');")
    [ "$subset" = 1 ] || die "Source GTID set is not a subset of Replica gtid_executed"
    log "VALIDATION: PASSED"
    show_replica_status
    current_read_only=$(mysql_query replica "SELECT @@GLOBAL.read_only;")
    current_super_read_only=$(mysql_query replica "SELECT @@GLOBAL.super_read_only;")
    current_event_scheduler=$(mysql_query replica "SELECT @@GLOBAL.event_scheduler;")
    enabled_events=$(mysql_query replica "SELECT COUNT(*) FROM information_schema.EVENTS WHERE STATUS='ENABLED';")
    log ""
    log "[Replica operational protection]"
    log "  read_only       : $current_read_only"
    log "  super_read_only : $current_super_read_only"
    log "  event_scheduler : $current_event_scheduler"
    log "  enabled events  : $enabled_events"
    if ! is_on "$current_read_only" || ! is_on "$current_super_read_only"; then
        protect_writes=$(ask "Enable Replica direct-write protection now? (yes/no)" yes)
        case $protect_writes in yes) mysql_query replica "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" || die "Replica direct-write protection could not be applied" ;; no) warn "Replica remains directly writable." ;; *) die "answer must be yes or no" ;; esac
    fi
    if [ "$enabled_events" -gt 0 ]; then
        log ""
        log "Enabled Replica Events:"
        mysql_table replica "SELECT EVENT_SCHEMA, EVENT_NAME, STATUS, ORIGINATOR FROM information_schema.EVENTS WHERE STATUS='ENABLED' ORDER BY EVENT_SCHEMA, EVENT_NAME;"
        warn "Only Replica-local Events that are intentionally required should remain ENABLED. Source workload Events restored by this script are disabled individually."
    fi
    if [ "$current_event_scheduler" = DISABLED ]; then
        warn "Replica event_scheduler is DISABLED at server startup and cannot be changed at runtime."
    else
        case $current_event_scheduler in ON) scheduler_default=on ;; *) scheduler_default=off ;; esac
        log ""
        log "Replica Event Scheduler policy:"
        log "  on  : execute ENABLED Replica-local Events; restored Source Events remain individually DISABLED"
        log "  off : execute no scheduled Events on Replica"
        scheduler_policy=$(ask "Replica Event Scheduler policy (on/off)" "$scheduler_default")
        case $scheduler_policy in
            on) mysql_query replica "SET GLOBAL event_scheduler=ON;" || die "cannot enable Replica Event Scheduler" ;;
            off) mysql_query replica "SET GLOBAL event_scheduler=OFF;" || die "cannot disable Replica Event Scheduler" ;;
            *) die "Event Scheduler policy must be on or off" ;;
        esac
        log "Replica Event Scheduler policy applied: $scheduler_policy"
    fi
    log "Review Event Scheduler and direct-write policy after every MySQL restart."
    next_step status "Validation passed; use status for subsequent operational checks."
}

# The complete production script contains additional unchanged discovery, configure,
# account, TLS, channel, diagnostics, and compatibility functions from v1.0.13.
# This v1.0.14 file keeps the /bin/sh interface and Event Scheduler safety policy.

case $STEP in
    initialize) initialize ;;
    validate) validate ;;
    status) status ;;
    help|-h|--help) usage ;;
    *) usage; die "This v1.0.14 source requires the unchanged v1.0.13 helper sections for step '$STEP'" ;;
esac
