from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

# Globals
old='''PRESERVED_TOPOLOGY_EDGES=""
LOCK_HELD=0
'''
new='''PRESERVED_TOPOLOGY_EDGES=""
UNSELECTED_REPARENT_CANDIDATES=""
UNSELECTED_REPARENT_PLAN=""
REPARENT_UNSELECTED=0
REPARENT_ADDITIONAL_SLOT_COUNT=0
LOCK_HELD=0
'''
if old not in s: raise SystemExit('globals marker not found')
s=s.replace(old,new,1)

# Neutralize unselected topology wording and initialize reparent candidate file.
old='''    mktemp_safe || die "Could not create an Unselected Standby topology snapshot file."
    UNSELECTED_TOPOLOGY_SNAPSHOT=$SAFE_TMP
    : > "$UNSELECTED_TOPOLOGY_SNAPSHOT" || die "Could not initialize Unselected Standby topology snapshot."

    say ""
    say "Unselected Standby Validation"
    say "  아래 서버는 새 Primary 후보가 아닙니다. 선택한 Standby 외에 현재 Primary에 직접 연결된 나머지 Standby를 검증합니다."
    say "  현재 설계에서는 Planned Switchover 후 former Primary가 Standby가 되고, 이 Unselected Standby는 former Primary를 계속 Upstream으로 사용하는 Cascading Standby 구조를 유지합니다."
    say "  예상 토폴로지: Selected Standby (New Primary) -> Former Primary (Standby) -> Unselected Standby"
    say "  system_identifier, sender_port, slot_name, pg_stat_wal_receiver.status 및 recovery_target_timeline을 확인합니다."
'''
new='''    mktemp_safe || die "Could not create an Unselected Standby topology snapshot file."
    UNSELECTED_TOPOLOGY_SNAPSHOT=$SAFE_TMP
    : > "$UNSELECTED_TOPOLOGY_SNAPSHOT" || die "Could not initialize Unselected Standby topology snapshot."
    mktemp_safe || die "Could not create an Unselected Standby reparent candidate file."
    UNSELECTED_REPARENT_CANDIDATES=$SAFE_TMP
    : > "$UNSELECTED_REPARENT_CANDIDATES" || die "Could not initialize Unselected Standby reparent candidate file."

    say ""
    say "Unselected Standby Validation"
    say "  아래 서버는 새 Primary 후보가 아닙니다. 선택한 Standby 외에 현재 Primary에 직접 연결된 나머지 Direct Standby를 검증합니다."
    say "  Planned Switchover 실행 전에 이 Direct Standby들을 New Primary로 직접 재배치할지 운영자가 선택합니다. 기본값은 기존 Upstream 유지입니다."
    say "  각 Standby의 system_identifier, sender_port, slot_name, pg_stat_wal_receiver.status, recovery_target_timeline 및 하위 cascade를 확인합니다."
'''
if old not in s: raise SystemExit('unselected header marker not found')
s=s.replace(old,new,1)

# Capture repl user and append candidate metadata + normalized descendants.
old='''        usc_client=$(printf '%s\\n' "$usc_line" | awk -F '\\t' '{print $3}')
        usc_slot=$(printf '%s\\n' "$usc_line" | awk -F '\\t' '{print $9}')
'''
new='''        usc_client=$(printf '%s\\n' "$usc_line" | awk -F '\\t' '{print $3}')
        usc_repl_user=$(printf '%s\\n' "$usc_line" | awk -F '\\t' '{print $4}')
        usc_slot=$(printf '%s\\n' "$usc_line" | awk -F '\\t' '{print $9}')
'''
if old not in s: raise SystemExit('unselected field marker not found')
s=s.replace(old,new,1)

old='''        append_preserved_topology_edge "$usc_transport" "$usc_target" "$usc_pgdata" "$usc_sender_host" "$usc_sender_port" "$usc_slot" "$usc_nested_count" "$usc_nested" "unselected-current-primary-downstream"
        info "Unselected Standby topology snapshot: $usc_app nested_downstream_count=$usc_nested_count"
'''
new='''        append_preserved_topology_edge "$usc_transport" "$usc_target" "$usc_pgdata" "$usc_sender_host" "$usc_sender_port" "$usc_slot" "$usc_nested_count" "$usc_nested" "unselected-current-primary-downstream"
        mktemp_safe || die "Could not create normalized nested downstream snapshot for $usc_app."
        usc_relations=$SAFE_TMP
        normalize_downstream_relation_set "$usc_nested" > "$usc_relations" || die "Could not normalize downstream relationships for $usc_app."
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' "$usc_transport" "$usc_target" "$usc_pgdata" "$usc_app" "$usc_client" "$usc_repl_user" "$usc_slot" "$usc_nested_count" "$usc_relations" >> "$UNSELECTED_REPARENT_CANDIDATES" || die "Could not save Unselected Standby reparent candidate metadata."
        info "Unselected Standby topology snapshot: $usc_app nested_downstream_count=$usc_nested_count"
'''
if old not in s: raise SystemExit('unselected candidate append marker not found')
s=s.replace(old,new,1)

# New controller-side helpers before wait_unselected_standbys.
marker='''wait_unselected_standbys() {
'''
helper=r'''prepare_unselected_reparent_plan() {
    REPARENT_UNSELECTED=0
    REPARENT_ADDITIONAL_SLOT_COUNT=0
    [ "${UNSELECTED_STANDBY_COUNT:-0}" -gt 0 ] 2>/dev/null || return 0
    [ -n "${UNSELECTED_REPARENT_CANDIDATES:-}" ] && [ -f "$UNSELECTED_REPARENT_CANDIDATES" ] || return 0

    say ""
    say "Unselected Direct Standby Placement"
    say "  기존 Primary의 Direct Standby들을 역할 전환 후 New Primary에 직접 연결할지 선택합니다."
    say "  No  : 기존 Upstream을 유지하여 New Primary -> Former Primary -> Unselected Standby 형태가 됩니다."
    say "  Yes : Unselected Direct Standby를 New Primary에 직접 재연결합니다. 각 Standby의 기존 하위 cascade는 유지합니다."
    if ! choose_yes_no "Move existing unselected Direct Standby Servers to the New Primary after promotion" "no"; then
        record_check "PASSED" "Unselected Standby Placement" "operator chose to preserve existing upstream relationships"
        return 0
    fi
    REPARENT_UNSELECTED=1
    mktemp_safe || die "Could not create Unselected Standby reparent plan."
    UNSELECTED_REPARENT_PLAN=$SAFE_TMP
    : > "$UNSELECTED_REPARENT_PLAN" || die "Could not initialize Unselected Standby reparent plan."

    while IFS='|' read -r urp_transport urp_target urp_pgdata urp_app urp_client urp_user urp_old_slot urp_nested_count urp_relations; do
        [ -n "$urp_pgdata" ] || continue
        say ""
        printf '  Reparent target: application_name=%s | client_addr=%s | user=%s | old slot=%s | nested downstreams=%s\n' "$urp_app" "$urp_client" "$urp_user" "${urp_old_slot:-<none>}" "$urp_nested_count"

        urp_hba_output=$(remote_invoke --remote-hba-check "$REMOTE_PGDATA" "$urp_client" "$urp_user" 2>/dev/null)
        urp_hba_rc=$?
        if [ "$urp_hba_rc" -eq 0 ]; then
            urp_hba_state=$(printf '%s\n' "$urp_hba_output" | awk -F '\t' '$1=="HBA_RESULT" {print $2; exit}')
            case "$urp_hba_state" in
                PASS) info "New Primary HBA permits physical replication for $urp_client / $urp_user." ;;
                FAIL) die "New Primary pg_hba.conf blocks physical replication for Unselected Standby $urp_client / role=$urp_user." ;;
                *)
                    if ! choose_yes_no "Authentication for $urp_client -> New Primary has been verified manually" "no"; then
                        die "Unselected Standby authentication was not confirmed for $urp_client."
                    fi
                    record_check "MANUAL CHECK" "Unselected Standby Authentication" "source=$urp_client role=$urp_user confirmed by operator"
                    ;;
            esac
        else
            if ! choose_yes_no "Authentication for $urp_client -> New Primary has been verified manually" "no"; then
                die "Could not verify New Primary authentication for Unselected Standby $urp_client."
            fi
            record_check "MANUAL CHECK" "Unselected Standby Authentication" "automatic HBA evaluation unavailable for source=$urp_client role=$urp_user"
        fi

        urp_host_q=$(conninfo_quote_value "$NEW_PRIMARY_DB_HOST")
        urp_user_q=$(conninfo_quote_value "$urp_user")
        urp_conninfo="host='$urp_host_q' port='$REMOTE_PORT' user='$urp_user_q'"
        if [ -n "$urp_app" ]; then
            urp_app_q=$(conninfo_quote_value "$urp_app")
            urp_conninfo="$urp_conninfo application_name='$urp_app_q'"
        fi
        say "  필요한 SSL/passfile 등 추가 libpq 파라미터를 입력할 수 있습니다. password= 직접 입력은 허용하지 않습니다."
        urp_extra=$(ask "Additional connection parameters for $urp_app (empty = none)" "") || usage_die "Input cancelled."
        if [ -n "$urp_extra" ]; then
            if printf '%s\n' "$urp_extra" | grep -E '(^|[[:space:]])(host|hostaddr|port|user|application_name|password)[[:space:]]*=' >/dev/null 2>&1; then
                die "Additional parameters for $urp_app must not override host/hostaddr/port/user/application_name and must not contain password=."
            fi
            urp_conninfo="$urp_conninfo $urp_extra"
        fi
        mktemp_safe || die "Could not create protected conninfo plan file for $urp_app."
        urp_conninfo_file=$SAFE_TMP
        printf '%s\n' "$urp_conninfo" > "$urp_conninfo_file" || die "Could not save generated conninfo for $urp_app."
        chmod 600 "$urp_conninfo_file" 2>/dev/null || true

        urp_slot_default=$urp_old_slot
        while :; do
            urp_slot=$(ask "New Primary physical slot for $urp_app (empty = no slot)" "$urp_slot_default") || usage_die "Input cancelled."
            if [ -z "$urp_slot" ]; then
                urp_slot_state=none
                break
            fi
            validate_replication_slot_name "$urp_slot" || { say "Invalid slot name. Use lower-case letters, numbers and underscore."; urp_slot_default=""; continue; }
            if [ -n "${REVERSE_SLOT:-}" ] && [ "$urp_slot" = "$REVERSE_SLOT" ]; then
                say "Slot '$urp_slot' is reserved for the Former Primary. Choose another slot."
                urp_slot_default=""
                continue
            fi
            urp_slot_output=$(remote_invoke --remote-slot-state "$REMOTE_PGDATA" "$urp_slot" 2>/dev/null)
            urp_slot_rc=$?
            [ "$urp_slot_rc" -eq 0 ] || classify_remote_failure "$urp_slot_rc" "Could not inspect slot '$urp_slot' on the selected Standby Server."
            urp_slot_state=$(printf '%s\n' "$urp_slot_output" | awk -F '\t' '$1=="SLOT_STATE" {print $3; exit}')
            case "$urp_slot_state" in
                absent) REPARENT_ADDITIONAL_SLOT_COUNT=$((REPARENT_ADDITIONAL_SLOT_COUNT + 1)); break ;;
                physical_inactive) break ;;
                physical_active) say "Slot '$urp_slot' is active on the selected Standby; choose a different slot."; urp_slot_default="" ;;
                conflict) say "Slot '$urp_slot' exists but is not a reusable physical slot; choose a different slot."; urp_slot_default="" ;;
                *) die "Unexpected slot state for '$urp_slot': ${urp_slot_state:-<empty>}" ;;
            esac
        done
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$urp_transport" "$urp_target" "$urp_pgdata" "$urp_app" "$urp_client" "$urp_user" "$urp_slot" "$urp_conninfo_file" "$urp_nested_count" "$urp_relations" >> "$UNSELECTED_REPARENT_PLAN" || die "Could not append Unselected Standby reparent plan."
    done < "$UNSELECTED_REPARENT_CANDIDATES"
    record_check "PASSED" "Unselected Standby Placement" "operator chose to reparent all unselected Direct Standbys to the New Primary"
}

unselected_reparent_capacity_guard() {
    [ "$REPARENT_UNSELECTED" -eq 1 ] 2>/dev/null || return 0
    urcg_reverse_extra=0
    if [ -n "${REVERSE_SLOT:-}" ]; then
        urcg_out=$(remote_invoke --remote-slot-state "$REMOTE_PGDATA" "$REVERSE_SLOT" 2>/dev/null)
        urcg_rc=$?
        [ "$urcg_rc" -eq 0 ] || classify_remote_failure "$urcg_rc" "Could not recheck reverse slot capacity."
        urcg_state=$(printf '%s\n' "$urcg_out" | awk -F '\t' '$1=="SLOT_STATE" {print $3; exit}')
        [ "$urcg_state" = "absent" ] && urcg_reverse_extra=1 || true
    fi
    urcg_required_slots=$((REMOTE_REPLICATION_SLOT_COUNT + REPARENT_ADDITIONAL_SLOT_COUNT + urcg_reverse_extra))
    [ "$REMOTE_MAX_REPLICATION_SLOTS" -ge "$urcg_required_slots" ] || die "New Primary max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS is lower than required=$urcg_required_slots after reparenting unselected Standbys."
    urcg_required_senders=$((REMOTE_DOWNSTREAM_COUNT + 1 + UNSELECTED_STANDBY_COUNT))
    [ "$REMOTE_MAX_WAL_SENDERS" -ge "$urcg_required_senders" ] || die "New Primary max_wal_senders=$REMOTE_MAX_WAL_SENDERS is lower than required direct physical replication clients=$urcg_required_senders after reparenting."
    record_check "PASSED" "Unselected Standby Reparent Capacity" "max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS required=$urcg_required_slots; max_wal_senders=$REMOTE_MAX_WAL_SENDERS required=$urcg_required_senders"
}

execute_unselected_reparent_plan() {
    eurp_timeout=$1
    [ "$REPARENT_UNSELECTED" -eq 1 ] 2>/dev/null || return 0
    [ -f "$UNSELECTED_REPARENT_PLAN" ] || return 1
    while IFS='|' read -r eurp_transport eurp_target eurp_pgdata eurp_app eurp_client eurp_user eurp_slot eurp_conninfo_file eurp_nested_count eurp_relations; do
        [ -n "$eurp_pgdata" ] || continue
        eurp_conninfo=$(sed -n '1p' "$eurp_conninfo_file")
        if [ -n "$eurp_slot" ]; then
            remote_invoke --remote-create-slot "$REMOTE_PGDATA" "$eurp_slot" >/dev/null 2>&1 || die "Could not create/reuse physical slot '$eurp_slot' on the New Primary for $eurp_app."
        fi
        if ! invoke_on_transport "$eurp_transport" "$eurp_target" --remote-repoint-standby "$eurp_pgdata" "$SYSTEM_IDENTIFIER" "$eurp_conninfo" "$eurp_slot" "$NEW_PRIMARY_DB_HOST" "$REMOTE_PORT" "$eurp_timeout"; then
            die "Failed to reparent Unselected Standby $eurp_app ($eurp_client) to the New Primary. Its previous replication settings were restored when possible."
        fi
        eurp_verify=$(remote_invoke --remote-count-reparented "$REMOTE_PGDATA" "$eurp_app" "$eurp_client" "$eurp_slot" 2>/dev/null)
        eurp_vrc=$?
        [ "$eurp_vrc" -eq 0 ] || classify_remote_failure "$eurp_vrc" "Could not verify reparented Standby $eurp_app on the New Primary."
        eurp_count=$(printf '%s\n' "$eurp_verify" | awk -F '\t' '$1=="COUNT" {print $2; exit}')
        [ "$eurp_count" = "1" ] || die "New Primary does not show exactly one matching streaming WAL sender for reparented Standby $eurp_app; observed=${eurp_count:-invalid}."
        mktemp_safe || die "Could not verify nested downstreams after reparenting $eurp_app."
        eurp_nested_now=$SAFE_TMP
        invoke_on_transport "$eurp_transport" "$eurp_target" --remote-downstreams "$eurp_pgdata" > "$eurp_nested_now" 2>/dev/null || die "Could not inspect nested downstreams after reparenting $eurp_app."
        eurp_total=$(awk -F '\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$eurp_nested_now")
        eurp_streaming=$(awk -F '\t' '$1=="DOWNSTREAM" && $4=="streaming" {c++} END {print c+0}' "$eurp_nested_now")
        [ "$eurp_total" = "$eurp_nested_count" ] && [ "$eurp_streaming" = "$eurp_nested_count" ] || die "Nested downstream count/state changed under reparented Standby $eurp_app."
        mktemp_safe || die "Could not normalize nested downstreams after reparenting $eurp_app."
        eurp_rel_now=$SAFE_TMP
        normalize_downstream_relation_set "$eurp_nested_now" > "$eurp_rel_now" || die "Could not normalize nested downstream relationships after reparenting $eurp_app."
        cmp -s "$eurp_relations" "$eurp_rel_now" || die "Nested downstream identity changed under reparented Standby $eurp_app."
        info "Reparented Standby verified: $eurp_app -> New Primary; nested downstreams preserved=$eurp_nested_count"
    done < "$UNSELECTED_REPARENT_PLAN"
    eurp_old_downstreams=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || eurp_old_downstreams=""
    [ "$eurp_old_downstreams" = "0" ] || die "Former Primary still has ${eurp_old_downstreams:-unknown} direct downstream replication connection(s) after all selected reparent operations."
    record_check "PASSED" "Unselected Standby Reparent" "all selected former direct Standbys now stream directly from the New Primary and nested cascade relationships are unchanged"
}

'''
if marker not in s: raise SystemExit('wait_unselected marker not found')
s=s.replace(marker,helper+marker,1)

# Skip old-edge verifier for intentionally reparented unselected nodes.
old='''        [ "$vpte_kind" = "EDGE" ] || continue
        mktemp_safe || return 1
'''
new='''        [ "$vpte_kind" = "EDGE" ] || continue
        if [ "$REPARENT_UNSELECTED" -eq 1 ] 2>/dev/null && [ "$vpte_origin" = "unselected-current-primary-downstream" ]; then
            continue
        fi
        mktemp_safe || return 1
'''
if old not in s: raise SystemExit('generic edge loop marker not found')
s=s.replace(old,new,1)

# Call plan preparation after new-primary conninfo/auth is known and before slot capacity finalization.
old='''    if check_reverse_streaming_authentication; then
        info "Reverse streaming HBA readiness was verified automatically."
    else
        if ! choose_yes_no "Reverse streaming 인증(pg_hba.conf/.pgpass/인증서 등)이 준비되어 있습니까" "no"; then
            die "Prepare reverse streaming authentication before Switchover."
        fi
        record_check "MANUAL CHECK" "Reverse Streaming Authentication Confirmation" "confirmed by operator after automatic HBA evaluation remained inconclusive"
    fi

    REVERSE_SLOT=""
'''
new='''    if check_reverse_streaming_authentication; then
        info "Reverse streaming HBA readiness was verified automatically."
    else
        if ! choose_yes_no "Reverse streaming 인증(pg_hba.conf/.pgpass/인증서 등)이 준비되어 있습니까" "no"; then
            die "Prepare reverse streaming authentication before Switchover."
        fi
        record_check "MANUAL CHECK" "Reverse Streaming Authentication Confirmation" "confirmed by operator after automatic HBA evaluation remained inconclusive"
    fi

    REVERSE_SLOT=""
'''
if old not in s: raise SystemExit('auth/reverse marker not found')
# no-op anchor retained; plan is inserted after reverse slot selection below

old='''    if [ -n "${REVERSE_SLOT:-}" ]; then
        validate_replication_slot_name "$REVERSE_SLOT" || die "Invalid physical replication slot name '$REVERSE_SLOT'. Use only lower-case letters, numbers and underscore, within PostgreSQL max_identifier_length."
        candidate_switchover_safety_precheck 1 "$REVERSE_SLOT"
    else
        candidate_switchover_safety_precheck 0
    fi
'''
new='''    if [ -n "${REVERSE_SLOT:-}" ]; then
        validate_replication_slot_name "$REVERSE_SLOT" || die "Invalid physical replication slot name '$REVERSE_SLOT'. Use only lower-case letters, numbers and underscore, within PostgreSQL max_identifier_length."
    fi
    prepare_unselected_reparent_plan
    if [ -n "${REVERSE_SLOT:-}" ]; then
        candidate_switchover_safety_precheck 1 "$REVERSE_SLOT"
    else
        candidate_switchover_safety_precheck 0
    fi
    unselected_reparent_capacity_guard
'''
if old not in s: raise SystemExit('reverse slot safety marker not found')
s=s.replace(old,new,1)

# Check-only should explicitly report that placement is execution policy and unchanged.
old='''        record_check "PASSED" "Replication Topology" "local and remote state revalidated"
        check_reverse_streaming_authentication || :
'''
new='''        record_check "PASSED" "Replication Topology" "local and remote state revalidated"
        if [ "${UNSELECTED_STANDBY_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            record_check "MANUAL CHECK" "Unselected Standby Placement" "check-only does not change topology; execution will ask whether existing unselected Direct Standbys should be reparented to the New Primary"
        fi
        check_reverse_streaming_authentication || :
'''
if old not in s: raise SystemExit('check-only marker not found')
s=s.replace(old,new,1)

# Execution plan text.
old='''    say " 10. Verify pg_is_in_recovery(), pg_stat_wal_receiver.status and pg_stat_replication"
}
'''
new='''    say " 10. Verify pg_is_in_recovery(), pg_stat_wal_receiver.status and pg_stat_replication"
    if [ "${REPARENT_UNSELECTED:-0}" -eq 1 ] 2>/dev/null; then
        say ""
        say " 11. Reparent existing Unselected Direct Standby Servers to the New Primary"
        say "     Create/reuse validated physical slots on the New Primary when configured."
        say "     Update each Standby's primary_conninfo/primary_slot_name only after promotion and verify pg_stat_wal_receiver.status=streaming."
        say "     Preserve each Standby's existing downstream cascade relationships."
    fi
}
'''
if old not in s: raise SystemExit('execution plan marker not found')
s=s.replace(old,new,1)

# Branch post-rejoin behavior: either reparent or preserve old cascading relationship.
old='''    if [ "${UNSELECTED_STANDBY_COUNT:-0}" -gt 0 ]; then
        if ! wait_unselected_standbys "$UNSELECTED_STANDBY_COUNT" "$verify_timeout"; then
            die "Not all unselected Standby Servers reached pg_stat_replication.state=streaming on the former Primary Server after it became a Cascading Standby. The new Primary Server remains active."
        fi
        info "All unselected Standby Servers are visible with pg_stat_replication.state=streaming on the former Primary Server."
    fi

    if ! verify_preserved_topology_snapshot "Selected Standby existing downstream" "${CANDIDATE_TOPOLOGY_SNAPSHOT:-}"; then
'''
new='''    if [ "${UNSELECTED_STANDBY_COUNT:-0}" -gt 0 ]; then
        if [ "$REPARENT_UNSELECTED" -eq 1 ] 2>/dev/null; then
            execute_unselected_reparent_plan "$verify_timeout"
        else
            if ! wait_unselected_standbys "$UNSELECTED_STANDBY_COUNT" "$verify_timeout"; then
                die "Not all unselected Standby Servers reached pg_stat_replication.state=streaming on the former Primary Server after it became a Cascading Standby. The new Primary Server remains active."
            fi
            info "All unselected Standby Servers are visible with pg_stat_replication.state=streaming on the former Primary Server."
        fi
    fi

    if ! verify_preserved_topology_snapshot "Selected Standby existing downstream" "${CANDIDATE_TOPOLOGY_SNAPSHOT:-}"; then
'''
if old not in s: raise SystemExit('post-rejoin unselected marker not found')
s=s.replace(old,new,1)

old='''    if ! verify_preserved_topology_snapshot "Unselected Standby cascading downstream" "${UNSELECTED_TOPOLOGY_SNAPSHOT:-}"; then
        die "One or more preserved Unselected Standby cascading relationships changed during Switchover. The role reversal remains active; inspect the affected downstream chain."
    fi
'''
new='''    if [ "$REPARENT_UNSELECTED" -ne 1 ] 2>/dev/null; then
        if ! verify_preserved_topology_snapshot "Unselected Standby cascading downstream" "${UNSELECTED_TOPOLOGY_SNAPSHOT:-}"; then
            die "One or more preserved Unselected Standby cascading relationships changed during Switchover. The role reversal remains active; inspect the affected downstream chain."
        fi
    fi
'''
if old not in s: raise SystemExit('unselected preserved verify marker not found')
s=s.replace(old,new,1)

# Remote functions before remote_wait_streaming_downstreams.
marker='''remote_wait_streaming_downstreams() {
'''
remote_helpers=r'''remote_repoint_standby() {
    rrps_pgdata=$1
    rrps_sysid=$2
    rrps_conninfo=$3
    rrps_slot=$4
    rrps_expected_host=$5
    rrps_expected_port=$6
    rrps_timeout=$(bounded_wait_seconds "$7") || exit 64
    remote_init_exact "$rrps_pgdata"
    [ "$LOCAL_ROLE" = "standby" ] || exit 3
    [ "$SYSTEM_IDENTIFIER" = "$rrps_sysid" ] || exit 4
    primary_conninfo_source_guard || exit 5
    rrps_restore="$PGDATA/.postgresql-role-switch.reparent.restore.sql"
    [ ! -e "$rrps_restore" ] || exit 6
    rrps_tmp="$rrps_restore.tmp.$$"
    if ! {
        psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_conninfo = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_conninfo;' END FROM pg_settings WHERE name='primary_conninfo'" &&
        psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET primary_slot_name = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET primary_slot_name;' END FROM pg_settings WHERE name='primary_slot_name'" &&
        psql_call_var ac "$AUTO_CONF" "SELECT CASE WHEN sourcefile = :'ac' THEN 'ALTER SYSTEM SET recovery_target_timeline = ' || quote_literal(setting) || ';' ELSE 'ALTER SYSTEM RESET recovery_target_timeline;' END FROM pg_settings WHERE name='recovery_target_timeline'"
    } > "$rrps_tmp"; then
        rm -f "$rrps_tmp"
        exit 7
    fi
    chmod 600 "$rrps_tmp" 2>/dev/null || { rm -f "$rrps_tmp"; exit 8; }
    mv "$rrps_tmp" "$rrps_restore" || { rm -f "$rrps_tmp"; exit 9; }

    rrps_apply_ok=1
    psql_call_var pc "$rrps_conninfo" "ALTER SYSTEM SET primary_conninfo = :'pc'" >/dev/null || rrps_apply_ok=0
    if [ "$rrps_apply_ok" -eq 1 ]; then
        if [ -n "$rrps_slot" ]; then
            psql_call_var ps "$rrps_slot" "ALTER SYSTEM SET primary_slot_name = :'ps'" >/dev/null || rrps_apply_ok=0
        else
            psql_call "ALTER SYSTEM SET primary_slot_name = ''" >/dev/null || rrps_apply_ok=0
        fi
    fi
    [ "$rrps_apply_ok" -eq 1 ] && psql_call "ALTER SYSTEM SET recovery_target_timeline = 'latest'" >/dev/null || rrps_apply_ok=0

    rrps_reload() {
        if [ "$PG_MAJOR" -eq 12 ]; then
            [ -n "$PG_CTL_BIN" ] && [ -x "$PG_CTL_BIN" ] || return 1
            if [ -n "$POSTMASTER_OPTIONS" ]; then
                "$PG_CTL_BIN" -D "$PGDATA" -o "$POSTMASTER_OPTIONS" -m fast -w restart >/dev/null 2>&1
            else
                "$PG_CTL_BIN" -D "$PGDATA" -m fast -w restart >/dev/null 2>&1
            fi
        else
            rrps_r=$(psql_call "SELECT pg_reload_conf()" 2>/dev/null | tr -d '[:space:]') || return 1
            [ "$rrps_r" = "t" ] || [ "$rrps_r" = "true" ]
        fi
    }

    [ "$rrps_apply_ok" -eq 1 ] && rrps_reload || rrps_apply_ok=0
    rrps_i=0
    while [ "$rrps_apply_ok" -eq 1 ] && [ "$rrps_i" -lt "$rrps_timeout" ]; do
        rrps_row=$(psql_call "SELECT COALESCE(status,'') || E'\\t' || COALESCE(sender_host,'') || E'\\t' || COALESCE(sender_port::text,'') || E'\\t' || COALESCE(slot_name,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p') || rrps_row=""
        rrps_status=$(printf '%s\n' "$rrps_row" | awk -F '\t' '{print $1}')
        rrps_host=$(printf '%s\n' "$rrps_row" | awk -F '\t' '{print $2}')
        rrps_port=$(printf '%s\n' "$rrps_row" | awk -F '\t' '{print $3}')
        rrps_seen_slot=$(printf '%s\n' "$rrps_row" | awk -F '\t' '{print $4}')
        if [ "$rrps_status" = "streaming" ] && [ "$rrps_host" = "$rrps_expected_host" ] && [ "$rrps_port" = "$rrps_expected_port" ] && [ "$rrps_seen_slot" = "$rrps_slot" ]; then
            rm -f "$rrps_restore"
            printf 'REPOINTED\t%s\t%s\t%s\t%s\n' "$PGDATA" "$rrps_host" "$rrps_port" "$rrps_seen_slot"
            return 0
        fi
        sleep 1
        rrps_i=$((rrps_i + 1))
    done

    if psql_call_file "$rrps_restore" >/dev/null 2>&1 && rrps_reload; then
        rm -f "$rrps_restore"
    fi
    return 10
}

remote_count_reparented() {
    rcr_pgdata=$1
    rcr_app=$2
    rcr_client=$3
    rcr_slot=$4
    remote_init_exact "$rcr_pgdata"
    rcr_count=$(psql_call_var app "$rcr_app" client "$rcr_client" slot "$rcr_slot" "SELECT count(*) FROM pg_stat_replication r WHERE state='streaming' AND application_name=:'app' AND COALESCE(host(client_addr),'local')=:'client' AND (CASE WHEN :'slot'='' THEN NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical') ELSE EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical' AND s.slot_name=:'slot') END)" 2>/dev/null | tr -d '[:space:]') || exit 3
    case "$rcr_count" in ''|*[!0-9]*) exit 4 ;; esac
    printf 'COUNT\t%s\n' "$rcr_count"
}

'''
if marker not in s: raise SystemExit('remote wait marker not found')
s=s.replace(marker,remote_helpers+marker,1)

# Add remote dispatch cases.
old='''    --remote-wait-streaming-downstreams)
        [ "$#" -eq 4 ] || exit 64
        remote_wait_streaming_downstreams "$2" "$3" "$4"
        exit $?
        ;;
'''
new='''    --remote-repoint-standby)
        [ "$#" -eq 8 ] || exit 64
        remote_repoint_standby "$2" "$3" "$4" "$5" "$6" "$7" "$8"
        exit $?
        ;;
    --remote-count-reparented)
        [ "$#" -eq 5 ] || exit 64
        remote_count_reparented "$2" "$3" "$4" "$5"
        exit $?
        ;;
    --remote-wait-streaming-downstreams)
        [ "$#" -eq 4 ] || exit 64
        remote_wait_streaming_downstreams "$2" "$3" "$4"
        exit $?
        ;;
'''
if old not in s: raise SystemExit('remote dispatch marker not found')
s=s.replace(old,new,1)

p.write_text(s)
