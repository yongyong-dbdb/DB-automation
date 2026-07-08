#!/usr/bin/env bash
set -Eeuo pipefail

# PostgreSQL primary/single major upgrade helper.
# Default target: PostgreSQL 15.7 -> 18.4 on /home/postgres.
#
# This script is for primary or standalone servers.
# Physical standby servers should be rebuilt from the upgraded primary with
# pg_basebackup instead of running pg_upgrade locally.

BASE="${BASE:-/home/postgres}"
PG_NEW_VERSION="${PG_NEW_VERSION:-18.4}"
PG_NEW_MAJOR="${PG_NEW_MAJOR:-18}"

SRC_TAR="${SRC_TAR:-$BASE/postgresql-$PG_NEW_VERSION.tar.gz}"
SRC_DIR="${SRC_DIR:-$BASE/postgresql-$PG_NEW_VERSION}"

PG_HOME_OLD="${PG_HOME_OLD:-$BASE/pgsql}"
PG_HOME_NEW="${PG_HOME_NEW:-$BASE/pgsql_$PG_NEW_VERSION}"
PGDATA_OLD="${PGDATA_OLD:-$BASE/data}"
PGDATA_NEW="${PGDATA_NEW:-$BASE/data_$PG_NEW_MAJOR}"

OLD_PORT="${OLD_PORT:-5444}"
NEW_PORT="${NEW_PORT:-$OLD_PORT}"
PGUSER_NAME="${PGUSER_NAME:-postgres}"
JOBS="${JOBS:-2}"
USE_LINK="${USE_LINK:-true}"

BACKUP_DIR="${BACKUP_DIR:-$BASE/backup_pg_upgrade_$(date +%Y%m%d_%H%M%S)}"
WORK_DIR="${WORK_DIR:-$BASE/pg_upgrade_work_$PG_NEW_VERSION}"
BASH_PROFILE="${BASH_PROFILE:-$HOME/.bash_profile}"
INITDB_EXTRA_OPTS="${INITDB_EXTRA_OPTS:-}"
OLD_ENCODING="${OLD_ENCODING:-}"
OLD_LC_COLLATE="${OLD_LC_COLLATE:-}"
OLD_LC_CTYPE="${OLD_LC_CTYPE:-}"

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  local expected="$1"
  echo "$2"
  printf 'Type "%s" to continue: ' "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "cancelled"
}

link_arg() {
  [[ "$USE_LINK" == "true" ]] && printf '%s\n' "--link"
}

psql_old_at_optional() {
  "$PG_HOME_OLD/bin/psql" -X -A -t -v ON_ERROR_STOP=1 -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "$1" 2>/dev/null || true
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

  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "select version();"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show data_directory;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show port;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show listen_addresses;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show shared_preload_libraries;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show server_encoding;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show lc_collate;"
  "$PG_HOME_OLD/bin/psql" -p "$OLD_PORT" -U "$PGUSER_NAME" -d postgres -c "show lc_ctype;"
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
  old_encoding="${OLD_ENCODING:-$(psql_old_at_optional "show server_encoding;")}"
  old_lc_collate="${OLD_LC_COLLATE:-$(psql_old_at_optional "show lc_collate;")}"
  old_lc_ctype="${OLD_LC_CTYPE:-$(psql_old_at_optional "show lc_ctype;")}"
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
  confirm "UPGRADE" "This runs pg_upgrade. Physical standby servers must be rebuilt after primary upgrade."
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

postcheck() {
  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "select version();"
  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "show data_directory;"
  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "show port;"
  "$PG_HOME_NEW/bin/psql" -p "$NEW_PORT" -U "$PGUSER_NAME" -d postgres -c "show listen_addresses;"
  [[ -x "$WORK_DIR/analyze_new_cluster.sh" ]] && "$WORK_DIR/analyze_new_cluster.sh"
}

update_env() {
  cp -p "$BASH_PROFILE" "$BASH_PROFILE.before_pg${PG_NEW_MAJOR}_upgrade"
  sed -i "s|$PG_HOME_OLD|$PG_HOME_NEW|g" "$BASH_PROFILE"
  sed -i "s|$PGDATA_OLD|$PGDATA_NEW|g" "$BASH_PROFILE"
  sed -i "s|PGPORT=.*|PGPORT=$NEW_PORT|g" "$BASH_PROFILE"
  sed -i -E "s|(-p[[:space:]]*)$OLD_PORT|\\1$NEW_PORT|g" "$BASH_PROFILE"
  log "updated $BASH_PROFILE; run: source $BASH_PROFILE"
}

usage() {
  cat <<EOF
Usage: $0 <step>

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
  $0 prepare
  $0 stop-old
  $0 check
  $0 upgrade
  $0 start-new
  $0 postcheck
  $0 env

Examples:
  USE_LINK=true  $0 upgrade
  USE_LINK=false $0 upgrade
  NEW_PORT=5444  $0 initdb
  $0 contrib
  $0 reinitdb
EOF
}

case "${1:-help}" in
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
