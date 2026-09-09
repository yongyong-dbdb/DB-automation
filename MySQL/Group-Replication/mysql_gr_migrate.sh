#!/bin/sh
# mysql_gr_migrate.sh v1.0.0
# POSIX sh; OS utilities and MySQL clients only. No external language packages.
# Supported: Oracle MySQL 8.0.27+, 8.4.x, 9.7.x; homogeneous exact versions.
# Single-primary or multi-primary / XCom. Never resets GTID or binary logs.
set -eu
umask 077
VERSION=1.0.0
ROOT=${MYSQL_GR_WORK_ROOT:-"$(pwd)/mysql_gr_work"}
MYSQL=${MYSQL_GR_MYSQL:-mysql}
DUMP=${MYSQL_GR_MYSQLDUMP:-mysqldump}
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
confirm() { [ "$(ask "Type $1 to continue" '')" = "$1" ] || die 'Cancelled.'; }
uint() { case $1 in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
port_ok() { uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
safe_host() { case $1 in ''|*[!a-zA-Z0-9_.-]*) die 'Use an IPv4 address or DNS name (IPv6 is not supported in v1.0.0).';; esac; }
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
    if [ "$rc" -ne 0 ]; then log "Stopped. Preserve state in $ROOT. Inspect status and diagnostics before retrying. Write fences and stopped channels are NOT automatically reversed."; fi
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
Environment: MYSQL_GR_WORK_ROOT, MYSQL_GR_MYSQL, MYSQL_GR_MYSQLDUMP
Use the same absolute MYSQL_GR_WORK_ROOT for every invocation.
No SSH/repository/package installation required. Remote cnf/restart is performed
on that host using the generated snippet, then configure/precheck is rerun.
Credentials are prompted each run and deleted from temporary files on exit.
EOF
}
credential() (
    i=$1
    [ ! -f "$TEMP/$i.cnf" ] || exit 0
    pw=$(secret "Node $i password for $(get "$i" user)")
    {
        printf '[client]\nuser="%s"\npassword="%s"\n' "$(optq "$(get "$i" user)")" "$(optq "$pw")"
        if [ "$(get "$i" mode)" = socket ]; then
            printf 'protocol=SOCKET\nsocket="%s"\n' "$(optq "$(get "$i" socket)")"
        else
            printf 'protocol=TCP\nhost="%s"\nport=%s\nssl-mode=%s\n' "$(optq "$(get "$i" host)")" "$(get "$i" port)" "$(get "$i" admin_tls)"
            [ ! -s "$ROOT/$i/admin_ca" ] || printf 'ssl-ca="%s"\n' "$(optq "$(get "$i" admin_ca)")"
        fi
        printf 'connect-timeout=10\n'
    } > "$TEMP/$i.cnf"
)
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
discover() {
    [ ! -e "$ROOT/meta/count" ] || die 'Existing project found. Use a different MYSQL_GR_WORK_ROOT to rediscover.'
    mkdir -p "$ROOT/meta"
    log '1) Existing GTID replication -> GR'; log '2) Standalone -> GR'
    choice=$(required 'Migration mode (1/2)' '')
    case $choice in 1) put meta mode gtid;; 2) put meta mode standalone;; *) die 'Choose 1 or 2';; esac
    count=$(required 'Member count (2..9)' 3)
    uint "$count" && [ "$count" -ge 2 ] && [ "$count" -le 9 ] || die 'Member count must be 2..9'
    put meta count "$count"
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
    log "Discovery complete: $ROOT"
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
configure() {
    connected; no_group; endpoints_check
    profile=$(required 'Configuration profile (minimum/production)' minimum)
    case $profile in minimum|production) :;; *) die 'Invalid profile';; esac
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
        if [ "$(get "$i" location)" = remote ] || [ -z "$(get "$i" cnf)" ]; then
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
        backup="${cnf}.before_gr_v${VERSION}_$(date +%Y%m%d_%H%M%S)_$$"
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
}
fence() {
    log 'Stop application writers, DDL jobs, backup/restore jobs and privileged maintenance connections first.'
    confirm 'WRITERS STOPPED'
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
catchup() (
    i=$1; target=$2
    [ "$(sql "$i" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(q "$target")',300);")" = 0 ] || die "Node $i GTID wait timed out"
    [ "$(sql "$i" "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,'$(q "$target")');")" = '' ] || die "Node $i contains extra/errant GTIDs; reconcile or externally reprovision"
)
initialize() {
    precheck; fence
    target=$(val 1 gtid_executed)
    put meta frozen_gtid "$target"
    for i in $(ids); do
        [ "$i" != 1 ] || continue
        if [ "$(get "$i" kind)" = replica ]; then
            ch=$(q "$(get "$i" channel)")
            log "Starting/catching up only node $i selected GTID channel after any configuration restart."
            sql "$i" "START REPLICA FOR CHANNEL '$ch';"
            catchup "$i" "$target"
            put "$i" initialized replica
            continue
        fi
        method=$(required "Node $i initialization (dump/already/external)" dump)
        case $method in
            external) log 'Restore the authoritative full data/GTID set using your validated physical backup/Clone procedure, then select already.'; die 'External initialization pending';;
            already)
                confirm "NODE $i DATA AND GTID VERIFIED"
                catchup "$i" "$target"; put "$i" initialized external; continue;;
            dump) :;; *) die 'Invalid initialization method';;
        esac
        [ -z "$(val "$i" gtid_executed)" ] || die "Node $i has GTID history; no automatic GTID reset is performed"
        [ "$(sql "$i" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema');")" = 0 ] || die "Node $i is not empty; use external provisioning"
        # Strict names keep positional arguments and DEFINER/event SQL unambiguous.
        dbs=$(sql 1 "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY schema_name;")
        [ -n "$dbs" ] || die 'No application DBs; use already for an intentionally empty topology'
        for db in $dbs; do case $db in *[!A-Za-z0-9_\$]*) die 'Database name requires external provisioning';; esac; done
        command -v "$DUMP" >/dev/null 2>&1 || die 'Matching mysqldump executable required'
        "$DUMP" --version > "$RUN/mysqldump_version.txt"
        dv=$(sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' "$RUN/mysqldump_version.txt")
        sv=$(get 1 version | sed 's/[^0-9.].*//')
        [ "$dv" = "$sv" ] || die "mysqldump version $dv does not match server $sv; set MYSQL_GR_MYSQLDUMP"
        confirm "INITIALIZE EMPTY NODE $i"
        dump="$RUN/full_application_node_$i.sql"
        # Source is fenced: GTID snapshot remains stable throughout the dump.
        set -f; set -- $dbs; set +f
        "$DUMP" --defaults-file="$TEMP/1.cnf" --no-login-paths --single-transaction --quick --skip-lock-tables --routines --events --triggers --hex-blob --set-gtid-purged=ON --databases "$@" > "$dump" 2> "$RUN/node_$i.dump.log"
        [ -s "$dump" ] || die 'Empty dump'
        sha256sum "$dump" > "$dump.sha256"
        [ "$(val 1 gtid_executed)" = "$target" ] || die 'Source changed during initialization'
        mkdir -p "$TEMP/unfenced"; : > "$TEMP/unfenced/$i"
        sql "$i" 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;'
        if ! "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --binary-mode < "$dump" > "$RUN/node_$i.restore.log" 2>&1; then
            sql "$i" 'SET GLOBAL super_read_only=ON;' || :
            die "Restore failed; node $i requires external clean reprovisioning before retry"
        fi
        # Dumped events stay disabled; no replicated event may run twice.
        events=$(sql "$i" "SELECT CONCAT('ALTER EVENT ',CHAR(96),REPLACE(EVENT_SCHEMA,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),'.',CHAR(96),REPLACE(EVENT_NAME,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),' DISABLE;') FROM information_schema.events;")
        sql "$i" "SET SESSION sql_log_bin=0; $events SET GLOBAL super_read_only=ON;"
        rm -f "$TEMP/unfenced/$i"
        catchup "$i" "$target"
        put "$i" initialized dump
    done
    [ "$(val 1 gtid_executed)" = "$target" ] || die 'Source changed while fenced'
    data_checks
    put meta initialized yes
    log 'INITIALIZATION PASSED. All nodes remain write-fenced; event schedulers remain OFF.'
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
if [ "${MYSQL_GR_LIB_ONLY:-0}" != 1 ]; then main; fi
