#!/usr/bin/env bash
set -Eeuo pipefail

# Rebuild a physical standby after the primary PostgreSQL major upgrade.
# This script does not run pg_upgrade. It installs/reuses the new PostgreSQL
# home and recreates standby PGDATA with pg_basebackup from the upgraded primary.

BASE="${BASE:-/home/postgres}"
PG_NEW_VERSION="${PG_NEW_VERSION:-18.4}"
PG_NEW_MAJOR="${PG_NEW_MAJOR:-18}"

PG_HOME_OLD="${PG_HOME_OLD:-$BASE/pgsql}"
PG_HOME_NEW="${PG_HOME_NEW:-$BASE/pgsql_$PG_NEW_VERSION}"
PGDATA="${PGDATA:-$BASE/data}"
PGDATA_BACKUP="${PGDATA_BACKUP:-$BASE/data_before_pg${PG_NEW_MAJOR}_standby_rebuild_$(date +%Y%m%d_%H%M%S)}"

PRIMARY_HOST="${PRIMARY_HOST:-}"
PRIMARY_PORT="${PRIMARY_PORT:-5444}"
REPL_USER="${REPL_USER:-repl}"
REPL_SLOT="${REPL_SLOT:-}"
APP_NAME="${APP_NAME:-$(hostname)}"

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  local expected="$1"
  echo "$2"
  printf 'Type "%s" to continue: ' "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "cancelled"
}

show_config() {
  cat <<EOF
BASE=$BASE
PG_NEW_VERSION=$PG_NEW_VERSION
PG_HOME_OLD=$PG_HOME_OLD
PG_HOME_NEW=$PG_HOME_NEW
PGDATA=$PGDATA
PGDATA_BACKUP=$PGDATA_BACKUP
PRIMARY_HOST=$PRIMARY_HOST
PRIMARY_PORT=$PRIMARY_PORT
REPL_USER=$REPL_USER
REPL_SLOT=$REPL_SLOT
APP_NAME=$APP_NAME
EOF
}

precheck() {
  show_config
  [[ -n "$PRIMARY_HOST" ]] || die "set PRIMARY_HOST"
  [[ -x "$PG_HOME_NEW/bin/pg_basebackup" ]] || die "new pg_basebackup not found: $PG_HOME_NEW/bin/pg_basebackup"
  "$PG_HOME_NEW/bin/pg_basebackup" --version
  "$PG_HOME_NEW/bin/psql" -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" -d postgres -c "select version();"
}

stop_old() {
  if [[ -x "$PG_HOME_OLD/bin/pg_ctl" && -d "$PGDATA" ]]; then
    "$PG_HOME_OLD/bin/pg_ctl" -D "$PGDATA" -m fast -w stop || true
  fi
}

move_old_data() {
  [[ -e "$PGDATA" ]] || return 0
  confirm "MOVE DATA" "This moves $PGDATA to $PGDATA_BACKUP before running pg_basebackup."
  mv "$PGDATA" "$PGDATA_BACKUP"
  log "moved old PGDATA to $PGDATA_BACKUP"
}

basebackup() {
  [[ -n "$PRIMARY_HOST" ]] || die "set PRIMARY_HOST"
  [[ ! -e "$PGDATA" ]] || die "$PGDATA already exists; run move-data first or choose another PGDATA"

  local slot_args=()
  if [[ -n "$REPL_SLOT" ]]; then
    slot_args=(-S "$REPL_SLOT")
  fi

  "$PG_HOME_NEW/bin/pg_basebackup" \
    -h "$PRIMARY_HOST" \
    -p "$PRIMARY_PORT" \
    -U "$REPL_USER" \
    -D "$PGDATA" \
    -Fp \
    -Xs \
    -P \
    -R \
    "${slot_args[@]}"

  {
    echo
    echo "# Added by postgresql_standby_rebuild.sh"
    echo "port = $PRIMARY_PORT"
  } >> "$PGDATA/postgresql.conf"

  if [[ -f "$PGDATA/postgresql.auto.conf" ]]; then
    sed -i -E "s|application_name=[^ ']+|application_name=$APP_NAME|g" "$PGDATA/postgresql.auto.conf" || true
  fi
}

start_new() {
  "$PG_HOME_NEW/bin/pg_ctl" -D "$PGDATA" -l "$PGDATA/server.log" -w start
}

postcheck() {
  "$PG_HOME_NEW/bin/psql" -p "$PRIMARY_PORT" -U postgres -d postgres -c "select pg_is_in_recovery();"
  "$PG_HOME_NEW/bin/psql" -p "$PRIMARY_PORT" -U postgres -d postgres -c "select status, sender_host, sender_port from pg_stat_wal_receiver;"
}

rebuild() {
  precheck
  stop_old
  move_old_data
  basebackup
  start_new
  postcheck
}

usage() {
  cat <<EOF
Usage: $0 <step>

Steps:
  help       Show this help
  config     Show effective variables
  precheck   Check PostgreSQL 18 client and primary connectivity
  stop-old   Stop old standby if running
  move-data  Move existing standby PGDATA aside
  basebackup Run pg_basebackup from upgraded primary
  start-new  Start rebuilt standby
  postcheck  Check recovery and WAL receiver
  rebuild    Run precheck, stop-old, move-data, basebackup, start-new, postcheck

Example:
  PRIMARY_HOST=128.10.41.133 REPL_USER=repl REPL_SLOT=physical_slot01 $0 rebuild
EOF
}

case "${1:-help}" in
  help|-h|--help) usage ;;
  config) show_config ;;
  precheck) precheck ;;
  stop-old) stop_old ;;
  move-data) move_old_data ;;
  basebackup) basebackup ;;
  start-new) start_new ;;
  postcheck) postcheck ;;
  rebuild) rebuild ;;
  *) usage; exit 1 ;;
esac
