#!/bin/sh
# mysql_innodb_cluster_migrate.sh v1.0.44
# POSIX sh. Oracle MySQL GA 8.0+; runtime AdminAPI capability detection. Requires preinstalled mysql/mysqlsh; never installs packages.
# Automation for prepared MySQL instances / existing Group Replication -> InnoDB Cluster.
set -eu
umask 077
VERSION=1.0.44
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
# - Error handling must not infer causes beyond exact server/mysqlsh output. Emit objective state and ERROR_CODE values only.
prompt_block(){
    title=$1; meaning=$2; example=$3; detected=${4-}
    printf '\n%s\n' "$title" >&2
    [ -z "$meaning" ] || printf '  Meaning : %s\n' "$meaning" >&2
    [ -z "$example" ] || printf '  Example : %s\n' "$example" >&2
    [ -z "$detected" ] || printf '  Default : %s\n' "$detected" >&2
}
ask(){ p=$1; d=${2-}; printf '%s%s: ' "$p" "${d:+ [$d]}" >&2; IFS= read -r a || return 1; printf '%s' "${a:-$d}"; }
ask_explained(){ title=$1; meaning=$2; example=$3; prompt=$4; def=${5-}; prompt_block "$title" "$meaning" "$example" "$def"; ask "$prompt" "$def"; }
secret(){
    printf '%s: ' "$1" >&2
    if [ -t 0 ]; then
        o=$(stty -g) || return 1
        trap 'stty "$o" 2>/dev/null || :; exit 130' 1 2 15
        stty -echo
        IFS= read -r a; read_rc=$?
        stty "$o" 2>/dev/null || :
        trap cleanup 1 2 15
        [ "$read_rc" -eq 0 ] || return "$read_rc"
    else
        IFS= read -r a || return 1
    fi
    printf '\n' >&2
    printf '%s' "$a"
}
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
next_step(){
    [ "${SUPPRESS_NEXT_STEP:-no}" = yes ] && return 0
    step=$1
    printf '\nNext step:\n  sh %s %s\n' "$0" "$step" >&2
}

cleanup(){
    saved_rc=$?
    if [ "$#" -gt 0 ]; then rc=$1; else rc=$saved_rc; fi
    trap - 0 1 2 15
    [ -z "${TMP:-}" ] || rm -rf "$TMP"
    [ -z "${LOCK:-}" ] || rmdir "$LOCK" 2>/dev/null || :
    exit "$rc"
}
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
Usage: sh $0 discover|capabilities|sql-precheck|strict-gtid|gr-restart-precheck|configure-admin|precheck|configure|plan|create|adopt|validate|status|all
  discover   Register 1..9 instances and detect GR / metadata state; read-only
  capabilities Show mysqlsh AdminAPI options supported by the installed version; read-only
  sql-precheck Run SQL/GR/topology safety checks only; read-only
  strict-gtid Require moment-in-time exact GTID equality; use with application writes quiesced
  gr-restart-precheck Read-only full-outage GR check; identifies GTID-superset bootstrap candidate(s) but never starts/bootstraps GR
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
cred(){ i=$1; [ -f "$TMP/$i.pw" ] && return 0; mode=$(get "$i" auth_mode); if [ "$mode" = login-path ]; then return 0; fi; pw=$(secret_explained "Node $i bootstrap password" "Password for the selected bootstrap administrative account." "Node $i password for $(get "$i" user)"); printf '%s\n' "$pw" > "$TMP/$i.pw"; chmod 600 "$TMP/$i.pw"; }
mysql_cmd(){ i=$1; shift; if [ "$(get "$i" auth_mode)" = login-path ]; then lp=$(get "$i" login_path); lf=$(get "$i" login_file); MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" "$@"; else cred "$i"; pw=$(cat "$TMP/$i.pw"); MYSQL_PWD="$pw" "$MYSQL" -h "$(get "$i" host)" -P "$(get "$i" port)" -u "$(get "$i" user)" --protocol=TCP "$@"; fi; }
sql(){ i=$1; stmt=$2; printf '%s\n' "$stmt" | mysql_cmd "$i" --batch --raw --skip-column-names; }
admin_ready(){ [ -f "$ROOT/meta/admin_user" ]; }
admin_cred(){ [ -f "$TMP/admin.pw" ] && return 0; admin_ready || die 'Run configure-admin first'; ap=$(secret_explained "Cluster admin password" "Password for the configured clusterAdmin account." "Cluster admin password for $(get meta admin_user)"); [ -n "$ap" ] || die 'Cluster admin password cannot be empty'; printf '%s\n' "$ap" > "$TMP/admin.pw"; chmod 600 "$TMP/admin.pw"; }
admin_host_for(){ i=$1; if [ -f "$ROOT/$i/admin_host" ]; then get "$i" admin_host; else get "$i" connect_host; fi; }
admin_port_for(){ i=$1; get "$i" runtime_port; }
mysqlsh_admin_exec(){ i=$1; code=$2; out=$3; admin_cred; uri="$(get meta admin_user)@$(admin_host_for "$i"):$(admin_port_for "$i")"; cat "$TMP/admin.pw" | "$MYSQLSH" --mysql --uri "$uri" --passwords-from-stdin --js --execute="$code" >"$out" 2>&1; }
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
gr_configured(){
    i=$1
    gn=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_group_name,'');")
    la=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_local_address,'');")
    ch=$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME IN ('group_replication_applier','group_replication_recovery');")
    [ -n "$gn" ] && [ -n "$la" ] && [ "$ch" -gt 0 ]
}
detect_gr_state(){
    configured=0; active_ref=0; active_count=0; ref_group=''; ref_mode=''; locals="$TMP/gr_local_addresses"
    : > "$locals"
    for i in $(ids); do
        gi=$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE<>'OFFLINE';")
        if [ "$gi" -gt "$active_count" ]; then active_count=$gi; active_ref=$i; fi
        if gr_configured "$i"; then
            configured=$((configured+1))
            gn=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_group_name,'');")
            gm=$(gr_mode "$i")
            la=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_local_address,'');")
            [ -z "$ref_group" ] && ref_group=$gn
            [ -z "$ref_mode" ] && ref_mode=$gm
            [ "$gn" = "$ref_group" ] || die "ERROR_CODE=GR_CONFIG_GROUP_NAME_MISMATCH NODE=$i"
            [ "$gm" = "$ref_mode" ] || die "ERROR_CODE=GR_CONFIG_MODE_MISMATCH NODE=$i"
            printf '%s\n' "$la" >> "$locals"
        fi
    done
    put meta gr_configured_count "$configured"
    put meta gr_reference_node "${active_ref:-0}"
    put meta gr_count "$active_count"
    put meta gr_group_name "$ref_group"
    if [ "$configured" -gt 1 ]; then
        unique_locals=$(sort "$locals" | uniq | awk 'END{print NR+0}')
        [ "$unique_locals" -eq "$configured" ] || die 'ERROR_CODE=DUPLICATE_GR_LOCAL_ADDRESS'
    fi
    if [ "$active_count" -gt 0 ]; then
        put meta gr_state online
        [ "$active_count" -eq "$(get meta count)" ] || die "ERROR_CODE=GR_MEMBER_COUNT_MISMATCH REGISTERED=$(get meta count) GR_MEMBERS=$active_count"
        put meta gr_mode "$(gr_role_guard "$active_ref")"
    elif [ "$configured" -eq 0 ]; then
        put meta gr_state none; put meta gr_mode none
    elif [ "$configured" -eq "$(get meta count)" ]; then
        put meta gr_state configured-offline; put meta gr_mode "$ref_mode"
    else
        put meta gr_state partial-configured; put meta gr_mode "${ref_mode:-unknown}"
    fi
}
gr_restart_precheck(){
    require_discovery_schema
    [ -f "$ROOT/meta/complete" ] || die 'Run discover first'
    assert_identity
    state=$(get meta gr_state)
    [ "$state" = configured-offline ] || die "ERROR_CODE=GR_RESTART_PRECHECK_REQUIRES_CONFIGURED_OFFLINE CURRENT=$state"
    live_configured=0; live_active=0
    for i in $(ids); do
        gi=$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE<>'OFFLINE';")
        [ "$gi" -le "$live_active" ] || live_active=$gi
        if gr_configured "$i"; then
            live_configured=$((live_configured+1))
            gn=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_group_name,'');")
            gm=$(gr_mode "$i")
            [ "$gn" = "$(get meta gr_group_name)" ] || die "ERROR_CODE=GR_STATE_CHANGED_GROUP_NAME NODE=$i REDISCOVER_REQUIRED=YES"
            [ "$gm" = "$(get meta gr_mode)" ] || die "ERROR_CODE=GR_STATE_CHANGED_MODE NODE=$i REDISCOVER_REQUIRED=YES"
        fi
    done
    [ "$live_active" -eq 0 ] || die "ERROR_CODE=GR_STATE_CHANGED_ACTIVE_MEMBERS DETECTED=$live_active REDISCOVER_REQUIRED=YES"
    [ "$live_configured" -eq "$(get meta count)" ] || die "ERROR_CODE=GR_STATE_CHANGED_CONFIGURATION CONFIGURED=$live_configured EXPECTED=$(get meta count) REDISCOVER_REQUIRED=YES"
    out="$ROOT/gr_restart_precheck.txt"; : > "$out"
    candidates=''; candidate_count=0; writable_nodes=''
    for i in $(ids); do
        bg=$(sql "$i" 'SELECT @@GLOBAL.group_replication_bootstrap_group;')
        [ "$bg" = 0 ] || die "ERROR_CODE=GR_BOOTSTRAP_FLAG_ALREADY_ON NODE=$i"
        ru=$(sql "$i" "SELECT COALESCE(USER,'') FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME='group_replication_recovery';")
        ro=$(sql "$i" 'SELECT @@GLOBAL.read_only;')
        sro=$(sql "$i" 'SELECT @@GLOBAL.super_read_only;')
        sob=$(sql "$i" 'SELECT @@GLOBAL.group_replication_start_on_boot;')
        printf 'node=%s bootstrap_group=%s start_on_boot=%s read_only=%s super_read_only=%s recovery_user=%s\n' "$i" "$bg" "$sob" "$ro" "$sro" "${ru:-'(empty)'}" >> "$out"
        if [ "$ro" != 1 ] || [ "$sro" != 1 ]; then writable_nodes="${writable_nodes}${writable_nodes:+ }$i"; fi
        cur=$(gtids "$i"); printf '%s\n' "$cur" > "$ROOT/node_${i}.gtid.offline"
    done
    if [ -n "$writable_nodes" ]; then
        cat "$out"
        die "ERROR_CODE=GR_OFFLINE_MEMBER_WRITABLE NODES=$writable_nodes Fence application writes and explicitly make offline members read-only before comparing GTIDs; this script does not change read_only/super_read_only automatically."
    fi
    for i in $(ids); do
        ci=$(cat "$ROOT/node_${i}.gtid.offline"); superset=yes
        for j in $(ids); do
            cj=$(cat "$ROOT/node_${j}.gtid.offline")
            ok=$(sql 1 "SELECT GTID_SUBSET('$(q "$cj")','$(q "$ci")');")
            [ "$ok" = 1 ] || { superset=no; break; }
        done
        if [ "$superset" = yes ]; then candidates="${candidates}${candidates:+ }$i"; candidate_count=$((candidate_count+1)); fi
    done
    [ "$candidate_count" -gt 0 ] || die 'ERROR_CODE=GR_GTID_DIVERGENCE_NO_SUPERSET_CANDIDATE'
    printf 'bootstrap_candidate_nodes=%s\n' "$candidates" >> "$out"
    cat "$out"
    if [ "$candidate_count" -eq 1 ]; then log "BOOTSTRAP_CANDIDATE_NODE=$candidates"; else log "BOOTSTRAP_CANDIDATE_NODES=$candidates (GTID-equivalent maxima)"; fi
    log 'READ_ONLY_RESULT=Use the official full-outage Group Replication restart procedure. This script does not bootstrap or START GROUP_REPLICATION automatically.'
}
detect_login_paths(){
    out="$TMP/login_path_candidates"
    : > "$out"
    command -v mysql_config_editor >/dev/null 2>&1 || return 0
    seen_files=''
    for lf in "$HOME/.mylogin.cnf" /root/.mylogin.cnf /home/*/.mylogin.cnf; do
        [ -f "$lf" ] || continue
        case " $seen_files " in *" $lf "*) continue;; esac
        seen_files="$seen_files $lf"
        dump="$TMP/loginfile.$$.txt"
        MYSQL_TEST_LOGIN_FILE="$lf" mysql_config_editor print --all >"$dump" 2>/dev/null || { rm -f "$dump"; continue; }
        sed -n 's/^\[\(.*\)\]$/\1/p' "$dump" |
        while IFS= read -r lp; do
            [ -n "$lp" ] || continue
            block="$TMP/loginblock.$$.txt"
            awk -v target="[$lp]" '
                /^\[/ { if (hit) exit; hit=($0==target); next }
                hit { print }
            ' "$dump" > "$block"
            cfg_user=$(awk -F '=' '/^[[:space:]]*user[[:space:]]*=/ {gsub(/^[[:space:]\"]+|[[:space:]\"]+$/,"",$2); print $2; exit}' "$block")
            cfg_host=$(awk -F '=' '/^[[:space:]]*host[[:space:]]*=/ {gsub(/^[[:space:]\"]+|[[:space:]\"]+$/,"",$2); print $2; exit}' "$block")
            cfg_port=$(awk -F '=' '/^[[:space:]]*port[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$block")
            cfg_socket=$(awk -F '=' '/^[[:space:]]*socket[[:space:]]*=/ {gsub(/^[[:space:]\"]+|[[:space:]\"]+$/,"",$2); print $2; exit}' "$block")
            rm -f "$block"
            if [ -n "$cfg_socket" ]; then transport=socket; elif [ -n "$cfg_host" ]; then transport=tcp; else transport=unknown; fi
            if MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" --batch --skip-column-names -e 'SELECT @@server_uuid,@@port,@@socket;' >/dev/null 2>&1; then
                info=$(MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" --batch --skip-column-names -e 'SELECT @@server_uuid,@@port,@@socket;' 2>/dev/null | head -1)
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lf" "$lp" "$info" "$transport" "$cfg_user" "$cfg_host" "${cfg_port:-0}"
            fi
        done
        rm -f "$dump"
    done | awk -F '\t' '!seen[$1 FS $2]++' > "$out"
}
select_detected_login_path(){
    i=$1
    placement=$2
    select_mode=${3:-select}
    src="$TMP/login_path_candidates"
    eligible="$TMP/login_path_eligible_$i"
    avail="$TMP/login_path_available_$i"
    : > "$eligible"
    : > "$avail"
    tab=$(printf '\t')
    while IFS="$tab" read -r lf lp uuid port sock transport cfg_user cfg_host cfg_port; do
        case $placement in
            local)
                case "$transport:$cfg_host" in
                    socket:*|tcp:localhost|tcp:127.*|tcp:::1) : ;;
                    *) continue ;;
                esac
                ;;
            remote)
                [ "$transport" = tcp ] || continue
                case $cfg_host in ''|localhost|127.*|::1) continue;; esac
                ;;
            *) die "ERROR_CODE=INVALID_NODE_PLACEMENT NODE=$i";;
        esac
        used=no
        j=1
        while [ "$j" -lt "$i" ]; do
            if [ -f "$ROOT/$j/uuid" ] && [ "$(get "$j" uuid)" = "$uuid" ]; then used=yes; break; fi
            j=$((j+1))
        done
        [ "$used" = no ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lf" "$lp" "$uuid" "$port" "$sock" "$transport" "$cfg_user" "$cfg_host" "$cfg_port" >> "$eligible"
    done < "$src"
    awk -F '\t' '
        !seen[$3]++ { order[++n]=$3; row[$3]=$0; tr[$3]=$6; next }
        $6=="tcp" && tr[$3]!="tcp" { row[$3]=$0; tr[$3]=$6 }
        END { for (x=1; x<=n; x++) print row[order[x]] }
    ' "$eligible" > "$avail"
    [ -s "$avail" ] || return 1
    [ "$select_mode" = probe ] && return 0
    prompt_block "Node $i detected MySQL login-paths" "Saved login-path credentials on this execution host for MySQL instances not yet registered." "<LOGIN_PATH> [transport=tcp|socket, file=/home/<OS_USER>/.mylogin.cnf]" ''
    n=1
    while IFS="$tab" read -r lf lp uuid port sock transport cfg_user cfg_host cfg_port; do
        if [ "$transport" = tcp ]; then endpoint="${cfg_host:-<HOST>}:${cfg_port:-<PORT>}"; else endpoint="${sock:-<SOCKET>}"; fi
        printf '  %s) %s [transport=%s, endpoint=%s, file=%s]\n' "$n" "$lp" "$transport" "$endpoint" "$lf" >&2
        n=$((n+1))
    done < "$avail"
    lines=$(awk 'END{print NR+0}' "$avail")
    if [ "$lines" -eq 1 ]; then sel=1; log "AUTO_SELECTED_LOGIN_PATH=1 NODE=$i"; else sel=$(ask "Select login-path for Node $i" ''); fi
    case $sel in ''|*[!0-9]*) die 'login-path selection must be a number';; esac
    line=$(sed -n "${sel}p" "$avail")
    [ -n "$line" ] || die "Invalid login-path selection: $sel"
    printf '%s\n' "$line"
}
register_node(){
    i=$1
    [ -f "$TMP/login_paths_scanned" ] || { detect_login_paths; : > "$TMP/login_paths_scanned"; }
    layout=$(get meta deployment_layout)
    case $layout in
        same-host) placement=local ;;
        remote-hosts) placement=remote ;;
        mixed)
            prompt_block "Node $i placement" "Whether this MySQL instance runs on the script execution host or on another host." "local | remote" ''
            placement=$(choice "Node $i placement" '' local remote)
            ;;
        *) die "ERROR_CODE=INVALID_DEPLOYMENT_LAYOUT VALUE=$layout";;
    esac
    put "$i" placement "$placement"
    if select_detected_login_path "$i" "$placement" probe >/dev/null 2>&1; then auth_default=login-path; else auth_default=password; fi
    mode=$(ask_explained "Node $i authentication method" "How this script authenticates to the instance during discovery/bootstrap." "login-path | password" "Authentication method for Node $i" "$auth_default")
    case $mode in
        login-path)
            if selected=$(select_detected_login_path "$i" "$placement"); then
                lf=$(printf '%s\n' "$selected" | cut -f1)
                lp=$(printf '%s\n' "$selected" | cut -f2)
                lpuuid=$(printf '%s\n' "$selected" | cut -f3)
                lpruntime_port=$(printf '%s\n' "$selected" | cut -f4)
                lpsocket=$(printf '%s\n' "$selected" | cut -f5)
                lpt=$(printf '%s\n' "$selected" | cut -f6)
                lpu=$(printf '%s\n' "$selected" | cut -f7)
                lph=$(printf '%s\n' "$selected" | cut -f8)
                lpp=$(printf '%s\n' "$selected" | cut -f9)
            else
                lp=$(ask_explained "Node $i MySQL login-path name" "The login-path label previously created with mysql_config_editor." "root@/path/to/mysql.sock | root@<HOST>:<PORT>" "Login-path name for Node $i" "")
                [ -n "$lp" ] || die 'login-path required'
                lf=$(ask_explained "Node $i login-path file (.mylogin.cnf)" "The encrypted credential file containing the selected login-path on this execution host." "/home/<OS_USER>/.mylogin.cnf | /root/.mylogin.cnf" "Path to .mylogin.cnf for Node $i" "$HOME/.mylogin.cnf")
                lpt=unknown; lpu=''; lph=''; lpp=0; lpsocket=''
            fi
            put "$i" auth_mode login-path; put "$i" login_path "$lp"; put "$i" login_file "$lf"; put "$i" login_transport "$lpt"; put "$i" login_user "$lpu"; put "$i" login_host "$lph"; put "$i" login_port "$lpp"; put "$i" login_socket "$lpsocket"; put "$i" user ''; put "$i" host ''; put "$i" port 0
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
    report_host=$(sql "$i" "SELECT COALESCE(@@report_host,'');")
    gr_member_host=$(sql "$i" "SELECT COALESCE((SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ID='$(q "$uuid")' LIMIT 1),'');")
    gr_member_port=$(sql "$i" "SELECT COALESCE((SELECT MEMBER_PORT FROM performance_schema.replication_group_members WHERE MEMBER_ID='$(q "$uuid")' LIMIT 1),0);")
    detected_admin_host=$gr_member_host
    [ -n "$detected_admin_host" ] || detected_admin_host=$report_host
    if [ -z "$detected_admin_host" ] && [ "$(get "$i" auth_mode)" = login-path ] && [ "$(get "$i" login_transport)" = tcp ]; then detected_admin_host=$(get "$i" login_host); fi
    if [ -z "$detected_admin_host" ] && [ "$(get "$i" auth_mode)" = password ]; then detected_admin_host=$(get "$i" host); fi
    admin_connect_host=$(ask_explained "Node $i AdminAPI reachable host" "Address MySQL Shell AdminAPI will use to reach this MySQL instance." "<HOSTNAME> | <IP_ADDRESS>" "AdminAPI reachable host for Node $i" "$detected_admin_host")
    [ -n "$admin_connect_host" ] || die "Node $i AdminAPI reachable host/IP could not be auto-detected; enter it explicitly"
    put "$i" uuid "$uuid"; put "$i" version "$ver"; put "$i" runtime_port "$port"; put "$i" runtime_host "$host"
    put "$i" report_host "$report_host"; put "$i" gr_member_host "$gr_member_host"; put "$i" gr_member_port "$gr_member_port"
    put "$i" connect_host "$admin_connect_host"; put "$i" admin_host "$admin_connect_host"
    log "Node $i: $ver uuid=$uuid AdminAPI=$admin_connect_host:$port runtime_host=$host report_host=${report_host:-'(empty)'} GR_MEMBER_HOST=${gr_member_host:-'(none)'}"
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
    [ "$(get meta work_schema_version)" = 6 ] || die "ERROR_CODE=WORK_ROOT_SCHEMA_MISMATCH CURRENT=$(get meta work_schema_version) REQUIRED=6"
}
discover(){
    [ ! -f "$ROOT/meta/complete" ] || die "Discovery already complete in $ROOT. Use a new MYSQL_IC_WORK_ROOT to rediscover."
    detect_login_paths
    : > "$TMP/login_paths_scanned"
    prompt_block 'Deployment layout' 'Physical placement of the MySQL instances in this migration set.' 'same-host | remote-hosts | mixed' ''
    layout=$(choice 'Deployment layout' '' same-host remote-hosts mixed)
    c=$(ask_explained 'Instance count' 'Number of MySQL instances participating in this migration set.' '<INSTANCE_COUNT>' 'Number of MySQL instances' '')
    case $c in ''|*[!0-9]*) die 'invalid count';; esac
    [ "$c" -ge 1 ] && [ "$c" -le 9 ] || die 'count must be 1..9'
    mkdir -p "$ROOT/meta"
    put meta deployment_layout "$layout"
    put meta count "$c"
    put meta work_schema_version 6
    n=1
    while [ "$n" -le "$c" ]; do register_node "$n"; n=$((n+1)); done
    v=$(get 1 version); mixed=no
    for i in $(ids); do [ "$(get "$i" version)" = "$v" ] || mixed=yes; done
    if [ "$mixed" = yes ]; then
        log 'MIXED_SERVER_VERSIONS=YES'
        log 'Exact-version policy requires identical MySQL Server versions on all registered nodes.'
        log 'AdminAPI policy continues only if AdminAPI validation succeeds on every registered node.'
        prompt_block 'Version compatibility policy' 'Controls whether every node must run the exact same MySQL version.' 'exact | adminapi' 'exact'; vp=$(choice 'Select version policy' exact exact adminapi)
        [ "$vp" = adminapi ] || die 'Mixed versions detected under exact-version policy'
        put meta version_policy adminapi
    else
        put meta version_policy exact
    fi
    detect_gr_state
    g=$(get meta gr_count)
    if meta_exists 1; then put meta metadata yes; else put meta metadata no; fi
    discover_common_accounts
    : > "$ROOT/meta/complete"
    log "Discovery complete: count=$c gr_state=$(get meta gr_state) configured=$(get meta gr_configured_count) active_members=$g gr_mode=$(get meta gr_mode) metadata=$(get meta metadata)"
    log "Common user@host accounts across all registered nodes: $ROOT/common_accounts.txt"
    next_step sql-precheck
}

assert_identity(){ for i in $(ids); do live=$(sql "$i" 'SELECT @@server_uuid;'); [ "$live" = "$(get "$i" uuid)" ] || die "Node $i UUID changed; use a new MYSQL_IC_WORK_ROOT and rediscover."; done; }
base_sql_precheck(){
    require_discovery_schema; i=$1; out="$ROOT/node_${i}.sql_precheck.txt"
    {
        printf 'version='; sql "$i" 'SELECT VERSION();'
        printf 'uuid='; sql "$i" 'SELECT @@server_uuid;'
        printf 'gtid_mode='; sql "$i" 'SELECT @@gtid_mode;'
        printf 'enforce_gtid_consistency='; sql "$i" 'SELECT @@enforce_gtid_consistency;'
        printf 'log_bin='; sql "$i" 'SELECT @@log_bin;'
        printf 'log_replica_updates='; sql "$i" 'SELECT @@log_replica_updates;'
        printf 'binlog_format='; sql "$i" 'SELECT @@binlog_format;'
        printf 'replica_parallel_workers='; sql "$i" 'SELECT @@replica_parallel_workers;'
        printf 'replica_preserve_commit_order='; sql "$i" 'SELECT @@replica_preserve_commit_order;'
        printf 'default_table_encryption='; sql "$i" 'SELECT @@default_table_encryption;'
        printf 'server_id='; sql "$i" 'SELECT @@server_id;'
        printf 'performance_schema='; sql "$i" 'SELECT @@performance_schema;'
        printf 'report_host='; sql "$i" "SELECT COALESCE(@@report_host,'');"
        printf 'metadata='; sql "$i" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mysql_innodb_cluster_metadata';"
        printf 'non_innodb='; sql "$i" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','sys','performance_schema','information_schema') AND table_type='BASE TABLE' AND engine<>'InnoDB';"
        printf 'tables_without_gr_key='; sql "$i" "SELECT COUNT(*) FROM information_schema.tables t WHERE t.table_schema NOT IN ('mysql','sys','performance_schema','information_schema') AND t.table_type='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.statistics s WHERE s.table_schema=t.table_schema AND s.table_name=t.table_name AND s.non_unique=0 GROUP BY s.index_name HAVING SUM(CASE WHEN s.nullable='YES' THEN 1 ELSE 0 END)=0);"
        printf 'inbound_async_channels='; sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT IN ('group_replication_applier','group_replication_recovery') AND CHANNEL_NAME NOT LIKE 'clusterset_replication%';"
    } > "$out"
    grep -q '^gtid_mode=ON$' "$out" || die "ERROR_CODE=GTID_MODE_NOT_ON NODE=$i"
    grep -q '^enforce_gtid_consistency=ON$' "$out" || die "ERROR_CODE=GTID_CONSISTENCY_NOT_ON NODE=$i"
    grep -q '^log_bin=1$' "$out" || die "ERROR_CODE=BINARY_LOG_DISABLED NODE=$i"
    grep -q '^log_replica_updates=1$' "$out" || die "ERROR_CODE=LOG_REPLICA_UPDATES_DISABLED NODE=$i"
    grep -q '^binlog_format=ROW$' "$out" || die "ERROR_CODE=BINLOG_FORMAT_NOT_ROW NODE=$i"
    workers=$(awk -F '=' '$1=="replica_parallel_workers"{print $2}' "$out")
    preserve=$(awk -F '=' '$1=="replica_preserve_commit_order"{print $2}' "$out")
    case $workers in ''|*[!0-9]*) die "ERROR_CODE=INVALID_REPLICA_PARALLEL_WORKERS NODE=$i VALUE=$workers";; esac
    if [ "$workers" -gt 1 ] && [ "$preserve" != 1 ]; then die "ERROR_CODE=REPLICA_PRESERVE_COMMIT_ORDER_OFF NODE=$i WORKERS=$workers"; fi
    grep -q '^performance_schema=1$' "$out" || die "ERROR_CODE=PERFORMANCE_SCHEMA_DISABLED NODE=$i"
    grep -q '^non_innodb=0$' "$out" || die "ERROR_CODE=NON_INNODB_APPLICATION_TABLE NODE=$i"
    grep -q '^tables_without_gr_key=0$' "$out" || die "ERROR_CODE=TABLE_WITHOUT_GR_ROW_IDENTITY_KEY NODE=$i"
    grep -q '^inbound_async_channels=0$' "$out" || {
        sql "$i" "SELECT CHANNEL_NAME,HOST,PORT,AUTO_POSITION FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME NOT IN ('group_replication_applier','group_replication_recovery') AND CHANNEL_NAME NOT LIKE 'clusterset_replication%' ORDER BY CHANNEL_NAME;" >&2
        die "ERROR_CODE=UNMANAGED_ASYNC_REPLICATION_CHANNEL NODE=$i"
    }
}
topology_address_check(){
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
            all_local=yes
            for j in $(ids); do [ "$(get "$j" placement)" = local ] || all_local=no; done
            [ "$all_local" = yes ] || die "ERROR_CODE=GR_LOOPBACK_MEMBER_IN_DISTRIBUTED_LAYOUT NODE=$i MEMBER_HOST=$mh"
            ;;
        esac
    done
}
sql_precheck(){
    require_discovery_schema
    [ -f "$ROOT/meta/complete" ] || die 'Run discover first'
    case $(get meta gr_state) in
        configured-offline) die 'ERROR_CODE=GR_CONFIGURED_BUT_OFFLINE Run gr-restart-precheck and restore the existing Group Replication group before migration.';;
        partial-configured) die 'ERROR_CODE=GR_PARTIAL_CONFIGURATION Review Group Replication configuration on every registered node before migration.';;
    esac
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
    next_step configure-admin
}
show_existing_admin_candidates(){
    out="$ROOT/existing_admin_candidates.txt"
    accounts="$TMP/existing_accounts.tsv"
    : > "$out"
    sql 1 "SELECT User,Host FROM mysql.user WHERE User<>'' AND User NOT IN ('mysql.infoschema','mysql.session','mysql.sys') ORDER BY User,Host;" > "$accounts"
    log 'Existing accounts present on every registered node:'
    log '  EXISTS means only that the same user@host is present on every registered node.'
    log '  AdminAPI status remains UNVALIDATED until the supplied password and dba.checkInstanceConfiguration() succeed on every node.'
    log '  Listed privileges are informational only; roles and release-specific AdminAPI requirements can change effective privileges.'
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
        log 'ERROR_CODE=PARTIAL_ADMIN_ACCOUNT_STATE'
    fi
}

rollback_created_admin_accounts(){
    u=$1; h=$2
    present_nodes=''
    for j in $(ids); do
        c=$(sql "$j" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$u")' AND Host='$(q "$h")';" 2>/dev/null || printf '0')
        [ "$c" -gt 0 ] && present_nodes="${present_nodes}${present_nodes:+ }$j"
    done
    [ -n "$present_nodes" ] || { log 'Rollback check: no newly created clusterAdmin account is present.'; return 0; }
    prompt_block 'Rollback newly created clusterAdmin accounts' 'Drops only the exact user@host that was absent on every node before this create attempt but now exists on one or more nodes.' 'yes | no' 'yes'
    rb=$(choice 'Rollback newly created clusterAdmin account(s)?' yes yes no)
    [ "$rb" = yes ] || { log "ROLLBACK=SKIPPED NODES=$present_nodes"; return 0; }
    failed=''
    for j in $present_nodes; do
        if sql "$j" "DROP USER IF EXISTS '$(q "$u")'@'$(q "$h")';" >/dev/null 2>&1; then
            log "Rollback: removed '$u'@'$h' from node $j."
        else
            failed="${failed}${failed:+ }$j"
        fi
    done
    [ -z "$failed" ] || die "ERROR_CODE=ADMIN_ACCOUNT_ROLLBACK_FAILED NODES=$failed"
    for j in $(ids); do
        c=$(sql "$j" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$u")' AND Host='$(q "$h")';" 2>/dev/null || printf '0')
        [ "$c" -eq 0 ] || die "Rollback verification failed: '$u'@'$h' still exists on node $j."
    done
    log 'Rollback verification: newly created clusterAdmin account removed from all registered nodes.'
}

adminapi_bootstrap_exec(){
    i=$1; js=$2; out=$3
    detect_login_paths
    uuid=$(get "$i" uuid)
    placement=$(get "$i" placement)
    tcp="$TMP/adminapi_tcp_$i.tsv"
    case $placement in
        local)
            awk -F '\t' -v u="$uuid" '$3==u && $6=="tcp" && ($8=="localhost" || $8 ~ /^127\./ || $8=="::1")' "$TMP/login_path_candidates" > "$tcp"
            ;;
        remote)
            awk -F '\t' -v u="$uuid" '$3==u && $6=="tcp" && $8!="" && $8!="localhost" && $8 !~ /^127\./ && $8!="::1"' "$TMP/login_path_candidates" > "$tcp"
            ;;
        *) die "ERROR_CODE=INVALID_NODE_PLACEMENT NODE=$i";;
    esac
    count=$(awk 'END{print NR+0}' "$tcp")
    if [ "$count" -gt 0 ]; then
        line=$(sed -n '1p' "$tcp")
        if [ "$count" -gt 1 ]; then
            prompt_block "Node $i AdminAPI TCP login-path" "TCP login-path on this execution host for dba.configureInstance()." "<LOGIN_PATH> [file=/home/<OS_USER>/.mylogin.cnf]" ''
            n=1; tab=$(printf '\t')
            while IFS="$tab" read -r lf lp u p sock transport cfg_user cfg_host cfg_port; do
                printf '  %s) %s [endpoint=%s:%s, file=%s]\n' "$n" "$lp" "${cfg_host:-<HOST>}" "${cfg_port:-<PORT>}" "$lf" >&2
                n=$((n+1))
            done < "$tcp"
            sel=$(ask "Select AdminAPI TCP login-path for Node $i" '1')
            case $sel in ''|*[!0-9]*) die 'AdminAPI login-path selection must be a number';; esac
            line=$(sed -n "${sel}p" "$tcp")
            [ -n "$line" ] || die "Invalid AdminAPI login-path selection: $sel"
        fi
        lf=$(printf '%s\n' "$line" | cut -f1)
        lp=$(printf '%s\n' "$line" | cut -f2)
        log "ADMINAPI_BOOTSTRAP_AUTH=login-path NODE=$i LOGIN_PATH=$lp"
        MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQLSH" --login-path="$lp" --mysql --no-wizard --js -f "$js" >"$out" 2>&1
        return $?
    fi

    if [ "$(get "$i" auth_mode)" = password ]; then
        u=$(get "$i" user); h=$(get "$i" host); p=$(get "$i" port)
        cred "$i"
        pwfile="$TMP/$i.pw"
    else
        u=$(ask_explained "Node $i AdminAPI bootstrap user" "Administrative MySQL account used for dba.configureInstance() over TCP." "root | <ADMIN_USER>" "AdminAPI bootstrap user for Node $i" 'root')
        h=$(ask_explained "Node $i AdminAPI bootstrap host" "TCP host used by MySQL Shell for dba.configureInstance()." "<HOSTNAME> | <IP_ADDRESS>" "AdminAPI bootstrap host for Node $i" "$(get "$i" connect_host)")
        p=$(ask_explained "Node $i AdminAPI bootstrap port" "Classic MySQL TCP port used by MySQL Shell." "<PORT>" "AdminAPI bootstrap port for Node $i" "$(get "$i" runtime_port)")
        case $p in ''|*[!0-9]*) die "Node $i AdminAPI bootstrap port must be numeric";; esac
        pw=$(secret_explained "Node $i AdminAPI bootstrap password" "Password for the selected AdminAPI bootstrap account." "AdminAPI bootstrap password for Node $i")
        [ -n "$pw" ] || die "Node $i AdminAPI bootstrap password cannot be empty"
        pwfile="$TMP/adminapi_bootstrap_$i.pw"
        printf '%s\n' "$pw" > "$pwfile"; chmod 600 "$pwfile"
    fi
    uri="$u@$h:$p"
    log "ADMINAPI_BOOTSTRAP_AUTH=password NODE=$i ENDPOINT=$h:$p"
    cat "$pwfile" | "$MYSQLSH" --mysql --uri "$uri" --passwords-from-stdin --js -f "$js" >"$out" 2>&1
}

configure_admin(){ require_discovery_schema;
    [ -f "$ROOT/meta/complete" ] || die 'Run discover first'
    SUPPRESS_NEXT_STEP=yes sql_precheck
    SUPPRESS_NEXT_STEP=no
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
            prompt_block 'Existing account detected on every node' 'The same user@host exists on all registered nodes, but AdminAPI compatibility is still UNVALIDATED.' 'yes | no' 'yes'; reuse=$(choice 'Validate and try to reuse this existing account first?' yes yes no)
            if [ "$reuse" = yes ]; then action=existing; fi
        fi
        if [ "$action" = existing ]; then
            ah=$(ask_explained 'Existing cluster admin Host' 'The Host value attached to the already existing MySQL account on every registered node.' '<IP_ADDRESS> | <HOSTNAME> | <NETWORK_PATTERN>' 'Existing cluster admin Host' "$first_common")
            printf '%s\n' "$common_hosts" | grep -Fxq "$ah" || die "'$au'@'$ah' does not exist on every registered node"
        fi
    fi
    if [ "${action}" = existing ] && [ -n "${ah:-}" ]; then
        rec_ah=''
    else
        rec_ah=''
        ah=$(ask_explained 'Cluster admin account Host' 'MySQL account Host value for the clusterAdmin account.' '<IP_ADDRESS> | <HOSTNAME> | <NETWORK>/<PREFIX> | %' 'Cluster admin account Host' '')
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
            log 'ACCOUNT_PROVISIONING_METHOD=dba.configureInstance'
            log 'STATE_SNAPSHOT=before_configure_admin,after_configure_admin'
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
                    adminapi_bootstrap_exec "$i" "$js" "$out" || rc=$?
                    [ "$rc" -eq 0 ] && break
                    cat "$out" >&2
                    if grep -Eq 'MYSQLSH 1819|does not satisfy the current policy requirements' "$out"; then
                        log 'Password rejected by the server password policy.'
                        password_policy_report "$i"
                        admin_account_presence_report "$au" "$ah"
                        present_count=$(admin_account_presence_count "$au" "$ah")
                        if [ "$present_count" -gt 0 ]; then
                            log 'Partial account creation detected during the failed attempt.'
                            rollback_created_admin_accounts "$au" "$ah"
                            die 'clusterAdmin creation stopped after partial-state handling.'
                        fi
                        log 'Enter a new password that satisfies the policy. Only the password entry is retried; the migration does not restart.'
                        ap=$(secret_explained 'Cluster admin password retry' 'Password for the clusterAdmin account.' 'Cluster admin password (re-enter)')
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
                    present_count=$(admin_account_presence_count "$au" "$ah")
                    if [ "$present_count" -gt 0 ]; then rollback_created_admin_accounts "$au" "$ah"; fi
                    die "clusterAdmin creation failed on node $i"
                done
                rm -f "$js"
            done
            if ! (
                state_snapshot after_configure_admin
                if [ "$(get meta gr_count)" -gt 0 ]; then
                    snapshot_critical_equal before_configure_admin after_configure_admin
                    all_node_gr_consistency_guard
                    gr_writeability_guard
                    writeability_persistence_check
                fi
            ); then
                rollback_created_admin_accounts "$au" "$ah"
                die 'ERROR_CODE=POST_ADMIN_CREATE_STATE_VALIDATION_FAILED'
            fi
            log 'ADMINAPI_VALIDATION=dba.checkInstanceConfiguration'
            for i in $(ids); do
                uri="$au@$(admin_host_for "$i"):$(admin_port_for "$i")"
                out="$ROOT/node_${i}.new_admin_check.txt"
                if ! cat "$TMP/admin.pw" | "$MYSQLSH" --mysql --uri "$uri" --passwords-from-stdin --js --execute='var r=dba.checkInstanceConfiguration(); print("IC_CHECK_STATUS="+r.status);' >"$out" 2>&1; then
                    cat "$out" >&2
                    admin_account_presence_report "$au" "$ah"
                    rollback_created_admin_accounts "$au" "$ah"
                    die "ERROR_CODE=NEW_ADMINAPI_CHECK_FAILED NODE=$i"
                fi
                if ! grep -q 'IC_CHECK_STATUS=ok' "$out"; then
                    cat "$out" >&2
                    admin_account_presence_report "$au" "$ah"
                    rollback_created_admin_accounts "$au" "$ah"
                    die "ERROR_CODE=NEW_ADMINAPI_STATUS_NOT_OK NODE=$i"
                fi
            done
            ;;
        existing)
            log "Existing account will be reused: '$au'@'$ah'"
            log 'GRANT_OR_ALTER_USER=DISABLED_FOR_EXISTING_ACCOUNT'
            confirm "USE-EXISTING-CLUSTER-ADMIN-$au"
            for i in $(ids); do
                out="$ROOT/node_${i}.existing_admin_check.txt"
                while :; do
                    rc=0
                    uri="$au@$(get "$i" connect_host):$(get "$i" runtime_port)"
                    cat "$TMP/admin.pw" | "$MYSQLSH" --mysql --uri "$uri" --passwords-from-stdin --js --execute='var r=dba.checkInstanceConfiguration(); print("IC_CHECK_STATUS="+r.status);' >"$out" 2>&1 || rc=$?
                    [ "$rc" -eq 0 ] && break
                    cat "$out" >&2
                    if grep -Eq 'MySQL Error 1045|Access denied for user' "$out"; then
                        log "ERROR_CODE=MYSQL_AUTH_1045"
                        log "NODE=$i"
                        exit 1
                    fi
                    if grep -q 'proper source address specification' "$out"; then
                        log "ERROR_CODE=ADMINAPI_HOST_SCOPE_REJECTED"
                        log "NODE=$i"
                        exit 1
                    fi
                    die "ERROR_CODE=ADMINAPI_CHECK_FAILED NODE=$i"
                done
                grep -q 'IC_CHECK_STATUS=ok' "$out" || { cat "$out" >&2; die "ERROR_CODE=ADMINAPI_STATUS_NOT_OK NODE=$i"; }
            done
            put meta admin_user "$au"
            put meta admin_host_pattern "$ah"
            for i in $(ids); do put "$i" admin_host "$(get "$i" connect_host)"; done
            : > "$ROOT/meta/admin_configured"
            unset ap
            log 'ADMINAPI_VALIDATION=OK'
            next_step precheck
            return 0
            ;;
    esac

    put meta admin_user "$au"; put meta admin_host_pattern "$ah"; : > "$ROOT/meta/admin_configured"
    unset ap
    log 'ADMIN_CONFIGURED=OK'
    next_step precheck
}
adminapi_check(){ i=$1; out="$ROOT/node_${i}.adminapi_check.txt"; code='var r=dba.checkInstanceConfiguration(); print("IC_CHECK_STATUS="+r.status);'; mysqlsh_admin_exec "$i" "$code" "$out" || { cat "$out" >&2; die "ERROR_CODE=ADMINAPI_CHECK_FAILED NODE=$i"; }; grep -q 'IC_CHECK_STATUS=ok' "$out" || { cat "$out" >&2; die "ERROR_CODE=ADMINAPI_STATUS_NOT_OK NODE=$i"; }; }
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
    baseline=$(gtids 1)
    for i in $(ids); do
        reached=$(sql "$i" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$(q "$baseline")',30);")
        [ "$reached" = 0 ] || die "Node $i did not execute the baseline GTID set within 30 seconds. Adoption is blocked."
    done
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
    ref_dte=$(sql 1 'SELECT @@GLOBAL.default_table_encryption;')
    for i in $(ids); do
        [ "$(sql "$i" 'SELECT @@GLOBAL.lower_case_table_names;')" = "$ref_lctn" ] || die "ERROR_CODE=LOWER_CASE_TABLE_NAMES_MISMATCH NODE=$i"
        [ "$(sql "$i" 'SELECT @@GLOBAL.default_table_encryption;')" = "$ref_dte" ] || die "ERROR_CODE=DEFAULT_TABLE_ENCRYPTION_MISMATCH NODE=$i"
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

        pro=$(awk -F '\t' '$1=="read_only"{print $2; exit}' "$pv")
        if [ -n "$pro" ]; then
            cat "$pv" >&2
            die "ERROR_CODE=PERSISTED_READ_ONLY_OVERRIDE NODE=$i VALUE=$pro. Persisted read_only is not managed automatically by this migration; review/remove it explicitly before relying on role-based writeability."
        fi

        psro=$(awk -F '\t' '$1=="super_read_only"{print $2; exit}' "$pv")
        if [ -n "$psro" ]; then
            case $(printf '%s' "$psro" | tr '[:lower:]' '[:upper:]') in
                ON|1)
                    log "Node $i startup safeguard accepted: persisted super_read_only=ON. Group Replication/AdminAPI runtime role state remains authoritative while ONLINE."
                    ;;
                *)
                    cat "$pv" >&2
                    die "ERROR_CODE=PERSISTED_SUPER_READ_ONLY_UNSAFE NODE=$i VALUE=$psro. Only persisted super_read_only=ON is accepted as a startup write-protection safeguard."
                    ;;
            esac
        fi

        bad_ro=$(awk -F '\t' '$1=="read_only" && $2 != "DYNAMIC" && $2 != "COMPILED" {print}' "$vi")
        if [ -n "$bad_ro" ]; then
            printf '%s\n' "$bad_ro" >&2
            die "ERROR_CODE=STATIC_READ_ONLY_OVERRIDE NODE=$i. read_only is sourced from startup/static configuration and can conflict with role-based writeability."
        fi
    done
}

multi_primary_schema_guard(){
    [ "$(get meta gr_mode)" = multi-primary ] || return 0
    iso=$(sql 1 'SELECT @@GLOBAL.transaction_isolation;')
    log "MULTI_PRIMARY_TRANSACTION_ISOLATION=$iso"
    for i in 1; do
        out="$ROOT/multi_primary_cascade_fk.tsv"
        sql "$i" "SELECT CONSTRAINT_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,REFERENCED_TABLE_NAME,UPDATE_RULE,DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') AND (UPDATE_RULE='CASCADE' OR DELETE_RULE='CASCADE') ORDER BY CONSTRAINT_SCHEMA,TABLE_NAME,CONSTRAINT_NAME;" > "$out"
        [ ! -s "$out" ] || { cat "$out" >&2; die 'ERROR_CODE=MULTI_PRIMARY_CASCADE_FK_DETECTED'; }
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
                die "ERROR_CODE=EVENT_DEFINER_ACCOUNT_MISSING NODE=$i"
            fi
            review=yes
            cat "$out" >&2
            if [ "$mode" = multi-primary ] && [ "$es" = ON ]; then
                die "ERROR_CODE=MULTI_PRIMARY_EVENT_SCHEDULER_ON NODE=$i"
            fi
        fi
    done
    if [ "$review" = yes ]; then
        log 'Scheduled EVENT objects exist. InnoDB Cluster does not automatically enforce single execution ownership for application events.'
        log 'EVENT_REVIEW_REQUIRED=YES'
        : > "$ROOT/meta/event_review_required"
    else
        rm -f "$ROOT/meta/event_review_required" "$ROOT/meta/event_review_ack" 2>/dev/null || :
    fi
}
event_ack(){
    [ -f "$ROOT/meta/event_review_required" ] || return 0
    [ -f "$ROOT/meta/event_review_ack" ] && return 0
    log 'EVENT_REVIEW_REQUIRED=YES'
    log 'EVENT_REVIEW_CONFIRMATION_REQUIRED=EVENT-POLICY-REVIEWED'
    confirm 'EVENT-POLICY-REVIEWED'
    : > "$ROOT/meta/event_review_ack"
}
mutation_safety_gate(){
    [ -f "$ROOT/meta/prechecked" ] || die 'Run precheck first'
    metadata_absence_guard
    assert_identity
    event_ack
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
    next_step plan
}
plan(){ require_discovery_schema; [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; assert_identity; show_capabilities >/dev/null; gr=$(get meta gr_count); state=$(get meta gr_state); mode=$(get meta gr_mode); metadata=$(get meta metadata); log '--- InnoDB Cluster migration plan ---'; log "Instances: $(get meta count)"; log "Version policy: $(get meta version_policy)"; log "GR state: $state"; log "Existing GR active members: $gr"; log "Existing GR mode: $mode"; log "Existing InnoDB Cluster metadata: $metadata"; case $state in online) log 'ACTION=adopt'; log 'adoptFromGR preserves the existing single-primary or multi-primary topology.'; next_step adopt;; none) log 'ACTION=create'; log 'Create options are selected interactively according to mysqlsh runtime capabilities.'; next_step create;; configured-offline) log 'ACTION=restore-existing-gr-first'; log 'Configured Group Replication is fully offline. Run gr-restart-precheck, restore the group using the official full-outage procedure, then rediscover.';; partial-configured) log 'ACTION=review-gr-configuration'; log 'Only part of the registered set has Group Replication configuration; create/adopt is blocked.';; *) die "ERROR_CODE=UNKNOWN_GR_STATE VALUE=$state";; esac; log "Capabilities: $ROOT/capabilities.txt"; }
create_options(){
    opts=''
    log 'Primary topology:'
    log '  single-primary: one R/W primary, secondaries R/O'
    if has_create_option multiPrimary; then
        log '  multi-primary: multiple R/W members'
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
            log 'ipAllowlist limits XCom peers. AUTOMATIC lets AdminAPI derive entries; explicit CIDRs use the entered networks.'
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
configure(){ require_discovery_schema; [ -f "$ROOT/meta/prechecked" ] || die 'Run precheck first'; assert_identity; log 'CONFIGURE_RESTART=false'; confirm CONFIGURE-INSTANCES; for i in $(ids); do out="$ROOT/node_${i}.configure.txt"; mysqlsh_admin_exec "$i" 'dba.configureInstance(undefined,{restart:false});' "$out" || { cat "$out" >&2; die "ERROR_CODE=CONFIGURE_INSTANCE_FAILED NODE=$i"; }; done; : > "$ROOT/meta/configured"; log 'CONFIGURE_INSTANCE=OK'; next_step precheck; }
cluster_name(){ n=$(ask_explained 'InnoDB Cluster name' 'Logical name stored in InnoDB Cluster metadata.' '<CLUSTER_NAME>' 'InnoDB Cluster name' ''); case $n in ''|*[!A-Za-z0-9_.-]*) die 'Cluster name may contain only alphanumeric, _, . and -';; esac; [ "${#n}" -le 63 ] || die 'Cluster name exceeds 63 characters'; printf '%s' "$n"; }
create(){ require_discovery_schema; [ "$(get meta gr_state)" = none ] || die "ERROR_CODE=CREATE_REQUIRES_NO_GR CURRENT=$(get meta gr_state)"; mutation_safety_gate; meta_exists 1 && die 'InnoDB Cluster metadata already exists'; total=$(grmembers 1 | awk 'NF{n++} END{print n+0}'); [ "$total" -eq 0 ] || die 'Seed belongs to Group Replication. Use adopt; create never performs implicit adoption.'; name=$(cluster_name); opts=$(create_options); log "Will create new InnoDB Cluster '$name' using node 1 as seed."; log "Selected options: ${opts:-AdminAPI defaults}"; log 'No force:true option is ever used.'; confirm "CREATE-$name"; if [ -n "$opts" ]; then code="var c=dba.createCluster(\"$(jsq "$name")\", {$opts}); print('IC_CREATED='+c.name);"; else code="var c=dba.createCluster(\"$(jsq "$name")\"); print('IC_CREATED='+c.name);"; fi; out="$ROOT/create.txt"; mysqlsh_admin_exec 1 "$code" "$out" || { cat "$out" >&2; die 'createCluster failed'; }; put meta cluster_name "$name"; : > "$ROOT/meta/created"; n=2; while [ "$n" -le "$(get meta count)" ]; do method=$(add_recovery_method); log "About to add node $n using recoveryMethod=$method. Existing data on the target can be replaced if clone is selected."; if [ "$method" = clone ]; then log "WARNING: clone replaces the recipient dataset on node $n."; confirm "CLONE-WILL-REPLACE-NODE-$n"; fi; confirm "ADD-NODE-$n"; uri="$(get meta admin_user)@$(admin_host_for "$n"):$(admin_port_for "$n")"; addopts=''; [ "$method" = __omit__ ] || addopts="recoveryMethod:\"$method\""; if has_add_option localAddress; then log "Node $n localAddress is its internal Group Replication communication endpoint."; la=$(ask_explained "Node $n Group Replication localAddress" 'Internal host:port endpoint used by this member for Group Replication communication.' '<HOSTNAME>:<PORT> | <IP_ADDRESS>:<PORT>' "Node $n localAddress (blank = AdminAPI default)" ''); [ -z "$la" ] || { [ -z "$addopts" ] || addopts="$addopts, "; addopts="$addopts localAddress:\"$(jsq "$la")\""; }; fi; if [ -n "$addopts" ]; then code="var c=dba.getCluster(\"$(jsq "$name")\"); c.addInstance(\"$(jsq "$uri")\", {$addopts}); print(JSON.stringify(c.status({extended:1})));"; else code="var c=dba.getCluster(\"$(jsq "$name")\"); c.addInstance(\"$(jsq "$uri")\"); print(JSON.stringify(c.status({extended:1})));"; fi; mysqlsh_admin_exec 1 "$code" "$ROOT/add_${n}.txt" || { cat "$ROOT/add_${n}.txt" >&2; die "addInstance failed for node $n"; }; n=$((n+1)); done; validate; }

adopt(){ require_discovery_schema; [ "$(get meta gr_state)" = online ] || die "ERROR_CODE=ADOPT_REQUIRES_ONLINE_GR CURRENT=$(get meta gr_state)"; mutation_safety_gate; meta_exists 1 && die 'InnoDB Cluster metadata already exists; refusing to overwrite/adopt again'; members=$(grmembers 1); total=$(printf '%s\n' "$members" | awk 'NF{n++} END{print n+0}'); online=$(printf '%s\n' "$members" | awk '$4=="ONLINE"{n++} END{print n+0}'); [ "$total" -ge 3 ] || die 'ERROR_CODE=GR_MEMBER_COUNT_LT_3'; [ "$online" -eq "$total" ] || die 'All GR members must be ONLINE before adoption'; [ "$total" -eq "$(get meta count)" ] || die 'Registered instances do not exactly match GR membership'; for i in $(ids); do grep -q "^$(get "$i" uuid)[[:space:]]" "$ROOT/gr_members.before" || die "Node $i UUID was not in prechecked GR membership"; done
name=$(cluster_name); mode=$(gr_role_guard 1); [ "$mode" = "$(get meta gr_mode)" ] || die 'GR topology mode changed after precheck; rerun discover/precheck with a new work root.'; log "Will adopt existing $mode GR ($total ONLINE members) as InnoDB Cluster '$name'."; log 'The existing single-primary/multi-primary mode will be preserved. This script does not switch topology during adoption.'; log 'This creates InnoDB Cluster metadata and transfers management responsibility to AdminAPI; it does not rebuild the GR group.'; confirm "ADOPT-$name"; code="var c=dba.createCluster(\"$(jsq "$name")\", {adoptFromGR:true}); print('IC_ADOPTED='+c.name); print(JSON.stringify(c.status({extended:1})));"; out="$ROOT/adopt.txt"; mysqlsh_admin_exec 1 "$code" "$out" || { cat "$out" >&2; die 'adoptFromGR failed'; }; post_mode=$(gr_role_guard 1); [ "$post_mode" = "$mode" ] || die "URGENT: GR mode changed during adoption ($mode -> $post_mode); stop and inspect before any further action"; all_node_gr_consistency_guard; gtid_convergence_guard; state_snapshot post_adopt; cmp "$ROOT/snapshots/pre_mutation/gr_members.tsv" "$ROOT/snapshots/post_adopt/gr_members.tsv" >/dev/null 2>&1 || { diff -u "$ROOT/snapshots/pre_mutation/gr_members.tsv" "$ROOT/snapshots/post_adopt/gr_members.tsv" >&2 || :; die 'URGENT: GR membership/roles changed during adoption'; }; put meta cluster_name "$name"; put meta adopted_gr_mode "$mode"; : > "$ROOT/meta/adopted"; log "Adoption completed with topology preserved ($mode). Evidence: $out"; validate; }
final_operational_validation(){
    members=$1; total=$2; online=$3; mode=$4; primary_count=$5
    report="$ROOT/final_validation.txt"
    admin_out="$ROOT/final_adminapi.txt"
    code='var c=dba.getCluster(); var s=c.status({extended:2}); var d=c.describe(); var o=c.options({all:true}); var r=c.listRouters(); var t=s.defaultReplicaSet.topology||{}; var ie=0; Object.keys(t).forEach(function(k){if(t[k].instanceErrors){ie+=t[k].instanceErrors.length;} println("IC_TOPOLOGY="+k+"\t"+(t[k].memberRole||"")+"\t"+(t[k].memberState||t[k].status||"")+"\t"+(t[k].mode||""));}); var rc=0; if(r){if(r.routers){rc=Object.keys(r.routers).length;}else{rc=Object.keys(r).length;}} println("IC_CLUSTER_NAME="+c.name); println("IC_CLUSTER_STATUS="+s.defaultReplicaSet.status); println("IC_STATUS_TEXT="+s.defaultReplicaSet.statusText); println("IC_PRIMARY="+s.defaultReplicaSet.primary); println("IC_TOPOLOGY_MODE="+s.defaultReplicaSet.topologyMode); println("IC_INSTANCE_ERRORS="+ie); println("IC_DESCRIBE_ENDPOINTS="+(d.defaultReplicaSet.topology||[]).map(function(x){return x.address;}).sort().join(",")); println("IC_ROUTER_COUNT="+rc); println("IC_ROUTERS="+JSON.stringify(r)); println("IC_OPTIONS="+JSON.stringify(o));'
    mysqlsh_admin_exec 1 "$code" "$admin_out" || { cat "$admin_out" >&2; die 'ERROR_CODE=FINAL_ADMINAPI_VALIDATION_FAILED'; }

    cluster_name=$(sed -n 's/^IC_CLUSTER_NAME=//p' "$admin_out" | tail -1)
    cluster_status=$(sed -n 's/^IC_CLUSTER_STATUS=//p' "$admin_out" | tail -1)
    primary_ep=$(sed -n 's/^IC_PRIMARY=//p' "$admin_out" | tail -1)
    topology_mode=$(sed -n 's/^IC_TOPOLOGY_MODE=//p' "$admin_out" | tail -1)
    instance_errors=$(sed -n 's/^IC_INSTANCE_ERRORS=//p' "$admin_out" | tail -1)
    describe_eps=$(sed -n 's/^IC_DESCRIBE_ENDPOINTS=//p' "$admin_out" | tail -1)
    router_count=$(sed -n 's/^IC_ROUTER_COUNT=//p' "$admin_out" | tail -1)
    adminapi_topology="$ROOT/cluster_status_topology.tsv"
    sed -n 's/^IC_TOPOLOGY=//p' "$admin_out" > "$adminapi_topology"
    case $instance_errors in ''|*[!0-9]*) instance_errors=unknown;; esac
    case $router_count in ''|*[!0-9]*) router_count=unknown;; esac

    gr_eps=$(printf '%s\n' "$members" | awk 'NF{print $2":"$3}' | sort | paste -sd, -)
    if [ "$describe_eps" = "$gr_eps" ]; then drift='MATCH'; drift_result='PASS'; else drift='MISMATCH'; drift_result='FAIL'; fi

    member_runtime="$ROOT/member_runtime_state.tsv"
    : > "$member_runtime"
    for i in $(ids); do
        u=$(get "$i" uuid)
        row=$(printf '%s\n' "$members" | awk -v u="$u" '$1==u{print; exit}')
        mh=$(printf '%s\n' "$row" | awk '{print $2}'); mp=$(printf '%s\n' "$row" | awk '{print $3}')
        ms=$(printf '%s\n' "$row" | awk '{print $4}'); mr=$(printf '%s\n' "$row" | awk '{print $5}')
        ro=$(sql "$i" 'SELECT @@GLOBAL.read_only;'); sro=$(sql "$i" 'SELECT @@GLOBAL.super_read_only;')
        if [ "$ro" = 0 ] && [ "$sro" = 0 ]; then rwmode='R/W'; elif [ "$sro" = 1 ]; then rwmode='R/O'; else rwmode='CHECK'; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mh" "$mp" "$ms" "$mr" "$rwmode" "$ro" "$sro" >> "$member_runtime"
    done

    queue_file="$ROOT/gr_queue_conflict_snapshot.tsv"
    sql 1 "SELECT m.MEMBER_HOST,m.MEMBER_PORT,m.MEMBER_STATE,m.MEMBER_ROLE,s.COUNT_TRANSACTIONS_IN_QUEUE,s.COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE,s.COUNT_TRANSACTIONS_CHECKED,s.COUNT_CONFLICTS_DETECTED,s.COUNT_TRANSACTIONS_ROWS_VALIDATING,s.COUNT_TRANSACTIONS_LOCAL_PROPOSED,s.COUNT_TRANSACTIONS_LOCAL_ROLLBACK,s.COUNT_TRANSACTIONS_REMOTE_APPLIED,COALESCE(s.LAST_CONFLICT_FREE_TRANSACTION,'') FROM performance_schema.replication_group_members m JOIN performance_schema.replication_group_member_stats s ON m.MEMBER_ID=s.MEMBER_ID ORDER BY m.MEMBER_HOST,m.MEMBER_PORT;" > "$queue_file"
    cert_queue=$(awk -F '\t' '{s+=$5} END{print s+0}' "$queue_file")
    apply_queue=$(awk -F '\t' '{s+=$6} END{print s+0}' "$queue_file")
    conflicts=$(awk -F '\t' '{s+=$8} END{print s+0}' "$queue_file")
    if [ "$cert_queue" -eq 0 ] && [ "$apply_queue" -eq 0 ]; then queue_result='PASS(snapshot)'; else queue_result='WARN(snapshot)'; fi
    if [ "$conflicts" -eq 0 ]; then conflict_result='PASS(snapshot)'; else conflict_result='WARN(cumulative)'; fi

    error_total=0; error_unavailable=''
    for i in $(ids); do
        ef="$ROOT/node_${i}.recent_gr_error_log.tsv"
        if sql "$i" "SELECT LOGGED,PRIO,ERROR_CODE,SUBSYSTEM,DATA FROM performance_schema.error_log WHERE LOGGED >= NOW() - INTERVAL 24 HOUR AND PRIO IN ('Error','Warning') AND (LOWER(DATA) LIKE '%group replication%' OR LOWER(DATA) LIKE '%group_replication%' OR LOWER(DATA) LIKE '%distributed recovery%' OR LOWER(DATA) LIKE '%rejoin%' OR LOWER(DATA) LIKE '%expel%' OR LOWER(DATA) LIKE '%quorum%') ORDER BY LOGGED DESC;" > "$ef" 2>/dev/null; then
            ec=$(awk 'END{print NR+0}' "$ef"); error_total=$((error_total+ec))
        else
            error_unavailable="${error_unavailable}${error_unavailable:+ }$i"
            : > "$ef"
        fi
    done
    if [ -n "$error_unavailable" ]; then error_result="CHECK(unavailable nodes:$error_unavailable)"; elif [ "$error_total" -eq 0 ]; then error_result='PASS(24h snapshot)'; else error_result="WARN(24h matches:$error_total)"; fi

    if [ "$router_count" = unknown ]; then router_result='CHECK'; router_endpoint='NOT_TESTED';
    elif [ "$router_count" -eq 0 ]; then router_result='N/A(no registered Router)'; router_endpoint='N/A';
    else router_result="PASS(registered:$router_count)"; router_endpoint='EXTERNAL_CHECK_REQUIRED'; fi

    if [ "$cluster_status" = OK ]; then cluster_result='PASS'; else cluster_result='FAIL'; fi
    if [ "$online" -eq "$total" ]; then member_result='PASS'; else member_result='FAIL'; fi
    if [ "$mode" = single-primary ] && [ "$primary_count" -eq 1 ]; then role_result='PASS'; elif [ "$mode" = multi-primary ] && [ "$primary_count" -eq "$total" ]; then role_result='PASS'; else role_result='FAIL'; fi
    if [ "$instance_errors" = 0 ]; then instance_result='PASS'; elif [ "$instance_errors" = unknown ]; then instance_result='CHECK'; else instance_result='FAIL'; fi

    final='PASS'
    case "$cluster_result:$member_result:$role_result:$drift_result:$instance_result" in *FAIL*) final='FAIL';; *CHECK*) final='PASS_WITH_CHECKS';; esac
    case "$queue_result:$conflict_result:$error_result:$router_result:$router_endpoint" in *WARN*|*CHECK*|*EXTERNAL_CHECK_REQUIRED*) [ "$final" = PASS ] && final='PASS_WITH_WARNINGS';; esac

    {
        printf '%s\n' '========================================================'
        printf '%s\n' ' InnoDB Cluster validation (script-generated report)'
        printf '%s\n' '========================================================'
        printf '\nCluster.status({extended:2})\n'
        printf '  clusterName                         : %s\n' "$cluster_name"
        printf '  defaultReplicaSet.status            : %s [SCRIPT_CHECK=%s]\n' "$cluster_status" "$cluster_result"
        printf '  defaultReplicaSet.topologyMode      : %s [SCRIPT_CHECK=%s]\n' "$topology_mode" "$role_result"
        printf '  defaultReplicaSet.primary           : %s\n' "$primary_ep"
        printf '  instanceErrors                      : %s [SCRIPT_CHECK=%s]\n' "$instance_errors" "$instance_result"
        printf '\nCluster.status({extended:2}).defaultReplicaSet.topology\n'
        printf '  address                         memberRole   memberState  mode\n'
        awk -F '\t' '{printf "  %-31s %-12s %-12s %s\n",$1,$2,$3,$4}' "$adminapi_topology"
        printf '\nperformance_schema.replication_group_members / system variables\n'
        printf '  MEMBER_HOST:MEMBER_PORT          MEMBER_ROLE  MEMBER_STATE  @@GLOBAL.read_only  @@GLOBAL.super_read_only\n'
        awk -F '\t' '{printf "  %-21s:%-5s %-12s %-13s %-20s %s\n",$1,$2,$4,$3,$6,$7}' "$member_runtime"
        printf '  MEMBER_STATE=ONLINE              : %s/%s [SCRIPT_CHECK=%s]\n' "$online" "$total" "$member_result"
        printf '\nperformance_schema.replication_group_member_stats\n'
        printf '  COUNT_TRANSACTIONS_IN_QUEUE                  : %s [SCRIPT_CHECK=%s]\n' "$cert_queue" "$queue_result"
        printf '  COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE   : %s [SCRIPT_CHECK=%s]\n' "$apply_queue" "$queue_result"
        printf '  COUNT_CONFLICTS_DETECTED                     : %s [SCRIPT_CHECK=%s]\n' "$conflicts" "$conflict_result"
        printf '\nGTID functions / variables\n'
        printf '  @@GLOBAL.gtid_executed with GTID_SUBSET() bidirectional comparison : EQUAL [SCRIPT_CHECK=PASS]\n'
        printf '\nCluster.describe() / performance_schema.replication_group_members\n'
        printf '  defaultReplicaSet.topology addresses vs MEMBER_HOST:MEMBER_PORT : %s [SCRIPT_CHECK=%s]\n' "$drift" "$drift_result"
        printf '\nCluster.options({all:true})\n'
        printf '  captured output                      : %s\n' "$ROOT/final_adminapi.txt"
        printf '\nCluster.listRouters()\n'
        printf '  routers                              : %s [SCRIPT_CHECK=%s]\n' "$router_count" "$router_result"
        printf '  SCRIPT_CHECK_ROUTING_TO_defaultReplicaSet.primary : %s\n' "$router_endpoint"
        printf '\nperformance_schema.error_log\n'
        printf '  SCRIPT_FILTER_MATCHES(last 24h)      : %s\n' "$error_result"
        printf '\n--------------------------------------------------------\n'
        printf 'SCRIPT_RESULT                          : %s\n' "$final"
        printf '%s\n' '--------------------------------------------------------'
        printf 'SCRIPT_EVIDENCE_DIRECTORY              : %s\n' "$ROOT"
        printf 'SCRIPT_NOTE                            : replication_group_member_stats values are point-in-time/cumulative observations; trend evaluation is an operational check.\n'
        [ "$router_endpoint" != EXTERNAL_CHECK_REQUIRED ] || printf 'SCRIPT_NOTE                            : verify MySQL Router application routing to defaultReplicaSet.primary=%s.\n' "$primary_ep"
    } > "$report"
    cat "$report" >&2

    [ "$cluster_result" = PASS ] || die "ERROR_CODE=CLUSTER_STATUS_NOT_OK STATUS=$cluster_status"
    [ "$member_result" = PASS ] || die 'ERROR_CODE=FINAL_MEMBER_STATE_FAILED'
    [ "$role_result" = PASS ] || die 'ERROR_CODE=FINAL_ROLE_VALIDATION_FAILED'
    [ "$drift_result" = PASS ] || die 'ERROR_CODE=METADATA_GR_TOPOLOGY_DRIFT'
    [ "$instance_result" != FAIL ] || die "ERROR_CODE=INSTANCE_ERRORS_PRESENT COUNT=$instance_errors"
}

validate(){
    require_discovery_schema
    [ -f "$ROOT/meta/complete" ] || die 'Run discover first'
    assert_identity
    meta_exists 1 || die 'mysql_innodb_cluster_metadata is absent'
    writeability_persistence_check
    name=''; [ ! -f "$ROOT/meta/cluster_name" ] || name=$(get meta cluster_name)
    code='var c=dba.getCluster(); print("IC_CLUSTER_NAME="+c.name); print("IC_STATUS="+JSON.stringify(c.status({extended:2}))); print("IC_DESCRIBE="+JSON.stringify(c.describe()));'
    out="$ROOT/validate.txt"
    mysqlsh_admin_exec 1 "$code" "$out" || { cat "$out" >&2; die 'dba.getCluster/status failed'; }
    members=$(grmembers 1); printf '%s\n' "$members" > "$ROOT/gr_members.after"
    total=$(printf '%s\n' "$members" | awk 'NF{n++} END{print n+0}')
    online=$(printf '%s\n' "$members" | awk '$4=="ONLINE"{n++} END{print n+0}')
    [ "$online" -eq "$total" ] || die "Cluster GR members not fully ONLINE ($online/$total)"
    [ "$total" -eq "$(get meta count)" ] || die 'ERROR_CODE=CLUSTER_MEMBER_COUNT_CHANGED'
    primary=$(printf '%s\n' "$members" | awk '$5=="PRIMARY"{n++} END{print n+0}')
    mode=$(gr_role_guard 1)
    all_node_gr_consistency_guard
    gtid_convergence_guard
    gr_writeability_guard
    if [ -f "$ROOT/meta/adopted_gr_mode" ]; then [ "$mode" = "$(get meta adopted_gr_mode)" ] || die "ERROR_CODE=ADOPTED_GR_MODE_CHANGED BEFORE=$(get meta adopted_gr_mode) AFTER=$mode"; fi
    for i in $(ids); do gtids "$i" > "$ROOT/node_${i}.gtid.after"; done
    final_operational_validation "$members" "$total" "$online" "$mode" "$primary"
    : > "$ROOT/meta/validated"
    log "VALIDATION PASSED: metadata present, $online/$total ONLINE, mode=$mode primary_count=$primary. Evidence: $ROOT"
    next_step status
}
status(){ require_discovery_schema; [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; assert_identity; log '--- Group Replication members ---'; grmembers 1; if meta_exists 1; then out="$ROOT/status.txt"; mysqlsh_admin_exec 1 'var c=dba.getCluster(); print(JSON.stringify(c.status({extended:1}))); print(JSON.stringify(c.describe()));' "$out" || { cat "$out" >&2; return 1; }; cat "$out"; else log 'InnoDB Cluster metadata: ABSENT'; fi; }
all(){ if [ ! -f "$ROOT/meta/complete" ]; then discover; fi; sql_precheck; if admin_ready; then precheck; else log 'ALL stopped: run configure-admin explicitly, then precheck. No account/configuration mutation is implicit.'; fi; }
case $STEP in help|-h|--help) help;; discover) discover;; capabilities) show_capabilities;; sql-precheck) sql_precheck;; strict-gtid) require_discovery_schema; [ -f "$ROOT/meta/complete" ] || die 'Run discover first'; assert_identity; strict_exact_gtid_guard; log 'STRICT GTID CHECK PASSED';; gr-restart-precheck) gr_restart_precheck;; configure-admin) configure_admin;; precheck) precheck;; configure) configure;; plan) plan;; create) create;; adopt) adopt;; validate) validate;; status) status;; all) all;; *) help; die "Unknown command: $STEP";; esac
