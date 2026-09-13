from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

# Add a dedicated three-variable psql helper. Do not change the existing one-variable helper contract.
marker='''psql_call_var() {\n    pcv_name=$1\n    pcv_value=$2\n    pcv_sql=$3\n'''
if marker not in s:
    raise SystemExit('psql_call_var marker missing')
end='''}\n\ntry_connect_local() {\n'''
idx=s.index(marker)
end_idx=s.index(end, idx)
helper=r'''psql_call_var3() {
    pcv3_name1=$1
    pcv3_value1=$2
    pcv3_name2=$3
    pcv3_value2=$4
    pcv3_name3=$5
    pcv3_value3=$6
    pcv3_sql=$7
    if [ -n "$PGUSER_LOCAL" ] && [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        printf '%s\n' "$pcv3_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv3_name1=$pcv3_value1" -v "$pcv3_name2=$pcv3_value2" -v "$pcv3_name3=$pcv3_value3" -U "$PGUSER_LOCAL" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME"
    elif [ -n "$PGUSER_LOCAL" ] && [ -n "$PGPORT" ]; then
        printf '%s\n' "$pcv3_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv3_name1=$pcv3_value1" -v "$pcv3_name2=$pcv3_value2" -v "$pcv3_name3=$pcv3_value3" -U "$PGUSER_LOCAL" -p "$PGPORT" -d "$DB_NAME"
    elif [ -n "$SOCKET_DIR" ] && [ -n "$PGPORT" ]; then
        printf '%s\n' "$pcv3_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv3_name1=$pcv3_value1" -v "$pcv3_name2=$pcv3_value2" -v "$pcv3_name3=$pcv3_value3" -h "$SOCKET_DIR" -p "$PGPORT" -d "$DB_NAME"
    elif [ -n "$PGPORT" ]; then
        printf '%s\n' "$pcv3_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv3_name1=$pcv3_value1" -v "$pcv3_name2=$pcv3_value2" -v "$pcv3_name3=$pcv3_value3" -p "$PGPORT" -d "$DB_NAME"
    else
        printf '%s\n' "$pcv3_sql" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "$pcv3_name1=$pcv3_value1" -v "$pcv3_name2=$pcv3_value2" -v "$pcv3_name3=$pcv3_value3" -d "$DB_NAME"
    fi
}

'''
s=s[:end_idx+2]+'\n\n'+helper+s[end_idx+3:]

# Fix verifier to use the actual three-variable helper.
old='''    rcr_count=$(psql_call_var app "$rcr_app" client "$rcr_client" slot "$rcr_slot" "SELECT count(*) FROM pg_stat_replication r WHERE state='streaming' AND application_name=:'app' AND COALESCE(host(client_addr),'local')=:'client' AND (CASE WHEN :'slot'='' THEN NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical') ELSE EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical' AND s.slot_name=:'slot') END)" 2>/dev/null | tr -d '[:space:]') || exit 3\n'''
new='''    rcr_count=$(psql_call_var3 app "$rcr_app" client "$rcr_client" slot "$rcr_slot" "SELECT count(*) FROM pg_stat_replication r WHERE state='streaming' AND application_name=:'app' AND COALESCE(host(client_addr),'local')=:'client' AND (CASE WHEN :'slot'='' THEN NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical') ELSE EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical' AND s.slot_name=:'slot') END)" 2>/dev/null | tr -d '[:space:]') || exit 3\n'''
if old not in s:
    raise SystemExit('remote_count_reparented call marker missing')
s=s.replace(old,new,1)

# Expand execution plan details, including nested cascade relationships.
old='''    if [ "${REPARENT_UNSELECTED:-0}" -eq 1 ] 2>/dev/null; then
        say ""
        say " 11. Reparent existing Unselected Direct Standby Servers to the New Primary"
        say "     Create/reuse validated physical slots on the New Primary when configured."
        say "     Update each Standby's primary_conninfo/primary_slot_name only after promotion and verify pg_stat_wal_receiver.status=streaming."
        say "     Preserve each Standby's existing downstream cascade relationships."
    fi
'''
new=r'''    if [ "${REPARENT_UNSELECTED:-0}" -eq 1 ] 2>/dev/null; then
        say ""
        say " 11. Reparent existing Unselected Direct Standby Servers to the New Primary"
        say "     Create/reuse validated physical slots on the New Primary when configured."
        say "     Update each Standby's primary_conninfo/primary_slot_name only after promotion and verify pg_stat_wal_receiver.status=streaming."
        say "     Preserve each Standby's existing downstream cascade relationships."
        if [ -n "${UNSELECTED_REPARENT_PLAN:-}" ] && [ -f "$UNSELECTED_REPARENT_PLAN" ]; then
            while IFS='|' read -r ssep_transport ssep_target ssep_pgdata ssep_app ssep_client ssep_user ssep_slot ssep_conninfo_file ssep_nested_count ssep_relations <&3; do
                [ -n "$ssep_pgdata" ] || continue
                say ""
                printf '     Reparent target          : application_name=%s | client_addr=%s\n' "$ssep_app" "$ssep_client"
                printf '     data_directory          : %s\n' "$ssep_pgdata"
                printf '     Existing upstream       : Current Primary (port=%s)\n' "$PGPORT"
                printf '     New upstream            : %s:%s\n' "$NEW_PRIMARY_DB_HOST" "$REMOTE_PORT"
                printf '     New Primary slot        : %s\n' "${ssep_slot:-<none>}"
                printf '     Existing downstreams    : %s\n' "$ssep_nested_count"
                if [ "$ssep_nested_count" -gt 0 ] 2>/dev/null; then
                    say "     Cascade preservation     : required"
                    if [ -n "$ssep_relations" ] && [ -f "$ssep_relations" ]; then
                        while IFS="$TAB" read -r ssep_child_app ssep_child_client ssep_child_slot <&4; do
                            [ -n "$ssep_child_app$ssep_child_client$ssep_child_slot" ] || continue
                            printf '       preserve downstream  : application_name=%s | client_addr=%s | slot_name=%s\n' "$ssep_child_app" "$ssep_child_client" "${ssep_child_slot:-<none>}"
                        done 4< "$ssep_relations"
                    fi
                else
                    say "     Cascade preservation     : no existing downstream"
                fi
            done 3< "$UNSELECTED_REPARENT_PLAN"
        fi
    fi
'''
if old not in s:
    raise SystemExit('execution plan marker missing')
s=s.replace(old,new,1)

p.write_text(s)
