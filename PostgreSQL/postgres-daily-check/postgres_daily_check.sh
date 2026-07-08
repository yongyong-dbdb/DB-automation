#!/usr/bin/env bash
set -u

DB_NAME="${DB_NAME:-postgres}"
DB_USER="${DB_USER:-postgres}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-${PGPORT:-${PG_PORT:-}}}"
PGDATA="${PGDATA:-${PGDATA_OLD:-}}"
REPORT_DIR="${REPORT_DIR:-$HOME/postgres_daily_reports}"
SQL_DIR="${SQL_DIR:-$(cd "$(dirname "$0")/sql" && pwd)}"

LONG_QUERY_THRESHOLD="${LONG_QUERY_THRESHOLD:-5 minutes}"
IDLE_XACT_THRESHOLD="${IDLE_XACT_THRESHOLD:-5 minutes}"
AUTOVACUUM_DELAY_THRESHOLD="${AUTOVACUUM_DELAY_THRESHOLD:-1 day}"
DEAD_TUPLE_MIN="${DEAD_TUPLE_MIN:-10000}"
DEAD_TUPLE_PCT="${DEAD_TUPLE_PCT:-20}"
TOP_SQL_LIMIT="${TOP_SQL_LIMIT:-20}"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
HOSTNAME_VALUE="$(hostname)"
REPORT_FILE="$REPORT_DIR/postgres_daily_check_${HOSTNAME_VALUE}_${DB_NAME}_${RUN_TS}.log"

mkdir -p "$REPORT_DIR"

PSQL_BASE=(psql -X -v ON_ERROR_STOP=0 -U "$DB_USER" -d "$DB_NAME")
if [ -n "$DB_PORT" ]; then
  PSQL_BASE+=(-p "$DB_PORT")
fi
if [ -n "$DB_HOST" ]; then
  PSQL_BASE+=(-h "$DB_HOST")
fi

query_setting() {
  local setting_name="$1"
  "${PSQL_BASE[@]}" -Atc "SELECT current_setting('$setting_name', true);" 2>/dev/null | head -1
}

DATA_DIRECTORY="$(query_setting data_directory)"
SERVER_PORT="$(query_setting port)"
CONFIG_FILE="$(query_setting config_file)"
CONFIG_LOG_DIRECTORY="$(query_setting log_directory)"

if [ -z "$DATA_DIRECTORY" ] && [ -n "$PGDATA" ]; then
  DATA_DIRECTORY="$PGDATA"
fi

if [ -z "$DATA_DIRECTORY" ]; then
  DATA_DIRECTORY="unknown"
fi

if [ -n "${LOG_DIR:-}" ]; then
  RESOLVED_LOG_DIR="$LOG_DIR"
elif [ -z "$CONFIG_LOG_DIRECTORY" ]; then
  RESOLVED_LOG_DIR="$DATA_DIRECTORY/log"
elif [[ "$CONFIG_LOG_DIRECTORY" = /* ]]; then
  RESOLVED_LOG_DIR="$CONFIG_LOG_DIRECTORY"
else
  RESOLVED_LOG_DIR="$DATA_DIRECTORY/$CONFIG_LOG_DIRECTORY"
fi

run_section() {
  local title="$1"
  shift
  {
    echo
    echo "================================================================================"
    echo "$title"
    echo "================================================================================"
    "$@"
  } >> "$REPORT_FILE" 2>&1
}

run_sql() {
  local sql_file="$1"
  "${PSQL_BASE[@]}" \
    -v long_query_threshold="$LONG_QUERY_THRESHOLD" \
    -v idle_xact_threshold="$IDLE_XACT_THRESHOLD" \
    -v autovacuum_delay_threshold="$AUTOVACUUM_DELAY_THRESHOLD" \
    -v dead_tuple_min="$DEAD_TUPLE_MIN" \
    -v dead_tuple_pct="$DEAD_TUPLE_PCT" \
    -v top_sql_limit="$TOP_SQL_LIMIT" \
    -f "$sql_file"
}

{
  echo "PostgreSQL Daily Check"
  echo "host=$HOSTNAME_VALUE"
  echo "db=$DB_NAME"
  echo "user=$DB_USER"
  echo "requested_port=${DB_PORT:-psql_default}"
  echo "server_port=${SERVER_PORT:-unknown}"
  echo "pgdata=${PGDATA:-not_set}"
  echo "data_directory=$DATA_DIRECTORY"
  echo "config_file=$CONFIG_FILE"
  echo "log_directory_setting=$CONFIG_LOG_DIRECTORY"
  echo "resolved_log_dir=$RESOLVED_LOG_DIR"
  echo "script_started_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
} > "$REPORT_FILE"

run_section "00. DB Connectivity" bash -c '
  user="$1"
  db="$2"
  port="$3"
  host="$4"

  if command -v pg_isready >/dev/null 2>&1; then
    args=(-U "$user" -d "$db")
    [ -n "$port" ] && args+=(-p "$port")
    [ -n "$host" ] && args+=(-h "$host")
    pg_isready "${args[@]}"
  else
    echo "pg_isready not found; using psql SELECT 1"
    args=(psql -X -v ON_ERROR_STOP=0 -U "$user" -d "$db")
    [ -n "$port" ] && args+=(-p "$port")
    [ -n "$host" ] && args+=(-h "$host")
    "${args[@]}" -c "select 1;"
  fi
' _ "$DB_USER" "$DB_NAME" "$DB_PORT" "$DB_HOST"

run_section "01. Instance Health / Restart Check" run_sql "$SQL_DIR/01_instance_health.sql"

run_section "02. PostgreSQL Log FATAL / PANIC / ERROR In Last 24 Hours" bash -c '
  log_dir="$0"
  if [ ! -d "$log_dir" ]; then
    echo "Log directory not found: $log_dir"
    exit 0
  fi
  find "$log_dir" -type f -mtime -1 \( -name "*.log" -o -name "postgresql-*.csv" -o -name "*.csv" \) -print0 |
    xargs -0 grep -nE "FATAL|PANIC|ERROR" 2>/dev/null || true
' "$RESOLVED_LOG_DIR"

run_section "03. Disk Usage / WAL Directory Usage" bash -c '
  pgdata="$0"
  if [ "$pgdata" = "unknown" ] || [ ! -d "$pgdata" ]; then
    echo "PGDATA/data_directory not found: $pgdata"
    exit 0
  fi

  echo "# df -h PGDATA"
  df -h "$pgdata" || true
  echo
  echo "# du -sh PGDATA"
  du -sh "$pgdata" 2>/dev/null || true
  echo
  echo "# du -sh pg_wal"
  du -sh "$pgdata/pg_wal" 2>/dev/null || true
  echo
  echo "# WAL file count"
  find "$pgdata/pg_wal" -maxdepth 1 -type f 2>/dev/null | wc -l || true
  echo
  echo "# archive_status"
  if [ -d "$pgdata/pg_wal/archive_status" ]; then
    find "$pgdata/pg_wal/archive_status" -type f | sed "s#^#  #" | tail -100
  else
    echo "archive_status directory not found"
  fi
' "$DATA_DIRECTORY"

run_section "04. WAL / Archiver / Replication Slot Backlog" run_sql "$SQL_DIR/02_wal_and_archiver.sql"
run_section "05. Long Query / Idle In Transaction / Lock" run_sql "$SQL_DIR/03_long_queries_idle_locks.sql"
run_section "06. Replication Lag" run_sql "$SQL_DIR/04_replication_lag.sql"
run_section "07. Dead Tuple / Autovacuum Delay" run_sql "$SQL_DIR/05_dead_tuple_autovacuum.sql"
run_section "08. XID Age" run_sql "$SQL_DIR/06_xid_age.sql"
run_section "09. pg_stat_statements TOP SQL" run_sql "$SQL_DIR/07_pg_stat_statements_top.sql"

{
  echo
  echo "================================================================================"
  echo "Finished"
  echo "================================================================================"
  echo "script_finished_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "report_file=$REPORT_FILE"
} >> "$REPORT_FILE"

echo "$REPORT_FILE"
