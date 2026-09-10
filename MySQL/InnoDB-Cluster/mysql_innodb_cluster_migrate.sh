#!/bin/sh
# mysql_innodb_cluster_migrate.sh v1.0.26
# POSIX sh. Oracle MySQL GA 8.0+; runtime AdminAPI capability detection. Requires preinstalled mysql/mysqlsh; never installs packages.
# Safe automation for prepared MySQL instances / existing Group Replication -> InnoDB Cluster.
set -eu
umask 077
VERSION=1.0.26
ROOT=${MYSQL_IC_WORK_ROOT:-"$(pwd)/mysql_innodb_cluster_work"}
MYSQL=${MYSQL_IC_MYSQL:-mysql}
MYSQLSH=${MYSQL_IC_MYSQLSH:-mysqlsh}
STEP=${1:-help}
log(){ printf '%s\n' "$*" >&2; }
die(){ log "ERROR: $*"; exit 1; }
# INTERACTIVE PROMPT POLICY (mandatory for every user-entered value):
# - Never present only a bare technical term as the prompt.
# - Always explain what the value means and show a masked example.
# - If a default/auto-detected value exists, show the value without extra reasoning text.
# - Never embed real environment IP addresses or ports in examples; use <IP_ADDRESS>, <HOSTNAME>, <PORT>, <NETWORK_PATTERN>.
# - Password prompts must explain purpose/policy, never echo or print the password.
prompt_block(){
    title=$1; meaning=$2; example=$3; detected=${4-}
    printf '\n%s\n' "$title" >&2
    [ -z "$meaning" ] || printf '  Meaning : %s\n' "$meaning" >&2
    [ -z "$example" ] || printf '  Example : %s\n' "$example" >&2
    [ -z "$detected" ] || printf '  Default : %s\n' "$detected" >&2
}
ask(){ p=$1; d=${2-}; printf '%s%s: ' "$p" "${d:+ [$d]}" >&2; IFS= read -r a || return 1; printf '%s' "${a:-$d}"; }
ask_explained(){ title=$1; meaning=$2; example=$3; prompt=$4; def=${5-}; prompt_block "$title" "$meaning" "$example" "$def"; ask "$prompt" "$def"; }
secret(){ printf '%s: ' "$1" >&2; if [ -t 0 ]; then o=$(stty -g); trap 'stty "$o"' 0 1 2 15; stty -echo; fi; IFS= read -r a || return 1; printf '\n' >&2; printf '%s' "$a"; }
secret_explained(){ title=$1; meaning=$2; prompt=$3; prompt_block "$title" "$meaning" '******** (not echoed)' ''; secret "$prompt"; }

confirm(){ want=$1; got=$(ask "Type $want to continue" '') || return 1; [ "$got" = "$want" ] || die "Confirmation mismatch; expected $want"; }
q(){ printf '%s' "$1" | sed "s/'/''/g"; }
jsq(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
need(){ command -v "$1" >/dev/null 2>&1 || die "$1 is required and must already be installed; this script never installs packages."; }
cap_help(){ "$MYSQLSH" -- dba createCluster --help 2>/dev/null || :; }
has_create_option(){ cap_help | grep -q -- "--$1="; }
add_help(){ "$MYSQLSH" -- cluster addInstance --help 2>/dev/null || :; }
has_add_option(){ add_help | grep -q -- "--$1="; }
show_capabilities(){ out="$ROOT/capabilities.txt"; { printf 'mysqlsh='; "$MYSQLSH" --version | head -1; for o in adoptFromGR multiPrimary communicationStack localAddress memberSslMode ipAllowlist disableClone gtidSetIsComplete consistency exitStateAction expelTimeout autoRejoinTries memberWeight; do if has_create_option "$o"; then printf 'create.%s=yes\n' "$o"; else printf 'create.%s=no\n' "$o"; fi; done; for o in recoveryMethod localAddress cloneDonor waitRecovery timeout; do if has_add_option "$o"; then printf 'add.%s=yes\n' "$o"; else printf 'add.%s=no\n' "$o"; fi; done; } > "$out"; cat "$out"; }
choice(){ prompt=$1; def=$2; shift 2; while :; do v=$(ask "$prompt" "$def") || return 1; for x in "$@"; do [ "$v" = "$x" ] && { printf '%s' "$v"; return 0; }; done; log "Choose one of: $*"; done; }

cleanup(){ rc=$?; trap - 0 1 2 15; [ -z "${TMP:-}" ] || rm -rf "$TMP"; [ -z "${LOCK:-}" ] || rmdir "$LOCK" 2>/dev/null || :; exit "$rc"; }
trap cleanup 0 1 2 15
mkdir -p "$ROOT"; chmod 700 "$ROOT" 2>/dev/null || :
LOCK="$ROOT/.lock"; mkdir "$LOCK" 2>/dev/null || die "Another operation is using $ROOT"
TMP=$(mktemp -d "$ROOT/.tmp.XXXXXX")
need "$MYSQL"; need "$MYSQLSH"
put(){ mkdir -p "$ROOT/$1"; printf '%s\n' "$3" > "$ROOT/$1/$2"; }
get(){ cat "$ROOT/$1/$2"; }
ids(){ n=1; c=$(get meta count); while [ "$n" -le "$c" ]; do printf '%s\n' "$n"; n=$((n+1)); done; }
help(){ cat <<EOF
mysql_innodb_cluster_migrate.sh v$VERSION
Usage: sh $0 discover|capabilities|sql-precheck|strict-gtid|configure-admin|precheck|configure|plan|create|adopt|validate|status|all
  discover   Register 1..9 instances and detect GR / metadata state; read-only
  capabilities Show mysqlsh AdminAPI options supported by the installed version; read-only
  sql-precheck Run SQL/GR/topology safety checks only; read-only
  strict-gtid Require moment-in-time exact GTID equality; use with application writes quiesced
  configure-admin Create/reuse a dedicated AdminAPI clusterAdmin using dba.configureInstance(); mutating
  precheck   Run SQL safety checks + dba.checkInstanceConfiguration() as clusterAdmin; read-only
  configure  Explicitly run dba.configureInstance() as clusterAdmin only after precheck and confirmation
  plan       Explain detected topology and selectable options; read-only
  create     Create a new InnoDB Cluster from a prepared non-GR seed; no implicit adoption
  adopt      Adopt an existing ONLINE Group Replication group using adoptFromGR:true
  validate   Validate metadata, topology, ONLINE state, roles and GTID convergence
  status     Display cluster/GR status without changes
  all        discover -> precheck, then stops before any mutating create/adopt action
Environment: MYSQL_IC_WORK_ROOT, MYSQL_IC_MYSQL, MYSQL_IC_MYSQLSH
Version handling: runtime capability detection; unsupported AdminAPI options are not offered. No force bypass.
No package installation, GTID reset, metadata drop, GR dissolve, or destructive recovery is performed.
EOF
}
cred(){ i=$1; [ -f "$TMP/$i.pw" ] && return 0; mode=$(get "$i" auth_mode); if [ "$mode" = login-path ]; then return 0; fi; pw=$(secret "Node $i password for $(get "$i" user)"); printf '%s\n' "$pw" > "$TMP/$i.pw"; chmod 600 "$TMP/$i.pw"; }
mysql_cmd(){ i=$1; shift; if [ "$(get "$i" auth_mode)" = login-path ]; then lp=$(get "$i" login_path); lf=$(get "$i" login_file); MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" "$@"; else cred "$i"; pw=$(cat "$TMP/$i.pw"); MYSQL_PWD="$pw" "$MYSQL" -h "$(get "$i" host)" -P "$(get "$i" port)" -u "$(get "$i" user)" --protocol=TCP "$@"; fi; }
sql(){ i=$1; stmt=$2; printf '%s\n' "$stmt" | mysql_cmd "$i" --batch --raw --skip-column-names; }
mysqlsh_exec(){ i=$1; code=$2; out=$3; if [ "$(get "$i" auth_mode)" = login-path ]; then lp=$(get "$i" login_path); lf=$(get "$i" login_file); MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQLSH" --login-path="$lp" --no-wizard --js --execute="$code" >"$out" 2>&1; else cred "$i"; uri="$(get "$i" user)@$(get "$i" host):$(get "$i" port)"; cat "$TMP/$i.pw" | "$MYSQLSH" --uri "$uri" --passwords-from-stdin --js --execute="$code" >"$out" 2>&1; fi; }
admin_ready(){ [ -f "$ROOT/meta/admin_user" ]; }
admin_cred(){ [ -f "$TMP/admin.pw" ] && return 0; admin_ready || die 'Run configure-admin first'; ap=$(secret "Cluster admin password for $(get meta admin_user)"); [ -n "$ap" ] || die 'Cluster admin password cannot be empty'; printf '%s\n' "$ap" > "$TMP/admin.pw"; chmod 600 "$TMP/admin.pw"; }
admin_host_for(){ i=$1; if [ -f "$ROOT/$i/admin_host" ]; then get "$i" admin_host; else get "$i" connect_host; fi; }
admin_port_for(){ i=$1; get "$i" runtime_port; }
mysqlsh_admin_exec(){ i=$1; code=$2; out=$3; admin_cred; uri="$(get meta admin_user)@$(admin_host_for "$i"):$(admin_port_for "$i")"; cat "$TMP/admin.pw" | "$MYSQLSH" --uri "$uri" --passwords-from-stdin --js --execute="$code" >"$out" 2>&1; }
meta_exists(){ [ "$(sql "$1" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mysql_innodb_cluster_metadata';")" -gt 0 ]; }
grmembers(){ sql "$1" "SELECT MEMBER_ID,MEMBER_HOST,MEMBER_PORT,MEMBER_STATE,MEMBER_ROLE FROM performance_schema.replication_group_members ORDER BY MEMBER_ID;"; }
metadata_absence_guard(){
    found=0
    for i in $(ids); do
        c=$(sql "$i" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mysql_innodb_cluster_metadata';")
        [ "$c" -eq 0 ] || found=$((found+1))
    done
    [ "$found" -eq 0 ] || die "InnoDB Cluster metadata exists on $found/$(get meta count) registered node(s). Migration create/adopt will not overwrite or drop metadata; use AdminAPI status/recovery procedures instead."
}
gtids(){ sql "$1" 'SELECT @@GLOBAL.gtid_executed;'; }
gr_mode(){ if [ "$(sql "$1" 'SELECT @@GLOBAL.group_replication_single_primary_mode;')" = 1 ]; then printf 'single-primary'; else printf 'multi-primary'; fi; }
gr_role_guard(){ i=$1; mode=$(gr_mode "$i"); members=$(grmembers "$i"); total=$(printf '%s\n' "$members" | awk 'NF{n++} END{print n+0}'); primaries=$(printf '%s\n' "$members" | awk '$5=="PRIMARY"{n++} END{print n+0}'); case $mode in single-primary) [ "$primaries" -eq 1 ] || die "Single-primary GR must have exactly one PRIMARY; found $primaries";; multi-primary) [ "$primaries" -eq "$total" ] || die "Multi-primary GR must report every ONLINE member as PRIMARY; found $primaries/$total";; esac; printf '%s' "$mode"; }
detect_login_paths(){
    out="$TMP/login_path_candidates"
    : > "$out"
    command -v mysql_config_editor >/dev/null 2>&1 || return 0
    for lf in "$HOME/.mylogin.cnf" /root/.mylogin.cnf /home/*/.mylogin.cnf; do
        [ -f "$lf" ] || continue
        MYSQL_TEST_LOGIN_FILE="$lf" mysql_config_editor print --all 2>/dev/null |
        sed -n 's/^\[\(.*\)\]$/\1/p' |
        while IFS= read -r lp; do
            [ -n "$lp" ] || continue
            if MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" --batch --skip-column-names -e 'SELECT @@server_uuid,@@port,@@socket;' >/dev/null 2>&1; then
                info=$(MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" --batch --skip-column-names -e 'SELECT @@server_uuid,@@port,@@socket;' 2>/dev/null | head -1)
                printf '%s\t%s\t%s\n' "$lf" "$lp" "$info"
            fi
        done
    done | awk -F '\t' '!seen[$3 FS $4 FS $5]++' > "$out"
}
select_detected_login_path(){
    i=$1
    [ -s "$TMP/login_path_candidates" ] || return 1
    prompt_block "Node $i detected MySQL login-paths" "Saved login-path credentials that successfully connect to a running MySQL instance." "<LOGIN_PATH>  [file: /home/<OS_USER>/.mylogin.cnf]" ''
    n=1
    while IFS='	' read -r lf lp uuid port sock; do
        printf '  %s) %s  [file=%s, port=%s, socket=%s]\n' "$n" "$lp" "$lf" "$port" "$sock" >&2
        n=$((n+1))
    done < "$TMP/login_path_candidates"
    sel=$(ask "Select login-path for Node $i" '1')
    case $sel in ''|*[!0-9]*) die 'login-path selection must be a number';; esac
    line=$(sed -n "${sel}p" "$TMP/login_path_candidates")
    [ -n "$line" ] || die "Invalid login-path selection: $sel"
    lf=$(printf '%s\n' "$line" | cut -f1)
    lp=$(printf '%s\n' "$line" | cut -f2)
    printf '%s\t%s\n' "$lf" "$lp"
}
register_node(){
    i=$1
    [ -f "$TMP/login_paths_scanned" ] || { detect_login_paths; : > "$TMP/login_paths_scanned"; }
    if [ -s "$TMP/login_path_candidates" ]; then auth_default=login-path; else auth_default=password; fi
    mode=$(ask_explained "Node $i authentication method" "How this script authenticates to the instance during discovery/bootstrap." "login-path | password" "Authentication method for Node $i" "$auth_default")
    case $mode in
        login-path)
            if selected=$(select_detected_login_path "$i"); then
                lf=$(printf '%s\n' "$selected" | cut -f1)
                lp=$(printf '%s\n' "$selected" | cut -f2)
            else
                lp=$(ask_explained "Node $i MySQL login-path name" "The login-path label previously created with mysql_config_editor." "root@/path/to/mysql.sock | root@<HOST>:<PORT>" "Login-path name for Node $i" "")
                [ -n "$lp" ] || die 'login-path required'
                lf=$(ask_explained "Node $i login-path file (.mylogin.cnf)" "The encrypted credential file containing the selected login-path." "/home/<OS_USER>/.mylogin.cnf | /root/.mylogin.cnf" "Path to .mylogin.cnf for Node $i" "$HOME/.mylogin.cnf")
            fi
            put "$i" auth_mode login-path; put "$i" login_path "$lp"; put "$i" login_file "$lf"; put "$i" user ''; put "$i" host ''; put "$i" port 0
            ;;
        password)
            u=$(ask_explained "Node $i bootstrap administrative user" "Administrative account used before the dedicated clusterAdmin is available." "root | <ADMIN_USER>" "Bootstrap admin user for Node $i" "root")
            h=$(ask_explained "Node $i bootstrap connection host" "Host used by this script for the initial TCP connection." "<HOSTNAME> | <IP_ADDRESS>" "Connection host for Node $i" "${MYSQL_HOST:-}")
            [ -n "$h" ] || die "Node $i connection host/IP is required when password authentication is used"
            p=$(ask_explained "Node $i MySQL SQL port" "TCP listener port of this MySQL instance." "<PORT>" "SQL port for Node $i" "${MYSQL_TCP_PORT:-}")
            case $p in ''|*[!0-9]*) die "Node $i SQL port must be entered as a number";; esac
            put "$i" auth_mode password; put "$i" user "$u"; put "$i" host "$h"; put "$i" port "$p"
            ;;
        *) die 'auth mode must be login-path or password';;
    esac
    cred "$i"
    uuid=$(sql "$i" 'SELECT @@server_uuid;'); ver=$(sql "$i" 'SELECT VERSION();'); port=$(sql "$i" 'SELECT @@port;'); host=$(sql "$i" 'SELECT @@hostname;')
    # AdminAPI must use an address reachable by every member. Prefer live GR MEMBER_HOST, then report_host, then the explicit bootstrap host.
    report_host=$(sql "$i" "SELECT COALESCE(@@report_host,'');")
    gr_member_host=$(sql "$i" "SELECT COALESCE((SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ID='$(q "$uuid")' LIMIT 1),'');")
    gr_member_port=$(sql "$i" "SELECT COALESCE((SELECT MEMBER_PORT FROM performance_schema.replication_group_members WHERE MEMBER_ID='$(q "$uuid")' LIMIT 1),0);")
    detected_admin_host=$gr_member_host
    [ -n "$detected_admin_host" ] || detected_admin_host=$report_host
    if [ -z "$detected_admin_host" ] && [ "$(get "$i" auth_mode)" = password ]; then detected_admin_host=$(get "$i" host); fi
    admin_connect_host=$(ask_explained "Node $i AdminAPI reachable host" "Address MySQL Shell AdminAPI will use to reach this MySQL instance." "<HOSTNAME> | <IP_ADDRESS>" "AdminAPI reachable host for Node $i" "$detected_admin_host")
    [ -n "$admin_connect_host" ] || die "Node $i AdminAPI reachable host/IP could not be auto-detected; enter it explicitly"
    put "$i" uuid "$uuid"; put "$i" version "$ver"; put "$i" runtime_port "$port"; put "$i" runtime_host "$host"
    put "$i" report_host "$report_host"; put "$i" gr_member_host "$gr_member_host"; put "$i" gr_member_port "$gr_member_port"
    put "$i" connect_host "$admin_connect_host"; put "$i" admin_host "$admin_connect_host"
    log "Node $i: $ver uuid=$uuid AdminAPI=$admin_connect_host:$port runtime_host=$host report_host=${report_host:-'(empty)'} GR_MEMBER_HOST=${gr_member_host:-'(none)'}"
}
discover_admin_host_candidate(){
    members=$(grmembers 1)
    [ -n "$members" ] || { printf ''; return 0; }
    first=$(printf '%s\n' "$members" | awk 'NF{print $2; exit}')
    [ -n "$first" ] || { printf ''; return 0; }
    same=yes
    while IFS= read -r h; do [ "$h" = "$first" ] || same=no; done <<EOF
$(printf '%s\n' "$members" | awk 'NF{print $2}')
EOF
    [ "$same" = yes ] || { printf ''; return 0; }
    case $first in localhost|127.0.0.1|::1|*:* ) printf ''; return 0;; esac
    command -v ip >/dev/null 2>&1 || { printf ''; return 0; }
    iface_line=$(ip -o -4 addr show scope global 2>/dev/null | awk -v h="$first" '$4 ~ ("^" h "/") {print; exit}')
    [ -n "$iface_line" ] || { printf ''; return 0; }
    iface=$(printf '%s\n' "$iface_line" | awk '{print $2}')
    ip -4 route show dev "$iface" scope link 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print $1; exit}'
}
discover_common_accounts(){
    out="$ROOT/common_accounts.txt"
    sql 1 "SELECT CONCAT(User,'@',Host) FROM mysql.user ORDER BY User,Host;" > "$TMP/accounts.1"
    cp "$TMP/accounts.1" "$TMP/accounts.common"
    for j in $(ids); do
        [ "$j" -eq 1 ] && continue
        sql "$j" "SELECT CONCAT(User,'@',Host) FROM mysql.user ORDER BY User,Host;" > "$TMP/accounts.$j"
        awk 'NR==FNR{a[$0]=1;next} a[$0]' "$TMP/accounts.$j" "$TMP/accounts.common" > "$TMP/accounts.next"
        mv "$TMP/accounts.next" "$TMP/accounts.common"
    done
    cp "$TMP/accounts.common" "$out"
}
require_discovery_schema(){
    [ -f "$ROOT/meta/work_schema_version" ] || die "This work root was created by an older discovery layout. Use a new MYSQL_IC_WORK_ROOT and run discover again."
    [ "$(get meta work_schema_version)" = 2 ] || die "Unsupported work-root schema version $(get meta work_schema_version); rediscover with a new work root."
}
discover(){
    [ ! -f "$ROOT/meta/complete" ] || die "Discovery already complete in $ROOT. Use a new MYSQL_IC_WORK_ROOT to rediscover."
    c=$(ask_explained 'Instance count' 'Number of MySQL instances participating in this migration set.' '3' 'Number of MySQL instances' '3')
    case $c in ''|*[!0-9]*) die 'invalid count';; esac
    [ "$c" -ge 1 ] && [ "$c" -le 9 ] || die 'count must be 1..9'
    mkdir -p "$ROOT/meta"
    put meta count "$c"
    put meta work_schema_version 2
    n=1
    while [ "$n" -le "$c" ]; do register_node "$n"; n=$((n+1)); done
    v=$(get 1 version); mixed=no
    for i in $(ids); do [ "$(get "$i" version)" = "$v" ] || mixed=yes; done
    if [ "$mixed" = yes ]; then
        log 'Detected mixed MySQL Server versions. Exact same version is the safest and recommended policy.'
        log 'Advanced mixed-version operation is accepted only if AdminAPI validates every member; force bypass is never used.'
        prompt_block 'Version compatibility policy' 'Controls whether every node must run the exact same MySQL version.' 'exact | adminapi' 'exact'; vp=$(choice 'Select version policy' exact exact adminapi)
        [ "$vp" = adminapi ] || die 'Mixed versions detected under exact-version policy'
        put meta version_policy adminapi
    else
        put meta version_policy exact
    fi
    g=$(sql 1 "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE<>'OFFLINE';")
    put meta gr_count "$g"
    if [ "$g" -gt 0 ]; then put meta gr_mode "$(gr_role_guard 1)"; else put meta gr_mode none; fi
    if meta_exists 1; then put meta metadata yes; else put meta metadata no; fi
    candidate=$(discover_admin_host_candidate)
    put meta admin_host_candidate "$candidate"
    discover_common_accounts
    : > "$ROOT/meta/complete"
    log "Discovery complete: count=$c gr_members=$g gr_mode=$(get meta gr_mode) metadata=$(get meta metadata)"
    if [ -n "$candidate" ]; then log "Discovered clusterAdmin Host candidate: $candidate (derived from live GR MEMBER_HOST and local interface route)"; else log 'No safe clusterAdmin Host candidate was auto-derived; configure-admin will require explicit review.'; fi
    log "Common user@host accounts across all registered nodes: $ROOT/common_accounts.txt"
}

assert_identity(){ for i in $(ids); do live=$(sql "$i" 'SELECT @@server_uuid;'); [ "$live" = "$(get "$i" uuid)" ] || die "Node $i UUID changed; use a new MYSQL_IC_WORK_ROOT and rediscover."; done; }
base_sql_precheck(){ require_discovery_schema; i=$1; out="$ROOT/node_${i}.sql_precheck.txt"; { printf 'version='; sql "$i" 'SELECT VERSION();'; printf 'uuid='; sql "$i" 'SELECT @@server_uuid;'; printf 'gtid_mode='; sql "$i" 'SELECT @@gtid_mode;'; printf 'enforce_gtid_consistency='; sql "$i" 'SELECT @@enforce_gtid_consistency;'; printf 'binlog_format='; sql "$i" 'SELECT @@binlog_format;'; printf 'server_id='; sql "$i" 'SELECT @@server_id;'; printf 'performance_schema='; sql "$i" 'SELECT @@performance_schema;'; printf 'report_host='; sql "$i" "SELECT COALESCE(@@report_host,'');"; printf 'metadata='; sql "$i" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mysql_innodb_cluster_metadata';"; printf 'non_innodb='; sql "$i" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','sys','performance_schema','information_schema') AND table_type='BASE TABLE' AND engine<>'InnoDB';"; printf 'tables_without_gr_key='; sql "$i" "SELECT COUNT(*) FROM information_schema.tables t WHERE t.table_schema NOT IN ('mysql','sys','performance_schema','information_schema') AND t.table_type='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.statistics s WHERE s.table_schema=t.table_schema AND s.table_name=t.table_name AND s.non_unique=0 GROUP BY s.index_name HAVING SUM(CASE WHEN s.nullable='YES' THEN 1 ELSE 0 END)=0);"; printf 'inbound_async_channels='; sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT IN ('group_replication_applier','group_replication_recovery') AND CHANNEL_NAME NOT LIKE 'clusterset_replication%';"; } > "$out"; grep -q '^gtid_mode=ON$' "$out" || die "Node $i gtid_mode is not ON"; grep -q '^enforce_gtid_consistency=ON$' "$out" || die "Node $i enforce_gtid_consistency is not ON"; grep -q '^binlog_format=ROW$' "$out" || die "Node $i binlog_format is not ROW"; grep -q '^performance_schema=1$' "$out" || die "Node $i performance_schema is not enabled"; grep -q '^non_innodb=0$' "$out" || die "Node $i has non-InnoDB application tables"; grep -q '^tables_without_gr_key=0$' "$out" || die "Node $i has application tables without a primary key or non-NULL UNIQUE key; Group Replication requires a row-identity key"; grep -q '^inbound_async_channels=0$' "$out" || { sql "$i" "SELECT CHANNEL_NAME,HOST,PORT,AUTO_POSITION FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT IN ('group_replication_applier','group_replication_recovery') AND CHANNEL_NAME NOT LIKE 'clusterset_replication%' ORDER BY CHANNEL_NAME;" >&2; die "Node $i has unmanaged inbound asynchronous replication channel(s). InnoDB Cluster setup does not support them; this script never uses force:true to bypass the check."; }; }
topology_address_check(){
    # Existing GR is authoritative for member-advertised addresses. Same host + different ports is valid.
    members=$(grmembers 1)
    [ -n "$members" ] || return 0
    for i in $(ids); do
        u=$(get "$i" uuid)
        row=$(printf '%s\n' "$members" | awk -v u="$u" '$1==u{print; exit}')
        [ -n "$row" ] || die "Node $i UUID is not in the existing GR membership"
        mh=$(printf '%s\n' "$row" | awk '{print $2}'); mp=$(printf '%s\n' "$row" | awk '{print $3}')
        [ "$mp" = "$(get "$i" runtime_port)" ] || die "Node $i GR MEMBER_PORT=$mp differs from runtime port $(get "$i" runtime_port)"
        stored_mh=$(get "$i" gr_member_host)
        [ "$stored_mh" = "$mh" ] || die "Node $i GR MEMBER_HOST changed since discover ($stored_mh -> $mh); rediscover with a new work root"
        case $mh in localhost|127.0.0.1|::1)
            # Loopback is acceptable only when all registered instances are on the same host and AdminAPI is local-only.
            allsame=yes; rh=$(get 1 runtime_host)
            for j in $(ids); do [ "$(get "$j" runtime_host)" = "$rh" ] || allsame=no; done
            [ "$allsame" = yes ] || die "Node $i advertises loopback ($mh) in a distributed topology; fix report_host/GR member address before InnoDB Cluster adoption"
            ;;
        esac
    done
}
sql_precheck(){
    require_discovery_schema
    [ -f "$ROOT/meta/complete" ] || die 'Run discover first'
    assert_identity
    topology_address_check
    identity_uniqueness_guard
    for i in $(ids); do base_sql_precheck "$i"; done
    writeability_persistence_check
    cross_node_variable_guard
    members=$(grmembers 1); printf '%s\n' "$members" > "$ROOT/gr_members.before"
    total=$(printf '%s\n' "$members" | awk 'NF{n++} END{print n+0}'); online=$(printf '%s\n' "$members" | awk '$4=="ONLINE"{n++} END{print n+0}')
    if [ "$total" -gt 0 ]; then
        [ "$online" -eq "$total" ] || die "Existing GR is not fully ONLINE ($online/$total)"
        [ "$total" -eq "$(get meta count)" ] || die 'Registered node count does not match GR member count'
        mode=$(gr_role_guard 1); [ "$mode" = "$(get meta gr_mode)" ] || die "GR mode changed since discover: $(get meta gr_mode) -> $mode; rediscover with a new work root"
        all_node_gr_consistency_guard
        gtid_convergence_guard
        gr_writeability_guard
        multi_primary_schema_guard
    fi
    event_precheck
    for i in $(ids); do gtids "$i" > "$ROOT/node_${i}.gtid.before"; done
    : > "$ROOT/meta/sql_prechecked"
    log "SQL PRECHECK PASSED: members=$total ONLINE=$online mode=$(get meta gr_mode). No configuration was changed."
}
show_existing_admin_candidates(){
    out="$ROOT/existing_admin_candidates.txt"
    accounts="$TMP/existing_accounts.tsv"
    : > "$out"
    sql 1 "SELECT User,Host FROM mysql.user WHERE User<>'' AND User NOT IN ('mysql.infoschema','mysql.session','mysql.sys') ORDER BY User,Host;" > "$accounts"
    log 'Existing AdminAPI account candidates:'
    log '  Candidate means the same user@host exists on every registered node.'
    log '  Listed privileges are informational only; roles and release-specific AdminAPI requirements can change effective privileges.'
    log '  Final acceptance always requires the supplied password plus dba.checkInstanceConfiguration() on every node.'
    found=0
    tab=$(printf '\t')
    while IFS="$tab" read -r u h; do
        [ -n "$u" ] && [ -n "$h" ] || continue
        all=yes
        for i in $(ids); do
            c=$(sql "$i" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$u")' AND Host='$(q "$h")';")
            [ "$c" -eq 1 ] || { all=no; break; }
        done
        [ "$all" = yes ] || continue
        found=$((found+1))
        printf '  %s@%s\n' "$u" "$h" >> "$out"
        gp=$(sql 1 "SELECT COALESCE(GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ','),'') FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=CONCAT(CHAR(39),'$(q "$u")',CHAR(39),'@',CHAR(39),'$(q "$h")',CHAR(39));")
        dp=$(sql 1 "SELECT COALESCE(GROUP_CONCAT(PRIV ORDER BY PRIV SEPARATOR ','),'') FROM mysql.global_grants WHERE USER='$(q "$u")' AND HOST='$(q "$h")';" 2>/dev/null || printf '')
        [ -n "$gp" ] || gp='(none shown; effective privileges may be role-based)'
        printf '    global/static: %s\n' "$gp" >> "$out"
        [ -z "$dp" ] || printf '    global/dynamic: %s\n' "$dp" >> "$out"
    done < "$accounts"
    [ "$found" -gt 0 ] || printf '  (no identical user@host account exists on every registered node)\n' >> "$out"
    cat "$out" >&2
}

recommended_admin_host_pattern(){
    require_discovery_schema
    [ -f "$ROOT/meta/admin_host_candidate" ] || { printf ''; return 0; }
    get meta admin_host_candidate
}


common_hosts_for_user(){
    u=$1
    first="$TMP/common_user_hosts.1"
    sql 1 "SELECT Host FROM mysql.user WHERE User='$(q "$u")' ORDER BY Host;" > "$first"
    cp "$first" "$TMP/common_user_hosts"
    for j in $(ids); do
        [ "$j" -eq 1 ] && continue
        sql "$j" "SELECT Host FROM mysql.user WHERE User='$(q "$u")' ORDER BY Host;" > "$TMP/common_user_hosts.$j"
        awk 'NR==FNR{a[$0]=1;next} a[$0]' "$TMP/common_user_hosts.$j" "$TMP/common_user_hosts" > "$TMP/common_user_hosts.next"
        mv "$TMP/common_user_hosts.next" "$TMP/common_user_hosts"
    done
    cat "$TMP/common_user_hosts"
}

password_policy_report(){
    i=$1
    log "Current validate_password policy on node $i:"
    sql "$i" "SHOW VARIABLES LIKE 'validate_password%';" 2>/dev/null | sed 's/^/  /' >&2 || log '  validate_password variables are unavailable on this server.'
    log 'The script does not weaken or change password policy.'
}
admin_account_presence_count(){
    u=$1; h=$2; count=0
    for j in $(ids); do
        c=$(sql "$j" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$u")' AND Host='$(q "$h")';" 2>/dev/null || printf '0')
        [ "$c" -gt 0 ] && count=$((count+1))
    done
    printf '%s' "$count"
}
admin_account_presence_report(){
    u=$1; h=$2; present=''; count=0
    for j in $(ids); do
        c=$(sql "$j" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$u")' AND Host='$(q "$h")';" 2>/dev/null || printf '0')
        if [ "$c" -gt 0 ]; then present="${present}${present:+ }$j"; count=$((count+1)); fi
    done
    total=$(get meta count)
    if [ "$count" -eq 0 ]; then
        log "Account state after failure: '$u'@'$h' was not created on any registered node."
    elif [ "$count" -eq "$total" ]; then
        log "Account state after failure: '$u'@'$h' exists on every registered node."
    else
        log "Account state after failure: '$u'@'$h' exists only on node(s): $present."
        log 'Partial account creation detected; automatic password retry is disabled until the account state is reviewed.'
    fi
}

configure_admin(){ require_discovery_schema;
    [ -f "$ROOT/meta/complete" ] || die 'Run discover first'
    sql_precheck
    event_ack
    assert_identity
    metadata_absence_guard

    log 'Cluster admin preparation:'
    log '  create   : create a dedicated AdminAPI account using dba.configureInstance(clusterAdmin=...).'
    log '             MySQL Shell grants only the privileges required for InnoDB Cluster administration for this version.'
    log '  existing : reuse an existing account. The script validates it and never broadens privileges automatically.'
    show_existing_admin_candidates
    prompt_block 'Cluster admin account action' 'Choose whether to create a dedicated AdminAPI account or reuse an identical existing account.' 'create | existing' 'create'; action=$(choice 'Select cluster admin action' create create existing)

    au=$(ask_explained 'Cluster admin account name' 'Dedicated MySQL account used by MySQL Shell AdminAPI.' 'icadmin | <ADMIN_USER>' 'Cluster admin user name' 'icadmin')
    case $au in ''|*[!A-Za-z0-9_.-]*) die 'Invalid cluster admin user';; esac
    common_hosts=$(common_hosts_for_user "$au")
    if [ -n "$common_hosts" ]; then
        log "Existing '$au' account Host value(s) present on every registered node:"
        printf '%s\n' "$common_hosts" | sed 's/^/  /' >&2
        first_common=$(printf '%s\n' "$common_hosts" | head -1)
        if [ "$action" = create ]; then
            prompt_block 'Existing common clusterAdmin candidate' 'An identical user@host already exists on every registered node.' 'yes | no' 'yes'; reuse=$(choice 'Reuse the existing common account?' yes yes no)
            if [ "$reuse" = yes ]; then action=existing; fi
        fi
        if [ "$action" = existing ]; then
            ah=$(ask_explained 'Existing cluster admin Host' 'The Host value attached to the already existing MySQL account on every registered node.' '<IP_ADDRESS> | <HOSTNAME> | <NETWORK_PATTERN>' 'Existing cluster admin Host' "$first_common")
            printf '%s\n' "$common_hosts" | grep -Fxq "$ah" || die "'$au'@'$ah' does not exist on every registered node"
        fi
    fi
    log 'Cluster admin Host must allow connections from every cluster member while remaining as narrow as your network permits.'
    log "Use the narrowest source-address range that covers every cluster member. A local NIC CIDR is suggested only when all current GR members advertise the same local IPv4 address. '%' is broad and requires extra confirmation."
    if [ "${action}" = existing ] && [ -n "${ah:-}" ]; then
        rec_ah=''
    else
        rec_ah=$(recommended_admin_host_pattern)
        if [ -n "$rec_ah" ]; then log "Auto-detected narrow Host candidate from the local interface network matching current GR MEMBER_HOST: $rec_ah"; fi
        ah=$(ask_explained 'Cluster admin account Host' 'Source-address scope allowed to authenticate as the clusterAdmin account.' '<IP_ADDRESS> | <HOSTNAME> | <NETWORK_PATTERN>' 'Cluster admin account Host' "$rec_ah")
    fi
    [ -n "$ah" ] || die 'Cluster admin host pattern cannot be empty'
    [ "$ah" != '%' ] || { log "WARNING: '$au'@'%' accepts authentication attempts from any source address allowed by network controls."; confirm "ALLOW-BROAD-ADMIN-HOST-$au"; }
    ap=$(secret_explained 'Cluster admin password' 'Password for the dedicated AdminAPI account; it must satisfy the active MySQL password policy.' 'Cluster admin password')
    [ -n "$ap" ] || die 'Cluster admin password cannot be empty'
    printf '%s\n' "$ap" > "$TMP/admin.pw"; chmod 600 "$TMP/admin.pw"

    case $action in
        create)
            existing_nodes=''
            existing_count=0
            for i in $(ids); do
                exists=$(sql "$i" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$au")' AND Host='$(q "$ah")';")
                if [ "$exists" -gt 0 ]; then
                    existing_count=$((existing_count+1))
                    existing_nodes="${existing_nodes}${existing_nodes:+,}$i"
                fi
            done
            total_nodes=$(get meta count)
            if [ "$existing_count" -eq "$total_nodes" ]; then
                die "'$au'@'$ah' already exists on every registered node. Re-run configure-admin and choose existing; the script will validate it without broadening privileges."
            fi
            if [ "$existing_count" -gt 0 ]; then
                die "'$au'@'$ah' exists only on node(s) $existing_nodes. Account state is inconsistent; no CREATE/ALTER/GRANT was attempted. Review the partial account state before retrying."
            fi
            log "New account requested on every member: '$au'@'$ah'"
            log 'No GRANT ALL is used. Privileges are delegated to dba.configureInstance() so the installed MySQL Shell grants the version-appropriate minimum set.'
            log 'dba.configureInstance() can change instance configuration. Existing GR state is snapshotted before/after and any unexpected topology/identity change is treated as failure.'
            state_snapshot before_configure_admin
            confirm "CREATE-CLUSTER-ADMIN-$au"
            for i in $(ids); do
                out="$ROOT/node_${i}.configure_admin.txt"
                js="$TMP/configure_admin_$i.js"
                cat > "$js" <<EOF
var opts={clusterAdmin:"'$(jsq "$au")'@'$(jsq "$ah")'",clusterAdminPassword:"$(jsq "$ap")",restart:false};
dba.configureInstance(undefined,opts);
print("IC_ADMIN_CONFIGURED=ok");
EOF
                chmod 600 "$js"
                while :; do
                    rc=0
                    if [ "$(get "$i" auth_mode)" = login-path ]; then
                        MYSQL_TEST_LOGIN_FILE="$(get "$i" login_file)" "$MYSQLSH" --login-path="$(get "$i" login_path)" --no-wizard --js -f "$js" >"$out" 2>&1 || rc=$?
                    else
                        cred "$i"; uri="$(get "$i" user)@$(get "$i" host):$(get "$i" port)"
                        cat "$TMP/$i.pw" | "$MYSQLSH" --uri "$uri" --passwords-from-stdin --js -f "$js" >"$out" 2>&1 || rc=$?
                    fi
                    [ "$rc" -eq 0 ] && break
                    cat "$out" >&2
                    if grep -Eq 'MYSQLSH 1819|does not satisfy the current policy requirements' "$out"; then
                        log 'Password rejected by the server password policy.'
                        password_policy_report "$i"
                        admin_account_presence_report "$au" "$ah"
                        present_count=$(admin_account_presence_count "$au" "$ah")
                        [ "$present_count" -eq 0 ] || die 'clusterAdmin account state changed during the failed attempt; review it before retrying.'
                        log 'Enter a new password that satisfies the policy. Only the password entry is retried; the migration does not restart.'
                        ap=$(secret 'Cluster admin password (re-enter)')
                        [ -n "$ap" ] || die 'Cluster admin password cannot be empty'
                        printf '%s\n' "$ap" > "$TMP/admin.pw"; chmod 600 "$TMP/admin.pw"
                        cat > "$js" <<EOF
var opts={clusterAdmin:"'$(jsq "$au")'@'$(jsq "$ah")'",clusterAdminPassword:"$(jsq "$ap")",restart:false};
dba.configureInstance(undefined,opts);
print("IC_ADMIN_CONFIGURED=ok");
EOF
                        chmod 600 "$js"
                        log 'Retrying clusterAdmin creation with the newly entered password.'
                        continue
                    fi
                    admin_account_presence_report "$au" "$ah"
                    die "clusterAdmin creation failed on node $i"
                done
                rm -f "$js"
            done
            state_snapshot after_configure_admin
            if [ "$(get meta gr_count)" -gt 0 ]; then snapshot_critical_equal before_configure_admin after_configure_admin; all_node_gr_consistency_guard; gr_writeability_guard; writeability_persistence_check; fi
            log 'Validating the newly created clusterAdmin with dba.checkInstanceConfiguration() on every registered node.'
            for i in $(ids); do
                uri="$au@$(admin_host_for "$i"):$(admin_port_for "$i")"
                out="$ROOT/node_${i}.new_admin_check.txt"
                if ! cat "$TMP/admin.pw" | "$MYSQLSH" --uri "$uri" --passwords-from-stdin --js --execute='var r=dba.checkInstanceConfiguration(); print("IC_CHECK_STATUS="+r.status);' >"$out" 2>&1; then
                    cat "$out" >&2
                    admin_account_presence_report "$au" "$ah"
                    die "New clusterAdmin failed AdminAPI validation on node $i. The account remains unchanged; choose a Host pattern accepted from every member before retrying."
                fi
                grep -q 'IC_CHECK_STATUS=ok' "$out" || { cat "$out" >&2; admin_account_presence_report "$au" "$ah"; die "New clusterAdmin is not accepted by AdminAPI on node $i."; }
            done
            ;;
        existing)
            log "Existing account will be reused: '$au'@'$ah'"
            log 'The script will not issue GRANT/ALTER USER for this path. Missing privileges cause a safe failure.'
            confirm "USE-EXISTING-CLUSTER-ADMIN-$au"
            put meta admin_user "$au"; put meta admin_host_pattern "$ah"
            # Validate connectivity and AdminAPI readiness using the supplied account on every node.
            for i in $(ids); do
                put "$i" admin_host "$(admin_host_for "$i")"
                out="$ROOT/node_${i}.existing_admin_check.txt"
                if ! mysqlsh_admin_exec "$i" 'var r=dba.checkInstanceConfiguration(); print("IC_CHECK_STATUS="+r.status);' "$out"; then
                    cat "$out" >&2
                    die "Existing cluster admin failed AdminAPI validation on node $i; no privileges were changed."
                fi
                grep -q 'IC_CHECK_STATUS=ok' "$out" || { cat "$out" >&2; die "Existing cluster admin is insufficient on node $i; no privileges were changed."; }
            done
            : > "$ROOT/meta/admin_configured"
            unset ap
            log 'Existing cluster admin validated successfully on all members.'
            return 0
            ;;
    esac

    put meta admin_user "$au"; put meta admin_host_pattern "$ah"; : > "$ROOT/meta/admin_configured"
    unset ap
    log 'Cluster admin prepared. Re-run precheck; subsequent AdminAPI operations use this clusterAdmin.'
}
adminapi_check(){ i=$1; out="$ROOT/node_${i}.adminapi_check.txt"; code='var r=dba.checkInstanceConfiguration(); print("IC_CHECK_STATUS="+r.status);'; mysqlsh_admin_exec "$i" "$code" "$out" || { cat "$out" >&2; die "AdminAPI check failed on node $i"; }; grep -q 'IC_CHECK_STATUS=ok' "$out" || { cat "$out" >&2; die "Node $i is not ready according to dba.checkInstanceConfiguration()"; }; }
gr_writeability_guard(){
    mode=$(get meta gr_mode)
    [ "$mode" != none ] || return 0
    members=$(grmembers 1)
    for i in $(ids); do
        uuid=$(get "$i" uuid)
        role=$(printf '%s\n' "$members" | awk -v u="$uuid" '$1==u{print $5; exit}')
        state=$(printf '%s\n' "$members" | awk -v u="$uuid" '$1==u{print $4; exit}')
        [ "$state" = ONLINE ] || die "Node $i is not ONLINE while validating GR writeability (state=$state)"
        ro=$(sql "$i" 'SELECT @@GLOBAL.read_only;')
        sro=$(sql "$i" 'SELECT @@GLOBAL.super_read_only;')
        case "$mode:$role" in
            single-primary:PRIMARY|multi-primary:PRIMARY)
                [ "$ro" = 0 ] && [ "$sro" = 0 ] || die "Node $i is GR PRIMARY but not writable (read_only=$ro super_read_only=$sro). Release/repair the source GR before InnoDB Cluster migration.";;
            single-primary:SECONDARY)
                [ "$sro" = 1 ] || die "Node $i is single-primary SECONDARY but super_read_only=$sro; repair the source GR before migration.";;
            *) die "Unexpected GR topology role: mode=$mode node=$i role=$role";;
        esac
    done
}


state_snapshot(){
    tag=$1
    mkdir -p "$ROOT/snapshots/$tag"
    for i in $(ids); do
        out="$ROOT/snapshots/$tag/node_$i.tsv"
        sql "$i" "SELECT 'server_uuid',@@server_uuid UNION ALL SELECT 'server_id',CAST(@@server_id AS CHAR) UNION ALL SELECT 'port',CAST(@@port AS CHAR) UNION ALL SELECT 'version',VERSION() UNION ALL SELECT 'gtid_executed',@@GLOBAL.gtid_executed UNION ALL SELECT 'read_only',CAST(@@GLOBAL.read_only AS CHAR) UNION ALL SELECT 'super_read_only',CAST(@@GLOBAL.super_read_only AS CHAR) UNION ALL SELECT 'event_scheduler',@@GLOBAL.event_scheduler UNION ALL SELECT 'lower_case_table_names',CAST(@@GLOBAL.lower_case_table_names AS CHAR) UNION ALL SELECT 'gr_group_name',COALESCE(@@GLOBAL.group_replication_group_name,'') UNION ALL SELECT 'gr_single_primary',CAST(@@GLOBAL.group_replication_single_primary_mode AS CHAR) UNION ALL SELECT 'gr_local_address',COALESCE(@@GLOBAL.group_replication_local_address,'') UNION ALL SELECT 'gr_group_seeds',COALESCE(@@GLOBAL.group_replication_group_seeds,'');" > "$out"
        sql "$i" "SHOW VARIABLES LIKE 'group_replication_communication_stack';" >> "$out"
        sql "$i" "SHOW VARIABLES LIKE 'group_replication_enforce_update_everywhere_checks';" >> "$out"
        sql "$i" "SHOW VARIABLES LIKE 'group_replication_tls_source';" >> "$out"
    done
    grmembers 1 > "$ROOT/snapshots/$tag/gr_members.tsv"
}

snapshot_critical_equal(){
    before=$1; after=$2
    for i in $(ids); do
        b="$ROOT/snapshots/$before/node_$i.tsv"; a="$ROOT/snapshots/$after/node_$i.tsv"
        [ -f "$b" ] && [ -f "$a" ] || die "Missing state snapshot for node $i ($before/$after)"
        # Account creation/config validation must never alter these existing-GR identity/topology fields.
        for k in server_uuid server_id port read_only super_read_only event_scheduler lower_case_table_names gr_group_name gr_single_primary gr_local_address gr_group_seeds; do
            bv=$(awk -F '\t' -v k="$k" '$1==k{print substr($0,index($0,"\t")+1); exit}' "$b")
            av=$(awk -F '\t' -v k="$k" '$1==k{print substr($0,index($0,"\t")+1); exit}' "$a")
            [ "$bv" = "$av" ] || die "Unexpected node $i state change during administrative preparation: $k: '$bv' -> '$av'"
        done
    done
    cmp "$ROOT/snapshots/$before/gr_members.tsv" "$ROOT/snapshots/$after/gr_members.tsv" >/dev/null 2>&1 || {
        diff -u "$ROOT/snapshots/$before/gr_members.tsv" "$ROOT/snapshots/$after/gr_members.tsv" >&2 || :
        die 'Group Replication membership/roles changed during administrative preparation.'
    }
}

gtid_convergence_guard(){
    # Online-safe check: capture a group baseline, wait every member to execute it,
    # then reject GTIDs that are not present in the group reference. This avoids
    # false failures while legitimate transactions continue during precheck.
    baseline=$(gtids 1)
    for i in $(ids); do
        reached=$(sql "$i" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(q "$baseline")',30);")
        [ "$reached" = 0 ] || die "Node $i did not execute the baseline GTID set within 30 seconds. Adoption is blocked."
    done
    # Refresh reference after all members reached the baseline. Repeat a few times
    # so concurrent multi-primary commits have time to become visible everywhere.
    round=1
    while [ "$round" -le 3 ]; do
        ref=$(gtids 1)
        clean=yes
        for i in $(ids); do
            cur=$(gtids "$i")
            extra=$(sql 1 "SELECT GTID_SUBTRACT('$(q "$cur")','$(q "$ref")');")
            if [ -n "$extra" ]; then clean=no; break; fi
        done
        [ "$clean" = yes ] && { printf '%s\n' "$ref" > "$ROOT/gtid_group_reference.txt"; return 0; }
        for i in $(ids); do sql "$i" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(q "$ref")',10);" >/dev/null || :; done
        round=$((round+1))
    done
    die 'GTID convergence/errant-GTID check did not stabilize. Quiesce writes or inspect GTID sets; this script never resets or rewrites GTIDs.'
}

strict_exact_gtid_guard(){
    ref=$(gtids 1)
    for i in $(ids); do
        cur=$(gtids "$i")
        a=$(sql 1 "SELECT GTID_SUBSET('$(q "$ref")','$(q "$cur")');")
        b=$(sql 1 "SELECT GTID_SUBSET('$(q "$cur")','$(q "$ref")');")
        [ "$a" = 1 ] && [ "$b" = 1 ] || die "Node $i GTID set is not exactly equal to node 1. Strict validation requires application writes to be quiesced."
    done
}

all_node_gr_consistency_guard(){
    ref="$TMP/gr_ref.tsv"
    grmembers 1 > "$ref"
    ref_group=$(sql 1 'SELECT @@GLOBAL.group_replication_group_name;')
    ref_mode=$(gr_mode 1)
    for i in $(ids); do
        cur="$TMP/gr_$i.tsv"; grmembers "$i" > "$cur"
        cmp "$ref" "$cur" >/dev/null 2>&1 || { diff -u "$ref" "$cur" >&2 || :; die "Node $i sees a different Group Replication membership/role view."; }
        [ "$(sql "$i" 'SELECT @@GLOBAL.group_replication_group_name;')" = "$ref_group" ] || die "Node $i group_replication_group_name differs from node 1"
        [ "$(gr_mode "$i")" = "$ref_mode" ] || die "Node $i primary mode differs from node 1"
    done
}

identity_uniqueness_guard(){
    : > "$TMP/uuids"; : > "$TMP/server_ids"; : > "$TMP/endpoints"
    for i in $(ids); do
        sql "$i" 'SELECT @@server_uuid;' >> "$TMP/uuids"
        sql "$i" 'SELECT @@server_id;' >> "$TMP/server_ids"
        printf '%s:%s\n' "$(admin_host_for "$i")" "$(admin_port_for "$i")" >> "$TMP/endpoints"
    done
    [ "$(sort "$TMP/uuids" | uniq | wc -l | tr -d ' ')" = "$(get meta count)" ] || die 'Duplicate server_uuid detected among registered members'
    [ "$(sort "$TMP/server_ids" | uniq | wc -l | tr -d ' ')" = "$(get meta count)" ] || die 'Duplicate server_id detected among registered members'
    [ "$(sort "$TMP/endpoints" | uniq | wc -l | tr -d ' ')" = "$(get meta count)" ] || die 'Duplicate AdminAPI host:port endpoint detected among registered members'
}

cross_node_variable_guard(){
    ref_lctn=$(sql 1 'SELECT @@GLOBAL.lower_case_table_names;')
    for i in $(ids); do
        [ "$(sql "$i" 'SELECT @@GLOBAL.lower_case_table_names;')" = "$ref_lctn" ] || die "Node $i lower_case_table_names differs from node 1"
        tls_src=$(sql "$i" "SHOW VARIABLES LIKE 'group_replication_tls_source';" | awk -F '\t' 'NR==1{print $2}')
        [ -z "$tls_src" ] || [ "$(printf '%s' "$tls_src" | tr '[:upper:]' '[:lower:]')" != mysql_admin ] || die "Node $i group_replication_tls_source=mysql_admin is not supported for InnoDB Cluster adoption; review TLS configuration first."
    done
    if [ "$(get meta gr_mode)" = multi-primary ]; then expected=ON; else expected=OFF; fi
    for i in $(ids); do
        euc=$(sql "$i" "SHOW VARIABLES LIKE 'group_replication_enforce_update_everywhere_checks';" | awk -F '\t' 'NR==1{print $2}')
        [ -z "$euc" ] || [ "$euc" = "$expected" ] || die "Node $i group_replication_enforce_update_everywhere_checks=$euc but $expected is expected for $(get meta gr_mode)."
    done
}

writeability_persistence_check(){
    for i in $(ids); do
        pv="$ROOT/node_${i}.read_only.persisted.tsv"
        vi="$ROOT/node_${i}.read_only.variables_info.tsv"
        sql "$i" "SELECT VARIABLE_NAME,VARIABLE_VALUE FROM performance_schema.persisted_variables WHERE VARIABLE_NAME IN ('read_only','super_read_only') ORDER BY VARIABLE_NAME;" > "$pv"
        sql "$i" "SELECT VARIABLE_NAME,VARIABLE_SOURCE,COALESCE(VARIABLE_PATH,''),COALESCE(CAST(SET_TIME AS CHAR),''),COALESCE(SET_USER,''),COALESCE(SET_HOST,'') FROM performance_schema.variables_info WHERE VARIABLE_NAME IN ('read_only','super_read_only') ORDER BY VARIABLE_NAME;" > "$vi"
        if [ -s "$pv" ]; then
            cat "$pv" >&2
            die "Node $i has persisted read_only/super_read_only override(s). Remove/review them before InnoDB Cluster migration; the script never RESET PERSIST automatically."
        fi
        bad=$(awk -F '\t' '$2 != "DYNAMIC" && $2 != "COMPILED" {print}' "$vi")
        if [ -n "$bad" ]; then
            printf '%s\n' "$bad" >&2
            die "Node $i read_only/super_read_only is sourced from startup/static configuration and can override AdminAPI role-based writeability after restart."
        fi
    done
}

multi_primary_schema_guard(){
    [ "$(get meta gr_mode)" = multi-primary ] || return 0
    iso=$(sql 1 'SELECT @@GLOBAL.transaction_isolation;')
    log "Multi-primary transaction_isolation=$iso. MySQL recommends READ-COMMITTED unless the application relies on REPEATABLE-READ semantics. This is advisory; the script does not change it."
    for i in 1; do
        out="$ROOT/multi_primary_cascade_fk.tsv"
        sql "$i" "SELECT CONSTRAINT_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,REFERENCED_TABLE_NAME,UPDATE_RULE,DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') AND (UPDATE_RULE='CASCADE' OR DELETE_RULE='CASCADE') ORDER BY CONSTRAINT_SCHEMA,TABLE_NAME,CONSTRAINT_NAME;" > "$out"
        [ ! -s "$out" ] || { cat "$out" >&2; die 'Multi-primary GR has cascading foreign keys. Group Replication can reject transactions using cascading constraints; review/resolve before InnoDB Cluster adoption.'; }
    done
}

event_precheck(){
    mode=$(get meta gr_mode)
    [ "$mode" != none ] || mode=single-primary
    review=no
    for i in $(ids); do
        es=$(sql "$i" 'SELECT @@GLOBAL.event_scheduler;')
        ec=$(sql "$i" "SELECT COUNT(*) FROM information_schema.EVENTS;")
        out="$ROOT/node_${i}.events.tsv"
        sql "$i" "SELECT EVENT_SCHEMA,EVENT_NAME,DEFINER,STATUS,EVENT_TYPE,COALESCE(EXECUTE_AT,''),COALESCE(INTERVAL_VALUE,''),COALESCE(INTERVAL_FIELD,''),ON_COMPLETION FROM information_schema.EVENTS ORDER BY EVENT_SCHEMA,EVENT_NAME;" > "$out"
        log "Node $i Event Scheduler=$es, defined events=$ec"
        if [ "$ec" -gt 0 ]; then
            missing_definers=$(sql "$i" "SELECT COUNT(*) FROM information_schema.EVENTS e LEFT JOIN mysql.user u ON u.User=SUBSTRING_INDEX(e.DEFINER,'@',1) AND u.Host=SUBSTRING_INDEX(e.DEFINER,'@',-1) WHERE u.User IS NULL;")
            if [ "$missing_definers" -gt 0 ]; then
                sql "$i" "SELECT e.EVENT_SCHEMA,e.EVENT_NAME,e.DEFINER FROM information_schema.EVENTS e LEFT JOIN mysql.user u ON u.User=SUBSTRING_INDEX(e.DEFINER,'@',1) AND u.Host=SUBSTRING_INDEX(e.DEFINER,'@',-1) WHERE u.User IS NULL ORDER BY e.EVENT_SCHEMA,e.EVENT_NAME;" >&2
                die "Node $i has scheduled EVENT object(s) whose DEFINER account does not exist. Repair DEFINER/account consistency before cluster migration."
            fi
            review=yes
            cat "$out" >&2
            if [ "$mode" = multi-primary ] && [ "$es" = ON ]; then
                die "Node $i has Event Scheduler ON with defined events in multi-primary mode. Review execution ownership before migration; the script will not change event_scheduler automatically."
            fi
        fi
    done
    if [ "$review" = yes ]; then
        log 'Scheduled EVENT objects exist. InnoDB Cluster does not automatically enforce single execution ownership for application events.'
        log 'Review DEFINER accounts, ENABLED/DISABLED state, failover behavior, and whether events may execute on more than one writable member.'
        : > "$ROOT/meta/event_review_required"
    else
        rm -f "$ROOT/meta/event_review_required" "$ROOT/meta/event_review_ack" 2>/dev/null || :
    fi
}
event_ack(){
    [ -f "$ROOT/meta/event_review_required" ] || return 0
    [ -f "$ROOT/meta/event_review_ack" ] && return 0
    log 'EVENT REVIEW REQUIRED before any create/adopt mutation.'
    confirm 'EVENT-POLICY-REVIEWED'
    : > "$ROOT/meta/event_review_ack"
}
mutation_safety_gate(){
    [ -f "$ROOT/meta/prechecked" ] || die 'Run precheck first'
    metadata_absence_guard
    assert_identity
    event_ack
    # Re-run non-mutating topology checks immediately before metadata/config mutation.
    sql_precheck
    admin_ready || die 'Dedicated clusterAdmin is not configured'
    for i in $(ids); do adminapi_check "$i"; done
    state_snapshot pre_mutation
}
precheck(){
    require_discovery_schema
    [ -f "$ROOT/meta/sql_prechecked" ] || sql_precheck
    admin_ready || die 'Dedicated clusterAdmin is not registered. Run configure-admin, then precheck again.'
    assert_identity
    for i in $(ids); do adminapi_check "$i"; done
    mcount=$(sql 1 "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mysql_innodb_cluster_metadata';")
    [ "$mcount" -eq 0 ] || log 'NOTICE: InnoDB Cluster metadata already exists; create/adopt will refuse and validate/status should be used.'
    : > "$ROOT/meta/prechecked"
    log "PRECHECK PASSED: SQL checks + dba.checkInstanceConfiguration() as $(get meta admin_user)."
}
plan(){ require_discovery_schema; [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; assert_identity; show_capabilities >/dev/null; gr=$(get meta gr_count); mode=$(get meta gr_mode); metadata=$(get meta metadata); log '--- InnoDB Cluster migration plan ---'; log "Instances: $(get meta count)"; log "Version policy: $(get meta version_policy)"; log "Existing GR members: $gr"; log "Existing GR mode: $mode"; log "Existing InnoDB Cluster metadata: $metadata"; if [ "$gr" -gt 0 ]; then log 'Recommended action: adopt'; log 'adoptFromGR preserves the existing single-primary or multi-primary topology.'; log 'Topology mode is not selectable during safe adoption; change topology later only with Cluster.switchTo* APIs if explicitly desired.'; else log 'Recommended action: create'; log 'Create options are selected interactively: single/multi-primary, communication stack when supported, member SSL mode, clone policy, and addInstance recovery method.'; fi; log "Capabilities: $ROOT/capabilities.txt"; }
create_options(){
    opts=''
    log 'Primary topology:'
    log '  single-primary (recommended): one R/W primary, secondaries R/O'
    if has_create_option multiPrimary; then
        log '  multi-primary (advanced): multiple R/W members; application conflict/cascading-FK behavior must be reviewed'
        prompt_block 'Primary topology' 'Controls which members are writable after cluster creation.' 'single | multi' 'single'; pm=$(choice 'Select primary topology' single single multi)
        [ "$pm" = single ] || opts="$opts, multiPrimary:true"
    else
        log '  multi-primary is not exposed by this mysqlsh createCluster capability; single-primary only.'
    fi
    if has_create_option communicationStack; then
        log 'Communication stack:'
        log '  XCOM: Group Replication XCom stack; requires reachable GR local addresses/allowlist'
        log '  MYSQL: MySQL communication stack when supported by this server/mysqlsh combination'
        prompt_block 'Group Replication communication stack' 'Transport used by Group Replication members for internal communication.' 'XCOM | MYSQL' 'XCOM'; cs=$(choice 'Select communication stack' XCOM XCOM MYSQL)
        opts="$opts, communicationStack:\"$cs\""
        if [ "$cs" = XCOM ] && has_create_option ipAllowlist; then
            log 'ipAllowlist limits XCom peers. AUTOMATIC lets AdminAPI derive private-network entries; explicit CIDRs are safer when known.'
            al=$(ask_explained 'XCom IP allowlist' 'Source networks allowed to participate in XCom Group Replication communication.' 'AUTOMATIC | <CIDR> | <CIDR>,<CIDR>' 'XCom ipAllowlist' 'AUTOMATIC')
            opts="$opts, ipAllowlist:\"$(jsq "$al")\""
        fi
    fi
    if has_create_option localAddress; then
        log 'Seed localAddress is the internal Group Replication communication endpoint, not the application SQL endpoint.'
        la=$(ask_explained 'Seed Group Replication localAddress' 'Internal host:port endpoint used by the seed for Group Replication member communication.' '<HOSTNAME>:<PORT> | <IP_ADDRESS>:<PORT>' 'Seed localAddress (blank = AdminAPI default)' '')
        [ -z "$la" ] || opts="$opts, localAddress:\"$(jsq "$la")\""
    fi
    if has_create_option memberSslMode; then
        log 'memberSslMode: AUTO uses SSL when available; REQUIRED requires encryption; VERIFY_CA/VERIFY_IDENTITY additionally verify certificates.'
        prompt_block 'Member SSL mode' 'TLS verification policy for Group Replication member connections.' 'AUTO | REQUIRED | VERIFY_CA | VERIFY_IDENTITY | DISABLED' 'AUTO'; sm=$(choice 'Select member SSL mode' AUTO AUTO REQUIRED VERIFY_CA VERIFY_IDENTITY DISABLED)
        opts="$opts, memberSslMode:\"$sm\""
    fi
    if has_create_option disableClone; then
        log 'Clone can efficiently provision a member but replaces the recipient dataset. Default leaves clone available; recovery is still selected before each addInstance.'
        prompt_block 'Cluster Clone policy' 'Controls whether MySQL Clone may be used for provisioning members.' 'no | yes' 'no'; dc=$(choice 'Disable Clone at cluster level?' no no yes)
        [ "$dc" = no ] || opts="$opts, disableClone:true"
    fi
    printf '%s' "${opts#, }"
}
add_recovery_method(){
    if has_add_option recoveryMethod; then
        log 'Instance recovery method:'
        log '  auto: AdminAPI chooses when recovery is unambiguous'
        log '  incremental: requires sufficient GTID history'
        log '  clone: replaces recipient data; requires an additional destructive confirmation'
        prompt_block 'Recovery method for added instances' 'Method used to provision/synchronize a member when it is added.' 'auto | incremental | clone' 'auto'; choice 'Select recovery method' auto auto incremental clone
    else
        log 'This mysqlsh does not expose addInstance recoveryMethod; AdminAPI default behavior will be used.'
        printf '__omit__'
    fi
}
configure(){ require_discovery_schema; [ -f "$ROOT/meta/prechecked" ] || die 'Run precheck first'; assert_identity; log 'configure may persist settings. restart:false is forced; if a restart is required, the script stops and the user performs/reviews it separately. It is never run implicitly by precheck/all.'; confirm CONFIGURE-INSTANCES; for i in $(ids); do out="$ROOT/node_${i}.configure.txt"; mysqlsh_admin_exec "$i" 'dba.configureInstance({restart:false});' "$out" || { cat "$out" >&2; die "configureInstance failed on node $i"; }; done; : > "$ROOT/meta/configured"; log 'configureInstance completed. Re-run precheck before create/adopt.'; }
cluster_name(){ n=$(ask_explained 'InnoDB Cluster name' 'Logical name stored in InnoDB Cluster metadata.' '<CLUSTER_NAME>' 'InnoDB Cluster name' 'prodCluster'); case $n in ''|*[!A-Za-z0-9_.-]*) die 'Cluster name may contain only alphanumeric, _, . and -';; esac; [ "${#n}" -le 63 ] || die 'Cluster name exceeds 63 characters'; printf '%s' "$n"; }
create(){ require_discovery_schema; mutation_safety_gate; meta_exists 1 && die 'InnoDB Cluster metadata already exists'; total=$(grmembers 1 | awk 'NF{n++} END{print n+0}'); [ "$total" -eq 0 ] || die 'Seed belongs to Group Replication. Use adopt; create never performs implicit adoption.'; name=$(cluster_name); opts=$(create_options); log "Will create new InnoDB Cluster '$name' using node 1 as seed."; log "Selected options: ${opts:-AdminAPI safe defaults}"; log 'No force:true option is ever used.'; confirm "CREATE-$name"; if [ -n "$opts" ]; then code="var c=dba.createCluster(\"$(jsq "$name")\", {$opts}); print('IC_CREATED='+c.name);"; else code="var c=dba.createCluster(\"$(jsq "$name")\"); print('IC_CREATED='+c.name);"; fi; out="$ROOT/create.txt"; mysqlsh_admin_exec 1 "$code" "$out" || { cat "$out" >&2; die 'createCluster failed'; }; put meta cluster_name "$name"; : > "$ROOT/meta/created"; n=2; while [ "$n" -le "$(get meta count)" ]; do method=$(add_recovery_method); log "About to add node $n using recoveryMethod=$method. Existing data on the target can be replaced if clone is selected."; if [ "$method" = clone ]; then log "WARNING: clone replaces the recipient dataset on node $n."; confirm "CLONE-WILL-REPLACE-NODE-$n"; fi; confirm "ADD-NODE-$n"; uri="$(get meta admin_user)@$(admin_host_for "$n"):$(admin_port_for "$n")"; addopts=''; [ "$method" = __omit__ ] || addopts="recoveryMethod:\"$method\""; if has_add_option localAddress; then log "Node $n localAddress is its internal Group Replication communication endpoint."; la=$(ask_explained "Node $n Group Replication localAddress" 'Internal host:port endpoint used by this member for Group Replication communication.' '<HOSTNAME>:<PORT> | <IP_ADDRESS>:<PORT>' "Node $n localAddress (blank = AdminAPI default)" ''); [ -z "$la" ] || { [ -z "$addopts" ] || addopts="$addopts, "; addopts="$addopts localAddress:\"$(jsq "$la")\""; }; fi; if [ -n "$addopts" ]; then code="var c=dba.getCluster(\"$(jsq "$name")\"); c.addInstance(\"$(jsq "$uri")\", {$addopts}); print(JSON.stringify(c.status({extended:1})));"; else code="var c=dba.getCluster(\"$(jsq "$name")\"); c.addInstance(\"$(jsq "$uri")\"); print(JSON.stringify(c.status({extended:1})));"; fi; mysqlsh_admin_exec 1 "$code" "$ROOT/add_${n}.txt" || { cat "$ROOT/add_${n}.txt" >&2; die "addInstance failed for node $n"; }; n=$((n+1)); done; validate; }

adopt(){ require_discovery_schema; mutation_safety_gate; meta_exists 1 && die 'InnoDB Cluster metadata already exists; refusing to overwrite/adopt again'; members=$(grmembers 1); total=$(printf '%s\n' "$members" | awk 'NF{n++} END{print n+0}'); online=$(printf '%s\n' "$members" | awk '$4=="ONLINE"{n++} END{print n+0}'); [ "$total" -ge 3 ] || die 'Existing GR must have at least 3 members for this production-oriented adoption workflow'; [ "$online" -eq "$total" ] || die 'All GR members must be ONLINE before adoption'; [ "$total" -eq "$(get meta count)" ] || die 'Registered instances do not exactly match GR membership'; # membership UUID exact check
for i in $(ids); do grep -q "^$(get "$i" uuid)[[:space:]]" "$ROOT/gr_members.before" || die "Node $i UUID was not in prechecked GR membership"; done
name=$(cluster_name); mode=$(gr_role_guard 1); [ "$mode" = "$(get meta gr_mode)" ] || die 'GR topology mode changed after precheck; rerun discover/precheck with a new work root.'; log "Will adopt existing $mode GR ($total ONLINE members) as InnoDB Cluster '$name'."; log 'The existing single-primary/multi-primary mode will be preserved. This script does not switch topology during adoption.'; log 'This creates InnoDB Cluster metadata and transfers management responsibility to AdminAPI; it does not rebuild the GR group.'; confirm "ADOPT-$name"; code="var c=dba.createCluster(\"$(jsq "$name")\", {adoptFromGR:true}); print('IC_ADOPTED='+c.name); print(JSON.stringify(c.status({extended:1})));"; out="$ROOT/adopt.txt"; mysqlsh_admin_exec 1 "$code" "$out" || { cat "$out" >&2; die 'adoptFromGR failed'; }; post_mode=$(gr_role_guard 1); [ "$post_mode" = "$mode" ] || die "URGENT: GR mode changed during adoption ($mode -> $post_mode); stop and inspect before any further action"; all_node_gr_consistency_guard; gtid_convergence_guard; state_snapshot post_adopt; cmp "$ROOT/snapshots/pre_mutation/gr_members.tsv" "$ROOT/snapshots/post_adopt/gr_members.tsv" >/dev/null 2>&1 || { diff -u "$ROOT/snapshots/pre_mutation/gr_members.tsv" "$ROOT/snapshots/post_adopt/gr_members.tsv" >&2 || :; die 'URGENT: GR membership/roles changed during adoption'; }; put meta cluster_name "$name"; put meta adopted_gr_mode "$mode"; : > "$ROOT/meta/adopted"; log "Adoption completed with topology preserved ($mode). Evidence: $out"; validate; }
validate(){ require_discovery_schema; [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; assert_identity; meta_exists 1 || die 'mysql_innodb_cluster_metadata is absent'; writeability_persistence_check; name=''; [ ! -f "$ROOT/meta/cluster_name" ] || name=$(get meta cluster_name); code='var c=dba.getCluster(); print("IC_CLUSTER_NAME="+c.name); print("IC_STATUS="+JSON.stringify(c.status({extended:2}))); print("IC_DESCRIBE="+JSON.stringify(c.describe()));'; out="$ROOT/validate.txt"; mysqlsh_admin_exec 1 "$code" "$out" || { cat "$out" >&2; die 'dba.getCluster/status failed'; }; members=$(grmembers 1); printf '%s\n' "$members" > "$ROOT/gr_members.after"; total=$(printf '%s\n' "$members" | awk 'NF{n++} END{print n+0}'); online=$(printf '%s\n' "$members" | awk '$4=="ONLINE"{n++} END{print n+0}'); [ "$online" -eq "$total" ] || die "Cluster GR members not fully ONLINE ($online/$total)"; [ "$total" -eq "$(get meta count)" ] || die 'Cluster member count changed unexpectedly'; primary=$(printf '%s\n' "$members" | awk '$5=="PRIMARY"{n++} END{print n+0}'); mode=$(gr_role_guard 1); all_node_gr_consistency_guard; gtid_convergence_guard; gr_writeability_guard; if [ -f "$ROOT/meta/adopted_gr_mode" ]; then [ "$mode" = "$(get meta adopted_gr_mode)" ] || die "Adopted GR topology changed unexpectedly: $(get meta adopted_gr_mode) -> $mode"; fi; for i in $(ids); do gtids "$i" > "$ROOT/node_${i}.gtid.after"; done; : > "$ROOT/meta/validated"; log "VALIDATION PASSED: metadata present, $online/$total ONLINE, mode=$mode primary_count=$primary. Evidence: $ROOT"; }
status(){ require_discovery_schema; [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; assert_identity; log '--- Group Replication members ---'; grmembers 1; if meta_exists 1; then out="$ROOT/status.txt"; mysqlsh_admin_exec 1 'var c=dba.getCluster(); print(JSON.stringify(c.status({extended:1}))); print(JSON.stringify(c.describe()));' "$out" || { cat "$out" >&2; return 1; }; cat "$out"; else log 'InnoDB Cluster metadata: ABSENT'; fi; }
all(){ if [ ! -f "$ROOT/meta/complete" ]; then discover; fi; sql_precheck; if admin_ready; then precheck; else log 'ALL stopped: run configure-admin explicitly, then precheck. No account/configuration mutation is implicit.'; fi; }
case $STEP in help|-h|--help) help;; discover) discover;; capabilities) show_capabilities;; sql-precheck) sql_precheck;; strict-gtid) [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; assert_identity; strict_exact_gtid_guard; log 'STRICT GTID CHECK PASSED';; configure-admin) configure_admin;; precheck) precheck;; configure) configure;; plan) plan;; create) create;; adopt) adopt;; validate) validate;; status) status;; all) all;; *) help; die "Unknown command: $STEP";; esac
