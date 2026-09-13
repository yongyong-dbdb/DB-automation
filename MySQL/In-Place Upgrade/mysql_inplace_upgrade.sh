#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi

set -Eeuo pipefail

SCRIPT_VERSION="1.0.1"
STEP=""
BASE="${BASE:-/home/mysql}"
BUNDLE_TAR="${BUNDLE_TAR:-}"
OLD_BUNDLE_TAR="${OLD_BUNDLE_TAR:-}"
MYSQL_SERVICE="${MYSQL_SERVICE:-mysqld}"
MYSQL_CNF="${MYSQL_CNF:-/etc/my.cnf}"
MYSQL_USER_NAME="${MYSQL_USER_NAME:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_SOCKET="${MYSQL_SOCKET:-}"
WORK_DIR="${WORK_DIR:-}"
BACKUP_ROOT="${BACKUP_ROOT:-}"
STATE_FILE="${STATE_FILE:-}"
LOG_DIR="${LOG_DIR:-}"
ALLOW_UNVERIFIED_PATH="${ALLOW_UNVERIFIED_PATH:-false}"
ALLOW_REPLICATION_TOPOLOGY="${ALLOW_REPLICATION_TOPOLOGY:-false}"
SKIP_PHYSICAL_BACKUP="${SKIP_PHYSICAL_BACKUP:-false}"
DRY_RUN="${DRY_RUN:-false}"
CURRENT_VERSION="${CURRENT_VERSION:-}"
TARGET_VERSION="${TARGET_VERSION:-}"
DATADIR="${DATADIR:-}"
LOG_ERROR="${LOG_ERROR:-}"
PID_FILE="${PID_FILE:-}"
BACKUP_DIR="${BACKUP_DIR:-}"
EXTRACT_DIR="${EXTRACT_DIR:-}"
OLD_EXTRACT_DIR="${OLD_EXTRACT_DIR:-}"
RUN_ID="${RUN_ID:-}"
LOG_FILE=""
MYSQL_LOGIN_FILE=""

usage() {
    cat <<'EOF'
MySQL RPM Bundle In-place Upgrade Automation

Usage:
  sh mysql_inplace_upgrade.sh [options] precheck
  sh mysql_inplace_upgrade.sh [options] prepare
  sh mysql_inplace_upgrade.sh [options] upgrade
  sh mysql_inplace_upgrade.sh [options] postcheck
  sh mysql_inplace_upgrade.sh [options] rollback
  sh mysql_inplace_upgrade.sh [options] status

Steps:
  precheck   Detect current/target versions, validate the upgrade path and environment.
  prepare    Extract and validate target RPMs, collect metadata and save state.
  upgrade    Stop MySQL, create an offline physical backup, upgrade RPMs and start MySQL.
  postcheck  Validate version, service, SQL access, tables and upgrade errors.
  rollback   Restore the offline backup and old RPM bundle after explicit confirmation.
  status     Display saved state and current service/package status.

Options:
  --bundle PATH             Target MySQL RPM Bundle tar file.
  --old-bundle PATH         Old MySQL RPM Bundle tar file for rollback.
  --base PATH               Base directory. Default: /home/mysql
  --config PATH             MySQL configuration file. Default: /etc/my.cnf
  --service NAME            systemd service. Default: mysqld
  --socket PATH             MySQL socket. Auto-detected when omitted.
  --backup-root PATH        Backup parent directory.
  --work-dir PATH           RPM extraction and metadata directory.
  --allow-unverified-path   Permit a path not in the built-in safe matrix.
  --allow-replication-topology
                            Permit execution when replication/Group Replication is detected.
  --skip-physical-backup    Skip physical backup. Not recommended.
  --dry-run                 Print mutating commands without executing them.
  --version                 Print script version.
  -h, --help                Show this help.

Environment variables may be used instead of options. MYSQL_PASSWORD is accepted but
interactive password input is safer because saved state never stores the password.
EOF
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local message
    message="[$(timestamp)] $*"
    printf '%s\n' "$message"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$message" >> "$LOG_FILE"
    fi
}

warn() {
    log "WARN: $*" >&2
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$MYSQL_LOGIN_FILE" && -f "$MYSQL_LOGIN_FILE" ]]; then
        rm -f -- "$MYSQL_LOGIN_FILE"
    fi
}

trap cleanup EXIT

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

confirm() {
    local expected="$1"
    local message="$2"
    local answer

    printf '\n%s\n' "$message"
    printf 'Type "%s" to continue: ' "$expected"
    read -r answer
    [[ "$answer" == "$expected" ]] || die "cancelled"
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "this step must be run as root"
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
    done
}

bool_value() {
    case "$1" in
        true|false) printf '%s\n' "$1" ;;
        *) die "boolean value must be true or false: $1" ;;
    esac
}

absolute_path() {
    local input="$1"
    if [[ "$input" == /* ]]; then
        printf '%s\n' "$input"
    else
        printf '%s/%s\n' "$PWD" "$input"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle)
                [[ $# -ge 2 ]] || die "--bundle requires a path"
                BUNDLE_TAR="$2"
                shift 2
                ;;
            --bundle=*) BUNDLE_TAR="${1#*=}"; shift ;;
            --old-bundle)
                [[ $# -ge 2 ]] || die "--old-bundle requires a path"
                OLD_BUNDLE_TAR="$2"
                shift 2
                ;;
            --old-bundle=*) OLD_BUNDLE_TAR="${1#*=}"; shift ;;
            --base)
                [[ $# -ge 2 ]] || die "--base requires a path"
                BASE="$2"
                shift 2
                ;;
            --base=*) BASE="${1#*=}"; shift ;;
            --config)
                [[ $# -ge 2 ]] || die "--config requires a path"
                MYSQL_CNF="$2"
                shift 2
                ;;
            --config=*) MYSQL_CNF="${1#*=}"; shift ;;
            --service)
                [[ $# -ge 2 ]] || die "--service requires a name"
                MYSQL_SERVICE="$2"
                shift 2
                ;;
            --service=*) MYSQL_SERVICE="${1#*=}"; shift ;;
            --socket)
                [[ $# -ge 2 ]] || die "--socket requires a path"
                MYSQL_SOCKET="$2"
                shift 2
                ;;
            --socket=*) MYSQL_SOCKET="${1#*=}"; shift ;;
            --backup-root)
                [[ $# -ge 2 ]] || die "--backup-root requires a path"
                BACKUP_ROOT="$2"
                shift 2
                ;;
            --backup-root=*) BACKUP_ROOT="${1#*=}"; shift ;;
            --work-dir)
                [[ $# -ge 2 ]] || die "--work-dir requires a path"
                WORK_DIR="$2"
                shift 2
                ;;
            --work-dir=*) WORK_DIR="${1#*=}"; shift ;;
            --allow-unverified-path) ALLOW_UNVERIFIED_PATH=true; shift ;;
            --allow-replication-topology) ALLOW_REPLICATION_TOPOLOGY=true; shift ;;
            --skip-physical-backup) SKIP_PHYSICAL_BACKUP=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help|help) STEP="help"; shift ;;
            -*) die "unknown option: $1" ;;
            *)
                [[ -z "$STEP" ]] || die "multiple steps specified: $STEP and $1"
                STEP="$1"
                shift
                ;;
        esac
    done
    STEP="${STEP:-help}"
}

init_paths() {
    BASE="$(absolute_path "$BASE")"
    WORK_DIR="${WORK_DIR:-$BASE/mysql_inplace_upgrade_work}"
    BACKUP_ROOT="${BACKUP_ROOT:-$BASE/mysql_inplace_upgrade_backup}"
    STATE_FILE="${STATE_FILE:-$BASE/.mysql_inplace_upgrade.conf}"
    LOG_DIR="${LOG_DIR:-$BASE/mysql_inplace_upgrade_logs}"
    WORK_DIR="$(absolute_path "$WORK_DIR")"
    BACKUP_ROOT="$(absolute_path "$BACKUP_ROOT")"
    STATE_FILE="$(absolute_path "$STATE_FILE")"
    LOG_DIR="$(absolute_path "$LOG_DIR")"
    [[ -z "$BUNDLE_TAR" ]] || BUNDLE_TAR="$(absolute_path "$BUNDLE_TAR")"
    [[ -z "$OLD_BUNDLE_TAR" ]] || OLD_BUNDLE_TAR="$(absolute_path "$OLD_BUNDLE_TAR")"
    ALLOW_UNVERIFIED_PATH="$(bool_value "$ALLOW_UNVERIFIED_PATH")"
    ALLOW_REPLICATION_TOPOLOGY="$(bool_value "$ALLOW_REPLICATION_TOPOLOGY")"
    SKIP_PHYSICAL_BACKUP="$(bool_value "$SKIP_PHYSICAL_BACKUP")"
    DRY_RUN="$(bool_value "$DRY_RUN")"
}

init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/mysql_inplace_upgrade_$(date '+%Y%m%d_%H%M%S')_${STEP}.log"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

version_gt() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

version_series() {
    local version="$1"
    local major minor rest
    IFS=. read -r major minor rest <<< "$version"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    printf '%s.%s\n' "$major" "$minor"
}

is_supported_path() {
    local current="$1"
    local target="$2"
    local current_series target_series current_major current_minor target_major target_minor

    version_gt "$target" "$current" || return 1
    current_series="$(version_series "$current")" || return 1
    target_series="$(version_series "$target")" || return 1
    [[ "$current_series" == "$target_series" ]] && return 0

    IFS=. read -r current_major current_minor <<< "$current_series"
    IFS=. read -r target_major target_minor <<< "$target_series"

    [[ "$current_series" == "5.7" && "$target_series" == "8.0" ]] && return 0
    [[ "$current_series" == "8.0" && "$target_series" == "8.4" ]] && return 0
    [[ "$current_major" == "8" && "$current_minor" -ge 1 && "$current_minor" -le 3 && "$target_series" == "8.4" ]] && return 0
    [[ "$current_series" == "8.4" && "$target_major" == "9" ]] && return 0
    [[ "$current_major" == "$target_major" && "$current_major" -ge 9 && "$target_minor" -gt "$current_minor" ]] && return 0
    return 1
}

find_bundle() {
    local candidate
    local candidates=()
    local selection index

    if [[ -n "$BUNDLE_TAR" ]]; then
        [[ -f "$BUNDLE_TAR" ]] || die "target bundle not found: $BUNDLE_TAR"
        return
    fi

    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(find "$BASE" -maxdepth 2 -type f \( -name 'mysql-*.rpm-bundle.tar' -o -name 'mysql-*-bundle.tar' \) | sort -V)

    [[ ${#candidates[@]} -gt 0 ]] || die "no MySQL RPM Bundle tar found under $BASE"
    if [[ ${#candidates[@]} -eq 1 ]]; then
        BUNDLE_TAR="${candidates[0]}"
        return
    fi

    printf 'Available MySQL RPM Bundle files:\n'
    for index in "${!candidates[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${candidates[$index]}"
    done
    printf 'Select target bundle [1-%d]: ' "${#candidates[@]}"
    read -r selection
    [[ "$selection" =~ ^[1-9][0-9]*$ ]] || die "invalid selection: $selection"
    (( selection <= ${#candidates[@]} )) || die "selection out of range: $selection"
    BUNDLE_TAR="${candidates[$((selection - 1))]}"
}

bundle_version_from_name() {
    local name
    name="$(basename "$1")"
    if [[ "$name" =~ ^mysql-([0-9]+\.[0-9]+\.[0-9]+)(-[^-]+)?[.-].*bundle[.]tar$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$name" =~ ^mysql-([0-9]+\.[0-9]+\.[0-9]+).*rpm-bundle[.]tar$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

detect_current_version() {
    local rpm_version sql_version
    rpm_version="$(rpm -q --qf '%{VERSION}\n' mysql-community-server 2>/dev/null || true)"
    [[ "$rpm_version" =~ ^[0-9]+([.][0-9]+){2}$ ]] || die "mysql-community-server RPM is not installed"
    CURRENT_VERSION="$rpm_version"

    if systemctl is-active --quiet "$MYSQL_SERVICE"; then
        sql_version="$(mysql_query_value 'SELECT VERSION();' 2>/dev/null || true)"
        if [[ -n "$sql_version" ]]; then
            sql_version="${sql_version%%-*}"
            [[ "$sql_version" == "$CURRENT_VERSION" ]] || die "running server version $sql_version differs from RPM version $CURRENT_VERSION"
        fi
    fi
}

detect_target_version() {
    local parsed
    parsed="$(bundle_version_from_name "$BUNDLE_TAR" || true)"
    [[ -n "$parsed" ]] || die "cannot parse target version from bundle filename: $BUNDLE_TAR"
    TARGET_VERSION="$parsed"
}

load_defaults_value() {
    local group="$1"
    local option="$2"
    my_print_defaults --defaults-file="$MYSQL_CNF" "$group" 2>/dev/null | sed -n "s/^--${option}=//p" | tail -1
}

detect_paths() {
    local resolved_datadir resolved_backup
    [[ -f "$MYSQL_CNF" ]] || die "MySQL config not found: $MYSQL_CNF"
    DATADIR="${DATADIR:-$(load_defaults_value mysqld datadir)}"
    MYSQL_SOCKET="${MYSQL_SOCKET:-$(load_defaults_value mysqld socket)}"
    LOG_ERROR="${LOG_ERROR:-$(load_defaults_value mysqld log-error)}"
    PID_FILE="${PID_FILE:-$(load_defaults_value mysqld pid-file)}"
    DATADIR="${DATADIR:-/var/lib/mysql}"
    MYSQL_SOCKET="${MYSQL_SOCKET:-/var/lib/mysql/mysql.sock}"
    LOG_ERROR="${LOG_ERROR:-/var/log/mysqld.log}"
    PID_FILE="${PID_FILE:-/var/run/mysqld/mysqld.pid}"
    [[ "$DATADIR" == /* ]] || die "datadir must be an absolute path: $DATADIR"
    [[ -d "$DATADIR" ]] || die "datadir not found: $DATADIR"
    [[ -f "$DATADIR/auto.cnf" ]] || die "MySQL auto.cnf not found in datadir: $DATADIR"
    [[ -d "$DATADIR/mysql" ]] || die "mysql system schema directory not found in datadir: $DATADIR/mysql"
    resolved_datadir="$(readlink -m -- "$DATADIR")"
    resolved_backup="$(readlink -m -- "$BACKUP_ROOT")"
    [[ "$resolved_backup" != "$resolved_datadir" && "$resolved_backup" != "$resolved_datadir"/* ]] || die "backup root must not be inside datadir: $BACKUP_ROOT"
}

create_mysql_login_file() {
    local escaped_password escaped_user escaped_socket
    [[ -n "$MYSQL_LOGIN_FILE" ]] && return 0
    if [[ -z "$MYSQL_PASSWORD" ]]; then
        printf 'MySQL password for %s: ' "$MYSQL_USER_NAME"
        read -r -s MYSQL_PASSWORD
        printf '\n'
    fi
    [[ -n "$MYSQL_PASSWORD" ]] || die "MySQL password is empty"
    MYSQL_LOGIN_FILE="$(mktemp "$WORK_DIR/mysql-login.XXXXXX.cnf")"
    chmod 600 "$MYSQL_LOGIN_FILE"
    escaped_password="${MYSQL_PASSWORD//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"
    escaped_user="${MYSQL_USER_NAME//\\/\\\\}"
    escaped_user="${escaped_user//\"/\\\"}"
    escaped_socket="${MYSQL_SOCKET//\\/\\\\}"
    escaped_socket="${escaped_socket//\"/\\\"}"
    {
        printf '[client]\n'
        printf 'user="%s"\n' "$escaped_user"
        printf 'password="%s"\n' "$escaped_password"
        printf 'socket="%s"\n' "$escaped_socket"
    } > "$MYSQL_LOGIN_FILE"
}

mysql_query() {
    create_mysql_login_file
    mysql --defaults-extra-file="$MYSQL_LOGIN_FILE" --batch --raw --skip-column-names -e "$1"
}

mysql_query_value() {
    mysql_query "$1" | head -1
}

validate_sql_access() {
    local result
    result="$(mysql_query_value 'SELECT 1;')" || die "MySQL SQL connection failed"
    [[ "$result" == "1" ]] || die "unexpected SQL validation result: $result"
}

check_mysql_topology() {
    local async_channels group_members
    async_channels="$(mysql_query_value 'SELECT COUNT(*) FROM performance_schema.replication_connection_configuration;')"
    group_members="$(mysql_query_value 'SELECT COUNT(*) FROM performance_schema.replication_group_members;')"
    [[ "$async_channels" =~ ^[0-9]+$ ]] || die "could not determine asynchronous replication topology"
    [[ "$group_members" =~ ^[0-9]+$ ]] || die "could not determine Group Replication topology"

    if (( async_channels > 0 || group_members > 0 )); then
        if [[ "$ALLOW_REPLICATION_TOPOLOGY" == "true" ]]; then
            warn "replication topology detected and explicitly allowed: channels=$async_channels group_members=$group_members"
            warn "single-server execution does not implement rolling topology orchestration"
        else
            die "replication topology detected: channels=$async_channels group_members=$group_members; use a topology-specific rolling upgrade plan"
        fi
    else
        log "single-server topology check passed"
    fi
}

check_prepared_xa() {
    local xa_output
    xa_output="$(mysql_query 'XA RECOVER;' || true)"
    [[ -z "$xa_output" ]] || die "prepared XA transactions exist; resolve them before upgrade"
    log "no prepared XA transactions detected"
}

validate_path() {
    if is_supported_path "$CURRENT_VERSION" "$TARGET_VERSION"; then
        log "supported path: $CURRENT_VERSION -> $TARGET_VERSION"
        return 0
    fi
    if [[ "$ALLOW_UNVERIFIED_PATH" == "true" ]]; then
        warn "path is not in the built-in safe matrix: $CURRENT_VERSION -> $TARGET_VERSION"
        warn "verify the target path in the official MySQL documentation before proceeding"
        return 0
    fi
    die "unsupported or non-increasing path: $CURRENT_VERSION -> $TARGET_VERSION"
}

check_service() {
    systemctl cat "$MYSQL_SERVICE" >/dev/null 2>&1 || die "systemd service not found: $MYSQL_SERVICE"
    systemctl is-active --quiet "$MYSQL_SERVICE" || die "MySQL service is not active: $MYSQL_SERVICE"
}

check_disk_space() {
    local data_kb available_kb required_kb backup_parent
    [[ "$SKIP_PHYSICAL_BACKUP" == "false" ]] || return 0
    backup_parent="$(dirname "$BACKUP_ROOT")"
    mkdir -p "$backup_parent"
    data_kb="$(du -sk "$DATADIR" | awk '{print $1}')"
    available_kb="$(df -Pk "$backup_parent" | awk 'NR==2 {print $4}')"
    required_kb=$((data_kb + data_kb / 5 + 102400))
    (( available_kb >= required_kb )) || die "insufficient backup space: required=${required_kb}KB available=${available_kb}KB"
    log "backup space check passed: data=${data_kb}KB required=${required_kb}KB available=${available_kb}KB"
}

list_bundle_rpms() {
    tar -tf "$1" | sed -n '/[.]rpm$/p'
}

validate_bundle_contents() {
    local bundle="$1"
    local expected_version="$2"
    local package_name
    local required=(
        mysql-community-common
        mysql-community-client-plugins
        mysql-community-libs
        mysql-community-icu-data-files
        mysql-community-client
        mysql-community-server
    )

    tar -tf "$bundle" >/dev/null || die "invalid tar archive: $bundle"
    for package_name in "${required[@]}"; do
        list_bundle_rpms "$bundle" | grep -Eq "(^|/)${package_name}-${expected_version}([.-]|$)" || die "required target RPM missing: $package_name $expected_version"
    done
}

extract_bundle() {
    local bundle="$1"
    local destination="$2"
    mkdir -p "$destination"
    if find "$destination" -maxdepth 1 -type f -name '*.rpm' | grep -q .; then
        log "reusing extracted RPMs: $destination"
    else
        run tar -xf "$bundle" -C "$destination"
    fi
}

rpm_path_for_package() {
    local directory="$1"
    local package_name="$2"
    local version="$3"
    local result
    result="$(find "$directory" -maxdepth 1 -type f -name "${package_name}-${version}-*.rpm" ! -name '*debuginfo*' ! -name '*debugsource*' ! -name '*-debug-*' | sort | head -1)"
    [[ -n "$result" ]] || return 1
    printf '%s\n' "$result"
}

build_target_rpm_list() {
    local directory="$1"
    local version="$2"
    local package_name rpm_file
    local installed_name
    local required=(
        mysql-community-common
        mysql-community-client-plugins
        mysql-community-libs
        mysql-community-icu-data-files
        mysql-community-client
        mysql-community-server
    )
    local rpms=()

    for package_name in "${required[@]}"; do
        rpm_file="$(rpm_path_for_package "$directory" "$package_name" "$version")" || die "target RPM not found: $package_name $version"
        rpms+=("$rpm_file")
    done

    while IFS= read -r installed_name; do
        case "$installed_name" in
            mysql-community-common|mysql-community-client-plugins|mysql-community-libs|mysql-community-icu-data-files|mysql-community-client|mysql-community-server) continue ;;
            mysql-community-*)
                rpm_file="$(rpm_path_for_package "$directory" "$installed_name" "$version" || true)"
                if [[ -n "$rpm_file" ]]; then
                    rpms+=("$rpm_file")
                else
                    warn "installed optional package has no target RPM and requires manual review: $installed_name"
                fi
                ;;
        esac
    done < <(rpm -qa --qf '%{NAME}\n' 'mysql-community-*' | sort -u)

    printf '%s\n' "${rpms[@]}" | awk '!seen[$0]++'
}

save_state() {
    umask 077
    mkdir -p "$(dirname "$STATE_FILE")"
    {
        printf 'STATE_SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
        printf 'BASE=%q\n' "$BASE"
        printf 'BUNDLE_TAR=%q\n' "$BUNDLE_TAR"
        printf 'OLD_BUNDLE_TAR=%q\n' "$OLD_BUNDLE_TAR"
        printf 'MYSQL_SERVICE=%q\n' "$MYSQL_SERVICE"
        printf 'MYSQL_CNF=%q\n' "$MYSQL_CNF"
        printf 'MYSQL_USER_NAME=%q\n' "$MYSQL_USER_NAME"
        printf 'MYSQL_SOCKET=%q\n' "$MYSQL_SOCKET"
        printf 'WORK_DIR=%q\n' "$WORK_DIR"
        printf 'BACKUP_ROOT=%q\n' "$BACKUP_ROOT"
        printf 'STATE_FILE=%q\n' "$STATE_FILE"
        printf 'LOG_DIR=%q\n' "$LOG_DIR"
        printf 'ALLOW_UNVERIFIED_PATH=%q\n' "$ALLOW_UNVERIFIED_PATH"
        printf 'ALLOW_REPLICATION_TOPOLOGY=%q\n' "$ALLOW_REPLICATION_TOPOLOGY"
        printf 'SKIP_PHYSICAL_BACKUP=%q\n' "$SKIP_PHYSICAL_BACKUP"
        printf 'CURRENT_VERSION=%q\n' "$CURRENT_VERSION"
        printf 'TARGET_VERSION=%q\n' "$TARGET_VERSION"
        printf 'DATADIR=%q\n' "$DATADIR"
        printf 'LOG_ERROR=%q\n' "$LOG_ERROR"
        printf 'PID_FILE=%q\n' "$PID_FILE"
        printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
        printf 'EXTRACT_DIR=%q\n' "$EXTRACT_DIR"
        printf 'OLD_EXTRACT_DIR=%q\n' "$OLD_EXTRACT_DIR"
        printf 'RUN_ID=%q\n' "$RUN_ID"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

load_state() {
    [[ -f "$STATE_FILE" ]] || die "state file not found; run precheck and prepare first: $STATE_FILE"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    DRY_RUN="${DRY_RUN:-false}"
}

collect_metadata() {
    local destination="$1"
    mkdir -p "$destination"
    rpm -qa | sort > "$destination/rpm_all.txt"
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' 'mysql-community-*' | sort > "$destination/rpm_mysql.txt"
    cp -a "$MYSQL_CNF" "$destination/my.cnf"
    my_print_defaults --defaults-file="$MYSQL_CNF" mysqld > "$destination/mysqld_defaults.txt" 2>&1 || true
    systemctl cat "$MYSQL_SERVICE" > "$destination/systemd_unit.txt" 2>&1 || true
    getenforce > "$destination/selinux_status.txt" 2>&1 || true
    ls -Zd "$BASE" "$DATADIR" "$(dirname "$LOG_ERROR")" "$(dirname "$PID_FILE")" > "$destination/selinux_contexts.txt" 2>&1 || true
    df -hT "$DATADIR" "$BACKUP_ROOT" > "$destination/filesystem.txt" 2>&1 || true
    du -sh "$DATADIR" > "$destination/datadir_size.txt" 2>&1 || true
    if systemctl is-active --quiet "$MYSQL_SERVICE"; then
        mysql_query 'SELECT VERSION(); SHOW DATABASES; SHOW VARIABLES WHERE Variable_name IN ("basedir","datadir","socket","pid_file","log_error","port","lower_case_table_names","character_set_server","collation_server","sql_mode");' > "$destination/mysql_runtime.txt"
        mysql_query 'SELECT PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_STATUS, PLUGIN_TYPE FROM INFORMATION_SCHEMA.PLUGINS ORDER BY PLUGIN_NAME;' > "$destination/mysql_plugins.txt"
        mysql_query 'SELECT user, host, plugin, account_locked, password_expired FROM mysql.user ORDER BY user, host;' > "$destination/mysql_accounts.txt"
    fi
}

do_precheck() {
    require_root
    require_commands bash tar rpm yum systemctl mysql my_print_defaults sort find awk sed grep df du cp
    mkdir -p "$WORK_DIR"
    find_bundle
    detect_target_version
    detect_paths
    detect_current_version
    validate_path
    validate_bundle_contents "$BUNDLE_TAR" "$TARGET_VERSION"
    check_service
    validate_sql_access
    check_mysql_topology
    check_prepared_xa
    mysqlcheck --defaults-extra-file="$MYSQL_LOGIN_FILE" --all-databases --check-upgrade
    if command -v mysqlsh >/dev/null 2>&1; then
        log "mysqlsh detected; run Upgrade Checker for target $TARGET_VERSION and archive its result before upgrade"
    else
        warn "mysqlsh not found; MySQL Shell Upgrade Checker must be run separately before a production upgrade"
    fi
    check_disk_space
    mysqld --defaults-file="$MYSQL_CNF" --validate-config
    RUN_ID="${RUN_ID:-$(date '+%Y%m%d_%H%M%S')_${CURRENT_VERSION}_to_${TARGET_VERSION}}"
    EXTRACT_DIR="$WORK_DIR/mysql-$TARGET_VERSION"
    [[ -z "$OLD_BUNDLE_TAR" ]] || OLD_EXTRACT_DIR="$WORK_DIR/mysql-$CURRENT_VERSION"
    save_state

    log "precheck completed"
    log "current version : $CURRENT_VERSION"
    log "target version  : $TARGET_VERSION"
    log "target bundle   : $BUNDLE_TAR"
    log "datadir         : $DATADIR"
    log "socket          : $MYSQL_SOCKET"
    log "error log       : $LOG_ERROR"
    log "state file      : $STATE_FILE"
}

do_prepare() {
    require_root
    load_state
    require_commands tar rpm yum systemctl mysql my_print_defaults
    [[ -f "$BUNDLE_TAR" ]] || die "target bundle not found: $BUNDLE_TAR"
    detect_current_version
    [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]] || die "target version is already installed: $TARGET_VERSION"
    validate_path
    validate_bundle_contents "$BUNDLE_TAR" "$TARGET_VERSION"
    extract_bundle "$BUNDLE_TAR" "$EXTRACT_DIR"
    mapfile -t target_rpms < <(build_target_rpm_list "$EXTRACT_DIR" "$TARGET_VERSION")
    [[ ${#target_rpms[@]} -ge 6 ]] || die "target RPM list is incomplete"
    rpm -K "${target_rpms[@]}" | tee "$WORK_DIR/target_rpm_signatures.txt"
    printf '%s\n' "${target_rpms[@]}" > "$WORK_DIR/target_rpms.txt"
    collect_metadata "$WORK_DIR/precheck_$RUN_ID"
    save_state
    log "prepare completed"
    log "target RPM list: $WORK_DIR/target_rpms.txt"
}

create_offline_backup() {
    local data_parent data_name
    [[ "$SKIP_PHYSICAL_BACKUP" == "false" ]] || {
        warn "physical backup skipped by explicit option"
        return 0
    }
    BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"
    [[ ! -e "$BACKUP_DIR" ]] || die "backup directory already exists: $BACKUP_DIR"
    if [[ "$DRY_RUN" == "true" ]]; then
        run mkdir -p "$BACKUP_DIR"
        run cp -a --reflink=auto "$MYSQL_CNF" "$BACKUP_DIR/my.cnf"
        run cp -a --reflink=auto "$DATADIR" "$BACKUP_DIR/datadir"
        log "dry-run: offline backup would be created at $BACKUP_DIR"
        return 0
    fi
    run mkdir -p "$BACKUP_DIR"
    data_parent="$(dirname "$DATADIR")"
    data_name="$(basename "$DATADIR")"
    run cp -a --reflink=auto "$MYSQL_CNF" "$BACKUP_DIR/my.cnf"
    run cp -a --reflink=auto "$data_parent/$data_name" "$BACKUP_DIR/datadir"
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' 'mysql-community-*' | sort > "$BACKUP_DIR/rpm_mysql_before.txt"
    printf '%s\n' "$CURRENT_VERSION" > "$BACKUP_DIR/source_version.txt"
    printf '%s\n' "$DATADIR" > "$BACKUP_DIR/original_datadir_path.txt"
    sync
    save_state
    log "offline backup completed: $BACKUP_DIR"
}

clean_shutdown() {
    mysql_query 'SET GLOBAL innodb_fast_shutdown=0;'
    log "innodb_fast_shutdown set to 0"
    run systemctl stop "$MYSQL_SERVICE"
    if [[ "$DRY_RUN" == "false" ]]; then
        systemctl is-active --quiet "$MYSQL_SERVICE" && die "MySQL service did not stop"
        [[ ! -e "$PID_FILE" ]] || die "PID file still exists after stop: $PID_FILE"
    fi
    log "MySQL stopped"
}

install_target_rpms() {
    local rpms=()
    [[ -f "$WORK_DIR/target_rpms.txt" ]] || die "target RPM list not found; run prepare first"
    mapfile -t rpms < "$WORK_DIR/target_rpms.txt"
    [[ ${#rpms[@]} -ge 6 ]] || die "target RPM list is incomplete"
    run yum localinstall -y "${rpms[@]}"
    if [[ "$DRY_RUN" == "false" ]]; then
        local installed_version
        installed_version="$(rpm -q --qf '%{VERSION}\n' mysql-community-server)"
        [[ "$installed_version" == "$TARGET_VERSION" ]] || die "installed version mismatch: expected=$TARGET_VERSION actual=$installed_version"
    fi
}

start_and_wait() {
    run systemctl daemon-reload
    run systemctl start "$MYSQL_SERVICE"
    if [[ "$DRY_RUN" == "false" ]]; then
        systemctl is-active --quiet "$MYSQL_SERVICE" || {
            systemctl status "$MYSQL_SERVICE" --no-pager || true
            tail -100 "$LOG_ERROR" 2>/dev/null || true
            die "new MySQL failed to start; do not start the old binary on this datadir"
        }
    fi
    log "MySQL started"
}

do_upgrade() {
    require_root
    load_state
    require_commands yum rpm systemctl cp sync
    check_service
    validate_sql_access
    detect_current_version
    [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]] || die "target version is already installed: $TARGET_VERSION"
    validate_path
    check_disk_space
    [[ -f "$WORK_DIR/target_rpms.txt" ]] || die "prepare step has not completed"

    log "upgrade summary"
    log "  version : $CURRENT_VERSION -> $TARGET_VERSION"
    log "  datadir : $DATADIR"
    log "  bundle  : $BUNDLE_TAR"
    log "  backup  : $BACKUP_ROOT/$RUN_ID"
    confirm "UPGRADE $CURRENT_VERSION TO $TARGET_VERSION" "MySQL will be stopped and the existing datadir will be upgraded in place."

    clean_shutdown
    create_offline_backup
    install_target_rpms
    start_and_wait
    if [[ "$DRY_RUN" == "false" ]]; then
        save_state
    fi
    log "upgrade step completed; run postcheck"
}

check_upgrade_log() {
    local matches
    [[ -f "$LOG_ERROR" ]] || {
        warn "error log not found: $LOG_ERROR"
        return 0
    }
    matches="$(tail -500 "$LOG_ERROR" | grep -Ei 'upgrade|error|fail|corrupt|crash' || true)"
    if [[ -n "$matches" ]]; then
        printf '%s\n' "$matches" | tee "$WORK_DIR/postcheck_log_matches.txt"
        warn "review upgrade/error keywords in $WORK_DIR/postcheck_log_matches.txt"
    else
        log "no upgrade/error keywords found in the last 500 error-log lines"
    fi
}

do_postcheck() {
    require_root
    load_state
    require_commands rpm systemctl mysql mysqlcheck
    systemctl is-active --quiet "$MYSQL_SERVICE" || die "MySQL service is not active"
    validate_sql_access
    local runtime_version rpm_version
    runtime_version="$(mysql_query_value 'SELECT VERSION();')"
    runtime_version="${runtime_version%%-*}"
    rpm_version="$(rpm -q --qf '%{VERSION}\n' mysql-community-server)"
    [[ "$runtime_version" == "$TARGET_VERSION" ]] || die "runtime version mismatch: expected=$TARGET_VERSION actual=$runtime_version"
    [[ "$rpm_version" == "$TARGET_VERSION" ]] || die "RPM version mismatch: expected=$TARGET_VERSION actual=$rpm_version"

    mysql --defaults-extra-file="$MYSQL_LOGIN_FILE" -e 'SELECT VERSION(); SHOW DATABASES;'
    mysqlcheck --defaults-extra-file="$MYSQL_LOGIN_FILE" --all-databases --check
    collect_metadata "$WORK_DIR/postcheck_$RUN_ID"
    check_upgrade_log
    log "postcheck completed: $CURRENT_VERSION -> $TARGET_VERSION"
}

restore_old_packages() {
    local old_version old_bundle_version
    local old_rpms=()
    [[ -n "$OLD_BUNDLE_TAR" ]] || die "OLD_BUNDLE_TAR is required for rollback"
    [[ -f "$OLD_BUNDLE_TAR" ]] || die "old bundle not found: $OLD_BUNDLE_TAR"
    old_version="$(cat "$BACKUP_DIR/source_version.txt")"
    old_bundle_version="$(bundle_version_from_name "$OLD_BUNDLE_TAR" || true)"
    [[ "$old_bundle_version" == "$old_version" ]] || die "old bundle version mismatch: backup=$old_version bundle=$old_bundle_version"
    OLD_EXTRACT_DIR="${OLD_EXTRACT_DIR:-$WORK_DIR/mysql-$old_version}"
    validate_bundle_contents "$OLD_BUNDLE_TAR" "$old_version"
    extract_bundle "$OLD_BUNDLE_TAR" "$OLD_EXTRACT_DIR"
    mapfile -t old_rpms < <(build_target_rpm_list "$OLD_EXTRACT_DIR" "$old_version")
    [[ ${#old_rpms[@]} -ge 6 ]] || die "old RPM list is incomplete"
    run yum downgrade -y "${old_rpms[@]}"
}

restore_datadir() {
    local failed_dir
    [[ -d "$BACKUP_DIR/datadir" ]] || die "backup datadir not found: $BACKUP_DIR/datadir"
    failed_dir="${DATADIR}.failed_${TARGET_VERSION}_$(date '+%Y%m%d_%H%M%S')"
    [[ ! -e "$failed_dir" ]] || die "failed datadir quarantine already exists: $failed_dir"
    run mv "$DATADIR" "$failed_dir"
    run cp -a --reflink=auto "$BACKUP_DIR/datadir" "$DATADIR"
    run cp -a "$BACKUP_DIR/my.cnf" "$MYSQL_CNF"
    if command -v restorecon >/dev/null 2>&1; then
        run restorecon -RF "$DATADIR" "$MYSQL_CNF"
    fi
    log "upgraded datadir preserved for analysis: $failed_dir"
}

do_rollback() {
    require_root
    load_state
    require_commands yum rpm systemctl cp mv
    [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || die "valid backup directory not found in state"
    [[ "$SKIP_PHYSICAL_BACKUP" == "false" ]] || die "rollback is unavailable because physical backup was skipped"
    confirm "ROLLBACK TO $CURRENT_VERSION" "MySQL will be stopped, target packages downgraded and the offline backup restored."
    run systemctl stop "$MYSQL_SERVICE"
    restore_datadir
    restore_old_packages
    start_and_wait
    if [[ "$DRY_RUN" == "false" ]]; then
        local restored_version
        restored_version="$(rpm -q --qf '%{VERSION}\n' mysql-community-server)"
        [[ "$restored_version" == "$CURRENT_VERSION" ]] || die "rollback RPM version mismatch: expected=$CURRENT_VERSION actual=$restored_version"
    fi
    log "rollback completed; validate SQL and application behavior"
}

do_status() {
    if [[ -f "$STATE_FILE" ]]; then
        load_state
        printf 'Script version : %s\n' "$SCRIPT_VERSION"
        printf 'Current version: %s\n' "$CURRENT_VERSION"
        printf 'Target version : %s\n' "$TARGET_VERSION"
        printf 'Bundle         : %s\n' "$BUNDLE_TAR"
        printf 'Datadir        : %s\n' "$DATADIR"
        printf 'Backup         : %s\n' "${BACKUP_DIR:-not created}"
        printf 'State file     : %s\n' "$STATE_FILE"
    else
        printf 'State file not found: %s\n' "$STATE_FILE"
    fi
    rpm -q mysql-community-server 2>/dev/null || true
    systemctl is-active "$MYSQL_SERVICE" 2>/dev/null || true
}

main() {
    parse_args "$@"
    [[ "$STEP" != "help" ]] || { usage; return 0; }
    init_paths
    init_log
    log "mysql_inplace_upgrade.sh v$SCRIPT_VERSION step=$STEP"
    case "$STEP" in
        precheck) do_precheck ;;
        prepare) do_prepare ;;
        upgrade) do_upgrade ;;
        postcheck) do_postcheck ;;
        rollback) do_rollback ;;
        status) do_status ;;
        *) die "unknown step: $STEP" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
