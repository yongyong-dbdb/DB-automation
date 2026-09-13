from pathlib import Path

p = Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s = p.read_text()
old = '''revalidate_switchover_topology() {
    rst_selected_identity=$(psql_call_var pid "$CANDIDATE_PID" "SELECT application_name || E'\\\\t' || COALESCE(host(client_addr),'local') || E'\\\\t' || usename || E'\\\\t' || state || E'\\\\t' || COALESCE((SELECT slot_name FROM pg_replication_slots s WHERE s.active_pid=r.pid LIMIT 1),'') FROM pg_stat_replication r WHERE pid=:'pid'::integer LIMIT 1" 2>/dev/null | sed -n '1p') || rst_selected_identity=""
    rst_expected_identity=$(printf '%s\\t%s\\t%s\\tstreaming\\t%s' "$CANDIDATE_APP" "$CANDIDATE_CLIENT" "$CANDIDATE_REPL_USER" "${CANDIDATE_SLOT:-}")
    if [ "$rst_selected_identity" != "$rst_expected_identity" ]; then
        rollback_preconfigured_primary
        die "Selected pg_stat_replication row changed or left state=streaming."
    fi

'''
new = '''revalidate_switchover_topology() {
    # A WAL sender PID is connection-scoped and can legitimately change when a
    # Standby reconnects. Do not use pid as the durable identity of the selected
    # Standby. Re-identify it by stable connection attributes plus the physical
    # replication slot (when present), and require exactly one streaming row.
    rst_app_sql=$(printf "%s" "$CANDIDATE_APP" | sed "s/'/''/g")
    rst_client_sql=$(printf "%s" "$CANDIDATE_CLIENT" | sed "s/'/''/g")
    rst_user_sql=$(printf "%s" "$CANDIDATE_REPL_USER" | sed "s/'/''/g")
    rst_slot_sql=$(printf "%s" "${CANDIDATE_SLOT:-}" | sed "s/'/''/g")
    rst_match=$(psql_call "SELECT count(*)::text || E'\\\\t' || COALESCE(min(pid)::text,'') FROM pg_stat_replication r WHERE state='streaming' AND application_name='$rst_app_sql' AND COALESCE(host(client_addr),'local')='$rst_client_sql' AND usename='$rst_user_sql' AND COALESCE((SELECT slot_name FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical' LIMIT 1),'')='$rst_slot_sql'" 2>/dev/null | sed -n '1p') || rst_match=""
    rst_match_count=$(printf '%s\\n' "$rst_match" | awk -F '\\t' '{print $1}')
    rst_current_pid=$(printf '%s\\n' "$rst_match" | awk -F '\\t' '{print $2}')
    case "$rst_match_count" in
        1) ;;
        0|"")
            rollback_preconfigured_primary
            die "Selected Standby is no longer uniquely present in pg_stat_replication with the expected application_name, client_addr, usename, physical slot and state=streaming."
            ;;
        *)
            rollback_preconfigured_primary
            die "Multiple pg_stat_replication rows match the selected Standby identity; refusing Planned Switchover because the candidate cannot be identified uniquely."
            ;;
    esac
    if [ -n "$rst_current_pid" ] && [ "$rst_current_pid" != "$CANDIDATE_PID" ]; then
        info "Selected Standby WAL sender reconnected: pg_stat_replication.pid changed from $CANDIDATE_PID to $rst_current_pid; stable identity is unchanged and state=streaming."
        CANDIDATE_PID=$rst_current_pid
    fi

'''
if old not in s:
    raise SystemExit('target revalidation block not found')
s=s.replace(old,new,1)
p.write_text(s)
