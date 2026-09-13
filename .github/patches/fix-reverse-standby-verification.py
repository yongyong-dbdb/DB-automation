from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

old='''    new_primary_count_output=$(remote_invoke --remote-count-standby "$REMOTE_PGDATA" "$OLD_PRIMARY_APP" 2>/dev/null)
    new_primary_count_rc=$?
    [ "$new_primary_count_rc" -eq 0 ] || classify_remote_failure "$new_primary_count_rc" "Could not verify the former Primary's streaming connection on the new Primary."
    new_primary_sees_old=$(printf '%s\\n' "$new_primary_count_output" | awk -F '\\t' '$1=="COUNT" {print $2; exit}')
    case "$new_primary_sees_old" in ''|*[!0-9]*) die "New Primary returned an invalid pg_stat_replication count for application_name=$OLD_PRIMARY_APP." ;; esac
    [ "$new_primary_sees_old" -eq 1 ] || die "New Primary pg_stat_replication has $new_primary_sees_old streaming row(s) for application_name=$OLD_PRIMARY_APP; expected exactly 1."
'''
new='''    # primary_conninfo may intentionally omit application_name. PostgreSQL's
    # physical WAL receiver then uses cluster_name when set, otherwise
    # "walreceiver" as the effective application_name. Verify the effective
    # value, and when a reverse physical slot is configured also require that
    # exact slot to be attached to the same streaming WAL sender.
    if [ -n "$OLD_PRIMARY_APP" ]; then
        OLD_PRIMARY_EFFECTIVE_APP=$OLD_PRIMARY_APP
        OLD_PRIMARY_APP_SOURCE="explicit primary_conninfo application_name"
    else
        OLD_PRIMARY_EFFECTIVE_APP=$(psql_call "SHOW cluster_name" 2>/dev/null | sed -n '1p') || OLD_PRIMARY_EFFECTIVE_APP=""
        if [ -n "$OLD_PRIMARY_EFFECTIVE_APP" ]; then
            OLD_PRIMARY_APP_SOURCE="PostgreSQL default from cluster_name"
        else
            OLD_PRIMARY_EFFECTIVE_APP="walreceiver"
            OLD_PRIMARY_APP_SOURCE="PostgreSQL WAL receiver default"
        fi
    fi

    new_primary_count_output=$(remote_invoke --remote-count-standby "$REMOTE_PGDATA" "$OLD_PRIMARY_EFFECTIVE_APP" "${REVERSE_SLOT:-}" 2>/dev/null)
    new_primary_count_rc=$?
    [ "$new_primary_count_rc" -eq 0 ] || classify_remote_failure "$new_primary_count_rc" "Could not verify the former Primary's streaming connection on the new Primary."
    new_primary_sees_old=$(printf '%s\\n' "$new_primary_count_output" | awk -F '\\t' '$1=="COUNT" {print $2; exit}')
    case "$new_primary_sees_old" in ''|*[!0-9]*) die "New Primary returned an invalid pg_stat_replication verification count for effective application_name=$OLD_PRIMARY_EFFECTIVE_APP, slot=${REVERSE_SLOT:-<none>}." ;; esac
    [ "$new_primary_sees_old" -eq 1 ] || die "New Primary pg_stat_replication has $new_primary_sees_old matching streaming row(s) for effective application_name=$OLD_PRIMARY_EFFECTIVE_APP, slot=${REVERSE_SLOT:-<none>}; expected exactly 1."
    record_check "PASSED" "Reverse Streaming Verification" "effective application_name=$OLD_PRIMARY_EFFECTIVE_APP ($OLD_PRIMARY_APP_SOURCE); slot=${REVERSE_SLOT:-<none>}; exactly one streaming WAL sender matched"
'''
if old not in s: raise SystemExit('post-switchover verification block not found')
s=s.replace(old,new,1)

old='''    printf '  SELECT count(*) FROM pg_stat_replication: %s (application_name=%s)\\n' "$new_primary_sees_old" "$OLD_PRIMARY_APP"
'''
new='''    printf '  SELECT count(*) FROM pg_stat_replication: %s (effective application_name=%s, slot=%s)\\n' "$new_primary_sees_old" "$OLD_PRIMARY_EFFECTIVE_APP" "${REVERSE_SLOT:-<none>}"
'''
if old not in s: raise SystemExit('post-switchover summary line not found')
s=s.replace(old,new,1)

old='''remote_count_standby() {
    rcs2_pgdata=$1
    rcs2_app=$2
    remote_init_exact "$rcs2_pgdata"
    rcs2_output=$(psql_call_var app "$rcs2_app" "SELECT count(*) FROM pg_stat_replication r WHERE application_name=:'app' AND state='streaming' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null) || return 1
    rcs2_count=$(printf '%s' "$rcs2_output" | tr -d '[:space:]')
    case "$rcs2_count" in ''|*[!0-9]*) return 1 ;; esac
    printf 'COUNT\\t%s\\n' "$rcs2_count"
}
'''
new='''remote_count_standby() {
    rcs2_pgdata=$1
    rcs2_app=$2
    rcs2_slot=$3
    remote_init_exact "$rcs2_pgdata"
    [ -n "$rcs2_app" ] || return 1
    if [ -n "$rcs2_slot" ]; then
        rcs2_output=$(printf '%s\\n' "SELECT count(*) FROM pg_stat_replication r WHERE r.application_name=:'app' AND r.state='streaming' AND EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='physical' AND s.slot_name=:'slot')" | "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -v "app=$rcs2_app" -v "slot=$rcs2_slot" ${PGUSER_LOCAL:+-U "$PGUSER_LOCAL"} ${SOCKET_DIR:+-h "$SOCKET_DIR"} ${PGPORT:+-p "$PGPORT"} -d "$DB_NAME" 2>/dev/null) || return 1
    else
        rcs2_output=$(psql_call_var app "$rcs2_app" "SELECT count(*) FROM pg_stat_replication r WHERE application_name=:'app' AND state='streaming' AND NOT EXISTS (SELECT 1 FROM pg_replication_slots s WHERE s.active_pid=r.pid AND s.slot_type='logical')" 2>/dev/null) || return 1
    fi
    rcs2_count=$(printf '%s' "$rcs2_output" | tr -d '[:space:]')
    case "$rcs2_count" in ''|*[!0-9]*) return 1 ;; esac
    printf 'COUNT\\t%s\\n' "$rcs2_count"
}
'''
if old not in s: raise SystemExit('remote_count_standby block not found')
s=s.replace(old,new,1)

old='''    --remote-count-standby)
        [ "$#" -eq 3 ] || exit 64
        remote_count_standby "$2" "$3"
        exit $?
        ;;
'''
new='''    --remote-count-standby)
        [ "$#" -eq 4 ] || exit 64
        remote_count_standby "$2" "$3" "$4"
        exit $?
        ;;
'''
if old not in s: raise SystemExit('remote-count dispatcher not found')
s=s.replace(old,new,1)

p.write_text(s)
