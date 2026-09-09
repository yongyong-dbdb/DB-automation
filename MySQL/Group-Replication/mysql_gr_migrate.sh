#!/bin/sh
# mysql_gr_migrate.sh v1.0.3
# POSIX sh; OS utilities and MySQL clients only. No external language packages.
# v1.0.3 keeps the reviewed v1.0.2 migration core and overrides discovery/configuration
# selection so values that can be proven from the running MySQL instance are not re-asked.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE="$SCRIPT_DIR/mysql_gr_migrate_core_v1.0.2.sh"
[ -r "$CORE" ] || { printf 'ERROR: required core file not found: %s\n' "$CORE" >&2; exit 1; }
MYSQL_GR_LIB_ONLY=1
export MYSQL_GR_LIB_ONLY
. "$CORE"
unset MYSQL_GR_LIB_ONLY
VERSION=1.0.3

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
    log '1) Existing GTID replication -> GR'; log '2) Standalone -> GR'
    legacy_state=${MYSQL_GR_GTID_STATE_FILE:-${MYSQL_GTID_STATE_FILE:-"$(pwd)/.mysql_gtid_replication.state"}}
    default_migration=2; [ -r "$legacy_state" ] && [ "${MYSQL_GR_IGNORE_GTID_STATE:-0}" != 1 ] && default_migration=1
    choice=$(required 'Migration mode (1/2)' "$default_migration")
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

main
