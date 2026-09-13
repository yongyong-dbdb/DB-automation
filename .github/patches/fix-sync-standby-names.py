from pathlib import Path
import re

p = Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s = p.read_text()

def rep(old, new, count=1, label='block'):
    global s
    if old not in s:
        raise SystemExit(f'{label} not found')
    s = s.replace(old, new, count)

# 1) Validate operator-entered replication slot names against PostgreSQL rules.
rep("""sanitize_identifier() {
    printf '%s' \"$1\" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g; s/^_*//; s/_*$//'
}
""", """sanitize_identifier() {
    printf '%s' \"$1\" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g; s/^_*//; s/_*$//'
}

validate_replication_slot_name() {
    vrs_name=$1
    [ -n \"$vrs_name\" ] || return 1
    case \"$vrs_name\" in *[!a-z0-9_]*) return 1 ;; esac
    vrs_max=$(psql_call \"SHOW max_identifier_length\" 2>/dev/null | tr -d '[:space:]') || return 1
    case \"$vrs_max\" in ''|*[!0-9]*) return 1 ;; esac
    [ \"${#vrs_name}\" -le \"$vrs_max\" ] 2>/dev/null
}
""", label='slot validator insertion')

# 2) Preserve remote exit status instead of masking it through an awk pipeline.
rep("""        lrsp_result=$(remote_invoke --remote-check-logical-slot \"$REMOTE_PGDATA\" \"$lrsp_slot\" 2>/dev/null | awk -F '\\t' '$1==\"LOGICAL_SLOT\" {print $3; exit}')
        if [ \"$lrsp_result\" != \"ready\" ]; then
""", """        lrsp_output=$(remote_invoke --remote-check-logical-slot \"$REMOTE_PGDATA\" \"$lrsp_slot\" 2>/dev/null)
        lrsp_rc=$?
        [ \"$lrsp_rc\" -eq 0 ] || classify_remote_failure \"$lrsp_rc\" \"Could not validate logical failover slot '$lrsp_slot' on the selected Standby Server.\"
        lrsp_result=$(printf '%s\\n' \"$lrsp_output\" | awk -F '\\t' '$1==\"LOGICAL_SLOT\" {print $3; exit}')
        if [ \"$lrsp_result\" != \"ready\" ]; then
""", label='logical slot remote status')

rep("""    css_line=$(remote_invoke --remote-switchover-safety \"$REMOTE_PGDATA\" 2>/dev/null | awk -F '\\t' '$1==\"SWITCHOVER_SAFETY\" {print; exit}') || classify_remote_failure \"$?\" \"Could not inspect the selected Standby Server's replication settings and replication slot state.\"
    [ -n \"$css_line\" ] || die \"Selected Standby Server returned no replication settings and replication slot state.\"
""", """    css_output=$(remote_invoke --remote-switchover-safety \"$REMOTE_PGDATA\" 2>/dev/null)
    css_rc=$?
    [ \"$css_rc\" -eq 0 ] || classify_remote_failure \"$css_rc\" \"Could not inspect the selected Standby Server's replication settings and replication slot state.\"
    css_line=$(printf '%s\\n' \"$css_output\" | awk -F '\\t' '$1==\"SWITCHOVER_SAFETY\" {print; exit}')
    [ -n \"$css_line\" ] || die \"Selected Standby Server returned no replication settings and replication slot state.\"
""", label='safety remote status')

rep("""        css_slot_state=$(remote_invoke --remote-slot-state \"$REMOTE_PGDATA\" \"$css_reverse_slot\" 2>/dev/null | awk -F '\\t' '$1==\"SLOT_STATE\" {print $3; exit}') || classify_remote_failure \"$?\" \"Could not inspect reverse replication slot state on the selected Standby Server.\"
        case \"$css_slot_state\" in
            absent) css_effective_reserve=1 ;;
            physical) css_effective_reserve=0 ;;
            conflict) die \"Replication slot '$css_reverse_slot' already exists on the selected Standby Server but slot_type is not physical. Choose another slot_name.\" ;;
""", """        css_slot_output=$(remote_invoke --remote-slot-state \"$REMOTE_PGDATA\" \"$css_reverse_slot\" 2>/dev/null)
        css_slot_rc=$?
        [ \"$css_slot_rc\" -eq 0 ] || classify_remote_failure \"$css_slot_rc\" \"Could not inspect reverse replication slot state on the selected Standby Server.\"
        css_slot_state=$(printf '%s\\n' \"$css_slot_output\" | awk -F '\\t' '$1==\"SLOT_STATE\" {print $3; exit}')
        case \"$css_slot_state\" in
            absent) css_effective_reserve=1 ;;
            physical_inactive) css_effective_reserve=0 ;;
            physical_active) die \"Replication slot '$css_reverse_slot' already exists and is active on the selected Standby Server. An active slot cannot be reassigned to the former Primary.\" ;;
            conflict) die \"Replication slot '$css_reverse_slot' already exists on the selected Standby Server but slot_type is not physical. Choose another slot_name.\" ;;
""", label='slot state remote status')

# 3) Add Hot Standby shared-memory compatibility values to candidate safety output and enforce future standby >= future primary.
rep("""    REMOTE_WAL_LEVEL=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $11}')
    REMOTE_LOGICAL_SLOT_COUNT=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $12}')

    for css_n in \"$REMOTE_MAX_WAL_SENDERS\" \"$REMOTE_MAX_REPLICATION_SLOTS\" \"$REMOTE_REPLICATION_SLOT_COUNT\" \"$REMOTE_LOGICAL_SLOT_COUNT\"; do
""", """    REMOTE_WAL_LEVEL=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $11}')
    REMOTE_LOGICAL_SLOT_COUNT=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $12}')
    REMOTE_MAX_CONNECTIONS=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $13}')
    REMOTE_MAX_PREPARED_TRANSACTIONS=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $14}')
    REMOTE_MAX_LOCKS_PER_TRANSACTION=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $15}')
    REMOTE_MAX_WORKER_PROCESSES=$(printf '%s\\n' \"$css_line\" | awk -F '\\t' '{print $16}')

    for css_n in \"$REMOTE_MAX_WAL_SENDERS\" \"$REMOTE_MAX_REPLICATION_SLOTS\" \"$REMOTE_REPLICATION_SLOT_COUNT\" \"$REMOTE_LOGICAL_SLOT_COUNT\" \"$REMOTE_MAX_CONNECTIONS\" \"$REMOTE_MAX_PREPARED_TRANSACTIONS\" \"$REMOTE_MAX_LOCKS_PER_TRANSACTION\" \"$REMOTE_MAX_WORKER_PROCESSES\"; do
""", label='parse hot standby values')

needle = """    case \"$REMOTE_WAL_LEVEL\" in minimal|replica|logical) ;; *) die \"Selected Standby Server returned an invalid wal_level: ${REMOTE_WAL_LEVEL:-<empty>}\" ;; esac

    css_effective_reserve=$css_reserve_slots
"""
insert = """    case \"$REMOTE_WAL_LEVEL\" in minimal|replica|logical) ;; *) die \"Selected Standby Server returned an invalid wal_level: ${REMOTE_WAL_LEVEL:-<empty>}\" ;; esac

    css_local_max_connections=$(psql_call \"SHOW max_connections\" 2>/dev/null | tr -d '[:space:]') || die \"Could not inspect max_connections on the current Primary Server.\"
    css_local_max_prepared_transactions=$(psql_call \"SHOW max_prepared_transactions\" 2>/dev/null | tr -d '[:space:]') || die \"Could not inspect max_prepared_transactions on the current Primary Server.\"
    css_local_max_locks_per_transaction=$(psql_call \"SHOW max_locks_per_transaction\" 2>/dev/null | tr -d '[:space:]') || die \"Could not inspect max_locks_per_transaction on the current Primary Server.\"
    css_local_max_wal_senders=$(psql_call \"SHOW max_wal_senders\" 2>/dev/null | tr -d '[:space:]') || die \"Could not inspect max_wal_senders on the current Primary Server.\"
    css_local_max_worker_processes=$(psql_call \"SHOW max_worker_processes\" 2>/dev/null | tr -d '[:space:]') || die \"Could not inspect max_worker_processes on the current Primary Server.\"
    for css_n in \"$css_local_max_connections\" \"$css_local_max_prepared_transactions\" \"$css_local_max_locks_per_transaction\" \"$css_local_max_wal_senders\" \"$css_local_max_worker_processes\"; do
        case \"$css_n\" in ''|*[!0-9]*) die \"Current Primary Server returned an invalid Hot Standby shared-memory parameter value: ${css_n:-<empty>}\" ;; esac
    done
    [ \"$css_local_max_connections\" -ge \"$REMOTE_MAX_CONNECTIONS\" ] || die \"Former Primary cannot safely become a Standby: max_connections=$css_local_max_connections is lower than the selected Standby Server's future Primary value=$REMOTE_MAX_CONNECTIONS.\"
    [ \"$css_local_max_prepared_transactions\" -ge \"$REMOTE_MAX_PREPARED_TRANSACTIONS\" ] || die \"Former Primary cannot safely become a Standby: max_prepared_transactions=$css_local_max_prepared_transactions is lower than the selected Standby Server's future Primary value=$REMOTE_MAX_PREPARED_TRANSACTIONS.\"
    [ \"$css_local_max_locks_per_transaction\" -ge \"$REMOTE_MAX_LOCKS_PER_TRANSACTION\" ] || die \"Former Primary cannot safely become a Standby: max_locks_per_transaction=$css_local_max_locks_per_transaction is lower than the selected Standby Server's future Primary value=$REMOTE_MAX_LOCKS_PER_TRANSACTION.\"
    [ \"$css_local_max_wal_senders\" -ge \"$REMOTE_MAX_WAL_SENDERS\" ] || die \"Former Primary cannot safely become a Standby: max_wal_senders=$css_local_max_wal_senders is lower than the selected Standby Server's future Primary value=$REMOTE_MAX_WAL_SENDERS.\"
    [ \"$css_local_max_worker_processes\" -ge \"$REMOTE_MAX_WORKER_PROCESSES\" ] || die \"Former Primary cannot safely become a Standby: max_worker_processes=$css_local_max_worker_processes is lower than the selected Standby Server's future Primary value=$REMOTE_MAX_WORKER_PROCESSES.\"
    record_check \"PASSED\" \"Hot Standby Shared Memory\" \"former Primary settings are >= selected Standby future-Primary settings for max_connections, max_prepared_transactions, max_locks_per_transaction, max_wal_senders and max_worker_processes\"

    css_effective_reserve=$css_reserve_slots
"""
rep(needle, insert, label='hot standby comparison')

# 4) Validate operator-entered reverse slot after all branches select it.
rep("""    if [ -n \"${REVERSE_SLOT:-}\" ]; then
        candidate_switchover_safety_precheck 1 \"$REVERSE_SLOT\"
""", """    if [ -n \"${REVERSE_SLOT:-}\" ]; then
        validate_replication_slot_name \"$REVERSE_SLOT\" || die \"Invalid physical replication slot name '$REVERSE_SLOT'. Use only lower-case letters, numbers and underscore, within PostgreSQL max_identifier_length.\"
        candidate_switchover_safety_precheck 1 \"$REVERSE_SLOT\"
""", label='reverse slot validation call')

# 5) Resolve and validate remote timeout before any Primary shutdown.
rep("""    startup_options_guard || die \"Switchover cannot guarantee that the former Primary will restart with the same startup configuration.\"

    show_client_session_check
    show_switchover_execution_plan
""", """    startup_options_guard || die \"Switchover cannot guarantee that the former Primary will restart with the same startup configuration.\"

    remote_wait_output=$(remote_invoke --remote-timeout-default \"$REMOTE_PGDATA\" 2>/dev/null)
    remote_wait_rc=$?
    [ \"$remote_wait_rc\" -eq 0 ] || classify_remote_failure \"$remote_wait_rc\" \"Could not determine the selected Standby Server replay wait timeout before Primary shutdown.\"
    remote_wait_default=$(printf '%s\\n' \"$remote_wait_output\" | awk -F '\\t' '$1==\"TIMEOUT\" {print $2; exit}')
    case \"$remote_wait_default\" in ''|*[!0-9]*) die \"Selected Standby Server returned an invalid replay wait timeout: ${remote_wait_default:-<empty>}\" ;; esac
    [ \"$remote_wait_default\" -ge 1 ] 2>/dev/null || die \"Selected Standby Server returned a non-positive replay wait timeout.\"
    [ \"$remote_wait_default\" -le \"$MAX_WAIT_SECONDS\" ] 2>/dev/null || remote_wait_default=$MAX_WAIT_SECONDS

    show_client_session_check
    show_switchover_execution_plan
""", label='pre-shutdown timeout preflight')

rep("""    remote_wait_default=$(remote_invoke --remote-timeout-default \"$REMOTE_PGDATA\" 2>/dev/null | awk -F '\\t' '$1==\"TIMEOUT\" {print $2; exit}')
    case \"$remote_wait_default\" in ''|*[!0-9]*) remote_wait_default=120 ;; esac
    [ \"$remote_wait_default\" -le \"$MAX_WAIT_SECONDS\" ] 2>/dev/null || remote_wait_default=$MAX_WAIT_SECONDS
""", "", label='remove post-stop timeout query')

# 6) Require exact pg_controldata state; do not accept 'shut down in recovery'.
rep("""    case \"$shutdown_state\" in
        *\"shut down\"*) ;;
        *) die \"Former Primary control state is not a clean shutdown state: $shutdown_state\" ;;
    esac
""", """    case \"$shutdown_state\" in
        \"shut down\") ;;
        *) die \"Former Primary control state must be exactly 'shut down' before promotion; observed: ${shutdown_state:-<empty>}\" ;;
    esac
""", label='exact control state')

# 7) Preserve promotion/count remote failures before parsing output.
rep("""    promote_result=$(remote_invoke --remote-promote \"$REMOTE_PGDATA\" 2>/dev/null | awk -F '\\t' '$1==\"PROMOTED\" {print $2; exit}')
    [ \"$promote_result\" = \"primary\" ] || die \"Promotion of the selected Standby Server could not be verified. Do not restart the former Primary Server until roles are checked manually.\"
""", """    promote_output=$(remote_invoke --remote-promote \"$REMOTE_PGDATA\" 2>/dev/null)
    promote_rc=$?
    [ \"$promote_rc\" -eq 0 ] || classify_remote_failure \"$promote_rc\" \"Promotion command on the selected Standby Server failed or could not be verified. The former Primary remains stopped.\"
    promote_result=$(printf '%s\\n' \"$promote_output\" | awk -F '\\t' '$1==\"PROMOTED\" {print $2; exit}')
    [ \"$promote_result\" = \"primary\" ] || die \"Promotion of the selected Standby Server could not be verified. Do not restart the former Primary Server until roles are checked manually.\"
""", label='promotion remote status')

rep("""    new_primary_sees_old=$(remote_invoke --remote-count-standby \"$REMOTE_PGDATA\" \"$OLD_PRIMARY_APP\" 2>/dev/null | awk -F '\\t' '$1==\"COUNT\" {print $2; exit}')
    case \"$new_primary_sees_old\" in ''|*[!0-9]*) new_primary_sees_old=0 ;; esac
""", """    new_primary_count_output=$(remote_invoke --remote-count-standby \"$REMOTE_PGDATA\" \"$OLD_PRIMARY_APP\" 2>/dev/null)
    new_primary_count_rc=$?
    [ \"$new_primary_count_rc\" -eq 0 ] || classify_remote_failure \"$new_primary_count_rc\" \"Could not verify the former Primary's streaming connection on the new Primary.\"
    new_primary_sees_old=$(printf '%s\\n' \"$new_primary_count_output\" | awk -F '\\t' '$1==\"COUNT\" {print $2; exit}')
    case \"$new_primary_sees_old\" in ''|*[!0-9]*) die \"New Primary returned an invalid pg_stat_replication count for application_name=$OLD_PRIMARY_APP.\" ;; esac
""", label='new primary count status')

# 8) Treat final pre-mutation refusal as cancellation, not validation failure.
rep("""    if ! confirm_word \"SWITCHOVER\" \"Pre-Switchover checks completed. Review the execution plan above. The next step stages reverse replication settings and shuts down the current Primary.\"; then
        die \"Switchover cancelled before Primary shutdown.\"
    fi
""", """    if ! confirm_word \"SWITCHOVER\" \"Pre-Switchover checks completed. Review the execution plan above. The next step stages reverse replication settings and shuts down the current Primary.\"; then
        cancel_operation \"Switchover cancelled before Primary shutdown.\"
    fi
""", label='final switchover cancellation')

# 9) Make execution-plan start command match the real preserved-startup-options behavior without leaking options.
rep("""    say \"  9. Start former Primary as Standby\"
    printf '     %s -D %s -w start\\n' \"$PG_CTL_BIN\" \"$PGDATA\"
""", """    say \"  9. Start former Primary as Standby\"
    if [ -n \"$POSTMASTER_OPTIONS\" ]; then
        printf '     %s -D %s -o <preserved-postmaster.opts> -w start\\n' \"$PG_CTL_BIN\" \"$PGDATA\"
    else
        printf '     %s -D %s -w start\\n' \"$PG_CTL_BIN\" \"$PGDATA\"
    fi
""", label='execution plan startup')

# 10) Remote slot state must distinguish active physical slots; create-slot must refuse active/conflicting reuse.
rep("""    rss_state=$(psql_call_var slot \"$rss_slot\" \"SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot') THEN 'absent' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical') THEN 'physical' ELSE 'conflict' END\" 2>/dev/null | tr -d '[:space:]') || exit 3
""", """    rss_state=$(psql_call_var slot \"$rss_slot\" \"SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot') THEN 'absent' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical' AND active) THEN 'physical_active' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical' AND NOT active) THEN 'physical_inactive' ELSE 'conflict' END\" 2>/dev/null | tr -d '[:space:]') || exit 3
""", label='remote slot active state')

rep("""    rcs_exists=$(psql_call_var slot \"$rcs_slot\" \"SELECT count(*) FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical'\" 2>/dev/null | tr -d '[:space:]') || exit 4
    if [ \"$rcs_exists\" -eq 0 ]; then
        psql_call_var slot \"$rcs_slot\" \"SELECT slot_name FROM pg_create_physical_replication_slot(:'slot', true)\" >/dev/null || exit 5
    fi
""", """    rcs_state=$(psql_call_var slot \"$rcs_slot\" \"SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot') THEN 'absent' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical' AND NOT active) THEN 'physical_inactive' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical' AND active) THEN 'physical_active' ELSE 'conflict' END\" 2>/dev/null | tr -d '[:space:]') || exit 4
    case \"$rcs_state\" in
        absent) psql_call_var slot \"$rcs_slot\" \"SELECT slot_name FROM pg_create_physical_replication_slot(:'slot', true)\" >/dev/null || exit 5 ;;
        physical_inactive) : ;;
        physical_active|conflict) exit 6 ;;
        *) exit 7 ;;
    esac
""", label='remote create slot safe reuse')

# 11) Extend remote safety output with parameters required by Hot Standby shared-memory compatibility.
rep("""    rss_logical_slots=$(psql_call \"SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'\" 2>/dev/null | tr -d '[:space:]') || exit 9
    printf 'SWITCHOVER_SAFETY\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$rss_mws\" \"$rss_mrs\" \"$rss_slots\" \"$rss_risky\" \"$rss_archived\" \"$rss_failed\" \"$rss_last_ok\" \"$rss_last_fail\" \"$rss_unresolved\" \"$rss_wal_level\" \"$rss_logical_slots\"
""", """    rss_logical_slots=$(psql_call \"SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'\" 2>/dev/null | tr -d '[:space:]') || exit 9
    rss_max_connections=$(psql_call \"SHOW max_connections\" 2>/dev/null | tr -d '[:space:]') || exit 10
    rss_max_prepared_transactions=$(psql_call \"SHOW max_prepared_transactions\" 2>/dev/null | tr -d '[:space:]') || exit 11
    rss_max_locks_per_transaction=$(psql_call \"SHOW max_locks_per_transaction\" 2>/dev/null | tr -d '[:space:]') || exit 12
    rss_max_worker_processes=$(psql_call \"SHOW max_worker_processes\" 2>/dev/null | tr -d '[:space:]') || exit 13
    printf 'SWITCHOVER_SAFETY\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$rss_mws\" \"$rss_mrs\" \"$rss_slots\" \"$rss_risky\" \"$rss_archived\" \"$rss_failed\" \"$rss_last_ok\" \"$rss_last_fail\" \"$rss_unresolved\" \"$rss_wal_level\" \"$rss_logical_slots\" \"$rss_max_connections\" \"$rss_max_prepared_transactions\" \"$rss_max_locks_per_transaction\" \"$rss_max_worker_processes\"
""", label='remote hot standby output')

# Static regression assertions.
assert "*\"shut down\"*" not in s
assert "remote_wait_default=$(remote_invoke" not in s
assert "promote_result=$(remote_invoke" not in s
assert "new_primary_sees_old=$(remote_invoke" not in s
assert "css_line=$(remote_invoke" not in s
assert "css_slot_state=$(remote_invoke" not in s
assert "lrsp_result=$(remote_invoke" not in s
assert "physical_active" in s and "physical_inactive" in s
assert "Hot Standby Shared Memory" in s
assert "validate_replication_slot_name" in s

p.write_text(s)
