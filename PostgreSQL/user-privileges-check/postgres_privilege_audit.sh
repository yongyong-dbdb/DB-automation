#!/bin/sh
set -u

DB_NAME="${DB_NAME:-${PGDATABASE:-}}"
DB_USER="${DB_USER:-${PGUSER:-}}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-${PGPORT:-${PG_PORT:-}}}"
REPORT_DIR="${REPORT_DIR:-$HOME/postgres_audit_reports}"
SQL_DIR="${SQL_DIR:-$(cd "$(dirname "$0")/sql_audit" && pwd)}"
ALLOWED_SUPERUSERS="${ALLOWED_SUPERUSERS:-postgres}"
SYSTEM_ROLE_REGEX="${SYSTEM_ROLE_REGEX:-^pg_}"
EXCLUDED_SCHEMA_REGEX="${EXCLUDED_SCHEMA_REGEX:-^(pg_|information_schema$)}"
PUBLIC_GRANTEE="${PUBLIC_GRANTEE:-public}"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
HOSTNAME_VALUE="$(hostname)"
DB_NAME_LABEL="${DB_NAME:-psql_default}"
REPORT_FILE="$REPORT_DIR/postgres_privilege_audit_${HOSTNAME_VALUE}_${DB_NAME_LABEL}_${RUN_TS}.log"

mkdir -p "$REPORT_DIR"

if [ -n "$DB_USER" ]; then
  PGUSER="$DB_USER"
  export PGUSER
fi
if [ -n "$DB_NAME" ]; then
  PGDATABASE="$DB_NAME"
  export PGDATABASE
fi
if [ -n "$DB_PORT" ]; then
  PGPORT="$DB_PORT"
  export PGPORT
fi
if [ -n "$DB_HOST" ]; then
  PGHOST="$DB_HOST"
  export PGHOST
fi

run_psql() {
  psql -X -v ON_ERROR_STOP=0 "$@"
}

query_setting() {
  setting_name="$1"
  run_psql -Atc "SELECT current_setting('$setting_name', true);" 2>/dev/null | head -1
}

query_sql() {
  sql="$1"
  run_psql -Atc "$sql" 2>/dev/null | head -1
}

SERVER_PORT="$(query_setting port)"
SERVER_VERSION="$(query_setting server_version)"
SERVER_DATABASE="$(query_sql 'SELECT current_database();')"
SERVER_USER="$(query_sql 'SELECT current_user;')"

run_section() {
  title="$1"
  sql_file="$2"
  {
    echo
    echo "================================================================================"
    echo "$title"
    echo "================================================================================"
    run_psql \
      -v allowed_superusers="$ALLOWED_SUPERUSERS" \
      -v system_role_regex="$SYSTEM_ROLE_REGEX" \
      -v excluded_schema_regex="$EXCLUDED_SCHEMA_REGEX" \
      -v public_grantee="$PUBLIC_GRANTEE" \
      -f "$sql_file"
  } >> "$REPORT_FILE" 2>&1
}

{
  echo "PostgreSQL Account / Privilege Audit"
  echo "host=$HOSTNAME_VALUE"
  echo "server_db=${SERVER_DATABASE:-unknown}"
  echo "server_user=${SERVER_USER:-unknown}"
  echo "server_port=${SERVER_PORT:-unknown}"
  echo "server_version=${SERVER_VERSION:-unknown}"
  echo "allowed_superusers=$ALLOWED_SUPERUSERS"
  echo "system_role_regex=$SYSTEM_ROLE_REGEX"
  echo "excluded_schema_regex=$EXCLUDED_SCHEMA_REGEX"
  echo "public_grantee=$PUBLIC_GRANTEE"
  echo "script_started_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
} > "$REPORT_FILE"

run_section "01. Audit Findings Summary" "$SQL_DIR/01_findings.sql"
run_section "02. Role Attributes" "$SQL_DIR/02_roles.sql"
run_section "03. Database Privileges" "$SQL_DIR/03_database_privileges.sql"
run_section "04. Schema Privileges" "$SQL_DIR/04_schema_privileges.sql"
run_section "05. Table Privileges" "$SQL_DIR/05_table_privileges.sql"
run_section "06. Sequence Privileges" "$SQL_DIR/06_sequence_privileges.sql"
run_section "07. Default Privileges" "$SQL_DIR/07_default_privileges.sql"
run_section "08. Object Owners" "$SQL_DIR/08_object_owners.sql"

{
  echo
  echo "================================================================================"
  echo "Finished"
  echo "================================================================================"
  echo "script_finished_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "report_file=$REPORT_FILE"
} >> "$REPORT_FILE"

echo "$REPORT_FILE"
