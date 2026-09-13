from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
old='''preconfigure_former_primary() {
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
new='''preconfigure_former_primary() {
    pfp_conninfo=$1
    pfp_slot=$2
    pfp_restore_file="$STATE_DIR/$STATE_KEY.switchover.config.restore.sql"
    pfp_restore_tmp="$pfp_restore_file.tmp.$$"
    [ ! -e "$pfp_restore_file" ] || die "Existing Switchover restore state exists: $pfp_restore_file"
    [ ! -e "$pfp_restore_tmp" ] || rm -f "$pfp_restore_tmp" || die "Could not clear stale temporary Switchover restore state: $pfp_restore_tmp"

    # Build the rollback script completely in a temporary file first. Do not
    # expose a partial/empty final restore file if any SQL query fails.
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
if old not in s: raise SystemExit('target block not found')
s=s.replace(old,new,1)
p.write_text(s)
