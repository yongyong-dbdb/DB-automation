from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

s=s.replace('SWITCHOVER_PRIMARY_STOPPED=0\n','',1)
s=s.replace('    SWITCHOVER_PRIMARY_STOPPED=1\n','',1)

s=s.replace('for rld_name in owner pid started_at system_identifier data_directory; do',
            'for rld_name in owner pid started_at system_identifier data_directory lease_expires; do',1)

old='''acquire_candidate_lock() {
    REMOTE_LOCK_TOKEN="$SYSTEM_IDENTIFIER-$$-$(date +%s 2>/dev/null || echo unknown)"
    # Assume ownership before the call so a lost SSH response still triggers a
    # best-effort release. Failed release leaves the candidate locked closed.
    REMOTE_LOCK_HELD=1
    if ! remote_invoke --remote-lock-acquire "$REMOTE_PGDATA" "$REMOTE_LOCK_TOKEN" >/dev/null; then
        die "Could not acquire the selected Standby instance lock. Inspect its data_directory before retrying."
    fi
    record_check "PASSED" "Candidate Instance Lock" "exclusive lock acquired on selected Standby data_directory"
}
'''
new='''acquire_candidate_lock() {
    REMOTE_LOCK_TOKEN="$SYSTEM_IDENTIFIER-$$-$(date +%s 2>/dev/null || echo unknown)"
    # The remote lock uses a renewable lease. This lets a later controller
    # safely reclaim a lock left by a crashed process without guessing from PID
    # values that are meaningful only on another host.
    REMOTE_LOCK_LEASE_SECONDS=$((MAX_WAIT_SECONDS + 600))
    REMOTE_LOCK_HELD=1
    if ! remote_invoke --remote-lock-acquire "$REMOTE_PGDATA" "$REMOTE_LOCK_TOKEN" "$REMOTE_LOCK_LEASE_SECONDS" >/dev/null; then
        die "Could not acquire the selected Standby instance lock. Another controller may still hold a valid lease, or legacy/incomplete lock metadata requires inspection."
    fi
    record_check "PASSED" "Candidate Instance Lock" "exclusive renewable lease acquired on selected Standby data_directory"
}

refresh_candidate_lock() {
    [ "$REMOTE_LOCK_HELD" -eq 1 ] 2>/dev/null || return 0
    if ! remote_invoke --remote-lock-refresh "$REMOTE_PGDATA" "$REMOTE_LOCK_TOKEN" "$REMOTE_LOCK_LEASE_SECONDS" >/dev/null; then
        die "Candidate instance lock lease could not be refreshed. Refusing to continue because exclusive ownership can no longer be proven."
    fi
}
'''
if old not in s: raise SystemExit('acquire_candidate_lock block not found')
s=s.replace(old,new,1)

old='''verify_upstream_connection() {
    # Do not open a second libpq/replication connection here. The authoritative
    # topology evidence is the live pg_stat_replication row on the Primary plus
    # pg_stat_wal_receiver on the selected Standby. A separate probe can fail
    # because of authentication/passfile rules even while physical streaming is
    # healthy, producing a false negative.
    [ "$REMOTE_SYSTEM_IDENTIFIER" = "$SYSTEM_IDENTIFIER" ] || die "Selected Standby system_identifier changed during validation."
    [ "$REMOTE_ROLE" = "standby" ] || die "Selected Standby is no longer in recovery."
    [ "$REMOTE_RECEIVER_STATUS" = "streaming" ] || die "Selected Standby pg_stat_wal_receiver.status is no longer streaming."
    [ "$REMOTE_SENDER_PORT" = "$PGPORT" ] || die "Selected Standby pg_stat_wal_receiver.sender_port=$REMOTE_SENDER_PORT does not match current Primary port=$PGPORT."
    [ "${REMOTE_RECEIVER_SLOT:-}" = "${CANDIDATE_SLOT:-}" ] || die "Selected Standby pg_stat_wal_receiver.slot_name changed during validation."
    record_check "PASSED" "Streaming Topology Cross-check" "Primary pg_stat_replication and selected Standby pg_stat_wal_receiver agree on streaming state, system_identifier, sender_port=$PGPORT and physical slot=${CANDIDATE_SLOT:-<empty>}"
}

'''
if old not in s: raise SystemExit('verify_upstream_connection block not found')
s=s.replace(old,'',1)

old='''    if ! remote_invoke --remote-validate-candidate "$REMOTE_PGDATA" "$SYSTEM_IDENTIFIER" "$PGPORT" "${CANDIDATE_SLOT:-}" "$REMOTE_DOWNSTREAM_COUNT" >/dev/null; then
        rollback_preconfigured_primary
        die "The selected Standby Server's Current Role, system_identifier, pg_stat_wal_receiver, recovery settings, or pg_stat_replication result changed."
    fi
    verify_upstream_connection
    record_check "PASSED" "pg_stat_wal_receiver" "sender_port=$PGPORT, status=streaming"
'''
new='''    refresh_candidate_lock
    rst_remote_output=$(remote_invoke --remote-validate-candidate "$REMOTE_PGDATA" "$SYSTEM_IDENTIFIER" "$PGPORT" "${CANDIDATE_SLOT:-}" "$REMOTE_DOWNSTREAM_COUNT" 2>/dev/null)
    rst_remote_rc=$?
    if [ "$rst_remote_rc" -ne 0 ]; then
        rollback_preconfigured_primary
        classify_remote_failure "$rst_remote_rc" "The selected Standby Server's Current Role, system_identifier, pg_stat_wal_receiver, recovery settings, or pg_stat_replication result changed."
    fi
    rst_remote_line=$(printf '%s\\n' "$rst_remote_output" | awk -F '\\t' '$1=="CANDIDATE_READY" {print; exit}')
    [ -n "$rst_remote_line" ] || { rollback_preconfigured_primary; die "Selected Standby revalidation returned no CANDIDATE_READY record."; }
    REMOTE_SYSTEM_IDENTIFIER=$(printf '%s\\n' "$rst_remote_line" | awk -F '\\t' '{print $3}')
    REMOTE_ROLE=$(printf '%s\\n' "$rst_remote_line" | awk -F '\\t' '{print $4}')
    REMOTE_RECEIVER_STATUS=$(printf '%s\\n' "$rst_remote_line" | awk -F '\\t' '{print $5}')
    REMOTE_SENDER_PORT=$(printf '%s\\n' "$rst_remote_line" | awk -F '\\t' '{print $6}')
    REMOTE_RECEIVER_SLOT=$(printf '%s\\n' "$rst_remote_line" | awk -F '\\t' '{print $7}')
    REMOTE_DOWNSTREAM_COUNT=$(printf '%s\\n' "$rst_remote_line" | awk -F '\\t' '{print $8}')
    record_check "PASSED" "Streaming Topology Cross-check" "fresh Primary pg_stat_replication and selected Standby pg_stat_wal_receiver agree on streaming state, system_identifier=$REMOTE_SYSTEM_IDENTIFIER, sender_port=$REMOTE_SENDER_PORT and physical slot=${REMOTE_RECEIVER_SLOT:-<empty>}"
    record_check "PASSED" "pg_stat_wal_receiver" "fresh status=$REMOTE_RECEIVER_STATUS, sender_port=$REMOTE_SENDER_PORT, slot_name=${REMOTE_RECEIVER_SLOT:-<empty>}"
'''
if old not in s: raise SystemExit('revalidate remote block not found')
s=s.replace(old,new,1)

start=s.index('remote_lock_acquire() {')
end=s.index('\nremote_preflight() {', start)
newlocks=r'''remote_lock_acquire() {
    rla_data=$1
    rla_token=$2
    rla_lease=$3
    [ -n "$rla_token" ] && [ -d "$rla_data" ] && [ -w "$rla_data" ] || return 1
    case "$rla_lease" in ''|*[!0-9]*) return 1 ;; esac
    [ "$rla_lease" -ge 60 ] 2>/dev/null || return 1
    rla_dir="$rla_data/.postgresql-role-switch.lock"
    [ ! -L "$rla_dir" ] || return 1
    rla_now=$(date +%s 2>/dev/null) || return 1
    case "$rla_now" in ''|*[!0-9]*) return 1 ;; esac

    if ! mkdir "$rla_dir" 2>/dev/null; then
        [ ! -L "$rla_dir" ] && [ -d "$rla_dir" ] || return 1
        rla_owner=$(sed -n '1p' "$rla_dir/owner" 2>/dev/null || true)
        rla_saved_data=$(sed -n '1p' "$rla_dir/data_directory" 2>/dev/null || true)
        rla_expires=$(sed -n '1p' "$rla_dir/lease_expires" 2>/dev/null || true)
        case "$rla_owner" in remote:*) ;; *) return 1 ;; esac
        [ "$rla_saved_data" = "$rla_data" ] || return 1
        case "$rla_expires" in ''|*[!0-9]*) return 1 ;; esac
        [ "$rla_now" -gt "$rla_expires" ] 2>/dev/null || return 2
        # Expired lease: remove only the exact metadata files this script owns.
        for rla_name in owner pid started_at data_directory lease_expires; do
            [ ! -e "$rla_dir/$rla_name" ] || unlink "$rla_dir/$rla_name" 2>/dev/null || return 1
        done
        rmdir "$rla_dir" 2>/dev/null || return 1
        mkdir "$rla_dir" 2>/dev/null || return 2
    fi

    rla_expires=$((rla_now + rla_lease))
    printf 'remote:%s\n' "$rla_token" > "$rla_dir/owner" || return 1
    printf '0\n' > "$rla_dir/pid" || return 1
    printf '%s\n' "$rla_data" > "$rla_dir/data_directory" || return 1
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)" > "$rla_dir/started_at" || return 1
    printf '%s\n' "$rla_expires" > "$rla_dir/lease_expires" || return 1
}

remote_lock_refresh() {
    rlf_data=$1
    rlf_token=$2
    rlf_lease=$3
    case "$rlf_lease" in ''|*[!0-9]*) return 1 ;; esac
    rlf_dir="$rlf_data/.postgresql-role-switch.lock"
    [ ! -L "$rlf_dir" ] && [ -d "$rlf_dir" ] || return 1
    [ "$(sed -n '1p' "$rlf_dir/owner" 2>/dev/null)" = "remote:$rlf_token" ] || return 1
    [ "$(sed -n '1p' "$rlf_dir/data_directory" 2>/dev/null)" = "$rlf_data" ] || return 1
    rlf_now=$(date +%s 2>/dev/null) || return 1
    case "$rlf_now" in ''|*[!0-9]*) return 1 ;; esac
    rlf_expires=$((rlf_now + rlf_lease))
    printf '%s\n' "$rlf_expires" > "$rlf_dir/lease_expires" || return 1
}

remote_lock_release() {
    rlr_data=$1
    rlr_token=$2
    [ -n "$rlr_token" ] && [ -d "$rlr_data" ] || return 1
    rlr_dir="$rlr_data/.postgresql-role-switch.lock"
    [ ! -L "$rlr_dir" ] && [ -d "$rlr_dir" ] || return 1
    [ "$(sed -n '1p' "$rlr_dir/owner" 2>/dev/null)" = "remote:$rlr_token" ] || return 1
    [ "$(sed -n '1p' "$rlr_dir/data_directory" 2>/dev/null)" = "$rlr_data" ] || return 1
    for rlr_name in owner pid started_at data_directory lease_expires; do
        [ ! -e "$rlr_dir/$rlr_name" ] || unlink "$rlr_dir/$rlr_name" 2>/dev/null || return 1
    done
    rmdir "$rlr_dir" 2>/dev/null
}
'''
s=s[:start]+newlocks+s[end:]

old='''    rvc_receiver=$(psql_call "SELECT COALESCE(status,'') || E'\\\\t' || COALESCE(sender_port::text,'') || E'\\\\t' || COALESCE(slot_name,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p') || exit 5
    [ "$(printf '%s\\n' "$rvc_receiver" | awk -F '\\t' '{print $1}')" = "streaming" ] || exit 6
    [ "$(printf '%s\\n' "$rvc_receiver" | awk -F '\\t' '{print $2}')" = "$rvc_expected_port" ] || exit 7
    [ "$(printf '%s\\n' "$rvc_receiver" | awk -F '\\t' '{print $3}')" = "$rvc_expected_slot" ] || exit 8
'''
new='''    rvc_receiver=$(psql_call "SELECT COALESCE(status,'') || E'\\\\t' || COALESCE(sender_port::text,'') || E'\\\\t' || COALESCE(slot_name,'') FROM pg_stat_wal_receiver LIMIT 1" 2>/dev/null | sed -n '1p') || exit 5
    rvc_status=$(printf '%s\\n' "$rvc_receiver" | awk -F '\\t' '{print $1}')
    rvc_sender_port=$(printf '%s\\n' "$rvc_receiver" | awk -F '\\t' '{print $2}')
    rvc_sender_slot=$(printf '%s\\n' "$rvc_receiver" | awk -F '\\t' '{print $3}')
    [ "$rvc_status" = "streaming" ] || exit 6
    [ "$rvc_sender_port" = "$rvc_expected_port" ] || exit 7
    [ "$rvc_sender_slot" = "$rvc_expected_slot" ] || exit 8
'''
if old not in s: raise SystemExit('remote candidate receiver block not found')
s=s.replace(old,new,1)
s=s.replace('''    printf 'CANDIDATE_READY\\t%s\\n' "$rvc_pgdata"
}''', '''    printf 'CANDIDATE_READY\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$rvc_pgdata" "$SYSTEM_IDENTIFIER" "$LOCAL_ROLE" "$rvc_status" "$rvc_sender_port" "$rvc_sender_slot" "$rvc_downstreams"
}''',1)

old='''    --remote-lock-acquire)
        [ "$#" -eq 3 ] || exit 64
        remote_lock_acquire "$2" "$3"
        exit $?
        ;;
    --remote-lock-release)
'''
new='''    --remote-lock-acquire)
        [ "$#" -eq 4 ] || exit 64
        remote_lock_acquire "$2" "$3" "$4"
        exit $?
        ;;
    --remote-lock-refresh)
        [ "$#" -eq 4 ] || exit 64
        remote_lock_refresh "$2" "$3" "$4"
        exit $?
        ;;
    --remote-lock-release)
'''
if old not in s: raise SystemExit('remote lock dispatcher block not found')
s=s.replace(old,new,1)

# Refresh the lease immediately after promotion as the workflow can still spend
# time creating slots and rejoining the former Primary.
s=s.replace('''    SWITCHOVER_PROMOTED=1
    CURRENT_PHASE="after_promotion"
    info "Promotion verified: Current Role=Primary."
''','''    SWITCHOVER_PROMOTED=1
    CURRENT_PHASE="after_promotion"
    refresh_candidate_lock
    info "Promotion verified: Current Role=Primary."
''',1)

p.write_text(s)
