#!/bin/sh
# Oracle MySQL Community RPM Bundle installer
# POSIX /bin/sh, no third-party runtime dependency
SCRIPT_VERSION="1.0.11"
set -u
umask 027

MODE="install"
BUNDLE_ARG=""
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
WORKDIR=""
BLOCKERS=0
WARNINGS=0
ROLLBACK_ACTIVE=no
ROLLBACK_DONE=no
CREATED_CONF=no
CREATED_UNIT=no
SERVICE_STARTED=no
SERVICE_ENABLED=no
PACKAGE_CHANGED=no
CUSTOM_USER_CREATED=no
CUSTOM_GROUP_CREATED=no
DATADIR_INITIALIZED=no
DATADIR_CREATED=no
CONF_PARENT_CREATED=no
CREATED_PATHS=""
SELINUX_FCONTEXT_ADDED=""
SELINUX_PORT_ADDED=""

log()  { printf '%s\n' "[INFO] $*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '%s\n' "[WARN] $*" >&2; }
block(){ BLOCKERS=$((BLOCKERS + 1)); printf '%s\n' "[BLOCK] $*" >&2; }

rollback_changes() {
    [ "${ROLLBACK_ACTIVE:-no}" = yes ] || return 0
    ROLLBACK_ACTIVE=no
    printf '%s\n' "[ROLLBACK] Reverting instance-level changes created by this run" >&2
    if [ "${SERVICE_STARTED:-no}" = yes ]; then systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true; fi
    if [ "${SERVICE_ENABLED:-no}" = yes ]; then systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true; fi
    if [ "${CREATED_UNIT:-no}" = yes ] && [ -n "${UNIT_FILE:-}" ]; then rm -f "$UNIT_FILE"; systemctl daemon-reload >/dev/null 2>&1 || true; fi
    if [ "${CREATED_CONF:-no}" = yes ] && [ -n "${CONF:-}" ]; then rm -f "$CONF"; fi
    # Known instance files are required to be absent by precheck; remove only files created by this run.
    for _f in "${INIT_LOG:-}" "${LOGFILE:-}" "${SLOWLOG:-}" "${PIDFILE:-}" "${SOCKET:-}" "${SOCKET:-}.lock" "${MYSQLX_SOCKET:-}" "${MYSQLX_SOCKET:-}.lock"; do
        [ -n "$_f" ] && [ "$_f" != ".lock" ] && rm -f "$_f" 2>/dev/null || true
    done
    for _p in ${SELINUX_PORT_ADDED:-}; do semanage port -d -p tcp "$_p" >/dev/null 2>&1 || true; done
    for _e in ${SELINUX_FCONTEXT_ADDED:-}; do semanage fcontext -d "$_e" >/dev/null 2>&1 || true; done
    if [ "${INITIALIZE_ATTEMPTED:-no}" = yes ] && [ "${DATADIR_CREATED:-no}" != yes ] && [ -d "${DATADIR:-}" ]; then
        find "$DATADIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    fi
    for _d in ${CREATED_PATHS:-}; do [ -n "$_d" ] && rm -rf "$_d" 2>/dev/null || true; done
    if [ -n "${WORKDIR:-}" ] && [ -f "$WORKDIR/preexisting_dirs.meta" ]; then
        while IFS='|' read -r _uid _gid _mode _ctx _path; do
            [ -d "$_path" ] || continue
            chown "$_uid:$_gid" "$_path" >/dev/null 2>&1 || true
            chmod "$_mode" "$_path" >/dev/null 2>&1 || true
            case "$_ctx" in *:*) chcon "$_ctx" "$_path" >/dev/null 2>&1 || true ;; esac
        done < "$WORKDIR/preexisting_dirs.meta"
    fi
    if [ "${CUSTOM_USER_CREATED:-no}" = yes ] && [ -n "${OS_USER:-}" ]; then userdel "$OS_USER" >/dev/null 2>&1 || true; fi
    if [ "${CUSTOM_GROUP_CREATED:-no}" = yes ] && [ -n "${OS_GROUP:-}" ]; then groupdel "$OS_GROUP" >/dev/null 2>&1 || true; fi
    if [ "${PACKAGE_CHANGED:-no}" = yes ]; then
        printf '%s\n' "[ROLLBACK] RPM transaction retained intentionally; automatic package removal can remove shared dependencies or affect other instances" >&2
    fi
    ROLLBACK_DONE=yes
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    rollback_changes
    exit 1
}

cleanup() {
    [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}
on_signal() {
    rollback_changes
    cleanup
    exit 130
}
trap cleanup EXIT
trap on_signal HUP INT TERM

usage() {
    echo "Usage: sh $0 [--bundle /path/mysql-*.rpm-bundle.tar] [--precheck-only|--dry-run]"
}
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) [ $# -ge 2 ] || die "--bundle requires a path"; BUNDLE_ARG=$2; shift 2 ;;
        --precheck-only) MODE="precheck"; shift ;;
        --dry-run) MODE="dryrun"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

ask() {
    ASK_PROMPT=$1
    ASK_DEFAULT=${2-}
    if [ -n "$ASK_DEFAULT" ]; then
        printf '%s' "$ASK_PROMPT [$ASK_DEFAULT]: " >&2
    else
        printf '%s' "$ASK_PROMPT: " >&2
    fi
    if ! IFS= read -r ASK_INPUT; then
        die "Input aborted"
    fi
    [ -n "$ASK_INPUT" ] || ASK_INPUT=$ASK_DEFAULT
    ASK_RESULT=$ASK_INPUT
}

ask_yn() {
    YN_PROMPT=$1
    YN_DEFAULT=${2:-yes}
    while :; do
        ask "$YN_PROMPT (yes/no)" "$YN_DEFAULT"
        YN_VALUE=$ASK_RESULT
        case "$YN_VALUE" in y|Y|yes|YES|Yes) return 0 ;; n|N|no|NO|No) return 1 ;; esac
        echo "Enter yes or no." >&2
    done
}
version_ge() {
    awk -v A="$1" -v B="$2" 'BEGIN {
        na=split(A,a,"."); nb=split(B,b,"."); n=(na>nb?na:nb);
        for(i=1;i<=n;i++){x=(a[i]==""?0:a[i])+0; y=(b[i]==""?0:b[i])+0;
            if(x>y) exit 0; if(x<y) exit 1}
        exit 0
    }'
}

safe_path() {
    case "$1" in
        /*) ;;
        *) die "Absolute path required: $1" ;;
    esac
    case "$1" in
        *[!A-Za-z0-9_./-]*) die "Path contains unsupported characters: $1" ;;
    esac
}

valid_port() {
    case "$1" in *[!0-9]*|'') return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}
valid_nonnegative_number() {
    awk -v v="$1" 'BEGIN { if (v ~ /^[0-9]+([.][0-9]+)?$/ && v+0 >= 0) exit 0; exit 1 }'
}

port_busy() {
    _p=$1
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lnt 2>/dev/null | awk -v p="$_p" '{x=$4; sub(/^.*:/,"",x); if(x==p) found=1} END{exit(found?0:1)}'
}
config_candidates() {
    {
        find /etc -maxdepth 3 -type f \( -name 'my.cnf' -o -name 'my[0-9A-Za-z_.-]*.cnf' -o -name 'mysqld*.cnf' \) -print 2>/dev/null
        for _pid in $(pgrep mysqld 2>/dev/null); do
            [ -r "/proc/$_pid/cmdline" ] || continue
            tr '\0' '\n' < "/proc/$_pid/cmdline" 2>/dev/null | sed -n 's/^--defaults-file=//p'
        done
        if command -v systemctl >/dev/null 2>&1; then
            systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^(mysql|mysqld)/ {print $1}' | while IFS= read -r _u; do
                systemctl cat "$_u" 2>/dev/null | sed -n 's/.*--defaults-file=\([^[:space:]]*\).*/\1/p'
            done
        fi
        for _sf in /etc/sysconfig/mysql*; do
            [ -f "$_sf" ] || continue
            sed -n 's/.*--defaults-file=\([^[:space:]]*\).*/\1/p' "$_sf" 2>/dev/null
        done
    } | awk 'NF && !seen[$0]++' | while IFS= read -r _f; do
        [ -f "$_f" ] || continue
        case "$_f" in *.bak|*.backup*|*.rpmnew|*.rpmsave|*.orig) continue ;; esac
        printf '%s\n' "$_f"
    done
}
config_option_value() {
    _cf=$1; _opt=$2
    if command -v my_print_defaults >/dev/null 2>&1; then
        my_print_defaults --defaults-file="$_cf" mysqld 2>/dev/null | sed -n "s/^--${_opt}=//p" | tail -n 1
    else
        if grep -Eq '^[[:space:]]*![[:space:]]*include(dir)?[[:space:]]+' "$_cf" 2>/dev/null; then
            warn "my_print_defaults not available; include chain cannot be resolved safely for $_cf"
        fi
        awk -v key="$_opt" '
            BEGIN{in_mysqld=0}
            /^[[:space:]]*\[mysqld\][[:space:]]*$/ {in_mysqld=1; next}
            /^[[:space:]]*\[/ {in_mysqld=0}
            in_mysqld {
                line=$0; sub(/[;#].*$/, "", line)
                split(line,a,"="); k=a[1]; gsub(/[[:space:]_-]/,"",k)
                kk=key; gsub(/[[:space:]_-]/,"",kk)
                if(k==kk){sub(/^[^=]*=[[:space:]]*/,"",line); gsub(/[[:space:]]+$/,"",line); val=line}
            }
            END{if(val!="") print val}
        ' "$_cf"
    fi
}
configured_option_owner() {
    _opt=$1; _want=$2
    config_candidates | while IFS= read -r _cf; do
        _got=$(config_option_value "$_cf" "$_opt")
        [ -n "$_got" ] && [ "$_got" = "$_want" ] && { printf '%s\n' "$_cf"; exit 0; }
    done
}
configured_port_owner() {
    _want=$1
    if [ -n "${CONFIG_PORT_CACHE:-}" ] && [ -f "$CONFIG_PORT_CACHE" ]; then
        awk -F'|' -v p="$_want" '$1=="port" && $2==p {print $3; exit}' "$CONFIG_PORT_CACHE"
    else
        configured_option_owner port "$_want"
    fi
}
configured_mysqlx_port_owner() {
    _want=$1
    if [ -n "${CONFIG_PORT_CACHE:-}" ] && [ -f "$CONFIG_PORT_CACHE" ]; then
        awk -F'|' -v p="$_want" '$1=="mysqlx-port" && $2==p {print $3; exit}' "$CONFIG_PORT_CACHE"
    else
        configured_option_owner mysqlx-port "$_want"
    fi
}
refresh_collision_cache() {
    CONFIG_PORT_CACHE="$WORKDIR/config_ports.cache"
    SELINUX_PORT_CACHE="$WORKDIR/selinux_ports.cache"
    : > "$CONFIG_PORT_CACHE"
    config_candidates | while IFS= read -r _cf; do
        _p=$(config_option_value "$_cf" port)
        valid_port "$_p" && printf 'port|%s|%s\n' "$_p" "$_cf"
        _xp=$(config_option_value "$_cf" mysqlx-port)
        valid_port "$_xp" && printf 'mysqlx-port|%s|%s\n' "$_xp" "$_cf"
    done > "$CONFIG_PORT_CACHE"
    : > "$SELINUX_PORT_CACHE"
    if [ "$(getenforce 2>/dev/null || echo Disabled)" != Disabled ] && command -v semanage >/dev/null 2>&1; then
        semanage port -l > "$SELINUX_PORT_CACHE" 2>/dev/null || : > "$SELINUX_PORT_CACHE"
    fi
}
selinux_conflicting_port_type() {
    _p=$1
    [ "$(getenforce 2>/dev/null || echo Disabled)" != Disabled ] || return 1
    if [ -n "${SELINUX_PORT_CACHE:-}" ] && [ -s "$SELINUX_PORT_CACHE" ]; then
        _src=$SELINUX_PORT_CACHE
    else
        command -v semanage >/dev/null 2>&1 || return 1
        _src="$WORKDIR/selinux_ports.live"
        semanage port -l > "$_src" 2>/dev/null || return 1
    fi
    awk -v p="$_p" '
        $2=="tcp" && $1!="mysqld_port_t" && $1!="unreserved_port_t" && $1!="ephemeral_port_t" {
            for(i=3;i<=NF;i++){
                x=$i; gsub(/,/,"",x)
                if(x ~ /^[0-9]+$/ && x+0==p){print $1; exit}
                if(x ~ /^[0-9]+-[0-9]+$/){split(x,a,"-"); if(p>=a[1] && p<=a[2]){print $1; exit}}
            }
        }' "$_src"
}
find_free_port() {
    _p=3306
    while [ "$_p" -le 65535 ]; do
        _cf=$(configured_port_owner "$_p")
        _sel_t=$(selinux_conflicting_port_type "$_p" || true)
        if ! port_busy "$_p" && [ -z "$_cf" ] && [ -z "$_sel_t" ]; then printf '%s\n' "$_p"; return 0; fi
        _p=$((_p + 1))
    done
    die "No available TCP port found in range 3306-65535"
}

socket_busy() {
    _s=$1
    [ -S "$_s" ] && return 0
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lx 2>/dev/null | awk -v s="$_s" '$0 ~ s {found=1} END{exit(found?0:1)}'
}

path_nonempty() {
    [ -d "$1" ] || return 1
    [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

show_running_mysqld() {
    echo "-- Running mysqld processes --"
    pgrep -a mysqld 2>/dev/null || echo "(none)"
    if command -v ss >/dev/null 2>&1; then
        echo "-- Listening TCP ports owned by mysqld --"
        ss -lntp 2>/dev/null | grep -i mysqld || echo "(none detected)"
        echo "-- Unix sockets owned by mysqld --"
        ss -lxnp 2>/dev/null | grep -i mysqld || echo "(none detected)"
    fi
}
detect_bundle() {
    if [ -n "$BUNDLE_ARG" ]; then
        BUNDLE=$BUNDLE_ARG
    else
        _list=""
        for _dir in "$SCRIPT_DIR" "$(pwd)"; do
            [ -d "$_dir" ] || continue
            for _f in "$_dir"/*.tar; do
                [ -f "$_f" ] || continue
                tar -tf "$_f" 2>/dev/null | grep -qE '(^|/)mysql-community-server-[^/]+\.rpm$' || continue
                case "
$_list
" in *"
$_f
"*) ;; *) _list="${_list}${_list:+
}$_f" ;; esac
            done
        done
        _count=$(printf '%s\n' "$_list" | sed '/^$/d' | wc -l | awk '{print $1}')
        if [ "$_count" -eq 1 ]; then
            _candidate=$(printf '%s\n' "$_list" | sed -n '1p')
            ask "RPM bundle path" "$_candidate"; BUNDLE=$ASK_RESULT
        else
            [ "$_count" -gt 1 ] && { echo "Detected MySQL RPM bundle candidates:" >&2; printf '%s\n' "$_list" >&2; }
            ask "RPM bundle path" ""; BUNDLE=$ASK_RESULT
        fi
    fi
    safe_path "$BUNDLE"
    [ -r "$BUNDLE" ] || die "Bundle not readable: $BUNDLE"
    tar -tf "$BUNDLE" >/dev/null 2>&1 || die "Invalid tar archive: $BUNDLE"
    tar -tf "$BUNDLE" 2>/dev/null | grep -qE '(^|/)mysql-community-server-[^/]+\.rpm$' || die "Archive does not contain mysql-community-server RPM"
}
extract_bundle() {
    WORKDIR=$(mktemp -d /var/tmp/mysql-install.XXXXXX) || die "mktemp failed"
    tar -xf "$BUNDLE" -C "$WORKDIR" || die "Bundle extraction failed"
    RPM_COUNT=$(find "$WORKDIR" -maxdepth 1 -type f -name '*.rpm' | wc -l | awk '{print $1}')
    [ "$RPM_COUNT" -gt 0 ] || die "No RPM files found in bundle"
}
inspect_rpms() {
    SERVER_RPM=""; COMMON_RPM=""; CLIENT_RPM=""; PLUGINS_RPM=""; LIBS_RPM=""; ICU_RPM=""; COMPAT_RPM=""
    for _rpm in "$WORKDIR"/*.rpm; do
        [ -f "$_rpm" ] || continue
        _name=$(rpm -qp --qf '%{NAME}' "$_rpm" 2>/dev/null) || continue
        case "$_name" in
            mysql-community-server) SERVER_RPM=$_rpm ;;
            mysql-community-common) COMMON_RPM=$_rpm ;;
            mysql-community-client) CLIENT_RPM=$_rpm ;;
            mysql-community-client-plugins) PLUGINS_RPM=$_rpm ;;
            mysql-community-libs) LIBS_RPM=$_rpm ;;
            mysql-community-icu-data-files) ICU_RPM=$_rpm ;;
            mysql-community-libs-compat) COMPAT_RPM=$_rpm ;;
        esac
    done
    [ -n "$SERVER_RPM" ] || die "mysql-community-server RPM not found"
    [ -n "$COMMON_RPM" ] || die "mysql-community-common RPM not found"
    [ -n "$CLIENT_RPM" ] || die "mysql-community-client RPM not found"
    [ -n "$LIBS_RPM" ] || die "mysql-community-libs RPM not found"
    TARGET_VERSION=$(rpm -qp --qf '%{VERSION}' "$SERVER_RPM" 2>/dev/null)
    TARGET_RELEASE=$(rpm -qp --qf '%{RELEASE}' "$SERVER_RPM" 2>/dev/null)
    TARGET_ARCH=$(rpm -qp --qf '%{ARCH}' "$SERVER_RPM" 2>/dev/null)
    TARGET_VENDOR=$(rpm -qp --qf '%{VENDOR}' "$SERVER_RPM" 2>/dev/null)
    TARGET_MYSQLD_PATH=$(rpm -qpl "$SERVER_RPM" 2>/dev/null | awk '/\/mysqld$/ {print; exit}')
    [ -n "$TARGET_MYSQLD_PATH" ] || die "mysqld path not found in server RPM"
    safe_path "$TARGET_MYSQLD_PATH"
    case "$TARGET_VERSION" in 8.*|9.*) ;; *) die "Supported MySQL major versions: 8.x and 9.x; found $TARGET_VERSION" ;; esac
    echo "$TARGET_VENDOR" | grep -qi 'Oracle' || die "Server RPM vendor is not Oracle: $TARGET_VENDOR"
}
build_core_rpm_list() {
    CORE_RPMS="$COMMON_RPM $LIBS_RPM $CLIENT_RPM $SERVER_RPM"
    [ -n "$PLUGINS_RPM" ] && CORE_RPMS="$CORE_RPMS $PLUGINS_RPM"
    [ -n "$ICU_RPM" ] && CORE_RPMS="$CORE_RPMS $ICU_RPM"
    [ -n "$COMPAT_RPM" ] && log "Optional package detected but not selected by default: $(basename "$COMPAT_RPM")"
}

validate_rpm_set() {
    for _rpm in $CORE_RPMS; do
        _n=$(rpm -qp --qf '%{NAME}' "$_rpm" 2>/dev/null)
        _v=$(rpm -qp --qf '%{VERSION}' "$_rpm" 2>/dev/null)
        _r=$(rpm -qp --qf '%{RELEASE}' "$_rpm" 2>/dev/null)
        _a=$(rpm -qp --qf '%{ARCH}' "$_rpm" 2>/dev/null)
        [ "$_v" = "$TARGET_VERSION" ] || block "Version mismatch: $_n=$_v, server=$TARGET_VERSION"
        [ "$_r" = "$TARGET_RELEASE" ] || block "Release mismatch: $_n=$_r, server=$TARGET_RELEASE"
        [ "$_a" = "$TARGET_ARCH" ] || [ "$_a" = "noarch" ] || block "Architecture mismatch inside bundle: $_n=$_a"
    done
}

host_compatibility() {
    [ -r /etc/os-release ] || die "/etc/os-release not found"
    . /etc/os-release
    HOST_ARCH=$(uname -m)
    HOST_MAJOR=$(printf '%s' "${VERSION_ID:-}" | cut -d. -f1)
    [ "$HOST_ARCH" = "$TARGET_ARCH" ] || block "Host arch $HOST_ARCH != RPM arch $TARGET_ARCH"
    RPM_DIST=$(printf '%s' "$TARGET_RELEASE" | sed -n 's/.*\.\(el[0-9][0-9]*\).*/\1/p')
    [ -n "$RPM_DIST" ] || block "Cannot derive EL distribution tag from RPM release: $TARGET_RELEASE"
    [ -z "$RPM_DIST" ] || [ "$RPM_DIST" = "el$HOST_MAJOR" ] || block "Host major $HOST_MAJOR != RPM distribution $RPM_DIST"
    if [ -n "$RPM_DIST" ]; then
        _family="${ID:-} ${ID_LIKE:-}"
        echo "$_family" | grep -Eqi '(^|[[:space:]])(rhel|fedora|centos|rocky|almalinux|ol)([[:space:]]|$)' ||             block "Oracle EL RPM bundle detected ($RPM_DIST), but host family is not recognized as RHEL-compatible: $_family"
    fi
}
check_signatures() {
    SIG_IMPORT_NEEDED=no
    _fatal_sig=0
    _saw_nokey=0
    for _rpm in $CORE_RPMS; do
        _sig=$(rpm -Kv "$_rpm" 2>&1 || true)
        printf '%s
' "$_sig"
        echo "$_sig" | grep -qi 'NOKEY' && _saw_nokey=1
        echo "$_sig" | grep -qiE 'BAD|NOTTRUSTED' && _fatal_sig=1
        if echo "$_sig" | grep -qi 'NOT OK' && ! echo "$_sig" | grep -qi 'NOKEY'; then _fatal_sig=1; fi
    done
    [ "$_fatal_sig" -eq 0 ] || { block "RPM signature verification failed"; return; }
    if [ "$_saw_nokey" -eq 1 ]; then
        set -- /etc/pki/rpm-gpg/RPM-GPG-KEY-mysql*
        if [ -f "$1" ]; then
            SIG_IMPORT_NEEDED=yes
            warn "MySQL RPM signing key is not imported; local MySQL GPG key file(s) are available and can be imported at install stage"
        else
            block "RPM signature reports NOKEY and no local /etc/pki/rpm-gpg/RPM-GPG-KEY-mysql* file is available"
        fi
    fi
}

ensure_signatures_before_install() {
    if [ "$SIG_IMPORT_NEEDED" = yes ]; then
        ask_yn "Import local MySQL RPM GPG key(s)" yes || die "RPM signature trust is required"
        for _key in /etc/pki/rpm-gpg/RPM-GPG-KEY-mysql*; do [ -f "$_key" ] && rpm --import "$_key"; done
    fi
    for _rpm in $CORE_RPMS; do
        _sig=$(rpm -Kv "$_rpm" 2>&1 || true)
        echo "$_sig"
        echo "$_sig" | grep -qiE 'NOKEY|NOT OK|BAD|NOTTRUSTED' && die "RPM signature verification failed: $_rpm"
    done
}

check_installed_products() {
    INSTALLED_MYSQL=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' mysql-community-server 2>/dev/null || true)
    TARGET_NEVRA="$TARGET_VERSION-$TARGET_RELEASE.$TARGET_ARCH"
    if [ -n "$INSTALLED_MYSQL" ]; then
        if [ "$INSTALLED_MYSQL" = "$TARGET_NEVRA" ]; then PACKAGE_ACTION="reuse"; else PACKAGE_ACTION="blocked"; block "Installed mysql-community-server=$INSTALLED_MYSQL differs from bundle=$TARGET_NEVRA; package replacement can affect all local instances"; fi
    else
        PACKAGE_ACTION="install"
    fi
}
validate_installed_core_set() {
    [ "$PACKAGE_ACTION" = reuse ] || return 0
    for _rpm in $CORE_RPMS; do
        _name=$(rpm -qp --qf '%{NAME}' "$_rpm" 2>/dev/null)
        _want=$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$_rpm" 2>/dev/null)
        _have=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$_name" 2>/dev/null || true)
        [ "$_have" = "$_want" ] || block "Installed component mismatch: $_name=${_have:-missing}, bundle=$_want"
    done
}

check_foreign_mysql() {
    _foreign=$(rpm -qa --qf '%{NAME}\n' | grep -Ei '^(mariadb-server|Percona-Server-server|percona-server-server)' || true)
    if [ -n "$_foreign" ] && [ "$PACKAGE_ACTION" = "install" ]; then
        block "Other MySQL-family server RPM detected: $(printf '%s' "$_foreign" | tr '\n' ' ')"
    fi
    if [ "$PACKAGE_ACTION" = "install" ] && pgrep mysqld >/dev/null 2>&1; then
        block "Running mysqld process detected while Oracle MySQL server RPM is not installed; package installation requires manual coexistence review"
    fi
}

package_test() {
    [ "$PACKAGE_ACTION" = "install" ] || return 0
    log "RPM dependency/conflict test (no changes)"
    if rpm -Uvh --test $CORE_RPMS >/tmp/mysql-install-rpmtest.$$ 2>&1; then
        cat /tmp/mysql-install-rpmtest.$$
    else
        cat /tmp/mysql-install-rpmtest.$$ >&2
        warn "rpm --test detected missing dependency or package conflict; package manager may resolve OS dependencies only when enabled repositories are allowed"
    fi
    rm -f /tmp/mysql-install-rpmtest.$$
}

print_precheck_summary() {
    echo ""
    echo "===== PRECHECK SUMMARY ====="
    echo "Bundle        : $BUNDLE"
    echo "Target        : MySQL $TARGET_VERSION-$TARGET_RELEASE.$TARGET_ARCH"
    echo "Vendor        : $TARGET_VENDOR"
    echo "Host          : ${PRETTY_NAME:-unknown} / $HOST_ARCH"
    echo "Package action: $PACKAGE_ACTION"
    echo "Blockers      : $BLOCKERS"
    echo "Warnings      : $WARNINGS"
    echo "============================"
}
collect_instance_inputs() {
    _owner=$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || echo mysql)
    case "$_owner" in root|UNKNOWN|'') _owner=mysql ;; esac
    ask "MySQL OS account" "$_owner"; OS_USER=$ASK_RESULT
    [ "$OS_USER" != "root" ] || die "mysqld must not run as OS root"
    case "$OS_USER" in *[!A-Za-z0-9_.-]*|'') die "Invalid OS account name" ;; esac

    if getent passwd "$OS_USER" >/dev/null 2>&1; then
        OS_HOME=$(getent passwd "$OS_USER" | awk -F: '{print $6}')
        OS_GROUP=$(id -gn "$OS_USER")
        CREATE_OS_USER=no
    else
        OS_HOME="/var/lib/$OS_USER"
        OS_GROUP=$OS_USER
        if [ "$OS_USER" = mysql ] && [ "$PACKAGE_ACTION" = install ]; then
            CREATE_OS_USER=package
            log "OS account 'mysql' expected to be created by Oracle MySQL RPM installation"
        elif ask_yn "OS account '$OS_USER' does not exist. Create a system account" no; then
            CREATE_OS_USER=yes
        else
            die "Existing or approved OS account required"
        fi
    fi

    _root_default=$OS_HOME
    _script_owner=$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || echo UNKNOWN)
    case "$SCRIPT_DIR" in /home/*|/opt/*|/srv/*) [ "$_script_owner" = "$OS_USER" ] && _root_default=$SCRIPT_DIR ;; esac
    ask "Instance root directory" "$_root_default"; INSTANCE_ROOT=$ASK_RESULT
    safe_path "$INSTANCE_ROOT"
    ask "systemd service name" "mysqld-$OS_USER"; SERVICE_NAME=$ASK_RESULT
    case "$SERVICE_NAME" in *[!A-Za-z0-9_.@-]*|'') die "Invalid systemd service name" ;; esac
    ask "Separate my.cnf path" "/etc/$SERVICE_NAME.cnf"; CONF=$ASK_RESULT
    ask "Data directory" "$INSTANCE_ROOT/data"; DATADIR=$ASK_RESULT
    ask "Log directory" "$INSTANCE_ROOT/log"; LOGDIR=$ASK_RESULT
    ask "Socket/PID directory" "$INSTANCE_ROOT/mysqld"; RUNDIR=$ASK_RESULT
    ask "secure_file_priv directory" "$INSTANCE_ROOT/mysql-files"; FILESDIR=$ASK_RESULT
    for _p in "$CONF" "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"; do safe_path "$_p"; done
}
collect_network_inputs() {
    DEFAULT_PORT=$(find_free_port)
    while :; do
        ask "MySQL SQL port" "$DEFAULT_PORT"; PORT=$ASK_RESULT
        valid_port "$PORT" || { echo "Invalid port." >&2; continue; }
        _cf=$(configured_port_owner "$PORT")
        if port_busy "$PORT"; then
            echo "Port $PORT is already listening. Choose another port." >&2
            DEFAULT_PORT=$((PORT + 1)); continue
        elif [ -n "$_cf" ]; then
            echo "Port $PORT is already configured in $_cf. Choose another port." >&2
            DEFAULT_PORT=$((PORT + 1)); continue
        fi
        _sel_t=$(selinux_conflicting_port_type "$PORT" || true)
        if [ -n "$_sel_t" ]; then
            echo "Port $PORT is reserved by SELinux type $_sel_t. Choose another port." >&2
            DEFAULT_PORT=$((PORT + 1)); continue
        fi
        break
    done

    if ask_yn "Enable TCP/IP connections" yes; then
        TCP_ENABLED=yes
        ask "bind-address" "127.0.0.1"; BIND_ADDRESS=$ASK_RESULT
    else
        TCP_ENABLED=no
        BIND_ADDRESS=""
    fi

    if ask_yn "Enable MySQL X Protocol" no; then
        MYSQLX_ENABLED=yes
        _xp=33060
        while [ "$_xp" -le 65535 ]; do
            _xcf=$(configured_mysqlx_port_owner "$_xp")
            _xsel=$(selinux_conflicting_port_type "$_xp" || true)
            ! port_busy "$_xp" && [ -z "$_xcf" ] && [ -z "$_xsel" ] && break
            _xp=$((_xp + 1))
        done
        [ "$_xp" -le 65535 ] || die "No available MySQL X Protocol port found in range 33060-65535"
        while :; do
            ask "MySQL X Protocol port" "$_xp"; MYSQLX_PORT=$ASK_RESULT
            valid_port "$MYSQLX_PORT" || { echo "Invalid port." >&2; continue; }
            [ "$MYSQLX_PORT" != "$PORT" ] || { echo "X Protocol port must differ from SQL port." >&2; continue; }
            _xcf=$(configured_mysqlx_port_owner "$MYSQLX_PORT")
            port_busy "$MYSQLX_PORT" && { echo "Port $MYSQLX_PORT is already listening." >&2; _xp=$((MYSQLX_PORT + 1)); continue; }
            [ -n "$_xcf" ] && { echo "MySQL X port $MYSQLX_PORT is already configured in $_xcf." >&2; _xp=$((MYSQLX_PORT + 1)); continue; }
            _xsel=$(selinux_conflicting_port_type "$MYSQLX_PORT" || true)
            [ -n "$_xsel" ] && { echo "MySQL X port $MYSQLX_PORT is reserved by SELinux type $_xsel." >&2; _xp=$((MYSQLX_PORT + 1)); continue; }
            break
        done
        _xbind_default=${BIND_ADDRESS:-127.0.0.1}
        [ -n "$_xbind_default" ] || _xbind_default=127.0.0.1
        ask "MySQL X Protocol bind-address" "$_xbind_default"; MYSQLX_BIND_ADDRESS=$ASK_RESULT
        MYSQLX_SOCKET="$RUNDIR/mysqlx.sock"
    else
        MYSQLX_ENABLED=no; MYSQLX_PORT=""; MYSQLX_BIND_ADDRESS=""; MYSQLX_SOCKET=""
    fi
}
collect_profile_inputs() {
    while :; do
        ask "my.cnf profile: 1=minimum, 2=production" "1"; PROFILE=$ASK_RESULT
        case "$PROFILE" in 1) PROFILE_NAME=minimum; break ;; 2) PROFILE_NAME=production; break ;; esac
    done
    DEDICATED=no; BUFFER_POOL_MB=0; MAX_CONNECTIONS=151; SLOW_QUERY=no; LONG_QUERY_TIME=2
    [ "$PROFILE" = "2" ] || return 0

    _running=$(pgrep -c mysqld 2>/dev/null || echo 0)
    _configured=$(config_candidates | wc -l | awk '{print $1}')
    _ded_default=yes
    if [ "$_running" -gt 0 ] 2>/dev/null || [ "$_configured" -gt 0 ] 2>/dev/null; then _ded_default=no; fi
    _want_dedicated=no
    if version_ge "$TARGET_VERSION" "8.0.3" && ask_yn "Dedicated server/VM for this MySQL instance" "$_ded_default"; then
        _want_dedicated=yes
    fi
    if [ "$_want_dedicated" = yes ] && { [ "$_running" -gt 0 ] 2>/dev/null || [ "$_configured" -gt 0 ] 2>/dev/null; }; then
        warn "Existing MySQL process/configuration detected; innodb_dedicated_server is intended for a host dedicated to one MySQL instance"
        ask_yn "Confirm innodb_dedicated_server despite detected coexistence" no || _want_dedicated=no
    fi
    if [ "$_want_dedicated" = yes ]; then
        DEDICATED=yes
    else
        DEDICATED=no
        ask "innodb_buffer_pool_size in MB (0=leave MySQL default)" "0"; BUFFER_POOL_MB=$ASK_RESULT
        case "$BUFFER_POOL_MB" in *[!0-9]*|'') die "Invalid buffer pool size" ;; esac
    fi
    ask "max_connections" "151"; MAX_CONNECTIONS=$ASK_RESULT
    case "$MAX_CONNECTIONS" in *[!0-9]*|'') die "Invalid max_connections" ;; esac
    [ "$MAX_CONNECTIONS" -ge 1 ] || die "max_connections must be >= 1"
    if ask_yn "Enable slow query log" yes; then
        SLOW_QUERY=yes
        while :; do
            ask "long_query_time seconds" "2"; LONG_QUERY_TIME=$ASK_RESULT
            valid_nonnegative_number "$LONG_QUERY_TIME" && break
            echo "long_query_time must be a non-negative number." >&2
        done
    fi
}

detect_mysql_conf_selinux_type() {
    MYSQL_CONF_SELINUX_TYPE=""
    if command -v matchpathcon >/dev/null 2>&1; then
        _ctx=$(matchpathcon -n /etc/my.cnf 2>/dev/null || true)
        MYSQL_CONF_SELINUX_TYPE=$(printf '%s\n' "$_ctx" | awk -F: 'NF>=3 {print $3; exit}')
    fi
    if [ -z "$MYSQL_CONF_SELINUX_TYPE" ] && command -v semanage >/dev/null 2>&1; then
        MYSQL_CONF_SELINUX_TYPE=$(semanage fcontext -l 2>/dev/null | awk '$1=="/etc/my\\.cnf" {n=split($NF,a,":"); if(n>=3){print a[3]; exit}}')
    fi
}

collect_selinux_choice() {
    SELINUX_STATE=$(getenforce 2>/dev/null || echo Disabled)
    SELINUX_APPLY=no
    case "$SELINUX_STATE" in
        Enforcing|Permissive)
            if ask_yn "Apply MySQL SELinux file/port contexts for selected custom paths and ports" yes; then
                SELINUX_APPLY=yes
                detect_mysql_conf_selinux_type
                [ -n "$MYSQL_CONF_SELINUX_TYPE" ] || warn "Could not derive the host SELinux type for MySQL option files from /etc/my.cnf; custom option-file paths outside an already-allowed context may fail"
            else
                warn "SELinux is $SELINUX_STATE; custom paths or non-default ports can prevent mysqld startup without matching policy"
                ask_yn "Continue without SELinux policy changes" no || die "Cancelled by user"
            fi
            ;;
    esac
}
check_instance_collisions() {
    [ "$PORT" -ge 1024 ] || block "Port $PORT requires root privileges; mysqld runs as $OS_USER"
    port_busy "$PORT" && block "SQL port already in use: $PORT"
    _port_cf=$(configured_port_owner "$PORT")
    [ -z "$_port_cf" ] || block "SQL port $PORT already configured in $_port_cf"
    _sel_t=$(selinux_conflicting_port_type "$PORT" || true)
    [ -z "$_sel_t" ] || block "SQL port $PORT reserved by SELinux type $_sel_t"
    SOCKET="$RUNDIR/mysql.sock"
    PIDFILE="$RUNDIR/mysqld.pid"
    LOGFILE="$LOGDIR/mysqld.log"
    SLOWLOG="$LOGDIR/slow.log"

    socket_busy "$SOCKET" && block "Unix socket already in use: $SOCKET"
    [ -e "$SOCKET" ] && block "Unix socket path already exists: $SOCKET"
    [ -e "$SOCKET.lock" ] && block "Unix socket lock path already exists: $SOCKET.lock"
    [ -e "$PIDFILE" ] && block "PID file path already exists: $PIDFILE"
    [ -e "$LOGFILE" ] && block "Error log path already exists: $LOGFILE"
    [ -e "$LOGDIR/initialize.log" ] && block "Initialization log path already exists: $LOGDIR/initialize.log"
    [ "$PROFILE" = "2" ] && [ "$SLOW_QUERY" = yes ] && [ -e "$SLOWLOG" ] && block "Slow query log path already exists: $SLOWLOG"
    path_nonempty "$DATADIR" && block "Data directory is not empty: $DATADIR"
    [ -e "$CONF" ] && block "Configuration file already exists: $CONF"
    systemctl cat "$SERVICE_NAME.service" >/dev/null 2>&1 && block "systemd unit already exists: $SERVICE_NAME.service"

    for _pair in "datadir:$DATADIR" "socket:$SOCKET" "pid-file:$PIDFILE" "log-error:$LOGFILE" "secure-file-priv:$FILESDIR"; do
        _opt=${_pair%%:*}; _val=${_pair#*:}
        _owner_cf=$(configured_option_owner "$_opt" "$_val")
        [ -z "$_owner_cf" ] || block "$_opt path already configured in $_owner_cf: $_val"
    done

    case "$FILESDIR/" in "$DATADIR"/*) block "secure_file_priv directory must not be inside Data Directory" ;; esac
    [ "$DATADIR" != "$LOGDIR" ] || block "Data and log directories must differ"
    [ "$DATADIR" != "$RUNDIR" ] || block "Data and socket/PID directories must differ"
    [ ${#SOCKET} -lt 100 ] || block "Unix socket path is too long for safe Linux operation: $SOCKET"

    if [ "$MYSQLX_ENABLED" = yes ]; then
        port_busy "$MYSQLX_PORT" && block "MySQL X Protocol port already in use: $MYSQLX_PORT"
        _xport_cf=$(configured_mysqlx_port_owner "$MYSQLX_PORT")
        [ -z "$_xport_cf" ] || block "MySQL X Protocol port $MYSQLX_PORT already configured in $_xport_cf"
        _xsel=$(selinux_conflicting_port_type "$MYSQLX_PORT" || true)
        [ -z "$_xsel" ] || block "MySQL X Protocol port $MYSQLX_PORT reserved by SELinux type $_xsel"
        [ "$MYSQLX_PORT" -ge 1024 ] || block "MySQL X Protocol port requires root privileges"
        socket_busy "$MYSQLX_SOCKET" && block "MySQL X Unix socket already in use: $MYSQLX_SOCKET"
        [ -e "$MYSQLX_SOCKET" ] && block "MySQL X Unix socket path already exists: $MYSQLX_SOCKET"
        [ -e "$MYSQLX_SOCKET.lock" ] && block "MySQL X Unix socket lock path already exists: $MYSQLX_SOCKET.lock"
        _xsocket_cf=$(configured_option_owner mysqlx-socket "$MYSQLX_SOCKET")
        [ -z "$_xsocket_cf" ] || block "MySQL X Unix socket already configured in $_xsocket_cf: $MYSQLX_SOCKET"
    fi
}

choose_dependency_mode() {
    DEP_MODE=local
    [ "$PACKAGE_ACTION" = install ] || return 0
    ask "OS dependency source: 1=local/installed only, 2=enabled OS repositories" "1"; _v=$ASK_RESULT
    [ "$_v" = "2" ] && DEP_MODE=repos
}
render_config() {
    cat <<EOF
# Generated by mysql_install_auto.sh v$SCRIPT_VERSION
# Target Oracle MySQL Community: $TARGET_VERSION-$TARGET_RELEASE.$TARGET_ARCH
[mysqld]
user=$OS_USER
port=$PORT
datadir=$DATADIR
socket=$SOCKET
pid-file=$PIDFILE
log-error=$LOGFILE
secure-file-priv=$FILESDIR
EOF
    if [ "$TCP_ENABLED" = yes ]; then
        echo "bind-address=$BIND_ADDRESS"
    else
        echo "skip-networking=ON"
    fi
    if [ "$MYSQLX_ENABLED" = yes ]; then
        echo "mysqlx-port=$MYSQLX_PORT"
        echo "mysqlx-bind-address=$MYSQLX_BIND_ADDRESS"
        echo "mysqlx-socket=$MYSQLX_SOCKET"
    else
        echo "mysqlx=0"
    fi
    if [ "$PROFILE" = "2" ]; then
        echo "innodb-flush-log-at-trx-commit=1"
        echo "sync-binlog=1"
        echo "max-connections=$MAX_CONNECTIONS"
        echo "local-infile=OFF"
        [ "$DEDICATED" = yes ] && echo "innodb-dedicated-server=ON"
        [ "$DEDICATED" = no ] && [ "$BUFFER_POOL_MB" -gt 0 ] && echo "innodb-buffer-pool-size=${BUFFER_POOL_MB}M"
        if [ "$SLOW_QUERY" = yes ]; then
            echo "slow-query-log=ON"
            echo "slow-query-log-file=$SLOWLOG"
            echo "long-query-time=$LONG_QUERY_TIME"
        fi
    fi
    cat <<EOF

[client]
port=$PORT
socket=$SOCKET
EOF
}
render_service() {
    cat <<EOF
[Unit]
Description=MySQL Server ($SERVICE_NAME)
Documentation=man:mysqld(8)
After=network-online.target
Wants=network-online.target

[Service]
User=$OS_USER
Group=$OS_GROUP
Type=notify
TimeoutSec=0
ExecStart=$TARGET_MYSQLD_PATH --defaults-file=$CONF
LimitNOFILE=10000
Restart=on-failure
RestartPreventExitStatus=1
Environment=MYSQLD_PARENT_PID=1
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF
}

show_plan() {
    echo ""
    echo "===== INSTALL PLAN ====="
    echo "Target        : MySQL $TARGET_VERSION-$TARGET_RELEASE.$TARGET_ARCH"
    echo "mysqld binary : $TARGET_MYSQLD_PATH"
    echo "OS account    : $OS_USER:$OS_GROUP"
    echo "Service       : $SERVICE_NAME.service"
    echo "Profile       : $PROFILE_NAME"
    echo "Config        : $CONF"
    echo "Data          : $DATADIR"
    echo "Log           : $LOGFILE"
    echo "Socket        : $SOCKET"
    echo "PID           : $PIDFILE"
    echo "SQL port      : $PORT"
    echo "TCP           : $TCP_ENABLED ${BIND_ADDRESS:+($BIND_ADDRESS)}"
    echo "MySQL X       : $MYSQLX_ENABLED ${MYSQLX_PORT:+($MYSQLX_PORT)} ${MYSQLX_BIND_ADDRESS:+bind=$MYSQLX_BIND_ADDRESS}"
    [ "$MYSQLX_ENABLED" = yes ] && echo "MySQL X socket: $MYSQLX_SOCKET"
    echo "SELinux       : $SELINUX_STATE / apply=$SELINUX_APPLY"
    echo "Package       : $PACKAGE_ACTION ${DEP_MODE:+/ dependencies=$DEP_MODE}"
    echo "========================"
}
install_packages() {
    [ "$PACKAGE_ACTION" = install ] || { log "Target MySQL RPM version already installed; package installation skipped"; return 0; }
    ensure_signatures_before_install
    if command -v dnf >/dev/null 2>&1; then PM=dnf; elif command -v yum >/dev/null 2>&1; then PM=yum; else die "dnf/yum not found"; fi
    log "Installing Oracle MySQL Community RPMs with $PM"
    if [ "$DEP_MODE" = local ]; then
        "$PM" --disablerepo='*' install -y $CORE_RPMS || die "Local-only RPM installation failed. Prepare missing OS dependency RPMs or rerun with enabled OS repositories."
    else
        "$PM" install -y $CORE_RPMS || die "RPM installation failed"
    fi
    PACKAGE_CHANGED=yes
    _installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' mysql-community-server 2>/dev/null || true)
    [ "$_installed" = "$TARGET_NEVRA" ] || die "Installed server RPM mismatch: $_installed != $TARGET_NEVRA"
    if systemctl is-active --quiet mysqld.service 2>/dev/null; then
        die "Vendor mysqld.service became active during package installation; stop and review default instance before continuing"
    fi
    if [ "$SERVICE_NAME" != mysqld ] && systemctl is-enabled --quiet mysqld.service 2>/dev/null; then
        systemctl disable mysqld.service >/dev/null 2>&1 || warn "Could not disable vendor mysqld.service; verify boot-time collision manually"
    fi
}

ensure_os_account() {
    if getent passwd "$OS_USER" >/dev/null 2>&1; then
        OS_GROUP=$(id -gn "$OS_USER")
        return 0
    fi
    if [ "$CREATE_OS_USER" = package ]; then
        getent passwd "$OS_USER" >/dev/null 2>&1 || die "Oracle MySQL RPM did not create expected OS account: $OS_USER"
        OS_GROUP=$(id -gn "$OS_USER")
        return 0
    fi
    [ "$CREATE_OS_USER" = yes ] || die "OS account missing after package installation: $OS_USER"
    if ! getent group "$OS_GROUP" >/dev/null 2>&1; then
        groupadd -r "$OS_GROUP" || die "groupadd failed"
        CUSTOM_GROUP_CREATED=yes
    fi
    useradd -r -M -d "$INSTANCE_ROOT" -s /sbin/nologin -g "$OS_GROUP" "$OS_USER" || die "useradd failed"
    CUSTOM_USER_CREATED=yes
    log "Created system account: $OS_USER:$OS_GROUP"
}

snapshot_existing_dir() {
    _d=$1
    [ -d "$_d" ] || return 0
    _meta="$WORKDIR/preexisting_dirs.meta"
    grep -Fq "|$_d" "$_meta" 2>/dev/null && return 0
    stat -c '%u|%g|%a|%C|%n' "$_d" >> "$_meta" || die "Could not snapshot directory metadata: $_d"
}

prepare_directories() {
    for _d in "$INSTANCE_ROOT" "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"; do snapshot_existing_dir "$_d"; done
    _root_was_new=no
    [ -d "$INSTANCE_ROOT" ] || _root_was_new=yes
    _data_new=no; [ -d "$DATADIR" ] || _data_new=yes
    _log_new=no; [ -d "$LOGDIR" ] || _log_new=yes
    _run_new=no; [ -d "$RUNDIR" ] || _run_new=yes
    _files_new=no; [ -d "$FILESDIR" ] || _files_new=yes
    _conf_parent=$(dirname "$CONF")
    _conf_parent_new=no; [ -d "$_conf_parent" ] || _conf_parent_new=yes

    mkdir -p "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR" "$_conf_parent" || die "Directory creation failed"
    chown "$OS_USER:$OS_GROUP" "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"
    chmod 750 "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"
    [ "$_root_was_new" = yes ] && { chown "$OS_USER:$OS_GROUP" "$INSTANCE_ROOT"; chmod 750 "$INSTANCE_ROOT"; }

    [ "$_data_new" = yes ] && { DATADIR_CREATED=yes; CREATED_PATHS="$DATADIR${CREATED_PATHS:+ }$CREATED_PATHS"; }
    [ "$_log_new" = yes ] && CREATED_PATHS="$LOGDIR${CREATED_PATHS:+ }$CREATED_PATHS"
    [ "$_run_new" = yes ] && CREATED_PATHS="$RUNDIR${CREATED_PATHS:+ }$CREATED_PATHS"
    [ "$_files_new" = yes ] && CREATED_PATHS="$FILESDIR${CREATED_PATHS:+ }$CREATED_PATHS"
    [ "$_conf_parent_new" = yes ] && CREATED_PATHS="$_conf_parent${CREATED_PATHS:+ }$CREATED_PATHS"
    [ "$_root_was_new" = yes ] && CREATED_PATHS="$CREATED_PATHS${CREATED_PATHS:+ }$INSTANCE_ROOT"
}
write_config() {
    [ ! -e "$CONF" ] || die "Refusing to overwrite existing config: $CONF"
    render_config > "$CONF" || die "Config write failed"
    CREATED_CONF=yes
    chown root:"$OS_GROUP" "$CONF"
    chmod 640 "$CONF"
    log "Created config: $CONF"
}

selinux_port_has_type() {
    _type=$1; _p=$2; _cmd=${3:-all}
    if [ "$_cmd" = local ]; then _data=$(semanage port -C -l 2>/dev/null); else _data=$(semanage port -l 2>/dev/null); fi
    printf '%s\n' "$_data" | awk -v want="$_type" -v p="$_p" '
        $1==want && $2=="tcp" {
            for(i=3;i<=NF;i++){
                x=$i; gsub(/,/,"",x)
                if(x ~ /^[0-9]+$/ && x+0==p) found=1
                if(x ~ /^[0-9]+-[0-9]+$/){split(x,a,"-"); if(p>=a[1] && p<=a[2]) found=1}
            }
        }
        END{exit(found?0:1)}'
}
selinux_local_port_owner() {
    _p=$1
    semanage port -C -l 2>/dev/null | awk -v p="$_p" '
        $2=="tcp" {
            for(i=3;i<=NF;i++){
                x=$i; gsub(/,/,"",x)
                if(x ~ /^[0-9]+$/ && x+0==p){print $1; exit}
                if(x ~ /^[0-9]+-[0-9]+$/){split(x,a,"-"); if(p>=a[1] && p<=a[2]){print $1; exit}}
            }
        }'
}
selinux_ensure_port() {
    _p=$1
    selinux_port_has_type mysqld_port_t "$_p" all && return 0
    _local_owner=$(selinux_local_port_owner "$_p")
    if [ -n "$_local_owner" ] && [ "$_local_owner" != mysqld_port_t ]; then
        die "SELinux TCP port $_p has local custom type $_local_owner; automatic reassignment blocked"
    fi
    if semanage port -a -t mysqld_port_t -p tcp "$_p"; then
        SELINUX_PORT_ADDED="${SELINUX_PORT_ADDED}${SELINUX_PORT_ADDED:+ }$_p"
    else
        die "Failed to add mysqld_port_t for TCP port $_p; existing specific SELinux assignment may conflict"
    fi
}
selinux_local_fcontext_type() {
    _expr=$1
    _line=$(semanage fcontext -C -l 2>/dev/null | grep -F -- "$_expr" | sed -n '1p')
    [ -n "$_line" ] || return 0
    printf '%s\n' "$_line" | awk '{n=split($NF,a,":"); if(n>=3) print a[3]}'
}
selinux_exact_fcontext_type() {
    _expr=$1
    _line=$(semanage fcontext -l 2>/dev/null | grep -F -- "$_expr" | sed -n '1p')
    [ -n "$_line" ] || return 0
    printf '%s\n' "$_line" | awk '{n=split($NF,a,":"); if(n>=3) print a[3]}'
}
selinux_fcontext_set() {
    _type=$1; _expr=$2
    _local=$(selinux_local_fcontext_type "$_expr")
    if [ -n "$_local" ]; then
        [ "$_local" = "$_type" ] || die "SELinux fcontext $_expr already has local type $_local; automatic reassignment blocked"
        return 0
    fi
    _exact=$(selinux_exact_fcontext_type "$_expr")
    if [ -n "$_exact" ]; then
        [ "$_exact" = "$_type" ] || die "SELinux fcontext $_expr already has type $_exact; automatic reassignment blocked"
        return 0
    fi
    semanage fcontext -a -t "$_type" "$_expr" || die "SELinux fcontext add failed: $_expr"
    SELINUX_FCONTEXT_ADDED="${SELINUX_FCONTEXT_ADDED}${SELINUX_FCONTEXT_ADDED:+ }$_expr"
}
apply_selinux() {
    [ "$SELINUX_APPLY" = yes ] || { log "SELinux policy changes skipped by user choice"; return 0; }
    command -v semanage >/dev/null 2>&1 || die "semanage not found. Prepare policycoreutils-python-utils before rerun."
    command -v restorecon >/dev/null 2>&1 || die "restorecon not found"

    selinux_fcontext_set mysqld_db_t "$DATADIR(/.*)?"
    selinux_fcontext_set mysqld_log_t "$LOGDIR(/.*)?"
    selinux_fcontext_set mysqld_var_run_t "$RUNDIR(/.*)?"
    selinux_fcontext_set mysqld_db_t "$FILESDIR(/.*)?"
    if [ -n "${MYSQL_CONF_SELINUX_TYPE:-}" ]; then
        CONF_SELINUX_EXPR=$(printf '%s' "$CONF" | sed 's/[.]/\\./g')
        selinux_fcontext_set "$MYSQL_CONF_SELINUX_TYPE" "$CONF_SELINUX_EXPR"
    fi
    restorecon -Rv "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR" || die "restorecon failed"
    restorecon -v "$CONF" || die "restorecon failed for MySQL option file: $CONF"

    [ "$TCP_ENABLED" = yes ] && selinux_ensure_port "$PORT"
    [ "$MYSQLX_ENABLED" = yes ] && selinux_ensure_port "$MYSQLX_PORT"
}

selinux_path_type() {
    _sp=$1
    stat -c '%C' "$_sp" 2>/dev/null | awk -F: 'NF>=3 {print $3; exit}'
}

verify_selinux_runtime() {
    [ "$SELINUX_APPLY" = yes ] || return 0
    _t=$(selinux_path_type "$DATADIR"); [ "$_t" = mysqld_db_t ] || die "SELinux type mismatch for Data Directory: ${_t:-unknown}"
    _t=$(selinux_path_type "$LOGDIR"); [ "$_t" = mysqld_log_t ] || die "SELinux type mismatch for log directory: ${_t:-unknown}"
    _t=$(selinux_path_type "$RUNDIR"); [ "$_t" = mysqld_var_run_t ] || die "SELinux type mismatch for socket/PID directory: ${_t:-unknown}"
    _t=$(selinux_path_type "$FILESDIR"); [ "$_t" = mysqld_db_t ] || die "SELinux type mismatch for secure_file_priv directory: ${_t:-unknown}"
    if [ -n "${MYSQL_CONF_SELINUX_TYPE:-}" ]; then
        _t=$(selinux_path_type "$CONF"); [ "$_t" = "$MYSQL_CONF_SELINUX_TYPE" ] || die "SELinux type mismatch for MySQL option file: ${_t:-unknown} != $MYSQL_CONF_SELINUX_TYPE"
    fi
    [ "$TCP_ENABLED" = yes ] && selinux_port_has_type mysqld_port_t "$PORT" all || [ "$TCP_ENABLED" != yes ] || die "SELinux mysqld_port_t missing for SQL port $PORT"
    [ "$MYSQLX_ENABLED" = yes ] && selinux_port_has_type mysqld_port_t "$MYSQLX_PORT" all || [ "$MYSQLX_ENABLED" != yes ] || die "SELinux mysqld_port_t missing for MySQL X port $MYSQLX_PORT"
}

validate_account_access() {
    if command -v runuser >/dev/null 2>&1; then
        for _d in "$INSTANCE_ROOT" "$(dirname "$CONF")" "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"; do
            runuser -u "$OS_USER" -- test -x "$_d" || die "$OS_USER cannot traverse $_d; verify execute permission on this directory and every parent directory"
        done
        runuser -u "$OS_USER" -- test -r "$CONF" || die "$OS_USER cannot read $CONF; verify file mode/group and parent-directory traversal"
        runuser -u "$OS_USER" -- test -w "$DATADIR" || die "$OS_USER cannot write $DATADIR"
        runuser -u "$OS_USER" -- test -w "$LOGDIR" || die "$OS_USER cannot write $LOGDIR"
        runuser -u "$OS_USER" -- test -w "$RUNDIR" || die "$OS_USER cannot write $RUNDIR"
        runuser -u "$OS_USER" -- test -w "$FILESDIR" || die "$OS_USER cannot write $FILESDIR"
    fi
}
validate_config() {
    MYSQLD_BIN=$TARGET_MYSQLD_PATH
    [ -x "$MYSQLD_BIN" ] || die "Target mysqld binary not found after package stage: $MYSQLD_BIN"
    _owner_pkg=$(rpm -qf "$MYSQLD_BIN" 2>/dev/null || true)
    echo "$_owner_pkg" | grep -q '^mysql-community-server-' || die "Target mysqld is not owned by mysql-community-server RPM: $MYSQLD_BIN"

    log "Validating my.cnf with target mysqld"
    if version_ge "$TARGET_VERSION" "8.0.16"; then
        "$MYSQLD_BIN" --defaults-file="$CONF" --validate-config || die "mysqld --validate-config failed"
    else
        "$MYSQLD_BIN" --defaults-file="$CONF" --verbose --help >/dev/null 2>&1 || die "mysqld option validation failed"
    fi
}

initialize_datadir() {
    path_nonempty "$DATADIR" && die "Data Directory became non-empty before initialization: $DATADIR"
    INIT_LOG="$LOGDIR/initialize.log"
    INITIALIZE_ATTEMPTED=yes
    log "Initializing Data Directory with --initialize"
    if "$MYSQLD_BIN" --no-defaults --initialize --user="$OS_USER" --datadir="$DATADIR" >"$INIT_LOG" 2>&1; then
        DATADIR_INITIALIZED=yes
        chown "$OS_USER:$OS_GROUP" "$INIT_LOG" 2>/dev/null || true
        chmod 640 "$INIT_LOG" 2>/dev/null || true
    else
        cat "$INIT_LOG" >&2
        die "Data Directory initialization failed"
    fi
    [ -d "$DATADIR/mysql" ] || die "mysql system schema directory not found after initialization"
}

write_service() {
    UNIT_FILE="/etc/systemd/system/$SERVICE_NAME.service"
    [ ! -e "$UNIT_FILE" ] || die "Refusing to overwrite systemd unit: $UNIT_FILE"
    render_service > "$UNIT_FILE" || die "systemd unit write failed"
    CREATED_UNIT=yes
    chown root:root "$UNIT_FILE"; chmod 644 "$UNIT_FILE"
    systemctl daemon-reload || die "systemctl daemon-reload failed"
}
start_service() {
    port_busy "$PORT" && die "SQL port $PORT became busy before service start"
    socket_busy "$SOCKET" && die "Socket path became busy before service start"
    systemctl enable "$SERVICE_NAME.service" >/dev/null || die "systemctl enable failed"
    SERVICE_ENABLED=yes
    if ! systemctl start "$SERVICE_NAME.service"; then
        systemctl status "$SERVICE_NAME.service" --no-pager -l 2>/dev/null || true
        journalctl -u "$SERVICE_NAME.service" -n 100 --no-pager 2>/dev/null || true
        [ -f "$LOGFILE" ] && tail -100 "$LOGFILE" || true
        if [ "$SELINUX_STATE" != Disabled ] && command -v ausearch >/dev/null 2>&1; then
            ausearch -m AVC -ts recent 2>/dev/null | tail -50 || true
        fi
        die "MySQL service start failed"
    fi
    SERVICE_STARTED=yes
}

postcheck() {
    echo ""
    echo "===== POST-INSTALL VALIDATION ====="
    systemctl is-active --quiet "$SERVICE_NAME.service" || die "Service is not active"
    _pid=$(systemctl show -p MainPID --value "$SERVICE_NAME.service" 2>/dev/null || echo 0)
    [ "$_pid" -gt 0 ] 2>/dev/null || die "MainPID not detected"
    _run_user=$(ps -o user= -p "$_pid" 2>/dev/null | awk '{print $1}')
    [ "$_run_user" = "$OS_USER" ] || die "mysqld OS user mismatch: $_run_user != $OS_USER"
    _run_exe=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)
    _target_exe=$(readlink -f "$TARGET_MYSQLD_PATH" 2>/dev/null || printf '%s' "$TARGET_MYSQLD_PATH")
    [ "$_run_exe" = "$_target_exe" ] || die "Running mysqld binary mismatch: $_run_exe != $_target_exe"

    [ -S "$SOCKET" ] || die "Expected Unix socket not found: $SOCKET"
    if [ "$TCP_ENABLED" = yes ]; then port_busy "$PORT" || die "Expected SQL port not listening: $PORT"; fi
    if [ "$MYSQLX_ENABLED" = yes ]; then
        port_busy "$MYSQLX_PORT" || die "Expected MySQL X port not listening: $MYSQLX_PORT"
        [ -S "$MYSQLX_SOCKET" ] || die "Expected MySQL X Unix socket not found: $MYSQLX_SOCKET"
    fi
    if [ -f "$LOGFILE" ] && grep -q '\[ERROR\]' "$LOGFILE"; then
        tail -100 "$LOGFILE" >&2
        die "MySQL error entries detected in startup log: $LOGFILE"
    fi
    verify_selinux_runtime
    if [ "$SELINUX_APPLY" = yes ] && command -v ps >/dev/null 2>&1; then
        _domain=$(ps -Z -p "$_pid" -o label= 2>/dev/null | awk -F: 'NF>=3 {print $3; exit}')
        [ -z "$_domain" ] || [ "$_domain" = mysqld_t ] || die "Unexpected SELinux process domain for mysqld: $_domain"
    fi

    echo "Service        : ACTIVE"
    echo "MainPID        : $_pid"
    echo "Process user   : $_run_user"
    echo "Socket         : $SOCKET"
    echo "SQL port       : $PORT"
    "$MYSQLD_BIN" --version
    command -v my_print_defaults >/dev/null 2>&1 && my_print_defaults --defaults-file="$CONF" mysqld || true
    if [ "$SELINUX_STATE" != Disabled ]; then
        echo "-- SELinux contexts --"
        ls -Zd "$CONF" "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR" 2>/dev/null || true
        ps -eZ 2>/dev/null | grep "[m]ysqld" || true
    fi
    echo "-- Initial root password location --"
    if grep -i 'temporary password' "$INIT_LOG" >/dev/null 2>&1; then
        echo "$INIT_LOG"
        grep -i 'temporary password' "$INIT_LOG" | sed 's/: .*/: <hidden>/' || true
    else
        echo "No temporary-password line detected; inspect $INIT_LOG"
    fi
    echo "Manual login / password change command:"
    echo "  mysql --defaults-file=$CONF --protocol=socket -uroot -p"
    echo "==================================="
}

main() {
    [ "$(id -u)" -eq 0 ] || die "Run as root"
    command -v rpm >/dev/null 2>&1 || die "rpm command not found"
    command -v tar >/dev/null 2>&1 || die "tar command not found"
    command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl required"

    echo "MySQL Community RPM Bundle Installer v$SCRIPT_VERSION"
    detect_bundle
    extract_bundle
    inspect_rpms
    build_core_rpm_list
    validate_rpm_set
    host_compatibility
    check_signatures
    check_installed_products
    validate_installed_core_set
    check_foreign_mysql
    package_test
    show_running_mysqld
    print_precheck_summary

    if [ "$MODE" = precheck ]; then
        [ "$BLOCKERS" -eq 0 ] && exit 0 || exit 2
    fi
    refresh_collision_cache
    if [ "$MODE" = install ] && [ "$BLOCKERS" -gt 0 ]; then
        die "Precheck blockers detected. No installation changes made."
    fi
    collect_instance_inputs
    collect_network_inputs
    collect_profile_inputs
    collect_selinux_choice
    choose_dependency_mode
    refresh_collision_cache
    check_instance_collisions
    show_plan

    echo ""
    echo "----- Planned my.cnf -----"
    render_config
    echo "----- Planned systemd unit -----"
    render_service
    echo "-------------------------------"

    if [ "$MODE" = dryrun ]; then
        echo "DRY-RUN: no package/config/directory/SELinux/systemd changes applied."
        if [ "$BLOCKERS" -gt 0 ]; then
            echo "DRY-RUN blockers: $BLOCKERS (real installation would stop)."
            exit 2
        fi
        exit 0
    fi
    [ "$BLOCKERS" -eq 0 ] || die "Collision/configuration blockers detected. No installation changes made."
    ask_yn "Proceed with installation using this plan" no || die "Cancelled by user"
    ROLLBACK_ACTIVE=yes

    install_packages
    ensure_os_account
    prepare_directories
    write_config
    apply_selinux
    validate_account_access
    validate_config
    initialize_datadir
    write_service
    start_service
    postcheck
    ROLLBACK_ACTIVE=no
    log "Installation completed successfully"
}

main "$@"
