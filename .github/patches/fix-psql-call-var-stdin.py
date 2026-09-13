from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
start=s.index('psql_call_var() {')
end=s.index('\nsetting_exists() {', start)
new=r'''psql_call_var() {
    pcv_name=$1
    pcv_value=$2
    pcv_sql=$3
    # psql -c requires a command string that is directly parseable by the
    # server, so psql-specific :'var' interpolation is not available there.
    # Feed SQL through stdin instead so -v NAME=VALUE interpolation is applied
    # by psql before the statement is sent to PostgreSQL.
    if [ -n "$PGUSER_LOCAL" ] && [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        printf '%s\n' "$pcv_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -U "$PGUSER_LOCAL" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME"
    elif [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        printf '%s\n' "$pcv_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME"
    elif [ -n "$PGUSER_LOCAL" ]; then
        printf '%s\n' "$pcv_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -U "$PGUSER_LOCAL" -d "$DB_NAME"
    else
        printf '%s\n' "$pcv_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv_name=$pcv_value" -d "$DB_NAME"
    fi
}
'''
s=s[:start]+new+s[end:]
p.write_text(s)
