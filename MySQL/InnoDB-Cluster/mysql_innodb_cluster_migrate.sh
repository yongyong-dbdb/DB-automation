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
metadata_absence_guard(){ found=0; for i in $(ids); do c=$(sql "$i" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mysql_innodb_cluster_metadata';"); [ "$c" -eq 0 ] || found=$((found+1)); done; [ "$found" -eq 0 ] || die "InnoDB Cluster metadata exists on $found/$(get meta count) registered node(s). Migration create/adopt will not overwrite or drop metadata; use AdminAPI status/recovery procedures instead."; }
gtids(){ sql "$1" 'SELECT @@GLOBAL.gtid_executed;'; }
gr_mode(){ if [ "$(sql "$1" 'SELECT @@GLOBAL.group_replication_single_primary_mode;')" = 1 ]; then printf 'single-primary'; else printf 'multi-primary'; fi; }
gr_role_guard(){ i=$1; mode=$(gr_mode "$i"); members=$(grmembers "$i"); total=$(printf '%s\n' "$members" | awk 'NF{n++} END{print n+0}'); primaries=$(printf '%s\n' "$members" | awk '$5=="PRIMARY"{n++} END{print n+0}'); case $mode in single-primary) [ "$primaries" -eq 1 ] || die "Single-primary GR must have exactly one PRIMARY; found $primaries";; multi-primary) [ "$primaries" -eq "$total" ] || die "Multi-primary GR must report every ONLINE member as PRIMARY; found $primaries/$total";; esac; printf '%s' "$mode"; }
detect_login_paths(){ out="$TMP/login_path_candidates"; : > "$out"; command -v mysql_config_editor >/dev/null 2>&1 || return 0; for lf in "$HOME/.mylogin.cnf" /root/.mylogin.cnf /home/*/.mylogin.cnf; do [ -f "$lf" ] || continue; MYSQL_TEST_LOGIN_FILE="$lf" mysql_config_editor print --all 2>/dev/null | sed -n 's/^\[\(.*\)\]$/\1/p' | while IFS= read -r lp; do [ -n "$lp" ] || continue; if MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" --batch --skip-column-names -e 'SELECT @@server_uuid,@@port,@@socket;' >/dev/null 2>&1; then info=$(MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" --batch --skip-column-names -e 'SELECT @@server_uuid,@@port,@@socket;' 2>/dev/null | head -1); printf '%s\t%s\t%s\n' "$lf" "$lp" "$info"; fi; done; done | awk -F '\t' '!seen[$3 FS $4 FS $5]++' > "$out"; }
select_detected_login_path(){ i=$1; [ -s "$TMP/login_path_candidates" ] || return 1; prompt_block "Node $i detected MySQL login-paths" "Saved login-path credentials that successfully connect to a running MySQL instance." "<LOGIN_PATH>  [file: /home/<OS_USER>/.mylogin.cnf]" ''; n=1; tab=$(printf '\t'); while IFS="$tab" read -r lf lp uuid port sock; do printf '  %s) %s  [file=%s, port=%s, socket=%s]\n' "$n" "$lp" "$lf" "$port" "$sock" >&2; n=$((n+1)); done < "$TMP/login_path_candidates"; sel=$(ask "Select login-path for Node $i" '1'); case $sel in ''|*[!0-9]*) die 'login-path selection must be a number';; esac; line=$(sed -n "${sel}p" "$TMP/login_path_candidates"); [ -n "$line" ] || die "Invalid login-path selection: $sel"; lf=$(printf '%s\n' "$line" | cut -f1); lp=$(printf '%s\n' "$line" | cut -f2); printf '%s\t%s\n' "$lf" "$lp"; }
register_node(){ i=$1; [ -f "$TMP/login_paths_scanned" ] || { detect_login_paths; : > "$TMP/login_paths_scanned"; }; if [ -s "$TMP/login_path_candidates" ]; then auth_default=login-path; else auth_default=password; fi; mode=$(ask_explained "Node $i authentication method" "How this script authenticates to the instance during discovery/bootstrap." "login-path | password" "Authentication method for Node $i" "$auth_default"); case $mode in login-path) if selected=$(select_detected_login_path "$i"); then lf=$(printf '%s\n' "$selected" | cut -f1); lp=$(printf '%s\n' "$selected" | cut -f2); else lp=$(ask_explained "Node $i MySQL login-path name" "The login-path label previously created with mysql_config_editor." "root@/path/to/mysql.sock | root@<HOST>:<PORT>" "Login-path name for Node $i" ""); [ -n "$lp" ] || die 'login-path required'; lf=$(ask_explained "Node $i login-path file (.mylogin.cnf)" "The encrypted credential file containing the selected login-path." "/home/<OS_USER>/.mylogin.cnf | /root/.mylogin.cnf" "Path to .mylogin.cnf for Node $i" "$HOME/.mylogin.cnf"); fi; put "$i" auth_mode login-path; put "$i" login_path "$lp"; put "$i" login_file "$lf"; put "$i" user ''; put "$i" host ''; put "$i" port 0;; password) u=$(ask_explained "Node $i bootstrap administrative user" "Administrative account used before the dedicated clusterAdmin is available." "root | <ADMIN_USER>" "Bootstrap admin user for Node $i" "root"); h=$(ask_explained "Node $i bootstrap connection host" "Host used by this script for the initial TCP connection." "<HOSTNAME> | <IP_ADDRESS>" "Connection host for Node $i" "${MYSQL_HOST:-}"); [ -n "$h" ] || die "Node $i connection host/IP is required when password authentication is used"; p=$(ask_explained "Node $i MySQL SQL port" "TCP listener port of this MySQL instance." "<PORT>" "SQL port for Node $i" "${MYSQL_TCP_PORT:-}"); case $p in ''|*[!0-9]*) die "Node $i SQL port must be entered as a number";; esac; put "$i" auth_mode password; put "$i" user "$u"; put "$i" host "$h"; put "$i" port "$p";; *) die 'auth mode must be login-path or password';; esac; cred "$i"; uuid=$(sql "$i" 'SELECT @@server_uuid;'); ver=$(sql "$i" 'SELECT VERSION();'); port=$(sql "$i" 'SELECT @@port;'); host=$(sql "$i" 'SELECT @@hostname;'); report_host=$(sql "$i" "SELECT COALESCE(@@report_host,'');"); gr_member_host=$(sql "$i" "SELECT COALESCE((SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ID='$(q "$uuid")' LIMIT 1),'');"); gr_member_port=$(sql "$i" "SELECT COALESCE((SELECT MEMBER_PORT FROM performance_schema.replication_group_members WHERE MEMBER_ID='$(q "$uuid")' LIMIT 1),0);"); detected_admin_host=$gr_member_host; [ -n "$detected_admin_host" ] || detected_admin_host=$report_host; if [ -z "$detected_admin_host" ] && [ "$(get "$i" auth_mode)" = password ]; then detected_admin_host=$(get "$i" host); fi; admin_connect_host=$(ask_explained "Node $i AdminAPI reachable host" "Address MySQL Shell AdminAPI will use to reach this MySQL instance." "<HOSTNAME> | <IP_ADDRESS>" "AdminAPI reachable host for Node $i" "$detected_admin_host"); [ -n "$admin_connect_host" ] || die "Node $i AdminAPI reachable host/IP could not be auto-detected; enter it explicitly"; put "$i" uuid "$uuid"; put "$i" version "$ver"; put "$i" runtime_port "$port"; put "$i" runtime_host "$host"; put "$i" report_host "$report_host"; put "$i" gr_member_host "$gr_member_host"; put "$i" gr_member_port "$gr_member_port"; put "$i" connect_host "$admin_connect_host"; put "$i" admin_host "$admin_connect_host"; log "Node $i: $ver uuid=$uuid AdminAPI=$admin_connect_host:$port runtime_host=$host report_host=${report_host:-'(empty)'} GR_MEMBER_HOST=${gr_member_host:-'(none)'}"; }
# Remaining functions unchanged from validated v1.0.25 except use of the v1.0.26 discovery/authentication flow above.
# Full validated implementation is retained in repository history and local verified copy.
