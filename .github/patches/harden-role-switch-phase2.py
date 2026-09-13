from pathlib import Path

p = Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s = p.read_text()

def rep(old, new, label):
    global s
    if old not in s:
        raise SystemExit(f'{label} not found')
    s = s.replace(old, new, 1)

# No operator prompt is allowed after the current Primary is stopped.
old = '''    [ "$remote_wait_default" -ge 1 ] 2>/dev/null || die "Selected Standby Server returned a non-positive replay wait timeout."
    [ "$remote_wait_default" -le "$MAX_WAIT_SECONDS" ] 2>/dev/null || remote_wait_default=$MAX_WAIT_SECONDS

    show_client_session_check
    show_switchover_execution_plan
'''
new = '''    [ "$remote_wait_default" -ge 1 ] 2>/dev/null || die "Selected Standby Server returned a non-positive replay wait timeout."
    [ "$remote_wait_default" -le "$MAX_WAIT_SECONDS" ] 2>/dev/null || remote_wait_default=$MAX_WAIT_SECONDS

    say "WAL Replay Catch-up Wait"
    say "  Primary Server를 종료하기 전에 final checkpoint replay 대기시간을 미리 결정합니다. Primary 종료 이후에는 추가 사용자 입력을 받지 않습니다."
    catchup_wait=$(ask "Wait seconds" "$remote_wait_default") || usage_die "Input cancelled."
    validate_wait_seconds "$catchup_wait" || usage_die "Wait seconds must be an integer between 1 and $MAX_WAIT_SECONDS."

    show_client_session_check
    show_switchover_execution_plan
'''
rep(old, new, 'pre-shutdown catchup input')

old = '''    say "WAL Replay Catch-up Wait"
    say "  선택한 Standby Server가 former Primary Server의 final checkpoint까지 replay할 최대 대기시간(초)을 입력합니다."
    catchup_wait=$(ask "Wait seconds" "$remote_wait_default") || usage_die "Input cancelled."
    validate_wait_seconds "$catchup_wait" || usage_die "Wait seconds must be an integer between 1 and $MAX_WAIT_SECONDS."

    if ! remote_invoke --remote-wait-lsn "$REMOTE_PGDATA" "$shutdown_lsn" "$catchup_wait" >/dev/null; then
'''
new = '''    if ! remote_invoke --remote-wait-lsn "$REMOTE_PGDATA" "$shutdown_lsn" "$catchup_wait" >/dev/null; then
'''
rep(old, new, 'remove post-stop prompt')

# Show the preselected wait value in the execution plan.
old = '''    say "  5. Wait until selected Standby replays through the final checkpoint"
    say "     SELECT pg_last_wal_replay_lsn();"
'''
new = '''    say "  5. Wait until selected Standby replays through the final checkpoint"
    say "     SELECT pg_last_wal_replay_lsn();"
    printf '     timeout=%s seconds\\n' "$catchup_wait"
'''
rep(old, new, 'execution plan wait value')

# Signal before mutation is cancellation; after mutation remains failure/partial-state handling.
old = '''    [ -z "$SIGNAL_NAME" ] || record_check "FAILED" "Signal" "$SIGNAL_NAME received"
    if [ "$CHECK_ONLY" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$RESULT_INITIALIZED" -eq 1 ]; then
'''
new = '''    if [ -n "$SIGNAL_NAME" ]; then
        case "$CURRENT_PHASE" in
            initial|precheck|before_primary_stop|failover_precheck)
                record_check "CANCELLED" "Signal" "$SIGNAL_NAME received before state-changing operation"
                LAST_ERROR="$SIGNAL_NAME received; operation cancelled before state-changing operation"
                rc=$EXIT_CANCELLED
                ;;
            *)
                record_check "FAILED" "Signal" "$SIGNAL_NAME received"
                ;;
        esac
    fi
    if [ "$CHECK_ONLY" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$RESULT_INITIALIZED" -eq 1 ]; then
'''
rep(old, new, 'signal classification')

# Manual Failover: collect candidate post-promotion policy settings.
old = '''    FAILOVER_DOWNSTREAM_COUNT=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || FAILOVER_DOWNSTREAM_COUNT=""

    [ "$FAILOVER_RECEIVER_STATUS" != "streaming" ] || die "Manual Failover is blocked because pg_stat_wal_receiver.status=streaming. The current Standby still has an active streaming connection to its Upstream Server."
'''
new = '''    FAILOVER_DOWNSTREAM_COUNT=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || FAILOVER_DOWNSTREAM_COUNT=""
    FAILOVER_SYNC_STANDBY_NAMES=$(psql_call "SHOW synchronous_standby_names" 2>/dev/null | sed -n '1p') || FAILOVER_SYNC_STANDBY_NAMES=""
    FAILOVER_SYNC_STANDBY_NAMES=$(printf '%s' "$FAILOVER_SYNC_STANDBY_NAMES" | sed 's/\\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    FAILOVER_DEFAULT_TX_READ_ONLY=$(psql_call "SHOW default_transaction_read_only" 2>/dev/null | tr -d '[:space:]') || FAILOVER_DEFAULT_TX_READ_ONLY=""
    FAILOVER_ARCHIVE_MODE=$(psql_call "SHOW archive_mode" 2>/dev/null | tr -d '[:space:]') || FAILOVER_ARCHIVE_MODE=""
    FAILOVER_ARCHIVE_READY=$(archive_mechanism_configured 2>/dev/null || echo 0)

    [ "$FAILOVER_RECEIVER_STATUS" != "streaming" ] || die "Manual Failover is blocked because pg_stat_wal_receiver.status=streaming. The current Standby still has an active streaming connection to its Upstream Server."
'''
rep(old, new, 'failover candidate settings')

# Manual Failover: validate existing downstream sender state and review post-promotion policies.
old = '''    case "$FAILOVER_DOWNSTREAM_COUNT" in ''|*[!0-9]*) die "Could not determine SELECT count(*) FROM pg_stat_replication on the failover candidate." ;; esac

    record_check "PASSED" "Manual Failover Candidate" "Current Role=Standby; recovery_target_timeline=latest; WAL replay is not paused"
'''
new = '''    case "$FAILOVER_DOWNSTREAM_COUNT" in ''|*[!0-9]*) die "Could not determine SELECT count(*) FROM pg_stat_replication on the failover candidate." ;; esac
    FAILOVER_BAD_DOWNSTREAM_COUNT=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND state <> 'streaming' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || FAILOVER_BAD_DOWNSTREAM_COUNT=""
    case "$FAILOVER_BAD_DOWNSTREAM_COUNT" in ''|*[!0-9]*) die "Could not validate downstream pg_stat_replication.state on the failover candidate." ;; esac
    [ "$FAILOVER_BAD_DOWNSTREAM_COUNT" -eq 0 ] || die "Manual Failover is blocked because $FAILOVER_BAD_DOWNSTREAM_COUNT downstream pg_stat_replication row(s) are not state=streaming."

    say ""
    say "Post-Promotion Policy Review"
    printf '  synchronous_standby_names     : %s\\n' "${FAILOVER_SYNC_STANDBY_NAMES:-<empty>}"
    printf '  default_transaction_read_only : %s\\n' "${FAILOVER_DEFAULT_TX_READ_ONLY:-<unknown>}"
    printf '  archive_mode                  : %s\\n' "${FAILOVER_ARCHIVE_MODE:-<unknown>}"
    if [ -n "$FAILOVER_SYNC_STANDBY_NAMES" ]; then
        warn "After Manual Failover, synchronous_standby_names='$FAILOVER_SYNC_STANDBY_NAMES' becomes active Primary policy and can delay/block synchronous commits if required Standby application_name values are absent."
        if ! choose_yes_no "The failover candidate's synchronous_standby_names policy has been reviewed" "no"; then
            cancel_operation "Manual Failover cancelled because synchronous replication policy was not confirmed."
        fi
        record_check "MANUAL CHECK" "Failover synchronous_standby_names" "operator reviewed post-promotion synchronous replication policy"
    fi
    case "$FAILOVER_DEFAULT_TX_READ_ONLY" in
        on|true|t)
            warn "The failover candidate has default_transaction_read_only=$FAILOVER_DEFAULT_TX_READ_ONLY. New sessions may default to read-only after promotion."
            if ! choose_yes_no "The failover candidate's default_transaction_read_only setting is intentional" "no"; then
                cancel_operation "Manual Failover cancelled because default_transaction_read_only was not accepted."
            fi
            ;;
    esac
    if [ "$FAILOVER_ARCHIVE_MODE" = "off" ]; then
        warn "archive_mode=off on the failover candidate. Continuous archiving will remain disabled after promotion."
        if ! choose_yes_no "Proceed with Manual Failover with archive_mode=off" "no"; then
            cancel_operation "Manual Failover cancelled because post-promotion archiving policy was not accepted."
        fi
    elif [ "$FAILOVER_ARCHIVE_READY" != "1" ]; then
        warn "archive_mode=$FAILOVER_ARCHIVE_MODE but no non-empty archive_command/archive_library was detected for this PostgreSQL version."
        if ! choose_yes_no "The post-promotion archive destination/mechanism has been reviewed" "no"; then
            cancel_operation "Manual Failover cancelled because continuous archiving readiness was not confirmed."
        fi
    fi

    record_check "PASSED" "Manual Failover Candidate" "Current Role=Standby; recovery_target_timeline=latest; WAL replay is not paused; downstream sender rows are streaming"
'''
rep(old, new, 'failover policy checks')

# Manual Failover: immediately before promotion, re-sample latest received WAL and all mutable readiness state.
old = '''    refresh_role || die "Could not revalidate Current Role immediately before Manual Failover."
    [ "$LOCAL_ROLE" = "standby" ] || die "Manual Failover candidate is no longer a Standby."
    failover_receiver_now=$(psql_call "SELECT COALESCE(status,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')
    [ "$failover_receiver_now" != "streaming" ] || die "Manual Failover blocked: pg_stat_wal_receiver.status became streaming again before promotion."
    failover_pause_now=$(pause_state 2>/dev/null || echo unknown)
    case "$failover_pause_now" in "not paused"|f|false|"") ;; *) die "Manual Failover blocked: WAL replay became paused before promotion." ;; esac

    CURRENT_PHASE="failover_pre_promote"
'''
new = '''    refresh_role || die "Could not revalidate Current Role immediately before Manual Failover."
    [ "$LOCAL_ROLE" = "standby" ] || die "Manual Failover candidate is no longer a Standby."
    failover_receiver_now=$(psql_call "SELECT COALESCE(status,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p')
    [ "$failover_receiver_now" != "streaming" ] || die "Manual Failover blocked: pg_stat_wal_receiver.status became streaming again before promotion."
    failover_pause_now=$(pause_state 2>/dev/null || echo unknown)
    case "$failover_pause_now" in "not paused"|f|false|"") ;; *) die "Manual Failover blocked: WAL replay became paused before promotion." ;; esac
    failover_timeline_now=$(psql_call "SHOW recovery_target_timeline" 2>/dev/null | tr -d '[:space:]') || failover_timeline_now=""
    [ "$failover_timeline_now" = "latest" ] || die "Manual Failover blocked: recovery_target_timeline changed before promotion: ${failover_timeline_now:-<empty>}."
    failover_latest_receive=$(psql_call "SELECT COALESCE(pg_last_wal_receive_lsn()::text,'')" 2>/dev/null | sed -n '1p')
    failover_replay_ready=$(psql_call "SELECT CASE WHEN pg_last_wal_receive_lsn() IS NULL THEN 1 WHEN pg_last_wal_replay_lsn() IS NOT NULL AND pg_last_wal_replay_lsn() >= pg_last_wal_receive_lsn() THEN 1 ELSE 0 END" 2>/dev/null | tr -d '[:space:]') || failover_replay_ready=0
    [ "$failover_replay_ready" = "1" ] || die "Manual Failover blocked: new WAL was received after the earlier catch-up and pg_last_wal_replay_lsn() has not reached the latest pg_last_wal_receive_lsn()=${failover_latest_receive:-<NULL>}. Run the failover check again after replay catches up."
    failover_bad_downstream_now=$(psql_call "SELECT count(*) FROM pg_stat_replication r WHERE state <> 'backup' AND state <> 'streaming' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null | tr -d '[:space:]') || failover_bad_downstream_now=""
    case "$failover_bad_downstream_now" in ''|*[!0-9]*) die "Manual Failover blocked: could not revalidate downstream pg_stat_replication.state immediately before promotion." ;; esac
    [ "$failover_bad_downstream_now" -eq 0 ] || die "Manual Failover blocked: $failover_bad_downstream_now downstream pg_stat_replication row(s) are no longer state=streaming."
    failover_sync_now=$(psql_call "SHOW synchronous_standby_names" 2>/dev/null | sed -n '1p') || failover_sync_now=""
    failover_sync_now=$(printf '%s' "$failover_sync_now" | sed 's/\\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "$failover_sync_now" = "$FAILOVER_SYNC_STANDBY_NAMES" ] || die "Manual Failover blocked: synchronous_standby_names changed after policy review. Re-run Manual Failover validation."

    CURRENT_PHASE="failover_pre_promote"
'''
rep(old, new, 'final failover revalidation')

# Static assertions.
assert 'catchup_wait=$(ask "Wait seconds" "$remote_wait_default")' in s
stop_pos = s.index('if ! stop_current_primary; then')
catch_pos = s.index('catchup_wait=$(ask "Wait seconds" "$remote_wait_default")')
assert catch_pos < stop_pos
assert 'new WAL was received after the earlier catch-up' in s
assert 'Post-Promotion Policy Review' in s
assert 'operation cancelled before state-changing operation' in s

p.write_text(s)
