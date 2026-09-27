#!/bin/sh
# mysql_innodb_cluster_preflight.sh v1.0.2
# POSIX /bin/sh. Read-only preflight companion for mysql_innodb_cluster_migrate.sh.
# No package installation, no third-party runtime, no hard-coded host/port/path/version policy.
set -eu
umask 077

VERSION=1.0.2
ROOT=${MYSQL_IC_WORK_ROOT:-"$(pwd)/mysql_innodb_cluster_work"}
MYSQL=${MYSQL_IC_MYSQL:-mysql}
MYSQLSH=${MYSQL_IC_MYSQLSH:-mysqlsh}
STEP=${1:-all}
TMP=''
MANUAL_CHECKS=0
WARNINGS=0

log(){ printf '%s\n' "$*" >&2; }
warn(){ WARNINGS=$((WARNINGS+1)); log "WARNING: $*"; }
die(){ log "ERROR: $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "$1 is required and must already be installed; this script never installs packages."; }
cleanup(){ [ -z "${TMP:-}" ] || rm -rf "$TMP"; }
trap cleanup 0 1 2 15

need "$MYSQL"
[ -d "$ROOT/meta" ] || die "Work root metadata is absent: $ROOT/meta. Run mysql_innodb_cluster_migrate.sh discover first."
[ -f "$ROOT/meta/complete" ] || die "Discovery is incomplete. Run mysql_innodb_cluster_migrate.sh discover first."
TMP=$(mktemp -d "$ROOT/.preflight.XXXXXX")
chmod 700 "$TMP" 2>/dev/null || :
TAB=$(printf '\t')

get(){ cat "$ROOT/$1/$2"; }
get_optional(){ [ -f "$ROOT/$1/$2" ] && cat "$ROOT/$1/$2" || :; }
ids(){ n=1; c=$(get meta count); while [ "$n" -le "$c" ]; do printf '%s\n' "$n"; n=$((n+1)); done; }
manual(){ MANUAL_CHECKS=$((MANUAL_CHECKS+1)); log "MANUAL_CHECK_REQUIRED: $*"; }

secret(){
    printf '%s: ' "$1" >&2
    if [ -t 0 ]; then
        old=$(stty -g) || return 1
        trap 'stty "$old" 2>/dev/null || :; exit 130' 1 2 15
        stty -echo
        IFS= read -r v; rc=$?
        stty "$old" 2>/dev/null || :
        trap cleanup 1 2 15
        printf '\n' >&2
        [ "$rc" -eq 0 ] || return "$rc"
    else
        IFS= read -r v || return 1
    fi
    printf '%s' "$v"
}

cred(){
    i=$1
    [ -f "$TMP/$i.pw" ] && return 0
    [ "$(get "$i" auth_mode)" = login-path ] && return 0
    user=$(get "$i" user)
    pw=$(secret "Node $i password for $user")
    printf '%s\n' "$pw" > "$TMP/$i.pw"
    chmod 600 "$TMP/$i.pw"
}

node_host(){
    i=$1
    h=$(get_optional "$i" connect_host)
    [ -n "$h" ] || h=$(get "$i" host)
    printf '%s' "$h"
}
node_port(){
    i=$1
    p=$(get_optional "$i" runtime_port)
    [ -n "$p" ] || p=$(get "$i" port)
    printf '%s' "$p"
}

mysql_cmd(){
    i=$1; shift
    if [ "$(get "$i" auth_mode)" = login-path ]; then
        lp=$(get "$i" login_path); lf=$(get "$i" login_file)
        MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" "$@"
    else
        cred "$i"
        pw=$(cat "$TMP/$i.pw")
        MYSQL_PWD="$pw" "$MYSQL" -h "$(node_host "$i")" -P "$(node_port "$i")" -u "$(get "$i" user)" --protocol=TCP "$@"
    fi
}
sql(){ i=$1; stmt=$2; printf '%s\n' "$stmt" | mysql_cmd "$i" --batch --raw --skip-column-names; }

placement(){ get_optional "$1" placement; }
valid_port(){ case $1 in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }

clone_precheck(){
    need "$MYSQLSH"
    donor=${MYSQL_IC_CLONE_DONOR:-1}
    margin=${MYSQL_IC_CLONE_SPACE_MARGIN_PERCENT:-10}
    case $donor in ''|*[!0-9]*) die "MYSQL_IC_CLONE_DONOR must be a node number";; esac
    case $margin in ''|*[!0-9]*) die "MYSQL_IC_CLONE_SPACE_MARGIN_PERCENT must be a non-negative integer";; esac
    [ "$donor" -ge 1 ] && [ "$donor" -le "$(get meta count)" ] || die "Clone donor node is outside the registered range: $donor"

    shell_ver=$($MYSQLSH --version 2>/dev/null | sed -n '1p' || :)
    log "CLONE_COMPATIBILITY_AUTHORITY=AdminAPI_runtime mysqlsh=${shell_ver:-UNKNOWN}"
    log 'CLONE_VERSION_POLICY=not_hard_coded; Cluster.addInstance(recoveryMethod=clone) performs the authoritative runtime version compatibility check.'

    dver=$(sql "$donor" 'SELECT VERSION();')
    dos=$(sql "$donor" 'SELECT @@version_compile_os;')
    darch=$(sql "$donor" 'SELECT @@version_compile_machine;')
    ddatadir=$(sql "$donor" 'SELECT @@datadir;')
    dplugin=$(sql "$donor" "SELECT COALESCE((SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='clone' LIMIT 1),'NOT_INSTALLED');")
    log "CLONE_DONOR node=$donor version=$dver os=$dos arch=$darch plugin=$dplugin datadir=$ddatadir"
    [ "$dplugin" = ACTIVE ] || warn "Clone plugin is not ACTIVE on donor node $donor ($dplugin). AdminAPI may install it when Clone recovery is selected; this preflight never installs plugins."

    donor_kb=''
    if [ "$(placement "$donor")" = local ] && [ -d "$ddatadir" ]; then
        donor_kb=$(du -sk "$ddatadir" 2>/dev/null | awk 'NR==1{print $1}')
        case $donor_kb in ''|*[!0-9]*) donor_kb='';; esac
    fi
    [ -n "$donor_kb" ] || manual "Clone donor data size could not be measured locally. On node $donor run: du -sk '$ddatadir'"

    outside=$(sql "$donor" "SELECT COUNT(*) FROM information_schema.FILES WHERE FILE_NAME IS NOT NULL AND FILE_NAME LIKE '/%' AND FILE_NAME NOT LIKE CONCAT(@@datadir,'%');" 2>/dev/null || printf 'UNKNOWN')
    case $outside in
        ''|*[!0-9]*) manual 'Could not determine whether clone-relevant tablespace files exist outside @@datadir; include external tablespaces in the donor size estimate.';;
        0) :;;
        *) manual "Donor reports $outside absolute tablespace file record(s) outside @@datadir. Add their filesystem usage to the clone capacity estimate.";;
    esac

    for i in $(ids); do
        [ "$i" -eq "$donor" ] && continue
        rver=$(sql "$i" 'SELECT VERSION();')
        ros=$(sql "$i" 'SELECT @@version_compile_os;')
        rarch=$(sql "$i" 'SELECT @@version_compile_machine;')
        rdatadir=$(sql "$i" 'SELECT @@datadir;')
        rplugin=$(sql "$i" "SELECT COALESCE((SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='clone' LIMIT 1),'NOT_INSTALLED');")
        log "CLONE_RECIPIENT node=$i version=$rver os=$ros arch=$rarch plugin=$rplugin datadir=$rdatadir"

        [ "$dos" = "$ros" ] || die "ERROR_CODE=CLONE_OS_INCOMPATIBLE DONOR=$dos RECIPIENT=$ros NODE=$i"
        [ "$darch" = "$rarch" ] || die "ERROR_CODE=CLONE_PLATFORM_INCOMPATIBLE DONOR=$darch RECIPIENT=$rarch NODE=$i"
        if [ "$dver" = "$rver" ]; then
            log "CLONE_VERSION_INVENTORY node=$i donor=$dver recipient=$rver exact_match=yes"
        else
            log "CLONE_VERSION_INVENTORY node=$i donor=$dver recipient=$rver exact_match=no authoritative_check=AdminAPI"
        fi
        [ "$rplugin" = ACTIVE ] || warn "Clone plugin is not ACTIVE on recipient node $i ($rplugin). AdminAPI may install it when Clone recovery is selected."

        if [ -n "$donor_kb" ] && [ "$(placement "$i")" = local ] && [ -d "$rdatadir" ]; then
            avail=$(df -Pk "$rdatadir" 2>/dev/null | awk 'END{print $4}')
            case $avail in ''|*[!0-9]*) avail='';; esac
            if [ -n "$avail" ]; then
                required=$((donor_kb + (donor_kb * margin / 100)))
                log "CLONE_SPACE_ESTIMATE node=$i donor_datadir_used_kb=$donor_kb available_kb=$avail required_with_margin_kb=$required margin_percent=$margin"
                [ "$avail" -ge "$required" ] || die "ERROR_CODE=CLONE_RECIPIENT_DISK_INSUFFICIENT NODE=$i AVAILABLE_KB=$avail REQUIRED_KB=$required"
            else
                manual "Recipient free space could not be measured. On node $i run: df -Pk '$rdatadir'"
            fi
        else
            manual "Clone disk capacity requires node-local filesystem evidence for recipient node $i. Run donor: du -sk '$ddatadir' ; recipient: df -Pk '$rdatadir' ; require recipient available KB >= donor used KB plus configured margin, plus external tablespace usage if present."
        fi
    done
    log 'CLONE_PREFLIGHT=PASS_WITH_ADMINAPI_VERSION_CHECK_AT_ADDINSTANCE'
}

resolved_tls_mode(){
    requested=${MYSQL_IC_TLS_MODE:-AUTO}
    case $requested in AUTO|DISABLED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY) :;; *) die "Invalid MYSQL_IC_TLS_MODE: $requested";; esac
    if [ "$requested" != AUTO ]; then printf '%s' "$requested"; return; fi
    mode=''
    for i in $(ids); do
        m=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_ssl_mode,'');" 2>/dev/null || printf '')
        [ -n "$m" ] || continue
        [ -z "$mode" ] && mode=$m
        [ "$m" = "$mode" ] || die "ERROR_CODE=GR_SSL_MODE_MISMATCH NODE=$i VALUE=$m REFERENCE=$mode"
    done
    [ -n "$mode" ] || mode=REQUIRED
    printf '%s' "$mode"
}

tls_connect_test(){
    i=$1; mode=$2; ca=$3
    host=$(node_host "$i"); port=$(node_port "$i")
    if [ "$(get "$i" auth_mode)" = login-path ]; then
        lp=$(get "$i" login_path); lf=$(get "$i" login_file)
        MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQL" --login-path="$lp" --host="$host" --port="$port" --protocol=TCP --ssl-mode="$mode" --ssl-ca="$ca" --batch --skip-column-names -e 'SELECT 1;' >/dev/null
    else
        cred "$i"; pw=$(cat "$TMP/$i.pw")
        MYSQL_PWD="$pw" "$MYSQL" -h "$host" -P "$port" -u "$(get "$i" user)" --protocol=TCP --ssl-mode="$mode" --ssl-ca="$ca" --batch --skip-column-names -e 'SELECT 1;' >/dev/null
    fi
}

tls_precheck(){
    mode=$(resolved_tls_mode)
    log "TLS_MODE=$mode"
    for i in $(ids); do
        have=$(sql "$i" "SELECT COALESCE(@@have_ssl,'');")
        ca_server=$(sql "$i" "SELECT COALESCE(@@ssl_ca,'');")
        cert_server=$(sql "$i" "SELECT COALESCE(@@ssl_cert,'');")
        grmode=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_ssl_mode,'');" 2>/dev/null || printf '')
        log "TLS_NODE node=$i have_ssl=$have gr_ssl_mode=${grmode:-UNAVAILABLE} server_ssl_ca=${ca_server:-EMPTY} server_ssl_cert=${cert_server:-EMPTY} endpoint=$(node_host "$i"):$(node_port "$i")"
        case $mode in DISABLED) :;; *) [ "$have" = YES ] || die "ERROR_CODE=TLS_UNAVAILABLE NODE=$i HAVE_SSL=$have";; esac
    done

    case $mode in
        VERIFY_CA|VERIFY_IDENTITY)
            ca=${MYSQL_IC_TLS_CA:-}
            [ -n "$ca" ] || die "MYSQL_IC_TLS_CA must point to a CA file on the execution host when TLS mode is $mode"
            [ -r "$ca" ] || die "TLS CA file is not readable on the execution host: $ca"
            for i in $(ids); do
                host=$(node_host "$i")
                [ -n "$host" ] || die "ERROR_CODE=TLS_ENDPOINT_HOST_EMPTY NODE=$i"
                if tls_connect_test "$i" "$mode" "$ca"; then
                    log "TLS_VERIFY=PASS node=$i mode=$mode host=$host"
                else
                    die "ERROR_CODE=TLS_VERIFY_FAILED NODE=$i MODE=$mode HOST=$host. VERIFY_IDENTITY validates the connection host against the certificate identity as implemented by the installed MySQL client."
                fi
            done
            ;;
        REQUIRED) log 'TLS_VERIFY=ENCRYPTION_REQUIRED. CA/identity verification is not requested by this mode.';;
        DISABLED) warn 'TLS is explicitly disabled for this preflight mode.';;
    esac
    log 'TLS_PREFLIGHT=PASS'
}

endpoint_host(){ printf '%s\n' "$1" | sed 's/:\([0-9][0-9]*\)$//' | sed 's/^\[//;s/\]$//'; }
endpoint_port(){ printf '%s\n' "$1" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p'; }

communication_stack(){
    requested=${MYSQL_IC_COMMUNICATION_STACK:-AUTO}
    case $requested in AUTO|XCOM|MYSQL) :;; *) die "Invalid MYSQL_IC_COMMUNICATION_STACK: $requested";; esac
    [ "$requested" = AUTO ] || { printf '%s' "$requested"; return; }
    s=$(sql 1 "SELECT COALESCE(@@GLOBAL.group_replication_communication_stack,'');" 2>/dev/null || printf '')
    [ -n "$s" ] || s=XCOM
    printf '%s' "$s"
}

build_gr_endpoints(){
    stack=$1
    out="$ROOT/preflight_gr_endpoints.tsv"
    only="$TMP/gr_endpoints.only"
    : > "$out"; : > "$only"
    for i in $(ids); do
        la=$(sql "$i" "SELECT COALESCE(@@GLOBAL.group_replication_local_address,'');" 2>/dev/null || printf '')
        if [ -z "$la" ]; then
            rh=$(sql "$i" "SELECT COALESCE(NULLIF(@@report_host,''),@@hostname);")
            sqlp=$(sql "$i" 'SELECT @@port;')
            if [ "$stack" = XCOM ]; then p=$((sqlp * 10 + 1)); else p=$sqlp; fi
            valid_port "$p" || die "ERROR_CODE=GR_LOCAL_ADDRESS_PORT_INVALID NODE=$i COMPUTED_PORT=$p SQL_PORT=$sqlp STACK=$stack"
            la="$rh:$p"
        fi
        h=$(endpoint_host "$la"); p=$(endpoint_port "$la")
        [ -n "$h" ] || die "ERROR_CODE=GR_LOCAL_ADDRESS_HOST_INVALID NODE=$i VALUE=$la"
        valid_port "$p" || die "ERROR_CODE=GR_LOCAL_ADDRESS_PORT_INVALID NODE=$i VALUE=$la"
        printf '%s\t%s\t%s\t%s\n' "$i" "$h" "$p" "$la" >> "$out"
        printf '%s\n' "$la" >> "$only"
    done
    dup=$(sort "$only" | uniq -d | sed -n '1p')
    [ -z "$dup" ] || die "ERROR_CODE=DUPLICATE_GR_LOCAL_ADDRESS VALUE=$dup"
    cat "$out" >&2
}

probe_cmd(){
    if command -v nc >/dev/null 2>&1; then printf 'nc'; elif command -v ncat >/dev/null 2>&1; then printf 'ncat'; else printf ''; fi
}
probe_tcp(){ tool=$1; h=$2; p=$3; "$tool" -z -w 3 "$h" "$p" >/dev/null 2>&1; }

xcom_precheck(){
    stack=$(communication_stack)
    case $stack in XCOM|MYSQL) :;; *) die "Unsupported Group Replication communication stack: $stack";; esac
    log "COMMUNICATION_STACK=$stack"
    build_gr_endpoints "$stack"
    eps="$ROOT/preflight_gr_endpoints.tsv"

    active=0
    for i in $(ids); do
        c=$(sql "$i" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE<>'OFFLINE';" 2>/dev/null || printf '0')
        [ "$c" -gt "$active" ] && active=$c
    done

    tool=$(probe_cmd)
    if [ "$stack" = XCOM ] && [ "$active" -gt 0 ]; then
        if [ -n "$tool" ]; then
            while IFS="$TAB" read -r i h p la; do
                if probe_tcp "$tool" "$h" "$p"; then
                    log "EXECUTION_HOST_XCOM_REACHABILITY=PASS node=$i endpoint=$la probe=$tool"
                else
                    warn "Execution host cannot open XCOM endpoint $la for node $i. This does not prove peer-to-peer failure because firewall policy may differ by source."
                    manual "Validate XCOM endpoint $la from every other GR member."
                fi
            done < "$eps"
        else
            manual 'No preinstalled nc/ncat is available, so execution-host TCP reachability was not tested. No package is installed automatically.'
        fi
    elif [ "$stack" = XCOM ]; then
        log 'XCOM listeners are not active yet; pre-create TCP failure would be ambiguous, so endpoint syntax/range/uniqueness is checked now and pairwise live tests are deferred until listeners are active.'
    else
        log 'MYSQL communication stack selected; registered Classic TCP connectivity has already been exercised by SQL discovery/preflight queries.'
    fi

    if [ "$stack" = XCOM ]; then
        hint=${tool:-nc}
        log 'Pairwise XCOM validation commands (run on each source node OS after the XCOM listeners are active; use an already-approved TCP probe utility):'
        while IFS="$TAB" read -r src shost sport sla; do
            log "  Source Node $src:"
            while IFS="$TAB" read -r dst dhost dport dla; do
                [ "$src" = "$dst" ] && continue
                log "    $hint -z -w 3 '$dhost' '$dport'    # target Node $dst $dla"
            done < "$eps"
        done < "$eps"
        manual 'True node-to-node XCOM reachability cannot be proven from one execution host without remote command execution. Validate every source-to-target pair after listeners are active; firewall/SELinux policy must allow the selected localAddress ports.'
    fi
    log 'COMMUNICATION_PREFLIGHT=PASS_WITH_PAIRWISE_CHECK_REQUIREMENT'
}

summary(){
    if [ "$MANUAL_CHECKS" -gt 0 ]; then
        log "PREFLIGHT_RESULT=PASS_WITH_MANUAL_CHECKS manual_checks=$MANUAL_CHECKS warnings=$WARNINGS"
    elif [ "$WARNINGS" -gt 0 ]; then
        log "PREFLIGHT_RESULT=PASS_WITH_WARNINGS warnings=$WARNINGS"
    else
        log 'PREFLIGHT_RESULT=PASS'
    fi
}

usage(){ cat >&2 <<EOF
mysql_innodb_cluster_preflight.sh v$VERSION
Usage: sh $0 all|clone|tls|xcom

Reads discovery metadata from MYSQL_IC_WORK_ROOT created by mysql_innodb_cluster_migrate.sh.
Environment:
  MYSQL_IC_WORK_ROOT
  MYSQL_IC_MYSQL
  MYSQL_IC_MYSQLSH
  MYSQL_IC_CLONE_DONOR                  node number, default 1
  MYSQL_IC_CLONE_SPACE_MARGIN_PERCENT   default 10
  MYSQL_IC_TLS_MODE                     AUTO|DISABLED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY
  MYSQL_IC_TLS_CA                       CA file on this execution host for VERIFY_CA/VERIFY_IDENTITY
  MYSQL_IC_COMMUNICATION_STACK          AUTO|XCOM|MYSQL

Clone version compatibility is deliberately not hard-coded. The installed MySQL Shell/AdminAPI performs the authoritative check when Cluster.addInstance() runs.
No packages, plugins, runtimes, firewall rules, SELinux rules, GTIDs, or MySQL configuration are modified.
EOF
}

case $STEP in
    all) clone_precheck; tls_precheck; xcom_precheck; summary;;
    clone) clone_precheck; summary;;
    tls) tls_precheck; summary;;
    xcom|communication) xcom_precheck; summary;;
    help|-h|--help) usage;;
    *) usage; die "Unknown command: $STEP";;
esac
