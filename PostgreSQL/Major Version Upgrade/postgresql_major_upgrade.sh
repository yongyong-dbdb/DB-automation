#!/usr/bin/env bash
set -Eeuo pipefail

# PostgreSQL primary/single major upgrade helper.
# Example target: PostgreSQL 15.7 -> 18.4 on /home/postgres.
#
# This script is for primary or standalone servers.
# Physical standby servers should be rebuilt from the upgraded primary with
# pg_basebackup instead of running pg_upgrade locally.

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

BASE="${BASE:-/home/postgres}"
PG_NEW_VERSION="${PG_NEW_VERSION:-}"
PG_NEW_MAJOR="${PG_NEW_MAJOR:-}"

SRC_TAR="${SRC_TAR:-}"
SRC_DIR="${SRC_DIR:-}"

PG_HOME_OLD="${PG_HOME_OLD:-}"
PG_HOME_NEW="${PG_HOME_NEW:-}"
PGDATA_OLD="${PGDATA_OLD:-}"
PGDATA_NEW="${PGDATA_NEW:-}"

OLD_PORT="${OLD_PORT:-5444}"
NEW_PORT="${NEW_PORT:-}"
PGUSER_NAME="${PGUSER_NAME:-postgres}"
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

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  local expected="$1"
  echo "$2"
  printf 'Type "%s" to continue: ' "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "cancelled"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new-version)
        [[ $# -ge 2 ]] || die "--new-version requires a value"
        PG_NEW_VERSION="$2"
        shift 2
        ;;
      --new-version=*)
        PG_NEW_VERSION="${1#*=}"
        shift
        ;;
      --new-port)
        [[ $# -ge 2 ]] || die "--new-port requires a value"
        NEW_PORT="$2"
        shift 2
        ;;
      --new-port=*)
        NEW_PORT="${1#*=}"
        shift
        ;;
      --old-port)
        [[ $# -ge 2 ]] || die "--old-port requires a value"
        OLD_PORT="$2"
        shift 2
        ;;
      --old-port=*)
        OLD_PORT="${1#*=}"
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
        [[ -z "$STEP" ]] || die "multiple steps specified: $STEP and $1"
        STEP="$1"
        shift
        ;;
    esac
  done

  STEP="${STEP:-help}"
}

config_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v key="$key" '$1 == key { sub(/^[ \t]+/, "", $2); sub(/[ \t]+$/, "", $2); print $2; exit }' "$file"
}

load_saved_config() {
  [[ -n "$UPGRADE_CONFIG_FILE" ]] || UPGRADE_CONFIG_FILE="$BASE/.postgresql_major_upgrade.conf"
  [[ -f "$UPGRADE_CONFIG_FILE" ]] || return 0

  PG_NEW_VERSION="${PG_NEW_VERSION:-$(config_value PG_NEW_VERSION "$UPGRADE_CONFIG_FILE")}"
  PG_NEW_MAJOR="${PG_NEW_MAJOR:-$(config_value PG_NEW_MAJOR "$UPGRADE_CONFIG_FILE")}"
  NEW_PORT="${NEW_PORT:-$(config_value NEW_PORT "$UPGRADE_CONFIG_FILE")}"
  OLD_PORT="${OLD_PORT:-$(config_value OLD_PORT "$UPGRADE_CONFIG_FILE")}"
  PG_HOME_OLD="${PG_HOME_OLD:-$(config_value PG_HOME_OLD "$UPGRADE_CONFIG_FILE")}"
  PG_HOME_NEW="${PG_HOME_NEW:-$(config_value PG_HOME_NEW "$UPGRADE_CONFIG_FILE")}"
  PGDATA_OLD="${PGDATA_OLD:-$(config_value PGDATA_OLD "$UPGRADE_CONFIG_FILE")}"
  PGDATA_NEW="${PGDATA_NEW:-$(config_value PGDATA_NEW "$UPGRADE_CONFIG_FILE")}"
  SRC_TAR="${SRC_TAR:-$(config_value SRC_TAR "$UPGRADE_CONFIG_FILE")}"
  SRC_DIR="${SRC_DIR:-$(config_value SRC_DIR "$UPGRADE_CONFIG_FILE")}"
  WORK_DIR="${WORK_DIR:-$(config_value WORK_DIR "$UPGRADE_CONFIG_FILE")}"
  JOBS="${JOBS:-$(config_value JOBS "$UPGRADE_CONFIG_FILE")}"
  USE_LINK="${USE_LINK:-$(config_value USE_LINK "$UPGRADE_CONFIG_FILE")}"
}

save_config() {
  [[ -n "$UPGRADE_CONFIG_FILE" ]] || UPGRADE_CONFIG_FILE="$BASE/.postgresql_major_upgrade.conf"
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

prompt_initial_config() {
  local input old_version

  old_version="$PG_NEW_VERSION"

  printf 'Enter old PostgreSQL home [current: %s]: ' "$PG_HOME_OLD"
  read -r input
  [[ -n "$input" ]] && PG_HOME_OLD="$input"

  printf 'Enter old PostgreSQL data directory [current: %s]: ' "$PGDATA_OLD"
  read -r input
  [[ -n "$input" ]] && PGDATA_OLD="$input"

  printf 'Enter old PostgreSQL port [current: %s]: ' "$OLD_PORT"
  read -r input
  [[ -n "$input" ]] && OLD_PORT="$input"

  if [[ -n "$PG_NEW_VERSION" ]]; then
    printf 'Enter new PostgreSQL version [current: %s]: ' "$PG_NEW_VERSION"
  else
    printf 'Enter new PostgreSQL version, for example 18.4: '
  fi
  read -r input
  [[ -n "$input" ]] && PG_NEW_VERSION="$input"

  if [[ -n "$NEW_PORT" ]]; then
    printf 'Enter new PostgreSQL port [current: %s]: ' "$NEW_PORT"
  else
    printf 'Enter new PostgreSQL port, for example 5444: '
  fi
  read -r input
  [[ -n "$input" ]] && NEW_PORT="$input"

  if [[ "$PG_NEW_VERSION" != "$old_version" ]]; then
    PG_NEW_MAJOR=""
    SRC_TAR=""
    SRC_DIR=""
    PG_HOME_NEW=""
    PGDATA_NEW=""
    WORK_DIR=""
  fi
}

finalize_config() {
  [[ "$STEP" == "help" ]] && return 0
  load_saved_config
  PG_HOME_OLD="${PG_HOME_OLD:-$BASE/pgsql}"
  PGDATA_OLD="${PGDATA_OLD:-$BASE/data}"

  case "$STEP" in
    config|prepare)
      prompt_initial_config
      ;;
  esac

  if [[ -z "$PG_NEW_VERSION" ]]; then
    printf 'Enter new PostgreSQL version, for example 18.4: '
    read -r PG_NEW_VERSION
  fi
  [[ -n "$PG_NEW_VERSION" ]] || die "new PostgreSQL version is required"

  if [[ -z "$NEW_PORT" ]]; then
    printf 'Enter new PostgreSQL port, for example 5444: '
    read -r NEW_PORT
  fi
  [[ -n "$NEW_PORT" ]] || die "new PostgreSQL port is required"

  PG_NEW_MAJOR="${PG_NEW_MAJOR:-$(version_major "$PG_NEW_VERSION")}"

  SRC_TAR="${SRC_TAR:-$BASE/postgresql-$PG_NEW_VERSION.tar.gz}"
  SRC_DIR="${SRC_DIR:-$BASE/postgresql-$PG_NEW_VERSION}"
  PG_HOME_OLD="${PG_HOME_OLD:-$BASE/pgsql}"
  PG_HOME_NEW="${PG_HOME_NEW:-$BASE/pgsql_$PG_NEW_VERSION}"
  PGDATA_OLD="${PGDATA_OLD:-$BASE/data}"
  PGDATA_NEW="${PGDATA_NEW:-$BASE/data_$PG_NEW_MAJOR}"
  BACKUP_DIR="${BACKUP_DIR:-$BASE/backup_pg_upgrade_$(date +%Y%m%d_%H%M%S)}"
  WORK_DIR="${WORK_DIR:-$BASE/pg_upgrade_work_$PG_NEW_VERSION}"
  JOBS="${JOBS:-2}"
  USE_LINK="${USE_LINK:-true}"
  save_config
}

ask_upgrade_tuning() {
  local answer jobs_answer detected_cores recommended_jobs

  echo "Use --link option for pg_upgrade? [y/N]"
  echo "  y: faster, uses hard links, rollback is limited after new cluster receives writes."
  echo "  n: copies data files, needs more disk space, keeps old cluster more independent."
  printf "Select [y/N]: "
  read -r answer
  case "${answer,,}" in
    y|yes) USE_LINK="true" ;;
    *) USE_LINK="false" ;;
  esac

  detected_cores="$(detect_physical_cores)"
  recommended_jobs="1"
  if [[ "$detected_cores" =~ ^[1-9][0-9]*$ ]]; then
    recommended_jobs=$((detected_cores / 2))
    [[ "$recommended_jobs" -ge 1 ]] || recommended_jobs="1"
  fi

  echo "Set --jobs for pg_upgrade parallel workers."
  echo "  Detected physical CPU cores: $detected_cores"
  echo "  Recommended: $recommended_jobs, about 50% of physical CPU cores."
  printf "Enter jobs value [recommended: %s]: " "$recommended_jobs"
  read -r jobs_answer
  if [[ -n "$jobs_answer" ]]; then
    [[ "$jobs_answer" =~ ^[1-9][0-9]*$ ]] || die "jobs must be a positive integer"
    JOBS="$jobs_answer"
  else
    JOBS="$recommended_jobs"
  fi

}

detect_physical_cores() {
  local cores_per_socket sockets

  if command -v lscpu >/dev/null 2>&1; then
    cores_per_socket="$(lscpu | awk -F: '/Core\(s\) per socket:/ { gsub(/[ \t]/, "", $2); print $2; exit }')"
    sockets="$(lscpu | awk -F: '/Socket\(s\):/ { gsub(/[ \t]/, "", $2); print $2; exit }')"
    if [[ "$cores_per_socket" =~ ^[1-9][0-9]*$ && "$sockets" =~ ^[1-9][0-9]*$ ]]; then
      echo $((cores_per_socket * sockets))
      return 0
    fi
  fi

  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi

  getconf _NPROCESSORS_ONLN 2>/dev/null || echo "unknown"
}

link_arg() {
  [[ "$USE_LINK" == "true" ]] && printf '%s\n' "--link"
}

version_major() {
  echo "$1" | sed -E 's/[^0-9]*([0-9]+).*/\1/'
}

psql_old_at_optional() {
  "$PG_HOME_OLD/bin/psql" -X -A -t -v ON_ERROR_STOP=1 -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "$1" 2>/dev/null || true
}

psql_old_at() {
  "$PG_HOME_OLD/bin/psql" -X -A -t -v ON_ERROR_STOP=1 -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "$1"
}

validate_old_cluster_paths() {
  local server_version_num server_major dumpall_version dumpall_major running_data_dir

  [[ -x "$PG_HOME_OLD/bin/pg_dumpall" ]] || die "old pg_dumpall not found: $PG_HOME_OLD/bin/pg_dumpall"

  server_version_num="$(psql_old_at "show server_version_num;")"
  server_major=$((server_version_num / 10000))
  dumpall_version="$("$PG_HOME_OLD/bin/pg_dumpall" --version)"
  dumpall_major="$(version_major "$dumpall_version")"

  if [[ "$server_major" != "$dumpall_major" ]]; then
    die "old PostgreSQL binary mismatch: server major=$server_major but $PG_HOME_OLD/bin/pg_dumpall is $dumpall_version. Set PG_HOME_OLD to the running old server home, for example /home/postgres/pgsql_18.4"
  fi

  running_data_dir="$(psql_old_at "show data_directory;")"
  if [[ "$running_data_dir" != "$PGDATA_OLD" ]]; then
    die "old PGDATA mismatch: running server data_directory=$running_data_dir but PGDATA_OLD=$PGDATA_OLD. Set PGDATA_OLD to the running old server data directory."
  fi
}

old_template0_value() {
  local column="$1"
  psql_old_at_optional "select $column from pg_database where datname = 'template0';"
}

old_control_value() {
  "$PG_HOME_OLD/bin/pg_controldata" "$PGDATA_OLD" | awk -F: -v key="$1" '$1 == key { sub(/^[ \t]+/, "", $2); print $2; exit }'
}

new_control_value() {
  "$PG_HOME_NEW/bin/pg_controldata" "$PGDATA_NEW" | awk -F: -v key="$1" '$1 == key { sub(/^[ \t]+/, "", $2); print $2; exit }'
}

old_checksum_arg() {
  local checksum_version
  checksum_version="$(old_control_value "Data page checksum version")"
  case "$checksum_version" in
    0) printf '%s\n' "--no-data-checksums" ;;
    ''|*[!0-9]*) die "could not read old data checksum version from $PGDATA_OLD" ;;
    *) printf '%s\n' "--data-checksums" ;;
  esac
}

set_new_postgresql_conf_port() {
  local conf_file="$PGDATA_NEW/postgresql.conf"
  [[ -f "$conf_file" ]] || die "new postgresql.conf not found: $conf_file"

  cp -p "$conf_file" "$conf_file.before_port_update"
  sed -i -E 's/^[[:space:]]*port[[:space:]]*=/# port disabled by postgresql_major_upgrade.sh: /' "$conf_file"
  {
    echo
    echo "# Added by postgresql_major_upgrade.sh"
    echo "port = $NEW_PORT"
  } >> "$conf_file"

  log "set new postgresql.conf port to $NEW_PORT; backup: $conf_file.before_port_update"
}

show_config() {
  cat <<EOF
BASE=$BASE
PG_NEW_VERSION=$PG_NEW_VERSION
SRC_TAR=$SRC_TAR
SRC_DIR=$SRC_DIR
PG_HOME_OLD=$PG_HOME_OLD
PG_HOME_NEW=$PG_HOME_NEW
PGDATA_OLD=$PGDATA_OLD
PGDATA_NEW=$PGDATA_NEW
OLD_PORT=$OLD_PORT
NEW_PORT=$NEW_PORT
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

precheck() {
  show_config
  [[ -x "$PG_HOME_OLD/bin/psql" ]] || die "old psql not found: $PG_HOME_OLD/bin/psql"
  [[ -x "$PG_HOME_OLD/bin/pg_controldata" ]] || die "old pg_controldata not found: $PG_HOME_OLD/bin/pg_controldata"
  [[ -d "$PGDATA_OLD" ]] || die "old PGDATA not found: $PGDATA_OLD"
  [[ -f "$SRC_TAR" ]] || die "source tar not found: $SRC_TAR"
  validate_old_cluster_paths

  "$PG_HOME_OLD/bin/postgres" --version
  "$PG_HOME_OLD/bin/pg_dumpall" --version
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "select version();"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show data_directory;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show port;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show listen_addresses;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show shared_preload_libraries;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "select datname, pg_encoding_to_char(encoding) as encoding, datcollate, datctype from pg_database where datname = 'template0';"
  "$PG_HOME_OLD/bin/pg_controldata" "$PGDATA_OLD" | egrep 'Database cluster state|Data page checksum version|WAL block size|Bytes per WAL segment'
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "select application_name, client_addr, state, sync_state, sent_lsn, replay_lsn from pg_stat_replication;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "select extname, extversion from pg_extension order by extname;"
}

build() {
  [[ -d "$SRC_DIR" ]] || tar -C "$BASE" -xzf "$SRC_TAR"
  cd "$SRC_DIR"
  ./configure --prefix="$PG_HOME_NEW"
  make -j "$JOBS"
  make install
  make -C contrib install
  "$PG_HOME_NEW/bin/postgres" --version
}

install_contrib() {
  [[ -d "$SRC_DIR/contrib" ]] || die "contrib source directory not found: $SRC_DIR/contrib"
  cd "$SRC_DIR"
  make -C contrib install
  log "contrib extensions installed into $PG_HOME_NEW"
}

backup() {
  validate_old_cluster_paths
  mkdir -p "$BACKUP_DIR"
  "$PG_HOME_OLD/bin/pg_dumpall" -p "$OLD_PORT" -U "$PGUSER_NAME" > "$BACKUP_DIR/backup_pg${OLD_PORT}_all.sql"
  cp -p "$PGDATA_OLD/postgresql.conf" "$BACKUP_DIR/postgresql.conf.old"
  cp -p "$PGDATA_OLD/pg_hba.conf" "$BACKUP_DIR/pg_hba.conf.old"
  [[ -f "$PGDATA_OLD/pg_ident.conf" ]] && cp -p "$PGDATA_OLD/pg_ident.conf" "$BACKUP_DIR/pg_ident.conf.old"
  log "backup saved: $BACKUP_DIR"
}

initdb_new() {
  [[ -x "$PG_HOME_NEW/bin/initdb" ]] || die "new initdb not found: $PG_HOME_NEW/bin/initdb"
  [[ -x "$PG_HOME_NEW/bin/pg_controldata" ]] || die "new pg_controldata not found: $PG_HOME_NEW/bin/pg_controldata"
  [[ ! -e "$PGDATA_NEW/PG_VERSION" ]] || die "already initialized: $PGDATA_NEW"

  local old_encoding old_lc_collate old_lc_ctype checksum_arg
  old_encoding="${OLD_ENCODING:-$(old_template0_value "pg_encoding_to_char(encoding)")}"
  old_lc_collate="${OLD_LC_COLLATE:-$(old_template0_value "datcollate")}"
  old_lc_ctype="${OLD_LC_CTYPE:-$(old_template0_value "datctype")}"
  checksum_arg="$(old_checksum_arg)"

  local initdb_args
  initdb_args=(-D "$PGDATA_NEW")
  [[ -n "$old_encoding" ]] && initdb_args+=(--encoding="$old_encoding")
  [[ -n "$old_lc_collate" ]] && initdb_args+=(--lc-collate="$old_lc_collate")
  [[ -n "$old_lc_ctype" ]] && initdb_args+=(--lc-ctype="$old_lc_ctype")
  initdb_args+=("$checksum_arg")

  mkdir -p "$PGDATA_NEW"
  log "initdb with old-compatible settings: encoding=$old_encoding lc_collate=$old_lc_collate lc_ctype=$old_lc_ctype $checksum_arg"
  "$PG_HOME_NEW/bin/initdb" "${initdb_args[@]}" $INITDB_EXTRA_OPTS

  local old_checksum new_checksum
  old_checksum="$(old_control_value "Data page checksum version")"
  new_checksum="$(new_control_value "Data page checksum version")"
  [[ "$old_checksum" == "$new_checksum" ]] || die "checksum mismatch after initdb: old=$old_checksum new=$new_checksum"

  cp -p "$PGDATA_OLD/pg_hba.conf" "$PGDATA_NEW/pg_hba.conf"
  [[ -f "$PGDATA_OLD/pg_ident.conf" ]] && cp -p "$PGDATA_OLD/pg_ident.conf" "$PGDATA_NEW/pg_ident.conf"
  set_new_postgresql_conf_port
}

prepare() {
  log "prepare step 1/4: precheck"
  precheck
  log "prepare step 2/4: build PostgreSQL $PG_NEW_VERSION and contrib extensions"
  build
  log "prepare step 3/4: backup old cluster"
  backup
  log "prepare step 4/4: initdb new PGDATA"
  initdb_new
  log "prepare complete. Next downtime steps: stop-old, check, upgrade, start-new, postcheck"
}

reinitdb_new() {
  if [[ -e "$PGDATA_NEW" ]]; then
    local backup_dir
    backup_dir="${PGDATA_NEW}.before_reinit_$(date +%Y%m%d_%H%M%S)"
    confirm "REINITDB" "This moves $PGDATA_NEW to $backup_dir and recreates it with old-compatible initdb options."
    mv "$PGDATA_NEW" "$backup_dir"
    log "moved existing new PGDATA to $backup_dir"
  fi
  initdb_new
}

show_latest_loadable_libraries() {
  local latest_file
  latest_file="$(find "$PGDATA_NEW/pg_upgrade_output.d" -name loadable_libraries.txt -type f 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$latest_file" && -s "$latest_file" ]]; then
    echo
    echo "Missing loadable libraries reported by pg_upgrade:"
    echo "$latest_file"
    echo "------------------------------------------------------------"
    cat "$latest_file"
    echo "------------------------------------------------------------"
    echo "If these are PostgreSQL contrib modules, run: $0 contrib"
    echo "If these are external extensions such as postgis, timescaledb, repmgr, or citus,"
    echo "install matching extension packages/libraries for PostgreSQL $PG_NEW_VERSION first."
  fi
}

stop_old() {
  confirm "STOP OLD" "This stops the old PostgreSQL cluster."
  "$PG_HOME_OLD/bin/pg_ctl" -D "$PGDATA_OLD" -m fast -w stop
}

upgrade_check() {
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"
  set +e
  "$PG_HOME_NEW/bin/pg_upgrade" \
    --old-bindir="$PG_HOME_OLD/bin" \
    --new-bindir="$PG_HOME_NEW/bin" \
    --old-datadir="$PGDATA_OLD" \
    --new-datadir="$PGDATA_NEW" \
    --old-port="$OLD_PORT" \
    --new-port="$NEW_PORT" \
    --old-options="-c config_file=$PGDATA_OLD/postgresql.conf" \
    --new-options="-c config_file=$PGDATA_NEW/postgresql.conf" \
    --username="$PGUSER_NAME" \
    --jobs="$JOBS" \
    $(link_arg) \
    --check \
    --verbose
  local rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    show_latest_loadable_libraries
    exit "$rc"
  fi
}

upgrade() {
  ask_upgrade_tuning
  confirm "UPGRADE" "Ready to run pg_upgrade."
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"
  "$PG_HOME_NEW/bin/pg_upgrade" \
    --old-bindir="$PG_HOME_OLD/bin" \
    --new-bindir="$PG_HOME_NEW/bin" \
    --old-datadir="$PGDATA_OLD" \
    --new-datadir="$PGDATA_NEW" \
    --old-port="$OLD_PORT" \
    --new-port="$NEW_PORT" \
    --old-options="-c config_file=$PGDATA_OLD/postgresql.conf" \
    --new-options="-c config_file=$PGDATA_NEW/postgresql.conf" \
    --username="$PGUSER_NAME" \
    --jobs="$JOBS" \
    $(link_arg) \
    --verbose \
    2>&1 | tee "$WORK_DIR/pg_upgrade.log"
}

start_new() {
  set_new_postgresql_conf_port
  "$PG_HOME_NEW/bin/pg_ctl" -D "$PGDATA_NEW" -l "$PGDATA_NEW/server.log" -w start
}

find_analyze_new_cluster_script() {
  local analyze_script

  if [[ -x "$WORK_DIR/analyze_new_cluster.sh" ]]; then
    echo "$WORK_DIR/analyze_new_cluster.sh"
    return 0
  fi

  analyze_script="$(find "$BASE" -name analyze_new_cluster.sh -type f -perm -u+x 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$analyze_script" ]]; then
    echo "$analyze_script"
    return 0
  fi

  analyze_script="$(find "$BASE" -name analyze_new_cluster.sh -type f 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$analyze_script" ]]; then
    chmod u+x "$analyze_script" 2>/dev/null || true
    echo "$analyze_script"
  fi
}

postcheck() {
  local analyze_script

  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "select version();"
  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "show data_directory;"
  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "show port;"
  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "show listen_addresses;"

  analyze_script="$(find_analyze_new_cluster_script)"
  if [[ -n "$analyze_script" && -x "$analyze_script" ]]; then
    log "running analyze script: $analyze_script"
    "$analyze_script"
  else
    log "analyze_new_cluster.sh not found; run analyze manually if needed"
    echo "Manual analyze command:"
    echo "$PG_HOME_NEW/bin/vacuumdb -p $NEW_PORT -U $PGUSER_NAME --all --analyze-in-stages"
  fi
}

update_env() {
  local shell_file backup_suffix
  backup_suffix="before_pg${PG_NEW_MAJOR}_upgrade_$(date +%Y%m%d_%H%M%S)"

  [[ -f "$BASH_PROFILE" ]] || touch "$BASH_PROFILE"

  for shell_file in "$BASH_PROFILE" "$HOME/.bashrc"; do
    [[ -f "$shell_file" ]] || continue

    cp -p "$shell_file" "$shell_file.$backup_suffix"
    log "backup saved: $shell_file.$backup_suffix"

    sed -i '/# Added by postgresql_major_upgrade.sh/,/# End postgresql_major_upgrade.sh/d' "$shell_file"
    sed -i -E "s|$BASE/pgsql(_[0-9][^/:\"' ]*)?/bin:||g" "$shell_file"
    sed -i -E "s|:$BASE/pgsql(_[0-9][^/:\"' ]*)?/bin||g" "$shell_file"
    sed -i -E "s|$BASE/pgsql(_[0-9][^/:\"' ]*)?|$PG_HOME_NEW|g" "$shell_file"
    sed -i -E "s|$BASE/data(_[0-9][^/:\"' ]*)?|$PGDATA_NEW|g" "$shell_file"
    sed -i -E "s|^export PG_HOME=.*|export PG_HOME=$PG_HOME_NEW|g" "$shell_file"
    sed -i -E "s|^export PGDATA=.*|export PGDATA=$PGDATA_NEW|g" "$shell_file"
    sed -i -E "s|^export PGPORT=.*|export PGPORT=$NEW_PORT|g" "$shell_file"
    sed -i -E "s|^export PG_PORT=.*|export PG_PORT=$NEW_PORT|g" "$shell_file"
    sed -i -E "s|(-p[[:space:]]*)$OLD_PORT|\\1$NEW_PORT|g" "$shell_file"
  done

  cat >> "$BASH_PROFILE" <<EOF

# Added by postgresql_major_upgrade.sh
export PG_HOME=$PG_HOME_NEW
export PGDATA=$PGDATA_NEW
export PGPORT=$NEW_PORT
export PG_PORT=$NEW_PORT
export PATH=\$PG_HOME/bin:\$PATH
# End postgresql_major_upgrade.sh
EOF

  log "updated $BASH_PROFILE"
  echo "Apply now: source $BASH_PROFILE"
  echo "Verify: which psql; psql --version"
}

next_step_hint() {
  case "$STEP" in
    config)
      echo "Next step: $0 prepare"
      ;;
    precheck|build|backup|initdb|prepare)
      echo "Next downtime step: $0 stop-old"
      ;;
    stop-old)
      echo "Next step: $0 check"
      ;;
    check)
      echo "Next step: $0 upgrade"
      ;;
    upgrade)
      echo "Next step: $0 start-new"
      ;;
    start-new)
      echo "Next step: $0 postcheck"
      ;;
    postcheck)
      echo "Next step: $0 env"
      ;;
    env)
      echo "Upgrade flow complete. Run: source $BASH_PROFILE"
      ;;
    contrib|reinitdb)
      echo "Next step: $0 check"
      ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  $0 <step>

Interactive input:
  If PG_NEW_VERSION or NEW_PORT is not set, the script asks for them at runtime.

Optional non-interactive flags:
  --new-version VERSION   New PostgreSQL version, for example 18.4
  --new-port PORT         New PostgreSQL port. Use the old port when keeping the same service port.

Common optional values can also be set as environment variables:
  BASE, PG_HOME_OLD, PG_HOME_NEW, PGDATA_OLD, PGDATA_NEW, OLD_PORT, JOBS, USE_LINK

Steps:
  help       Show this help
  config     Show effective variables
  precheck   Show old cluster info
  build      Extract, configure, make, make install, contrib install
  contrib    Install contrib extensions only
  prepare    Run precheck, build, backup, initdb while old DB is online
  backup     pg_dumpall and config backup
  initdb     Create new PGDATA with initdb
  reinitdb   Move existing new PGDATA aside, then initdb again
  stop-old   Stop old cluster
  check      Run pg_upgrade --check
  upgrade    Run pg_upgrade
  start-new  Start new cluster
  postcheck  Check new cluster and run analyze script if available
  env        Update ~/.bash_profile

Typical:
  $0 config
  $0 prepare
  $0 stop-old
  $0 check
  $0 upgrade
  $0 start-new
  $0 postcheck
  $0 env

Examples:
  $0 config
  USE_LINK=true  $0 upgrade
  USE_LINK=false $0 upgrade
  $0 --new-version 18.4 --new-port 5444 prepare
  $0 contrib
  $0 reinitdb
EOF
}

parse_args "$@"
finalize_config

case "$STEP" in
  help|-h|--help) usage ;;
  config) show_config ;;
  precheck) precheck ;;
  build) build ;;
  contrib) install_contrib ;;
  prepare) prepare ;;
  backup) backup ;;
  initdb) initdb_new ;;
  reinitdb) reinitdb_new ;;
  stop-old) stop_old ;;
  check) upgrade_check ;;
  upgrade) upgrade ;;
  start-new) start_new ;;
  postcheck) postcheck ;;
  env) update_env ;;
  *) usage; exit 1 ;;
esac

next_step_hint
