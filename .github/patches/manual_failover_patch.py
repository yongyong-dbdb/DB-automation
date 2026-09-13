from pathlib import Path

p = Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s = p.read_text()

old = '''        case "$CURRENT_PHASE" in
            before_primary_stop|initial|precheck)
                # ALTER SYSTEM changes staged for role reversal must be restored
                # while the current Primary Server is still available.
                rollback_preconfigured_primary
                ;;
            after_primary_stop)
'''
new = '''        case "$CURRENT_PHASE" in
            before_primary_stop|initial|precheck)
                # ALTER SYSTEM changes staged for role reversal must be restored
                # while the current Primary Server is still available.
                rollback_preconfigured_primary
                ;;
            failover_precheck)
                :
                ;;
            failover_pre_promote)
                warn "Manual Failover stopped before promotion. Verify this server is still a Standby and keep the former Primary fenced until topology is confirmed."
                ;;
            failover_after_promotion)
                warn "Manual Failover promotion was requested. Keep the former Primary fenced and do NOT restart it as Primary."
                manual_recovery_branch_notice
                ;;
            after_primary_stop)
'''
assert old in s
s = s.replace(old, new, 1)

s = s.replace('die "Planned Switchover must run as the PostgreSQL server OS account ($clea_owner), not $clea_user; pg_ctl cannot safely administer this instance under another account."',
              'die "This operation must run as the PostgreSQL server OS account ($clea_owner), not $clea_user; PostgreSQL instance administration cannot safely continue under another OS account."', 1)

s = s.replace('manual_failover() {\n    CURRENT_PHASE="precheck"\n', 'manual_failover() {\n    CURRENT_PHASE="failover_precheck"\n', 1)
s = s.replace('    CURRENT_PHASE="after_primary_stop"\n    failover_promote=$(psql_call "SELECT pg_promote()"', '    CURRENT_PHASE="failover_pre_promote"\n    failover_promote=$(psql_call "SELECT pg_promote()"', 1)
s = s.replace('    SWITCHOVER_PROMOTED=1\n    CURRENT_PHASE="after_promotion"\n\n    refresh_role || die "Promotion was requested', '    SWITCHOVER_PROMOTED=1\n    CURRENT_PHASE="failover_after_promotion"\n\n    refresh_role || die "Promotion was requested', 1)

old = '''    warn "Keep the former Primary fenced. Before rejoining it, compare timelines/control state and use operator-directed pg_rewind when prerequisites are satisfied, otherwise create a new Standby from a fresh base backup."
    manual_recovery_branch_notice
'''
new = '''    say "  Former Primary Rejoin"
    say "    Keep the former Primary fenced. Before rejoining it, compare timelines/control state."
    say "    Use operator-directed pg_rewind only when its prerequisites and required WAL are satisfied; otherwise create a new Standby from a fresh base backup."
    record_check "MANUAL CHECK" "Former Primary Rejoin" "former Primary remains fenced; operator-directed pg_rewind or new base backup is required before rejoin"
'''
assert old in s
s = s.replace(old, new, 1)

p.write_text(s)
