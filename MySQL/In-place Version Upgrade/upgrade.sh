#!/bin/sh
# MySQL RPM Package-based In-place Upgrade Automation
# POSIX /bin/sh compatible
# Scope: Oracle MySQL Community RPM installations on EL8/EL9-family systems

set -u

SCRIPT_VERSION="1.0.18"
SERVICE_NAME="${SERVICE_NAME:-}"
CONFIG_FILE=""
WORK_ROOT=""
DB_USER=""
DB_HOST=""
DB_PORT=""
DB_SOCKET=""
CONNECTION_MODE="socket"
BACKUP_MODE="1"
PACKAGE_SOURCE=""
PACKAGE_PATH=""
TARGET_VERSION=""
CURRENT_VERSION=""
BEFORE_BASEDIR=""
BEFORE_DATADIR=""
BEFORE_PORT=""
BEFORE_SOCKET=""
BEFORE_SERVER_ID=""
DATADIR=""
LOG_ERROR=""
OS_SERVICE_USER=""
OS_SERVICE_GROUP=""
GPG_CHECK="no"
TMP_DIR=""
MYSQL_CNF=""
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE=""
BACKUP_DIR=""
CONFIG_BACKUP_DIR=""
CONFIG_PRIMARY_BACKUP=""
VALIDATION_DIR=""
SMOKE_SQL_FILE=""
BEFORE_ERROR_LOG_LINES="0"
EXTENDED_FAILED="0"
EXTENDED_REVIEW="0"
RPM_LIST_FILE=""

line() { printf '%s\n' '=============================================================================='; }
info() { printf '[INFO] %s\n' "$*"; [ -n "$LOG_FILE" ] && printf '[INFO] %s\n' "$*" >> "$LOG_FILE"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; [ -n "$LOG_FILE" ] && printf '[WARNING] %s\n' "$*" >> "$LOG_FILE"; }
die() { printf '[ERROR] %s\n' "$*" >&2; [ -n "$LOG_FILE" ] && printf '[ERROR] %s\n' "$*" >> "$LOG_FILE"; exit 1; }

cleanup() {
    if [ -t 0 ]; then
        stty echo 2>/dev/null || true
    fi
    [ -n "$MYSQL_CNF" ] && [ -f "$MYSQL_CNF" ] && rm -f "$MYSQL_CNF"
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

prompt_default() {
    _label=$1
    _default=$2
    printf '%s [%s]: ' "$_label" "$_default" >&2
    IFS= read -r _answer || exit 1
    [ -n "$_answer" ] || _answer=$_default
    printf '%s' "$_answer"
}

prompt_secret() {
    _label=$1
    printf '%s: ' "$_label" >&2
    if [ -t 0 ]; then stty -echo; fi
    IFS= read -r _secret || { if [ -t 0 ]; then stty echo; fi; exit 1; }
    if [ -t 0 ]; then stty echo; fi
    printf '\n' >&2
    printf '%s' "$_secret"
}

confirm() {
    printf '%s [y/N]: ' "$1"
    IFS= read -r _answer || exit 1
    case $_answer in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "root 계정 필요. sudo가 없으면 su - 후 재실행"
}

require_commands() {
    for _cmd in mysql mysqld mysqldump mysqlcheck my_print_defaults rpm yum tar sha256sum systemctl awk sed grep find stat df du cmp diff pgrep mktemp tee tr sort sleep cp chmod chown readlink ps wc tail basename mv; do
        command -v "$_cmd" >/dev/null 2>&1 || die "필수 명령 없음: $_cmd"
    done
}

create_login_file() {
    _password=$(prompt_secret "MySQL DB 계정 비밀번호")
    MYSQL_CNF=$(mktemp /tmp/mysql-upgrade-client.XXXXXX) || die "임시 접속 설정 생성 실패"
    chmod 600 "$MYSQL_CNF"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$DB_USER"
        printf 'password=%s\n' "$_password"
        if [ "$CONNECTION_MODE" = "socket" ]; then
            printf 'socket=%s\n' "$DB_SOCKET"
        else
            printf 'host=%s\nport=%s\nprotocol=tcp\n' "$DB_HOST" "$DB_PORT"
        fi
    } > "$MYSQL_CNF"
    unset _password
}

mysql_cmd() { mysql --defaults-extra-file="$MYSQL_CNF" "$@"; }
mysqldump_cmd() { mysqldump --defaults-extra-file="$MYSQL_CNF" "$@"; }
mysqlcheck_cmd() { mysqlcheck --defaults-extra-file="$MYSQL_CNF" "$@"; }
my_print_defaults_cmd() { my_print_defaults --defaults-file="$CONFIG_FILE" mysqld; }

mysqld_effective_value() {
    _effective_name=$1
    mysqld --defaults-file="$CONFIG_FILE" --verbose --help 2>/dev/null |
        awk -v option="$_effective_name" '
            $1 == option {
                $1=""
                sub(/^[[:space:]]+/, "")
                value=$0
            }
            END { print value }
        '
}

select_service_name() {
    if [ -n "$SERVICE_NAME" ]; then
        systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || die "systemd service unit 없음: $SERVICE_NAME"
        info "systemd service 지정값 사용: $SERVICE_NAME"
        return 0
    fi

    _service_candidates=$(mktemp /tmp/mysql-service-candidates.XXXXXX) || die "서비스 후보 임시 파일 생성 실패"
    _service_details=$(mktemp /tmp/mysql-service-details.XXXXXX) || {
        rm -f "$_service_candidates"
        die "서비스 상세 임시 파일 생성 실패"
    }

    systemctl list-units --type=service --state=running --no-legend 2>/dev/null |
        awk '{print $1}' |
        while IFS= read -r _unit_name; do
            [ -n "$_unit_name" ] || continue
            _unit_pid=$(systemctl show "$_unit_name" --property=MainPID --value 2>/dev/null || true)
            case $_unit_pid in ''|0|*[!0-9]*) continue ;; esac
            _unit_exe=$(readlink -f "/proc/$_unit_pid/exe" 2>/dev/null || true)
            [ -n "$_unit_exe" ] || continue
            case $(basename "$_unit_exe") in
                mysqld|mysqld-debug)
                    _unit_service=${_unit_name%.service}
                    _unit_version=$("$_unit_exe" --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="Ver"){print $(i+1); exit}}')
                    printf '%s\n' "$_unit_service" >> "$_service_candidates"
                    printf '%s\t%s\t%s\t%s\n' "$_unit_service" "$_unit_pid" "$_unit_exe" "${_unit_version:-unknown}" >> "$_service_details"
                    ;;
            esac
        done

    awk '!seen[$0]++' "$_service_candidates" > "${_service_candidates}.unique"
    mv "${_service_candidates}.unique" "$_service_candidates"
    _service_count=$(wc -l < "$_service_candidates" | tr -d ' ')

    if [ "$_service_count" -eq 0 ]; then
        rm -f "$_service_candidates" "$_service_details"
        SERVICE_NAME=$(prompt_default "실행 중인 MySQL Service 자동 감지 실패. systemd service 이름" "")
        [ -n "$SERVICE_NAME" ] || die "systemd service 이름 입력 필요"
        systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || die "systemd service unit 없음: $SERVICE_NAME"
        return 0
    fi

    if [ "$_service_count" -eq 1 ]; then
        SERVICE_NAME=$(sed -n '1p' "$_service_candidates")
        info "실행 중인 MySQL 인스턴스 자동 감지: $SERVICE_NAME"
        rm -f "$_service_candidates" "$_service_details"
        return 0
    fi

    printf '%s\n' '' '실행 중인 MySQL 인스턴스:' >&2
    awk -F '\t' '{printf "  %d) Service=%s, PID=%s, Binary=%s, Version=%s\n", NR, $1, $2, $3, $4}' "$_service_details" >&2
    printf '업그레이드 대상 인스턴스 선택 번호: ' >&2
    IFS= read -r _service_choice || {
        rm -f "$_service_candidates" "$_service_details"
        exit 1
    }
    case $_service_choice in
        ''|*[!0-9]*)
            rm -f "$_service_candidates" "$_service_details"
            die "올바른 인스턴스 선택 번호 필요"
            ;;
    esac
    SERVICE_NAME=$(sed -n "${_service_choice}p" "$_service_candidates")
    rm -f "$_service_candidates" "$_service_details"

    [ -n "$SERVICE_NAME" ] || die "선택 범위를 벗어난 번호: $_service_choice"
    systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || die "systemd service unit 없음: $SERVICE_NAME"
    info "업그레이드 대상 MySQL 인스턴스 선택: $SERVICE_NAME"
}

select_config_file() {
    _config_all=$(mktemp /tmp/mysql-config-all.XXXXXX) || die "설정 파일 후보 임시 파일 생성 실패"
    _config_candidates=$(mktemp /tmp/mysql-config-candidates.XXXXXX) || {
        rm -f "$_config_all"
        die "설정 파일 후보 임시 파일 생성 실패"
    }

    {
        _mysqld_pid=$(systemctl show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null || true)
        if [ -n "$_mysqld_pid" ] && [ "$_mysqld_pid" != "0" ]; then
            ps -ww -p "$_mysqld_pid" -o args= 2>/dev/null |
                tr ' ' '\n' |
                sed -n -e 's/^--defaults-file=//p' -e 's/^--defaults-extra-file=//p'
        fi

        systemctl cat "$SERVICE_NAME" 2>/dev/null |
            tr ' ' '\n' |
            sed -n -e 's/^--defaults-file=//p' -e 's/^--defaults-extra-file=//p'

        mysqld --verbose --help 2>/dev/null |
            awk '
                /Default options are read from the following files in the given order:/ {
                    getline
                    for (i=1; i<=NF; i++) print $i
                    exit
                }
            '

        find /etc -maxdepth 3 -type f \( -name 'my.cnf' -o -name 'my.cnf.*' \) -print 2>/dev/null
    } | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++' > "$_config_all"

    while IFS= read -r _config_path; do
        [ -f "$_config_path" ] && printf '%s\n' "$_config_path"
    done < "$_config_all" > "$_config_candidates"
    rm -f "$_config_all"

    _config_count=$(wc -l < "$_config_candidates" | tr -d ' ')
    if [ "$_config_count" -eq 0 ]; then
        rm -f "$_config_candidates"
        CONFIG_FILE=$(prompt_default "MySQL option file 절대 경로" "")
        [ -f "$CONFIG_FILE" ] || die "MySQL option file 없음: $CONFIG_FILE"
        return 0
    fi

    if [ "$_config_count" -eq 1 ]; then
        CONFIG_FILE=$(sed -n '1p' "$_config_candidates")
        rm -f "$_config_candidates"
        info "MySQL option file 자동 감지: $CONFIG_FILE"
        return 0
    fi

    printf '%s\n' '' '발견된 MySQL option file:' >&2
    awk '{printf "  %d) %s\n", NR, $0}' "$_config_candidates" >&2
    printf '선택 번호 또는 option file 절대 경로 [1]: ' >&2
    IFS= read -r _config_choice || {
        rm -f "$_config_candidates"
        exit 1
    }
    _config_choice=${_config_choice:-1}

    case $_config_choice in
        *[!0-9]*)
            CONFIG_FILE=$_config_choice
            ;;
        *)
            CONFIG_FILE=$(sed -n "${_config_choice}p" "$_config_candidates")
            ;;
    esac
    rm -f "$_config_candidates"

    [ -n "$CONFIG_FILE" ] || die "선택 범위를 벗어난 번호: $_config_choice"
    [ -f "$CONFIG_FILE" ] || die "MySQL option file 없음: $CONFIG_FILE"
    info "MySQL option file 선택: $CONFIG_FILE"
}

configure_connection() {
    _socket_detected=$(my_print_defaults_cmd 2>/dev/null | sed -n 's/^--socket=//p' | tail -n 1)
    [ -n "$_socket_detected" ] || _socket_detected=$(mysqld_effective_value socket)

    if [ -n "$_socket_detected" ] && [ -S "$_socket_detected" ]; then
        CONNECTION_MODE="socket"
        DB_SOCKET=$_socket_detected
        info "실행 중인 MySQL Unix Socket 자동 감지: $DB_SOCKET"
        return 0
    fi

    warn "실행 중인 MySQL Unix Socket을 자동 확인하지 못함"
    CONNECTION_MODE="tcp"
    _port_detected=$(my_print_defaults_cmd 2>/dev/null | sed -n 's/^--port=//p' | tail -n 1)
    [ -n "$_port_detected" ] || _port_detected=$(mysqld_effective_value port)
    DB_HOST=$(prompt_default "TCP Host" "")
    [ -n "$DB_HOST" ] || die "TCP Host 입력 필요"
    DB_PORT=$(prompt_default "TCP Port" "$_port_detected")
    [ -n "$DB_PORT" ] || die "TCP Port 입력 필요"
    case $DB_PORT in *[!0-9]*) die "TCP Port는 숫자만 입력 가능: $DB_PORT" ;; esac
}

collect_inputs() {
    line
    printf 'MySQL RPM Package-based In-place Upgrade Automation v%s\n' "$SCRIPT_VERSION"
    line
    select_service_name
    select_config_file
    configure_connection
    DB_USER=$(prompt_default "MySQL 접속용 DB 관리자 계정 (OS 계정 아님)" "")
    [ -n "$DB_USER" ] || die "MySQL DB 관리자 계정 입력 필요"
    create_login_file
    mysql_cmd -NBe "SELECT 1" >/dev/null 2>&1 || die "MySQL 접속 실패"
    CURRENT_VERSION=$(mysql_cmd -NBe "SELECT VERSION()") || die "현재 버전 조회 실패"
    BEFORE_BASEDIR=$(mysql_cmd -NBe "SELECT @@basedir") || die "basedir 조회 실패"
    BEFORE_DATADIR=$(mysql_cmd -NBe "SELECT @@datadir") || die "datadir 조회 실패"
    BEFORE_PORT=$(mysql_cmd -NBe "SELECT @@port") || die "port 조회 실패"
    BEFORE_SOCKET=$(mysql_cmd -NBe "SELECT @@socket") || die "socket 조회 실패"
    BEFORE_SERVER_ID=$(mysql_cmd -NBe "SELECT @@server_id") || die "server_id 조회 실패"
    DATADIR=$BEFORE_DATADIR
    DB_PORT=$BEFORE_PORT
    DB_SOCKET=$BEFORE_SOCKET
    LOG_ERROR=$(mysql_cmd -NBe "SELECT @@log_error") || die "log_error 조회 실패"
    info "실행 중인 MySQL Runtime 값 확인: socket=$DB_SOCKET, port=$DB_PORT, datadir=$DATADIR"
    OS_SERVICE_USER=$(stat -c '%U' "$DATADIR") || die "datadir 소유자 조회 실패"
    OS_SERVICE_GROUP=$(stat -c '%G' "$DATADIR") || die "datadir 그룹 조회 실패"
    printf '%s\n' '' '업그레이드 결과 및 백업 저장 경로' '  - Upgrade Checker, 로그, 사전/사후 상태, Logical/Physical Backup 저장' '  - RPM Bundle 또는 RPM 파일 경로는 다음 Package Source 단계에서 별도 입력' >&2
    WORK_ROOT=$(prompt_default "결과 및 백업 저장 상위 경로" "$(dirname "$DATADIR")/mysql_upgrade")
    _data_real=$(readlink -f "$DATADIR") || die "datadir 실제 경로 확인 실패"
    _work_real=$(readlink -m "$WORK_ROOT") || die "작업 경로 확인 실패"
    case "$_work_real/" in "$_data_real"/*) die "작업 경로를 datadir 내부에 지정할 수 없음" ;; esac
    mkdir -p "$WORK_ROOT" || die "작업 경로 생성 실패: $WORK_ROOT"
    SMOKE_SQL_FILE=$(prompt_default "Application Smoke Test SQL 파일 절대 경로 (미사용 시 Enter)" "")
    [ -z "$SMOKE_SQL_FILE" ] || [ -f "$SMOKE_SQL_FILE" ] || die "Application Smoke Test SQL 파일 없음: $SMOKE_SQL_FILE"
}

select_package_source() {
    line
    printf '%s\n' 'MySQL Package Source Selection' 'MySQL 패키지 소스 선택' ''
    printf '%s\n' '1) MySQL Yum Repository' '   - 공식 또는 내부 Yum Repository에서 RPM 조회 및 업그레이드' ''
    printf '%s\n' '2) RPM Bundle' '   - *.rpm-bundle.tar 압축 해제 후 현재 설치 구성과 일치하는 RPM 선별' ''
    printf '%s\n' '3) Local RPM Directory' '   - 로컬 디렉터리의 개별 RPM 검증 및 선별' ''
    printf '선택 [2]: '
    IFS= read -r PACKAGE_SOURCE
    PACKAGE_SOURCE=${PACKAGE_SOURCE:-2}
    case $PACKAGE_SOURCE in
        1)
            TARGET_VERSION=$(prompt_default "목표 MySQL 버전" "")
            [ -n "$TARGET_VERSION" ] || die "목표 MySQL 버전 입력 필요"
            ;;
        2)
            PACKAGE_PATH=$(prompt_default "RPM Bundle 파일 또는 Bundle 보관 디렉터리 절대 경로" "")
            select_bundle_file "$PACKAGE_PATH"
            ;;
        3)
            PACKAGE_PATH=$(prompt_default "Local RPM Directory 절대 경로" "")
            [ -d "$PACKAGE_PATH" ] || die "RPM 디렉터리 없음: $PACKAGE_PATH"
            case $PACKAGE_PATH in *' '*) die "Local RPM Directory 경로에 공백 사용 불가" ;; esac
            ;;
        *) die "지원하지 않는 Package Source" ;;
    esac
}

select_bundle_file() {
    _bundle_input=$1
    if [ -f "$_bundle_input" ]; then
        case $_bundle_input in
            *.rpm-bundle.tar|*bundle.tar) PACKAGE_PATH=$_bundle_input ;;
            *) die "RPM Bundle TAR 형식 아님: $_bundle_input" ;;
        esac
        return 0
    fi
    [ -d "$_bundle_input" ] || die "RPM Bundle 파일 또는 디렉터리 없음: $_bundle_input"

    _bundle_list=$(mktemp /tmp/mysql-bundle-list.XXXXXX) || die "Bundle 목록 임시 파일 생성 실패"
    find "$_bundle_input" -maxdepth 1 -type f \( -name 'mysql-*.rpm-bundle.tar' -o -name 'mysql-*-bundle.tar' \) -print | sort -V > "$_bundle_list"
    _bundle_count=$(wc -l < "$_bundle_list" | tr -d ' ')
    if [ "$_bundle_count" -eq 0 ]; then
        rm -f "$_bundle_list"
        die "디렉터리에 MySQL RPM Bundle 없음: $_bundle_input"
    fi
    if [ "$_bundle_count" -eq 1 ]; then
        PACKAGE_PATH=$(sed -n '1p' "$_bundle_list")
        rm -f "$_bundle_list"
        info "RPM Bundle 자동 선택: $PACKAGE_PATH"
        return 0
    fi

    printf '%s\n' '' '발견된 MySQL RPM Bundle:'
    awk '{printf "  %d) %s\n", NR, $0}' "$_bundle_list"
    printf '선택 번호: '
    IFS= read -r _bundle_no
    case $_bundle_no in *[!0-9]*|'') rm -f "$_bundle_list"; die "올바른 선택 번호 필요" ;; esac
    PACKAGE_PATH=$(sed -n "${_bundle_no}p" "$_bundle_list")
    rm -f "$_bundle_list"
    [ -n "$PACKAGE_PATH" ] || die "선택 범위를 벗어난 번호: $_bundle_no"
}

prepare_local_rpms() {
    TMP_DIR=$(mktemp -d /tmp/mysql-rpm-upgrade.XXXXXX) || die "임시 디렉터리 생성 실패"
    if [ "$PACKAGE_SOURCE" = "2" ]; then
        tar -tf "$PACKAGE_PATH" >/dev/null 2>&1 || die "RPM Bundle TAR 무결성 검사 실패"
        tar -xf "$PACKAGE_PATH" -C "$TMP_DIR" || die "RPM Bundle 압축 해제 실패"
        _rpm_dir=$TMP_DIR
    else
        _rpm_dir=$PACKAGE_PATH
    fi

    RPM_LIST_FILE="$WORK_ROOT/rpm_list_${RUN_ID}.txt"
    : > "$RPM_LIST_FILE"
    _versions=""
    for _rpm in "$_rpm_dir"/*.rpm; do
        [ -f "$_rpm" ] || continue
        _name=$(rpm -qp --qf '%{NAME}' "$_rpm" 2>/dev/null) || continue
        _version=$(rpm -qp --qf '%{VERSION}' "$_rpm" 2>/dev/null) || continue
        case $_name in mysql-community-*) ;; *) continue ;; esac
        if rpm -q "$_name" >/dev/null 2>&1; then
            printf '%s\n' "$_rpm" >> "$RPM_LIST_FILE"
            _versions="$_versions $_version"
        fi
    done
    [ -s "$RPM_LIST_FILE" ] || die "현재 설치된 MySQL 구성과 대응하는 목표 RPM 없음"
    TARGET_VERSION=$(printf '%s\n' $_versions | awk 'NF{print}' | sort -u | awk 'NR==1{v=$0} NR>1{bad=1} END{if(!bad)print v}')
    [ -n "$TARGET_VERSION" ] || die "서로 다른 목표 버전 RPM 혼재"
}

version_guard() {
    [ "$CURRENT_VERSION" != "$TARGET_VERSION" ] || die "현재 버전과 목표 버전 동일: $CURRENT_VERSION"
    _lowest=$(printf '%s\n%s\n' "$CURRENT_VERSION" "$TARGET_VERSION" | sort -V | sed -n '1p')
    [ "$_lowest" = "$CURRENT_VERSION" ] || die "다운그레이드 또는 잘못된 버전 순서: $CURRENT_VERSION -> $TARGET_VERSION"
}

backup_option_files() {
    CONFIG_BACKUP_DIR="$WORK_ROOT/config_backup_${CURRENT_VERSION}_${RUN_ID}"
    _config_list=$(mktemp /tmp/mysql-config-backup-list.XXXXXX) || die "Config 백업 목록 생성 실패"
    _config_next=$(mktemp /tmp/mysql-config-backup-next.XXXXXX) || { rm -f "$_config_list"; die "Config 백업 목록 생성 실패"; }
    printf '%s\n' "$CONFIG_FILE" > "$_config_list"

    _config_pass=0
    while [ "$_config_pass" -lt 20 ]; do
        _config_pass=$((_config_pass + 1))
        cp "$_config_list" "$_config_next" || die "Config 백업 목록 처리 실패"
        while IFS= read -r _config_source; do
            [ -f "$_config_source" ] || continue
            _config_base=$(dirname "$_config_source")

            sed -n 's/^[[:space:]]*!include[[:space:]][[:space:]]*//p' "$_config_source" |
                while IFS= read -r _include_file; do
                    [ -n "$_include_file" ] || continue
                    case $_include_file in /*) ;; *) _include_file="$_config_base/$_include_file" ;; esac
                    [ -f "$_include_file" ] && readlink -f "$_include_file" >> "$_config_next"
                done

            sed -n 's/^[[:space:]]*!includedir[[:space:]][[:space:]]*//p' "$_config_source" |
                while IFS= read -r _include_dir; do
                    [ -n "$_include_dir" ] || continue
                    case $_include_dir in /*) ;; *) _include_dir="$_config_base/$_include_dir" ;; esac
                    [ -d "$_include_dir" ] || continue
                    find "$_include_dir" -maxdepth 1 -type f -name '*.cnf' -print
                done >> "$_config_next"
        done < "$_config_list"

        sort -u "$_config_next" -o "$_config_next"
        if cmp -s "$_config_list" "$_config_next"; then
            break
        fi
        cp "$_config_next" "$_config_list" || die "Config 백업 목록 갱신 실패"
    done
    [ "$_config_pass" -lt 20 ] || { rm -f "$_config_list" "$_config_next"; die "Config include 탐색이 20회를 초과함"; }

    mkdir -p "$CONFIG_BACKUP_DIR/files" || { rm -f "$_config_list" "$_config_next"; die "Config 백업 디렉터리 생성 실패: $CONFIG_BACKUP_DIR"; }
    chmod 700 "$CONFIG_BACKUP_DIR"
    : > "$CONFIG_BACKUP_DIR/option_files.manifest"
    : > "$CONFIG_BACKUP_DIR/option_files.sha256"

    while IFS= read -r _config_source; do
        [ -f "$_config_source" ] || { rm -f "$_config_list" "$_config_next"; die "Config 파일 없음: $_config_source"; }
        _config_real=$(readlink -f "$_config_source") || { rm -f "$_config_list" "$_config_next"; die "Config 실제 경로 확인 실패: $_config_source"; }
        _config_relative=${_config_real#/}
        _config_dest="$CONFIG_BACKUP_DIR/files/$_config_relative"
        mkdir -p "$(dirname "$_config_dest")" || { rm -f "$_config_list" "$_config_next"; die "Config 백업 하위 디렉터리 생성 실패"; }
        cp -a "$_config_real" "$_config_dest" || { rm -f "$_config_list" "$_config_next"; die "Config 백업 실패: $_config_real"; }
        printf '%s\t%s\n' "$_config_real" "files/$_config_relative" >> "$CONFIG_BACKUP_DIR/option_files.manifest"
        (cd "$CONFIG_BACKUP_DIR" && sha256sum "files/$_config_relative") >> "$CONFIG_BACKUP_DIR/option_files.sha256" || { rm -f "$_config_list" "$_config_next"; die "Config SHA-256 생성 실패"; }
        if [ "$_config_real" = "$(readlink -f "$CONFIG_FILE")" ]; then
            CONFIG_PRIMARY_BACKUP=$_config_dest
        fi
    done < "$_config_list"

    rm -f "$_config_list" "$_config_next"
    [ -n "$CONFIG_PRIMARY_BACKUP" ] && [ -f "$CONFIG_PRIMARY_BACKUP" ] || die "선택한 option file 백업 확인 실패"
    (cd "$CONFIG_BACKUP_DIR" && sha256sum -c option_files.sha256) >/dev/null 2>&1 || die "Config 백업 SHA-256 검증 실패"
    info "MySQL Config 백업 완료: $CONFIG_BACKUP_DIR"
}

setup_run_paths() {
    BACKUP_DIR="$WORK_ROOT/${CURRENT_VERSION}_to_${TARGET_VERSION}_${RUN_ID}"
    mkdir -p "$BACKUP_DIR" || die "백업 디렉터리 생성 실패"
    LOG_FILE="$BACKUP_DIR/upgrade.log"
    VALIDATION_DIR="$BACKUP_DIR/validation"
    chmod 700 "$BACKUP_DIR"
    mkdir -p "$VALIDATION_DIR" || die "검증 디렉터리 생성 실패"
    chmod 700 "$VALIDATION_DIR"
    backup_option_files
}

show_summary() {
    line
    printf 'Current Version   : %s\n' "$CURRENT_VERSION"
    printf 'Target Version    : %s\n' "$TARGET_VERSION"
    printf 'Option File       : %s\n' "$CONFIG_FILE"
    printf 'Data Directory    : %s\n' "$DATADIR"
    printf 'Service           : %s\n' "$SERVICE_NAME"
    printf 'OS Service Account: %s:%s\n' "$OS_SERVICE_USER" "$OS_SERVICE_GROUP"
    printf 'DB Account        : %s\n' "$DB_USER"
    printf 'Backup Directory  : %s\n' "$BACKUP_DIR"
    printf 'Config Backup Dir : %s\n' "$CONFIG_BACKUP_DIR"
    printf 'Validation Dir    : %s\n' "$VALIDATION_DIR"
    [ -n "$SMOKE_SQL_FILE" ] && printf 'Smoke Test SQL   : %s\n' "$SMOKE_SQL_FILE"
    [ "$PACKAGE_SOURCE" = "1" ] || printf 'Package Source    : %s\n' "$PACKAGE_PATH"
    line
    confirm "이 구성으로 사전 검사를 시작할까요?" || die "사용자 취소"
}

run_upgrade_checker() {
    command -v mysqlsh >/dev/null 2>&1 || die "mysqlsh 없음. Upgrade Checker Utility 필요"
    _checker="$BACKUP_DIR/upgrade_check_${CURRENT_VERSION}_to_${TARGET_VERSION}.txt"
    info "Upgrade Checker Utility 실행"
    if [ "$CONNECTION_MODE" = "socket" ]; then
        mysqlsh --socket="$DB_SOCKET" --user="$DB_USER" -- util check-for-server-upgrade --target-version="$TARGET_VERSION" --config-path="$CONFIG_FILE" > "$_checker" 2>&1
        _checker_status=$?
    else
        mysqlsh --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" -- util check-for-server-upgrade --target-version="$TARGET_VERSION" --config-path="$CONFIG_FILE" > "$_checker" 2>&1
        _checker_status=$?
    fi
    [ -s "$_checker" ] || die "Upgrade Checker 결과 파일 생성 실패"

    _errors=$(sed -n 's/^Errors:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_checker" | tail -n 1)
    _warnings=$(sed -n 's/^Warnings:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_checker" | tail -n 1)
    _notices=$(sed -n 's/^Notices:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_checker" | tail -n 1)
    _errors=${_errors:-unknown}
    _warnings=${_warnings:-unknown}
    _notices=${_notices:-unknown}

    if [ "$_checker_status" -ne 0 ] || [ "$_errors" != "0" ]; then
        printf '%s\n' '' '===== Upgrade Checker 전체 결과(Error 포함) ====='
        sed -n '1,2000p' "$_checker"
        printf '%s\n' "Upgrade Checker 원문: $_checker"
        die "Upgrade Checker 실행 실패 또는 호환성 Error 존재 (Errors: $_errors)"
    fi

    printf '%s\n' '' '===== Upgrade Checker 전체 결과 ====='
    sed -n '1,2000p' "$_checker"
    printf '\nErrors: %s, Warnings: %s, Notices: %s\n' "$_errors" "$_warnings" "$_notices"
    printf 'Upgrade Checker 원문: %s\n' "$_checker"
    confirm "Upgrade Checker Warning/Notice 검토 완료 후 계속 진행할까요?" || die "사용자 중단"
}

snapshot_validation_state() {
    _phase=$1; _version=$2; _suffix="${_version}.${_phase}"
    mysql_cmd -NBe "SHOW GLOBAL VARIABLES" | sort > "$VALIDATION_DIR/global_variables_${_suffix}.txt" || die "Global Variables 저장 실패"
    mysql_cmd -NBe "SELECT VERSION(),@@version_comment,@@basedir,@@datadir,@@port,@@socket,@@server_id,@@hostname,@@lower_case_table_names,@@character_set_server,@@collation_server,@@sql_mode,@@time_zone,@@max_connections" > "$VALIDATION_DIR/server_identity_${_suffix}.txt" || die "Server Identity 저장 실패"
    mysql_cmd -NBe "SELECT TABLE_SCHEMA,TABLE_TYPE,COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') GROUP BY TABLE_SCHEMA,TABLE_TYPE UNION ALL SELECT TRIGGER_SCHEMA,'TRIGGER',COUNT(*) FROM INFORMATION_SCHEMA.TRIGGERS GROUP BY TRIGGER_SCHEMA UNION ALL SELECT ROUTINE_SCHEMA,ROUTINE_TYPE,COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES GROUP BY ROUTINE_SCHEMA UNION ALL SELECT EVENT_SCHEMA,'EVENT',COUNT(*) FROM INFORMATION_SCHEMA.EVENTS GROUP BY EVENT_SCHEMA ORDER BY 1,2" > "$VALIDATION_DIR/user_objects_${_suffix}.txt" || die "사용자 객체 저장 실패"
    mysql_cmd -NBe "SELECT TABLE_SCHEMA,COUNT(*),COALESCE(SUM(TABLE_ROWS),0),COALESCE(SUM(DATA_LENGTH),0),COALESCE(SUM(INDEX_LENGTH),0) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema') GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA" > "$VALIDATION_DIR/schema_metrics_${_suffix}.txt" || die "Schema 지표 저장 실패"
    mysql_cmd -NBe "SELECT user,host,plugin,account_locked FROM mysql.user ORDER BY user,host" > "$VALIDATION_DIR/accounts_${_suffix}.txt" || die "계정 저장 실패"
    mysql_cmd -NBe "SELECT PLUGIN_NAME,PLUGIN_VERSION,PLUGIN_STATUS,PLUGIN_TYPE,COALESCE(PLUGIN_LIBRARY,'BUILT-IN') FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' ORDER BY PLUGIN_TYPE,PLUGIN_NAME" > "$VALIDATION_DIR/plugins_${_suffix}.txt" || die "Plugin 저장 실패"
    rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' | grep '^mysql' | sort > "$VALIDATION_DIR/rpm_${_suffix}.txt" || true
    { systemctl is-active "$SERVICE_NAME" 2>/dev/null || true; systemctl show "$SERVICE_NAME" --property=MainPID,ExecMainStatus,SubState --no-pager 2>/dev/null || true; } > "$VALIDATION_DIR/service_${_suffix}.txt"
    { mysql_cmd -NBe "SELECT @@gtid_mode,@@enforce_gtid_consistency,@@global.gtid_executed,@@global.gtid_purged" 2>/dev/null || true; mysql_cmd -e "SHOW REPLICA STATUS\G" 2>/dev/null || true; } > "$VALIDATION_DIR/replication_${_suffix}.txt"
}

compare_validation_file() {
    _label=$1; _before=$2; _after=$3; _diff=$4
    if cmp -s "$_before" "$_after"; then printf '%-28s : PASSED\n' "$_label" >> "$VALIDATION_DIR/validation_summary.txt"; return 0; fi
    diff -u "$_before" "$_after" > "$_diff" 2>/dev/null || true
    printf '%-28s : REVIEW (%s)\n' "$_label" "$_diff" >> "$VALIDATION_DIR/validation_summary.txt"
    EXTENDED_REVIEW=1; return 1
}

validate_config_files_unchanged() {
    while IFS="$(printf '\t')" read -r _original _saved; do
        [ -f "$_original" ] || die "업그레이드 전 Config 원본 파일 없음: $_original"
        cmp -s "$_original" "$CONFIG_BACKUP_DIR/$_saved" || die "기존 Config 변경 감지: $_original"
    done < "$CONFIG_BACKUP_DIR/option_files.manifest"
}

validate_replication_state() {
    _before="$VALIDATION_DIR/replication_${CURRENT_VERSION}.before.txt"; _after="$VALIDATION_DIR/replication_${TARGET_VERSION}.after.txt"
    _bc=$(grep -c '^[[:space:]]*Source_Host:' "$_before" 2>/dev/null || true); _ac=$(grep -c '^[[:space:]]*Source_Host:' "$_after" 2>/dev/null || true)
    if [ "$_bc" -eq 0 ] && [ "$_ac" -eq 0 ]; then printf '%-28s : NOT APPLICABLE\n' "Replication" >> "$VALIDATION_DIR/validation_summary.txt"; return 0; fi
    _io=$(grep -c '^[[:space:]]*Replica_IO_Running: Yes' "$_after" 2>/dev/null || true); _sql=$(grep -c '^[[:space:]]*Replica_SQL_Running: Yes' "$_after" 2>/dev/null || true)
    if [ "$_bc" -eq "$_ac" ] && [ "$_io" -eq "$_ac" ] && [ "$_sql" -eq "$_ac" ]; then printf '%-28s : PASSED (%s channel)\n' "Replication" "$_ac" >> "$VALIDATION_DIR/validation_summary.txt"; return 0; fi
    printf '%-28s : FAILED (channel 또는 IO/SQL 상태)\n' "Replication" >> "$VALIDATION_DIR/validation_summary.txt"; EXTENDED_FAILED=1; return 1
}

validate_new_error_log() {
    _result="$VALIDATION_DIR/error_log_${TARGET_VERSION}.after.txt"; : > "$_result"
    if [ -n "$LOG_ERROR" ] && [ -f "$LOG_ERROR" ]; then _start=$((BEFORE_ERROR_LOG_LINES + 1)); tail -n "+$_start" "$LOG_ERROR" > "$_result" 2>/dev/null || true; fi
    if grep -Ei '\[ERROR\]|fatal|abort|upgrade[^[:alnum:]]+fail|fail[^[:alnum:]]+upgrade' "$_result" > "$VALIDATION_DIR/error_log_critical_${TARGET_VERSION}.txt" 2>/dev/null; then printf '%-28s : FAILED\n' "Error Log" >> "$VALIDATION_DIR/validation_summary.txt"; EXTENDED_FAILED=1; return 1; fi
    if grep -Ei 'warning|deprecated' "$_result" > "$VALIDATION_DIR/error_log_review_${TARGET_VERSION}.txt" 2>/dev/null; then printf '%-28s : REVIEW\n' "Error Log" >> "$VALIDATION_DIR/validation_summary.txt"; EXTENDED_REVIEW=1; return 0; fi
    printf '%-28s : PASSED\n' "Error Log" >> "$VALIDATION_DIR/validation_summary.txt"
}

run_smoke_test() {
    if [ -z "$SMOKE_SQL_FILE" ]; then printf '%-28s : NOT PROVIDED\n' "Application Smoke Test" >> "$VALIDATION_DIR/validation_summary.txt"; return 0; fi
    if mysql_cmd < "$SMOKE_SQL_FILE" > "$VALIDATION_DIR/application_smoke_${TARGET_VERSION}.out" 2> "$VALIDATION_DIR/application_smoke_${TARGET_VERSION}.err"; then printf '%-28s : PASSED\n' "Application Smoke Test" >> "$VALIDATION_DIR/validation_summary.txt"; return 0; fi
    printf '%-28s : FAILED\n' "Application Smoke Test" >> "$VALIDATION_DIR/validation_summary.txt"; EXTENDED_FAILED=1; return 1
}

run_extended_validation() {
    EXTENDED_FAILED=0; EXTENDED_REVIEW=0; : > "$VALIDATION_DIR/validation_summary.txt"
    printf 'MySQL Upgrade Validation Summary\nASIS=%s TOBE=%s Service=%s\n\n' "$CURRENT_VERSION" "$TARGET_VERSION" "$SERVICE_NAME" >> "$VALIDATION_DIR/validation_summary.txt"
    compare_validation_file "User Objects" "$VALIDATION_DIR/user_objects_${CURRENT_VERSION}.before.txt" "$VALIDATION_DIR/user_objects_${TARGET_VERSION}.after.txt" "$VALIDATION_DIR/user_objects_${CURRENT_VERSION}_to_${TARGET_VERSION}.diff" || true
    compare_validation_file "Schema Metrics (estimated)" "$VALIDATION_DIR/schema_metrics_${CURRENT_VERSION}.before.txt" "$VALIDATION_DIR/schema_metrics_${TARGET_VERSION}.after.txt" "$VALIDATION_DIR/schema_metrics_${CURRENT_VERSION}_to_${TARGET_VERSION}.diff" || true
    compare_validation_file "Accounts" "$VALIDATION_DIR/accounts_${CURRENT_VERSION}.before.txt" "$VALIDATION_DIR/accounts_${TARGET_VERSION}.after.txt" "$VALIDATION_DIR/accounts_${CURRENT_VERSION}_to_${TARGET_VERSION}.diff" || true
    compare_validation_file "Active Plugins" "$VALIDATION_DIR/plugins_${CURRENT_VERSION}.before.txt" "$VALIDATION_DIR/plugins_${TARGET_VERSION}.after.txt" "$VALIDATION_DIR/plugins_${CURRENT_VERSION}_to_${TARGET_VERSION}.diff" || true
    compare_validation_file "Global Variables" "$VALIDATION_DIR/global_variables_${CURRENT_VERSION}.before.txt" "$VALIDATION_DIR/global_variables_${TARGET_VERSION}.after.txt" "$VALIDATION_DIR/global_variables_${CURRENT_VERSION}_to_${TARGET_VERSION}.diff" || true
    if rpm -qa --qf '%{NAME}\t%{VERSION}\n' | awk -F '\t' -v target="$TARGET_VERSION" '$1 ~ /^mysql-community-/ && $2 != target {bad=1} END{exit bad}'; then printf '%-28s : PASSED\n' "RPM Packages" >> "$VALIDATION_DIR/validation_summary.txt"; else printf '%-28s : FAILED\n' "RPM Packages" >> "$VALIDATION_DIR/validation_summary.txt"; EXTENDED_FAILED=1; fi
    if [ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" = "active" ] && [ "$(systemctl show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null || true)" != "0" ]; then printf '%-28s : PASSED\n' "systemd Service" >> "$VALIDATION_DIR/validation_summary.txt"; else printf '%-28s : FAILED\n' "systemd Service" >> "$VALIDATION_DIR/validation_summary.txt"; EXTENDED_FAILED=1; fi
    printf '%-28s : PASSED\n' "Config Files" >> "$VALIDATION_DIR/validation_summary.txt"
    validate_replication_state || true; validate_new_error_log || true; run_smoke_test || true
    if [ "$EXTENDED_FAILED" -ne 0 ]; then _overall=FAILED; elif [ "$EXTENDED_REVIEW" -ne 0 ]; then _overall=REVIEW; else _overall=PASSED; fi
    printf '\nOverall Result               : %s\n' "$_overall" >> "$VALIDATION_DIR/validation_summary.txt"
}
collect_precheck() {
    info "업그레이드 전 상태 저장"
    if [ -n "$LOG_ERROR" ] && [ -f "$LOG_ERROR" ]; then
        BEFORE_ERROR_LOG_LINES=$(wc -l < "$LOG_ERROR" | tr -d ' ')
    else
        BEFORE_ERROR_LOG_LINES=0
    fi
    snapshot_validation_state before "$CURRENT_VERSION"
    mysql_cmd --table -e "SELECT 'SERVER_INFO' AS section; SELECT VERSION() version,@@version_comment edition,@@basedir basedir,@@datadir datadir,@@port port,@@socket socket,@@server_id server_id; SELECT 'SCHEMA_TABLE_COUNT' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'SCHEMA_SIZE' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count,COALESCE(SUM(TABLE_ROWS),0) estimated_rows,COALESCE(SUM(DATA_LENGTH),0) data_bytes,COALESCE(SUM(INDEX_LENGTH),0) index_bytes FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'USERS' AS section; SELECT user,host,plugin,account_locked FROM mysql.user ORDER BY user,host; SELECT 'ACTIVE_PLUGINS' AS section; SELECT PLUGIN_NAME,PLUGIN_VERSION,PLUGIN_STATUS,PLUGIN_TYPE,COALESCE(PLUGIN_LIBRARY,'BUILT-IN') plugin_library FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' ORDER BY PLUGIN_TYPE,PLUGIN_NAME;" > "$BACKUP_DIR/mysql_state_${CURRENT_VERSION}.before.txt" || die "DB 상태 저장 실패"
    {
        printf '===== RPM PACKAGES =====\n'; rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | grep '^mysql' | sort
        printf '\n===== MYSQLD DEFAULTS =====\n'; my_print_defaults_cmd
        printf '\n===== SERVICE =====\n'; systemctl status "$SERVICE_NAME" --no-pager || true
        printf '\n===== OPTION FILE =====\n'; sed -n '1,400p' "$CONFIG_FILE"
    } > "$BACKUP_DIR/os_state_${CURRENT_VERSION}.before.txt"
    info "CHECK TABLE ... FOR UPGRADE 사전 검사"
    mysqlcheck_cmd --all-databases --check-upgrade > "$BACKUP_DIR/mysqlcheck_${CURRENT_VERSION}.before.txt" 2>&1 || die "mysqlcheck --check-upgrade 사전 검사 실패"
    _unsupported_partitions=$(mysql_cmd -NBe "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE ENGINE NOT IN ('innodb','ndbcluster') AND CREATE_OPTIONS LIKE '%partitioned%'") || die "Partition 사전 검사 실패"
    [ "$_unsupported_partitions" -eq 0 ] || die "Native Partitioning 미지원 Storage Engine 사용 테이블 존재"
}

select_backup_mode() {
    line
    printf '%s\n' 'Backup Method Selection' '백업 방식 선택' ''
    printf '%s\n' '1) Online Logical Backup + Offline Physical Backup [권장]' '   - mysqldump SQL 형식 백업 + MySQL 정상 종료 후 전체 datadir 백업' '   - Physical Backup 기반 Full Restore와 Logical Backup 기반 SQL reload' ''
    printf '%s\n' '2) Offline Physical Backup' '   - MySQL 정상 종료 후 전체 datadir의 파일 시스템 수준 백업' '   - 동일하거나 호환되는 환경에서 빠른 Full Restore' ''
    printf '%s\n' '3) Online Logical Backup' '   - 실행 중인 MySQL에서 mysqldump SQL 형식 백업' '   - 서버·데이터베이스·테이블 단위 reload, 대용량 환경의 긴 Restore 시간' ''
    printf '%s\n' '4) Existing Backup' '   - 기존 백업의 경로·버전·생성 시각·무결성 검증' ''
    printf '%s\n' '5) No New Backup [운영 환경 비권장]' '   - 신규 백업 없음, 업그레이드 전 상태 Recovery 보장 불가' ''
    printf '선택 [1]: '
    IFS= read -r BACKUP_MODE
    BACKUP_MODE=${BACKUP_MODE:-1}
    case $BACKUP_MODE in 1|2|3) ;; 4) validate_existing_backup ;; 5) confirm_no_backup ;; *) die "잘못된 백업 방식" ;; esac
}

validate_existing_backup() {
    _existing=$(prompt_default "기존 백업 절대 경로" "")
    [ -f "$_existing" ] || die "기존 백업 파일 없음"
    [ -s "$_existing" ] || die "기존 백업 파일이 비어 있음"
    if [ -f "${_existing}.sha256" ]; then (cd "$(dirname "$_existing")" && sha256sum -c "$(basename "${_existing}.sha256")") || die "기존 백업 체크섬 실패"; else warn "SHA-256 체크섬 파일 없음"; fi
    confirm "기존 백업의 출발 버전과 Restore 절차 확인 완료?" || die "기존 백업 검증 미승인"
}

confirm_no_backup() {
    warn "신규 백업 없음. 업그레이드 전 상태 Recovery 보장 불가"
    printf '계속하려면 NO_BACKUP 입력: '
    IFS= read -r _answer
    [ "$_answer" = "NO_BACKUP" ] || die "백업 생략 취소"
}

logical_backup() {
    _dump="$BACKUP_DIR/all_databases_${CURRENT_VERSION}.sql"
    _err="$BACKUP_DIR/all_databases_${CURRENT_VERSION}.err"
    info "Online Logical Backup 시작: mysqldump"
    mysqldump_cmd --all-databases --single-transaction --routines --events --triggers --hex-blob --set-gtid-purged=OFF > "$_dump" 2> "$_err" || die "Online Logical Backup 실패: $_err"
    [ -s "$_dump" ] && grep -q '^-- Dump completed on' "$_dump" || die "Logical Backup 완료 문구 확인 실패"
    [ ! -s "$_err" ] || warn "mysqldump 경고 확인 필요: $_err"
    sha256sum "$_dump" > "${_dump}.sha256" || die "Logical Backup 체크섬 생성 실패"
}

check_space_for_physical() {
    _need=$(du -sk "$DATADIR" | awk '{print $1}')
    _avail=$(df -Pk "$BACKUP_DIR" | awk 'NR==2{print $4}')
    [ "$_avail" -gt "$_need" ] || die "Offline Physical Backup 공간 부족: need=${_need}KB available=${_avail}KB"
}

stop_server_cleanly() {
    info "innodb_fast_shutdown=0 적용"
    mysql_cmd -e "SET GLOBAL innodb_fast_shutdown=0" || die "innodb_fast_shutdown 설정 실패"
    info "MySQL 정상 종료"
    systemctl stop "$SERVICE_NAME" || die "서비스 종료 실패"
    [ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" != "active" ] || die "선택한 서비스가 계속 실행 중: $SERVICE_NAME"
    _remaining_pid=$(systemctl show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null || true)
    [ -z "$_remaining_pid" ] || [ "$_remaining_pid" = "0" ] || die "선택한 서비스의 mysqld 프로세스 잔존: service=$SERVICE_NAME pid=$_remaining_pid"
}

physical_backup() {
    check_space_for_physical
    _parent=$(dirname "$DATADIR")
    _base=$(basename "$DATADIR")
    _tar="$BACKUP_DIR/mysql_datadir_${CURRENT_VERSION}.offline_physical.tar"
    info "Offline Physical Backup 시작: $_tar"
    tar --xattrs --acls --selinux -cpf "$_tar" -C "$_parent" "$_base" || die "Offline Physical Backup 실패"
    tar -tf "$_tar" >/dev/null 2>&1 || die "Physical Backup TAR 검증 실패"
    sha256sum "$_tar" > "${_tar}.sha256" || die "Physical Backup 체크섬 생성 실패"
}

perform_backups_and_stop() {
    case $BACKUP_MODE in 1|3) logical_backup ;; esac
    case $BACKUP_MODE in
        1|2) stop_server_cleanly; physical_backup ;;
        *) stop_server_cleanly ;;
    esac
}

choose_gpg_policy() {
    printf '%s\n' '' 'RPM GPG Signature Verification' '  - Y: RPM DB에 등록된 공개 키로 패키지 서명 검증' '  - N: 서명 검증 생략, RPM digest 및 Yum transaction test는 계속 수행'
    printf 'RPM GPG signature 검증 사용 [y/N]: '
    IFS= read -r _gpg
    case ${_gpg:-N} in y|Y|yes|YES) GPG_CHECK=yes ;; *) GPG_CHECK=no; warn "RPM GPG signature 검증 생략; digest 검증은 수행" ;; esac
}

verify_local_rpms() {
    [ "$PACKAGE_SOURCE" = "1" ] && return 0
    if [ "$GPG_CHECK" = "yes" ]; then
        while IFS= read -r _rpm; do
            _verify_output=$(rpm -Kv "$_rpm" 2>&1)
            printf '%s\n' "$_verify_output" | tee -a "$LOG_FILE"
            if printf '%s\n' "$_verify_output" | grep -q 'NOKEY'; then
                die "RPM 서명 공개 키 미등록(NOKEY): $_rpm (공개 키 등록 후 재실행하거나 GPG 검증 N 선택)"
            fi
            printf '%s\n' "$_verify_output" | grep -q 'Signature.*OK' || die "RPM 서명 검증 실패: $_rpm"
        done < "$RPM_LIST_FILE"
    else
        while IFS= read -r _rpm; do rpm -K --nosignature "$_rpm" | tee -a "$LOG_FILE" | grep -q 'digests OK' || die "RPM digest 검증 실패: $_rpm"; done < "$RPM_LIST_FILE"
    fi
}

transaction_test() {
    info "RPM transaction test"
    if [ "$PACKAGE_SOURCE" = "1" ]; then
        _specs=""
        for _pkg in $(rpm -qa --qf '%{NAME}\n' | grep '^mysql-community-' | sort -u); do _specs="$_specs ${_pkg}-${TARGET_VERSION}"; done
        [ -n "$_specs" ] || die "설치된 mysql-community 패키지 없음"
        if [ "$GPG_CHECK" = "yes" ]; then
            yum upgrade -y --setopt=tsflags=test $_specs >> "$LOG_FILE" 2>&1 || die "Yum Repository transaction test 실패"
        else
            yum upgrade -y --nogpgcheck --setopt=tsflags=test $_specs >> "$LOG_FILE" 2>&1 || die "Yum Repository transaction test 실패"
        fi
    else
        _rpms=$(tr '\n' ' ' < "$RPM_LIST_FILE")
        if [ "$GPG_CHECK" = "yes" ]; then
            yum localinstall -y --disablerepo='*' --setopt=tsflags=test $_rpms >> "$LOG_FILE" 2>&1 || die "Local RPM transaction test 실패"
        else
            yum localinstall -y --disablerepo='*' --nogpgcheck --setopt=tsflags=test $_rpms >> "$LOG_FILE" 2>&1 || die "Local RPM transaction test 실패"
        fi
    fi
}

upgrade_packages() {
    info "RPM Package Upgrade 시작"
    if [ "$PACKAGE_SOURCE" = "1" ]; then
        _specs=""
        for _pkg in $(rpm -qa --qf '%{NAME}\n' | grep '^mysql-community-' | sort -u); do _specs="$_specs ${_pkg}-${TARGET_VERSION}"; done
        [ -n "$_specs" ] || die "설치된 mysql-community 패키지 없음"
        if [ "$GPG_CHECK" = "yes" ]; then yum upgrade -y $_specs || die "MySQL Yum Repository 업그레이드 실패"; else yum upgrade -y --nogpgcheck $_specs || die "MySQL Yum Repository 업그레이드 실패"; fi
    else
        # Paths originate from validated local metadata and contain no whitespace in supported RPM naming.
        _rpms=$(tr '\n' ' ' < "$RPM_LIST_FILE")
        if [ "$GPG_CHECK" = "yes" ]; then yum localinstall -y --disablerepo='*' $_rpms || die "Local RPM 업그레이드 실패"; else yum localinstall -y --disablerepo='*' --nogpgcheck $_rpms || die "Local RPM 업그레이드 실패"; fi
    fi
    rpm -q mysql-community-server --qf '%{VERSION}\n' | grep -qx "$TARGET_VERSION" || die "Server RPM 목표 버전 불일치"
}

validate_config_after_rpm() {
    if [ -f "${CONFIG_FILE}.rpmnew" ]; then cp -a "${CONFIG_FILE}.rpmnew" "$BACKUP_DIR/my.cnf.${TARGET_VERSION}.rpmnew" || die "rpmnew 보관 실패"; fi
    cmp -s "$CONFIG_PRIMARY_BACKUP" "$CONFIG_FILE" || die "기존 option file 변경 감지: $CONFIG_FILE"
    validate_config_files_unchanged
    mysqld --defaults-file="$CONFIG_FILE" --validate-config --user="$OS_SERVICE_USER" >> "$LOG_FILE" 2>&1 || die "새 mysqld의 기존 option file 검증 실패"
    _new_datadir=$(my_print_defaults_cmd | sed -n 's/^--datadir=//p' | tail -n 1)
    [ "${_new_datadir%/}" = "${DATADIR%/}" ] || die "datadir 변경 감지: $DATADIR -> $_new_datadir"
    [ "$(stat -c '%U:%G' "$DATADIR")" = "$OS_SERVICE_USER:$OS_SERVICE_GROUP" ] || die "datadir 소유권 변경 감지"
}

start_and_wait() {
    systemctl daemon-reload
    info "MySQL ${TARGET_VERSION} 최초 기동 및 내부 Data Dictionary/System Table 자동 업그레이드 완료 대기"
    systemctl start "$SERVICE_NAME" || { [ -n "$LOG_ERROR" ] && tail -n 200 "$LOG_ERROR" >> "$LOG_FILE" 2>&1; die "서비스 시작 실패"; }
    _i=0
    while [ $_i -lt 60 ]; do
        mysql_cmd -NBe "SELECT VERSION()" >/dev/null 2>&1 && break
        _i=$((_i + 1)); sleep 2
    done
    [ $_i -lt 60 ] || die "MySQL 접속 대기 시간 초과"
    _running=$(mysql_cmd -NBe "SELECT VERSION()")
    [ "$_running" = "$TARGET_VERSION" ] || die "실행 버전 불일치: $_running"
    if [ -n "$LOG_ERROR" ] && [ -f "$LOG_ERROR" ]; then
        tail -n 300 "$LOG_ERROR" > "$BACKUP_DIR/error_log_${TARGET_VERSION}.after.txt"
        grep -Ei 'upgrade|error|warning|fail|abort|ready for connections' "$LOG_ERROR" | tail -n 300 > "$BACKUP_DIR/upgrade_log_${TARGET_VERSION}.after.txt" || true
    fi
}

postcheck() {
    info "업그레이드 후 검증"
    snapshot_validation_state after "$TARGET_VERSION"
    mysql_cmd --table -e "SELECT 'SERVER_INFO' AS section; SELECT VERSION() version,@@version_comment edition,@@basedir basedir,@@datadir datadir,@@port port,@@socket socket,@@server_id server_id; SELECT 'SCHEMA_TABLE_COUNT' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'SCHEMA_SIZE' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count,COALESCE(SUM(TABLE_ROWS),0) estimated_rows,COALESCE(SUM(DATA_LENGTH),0) data_bytes,COALESCE(SUM(INDEX_LENGTH),0) index_bytes FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'USERS' AS section; SELECT user,host,plugin,account_locked FROM mysql.user ORDER BY user,host; SELECT 'ACTIVE_PLUGINS' AS section; SELECT PLUGIN_NAME,PLUGIN_VERSION,PLUGIN_STATUS,PLUGIN_TYPE,COALESCE(PLUGIN_LIBRARY,'BUILT-IN') plugin_library FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' ORDER BY PLUGIN_TYPE,PLUGIN_NAME;" > "$BACKUP_DIR/mysql_state_${TARGET_VERSION}.after.txt" || die "업그레이드 후 상태 저장 실패"
    _after_version=$(mysql_cmd -NBe "SELECT VERSION()") || die "업그레이드 후 version 조회 실패"
    _after_basedir=$(mysql_cmd -NBe "SELECT @@basedir") || die "업그레이드 후 basedir 조회 실패"
    _after_datadir=$(mysql_cmd -NBe "SELECT @@datadir") || die "업그레이드 후 datadir 조회 실패"
    _after_port=$(mysql_cmd -NBe "SELECT @@port") || die "업그레이드 후 port 조회 실패"
    _after_socket=$(mysql_cmd -NBe "SELECT @@socket") || die "업그레이드 후 socket 조회 실패"
    _after_server_id=$(mysql_cmd -NBe "SELECT @@server_id") || die "업그레이드 후 server_id 조회 실패"
    _validation_file="$BACKUP_DIR/runtime_comparison_${CURRENT_VERSION}_to_${TARGET_VERSION}.txt"
    _validation_failed=0
    _runtime_changed=0
    {
        printf 'Field\tASIS\tTOBE\tResult\n'
        printf 'version\t%s\t%s\tEXPECTED\n' "$CURRENT_VERSION" "$_after_version"
        compare_runtime_value basedir "$BEFORE_BASEDIR" "$_after_basedir" || _runtime_changed=1
        compare_runtime_value datadir "${BEFORE_DATADIR%/}" "${_after_datadir%/}" || _runtime_changed=1
        compare_runtime_value port "$BEFORE_PORT" "$_after_port" || _runtime_changed=1
        compare_runtime_value socket "$BEFORE_SOCKET" "$_after_socket" || _runtime_changed=1
        compare_runtime_value server_id "$BEFORE_SERVER_ID" "$_after_server_id" || _runtime_changed=1
    } > "$_validation_file"
    if ! mysqlcheck_cmd --all-databases --check-upgrade > "$BACKUP_DIR/mysqlcheck_${TARGET_VERSION}.after.txt" 2>&1; then
        _validation_failed=1
        printf 'mysqlcheck\tPASS required\tFAILED\tFAILED\n' >> "$_validation_file"
    fi
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | grep '^mysql' | sort > "$BACKUP_DIR/rpm_${TARGET_VERSION}.after.txt"
    cp -a "$CONFIG_FILE" "$BACKUP_DIR/my.cnf.${TARGET_VERSION}.after"
    run_extended_validation
    [ "$EXTENDED_FAILED" -eq 0 ] || _validation_failed=1
    chown -R "$OS_SERVICE_USER:$OS_SERVICE_GROUP" "$BACKUP_DIR" 2>/dev/null || warn "결과 파일 소유권 변경 실패"
    line
    printf '%s\n' 'Runtime Value Comparison:'
    awk -F '\t' '{printf "  %-12s | ASIS: %-35s | TOBE: %-35s | %s\n", $1, $2, $3, $4}' "$_validation_file"
    if [ "$_validation_failed" -eq 0 ]; then
        printf 'Package Upgrade         : COMPLETED\nAutomatic Upgrade       : COMPLETED\nPost-upgrade Validation : PASSED\n'
        if [ "$_runtime_changed" -eq 0 ]; then
            printf 'Runtime Value Review    : NO CHANGE\n'
        else
            printf 'Runtime Value Review    : USER ACTION REQUIRED\n'
            warn "업그레이드 전후 런타임 값 변경 감지. 비교 결과 확인 후 사용자가 조치"
        fi
        printf 'Current Version         : %s\nTarget Version          : %s\nResult Directory        : %s\nValidation Summary      : %s\n' "$CURRENT_VERSION" "$TARGET_VERSION" "$BACKUP_DIR" "$VALIDATION_DIR/validation_summary.txt"
    else
        printf 'Package Upgrade         : COMPLETED\nAutomatic Upgrade       : COMPLETED\nPost-upgrade Validation : FAILED\nDatabase Service        : RUNNING (자동 종료 안 함)\nComparison Result       : %s\nResult Directory        : %s\n' "$_validation_file" "$BACKUP_DIR"
        printf '%s\n' '확인 필요 항목:'
        awk -F '\t' 'NR==1 || $4=="FAILED"' "$_validation_file"
        line
        printf 'Validation Summary      : %s\n' "$VALIDATION_DIR/validation_summary.txt"
        warn "패키지 업그레이드는 적용됐지만 사후 검증 실패. 자동 Rollback 또는 서비스 종료는 수행하지 않음"
        return 1
    fi
    line
}

compare_runtime_value() {
    _compare_name=$1
    _compare_expected=$2
    _compare_actual=$3
    if [ "$_compare_expected" = "$_compare_actual" ]; then
        printf '%s\t%s\t%s\tUNCHANGED\n' "$_compare_name" "$_compare_expected" "$_compare_actual"
        return 0
    fi
    printf '%s\t%s\t%s\tREVIEW\n' "$_compare_name" "$_compare_expected" "$_compare_actual"
    return 1
}

main() {
    require_root
    require_commands
    collect_inputs
    select_package_source
    [ "$PACKAGE_SOURCE" = "1" ] || prepare_local_rpms
    version_guard
    setup_run_paths
    show_summary
    run_upgrade_checker
    collect_precheck
    select_backup_mode
    choose_gpg_policy
    verify_local_rpms
    transaction_test
    perform_backups_and_stop
    upgrade_packages
    validate_config_after_rpm
    start_and_wait
    postcheck
}

if [ "${MYSQL_UPGRADE_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi
