#!/bin/sh

# ============================================================
# PostgreSQL Major Upgrade Helper
#
# 실행:
#   sh major_upgrade.sh <step>
#
# Bash 전용 기능을 사용하므로 sh로 실행된 경우
# 자동으로 Bash로 재실행한다.
# ============================================================

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail


# ============================================================
# Default Configuration
# ============================================================

BASE="${BASE:-$HOME}"

PG_NEW_VERSION="${PG_NEW_VERSION:-}"
PG_NEW_MAJOR="${PG_NEW_MAJOR:-}"

SRC_TAR="${SRC_TAR:-}"
SRC_DIR="${SRC_DIR:-}"

PG_HOME_OLD="${PG_HOME_OLD:-}"
PG_HOME_NEW="${PG_HOME_NEW:-}"

PGDATA_OLD="${PGDATA_OLD:-}"
PGDATA_NEW="${PGDATA_NEW:-}"

OLD_PORT="${OLD_PORT:-}"
NEW_PORT="${NEW_PORT:-}"

PGUSER_NAME="${PGUSER_NAME:-postgres}"
PGPASSWORD="${PGPASSWORD:-}"

JOBS="${JOBS:-}"
USE_LINK="${USE_LINK:-}"

BACKUP_DIR="${BACKUP_DIR:-}"
WORK_DIR="${WORK_DIR:-}"

BASH_PROFILE="${BASH_PROFILE:-$HOME/.bash_profile}"

INITDB_EXTRA_OPTS="${INITDB_EXTRA_OPTS:-}"

OLD_ENCODING="${OLD_ENCODING:-}"
OLD_LC_COLLATE="${OLD_LC_COLLATE:-}"
OLD_LC_CTYPE="${OLD_LC_CTYPE:-}"

UPGRADE_CONFIG_FILE="${UPGRADE_CONFIG_FILE:-}"

STEP=""


# ============================================================
# Common
# ============================================================

log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}


die() {
    echo "ERROR: $*" >&2
    exit 1
}


confirm() {
    local expected="$1"
    local message="$2"
    local answer

    echo
    echo "$message"

    printf 'Type "%s" to continue: ' "$expected"
    read -r answer

    [[ "$answer" == "$expected" ]] || \
        die "cancelled"
}


# ============================================================
# PostgreSQL Password
#
# 한 번의 script 실행에서는 1회만 입력
# ============================================================

ensure_pg_password() {
    if [[ -n "${PGPASSWORD:-}" ]]; then

        export PGPASSWORD
        return 0

    fi

    echo
    printf 'PostgreSQL password for %s: ' "$PGUSER_NAME"

    read -r -s PGPASSWORD

    echo

    [[ -n "$PGPASSWORD" ]] || \
        die "PostgreSQL password is empty"

    export PGPASSWORD

    log "PostgreSQL password loaded for current script execution"
}


# ============================================================
# Arguments
# ============================================================

parse_args() {
    while [[ $# -gt 0 ]]; do

        case "$1" in

            --new-version)

                [[ $# -ge 2 ]] || \
                    die "--new-version requires a value"

                PG_NEW_VERSION="$2"

                shift 2
                ;;


            --new-version=*)

                PG_NEW_VERSION="${1#*=}"

                shift
                ;;


            --new-port)

                [[ $# -ge 2 ]] || \
                    die "--new-port requires a value"

                NEW_PORT="$2"

                shift 2
                ;;


            --new-port=*)

                NEW_PORT="${1#*=}"

                shift
                ;;


            --old-port)

                [[ $# -ge 2 ]] || \
                    die "--old-port requires a value"

                OLD_PORT="$2"

                shift 2
                ;;


            --old-port=*)

                OLD_PORT="${1#*=}"

                shift
                ;;


            --base)

                [[ $# -ge 2 ]] || \
                    die "--base requires a value"

                BASE="$2"

                shift 2
                ;;


            --base=*)

                BASE="${1#*=}"

                shift
                ;;


            help|-h|--help)

                STEP="help"

                shift
                ;;


            -*)

                die "unknown option: $1"
                ;;


            *)

                [[ -z "$STEP" ]] || \
                    die "multiple steps specified: $STEP and $1"

                STEP="$1"

                shift
                ;;

        esac

    done


    STEP="${STEP:-help}"
}


# ============================================================
# Config File
# ============================================================

config_value() {
    local key="$1"
    local file="$2"

    [[ -f "$file" ]] || \
        return 0

    awk -F= -v key="$key" '
        $1 == key {
            sub(/^[ \t]+/, "", $2)
            sub(/[ \t]+$/, "", $2)
            print $2
            exit
        }
    ' "$file"
}


load_saved_config() {
    [[ -n "$UPGRADE_CONFIG_FILE" ]] || \
        UPGRADE_CONFIG_FILE="$BASE/.postgresql_major_upgrade.conf"


    [[ -f "$UPGRADE_CONFIG_FILE" ]] || \
        return 0


    #
    # OLD 환경은 저장값을 authoritative하게 사용하지 않는다.
    #
    # NEW Version / Port / tuning만 재사용.
    #

    PG_NEW_VERSION="${PG_NEW_VERSION:-$(config_value PG_NEW_VERSION "$UPGRADE_CONFIG_FILE")}"

    NEW_PORT="${NEW_PORT:-$(config_value NEW_PORT "$UPGRADE_CONFIG_FILE")}"

    JOBS="${JOBS:-$(config_value JOBS "$UPGRADE_CONFIG_FILE")}"

    USE_LINK="${USE_LINK:-$(config_value USE_LINK "$UPGRADE_CONFIG_FILE")}"
}


save_config() {
    [[ -n "$UPGRADE_CONFIG_FILE" ]] || \
        UPGRADE_CONFIG_FILE="$BASE/.postgresql_major_upgrade.conf"


    cat > "$UPGRADE_CONFIG_FILE" <<EOF
PG_NEW_VERSION=$PG_NEW_VERSION
PG_NEW_MAJOR=$PG_NEW_MAJOR
OLD_PORT=$OLD_PORT
NEW_PORT=$NEW_PORT
BASE=$BASE
SRC_TAR=$SRC_TAR
SRC_DIR=$SRC_DIR
PG_HOME_OLD=$PG_HOME_OLD
PG_HOME_NEW=$PG_HOME_NEW
PGDATA_OLD=$PGDATA_OLD
PGDATA_NEW=$PGDATA_NEW
WORK_DIR=$WORK_DIR
JOBS=$JOBS
USE_LINK=$USE_LINK
EOF


    log "saved upgrade config: $UPGRADE_CONFIG_FILE"
}


# ============================================================
# OLD Environment Detection
#
# 우선순위:
#
# 1. PG_HOME_OLD / PGDATA_OLD / --old-port
# 2. 현재 shell 환경
# 3. ~/.bash_profile
# 4. 기본 경로
#
# OLD port는 임의 추정하지 않는다.
# ============================================================

load_old_environment() {
    local profile_pg_home=""
    local profile_pghome=""
    local profile_pgdata=""
    local profile_pgport=""
    local profile_pg_port=""

    log "detecting OLD PostgreSQL environment"


    # --------------------------------------------------------
    # PG_HOME
    # --------------------------------------------------------

    if [[ -z "$PG_HOME_OLD" ]]; then

        if [[ -n "${PG_HOME:-}" ]]; then

            PG_HOME_OLD="$PG_HOME"

            log "OLD PG_HOME detected from current environment PG_HOME: $PG_HOME_OLD"

        elif [[ -n "${PGHOME:-}" ]]; then

            PG_HOME_OLD="$PGHOME"

            log "OLD PG_HOME detected from current environment PGHOME: $PG_HOME_OLD"

        fi

    else

        log "OLD PG_HOME explicitly specified: $PG_HOME_OLD"

    fi


    # --------------------------------------------------------
    # PGDATA
    # --------------------------------------------------------

    if [[ -z "$PGDATA_OLD" ]]; then

        if [[ -n "${PGDATA:-}" ]]; then

            PGDATA_OLD="$PGDATA"

            log "OLD PGDATA detected from current environment PGDATA: $PGDATA_OLD"

        fi

    else

        log "OLD PGDATA explicitly specified: $PGDATA_OLD"

    fi


    # --------------------------------------------------------
    # PORT
    # --------------------------------------------------------

    if [[ -z "$OLD_PORT" ]]; then

        if [[ -n "${PGPORT:-}" ]]; then

            OLD_PORT="$PGPORT"

            log "OLD PORT detected from current environment PGPORT: $OLD_PORT"

        elif [[ -n "${PG_PORT:-}" ]]; then

            OLD_PORT="$PG_PORT"

            log "OLD PORT detected from current environment PG_PORT: $OLD_PORT"

        fi

    else

        log "OLD PORT explicitly specified: $OLD_PORT"

    fi


    # --------------------------------------------------------
    # .bash_profile
    # --------------------------------------------------------

    if [[ -f "$BASH_PROFILE" ]]; then

        if [[ -z "$PG_HOME_OLD" ]]; then

            profile_pg_home="$(
                /usr/bin/env bash --noprofile --norc -c '
                    set +u
                    source "$1" >/dev/null 2>&1 || true
                    printf "%s" "${PG_HOME:-}"
                ' _ "$BASH_PROFILE" 2>/dev/null || true
            )"


            profile_pghome="$(
                /usr/bin/env bash --noprofile --norc -c '
                    set +u
                    source "$1" >/dev/null 2>&1 || true
                    printf "%s" "${PGHOME:-}"
                ' _ "$BASH_PROFILE" 2>/dev/null || true
            )"


            if [[ -n "$profile_pg_home" ]]; then

                PG_HOME_OLD="$profile_pg_home"

                log "OLD PG_HOME detected from $BASH_PROFILE PG_HOME: $PG_HOME_OLD"

            elif [[ -n "$profile_pghome" ]]; then

                PG_HOME_OLD="$profile_pghome"

                log "OLD PG_HOME detected from $BASH_PROFILE PGHOME: $PG_HOME_OLD"

            fi

        fi


        if [[ -z "$PGDATA_OLD" ]]; then

            profile_pgdata="$(
                /usr/bin/env bash --noprofile --norc -c '
                    set +u
                    source "$1" >/dev/null 2>&1 || true
                    printf "%s" "${PGDATA:-}"
                ' _ "$BASH_PROFILE" 2>/dev/null || true
            )"


            if [[ -n "$profile_pgdata" ]]; then

                PGDATA_OLD="$profile_pgdata"

                log "OLD PGDATA detected from $BASH_PROFILE: $PGDATA_OLD"

            fi

        fi


        if [[ -z "$OLD_PORT" ]]; then

            profile_pgport="$(
                /usr/bin/env bash --noprofile --norc -c '
                    set +u
                    source "$1" >/dev/null 2>&1 || true
                    printf "%s" "${PGPORT:-}"
                ' _ "$BASH_PROFILE" 2>/dev/null || true
            )"


            profile_pg_port="$(
                /usr/bin/env bash --noprofile --norc -c '
                    set +u
                    source "$1" >/dev/null 2>&1 || true
                    printf "%s" "${PG_PORT:-}"
                ' _ "$BASH_PROFILE" 2>/dev/null || true
            )"


            if [[ -n "$profile_pgport" ]]; then

                OLD_PORT="$profile_pgport"

                log "OLD PORT detected from $BASH_PROFILE PGPORT: $OLD_PORT"

            elif [[ -n "$profile_pg_port" ]]; then

                OLD_PORT="$profile_pg_port"

                log "OLD PORT detected from $BASH_PROFILE PG_PORT: $OLD_PORT"

            fi

        fi

    else

        log "bash profile not found: $BASH_PROFILE"

    fi


    # --------------------------------------------------------
    # Fallback
    # --------------------------------------------------------

    if [[ -z "$PG_HOME_OLD" ]]; then

        PG_HOME_OLD="$BASE/pgsql"

        log "OLD PG_HOME not found in environment; fallback: $PG_HOME_OLD"

    fi


    if [[ -z "$PGDATA_OLD" ]]; then

        if [[ -d "$BASE/pgsql/data" ]]; then

            PGDATA_OLD="$BASE/pgsql/data"

        else

            PGDATA_OLD="$BASE/data"

        fi


        log "OLD PGDATA not found in environment; fallback: $PGDATA_OLD"

    fi


    # --------------------------------------------------------
    # Port validation
    # --------------------------------------------------------

    [[ -n "$OLD_PORT" ]] || \
        die "OLD PostgreSQL port could not be detected. Specify --old-port."


    [[ "$OLD_PORT" =~ ^[0-9]+$ ]] || \
        die "invalid OLD PostgreSQL port: $OLD_PORT"


    if (( OLD_PORT < 1 || OLD_PORT > 65535 )); then

        die "OLD PostgreSQL port out of range: $OLD_PORT"

    fi


    log "OLD PostgreSQL environment"

    log "  PG_HOME : $PG_HOME_OLD"

    log "  PGDATA  : $PGDATA_OLD"

    log "  PORT    : $OLD_PORT"
}


# ============================================================
# Initial Configuration
# ============================================================

prompt_initial_config() {
    local input

    echo
    echo "============================================================"
    echo "OLD PostgreSQL Environment"
    echo "============================================================"
    echo

    echo "PG_HOME_OLD : $PG_HOME_OLD"
    echo "PGDATA_OLD  : $PGDATA_OLD"
    echo "OLD_PORT    : $OLD_PORT"

    echo


    if [[ -n "$PG_NEW_VERSION" ]]; then

        printf 'Enter new PostgreSQL version [current: %s]: ' \
            "$PG_NEW_VERSION"

    else

        printf 'Enter new PostgreSQL version, for example 15.9: '

    fi


    read -r input


    if [[ -n "$input" ]]; then

        PG_NEW_VERSION="$input"

    fi


    if [[ -n "$NEW_PORT" ]]; then

        printf 'Enter new PostgreSQL port [current: %s]: ' \
            "$NEW_PORT"

    else

        printf 'Enter new PostgreSQL port: '

    fi


    read -r input


    if [[ -n "$input" ]]; then

        NEW_PORT="$input"

    fi
}


version_major() {
    echo "$1" |
        sed -E 's/[^0-9]*([0-9]+).*/\1/'
}


finalize_config() {
    [[ "$STEP" == "help" ]] && \
        return 0


    load_saved_config

    load_old_environment


    case "$STEP" in

        config|prepare)

            prompt_initial_config
            ;;

    esac


    if [[ -z "$PG_NEW_VERSION" ]]; then

        printf 'Enter new PostgreSQL version, for example 15.9: '

        read -r PG_NEW_VERSION

    fi


    [[ -n "$PG_NEW_VERSION" ]] || \
        die "new PostgreSQL version is required"


    if [[ -z "$NEW_PORT" ]]; then

        printf 'Enter new PostgreSQL port: '

        read -r NEW_PORT

    fi


    [[ -n "$NEW_PORT" ]] || \
        die "new PostgreSQL port is required"


    [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || \
        die "invalid NEW PostgreSQL port: $NEW_PORT"


    if (( NEW_PORT < 1 || NEW_PORT > 65535 )); then

        die "NEW PostgreSQL port out of range: $NEW_PORT"

    fi


    PG_NEW_MAJOR="$(version_major "$PG_NEW_VERSION")"


    #
    # NEW 경로는 전체 Version을 사용한다.
    #
    # 15.9
    #
    #   PG_HOME_NEW=/home/sherpa/pgsql_15.9
    #   PGDATA_NEW=/home/sherpa/data_15.9
    #

    SRC_TAR="${SRC_TAR:-$BASE/postgresql-$PG_NEW_VERSION.tar.gz}"

    SRC_DIR="${SRC_DIR:-$BASE/postgresql-$PG_NEW_VERSION}"

    PG_HOME_NEW="${PG_HOME_NEW:-$BASE/pgsql_$PG_NEW_VERSION}"

    PGDATA_NEW="${PGDATA_NEW:-$BASE/data_$PG_NEW_VERSION}"

    WORK_DIR="${WORK_DIR:-$BASE/pg_upgrade_work_$PG_NEW_VERSION}"

    BACKUP_DIR="${BACKUP_DIR:-$BASE/backup_pg_upgrade_$(date +%Y%m%d_%H%M%S)}"

    JOBS="${JOBS:-2}"

    USE_LINK="${USE_LINK:-true}"


    save_config
}


# ============================================================
# PostgreSQL Connection Helpers
# ============================================================

psql_old_at() {
    "$PG_HOME_OLD/bin/psql" \
        -X \
        -A \
        -t \
        -v ON_ERROR_STOP=1 \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "$1"
}


psql_old_at_optional() {
    "$PG_HOME_OLD/bin/psql" \
        -X \
        -A \
        -t \
        -v ON_ERROR_STOP=1 \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "$1" \
        2>/dev/null || true
}


# ============================================================
# OLD Cluster Validation
# ============================================================

validate_old_cluster_paths() {
    local server_version_num
    local server_major

    local dumpall_version
    local dumpall_major

    local running_data_dir
    local running_port


    ensure_pg_password


    [[ -x "$PG_HOME_OLD/bin/pg_dumpall" ]] || \
        die "OLD pg_dumpall not found: $PG_HOME_OLD/bin/pg_dumpall"


    server_version_num="$(
        psql_old_at "show server_version_num;"
    )"


    [[ "$server_version_num" =~ ^[0-9]+$ ]] || \
        die "could not read OLD PostgreSQL server_version_num using port $OLD_PORT"


    server_major=$((server_version_num / 10000))


    dumpall_version="$(
        "$PG_HOME_OLD/bin/pg_dumpall" --version
    )"


    dumpall_major="$(
        version_major "$dumpall_version"
    )"


    if [[ "$server_major" != "$dumpall_major" ]]; then

        die "OLD binary mismatch: server major=$server_major, pg_dumpall=$dumpall_version"

    fi


    running_data_dir="$(
        psql_old_at "show data_directory;"
    )"


    if [[ "$running_data_dir" != "$PGDATA_OLD" ]]; then

        die "OLD PGDATA mismatch: server=$running_data_dir configured=$PGDATA_OLD"

    fi


    running_port="$(
        psql_old_at "show port;"
    )"


    if [[ "$running_port" != "$OLD_PORT" ]]; then

        die "OLD port mismatch: server=$running_port configured=$OLD_PORT"

    fi


    log "OLD PostgreSQL validation OK"

    log "  PG_HOME : $PG_HOME_OLD"

    log "  PGDATA  : $PGDATA_OLD"

    log "  PORT    : $OLD_PORT"

    log "  VERSION : $server_major"
}


# ============================================================
# pg_controldata Helpers
# ============================================================

old_template0_value() {
    local column="$1"

    psql_old_at_optional \
        "select $column from pg_database where datname = 'template0';"
}


old_control_value() {
    "$PG_HOME_OLD/bin/pg_controldata" "$PGDATA_OLD" |
        awk -F: -v key="$1" '
            $1 == key {
                sub(/^[ \t]+/, "", $2)
                print $2
                exit
            }
        '
}


new_control_value() {
    "$PG_HOME_NEW/bin/pg_controldata" "$PGDATA_NEW" |
        awk -F: -v key="$1" '
            $1 == key {
                sub(/^[ \t]+/, "", $2)
                print $2
                exit
            }
        '
}


# ============================================================
# Checksum Detection
# ============================================================

new_initdb_supports_option() {
    local option="$1"


    "$PG_HOME_NEW/bin/initdb" --help 2>&1 |
        grep -F -- "$option" >/dev/null 2>&1
}


determine_checksum_option() {
    local old_checksum


    old_checksum="$(
        old_control_value "Data page checksum version"
    )"


    case "$old_checksum" in

        0)

            #
            # OLD checksum OFF.
            #
            # NEW initdb에서 --no-data-checksums가 지원되면
            # 명시적으로 비활성화.
            #
            # 미지원 버전은 initdb 기본값을 사용.
            #

            if new_initdb_supports_option "--no-data-checksums"; then

                echo "--no-data-checksums"

            else

                echo ""

            fi
            ;;


        ''|*[!0-9]*)

            die "could not read OLD data checksum version"
            ;;


        *)

            #
            # OLD checksum ON.
            #

            if new_initdb_supports_option "--data-checksums"; then

                echo "--data-checksums"

            else

                die "NEW initdb does not support --data-checksums"

            fi
            ;;

    esac
}


checksum_status_text() {
    local value="$1"


    if [[ "$value" == "0" ]]; then

        echo "disabled"

    else

        echo "enabled"

    fi
}


# ============================================================
# pg_upgrade HBA
#
# pg_upgrade NEW 임시 postmaster 접속용.
#
# NEW initdb 직후에는 OLD catalog의 postgres password가
# 아직 없으므로 local socket만 trust 허용.
#
# pg_upgrade 완료 후 OLD HBA를 복구한다.
# ============================================================

prepare_pg_upgrade_hba() {
    local hba_file="$PGDATA_NEW/pg_hba.conf"

    local backup_file="$PGDATA_NEW/pg_hba.conf.before_pg_upgrade"

    local tmp_file

    local marker_begin="# BEGIN postgresql_major_upgrade.sh pg_upgrade trust"

    local marker_end="# END postgresql_major_upgrade.sh pg_upgrade trust"


    [[ -f "$hba_file" ]] || \
        die "NEW pg_hba.conf not found: $hba_file"


    if [[ ! -f "$backup_file" ]]; then

        cp -p \
            "$hba_file" \
            "$backup_file"


        log "NEW pg_hba.conf backup saved: $backup_file"

    fi


    tmp_file="${hba_file}.tmp.$$"


    awk \
        -v begin="$marker_begin" \
        -v end="$marker_end" '
            $0 == begin {
                skip = 1
                next
            }

            $0 == end {
                skip = 0
                next
            }

            !skip {
                print
            }
        ' "$hba_file" > "$tmp_file"


    {
        echo "$marker_begin"

        echo "local   all   all   trust"

        echo "$marker_end"

        echo

        cat "$tmp_file"

    } > "${tmp_file}.new"


    cp -p \
        "$hba_file" \
        "${hba_file}.permission.$$"


    cat "${tmp_file}.new" > "$hba_file"


    chmod \
        --reference="${hba_file}.permission.$$" \
        "$hba_file" \
        2>/dev/null || true


    rm -f \
        "$tmp_file" \
        "${tmp_file}.new" \
        "${hba_file}.permission.$$"


    if ! grep -Fqx \
        "local   all   all   trust" \
        "$hba_file"; then

        die "failed to configure NEW pg_hba.conf for pg_upgrade"

    fi


    log "configured NEW pg_hba.conf for pg_upgrade local trust"
}


pg_upgrade_hba_is_active() {
    local hba_file="$PGDATA_NEW/pg_hba.conf"


    [[ -f "$hba_file" ]] || \
        return 1


    grep -Fqx \
        "# BEGIN postgresql_major_upgrade.sh pg_upgrade trust" \
        "$hba_file"
}


# ============================================================
# Apply OLD Authentication Config to NEW
# ============================================================

apply_old_auth_to_new() {
    local old_hba="$PGDATA_OLD/pg_hba.conf"

    local old_ident="$PGDATA_OLD/pg_ident.conf"

    local new_hba="$PGDATA_NEW/pg_hba.conf"

    local new_ident="$PGDATA_NEW/pg_ident.conf"


    [[ -f "$old_hba" ]] || \
        die "OLD pg_hba.conf not found: $old_hba"


    if [[ -f "$new_hba" &&
          ! -f "$PGDATA_NEW/pg_hba.conf.pg_upgrade" ]]; then

        cp -p \
            "$new_hba" \
            "$PGDATA_NEW/pg_hba.conf.pg_upgrade"

    fi


    cp -p \
        "$old_hba" \
        "$new_hba"


    if [[ -f "$old_ident" ]]; then

        cp -p \
            "$old_ident" \
            "$new_ident"

    fi


    if pg_upgrade_hba_is_active; then

        die "pg_upgrade trust configuration still exists after HBA restore"

    fi


    log "OLD authentication configuration applied to NEW PostgreSQL"

    log "  pg_hba.conf : $new_hba"


    if [[ -f "$old_ident" ]]; then

        log "  pg_ident.conf : $new_ident"

    fi
}


# ============================================================
# Build Dependency Check
# ============================================================

detect_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo yum
    elif command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v zypper >/dev/null 2>&1; then
        echo zypper
    else
        echo none
    fi
}


build_dependency_packages() {
    local manager="$1"

    case "$manager" in
        dnf|yum)
            printf '%s\n' gcc make readline-devel zlib-devel openssl-devel
            ;;
        apt)
            printf '%s\n' build-essential libreadline-dev zlib1g-dev libssl-dev
            ;;
        zypper)
            printf '%s\n' gcc make readline-devel zlib-devel libopenssl-devel
            ;;
        *)
            return 1
            ;;
    esac
}


package_is_installed() {
    local manager="$1"
    local pkg="$2"

    case "$manager" in
        apt)
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
                grep -q 'install ok installed'
            ;;
        dnf|yum|zypper)
            rpm -q "$pkg" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}


package_install_command() {
    local manager="$1"
    shift

    case "$manager" in
        apt)
            printf 'apt-get install -y'
            ;;
        zypper)
            printf 'zypper --non-interactive install'
            ;;
        dnf|yum)
            printf '%s install -y' "$manager"
            ;;
    esac

    printf ' %q' "$@"
    echo
}


install_build_packages() {
    local manager="$1"
    shift

    case "$manager" in
        apt)
            apt-get install -y "$@"
            ;;
        zypper)
            zypper --non-interactive install "$@"
            ;;
        dnf|yum)
            "$manager" install -y "$@"
            ;;
        *)
            return 1
            ;;
    esac
}


check_build_dependencies() {
    local manager
    local missing=()
    local pkg
    local answer

    manager="$(detect_package_manager)"
    [[ "$manager" != none ]] || \
        die "supported package manager not found; supported: dnf, yum, apt-get, zypper"

    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        package_is_installed "$manager" "$pkg" || missing+=("$pkg")
    done < <(build_dependency_packages "$manager")


    if [[ ${#missing[@]} -eq 0 ]]; then

        log "PostgreSQL build dependencies OK"

        return 0

    fi


    echo
    echo "============================================================"
    echo "Missing PostgreSQL Build Dependencies"
    echo "============================================================"
    echo


    for pkg in "${missing[@]}"; do

        echo "  - $pkg"

    done


    echo


    #
    # 일반 계정이면 sudo 자동 수행 안 함.
    #

    if [[ "$(id -u)" -ne 0 ]]; then

        echo "Current user is not root."

        echo

        echo "Run the following command as root:"

        echo

        printf '  '
        package_install_command "$manager" "${missing[@]}"

        echo


        die "PostgreSQL build dependencies are missing"

    fi


    #
    # root여도 설치 전 확인.
    #

    printf 'Install missing packages now? [y/N]: '

    read -r answer


    case "${answer,,}" in

        y|yes)

            ;;

        *)

            die "package installation cancelled"
            ;;

    esac


    log "installing PostgreSQL build dependencies"


    install_build_packages "$manager" "${missing[@]}"

    for pkg in "${missing[@]}"; do
        package_is_installed "$manager" "$pkg" || \
            die "$pkg installation verification failed"
    done


    log "PostgreSQL build dependencies installed successfully"
}


# ============================================================
# NEW postgresql.conf Port
# ============================================================

set_new_postgresql_conf_port() {
    local conf_file="$PGDATA_NEW/postgresql.conf"

    local marker_begin="# BEGIN postgresql_major_upgrade.sh managed port"

    local marker_end="# END postgresql_major_upgrade.sh managed port"


    [[ -f "$conf_file" ]] || \
        die "NEW postgresql.conf not found: $conf_file"


    if [[ ! -f "$conf_file.before_port_update" ]]; then

        cp -p \
            "$conf_file" \
            "$conf_file.before_port_update"

    fi


    sed -i \
        '/^# BEGIN postgresql_major_upgrade.sh managed port$/,/^# END postgresql_major_upgrade.sh managed port$/d' \
        "$conf_file"


    sed -i -E \
        's/^[[:space:]]*port[[:space:]]*=/# port disabled by postgresql_major_upgrade.sh: /' \
        "$conf_file"


    {
        echo

        echo "$marker_begin"

        echo "port = $NEW_PORT"

        echo "$marker_end"

    } >> "$conf_file"


    log "set NEW postgresql.conf port to $NEW_PORT"
}


# ============================================================
# Show Config
# ============================================================

show_config() {
    cat <<EOF
BASE=$BASE
PG_NEW_VERSION=$PG_NEW_VERSION
PG_NEW_MAJOR=$PG_NEW_MAJOR
SRC_TAR=$SRC_TAR
SRC_DIR=$SRC_DIR
PG_HOME_OLD=$PG_HOME_OLD
PG_HOME_NEW=$PG_HOME_NEW
PGDATA_OLD=$PGDATA_OLD
PGDATA_NEW=$PGDATA_NEW
OLD_PORT=$OLD_PORT
NEW_PORT=$NEW_PORT
PGUSER_NAME=$PGUSER_NAME
JOBS=$JOBS
USE_LINK=$USE_LINK
BACKUP_DIR=$BACKUP_DIR
WORK_DIR=$WORK_DIR
BASH_PROFILE=$BASH_PROFILE
UPGRADE_CONFIG_FILE=$UPGRADE_CONFIG_FILE
INITDB_EXTRA_OPTS=$INITDB_EXTRA_OPTS
OLD_ENCODING=$OLD_ENCODING
OLD_LC_COLLATE=$OLD_LC_COLLATE
OLD_LC_CTYPE=$OLD_LC_CTYPE
EOF
}


# ============================================================
# Precheck
# ============================================================

precheck() {
    ensure_pg_password


    show_config


    [[ -x "$PG_HOME_OLD/bin/psql" ]] || \
        die "OLD psql not found: $PG_HOME_OLD/bin/psql"


    [[ -x "$PG_HOME_OLD/bin/pg_controldata" ]] || \
        die "OLD pg_controldata not found: $PG_HOME_OLD/bin/pg_controldata"


    [[ -d "$PGDATA_OLD" ]] || \
        die "OLD PGDATA not found: $PGDATA_OLD"


    [[ -f "$SRC_TAR" ]] || \
        die "source tar not found: $SRC_TAR"


    validate_old_cluster_paths


    "$PG_HOME_OLD/bin/postgres" --version


    "$PG_HOME_OLD/bin/pg_dumpall" --version


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "select version();"


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show data_directory;"


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show port;"


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show listen_addresses;"


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show shared_preload_libraries;"


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "
            select
                datname,
                pg_encoding_to_char(encoding) as encoding,
                datcollate,
                datctype
            from pg_database
            where datname = 'template0';
        "


    "$PG_HOME_OLD/bin/pg_controldata" "$PGDATA_OLD" |
        egrep \
            'Database cluster state|Data page checksum version|WAL block size|Bytes per WAL segment'


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "
            select
                application_name,
                client_addr,
                state,
                sync_state,
                sent_lsn,
                replay_lsn
            from pg_stat_replication;
        "


    "$PG_HOME_OLD/bin/psql" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "
            select
                extname,
                extversion
            from pg_extension
            order by extname;
        "
}


# ============================================================
# Build
# ============================================================

build() {
    check_build_dependencies


    if [[ ! -d "$SRC_DIR" ]]; then

        [[ -f "$SRC_TAR" ]] || \
            die "source tar not found: $SRC_TAR"


        tar \
            -C "$BASE" \
            -xzf "$SRC_TAR"

    fi


    cd "$SRC_DIR"


    # configure options or dependency availability may have changed since
    # a previous build.  Reusing objects from a differently configured
    # tree can produce duplicate or unresolved OpenSSL symbols.
    if [[ -f "$SRC_DIR/config.status" ]]; then

        log "cleaning previous PostgreSQL build artifacts"

        make distclean

    fi


    ./configure \
        --prefix="$PG_HOME_NEW" \
        --with-openssl


    make \
        -j "$JOBS"


    make install


    make \
        -C contrib \
        install


    "$PG_HOME_NEW/bin/postgres" --version
}


# ============================================================
# Contrib Only
# ============================================================

install_contrib() {
    [[ -d "$SRC_DIR/contrib" ]] || \
        die "contrib source directory not found: $SRC_DIR/contrib"


    cd "$SRC_DIR"


    make \
        -C contrib \
        install


    log "contrib extensions installed into $PG_HOME_NEW"
}


# ============================================================
# Backup
# ============================================================

backup() {
    ensure_pg_password


    validate_old_cluster_paths


    mkdir -p \
        "$BACKUP_DIR"


    "$PG_HOME_OLD/bin/pg_dumpall" \
        -p "$OLD_PORT" \
        -U "$PGUSER_NAME" \
        > "$BACKUP_DIR/backup_pg${OLD_PORT}_all.sql"


    cp -p \
        "$PGDATA_OLD/postgresql.conf" \
        "$BACKUP_DIR/postgresql.conf.old"


    cp -p \
        "$PGDATA_OLD/pg_hba.conf" \
        "$BACKUP_DIR/pg_hba.conf.old"


    if [[ -f "$PGDATA_OLD/pg_ident.conf" ]]; then

        cp -p \
            "$PGDATA_OLD/pg_ident.conf" \
            "$BACKUP_DIR/pg_ident.conf.old"

    fi


    log "backup saved: $BACKUP_DIR"
}


# ============================================================
# initdb
# ============================================================

initdb_new() {
    local old_encoding
    local old_lc_collate
    local old_lc_ctype

    local old_checksum
    local new_checksum

    local checksum_arg
    local checksum_status

    local initdb_args=()

    local extra_opts=()


    ensure_pg_password


    [[ -x "$PG_HOME_NEW/bin/initdb" ]] || \
        die "NEW initdb not found: $PG_HOME_NEW/bin/initdb"


    [[ -x "$PG_HOME_NEW/bin/pg_controldata" ]] || \
        die "NEW pg_controldata not found: $PG_HOME_NEW/bin/pg_controldata"


    if [[ -e "$PGDATA_NEW/PG_VERSION" ]]; then

        die "already initialized: $PGDATA_NEW"

    fi


    old_encoding="${OLD_ENCODING:-$(old_template0_value "pg_encoding_to_char(encoding)")}"


    old_lc_collate="${OLD_LC_COLLATE:-$(old_template0_value "datcollate")}"


    old_lc_ctype="${OLD_LC_CTYPE:-$(old_template0_value "datctype")}"


    [[ -n "$old_encoding" ]] || \
        die "could not detect OLD encoding"


    [[ -n "$old_lc_collate" ]] || \
        die "could not detect OLD lc_collate"


    [[ -n "$old_lc_ctype" ]] || \
        die "could not detect OLD lc_ctype"


    old_checksum="$(
        old_control_value "Data page checksum version"
    )"


    [[ "$old_checksum" =~ ^[0-9]+$ ]] || \
        die "could not read OLD checksum status"


    checksum_arg="$(
        determine_checksum_option
    )"


    checksum_status="$(
        checksum_status_text "$old_checksum"
    )"


    # ========================================================
    # IMPORTANT
    #
    # NEW cluster bootstrap superuser는 반드시
    # PGUSER_NAME과 동일하게 생성한다.
    #
    # 현재 기본값:
    #
    #   PGUSER_NAME=postgres
    #
    # 따라서:
    #
    #   initdb --username=postgres
    #
    # 로 실행된다.
    #
    # 이 옵션이 없으면 OS user(sherpa)가 bootstrap
    # superuser로 생성되어 pg_upgrade가 실패한다.
    # ========================================================

    initdb_args+=(
        -D "$PGDATA_NEW"
        "--username=$PGUSER_NAME"
        "--encoding=$old_encoding"
        "--lc-collate=$old_lc_collate"
        "--lc-ctype=$old_lc_ctype"
    )


    if [[ -n "$checksum_arg" ]]; then

        initdb_args+=(
            "$checksum_arg"
        )

    fi


    mkdir -p \
        "$PGDATA_NEW"


    echo
    echo "============================================================"
    echo "NEW PostgreSQL initdb Configuration"
    echo "============================================================"
    echo

    echo "NEW Version    : $PG_NEW_VERSION"

    echo "NEW PG_HOME    : $PG_HOME_NEW"

    echo "NEW PGDATA     : $PGDATA_NEW"

    echo "Superuser      : $PGUSER_NAME"

    echo "Encoding       : $old_encoding"

    echo "LC_COLLATE     : $old_lc_collate"

    echo "LC_CTYPE       : $old_lc_ctype"

    echo "Checksums      : $checksum_status"


    if [[ -n "$checksum_arg" ]]; then

        echo "Checksum Arg   : $checksum_arg"

    else

        echo "Checksum Arg   : none"

    fi


    echo


    log "initializing NEW PostgreSQL cluster"


    if [[ -n "$INITDB_EXTRA_OPTS" ]]; then

        # shellcheck disable=SC2206
        extra_opts=( $INITDB_EXTRA_OPTS )


        "$PG_HOME_NEW/bin/initdb" \
            "${initdb_args[@]}" \
            "${extra_opts[@]}"

    else

        "$PG_HOME_NEW/bin/initdb" \
            "${initdb_args[@]}"

    fi


    # --------------------------------------------------------
    # PG_VERSION Validation
    # --------------------------------------------------------

    [[ -f "$PGDATA_NEW/PG_VERSION" ]] || \
        die "NEW PG_VERSION not created after initdb"


    # --------------------------------------------------------
    # Checksum Validation
    # --------------------------------------------------------

    new_checksum="$(
        new_control_value "Data page checksum version"
    )"


    [[ "$new_checksum" =~ ^[0-9]+$ ]] || \
        die "could not read NEW checksum status after initdb"


    if [[ "$old_checksum" == "0" &&
          "$new_checksum" != "0" ]]; then

        die "checksum mismatch after initdb: OLD=disabled NEW=enabled"

    fi


    if [[ "$old_checksum" != "0" &&
          "$new_checksum" == "0" ]]; then

        die "checksum mismatch after initdb: OLD=enabled NEW=disabled"

    fi


    log "checksum verification OK"

    log "  OLD checksum version : $old_checksum"

    log "  NEW checksum version : $new_checksum"


    # --------------------------------------------------------
    # pg_upgrade용 HBA
    #
    # OLD HBA는 아직 복사하지 않는다.
    # --------------------------------------------------------

    prepare_pg_upgrade_hba


    set_new_postgresql_conf_port


    log "NEW PostgreSQL cluster initialized successfully"

    log "  PGDATA    : $PGDATA_NEW"

    log "  Superuser : $PGUSER_NAME"
}


# ============================================================
# Prepare
# ============================================================

prepare() {
    ensure_pg_password


    log "prepare step 1/4: precheck"

    precheck


    log "prepare step 2/4: build PostgreSQL $PG_NEW_VERSION and contrib extensions"

    build


    log "prepare step 3/4: backup OLD cluster"

    backup


    log "prepare step 4/4: initdb NEW PGDATA"

    initdb_new


    log "prepare complete"

    log "Next downtime steps: stop-old -> check -> upgrade -> start-new -> postcheck -> env"
}


# ============================================================
# Reinitdb
#
# 기존 NEW PGDATA는 삭제하지 않고 timestamp backup으로 이동.
# ============================================================

reinitdb_new() {
    local backup_dir


    ensure_pg_password


    if [[ -e "$PGDATA_NEW" ]]; then

        backup_dir="${PGDATA_NEW}.before_reinit_$(date +%Y%m%d_%H%M%S)"


        confirm \
            "REINITDB" \
            "This moves $PGDATA_NEW to $backup_dir and recreates it."


        mv \
            "$PGDATA_NEW" \
            "$backup_dir"


        log "moved existing NEW PGDATA to $backup_dir"

    fi


    initdb_new
}


# ============================================================
# pg_upgrade Library Error Helper
# ============================================================

show_latest_loadable_libraries() {
    local latest_file


    latest_file="$(
        find \
            "$PGDATA_NEW/pg_upgrade_output.d" \
            -name loadable_libraries.txt \
            -type f \
            2>/dev/null |
            sort |
            tail -1 || true
    )"


    if [[ -n "$latest_file" &&
          -s "$latest_file" ]]; then

        echo
        echo "Missing loadable libraries reported by pg_upgrade:"

        echo "$latest_file"

        echo "------------------------------------------------------------"


        cat "$latest_file"


        echo "------------------------------------------------------------"

        echo

        echo "Contrib module:"

        echo "  sh $0 contrib"

        echo

        echo "External extension:"

        echo "  Install matching PostgreSQL $PG_NEW_VERSION libraries first."

    fi
}


# ============================================================
# Stop OLD
# ============================================================

stop_old() {
    confirm \
        "STOP OLD" \
        "This stops the OLD PostgreSQL cluster."


    "$PG_HOME_OLD/bin/pg_ctl" \
        -D "$PGDATA_OLD" \
        -m fast \
        -w stop


    log "OLD PostgreSQL stopped successfully"
}


# ============================================================
# pg_upgrade --check
# ============================================================

upgrade_check() {
    local upgrade_args=()

    local rc


    ensure_pg_password


    [[ -x "$PG_HOME_NEW/bin/pg_upgrade" ]] || \
        die "pg_upgrade not found: $PG_HOME_NEW/bin/pg_upgrade"


    [[ -f "$PGDATA_NEW/PG_VERSION" ]] || \
        die "NEW cluster is not initialized: $PGDATA_NEW"


    #
    # check 수행 직전 local trust 보장.
    #

    prepare_pg_upgrade_hba


    mkdir -p \
        "$WORK_DIR"


    cd "$WORK_DIR"


    upgrade_args=(
        "--old-bindir=$PG_HOME_OLD/bin"
        "--new-bindir=$PG_HOME_NEW/bin"
        "--old-datadir=$PGDATA_OLD"
        "--new-datadir=$PGDATA_NEW"
        "--old-port=$OLD_PORT"
        "--new-port=$NEW_PORT"
        "--old-options=-c config_file=$PGDATA_OLD/postgresql.conf"
        "--new-options=-c config_file=$PGDATA_NEW/postgresql.conf"
        "--username=$PGUSER_NAME"
        "--jobs=$JOBS"
    )


    if [[ "$USE_LINK" == "true" ]]; then

        upgrade_args+=(
            --link
        )

    fi


    upgrade_args+=(
        --check
        --verbose
    )


    echo
    echo "============================================================"
    echo "pg_upgrade --check"
    echo "============================================================"
    echo

    echo "OLD PGDATA : $PGDATA_OLD"

    echo "NEW PGDATA : $PGDATA_NEW"

    echo "OLD PORT   : $OLD_PORT"

    echo "NEW PORT   : $NEW_PORT"

    echo "USER       : $PGUSER_NAME"

    echo "JOBS       : $JOBS"

    echo "LINK       : $USE_LINK"

    echo


    set +e


    "$PG_HOME_NEW/bin/pg_upgrade" \
        "${upgrade_args[@]}"


    rc=$?


    set -e


    if [[ "$rc" -ne 0 ]]; then

        show_latest_loadable_libraries

        exit "$rc"

    fi


    log "pg_upgrade --check completed successfully"
}


# ============================================================
# Upgrade Tuning
# ============================================================

detect_physical_cores() {
    local cores_per_socket

    local sockets


    if command -v lscpu >/dev/null 2>&1; then

        cores_per_socket="$(
            lscpu |
                awk -F: '
                    /Core\(s\) per socket:/ {
                        gsub(/[ \t]/, "", $2)
                        print $2
                        exit
                    }
                '
        )"


        sockets="$(
            lscpu |
                awk -F: '
                    /Socket\(s\):/ {
                        gsub(/[ \t]/, "", $2)
                        print $2
                        exit
                    }
                '
        )"


        if [[ "$cores_per_socket" =~ ^[1-9][0-9]*$ &&
              "$sockets" =~ ^[1-9][0-9]*$ ]]; then

            echo $((cores_per_socket * sockets))

            return 0

        fi

    fi


    if command -v nproc >/dev/null 2>&1; then

        nproc

        return 0

    fi


    getconf _NPROCESSORS_ONLN 2>/dev/null || \
        echo "unknown"
}


ask_upgrade_tuning() {
    local answer

    local jobs_answer

    local detected_cores

    local recommended_jobs


    echo
    echo "Use --link option for pg_upgrade? [y/N]"

    echo "  y: faster, but rollback is limited after NEW cluster receives writes."

    echo "  n: copies data files and requires more disk space."


    printf 'Select [y/N]: '

    read -r answer


    case "${answer,,}" in

        y|yes)

            USE_LINK="true"
            ;;


        *)

            USE_LINK="false"
            ;;

    esac


    detected_cores="$(
        detect_physical_cores
    )"


    recommended_jobs="1"


    if [[ "$detected_cores" =~ ^[1-9][0-9]*$ ]]; then

        recommended_jobs=$((detected_cores / 2))


        if (( recommended_jobs < 1 )); then

            recommended_jobs=1

        fi

    fi


    echo
    echo "Detected physical CPU cores : $detected_cores"

    echo "Recommended pg_upgrade jobs : $recommended_jobs"


    printf 'Enter jobs value [recommended: %s]: ' \
        "$recommended_jobs"


    read -r jobs_answer


    if [[ -n "$jobs_answer" ]]; then

        [[ "$jobs_answer" =~ ^[1-9][0-9]*$ ]] || \
            die "jobs must be a positive integer"


        JOBS="$jobs_answer"

    else

        JOBS="$recommended_jobs"

    fi


    save_config
}


# ============================================================
# pg_upgrade
# ============================================================

upgrade() {
    local upgrade_args=()

    local upgrade_rc


    ensure_pg_password


    ask_upgrade_tuning


    confirm \
        "UPGRADE" \
        "Ready to run pg_upgrade."


    [[ -x "$PG_HOME_NEW/bin/pg_upgrade" ]] || \
        die "pg_upgrade not found: $PG_HOME_NEW/bin/pg_upgrade"


    [[ -f "$PGDATA_NEW/PG_VERSION" ]] || \
        die "NEW cluster is not initialized: $PGDATA_NEW"


    #
    # upgrade 직전에도 trust 설정 보장.
    #

    prepare_pg_upgrade_hba


    mkdir -p \
        "$WORK_DIR"


    cd "$WORK_DIR"


    upgrade_args=(
        "--old-bindir=$PG_HOME_OLD/bin"
        "--new-bindir=$PG_HOME_NEW/bin"
        "--old-datadir=$PGDATA_OLD"
        "--new-datadir=$PGDATA_NEW"
        "--old-port=$OLD_PORT"
        "--new-port=$NEW_PORT"
        "--old-options=-c config_file=$PGDATA_OLD/postgresql.conf"
        "--new-options=-c config_file=$PGDATA_NEW/postgresql.conf"
        "--username=$PGUSER_NAME"
        "--jobs=$JOBS"
    )


    if [[ "$USE_LINK" == "true" ]]; then

        upgrade_args+=(
            --link
        )

    fi


    upgrade_args+=(
        --verbose
    )


    echo
    echo "============================================================"
    echo "pg_upgrade"
    echo "============================================================"
    echo

    echo "OLD PGDATA : $PGDATA_OLD"

    echo "NEW PGDATA : $PGDATA_NEW"

    echo "OLD PORT   : $OLD_PORT"

    echo "NEW PORT   : $NEW_PORT"

    echo "USER       : $PGUSER_NAME"

    echo "JOBS       : $JOBS"

    echo "LINK       : $USE_LINK"

    echo


    set +e


    "$PG_HOME_NEW/bin/pg_upgrade" \
        "${upgrade_args[@]}" \
        2>&1 |
        tee "$WORK_DIR/pg_upgrade.log"


    upgrade_rc="${PIPESTATUS[0]}"


    set -e


    if [[ "$upgrade_rc" -ne 0 ]]; then

        show_latest_loadable_libraries

        exit "$upgrade_rc"

    fi


    log "pg_upgrade completed successfully"


    # --------------------------------------------------------
    # 실제 catalog 이관이 끝난 후 OLD 인증 설정 적용.
    # --------------------------------------------------------

    apply_old_auth_to_new


    log "authentication configuration finalized"
}


# ============================================================
# Start NEW
# ============================================================

start_new() {
    [[ -f "$PGDATA_NEW/PG_VERSION" ]] || \
        die "NEW cluster is not initialized: $PGDATA_NEW"


    #
    # 혹시 pg_upgrade trust 설정이 남아 있다면
    # 기동 전에 OLD 인증 설정으로 자동 복구.
    #

    if pg_upgrade_hba_is_active; then

        log "pg_upgrade trust configuration detected before NEW startup"

        log "restoring OLD authentication configuration"


        apply_old_auth_to_new

    fi


    set_new_postgresql_conf_port


    "$PG_HOME_NEW/bin/pg_ctl" \
        -D "$PGDATA_NEW" \
        -l "$PGDATA_NEW/server.log" \
        -w start


    log "NEW PostgreSQL started successfully"
}


# ============================================================
# Analyze Script
# ============================================================

find_analyze_new_cluster_script() {
    local analyze_script


    if [[ -x "$WORK_DIR/analyze_new_cluster.sh" ]]; then

        echo "$WORK_DIR/analyze_new_cluster.sh"

        return 0

    fi


    analyze_script="$(
        find \
            "$BASE" \
            -name analyze_new_cluster.sh \
            -type f \
            2>/dev/null |
            sort |
            tail -1 || true
    )"


    if [[ -n "$analyze_script" ]]; then

        chmod u+x \
            "$analyze_script" \
            2>/dev/null || true


        echo "$analyze_script"

    fi
}


# ============================================================
# Postcheck
# ============================================================

postcheck() {
    local analyze_script


    ensure_pg_password


    "$PG_HOME_NEW/bin/psql" \
        -p "$NEW_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "select version();"


    "$PG_HOME_NEW/bin/psql" \
        -p "$NEW_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show data_directory;"


    "$PG_HOME_NEW/bin/psql" \
        -p "$NEW_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show port;"


    "$PG_HOME_NEW/bin/psql" \
        -p "$NEW_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show listen_addresses;"


    "$PG_HOME_NEW/bin/psql" \
        -p "$NEW_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "show data_checksums;"


    "$PG_HOME_NEW/bin/psql" \
        -p "$NEW_PORT" \
        -U "$PGUSER_NAME" \
        -d postgres \
        -c "
            select
                extname,
                extversion
            from pg_extension
            order by extname;
        "


    analyze_script="$(
        find_analyze_new_cluster_script
    )"


    if [[ -n "$analyze_script" &&
          -x "$analyze_script" ]]; then

        log "running analyze script: $analyze_script"


        "$analyze_script"

    else

        log "analyze_new_cluster.sh not found"


        echo
        echo "Run manually:"
        echo
        echo "  $PG_HOME_NEW/bin/vacuumdb -p $NEW_PORT -U $PGUSER_NAME --all --analyze-in-stages"

    fi
}


# ============================================================
# Update Environment
# ============================================================

archive_old_postgresql_directories() {
    local old_version

    local old_home_archive

    local old_data_archive

    local old_home_real

    local old_data_real


    old_version="$(
        "$PG_HOME_OLD/bin/postgres" --version | awk '{print $NF}'
    )"


    [[ "$old_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || \
        die "could not detect OLD PostgreSQL full version"


    old_home_archive="$BASE/pgsql_$old_version"

    old_data_archive="$BASE/data_$old_version"


    [[ "$old_home_archive" != "$PG_HOME_NEW" ]] || \
        die "OLD PG_HOME archive conflicts with NEW PG_HOME: $old_home_archive"


    [[ "$old_data_archive" != "$PGDATA_NEW" ]] || \
        die "OLD PGDATA archive conflicts with NEW PGDATA: $old_data_archive"


    if [[ ! -e "$PG_HOME_OLD" &&
          ! -e "$PGDATA_OLD" &&
          -d "$old_home_archive" &&
          -d "$old_data_archive" ]]; then

        log "OLD PostgreSQL directories already archived"

        log "  PG_HOME : $old_home_archive"

        log "  PGDATA  : $old_data_archive"

        return 0

    fi


    [[ -x "$PG_HOME_OLD/bin/pg_ctl" ]] || \
        die "OLD pg_ctl not found before archive: $PG_HOME_OLD/bin/pg_ctl"


    if "$PG_HOME_OLD/bin/pg_ctl" \
        -D "$PGDATA_OLD" \
        status >/dev/null 2>&1; then

        die "OLD PostgreSQL is running; stop it before archiving"

    fi


    [[ -x "$PG_HOME_NEW/bin/pg_ctl" ]] || \
        die "NEW pg_ctl not found: $PG_HOME_NEW/bin/pg_ctl"


    if ! "$PG_HOME_NEW/bin/pg_ctl" \
        -D "$PGDATA_NEW" \
        status >/dev/null 2>&1; then

        die "NEW PostgreSQL is not running; run start-new and postcheck before env"

    fi


    [[ -d "$PG_HOME_OLD" ]] || \
        die "OLD PG_HOME not found: $PG_HOME_OLD"


    [[ -d "$PGDATA_OLD" ]] || \
        die "OLD PGDATA not found: $PGDATA_OLD"


    [[ ! -e "$old_home_archive" ]] || \
        die "OLD PG_HOME archive target already exists: $old_home_archive"


    [[ ! -e "$old_data_archive" ]] || \
        die "OLD PGDATA archive target already exists: $old_data_archive"


    old_home_real="$(readlink -f "$PG_HOME_OLD")"

    old_data_real="$(readlink -f "$PGDATA_OLD")"


    case "$old_data_real/" in

        "$old_home_real"/*)

            mv \
                "$PGDATA_OLD" \
                "$old_data_archive"


            log "archived OLD PGDATA: $old_data_archive"


            mv \
                "$PG_HOME_OLD" \
                "$old_home_archive"


            log "archived OLD PG_HOME: $old_home_archive"
            ;;


        *)

            mv \
                "$PG_HOME_OLD" \
                "$old_home_archive"


            log "archived OLD PG_HOME: $old_home_archive"


            mv \
                "$PGDATA_OLD" \
                "$old_data_archive"


            log "archived OLD PGDATA: $old_data_archive"
            ;;

    esac
}


update_env() {
    local shell_file

    local backup_suffix

    local disabled_marker

    local tmp_file


    backup_suffix="before_pg${PG_NEW_VERSION}_upgrade_$(date +%Y%m%d_%H%M%S)"

    disabled_marker="# Disabled by postgresql_major_upgrade.sh $backup_suffix:"


    archive_old_postgresql_directories


    [[ -f "$BASH_PROFILE" ]] || \
        touch "$BASH_PROFILE"


    for shell_file in \
        "$BASH_PROFILE" \
        "$HOME/.bashrc"

    do

        [[ -f "$shell_file" ]] || \
            continue


        cp -p \
            "$shell_file" \
            "$shell_file.$backup_suffix"


        log "backup saved: $shell_file.$backup_suffix"


        sed -i \
            '/# Added by postgresql_major_upgrade.sh/,/# End postgresql_major_upgrade.sh/d' \
            "$shell_file"


        tmp_file="${shell_file}.postgresql_major_upgrade.$$"


        awk \
            -v marker="$disabled_marker" \
            -v old_home="$PG_HOME_OLD" \
            -v new_home="$PG_HOME_NEW" \
            -v legacy_home="$BASE/pgsql" '
            function is_pg_export(line) {
                return line ~ /^[[:space:]]*export[[:space:]]+(PG_HOME|PGHOME|PGDATA|PGPORT|PG_PORT)=/
            }

            {
                if (is_pg_export($0)) {
                    print marker " " $0
                } else if ($0 ~ /^[[:space:]]*export[[:space:]]+PATH=/) {
                    gsub(old_home "/bin", new_home "/bin")
                    gsub(legacy_home "/bin", new_home "/bin")
                    print
                } else if ($0 ~ /^[[:space:]]*export[[:space:]]+LD_LIBRARY_PATH=/) {
                    gsub(old_home "/lib", new_home "/lib")
                    gsub(legacy_home "/lib", new_home "/lib")
                    print
                } else {
                    print
                }
            }
        ' "$shell_file" > "$tmp_file"


        chmod \
            --reference="$shell_file" \
            "$tmp_file"


        mv \
            "$tmp_file" \
            "$shell_file"

    done


    cat >> "$BASH_PROFILE" <<EOF

# Added by postgresql_major_upgrade.sh
export PG_HOME=$PG_HOME_NEW
export PGHOME=$PG_HOME_NEW
export PGDATA=$PGDATA_NEW
export PGPORT=$NEW_PORT
export PG_PORT=$NEW_PORT
case ":\$PATH:" in *":\$PG_HOME/bin:"*) ;; *) export PATH=\$PG_HOME/bin:\$PATH ;; esac
case ":\${LD_LIBRARY_PATH:-}:" in *":\$PG_HOME/lib:"*) ;; *) export LD_LIBRARY_PATH=\$PG_HOME/lib:\${LD_LIBRARY_PATH:-} ;; esac
# End postgresql_major_upgrade.sh
EOF


    log "updated $BASH_PROFILE"


    echo
    echo "Apply:"
    echo
    echo "  source $BASH_PROFILE"

    echo
    echo "Verify:"
    echo
    echo "  which psql"
    echo "  psql --version"
}


# ============================================================
# Next Step Hint
# ============================================================

next_step_hint() {
    case "$STEP" in

        prepare)

            echo "Next step: sh $0 stop-old"
            ;;


        stop-old)

            echo "Next step: sh $0 check"
            ;;


        check)

            echo "Next step: sh $0 upgrade"
            ;;


        upgrade)

            echo "Next step: sh $0 start-new"
            ;;


        start-new)

            echo "Next step: sh $0 postcheck"
            ;;


        postcheck)

            echo "Next step: sh $0 env"
            ;;


        env)

            echo "Upgrade flow complete."

            echo "Run: source $BASH_PROFILE"
            ;;

    esac
}


# ============================================================
# Help
#
# 정상 Upgrade 필수 단계만 노출.
# Utility step은 기능상 사용 가능하지만
# Typical에는 표시하지 않는다.
# ============================================================

usage() {
    cat <<EOF
Usage:
  sh $0 <step> [options]

Options:
  --new-version VERSION
  --new-port PORT
  --old-port PORT
  --base PATH

Required Upgrade Flow:

  1. prepare
     Precheck + Build + Backup + initdb

  2. stop-old
     Stop OLD PostgreSQL

  3. check
     Run pg_upgrade --check

  4. upgrade
     Run pg_upgrade

  5. start-new
     Start NEW PostgreSQL

  6. postcheck
     Validate NEW PostgreSQL and analyze

  7. env
     Update PostgreSQL shell environment

Typical:

  sh $0 prepare
  sh $0 stop-old
  sh $0 check
  sh $0 upgrade
  sh $0 start-new
  sh $0 postcheck
  sh $0 env

Example:

  sh $0 --old-port 5432 prepare
EOF
}


# ============================================================
# Main
# ============================================================

parse_args "$@"

finalize_config


case "$STEP" in

    help|-h|--help)

        usage
        ;;


    config)

        show_config
        ;;


    precheck)

        precheck
        ;;


    build)

        build
        ;;


    contrib)

        install_contrib
        ;;


    prepare)

        prepare
        ;;


    backup)

        backup
        ;;


    initdb)

        initdb_new
        ;;


    reinitdb)

        reinitdb_new
        ;;


    stop-old)

        stop_old
        ;;


    check)

        upgrade_check
        ;;


    upgrade)

        upgrade
        ;;


    start-new)

        start_new
        ;;


    postcheck)

        postcheck
        ;;


    env)

        update_env
        ;;


    *)

        usage

        exit 1
        ;;

esac


next_step_hint
