from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

marker='''replication_control_menu() {\n'''
if marker not in s:
    raise SystemExit('replication_control_menu marker not found')
helper=r'''review_inactive_physical_slots() {
    refresh_role || { warn "Could not refresh role before physical replication slot review."; return 1; }
    rips_count=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_type='physical' AND NOT active AND NOT temporary" 2>/dev/null | tr -d '[:space:]') || {
        warn "Could not inspect inactive physical replication slots."
        return 1
    }
    case "$rips_count" in ''|*[!0-9]*) warn "Invalid inactive physical replication slot count: ${rips_count:-<empty>}"; return 1 ;; esac
    [ "$rips_count" -gt 0 ] || return 0

    section "Inactive Physical Replication Slot Review" "active=false인 physical replication slot을 정리 후보로 표시합니다. inactive만으로 obsolete를 확정하지 않으며 자동 삭제하지 않습니다."
    if [ "$PG_MAJOR" -ge 17 ]; then
        psql_call "SELECT slot_name || ' | active=' || active || ' | restart_lsn=' || COALESCE(restart_lsn::text,'NULL') || ' | wal_status=' || COALESCE(wal_status,'NULL') || ' | safe_wal_size=' || COALESCE(safe_wal_size::text,'NULL') || ' | inactive_since=' || COALESCE(inactive_since::text,'NULL') FROM pg_replication_slots WHERE slot_type='physical' AND NOT active AND NOT temporary ORDER BY slot_name" 2>/dev/null | sed 's/^/  /'
    elif [ "$PG_MAJOR" -ge 13 ]; then
        psql_call "SELECT slot_name || ' | active=' || active || ' | restart_lsn=' || COALESCE(restart_lsn::text,'NULL') || ' | wal_status=' || COALESCE(wal_status,'NULL') || ' | safe_wal_size=' || COALESCE(safe_wal_size::text,'NULL') FROM pg_replication_slots WHERE slot_type='physical' AND NOT active AND NOT temporary ORDER BY slot_name" 2>/dev/null | sed 's/^/  /'
    else
        psql_call "SELECT slot_name || ' | active=' || active || ' | restart_lsn=' || COALESCE(restart_lsn::text,'NULL') FROM pg_replication_slots WHERE slot_type='physical' AND NOT active AND NOT temporary ORDER BY slot_name" 2>/dev/null | sed 's/^/  /'
    fi

    warn "$rips_count inactive physical replication slot candidate(s) exist. Inactive does not prove that a slot is obsolete; a disconnected Standby may still depend on it."

    if [ "$LOCAL_ROLE" = "standby" ]; then
        say ""
        say "  Current Role=Standby"
        say "  이 자동화는 Standby 상태에서 physical replication slot을 삭제하지 않습니다."
        say "  승격 후 Primary가 되었을 때 topology와 slot 참조를 다시 확인한 뒤 삭제 여부를 선택합니다."
        record_check "MANUAL CHECK" "Inactive Physical Replication Slots" "$rips_count inactive physical slot candidate(s) detected on Standby; deletion intentionally deferred until Primary role and topology are revalidated"
        return 0
    fi

    mktemp_safe || { warn "Could not create inactive slot candidate file."; return 1; }
    rips_file=$SAFE_TMP
    psql_call "SELECT slot_name FROM pg_replication_slots WHERE slot_type='physical' AND NOT active AND NOT temporary ORDER BY slot_name" > "$rips_file" 2>/dev/null || {
        warn "Could not enumerate inactive physical slot names."
        return 1
    }

    rips_sync_names=""
    if [ "$PG_MAJOR" -ge 17 ]; then
        rips_sync_names=$(psql_call "SHOW synchronized_standby_slots" 2>/dev/null | sed -n '1p') || rips_sync_names=""
        rips_sync_names=$(printf '%s' "$rips_sync_names" | tr -d '[:space:]')
    fi

    while IFS= read -r rips_slot; do
        [ -n "$rips_slot" ] || continue
        if [ -n "$rips_sync_names" ]; then
            case ",$rips_sync_names," in
                *",$rips_slot,"*)
                    warn "Slot '$rips_slot' is referenced by synchronized_standby_slots and will not be offered for deletion."
                    record_check "MANUAL CHECK" "Inactive Physical Slot" "slot=$rips_slot retained because synchronized_standby_slots references it"
                    continue
                    ;;
            esac
        fi

        say ""
        printf '  Candidate slot: %s\n' "$rips_slot"
        say "  active=false만으로는 사용 종료를 증명하지 않습니다. 연결이 끊긴 Standby의 primary_slot_name, 운영 문서 및 현재 topology를 확인하십시오."
        if ! choose_yes_no "Drop inactive physical slot '$rips_slot' after confirming no Standby depends on it" "no"; then
            record_check "MANUAL CHECK" "Inactive Physical Slot" "slot=$rips_slot retained by operator"
            continue
        fi
        rips_confirm="DROP_SLOT_$rips_slot"
        if ! confirm_word "$rips_confirm" "Final confirmation to drop physical replication slot '$rips_slot'. This can release WAL retained for that slot."; then
            record_check "MANUAL CHECK" "Inactive Physical Slot" "slot=$rips_slot deletion cancelled at final confirmation"
            continue
        fi

        refresh_role || { warn "Could not revalidate role before dropping slot '$rips_slot'."; continue; }
        [ "$LOCAL_ROLE" = "primary" ] || { warn "Role changed to Standby; slot '$rips_slot' was not dropped."; continue; }
        rips_state=$(psql_call_var slot "$rips_slot" "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND slot_type='physical' AND NOT temporary AND NOT active) THEN 'drop_ok' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot' AND active) THEN 'active' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:'slot') THEN 'changed' ELSE 'absent' END" 2>/dev/null | tr -d '[:space:]') || rips_state=error
        case "$rips_state" in
            drop_ok)
                psql_call_var slot "$rips_slot" "SELECT pg_drop_replication_slot(:'slot')" >/dev/null 2>&1 || { warn "Failed to drop physical replication slot '$rips_slot'."; record_check "FAILED" "Inactive Physical Slot Drop" "slot=$rips_slot pg_drop_replication_slot failed"; continue; }
                info "Dropped inactive physical replication slot after explicit operator confirmation: $rips_slot"
                record_check "PASSED" "Inactive Physical Slot Drop" "slot=$rips_slot dropped after role/state revalidation and explicit confirmation"
                ;;
            active) warn "Slot '$rips_slot' became active and was not dropped." ;;
            absent) info "Slot '$rips_slot' no longer exists; nothing to drop." ;;
            *) warn "Slot '$rips_slot' changed state/type and was not dropped." ;;
        esac
    done < "$rips_file"
}

'''
s=s.replace(marker,helper+marker,1)

old='''                2) replication_status ;;\n'''
new='''                2) replication_status; review_inactive_physical_slots ;;\n'''
if old not in s:
    raise SystemExit('primary replication_status menu marker not found')
s=s.replace(old,new,1)
old='''                3) replication_status ;;\n'''
new='''                3) replication_status; review_inactive_physical_slots ;;\n'''
if old not in s:
    raise SystemExit('standby replication_status menu marker not found')
s=s.replace(old,new,1)

p.write_text(s)
