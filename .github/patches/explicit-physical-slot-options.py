from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

# Persist the precheck state for the execution-plan display.
old='''        css_slot_state=$(printf '%s\\n' "$css_slot_line" | awk -F '\\t' '{print $3}')\n        [ "$css_slot_name" = "$css_reverse_slot" ] || die "Reverse replication slot state response name mismatch: expected=$css_reverse_slot observed=${css_slot_name:-<empty>}"\n        case "$css_slot_state" in\n'''
new='''        css_slot_state=$(printf '%s\\n' "$css_slot_line" | awk -F '\\t' '{print $3}')\n        [ "$css_slot_name" = "$css_reverse_slot" ] || die "Reverse replication slot state response name mismatch: expected=$css_reverse_slot observed=${css_slot_name:-<empty>}"\n        REVERSE_SLOT_PRECHECK_STATE=$css_slot_state\n        case "$css_slot_state" in\n'''
if old not in s: raise SystemExit('precheck state marker not found')
s=s.replace(old,new,1)

# Make the execution plan describe all slot branches and explicit function options.
old='''    say "  7. Create/verify reverse physical replication slot when configured"\n    [ -z "${REVERSE_SLOT:-}" ] || printf "     SELECT pg_create_physical_replication_slot('%s', true);\\n" "$REVERSE_SLOT"\n'''
new='''    say "  7. Create/verify reverse physical replication slot when configured"\n    if [ -n "${REVERSE_SLOT:-}" ]; then\n        printf '     Precheck state: %s\\n' "${REVERSE_SLOT_PRECHECK_STATE:-unknown}"\n        say "     Revalidate pg_replication_slots on the promoted New Primary before changing anything."\n        say "     absent            -> create persistent slot with immediately_reserve=true, temporary=false"\n        printf "        SELECT pg_create_physical_replication_slot('%s', true, false);\\n" "$REVERSE_SLOT"\n        say "     physical_inactive -> reuse the existing physical slot; do not recreate it"\n        say "     physical_active   -> abort; an active slot is not reassigned"\n        say "     conflict          -> abort; same slot_name is not a reusable physical slot"\n    else\n        say "     No reverse physical replication slot configured."\n    fi\n'''
if old not in s: raise SystemExit('execution plan slot block not found')
s=s.replace(old,new,1)

# Harden actual slot creation/reuse and explicitly pass temporary=false.
start=s.index('remote_create_slot() {')
end=s.index('\nremote_check_logical_slot() {', start)
new_func=r'''remote_create_slot() {
    rcs_pgdata=$1
    rcs_slot=$2
    remote_init_exact "$rcs_pgdata"
    [ "$LOCAL_ROLE" = "primary" ] || exit 3
    case "$rcs_slot" in ''|*[!a-z0-9_]*) exit 64 ;; esac

    # Revalidate on the promoted New Primary. Never rely only on the earlier
    # precheck because slot state can change between validation and promotion.
    rcs_count=$(psql_call "SELECT count(*) FROM pg_replication_slots WHERE slot_name='$rcs_slot'" 2>/dev/null | tr -d '[:space:]') || exit 4
    case "$rcs_count" in ''|*[!0-9]*) exit 4 ;; esac
    if [ "$rcs_count" -eq 0 ] 2>/dev/null; then
        # immediately_reserve=true reserves WAL immediately; temporary=false
        # creates the persistent physical slot required after this SSH session ends.
        psql_call "SELECT slot_name FROM pg_create_physical_replication_slot('$rcs_slot', true, false)" >/dev/null || exit 5
        printf 'SLOT\t%s\tcreated\timmediately_reserve=true\ttemporary=false\n' "$rcs_slot"
        return 0
    fi
    [ "$rcs_count" -eq 1 ] 2>/dev/null || exit 7

    rcs_row=$(psql_call "SELECT slot_type || E'\\t' || active::text FROM pg_replication_slots WHERE slot_name='$rcs_slot'" 2>/dev/null | sed -n '1p') || exit 4
    rcs_type=$(printf '%s\n' "$rcs_row" | awk -F '\t' '{print $1}')
    rcs_active=$(printf '%s\n' "$rcs_row" | awk -F '\t' '{print $2}')
    [ "$rcs_type" = physical ] || exit 6
    case "$rcs_active" in
        f|false)
            printf 'SLOT\t%s\treused\timmediately_reserve=existing\ttemporary=false\n' "$rcs_slot"
            return 0
            ;;
        t|true) exit 6 ;;
        *) exit 7 ;;
    esac
}
'''
s=s[:start]+new_func+s[end:]
p.write_text(s)
