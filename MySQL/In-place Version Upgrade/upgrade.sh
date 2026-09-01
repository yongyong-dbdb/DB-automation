#!/bin/sh
# MySQL RPM Package-based In-place Upgrade Automation
# POSIX /bin/sh compatible
# Scope: Oracle MySQL Community RPM installations on EL8/EL9-family systems

set -u

SCRIPT_VERSION="1.0.2"
SERVICE_NAME="mysqld"
CONFIG_FILE="/etc/my.cnf"
WORK_ROOT=""
DB_USER=""
DB_HOST="localhost"
DB_PORT="3306"
DB_SOCKET=""
CONNECTION_MODE="socket"
BACKUP_MODE="1"
PACKAGE_SOURCE=""
PACKAGE_PATH=""
TARGET_VERSION=""
CURRENT_VERSION=""
DATADIR=""
LOG_ERROR=""
OS_SERVICE_USER=""
OS_SERVICE_GROUP=""
GPG_CHECK="yes"
TMP_DIR=""
MYSQL_CNF=""
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE=""
BACKUP_DIR=""
RPM_LIST_FILE=""

line() { printf '%s\n' '=============================================================================='; }
info() { printf '[INFO] %s\n' "$*"; [ -n "$LOG_FILE" ] && printf '[INFO] %s\n' "$*" >> "$LOG_FILE"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; [ -n "$LOG_FILE" ] && printf '[WARNING] %s\n' "$*" >> "$LOG_FILE"; }
die() { printf '[ERROR] %s\n' "$*" >&2; [ -n "$LOG_FILE" ] && printf '[ERROR] %s\n' "$*" >> "$LOG_FILE"; exit 1; }

cleanup() {
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
    for _cmd in mysql mysqld mysqldump mysqlcheck my_print_defaults rpm yum tar sha256sum systemctl awk sed grep find stat df du cmp pgrep mktemp tee tr sort sleep cp chmod chown readlink; do
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

collect_inputs() {
    line
    printf 'MySQL RPM Package-based In-place Upgrade Automation v%s\n' "$SCRIPT_VERSION"
    line
    CONFIG_FILE=$(prompt_default "MySQL option file 경로" "$CONFIG_FILE")
    if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
        info "systemd service 자동 감지: $SERVICE_NAME"
    else
        SERVICE_NAME=$(prompt_default "systemd service 이름" "$SERVICE_NAME")
        systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || die "systemd service unit 없음: $SERVICE_NAME"
    fi
    DB_USER=$(prompt_default "MySQL 접속용 DB 관리자 계정 (OS 계정 아님)" "root")

    printf '\n접속 방식\n1) Unix Socket\n2) TCP/IP\n선택 [1]: '
    IFS= read -r _mode
    case ${_mode:-1} in
        1)
            _socket_default=$(my_print_defaults mysqld 2>/dev/null | sed -n 's/^--socket=//p' | tail -n 1)
            [ -n "$_socket_default" ] || _socket_default="/var/lib/mysql/mysql.sock"
            CONNECTION_MODE="socket"
            DB_SOCKET=$(prompt_default "Unix Socket 경로" "$_socket_default")
            ;;
        2) CONNECTION_MODE="tcp"; DB_HOST=$(prompt_default "Host" "localhost"); DB_PORT=$(prompt_default "Port" "3306") ;;
        *) die "잘못된 접속 방식" ;;
    esac
    create_login_file
    mysql_cmd -NBe "SELECT 1" >/dev/null 2>&1 || die "MySQL 접속 실패"
    CURRENT_VERSION=$(mysql_cmd -NBe "SELECT VERSION()") || die "현재 버전 조회 실패"
    DATADIR=$(mysql_cmd -NBe "SELECT @@datadir") || die "datadir 조회 실패"
    LOG_ERROR=$(my_print_defaults mysqld 2>/dev/null | sed -n 's/^--log-error=//p' | tail -n 1)
    [ -n "$LOG_ERROR" ] || LOG_ERROR=$(mysql_cmd -NBe "SELECT @@log_error" 2>/dev/null || true)
    OS_SERVICE_USER=$(stat -c '%U' "$DATADIR") || die "datadir 소유자 조회 실패"
    OS_SERVICE_GROUP=$(stat -c '%G' "$DATADIR") || die "datadir 그룹 조회 실패"
    WORK_ROOT=$(prompt_default "작업 및 백업 상위 경로" "$(dirname "$DATADIR")/mysql_upgrade")
    _data_real=$(readlink -f "$DATADIR") || die "datadir 실제 경로 확인 실패"
    _work_real=$(readlink -m "$WORK_ROOT") || die "작업 경로 확인 실패"
    case "$_work_real/" in "$_data_real"/*) die "작업 경로를 datadir 내부에 지정할 수 없음" ;; esac
    mkdir -p "$WORK_ROOT" || die "작업 경로 생성 실패: $WORK_ROOT"
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
        1) TARGET_VERSION=$(prompt_default "목표 MySQL 버전" "9.7.2") ;;
        2) PACKAGE_PATH=$(prompt_default "RPM Bundle 절대 경로" ""); [ -f "$PACKAGE_PATH" ] || die "RPM Bundle 파일 없음: $PACKAGE_PATH" ;;
        3)
            PACKAGE_PATH=$(prompt_default "Local RPM Directory 절대 경로" "")
            [ -d "$PACKAGE_PATH" ] || die "RPM 디렉터리 없음: $PACKAGE_PATH"
            case $PACKAGE_PATH in *' '*) die "Local RPM Directory 경로에 공백 사용 불가" ;; esac
            ;;
        *) die "지원하지 않는 Package Source" ;;
    esac
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
    _cur_mm=$(printf '%s' "$CURRENT_VERSION" | awk -F. '{print $1"."$2}')
    _tgt_mm=$(printf '%s' "$TARGET_VERSION" | awk -F. '{print $1"."$2}')
    case "$_cur_mm:$_tgt_mm" in
        8.0:8.4|8.4:9.7|8.0:8.0|8.4:8.4|9.7:9.7) ;;
        *) die "자동 승인되지 않은 Upgrade Path: $CURRENT_VERSION -> $TARGET_VERSION" ;;
    esac
}

setup_run_paths() {
    BACKUP_DIR="$WORK_ROOT/${CURRENT_VERSION}_to_${TARGET_VERSION}_${RUN_ID}"
    mkdir -p "$BACKUP_DIR" || die "백업 디렉터리 생성 실패"
    LOG_FILE="$BACKUP_DIR/upgrade.log"
    chmod 700 "$BACKUP_DIR"
    cp -a "$CONFIG_FILE" "$BACKUP_DIR/my.cnf.${CURRENT_VERSION}.before" || die "option file 백업 실패"
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
    [ "$PACKAGE_SOURCE" = "1" ] || printf 'Package Source    : %s\n' "$PACKAGE_PATH"
    line
    confirm "이 구성으로 사전 검사를 시작할까요?" || die "사용자 취소"
}

run_upgrade_checker() {
    command -v mysqlsh >/dev/null 2>&1 || die "mysqlsh 없음. Upgrade Checker Utility 필요"
    _checker="$BACKUP_DIR/upgrade_check_${CURRENT_VERSION}_to_${TARGET_VERSION}.txt"
    info "Upgrade Checker Utility 실행"
    if [ "$CONNECTION_MODE" = "socket" ]; then
        mysqlsh --socket="$DB_SOCKET" --user="$DB_USER" -- util check-for-server-upgrade --target-version="$TARGET_VERSION" --config-path="$CONFIG_FILE" 2>&1 | tee "$_checker"
    else
        mysqlsh --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" -- util check-for-server-upgrade --target-version="$TARGET_VERSION" --config-path="$CONFIG_FILE" 2>&1 | tee "$_checker"
    fi
    grep -Eq 'Errors:[[:space:]]+0' "$_checker" || die "Upgrade Checker 오류 존재"
    confirm "Upgrade Checker Warning/Notice 검토 완료 후 계속 진행할까요?" || die "사용자 중단"
}

collect_precheck() {
    info "업그레이드 전 상태 저장"
    mysql_cmd --table -e "SELECT 'SERVER_INFO' AS section; SELECT VERSION() version,@@version_comment edition,@@basedir basedir,@@datadir datadir,@@port port,@@socket socket,@@server_id server_id; SELECT 'SCHEMA_TABLE_COUNT' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'SCHEMA_SIZE' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count,COALESCE(SUM(TABLE_ROWS),0) estimated_rows,COALESCE(SUM(DATA_LENGTH),0) data_bytes,COALESCE(SUM(INDEX_LENGTH),0) index_bytes FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'USERS' AS section; SELECT user,host,plugin,account_locked FROM mysql.user ORDER BY user,host; SELECT 'ACTIVE_PLUGINS' AS section; SELECT PLUGIN_NAME,PLUGIN_VERSION,PLUGIN_STATUS,PLUGIN_TYPE,COALESCE(PLUGIN_LIBRARY,'BUILT-IN') plugin_library FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' ORDER BY PLUGIN_TYPE,PLUGIN_NAME;" > "$BACKUP_DIR/mysql_state_${CURRENT_VERSION}.before.txt" || die "DB 상태 저장 실패"
    {
        printf '===== RPM PACKAGES =====\n'; rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | grep '^mysql' | sort
        printf '\n===== MYSQLD DEFAULTS =====\n'; my_print_defaults mysqld
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
    [ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" != "active" ] || die "서비스가 계속 실행 중"
    pgrep -x mysqld >/dev/null 2>&1 && die "mysqld 프로세스 잔존"
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
    printf 'RPM GPG signature 검증 사용 [Y/n]: '
    IFS= read -r _gpg
    case ${_gpg:-Y} in y|Y|yes|YES) GPG_CHECK=yes ;; *) GPG_CHECK=no; warn "RPM GPG signature 검증 생략" ;; esac
}

verify_local_rpms() {
    [ "$PACKAGE_SOURCE" = "1" ] && return 0
    if [ "$GPG_CHECK" = "yes" ]; then
        while IFS= read -r _rpm; do rpm -K "$_rpm" | tee -a "$LOG_FILE" | grep -q 'signatures OK' || die "RPM 서명 검증 실패: $_rpm"; done < "$RPM_LIST_FILE"
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
    cmp -s "$BACKUP_DIR/my.cnf.${CURRENT_VERSION}.before" "$CONFIG_FILE" || die "기존 option file 변경 감지: $CONFIG_FILE"
    mysqld --defaults-file="$CONFIG_FILE" --validate-config --user="$OS_SERVICE_USER" >> "$LOG_FILE" 2>&1 || die "새 mysqld의 기존 option file 검증 실패"
    _new_datadir=$(my_print_defaults mysqld | sed -n 's/^--datadir=//p' | tail -n 1)
    [ "${_new_datadir%/}" = "${DATADIR%/}" ] || die "datadir 변경 감지: $DATADIR -> $_new_datadir"
    [ "$(stat -c '%U:%G' "$DATADIR")" = "$OS_SERVICE_USER:$OS_SERVICE_GROUP" ] || die "datadir 소유권 변경 감지"
}

start_and_wait() {
    systemctl daemon-reload
    info "MySQL ${TARGET_VERSION} 첫 기동 및 Automatic Upgrade 대기"
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
    mysql_cmd --table -e "SELECT 'SERVER_INFO' AS section; SELECT VERSION() version,@@version_comment edition,@@basedir basedir,@@datadir datadir,@@port port,@@socket socket,@@server_id server_id; SELECT 'SCHEMA_TABLE_COUNT' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'SCHEMA_SIZE' AS section; SELECT TABLE_SCHEMA,COUNT(*) table_count,COALESCE(SUM(TABLE_ROWS),0) estimated_rows,COALESCE(SUM(DATA_LENGTH),0) data_bytes,COALESCE(SUM(INDEX_LENGTH),0) index_bytes FROM INFORMATION_SCHEMA.TABLES GROUP BY TABLE_SCHEMA ORDER BY TABLE_SCHEMA; SELECT 'USERS' AS section; SELECT user,host,plugin,account_locked FROM mysql.user ORDER BY user,host; SELECT 'ACTIVE_PLUGINS' AS section; SELECT PLUGIN_NAME,PLUGIN_VERSION,PLUGIN_STATUS,PLUGIN_TYPE,COALESCE(PLUGIN_LIBRARY,'BUILT-IN') plugin_library FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' ORDER BY PLUGIN_TYPE,PLUGIN_NAME;" > "$BACKUP_DIR/mysql_state_${TARGET_VERSION}.after.txt" || die "업그레이드 후 상태 저장 실패"
    mysqlcheck_cmd --all-databases --check-upgrade > "$BACKUP_DIR/mysqlcheck_${TARGET_VERSION}.after.txt" 2>&1 || die "mysqlcheck --check-upgrade 실패"
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | grep '^mysql' | sort > "$BACKUP_DIR/rpm_${TARGET_VERSION}.after.txt"
    cp -a "$CONFIG_FILE" "$BACKUP_DIR/my.cnf.${TARGET_VERSION}.after"
    chown -R "$OS_SERVICE_USER:$OS_SERVICE_GROUP" "$BACKUP_DIR" 2>/dev/null || warn "결과 파일 소유권 변경 실패"
    line
    printf 'Upgrade Completed\nCurrent Version : %s\nTarget Version  : %s\nResult Directory: %s\n' "$CURRENT_VERSION" "$TARGET_VERSION" "$BACKUP_DIR"
    line
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
