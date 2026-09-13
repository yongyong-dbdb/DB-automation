from pathlib import Path
import subprocess

target = Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
base = subprocess.check_output([
    'git','show','07f396e0f365724f3e455d5dc583be2d415fe253:PostgreSQL/postgresql_role_switch_v0.1.22.sh'
], text=True)
s = base

# 1) Fix psql variable interpolation: stdin, not -c.
start = s.index('psql_call_var() {')
end = s.index('\nsetting_exists() {', start)
new_helper = r'''psql_call_var() {
    pcv_name=$1
    pcv_value=$2
    pcv_sql=$3
    # psql variable interpolation (for example :'name') is performed by the
    # psql client. Feed SQL via stdin so -v NAME=VALUE substitution occurs
    # before PostgreSQL parses the statement.
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
s = s[:start] + new_helper + s[end:]

# 2) Make rollback-state creation atomic.
old = '''preconfigure_former_primary() {
    pfp_conninfo=$1
    pfp_slot=$2
    pfp_restore_file="$STATE_DIR/$STATE_KEY.switchover.config.restore.sql"
    [ ! -e "$pfp_restore_file" ] || die "Existing Switchover restore state exists: $pfp_restore_file"

    # Save exact effective values as SQL so secrets do not need shell parsing.
    psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_conninfo = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_conninfo;' END FROM pg_settings WHERE name='primary_conninfo'" > "$pfp_restore_file" || die "Could not save primary_conninfo rollback state."
    psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_slot_name = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_slot_name;' END FROM pg_settings WHERE name='primary_slot_name'" >> "$pfp_restore_file" || die "Could not save primary_slot_name rollback state."
    psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET recovery_target_timeline = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET recovery_target_timeline;' END FROM pg_settings WHERE name='recovery_target_timeline'" >> "$pfp_restore_file" || die "Could not save recovery_target_timeline rollback state."
    chmod 600 "$pfp_restore_file" || die "Could not protect Switchover restore state: $pfp_restore_file"

    # Set the rollback guard before the first non-transactional ALTER SYSTEM.
'''
new = '''preconfigure_former_primary() {
    pfp_conninfo=$1
    pfp_slot=$2
    pfp_restore_file="$STATE_DIR/$STATE_KEY.switchover.config.restore.sql"
    pfp_restore_tmp="$pfp_restore_file.tmp.$$"
    [ ! -e "$pfp_restore_file" ] || die "Existing Switchover restore state exists: $pfp_restore_file"
    [ ! -e "$pfp_restore_tmp" ] || rm -f "$pfp_restore_tmp" || die "Could not clear stale temporary Switchover restore state: $pfp_restore_tmp"

    # Build the complete rollback script first. Never leave a partial final
    # restore file if a query fails before ALTER SYSTEM staging begins.
    if ! {
        psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_conninfo = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_conninfo;' END FROM pg_settings WHERE name='primary_conninfo'" &&
        psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_slot_name = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_slot_name;' END FROM pg_settings WHERE name='primary_slot_name'" &&
        psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET recovery_target_timeline = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET recovery_target_timeline;' END FROM pg_settings WHERE name='recovery_target_timeline'"
    } > "$pfp_restore_tmp"; then
        rm -f "$pfp_restore_tmp"
        die "Could not save complete Switchover rollback state. No final restore file was created."
    fi
    chmod 600 "$pfp_restore_tmp" || { rm -f "$pfp_restore_tmp"; die "Could not protect temporary Switchover restore state: $pfp_restore_tmp"; }
    [ -s "$pfp_restore_tmp" ] || { rm -f "$pfp_restore_tmp"; die "Generated Switchover rollback state is empty."; }
    mv "$pfp_restore_tmp" "$pfp_restore_file" || { rm -f "$pfp_restore_tmp"; die "Could not finalize Switchover restore state: $pfp_restore_file"; }

    # Set the rollback guard before the first non-transactional ALTER SYSTEM.
'''
if old not in s:
    raise SystemExit('preconfigure_former_primary base block not found')
s = s.replace(old, new, 1)

target.write_text(s)
