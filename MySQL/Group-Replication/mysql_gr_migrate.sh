#!/bin/sh
# mysql_gr_migrate.sh v1.0.9
# POSIX sh; OS utilities and MySQL clients only. No external language packages.
# Supported: Oracle MySQL 8.0.27+, 8.4.x, 9.7.x; homogeneous exact versions.
# Single-primary or multi-primary / XCom. Never resets GTID or binary logs.
set -eu
umask 077
VERSION=1.0.9
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
Usage: sh mysql_gr_migrate.sh discover|configure|precheck|initialize|cutover|join|release|validate|status|all
  discover   Select GTID -> GR / Standalone -> GR and 2..9 nodes
  configure  Generate version-aware config; optionally apply/restart local nodes
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
    for pair in 'transaction_write_set_extraction XXHASH64' 'replica_parallel_type LOGICAL_CLOCK' 'master_info_repository TABLE' 'relay_log_info_repository TABLE'; do
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
                    obj=substr(line,RSTART+RLENGTH)
                    sub(/^[[:space:]]+/,"",obj)
                    sub(/^[Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)
                    sub(/^[Ii][Ff][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+/,"",obj)
                    sub(/[[:space:](;,].*$/,"",obj)
                    gsub(/`/,"",obj)
                    if (kind!="DATABASE" && kind!="SCHEMA" && obj !~ /\./ && db!="") obj=db "." obj
                    if (obj=="") obj="UNKNOWN"
                    emit("DDL",op " " kind,obj,line)
                } else {
                    emit("DDL",op " OBJECT","UNKNOWN",line)
                }
            }
        }
    ' "$evidence" > "$summary"
    chmod 600 "$summary"

    dml_count=$(awk -F '\t' 'NR>1 && $2=="DML" {n++} END{print n+0}' "$summary")
    ddl_count=$(awk -F '\t' 'NR>1 && $2=="DDL" {n++} END{print n+0}' "$summary")
    total=$(awk 'END{print NR>0?NR-1:0}' "$summary")
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

divergence_abort_snapshot() {
    i=$1
    snapshot="$RUN/divergence_abort_state.tsv"
    {
        printf 'NODE\tREAD_ONLY\tSUPER_READ_ONLY\tEVENT_SCHEDULER\tGTID_EXECUTED\n'
        for j in $(ids); do
            if row=$(sql "$j" 'SELECT @@server_uuid,@@read_only,@@super_read_only,@@event_scheduler,@@gtid_executed;' 2>/dev/null); then
                printf '%s\t%s\n' "$j" "$row"
            else
                printf '%s\tUNAVAILABLE\n' "$j"
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
    log '  6) After reviewed reconciliation/reprovisioning, rerun precheck and initialize if instance identity is unchanged.'
    log '     If server_uuid/instance identity changed, use a fresh MYSQL_GR_WORK_ROOT and run discover again.'
}

divergence_workflow() {
    i=$1; target=$2
    gtid_compare "$i" "$target"
    [ -n "$GTID_EXTRA" ] || return 0
    log "Node $i has divergent GTID history. There is no automatic ignore, skip, GTID rewrite, or reset path."
    while :; do
        log '  inspect : read current binary logs and decode only the extra GTIDs; no SQL is applied (binary-log I/O/network reads may occur).'
        log '  external: stop here for reviewed reconciliation/reprovisioning from the authoritative source.'
        log '  abort   : stop without changing GTID history; save a read-only state snapshot and print next checks.'
        action=$(required "Node $i divergent GTID action (inspect/external/abort)" inspect)
        case $action in
            inspect)
                inspect_extra_gtids "$i" "$target"
                log 'Inspection complete. Review the saved evidence before deciding how to reconcile the member.'
                while :; do
                    log '  external: reconcile/reprovision outside this script, then rerun after identity and GTID checks pass.'
                    log '  abort   : save current state and print exactly what to review next; no GTID reconciliation is attempted.'
                    next_action=$(required "Node $i action after inspection (external/abort)" abort)
                    case $next_action in
                        external)
                            divergence_abort_snapshot "$i"
                            external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"
                            log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."
                            die "Node $i external reconciliation/reprovisioning required before GR migration";;
                        abort)
                            divergence_abort_snapshot "$i"
                            die "Node $i divergence left unchanged after read-only inspection";;
                        *) log 'Invalid action. Enter external or abort.';;
                    esac
                done
                ;;
            external)
                divergence_abort_snapshot "$i"
                external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"
                log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."
                die "Node $i external reconciliation/reprovisioning required before GR migration";;
            abort)
                divergence_abort_snapshot "$i"
                die "Node $i divergence left unchanged";;
            *) log 'Invalid action. Enter inspect, external, or abort.';;
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
                dbs=$(sql 1 "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY schema_name;")
                [ -n "$dbs" ] || die 'Authoritative source has no application DBs; use external/preprovisioned verification for this intentionally empty topology'
                for db in $dbs; do case $db in *[!A-Za-z0-9_\$]*) die 'Database name requires external provisioning';; esac; done
                command -v "$DUMP" >/dev/null 2>&1 || die 'Matching mysqldump executable required'
                "$DUMP" --version > "$RUN/mysqldump_version.txt"
                dv=$(sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' "$RUN/mysqldump_version.txt")
                sv=$(get 1 version | sed 's/[^0-9.].*//')
                [ "$dv" = "$sv" ] || die "mysqldump version $dv does not match server $sv; set MYSQL_GR_MYSQLDUMP"
                confirm "INITIALIZE EMPTY NODE $i"
                dump="$RUN/full_application_node_$i.sql"
                set -f; set -- $dbs; set +f
                "$DUMP" --defaults-file="$TEMP/1.cnf" --no-login-paths --single-transaction --quick --skip-lock-tables --routines --events --triggers --hex-blob --set-gtid-purged=ON --databases "$@" > "$dump" 2> "$RUN/node_$i.dump.log"
                [ -s "$dump" ] || die 'Empty dump'
                sha256sum "$dump" > "$dump.sha256"
                [ "$(normalize_gtid "$(val 1 gtid_executed)")" = "$target" ] || die 'Source changed during initialization'
                mkdir -p "$TEMP/unfenced"; : > "$TEMP/unfenced/$i"
                sql "$i" 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;'
                if ! "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --binary-mode < "$dump" > "$RUN/node_$i.restore.log" 2>&1; then
                    sql "$i" 'SET GLOBAL super_read_only=ON;' || :
                    die "Restore failed; node $i requires external clean reprovisioning before retry"
                fi
                events=$(sql "$i" "SELECT CONCAT('ALTER EVENT ',CHAR(96),REPLACE(EVENT_SCHEMA,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),'.',CHAR(96),REPLACE(EVENT_NAME,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),' DISABLE;') FROM information_schema.events;")
                sql "$i" "SET SESSION sql_log_bin=0; $events SET GLOBAL super_read_only=ON;"
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
                external_manual_guidance "$i" "member is not empty and does not match the authoritative starting point"
                die "Node $i requires external provisioning from node 1 before GR migration; automatic merge/reset is not performed"
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
    if [ -z "$status" ]; then local_write "$i" "INSTALL PLUGIN group_replication SONAME 'group_replication.so';"; fi
    [ "$(sql "$i" "SELECT PLUGIN_STATUS FROM information_schema.plugins WHERE PLUGIN_NAME='group_replication';")" = ACTIVE ] || die 'GR plugin is not ACTIVE'
)
persist() {
    hasvar "$1" "$2" || die "Node $1 lacks required GR option $2"
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
    rp=$(secret 'Recovery password shared across these donor accounts')
    [ -n "$rp" ] || die 'Recovery password cannot be empty'
    for i in $(ids); do
        for host in $hosts; do
            account="'$(q "$ru")'@'$(q "$host")'"
            if [ "$action" = create ]; then
                [ "$(sql "$i" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$ru")' AND Host='$(q "$host")';")" = 0 ] || die "Account exists on node $i; choose existing or another name"
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
        sql "$i" "CHANGE REPLICATION SOURCE TO SOURCE_USER='$(q "$ru")', SOURCE_PASSWORD='$(q "$rp")' FOR CHANNEL 'group_replication_recovery';" >/dev/null 2> "$TEMP/account_error"
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
main() {
    case $STEP in help|--help|-h) help; return;; --version) printf '%s\n' "$VERSION"; return;; discover|configure|precheck|initialize|cutover|join|release|validate|status|all) :;; *) help; exit 2;; esac
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


main
