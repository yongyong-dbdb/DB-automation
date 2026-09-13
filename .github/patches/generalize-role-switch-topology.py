from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

old='''CANDIDATE_TOPOLOGY_SNAPSHOT=""
UNSELECTED_TOPOLOGY_SNAPSHOT=""
LOCK_HELD=0
'''
new='''CANDIDATE_TOPOLOGY_SNAPSHOT=""
UNSELECTED_TOPOLOGY_SNAPSHOT=""
PRESERVED_TOPOLOGY_EDGES=""
LOCK_HELD=0
'''
if old not in s: raise SystemExit('global topology snapshot block not found')
s=s.replace(old,new,1)

marker='''verify_preserved_topology_snapshot() {
'''
helper=r'''normalize_downstream_relation_set() {
    ndrs_file=$1
    # Compare stable relationship identity, not changing WAL positions/PIDs.
    # application_name, client_addr and physical slot identify the downstream
    # relationship; streaming state is validated separately.
    awk -F '\t' '$1=="DOWNSTREAM" {print $2 "\t" $3 "\t" $7}' "$ndrs_file" | sort
}

append_preserved_topology_edge() {
    apte_transport=$1
    apte_target=$2
    apte_pgdata=$3
    apte_sender_host=$4
    apte_sender_port=$5
    apte_slot=$6
    apte_expected_downstreams=$7
    apte_relation_file=$8
    apte_origin=$9
    if [ -z "$PRESERVED_TOPOLOGY_EDGES" ]; then
        mktemp_safe || die "Could not create preserved topology edge snapshot."
        PRESERVED_TOPOLOGY_EDGES=$SAFE_TMP
        : > "$PRESERVED_TOPOLOGY_EDGES" || die "Could not initialize preserved topology edge snapshot."
    fi
    mktemp_safe || die "Could not create normalized downstream relation snapshot."
    apte_normalized=$SAFE_TMP
    normalize_downstream_relation_set "$apte_relation_file" > "$apte_normalized" || die "Could not normalize downstream relationship snapshot."
    printf 'EDGE|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$apte_transport" "$apte_target" "$apte_pgdata" "$apte_sender_host" \
        "$apte_sender_port" "$apte_slot" "$apte_expected_downstreams" "$apte_normalized" "$apte_origin" \
        >> "$PRESERVED_TOPOLOGY_EDGES" || die "Could not append preserved topology edge snapshot."
}

verify_preserved_topology_edges() {
    [ -n "$PRESERVED_TOPOLOGY_EDGES" ] && [ -f "$PRESERVED_TOPOLOGY_EDGES" ] || return 0
    vpte_ok=1
    while IFS='|' read -r vpte_kind vpte_transport vpte_target vpte_pgdata vpte_sender_host vpte_sender_port vpte_slot vpte_expected_downstreams vpte_expected_relations vpte_origin; do
        [ "$vpte_kind" = "EDGE" ] || continue
        mktemp_safe || return 1
        vpte_receiver_file=$SAFE_TMP
        invoke_on_transport "$vpte_transport" "$vpte_target" --remote-list-downstream "$SYSTEM_IDENTIFIER" "$vpte_sender_port" "$vpte_slot" > "$vpte_receiver_file" 2>/dev/null || {
            error "Preserved topology edge could not be queried: origin=$vpte_origin data_directory=$vpte_pgdata"
            vpte_ok=0
            continue
        }
        vpte_receiver_line=$(awk -F '\t' -v d="$vpte_pgdata" '$1=="DOWNSTREAM_INSTANCE" && $2==d {print; exit}' "$vpte_receiver_file")
        if [ -z "$vpte_receiver_line" ]; then
            error "Preserved topology edge missing: origin=$vpte_origin data_directory=$vpte_pgdata sender_port=$vpte_sender_port slot=${vpte_slot:-<empty>}"
            vpte_ok=0
            continue
        fi
        vpte_observed_sender=$(printf '%s\n' "$vpte_receiver_line" | awk -F '\t' '{print $6}')
        if [ -n "$vpte_sender_host" ] && [ -n "$vpte_observed_sender" ] && [ "$vpte_observed_sender" != "$vpte_sender_host" ]; then
            warn "Preserved topology edge sender_host representation changed: origin=$vpte_origin data_directory=$vpte_pgdata before=$vpte_sender_host after=$vpte_observed_sender"
        fi
        mktemp_safe || return 1
        vpte_down_file=$SAFE_TMP
        invoke_on_transport "$vpte_transport" "$vpte_target" --remote-downstreams "$vpte_pgdata" > "$vpte_down_file" 2>/dev/null || {
            error "Could not inspect preserved downstream set: origin=$vpte_origin data_directory=$vpte_pgdata"
            vpte_ok=0
            continue
        }
        vpte_total=$(awk -F '\t' '$1=="DOWNSTREAM" {c++} END {print c+0}' "$vpte_down_file")
        vpte_streaming=$(awk -F '\t' '$1=="DOWNSTREAM" && $4=="streaming" {c++} END {print c+0}' "$vpte_down_file")
        if [ "$vpte_total" != "$vpte_expected_downstreams" ] || [ "$vpte_streaming" != "$vpte_expected_downstreams" ]; then
            error "Preserved topology downstream-count mismatch: origin=$vpte_origin data_directory=$vpte_pgdata expected=$vpte_expected_downstreams total=$vpte_total streaming=$vpte_streaming"
            vpte_ok=0
            continue
        fi
        mktemp_safe || return 1
        vpte_actual_relations=$SAFE_TMP
        normalize_downstream_relation_set "$vpte_down_file" > "$vpte_actual_relations" || return 1
        if ! cmp -s "$vpte_expected_relations" "$vpte_actual_relations"; then
            error "Preserved topology downstream identity changed: origin=$vpte_origin data_directory=$vpte_pgdata. application_name/client_addr/physical-slot set differs from pre-Switchover state."
            vpte_ok=0
        fi
    done < "$PRESERVED_TOPOLOGY_EDGES"
    [ "$vpte_ok" -eq 1 ]
}

'''
if marker not in s: raise SystemExit('topology verification marker not found')
s=s.replace(marker,helper+marker,1)

old='''        printf '%s|%s|%s|%s|%s|%s|%s\\n' "$cdc_transport" "$cdc_target" "$cdc_pgdata" "$cdc_sender_host" "$cdc_sender_port" "$cdc_slot" "$cdc_nested_count" >> "$CANDIDATE_TOPOLOGY_SNAPSHOT" || die "Could not save Selected Standby topology snapshot."
        info "Downstream verified: $cdc_app, recovery_target_timeline=latest, nested_downstream_count=$cdc_nested_count"
'''
new='''        printf '%s|%s|%s|%s|%s|%s|%s\\n' "$cdc_transport" "$cdc_target" "$cdc_pgdata" "$cdc_sender_host" "$cdc_sender_port" "$cdc_slot" "$cdc_nested_count" >> "$CANDIDATE_TOPOLOGY_SNAPSHOT" || die "Could not save Selected Standby topology snapshot."
        append_preserved_topology_edge "$cdc_transport" "$cdc_target" "$cdc_pgdata" "$cdc_sender_host" "$cdc_sender_port" "$cdc_slot" "$cdc_nested_count" "$cdc_nested" "selected-candidate-existing-downstream"
        info "Downstream verified: $cdc_app, recovery_target_timeline=latest, nested_downstream_count=$cdc_nested_count"
'''
if old not in s: raise SystemExit('candidate edge append point not found')
s=s.replace(old,new,1)

old='''        printf '%s|%s|%s|%s|%s|%s|%s\\n' "$usc_transport" "$usc_target" "$usc_pgdata" "$usc_sender_host" "$usc_sender_port" "$usc_slot" "$usc_nested_count" >> "$UNSELECTED_TOPOLOGY_SNAPSHOT" || die "Could not save Unselected Standby topology snapshot."
        info "Unselected Standby topology snapshot: $usc_app nested_downstream_count=$usc_nested_count"
'''
new='''        printf '%s|%s|%s|%s|%s|%s|%s\\n' "$usc_transport" "$usc_target" "$usc_pgdata" "$usc_sender_host" "$usc_sender_port" "$usc_slot" "$usc_nested_count" >> "$UNSELECTED_TOPOLOGY_SNAPSHOT" || die "Could not save Unselected Standby topology snapshot."
        append_preserved_topology_edge "$usc_transport" "$usc_target" "$usc_pgdata" "$usc_sender_host" "$usc_sender_port" "$usc_slot" "$usc_nested_count" "$usc_nested" "unselected-current-primary-downstream"
        info "Unselected Standby topology snapshot: $usc_app nested_downstream_count=$usc_nested_count"
'''
if old not in s: raise SystemExit('unselected edge append point not found')
s=s.replace(old,new,1)

old='''    if ! verify_preserved_topology_snapshot "Unselected Standby cascading downstream" "${UNSELECTED_TOPOLOGY_SNAPSHOT:-}"; then
        die "One or more preserved Unselected Standby cascading relationships changed during Switchover. The role reversal remains active; inspect the affected downstream chain."
    fi
    CURRENT_PHASE="topology_verified"
    record_check "PASSED" "Cascading Topology Preservation" "pre-Switchover downstream relationships and nested downstream counts remained streaming after role reversal"
'''
new='''    if ! verify_preserved_topology_snapshot "Unselected Standby cascading downstream" "${UNSELECTED_TOPOLOGY_SNAPSHOT:-}"; then
        die "One or more preserved Unselected Standby cascading relationships changed during Switchover. The role reversal remains active; inspect the affected downstream chain."
    fi
    if ! verify_preserved_topology_edges; then
        die "One or more role-agnostic preserved topology edges failed post-Switchover validation. The role reversal remains active; inspect the affected relationship without automatic role rollback."
    fi
    CURRENT_PHASE="topology_verified"
    record_check "PASSED" "Cascading Topology Preservation" "role-agnostic pre-Switchover relationships and downstream identities remained streaming after role reversal; no server address or fixed node count was assumed"
'''
if old not in s: raise SystemExit('post topology verification block not found')
s=s.replace(old,new,1)

p.write_text(s)
