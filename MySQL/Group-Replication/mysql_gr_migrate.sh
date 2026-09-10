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
discover() {
    PHASE=discover
    prepare_discovery
    mkdir -p "$ROOT/meta"
    log '1) Existing GTID replication -> GR : reuse an existing GTID source/replica topology; replicas catch up before cutover.'
    log '2) Standalone -> GR                 : build GR from standalone/new members; each non-source member is inspected before provisioning.'
    choice=$(required 'Migration mode (1/2)' '')
    case $choice in 1) put meta mode gtid;; 2) put meta mode standalone;; *) die 'Choose 1 or 2';; esac
    count=$(required 'Member count (2..9)' 3)
    uint "$count" && [ "$count" -ge 2 ] && [ "$count" -le 9 ] || die 'Member count must be 2..9'
    put meta count "$count"
    log '  single: one writable PRIMARY; secondaries remain read-only.'
    log '  multi : all members can accept writes; application conflict handling is required.'
    topology=$(required 'GR primary mode (single/multi)' single)
    case $topology in single|multi) :;; *) die 'Choose single or multi';; esac
    put meta primary_mode "$topology"
    if [ "$topology" = multi ]; then
        log 'Multi-primary: concurrent write conflicts require application retries; SERIALIZABLE and cascading foreign-key operations are restricted. Serialize DDL on one member.'
        confirm 'MULTI PRIMARY REQUIREMENTS REVIEWED'
    fi
    log 'Register the authoritative Source/Standalone as node 1. It will bootstrap as primary.'
    awk 'NF>=8 && $8 ~ /^\// && $8 !~ /mysqlx/ {print $8}' /proc/net/unix 2>/dev/null | sort -u > "$RUN/socket_candidates" || :
    for i in $(ids); do
        mkdir -p "$ROOT/$i"
        log "--- Node $i ---"
        cat -n "$RUN/socket_candidates" >&2
        mode=$(required 'Management connection (socket/tcp)' socket)
        case $mode in socket|tcp) :;; *) die 'Invalid connection mode';; esac
        put "$i" mode "$mode"
        if [ "$mode" = socket ]; then
            s=$(required 'Socket number or absolute path' '')
            if uint "$s"; then s=$(sed -n "${s}p" "$RUN/socket_candidates"); fi
            case $s in /*) :;; *) die 'Socket must be absolute';; esac
            [ -S "$s" ] || die 'Selected path is not a socket'
            put "$i" socket "$s"; put "$i" location local
        else
            h=$(required 'Management host' ''); safe_host "$h"; put "$i" host "$h"
            p=$(required 'Management TCP port' ''); port_ok "$p" || die 'Invalid port'; put "$i" port "$p"
            put "$i" location remote
            log '  VERIFY_IDENTITY: encrypted connection with CA/host identity verification (recommended).'
            log '  REQUIRED       : encrypted connection without server identity verification.'
            tls=$(required 'Management TLS (VERIFY_IDENTITY/REQUIRED)' VERIFY_IDENTITY)
            case $tls in VERIFY_IDENTITY|REQUIRED) :;; *) die 'Invalid TLS mode';; esac
            put "$i" admin_tls "$tls"
            if [ "$tls" = VERIFY_IDENTITY ]; then
                ca=$(required 'Client CA file on this controller' ''); [ -r "$ca" ] || die 'CA not readable'; put "$i" admin_ca "$ca"
            else confirm 'ALLOW UNVERIFIED ADMIN TLS'; fi
        fi
        put "$i" user "$(required 'Administrative MySQL user' '')"
        credential "$i"
        v=$(val "$i" version); version_guard "$v" || die "Unsupported version: $v"
        case "$(val "$i" version_comment) $v" in *MariaDB*|*Percona*) die 'This release targets Oracle MySQL';; esac
        put "$i" version "$v"; put "$i" uuid "$(val "$i" server_uuid)"
        put "$i" datadir "$(val "$i" datadir)"
        sql "$i" 'SELECT @@version,@@hostname,@@port,@@socket,@@datadir,@@server_id,@@server_uuid;' >&2
        if [ "$i" -gt 1 ]; then
            [ "$v" = "$(get 1 version)" ] || die 'Initial deployment requires identical exact server versions'
            for j in $(ids); do
                [ "$j" -lt "$i" ] || break
                [ "$(get "$j" uuid)" != "$(get "$i" uuid)" ] || die 'Duplicate UUID/instance selected'
            done
        fi
        cnf=''
        if p=$(local_pid "$i"); then
            tr '\000' '\n' < "/proc/$p/cmdline" | sed -n 's/^--defaults-file=//p' > "$RUN/$i.cnf_candidates"
            sql "$i" "SELECT DISTINCT VARIABLE_PATH FROM performance_schema.variables_info WHERE VARIABLE_PATH<>'' ORDER BY VARIABLE_PATH;" >> "$RUN/$i.cnf_candidates"
            log 'Observed option files:'; sort -u "$RUN/$i.cnf_candidates" >&2
            cnf=$(ask 'Main option file (absolute path; blank = generate only)' "$(head -n 1 "$RUN/$i.cnf_candidates")")
            put "$i" pid "$p"
        fi
        put "$i" cnf "$cnf"
        h=$(required 'Advertised SQL host reachable from every member' "$(val "$i" hostname)"); safe_host "$h"
        put "$i" advertise "$h"
        p=$(required 'Advertised SQL port' "$(val "$i" port)"); port_ok "$p" || die 'Invalid port'; put "$i" sql_port "$p"
        [ "$p" = "$(val "$i" port)" ] || die 'NAT/port mapping needs a separately reviewed recovery endpoint configuration'
        p=$(required 'Dedicated XCom port (different from SQL/X Protocol)' '')
        port_ok "$p" || die 'Invalid XCom port'
        [ "$p" != "$(get "$i" sql_port)" ] || die 'XCom and SQL ports must differ'
        if hasvar "$i" mysqlx_port; then [ "$p" != "$(val "$i" mysqlx_port)" ] || die 'XCom conflicts with X Protocol'; fi
        put "$i" xcom "$h:$p"
        kind=source; channel=''
        if [ "$i" -gt 1 ]; then
            if [ "$(get meta mode)" = gtid ]; then
                sql "$i" 'SELECT CHANNEL_NAME,HOST,PORT,AUTO_POSITION FROM performance_schema.replication_connection_configuration;' >&2
                kind=$(required 'Existing replica or new member (replica/new)' replica)
                case $kind in replica) channel=$(ask 'Channel name (blank = default channel)' '');; new) :;; *) die 'Invalid member kind';; esac
            else kind=new; fi
        fi
        case $channel in group_replication_*) die 'Reserved channel';; esac
        put "$i" kind "$kind"; put "$i" channel "$channel"
    done
    endpoints_check
    group=$(sql 1 'SELECT UUID();'); put meta group "$group"

    put meta allowlist "$(required 'XCom IP allowlist (member IPs/CIDRs, comma-separated; no spaces)' '')"
    case "$(get meta allowlist)" in *[!A-Za-z0-9_.,:/-]*) die 'Invalid allowlist';; esac
    log '  VERIFY_IDENTITY: verify the distributed-recovery server certificate identity (recommended).'
    log '  REQUIRED       : require TLS but do not verify server identity.'
    tls=$(required 'GR TLS (VERIFY_IDENTITY/REQUIRED)' VERIFY_IDENTITY)
    case $tls in VERIFY_IDENTITY|REQUIRED) :;; *) die 'Invalid GR TLS';; esac
    [ "$tls" != REQUIRED ] || confirm 'ALLOW UNVERIFIED GR TLS'
    put meta tls "$tls"
    for i in $(ids); do
        ca=$(val "$i" ssl_ca)
        case $ca in '') :;; /*) :;; *) ca="$(val "$i" datadir)$ca";; esac
        ca=$(required "Node $i CA path on its server (used for recovery)" "$ca")
        case $ca in /*) :;; *) die 'Use absolute server CA paths';; esac
        put "$i" recovery_ca "$ca"
    done
    put meta complete yes
    PHASE=registered
    log "Discovery complete: $ROOT"
    [ "$STEP" = all ] || log "NEXT: sh mysql_gr_migrate.sh configure"
}
no_group() {
    for ng in $(ids); do
        [ "$(sql "$ng" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE <> 'OFFLINE';")" = 0 ] || die "Node $ng already belongs to an active/recovering group. Use status; never bootstrap again."
    done
}
config_lines() (
    i=$1; sid=$2
    printf '[mysqld]\nserver_id=%s\ngtid_mode=ON\nenforce_gtid_consistency=ON\nbinlog_format=ROW\nlog_replica_updates=ON\nreplica_preserve_commit_order=ON\nskip_replica_start=ON\n' "$sid"
    if [ "$(val "$i" log_bin)" != 1 ]; then printf 'log_bin\n'; fi
    for pair in 'xa_detach_on_prepare ON' 'transaction_write_set_extraction XXHASH64' 'replica_parallel_type LOGICAL_CLOCK' 'master_info_repository TABLE' 'relay_log_info_repository TABLE'; do
        set -- $pair
        if hasvar "$i" "$1"; then printf '%s=%s\n' "$1" "$2"; fi
    done
    printf 'report_host=%s\nreport_port=%s\n' "$(get "$i" advertise)" "$(get "$i" sql_port)"
    if [ -f "$ROOT/meta/profile" ] && [ "$(get meta profile)" = production ]; then
        printf 'sync_binlog=1\ninnodb_flush_log_at_trx_commit=1\nbinlog_row_image=FULL\nbinlog_expire_logs_seconds=%s\n' "$(get "$i" retention)"
    fi
    # INSTALL PLUGIN is persisted in mysql.plugin; no duplicate plugin_load_add.
)
wait_connection() (
    i=$1; attempt=0
    while [ "$attempt" -lt 60 ]; do
        if [ "$(sql "$i" 'SELECT 1;' 2>/dev/null || :)" = 1 ]; then
            [ "$(val "$i" server_uuid)" = "$(get "$i" uuid)" ] || die 'Restarted instance UUID mismatch'
            exit 0
        fi
        sleep 2; attempt=$((attempt+1))
    done
    die "Node $i did not reconnect after restart"
)
restart_direct() (
    i=$1; p=$2; exe=$3; cnf=$4
    parent=$(awk '{print $4}' "/proc/$p/stat")
    parent_name=$(cat "/proc/$parent/comm" 2>/dev/null || :)
    case $parent_name in
        mysqld_safe|supervisord|s6-supervise|runsv)
            log "Node $i is managed by $parent_name. Restart using that supervisor, then rerun precheck."
            exit 0;;
        bash|sh|dash|init|systemd) :;;
        *) log "Node $i launcher is uncertain ($parent_name); restart the selected instance manually."; exit 0;;
    esac
    owner=$(stat -c %u "$(val "$i" datadir)")
    [ "$(id -u)" = 0 ] || [ "$(id -u)" = "$owner" ] || die 'Run as datadir owner or root for direct restart'
    tr '\000' '\n' < "/proc/$p/cmdline" > "$RUN/node_$i.start_arguments"
    # Replay the existing arguments, preserving per-instance command-line overrides.
    grep -Fx -- "--defaults-file=$cnf" "$RUN/node_$i.start_arguments" >/dev/null || {
        log 'Cannot prove the chosen cnf is the direct startup file. Restart manually.'; exit 0;
    }
    log "Node $i direct restart: SQL SHUTDOWN, then $exe with saved original arguments and --daemonize."
    [ "$(ask 'Execute this direct restart? (yes/no)' no)" = yes ] || exit 0
    set --
    first=yes
    while IFS= read -r arg; do
        if [ "$first" = yes ]; then first=no; continue; fi
        set -- "$@" "$arg"
    done < "$RUN/node_$i.start_arguments"
    sql "$i" 'SHUTDOWN;'
    tries=0
    while kill -0 "$p" 2>/dev/null; do
        [ "$tries" -lt 120 ] || die 'Old mysqld is still shutting down; do not launch a duplicate'
        sleep 2; tries=$((tries+1))
    done
    if [ "$(id -u)" = 0 ]; then
        os_user=$(stat -c %U "$(get "$i" datadir)")
        "$exe" "$@" --daemonize --user="$os_user"
    else "$exe" "$@" --daemonize; fi
    wait_connection "$i"
)
# Values travel as shell-quoted assignments on SSH stdin, never command arguments.
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
ssh_options() {
    ssh_node=$1
    command -v ssh >/dev/null 2>&1 || die 'OpenSSH client is required for remote OS management; no packages are installed automatically.'
    if [ ! -f "$ROOT/$ssh_node/ssh_host" ]; then
        ssh_host=$(required "Node $ssh_node SSH host" "$(get "$ssh_node" host)"); safe_host "$ssh_host"
        case $ssh_host in -*) die 'Invalid SSH host';; esac
        ssh_defaults=$(ssh -G "$ssh_host")
        ssh_port=$(required 'SSH port' "$(printf '%s\n' "$ssh_defaults" | awk '$1=="port" {print $2;exit}')")
        port_ok "$ssh_port" || die 'Invalid SSH port'
        ssh_user=$(required 'SSH OS user' "$(printf '%s\n' "$ssh_defaults" | awk '$1=="user" {print $2;exit}')")
        case $ssh_user in ''|-*|*[!A-Za-z0-9_.-]*) die 'Invalid SSH OS user';; esac
        ssh_key=$(ask 'SSH private key path (blank = SSH config/agent/password)' '')
        [ -z "$ssh_key" ] || [ -r "$ssh_key" ] || die 'SSH key is not readable'
        privilege=$(required 'Remote OS privilege (current/sudo)' current)
        case $privilege in current|sudo) :;; *) die 'Choose current or sudo';; esac
        log 'sudo uses sudo -n: configure the required OS permissions first. SSH passwords are handled by OpenSSH; they are not stored by this script.'
        put "$ssh_node" ssh_host "$ssh_host"; put "$ssh_node" ssh_port "$ssh_port"
        put "$ssh_node" ssh_user "$ssh_user"; put "$ssh_node" ssh_key "$ssh_key"
        put "$ssh_node" ssh_privilege "$privilege"
    fi
    if [ ! -f "$TEMP/$ssh_node.remote.cnf" ]; then
        credential "$ssh_node"
        choice=$(required "Node $ssh_node socket DB credentials (same/other)" same)
        case $choice in
            same) sed -n '/^user=/p; /^password=/p' "$TEMP/$ssh_node.cnf" > "$TEMP/$ssh_node.remote.cnf";;
            other)
                u=$(required 'Remote socket MySQL admin user' '')
                pw=$(secret 'Remote socket MySQL admin password')
                printf 'user="%s"\npassword="%s"\n' "$(optq "$u")" "$(optq "$pw")" > "$TEMP/$ssh_node.remote.cnf"
                unset pw;;
            *) die 'Choose same or other';;
        esac
    fi
}
ssh_transport() (
    i=$1
    set -- -T -o StrictHostKeyChecking=ask -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p "$(get "$i" ssh_port)" -l "$(get "$i" ssh_user)"
    key=$(get "$i" ssh_key)
    [ -z "$key" ] || set -- "$@" -i "$key"
    remote_command='sh -s'
    [ "$(get "$i" ssh_privilege)" != sudo ] || remote_command='sudo -n sh -s'
    ssh "$@" -- "$(get "$i" ssh_host)" "$remote_command"
)
remote_call() (
    i=$1; action=$2; snippet=${3:-}; restart=${4:-no}
    credential "$i"
    payload="$TEMP/remote_${i}_${action}.sh"
    {
        printf 'set -eu\numask 077\n'
        printf 'ACTION=%s\n' "$(shell_quote "$action")"
        printf 'EXPECTED_UUID=%s\n' "$(shell_quote "$(get "$i" uuid)")"
        printf 'EXPECTED_DATA=%s\n' "$(shell_quote "$(val "$i" datadir)")"
        printf 'EXPECTED_SOCKET=%s\n' "$(shell_quote "$(val "$i" socket)")"
        printf 'EXPECTED_PID_FILE=%s\n' "$(shell_quote "$(val "$i" pid_file)")"
        printf 'BASEDIR=%s\n' "$(shell_quote "$(val "$i" basedir)")"
        printf 'CNF=%s\n' "$(shell_quote "$(get "$i" cnf)")"
        printf 'CLIENT_AUTH=%s\n' "$(shell_quote "$(cat "$TEMP/$i.remote.cnf")")"
        printf 'SNIPPET=%s\n' "$(shell_quote "$(if [ -n "$snippet" ]; then cat "$snippet"; fi)")"
        printf 'DO_RESTART=%s\n' "$(shell_quote "$restart")"
        printf 'VERSION=%s\n' "$(shell_quote "$VERSION")"
        printf 'ADVERTISE=%s\n' "$(shell_quote "$(get "$i" advertise)")"
        printf 'SQL_PORT=%s\n' "$(shell_quote "$(get "$i" sql_port)")"
        xcom_value=$(get "$i" xcom); printf 'XCOM_PORT=%s\n' "$(shell_quote "${xcom_value##*:}")"
        printf 'GR_TLS_MODE=%s\n' "$(shell_quote "$(get meta tls)")"
        printf 'RECOVERY_CA=%s\n' "$(shell_quote "$(get "$i" recovery_ca)")"
        if [ "$action" = tls-apply ] || [ "$action" = tls-rollback ]; then
            printf 'TLS_OUTPUT=%s\n' "$(shell_quote "$(cat "$RUN/tls_change/$i.output")")"
        fi
        if [ "$action" = tls-apply ]; then
            material="$RUN/tls_change/$i.material"
            [ -r "$material/ca.pem" ] && [ -r "$material/server-cert.pem" ] && [ -r "$material/server-key.pem" ] || die "Node $i prepared TLS material missing"
            printf 'TLS_CA_PEM=%s\n' "$(shell_quote "$(cat "$material/ca.pem")")"
            printf 'TLS_CERT_PEM=%s\n' "$(shell_quote "$(cat "$material/server-cert.pem")")"
            printf 'TLS_KEY_PEM=%s\n' "$(shell_quote "$(cat "$material/server-key.pem")")"
        fi
        remote_agent
    } > "$payload"
    # Capture the SSH exit status directly; a pipeline/tee must not hide failure.
    if ssh_transport "$i" < "$payload" > "$RUN/node_${i}.remote_${action}.tsv"; then
        rm -f "$payload"
        cat "$RUN/node_${i}.remote_${action}.tsv"
    else
        rm -f "$payload"
        cat "$RUN/node_${i}.remote_${action}.tsv" >&2
        die "Node $i remote $action failed. Inspect SSH/server errors and retained configuration backups; no automatic database rollback."
    fi
)
remote_agent() {
    cat <<'REMOTE_AGENT'
r_die() { printf 'REMOTE ERROR: %s\n' "$*" >&2; exit 1; }
r_sql() { printf '%s\n' "$1" | "$RMYSQL" --defaults-file="$RTMP/client.cnf" --no-login-paths --batch --raw --skip-column-names; }
r_cleanup() {
    r_rc=$?; trap - 0 1 2 15
    [ -z "${CANDIDATE:-}" ] || rm -f -- "$CANDIDATE"
    [ -z "${CFGLOCK:-}" ] || rmdir "$CFGLOCK" 2>/dev/null || :
    [ -z "${RTMP:-}" ] || rm -rf -- "$RTMP"
    exit "$r_rc"
}
r_identity() {
    actual=$(r_sql "SELECT CONCAT(@@server_uuid,'|',@@datadir,'|',@@socket,'|',@@pid_file);")
    [ "$actual" = "$EXPECTED_UUID|$EXPECTED_DATA|$EXPECTED_SOCKET|$EXPECTED_PID_FILE" ] || r_die 'Remote socket instance differs from the controller SQL endpoint.'
    RPID=$(cat "$EXPECTED_PID_FILE")
    case $RPID in ''|*[!0-9]*) r_die 'Invalid runtime PID file';; esac
    REXE=$(readlink -f "/proc/$RPID/exe")
    case ${REXE##*/} in mysqld|mysqld-debug) :;; *) r_die 'PID is not mysqld';; esac
    tr '\000' '\n' < "/proc/$RPID/cmdline" > "$RTMP/argv"
    RCWD=$(readlink -f "/proc/$RPID/cwd")
    ROWNER=$(stat -c %U "$EXPECTED_DATA")
    RUID=$(stat -c %u "$EXPECTED_DATA")
    RSTART=$(awk '{print $22}' "/proc/$RPID/stat")
    RDEFAULT=$(sed -n 's/^--defaults-file=//p' "$RTMP/argv" | head -n 1)
    RPARENT=$(awk '{print $4}' "/proc/$RPID/stat")
    PNAME=$(cat "/proc/$RPARENT/comm" 2>/dev/null || :)
    RSERVICE=$(sed -n 's#.*\/\([^/]*\.service\)$#\1#p' "/proc/$RPID/cgroup" | head -n 1)
    RMETHOD=unknown
    if [ -n "$RSERVICE" ] && command -v systemctl >/dev/null 2>&1 && [ "$(systemctl show "$RSERVICE" -p MainPID --value)" = "$RPID" ]; then
        RMETHOD=systemd
    else
        case $PNAME in
            mysqld_safe)
                RMETHOD=mysqld_safe
                tr '\000' '\n' < "/proc/$RPARENT/cmdline" > "$RTMP/safe_argv"
                SAFE_CWD=$(readlink -f "/proc/$RPARENT/cwd")
                SAFESTART=$(awk '{print $22}' "/proc/$RPARENT/stat")
                SAFEUID=$(stat -c %u "/proc/$RPARENT")
                [ "$(id -u)" = "$SAFEUID" ] || RMETHOD=unknown
                # Preserve exact interpreter/script arguments; reject unknown wrappers.
                grep -E '^(/[^[:cntrl:]]*/)?mysqld_safe$' "$RTMP/safe_argv" >/dev/null || RMETHOD=unknown;;
            bash|sh|dash|init|systemd) RMETHOD=direct;;
        esac
    fi
    r_sql "SELECT DISTINCT VARIABLE_PATH FROM performance_schema.variables_info WHERE VARIABLE_PATH<>'' ORDER BY VARIABLE_PATH;" > "$RTMP/candidates"
    [ -z "$RDEFAULT" ] || printf '%s\n' "$RDEFAULT" >> "$RTMP/candidates"
    sort -u "$RTMP/candidates" -o "$RTMP/candidates"
}
r_chain_walk() (
    file=$1; cwd=$2; depth=$3
    [ "$depth" -le 32 ] || r_die 'Configuration include cycle or excessive depth'
    case $file in /*) :;; *) file="$cwd/$file";; esac
    file=$(readlink -f "$file") || r_die 'Cannot resolve configuration include'
    [ -f "$file" ] && [ -r "$file" ] || r_die "Unreadable configuration include: $file"
    case $file in *'
'*|*'\t'*) r_die 'Unsupported configuration filename';; esac
    sha256sum "$file" || exit 1
    awk '/^[[:space:]]*!include(dir)?[[:space:]]/ {line=$0; sub(/^[[:space:]]*/,"",line); key=line; sub(/[[:space:]].*$/, "",key); sub(/^[^[:space:]]+[[:space:]]+/, "",line); sub(/[[:space:]]+$/, "",line); print key "\t" line}' "$file" > "$RTMP/include.$$.${depth}"
    tab=$(printf '\t')
    while IFS="$tab" read -r kind path; do
        case $path in \"*\") path=${path#\"}; path=${path%\"};; \'*\') path=${path#\'}; path=${path%\'};; esac
        case $path in /*) :;; *) path="$cwd/$path";; esac
        case $kind in
            '!include') r_chain_walk "$path" "$cwd" "$((depth+1))" || exit 1;;
            '!includedir')
                [ -d "$path" ] && [ -r "$path" ] || r_die "Unreadable includedir: $path"
                printf 'DIRECTORY %s\n' "$path"
                for child in "$path"/*.cnf; do
                    [ -e "$child" ] || continue
                    r_chain_walk "$child" "$cwd" "$((depth+1))" || exit 1
                done;;
        esac
    done < "$RTMP/include.$$.${depth}"
)

r_chain_snapshot() (
    r_chain_walk "$1" "$3" 0 > "$2.unsorted" || exit 1
    LC_ALL=C sort -u "$2.unsorted" > "$2"
    rm -f "$2.unsorted"
)

r_config_guard() {
    case $CNF in /*) :;; *) r_die 'Choose an absolute remote configuration path';; esac
    [ -f "$CNF" ] && [ ! -L "$CNF" ] || r_die 'Configuration must be a regular non-symlink file'
    [ "$(stat -c %h "$CNF")" = 1 ] || r_die 'Hard-linked config requires manual review'
    [ -w "$CNF" ] && [ -w "$(dirname "$CNF")" ] || r_die 'Insufficient OS permission to back up/apply config'
    if [ -n "$RDEFAULT" ]; then
        [ "$(readlink -f "$RDEFAULT")" = "$(readlink -f "$CNF")" ] || r_die 'Selected cnf is not the process --defaults-file'
    else
        grep -Fx -- "$CNF" "$RTMP/candidates" >/dev/null || r_die 'Selected config was not observed in runtime variable sources'
    fi
    grep -E '^--(no-defaults|defaults-group-suffix)(=|$)' "$RTMP/argv" >/dev/null && r_die 'Per-group/no-defaults startup needs separate configuration handling'
    # Refuse a config explicitly used by another mysqld; default-file-less peers
    # are also ambiguous when this server uses the default search path.
    for proc in /proc/[0-9]*/cmdline; do
        [ "$proc" != "/proc/$RPID/cmdline" ] || continue
        [ -r "$proc" ] || continue
        other_exe=$(readlink -f "${proc%/cmdline}/exe" 2>/dev/null || :)
        case ${other_exe##*/} in mysqld|mysqld-debug) :;; *) continue;; esac
        tr '\000' '\n' < "$proc" > "$RTMP/other_argv" || r_die 'Cannot inspect another mysqld'
        other_cnf=$(sed -n 's/^--defaults-file=//p' "$RTMP/other_argv" | head -n 1)
        if [ -n "$other_cnf" ]; then
            [ "$(readlink -f "$other_cnf")" != "$(readlink -f "$CNF")" ] || r_die 'Another mysqld shares this configuration'
        elif [ -z "$RDEFAULT" ]; then r_die 'Multiple mysqld processes use default configuration search paths'; fi
    done
}
r_restart_guard() {
    [ "$RMETHOD" != unknown ] || r_die 'Cannot safely identify the remote launcher; configuration can be applied with restart=no'
    if [ "$RMETHOD" != systemd ]; then
        [ "$(id -u)" = 0 ] || [ "$(id -u)" = "$RUID" ] || r_die 'Direct restart requires root or datadir owner'
        [ -n "$RDEFAULT" ] || r_die 'Direct restart requires explicit --defaults-file'
    fi
}
r_validate_candidate() {
    # Keep command-line overrides and defaults-extra-file; replace only defaults-file.
    set -- "--defaults-file=$CANDIDATE"
    first=yes
    while IFS= read -r arg; do
        if [ "$first" = yes ]; then first=no; continue; fi
        case $arg in --defaults-file=*|--daemonize|--daemonize=*) continue;; esac
        set -- "$@" "$arg"
    done < "$RTMP/argv"
    if [ "$(id -u)" = 0 ]; then set -- "$@" "--user=$ROWNER"; fi
    (cd "$RCWD"; "$REXE" "$@" --validate-config) > "$VALIDATE_LOG" 2>&1 || r_die "Config validation failed; original unchanged. Log: $VALIDATE_LOG"
}
r_same_process() {
    [ "$(awk '{print $22}' "/proc/$RPID/stat" 2>/dev/null || :)" = "$RSTART" ] || r_die 'mysqld process changed during the operation'
}
r_wait_exit() {
    pid=$1; start=$2; attempts=0
    while [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || :)" = "$start" ]; do
        [ "$attempts" -lt 150 ] || r_die 'Shutdown timed out; no replacement process launched'
        sleep 2; attempts=$((attempts+1))
    done
}
r_runtime_check() {
    printf '%s\n' "$SNIPPET" > "$RTMP/expected_settings"
    while IFS='=' read -r key wanted; do
        case $key in ''|'#'*|'['*) continue;; *[!a-z_]*) r_die 'Unexpected generated variable name';; esac
        [ "$key" != log_bin ] || wanted=ON
        actual=$(r_sql "SELECT @@GLOBAL.$key;")
        case "$wanted:$actual" in ON:1|ON:ON|OFF:0|OFF:OFF) :;;
            *) [ "$actual" = "$wanted" ] || r_die "Runtime $key=$actual differs from $wanted; inspect persisted variables and command-line overrides";;
        esac
    done < "$RTMP/expected_settings"
    printf 'RUNTIME_CONFIG\tPASSED\n'
}
r_restart() {
    r_same_process
    if [ "$RMETHOD" = systemd ]; then
        [ "$(systemctl show "$RSERVICE" -p MainPID --value)" = "$RPID" ] || r_die 'Service MainPID changed'
        systemctl restart "$RSERVICE" || r_die 'systemd restart failed'
    else
        # SQL SHUTDOWN tells mysqld_safe to exit instead of restarting a crashed child.
        r_sql 'SHUTDOWN;' || r_die 'SQL shutdown failed'
        r_wait_exit "$RPID" "$RSTART"
        if [ "$RMETHOD" = mysqld_safe ]; then
            r_wait_exit "$RPARENT" "$SAFESTART"
            set --
            while IFS= read -r arg; do set -- "$@" "$arg"; done < "$RTMP/safe_argv"
            (cd "$SAFE_CWD"; nohup "$@" </dev/null >> "$START_LOG" 2>&1 &) 
        else
            set --; first=yes
            while IFS= read -r arg; do
                if [ "$first" = yes ]; then first=no; continue; fi
                case $arg in --daemonize|--daemonize=*) continue;; esac
                set -- "$@" "$arg"
            done < "$RTMP/argv"
            if [ "$(id -u)" = 0 ]; then set -- "$@" "--user=$ROWNER"; fi
            (cd "$RCWD"; "$REXE" "$@" --daemonize) >> "$START_LOG" 2>&1 || r_die "Direct startup failed; inspect $START_LOG"
        fi
    fi
    attempts=0
    while [ "$attempts" -lt 90 ]; do
        actual=$(r_sql 'SELECT @@server_uuid;' 2>/dev/null || :)
        if [ "$actual" = "$EXPECTED_UUID" ]; then r_runtime_check; printf 'RESTART\tOK\n'; return; fi
        [ -z "$actual" ] || r_die 'Unexpected instance after restart'
        sleep 2; attempts=$((attempts+1))
    done
    r_die 'Restarted instance did not reconnect; preserve backup and inspect server logs'
}
r_tls_paths() {
    RTLS_DATA=${EXPECTED_DATA%/}
    RTLS_CA=$(r_sql 'SELECT @@GLOBAL.ssl_ca;')
    RTLS_CERT=$(r_sql 'SELECT @@GLOBAL.ssl_cert;')
    RTLS_KEY=$(r_sql 'SELECT @@GLOBAL.ssl_key;')
    case $RTLS_CA in /*) :;; '') r_die 'Runtime ssl_ca is empty';; *) RTLS_CA="$RTLS_DATA/$RTLS_CA";; esac
    case $RTLS_CERT in /*) :;; '') r_die 'Runtime ssl_cert is empty';; *) RTLS_CERT="$RTLS_DATA/$RTLS_CERT";; esac
    case $RTLS_KEY in /*) :;; '') r_die 'Runtime ssl_key is empty';; *) RTLS_KEY="$RTLS_DATA/$RTLS_KEY";; esac
}
r_tls_selinux_report() {
    mode=Disabled
    if command -v getenforce >/dev/null 2>&1; then mode=$(getenforce 2>/dev/null || printf 'Unknown'); fi
    printf 'SELINUX_MODE\t%s\n' "$mode"
    for f in "$RTLS_CA" "$RTLS_CERT" "$RTLS_KEY"; do
        [ -e "$f" ] || continue
        printf 'SELINUX_CONTEXT\t%s\t%s\n' "$f" "$(stat -c %C "$f" 2>/dev/null || printf '?')"
    done
}
r_selinux_port_contains() {
    wanted=$1
    command -v semanage >/dev/null 2>&1 || return 2
    semanage port -l > "$RTMP/semanage_ports" 2>/dev/null || return 2
    awk '$1=="mysqld_port_t" && $2=="tcp" {for(i=3;i<=NF;i++) print $i}' "$RTMP/semanage_ports" | tr ',' '\n' | tr -d ' ' > "$RTMP/mysqld_ports" || return 2
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        case $spec in
            *-*) lo=${spec%-*}; hi=${spec#*-}; case $lo:$hi in *[!0-9:]*|:*) continue;; esac; [ "$wanted" -ge "$lo" ] && [ "$wanted" -le "$hi" ] && return 0;;
            *) [ "$wanted" = "$spec" ] && return 0;;
        esac
    done < "$RTMP/mysqld_ports"
    return 1
}
r_selinux_gr_port_preflight() {
    mode=Disabled
    if command -v getenforce >/dev/null 2>&1; then mode=$(getenforce 2>/dev/null || printf 'Unknown'); fi
    domain=$(tr -d '\000' < "/proc/$RPID/attr/current" 2>/dev/null || :)
    printf 'SELINUX_PROCESS_DOMAIN\t%s\n' "$domain"
    case $mode in Enforcing|Permissive) :;; *) return 0;; esac
    case $domain in *:mysqld_t:*) :;; *) printf 'SELINUX_PORT_CHECK\tSKIPPED_NON_MYSQLD_T\n'; return 0;; esac
    case $XCOM_PORT in ''|*[!0-9]*) r_die 'Invalid XCom port for SELinux preflight';; esac
    if r_selinux_port_contains "$XCOM_PORT"; then
        printf 'SELINUX_XCOM_PORT\t%s\tmysqld_port_t\n' "$XCOM_PORT"
        return 0
    else
        rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
        r_die "SELinux is $mode and mysqld runs in mysqld_t, but semanage is unavailable for read-only XCom port verification. No package is installed automatically; verify the existing host SELinux port policy manually before GR."
    fi
    r_die "SELinux XCom port $XCOM_PORT is not registered as mysqld_port_t. No semanage/policy change is performed automatically; register/review it on this host before GR."
}
r_tls_inspect() {
    command -v openssl >/dev/null 2>&1 || r_die 'Existing openssl is required; no package will be installed automatically'
    r_tls_paths
    [ "$ACTION" = tls-export ] || r_selinux_gr_port_preflight
    [ -r "$RTLS_CA" ] && [ -r "$RTLS_CERT" ] && [ -r "$RTLS_KEY" ] || r_die 'Runtime TLS CA/certificate/key is not readable on this host'
    openssl x509 -in "$RTLS_CERT" -noout -checkend 0 >/dev/null 2>&1 || r_die 'Runtime TLS certificate is invalid or expired'
    openssl x509 -in "$RTLS_CERT" -pubkey -noout > "$RTMP/tls.cert.pub" 2>/dev/null || r_die 'Cannot read TLS certificate public key'
    openssl pkey -in "$RTLS_KEY" -pubout > "$RTMP/tls.key.pub" 2>/dev/null || r_die 'Cannot read TLS private key'
    cmp -s "$RTMP/tls.cert.pub" "$RTMP/tls.key.pub" || r_die 'Runtime TLS certificate/key mismatch'
    set -- -CAfile "$RTLS_CA" -purpose sslserver
    if [ "$GR_TLS_MODE" = VERIFY_IDENTITY ] && [ "$ACTION" != tls-export ]; then
        case $ADVERTISE in *[!0-9.]*) set -- "$@" -verify_hostname "$ADVERTISE";; *) set -- "$@" -verify_ip "$ADVERTISE";; esac
    fi
    openssl verify "$@" "$RTLS_CERT" >/dev/null 2>&1 || r_die 'Runtime TLS certificate fails local CA/identity validation'
    RRECOVERY_CA=$RECOVERY_CA
    case $RRECOVERY_CA in /*) :;; '') RRECOVERY_CA=$RTLS_CA;; *) RRECOVERY_CA="$RTLS_DATA/$RRECOVERY_CA";; esac
    [ -r "$RRECOVERY_CA" ] || r_die 'Configured GR recovery CA is not readable on this host'
    printf 'TLS_CA_PATH\t%s\nTLS_CERT_PATH\t%s\nTLS_KEY_PATH\t%s\nTLS_RECOVERY_CA_PATH\t%s\n' "$RTLS_CA" "$RTLS_CERT" "$RTLS_KEY" "$RRECOVERY_CA"
    r_tls_selinux_report
    openssl x509 -in "$RTLS_CERT" -noout -fingerprint -sha256 | sed 's/^/TLS_CERT_FINGERPRINT\t/'
    openssl x509 -in "$RTLS_CA" -noout -fingerprint -sha256 | sed 's/^/TLS_CA_FINGERPRINT\t/'
    openssl x509 -in "$RRECOVERY_CA" -noout -fingerprint -sha256 | sed 's/^/TLS_RECOVERY_CA_FINGERPRINT\t/'
    tr -d '\000' < "$RTLS_CA" | awk '{print "TLS_CA_PEM\t" $0}'
    tr -d '\000' < "$RRECOVERY_CA" | awk '{print "TLS_RECOVERY_CA_PEM\t" $0}'
    tr -d '\000' < "$RTLS_CERT" | awk '{print "TLS_CERT_PEM\t" $0}'
    printf 'TLS_INSPECT\tPASSED\n'
}

r_tls_capture_avc() {
    out="$TLS_OUTPUT/tls_reload_avc.log"
    if command -v ausearch >/dev/null 2>&1; then
        ausearch -m AVC,USER_AVC -ts recent > "$out" 2>&1 || :
    elif [ -r /var/log/audit/audit.log ]; then
        grep -i 'avc:.*denied' /var/log/audit/audit.log | tail -100 > "$out" 2>/dev/null || :
    else
        printf '%s\n' 'AVC evidence unavailable; no package was installed.' > "$out"
    fi
}
r_tls_prepare_files() {
    [ "$(id -u)" = 0 ] || r_die 'TLS apply requires root on the MySQL host; no privilege escalation/package installation is attempted by the helper'
    command -v openssl >/dev/null 2>&1 || r_die 'Existing openssl is required; no package will be installed automatically'
    RTLS_DATA=${EXPECTED_DATA%/}
    case $TLS_OUTPUT in "$RTLS_DATA"/*) :;; *) r_die 'TLS output must be below the proven active datadir';; esac
    [ ! -e "$TLS_OUTPUT" ] || r_die 'TLS output path already exists; preserve it and review before retrying'
    r_tls_paths
    [ -r "$RTLS_CERT" ] || r_die 'Cannot read active certificate for rollback/SELinux comparison'
    old_ctx=$(stat -c %C "$RTLS_CERT" 2>/dev/null || :)
    old_type=$(printf '%s' "$old_ctx" | awk -F: 'NF>=3 {print $3}')
    mkdir "$TLS_OUTPUT" || r_die 'Cannot create TLS output directory'
    chmod 700 "$TLS_OUTPUT"
    printf '%s\n' "$TLS_CA_PEM" > "$TLS_OUTPUT/ca.pem"
    printf '%s\n' "$TLS_CERT_PEM" > "$TLS_OUTPUT/server-cert.pem"
    printf '%s\n' "$TLS_KEY_PEM" > "$TLS_OUTPUT/server-key.pem"
    chmod 644 "$TLS_OUTPUT/ca.pem" "$TLS_OUTPUT/server-cert.pem"
    chmod 600 "$TLS_OUTPUT/server-key.pem"
    chown -R "$(stat -c %u "$RTLS_DATA"):$(stat -c %g "$RTLS_DATA")" "$TLS_OUTPUT"
    openssl x509 -in "$TLS_OUTPUT/server-cert.pem" -noout -checkend 0 >/dev/null 2>&1 || r_die 'Prepared TLS certificate invalid/expired'
    openssl x509 -in "$TLS_OUTPUT/server-cert.pem" -pubkey -noout > "$RTMP/new.cert.pub" 2>/dev/null || r_die 'Cannot read prepared TLS certificate public key'
    openssl pkey -in "$TLS_OUTPUT/server-key.pem" -pubout > "$RTMP/new.key.pub" 2>/dev/null || r_die 'Cannot read prepared TLS key'
    cmp -s "$RTMP/new.cert.pub" "$RTMP/new.key.pub" || r_die 'Prepared TLS certificate/key mismatch'
    set -- -CAfile "$TLS_OUTPUT/ca.pem" -purpose sslserver
    if [ "$GR_TLS_MODE" = VERIFY_IDENTITY ]; then
        case $ADVERTISE in *[!0-9.]*) set -- "$@" -verify_hostname "$ADVERTISE";; *) set -- "$@" -verify_ip "$ADVERTISE";; esac
    fi
    openssl verify "$@" "$TLS_OUTPUT/server-cert.pem" >/dev/null 2>&1 || r_die 'Prepared TLS certificate fails CA/SAN validation'
    mode=Disabled
    if command -v getenforce >/dev/null 2>&1; then mode=$(getenforce 2>/dev/null || printf 'Unknown'); fi
    printf '%s\n' "$mode" > "$TLS_OUTPUT/selinux_mode.before"
    case $mode in Enforcing|Permissive)
        command -v restorecon >/dev/null 2>&1 || r_die "SELinux is $mode but restorecon is unavailable. No package will be installed; configure the existing host SELinux tooling/policy manually."
        restorecon -R "$TLS_OUTPUT" > "$TLS_OUTPUT/restorecon.log" 2>&1 || r_die 'restorecon failed for prepared TLS files'
        new_ctx=$(stat -c %C "$TLS_OUTPUT/server-cert.pem" 2>/dev/null || :)
        new_type=$(printf '%s' "$new_ctx" | awk -F: 'NF>=3 {print $3}')
        printf 'ACTIVE\t%s\t%s\nNEW\t%s\t%s\n' "$RTLS_CERT" "$old_ctx" "$TLS_OUTPUT/server-cert.pem" "$new_ctx" > "$TLS_OUTPUT/selinux_context.tsv"
        [ -n "$old_type" ] && [ "$old_type" != '?' ] || r_die 'Cannot determine active TLS SELinux type'
        [ "$new_type" = "$old_type" ] || r_die 'Prepared TLS SELinux type differs from active certificate type; no semanage/chcon/policy installation is performed automatically'
        ;;
    esac
}
r_tls_apply() {
    r_config_guard
    r_tls_prepare_files
    CFGLOCK="${CNF}.gr_tls_lock"; mkdir "$CFGLOCK" || { CFGLOCK=''; r_die 'TLS configuration is locked by another operation'; }
    stamp="$(date +%Y%m%d_%H%M%S)_$$"
    VALIDATE_LOG="$TLS_OUTPUT/config_validation.log"
    START_LOG="$TLS_OUTPUT/start_unused.log"
    CANDIDATE=$(mktemp "${CNF}.gr_tls_candidate.XXXXXX")
    cp -a "$CNF" "$CANDIDATE"
    r_chain_snapshot "$CNF" "$TLS_OUTPUT/include.before" "$RCWD"
    cp -a "$CNF" "$TLS_OUTPUT/cnf.before"
    r_sql "SELECT CONCAT('SET GLOBAL ssl_ca=',QUOTE(@@ssl_ca),'; SET GLOBAL ssl_cert=',QUOTE(@@ssl_cert),'; SET GLOBAL ssl_key=',QUOTE(@@ssl_key),'; ALTER INSTANCE RELOAD TLS;');" > "$TLS_OUTPUT/runtime_restore.sql"
    sed '/^# BEGIN mysql_gr_tls$/,/^# END mysql_gr_tls$/d' "$CNF" > "$RTMP/tls.cnf"
    printf '\n# BEGIN mysql_gr_tls\n[mysqld]\nssl_ca=%s/ca.pem\nssl_cert=%s/server-cert.pem\nssl_key=%s/server-key.pem\n# END mysql_gr_tls\n' "$TLS_OUTPUT" "$TLS_OUTPUT" "$TLS_OUTPUT" >> "$RTMP/tls.cnf"
    cat "$RTMP/tls.cnf" > "$CANDIDATE"
    r_validate_candidate
    r_same_process
    r_chain_snapshot "$CNF" "$TLS_OUTPUT/include.current" "$RCWD"
    cmp -s "$TLS_OUTPUT/include.before" "$TLS_OUTPUT/include.current" || r_die 'TLS configuration include chain changed concurrently'
    cmp -s "$CNF" "$TLS_OUTPUT/cnf.before" || r_die 'TLS configuration changed concurrently'
    BACKUP="${CNF}.before_gr_tls_${stamp}"
    [ ! -e "$BACKUP" ] || r_die 'TLS config backup already exists'
    cp -a "$CNF" "$BACKUP"; cmp -s "$CNF" "$BACKUP" || r_die 'TLS config backup verification failed'
    printf '%s\n' "$BACKUP" > "$TLS_OUTPUT/cnf_backup_path"
    cat "$CANDIDATE" > "$CNF"; rm -f "$CANDIDATE"; CANDIDATE=''
    if ! r_sql "SET GLOBAL ssl_ca='$(printf '%s' "$TLS_OUTPUT/ca.pem" | sed "s/'/''/g")'; SET GLOBAL ssl_cert='$(printf '%s' "$TLS_OUTPUT/server-cert.pem" | sed "s/'/''/g")'; SET GLOBAL ssl_key='$(printf '%s' "$TLS_OUTPUT/server-key.pem" | sed "s/'/''/g")'; ALTER INSTANCE RELOAD TLS;" > "$TLS_OUTPUT/reload.log" 2>&1; then
        r_tls_capture_avc
        cat "$TLS_OUTPUT/cnf.before" > "$CNF" || :
        r_sql "$(cat "$TLS_OUTPUT/runtime_restore.sql")" >> "$TLS_OUTPUT/reload.log" 2>&1 || :
        r_die "TLS reload failed; previous cnf/runtime restore attempted. Inspect $TLS_OUTPUT/reload.log and $TLS_OUTPUT/tls_reload_avc.log"
    fi
    actual=$(r_sql "SELECT CONCAT(@@ssl_ca,'|',@@ssl_cert,'|',@@ssl_key);")
    [ "$actual" = "$TLS_OUTPUT/ca.pem|$TLS_OUTPUT/server-cert.pem|$TLS_OUTPUT/server-key.pem" ] || {
        cat "$TLS_OUTPUT/cnf.before" > "$CNF" || :
        r_sql "$(cat "$TLS_OUTPUT/runtime_restore.sql")" >/dev/null 2>&1 || :
        r_die 'Runtime TLS paths differ after reload; rollback attempted'
    }
    : > "$TLS_OUTPUT/APPLIED"
    printf 'TLS_APPLIED\t%s\nTLS_BACKUP\t%s\n' "$TLS_OUTPUT" "$BACKUP"
    # Emit host-side evidence so a no-SSH controller can later verify/adopt the
    # exact manually applied plan without storing the DB password.
    RECOVERY_CA="$TLS_OUTPUT/ca.pem"
    r_tls_inspect
}
r_tls_rollback() {
    [ "$(id -u)" = 0 ] || r_die 'TLS rollback requires root on the MySQL host'
    [ -d "$TLS_OUTPUT" ] && [ -f "$TLS_OUTPUT/APPLIED" ] || r_die 'No applied TLS state found for rollback'
    [ -r "$TLS_OUTPUT/cnf.before" ] && [ -r "$TLS_OUTPUT/runtime_restore.sql" ] || r_die 'TLS rollback evidence is incomplete'
    r_config_guard
    r_same_process
    cat "$TLS_OUTPUT/cnf.before" > "$CNF" || r_die 'Cannot restore previous TLS cnf'
    r_sql "$(cat "$TLS_OUTPUT/runtime_restore.sql")" > "$TLS_OUTPUT/rollback.log" 2>&1 || r_die 'Cannot restore previous runtime TLS settings'
    mv "$TLS_OUTPUT/APPLIED" "$TLS_OUTPUT/ROLLED_BACK"
    printf 'TLS_ROLLBACK\tPASSED\n'
}

r_main() {
    RTMP=$(mktemp -d "${TMPDIR:-/tmp}/mysql_gr_remote.XXXXXX")
    trap r_cleanup 0; trap 'exit 130' 2; trap 'exit 143' 1 15
    RMYSQL="${BASEDIR%/}/bin/mysql"
    [ -x "$RMYSQL" ] || RMYSQL=$(command -v mysql) || r_die 'Remote mysql client not found'
    escaped_socket=$(printf '%s' "$EXPECTED_SOCKET" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '[client]\n%s\nprotocol=SOCKET\nsocket="%s"\nconnect-timeout=10\n' "$CLIENT_AUTH" "$escaped_socket" > "$RTMP/client.cnf"
    unset CLIENT_AUTH
    r_identity
    printf 'UUID\t%s\nPID\t%s\nBINARY\t%s\nLAUNCHER\t%s\nSERVICE\t%s\n' "$EXPECTED_UUID" "$RPID" "$REXE" "$RMETHOD" "$RSERVICE"
    [ ! -r /etc/machine-id ] || printf 'HOST_ID\t%s\n' "$(cat /etc/machine-id)"
    printf 'DEFAULT_CNF\t%s\n' "$RDEFAULT"
    while IFS= read -r f; do printf 'CANDIDATE\t%s\n' "$f"; done < "$RTMP/candidates"
    if [ "$ACTION" = tls-inspect ] || [ "$ACTION" = tls-export ]; then r_tls_inspect; return 0; fi
    if [ "$ACTION" = tls-apply ]; then r_tls_apply; return 0; fi
    if [ "$ACTION" = tls-rollback ]; then r_tls_rollback; return 0; fi
    [ "$ACTION" != inspect ] || return 0
    if [ "$ACTION" = manual ]; then
        [ -n "$CNF" ] || CNF=$RDEFAULT
        printf 'Actual main cnf path [%s]: ' "$CNF" >&2
        IFS= read -r chosen || r_die 'Input ended'; CNF=${chosen:-$CNF}
    fi
    r_config_guard
    [ "$DO_RESTART" != yes ] || r_restart_guard
    CFGLOCK="${CNF}.gr_lock"; mkdir "$CFGLOCK" || { CFGLOCK=''; r_die 'Remote config is locked by another operation'; }
    stamp="$(date +%Y%m%d_%H%M%S)_$$"
    VALIDATE_LOG="${CNF}.gr_validate_${stamp}.log"
    START_LOG="${CNF}.gr_start_${stamp}.log"
    CANDIDATE=$(mktemp "${CNF}.gr_candidate.XXXXXX")
    cp -a "$CNF" "$CANDIDATE"
    r_chain_snapshot "$CNF" "$RTMP/include.before" "$RCWD"
    cp -a "$CNF" "$RTMP/original.cnf"
    sed '/^# BEGIN mysql_gr_migrate$/,/^# END mysql_gr_migrate$/d' "$CNF" > "$RTMP/config"
    printf '\n# BEGIN mysql_gr_migrate\n%s\n# END mysql_gr_migrate\n' "$SNIPPET" >> "$RTMP/config"
    cat "$RTMP/config" > "$CANDIDATE"
    r_validate_candidate
    printf 'CONFIG_VALIDATION\tPASSED\n'
    [ "$ACTION" != plan ] || return 0
    if [ "$ACTION" = manual ]; then
        printf '\n--- Current cnf merged with proposed settings: %s ---\n' "$CNF"
        cat "$CANDIDATE"
        printf '\nBack up and apply this complete candidate? Type APPLY: ' >&2
        IFS= read -r answer || r_die 'Input ended'
        [ "$answer" = APPLY ] || { printf 'CONFIG_APPLIED\tNO\n'; return 0; }
        printf 'Restart the detected instance now? (yes/no) [no]: ' >&2
        IFS= read -r answer || r_die 'Input ended'; DO_RESTART=${answer:-no}
        case $DO_RESTART in yes) r_restart_guard;; no) :;; *) r_die 'Choose yes/no';; esac
        ACTION=apply
    fi
    [ "$ACTION" = apply ] || r_die 'Unknown remote action'
    r_same_process
    r_chain_snapshot "$CNF" "$RTMP/include.current" "$RCWD"
    cmp -s "$RTMP/include.before" "$RTMP/include.current" || r_die 'Configuration include chain changed concurrently'
    cmp -s "$CNF" "$RTMP/original.cnf" || r_die 'Configuration changed concurrently; original left unchanged'
    BACKUP="${CNF}.before_gr_${stamp}"
    [ ! -e "$BACKUP" ] || r_die 'Backup already exists'
    cp -a "$CNF" "$BACKUP"
    cmp -s "$CNF" "$BACKUP" || r_die 'Backup verification failed'
    printf 'BACKUP\t%s\n' "$BACKUP"
    cmp -s "$CNF" "$RTMP/original.cnf" || r_die 'Configuration changed after backup; no replacement performed'
    mv -f "$CANDIDATE" "$CNF"; CANDIDATE=''
    printf 'CONFIG_APPLIED\t%s\n' "$CNF"
    [ "$DO_RESTART" != yes ] || r_restart
}
r_main
REMOTE_AGENT
}
configure_remote() {
    remote_node=$1; remote_snippet=$2
    if ! command -v ssh >/dev/null 2>&1; then
        log 'OpenSSH client unavailable; generating the manual helper without installing packages.'
        configure_manual "$remote_node" "$remote_snippet"
        return 0
    fi
    ssh_options "$remote_node"
    if ! remote_call "$remote_node" inspect > "$RUN/node_${remote_node}.remote_inspect.display"; then
        log 'SSH inspection failed. Preparing a password-free helper to copy and run on that host.'
        configure_manual "$remote_node" "$remote_snippet"
        return 0
    fi
    cat "$RUN/node_${remote_node}.remote_inspect.display" >&2
    current_cnf=$(get "$remote_node" cnf)
    [ -n "$current_cnf" ] || current_cnf=$(awk -F '\t' '$1=="DEFAULT_CNF" {print $2;exit}' "$RUN/node_${remote_node}.remote_inspect.display")
    selected_cnf=$(required "Node $remote_node remote main cnf path" "$current_cnf")
    put "$remote_node" cnf "$selected_cnf"
    if ! remote_call "$remote_node" plan "$remote_snippet" no >&2; then
        log 'Remote plan did not complete. Use the helper on that host to inspect and resolve the reported configuration issue.'
        configure_manual "$remote_node" "$remote_snippet"
        return 0
    fi
    log "Remote node $remote_node: back up $selected_cnf, apply the displayed configuration, optionally restart the detected instance."
    [ "$(ask 'Apply this remote configuration? (yes/no)' no)" = yes ] || return 0
    restart=$(required 'Restart this remote instance after applying? (yes/no)' yes)
    case $restart in yes|no) :;; *) die 'Choose yes or no';; esac
    remote_call "$remote_node" apply "$remote_snippet" "$restart" >&2
    if [ "$restart" = yes ]; then wait_connection "$remote_node"; fi
}

# Read only simple quoted values written by the legacy GTID script. Never source/eval it.
legacy_field() (
    file=$1; key=$2
    [ -r "$file" ] || exit 0
    sed -n "s/^${key}='\\([^']*\\)'$/\\1/p" "$file" | head -n 1
)
legacy_cnf_candidate() (
    i=$1
    file=${MYSQL_GR_GTID_STATE_FILE:-${MYSQL_GTID_STATE_FILE:-"$(pwd)/.mysql_gtid_replication.state"}}
    [ -r "$file" ] || exit 0
    for role in SOURCE REPLICA; do
        mode=$(legacy_field "$file" "${role}_MODE")
        matched=no
        if [ "$mode" = socket ]; then
            sock=$(legacy_field "$file" "${role}_SOCKET")
            [ -z "$sock" ] || [ "$sock" != "$(val "$i" socket)" ] || matched=yes
        elif [ "$mode" = tcp ] && [ "$(get "$i" mode)" = tcp ]; then
            if [ "$(legacy_field "$file" "${role}_HOST")" = "$(get "$i" host)" ] && [ "$(legacy_field "$file" "${role}_PORT")" = "$(get "$i" port)" ]; then matched=yes; fi
        fi
        if [ "$matched" = yes ]; then
            candidate=$(legacy_field "$file" "${role}_CNF")
            if [ -n "$candidate" ]; then printf '%s' "$candidate"; exit 0; fi
        fi
    done
)
configure_manual() (
    i=$1; snippet=$2
    file="$RUN/node_${i}_apply_config.sh"
    {
        printf '#!/bin/sh\n# Generated remote configuration helper v%s; no stored credentials.\nset -eu\numask 077\n' "$VERSION"
        printf "ACTION='manual'\nDO_RESTART='no'\n"
        printf 'VERSION=%s\n' "$(shell_quote "$VERSION")"
        printf 'EXPECTED_UUID=%s\n' "$(shell_quote "$(get "$i" uuid)")"
        printf 'EXPECTED_DATA=%s\n' "$(shell_quote "$(val "$i" datadir)")"
        printf 'EXPECTED_SOCKET=%s\n' "$(shell_quote "$(val "$i" socket)")"
        printf 'EXPECTED_PID_FILE=%s\n' "$(shell_quote "$(val "$i" pid_file)")"
        printf 'BASEDIR=%s\n' "$(shell_quote "$(val "$i" basedir)")"
        printf 'CNF=%s\n' "$(shell_quote "$(get "$i" cnf)")"
        printf 'SNIPPET=%s\n' "$(shell_quote "$(cat "$snippet")")"
        printf 'DEFAULT_DB_USER=%s\n' "$(shell_quote "$(get "$i" user)")"
        cat <<'MANUAL_AUTH'
printf 'Socket MySQL admin user [%s]: ' "$DEFAULT_DB_USER" >&2
IFS= read -r db_user || exit 1; db_user=${db_user:-$DEFAULT_DB_USER}
printf 'Socket MySQL admin password: ' >&2
saved_tty=''
if [ -t 0 ]; then
    saved_tty=$(stty -g)
    trap 'stty "$saved_tty"' 0
    trap 'exit 1' 1 2 15
    stty -echo
fi
IFS= read -r db_password || exit 1
[ -z "$saved_tty" ] || stty "$saved_tty"
trap - 0 1 2 15
printf '\n' >&2
manual_option_quote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
CLIENT_AUTH=$(printf 'user="%s"\npassword="%s"' "$(manual_option_quote "$db_user")" "$(manual_option_quote "$db_password")")
unset db_password
MANUAL_AUTH
        remote_agent
    } > "$file"
    sh -n "$file" || die 'Generated manual helper has invalid syntax'
    log "Node $i manual configuration (SSH not required):"
    log "  Copy this helper to the actual MySQL host: $file"
    log "  On that host run: sh node_${i}_apply_config.sh"
    log '  The helper discovers/checks the active cnf, copies its current content into a candidate, merges the GR settings, and prints the full candidate for copying.'
    log '  It validates with the actual mysqld binary, then asks before backup/apply/restart.'
    log '  Enter the local socket DB credentials there. No password is stored in this helper.'
    log '  After completing each remote node, rerun precheck on this controller.'
    log 'Settings to copy into the selected cnf (replace only the existing managed block):'
    cat "$snippet" >&2
    printf 'Node %s current cnf candidate: %s\n' "$i" "$(get "$i" cnf)" >&2
    if [ "$(ask 'Print the complete helper for clipboard copying? (yes/no)' yes)" = yes ]; then cat "$file"; fi
)

configure() {
    PHASE=configure
    put meta mutation_started configure
    connected; no_group; endpoints_check
    while :; do
    log '  minimum   : GR-required settings only; preserves existing durability policy where possible.'
    log '  production: minimum + sync_binlog=1, innodb_flush_log_at_trx_commit=1 and FULL row image.'
    profile=$(required 'Configuration profile (minimum/production)' minimum)
    case $profile in
        minimum|min) profile=minimum; break;;
        production|prod) profile=production; break;;
        *) log 'Invalid profile. Enter minimum/min or production/prod.';;
    esac
done
    put meta profile "$profile"
    if [ "$profile" = production ]; then
        log 'Production profile adds sync_binlog=1, innodb_flush_log_at_trx_commit=1 and FULL row image; storage I/O can increase.'
        for i in $(ids); do
            retention=$(required "Node $i binary log retention seconds (must cover provisioning/recovery)" "$(val "$i" binlog_expire_logs_seconds)")
            uint "$retention" && [ "$retention" -le 4294967295 ] || die 'Invalid retention'
            put "$i" retention "$retention"
        done
    fi
    seen=' '
    for i in $(ids); do
        sid=$(val "$i" server_id)
        case $seen in *" $sid "*) sid='';; esac
        [ "$sid" != 0 ] || sid=''
        sid=$(required "Node $i unique server_id" "$sid")
        uint "$sid" && [ "$sid" -gt 0 ] && [ "$sid" -le 4294967295 ] || die 'Invalid server_id'
        case $seen in *" $sid "*) die 'Duplicate server_id';; esac
        seen="$seen$sid "
        snippet="$RUN/node_$i.cnf"
        config_lines "$i" "$sid" > "$snippet"
        log "Node $i proposed required configuration:"; cat "$snippet" >&2
        if [ -z "$(get "$i" cnf)" ]; then
            previous_cnf=$(legacy_cnf_candidate "$i")
            if [ -n "$previous_cnf" ]; then
                log "Node $i cnf candidate from matching GTID state: $previous_cnf (will be reverified on the actual host)"
                put "$i" cnf "$previous_cnf"
            fi
        fi
        if [ "$(get "$i" location)" = remote ]; then
            remote_mode=$(required "Node $i OS configuration method (ssh/manual)" manual)
            case $remote_mode in
                ssh) configure_remote "$i" "$snippet";;
                manual) configure_manual "$i" "$snippet";;
                *) die 'Choose ssh or manual';;
            esac
            continue
        fi
        if [ -z "$(get "$i" cnf)" ]; then
            log "Apply $snippet on node $i, restart that instance, then rerun precheck."
            continue
        fi
        [ "$(ask "Back up and apply node $i cnf? (yes/no)" no)" = yes ] || continue
        p=$(local_pid "$i") || die 'Cannot prove local instance identity'
        exe=$(readlink -f "/proc/$p/exe")
        cnf=$(get "$i" cnf); case $cnf in /*) :;; *) die 'cnf must be absolute';; esac
        [ -f "$cnf" ] && [ ! -L "$cnf" ] || die 'cnf must be a regular non-symlink file'
        # Multiple instances sharing one option file need group-specific editing.
        for j in $(ids); do
            [ "$j" = "$i" ] && continue
            if [ "$(get "$j" location)" = local ] && [ "$(get "$j" cnf)" = "$cnf" ]; then die 'Shared cnf requires manual instance-specific settings'; fi
        done
        candidate="${cnf}.gr_candidate_$$"
        sed '/^# BEGIN mysql_gr_migrate$/,/^# END mysql_gr_migrate$/d' "$cnf" > "$candidate"
        { printf '\n# BEGIN mysql_gr_migrate\n'; cat "$snippet"; printf '# END mysql_gr_migrate\n'; } >> "$candidate"
        if ! "$exe" --defaults-file="$candidate" --validate-config > "$RUN/node_$i.config_validation.log" 2>&1; then
            rm -f "$candidate"; die "Configuration validation failed: $RUN/node_$i.config_validation.log"
        fi
        backup="${cnf}.before_gr_$(date +%Y%m%d_%H%M%S)_$$"
        cp -p "$cnf" "$backup"; cmp -s "$cnf" "$backup" || die 'Config backup verification failed'
        cat "$candidate" > "$cnf"; rm -f "$candidate"
        log "Saved backup: $backup"
        service=$(sed -n 's#.*\/\([^/]*\.service\)$#\1#p' "/proc/$p/cgroup" | head -n 1)
        if [ -n "$service" ] && command -v systemctl >/dev/null 2>&1 && [ "$(systemctl show "$service" -p MainPID --value)" = "$p" ]; then
            log "Restart command: systemctl restart $service"
            if [ "$(ask 'Restart now? (yes/no)' no)" = yes ]; then systemctl restart "$service"; wait_connection "$i"; fi
        else
            restart_direct "$i" "$p" "$exe" "$cnf"
        fi
    done
    log 'Configuration generation finished. Runtime precheck is mandatory before initialization.'
    [ "$STEP" = all ] || log 'NEXT: sh mysql_gr_migrate.sh precheck'
}
channels_check() (
    i=$1; ch=$(q "$(get "$i" channel)")
    all=$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT LIKE 'group_replication_%';")
    if [ "$(get "$i" kind)" = replica ]; then
        [ "$all" = 1 ] || die "Node $i must have exactly the selected async channel"
        [ "$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME='$ch' AND AUTO_POSITION=1;")" = 1 ] || die 'Selected channel is not GTID auto-positioned'
        [ "$(sql "$i" "SELECT SOURCE_UUID FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME='$ch';")" = "$(get 1 uuid)" ] || die 'Selected replica does not directly replicate from node 1'
    else [ "$all" = 0 ] || die "Node $i has an unexpected async channel"; fi
    [ "$(sql "$i" 'SELECT (SELECT COUNT(*) FROM performance_schema.replication_applier_filters)+(SELECT COUNT(*) FROM performance_schema.replication_applier_global_filters);')" = 0 ] || die "Node $i has replication filters"
    case $(get "$i" version) in 8.0.*) bs='SHOW MASTER STATUS;';; *) bs='SHOW BINARY LOG STATUS;';; esac
    binstatus=$(sql "$i" "$bs")
    printf '%s\n' "$binstatus" | awk -F '\t' 'length($3)>0 || length($4)>0 {exit 1}' || die 'Binary log filters are not supported'
)
schema_check() (
    i=$1
    bad=$(sql "$i" "SELECT CONCAT(t.TABLE_SCHEMA,'.',t.TABLE_NAME,' engine=',COALESCE(t.ENGINE,'NULL')) FROM information_schema.tables t WHERE t.TABLE_TYPE='BASE TABLE' AND t.TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') AND (t.ENGINE <> 'InnoDB' OR NOT EXISTS (SELECT 1 FROM information_schema.statistics s WHERE s.TABLE_SCHEMA=t.TABLE_SCHEMA AND s.TABLE_NAME=t.TABLE_NAME AND s.NON_UNIQUE=0 GROUP BY s.INDEX_NAME HAVING SUM(CASE WHEN s.NULLABLE='YES' OR s.COLUMN_NAME IS NULL THEN 1 ELSE 0 END)=0));")
    [ -z "$bad" ] || { log "$bad"; die "Node $i needs InnoDB and primary/non-null unique keys"; }
    if [ "$(get meta primary_mode)" = multi ]; then
        [ "$(val "$i" transaction_isolation)" != SERIALIZABLE ] || die 'Multi-primary does not support SERIALIZABLE write transactions'
        cascades=$(sql "$i" "SELECT CONCAT(CONSTRAINT_SCHEMA,'.',TABLE_NAME,':',CONSTRAINT_NAME) FROM information_schema.referential_constraints WHERE DELETE_RULE IN ('CASCADE','SET NULL') OR UPDATE_RULE IN ('CASCADE','SET NULL');")
        [ -z "$cascades" ] || { log "$cascades"; die 'Multi-primary cascading foreign keys require schema/application review'; }
    fi
)
precheck() {
    connected; no_group; endpoints_check
    tls_preflight
    seen=' '
    for i in $(ids); do
        sid=$(val "$i" server_id); [ "$sid" -gt 0 ] || die 'server_id=0'
        case $seen in *" $sid "*) die 'Duplicate server_id';; esac; seen="$seen$sid "
        [ "$(val "$i" version)" = "$(get 1 version)" ] || die 'Version changed/mixed version'
        for pair in 'log_bin ON' 'gtid_mode ON' 'enforce_gtid_consistency ON' 'binlog_format ROW' 'log_replica_updates ON' 'replica_preserve_commit_order ON' 'skip_replica_start ON'; do
            set -- $pair; actual=$(val "$i" "$1")
            case "$2:$actual" in ON:1|ON:ON|ROW:ROW) :;; *) die "Node $i $1=$actual; configure/restart required";; esac
        done
        for pair in 'transaction_write_set_extraction XXHASH64' 'replica_parallel_type LOGICAL_CLOCK' 'master_info_repository TABLE' 'relay_log_info_repository TABLE'; do
            set -- $pair
            if hasvar "$i" "$1"; then [ "$(val "$i" "$1")" = "$2" ] || die "Node $i: $1 must be $2"; fi
        done
        for variable in lower_case_table_names default_table_encryption; do
            [ "$(val "$i" "$variable")" = "$(val 1 "$variable")" ] || die "Member mismatch: $variable"
        done
        [ "$(val "$i" report_host)" = "$(get "$i" advertise)" ] || die "Node $i report_host requires configure/restart"
        [ "$(val "$i" report_port)" = "$(get "$i" sql_port)" ] || die "Node $i report_port mismatch"
        [ -n "$(val "$i" ssl_cert)" ] && [ -n "$(val "$i" ssl_key)" ] || die 'Server TLS certificate/key required'
        [ "$(sql "$i" "SELECT COUNT(*) FROM information_schema.plugins WHERE PLUGIN_NAME='clone' AND PLUGIN_STATUS='ACTIVE';")" = 0 ] || die 'Active Clone plugin needs a separately reviewed clone workflow; this workflow is incremental-only'
        channels_check "$i"; schema_check "$i"
        if hasvar "$i" xa_detach_on_prepare; then
            case $(val "$i" xa_detach_on_prepare) in 1|ON) :;; *) die "Node $i xa_detach_on_prepare must be ON for this GR workflow";; esac
        fi
        sql "$i" 'XA RECOVER;' > "$RUN/node_$i.xa.tsv"
        [ ! -s "$RUN/node_$i.xa.tsv" ] || die 'Prepared XA must be resolved before migration'
        sql "$i" 'SHOW GLOBAL VARIABLES;' > "$RUN/node_$i.variables.tsv"
        sql "$i" 'SELECT @@version,@@server_uuid,@@server_id,@@gtid_executed,@@gtid_purged,@@read_only,@@super_read_only,@@event_scheduler;' > "$RUN/node_$i.precheck.tsv"
    done
    log 'PRECHECK PASSED'
    [ "$STEP" != precheck ] || log 'NEXT: sh mysql_gr_migrate.sh initialize'
}
fence() {
    log 'Stop application writers, DDL jobs, backup/restore jobs and privileged maintenance connections first.'
    confirm 'WRITERS STOPPED' 'STOPPED'
    for i in $(ids); do
        if [ ! -f "$ROOT/$i/before_read_only" ]; then
            put "$i" before_read_only "$(val "$i" read_only)"
            put "$i" before_super_read_only "$(val "$i" super_read_only)"
            put "$i" before_event_scheduler "$(val "$i" event_scheduler)"
        fi
        if [ "$(val "$i" event_scheduler)" != DISABLED ]; then sql "$i" 'SET GLOBAL event_scheduler=OFF;'; fi
        sql "$i" 'SET GLOBAL super_read_only=ON;'
        [ "$(sql "$i" "SELECT COUNT(*) FROM information_schema.innodb_trx;")" = 0 ] || die "Node $i has active InnoDB transactions; drain then retry"
    done
}
normalize_gtid() {
    printf '%s' "$1" | tr -d '[:space:]'
}

gtid_origin() {
    extra=$(normalize_gtid "$1")
    node_uuid=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    source_uuid=$(printf '%s' "$3" | tr 'A-Z' 'a-z')
    [ -n "$extra" ] || { printf '%s' NONE; return; }
    local_seen=no; source_seen=no; other_seen=no
    for component in $(printf '%s' "$extra" | tr ',' ' '); do
        component=$(printf '%s' "$component" | tr 'A-Z' 'a-z')
        case $component in
            "${node_uuid}":*) local_seen=yes;;
            "${source_uuid}":*) source_seen=yes;;
            *) other_seen=yes;;
        esac
    done
    if [ "$other_seen" = yes ]; then
        printf '%s' THIRD_PARTY_OR_MIXED
    elif [ "$local_seen" = yes ] && [ "$source_seen" = yes ]; then
        printf '%s' LOCAL_AND_SOURCE_UUID
    elif [ "$local_seen" = yes ]; then
        printf '%s' LOCAL_NODE_UUID
    elif [ "$source_seen" = yes ]; then
        printf '%s' SOURCE_UUID
    else
        printf '%s' UNKNOWN
    fi
}

gtid_compare() {
    i=$1; target=$(normalize_gtid "$2")
    node_gtid=$(normalize_gtid "$(val "$i" gtid_executed)")
    node_purged=$(normalize_gtid "$(val "$i" gtid_purged)")
    extra=$(normalize_gtid "$(sql "$i" "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,'$(q "$target")');")")
    missing=$(normalize_gtid "$(sql "$i" "SELECT GTID_SUBTRACT('$(q "$target")',@@GLOBAL.gtid_executed);")")
    source_available=$(normalize_gtid "$(sql 1 'SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,@@GLOBAL.gtid_purged);')")
    unavailable=''
    if [ -n "$missing" ]; then
        unavailable=$(normalize_gtid "$(sql 1 "SELECT GTID_SUBTRACT('$(q "$missing")','$(q "$source_available")');")")
    fi
    source_uuid=$(get 1 uuid)
    node_uuid=$(get "$i" uuid)
    origin=$(gtid_origin "$extra" "$node_uuid" "$source_uuid")
    {
        printf 'FIELD\tVALUE\n'
        printf 'SOURCE_UUID\t%s\n' "$source_uuid"
        printf 'NODE_UUID\t%s\n' "$node_uuid"
        printf 'TARGET_GTID\t%s\n' "$target"
        printf 'NODE_GTID\t%s\n' "$node_gtid"
        printf 'NODE_GTID_PURGED\t%s\n' "$node_purged"
        printf 'EXTRA_GTID\t%s\n' "$extra"
        printf 'MISSING_GTID\t%s\n' "$missing"
        printf 'MISSING_UNAVAILABLE_ON_SOURCE\t%s\n' "$unavailable"
        printf 'EXTRA_ORIGIN\t%s\n' "$origin"
    } > "$RUN/node_${i}.gtid_compare.tsv"
    GTID_EXTRA=$extra
    GTID_MISSING=$missing
    GTID_UNAVAILABLE=$unavailable
    GTID_ORIGIN=$origin
    if [ -n "$extra" ] || [ -n "$missing" ]; then
        log "Node $i GTID comparison:"
        log "  Source UUID                  : $source_uuid"
        log "  Node UUID                    : $node_uuid"
        log "  Extra on Node $i             : ${extra:-NONE}"
        log "  Missing on Node $i           : ${missing:-NONE}"
        log "  Missing unavailable on Source: ${unavailable:-NONE}"
        log "  Extra origin                 : $origin"
        log "  Evidence                     : $RUN/node_${i}.gtid_compare.tsv"
    fi
}

gtid_guard() {
    i=$1; target=$2
    gtid_compare "$i" "$target"
    [ -z "$GTID_EXTRA" ] || die "Node $i contains extra/errant GTIDs ($GTID_ORIGIN). Review the recorded GTIDs and reconcile or externally reprovision; GTIDs are never reset automatically."
    [ -z "$GTID_UNAVAILABLE" ] || die "Node $i is missing GTIDs already purged from node 1 binary logs; incremental catch-up is not possible. Externally reprovision from the authoritative source."
}

mysqlbinlog_tool() (
    i=$1
    command -v "$BINLOG" >/dev/null 2>&1 || exit 1
    tool=$(command -v "$BINLOG")
    version_file="$RUN/node_${i}.mysqlbinlog_version.txt"
    "$tool" --version > "$version_file" 2>&1 || exit 1
    tool_version=$(sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' "$version_file" | head -n 1)
    server_version=$(get "$i" version | sed 's/[^0-9.].*//')
    [ -n "$tool_version" ] && [ "$tool_version" = "$server_version" ] || exit 1
    printf '%s' "$tool"
)

prepare_direct_binlogs() {
    i=$1; logs_file=$2; direct_file=$3
    : > "$direct_file"
    [ "$(get "$i" location)" = local ] || return 1
    binlog_basename=$(val "$i" log_bin_basename)
    [ -n "$binlog_basename" ] || return 1
    binlog_dir=$(dirname "$binlog_basename")
    tab=$(printf '\t')
    while IFS="$tab" read -r log_name file_size encrypted; do
        [ -n "$log_name" ] || continue
        case $log_name in */*|*'..'*) return 1;; esac
        case $encrypted in No|NO|no|0) :;; *) return 1;; esac
        full="$binlog_dir/$log_name"
        [ -f "$full" ] && [ ! -L "$full" ] && [ -r "$full" ] || return 1
        printf '%s\n' "$full" >> "$direct_file"
    done < "$logs_file"
    [ -s "$direct_file" ]
}

write_mysqlbinlog_command() {
    i=$1; include_gtids=$2; logs_file=$3; inspect_mode=$4; direct_file=$5
    cmd_file="$RUN/node_${i}.mysqlbinlog_command.sh"
    {
        printf '#!/bin/sh\n'
        printf '# Read-only GTID inspection helper. It never pipes mysqlbinlog output into mysql.\n'
        printf '# Use a mysqlbinlog client matching MySQL server version %s.\n' "$(get "$i" version)"
        printf 'mysqlbinlog --base64-output=DECODE-ROWS -vv '
        if [ "$inspect_mode" = direct ]; then
            shell_quote "--include-gtids=$include_gtids"; printf ' '
            while IFS= read -r full; do
                [ -n "$full" ] || continue
                shell_quote "$full"; printf ' '
            done < "$direct_file"
        else
            printf '%s ' '--read-from-remote-server'
            if [ "$(get "$i" mode)" = socket ]; then
                printf '%s ' '--protocol=SOCKET'
                shell_quote "--socket=$(get "$i" socket)"; printf ' '
            else
                printf '%s ' '--protocol=TCP'
                shell_quote "--host=$(get "$i" host)"; printf ' '
                shell_quote "--port=$(get "$i" port)"; printf ' '
                shell_quote "--ssl-mode=$(get "$i" admin_tls)"; printf ' '
                if [ -s "$ROOT/$i/admin_ca" ]; then
                    shell_quote "--ssl-ca=$(get "$i" admin_ca)"; printf ' '
                fi
            fi
            shell_quote "--user=$(get "$i" user)"; printf ' '
            printf '%s ' '--password'
            shell_quote "--include-gtids=$include_gtids"; printf ' '
            tab=$(printf '\t')
            while IFS="$tab" read -r log_name rest; do
                [ -n "$log_name" ] || continue
                shell_quote "$log_name"; printf ' '
            done < "$logs_file"
        fi
        printf '\n'
    } > "$cmd_file"
    chmod 700 "$cmd_file"
    printf '%s' "$cmd_file"
}

write_mysql_readonly_command() {
    i=$1; stmt=$2; out=$3
    {
        printf 'mysql '
        if [ "$(get "$i" mode)" = socket ]; then
            printf '%s ' '--protocol=SOCKET'
            shell_quote "--socket=$(get "$i" socket)"; printf ' '
        else
            printf '%s ' '--protocol=TCP'
            shell_quote "--host=$(get "$i" host)"; printf ' '
            shell_quote "--port=$(get "$i" port)"; printf ' '
            shell_quote "--ssl-mode=$(get "$i" admin_tls)"; printf ' '
            if [ -s "$ROOT/$i/admin_ca" ]; then
                shell_quote "--ssl-ca=$(get "$i" admin_ca)"; printf ' '
            fi
        fi
        shell_quote "--user=$(get "$i" user)"; printf ' '
        printf '%s ' '--password'
        printf '%s ' '-e'
        shell_quote "$stmt"
        printf '\n'
    } > "$out"
    chmod 700 "$out"
}

server_streaming_guidance() {
    i=$1; cmd_file=$2
    grants_file="$RUN/node_${i}.mysqlbinlog_streaming_grants.txt"
    check_file="$RUN/node_${i}.mysqlbinlog_streaming_check.sh"
    grant_file="$RUN/node_${i}.mysqlbinlog_streaming_grant.sql"
    account=$(sql "$i" 'SELECT CURRENT_USER();')
    sql "$i" 'SHOW GRANTS FOR CURRENT_USER;' > "$grants_file" 2>/dev/null || :
    write_mysql_readonly_command "$i" 'SHOW GRANTS FOR CURRENT_USER;' "$check_file"
    grant_stmt=$(sql "$i" "SELECT CONCAT('GRANT REPLICATION SLAVE ON *.* TO ',QUOTE(SUBSTRING_INDEX(CURRENT_USER(),'@',1)),'@',QUOTE(SUBSTRING_INDEX(CURRENT_USER(),'@',-1)),';');" 2>/dev/null || :)
    {
        printf '%s\n' '-- Run only through an authorized DBA account, and only if the streaming account lacks REPLICATION SLAVE.'
        printf '%s\n' "${grant_stmt:-GRANT REPLICATION SLAVE ON *.* TO '<mysql_user>'@'<account_host>'; }"
    } > "$grant_file"
    chmod 600 "$grants_file" "$grant_file" 2>/dev/null || :
    log 'SERVER-STREAMING PREREQUISITES (shown before automatic attempt):'
    log "  MySQL account                  : ${account:-UNKNOWN}"
    log '  Required privilege             : REPLICATION SLAVE'
    log "  Check current grants           : $check_file"
    log "  Captured grants                : $grants_file"
    log "  Authorized DBA grant template  : $grant_file"
    log "  Read-only mysqlbinlog command  : $cmd_file"
    log '  The script does NOT grant privileges automatically and never pipes mysqlbinlog output into mysql.'
}

external_manual_guidance() {
    i=$1; reason=$2
    guide="$RUN/node_${i}.external_reprovision_guide.txt"
    identity_cmd="$RUN/node_${i}.external_identity_check.sh"
    gtid_cmd="$RUN/node_${i}.external_gtid_check.sh"
    write_mysql_readonly_command "$i" 'SELECT @@hostname,@@port,@@socket,@@datadir,@@server_uuid,@@server_id;' "$identity_cmd"
    write_mysql_readonly_command "$i" 'SELECT @@GLOBAL.gtid_executed,@@GLOBAL.gtid_purged,@@GLOBAL.read_only,@@GLOBAL.super_read_only;' "$gtid_cmd"
    {
        printf 'Node %s requires external provisioning/reconciliation.\n' "$i"
        printf 'Reason: %s\n\n' "$reason"
        printf 'Run these read-only checks on/from a host that can reach the target before changing anything:\n'
        printf '  %s\n' "$identity_cmd"
        printf '  %s\n' "$gtid_cmd"
        printf '\nNo destructive restore/reset command is generated automatically. Select and validate the backup/provisioning method first.\n'
        printf 'After provisioning, verify server_uuid/instance identity and GTID state before rerunning migration.\n'
    } > "$guide"
    chmod 600 "$guide"
    log "Manual/external action guide          : $guide"
    log "  Identity check command             : $identity_cmd"
    log "  GTID/fence check command           : $gtid_cmd"
}

safe_mysql_object_name() {
    name=$1
    case $name in ''|*[!A-Za-z0-9_$]*) return 1;; *) return 0;; esac
}

show_create_statement() {
    kind=$1; object=$2
    case $kind in
        DATABASE|SCHEMA)
            safe_mysql_object_name "$object" || return 1
            printf 'SHOW CREATE DATABASE `%s`;' "$object"
            ;;
        TABLE|VIEW|EVENT|PROCEDURE|FUNCTION|TRIGGER)
            case $object in *.*) db=${object%%.*}; obj=${object#*.};; *) return 1;; esac
            safe_mysql_object_name "$db" || return 1
            safe_mysql_object_name "$obj" || return 1
            printf 'SHOW CREATE %s `%s`.`%s`;' "$kind" "$db" "$obj"
            ;;
        *) return 1;;
    esac
}

summarize_mysqlbinlog_evidence() {
    i=$1; evidence=$2
    summary="$RUN/node_${i}.errant_gtid_summary.tsv"
    awk -v OFS='\t' '
        BEGIN {
            gtid="UNKNOWN"; db=""
            print "GTID","CATEGORY","OPERATION","OBJECT","DETAIL"
        }
        function emit(cat,op,obj,detail, key) {
            gsub(/\t/," ",detail)
            key=gtid SUBSEP cat SUBSEP op SUBSEP obj SUBSEP detail
            if (!seen[key]++) print gtid,cat,op,obj,detail
        }
        /^use `/ {
            line=$0
            sub(/^use `/,"",line)
            sub(/`.*/,"",line)
            db=line
            next
        }
        /GTID_NEXT[[:space:]]*=/ {
            line=$0
            p=index(line,"\047")
            if (p>0) {
                tail=substr(line,p+1)
                q=index(tail,"\047")
                if (q>0) {
                    x=substr(tail,1,q-1)
                    if (x!="AUTOMATIC") gtid=x
                }
            }
            next
        }
        /^### INSERT INTO / {
            obj=$0; sub(/^### INSERT INTO /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","INSERT",obj,"")
            next
        }
        /^### UPDATE / {
            obj=$0; sub(/^### UPDATE /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","UPDATE",obj,"")
            next
        }
        /^### DELETE FROM / {
            obj=$0; sub(/^### DELETE FROM /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","DELETE",obj,"")
            next
        }
        /^### REPLACE INTO / {
            obj=$0; sub(/^### REPLACE INTO /,"",obj); sub(/[[:space:]].*$/,"",obj); gsub(/`/,"",obj)
            if (obj !~ /\./ && db!="") obj=db "." obj
            emit("DML","REPLACE",obj,"")
            next
        }
        {
            raw=$0
            line=raw
            sub(/^[[:space:]]+/,"",line)
            upper=toupper(line)
            if (upper ~ /^(CREATE|ALTER|DROP|RENAME|TRUNCATE)[[:space:]]+/) {
                split(upper,a,/[[:space:]]+/)
                op=a[1]
                if (match(upper,/(TABLE|EVENT|VIEW|PROCEDURE|FUNCTION|TRIGGER|DATABASE|SCHEMA)[[:space:]]+/)) {
                    kind=substr(upper,RSTART,RLENGTH)
                    gsub(/[[:space:]]/,"",kind)
                    rest=substr(line,RSTART+RLENGTH)
                    sub(/^[[:space:]]+/,"",rest)
                    if (op=="RENAME" && kind=="TABLE") {
                        clean=rest; gsub(/`/,"",clean)
                        pair_count=split(clean,pairs,/,/)
                        for (pi=1; pi<=pair_count; pi++) {
                            pair=pairs[pi]
                            sub(/^[[:space:]]+/,"",pair); sub(/[[:space:]]+$/,"",pair)
                            n=split(pair,rn,/[[:space:]]+[Tt][Oo][[:space:]]+/)
                            if (n==2) {
                                src=rn[1]; dst=rn[2]
                                sub(/[[:space:];].*$/,"",src); sub(/[[:space:];].*$/,"",dst)
                                if (src !~ /\./ && db!="") src=db "." src
                                if (dst !~ /\./ && db!="") dst=db "." dst
                                emit("DDL",op " " kind,src,line)
                                emit("DDL",op " " kind,dst,line)
                            } else emit("DDL",op " " kind,"UNKNOWN",line)
                        }
                    } else {
                        obj=rest
                        sub(/^[Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)
                        sub(/^[Ii][Ff][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)
                        sub(/[[:space:](;,].*$/,"",obj)
                        gsub(/`/,"",obj)
                        if (kind!="DATABASE" && kind!="SCHEMA" && obj !~ /\./ && db!="") obj=db "." obj
                        if (obj=="") obj="UNKNOWN"
                        emit("DDL",op " " kind,obj,line)
                    }
                } else {
                    emit("DDL",op " OBJECT","UNKNOWN",line)
                }
            }
        }
    ' "$evidence" > "$summary"
    chmod 600 "$summary"

    dml_count=$(awk -F '\t' 'NR>1 && $2=="DML" {n++} END{print n+0}' "$summary")
    ddl_count=$(awk -F '\t' 'NR>1 && $2=="DDL" {n++} END{print n+0}' "$summary")
    total=$(awk 'END{print (NR > 0 ? NR - 1 : 0)}' "$summary")
    log '[ Extra GTID Summary ]'
    if [ "$total" -eq 0 ]; then
        log '  No DML/DDL operation could be summarized automatically. Review the raw mysqlbinlog evidence.'
    else
        awk -F '\t' 'NR>1 && shown<80 {printf "  %s | %s | %s | %s\n",$1,$2,$3,$4; shown++} END{if (NR-1>80) printf "  ... %d additional summary rows saved in the TSV file\n",(NR-1)-80}' "$summary" >&2
    fi
    log "  DML summary rows : $dml_count"
    log "  DDL summary rows : $ddl_count"
    log "  Summary evidence : $summary"
    [ "$dml_count" -eq 0 ] || log '  NOTE: INSERT/UPDATE/DELETE/REPLACE combinations are NOT treated as compensating changes; current row equality is not inferred.'
    [ "$ddl_count" -eq 0 ] || log '  NOTE: DDL objects are compared read-only against authoritative node 1 when the object name/type is safely parseable.'
}

compare_ddl_metadata() {
    i=$1
    summary="$RUN/node_${i}.errant_gtid_summary.tsv"
    [ -s "$summary" ] || return 0
    list="$RUN/node_${i}.ddl_objects.tsv"
    awk -F '\t' 'NR>1 && $2=="DDL" {print $3 "\t" $4}' "$summary" | sort -u > "$list"
    [ -s "$list" ] || return 0
    dir="$RUN/node_${i}.ddl_metadata"
    mkdir -p "$dir"; chmod 700 "$dir"
    log '[ DDL Current Metadata Comparison ]'
    tab=$(printf '\t')
    while IFS="$tab" read -r operation object; do
        [ -n "$operation" ] || continue
        kind=${operation#* }
        if ! stmt=$(show_create_statement "$kind" "$object"); then
            log "  SKIP  : $operation $object (name/type not safe for automatic SHOW CREATE)"
            continue
        fi
        safe=$(printf '%s_%s' "$kind" "$object" | tr './` ' '____')
        src="$dir/${safe}.source.tsv"
        mem="$dir/${safe}.node_${i}.tsv"
        src_ok=yes; mem_ok=yes
        if ! sql 1 "$stmt" > "$src" 2> "$src.err"; then src_ok=no; fi
        if ! sql "$i" "$stmt" > "$mem" 2> "$mem.err"; then mem_ok=no; fi
        if [ "$src_ok" = yes ] && [ "$mem_ok" = yes ]; then
            if cmp -s "$src" "$mem"; then
                log "  MATCH : $kind $object"
            else
                diff -u "$src" "$mem" > "$dir/${safe}.diff" || :
                log "  DIFF  : $kind $object -> $dir/${safe}.diff"
            fi
        else
            src_cmd="$dir/${safe}.source_check.sh"
            mem_cmd="$dir/${safe}.node_${i}_check.sh"
            write_mysql_readonly_command 1 "$stmt" "$src_cmd"
            write_mysql_readonly_command "$i" "$stmt" "$mem_cmd"
            log "  MANUAL: $kind $object metadata could not be read automatically."
            log "          Source check: $src_cmd"
            log "          Node check  : $mem_cmd"
        fi
    done < "$list"
    log "  Metadata evidence directory: $dir"
}

postprocess_mysqlbinlog_evidence() {
    i=$1; evidence=$2
    summarize_mysqlbinlog_evidence "$i" "$evidence"
    compare_ddl_metadata "$i"
    log 'Decision rule: extra GTIDs still block GR join even when current metadata appears equal; reconcile/reprovision or abort after review.'
}

inspect_extra_gtids() {
    i=$1; target=$2
    gtid_compare "$i" "$target"
    extra=$GTID_EXTRA
    [ -n "$extra" ] || { log "Node $i has no extra GTIDs to inspect."; return 0; }

    logs_file="$RUN/node_${i}.binary_logs.tsv"
    direct_file="$RUN/node_${i}.binary_log_files.txt"
    summary_file="$RUN/node_${i}.errant_gtid_inspection.tsv"
    output_file="$RUN/node_${i}.errant_gtid.mysqlbinlog.txt"
    error_file="$RUN/node_${i}.errant_gtid.mysqlbinlog.err"
    sql "$i" 'SHOW BINARY LOGS;' > "$logs_file"
    binlog_basename=$(val "$i" log_bin_basename)
    available_extra=$(normalize_gtid "$(sql "$i" "SELECT GTID_SUBTRACT('$(q "$extra")',@@GLOBAL.gtid_purged);")")
    purged_extra=$(normalize_gtid "$(sql "$i" "SELECT GTID_SUBTRACT('$(q "$extra")',GTID_SUBTRACT(@@GLOBAL.gtid_executed,@@GLOBAL.gtid_purged));")")
    log_count=$(awk 'END{print NR+0}' "$logs_file")
    log_bytes=$(awk -F '\t' '{sum += $2} END{printf "%.0f",sum+0}' "$logs_file")
    inspect_mode=remote
    if prepare_direct_binlogs "$i" "$logs_file" "$direct_file"; then inspect_mode=direct; else rm -f "$direct_file"; fi

    {
        printf 'FIELD\tVALUE\n'
        printf 'NODE\t%s\n' "$i"
        printf 'EXTRA_GTID\t%s\n' "$extra"
        printf 'EXTRA_ORIGIN\t%s\n' "$GTID_ORIGIN"
        printf 'EXTRA_AVAILABLE_IN_CURRENT_BINLOGS\t%s\n' "$available_extra"
        printf 'EXTRA_PURGED_FROM_CURRENT_BINLOGS\t%s\n' "$purged_extra"
        printf 'LOG_BIN_BASENAME\t%s\n' "$binlog_basename"
        printf 'BINARY_LOG_COUNT\t%s\n' "$log_count"
        printf 'BINARY_LOG_BYTES_TO_SCAN\t%s\n' "$log_bytes"
        printf 'INSPECTION_MODE\t%s\n' "$inspect_mode"
    } > "$summary_file"

    log "Node $i read-only errant-GTID inspection:"
    log "  Available in current binary logs: ${available_extra:-NONE}"
    log "  Already purged from binary logs  : ${purged_extra:-NONE}"
    log "  Binary log list                  : $logs_file"
    log "  Current binary log bytes to scan : $log_bytes"
    if [ "$inspect_mode" = direct ]; then
        log '  Inspection path                  : local readable unencrypted binlog files (no replication privilege required)'
    else
        log '  Inspection path                  : server streaming (remote/inaccessible/encrypted binlog)'
    fi
    log "  Inspection summary               : $summary_file"
    [ -z "$purged_extra" ] || log '  NOTE: Purged GTIDs cannot be reconstructed from the current binary logs; use retained backups/audit evidence if transaction contents must be reviewed.'

    [ -n "$available_extra" ] || {
        log 'No extra GTID events remain in the current binary logs. No mysqlbinlog decoding was attempted.'
        return 0
    }

    cmd_file=$(write_mysqlbinlog_command "$i" "$available_extra" "$logs_file" "$inspect_mode" "$direct_file")
    log "  Read-only fallback command        : $cmd_file"
    if [ "$inspect_mode" = remote ]; then
        server_streaming_guidance "$i" "$cmd_file"
    fi
    if ! tool=$(mysqlbinlog_tool "$i"); then
        log 'Matching mysqlbinlog was not found on this controller. No package is installed automatically; use the generated read-only command with a matching MySQL client.'
        return 0
    fi

    set --
    if [ "$inspect_mode" = direct ]; then
        while IFS= read -r full; do
            [ -n "$full" ] || continue
            set -- "$@" "$full"
        done < "$direct_file"
        [ "$#" -gt 0 ] || { log "Node $i has no readable direct binary log files; automatic decoding skipped."; return 0; }
        if "$tool" --base64-output=DECODE-ROWS -vv --include-gtids="$available_extra" "$@" > "$output_file" 2> "$error_file"; then
            chmod 600 "$output_file" "$error_file"
            rm -f "$error_file"
            log "  mysqlbinlog evidence              : $output_file"
            log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'
            postprocess_mysqlbinlog_evidence "$i" "$output_file"
            return 0
        fi
        # A local file may become inaccessible/rotated between SHOW BINARY LOGS and read.
        # Fall back to server streaming rather than changing any server state.
        log 'Direct local mysqlbinlog read failed; server streaming is required for the fallback.'
        inspect_mode=remote
        printf 'INSPECTION_MODE_FALLBACK\tremote\n' >> "$summary_file"
        cmd_file=$(write_mysqlbinlog_command "$i" "$available_extra" "$logs_file" remote "$direct_file")
        server_streaming_guidance "$i" "$cmd_file"
    fi

    credential "$i"
    set --
    tab=$(printf '\t')
    while IFS="$tab" read -r log_name rest; do
        [ -n "$log_name" ] || continue
        set -- "$@" "$log_name"
    done < "$logs_file"
    [ "$#" -gt 0 ] || { log "Node $i returned no binary log files; automatic decoding skipped."; return 0; }
    if "$tool" --defaults-file="$TEMP/$i.cnf" --no-login-paths --read-from-remote-server --base64-output=DECODE-ROWS -vv --include-gtids="$available_extra" "$@" > "$output_file" 2> "$error_file"; then
        chmod 600 "$output_file" "$error_file"
        rm -f "$error_file"
        log "  mysqlbinlog evidence              : $output_file"
        log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'
        postprocess_mysqlbinlog_evidence "$i" "$output_file"
    else
        chmod 600 "$error_file" 2>/dev/null || :
        log 'Automatic mysqlbinlog decoding failed. No server data was changed.'
        log "  mysqlbinlog error                 : $error_file"
        log "  Use the generated command         : $cmd_file"
    fi
}


capture_reprovision_evidence() {
    i=$1; target=$2
    dir="$RUN/node_${i}.reprovision"
    mkdir -p "$dir"; chmod 700 "$dir"
    sql "$i" "SELECT @@server_uuid,@@hostname,@@port,@@socket,@@datadir,@@pid_file,@@server_id,REPLACE(REPLACE(@@gtid_executed,CHAR(10),''),CHAR(13),''),REPLACE(REPLACE(@@gtid_purged,CHAR(10),''),CHAR(13),''),@@read_only,@@super_read_only,@@event_scheduler;" > "$dir/runtime_before.tsv"
    sql "$i" 'SELECT CURRENT_USER(),USER();' > "$dir/current_user.tsv"
    sql "$i" 'SHOW GRANTS FOR CURRENT_USER;' > "$dir/current_admin_grants.sql" 2>/dev/null || :
    sql "$i" "SELECT PLUGIN_NAME,PLUGIN_STATUS,PLUGIN_TYPE,PLUGIN_LIBRARY FROM information_schema.plugins ORDER BY PLUGIN_NAME;" > "$dir/plugins.tsv"
    sql "$i" "SELECT EVENT_SCHEMA,EVENT_NAME,DEFINER,STATUS,EVENT_TYPE,EXECUTE_AT,INTERVAL_VALUE,INTERVAL_FIELD FROM information_schema.events ORDER BY EVENT_SCHEMA,EVENT_NAME;" > "$dir/events.tsv"
    sql "$i" 'SELECT * FROM performance_schema.persisted_variables ORDER BY VARIABLE_NAME;' > "$dir/persisted_variables.tsv" 2>/dev/null || :
    sql "$i" 'SHOW REPLICA STATUS;' > "$dir/replica_status.tsv" 2>/dev/null || :
    sql "$i" "SELECT CHANNEL_NAME,HOST,PORT,AUTO_POSITION FROM performance_schema.replication_connection_configuration ORDER BY CHANNEL_NAME;" > "$dir/replication_connections.tsv" 2>/dev/null || :
    printf 'TARGET_GTID\t%s\n' "$target" > "$dir/target_gtid.tsv"
    if [ "$(get "$i" location)" = local ]; then
        pnow=$(local_pid "$i") || die "Node $i local runtime identity changed; reprovision package not generated"
        tr '\000' '\n' < "/proc/$pnow/cmdline" > "$dir/mysqld_argv.txt"
        cat "/proc/$pnow/cgroup" > "$dir/mysqld_cgroup.txt" 2>/dev/null || :
        readlink -f "/proc/$pnow/exe" > "$dir/mysqld_exe.txt"
        stat -c '%n|%U|%G|%u|%g|%a|%d|%i' "$(val "$i" datadir)" > "$dir/filesystem_identity.txt"
        cnf=$(get "$i" cnf)
        if [ -n "$cnf" ] && [ -f "$cnf" ] && [ ! -L "$cnf" ]; then
            cp -p "$cnf" "$dir/$(basename "$cnf").before_reprovision"
            sha256sum "$cnf" "$dir/$(basename "$cnf").before_reprovision" > "$dir/cnf.sha256"
            stat -c '%n|%U|%G|%u|%g|%a|%d|%i' "$cnf" >> "$dir/filesystem_identity.txt"
        fi
    else
        write_mysql_readonly_command "$i" 'SELECT @@server_uuid,@@hostname,@@port,@@socket,@@datadir,@@pid_file,@@server_id,@@gtid_executed,@@gtid_purged;' "$dir/remote_identity_check.sh"
    fi
    printf '%s' "$dir"
}



mysqldump_version_guard() {
    command -v "$DUMP" >/dev/null 2>&1 || die 'Matching mysqldump executable required'
    version_file="$RUN/mysqldump_version.txt"
    "$DUMP" --version > "$version_file" 2>&1 || die 'Cannot execute mysqldump --version'
    dump_version=$(sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' "$version_file" | head -n 1)
    source_version=$(get 1 version | sed 's/[^0-9.].*//')
    [ -n "$dump_version" ] && [ "$dump_version" = "$source_version" ] || die "mysqldump version ${dump_version:-UNKNOWN} does not match Source server $source_version; set MYSQL_GR_MYSQLDUMP"
}

source_admin_target_credential() {
    i=$1
    credential 1
    candidate="$TEMP/$i.source_admin.cnf"
    {
        printf '[client]\n'
        sed -n '/^user=/p; /^password=/p' "$TEMP/1.cnf"
        if [ "$(get "$i" mode)" = socket ]; then
            printf 'protocol=SOCKET\nsocket="%s"\n' "$(optq "$(get "$i" socket)")"
        else
            printf 'protocol=TCP\nhost="%s"\nport=%s\nssl-mode=%s\n' "$(optq "$(get "$i" host)")" "$(get "$i" port)" "$(get "$i" admin_tls)"
            [ ! -s "$ROOT/$i/admin_ca" ] || printf 'ssl-ca="%s"\n' "$(optq "$(get "$i" admin_ca)")"
        fi
        printf '\n[mysql]\nconnect-timeout=10\n'
    } > "$candidate"
    chmod 600 "$candidate"
    if ! target_current=$(printf 'SELECT CURRENT_USER();\n' | "$MYSQL" --defaults-file="$candidate" --no-login-paths --batch --raw --skip-column-names 2>/dev/null); then
        rm -f "$candidate"
        return 1
    fi
    source_current=$(sql 1 'SELECT CURRENT_USER();')
    if [ "$target_current" != "$source_current" ]; then
        rm -f "$candidate"
        return 1
    fi
    mv -f "$candidate" "$TEMP/$i.cnf"
}

export_source_accounts() {
    dir=$1; account_node=${2:-1}
    account_list="$dir/source_accounts.list"
    account_sql="$dir/source_accounts.sql"
    grant_sql="$dir/source_grants.sql"
    default_roles="$dir/source_default_roles.sql"
    role_rows="$dir/.source_default_roles.rows"

    if ! sql "$account_node" "SELECT CONCAT(QUOTE(u.User),'@',QUOTE(u.Host)) FROM mysql.user u LEFT JOIN (SELECT DISTINCT FROM_USER,FROM_HOST FROM mysql.role_edges) r ON r.FROM_USER=u.User AND r.FROM_HOST=u.Host WHERE u.User NOT IN ('mysql.infoschema','mysql.session','mysql.sys') ORDER BY CASE WHEN r.FROM_USER IS NULL THEN 1 ELSE 0 END,u.User,u.Host;" > "$account_list"; then
        die 'Cannot enumerate Source accounts/roles for logical reprovisioning'
    fi
    [ -s "$account_list" ] || die 'Source account list is empty; logical provisioning cannot safely mark the full Source GTID set executed'

    source_admin=$(sql "$account_node" "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.user WHERE CONCAT(User,'@',Host)=CURRENT_USER();")
    [ -n "$source_admin" ] || die 'Cannot resolve the Source administrative account in mysql.user'
    grep -Fx "$source_admin" "$account_list" >/dev/null 2>&1 || die 'Source administrative account was not included in the account export'

    : > "$account_sql"
    printf '%s\n' '-- Generated from authoritative node 1. Contains authentication hashes; protect this file.' >> "$account_sql"
    printf '%s\n' 'SET SESSION sql_log_bin=0;' >> "$account_sql"
    printf '%s\n' 'SET SESSION sql_log_bin=0;' > "$grant_sql"

    account_no=0
    while IFS= read -r account; do
        [ -n "$account" ] || continue
        case $account in *';'*) die 'Unexpected account literal from Source';; esac
        account_no=$((account_no+1))
        create_file="$dir/.source_create_user_$account_no.tsv"
        if hasvar "$account_node" print_identified_with_as_hex; then
            if ! sql "$account_node" "SET SESSION print_identified_with_as_hex=ON; SHOW CREATE USER $account;" > "$create_file"; then
                rm -f "$create_file"
                die "SHOW CREATE USER failed for $account"
            fi
        else
            if ! sql "$account_node" "SHOW CREATE USER $account;" > "$create_file"; then
                rm -f "$create_file"
                die "SHOW CREATE USER failed for $account"
            fi
        fi
        create=$(cut -f2- "$create_file")
        rm -f "$create_file"
        [ -n "$create" ] || die "SHOW CREATE USER returned no definition for $account"
        # Preserve existing DEFINER relationships. Fresh staging has root@localhost;
        # CREATE IF NOT EXISTS followed by ALTER also restores its authentication.
        create=${create%;}
        case $create in 'CREATE USER '*) :;; *) die 'Unexpected SHOW CREATE USER output';; esac
        printf 'CREATE USER IF NOT EXISTS %s;\n' "${create#CREATE USER }" >> "$account_sql"
        printf 'ALTER USER %s;\n' "${create#CREATE USER }" >> "$account_sql"
    done < "$account_list"

    grant_no=0
    while IFS= read -r account; do
        [ -n "$account" ] || continue
        grant_no=$((grant_no+1))
        grant_file="$dir/.source_grants_$grant_no.tsv"
        if ! sql "$account_node" "SHOW GRANTS FOR $account;" > "$grant_file"; then
            rm -f "$grant_file"
            die "SHOW GRANTS failed for $account; refusing an incomplete account package"
        fi
        [ -s "$grant_file" ] || { rm -f "$grant_file"; die "SHOW GRANTS returned no rows for $account"; }
        while IFS= read -r grant_line; do
            [ -n "$grant_line" ] || continue
            printf '%s;\n' "${grant_line%;}" >> "$grant_sql"
        done < "$grant_file"
        rm -f "$grant_file"
    done < "$account_list"

    if ! sql "$account_node" "SELECT QUOTE(USER),QUOTE(HOST),QUOTE(DEFAULT_ROLE_USER),QUOTE(DEFAULT_ROLE_HOST) FROM mysql.default_roles ORDER BY USER,HOST,DEFAULT_ROLE_USER,DEFAULT_ROLE_HOST;" > "$role_rows"; then
        rm -f "$role_rows"
        die 'Cannot export Source default-role metadata; refusing an incomplete account package'
    fi
    : > "$default_roles"
    tab=$(printf '\t')
    current_account=''
    current_roles=''
    while IFS="$tab" read -r role_user role_host default_user default_host; do
        [ -n "$role_user" ] || continue
        account="$role_user@$role_host"
        role="$default_user@$default_host"
        if [ -n "$current_account" ] && [ "$account" != "$current_account" ]; then
            printf 'SET DEFAULT ROLE %s TO %s;\n' "$current_roles" "$current_account" >> "$default_roles"
            current_roles=''
        fi
        current_account=$account
        if [ -n "$current_roles" ]; then current_roles="$current_roles,$role"; else current_roles=$role; fi
    done < "$role_rows"
    [ -z "$current_account" ] || printf 'SET DEFAULT ROLE %s TO %s;\n' "$current_roles" "$current_account" >> "$default_roles"
    rm -f "$role_rows"
    cat "$default_roles" >> "$grant_sql"

    printf '%s\n' 'SET SESSION sql_log_bin=1;' >> "$account_sql"
    printf '%s\n' 'SET SESSION sql_log_bin=1;' >> "$grant_sql"
    chmod 600 "$account_list" "$account_sql" "$grant_sql" "$default_roles"
    (cd "$dir" && sha256sum source_accounts.sql source_grants.sql > source_accounts.sql.sha256)
    printf '%s' "$account_sql"
}

prepare_reprovision_dump() {
    i=$1; target=$2; dir=$3
    definer_guard 1
    dbs=$(sql 1 "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY schema_name;")
    [ -n "$dbs" ] || die 'Authoritative source has no application DBs; automatic logical reprovision package cannot be built'
    for db in $dbs; do case $db in *[!A-Za-z0-9_\$]*) die 'Database name requires external provisioning';; esac; done
    mysqldump_version_guard
    accounts=$(export_source_accounts "$dir")
    dump="$dir/source_application.sql"
    set -f; set -- $dbs; set +f
    "$DUMP" --defaults-file="$TEMP/1.cnf" --no-login-paths --single-transaction --quick --skip-lock-tables --routines --events --triggers --hex-blob --set-gtid-purged=ON --databases "$@" > "$dump" 2> "$dir/source_dump.log"
    [ -s "$dump" ] || die 'Reprovision source dump is empty'
    (cd "$dir" && sha256sum source_application.sql > source_application.sql.sha256)
    printf 'ACCOUNT_SQL\t%s\n' "$accounts" > "$dir/logical_reprovision_components.tsv"
    printf 'APPLICATION_DUMP\t%s\n' "$dump" >> "$dir/logical_reprovision_components.tsv"
    [ "$(normalize_gtid "$(val 1 gtid_executed)")" = "$target" ] || die 'Authoritative source GTID changed while preparing reprovision package'
    printf '%s' "$dump"
}

write_reprovision_plan() {
    i=$1; target=$2; dir=$3; dump=$4
    plan="$dir/reprovision_plan.txt"
    datadir=$(val "$i" datadir); datadir=${datadir%/}
    cnf=$(get "$i" cnf)
    old_uuid=$(get "$i" uuid)
    stamp='$(date +%Y%m%d_%H%M%S)_$$'
    {
        printf 'Node %s clean reprovision plan\n' "$i"
        printf 'Authoritative node: 1\nOld UUID: %s\nTarget GTID: %s\nDatadir: %s\nCNF: %s\nDump: %s\n\n' "$old_uuid" "$target" "$datadir" "$cnf" "$dump"
        printf 'Safety rules:\n'
        printf '  - Do NOT run RESET BINARY LOGS AND GTIDS / RESET MASTER.\n'
        printf '  - Do NOT delete the original datadir. Preserve it by atomic rename on the same filesystem.\n'
        printf '  - Build and validate a fresh staging datadir before the final swap whenever OS access permits.\n'
        printf '  - auto.cnf from the old datadir remains only in the rollback backup; it must not be copied into the fresh datadir.\n'
        printf '  - Re-read PID/server_uuid/datadir immediately before any stop or swap; saved PID values are evidence only.\n\n'
        printf 'Recommended path layout at execution time:\n'
        printf '  STAGING=%s.gr_reprovision_stage_%s\n' "$datadir" "$stamp"
        printf '  BACKUP=%s.before_gr_reprovision_%s\n' "$datadir" "$stamp"
        printf '  FAILED=%s.failed_gr_reprovision_%s\n\n' "$datadir" "$stamp"
        if [ "$(get "$i" location)" = local ]; then
            pnow=$(local_pid "$i") || die "Node $i runtime identity changed while writing reprovision plan"
            exe=$(readlink -f "/proc/$pnow/exe")
            owner=$(stat -c %U "$datadir")
            pidfile=$(val "$i" pid_file); sock=$(val "$i" socket)
            service=$(sed -n 's#.*\/\([^/]*\.service\)$#\1#p' "/proc/$pnow/cgroup" | head -n 1)
            printf 'Local runtime evidence:\n  PID=%s\n  mysqld=%s\n  owner=%s\n  pid_file=%s\n  socket=%s\n  systemd_service=%s\n\n' "$pnow" "$exe" "$owner" "$pidfile" "$sock" "${service:-NONE}"
            printf 'Execution sequence:\n'
            printf '  1. Revalidate current UUID/datadir/PID and verify CNF checksum.\n'
            printf '  2. Create STAGING as a sibling of the current datadir with the same owner/group/mode.\n'
            printf '  3. Initialize STAGING with the same mysqld version using --initialize-insecure and isolated socket/pid/log/binlog paths.\n'
            printf '  4. Start only the STAGING instance with --skip-networking and event_scheduler=OFF.\n'
            printf '  5. Create/alter accounts without DROP USER, restore %s, then restore source_grants.sql/default roles in the same session.\n' "$dump"
            printf '     Account SQL contains authentication hashes and GRANT/role state; keep mode 600 and never print it to an unprotected terminal/log.\n'
            printf '  6. Verify application objects, Source account/role state, and GTID exactly equals %s before final swap.\n' "$target"
            printf '     If account/default-role export was incomplete, stop and use external/reviewed provisioning rather than marking all Source GTIDs executed.\n'
            printf '  7. Stop STAGING cleanly, stop the original instance using the proven launcher, then rename original datadir -> BACKUP and STAGING -> original datadir.\n'
            printf '  8. Start the original launcher, verify NEW server_uuid != %s, GTID == target, schema/data checks, and super_read_only=ON.\n' "$old_uuid"
            printf '  9. Keep BACKUP until GR validation and application smoke tests are complete.\n\n'
            printf 'Rollback sequence if the swapped instance fails validation:\n'
            printf '  - Stop the new instance with the same proven launcher.\n'
            printf '  - Rename current datadir -> FAILED.\n'
            printf '  - Rename BACKUP -> %s.\n' "$datadir"
            printf '  - Start the original launcher and verify server_uuid returns to %s before resuming any service.\n' "$old_uuid"
        else
            printf 'Remote-node handling:\n'
            printf '  - Controller cannot assume filesystem access. Use SSH only after host/instance identity verification.\n'
            printf '  - If SSH/OS access is unavailable, run the generated remote_identity_check.sh on/from an authorized host and execute the same STAGING/BACKUP/swap procedure there.\n'
            printf '  - Copy the application dump, source_accounts.sql, and both checksum files to the target host before stopping the original instance; verify every checksum there.\n'
            printf '  - Restore both application data and Source account/role state in an isolated STAGING instance before any datadir swap.\n'
            printf '  - Do not infer a remote cnf/datadir path from the controller filesystem.\n'
        fi
        printf '\nAfter successful reprovision:\n'
        printf '  - A fresh server_uuid is expected. Do not continue with this migration state.\n'
        printf '  - Use a fresh MYSQL_GR_WORK_ROOT, run discover again, then configure/precheck/initialize.\n'
    } > "$plan"
    chmod 600 "$plan"
    printf '%s' "$plan"
}

prepare_reprovision() {
    i=$1; target=$2; reason=$3
    log "Preparing reversible clean-reprovision package for node $i. No datadir/config mutation is performed by this step."
    dir=$(capture_reprovision_evidence "$i" "$target")
    dump=$(prepare_reprovision_dump "$i" "$target" "$dir")
    plan=$(write_reprovision_plan "$i" "$target" "$dir" "$dump")
    build_reprovision_executor "$i" "$target" "$dir"
    printf 'REASON\t%s\n' "$reason" > "$dir/reason.tsv"
    log "Reprovision evidence : $dir"
    log "Source dump          : $dump"
    log "Reprovision plan     : $plan"
    log "Host-side executor: sh $dir/reprovision_helper.sh stage $dir TARGET_AUTH SOURCE_AUTH"
    log 'Copy the COMPLETE package to a remote host without SSH. Run stage, review its result, then swap; rollback uses the same package. Original datadir is retained.'
}

divergence_abort_snapshot() {
    i=$1
    snapshot="$RUN/divergence_abort_state.tsv"
    {
        printf 'NODE	SERVER_UUID	READ_ONLY	SUPER_READ_ONLY	EVENT_SCHEDULER	GTID_EXECUTED
'
        for j in $(ids); do
            if row=$(sql "$j" "SELECT @@server_uuid,@@read_only,@@super_read_only,@@event_scheduler,REPLACE(REPLACE(@@gtid_executed,CHAR(10),''),CHAR(13),'');" 2>/dev/null); then
                printf '%s	%s
' "$j" "$row"
            else
                printf '%s	UNAVAILABLE	UNAVAILABLE	UNAVAILABLE	UNAVAILABLE	UNAVAILABLE
' "$j"
            fi
        done
    } > "$snapshot"
    chmod 600 "$snapshot"
    log "Abort state snapshot: $snapshot"
    log 'NEXT CHECKS:'
    if [ -s "$RUN/node_${i}.errant_gtid_summary.tsv" ]; then
        log "  1) Review automatic per-GTID DML/DDL summary: $RUN/node_${i}.errant_gtid_summary.tsv"
        [ ! -d "$RUN/node_${i}.ddl_metadata" ] || log "  2) Review Source/Node DDL metadata comparisons: $RUN/node_${i}.ddl_metadata"
        log "  3) Review raw decoded evidence if needed: $RUN/node_${i}.errant_gtid.mysqlbinlog.txt"
    elif [ -s "$RUN/node_${i}.errant_gtid.mysqlbinlog.err" ]; then
        log "  1) Review mysqlbinlog error: $RUN/node_${i}.errant_gtid.mysqlbinlog.err"
        [ ! -f "$RUN/node_${i}.mysqlbinlog_command.sh" ] || log "     Read-only retry command: $RUN/node_${i}.mysqlbinlog_command.sh"
        log "  2) Review GTID comparison: $RUN/node_${i}.gtid_compare.tsv"
    else
        log "  1) Review GTID evidence: $RUN/node_${i}.gtid_compare.tsv"
    fi
    log "  4) Review inspection summary: $RUN/node_${i}.errant_gtid_inspection.tsv"
    log '  5) Keep the migration stopped; do not run cutover while extra GTIDs remain.'
    log '  6) Choose reprovision to generate a reversible clean-rebuild package, or external for another reviewed method.'
    log '  7) After a rebuild changes server_uuid, use a fresh MYSQL_GR_WORK_ROOT and run discover again.'
}


divergence_workflow() {
    i=$1; target=$2
    gtid_compare "$i" "$target"
    [ -n "$GTID_EXTRA" ] || return 0
    log "Node $i has divergent GTID history. There is no automatic ignore, skip, GTID rewrite, or reset path."
    while :; do
        log '  inspect     : read current binary logs and decode only the extra GTIDs; no SQL is applied.'
        log '  reprovision : generate evidence + authoritative logical dump + reversible STAGING/BACKUP/rollback plan.'
        log '  external    : stop here for another reviewed reconciliation/reprovisioning method.'
        log '  abort       : stop without changing GTID history; save a read-only state snapshot.'
        action=$(required "Node $i divergent GTID action (inspect/reprovision/external/abort)" inspect)
        case $action in
            inspect)
                inspect_extra_gtids "$i" "$target"
                log 'Inspection complete. Review the saved evidence before deciding how to reconcile the member.'
                while :; do
                    log '  reprovision: prepare a reversible clean-rebuild package from authoritative node 1.'
                    log '  external   : use another separately reviewed reconciliation/provisioning method.'
                    log '  abort      : save current state and stop; no GTID reconciliation is attempted.'
                    next_action=$(required "Node $i action after inspection (reprovision/external/abort)" abort)
                    case $next_action in
                        reprovision)
                            divergence_abort_snapshot "$i"
                            prepare_reprovision "$i" "$target" "divergent GTID history ($GTID_ORIGIN)"
                            die "Node $i reprovision package prepared; execute/review it, then rediscover with a fresh work root";;
                        external)
                            divergence_abort_snapshot "$i"
                            external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"
                            die "Node $i external reconciliation/reprovisioning required before GR migration";;
                        abort)
                            divergence_abort_snapshot "$i"
                            die "Node $i divergence left unchanged after read-only inspection";;
                        *) log 'Invalid action. Enter reprovision, external, or abort.';;
                    esac
                done
                ;;
            reprovision)
                divergence_abort_snapshot "$i"
                prepare_reprovision "$i" "$target" "divergent GTID history ($GTID_ORIGIN)"
                die "Node $i reprovision package prepared; execute/review it, then rediscover with a fresh work root";;
            external)
                divergence_abort_snapshot "$i"
                external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"
                die "Node $i external reconciliation/reprovisioning required before GR migration";;
            abort)
                divergence_abort_snapshot "$i"
                die "Node $i divergence left unchanged";;
            *) log 'Invalid action. Enter inspect, reprovision, external, or abort.';;
        esac
    done
}


catchup() (
    i=$1; target=$(normalize_gtid "$2")
    gtid_guard "$i" "$target"
    if [ -n "$GTID_MISSING" ]; then
        wait_rc=$(sql "$i" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(q "$target")',300);")
        if [ "$wait_rc" != 0 ]; then
            gtid_compare "$i" "$target"
            die "Node $i GTID wait timed out; inspect the GTID comparison evidence"
        fi
    fi
    gtid_compare "$i" "$target"
    [ -z "$GTID_EXTRA" ] || die "Node $i acquired extra/errant GTIDs during catch-up; reconcile before GR migration"
    [ -z "$GTID_MISSING" ] || die "Node $i is still missing GTIDs after catch-up"
)

classify_member() {
    i=$1; target=$2
    if [ "$i" = 1 ]; then printf '%s' SOURCE; return; fi
    if [ "$(get "$i" kind)" = replica ]; then printf '%s' EXISTING_REPLICA; return; fi
    app_count=$(sql "$i" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema');")
    source_app_count=$(sql 1 "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema');")
    node_gtid=$(normalize_gtid "$(val "$i" gtid_executed)")
    if [ "$app_count" = 0 ] && [ -z "$node_gtid" ]; then
        printf '%s' NEW_EMPTY
        return
    fi
    gtid_compare "$i" "$target"
    if [ -n "$GTID_EXTRA" ]; then
        printf '%s' DIVERGED
    elif [ -n "$GTID_MISSING" ]; then
        printf '%s' NEEDS_PROVISIONING
    elif [ "$source_app_count" -gt 0 ] && [ "$app_count" = 0 ]; then
        printf '%s' NEEDS_PROVISIONING
    else
        printf '%s' PREPROVISIONED
    fi
}

initialize() {
    PHASE=initialize
    put meta mutation_started initialize
    precheck; preflight_client_utilities; fence
    target=$(normalize_gtid "$(val 1 gtid_executed)")
    put meta frozen_gtid "$target"
    for i in $(ids); do
        [ "$i" != 1 ] || continue
        state=$(classify_member "$i" "$target")
        put "$i" state "$state"
        case $state in
            EXISTING_REPLICA)
                log "Node $i state: EXISTING_REPLICA - existing GTID channel will catch up to node 1 before GR cutover."
                ch=$(q "$(get "$i" channel)")
                # Inspect divergence before changing the existing channel state.
                gtid_compare "$i" "$target"
                [ -z "$GTID_EXTRA" ] || divergence_workflow "$i" "$target"
                [ -z "$GTID_UNAVAILABLE" ] || die "Node $i is missing GTIDs already purged from node 1 binary logs; incremental catch-up is not possible. Externally reprovision from the authoritative source."
                log "Starting/catching up only node $i selected GTID channel after any configuration restart."
                sql "$i" "START REPLICA FOR CHANNEL '$ch';"
                catchup "$i" "$target"
                put "$i" initialized replica
                ;;
            NEW_EMPTY)
                log "Node $i state: NEW_EMPTY - no application schema and no executed GTID history."
                log '  dump    : provision from node 1 with a consistent logical dump and source GTID set.'
                log '  external: use a separately validated physical backup/other provisioning procedure.'
                while :; do
                    method=$(required "Node $i initialization (dump/external)" dump)
                    case $method in dump|external) break;; *) log 'Invalid initialization method. Enter dump or external.';; esac
                done
                if [ "$method" = external ]; then
                    external_manual_guidance "$i" "NEW_EMPTY member selected external provisioning"
                    log 'Restore the authoritative full data/GTID set, then rerun initialize. No GTID reset is performed by this script.'
                    die "Node $i external initialization pending"
                fi
                [ -z "$(normalize_gtid "$(val "$i" gtid_executed)")" ] || die "Node $i gained GTID history after classification; no automatic GTID reset is performed"
                [ "$(sql "$i" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema');")" = 0 ] || die "Node $i is no longer empty; externally provision it"
                confirm "INITIALIZE EMPTY NODE $i"
                package="$RUN/node_${i}.new_empty_provision"
                mkdir -p "$package"; chmod 700 "$package"
                dump=$(prepare_reprovision_dump "$i" "$target" "$package")
                account_sql="$package/source_accounts.sql"
                (cd "$package" && sha256sum -c source_application.sql.sha256 >/dev/null) || die 'Source application dump checksum verification failed before restore'
                (cd "$package" && sha256sum -c source_accounts.sql.sha256 >/dev/null) || die 'Source account package checksum verification failed before restore'
                mkdir -p "$TEMP/unfenced"; : > "$TEMP/unfenced/$i"
                # Keep read_only=ON so ordinary application accounts remain fenced while
                # the administrative provisioning session temporarily disables super_read_only.
                sql "$i" 'SET GLOBAL read_only=ON; SET GLOBAL super_read_only=OFF;'
                if ! { cat "$account_sql" "$dump" "$package/source_grants.sql"; } | "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --binary-mode > "$RUN/node_$i.restore.log" 2>&1; then
                    source_admin_target_credential "$i" || :
                    sql "$i" 'SET GLOBAL super_read_only=ON;' || :
                    die "Account/object/grant restore failed; node $i requires clean reprovisioning before retry"
                fi
                if ! source_admin_target_credential "$i"; then
                    die "Source accounts were restored but Source administrative credentials cannot reconnect to node $i; keep read_only=ON and externally verify/reprovision before retry"
                fi
                sql "$i" 'SET GLOBAL super_read_only=ON;'
                # Fence execution with the scheduler, preserving event definitions.
                sql "$i" 'SET GLOBAL event_scheduler=OFF;'
                rm -f "$TEMP/unfenced/$i"
                catchup "$i" "$target"
                put "$i" initialized dump
                ;;
            PREPROVISIONED)
                log "Node $i state: PREPROVISIONED - GTID set matches node 1 and application schemas exist; row equality is NOT inferred from GTIDs."
                log '  already : accept only after confirming the node came from the authoritative dataset and full data consistency was verified.'
                log '  external: replace/re-provision it using a separately validated procedure.'
                while :; do
                    method=$(required "Node $i initialization (already/external)" already)
                    case $method in already|external) break;; *) log 'Invalid initialization method. Enter already or external.';; esac
                done
                if [ "$method" = external ]; then
                    external_manual_guidance "$i" "PREPROVISIONED member selected external reprovisioning"
                    die "Node $i external re-provisioning pending"
                fi
                confirm "NODE $i DATA AND GTID VERIFIED"
                catchup "$i" "$target"
                put "$i" initialized preprovisioned
                ;;
            NEEDS_PROVISIONING)
                log "Node $i state: NEEDS_PROVISIONING - it is not empty and does not exactly match the authoritative GTID/data starting point."
                gtid_compare "$i" "$target"
                log '  reprovision: generate evidence + authoritative dump + reversible STAGING/BACKUP/rollback plan.'
                log '  external   : use another separately reviewed provisioning method.'
                method=$(required "Node $i provisioning (reprovision/external)" reprovision)
                case $method in
                    reprovision)
                        prepare_reprovision "$i" "$target" 'member is not empty and does not match the authoritative starting point'
                        die "Node $i reprovision package prepared; execute/review it, then rediscover with a fresh work root";;
                    external)
                        external_manual_guidance "$i" "member is not empty and does not match the authoritative starting point"
                        die "Node $i requires external provisioning from node 1 before GR migration";;
                    *) die 'Choose reprovision or external';;
                esac
                ;;
            DIVERGED)
                log "Node $i state: DIVERGED - extra GTIDs exist outside the authoritative node 1 set."
                divergence_workflow "$i" "$target"
                ;;
            *) die "Unknown node $i initialization state: $state";;
        esac
    done
    [ "$(normalize_gtid "$(val 1 gtid_executed)")" = "$target" ] || die 'Source changed while fenced'
    data_checks
    put meta initialized yes
    log 'INITIALIZATION PASSED. All nodes remain write-fenced; event schedulers remain OFF.'
    [ "$STEP" = all ] || log 'NEXT: sh mysql_gr_migrate.sh cutover'
}

data_checks() {
    full_object_checks
    manifest_sql="SELECT TABLE_SCHEMA,TABLE_NAME,TABLE_TYPE,COALESCE(ENGINE,'') FROM information_schema.tables WHERE TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY TABLE_SCHEMA,TABLE_NAME; SELECT TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,COALESCE(COLUMN_DEFAULT,'<NULL>'),EXTRA FROM information_schema.columns WHERE TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION;"
    sql 1 "$manifest_sql" > "$RUN/node_1.schema_manifest.tsv"
    for i in $(ids); do
        [ "$i" != 1 ] || continue
        sql "$i" "$manifest_sql" > "$RUN/node_$i.schema_manifest.tsv"
        diff -u "$RUN/node_1.schema_manifest.tsv" "$RUN/node_$i.schema_manifest.tsv" > "$RUN/node_$i.schema.diff" || die "Node $i schema differs from Source; inspect node_$i.schema.diff"
    done
    log 'Matching GTIDs and schema do not prove identical row contents. Full application DBs must be present on every member.'
    verify_file=$(ask 'Read-only business validation SQL file (blank = external verification)' '')
    if [ -n "$verify_file" ]; then
        [ -r "$verify_file" ] || die 'Validation SQL file is not readable'
        log 'Use deterministic SELECT results ordered identically on every node; SQL runs inside a READ ONLY transaction.'
        verify_sql=$(cat "$verify_file")
        for i in $(ids); do
            sql "$i" "START TRANSACTION READ ONLY; $verify_sql ROLLBACK;" > "$RUN/node_$i.business_validation.tsv"
            if [ "$i" != 1 ]; then
                diff -u "$RUN/node_1.business_validation.tsv" "$RUN/node_$i.business_validation.tsv" > "$RUN/node_$i.business.diff" || die "Node $i business verification differs"
            fi
        done
    else confirm 'FULL DATA CONSISTENCY VERIFIED'; fi
}
plugin() (
    i=$1
    status=$(sql "$i" "SELECT PLUGIN_STATUS FROM information_schema.plugins WHERE PLUGIN_NAME='group_replication';")
    if [ -z "$status" ]; then
        mkdir -p "$RUN/cutover_rollback"
        : > "$RUN/cutover_rollback/$i.new_gr_plugin"
        local_write "$i" "INSTALL PLUGIN group_replication SONAME 'group_replication.so';"
    fi
    [ "$(sql "$i" "SELECT PLUGIN_STATUS FROM information_schema.plugins WHERE PLUGIN_NAME='group_replication';")" = ACTIVE ] || die 'GR plugin is not ACTIVE'
)
persist() {
    hasvar "$1" "$2" || die "Node $1 lacks required GR option $2"
    persist_snapshot "$1" "$2"
    sql "$1" "SET PERSIST $2='$(q "$3")';"
}
group_settings() (
    i=$1
    seeds=''
    for j in $(ids); do seeds="${seeds}${seeds:+,}$(get "$j" xcom)"; done
    plugin "$i"
    if hasvar "$i" group_replication_communication_stack; then persist "$i" group_replication_communication_stack XCOM; fi
    persist "$i" group_replication_group_name "$(get meta group)"
    persist "$i" group_replication_start_on_boot OFF
    persist "$i" group_replication_bootstrap_group OFF
    if [ "$(get meta primary_mode)" = single ]; then
        persist "$i" group_replication_single_primary_mode ON
        persist "$i" group_replication_enforce_update_everywhere_checks OFF
    else
        persist "$i" group_replication_single_primary_mode OFF
        persist "$i" group_replication_enforce_update_everywhere_checks ON
        # Explicit offsets do not depend on server_id fitting the increment range.
        persist "$i" group_replication_auto_increment_increment "$(get meta count)"
        persist "$i" auto_increment_increment "$(get meta count)"
        persist "$i" auto_increment_offset "$i"
    fi
    persist "$i" group_replication_local_address "$(get "$i" xcom)"
    persist "$i" group_replication_group_seeds "$seeds"
    persist "$i" group_replication_ip_allowlist "$(get meta allowlist)"
    persist "$i" group_replication_ssl_mode "$(get meta tls)"
    persist "$i" group_replication_recovery_use_ssl ON
    persist "$i" group_replication_recovery_ssl_ca "$(get "$i" recovery_ca)"
    verify=ON; [ "$(get meta tls)" != REQUIRED ] || verify=OFF
    persist "$i" group_replication_recovery_ssl_verify_server_cert "$verify"
    persist "$i" group_replication_exit_state_action READ_ONLY
    # Incremental-only workflow. Clone fallback is rejected in precheck.
)
accounts() {
    log 'XCom/incremental recovery uses REPLICATION SLAVE and CONNECTION_ADMIN; no GRANT ALL.'
    log '  create  : create dedicated minimum-privilege recovery accounts on the members.'
    log '  existing: reuse pre-created recovery accounts after grant/TLS verification.'
    action=$(required 'Recovery accounts (create/existing)' create)
    case $action in create|existing) :;; *) die 'Invalid account action';; esac
    ru=$(required 'Dedicated recovery user' '')
    case $ru in *[!A-Za-z0-9_.-]*) die 'Invalid recovery user';; esac
    hosts=$(required 'Account host entries for member source IPs (space-separated)' '')
    for host in $hosts; do case $host in *[!A-Za-z0-9_.:%/-]*) die 'Invalid account host';; esac; done
    for i in $(ids); do sql "$i" "SHOW GLOBAL VARIABLES WHERE Variable_name LIKE 'validate_password%';" >&2; done
    if [ "$action" = create ]; then
        rp=$(secret 'Recovery password shared across these donor accounts (blank = auto-generate in memory)')
        if [ -z "$rp" ]; then
            command -v openssl >/dev/null 2>&1 || die 'Existing openssl is required to auto-generate a recovery password; no package will be installed automatically'
            random_part=$(openssl rand -hex 10 2>/dev/null) || die 'Recovery password generation failed'
            rp="Aa9!$random_part"
            unset random_part
            log 'Recovery password auto-generated in memory; it is not written to work files or logs.'
        fi
    else
        rp=$(secret 'Existing recovery account password')
        [ -n "$rp" ] || die 'Existing recovery account password cannot be empty'
    fi
    [ "$(printf '%s' "$rp" | wc -c)" -le 32 ] || die 'Replication SOURCE_PASSWORD must not exceed 32 bytes; no recovery accounts have been created'
    for i in $(ids); do
        for host in $hosts; do
            account="'$(q "$ru")'@'$(q "$host")'"
            if [ "$action" = create ]; then
                [ "$(sql "$i" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$ru")' AND Host='$(q "$host")';")" = 0 ] || die "Account exists on node $i; choose existing or another name"
                printf 'DROP USER IF EXISTS %s;\n' "$account" >> "$RUN/cutover_rollback/$i.accounts.sql"
                # sql_log_bin=0 prevents local account provisioning from making errant GTIDs.
                local_write "$i" "CREATE USER $account IDENTIFIED BY '$(q "$rp")' REQUIRE SSL; GRANT REPLICATION SLAVE, CONNECTION_ADMIN ON *.* TO $account;" secret
            else
                sql "$i" "SHOW GRANTS FOR $account;" > "$RUN/node_$i.grants_$(printf '%s' "$host" | tr '/:%' '___').txt"
                sql "$i" "SHOW GRANTS FOR $account;" >&2
                [ "$(sql "$i" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$ru")' AND Host='$(q "$host")' AND Repl_slave_priv='Y' AND account_locked='N' AND ssl_type<>'';")" = 1 ] || die 'Existing account needs REPLICATION SLAVE, REQUIRE SSL and unlocked status'
                [ "$(sql "$i" "SELECT COUNT(*) FROM mysql.global_grants WHERE USER='$(q "$ru")' AND HOST='$(q "$host")' AND PRIV='CONNECTION_ADMIN';")" = 1 ] || die 'CONNECTION_ADMIN missing'
            fi
        done
    done
    if [ "$action" = existing ]; then confirm 'RECOVERY ACCOUNT GRANTS REVIEWED'; fi
    for i in $(ids); do
        # Server stores channel credentials; only ephemeral SQL is kept locally.
        : > "$RUN/cutover_rollback/$i.new_recovery_channel"
        if ! sql "$i" "CHANGE REPLICATION SOURCE TO SOURCE_USER='$(q "$ru")', SOURCE_PASSWORD='$(q "$rp")' FOR CHANNEL 'group_replication_recovery';" >/dev/null 2> "$TEMP/account_error"; then
            cp "$TEMP/account_error" "$RUN/node_$i.recovery_channel.error"
            chmod 600 "$RUN/node_$i.recovery_channel.error"
            die "Recovery channel configuration failed on node $i; protected error evidence: $RUN/node_$i.recovery_channel.error"
        fi
    done
    unset rp
}
wait_member() (
    i=$1; tries=0
    while [ "$tries" -lt 150 ]; do
        state=$(sql "$i" "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_ID=@@server_uuid;")
        case $state in ONLINE) exit 0;; ERROR) die "Node $i GR state ERROR";; esac
        sleep 2; tries=$((tries+1))
    done
    die "Node $i did not become ONLINE within 300 seconds"
)
cutover() {
    PHASE=cutover
    put meta mutation_started cutover
    [ -f "$ROOT/meta/initialized" ] || die 'Run initialize first'
    [ ! -f "$ROOT/meta/bootstrap_attempted" ] || die 'Bootstrap was already attempted. Inspect status; do not automatically rebootstrap.'
    precheck
    target=$(get meta frozen_gtid)
    for i in $(ids); do
        [ "$(val "$i" super_read_only)" = 1 ] || die 'Write fence was removed; rerun initialize'
        catchup "$i" "$target"
    done
    log 'Confirm verified backups, data/DEFINER accounts, member-to-member SQL/XCom connectivity and TLS certificates.'
    log 'Recovery credentials are stored by MySQL in replication metadata. GR start_on_boot remains OFF.'
    confirm 'CUTOVER TO GR'
    cutover_snapshot
    for i in $(ids); do
        sql "$i" 'SHOW REPLICA STATUS;' > "$RUN/node_$i.async_before.tsv"
        sql "$i" 'SELECT * FROM performance_schema.persisted_variables;' > "$RUN/node_$i.persisted_before.tsv"
        if [ "$(get "$i" kind)" = replica ]; then
            sql "$i" "STOP REPLICA FOR CHANNEL '$(q "$(get "$i" channel)")';"
            put "$i" async_stopped yes
            catchup "$i" "$target"
        fi
        group_settings "$i"
    done
    # Accounts can be created while fenced only after explicit cutover approval.
    accounts
    for i in $(ids); do sql "$i" 'SET GLOBAL super_read_only=ON;'; catchup "$i" "$target"; done
    put meta bootstrap_attempted "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$TEMP/unfenced"; : > "$TEMP/unfenced/1"
    BOOT_NODE=1
    sql 1 'SET GLOBAL group_replication_bootstrap_group=ON;'
    if ! sql 1 'START GROUP_REPLICATION;'; then die 'Bootstrap failed; inspect status before recovery'; fi
    sql 1 'SET GLOBAL group_replication_bootstrap_group=OFF;'
    BOOT_NODE=''
    wait_member 1
    # Primary becomes writable automatically; fence again until validation.
    sql 1 'SET GLOBAL super_read_only=ON;'
    rm -f "$TEMP/unfenced/1"
    for i in $(ids); do
        [ "$i" != 1 ] || continue
        : > "$TEMP/unfenced/$i"
        sql "$i" 'START GROUP_REPLICATION;'
        wait_member "$i"
        sql "$i" 'SET GLOBAL super_read_only=ON;'
        rm -f "$TEMP/unfenced/$i"
    done
    put meta joined yes
    validate
    log 'All members validated. Application routing/DNS/MySQL Router is managed separately.'
    if [ "$(ask 'Release write fences on elected primary member(s) now? (yes/no)' no)" = yes ]; then
        for i in $(ids); do
            if [ "$(get meta primary_mode)" = multi ] || [ "$i" = 1 ]; then
                sql "$i" 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;'
            fi
        done
    fi
    log 'Event schedulers remain OFF. Review primary events and choose the desired scheduler policy manually.'
    log 'Old async channels remain STOPPED with metadata retained. Do not START REPLICA on them after GR cutover.'
}
join() {
    connected
    [ -f "$ROOT/meta/bootstrap_attempted" ] || die 'No recorded bootstrap attempt; use cutover'
    [ "$(val 1 group_replication_group_name)" = "$(get meta group)" ] || die 'Group UUID mismatch'
    [ "$(sql 1 "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_ID=@@server_uuid;")" = ONLINE ] || die 'Bootstrap node is not ONLINE. A full group recovery needs manual review; never blindly rebootstrap.'
    confirm 'RESUME JOIN EXISTING GROUP'
    mkdir -p "$TEMP/unfenced"
    for i in $(ids); do
        [ "$(val "$i" group_replication_group_name)" = "$(get meta group)" ] || die 'Member group UUID mismatch'
        state=$(sql "$i" "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_ID=@@server_uuid;")
        case $state in
            ONLINE) :;;
            RECOVERING) wait_member "$i";;
            ''|OFFLINE)
                [ "$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON';")" = 0 ] || die 'Async receiver is running'
                [ "$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON';")" = 0 ] || die 'Async applier is running'
                [ "$(sql "$i" "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,'$(q "$(val 1 gtid_executed)")');")" = '' ] || die 'Extra GTIDs require reconciliation'
                : > "$TEMP/unfenced/$i"
                sql "$i" 'SET GLOBAL group_replication_bootstrap_group=OFF; START GROUP_REPLICATION;'
                wait_member "$i";;
            *) die "Node $i state=$state; inspect diagnostics before retry";;
        esac
        sql "$i" 'SET GLOBAL super_read_only=ON;'
        rm -f "$TEMP/unfenced/$i"
    done
    validate
    log 'Join complete; all members remain write-fenced. Review then run release.'
}
release() {
    validate
    confirm 'RELEASE PRIMARY WRITES'
    for i in $(ids); do
        if [ "$(get meta primary_mode)" = multi ] || [ "$i" = 1 ]; then
            sql "$i" 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;'
        fi
    done
    log 'Primary write fences released; event schedulers remain OFF.'
}
validate() {
    connected
    target=$(val 1 gtid_executed)
    expected=$(get meta count)
    for i in $(ids); do
        sql "$i" 'SELECT MEMBER_ID,MEMBER_HOST,MEMBER_PORT,MEMBER_STATE,MEMBER_ROLE,MEMBER_VERSION FROM performance_schema.replication_group_members ORDER BY MEMBER_ID;' > "$RUN/node_$i.members.tsv"
        cat "$RUN/node_$i.members.tsv" >&2
        [ "$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE='ONLINE';")" = "$expected" ] || die "Node $i ONLINE count mismatch"
        actual=$(sql "$i" "SELECT MEMBER_ID FROM performance_schema.replication_group_members ORDER BY MEMBER_ID;")
        wanted=$(for j in $(ids); do get "$j" uuid; done | sort)
        [ "$actual" = "$wanted" ] || die 'Unexpected group member IDs'
        if [ "$(get meta primary_mode)" = single ]; then
            [ "$(sql "$i" "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY';")" = "$(get 1 uuid)" ] || die 'Unexpected primary'
        else
            [ "$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY';")" = "$expected" ] || die 'Multi-primary role count mismatch'
        fi
        [ "$(sql "$i" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(q "$target")',300);")" = 0 ] || die 'Validation GTID timeout'
        exact_gtid "$i" "$target"
        [ "$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_applier_status_by_worker WHERE CHANNEL_NAME LIKE 'group_replication_%' AND LAST_ERROR_NUMBER<>0;")" = 0 ] || die 'Applier error'
        if [ "$(get meta primary_mode)" = single ] && [ "$i" != 1 ]; then [ "$(val "$i" super_read_only)" = 1 ] || die 'Secondary is writable'; fi
        [ "$(val "$i" group_replication_group_name)" = "$(get meta group)" ] || die 'Group UUID mismatch'
        sp=1; [ "$(get meta primary_mode)" != multi ] || sp=0
        [ "$(val "$i" group_replication_single_primary_mode)" = "$sp" ] || die 'Primary mode mismatch'
        if [ "$(get meta primary_mode)" = multi ]; then
            [ "$(val "$i" auto_increment_increment)" = "$expected" ] || die 'Multi-primary auto increment interval mismatch'
            [ "$(val "$i" auto_increment_offset)" = "$i" ] || die 'Multi-primary auto increment offset mismatch'
        fi
        sql "$i" 'SELECT @@auto_increment_increment,@@auto_increment_offset,@@group_replication_auto_increment_increment;' > "$RUN/node_$i.auto_increment.tsv"
        sql "$i" 'SELECT * FROM performance_schema.replication_group_member_stats;' > "$RUN/node_$i.member_stats.tsv"
    done
    exact_gtid 1 "$target"
    put meta validated "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "VALIDATION PASSED: $expected ONLINE, $(get meta primary_mode) primary mode. Evidence: $RUN"
}
status() {
    connected
    for i in $(ids); do
        log "--- Node $i ---"
        [ ! -f "$ROOT/$i/state" ] || log "Initialization state: $(get "$i" state)"
        sql "$i" 'SELECT @@server_uuid,@@read_only,@@super_read_only,@@event_scheduler,@@gtid_executed; SELECT * FROM performance_schema.replication_group_members; SELECT CHANNEL_NAME,SERVICE_STATE,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE FROM performance_schema.replication_connection_status; SELECT CHANNEL_NAME,SERVICE_STATE,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE FROM performance_schema.replication_applier_status_by_worker;' | tee "$RUN/node_$i.status.tsv"
    done
}
platform_preflight() {
    # Fail before any database/config mutation when the controller shell
    # environment cannot support the portable code paths used by this script.
    for c in awk sed grep sort cut tr head tail dirname basename mktemp cmp diff date cp mv rm mkdir cat chmod readlink sha256sum tee stat id sleep; do
        command -v "$c" >/dev/null 2>&1 || die "Required controller utility not found: $c"
    done
    # Keep awk checks POSIX-compatible. The parentheses around a relational
    # expression used by ?: are intentional; without them some awk parsers
    # interpret '>' as output redirection.
    awk_result=$(awk 'BEGIN { n=1; print (n > 0 ? n - 1 : 0) }' 2>/dev/null) || die 'Controller awk failed the required conditional-expression compatibility check'
    [ "$awk_result" = 0 ] || die 'Controller awk returned an unexpected result in compatibility preflight'
    awk -F '\t' 'BEGIN { line="a\tb"; n=split(line,x,FS); if (n != 2 || x[1] != "a" || x[2] != "b") exit 1 }' >/dev/null 2>&1 || die 'Controller awk failed tab-field compatibility preflight'
}

main() {
    case $STEP in help|--help|-h) help; return;; --version) printf '%s\n' "$VERSION"; return;; discover|configure|tls|precheck|initialize|cutover|join|release|validate|status|all) :;; *) help; exit 2;; esac
    platform_preflight
    command -v "$MYSQL" >/dev/null 2>&1 || die 'mysql client not found; set MYSQL_GR_MYSQL'
    case $ROOT in /*) :;; *) ROOT="$(pwd)/$ROOT";; esac
    [ ! -L "$ROOT" ] || die 'Project root must not be a symlink'
    mkdir -p "$ROOT"; chmod 700 "$ROOT"
    LOCK="$ROOT/.lock"; mkdir "$LOCK" || die 'Another run is active; inspect stale lock after a killed process'
    TEMP=$(mktemp -d "$ROOT/.credentials.XXXXXX")
    RUN="$ROOT/runs/$(date +%Y%m%d_%H%M%S)_$$"; mkdir -p "$RUN"
    trap cleanup 0; trap 'exit 130' 2; trap 'exit 143' 1 15
    if [ "$STEP" != discover ] && [ "$STEP" != all ]; then [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; fi
    case $STEP in
        all) discover; configure; precheck; initialize; cutover;;
        *) "$STEP";;
    esac
}


# v1.0.4: automatic discovery/configuration overrides.
# v1.0.5: state-based member initialization, GTID diagnostics, safer prompts and concise option guidance.
# v1.0.8: client option-group compatibility, preflight checks, local-first binlog inspection and abort guidance.
# v1.0.9: generic per-GTID DML/DDL summaries and safe current-metadata comparison for divergent members.
# v1.0.10: POSIX-awk conditional fix and controller utility/awk compatibility preflight before mutation.
# v1.0.11: broader controller utility preflight and RENAME TABLE source/target metadata coverage.
# v1.0.12: reversible reprovision package generation, staging/swap rollback plan, and stable abort TSV output.
#           Logical reprovision package also exports Source users/roles/grants because partial mysqldump GTID metadata covers the full Source GTID set.
# v1.0.12-logical-safety2: NEW_EMPTY account restore + fail-fast grants/default roles + dump version guard.
# v1.0.13: single-file deployment; embedded reprovision executor; active datadir-relative TLS preservation;
#           local/remote TLS+SELinux host-side preflight; read-only mysqld_t XCom port validation;
#           mixed existing GTID replication + standalone member migration into one GR.
safe_host() { case $1 in ''|*[!a-zA-Z0-9_.-]*) die "Use an IPv4 address or DNS name (IPv6 is not supported in v$VERSION).";; esac; }

host_is_local() (
    check_host=$1
    case $check_host in localhost|localhost.localdomain|127.*) exit 0;; esac
    local_short=$(hostname 2>/dev/null || :)
    local_fqdn=$(hostname -f 2>/dev/null || :)
    [ -n "$local_short" ] && [ "$check_host" = "$local_short" ] && exit 0
    [ -n "$local_fqdn" ] && [ "$check_host" = "$local_fqdn" ] && exit 0
    if command -v ip >/dev/null 2>&1; then
        ip -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -F -x "$check_host" >/dev/null 2>&1 && exit 0
    fi
    if command -v getent >/dev/null 2>&1; then
        local_ips=$(hostname -I 2>/dev/null || :)
        for resolved in $(getent ahostsv4 "$check_host" 2>/dev/null | awk '{print $1}' | sort -u); do
            case " $local_ips " in *" $resolved "*) exit 0;; esac
        done
    fi
    exit 1
)

local_pid() (
    i=$1
    [ "$(get "$i" location)" = local ] || exit 1
    pf=$(val "$i" pid_file)
    [ -r "$pf" ] || exit 1
    p=$(cat "$pf"); uint "$p" || exit 1
    exe=$(readlink -f "/proc/$p/exe") || exit 1
    case ${exe##*/} in mysqld|mysqld-debug) :;; *) exit 1;; esac
    [ "$(val "$i" server_uuid)" = "$(get "$i" uuid)" ] || exit 1
    if [ "$(get "$i" mode)" = socket ]; then
        [ "$(val "$i" socket)" = "$(get "$i" socket)" ] || exit 1
    else
        [ "$(val "$i" port)" = "$(get "$i" port)" ] || exit 1
    fi
    printf '%s' "$p"
)

build_socket_candidates() {
    raw="$RUN/socket_candidates.raw"
    : > "$raw"
    if [ -r /proc/net/unix ]; then
        awk 'NF>=8 && $8 ~ /^\// && tolower($8) !~ /mysqlx/ && tolower($8) ~ /mysql/ {print $8}' /proc/net/unix >> "$raw" 2>/dev/null || :
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -xlpnH 2>/dev/null | awk '/mysqld/ {for (i=1;i<=NF;i++) if ($i ~ /^\// && tolower($i) !~ /mysqlx/) print $i}' >> "$raw" || :
    fi
    for cmdline in /proc/[0-9]*/cmdline; do
        [ -r "$cmdline" ] || continue
        first=$(tr '\000' '\n' < "$cmdline" 2>/dev/null | sed -n '1p')
        case ${first##*/} in mysqld|mysqld-debug)
            tr '\000' '\n' < "$cmdline" 2>/dev/null | sed -n 's/^--socket=//p' >> "$raw" || :;;
        esac
    done
    awk 'NF && tolower($0) !~ /mysqlx[^/]*\.sock$/ && !seen[$0]++' "$raw" | sort > "$RUN/socket_candidates"
}

socket_used() {
    case ":${USED_SOCKET_PATHS:-}:" in *:"$1":*) return 0;; *) return 1;; esac
}

select_socket() {
    node=$1
    available="$RUN/node_${node}.unused_sockets"
    : > "$available"
    while IFS= read -r candidate; do
        socket_used "$candidate" || printf '%s\n' "$candidate" >> "$available"
    done < "$RUN/socket_candidates"
    available_count=$(awk 'END{print NR+0}' "$available")
    if [ "$available_count" -eq 1 ]; then
        SELECTED_SOCKET=$(sed -n '1p' "$available")
        log "Node $node socket auto-detected: $SELECTED_SOCKET"
    elif [ "$available_count" -gt 1 ]; then
        log 'Detected unused local MySQL sockets:'
        awk '{printf "  %d) %s\n",NR,$0}' "$available" >&2
        choice=$(required "Node $node socket number or absolute path" 1)
        if uint "$choice"; then
            [ "$choice" -ge 1 ] && [ "$choice" -le "$available_count" ] || die 'Socket selection out of range'
            SELECTED_SOCKET=$(sed -n "${choice}p" "$available")
        else
            SELECTED_SOCKET=$choice
        fi
    else
        SELECTED_SOCKET=$(required "Node $node MySQL socket path (no unused socket auto-detected)" '')
    fi
    case $SELECTED_SOCKET in /*) :;; *) die 'Socket must be absolute';; esac
    [ -S "$SELECTED_SOCKET" ] || die "Selected path is not a socket: $SELECTED_SOCKET"
    USED_SOCKET_PATHS=${USED_SOCKET_PATHS:+$USED_SOCKET_PATHS:}$SELECTED_SOCKET
}

option_file_value() (
    file=$1; wanted=$2
    [ -r "$file" ] || exit 0
    if command -v my_print_defaults >/dev/null 2>&1; then
        value=$(my_print_defaults --defaults-file="$file" mysqld 2>/dev/null | sed -n "s/^--${wanted}=//p" | tail -n 1)
        [ -z "$value" ] || { printf '%s' "$value"; exit 0; }
    fi
    normalized=$(printf '%s' "$wanted" | tr '-' '_')
    awk -v wanted="$normalized" '
        /^[[:space:]]*\[/ {
            group=tolower($0); gsub(/[[:space:]\[\]]/,"",group); next
        }
        group=="mysqld" || group=="server" {
            line=$0
            sub(/[[:space:]]*[#;].*$/, "", line)
            pos=index(line,"="); if (!pos) next
            key=substr(line,1,pos-1); val=substr(line,pos+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/-/,"_",key)
            if (tolower(key)==wanted) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                if ((substr(val,1,1)=="\"" && substr(val,length(val),1)=="\"") || (substr(val,1,1)=="\047" && substr(val,length(val),1)=="\047")) val=substr(val,2,length(val)-2)
                result=val
            }
        }
        END { if (result!="") print result }
    ' "$file" | tail -n 1
)

normalize_path() (
    path=$1
    case $path in /*) :;; *) exit 1;; esac
    if [ -e "$path" ]; then readlink -f "$path"; else printf '%s' "$path" | sed 's#//*#/#g; s#/$##'; fi
)

cnf_matches_instance() (
    i=$1; file=$2
    runtime_socket=$(val "$i" socket)
    runtime_datadir=$(normalize_path "$(val "$i" datadir)" 2>/dev/null || printf '%s' "$(val "$i" datadir)" | sed 's#/$##')
    runtime_port=$(val "$i" port)
    matched=0
    candidate_socket=$(option_file_value "$file" socket)
    candidate_datadir=$(option_file_value "$file" datadir)
    candidate_port=$(option_file_value "$file" port)
    if [ -n "$candidate_socket" ]; then
        [ "$candidate_socket" = "$runtime_socket" ] || exit 1
        matched=$((matched+1))
    fi
    if [ -n "$candidate_datadir" ]; then
        case $candidate_datadir in /*) :;; *) candidate_datadir="$(dirname "$file")/$candidate_datadir";; esac
        candidate_datadir=$(normalize_path "$candidate_datadir" 2>/dev/null || printf '%s' "$candidate_datadir" | sed 's#/$##')
        [ "$candidate_datadir" = "$runtime_datadir" ] || exit 1
        matched=$((matched+1))
    fi
    if [ -n "$candidate_port" ]; then
        [ "$candidate_port" = "$runtime_port" ] || exit 1
        matched=$((matched+1))
    fi
    [ "$matched" -gt 0 ]
)

collect_local_cnf_candidates() {
    i=$1; pid=$2
    raw="$RUN/$i.cnf_candidates.raw"
    out="$RUN/$i.cnf_candidates"
    : > "$raw"
    tr '\000' '\n' < "/proc/$pid/cmdline" > "$RUN/$i.argv"
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || pwd)
    explicit=$(sed -n 's/^--defaults-file=//p' "$RUN/$i.argv" | head -n 1)
    if [ -n "$explicit" ]; then
        case $explicit in /*) :;; *) explicit="$cwd/$explicit";; esac
        printf '%s\n' "$explicit" >> "$raw"
    fi
    sql "$i" "SELECT DISTINCT VARIABLE_PATH FROM performance_schema.variables_info WHERE VARIABLE_PATH<>'' AND VARIABLE_SOURCE IN ('EXPLICIT','EXTRA','GLOBAL','SERVER','USER') ORDER BY VARIABLE_PATH;" >> "$raw" 2>/dev/null || :
    previous=$(legacy_cnf_candidate "$i" 2>/dev/null || :)
    [ -z "$previous" ] || printf '%s\n' "$previous" >> "$raw"
    exe=$(readlink -f "/proc/$pid/exe")
    default_line=$("$exe" --verbose --help 2>/dev/null | awk 'found {print; exit} /Default options are read from the following files/ {found=1}' || :)
    for candidate in $default_line; do
        case $candidate in '~/'*) continue;; esac
        printf '%s\n' "$candidate" >> "$raw"
    done
    : > "$out"
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        case $candidate in /*) :;; *) continue;; esac
        case ${candidate##*/} in mysqld-auto.cnf) continue;; esac
        [ -f "$candidate" ] || continue
        resolved=$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")
        printf '%s\n' "$resolved" >> "$out"
    done < "$raw"
    sort -u "$out" -o "$out"
    EXPLICIT_CNF=''
    if [ -n "$explicit" ] && [ -f "$explicit" ]; then EXPLICIT_CNF=$(readlink -f "$explicit" 2>/dev/null || printf '%s' "$explicit"); fi
}

select_local_cnf() {
    i=$1; pid=$2
    collect_local_cnf_candidates "$i" "$pid"
    if [ -n "$EXPLICIT_CNF" ]; then
        SELECTED_CNF=$EXPLICIT_CNF
        log "Node $i main option file auto-detected from mysqld --defaults-file: $SELECTED_CNF"
        return
    fi
    identity_paths="$RUN/$i.cnf_identity_paths"
    sql "$i" "SELECT DISTINCT VARIABLE_PATH FROM performance_schema.variables_info WHERE VARIABLE_NAME IN ('socket','datadir','port','pid_file','server_id') AND VARIABLE_PATH<>'' AND VARIABLE_SOURCE<>'PERSISTED' ORDER BY VARIABLE_PATH;" > "$identity_paths" 2>/dev/null || :
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        readlink -f "$f" 2>/dev/null || printf '%s\n' "$f"
    done < "$identity_paths" | sort -u > "$identity_paths.normalized"
    identity_count=$(awk 'END{print NR+0}' "$identity_paths.normalized")
    if [ "$identity_count" -eq 1 ]; then
        SELECTED_CNF=$(sed -n '1p' "$identity_paths.normalized")
        log "Node $i option file auto-detected from runtime variable provenance: $SELECTED_CNF"
        return
    fi
    matches="$RUN/$i.cnf_matches"
    : > "$matches"
    while IFS= read -r f; do
        cnf_matches_instance "$i" "$f" && printf '%s\n' "$f" >> "$matches" || :
    done < "$RUN/$i.cnf_candidates"
    match_count=$(awk 'END{print NR+0}' "$matches")
    if [ "$match_count" -eq 1 ]; then
        SELECTED_CNF=$(sed -n '1p' "$matches")
        log "Node $i option file auto-matched to runtime socket/datadir/port: $SELECTED_CNF"
        return
    fi
    previous=$(legacy_cnf_candidate "$i" 2>/dev/null || :)
    if [ -n "$previous" ] && [ -f "$previous" ]; then
        previous=$(readlink -f "$previous" 2>/dev/null || printf '%s' "$previous")
        if grep -Fx "$previous" "$RUN/$i.cnf_candidates" >/dev/null 2>&1; then
            SELECTED_CNF=$previous
            log "Node $i option file auto-reused from matching GTID replication state: $SELECTED_CNF"
            return
        fi
    fi
    candidate_count=$(awk 'END{print NR+0}' "$RUN/$i.cnf_candidates")
    if [ "$candidate_count" -eq 1 ]; then
        SELECTED_CNF=$(sed -n '1p' "$RUN/$i.cnf_candidates")
        log "Node $i only observed option file auto-selected: $SELECTED_CNF"
        return
    fi
    if [ "$candidate_count" -gt 1 ]; then
        log "Node $i has multiple plausible option files; automatic proof is ambiguous:"
        awk '{printf "  %d) %s\n",NR,$0}' "$RUN/$i.cnf_candidates" >&2
        choice=$(ask "Node $i option file number/path, or blank to generate only" '')
        case $choice in
            '') SELECTED_CNF='';;
            /*) SELECTED_CNF=$choice;;
            *)
                uint "$choice" || die 'Option file selection must be a number, absolute path, or blank'
                [ "$choice" -ge 1 ] && [ "$choice" -le "$candidate_count" ] || die 'Option file selection out of range'
                SELECTED_CNF=$(sed -n "${choice}p" "$RUN/$i.cnf_candidates");;
        esac
        return
    fi
    SELECTED_CNF=''
    log "Node $i option file could not be proven automatically; configuration will be generated without modifying a file."
}

reuse_legacy_endpoint() {
    i=$1
    [ "$(get meta mode)" = gtid ] || return 1
    [ "${MYSQL_GR_IGNORE_GTID_STATE:-0}" != 1 ] || return 1
    state=${MYSQL_GR_GTID_STATE_FILE:-${MYSQL_GTID_STATE_FILE:-"$(pwd)/.mysql_gtid_replication.state"}}
    [ -r "$state" ] || return 1
    case $i in 1) role=SOURCE;; 2) role=REPLICA;; *) return 1;; esac
    mode=$(legacy_field "$state" "${role}_MODE")
    user=$(legacy_field "$state" "${role}_ADMIN_USER")
    cnf=$(legacy_field "$state" "${role}_CNF")
    [ -n "$user" ] || return 1
    case $mode in
        socket)
            sock=$(legacy_field "$state" "${role}_SOCKET")
            [ -n "$sock" ] && [ -S "$sock" ] || return 1
            put "$i" mode socket; put "$i" socket "$sock"; put "$i" location local
            USED_SOCKET_PATHS=${USED_SOCKET_PATHS:+$USED_SOCKET_PATHS:}$sock
            ;;
        tcp)
            host=$(legacy_field "$state" "${role}_HOST")
            port=$(legacy_field "$state" "${role}_PORT")
            [ -n "$host" ] && port_ok "$port" || return 1
            safe_host "$host"
            put "$i" mode tcp; put "$i" host "$host"; put "$i" port "$port"
            location=$(legacy_field "$state" "${role}_LOCATION")
            case $location in local|remote) :;; *) if host_is_local "$host"; then location=local; else location=remote; fi;; esac
            put "$i" location "$location"
            ;;
        *) return 1;;
    esac
    put "$i" user "$user"
    [ -z "$cnf" ] || put "$i" cnf "$cnf"
    log "Node $i connection auto-reused from GTID replication state: role=$role mode=$mode user=$user"
    return 0
}

suggest_xcom_port() {
    sql_port=$1
    candidate=$((sql_port * 10 + 1))
    if ! port_ok "$candidate"; then candidate=$((sql_port + 10000)); fi
    if ! port_ok "$candidate"; then candidate=33061; fi
    printf '%s' "$candidate"
}

discover() {
    PHASE=discover
    prepare_discovery
    mkdir -p "$ROOT/meta"
    log '1) Existing GTID replication -> GR : reuse an existing GTID source/replica topology; replicas catch up before cutover.'
    log '2) Standalone -> GR                 : build GR from standalone/new members; each non-source member is inspected before provisioning.'
    legacy_state=${MYSQL_GR_GTID_STATE_FILE:-${MYSQL_GTID_STATE_FILE:-"$(pwd)/.mysql_gtid_replication.state"}}
    default_migration=2; [ -r "$legacy_state" ] && [ "${MYSQL_GR_IGNORE_GTID_STATE:-0}" != 1 ] && default_migration=1
    choice=$(required 'Migration mode (1/2)' "$default_migration")
    case $choice in 1) put meta mode gtid;; 2) put meta mode standalone;; *) die 'Choose 1 or 2';; esac
    count=$(required 'Member count (2..9)' 3)
    uint "$count" && [ "$count" -ge 2 ] && [ "$count" -le 9 ] || die 'Member count must be 2..9'
    put meta count "$count"
    log '  single: one writable PRIMARY; secondaries remain read-only.'
    log '  multi : all members can accept writes; application conflict handling is required.'
    topology=$(required 'GR primary mode (single/multi)' single)
    case $topology in single|multi) :;; *) die 'Choose single or multi';; esac
    put meta primary_mode "$topology"
    if [ "$topology" = multi ]; then
        log 'Multi-primary: concurrent write conflicts require application retries; SERIALIZABLE and cascading foreign-key operations are restricted. Serialize DDL on one member.'
        confirm 'MULTI PRIMARY REQUIREMENTS REVIEWED'
    fi
    log 'Register the authoritative Source/Standalone as node 1. It will bootstrap as primary.'
    build_socket_candidates
    USED_SOCKET_PATHS=''
    for i in $(ids); do
        mkdir -p "$ROOT/$i"
        log "--- Node $i ---"
        reused=no
        if reuse_legacy_endpoint "$i"; then
            reused=yes
            mode=$(get "$i" mode)
        else
            socket_total=$(awk 'END{print NR+0}' "$RUN/socket_candidates")
            default_mode=tcp; [ "$socket_total" -gt 0 ] && default_mode=socket
            log '  socket: local Unix socket; useful for multiple local MySQL instances.'
            log '  tcp   : network connection; use for remote hosts or TCP-only administration.'
            mode=$(required 'Management connection (socket/tcp)' "$default_mode")
            case $mode in socket|tcp) :;; *) die 'Invalid connection mode';; esac
            put "$i" mode "$mode"
            if [ "$mode" = socket ]; then
                select_socket "$i"
                s=$SELECTED_SOCKET
                put "$i" socket "$s"; put "$i" location local
            else
                h=$(required 'Management host' ''); safe_host "$h"; put "$i" host "$h"
                p=$(required 'Management TCP port' ''); port_ok "$p" || die 'Invalid port'; put "$i" port "$p"
                if host_is_local "$h"; then put "$i" location local; else put "$i" location remote; fi
            fi
        fi
        if [ "$mode" = tcp ]; then
            log '  VERIFY_IDENTITY: encrypted connection with CA/host identity verification (recommended).'
            log '  REQUIRED       : encrypted connection without server identity verification.'
            tls=$(required 'Management TLS (VERIFY_IDENTITY/REQUIRED)' VERIFY_IDENTITY)
            case $tls in VERIFY_IDENTITY|REQUIRED) :;; *) die 'Invalid TLS mode';; esac
            put "$i" admin_tls "$tls"
            if [ "$tls" = VERIFY_IDENTITY ]; then
                ca=$(required 'Client CA file on this controller' ''); [ -r "$ca" ] || die 'CA not readable'; put "$i" admin_ca "$ca"
            else confirm 'ALLOW UNVERIFIED ADMIN TLS'; fi
        fi
        if [ "$reused" != yes ]; then put "$i" user "$(required 'Administrative MySQL user' '')"; fi
        credential "$i"
        v=$(val "$i" version); version_guard "$v" || die "Unsupported version: $v"
        case "$(val "$i" version_comment) $v" in *MariaDB*|*Percona*) die 'This release targets Oracle MySQL';; esac
        put "$i" version "$v"; put "$i" uuid "$(val "$i" server_uuid)"
        put "$i" datadir "$(val "$i" datadir)"
        sql "$i" 'SELECT @@version,@@hostname,@@port,@@socket,@@datadir,@@server_id,@@server_uuid;' >&2
        if [ "$i" -gt 1 ]; then
            [ "$v" = "$(get 1 version)" ] || die 'Initial deployment requires identical exact server versions'
            for j in $(ids); do
                [ "$j" -lt "$i" ] || break
                [ "$(get "$j" uuid)" != "$(get "$i" uuid)" ] || die 'Duplicate UUID/instance selected'
            done
        fi
        cnf=''
        if p=$(local_pid "$i"); then
            select_local_cnf "$i" "$p"
            cnf=$SELECTED_CNF
            put "$i" pid "$p"
        fi
        put "$i" cnf "$cnf"
        if [ "$(get "$i" mode)" = tcp ]; then default_host=$(get "$i" host); else default_host=$(val "$i" hostname); fi
        h=$(required 'Advertised SQL host reachable from every member' "$default_host"); safe_host "$h"
        put "$i" advertise "$h"
        p=$(val "$i" port); port_ok "$p" || die 'Runtime MySQL port is invalid'; put "$i" sql_port "$p"
        log "Node $i advertised SQL port auto-detected from runtime: $p"
        suggested_xcom=$(suggest_xcom_port "$p")
        xp=$(required 'Dedicated XCom port (different from SQL/X Protocol)' "$suggested_xcom")
        port_ok "$xp" || die 'Invalid XCom port'
        [ "$xp" != "$p" ] || die 'XCom and SQL ports must differ'
        if hasvar "$i" mysqlx_port; then [ "$xp" != "$(val "$i" mysqlx_port)" ] || die 'XCom conflicts with X Protocol'; fi
        put "$i" xcom "$h:$xp"
        kind=source; channel=''
        if [ "$i" -gt 1 ]; then
            if [ "$(get meta mode)" = gtid ]; then
                sql "$i" "SELECT CHANNEL_NAME,HOST,PORT,AUTO_POSITION FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT LIKE 'group_replication_%';" >&2
                async_count=$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT LIKE 'group_replication_%';")
                case $async_count in
                    0) kind=new; log "Node $i has no existing async channel; auto-classified as new member.";;
                    1) kind=replica; channel=$(sql "$i" "SELECT CHANNEL_NAME FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT LIKE 'group_replication_%';"); log "Node $i existing replica/channel auto-detected: ${channel:-<default channel>}";;
                    *) die "Node $i has $async_count non-GR replication channels; reduce to one reviewed channel before migration";;
                esac
            else kind=new; fi
        fi
        case $channel in group_replication_*) die 'Reserved channel';; esac
        put "$i" kind "$kind"; put "$i" channel "$channel"
    done
    endpoints_check
    group=$(sql 1 'SELECT UUID();'); put meta group "$group"
    put meta allowlist "$(required 'XCom IP allowlist (member IPs/CIDRs, comma-separated; no spaces)' '')"
    case "$(get meta allowlist)" in *[!A-Za-z0-9_.,:/-]*) die 'Invalid allowlist';; esac
    log '  VERIFY_IDENTITY: verify the distributed-recovery server certificate identity (recommended).'
    log '  REQUIRED       : require TLS but do not verify server identity.'
    tls=$(required 'GR TLS (VERIFY_IDENTITY/REQUIRED)' VERIFY_IDENTITY)
    case $tls in VERIFY_IDENTITY|REQUIRED) :;; *) die 'Invalid GR TLS';; esac
    [ "$tls" != REQUIRED ] || confirm 'ALLOW UNVERIFIED GR TLS'
    put meta tls "$tls"
    for i in $(ids); do
        ca=$(val "$i" ssl_ca)
        case $ca in '') :;; /*) :;; *) ca="$(val "$i" datadir)$ca";; esac
        if [ -n "$ca" ]; then
            log "Node $i recovery CA path auto-detected from runtime: $ca"
        else
            ca=$(required "Node $i CA path on its server (runtime ssl_ca is empty)" '')
        fi
        case $ca in /*) :;; *) die 'Use absolute server CA paths';; esac
        put "$i" recovery_ca "$ca"
    done
    put meta complete yes
    PHASE=registered
    log "Discovery complete: $ROOT"
    [ "$STEP" = all ] || log "NEXT: sh mysql_gr_migrate.sh configure"
}

ssh_options() (
    ssh_node=$1
    command -v ssh >/dev/null 2>&1 || die 'OpenSSH client is required for remote OS management; no packages are installed automatically.'
    if [ ! -f "$ROOT/$ssh_node/ssh_host" ]; then
        ssh_host=${MYSQL_GR_SSH_HOST:-$(get "$ssh_node" host)}; safe_host "$ssh_host"
        ssh_defaults=$(ssh -G "$ssh_host" 2>/dev/null || :)
        ssh_port=${MYSQL_GR_SSH_PORT:-$(printf '%s\n' "$ssh_defaults" | awk '$1=="port" {print $2;exit}')}
        [ -n "$ssh_port" ] || ssh_port=22
        port_ok "$ssh_port" || die 'Invalid SSH port'
        ssh_user=${MYSQL_GR_SSH_USER:-$(printf '%s\n' "$ssh_defaults" | awk '$1=="user" {print $2;exit}')}
        [ -n "$ssh_user" ] || ssh_user=$(id -un)
        case $ssh_user in ''|-*|*[!A-Za-z0-9_.-]*) die 'Invalid SSH OS user';; esac
        ssh_key=${MYSQL_GR_SSH_KEY:-}
        [ -z "$ssh_key" ] || [ -r "$ssh_key" ] || die 'SSH key is not readable'
        privilege=${MYSQL_GR_SSH_PRIVILEGE:-current}
        case $privilege in current|sudo) :;; *) die 'MYSQL_GR_SSH_PRIVILEGE must be current or sudo';; esac
        log "Node $ssh_node SSH settings auto-selected: $ssh_user@$ssh_host:$ssh_port privilege=$privilege"
        put "$ssh_node" ssh_host "$ssh_host"; put "$ssh_node" ssh_port "$ssh_port"
        put "$ssh_node" ssh_user "$ssh_user"; put "$ssh_node" ssh_key "$ssh_key"
        put "$ssh_node" ssh_privilege "$privilege"
    fi
    if [ ! -f "$TEMP/$ssh_node.remote.cnf" ]; then
        credential "$ssh_node"
        sed -n '/^user=/p; /^password=/p' "$TEMP/$ssh_node.cnf" > "$TEMP/$ssh_node.remote.cnf"
        log "Node $ssh_node remote socket inspection will first reuse the same administrative DB credentials; SSH/manual fallback remains available on failure."
    fi
)

configure_remote() {
    remote_node=$1; remote_snippet=$2
    if ! command -v ssh >/dev/null 2>&1; then
        log 'OpenSSH client unavailable; generating the manual helper without installing packages.'
        configure_manual "$remote_node" "$remote_snippet"
        return 0
    fi
    ssh_options "$remote_node"
    if ! remote_call "$remote_node" inspect > "$RUN/node_${remote_node}.remote_inspect.display"; then
        log 'SSH inspection failed. Preparing a password-free helper to copy and run on that host.'
        configure_manual "$remote_node" "$remote_snippet"
        return 0
    fi
    cat "$RUN/node_${remote_node}.remote_inspect.display" >&2
    current_cnf=$(get "$remote_node" cnf)
    [ -n "$current_cnf" ] || current_cnf=$(awk -F '\t' '$1=="DEFAULT_CNF" && $2!="" {print $2;exit}' "$RUN/node_${remote_node}.remote_inspect.display")
    if [ -z "$current_cnf" ]; then
        candidate_count=$(awk -F '\t' '$1=="CANDIDATE" && $2!="" {n++} END{print n+0}' "$RUN/node_${remote_node}.remote_inspect.display")
        if [ "$candidate_count" -eq 1 ]; then
            current_cnf=$(awk -F '\t' '$1=="CANDIDATE" && $2!="" {print $2;exit}' "$RUN/node_${remote_node}.remote_inspect.display")
        fi
    fi
    if [ -n "$current_cnf" ]; then
        selected_cnf=$current_cnf
        log "Node $remote_node remote main option file auto-selected: $selected_cnf"
    else
        selected_cnf=$(required "Node $remote_node remote main cnf path (automatic proof is ambiguous)" '')
    fi
    put "$remote_node" cnf "$selected_cnf"
    if ! remote_call "$remote_node" plan "$remote_snippet" no >&2; then
        log 'Remote plan did not complete. Use the helper on that host to inspect and resolve the reported configuration issue.'
        configure_manual "$remote_node" "$remote_snippet"
        return 0
    fi
    log "Remote node $remote_node: back up $selected_cnf, apply the displayed configuration, optionally restart the detected instance."
    [ "$(ask 'Apply this remote configuration? (yes/no)' no)" = yes ] || return 0
    restart=$(required 'Restart this remote instance after applying? (yes/no)' yes)
    case $restart in yes|no) :;; *) die 'Choose yes or no';; esac
    remote_call "$remote_node" apply "$remote_snippet" "$restart" >&2
    if [ "$restart" = yes ]; then wait_connection "$remote_node"; fi
}

configure() {
    PHASE=configure
    put meta mutation_started configure
    connected; no_group; endpoints_check
    while :; do
    log '  minimum   : GR-required settings only; preserves existing durability policy where possible.'
    log '  production: minimum + sync_binlog=1, innodb_flush_log_at_trx_commit=1 and FULL row image.'
    profile=$(required 'Configuration profile (minimum/production)' minimum)
    case $profile in
        minimum|min) profile=minimum; break;;
        production|prod) profile=production; break;;
        *) log 'Invalid profile. Enter minimum/min or production/prod.';;
    esac
done
    put meta profile "$profile"
    if [ "$profile" = production ]; then
        log 'Production profile adds sync_binlog=1, innodb_flush_log_at_trx_commit=1 and FULL row image; storage I/O can increase.'
        for i in $(ids); do
            retention=$(required "Node $i binary log retention seconds (must cover provisioning/recovery)" "$(val "$i" binlog_expire_logs_seconds)")
            uint "$retention" && [ "$retention" -le 4294967295 ] || die 'Invalid retention'
            put "$i" retention "$retention"
        done
    fi
    seen=' '
    for i in $(ids); do
        sid=$(val "$i" server_id)
        sid_ok=yes
        [ "$sid" != 0 ] || sid_ok=no
        case $seen in *" $sid "*) sid_ok=no;; esac
        if [ "$sid_ok" = yes ]; then
            log "Node $i server_id auto-accepted from runtime: $sid"
        else
            sid=$(required "Node $i unique server_id (runtime value is zero/duplicate)" '')
        fi
        uint "$sid" && [ "$sid" -gt 0 ] && [ "$sid" -le 4294967295 ] || die 'Invalid server_id'
        case $seen in *" $sid "*) die 'Duplicate server_id';; esac
        seen="$seen$sid "
        snippet="$RUN/node_$i.cnf"
        config_lines "$i" "$sid" > "$snippet"
        log "Node $i proposed required configuration:"; cat "$snippet" >&2
        if [ -z "$(get "$i" cnf)" ]; then
            previous_cnf=$(legacy_cnf_candidate "$i")
            if [ -n "$previous_cnf" ]; then
                log "Node $i cnf candidate from matching GTID state: $previous_cnf (will be reverified on the actual host)"
                put "$i" cnf "$previous_cnf"
            fi
        fi
        if [ "$(get "$i" location)" = remote ]; then
            log "Node $i is remote: trying existing OpenSSH configuration first; falling back to a copyable manual helper if unavailable."
            configure_remote "$i" "$snippet"
            continue
        fi
        if [ -z "$(get "$i" cnf)" ]; then
            log "Apply $snippet on node $i, restart that instance, then rerun precheck."
            continue
        fi
        [ "$(ask "Back up and apply node $i cnf? (yes/no)" no)" = yes ] || continue
        p=$(local_pid "$i") || die 'Cannot prove local instance identity'
        exe=$(readlink -f "/proc/$p/exe")
        cnf=$(get "$i" cnf); case $cnf in /*) :;; *) die 'cnf must be absolute';; esac
        [ -f "$cnf" ] && [ ! -L "$cnf" ] || die 'cnf must be a regular non-symlink file'
        for j in $(ids); do
            [ "$j" = "$i" ] && continue
            if [ "$(get "$j" location)" = local ] && [ "$(get "$j" cnf)" = "$cnf" ]; then die 'Shared cnf requires manual instance-specific settings'; fi
        done
        candidate="${cnf}.gr_candidate_$$"
        cnf_chain_snapshot "$cnf" "$RUN/node_$i.include_chain.before" "$(readlink -f "/proc/$p/cwd")"
        sed '/^# BEGIN mysql_gr_migrate$/,/^# END mysql_gr_migrate$/d' "$cnf" > "$candidate"
        { printf '\n# BEGIN mysql_gr_migrate\n'; cat "$snippet"; printf '# END mysql_gr_migrate\n'; } >> "$candidate"
        if ! "$exe" --defaults-file="$candidate" --validate-config > "$RUN/node_$i.config_validation.log" 2>&1; then
            rm -f "$candidate"; die "Configuration validation failed: $RUN/node_$i.config_validation.log"
        fi
        backup="${cnf}.before_gr_$(date +%Y%m%d_%H%M%S)_$$"
        cnf_chain_snapshot "$cnf" "$RUN/node_$i.include_chain.current" "$(readlink -f "/proc/$p/cwd")"
        cmp -s "$RUN/node_$i.include_chain.before" "$RUN/node_$i.include_chain.current" || die 'Configuration include chain changed while preparing candidate'
        cp -p "$cnf" "$backup"; cmp -s "$cnf" "$backup" || die 'Config backup verification failed'
        cat "$candidate" > "$cnf"; rm -f "$candidate"
        log "Saved backup: $backup"
        service=$(sed -n 's#.*\/\([^/]*\.service\)$#\1#p' "/proc/$p/cgroup" | head -n 1)
        if [ -n "$service" ] && command -v systemctl >/dev/null 2>&1 && [ "$(systemctl show "$service" -p MainPID --value)" = "$p" ]; then
            log "Restart command: systemctl restart $service"
            if [ "$(ask 'Restart now? (yes/no)' no)" = yes ]; then systemctl restart "$service"; wait_connection "$i"; fi
        else
            restart_direct "$i" "$p" "$exe" "$cnf"
        fi
    done
    log 'Configuration generation finished. Runtime precheck is mandatory before initialization.'
    [ "$STEP" = all ] || log 'NEXT: sh mysql_gr_migrate.sh precheck'
}


emit_reprovision_helper() {
    cat <<'MYSQL_GR_REPROVISION_HELPER'
#!/bin/sh
# Host-side reprovision executor. Copy the complete package to the target host.
# No package installation, GTID reset, or original-directory deletion.
set -eu
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ACTION=${1:-help}
case $ACTION in stage|swap|rollback) :;; *) printf 'Usage: sh reprovision_helper.sh stage|swap|rollback PACKAGE TARGET_AUTH SOURCE_AUTH\nAUTH: absolute client option file, or login-path:NAME\n'; exit 2;; esac
PKG=$(readlink -f "${2:?Package directory required}")
TARGET_AUTH=${3:?Target authentication required}
SOURCE_AUTH=${4:?Source authentication required}
MYSQL=${MYSQL_GR_MYSQL:-mysql}
MYSQLDUMP=${MYSQL_GR_MYSQLDUMP:-mysqldump}
for utility in "$MYSQL" "$MYSQLDUMP" sha256sum readlink stat awk sed cmp cp mv mkdir chmod chown id mktemp; do command -v "$utility" >/dev/null 2>&1 || fail "Missing existing utility $utility"; done
[ -d "$PKG" ] && [ ! -L "$PKG" ] || fail 'Invalid package directory'
[ "$(stat -c %u "$PKG")" = "$(id -u)" ] || fail 'Package must be owned by the executing OS account'
LOCK="$PKG/.executor.lock"
mkdir "$LOCK" || fail 'Executor lock exists; inspect previous operation before retry'
WORK=$(mktemp -d "$PKG/.executor.XXXXXX")
STAGED_RUNNING=no
cleanup_executor() {
    code=$?
    trap - 0 1 2 15
    if [ "$STAGED_RUNNING" = yes ]; then
        # Both auth paths are needed if import failed during account restoration.
        if ! db "$SOURCE_AUTH" "$STAGE_SOCKET" 'SHUTDOWN;' >/dev/null 2>&1; then
            "$MYSQL" --no-defaults --no-login-paths --protocol=SOCKET --socket="$STAGE_SOCKET" -uroot -e 'SHUTDOWN;' >/dev/null 2>&1 || printf 'Staging may still be running at %s; inspect it.\n' "$STAGE_SOCKET" >&2
        fi
    fi
    # Evidence and every datadir are retained, including failed staging directories.
    rmdir "$LOCK" 2>/dev/null || :
    exit "$code"
}
trap cleanup_executor 0
trap 'exit 130' 2
trap 'exit 143' 1 15
db() (
    auth=$1; socket=$2; statement=$3
    case $auth in login-path:*) set -- "--login-path=${auth#login-path:}";; /*) [ -r "$auth" ] || fail 'Unreadable auth file'; set -- "--defaults-file=$auth" --no-login-paths;; *) fail 'AUTH must be an absolute option file or login-path:NAME';; esac
    printf '%s\n' "$statement" | "$MYSQL" "$@" --protocol=SOCKET --socket="$socket" --connect-timeout=5 --batch --raw --skip-column-names
)
field() { [ -f "$PKG/$1" ] || fail "Missing package field $1"; cat "$PKG/$1"; }
save() { printf '%s\n' "$2" > "$PKG/$1"; }
OLD_UUID=$(field expected_uuid)
SOCKET=$(field expected_socket)
DATA=$(field expected_datadir); DATA=${DATA%/}
VERSION=$(field source_version)
GTID=$(field target_gtid)
CNF=$(field expected_cnf)
case $DATA in /*) :;; *) fail 'Datadir must be absolute';; esac
[ "$DATA" != / ] && [ -n "$DATA" ] || fail 'Unsafe datadir'
check_package() (
    cd "$PKG"
    sha256sum -c package.sha256 > "$WORK/checksums" 2>&1 || fail 'Package checksum mismatch'
)
selinux_mode() {
    if command -v getenforce >/dev/null 2>&1; then getenforce 2>/dev/null || printf 'Unknown'; else printf 'Disabled'; fi
}
require_selinux_restore() {
    case $(selinux_mode) in
        Enforcing|Permissive) command -v restorecon >/dev/null 2>&1 || fail 'SELinux is active but restorecon is unavailable. No package or SELinux policy is installed automatically.';;
    esac
}
restore_datadir_context() {
    path=$1
    case $(selinux_mode) in
        Enforcing|Permissive) restorecon -R "$path" > "$WORK/restorecon.$$.log" 2>&1;;
        *) return 0;;
    esac
}
identity() (
    expected=$1; auth=$2
    actual=$(db "$auth" "$SOCKET" 'SELECT @@server_uuid;') || fail 'Cannot query target identity'
    [ "$actual" = "$expected" ] || fail 'Server UUID changed'
    current=$(db "$auth" "$SOCKET" 'SELECT @@datadir;')
    [ "${current%/}" = "$DATA" ] || fail 'Target datadir changed'
    [ "$(db "$auth" "$SOCKET" 'SELECT @@version;')" = "$VERSION" ] || fail 'Version differs from source'
    [ "$(db "$auth" "$SOCKET" 'SELECT @@super_read_only;')" = 1 ] || fail 'Target must remain write fenced'
    [ "$(db "$auth" "$SOCKET" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE IN ('ONLINE','RECOVERING');")" = 0 ] || fail 'Target is already a GR member'
)
wait_down() (
    pid=$1; start=$2; attempt=0
    while [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start" ]; do
        [ "$attempt" -lt 120 ] || fail 'Process did not stop; refusing duplicate startup or datadir move'
        sleep 1; attempt=$((attempt+1))
    done
)
capture_launcher() {
    pidfile=$(db "$TARGET_AUTH" "$SOCKET" 'SELECT @@pid_file;')
    PID=$(cat "$pidfile")
    case $PID in ''|*[!0-9]*) fail 'Invalid server PID';; esac
    EXE=$(readlink -f "/proc/$PID/exe")
    case ${EXE##*/} in mysqld|mysqld-debug) :;; *) fail 'PID is not mysqld';; esac
    CWD=$(readlink -f "/proc/$PID/cwd")
    tr '\000' '\n' < "/proc/$PID/cmdline" > "$PKG/launcher.argv"
    # Unknown command-line options could write outside staging or defeat fences.
    first=yes
    while IFS= read -r arg; do
        if [ "$first" = yes ]; then first=no; continue; fi
        case $arg in --defaults-file=*|--daemonize|--user=*|--skip-replica-start=ON|--event-scheduler=OFF|--super-read-only=ON) :;; *) fail "Launcher option needs explicit support before swap: $arg";; esac
    done < "$PKG/launcher.argv"
    grep -Fx -- "--defaults-file=$CNF" "$PKG/launcher.argv" >/dev/null || fail 'Explicit matching --defaults-file is required for this direct executor'
    parent=$(awk '{print $4}' "/proc/$PID/stat")
    parent_name=$(cat "/proc/$parent/comm")
    case $parent_name in systemd|init|bash|sh|dash) :;; *) fail 'Unsupported supervisor; do not stop this instance automatically';; esac
    service=$(sed -n 's#.*\/\([^/]*\.service\)$#\1#p' "/proc/$PID/cgroup" | head -n 1)
    if [ -n "$service" ] && [ "$(systemctl show "$service" -p MainPID --value)" = "$PID" ]; then
        fail 'Systemd-managed instance requires a separately reviewed launcher; direct executor will not bypass it'
    fi
    save expected_pid_file "$pidfile"
    save launcher_exe "$EXE"; save launcher_cwd "$CWD"
    save original_inode "$(stat -c '%d:%i' "$DATA")"
    save original_gtid "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT REPLACE(@@gtid_executed,CHAR(10),"");')"
    db "$TARGET_AUTH" "$SOCKET" "SELECT CONCAT('START REPLICA IO_THREAD FOR CHANNEL ',QUOTE(CHANNEL_NAME),';') FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON'; SELECT CONCAT('START REPLICA SQL_THREAD FOR CHANNEL ',QUOTE(CHANNEL_NAME),';') FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON';" > "$PKG/original_async.sql"
}
start_original() (
    exe=$(field launcher_exe); cwd=$(field launcher_cwd)
    set --
    first=yes
    while IFS= read -r arg; do
        if [ "$first" = yes ]; then first=no; continue; fi
        case $arg in --daemonize) continue;; esac
        set -- "$@" "$arg"
    done < "$PKG/launcher.argv"
    cd "$cwd"
    "$exe" "$@" --daemonize --skip-replica-start=ON --event-scheduler=OFF --super-read-only=ON
)
wait_up() (
    auth=$1; expected=$2; attempt=0
    while [ "$attempt" -lt 120 ]; do
        if uuid=$(db "$auth" "$SOCKET" 'SELECT @@server_uuid;' 2>/dev/null); then
            [ "$uuid" = "$expected" ] || fail 'Unexpected UUID after startup'
            exit 0
        fi
        sleep 1; attempt=$((attempt+1))
    done
    fail 'Instance did not reconnect'
)
stage_paths() {
    STAGE=$(field stage_path)
    STAGE_SOCKET=$(field stage_socket)
    BACKUP=$(field backup_path)
    FAILED=$(field failed_path)
    for path in "$STAGE" "$BACKUP" "$FAILED"; do
        case $path in "$DATA".gr_stage_*|"$DATA".gr_backup_*|"$DATA".gr_failed_*) :;; *) fail 'Invalid saved staging/backup path';; esac
        [ ! -L "$path" ] || fail 'Staging/backup path is a symlink'
    done
}
staging_validate() (
    auth=$1; socket=$2
    [ "$(db "$auth" "$socket" "SELECT GTID_SUBSET(@@gtid_executed,'$GTID') AND GTID_SUBSET('$GTID',@@gtid_executed);")" = 1 ] || fail 'GTID is not exactly equal to source snapshot'
    [ "$(db "$auth" "$socket" 'SELECT @@super_read_only;')" = 1 ] || fail 'New instance is not write fenced'
    [ "$(db "$auth" "$socket" 'SELECT @@event_scheduler;')" = OFF ] || fail 'Event scheduler must remain OFF'
    case $auth in login-path:*) set -- "--login-path=${auth#login-path:}";; *) set -- "--defaults-file=$auth" --no-login-paths;; esac
    # Canonical source dump includes rows ordered by primary key, full stored
    # objects, schemas, indexes, constraints, and DEFINER clauses.
    databases=$(cat "$PKG/databases")
    set -f
    for database in $databases; do case $database in *[!A-Za-z0-9_\$]*) fail 'Unsupported schema name';; esac; done
    "$MYSQLDUMP" "$@" --protocol=SOCKET --socket="$socket" --skip-comments --skip-dump-date --no-tablespaces --set-gtid-purged=OFF --routines --events --triggers --hex-blob --order-by-primary --skip-extended-insert --databases $databases > "$WORK/actual.sql" 2> "$WORK/dump.err" || fail 'Full validation dump failed'
    cmp -s "$PKG/source_validation.sql" "$WORK/actual.sql" || fail 'Full schema/stored-object/data validation differs; inspect protected executor evidence'
    # Reuse the same export logic to compare account authentication, grants,
    # role edges and default roles without printing authentication hashes.
    (
        MYSQL_GR_LIB_ONLY=1
        . "$PKG/mysql_gr_migrate.sh"
        RUN="$WORK/account_validation"; TEMP="$WORK"; mkdir -p "$RUN" "$RUN/actual"
        sql() { db "$auth" "$socket" "$2"; }
        export_source_accounts "$RUN/actual" 1 >/dev/null || fail "Account export failed during validation"
        for file in source_accounts.list source_accounts.sql source_grants.sql source_default_roles.sql; do
            cmp -s "$PKG/$file" "$RUN/actual/$file" || fail "Account validation differs: $file"
        done
    )
)
check_package
case $ACTION in
stage)
    [ ! -e "$PKG/stage_path" ] || fail 'Staging already attempted; preserve evidence and build a new package to retry'
    identity "$OLD_UUID" "$TARGET_AUTH"
    require_selinux_restore
    [ "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT COUNT(*) FROM performance_schema.persisted_variables;')" = 0 ] || fail "Persisted target settings require explicit reprovision migration; original is unchanged"
    [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'Original datadir is not a plain directory'
    capture_launcher
    [ "$(id -u)" = 0 ] || [ "$(id -u)" = "$(stat -c %u "$DATA")" ] || fail 'Run as original datadir owner or root'
    [ -z "$(find "$DATA" -type l -print -quit)" ] || fail 'Datadir symlinks require a reviewed storage executor'
    for variable in log_bin_basename relay_log_basename; do
        external=$(db "$TARGET_AUTH" "$SOCKET" "SELECT @@$variable;")
        case $external in "$DATA"/*) :;; *) fail "External $variable requires an explicit retention/rollback plan";; esac
    done
    stamp=$(date +%Y%m%d_%H%M%S)_$$
    STAGE="$DATA.gr_stage_$stamp"
    STAGE_SOCKET="$STAGE/gr.sock"
    [ "${#STAGE_SOCKET}" -lt 100 ] || fail 'Staging socket pathname is too long'
    save stage_path "$STAGE"; save stage_socket "$STAGE_SOCKET"
    save backup_path "$DATA.gr_backup_$stamp"; save failed_path "$DATA.gr_failed_$stamp"
    owner=$(stat -c %U "$DATA"); group=$(stat -c %G "$DATA")
    mkdir "$STAGE"
    chmod "$(stat -c %a "$DATA")" "$STAGE"
    chown "$owner:$group" "$STAGE"
    # Reject external tablespaces and nondefault storage layouts. A fresh
    # datadir cannot safely replace files living outside it.
    [ "$(db "$TARGET_AUTH" "$SOCKET" "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES WHERE SPACE_TYPE='General' AND NAME<>'mysql';")" = 0 ] || fail 'External/general tablespaces require a reviewed executor'
    lower=$(db "$TARGET_AUTH" "$SOCKET" 'SELECT @@lower_case_table_names;')
    "$EXE" --no-defaults --initialize-insecure --user="$owner" --datadir="$STAGE" --lower-case-table-names="$lower" > "$WORK/initialize.log" 2>&1
    # Staging reads no original option files, has no network listener, and
    # writes logs only inside its own directory.
    "$EXE" --no-defaults --user="$owner" --datadir="$STAGE" --socket="$STAGE_SOCKET" --pid-file="$STAGE/gr.pid" --log-error="$STAGE/gr.log" --skip-networking --mysqlx=OFF --event-scheduler=OFF --skip-replica-start=ON --gtid-mode=ON --enforce-gtid-consistency=ON --log-bin=gr-stage-bin --server-id=4294967294 --lower-case-table-names="$lower" --daemonize
    STAGED_RUNNING=yes
    { printf 'SET SESSION sql_log_bin=0;\n'; cat "$PKG/source_accounts.sql" "$PKG/source_application.sql" "$PKG/source_grants.sql"; printf 'SET GLOBAL super_read_only=ON;\n'; } | "$MYSQL" --no-defaults --no-login-paths --protocol=SOCKET --socket="$STAGE_SOCKET" -uroot --binary-mode > "$WORK/restore.log" 2>&1
    staging_validate "$SOURCE_AUTH" "$STAGE_SOCKET"
    new_uuid=$(db "$SOURCE_AUTH" "$STAGE_SOCKET" 'SELECT @@server_uuid;')
    [ "$new_uuid" != "$OLD_UUID" ] || fail 'Staging UUID unexpectedly equals original'
    save new_uuid "$new_uuid"
    pid=$(cat "$STAGE/gr.pid"); start=$(awk '{print $22}' "/proc/$pid/stat")
    db "$SOURCE_AUTH" "$STAGE_SOCKET" 'SHUTDOWN;'
    wait_down "$pid" "$start"
    STAGED_RUNNING=no
    # Preserve the exact active TLS files referenced by runtime/CNF. TLS paths
    # below the datadir must survive the atomic datadir swap at the same relative
    # path; external absolute TLS paths remain in place and are recorded only.
    : > "$PKG/runtime_tls_paths.tsv"
    for variable in ssl_ca ssl_cert ssl_key; do
        tls_value=$(db "$TARGET_AUTH" "$SOCKET" "SELECT @@$variable;")
        [ -n "$tls_value" ] || fail "Runtime $variable is empty; cannot preserve TLS across reprovision swap"
        case $tls_value in /*) tls_path=$tls_value;; *) tls_path="$DATA/$tls_value";; esac
        [ -f "$tls_path" ] && [ -r "$tls_path" ] || fail "Runtime $variable file is not readable: $tls_path"
        case $tls_path in
            "$DATA"/*)
                rel=${tls_path#"$DATA"/}
                case $rel in ''|../*|*/../*|*/..) fail "Unsafe TLS path below datadir: $tls_path";; esac
                (cd "$DATA" && cp -a --parents "$rel" "$STAGE") || fail "Cannot preserve $variable inside staging datadir"
                printf '%s\tDATADIR\t%s\n' "$variable" "$rel" >> "$PKG/runtime_tls_paths.tsv"
                ;;
            *)
                printf '%s\tEXTERNAL\t%s\n' "$variable" "$tls_path" >> "$PKG/runtime_tls_paths.tsv"
                ;;
        esac
    done
    # Capture the entire include chain using the reviewed library parser.
    ( MYSQL_GR_LIB_ONLY=1; . "$PKG/mysql_gr_migrate.sh"; TEMP="$WORK"; cnf_chain_snapshot "$CNF" "$PKG/include_chain.before" "$CWD" )
    save state STAGED_VALIDATED
    printf 'STAGED_VALIDATED: %s. Original instance and datadir unchanged.\n' "$STAGE"
    ;;
swap)
    [ "$(field state)" = STAGED_VALIDATED ] || fail 'Validated staging is required'
    stage_paths
    identity "$OLD_UUID" "$TARGET_AUTH"
    [ "$(stat -c '%d:%i' "$DATA")" = "$(field original_inode)" ] || fail 'Original directory identity changed'
    [ "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT REPLACE(@@gtid_executed,CHAR(10),"");')" = "$(field original_gtid)" ] || fail 'Original GTID changed after staging'
    [ ! -e "$BACKUP" ] && [ ! -e "$FAILED" ] || fail 'Backup/failed path collision'
    [ "$(stat -c %d "$DATA")" = "$(stat -c %d "$STAGE")" ] || fail 'Swap must stay on the same filesystem'
    ( MYSQL_GR_LIB_ONLY=1; . "$PKG/mysql_gr_migrate.sh"; TEMP="$WORK"; cnf_chain_snapshot "$CNF" "$WORK/include_chain.current" "$(field launcher_cwd)" )
    cmp -s "$PKG/include_chain.before" "$WORK/include_chain.current" || fail 'Configuration/include chain changed since staging'
    # Refuse a live staging process before any rename.
    if [ -S "$STAGE_SOCKET" ]; then fail 'Staging socket still exists; verify clean shutdown'; fi
    pidfile=$(db "$TARGET_AUTH" "$SOCKET" 'SELECT @@pid_file;'); pid=$(cat "$pidfile")
    [ "$(readlink -f "/proc/$pid/exe")" = "$(field launcher_exe)" ] || fail 'Launcher changed'
    start=$(awk '{print $22}' "/proc/$pid/stat")
    save state STOPPING_ORIGINAL
    db "$TARGET_AUTH" "$SOCKET" 'SHUTDOWN;'
    wait_down "$pid" "$start"
    save state ORIGINAL_STOPPED
    mv -T "$DATA" "$BACKUP"
    save state ORIGINAL_BACKED_UP
    if ! mv -T "$STAGE" "$DATA"; then mv -T "$BACKUP" "$DATA"; restore_datadir_context "$DATA" || :; start_original; fail 'Staging move failed; original directory restored'; fi
    if ! restore_datadir_context "$DATA"; then
        mv -T "$DATA" "$STAGE" || fail 'SELinux restore failed and staged datadir could not be moved back for rollback'
        mv -T "$BACKUP" "$DATA" || fail 'SELinux restore failed and original datadir could not be restored'
        restore_datadir_context "$DATA" || :
        start_original || :
        fail 'SELinux context restore failed on swapped datadir; original datadir restore/start attempted. No policy/package was changed.'
    fi
    save state SWAPPED
    if start_original && wait_up "$SOURCE_AUTH" "$(field new_uuid)" && staging_validate "$SOURCE_AUTH" "$SOCKET"; then
        save state SWAP_VALIDATED
        printf 'SWAP_VALIDATED. Retained original: %s. New instance remains fenced.\n' "$BACKUP"
    else
        printf 'Post-swap validation failed. Run rollback using this same package; original is retained at %s.\n' "$BACKUP" >&2
        exit 1
    fi
    ;;
rollback)
    stage_paths
    case $(field state) in ORIGINAL_BACKED_UP|SWAPPED|SWAP_VALIDATED) :;; *) fail 'State requires manual inspection; no paths moved';; esac
    [ -d "$BACKUP" ] && [ ! -e "$FAILED" ] || fail 'Rollback backup missing or failed path occupied'
    [ "$(stat -c '%d:%i' "$BACKUP")" = "$(field original_inode)" ] || fail 'Backup directory identity mismatch'
    if [ -d "$DATA" ]; then
        # Never move an unverified or still-running current datadir.
        identity "$(field new_uuid)" "$SOURCE_AUTH"
        [ "$(db "$SOURCE_AUTH" "$SOCKET" "SELECT GTID_SUBSET(@@gtid_executed,'$GTID') AND GTID_SUBSET('$GTID',@@gtid_executed);")" = 1 ] || fail 'New transactions exist; rollback requires reconciliation'
        pidfile=$(db "$SOURCE_AUTH" "$SOCKET" 'SELECT @@pid_file;'); pid=$(cat "$pidfile")
        start=$(awk '{print $22}' "/proc/$pid/stat")
        db "$SOURCE_AUTH" "$SOCKET" 'SHUTDOWN;'
        wait_down "$pid" "$start"
        mv -T "$DATA" "$FAILED"
    fi
    mv -T "$BACKUP" "$DATA"
    restore_datadir_context "$DATA" || fail 'Original datadir restored but SELinux context restore failed; do not start until host policy/context is corrected'
    start_original
    wait_up "$TARGET_AUTH" "$OLD_UUID"
    identity "$OLD_UUID" "$TARGET_AUTH"
    [ "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT REPLACE(@@gtid_executed,CHAR(10),"");')" = "$(field original_gtid)" ] || fail 'Original GTID changed during rollback'
    [ ! -s "$PKG/original_async.sql" ] || db "$TARGET_AUTH" "$SOCKET" "$(cat "$PKG/original_async.sql")"
    save state ROLLED_BACK
    printf 'ROLLED_BACK. Original UUID restored; writes, replication auto-start and events remain fenced.\n'
    ;;
esac
MYSQL_GR_REPROVISION_HELPER
}

build_reprovision_executor() (
    node=$1; expected=$2; directory=$3
    script_dir=${MYSQL_GR_SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
    [ -f "$script_dir/mysql_gr_migrate.sh" ] || die 'Cannot locate mysql_gr_migrate.sh; set MYSQL_GR_SCRIPT_DIR when sourced'
    cp "$script_dir/mysql_gr_migrate.sh" "$directory/mysql_gr_migrate.sh"
    emit_reprovision_helper > "$directory/reprovision_helper.sh"
    chmod 700 "$directory/reprovision_helper.sh"
    printf '%s\n' "$(get "$node" uuid)" > "$directory/expected_uuid"
    printf '%s\n' "$(val "$node" socket)" > "$directory/expected_socket"
    printf '%s\n' "$(val "$node" datadir)" > "$directory/expected_datadir"
    printf '%s\n' "$(get "$node" cnf)" > "$directory/expected_cnf"
    printf '%s\n' "$(val 1 version)" > "$directory/source_version"
    printf '%s\n' "$expected" > "$directory/target_gtid"
    databases=$(sql 1 "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY SCHEMA_NAME;")
    printf '%s\n' "$databases" > "$directory/databases"
    set -f; set -- $databases; set +f
    [ "$#" -gt 0 ] || die 'Empty source schema inventory'
    for database do case $database in *[!A-Za-z0-9_\$]*) die 'Unsupported schema name';; esac; done
    "$DUMP" --defaults-file="$TEMP/1.cnf" --no-login-paths --skip-comments --skip-dump-date --no-tablespaces --set-gtid-purged=OFF --routines --events --triggers --hex-blob --order-by-primary --skip-extended-insert --databases "$@" > "$directory/source_validation.sql" 2> "$directory/source_validation.err" || die 'Full source validation snapshot failed'
    exact_gtid 1 "$expected"
    (cd "$directory" && sha256sum expected_uuid expected_socket expected_datadir expected_cnf source_version target_gtid databases source_accounts.list source_accounts.sql source_grants.sql source_default_roles.sql source_application.sql source_validation.sql mysql_gr_migrate.sh reprovision_helper.sh > package.sha256)
    chmod 600 "$directory"/*
)

cnf_chain_walk() (
    file=$1; cwd=$2; depth=$3
    [ "$depth" -le 32 ] || die 'Configuration include cycle or excessive depth'
    case $file in /*) :;; *) file="$cwd/$file";; esac
    file=$(readlink -f "$file") || die 'Cannot resolve configuration include'
    [ -f "$file" ] && [ -r "$file" ] || die "Unreadable configuration include: $file"
    case $file in *'
'*|*'\t'*) die 'Unsupported configuration filename';; esac
    sha256sum "$file" || exit 1
    awk '/^[[:space:]]*!include(dir)?[[:space:]]/ {line=$0; sub(/^[[:space:]]*/,"",line); key=line; sub(/[[:space:]].*$/, "",key); sub(/^[^[:space:]]+[[:space:]]+/, "",line); sub(/[[:space:]]+$/, "",line); print key "\t" line}' "$file" > "$TEMP/include.$$.${depth}"
    tab=$(printf '\t')
    while IFS="$tab" read -r kind path; do
        case $path in \"*\") path=${path#\"}; path=${path%\"};; \'*\') path=${path#\'}; path=${path%\'};; esac
        case $path in /*) :;; *) path="$cwd/$path";; esac
        case $kind in
            '!include') cnf_chain_walk "$path" "$cwd" "$((depth+1))" || exit 1;;
            '!includedir')
                [ -d "$path" ] && [ -r "$path" ] || die "Unreadable includedir: $path"
                printf 'DIRECTORY %s\n' "$path"
                for child in "$path"/*.cnf; do
                    [ -e "$child" ] || continue
                    cnf_chain_walk "$child" "$cwd" "$((depth+1))" || exit 1
                done;;
        esac
    done < "$TEMP/include.$$.${depth}"
)

cnf_chain_snapshot() (
    cnf_chain_walk "$1" "$3" 0 > "$2.unsorted" || exit 1
    LC_ALL=C sort -u "$2.unsorted" > "$2"
    rm -f "$2.unsorted"
)

tls_remote_apply_helper() (
    i=$1
    material=$(cat "$RUN/tls_change/$i.material_path")
    output=$(cat "$RUN/tls_change/$i.output")
    file="$RUN/tls_change/node_${i}_apply_tls.sh"
    [ -r "$material/ca.pem" ] && [ -r "$material/server-cert.pem" ] && [ -r "$material/server-key.pem" ] || die "Node $i remote TLS material missing"
    cnf=$(get "$i" cnf); case $cnf in /*) :;; *) die "Node $i remote TLS helper requires a proven absolute cnf path from configure";; esac
    {
        printf '#!/bin/sh\n# Generated MySQL GR remote TLS apply/rollback helper v%s.\n# Contains the prepared leaf private key, but NO DB password and NO CA private key.\n# Installs no packages and never disables/relaxes SELinux.\nset -eu\numask 077\n' "$VERSION"
        cat <<'TLS_HELPER_ACTION'
mode=${1:-apply}
case $mode in apply) ACTION=tls-apply;; rollback) ACTION=tls-rollback;; *) printf 'Usage: sh %s apply|rollback\n' "$0" >&2; exit 2;; esac
TLS_HELPER_ACTION
        printf "DO_RESTART='no'\nSNIPPET=''\n"
        printf 'VERSION=%s\n' "$(shell_quote "$VERSION")"
        printf 'EXPECTED_UUID=%s\n' "$(shell_quote "$(get "$i" uuid)")"
        printf 'EXPECTED_DATA=%s\n' "$(shell_quote "$(val "$i" datadir)")"
        printf 'EXPECTED_SOCKET=%s\n' "$(shell_quote "$(val "$i" socket)")"
        printf 'EXPECTED_PID_FILE=%s\n' "$(shell_quote "$(val "$i" pid_file)")"
        printf 'BASEDIR=%s\n' "$(shell_quote "$(val "$i" basedir)")"
        printf 'CNF=%s\n' "$(shell_quote "$cnf")"
        printf 'ADVERTISE=%s\n' "$(shell_quote "$(get "$i" advertise)")"
        printf 'SQL_PORT=%s\n' "$(shell_quote "$(get "$i" sql_port)")"
        xcom_value=$(get "$i" xcom); printf 'XCOM_PORT=%s\n' "$(shell_quote "${xcom_value##*:}")"
        printf 'GR_TLS_MODE=%s\n' "$(shell_quote "$(get meta tls)")"
        printf 'RECOVERY_CA=%s\n' "$(shell_quote "$(get "$i" recovery_ca)")"
        printf 'TLS_OUTPUT=%s\n' "$(shell_quote "$output")"
        printf 'TLS_CA_PEM=%s\n' "$(shell_quote "$(cat "$material/ca.pem")")"
        printf 'TLS_CERT_PEM=%s\n' "$(shell_quote "$(cat "$material/server-cert.pem")")"
        printf 'TLS_KEY_PEM=%s\n' "$(shell_quote "$(cat "$material/server-key.pem")")"
        printf 'DEFAULT_DB_USER=%s\n' "$(shell_quote "$(get "$i" user)")"
        cat <<'TLS_APPLY_AUTH'
printf 'Socket MySQL admin user [%s]: ' "$DEFAULT_DB_USER" >&2
IFS= read -r db_user || exit 1; db_user=${db_user:-$DEFAULT_DB_USER}
printf 'Socket MySQL admin password: ' >&2
saved_tty=''
if [ -t 0 ]; then saved_tty=$(stty -g); trap 'stty "$saved_tty"' 0; trap 'exit 1' 1 2 15; stty -echo; fi
IFS= read -r db_password || exit 1
[ -z "$saved_tty" ] || stty "$saved_tty"
trap - 0 1 2 15
printf '\n' >&2
manual_option_quote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
CLIENT_AUTH=$(printf 'user="%s"\npassword="%s"' "$(manual_option_quote "$db_user")" "$(manual_option_quote "$db_password")")
unset db_password
TLS_APPLY_AUTH
        remote_agent
    } > "$file"
    chmod 700 "$file"
    sh -n "$file" || die "Node $i generated remote TLS apply helper has invalid POSIX sh syntax"
    log "Node $i remote TLS helper: $file"
)

tls_restore() (
    failed=0
    for node in $(ids); do
        [ -f "$RUN/tls_change/$node.applied" ] || continue
        if [ "$(get "$node" location)" = remote ]; then
            if command -v ssh >/dev/null 2>&1; then
                remote_call "$node" tls-rollback > "$RUN/tls_change/$node.rollback.log" 2>&1 || failed=1
            else
                log "URGENT: Node $node remote TLS was applied but OpenSSH is unavailable for automatic rollback. Run: sh $RUN/tls_change/node_${node}_apply_tls.sh rollback"
                failed=1
            fi
            cat "$RUN/tls_change/$node.recovery_ca.before" > "$ROOT/$node/recovery_ca" || failed=1
            continue
        fi
        cnf=$(get "$node" cnf)
        if [ -f "$RUN/tls_change/$node.cnf.before" ]; then cat "$RUN/tls_change/$node.cnf.before" > "$cnf" || failed=1; fi
        sql "$node" "$(cat "$RUN/tls_change/$node.runtime_restore.sql")" > "$RUN/tls_change/$node.rollback.log" 2>&1 || failed=1
        cat "$RUN/tls_change/$node.recovery_ca.before" > "$ROOT/$node/recovery_ca" || failed=1
    done
    [ "$failed" = 0 ] || return 1
)

tls_plan_manifest() (
    manifest="$RUN/tls_change/manifest.sha256"
    : > "$manifest"
    for node in $(ids); do
        material=$(cat "$RUN/tls_change/$node.material_path")
        if [ "$(get "$node" location)" = remote ]; then
            sha256sum "$material/ca.pem" "$material/server-cert.pem" "$material/server-key.pem" "$RUN/tls_change/$node.output" "$RUN/tls_change/$node.material_path" "$RUN/tls_change/$node.recovery_ca.before" "$RUN/tls_change/node_${node}_apply_tls.sh" >> "$manifest" || exit 1
        else
            sha256sum "$material/ca.pem" "$material/server-cert.pem" "$material/server-key.pem" "$RUN/tls_change/$node.output" "$RUN/tls_change/$node.material_path" "$RUN/tls_change/$node.cnf.candidate" "$RUN/tls_change/$node.cnf.before" "$RUN/tls_change/$node.runtime_restore.sql" "$RUN/tls_change/$node.recovery_ca.before" "$RUN/tls_change/$node.include.before" "$RUN/tls_change/node_${node}_apply_tls.sh" >> "$manifest" || exit 1
        fi
    done
)

tls_selinux_prepare_local() (
    node=$1; output=$2; datadir=$3
    mode=Disabled
    if command -v getenforce >/dev/null 2>&1; then mode=$(getenforce 2>/dev/null || printf 'Unknown'); fi
    printf '%s\n' "$mode" > "$RUN/tls_change/$node.selinux_mode"
    case $mode in Enforcing|Permissive)
        command -v restorecon >/dev/null 2>&1 || die "Node $node SELinux is $mode but restorecon is unavailable. No package will be installed automatically; configure the existing OS SELinux tooling/policy manually."
        old_cert=$(val "$node" ssl_cert)
        case $old_cert in /*) :;; *) old_cert="$datadir/$old_cert";; esac
        [ -r "$old_cert" ] || die "Node $node active TLS certificate is not readable for SELinux context comparison: $old_cert"
        old_ctx=$(stat -c %C "$old_cert" 2>/dev/null || :)
        old_type=$(printf '%s' "$old_ctx" | awk -F: 'NF>=3 {print $3}')
        [ -n "$old_type" ] && [ "$old_type" != '?' ] || die "Node $node cannot determine the active TLS SELinux type; no policy change was attempted"
        restorecon -R "$output" > "$RUN/tls_change/$node.restorecon.log" 2>&1 || die "Node $node restorecon failed; no package/policy is installed automatically. Evidence: $RUN/tls_change/$node.restorecon.log"
        new_ctx=$(stat -c %C "$output/server-cert.pem" 2>/dev/null || :)
        new_type=$(printf '%s' "$new_ctx" | awk -F: 'NF>=3 {print $3}')
        {
            printf 'active_cert\t%s\nactive_context\t%s\n' "$old_cert" "$old_ctx"
            printf 'new_cert\t%s\nnew_context\t%s\n' "$output/server-cert.pem" "$new_ctx"
        } > "$RUN/tls_change/$node.selinux_context"
        [ "$new_type" = "$old_type" ] || die "Node $node new TLS SELinux type ($new_type) differs from the proven active certificate type ($old_type). No semanage/chcon/package installation is performed automatically; place/label the certificate according to the host's existing persistent SELinux policy. Evidence: $RUN/tls_change/$node.selinux_context"
        ;;
    esac
)

selinux_port_contains_local() (
    wanted=$1
    command -v semanage >/dev/null 2>&1 || exit 2
    ports="$TEMP/mysqld_ports.$$"
    raw="$TEMP/semanage_ports.$$"
    semanage port -l > "$raw" 2>/dev/null || { rm -f "$raw" "$ports"; exit 2; }
    awk '$1=="mysqld_port_t" && $2=="tcp" {for(i=3;i<=NF;i++) print $i}' "$raw" | tr ',' '\n' | tr -d ' ' > "$ports" || { rm -f "$raw" "$ports"; exit 2; }
    rm -f "$raw"
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        case $spec in
            *-*) lo=${spec%-*}; hi=${spec#*-}; case $lo:$hi in *[!0-9:]*|:*) continue;; esac; [ "$wanted" -ge "$lo" ] && [ "$wanted" -le "$hi" ] && { rm -f "$ports"; exit 0; };;
            *) [ "$wanted" = "$spec" ] && { rm -f "$ports"; exit 0; };;
        esac
    done < "$ports"
    rm -f "$ports"
    exit 1
)

selinux_gr_port_preflight_local() (
    node=$1
    mode=Disabled
    if command -v getenforce >/dev/null 2>&1; then mode=$(getenforce 2>/dev/null || printf 'Unknown'); fi
    case $mode in Enforcing|Permissive) :;; *) exit 0;; esac
    pid=$(local_pid "$node") || die "Node $node cannot prove local mysqld identity for SELinux port preflight"
    domain=$(tr -d '\000' < "/proc/$pid/attr/current" 2>/dev/null || :)
    printf '%s\n' "$domain" > "$RUN/tls/$node.selinux_process_domain"
    case $domain in *:mysqld_t:*) :;; *) log "Node $node SELinux port preflight: mysqld is not in mysqld_t ($domain); no policy is changed."; exit 0;; esac
    xcom=$(get "$node" xcom); xport=${xcom##*:}
    case $xport in ''|*[!0-9]*) die "Node $node invalid XCom port for SELinux preflight";; esac
    if selinux_port_contains_local "$xport"; then
        printf 'XCOM_PORT\t%s\tmysqld_port_t\n' "$xport" > "$RUN/tls/$node.selinux_xcom_port"
        exit 0
    else
        rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
        die "Node $node SELinux is $mode and mysqld runs in mysqld_t, but semanage is unavailable for read-only XCom port verification. No package is installed automatically; verify the existing host SELinux port policy manually before GR."
    fi
    die "Node $node XCom port $xport is not registered as mysqld_port_t. No semanage/policy change is performed automatically; register/review the port on that host before GR."
)

tls_capture_avc_local() (
    node=$1
    out="$RUN/tls_change/$node.avc.log"
    if command -v ausearch >/dev/null 2>&1; then
        ausearch -m AVC,USER_AVC -ts recent > "$out" 2>&1 || :
    elif [ -r /var/log/audit/audit.log ]; then
        grep -i 'avc:.*denied' /var/log/audit/audit.log | tail -100 > "$out" 2>/dev/null || :
    else
        printf '%s\n' 'AVC evidence unavailable: ausearch/audit.log not present. No package was installed.' > "$out"
    fi
)

tls_prepare_local_files() (
    node=$1; material=$2; output=$3; datadir=$4
    case $output in "$datadir"/*) :;; *) die "Node $node TLS output must be below the proven active datadir";; esac
    [ ! -e "$output" ] || die "Node $node TLS output already exists; preserve/review it before retrying: $output"
    [ -r "$material/ca.pem" ] && [ -r "$material/server-cert.pem" ] && [ -r "$material/server-key.pem" ] || die "Node $node prepared TLS material is incomplete"
    mkdir "$output" || die "Node $node cannot create TLS output directory"
    chmod 700 "$output"
    cp "$material/ca.pem" "$output/ca.pem"
    cp "$material/server-cert.pem" "$output/server-cert.pem"
    cp "$material/server-key.pem" "$output/server-key.pem"
    chmod 644 "$output/ca.pem" "$output/server-cert.pem"
    chmod 600 "$output/server-key.pem"
    chown -R "$(stat -c %u "$datadir"):$(stat -c %g "$datadir")" "$output"
    tls_selinux_prepare_local "$node" "$output" "$datadir"
)

tls_apply_plan() (
    connected; no_group
    plan=${MYSQL_GR_TLS_PLAN:-$(get meta tls_plan)}
    [ -d "$plan" ] && [ "$(basename "$plan")" = tls_change ] || die 'Invalid prepared TLS plan'
    RUN=$(dirname "$plan")
    sha256sum -c "$plan/manifest.sha256" > "$plan/apply_checksum.log" 2>&1 || die 'Prepared TLS plan/certificates changed; no settings applied'

    # Prove every remote OS path before changing any node. If SSH is absent or
    # unusable, stop before mutation and use the generated copyable helper.
    manual_required=no
    for node in $(ids); do
        [ "$(get "$node" location)" = remote ] || continue
        if ! command -v ssh >/dev/null 2>&1; then
            manual_required=yes
            log "Node $node: OpenSSH unavailable. Use: sh $plan/node_${node}_apply_tls.sh apply"
            continue
        fi
        ssh_options "$node"
        if ! remote_call "$node" inspect > "$plan/$node.remote_apply_preflight" 2>&1; then
            manual_required=yes
            log "Node $node: SSH/host identity preflight failed. Use copyable helper: $plan/node_${node}_apply_tls.sh"
        fi
    done
    if [ "$manual_required" = yes ]; then
        all_applied=yes
        for node in $(ids); do
            output=$(cat "$RUN/tls_change/$node.output")
            actual=$(sql "$node" "SELECT CONCAT(@@ssl_ca,'|',@@ssl_cert,'|',@@ssl_key);")
            [ "$actual" = "$output/ca.pem|$output/server-cert.pem|$output/server-key.pem" ] || all_applied=no
        done
        if [ "$all_applied" = yes ]; then
            for node in $(ids); do output=$(cat "$RUN/tls_change/$node.output"); put "$node" recovery_ca "$output/ca.pem"; done
            tls_preflight
            log 'TLS MANUAL APPLY VERIFIED: every node runtime path and current certificate matches the prepared plan; controller metadata updated.'
            return 0
        fi
        log 'At least one remote host cannot be managed over SSH. To avoid an unrollable mixed state, this invocation will change NO node.'
        for node in $(ids); do
            if [ "$(get "$node" location)" = remote ]; then
                log "Node $node host: copy $plan/node_${node}_apply_tls.sh there and run: sh node_${node}_apply_tls.sh apply > node_${node}_tls_remote_evidence.tsv"
                log "Then copy that stdout evidence to controller path: $ROOT/$node/tls_remote_evidence.tsv"
            else
                log "Node $node local host: sh $plan/node_${node}_apply_tls.sh apply"
            fi
        done
        die 'Manual all-host TLS application required because at least one remote OS path is unavailable. No node was changed by this apply invocation; no package was installed.'
    fi

    confirm 'APPLY VERIFIED TLS CERTIFICATES'
    tls_ok=no
    trap 'rc=$?; trap - 0 1 2 15; if [ "$tls_ok" != yes ]; then tls_restore || log "URGENT: TLS rollback incomplete; inspect $RUN/tls_change"; fi; exit "$rc"' 0
    trap 'exit 130' 2; trap 'exit 143' 1 15
    for node in $(ids); do
        output=$(cat "$RUN/tls_change/$node.output")
        if [ "$(get "$node" location)" = remote ]; then
            if ! remote_call "$node" tls-apply > "$RUN/tls_change/$node.remote_apply.log" 2>&1; then
                remote_call "$node" tls-rollback >> "$RUN/tls_change/$node.remote_apply.log" 2>&1 || :
                die "Node $node remote TLS apply failed; host-side rollback was attempted. Evidence: $RUN/tls_change/$node.remote_apply.log"
            fi
            : > "$RUN/tls_change/$node.applied"
            put "$node" recovery_ca "$output/ca.pem"
            continue
        fi
        pid=$(local_pid "$node") || die 'TLS target identity changed before apply'
        cnf=$(get "$node" cnf)
        cnf_chain_snapshot "$cnf" "$RUN/tls_change/$node.include.current" "$(readlink -f "/proc/$pid/cwd")"
        cmp -s "$RUN/tls_change/$node.include.before" "$RUN/tls_change/$node.include.current" || die 'TLS configuration include chain changed concurrently'
        datadir=$(val "$node" datadir); datadir=${datadir%/}
        material=$(cat "$RUN/tls_change/$node.material_path")
        tls_prepare_local_files "$node" "$material" "$output" "$datadir"
        : > "$RUN/tls_change/$node.applied"
        cat "$RUN/tls_change/$node.cnf.candidate" > "$cnf"
        if ! sql "$node" "SET GLOBAL ssl_ca='$(q "$output/ca.pem")'; SET GLOBAL ssl_cert='$(q "$output/server-cert.pem")'; SET GLOBAL ssl_key='$(q "$output/server-key.pem")'; ALTER INSTANCE RELOAD TLS;"; then
            tls_capture_avc_local "$node"
            die "Node $node TLS reload failed. Automatic rollback will restore the previous cnf/runtime TLS settings. SELinux evidence (when available): $RUN/tls_change/$node.avc.log"
        fi
        put "$node" recovery_ca "$output/ca.pem"
    done
    tls_preflight
    tls_ok=yes
    log "TLS APPLIED: local/remote cross-member CA/SAN verified; existing connections retained. Evidence: $RUN/tls_change"
)

tls() (
    PHASE=tls
    tls_action=${MYSQL_GR_TLS_ACTION:-plan}
    case $tls_action in plan) :;; apply) tls_apply_plan; exit $?;; *) die 'MYSQL_GR_TLS_ACTION must be plan or apply';; esac
    connected; no_group
    command -v openssl >/dev/null 2>&1 || die 'Existing openssl required; no packages will be installed'
    mkdir -p "$RUN/tls_change" "$RUN/tls"
    ca_default=$(val 1 ssl_ca)
    case $ca_default in /*) :;; *) ca_default="$(val 1 datadir)/$ca_default";; esac
    [ -r "$ca_default" ] || ca_default=''
    authority=$(required 'Existing signing CA certificate path on this controller' "$ca_default")
    signing_key=$(required 'Existing signing CA private key path on this controller' "$(dirname "$authority")/ca-key.pem")
    days=$(required 'Certificate validity in days' 365)
    uint "$days" && [ "$days" -gt 0 ] && [ "$days" -le 3650 ] || die 'Invalid certificate lifetime'
    authority_normalized="$RUN/tls_change/signing_ca.normalized.pem"
    tr -d '\000' < "$authority" > "$authority_normalized" || die 'Cannot normalize signing CA PEM'
    openssl x509 -in "$authority_normalized" -noout -checkend "$((days*86400))" > "$RUN/tls_change/ca_expiry.log" 2>&1 || die 'CA expires before the requested certificate lifetime'
    openssl x509 -in "$authority_normalized" -pubkey -noout > "$RUN/tls_change/ca.pub" || die 'Cannot read signing CA'
    openssl pkey -in "$signing_key" -pubout > "$RUN/tls_change/ca_key.pub" 2>/dev/null || die 'Cannot access signing CA key'
    cmp -s "$RUN/tls_change/ca.pub" "$RUN/tls_change/ca_key.pub" || die 'CA certificate/key mismatch'
    stamp=$(date +%Y%m%d_%H%M%S)_$$

    for node in $(ids); do
        [ "$(sql "$node" "SELECT COUNT(*) FROM performance_schema.persisted_variables WHERE VARIABLE_NAME IN ('ssl_ca','ssl_cert','ssl_key');")" = 0 ] || die "Node $node existing persisted TLS overrides require explicit migration before cnf deployment"
        datadir=$(val "$node" datadir); datadir=${datadir%/}
        output="$datadir/gr_tls_${node}_$stamp"
        printf '%s\n' "$output" > "$RUN/tls_change/$node.output"
        host=$(get "$node" advertise); safe_host "$host"
        case $host in *[!0-9.]*) san="DNS:$host";; *) san="IP:$host";; esac
        printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n' "$san" > "$RUN/tls_change/$node.extensions"

        material="$RUN/tls_change/$node.material"
        [ ! -e "$material" ] || die "Node $node TLS material path collision"
        mkdir "$material"; chmod 700 "$material"
        if [ "$(get "$node" location)" = remote ]; then
            tls_remote_export "$node"
            old_ca="$RUN/tls/$node.ca.pem"
        else
            pid=$(local_pid "$node") || die 'Cannot prove TLS target process identity'
            cnf=$(get "$node" cnf)
            [ -f "$cnf" ] && [ ! -L "$cnf" ] || die 'TLS deployment requires a proven regular main cnf'
            old_ca=$(val "$node" ssl_ca)
            case $old_ca in /*) :;; *) old_ca="$datadir/$old_ca";; esac
        fi
        printf '%s\n' "$material" > "$RUN/tls_change/$node.material_path"

        openssl req -new -newkey rsa:3072 -nodes -subj "/CN=$host" -keyout "$material/server-key.pem" -out "$RUN/tls_change/$node.csr" > "$RUN/tls_change/$node.issue.log" 2>&1 || die 'TLS key/CSR generation failed'
        serial=$(openssl rand -hex 16)
        openssl x509 -req -in "$RUN/tls_change/$node.csr" -CA "$authority_normalized" -CAkey "$signing_key" -set_serial "0x$serial" -days "$days" -sha256 -extfile "$RUN/tls_change/$node.extensions" -out "$material/server-cert.pem" >> "$RUN/tls_change/$node.issue.log" 2>&1 || die 'TLS certificate signing failed'
        cat "$authority_normalized" > "$material/ca.pem"
        # Preserve pre-existing client-certificate trust on each host. MySQL
        # generated PEM files can contain a trailing NUL byte; normalize only the
        # copied evidence/material and never modify the active source file.
        if [ -r "$old_ca" ]; then
            normalized_old_ca="$RUN/tls/$node.old_ca.normalized.pem"
            tr -d '\000' < "$old_ca" > "$normalized_old_ca"
            openssl x509 -in "$normalized_old_ca" -noout >/dev/null 2>&1 || die "Node $node existing TLS CA is not a valid PEM certificate/bundle"
            cmp -s "$authority_normalized" "$normalized_old_ca" || cat "$normalized_old_ca" >> "$material/ca.pem"
        fi
        chmod 600 "$material/server-key.pem"; chmod 644 "$material/ca.pem" "$material/server-cert.pem"
        cp "$ROOT/$node/recovery_ca" "$RUN/tls_change/$node.recovery_ca.before"

        tls_remote_apply_helper "$node"
        if [ "$(get "$node" location)" = remote ]; then
            continue
        fi
        cnf_chain_snapshot "$cnf" "$RUN/tls_change/$node.include.before" "$(readlink -f "/proc/$pid/cwd")"
        cp -p "$cnf" "$RUN/tls_change/$node.cnf.before"
        sql "$node" "SELECT CONCAT('SET GLOBAL ssl_ca=',QUOTE(@@ssl_ca),'; SET GLOBAL ssl_cert=',QUOTE(@@ssl_cert),'; SET GLOBAL ssl_key=',QUOTE(@@ssl_key),'; ALTER INSTANCE RELOAD TLS;');" > "$RUN/tls_change/$node.runtime_restore.sql"
        sed '/^# BEGIN mysql_gr_tls$/,/^# END mysql_gr_tls$/d' "$cnf" > "$RUN/tls_change/$node.cnf.candidate"
        printf '\n# BEGIN mysql_gr_tls\n[mysqld]\nssl_ca=%s/ca.pem\nssl_cert=%s/server-cert.pem\nssl_key=%s/server-key.pem\n# END mysql_gr_tls\n' "$output" "$output" "$output" >> "$RUN/tls_change/$node.cnf.candidate"
        exe=$(readlink -f "/proc/$pid/exe")
        "$exe" --defaults-file="$RUN/tls_change/$node.cnf.candidate" --validate-config > "$RUN/tls_change/$node.config_validation.log" 2>&1 || die 'TLS candidate cnf validation failed'
    done

    for donor in $(ids); do
        donor_material=$(cat "$RUN/tls_change/$donor.material_path")
        host=$(get "$donor" advertise)
        for receiver in $(ids); do
            trust=$(cat "$RUN/tls_change/$receiver.material_path")
            case $host in *[!0-9.]*) set -- -verify_hostname "$host";; *) set -- -verify_ip "$host";; esac
            openssl verify -CAfile "$trust/ca.pem" -purpose sslserver "$@" "$donor_material/server-cert.pem" > "$RUN/tls_change/$receiver-to-$donor.verify" 2>&1 || die 'Proposed cross-member CA/SAN validation failed'
            openssl verify -CAfile "$trust/ca.pem" -purpose sslclient "$donor_material/server-cert.pem" >> "$RUN/tls_change/$receiver-to-$donor.verify" 2>&1 || die 'Proposed XCom client certificate validation failed'
        done
    done
    tls_plan_manifest
    printf '%s\n' "$RUN/tls_change" > "$ROOT/meta/tls_plan"
    log "TLS PLAN VERIFIED: $RUN/tls_change. Runtime/cnf unchanged. Remote nodes have copyable host helpers; no package or SELinux policy was installed."
)

tls_remote_inspect_helper() (
    i=$1; kind=${2:-inspect}
    case $kind in inspect) action=tls-inspect; evidence_name=tls_remote_evidence.tsv;; export) action=tls-export; evidence_name=tls_remote_export.tsv;; *) die 'Invalid remote TLS helper kind';; esac
    file="$RUN/node_${i}_tls_${kind}.sh"
    {
        printf '#!/bin/sh\n# Generated MySQL GR TLS host-side %s helper v%s.\n# No DB password, CA private key, or package installer is embedded.\nset -eu\numask 077\n' "$kind" "$VERSION"
        printf 'ACTION=%s\n' "$(shell_quote "$action")"
        printf "DO_RESTART='no'\nSNIPPET=''\nCNF=''\n"
        printf 'VERSION=%s\n' "$(shell_quote "$VERSION")"
        printf 'EXPECTED_UUID=%s\n' "$(shell_quote "$(get "$i" uuid)")"
        printf 'EXPECTED_DATA=%s\n' "$(shell_quote "$(val "$i" datadir)")"
        printf 'EXPECTED_SOCKET=%s\n' "$(shell_quote "$(val "$i" socket)")"
        printf 'EXPECTED_PID_FILE=%s\n' "$(shell_quote "$(val "$i" pid_file)")"
        printf 'BASEDIR=%s\n' "$(shell_quote "$(val "$i" basedir)")"
        printf 'ADVERTISE=%s\n' "$(shell_quote "$(get "$i" advertise)")"
        printf 'SQL_PORT=%s\n' "$(shell_quote "$(get "$i" sql_port)")"
        xcom_value=$(get "$i" xcom); printf 'XCOM_PORT=%s\n' "$(shell_quote "${xcom_value##*:}")"
        printf 'GR_TLS_MODE=%s\n' "$(shell_quote "$(get meta tls)")"
        printf 'RECOVERY_CA=%s\n' "$(shell_quote "$(get "$i" recovery_ca)")"
        printf 'DEFAULT_DB_USER=%s\n' "$(shell_quote "$(get "$i" user)")"
        cat <<'TLS_MANUAL_AUTH'
printf 'Socket MySQL admin user [%s]: ' "$DEFAULT_DB_USER" >&2
IFS= read -r db_user || exit 1; db_user=${db_user:-$DEFAULT_DB_USER}
printf 'Socket MySQL admin password: ' >&2
saved_tty=''
if [ -t 0 ]; then
    saved_tty=$(stty -g); trap 'stty "$saved_tty"' 0; trap 'exit 1' 1 2 15; stty -echo
fi
IFS= read -r db_password || exit 1
[ -z "$saved_tty" ] || stty "$saved_tty"
trap - 0 1 2 15
printf '\n' >&2
manual_option_quote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
CLIENT_AUTH=$(printf 'user="%s"\npassword="%s"' "$(manual_option_quote "$db_user")" "$(manual_option_quote "$db_password")")
unset db_password
TLS_MANUAL_AUTH
        remote_agent
    } > "$file"
    chmod 700 "$file"
    sh -n "$file" || die 'Generated remote TLS host helper has invalid POSIX sh syntax'
    log "Node $i remote TLS $kind helper generated: $file"
    log "Run it on that MySQL host and save stdout, then copy the evidence to: $ROOT/$i/$evidence_name"
    log 'The helper installs nothing and changes no MySQL/OS setting; it only reads identity/TLS files and host security state.'
)

tls_remote_export() (
    i=$1; evidence="$RUN/tls/$i.remote_export.tsv"
    if command -v ssh >/dev/null 2>&1; then
        ssh_options "$i"
        if remote_call "$i" tls-export > "$evidence" 2> "$RUN/tls/$i.remote_export.err"; then :
        elif [ -s "$ROOT/$i/tls_remote_export.tsv" ]; then cp "$ROOT/$i/tls_remote_export.tsv" "$evidence"
        else tls_remote_inspect_helper "$i" export; die "Node $i SSH TLS export failed and no manual export evidence is present"; fi
    elif [ -s "$ROOT/$i/tls_remote_export.tsv" ]; then
        cp "$ROOT/$i/tls_remote_export.tsv" "$evidence"
    else
        tls_remote_inspect_helper "$i" export
        die "Node $i remote TLS CA export requires the generated host helper because OpenSSH is unavailable. No package will be installed automatically."
    fi
    [ "$(awk -F '\t' '$1=="UUID" {print $2;exit}' "$evidence")" = "$(get "$i" uuid)" ] || die "Node $i remote TLS export UUID mismatch"
    [ "$(awk -F '\t' '$1=="TLS_INSPECT" {print $2;exit}' "$evidence")" = PASSED ] || die "Node $i remote TLS export evidence is incomplete"
    awk -F '\t' '$1=="TLS_CA_PEM" {sub(/^[^\t]*\t/,""); print}' "$evidence" > "$RUN/tls/$i.ca.pem"
    awk -F '\t' '$1=="TLS_RECOVERY_CA_PEM" {sub(/^[^\t]*\t/,""); print}' "$evidence" > "$RUN/tls/$i.recovery_ca.pem"
    openssl x509 -in "$RUN/tls/$i.ca.pem" -noout >/dev/null 2>&1 || die "Node $i exported TLS CA is invalid"
    openssl x509 -in "$RUN/tls/$i.recovery_ca.pem" -noout >/dev/null 2>&1 || die "Node $i exported recovery CA is invalid"
)

tls_remote_collect() (
    i=$1; evidence="$RUN/tls/$i.remote.tsv"
    if command -v ssh >/dev/null 2>&1; then
        ssh_options "$i"
        if remote_call "$i" tls-inspect > "$evidence" 2> "$RUN/tls/$i.remote.err"; then
            :
        elif [ -s "$ROOT/$i/tls_remote_evidence.tsv" ]; then
            cp "$ROOT/$i/tls_remote_evidence.tsv" "$evidence"
        else
            tls_remote_inspect_helper "$i"
            die "Node $i SSH TLS inspection failed and no manual host evidence is present. Evidence: $RUN/tls/$i.remote.err"
        fi
    elif [ -s "$ROOT/$i/tls_remote_evidence.tsv" ]; then
        cp "$ROOT/$i/tls_remote_evidence.tsv" "$evidence"
    else
        tls_remote_inspect_helper "$i"
        die "Node $i is remote and OpenSSH is unavailable. No package will be installed automatically; run the generated host helper and copy its output to $ROOT/$i/tls_remote_evidence.tsv, then rerun precheck."
    fi
    [ "$(awk -F '\t' '$1=="UUID" {print $2;exit}' "$evidence")" = "$(get "$i" uuid)" ] || die "Node $i remote TLS evidence UUID mismatch"
    [ "$(awk -F '\t' '$1=="TLS_INSPECT" {print $2;exit}' "$evidence")" = PASSED ] || die "Node $i remote TLS evidence is incomplete/failed"
    awk -F '\t' '$1=="TLS_CA_PEM" {sub(/^[^\t]*\t/,""); print}' "$evidence" > "$RUN/tls/$i.ca.pem"
    awk -F '\t' '$1=="TLS_RECOVERY_CA_PEM" {sub(/^[^\t]*\t/,""); print}' "$evidence" > "$RUN/tls/$i.recovery_ca.pem"
    awk -F '\t' '$1=="TLS_CERT_PEM" {sub(/^[^\t]*\t/,""); print}' "$evidence" > "$RUN/tls/$i.cert.pem"
    openssl x509 -in "$RUN/tls/$i.ca.pem" -noout >/dev/null 2>&1 || die "Node $i remote TLS CA evidence is invalid"
    openssl x509 -in "$RUN/tls/$i.recovery_ca.pem" -noout >/dev/null 2>&1 || die "Node $i remote recovery CA evidence is invalid"
    openssl x509 -in "$RUN/tls/$i.cert.pem" -noout >/dev/null 2>&1 || die "Node $i remote TLS certificate evidence is invalid"
    if [ -f "$RUN/tls_change/$i.material_path" ]; then
        planned_material=$(cat "$RUN/tls_change/$i.material_path")
        cmp -s "$RUN/tls/$i.cert.pem" "$planned_material/server-cert.pem" || die "Node $i remote TLS evidence does not match the prepared plan; rerun the host helper after applying the current plan"
    fi
)

tls_preflight() (
    command -v openssl >/dev/null 2>&1 || die 'Existing openssl is required for TLS CA/SAN validation; no packages are installed'
    mkdir -p "$RUN/tls"
    for donor in $(ids); do
        if [ "$(get "$donor" location)" = remote ]; then
            tls_remote_collect "$donor"
            continue
        fi
        selinux_gr_port_preflight_local "$donor" || exit $?
        directory=$(val "$donor" datadir); directory=${directory%/}
        cert=$(val "$donor" ssl_cert); key=$(val "$donor" ssl_key); ca=$(val "$donor" ssl_ca)
        recovery_ca=$(get "$donor" recovery_ca)
        case $cert in /*) :;; *) cert="$directory/$cert";; esac
        case $key in /*) :;; *) key="$directory/$key";; esac
        case $ca in /*) :;; '') die "Node $donor has no runtime ssl_ca";; *) ca="$directory/$ca";; esac
        case $recovery_ca in /*) :;; '') recovery_ca=$ca;; *) recovery_ca="$directory/$recovery_ca";; esac
        [ -r "$cert" ] && [ -r "$key" ] && [ -r "$ca" ] && [ -r "$recovery_ca" ] || die "Node $donor local TLS file is not readable"
        openssl x509 -in "$cert" -noout -checkend 0 > "$RUN/tls/$donor.expiry" 2>&1 || die "Node $donor TLS certificate invalid/expired"
        openssl x509 -in "$cert" -pubkey -noout > "$RUN/tls/$donor.cert.pub" 2>/dev/null || die 'Cannot read certificate public key'
        openssl pkey -in "$key" -pubout > "$RUN/tls/$donor.key.pub" 2>/dev/null || die 'Cannot read TLS key for key-pair validation'
        cmp -s "$RUN/tls/$donor.cert.pub" "$RUN/tls/$donor.key.pub" || die "Node $donor TLS certificate/key mismatch"
        cp "$cert" "$RUN/tls/$donor.cert.pem"
        cp "$ca" "$RUN/tls/$donor.ca.pem"
        cp "$recovery_ca" "$RUN/tls/$donor.recovery_ca.pem"
        if command -v getenforce >/dev/null 2>&1; then
            mode=$(getenforce 2>/dev/null || printf 'Unknown')
            printf 'SELINUX_MODE\t%s\n' "$mode" > "$RUN/tls/$donor.selinux"
            printf 'TLS_CERT\t%s\t%s\n' "$cert" "$(stat -c %C "$cert" 2>/dev/null || printf '?')" >> "$RUN/tls/$donor.selinux"
        fi
    done
    for donor in $(ids); do
        cert="$RUN/tls/$donor.cert.pem"; host=$(get "$donor" advertise)
        openssl x509 -in "$cert" -noout -checkend 0 > "$RUN/tls/$donor.expiry.controller" 2>&1 || die "Node $donor TLS certificate invalid/expired"
        if [ "$(get meta tls)" = VERIFY_IDENTITY ]; then
            openssl x509 -in "$cert" -noout -ext subjectAltName > "$RUN/tls/$donor.san" 2>/dev/null || die "Cannot inspect Node $donor TLS SAN"
            grep -E 'DNS:|IP Address:' "$RUN/tls/$donor.san" >/dev/null || die "Node $donor lacks a SAN for identity verification"
        fi
        for receiver in $(ids); do
            for ca in "$RUN/tls/$receiver.recovery_ca.pem" "$RUN/tls/$receiver.ca.pem"; do
                set -- -CAfile "$ca" -purpose sslserver
                if [ "$(get meta tls)" = VERIFY_IDENTITY ]; then
                    case $host in *[!0-9.]*) set -- "$@" -verify_hostname "$host";; *) set -- "$@" -verify_ip "$host";; esac
                fi
                openssl verify "$@" "$cert" >> "$RUN/tls/$receiver-to-$donor.verify" 2>&1 || die "Node $receiver CA cannot verify donor $donor TLS certificate/identity"
            done
        done
    done
    log "TLS PREFLIGHT PASSED: local/remote host-side certificate, key, CA, SAN and cross-member trust verified. Evidence: $RUN/tls"
)

cutover_snapshot() (
    mkdir -p "$RUN/cutover_rollback"
    for node in $(ids); do
        # Existing recovery credentials cannot be reconstructed from P_S.
        # Never overwrite them and then pretend rollback can restore them.
        [ "$(sql "$node" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME='group_replication_recovery';")" = 0 ] || die "Node $node has existing recovery channel metadata; preserve it and use a reviewed recovery procedure"
        sql "$node" "SELECT CONCAT('START REPLICA IO_THREAD FOR CHANNEL ',QUOTE(CHANNEL_NAME),';') FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON'; SELECT CONCAT('START REPLICA SQL_THREAD FOR CHANNEL ',QUOTE(CHANNEL_NAME),';') FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON';" > "$RUN/cutover_rollback/$node.async.sql"
    done
)

persist_snapshot() (
    node=$1; variable=$2
    case $variable in ''|*[!a-zA-Z0-9_]*) die 'Invalid persisted variable identifier';; esac
    dir="$RUN/cutover_rollback/$node.persist"
    mkdir -p "$dir"
    [ ! -f "$dir/$variable.sql" ] || exit 0
    null_runtime=$(sql "$node" "SELECT @@GLOBAL.$variable IS NULL;")
    if [ "$null_runtime" = 1 ]; then
        case $variable in
            group_replication_*)
                [ -f "$RUN/cutover_rollback/$node.new_gr_plugin" ] || die "Existing GR plugin has unset $variable that cannot be restored dynamically; preserve it and review plugin reinitialization before cutover";;
            *) die "NULL runtime value of $variable has no validated rollback path";;
        esac
    fi
    # Capture runtime and persisted values separately: RESET PERSIST does not
    # restore the current GLOBAL value and SET PERSIST alone conflates the two.
    sql "$node" "SELECT IF(@@GLOBAL.$variable IS NULL,'SELECT 1;',CONCAT('SET GLOBAL $variable=',QUOTE(@@GLOBAL.$variable),';')); SELECT IF(COUNT(*)=0,'RESET PERSIST IF EXISTS $variable;',CONCAT('SET PERSIST_ONLY $variable=',QUOTE(MAX(VARIABLE_VALUE)),';')) FROM performance_schema.persisted_variables WHERE VARIABLE_NAME='$variable';" > "$dir/$variable.sql.tmp"
    [ "$(wc -l < "$dir/$variable.sql.tmp")" = 2 ] || die 'Incomplete persisted-variable rollback snapshot'
    mv "$dir/$variable.sql.tmp" "$dir/$variable.sql"
    printf '%s\n' "$variable" >> "$dir/order"
)

rollback_cutover() (
    failed=0
    for node in $(ids); do
        dir="$RUN/cutover_rollback"
        sql "$node" 'SET GLOBAL super_read_only=ON;' || failed=1
        if [ -f "$dir/$node.new_recovery_channel" ] && [ "$(sql "$node" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME='group_replication_recovery';")" = 1 ]; then
            sql "$node" "RESET REPLICA ALL FOR CHANNEL 'group_replication_recovery';" || failed=1
        fi
        if [ -s "$dir/$node.accounts.sql" ]; then
            local_write "$node" "$(cat "$dir/$node.accounts.sql")" secret || failed=1
        fi
        if [ -s "$dir/$node.persist/order" ]; then
            awk '{a[NR]=$0} END {for(i=NR;i>0;i--)print a[i]}' "$dir/$node.persist/order" > "$dir/$node.persist/reverse"
            while IFS= read -r variable; do
                while IFS= read -r restore_statement; do
                    [ -n "$restore_statement" ] || continue
                    sql "$node" "$restore_statement" || failed=1
                done < "$dir/$node.persist/$variable.sql"
            done < "$dir/$node.persist/reverse"
        fi
        if [ -f "$dir/$node.new_gr_plugin" ] && [ "$(sql "$node" "SELECT COUNT(*) FROM information_schema.plugins WHERE PLUGIN_NAME='group_replication';")" = 1 ]; then
            local_write "$node" 'UNINSTALL PLUGIN group_replication;' || failed=1
        fi
        if [ -s "$dir/$node.async.sql" ]; then
            sql "$node" "$(cat "$dir/$node.async.sql")" || failed=1
        fi
        sql "$node" 'SET GLOBAL super_read_only=ON;' || failed=1
    done
    [ "$failed" = 0 ] || return 1
    printf '%s\n' 'Restored pre-bootstrap settings, new recovery objects and previous async thread state; write fences retained.' > "$RUN/cutover_rollback/result.txt"
)

definer_guard() (
    node=$1
    orphan=$(sql "$node" "SELECT COUNT(*) FROM (SELECT DEFINER FROM information_schema.VIEWS WHERE TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') UNION SELECT DEFINER FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') UNION SELECT DEFINER FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') UNION SELECT DEFINER FROM information_schema.EVENTS WHERE EVENT_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema')) d WHERE NOT EXISTS (SELECT 1 FROM mysql.user u WHERE CONCAT(u.User,'@',u.Host)=d.DEFINER);")
    [ "$orphan" = 0 ] || die "Node $node has missing DEFINER accounts; repair explicitly before export/validation"
)

exact_gtid() (
    node=$1; expected=$2
    # Set equality, not string equality or just a successful wait for a subset.
    equal=$(sql "$node" "SELECT GTID_SUBSET(@@GLOBAL.gtid_executed,'$(q "$expected")') AND GTID_SUBSET('$(q "$expected")',@@GLOBAL.gtid_executed);")
    [ "$equal" = 1 ] || die "Node $node GTID set differs from the frozen reference"
)

object_snapshot() (
    node=$1; output=$2
    credential "$node"
    definer_guard "$node"
    databases=$(sql "$node" "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY SCHEMA_NAME;")
    printf '%s\n' "$databases" > "$output.databases"
    : > "$output"
    [ -n "$databases" ] || exit 0
    set -f
    set -- $databases
    for database do case $database in *[!A-Za-z0-9_\$]*) die 'Schema name requires reviewed external validation';; esac; done
    # Includes empty databases, indexes, constraints, partitions, views,
    # routine bodies/characteristics, triggers and events, with their DEFINERs.
    "$DUMP" --defaults-file="$TEMP/$node.cnf" --no-login-paths --no-data --routines --events --triggers --no-tablespaces --set-gtid-purged=OFF --skip-comments --skip-dump-date --databases "$@" > "$output" 2> "$output.err" || die "Node $node full stored-object export failed"
)

full_object_checks() (
    mysqldump_version_guard
    object_snapshot 1 "$RUN/node_1.full_objects.sql"
    for node in $(ids); do
        [ "$node" != 1 ] || continue
        object_snapshot "$node" "$RUN/node_$node.full_objects.sql"
        account_snapshot_compare "$node"
        cmp -s "$RUN/node_1.full_objects.sql.databases" "$RUN/node_$node.full_objects.sql.databases" || die "Node $node schema inventory mismatch"
        diff -u "$RUN/node_1.full_objects.sql" "$RUN/node_$node.full_objects.sql" > "$RUN/node_$node.full_objects.diff" || die "Node $node schema/stored object mismatch; inspect full_objects.diff"
    done
)

account_snapshot_compare() (
    node=$1
    mkdir -p "$RUN/accounts_source" "$RUN/accounts_$node"
    export_source_accounts "$RUN/accounts_source" 1 >/dev/null
    export_source_accounts "$RUN/accounts_$node" "$node" >/dev/null
    for component in source_accounts.list source_accounts.sql source_grants.sql source_default_roles.sql; do
        cmp -s "$RUN/accounts_source/$component" "$RUN/accounts_$node/$component" || die "Node $node account/role state mismatch ($component); protected evidence retained"
    done
)

if [ "${MYSQL_GR_LIB_ONLY:-0}" != 1 ]; then main; fi
