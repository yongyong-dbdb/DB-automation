from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

# Globals for post-promotion lifecycle and topology snapshots.
old='''SWITCHOVER_PROMOTED=0
SWITCHOVER_CONFIG_CHANGED=0
LOCK_HELD=0
'''
new='''SWITCHOVER_PROMOTED=0
SWITCHOVER_CONFIG_CHANGED=0
SWITCHOVER_RESTORE_HISTORY=""
CANDIDATE_TOPOLOGY_SNAPSHOT=""
UNSELECTED_TOPOLOGY_SNAPSHOT=""
LOCK_HELD=0
'''
if old not in s: raise SystemExit('global state block not found')
s=s.replace(old,new,1)

# Phase-specific exit handling after the former Primary has already rejoined.
old='''            after_promotion|rejoin_old_primary)
                warn "The candidate has been promoted. Do NOT restart the former Primary as a Primary."
                warn "Keep the former Primary stopped until it is confirmed to start with standby.signal and correct primary_conninfo."
                manual_recovery_branch_notice
                ;;
'''
new='''            after_promotion|rejoin_old_primary)
                warn "The candidate has been promoted. Do NOT restart the former Primary as a Primary."
                warn "Keep the former Primary stopped until it is confirmed to start with standby.signal and correct primary_conninfo."
                manual_recovery_branch_notice
                ;;
            reverse_streaming_verified|topology_verified)
                warn "Role reversal is already active: the former Primary was verified as a Standby with pg_stat_wal_receiver.status=streaming."
                warn "A post-Switchover validation failed. Do NOT roll back roles automatically and do NOT restart the former Primary as Primary."
                warn "Keep the current topology running while the failed validation is investigated."
                record_check "MANUAL CHECK" "Post-Switchover State" "role reversal already active; investigate the failed post-validation without automatic role rollback"
                ;;
'''
if old not in s: raise SystemExit('on_exit promotion block not found')
s=s.replace(old,new,1)

# Add restore-state retirement helper after rollback_preconfigured_primary().
marker='''rollback_preconfigured_primary() {
    if [ "$SWITCHOVER_CONFIG_CHANGED" -eq 1 ] && [ -f "${SWITCHOVER_RESTORE_FILE:-}" ]; then
        if psql_call_file "$SWITCHOVER_RESTORE_FILE" >/dev/null 2>&1; then
            if rm -f "$SWITCHOVER_RESTORE_FILE"; then
                SWITCHOVER_CONFIG_CHANGED=0
            else
                warn "Settings were restored but could not remove the restore state: $SWITCHOVER_RESTORE_FILE"
            fi
        else
            warn "Could not roll back staged settings automatically. Restore state retained: $SWITCHOVER_RESTORE_FILE"
        fi
    fi
}
'''
addition=marker+r'''

retire_switchover_restore_state_after_promotion() {
    [ "$SWITCHOVER_PROMOTED" -eq 1 ] 2>/dev/null || return 1
    [ -n "${SWITCHOVER_RESTORE_FILE:-}" ] || { SWITCHOVER_CONFIG_CHANGED=0; return 0; }
    [ -f "$SWITCHOVER_RESTORE_FILE" ] || { SWITCHOVER_CONFIG_CHANGED=0; SWITCHOVER_RESTORE_FILE=""; return 0; }
    rsr_stamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo unknown)
    rsr_history="$STATE_DIR/$STATE_KEY.switchover.prepromotion.${rsr_stamp}.$$.history.sql"
    if mv "$SWITCHOVER_RESTORE_FILE" "$rsr_history"; then
        chmod 600 "$rsr_history" 2>/dev/null || true
        SWITCHOVER_RESTORE_HISTORY=$rsr_history
        SWITCHOVER_RESTORE_FILE=""
        SWITCHOVER_CONFIG_CHANGED=0
        record_check "PASSED" "Switchover Restore State" "pre-promotion rollback state retired after promotion; it is historical only and will never be auto-applied"
        return 0
    fi
    SWITCHOVER_CONFIG_CHANGED=0
    warn "Promotion succeeded but the pre-promotion restore state could not be retired: $SWITCHOVER_RESTORE_FILE"
    warn "That file is historical only now. Do NOT apply it automatically after promotion."
    return 1
}
'''
if marker not in s: raise SystemExit('rollback helper block not found')
s=s.replace(marker,addition,1)

# Snapshot candidate's existing direct downstreams and each one's own downstream count.
old='''    cdc_count=$(awk -F '\\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$cdc_tmp")
    [ "$cdc_count" -eq "${REMOTE_DOWNSTREAM_COUNT:-0}" ] 2>/dev/null || die "The selected Standby Server's pg_stat_replication result changed during precheck. Run discovery again."
    [ "$cdc_count" -gt 0 ] || return 0

    say ""
'''
new='''    cdc_count=$(awk -F '\\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$cdc_tmp")
    [ "$cdc_count" -eq "${REMOTE_DOWNSTREAM_COUNT:-0}" ] 2>/dev/null || die "The selected Standby Server's pg_stat_replication result changed during precheck. Run discovery again."
    [ "$cdc_count" -gt 0 ] || return 0
    mktemp_safe || die "Could not create a Selected Standby topology snapshot file."
    CANDIDATE_TOPOLOGY_SNAPSHOT=$SAFE_TMP
    : > "$CANDIDATE_TOPOLOGY_SNAPSHOT" || die "Could not initialize Selected Standby topology snapshot."

    say ""
'''
if old not in s: raise SystemExit('candidate snapshot init block not found')
s=s.replace(old,new,1)

old='''        cdc_timeline=$(printf '%s\\n' "$cdc_selected" | awk -F '\\t' '{print $9}')
        [ "$cdc_timeline" = "latest" ] || die "Downstream $cdc_app recovery_target_timeline=$cdc_timeline. Cascading Switchover requires latest."
        info "Downstream verified: $cdc_app, recovery_target_timeline=latest"
        cdc_i=$((cdc_i + 1))
'''
new='''        cdc_timeline=$(printf '%s\\n' "$cdc_selected" | awk -F '\\t' '{print $9}')
        [ "$cdc_timeline" = "latest" ] || die "Downstream $cdc_app recovery_target_timeline=$cdc_timeline. Cascading Switchover requires latest."
        cdc_pgdata=$(printf '%s\\n' "$cdc_selected" | awk -F '\\t' '{print $2}')
        cdc_sender_host=$(printf '%s\\n' "$cdc_selected" | awk -F '\\t' '{print $6}')
        cdc_sender_port=$(printf '%s\\n' "$cdc_selected" | awk -F '\\t' '{print $7}')
        mktemp_safe || die "Could not create a Selected Standby downstream snapshot file."
        cdc_nested=$SAFE_TMP
        invoke_on_transport "$cdc_transport" "$cdc_target" --remote-downstreams "$cdc_pgdata" > "$cdc_nested" 2>/dev/null || classify_remote_failure "$?" "Could not inspect nested downstreams of $cdc_app before Switchover."
        cdc_nested_count=$(awk -F '\\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$cdc_nested")
        cdc_nested_bad=$(awk -F '\\t' '$1=="DOWNSTREAM" && $4!="streaming" {c++} END {print c+0}' "$cdc_nested")
        [ "$cdc_nested_bad" -eq 0 ] || die "$cdc_app has $cdc_nested_bad nested downstream pg_stat_replication row(s) that are not state=streaming before Switchover."
        printf '%s|%s|%s|%s|%s|%s|%s\\n' "$cdc_transport" "$cdc_target" "$cdc_pgdata" "$cdc_sender_host" "$cdc_sender_port" "$cdc_slot" "$cdc_nested_count" >> "$CANDIDATE_TOPOLOGY_SNAPSHOT" || die "Could not save Selected Standby topology snapshot."
        info "Downstream verified: $cdc_app, recovery_target_timeline=latest, nested_downstream_count=$cdc_nested_count"
        cdc_i=$((cdc_i + 1))
'''
if old not in s: raise SystemExit('candidate snapshot row block not found')
s=s.replace(old,new,1)

# Snapshot unselected Standbys and their own downstream count.
old='''    UNSELECTED_STANDBY_COUNT=$usc_count
    [ "$usc_count" -gt 0 ] || return 0

    say ""
'''
new='''    UNSELECTED_STANDBY_COUNT=$usc_count
    [ "$usc_count" -gt 0 ] || return 0
    mktemp_safe || die "Could not create an Unselected Standby topology snapshot file."
    UNSELECTED_TOPOLOGY_SNAPSHOT=$SAFE_TMP
    : > "$UNSELECTED_TOPOLOGY_SNAPSHOT" || die "Could not initialize Unselected Standby topology snapshot."

    say ""
'''
if old not in s: raise SystemExit('unselected snapshot init block not found')
s=s.replace(old,new,1)

old='''        usc_timeline=$(printf '%s\\n' "$usc_selected" | awk -F '\\t' '{print $9}')
        [ "$usc_timeline" = "latest" ] || die "Standby Server $usc_app has recovery_target_timeline=$usc_timeline; latest is required to follow the new timeline."
        usc_i=$((usc_i + 1))
'''
new='''        usc_timeline=$(printf '%s\\n' "$usc_selected" | awk -F '\\t' '{print $9}')
        [ "$usc_timeline" = "latest" ] || die "Standby Server $usc_app has recovery_target_timeline=$usc_timeline; latest is required to follow the new timeline."
        usc_pgdata=$(printf '%s\\n' "$usc_selected" | awk -F '\\t' '{print $2}')
        usc_sender_host=$(printf '%s\\n' "$usc_selected" | awk -F '\\t' '{print $6}')
        usc_sender_port=$(printf '%s\\n' "$usc_selected" | awk -F '\\t' '{print $7}')
        mktemp_safe || die "Could not create an Unselected Standby downstream snapshot file."
        usc_nested=$SAFE_TMP
        invoke_on_transport "$usc_transport" "$usc_target" --remote-downstreams "$usc_pgdata" > "$usc_nested" 2>/dev/null || classify_remote_failure "$?" "Could not inspect nested downstreams of $usc_app before Switchover."
        usc_nested_count=$(awk -F '\\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$usc_nested")
        usc_nested_bad=$(awk -F '\\t' '$1=="DOWNSTREAM" && $4!="streaming" {c++} END {print c+0}' "$usc_nested")
        [ "$usc_nested_bad" -eq 0 ] || die "$usc_app has $usc_nested_bad nested downstream pg_stat_replication row(s) that are not state=streaming before Switchover."
        printf '%s|%s|%s|%s|%s|%s|%s\\n' "$usc_transport" "$usc_target" "$usc_pgdata" "$usc_sender_host" "$usc_sender_port" "$usc_slot" "$usc_nested_count" >> "$UNSELECTED_TOPOLOGY_SNAPSHOT" || die "Could not save Unselected Standby topology snapshot."
        info "Unselected Standby topology snapshot: $usc_app nested_downstream_count=$usc_nested_count"
        usc_i=$((usc_i + 1))
'''
if old not in s: raise SystemExit('unselected snapshot row block not found')
s=s.replace(old,new,1)

# Generic post-switchover verification of preserved cascade edges.
insert_before='''switchover_shutdown_mode() {
'''
helper=r'''verify_preserved_topology_snapshot() {
    vpts_label=$1
    vpts_file=$2
    [ -n "$vpts_file" ] && [ -f "$vpts_file" ] || return 0
    vpts_ok=1
    while IFS='|' read -r vpts_transport vpts_target vpts_pgdata vpts_sender_host vpts_sender_port vpts_slot vpts_expected_nested; do
        [ -n "$vpts_pgdata" ] || continue
        mktemp_safe || return 1
        vpts_receiver_file=$SAFE_TMP
        invoke_on_transport "$vpts_transport" "$vpts_target" --remote-list-downstream "$SYSTEM_IDENTIFIER" "$vpts_sender_port" "$vpts_slot" > "$vpts_receiver_file" 2>/dev/null || return 1
        vpts_receiver_line=$(awk -F '\t' -v d="$vpts_pgdata" '$1=="DOWNSTREAM_INSTANCE" && $2==d {print; exit}' "$vpts_receiver_file")
        if [ -z "$vpts_receiver_line" ]; then
            error "$vpts_label topology mismatch: data_directory=$vpts_pgdata no longer has the expected streaming WAL receiver (sender_port=$vpts_sender_port, slot=${vpts_slot:-<empty>})."
            vpts_ok=0
            continue
        fi
        vpts_observed_sender=$(printf '%s\n' "$vpts_receiver_line" | awk -F '\t' '{print $6}')
        if [ -n "$vpts_sender_host" ] && [ "$vpts_observed_sender" != "$vpts_sender_host" ]; then
            error "$vpts_label topology mismatch: data_directory=$vpts_pgdata sender_host changed from $vpts_sender_host to ${vpts_observed_sender:-<empty>}."
            vpts_ok=0
        fi
        mktemp_safe || return 1
        vpts_nested_file=$SAFE_TMP
        invoke_on_transport "$vpts_transport" "$vpts_target" --remote-downstreams "$vpts_pgdata" > "$vpts_nested_file" 2>/dev/null || return 1
        vpts_nested_total=$(awk -F '\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$vpts_nested_file")
        vpts_nested_streaming=$(awk -F '\t' '$1=="DOWNSTREAM" && $4=="streaming" {c++} END {print c+0}' "$vpts_nested_file")
        if [ "$vpts_nested_total" != "$vpts_expected_nested" ] || [ "$vpts_nested_streaming" != "$vpts_expected_nested" ]; then
            error "$vpts_label topology mismatch: data_directory=$vpts_pgdata expected $vpts_expected_nested nested downstream(s), observed total=$vpts_nested_total streaming=$vpts_nested_streaming."
            vpts_ok=0
        fi
    done < "$vpts_file"
    [ "$vpts_ok" -eq 1 ]
}

'''
if insert_before not in s: raise SystemExit('switchover_shutdown_mode marker not found')
s=s.replace(insert_before,helper+insert_before,1)

# Retire rollback state immediately after promotion is verified.
old='''    SWITCHOVER_PROMOTED=1
    CURRENT_PHASE="after_promotion"
    refresh_candidate_lock
    info "Promotion verified: Current Role=Primary."
'''
new='''    SWITCHOVER_PROMOTED=1
    CURRENT_PHASE="after_promotion"
    retire_switchover_restore_state_after_promotion || true
    refresh_candidate_lock
    info "Promotion verified: Current Role=Primary."
'''
if old not in s: raise SystemExit('promotion verified block not found')
s=s.replace(old,new,1)

# Mark reverse streaming safe phase and validate both preserved topology classes.
old='''    if ! wait_receiver_streaming "$verify_timeout"; then
        die "Former Primary is in Standby mode, but pg_stat_wal_receiver.status did not reach streaming within ${verify_timeout}s. The new Primary remains active; inspect authentication, pg_hba.conf, network, slot, and PostgreSQL logs."
    fi

    if [ "${UNSELECTED_STANDBY_COUNT:-0}" -gt 0 ]; then
'''
new='''    if ! wait_receiver_streaming "$verify_timeout"; then
        die "Former Primary is in Standby mode, but pg_stat_wal_receiver.status did not reach streaming within ${verify_timeout}s. The new Primary remains active; inspect authentication, pg_hba.conf, network, slot, and PostgreSQL logs."
    fi
    CURRENT_PHASE="reverse_streaming_verified"
    record_check "PASSED" "Former Primary Rejoin" "pg_is_in_recovery()=true and pg_stat_wal_receiver.status=streaming"

    if [ "${UNSELECTED_STANDBY_COUNT:-0}" -gt 0 ]; then
'''
if old not in s: raise SystemExit('wait_receiver_streaming block not found')
s=s.replace(old,new,1)

old='''        info "All unselected Standby Servers are visible with pg_stat_replication.state=streaming on the former Primary Server."
    fi

    # primary_conninfo may intentionally omit application_name.
'''
new='''        info "All unselected Standby Servers are visible with pg_stat_replication.state=streaming on the former Primary Server."
    fi

    if ! verify_preserved_topology_snapshot "Selected Standby existing downstream" "${CANDIDATE_TOPOLOGY_SNAPSHOT:-}"; then
        die "Post-Switchover validation failed: one or more downstream relationships that belonged to the selected Standby before promotion were not preserved."
    fi
    if ! verify_preserved_topology_snapshot "Unselected Standby cascading downstream" "${UNSELECTED_TOPOLOGY_SNAPSHOT:-}"; then
        die "Post-Switchover validation failed: one or more cascading relationships below an Unselected Standby were not preserved."
    fi
    CURRENT_PHASE="topology_verified"
    record_check "PASSED" "Preserved Cascading Topology" "selected-candidate downstreams and unselected-standby nested downstream counts remain streaming after role reversal"

    # primary_conninfo may intentionally omit application_name.
'''
if old not in s: raise SystemExit('post unselected topology insertion point not found')
s=s.replace(old,new,1)

# Final success removes historical pre-promotion state; post-check failures retain it for audit only.
old='''    if [ -n "${SWITCHOVER_RESTORE_FILE:-}" ] && ! rm -f "$SWITCHOVER_RESTORE_FILE"; then
        warn "Switchover succeeded but the rollback state could not be removed: $SWITCHOVER_RESTORE_FILE"
    fi
    SWITCHOVER_CONFIG_CHANGED=0
    CURRENT_PHASE="completed"
'''
new='''    if [ -n "${SWITCHOVER_RESTORE_HISTORY:-}" ] && [ -f "$SWITCHOVER_RESTORE_HISTORY" ]; then
        if ! rm -f "$SWITCHOVER_RESTORE_HISTORY"; then
            warn "Switchover completed but historical pre-promotion state could not be removed: $SWITCHOVER_RESTORE_HISTORY"
        fi
    fi
    SWITCHOVER_CONFIG_CHANGED=0
    SWITCHOVER_RESTORE_FILE=""
    CURRENT_PHASE="completed"
'''
if old not in s: raise SystemExit('final restore cleanup block not found')
s=s.replace(old,new,1)

p.write_text(s)
