#!/bin/sh
# Oracle MySQL Community RPM Bundle installer
# POSIX /bin/sh, no third-party runtime dependency
SCRIPT_VERSION="1.0.0"
set -u
umask 027

MODE="install"
BUNDLE_ARG=""
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
WORKDIR=""
BLOCKERS=0
WARNINGS=0

log()  { printf '%s\n' "[INFO] $*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '%s\n' "[WARN] $*" >&2; }
block(){ BLOCKERS=$((BLOCKERS + 1)); printf '%s\n' "[BLOCK] $*" >&2; }
die()  { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

cleanup() {
    [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT HUP INT TERM

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
    _prompt=$1; _default=${2-};
    if [ -n "$_default" ]; then
        printf '%s' "$_prompt [$_default]: " >&2
    else
        printf '%s' "$_prompt: " >&2
    fi
    IFS= read -r _answer || die "Input aborted"
    [ -n "$_answer" ] || _answer=$_default
    printf '%s\n' "$_answer"
}

ask_yn() {
    _prompt=$1; _default=${2:-yes}
    while :; do
        _v=$(ask "$_prompt (yes/no)" "$_default")
        case "$_v" in y|Y|yes|YES|Yes) return 0 ;; n|N|no|NO|No) return 1 ;; esac
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

port_busy() {
    _p=$1
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lnt 2>/dev/null | awk -v p="$_p" '{x=$4; sub(/^.*:/,"",x); if(x==p) found=1} END{exit(found?0:1)}'
}
find_free_port() {
    _p=3306
    while [ "$_p" -le 3399 ]; do
        if ! port_busy "$_p"; then printf '%s\n' "$_p"; return 0; fi
        _p=$((_p + 1))
    done
    printf '%s\n' 3306
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
        _candidate=""
        for _f in "$SCRIPT_DIR"/*rpm-bundle.tar "$(pwd)"/*rpm-bundle.tar; do
            [ -f "$_f" ] || continue
            [ -n "$_candidate" ] && [ "$_candidate" != "$_f" ] && _candidate="MULTIPLE" && break
            _candidate=$_f
        done
        if [ "$_candidate" = "MULTIPLE" ] || [ -z "$_candidate" ]; then
            BUNDLE=$(ask "RPM bundle path" "")
        else
            BUNDLE=$(ask "RPM bundle path" "$_candidate")
        fi
    fi
    safe_path "$BUNDLE"
    [ -r "$BUNDLE" ] || die "Bundle not readable: $BUNDLE"
    tar -tf "$BUNDLE" >/dev/null 2>&1 || die "Invalid tar archive: $BUNDLE"
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
    case "$TARGET_VERSION" in 8.*|9.*) ;; *) die "Supported MySQL major versions: 8.x and 9.x; found $TARGET_VERSION" ;; esac
    echo "$TARGET_VENDOR" | grep -qi 'Oracle' || die "Server RPM vendor is not Oracle: $TARGET_VENDOR"
}
build_core_rpm_list() {
    CORE_RPMS="$COMMON_RPM $LIBS_RPM $CLIENT_RPM $SERVER_RPM"
    [ -n "$PLUGINS_RPM" ] && CORE_RPMS="$CORE_RPMS $PLUGINS_RPM"
    [ -n "$ICU_RPM" ] && CORE_RPMS="$CORE_RPMS $ICU_RPM"
    [ -n "$COMPAT_RPM" ] && CORE_RPMS="$CORE_RPMS $COMPAT_RPM"
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
}
check_signatures() {
    SIG_IMPORT_NEEDED=no
    _fatal_sig=0
    _saw_nokey=0
    for _rpm in $CORE_RPMS; do
        _sig=$(rpm -Kv "$_rpm" 2>&1 || true)
        printf '%s\n' "$_sig"
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
check_foreign_mysql() {
    _foreign=$(rpm -qa --qf '%{NAME}\n' | grep -Ei '^(mariadb-server|Percona-Server-server|percona-server-server)' || true)
    if [ -n "$_foreign" ] && [ "$PACKAGE_ACTION" = "install" ]; then
        block "Other MySQL-family server RPM detected: $(printf '%s' "$_foreign" | tr '\n' ' ')"
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
    OS_USER=$(ask "MySQL OS account" "$_owner")
    [ "$OS_USER" != "root" ] || die "mysqld must not run as OS root"
    case "$OS_USER" in *[!A-Za-z0-9_.-]*|'') die "Invalid OS account name" ;; esac

    if getent passwd "$OS_USER" >/dev/null 2>&1; then
        OS_HOME=$(getent passwd "$OS_USER" | awk -F: '{print $6}')
        OS_GROUP=$(id -gn "$OS_USER")
        CREATE_OS_USER=no
    else
        OS_HOME="/var/lib/$OS_USER"
        OS_GROUP=$OS_USER
        if ask_yn "OS account '$OS_USER' does not exist. Create a system account" no; then CREATE_OS_USER=yes; else die "Existing or approved OS account required"; fi
    fi

    INSTANCE_ROOT=$(ask "Instance root directory" "$OS_HOME")
    safe_path "$INSTANCE_ROOT"
    SERVICE_NAME=$(ask "systemd service name" "mysqld-$OS_USER")
    case "$SERVICE_NAME" in *[!A-Za-z0-9_.@-]*|'') die "Invalid systemd service name" ;; esac
    CONF=$(ask "Separate my.cnf path" "/etc/$SERVICE_NAME.cnf")
    DATADIR=$(ask "Data directory" "$INSTANCE_ROOT/data")
    LOGDIR=$(ask "Log directory" "$INSTANCE_ROOT/log")
    RUNDIR=$(ask "Socket/PID directory" "$INSTANCE_ROOT/mysqld")
    FILESDIR=$(ask "secure_file_priv directory" "$INSTANCE_ROOT/mysql-files")
    for _p in "$CONF" "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"; do safe_path "$_p"; done
}
collect_network_inputs() {
    DEFAULT_PORT=$(find_free_port)
    while :; do
        PORT=$(ask "MySQL SQL port" "$DEFAULT_PORT")
        valid_port "$PORT" || { echo "Invalid port." >&2; continue; }
        if port_busy "$PORT"; then
            echo "Port $PORT is already listening. Choose another port." >&2
            DEFAULT_PORT=$((PORT + 1)); continue
        fi
        break
    done

    if ask_yn "Enable TCP/IP connections" yes; then
        TCP_ENABLED=yes
        BIND_ADDRESS=$(ask "bind-address" "127.0.0.1")
    else
        TCP_ENABLED=no
        BIND_ADDRESS=""
    fi

    if ask_yn "Enable MySQL X Protocol" no; then
        MYSQLX_ENABLED=yes
        _xp=33060
        while port_busy "$_xp"; do _xp=$((_xp + 1)); done
        while :; do
            MYSQLX_PORT=$(ask "MySQL X Protocol port" "$_xp")
            valid_port "$MYSQLX_PORT" || { echo "Invalid port." >&2; continue; }
            [ "$MYSQLX_PORT" != "$PORT" ] || { echo "X Protocol port must differ from SQL port." >&2; continue; }
            port_busy "$MYSQLX_PORT" && { echo "Port $MYSQLX_PORT is already listening." >&2; _xp=$((MYSQLX_PORT + 1)); continue; }
            break
        done
    else
        MYSQLX_ENABLED=no; MYSQLX_PORT=""
    fi
}
collect_profile_inputs() {
    while :; do
        PROFILE=$(ask "my.cnf profile: 1=minimum, 2=production" "1")
        case "$PROFILE" in 1) PROFILE_NAME=minimum; break ;; 2) PROFILE_NAME=production; break ;; esac
    done
    DEDICATED=no; BUFFER_POOL_MB=0; MAX_CONNECTIONS=151; SLOW_QUERY=no; LONG_QUERY_TIME=2
    [ "$PROFILE" = "2" ] || return 0

    _running=$(pgrep -c mysqld 2>/dev/null || echo 0)
    _ded_default=yes; [ "$_running" -gt 0 ] 2>/dev/null && _ded_default=no
    if version_ge "$TARGET_VERSION" "8.0.3" && ask_yn "Dedicated server/VM for this MySQL instance" "$_ded_default"; then
        DEDICATED=yes
    else
        DEDICATED=no
        BUFFER_POOL_MB=$(ask "innodb_buffer_pool_size in MB (0=leave MySQL default)" "0")
        case "$BUFFER_POOL_MB" in *[!0-9]*|'') die "Invalid buffer pool size" ;; esac
    fi
    MAX_CONNECTIONS=$(ask "max_connections" "151")
    case "$MAX_CONNECTIONS" in *[!0-9]*|'') die "Invalid max_connections" ;; esac
    [ "$MAX_CONNECTIONS" -ge 1 ] || die "max_connections must be >= 1"
    if ask_yn "Enable slow query log" yes; then
        SLOW_QUERY=yes
        LONG_QUERY_TIME=$(ask "long_query_time seconds" "2")
    fi
}

collect_selinux_choice() {
    SELINUX_STATE=$(getenforce 2>/dev/null || echo Disabled)
    SELINUX_APPLY=no
    case "$SELINUX_STATE" in
        Enforcing|Permissive) ask_yn "Apply MySQL SELinux file/port contexts for selected custom paths and ports" yes && SELINUX_APPLY=yes ;;
    esac
}
check_instance_collisions() {
    [ "$PORT" -ge 1024 ] || block "Port $PORT requires root privileges; mysqld runs as $OS_USER"
    port_busy "$PORT" && block "SQL port already in use: $PORT"
    SOCKET="$RUNDIR/mysql.sock"
    PIDFILE="$RUNDIR/mysqld.pid"
    LOGFILE="$LOGDIR/mysqld.log"
    SLOWLOG="$LOGDIR/slow.log"

    socket_busy "$SOCKET" && block "Unix socket already in use: $SOCKET"
    [ -e "$PIDFILE" ] && block "PID file path already exists: $PIDFILE"
    path_nonempty "$DATADIR" && block "Data directory is not empty: $DATADIR"
    [ -e "$CONF" ] && block "Configuration file already exists: $CONF"
    systemctl cat "$SERVICE_NAME.service" >/dev/null 2>&1 && block "systemd unit already exists: $SERVICE_NAME.service"

    case "$FILESDIR/" in "$DATADIR"/*) block "secure_file_priv directory must not be inside Data Directory" ;; esac
    [ "$DATADIR" != "$LOGDIR" ] || block "Data and log directories must differ"
    [ "$DATADIR" != "$RUNDIR" ] || block "Data and socket/PID directories must differ"
    [ ${#SOCKET} -lt 100 ] || block "Unix socket path is too long for safe Linux operation: $SOCKET"

    if [ "$MYSQLX_ENABLED" = yes ]; then
        port_busy "$MYSQLX_PORT" && block "MySQL X Protocol port already in use: $MYSQLX_PORT"
        [ "$MYSQLX_PORT" -ge 1024 ] || block "MySQL X Protocol port requires root privileges"
    fi
}

choose_dependency_mode() {
    DEP_MODE=local
    [ "$PACKAGE_ACTION" = install ] || return 0
    _v=$(ask "OS dependency source: 1=local/installed only, 2=enabled OS repositories" "1")
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
    if [ "$MYSQLX_ENABLED" = yes ]; then echo "mysqlx-port=$MYSQLX_PORT"; else echo "mysqlx=0"; fi
    if [ "$PROFILE" = "2" ]; then
        echo "innodb-flush-log-at-trx-commit=1"
        echo "sync-binlog=1"
        echo "max-connections=$MAX_CONNECTIONS"
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
ExecStart=/usr/sbin/mysqld --defaults-file=$CONF
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
    echo "MySQL X       : $MYSQLX_ENABLED ${MYSQLX_PORT:+($MYSQLX_PORT)}"
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
    _installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' mysql-community-server 2>/dev/null || true)
    [ "$_installed" = "$TARGET_NEVRA" ] || die "Installed server RPM mismatch: $_installed != $TARGET_NEVRA"
}

ensure_os_account() {
    if getent passwd "$OS_USER" >/dev/null 2>&1; then
        OS_GROUP=$(id -gn "$OS_USER")
        return 0
    fi
    [ "$CREATE_OS_USER" = yes ] || die "OS account missing after package installation: $OS_USER"
    getent group "$OS_GROUP" >/dev/null 2>&1 || groupadd -r "$OS_GROUP" || die "groupadd failed"
    useradd -r -M -d "$INSTANCE_ROOT" -s /sbin/nologin -g "$OS_GROUP" "$OS_USER" || die "useradd failed"
    log "Created system account: $OS_USER:$OS_GROUP"
}

prepare_directories() {
    _root_was_new=no
    [ -d "$INSTANCE_ROOT" ] || { mkdir -p "$INSTANCE_ROOT" || die "Cannot create $INSTANCE_ROOT"; _root_was_new=yes; }
    mkdir -p "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR" "$(dirname "$CONF")" || die "Directory creation failed"
    chown "$OS_USER:$OS_GROUP" "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"
    chmod 750 "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR"
    [ "$_root_was_new" = yes ] && { chown "$OS_USER:$OS_GROUP" "$INSTANCE_ROOT"; chmod 750 "$INSTANCE_ROOT"; }
}
write_config() {
    [ ! -e "$CONF" ] || die "Refusing to overwrite existing config: $CONF"
    render_config > "$CONF" || die "Config write failed"
    chown root:"$OS_GROUP" "$CONF"
    chmod 640 "$CONF"
    log "Created config: $CONF"
}

selinux_port_owner() {
    _p=$1
    command -v semanage >/dev/null 2>&1 || return 0
    semanage port -l 2>/dev/null | awk -v p="$_p" '
        $2=="tcp" {
            t=$1;
            for(i=3;i<=NF;i++){
                x=$i; gsub(/,/,"",x);
                if(x ~ /^[0-9]+$/ && x+0==p){print t; exit}
                if(x ~ /^[0-9]+-[0-9]+$/){split(x,a,"-"); if(p>=a[1] && p<=a[2]){print t; exit}}
            }
        }'
}

selinux_ensure_port() {
    _p=$1
    _owner=$(selinux_port_owner "$_p")
    if [ -z "$_owner" ]; then
        semanage port -a -t mysqld_port_t -p tcp "$_p" || die "Failed to label TCP port $_p"
    elif [ "$_owner" != "mysqld_port_t" ]; then
        die "SELinux TCP port $_p already belongs to $_owner; automatic relabel blocked"
    fi
}
selinux_fcontext_set() {
    _type=$1; _expr=$2
    semanage fcontext -a -t "$_type" "$_expr" 2>/dev/null || semanage fcontext -m -t "$_type" "$_expr" || die "SELinux fcontext failed: $_expr"
}

apply_selinux() {
    [ "$SELINUX_APPLY" = yes ] || { log "SELinux policy changes skipped by user choice"; return 0; }
    command -v semanage >/dev/null 2>&1 || die "semanage not found. Prepare policycoreutils-python-utils before rerun."
    command -v restorecon >/dev/null 2>&1 || die "restorecon not found"

    selinux_fcontext_set mysqld_db_t "$DATADIR(/.*)?"
    selinux_fcontext_set mysqld_log_t "$LOGDIR(/.*)?"
    selinux_fcontext_set mysqld_var_run_t "$RUNDIR(/.*)?"
    selinux_fcontext_set mysqld_db_t "$FILESDIR(/.*)?"
    restorecon -Rv "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR" || die "restorecon failed"

    [ "$TCP_ENABLED" = yes ] && selinux_ensure_port "$PORT"
    [ "$MYSQLX_ENABLED" = yes ] && selinux_ensure_port "$MYSQLX_PORT"
    restorecon "$CONF" 2>/dev/null || true
}

validate_account_access() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$OS_USER" -- test -r "$CONF" || die "$OS_USER cannot read $CONF"
        runuser -u "$OS_USER" -- test -w "$DATADIR" || die "$OS_USER cannot write $DATADIR"
        runuser -u "$OS_USER" -- test -w "$LOGDIR" || die "$OS_USER cannot write $LOGDIR"
        runuser -u "$OS_USER" -- test -w "$RUNDIR" || die "$OS_USER cannot write $RUNDIR"
    fi
}
validate_config() {
    MYSQLD_BIN=$(command -v mysqld 2>/dev/null || true)
    [ -n "$MYSQLD_BIN" ] || MYSQLD_BIN=/usr/sbin/mysqld
    [ -x "$MYSQLD_BIN" ] || die "mysqld binary not found after package stage"

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
    log "Initializing Data Directory with --initialize"
    if "$MYSQLD_BIN" --no-defaults --initialize --user="$OS_USER" --datadir="$DATADIR" >"$INIT_LOG" 2>&1; then
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
    chown root:root "$UNIT_FILE"; chmod 644 "$UNIT_FILE"
    systemctl daemon-reload || die "systemctl daemon-reload failed"
}
start_service() {
    port_busy "$PORT" && die "SQL port $PORT became busy before service start"
    socket_busy "$SOCKET" && die "Socket path became busy before service start"
    systemctl enable "$SERVICE_NAME.service" >/dev/null || die "systemctl enable failed"
    if ! systemctl start "$SERVICE_NAME.service"; then
        systemctl status "$SERVICE_NAME.service" --no-pager -l 2>/dev/null || true
        journalctl -u "$SERVICE_NAME.service" -n 100 --no-pager 2>/dev/null || true
        [ -f "$LOGFILE" ] && tail -100 "$LOGFILE" || true
        if [ "$SELINUX_STATE" != Disabled ] && command -v ausearch >/dev/null 2>&1; then
            ausearch -m AVC -ts recent 2>/dev/null | tail -50 || true
        fi
        die "MySQL service start failed"
    fi
}

postcheck() {
    echo ""
    echo "===== POST-INSTALL VALIDATION ====="
    systemctl is-active --quiet "$SERVICE_NAME.service" || die "Service is not active"
    _pid=$(systemctl show -p MainPID --value "$SERVICE_NAME.service" 2>/dev/null || echo 0)
    [ "$_pid" -gt 0 ] 2>/dev/null || die "MainPID not detected"
    _run_user=$(ps -o user= -p "$_pid" 2>/dev/null | awk '{print $1}')
    [ "$_run_user" = "$OS_USER" ] || die "mysqld OS user mismatch: $_run_user != $OS_USER"

    [ -S "$SOCKET" ] || die "Expected Unix socket not found: $SOCKET"
    if [ "$TCP_ENABLED" = yes ]; then port_busy "$PORT" || die "Expected SQL port not listening: $PORT"; fi
    if [ "$MYSQLX_ENABLED" = yes ]; then port_busy "$MYSQLX_PORT" || die "Expected MySQL X port not listening: $MYSQLX_PORT"; fi

    echo "Service        : ACTIVE"
    echo "MainPID        : $_pid"
    echo "Process user   : $_run_user"
    echo "Socket         : $SOCKET"
    echo "SQL port       : $PORT"
    "$MYSQLD_BIN" --version
    command -v my_print_defaults >/dev/null 2>&1 && my_print_defaults --defaults-file="$CONF" mysqld || true
    if [ "$SELINUX_STATE" != Disabled ]; then
        echo "-- SELinux contexts --"
        ls -Zd "$DATADIR" "$LOGDIR" "$RUNDIR" "$FILESDIR" 2>/dev/null || true
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
    check_foreign_mysql
    package_test
    show_running_mysqld
    print_precheck_summary

    if [ "$MODE" = precheck ]; then
        [ "$BLOCKERS" -eq 0 ] && exit 0 || exit 2
    fi
    if [ "$MODE" = install ] && [ "$BLOCKERS" -gt 0 ]; then
        die "Precheck blockers detected. No installation changes made."
    fi
    collect_instance_inputs
    collect_network_inputs
    collect_profile_inputs
    collect_selinux_choice
    choose_dependency_mode
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
        [ "$BLOCKERS" -gt 0 ] && echo "DRY-RUN blockers: $BLOCKERS (real installation would stop)."
        exit 0
    fi
    [ "$BLOCKERS" -eq 0 ] || die "Collision/configuration blockers detected. No installation changes made."
    ask_yn "Proceed with installation using this plan" no || die "Cancelled by user"

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
}

main "$@"
