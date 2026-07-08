#!/usr/bin/env bash
set -u

DB_NAME="${DB_NAME:-postgres}"
DB_USER="${DB_USER:-postgres}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-5432}"
PGDATA="${PGDATA:-/home/postgres/data}"
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

PSQL_BASE=(psql -X -v ON_ERROR_STOP=0 -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT")
if [ -n "$DB_HOST" ]; then
  PSQL_BASE+=(-h "$DB_HOST")
fi

query_setting() {
  local setting_name="$1"
  "${PSQL_BASE[@]}" -Atc "SELECT current_setting('$setting_name', true);" 2>/dev/null | head -1
}

DATA_DIRECTORY="$(query_setting data_directory)"
CONFIG_FILE="$(query_setting config_file)"
CONFIG_LOG_DIRECTORY="$(query_setting log_directory)"

if [ -z "$DATA_DIRECTORY" ]; then
  DATA_DIRECTORY="$PGDATA"
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
  echo "port=$DB_PORT"
  echo "pgdata=$PGDATA"
  echo "data_directory=$DATA_DIRECTORY"
  echo "config_file=$CONFIG_FILE"
  echo "log_directory_setting=$CONFIG_LOG_DIRECTORY"
  echo "resolved_log_dir=$RESOLVED_LOG_DIR"
  echo "script_started_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
} > "$REPORT_FILE"

run_section "00. DB Connectivity" bash -c '
  if command -v pg_isready >/dev/null 2>&1; then
    pg_isready -U "$0" -d "$1" -p "$2" ${3:+-h "$3"}
  else
    echo "pg_isready not found; using psql SELECT 1"
  fi
' "$DB_USER" "$DB_NAME" "$DB_PORT" "$DB_HOST"

run_section "01. Instance Health / Restart Check" run_sql "$SQL_DIR/01_instance_health.sql"

run_section "02. PostgreSQL Log FATAL / PANIC / ERROR In Last 24 Hours" bash -c '
  log_dir="$0"
  if [ ! -d "$log_dir" ]; then
    echo "Log directory not found: $log_dir"
    exit 0
  fi

  log_files="$(find "$log_dir" -type f -mtime -1 \( -name "*.log" -o -name "postgresql-*.csv" -o -name "*.csv" \) -print)"
  if [ -z "$log_files" ]; then
    echo "No PostgreSQL log files found in last 24 hours"
    exit 0
  fi

  echo "$log_files" | xargs awk "
    BEGIN {
      found = 0
    }
    match(\$0, /(PANIC|FATAL|ERROR):[[:space:]]*(.*)/, m) {
      found = 1
      level = m[1]
      message = m[2]
      sub(/[[:space:]]+$/, \"\", message)

      key = level SUBSEP message
      level_count[level]++
      message_count[key]++

      if (!(key in key_seen)) {
        key_seen[key] = 1
        key_order[++key_total] = key
        key_level[key] = level
        key_message[key] = message
      }

      timestamp = substr(\$0, 1, 23)
      recent_index[key] = (recent_index[key] % 5) + 1
      recent_time[key, recent_index[key]] = timestamp
    }
    END {
      if (!found) {
        print \"No FATAL/PANIC/ERROR logs found in last 24 hours\"
        exit
      }

      print \"## Log Level Summary\"
      printf \"%-8s %s\\n\", \"level\", \"count\"
      for (level in level_count) {
        printf \"%-8s %d\\n\", level, level_count[level]
      }

      print \"\"
      print \"## Repeated Message Summary\"
      printf \"%-8s %-8s %s\\n\", \"level\", \"count\", \"message\"
      for (i = 1; i <= key_total; i++) {
        key = key_order[i]
        printf \"%-8s %-8d %s\\n\", key_level[key], message_count[key], key_message[key]
      }

      print \"\"
      print \"## Recent 5 Occurrences Per Message\"
      for (i = 1; i <= key_total; i++) {
        key = key_order[i]
        print \"[\" key_level[key] \"] \" key_message[key]

        total = message_count[key]
        if (total < 5) {
          start = 1
          limit = total
        } else {
          start = (recent_index[key] % 5) + 1
          limit = 5
        }

        for (j = 0; j < limit; j++) {
          pos = ((start + j - 1) % 5) + 1
          if ((key, pos) in recent_time) {
            print \"  \" recent_time[key, pos]
          }
        }
        print \"\"
      }
    }
  "
' "$RESOLVED_LOG_DIR"

run_section "03. Disk Usage / WAL Directory Usage" bash -c '
  pgdata="$0"
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
' "$PGDATA"

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
