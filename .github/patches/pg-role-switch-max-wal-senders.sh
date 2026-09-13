#!/bin/sh
set -eu

TARGET='PostgreSQL/postgresql_role_switch_v0.1.22.sh'
test -f "$TARGET"

count_exact() {
    grep -F -c "$1" "$TARGET" || true
}

[ "$(count_exact 'REMOTE_ARCHIVER_UNRESOLVED=""')" -eq 1 ]
awk '{print} $0=="REMOTE_ARCHIVER_UNRESOLVED=\"\"" {print "REMOTE_WAL_LEVEL=\"\""; print "REMOTE_LOGICAL_SLOT_COUNT=\"\""}' "$TARGET" > "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

cat > /tmp/candidate_function <<'EOF'
candidate_switchover_safety_precheck() {
    css_reserve_slots=${1:-0}
    css_reverse_slot=${2:-}
    case "$REMOTE_DOWNSTREAM_COUNT" in ''|*[!0-9]*) die "The selected Standby Server returned an invalid downstream count: ${REMOTE_DOWNSTREAM_COUNT:-<empty>}" ;; esac
    css_line=$(remote_invoke --remote-switchover-safety "$REMOTE_PGDATA" 2>/dev/null | awk -F '\t' '$1=="SWITCHOVER_SAFETY" {print; exit}') || classify_remote_failure "$?" "Could not inspect the selected Standby Server's replication settings and replication slot state."
    [ -n "$css_line" ] || die "Selected Standby Server returned no replication settings and replication slot state."
    REMOTE_MAX_WAL_SENDERS=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $2}')
    REMOTE_MAX_REPLICATION_SLOTS=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $3}')
    REMOTE_REPLICATION_SLOT_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $4}')
    REMOTE_RISKY_PHYSICAL_SLOT_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $5}')
    REMOTE_ARCHIVED_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $6}')
    REMOTE_ARCHIVER_FAILED_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $7}')
    REMOTE_LAST_ARCHIVED_TIME=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $8}')
    REMOTE_LAST_FAILED_TIME=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $9}')
    REMOTE_ARCHIVER_UNRESOLVED=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $10}')
    REMOTE_WAL_LEVEL=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $11}')
    REMOTE_LOGICAL_SLOT_COUNT=$(printf '%s\n' "$css_line" | awk -F '\t' '{print $12}')

    for css_n in "$REMOTE_MAX_WAL_SENDERS" "$REMOTE_MAX_REPLICATION_SLOTS" "$REMOTE_REPLICATION_SLOT_COUNT" "$REMOTE_LOGICAL_SLOT_COUNT"; do
        case "$css_n" in ''|*[!0-9]*) die "Selected Standby Server returned an invalid PostgreSQL replication setting or slot count: ${css_n:-<empty>}" ;; esac
    done
    case "$REMOTE_WAL_LEVEL" in minimal|replica|logical) ;; *) die "Selected Standby Server returned an invalid wal_level: ${REMOTE_WAL_LEVEL:-<empty>}" ;; esac

    css_effective_reserve=$css_reserve_slots
    if [ "$css_reserve_slots" -eq 1 ] 2>/dev/null && [ -n "$css_reverse_slot" ]; then
        css_slot_state=$(remote_invoke --remote-slot-state "$REMOTE_PGDATA" "$css_reverse_slot" 2>/dev/null | awk -F '\t' '$1=="SLOT_STATE" {print $3; exit}') || classify_remote_failure "$?" "Could not inspect reverse replication slot state on the selected Standby Server."
        case "$css_slot_state" in
            absent) css_effective_reserve=1 ;;
            physical) css_effective_reserve=0 ;;
            conflict) die "Replication slot '$css_reverse_slot' already exists on the selected Standby Server but slot_type is not physical. Choose another slot_name." ;;
            *) die "Unexpected replication slot state for $css_reverse_slot: ${css_slot_state:-<empty>}" ;;
        esac
    fi

    css_required_slots=$((REMOTE_REPLICATION_SLOT_COUNT + css_effective_reserve))
    [ "$REMOTE_MAX_REPLICATION_SLOTS" -ge "$css_required_slots" ] || die "Selected Standby Server max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS is lower than required replication slots=$css_required_slots (existing=$REMOTE_REPLICATION_SLOT_COUNT, additional physical replication slot=$css_effective_reserve)."

    css_local_logical_slots=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'" 2>/dev/null | tr -d '[:space:]') || die "Could not inspect logical replication slots on the current Primary Server."
    case "$css_local_logical_slots" in ''|*[!0-9]*) die "Unexpected logical replication slot count on the current Primary Server: ${css_local_logical_slots:-<empty>}" ;; esac

    css_physical_replicas=$((REMOTE_DOWNSTREAM_COUNT + 1))
    if [ "$css_local_logical_slots" -gt 0 ] || [ "$REMOTE_LOGICAL_SLOT_COUNT" -gt 0 ]; then
        [ "$REMOTE_WAL_LEVEL" = "logical" ] || die "Logical replication slots exist, but the selected Standby Server wal_level=$REMOTE_WAL_LEVEL. A promoted server that publishes logical replication requires wal_level=logical."
        css_required_senders=$((REMOTE_MAX_REPLICATION_SLOTS + css_physical_replicas))
        css_sender_basis="max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS + physical replicas=$css_physical_replicas"
    else
        css_required_senders=$css_physical_replicas
        css_sender_basis="physical replicas=$css_physical_replicas"
    fi

    [ "$REMOTE_MAX_WAL_SENDERS" -ge "$css_required_senders" ] || die "Selected Standby Server max_wal_senders=$REMOTE_MAX_WAL_SENDERS is lower than required=$css_required_senders ($css_sender_basis)."
    if [ "$REMOTE_MAX_WAL_SENDERS" -eq "$css_required_senders" ]; then
        warn "Selected Standby Server max_wal_senders=$REMOTE_MAX_WAL_SENDERS has no capacity above the calculated maximum expected replication clients ($css_sender_basis). PostgreSQL documentation recommends setting max_wal_senders slightly higher so abruptly disconnected streaming clients can reconnect before the old WAL sender times out."
        record_check "WARNING" "max_wal_senders" "configured=$REMOTE_MAX_WAL_SENDERS; calculated expected maximum=$css_required_senders; no additional connection capacity"
    else
        record_check "PASSED" "max_wal_senders" "configured=$REMOTE_MAX_WAL_SENDERS; calculated expected maximum=$css_required_senders; basis=$css_sender_basis"
    fi

    if [ "$REMOTE_MAX_REPLICATION_SLOTS" -eq "$css_required_slots" ] && { [ "$css_local_logical_slots" -gt 0 ] || [ "$REMOTE_LOGICAL_SLOT_COUNT" -gt 0 ]; }; then
        warn "Selected Standby Server max_replication_slots=$REMOTE_MAX_REPLICATION_SLOTS has no capacity above currently accounted replication slots. PostgreSQL logical replication documentation requires reserve for table synchronization."
        record_check "WARNING" "max_replication_slots" "configured=$REMOTE_MAX_REPLICATION_SLOTS; accounted=$css_required_slots; no reserve for table synchronization"
    else
        record_check "PASSED" "max_replication_slots" "configured=$REMOTE_MAX_REPLICATION_SLOTS; accounted=$css_required_slots; existing=$REMOTE_REPLICATION_SLOT_COUNT; additional physical replication slot=$css_effective_reserve"
    fi

    if [ "$REMOTE_RISKY_PHYSICAL_SLOT_COUNT" = "-1" ]; then
        record_check "MANUAL CHECK" "pg_replication_slots.wal_status" "PostgreSQL $REMOTE_MAJOR does not expose pg_replication_slots.wal_status"
    else
        case "$REMOTE_RISKY_PHYSICAL_SLOT_COUNT" in ''|*[!0-9]*) die "Selected Standby Server returned an invalid pg_replication_slots.wal_status risk count: $REMOTE_RISKY_PHYSICAL_SLOT_COUNT" ;; esac
        [ "$REMOTE_RISKY_PHYSICAL_SLOT_COUNT" -eq 0 ] || die "Selected Standby Server has $REMOTE_RISKY_PHYSICAL_SLOT_COUNT physical replication slot(s) with pg_replication_slots.wal_status=unreserved/lost. Planned Switchover is blocked."
        record_check "PASSED" "pg_replication_slots.wal_status" "no physical replication slot has wal_status=unreserved/lost"
    fi
}
EOF

awk '
FNR==NR { repl=repl $0 ORS; next }
/^candidate_switchover_safety_precheck\(\) \{/ { printf "%s", repl; skip=1; next }
/^local_archiver_health_guard\(\) \{/ { skip=0 }
!skip { print }
' /tmp/candidate_function "$TARGET" > "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

cat > /tmp/remote_function <<'EOF'
remote_switchover_safety() {
    rss_pgdata=$1
    remote_init_exact "$rss_pgdata"
    rss_mws=$(psql_call "SHOW max_wal_senders" 2>/dev/null | tr -d '[:space:]') || exit 3
    rss_mrs=$(psql_call "SHOW max_replication_slots" 2>/dev/null | tr -d '[:space:]') || exit 4
    rss_slots=$(psql_call "SELECT count(*) FROM pg_replication_slots" 2>/dev/null | tr -d '[:space:]') || exit 5
    if [ "$PG_MAJOR" -ge 13 ]; then
        rss_risky=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='physical' AND wal_status IN ('unreserved','lost')" 2>/dev/null | tr -d '[:space:]') || exit 6
    else
        rss_risky=-1
    fi
    rss_arch=$(psql_call "SELECT archived_count::text || E'\\t' || failed_count::text || E'\\t' || COALESCE(last_archived_time::text,'') || E'\\t' || COALESCE(last_failed_time::text,'') || E'\\t' || CASE WHEN failed_count > 0 AND last_failed_time IS NOT NULL AND (last_archived_time IS NULL OR last_failed_time > last_archived_time) THEN '1' ELSE '0' END FROM pg_stat_archiver" 2>/dev/null | sed -n '1p') || exit 7
    rss_archived=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $1}')
    rss_failed=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $2}')
    rss_last_ok=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $3}')
    rss_last_fail=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $4}')
    rss_unresolved=$(printf '%s\n' "$rss_arch" | awk -F '\t' '{print $5}')
    rss_wal_level=$(psql_call "SHOW wal_level" 2>/dev/null | tr -d '[:space:]') || exit 8
    rss_logical_slots=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'" 2>/dev/null | tr -d '[:space:]') || exit 9
    printf 'SWITCHOVER_SAFETY\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rss_mws" "$rss_mrs" "$rss_slots" "$rss_risky" "$rss_archived" "$rss_failed" "$rss_last_ok" "$rss_last_fail" "$rss_unresolved" "$rss_wal_level" "$rss_logical_slots"
}
EOF

awk '
FNR==NR { repl=repl $0 ORS; next }
/^remote_switchover_safety\(\) \{/ { printf "%s", repl; skip=1; next }
/^remote_wait_streaming_downstreams\(\) \{/ { skip=0 }
!skip { print }
' /tmp/remote_function "$TARGET" > "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

# Static validation: POSIX shell syntax and exact wiring.
sh -n "$TARGET"
[ "$(grep -F -c 'REMOTE_WAL_LEVEL=""' "$TARGET")" -eq 1 ]
[ "$(grep -F -c 'REMOTE_LOGICAL_SLOT_COUNT=""' "$TARGET")" -eq 1 ]
[ "$(grep -F -c 'css_required_senders=$((REMOTE_MAX_REPLICATION_SLOTS + css_physical_replicas))' "$TARGET")" -eq 1 ]
[ "$(grep -F -c 'PostgreSQL documentation recommends setting max_wal_senders slightly higher' "$TARGET")" -eq 1 ]
[ "$(grep -F -c 'reserve for table synchronization' "$TARGET")" -eq 1 ]
[ "$(grep -F -c 'rss_wal_level=$(psql_call "SHOW wal_level"' "$TARGET")" -eq 1 ]
[ "$(grep -F -c "rss_logical_slots=\$(psql_call \"SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical'\"" "$TARGET")" -eq 1 ]
[ "$(grep -F -c 'candidate_switchover_safety_precheck 1 "$REVERSE_SLOT"' "$TARGET")" -eq 1 ]
[ "$(grep -F -c 'candidate_switchover_safety_precheck 0' "$TARGET")" -ge 1 ]

# No prohibited separate runtime/package dependency was introduced into target.
! grep -E '(^|[[:space:]])(python|python3|jq|yq|expect|perl|node|npm|pip)([[:space:]]|$)' "$TARGET"

# Guard against environment-specific hardcoding in the new capacity logic.
! sed -n '/^candidate_switchover_safety_precheck() {/,/^local_archiver_health_guard() {/p' "$TARGET" | grep -E '(/var/lib/pgsql|/usr/pgsql|127\.0\.0\.1|localhost|5432|postgresql-[0-9]+|slot[0-9]+)'

git diff --check -- "$TARGET"
