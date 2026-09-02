#!/bin/sh

if [ "${POSTGRESQL_MINOR_BASH_REEXEC:-0}" != 1 ]; then
    POSTGRESQL_MINOR_BASH_REEXEC=1 exec /usr/bin/env bash "$0" "$@"
fi

set -Eeuo pipefail

BASE="${BASE:-$HOME}"
PG_HOME_OLD="${PG_HOME_OLD:-${PG_HOME:-${PGHOME:-}}}"
PG_HOME_NEW="${PG_HOME_NEW:-}"
PGDATA_OLD="${PGDATA_OLD:-${PGDATA:-}}"
PGDATA_NEW="${PGDATA_NEW:-}"
PGPORT="${PGPORT:-${PG_PORT:-}}"
PGUSER_NAME="${PGUSER_NAME:-postgres}"
PGPASSWORD="${PGPASSWORD:-}"
TARGET_VERSION="${TARGET_VERSION:-}"
SOURCE_TAR="${SOURCE_TAR:-}"
TARGET_VERSION_EXPLICIT="${TARGET_VERSION:+true}"
SOURCE_TAR_EXPLICIT="${SOURCE_TAR:+true}"
TARGET_VERSION_INPUT="$TARGET_VERSION"
SOURCE_TAR_INPUT="$SOURCE_TAR"
SOURCE_DIR="${SOURCE_DIR:-}"
JOBS="${JOBS:-}"
ENABLE_OPENSSL="${ENABLE_OPENSSL:-true}"
RUN_MAKE_CHECK="${RUN_MAKE_CHECK:-true}"
BASH_PROFILE="${BASH_PROFILE:-$HOME/.bash_profile}"
STATE_FILE="${STATE_FILE:-$BASE/.postgresql_minor_upgrade.conf}"
WORK_DIR="${WORK_DIR:-$BASE/minor_upgrade_work}"
UPGRADE_MODE="${UPGRADE_MODE:-}"
PGDATA_ACTIVE="${PGDATA_ACTIVE:-}"
PGDATA_BACKUP="${PGDATA_BACKUP:-}"
STEP=""

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
    [[ "$answer" == "$expected" ]] || die "cancelled"
}

ensure_password() {
    if [[ -n "$PGPASSWORD" ]]; then
        export PGPASSWORD
        return
    fi

    printf 'PostgreSQL password for %s: ' "$PGUSER_NAME"
    read -r -s PGPASSWORD
    echo
    [[ -n "$PGPASSWORD" ]] || die "PostgreSQL password is empty"
    export PGPASSWORD
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-version)
                [[ $# -ge 2 ]] || die "--target-version requires a value"
                TARGET_VERSION="$2"
                TARGET_VERSION_EXPLICIT=true
                shift 2
                ;;
            --target-version=*)
                TARGET_VERSION="${1#*=}"
                TARGET_VERSION_EXPLICIT=true
                shift
                ;;
            --source-tar)
                [[ $# -ge 2 ]] || die "--source-tar requires a value"
                SOURCE_TAR="$2"
                SOURCE_TAR_EXPLICIT=true
                shift 2
                ;;
            --source-tar=*)
                SOURCE_TAR="${1#*=}"
                SOURCE_TAR_EXPLICIT=true
                shift
                ;;
            --base)
                [[ $# -ge 2 ]] || die "--base requires a value"
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
                [[ -z "$STEP" ]] || die "multiple steps specified"
                STEP="$1"
                shift
                ;;
        esac
    done

    STEP="${STEP:-help}"
}

version_key() {
    local version="$1"
    local first second

    IFS=. read -r first second _ <<< "$version"

    if (( first < 10 )); then
        printf '%s.%s\n' "$first" "${second:-0}"
    else
        printf '%s\n' "$first"
    fi
}

version_gt() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]
}

detect_old_environment() {
    local profile_value

    if [[ -z "$PG_HOME_OLD" && -f "$BASH_PROFILE" ]]; then
        profile_value="$(/usr/bin/env bash --noprofile --norc -c 'source "$1" >/dev/null 2>&1 || true; printf "%s" "${PG_HOME:-${PGHOME:-}}"' _ "$BASH_PROFILE")"
        PG_HOME_OLD="$profile_value"
    fi

    if [[ -z "$PGDATA_OLD" && -f "$BASH_PROFILE" ]]; then
        PGDATA_OLD="$(/usr/bin/env bash --noprofile --norc -c 'source "$1" >/dev/null 2>&1 || true; printf "%s" "${PGDATA:-}"' _ "$BASH_PROFILE")"
    fi

    if [[ -z "$PGPORT" && -f "$BASH_PROFILE" ]]; then
        PGPORT="$(/usr/bin/env bash --noprofile --norc -c 'source "$1" >/dev/null 2>&1 || true; printf "%s" "${PGPORT:-${PG_PORT:-}}"' _ "$BASH_PROFILE")"
    fi

    [[ -n "$PG_HOME_OLD" ]] || die "could not detect PG_HOME_OLD"
    [[ -n "$PGDATA_OLD" ]] || die "could not detect OLD PGDATA"
    [[ -n "$PGPORT" ]] || die "could not detect PGPORT"
    [[ -x "$PG_HOME_OLD/bin/postgres" ]] || die "OLD postgres not found"
    [[ -x "$PG_HOME_OLD/bin/pg_ctl" ]] || die "OLD pg_ctl not found"
    [[ -f "$PGDATA_OLD/PG_VERSION" ]] || die "invalid OLD PGDATA: $PGDATA_OLD"
}

detect_target() {
    local tar_file version old_key selection index
    local candidates=()

    old_key="$(version_key "$(old_binary_version)")"

    if [[ -n "$SOURCE_TAR" ]]; then
        [[ -f "$SOURCE_TAR" ]] || die "source tar not found: $SOURCE_TAR"
        tar_file="$SOURCE_TAR"
        version="$(basename "$tar_file" | sed -E 's/^postgresql-([0-9]+([.][0-9]+)+)[.]tar([.](gz|bz2|xz))?$/\1/')"
        [[ "$version" =~ ^[0-9]+([.][0-9]+)+$ ]] || die "cannot parse source version: $tar_file"
        TARGET_VERSION="${TARGET_VERSION:-$version}"
    elif [[ -n "$TARGET_VERSION" ]]; then
        for tar_file in "$BASE/postgresql-$TARGET_VERSION.tar"*; do
            [[ -f "$tar_file" ]] || continue
            SOURCE_TAR="$tar_file"
            break
        done
        [[ -n "$SOURCE_TAR" ]] || die "source tar for $TARGET_VERSION not found under $BASE"
    else
        for tar_file in "$BASE"/postgresql-*.tar "$BASE"/postgresql-*.tar.gz "$BASE"/postgresql-*.tar.bz2 "$BASE"/postgresql-*.tar.xz; do
            [[ -f "$tar_file" ]] || continue
            version="$(basename "$tar_file" | sed -E 's/^postgresql-([0-9]+([.][0-9]+)+)[.]tar([.](gz|bz2|xz))?$/\1/')"
            [[ "$version" =~ ^[0-9]+([.][0-9]+)+$ ]] || continue
            [[ "$(version_key "$version")" == "$old_key" ]] || continue
            candidates+=("$version|$tar_file")
        done
        [[ ${#candidates[@]} -gt 0 ]] || die "no compatible PostgreSQL source tar found under $BASE"

        mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort -t '|' -k1,1V)
        echo "Available PostgreSQL $old_key source files:"
        for index in "${!candidates[@]}"; do
            printf '  %d) PostgreSQL %s - %s\n' "$((index + 1))" "${candidates[$index]%%|*}" "${candidates[$index]#*|}"
        done
        printf 'Select source file [1-%d]: ' "${#candidates[@]}"
        read -r selection
        [[ "$selection" =~ ^[1-9][0-9]*$ ]] || die "invalid selection: $selection"
        (( selection <= ${#candidates[@]} )) || die "selection out of range: $selection"

        TARGET_VERSION="${candidates[$((selection - 1))]%%|*}"
        SOURCE_TAR="${candidates[$((selection - 1))]#*|}"
    fi

    SOURCE_DIR="${SOURCE_DIR:-$BASE/postgresql-$TARGET_VERSION}"
    PG_HOME_NEW="${PG_HOME_NEW:-$BASE/pgsql_$TARGET_VERSION}"
    if [[ -z "$PGDATA_NEW" || "$PGDATA_NEW" == "$BASE/data_$TARGET_VERSION" ]]; then
        PGDATA_NEW="$PG_HOME_NEW/data"
    fi
}

load_state() {
    [[ -f "$STATE_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

save_state() {
    umask 077
    cat > "$STATE_FILE" <<EOF
BASE=$(printf '%q' "$BASE")
PG_HOME_OLD=$(printf '%q' "$PG_HOME_OLD")
PG_HOME_NEW=$(printf '%q' "$PG_HOME_NEW")
PGDATA_OLD=$(printf '%q' "$PGDATA_OLD")
PGDATA_NEW=$(printf '%q' "$PGDATA_NEW")
PGPORT=$(printf '%q' "$PGPORT")
PGUSER_NAME=$(printf '%q' "$PGUSER_NAME")
TARGET_VERSION=$(printf '%q' "$TARGET_VERSION")
SOURCE_TAR=$(printf '%q' "$SOURCE_TAR")
SOURCE_DIR=$(printf '%q' "$SOURCE_DIR")
JOBS=$(printf '%q' "$JOBS")
ENABLE_OPENSSL=$(printf '%q' "$ENABLE_OPENSSL")
RUN_MAKE_CHECK=$(printf '%q' "$RUN_MAKE_CHECK")
BASH_PROFILE=$(printf '%q' "$BASH_PROFILE")
WORK_DIR=$(printf '%q' "$WORK_DIR")
UPGRADE_MODE=$(printf '%q' "$UPGRADE_MODE")
PGDATA_ACTIVE=$(printf '%q' "$PGDATA_ACTIVE")
PGDATA_BACKUP=$(printf '%q' "$PGDATA_BACKUP")
EOF
}

finalize_config() {
    detect_old_environment

    if [[ "$STEP" == prepare && "$TARGET_VERSION_EXPLICIT" != true && "$SOURCE_TAR_EXPLICIT" != true ]]; then
        TARGET_VERSION=""
        SOURCE_TAR=""
        SOURCE_DIR=""
        PG_HOME_NEW=""
        PGDATA_NEW=""
    fi
    detect_target

    JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "invalid JOBS: $JOBS"

    mkdir -p "$WORK_DIR"
    save_state
}

psql_old() {
    "$PG_HOME_OLD/bin/psql" -X -v ON_ERROR_STOP=1 -p "$PGPORT" -U "$PGUSER_NAME" "$@"
}

psql_new() {
    "$PG_HOME_NEW/bin/psql" -X -v ON_ERROR_STOP=1 -p "$PGPORT" -U "$PGUSER_NAME" "$@"
}

old_binary_version() {
    "$PG_HOME_OLD/bin/postgres" --version | awk '{print $NF}'
}

precheck_binary_versions() {
    local binary_version

    binary_version="$(old_binary_version)"
    [[ "$(version_key "$binary_version")" == "$(version_key "$TARGET_VERSION")" ]] || die "not a minor upgrade: $binary_version -> $TARGET_VERSION"
    version_gt "$TARGET_VERSION" "$binary_version" || die "target must be newer: $binary_version -> $TARGET_VERSION"

    log "binary upgrade validated: $binary_version -> $TARGET_VERSION"
}

precheck_server() {
    local binary_version server_version

    ensure_password
    binary_version="$(old_binary_version)"
    server_version="$(psql_old -d postgres -Atc 'show server_version')"

    [[ "$binary_version" == "$server_version" ]] || die "OLD binary/server mismatch: $binary_version / $server_version"

    [[ "$(psql_old -d postgres -Atc 'show data_directory')" == "$PGDATA_OLD" ]] || die "running data_directory mismatch"
    [[ "$(psql_old -d postgres -Atc 'show port')" == "$PGPORT" ]] || die "running port mismatch"

    log "minor upgrade validated: $binary_version -> $TARGET_VERSION"
}

package_manager() {
    if command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v zypper >/dev/null 2>&1; then echo zypper
    else echo none
    fi
}

required_packages() {
    local manager="$1"
    local configure_text="$2"

    case "$manager" in
        dnf|yum)
            printf '%s\n' gcc make readline-devel zlib-devel openssl-devel
            [[ "$configure_text" == *--with-icu* ]] && echo libicu-devel
            [[ "$configure_text" == *--with-libxml* ]] && echo libxml2-devel
            [[ "$configure_text" == *--with-libxslt* ]] && echo libxslt-devel
            [[ "$configure_text" == *--with-lz4* ]] && echo lz4-devel
            [[ "$configure_text" == *--with-zstd* ]] && echo libzstd-devel
            [[ "$configure_text" == *--with-ldap* ]] && echo openldap-devel
            [[ "$configure_text" == *--with-pam* ]] && echo pam-devel
            [[ "$configure_text" == *--with-gssapi* ]] && echo krb5-devel
            ;;
        zypper)
            printf '%s\n' gcc make readline-devel zlib-devel libopenssl-devel
            [[ "$configure_text" == *--with-icu* ]] && echo libicu-devel
            [[ "$configure_text" == *--with-libxml* ]] && echo libxml2-devel
            [[ "$configure_text" == *--with-libxslt* ]] && echo libxslt-devel
            [[ "$configure_text" == *--with-lz4* ]] && echo liblz4-devel
            [[ "$configure_text" == *--with-zstd* ]] && echo libzstd-devel
            [[ "$configure_text" == *--with-ldap* ]] && echo openldap2-devel
            [[ "$configure_text" == *--with-pam* ]] && echo pam-devel
            [[ "$configure_text" == *--with-gssapi* ]] && echo krb5-devel
            ;;
        apt)
            printf '%s\n' build-essential libreadline-dev zlib1g-dev libssl-dev
            [[ "$configure_text" == *--with-icu* ]] && echo libicu-dev
            [[ "$configure_text" == *--with-libxml* ]] && echo libxml2-dev
            [[ "$configure_text" == *--with-libxslt* ]] && echo libxslt1-dev
            [[ "$configure_text" == *--with-lz4* ]] && echo liblz4-dev
            [[ "$configure_text" == *--with-zstd* ]] && echo libzstd-dev
            [[ "$configure_text" == *--with-ldap* ]] && echo libldap2-dev
            [[ "$configure_text" == *--with-pam* ]] && echo libpam0g-dev
            [[ "$configure_text" == *--with-gssapi* ]] && echo libkrb5-dev
            ;;
    esac
}

check_dependencies() {
    local manager configure_text pkg answer
    local missing=()

    manager="$(package_manager)"
    configure_text="$($PG_HOME_OLD/bin/pg_config --configure)"
    [[ "$ENABLE_OPENSSL" == true ]] && configure_text="$configure_text --with-openssl"

    [[ "$manager" != none ]] || die "supported package manager not found"

    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        if [[ "$manager" == apt ]]; then
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
        else
            rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
        fi
    done < <(required_packages "$manager" "$configure_text" | awk '!seen[$0]++')

    [[ ${#missing[@]} -gt 0 ]] || { log "build dependencies OK"; return; }

    echo "Missing build packages: ${missing[*]}"
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Run as root:"
        [[ "$manager" == apt ]] && echo "  apt-get install -y ${missing[*]}" || echo "  $manager install -y ${missing[*]}"
        die "build dependencies are missing"
    fi

    printf 'Install missing packages now? [y/N]: '
    read -r answer
    [[ "${answer,,}" =~ ^(y|yes)$ ]] || die "package installation cancelled"
    if [[ "$manager" == apt ]]; then
        apt-get install -y "${missing[@]}"
    elif [[ "$manager" == zypper ]]; then
        zypper --non-interactive install "${missing[@]}"
    else
        "$manager" install -y "${missing[@]}"
    fi
}

configure_args() {
    local raw arg
    local inherited=()
    local has_openssl=false

    raw="$($PG_HOME_OLD/bin/pg_config --configure)"
    eval "inherited=($raw)"

    printf '%s\0' "--prefix=$PG_HOME_NEW"
    for arg in "${inherited[@]}"; do
        case "$arg" in
            --prefix=*) ;;
            --with-openssl) has_openssl=true; printf '%s\0' "$arg" ;;
            *) printf '%s\0' "$arg" ;;
        esac
    done
    [[ "$ENABLE_OPENSSL" == true && "$has_openssl" == false ]] && printf '%s\0' --with-openssl
}

build_new() {
    local args=()
    local source_path base_path

    check_dependencies

    if [[ ! -x "$SOURCE_DIR/configure" || ! -f "$SOURCE_DIR/GNUmakefile.in" ]]; then
        [[ ! -e "$SOURCE_DIR" || -d "$SOURCE_DIR" ]] || die "source path is not a directory: $SOURCE_DIR"
        if [[ -e "$SOURCE_DIR" || -L "$SOURCE_DIR" ]]; then
            base_path="$(cd -- "$BASE" && pwd -P)" || die "cannot resolve BASE: $BASE"
            source_path="$(readlink -m -- "$SOURCE_DIR")" || die "cannot resolve SOURCE_DIR: $SOURCE_DIR"
            [[ "$TARGET_VERSION" =~ ^[0-9]+([.][0-9]+)+$ &&
               "$source_path" == "${base_path%/}/postgresql-$TARGET_VERSION" &&
               ! -L "${SOURCE_DIR%/}" ]] || die "unsafe source removal path: $SOURCE_DIR"
            log "removing incomplete source directory: $source_path"
            rm -rf -- "$source_path" || die "failed to remove incomplete source directory: $source_path"
        fi
        tar -xf "$SOURCE_TAR" -C "$BASE"
    fi
    [[ -x "$SOURCE_DIR/configure" ]] || die "source extraction failed: $SOURCE_DIR/configure not found"
    [[ -f "$SOURCE_DIR/GNUmakefile.in" ]] || die "source extraction failed: $SOURCE_DIR/GNUmakefile.in not found"

    cd "$SOURCE_DIR"
    [[ ! -f config.status ]] || make distclean
    mapfile -d '' -t args < <(configure_args)

    ./configure "${args[@]}"
    make -j "$JOBS"
    [[ "$RUN_MAKE_CHECK" != true ]] || make check
    make install
    make -C contrib -j "$JOBS"
    make -C contrib install

    [[ "$($PG_HOME_NEW/bin/postgres --version | awk '{print $NF}')" == "$TARGET_VERSION" ]] || die "NEW binary version mismatch"
    "$PG_HOME_NEW/bin/pg_config" --configure
}

check_required_libraries() {
    local db library
    local failed=0

    ensure_password
    while IFS= read -r db; do
        while IFS= read -r library; do
            [[ -n "$library" ]] || continue
            library="${library#\$libdir/}"
            [[ -f "$PG_HOME_NEW/lib/$library.so" || -f "$PG_HOME_NEW/lib/$library" ]] || {
                echo "Missing NEW library: database=$db library=$library"
                failed=1
            }
        done < <(psql_old -d "$db" -Atc "select distinct probin from pg_proc where probin like '\$libdir/%' order by 1")
    done < <(psql_old -d postgres -Atc "select datname from pg_database where datallowconn and not datistemplate order by 1")

    (( failed == 0 )) || die "install missing external extension libraries before upgrade"
}

backup_metadata() {
    local backup_dir="$WORK_DIR/backup_$(date +%Y%m%d_%H%M%S)"
    local settings_file="$WORK_DIR/postgresql_settings.before"
    mkdir -p "$backup_dir"
    cp -p "$PGDATA_OLD/postgresql.conf" "$backup_dir/"
    [[ ! -f "$PGDATA_OLD/pg_hba.conf" ]] || cp -p "$PGDATA_OLD/pg_hba.conf" "$backup_dir/"
    [[ ! -f "$PGDATA_OLD/pg_ident.conf" ]] || cp -p "$PGDATA_OLD/pg_ident.conf" "$backup_dir/"
    "$PG_HOME_OLD/bin/pg_dumpall" -p "$PGPORT" -U "$PGUSER_NAME" --globals-only > "$backup_dir/globals.sql"
    psql_old -d postgres -A -t -c "
        select name || ' = ' || quote_literal(setting)
        from pg_settings
        where source = 'configuration file'
          and name not in (
              'data_directory', 'config_file', 'hba_file', 'ident_file',
              'external_pid_file', 'ssl_cert_file', 'ssl_key_file',
              'ssl_ca_file', 'ssl_crl_file'
          )
        order by name;
    " > "$settings_file"
    log "metadata backup saved: $backup_dir"
    log "active PostgreSQL settings saved: $settings_file"
}

prepare() {
    precheck_binary_versions
    precheck_server
    build_new
    check_required_libraries
    backup_metadata
    log "prepare complete; database remained online"
    echo
    echo "NEXT: sh $0 upgrade"
    echo "NOTICE: the upgrade step stops PostgreSQL briefly and asks for MINOR UPGRADE confirmation."
}

human_size_kb() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --from-unit=1024 "$1"
    else
        printf '%s KB\n' "$1"
    fi
}

check_copy_space() {
    local destination="$1"
    local label="$2"
    local required_kb available_kb safety_kb parent

    parent="$(dirname "$destination")"
    [[ -d "$parent" ]] || mkdir -p "$parent"

    required_kb="$(du -sk "$PGDATA_OLD" | awk '{print $1}')"
    available_kb="$(df -Pk "$parent" | awk 'NR==2 {print $4}')"
    safety_kb=$((required_kb + required_kb / 10))

    echo
    echo "============================================================"
    echo "PGDATA Capacity Check - $label"
    echo "============================================================"
    printf 'Current PGDATA size : %s\n' "$(human_size_kb "$required_kb")"
    printf 'Required free space : %s (PGDATA + 10%%)\n' "$(human_size_kb "$safety_kb")"
    printf 'Available space     : %s\n' "$(human_size_kb "$available_kb")"
    printf 'Destination         : %s\n' "$destination"
    echo
    echo "NOTICE: A full PGDATA copy can require substantial disk space."
    echo "        Verify filesystem capacity before continuing, especially for large databases."

    (( available_kb >= safety_kb )) || \
        die "insufficient disk space for $label: required=${safety_kb}KB available=${available_kb}KB"
}

prepare_new_data_directory() {
    [[ "$PGDATA_NEW" != "$PGDATA_OLD" ]] || die "OLD and NEW PGDATA must be different"
    [[ ! -e "$PGDATA_NEW" ]] || die "NEW PGDATA already exists: $PGDATA_NEW"

    mkdir -p "$PGDATA_NEW"
    if ! cp -a "$PGDATA_OLD/." "$PGDATA_NEW/"; then
        mv "$PGDATA_NEW" "$PGDATA_NEW.copy_failed_$(date +%Y%m%d_%H%M%S)" || true
        die "failed to copy OLD PGDATA; partial copy was preserved for inspection"
    fi

    log "OLD PGDATA preserved: $PGDATA_OLD"
    log "NEW PGDATA copied: $PGDATA_NEW"
}

prepare_pgdata_backup() {
    [[ -n "$PGDATA_BACKUP" ]] || die "PGDATA backup path is empty"
    [[ ! -e "$PGDATA_BACKUP" ]] || die "PGDATA backup path already exists: $PGDATA_BACKUP"

    mkdir -p "$PGDATA_BACKUP"
    if ! cp -a "$PGDATA_OLD/." "$PGDATA_BACKUP/"; then
        mv "$PGDATA_BACKUP" "$PGDATA_BACKUP.copy_failed_$(date +%Y%m%d_%H%M%S)" || true
        die "failed to back up OLD PGDATA; partial backup was preserved for inspection"
    fi

    log "PGDATA backup completed: $PGDATA_BACKUP"
}

select_upgrade_mode() {
    local selection timestamp

    echo
    echo "============================================================"
    echo "PostgreSQL Minor Upgrade Mode"
    echo "============================================================"
    printf 'Current version : %s\n' "$(old_binary_version)"
    printf 'Target version  : %s\n' "$TARGET_VERSION"
    printf 'OLD PG_HOME     : %s\n' "$PG_HOME_OLD"
    printf 'NEW PG_HOME     : %s\n' "$PG_HOME_NEW"
    printf 'OLD PGDATA      : %s\n' "$PGDATA_OLD"
    echo
    echo "1) Binary only"
    echo "   - Upgrade PostgreSQL binaries only."
    echo "   - Start the existing PGDATA with the new PostgreSQL binary."
    echo "   - No full PGDATA copy or backup is created."
    echo
    echo "2) Binary + PGDATA backup"
    echo "   - Upgrade PostgreSQL binaries and create a full backup of the existing PGDATA."
    echo "   - Start the original PGDATA with the new PostgreSQL binary."
    echo "   - WARNING: Requires additional disk space approximately equal to PGDATA size."
    echo "   - Backup time is included in database downtime."
    echo
    echo "3) Binary + PGDATA copy & switch"
    echo "   - Upgrade PostgreSQL binaries and copy PGDATA to the new versioned path."
    echo "   - Start the copied PGDATA with the new PostgreSQL binary."
    echo "   - WARNING: Requires additional disk space approximately equal to PGDATA size."
    echo "   - Copy time is included in database downtime."
    echo
    printf 'Select [1-3]: '
    read -r selection

    case "$selection" in
        1)
            UPGRADE_MODE="binary"
            PGDATA_ACTIVE="$PGDATA_OLD"
            PGDATA_BACKUP=""
            ;;
        2)
            UPGRADE_MODE="backup"
            PGDATA_ACTIVE="$PGDATA_OLD"
            timestamp="$(date +%Y%m%d_%H%M%S)"
            PGDATA_BACKUP="$BASE/backup_pg_minor_$(old_binary_version)_$timestamp"
            check_copy_space "$PGDATA_BACKUP" "PGDATA backup"
            ;;
        3)
            UPGRADE_MODE="copy"
            PGDATA_ACTIVE="$PGDATA_NEW"
            PGDATA_BACKUP=""
            check_copy_space "$PGDATA_NEW" "NEW PGDATA copy"
            ;;
        *)
            die "invalid upgrade mode: $selection"
            ;;
    esac

    save_state
}

start_with_home() {
    local home="$1"
    local data="$2"
    "$home/bin/pg_ctl" -w -D "$data" -l "$WORK_DIR/server.log" -o "-c config_file=$data/postgresql.conf -c data_directory=$data" start
}

upgrade() {
    local old_version mode_text
    old_version="$(old_binary_version)"

    [[ -x "$PG_HOME_NEW/bin/postgres" ]] || die "run prepare first"

    select_upgrade_mode

    case "$UPGRADE_MODE" in
        binary)
            mode_text="Binary only; keep current PGDATA: $PGDATA_OLD"
            ;;
        backup)
            mode_text="Binary + PGDATA backup: $PGDATA_BACKUP; keep current PGDATA active"
            ;;
        copy)
            mode_text="Binary + PGDATA copy & switch: $PGDATA_OLD -> $PGDATA_NEW"
            ;;
        *)
            die "invalid saved upgrade mode: $UPGRADE_MODE"
            ;;
    esac

    confirm "MINOR UPGRADE" "Stop PostgreSQL $old_version and run mode [$UPGRADE_MODE]? $mode_text"

    "$PG_HOME_OLD/bin/pg_ctl" -w -D "$PGDATA_OLD" -m fast stop

    case "$UPGRADE_MODE" in
        binary)
            ;;
        backup)
            prepare_pgdata_backup
            ;;
        copy)
            prepare_new_data_directory
            ;;
    esac

    if ! start_with_home "$PG_HOME_NEW" "$PGDATA_ACTIVE"; then
        echo "NEW PostgreSQL startup failed; restoring OLD binary startup" >&2
        start_with_home "$PG_HOME_OLD" "$PGDATA_OLD" || die "automatic rollback startup also failed"
        die "minor upgrade failed and OLD PostgreSQL was restarted"
    fi

    log "minor upgrade startup successful: $old_version -> $TARGET_VERSION"
    log "upgrade mode: $UPGRADE_MODE"
    log "active PGDATA: $PGDATA_ACTIVE"
    [[ -z "$PGDATA_BACKUP" ]] || log "PGDATA backup: $PGDATA_BACKUP"
    echo
    echo "NEXT: sh $0 postcheck"
}

update_extensions() {
    local db extension

    ensure_password
    while IFS= read -r db; do
        while IFS= read -r extension; do
            [[ -n "$extension" ]] || continue
            psql_new -d "$db" -c "ALTER EXTENSION \"${extension//\"/\"\"}\" UPDATE;"
        done < <(psql_new -d "$db" -Atc "select e.extname from pg_extension e join pg_available_extensions a on a.name=e.extname where a.default_version is distinct from e.extversion order by 1")
    done < <(psql_new -d postgres -Atc "select datname from pg_database where datallowconn and not datistemplate order by 1")
}

postcheck() {
    local server_version data_directory port
    local settings_before="$WORK_DIR/postgresql_settings.before"
    local settings_after="$WORK_DIR/postgresql_settings.after"

    ensure_password
    [[ -n "$PGDATA_ACTIVE" ]] || die "upgrade mode state not found; run upgrade first"

    server_version="$(psql_new -d postgres -Atc 'show server_version')"
    data_directory="$(psql_new -d postgres -Atc 'show data_directory')"
    port="$(psql_new -d postgres -Atc 'show port')"

    [[ "$server_version" == "$TARGET_VERSION" ]] || die "server version mismatch: $server_version"
    [[ "$data_directory" == "$PGDATA_ACTIVE" ]] || die "data directory mismatch: expected=$PGDATA_ACTIVE actual=$data_directory"
    [[ "$port" == "$PGPORT" ]] || die "port mismatch: $port"

    [[ -f "$settings_before" ]] || die "OLD PostgreSQL settings snapshot not found: $settings_before"
    psql_new -d postgres -A -t -c "
        select name || ' = ' || quote_literal(setting)
        from pg_settings
        where source = 'configuration file'
          and name not in (
              'data_directory', 'config_file', 'hba_file', 'ident_file',
              'external_pid_file', 'ssl_cert_file', 'ssl_key_file',
              'ssl_ca_file', 'ssl_crl_file'
          )
        order by name;
    " > "$settings_after"

    if ! diff -u "$settings_before" "$settings_after"; then
        die "PostgreSQL configuration values changed during minor upgrade"
    fi

    log "OLD PostgreSQL configuration values preserved"
    log "  before: $settings_before"
    log "  after : $settings_after"

    update_extensions

    if grep -E '(^|[[:space:]])(PANIC|FATAL):' "$WORK_DIR/server.log" | tail -20; then
        log "review FATAL/PANIC lines above if present"
    fi

    log "postcheck complete: PostgreSQL $server_version"
    log "upgrade mode: $UPGRADE_MODE"
    log "active PGDATA: $PGDATA_ACTIVE"
    echo
    echo "NEXT: sh $0 env"
}

rewrite_profile_file() {
    local file="$1"
    local activate_new="$2"
    local tmp="${file}.minor_upgrade.$$"
    local legacy_home="$BASE/pgsql"

    awk -v activate="$activate_new" -v old_home="$PG_HOME_OLD" -v new_home="$PG_HOME_NEW" -v new_data="$PGDATA_ACTIVE" -v new_port="$PGPORT" -v legacy_home="$legacy_home" '
        function variable_name(line, value) {
            value = line
            sub(/^[[:space:]]*export[[:space:]]+/, "", value)
            sub(/=.*/, "", value)
            return value
        }

        function expected_line(name) {
            if (name == "PG_HOME" || name == "PGHOME") return "export " name "=" new_home
            if (name == "PGDATA") return "export PGDATA=" new_data
            if (name == "PGPORT" || name == "PG_PORT") return "export " name "=" new_port
            return ""
        }

        function is_pg_export(line) {
            return line ~ /^[[:space:]]*export[[:space:]]+(PG_HOME|PGHOME|PGDATA|PGPORT|PG_PORT)=/
        }

        { source[NR] = $0 }

        END {
            for (i = 1; i <= NR; i++) {
                if (is_pg_export(source[i])) {
                    name = variable_name(source[i])
                    if (source[i] == expected_line(name)) correct[name] = 1
                }
            }

            for (i = 1; i <= NR; i++) {
                line = source[i]

                if (line ~ /^[[:space:]]*#[[:space:]]*Disabled by postgresql_(major|minor)_upgrade[.]sh .*:[[:space:]]*export[[:space:]]+(PG_HOME|PGHOME|PGDATA|PGPORT|PG_PORT)=/) {
                    sub(/^[[:space:]]*#[[:space:]]*Disabled by postgresql_(major|minor)_upgrade[.]sh .*:[[:space:]]*/, "# ", line)
                    print line
                    name = line
                    sub(/^[[:space:]]*#[[:space:]]*export[[:space:]]+/, "", name)
                    sub(/=.*/, "", name)
                    if (activate == "true" && !correct[name] && !active[name]) {
                        print expected_line(name)
                        active[name] = 1
                    }
                    continue
                }

                if (is_pg_export(line)) {
                    name = variable_name(line)
                    expected = expected_line(name)

                    if (activate == "true" && line == expected && !active[name]) {
                        print line
                        active[name] = 1
                    } else {
                        print "# " line
                        if (activate == "true" && !active[name]) {
                            print expected
                            active[name] = 1
                        }
                    }
                    continue
                }

                if (line ~ /^[[:space:]]*export[[:space:]]+PATH=/) {
                    gsub(old_home "/bin", new_home "/bin", line)
                    gsub(legacy_home "/bin", new_home "/bin", line)
                    print line
                    continue
                }

                if (line ~ /^[[:space:]]*export[[:space:]]+LD_LIBRARY_PATH=/) {
                    gsub(old_home "/lib", new_home "/lib", line)
                    gsub(legacy_home "/lib", new_home "/lib", line)
                    print line
                    continue
                }

                print line
            }

            if (activate == "true") {
                split("PG_HOME PGHOME PGDATA PGPORT PG_PORT", required, " ")
                for (i = 1; i <= 5; i++) {
                    name = required[i]
                    if (!active[name]) print expected_line(name)
                }
            }
        }
    ' "$file" > "$tmp"
    chmod --reference="$file" "$tmp"
    mv "$tmp" "$file"
}

update_env() {
    local file backup_suffix

    ensure_password
    [[ -n "$PGDATA_ACTIVE" ]] || die "upgrade mode state not found; run upgrade first"
    [[ "$(psql_new -d postgres -Atc 'show server_version')" == "$TARGET_VERSION" ]] || die "run upgrade and postcheck first"

    backup_suffix="before_pg${TARGET_VERSION}_minor_$(date +%Y%m%d_%H%M%S)"
    [[ -f "$BASH_PROFILE" ]] || touch "$BASH_PROFILE"
    for file in "$BASH_PROFILE" "$HOME/.bashrc"; do
        [[ -f "$file" ]] || continue
        cp -p "$file" "$file.$backup_suffix"
        sed -i '/# Added by postgresql_minor_upgrade.sh/,/# End postgresql_minor_upgrade.sh/d' "$file"
        sed -i '/# Added by postgresql_major_upgrade.sh/,/# End postgresql_major_upgrade.sh/d' "$file"
        if [[ "$file" == "$BASH_PROFILE" ]]; then
            rewrite_profile_file "$file" true
        else
            rewrite_profile_file "$file" false
        fi
    done

    log "environment updated; OLD binaries preserved at $PG_HOME_OLD"
    log "active PGDATA preserved in profile: $PGDATA_ACTIVE"
    echo "Run: source $BASH_PROFILE && hash -r"
    echo "COMPLETE: all four minor-upgrade steps finished."
}

usage() {
    cat <<EOF
Usage:
  sh $0 [--target-version VERSION] [--source-tar FILE] <step>

Steps:
  prepare    Validate, install dependencies, build and precheck while online
  upgrade    Select binary-only, PGDATA backup, or PGDATA copy-and-switch mode
  postcheck  Validate server and update installed extensions where required
  env        Preserve old profile lines as comments and activate NEW PG_HOME

Typical:
  sh $0 prepare
  sh $0 --source-tar /path/to/postgresql-VERSION.tar.gz prepare
  sh $0 upgrade
  sh $0 postcheck
  sh $0 env
EOF
}

parse_args "$@"

case "$STEP" in
    upgrade|postcheck|env)
        load_state
        ;;
esac

[[ "$TARGET_VERSION_EXPLICIT" != true ]] || TARGET_VERSION="$TARGET_VERSION_INPUT"
[[ "$SOURCE_TAR_EXPLICIT" != true ]] || SOURCE_TAR="$SOURCE_TAR_INPUT"

case "$STEP" in
    help) usage ;;
    prepare|upgrade|postcheck|env)
        finalize_config
        case "$STEP" in
            prepare) prepare ;;
            upgrade) upgrade ;;
            postcheck) postcheck ;;
            env) update_env ;;
        esac
        ;;
    *) die "unknown step: $STEP" ;;
esac
