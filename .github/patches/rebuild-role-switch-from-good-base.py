from pathlib import Path
import subprocess

target = Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s = subprocess.check_output([
    'git','show','315e9d2a3b68801e117dc1726f4383b5e2e7cbe8:PostgreSQL/postgresql_role_switch_v0.1.22.sh'
], text=True)

# 1) Rewrite only executable lines inside psql_call_var(). Do not replace or
# slice whole function ranges; this avoids deleting unrelated definitions.
lines=s.splitlines()
try:
    helper_start=lines.index('psql_call_var() {')
    helper_end=lines.index('setting_exists() {', helper_start+1)
except ValueError as e:
    raise SystemExit(f'psql_call_var boundary not found: {e}')
changed=0
for i in range(helper_start+1, helper_end):
    line=lines[i]
    if '$PSQL_BIN' in line and '-c "$pcv_sql"' in line:
        line=line.replace(' -c "$pcv_sql"','')
        lines[i]="        printf '%s\\n' \"$pcv_sql\" | " + line.lstrip()
        changed += 1
if changed != 5:
    raise SystemExit(f'expected 5 psql_call_var command branches, rewrote {changed}')
s='\n'.join(lines)+'\n'

# 2) Explicit physical-slot options. Existing branch behavior is preserved;
# only make temporary=false explicit for newly-created reverse slots.
old_slot="pg_create_physical_replication_slot(:'slot', true)"
if s.count(old_slot) != 1:
    raise SystemExit('expected one reverse slot creation call')
s=s.replace(old_slot, "pg_create_physical_replication_slot(:'slot', true, false)", 1)

# Preserve precheck state for the execution-plan display.
old_state='        css_slot_state=$(printf \'%s\\n\' "$css_slot_line" | awk -F \'\\t\' \'{print $3}\')\n        [ "$css_slot_name" = "$css_reverse_slot" ] || die "Reverse replication slot state response name mismatch: expected=$css_reverse_slot observed=${css_slot_name:-<empty>}"\n'
new_state=old_state + '        REVERSE_SLOT_PRECHECK_STATE=$css_slot_state\n'
if old_state not in s:
    raise SystemExit('reverse slot precheck state block not found')
s=s.replace(old_state,new_state,1)

# Make the execution plan describe all slot branches and explicit options.
old_plan='''    say "  7. Create/verify reverse physical replication slot when configured"\n    [ -z "${REVERSE_SLOT:-}" ] || printf "     SELECT pg_create_physical_replication_slot('%s', true);\\n" "$REVERSE_SLOT"\n'''
new_plan='''    say "  7. Create/verify reverse physical replication slot when configured"\n    if [ -n "${REVERSE_SLOT:-}" ]; then\n        printf '     Precheck state: %s\\n' "${REVERSE_SLOT_PRECHECK_STATE:-unknown}"\n        say "     Revalidate pg_replication_slots on the promoted New Primary before changing anything."\n        say "     absent            -> create persistent slot with immediately_reserve=true, temporary=false"\n        printf "        SELECT pg_create_physical_replication_slot('%s', true, false);\\n" "$REVERSE_SLOT"\n        say "     physical_inactive -> reuse the existing physical slot; do not recreate it"\n        say "     physical_active   -> abort; an active slot is not reassigned"\n        say "     conflict          -> abort; same slot_name is not a reusable physical slot"\n    else\n        say "     No reverse physical replication slot configured."\n    fi\n'''
if old_plan not in s:
    raise SystemExit('execution plan reverse slot block not found')
s=s.replace(old_plan,new_plan,1)

# 3) Build rollback state atomically so a failed query cannot leave an empty or
# partial final restore file that blocks the next run.
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

    # Save exact effective values as SQL in a temporary file first so secrets
    # do not need shell parsing and a query failure cannot leave partial state.
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
s=s.replace(old,new,1)

target.write_text(s)
