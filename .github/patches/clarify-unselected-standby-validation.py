from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
old='''    say "Unselected Standby Servers"\n    say "  역할 전환 후 former Primary Server가 Cascading Standby가 되면 선택하지 않은 Standby Server가 동일 서버를 계속 Upstream Server로 사용할 수 있는지 확인합니다."\n    say "  각 Standby Server의 system_identifier, sender_port, slot_name, pg_stat_wal_receiver.status 및 recovery_target_timeline을 확인합니다."\n'''
new='''    say "Unselected Standby Validation"\n    say "  아래 서버는 새 Primary 후보가 아닙니다. 선택한 Standby 외에 현재 Primary에 직접 연결된 나머지 Standby를 검증합니다."\n    say "  현재 설계에서는 Planned Switchover 후 former Primary가 Standby가 되고, 이 Unselected Standby는 former Primary를 계속 Upstream으로 사용하는 Cascading Standby 구조를 유지합니다."\n    say "  예상 토폴로지: Selected Standby (New Primary) -> Former Primary (Standby) -> Unselected Standby"\n    say "  system_identifier, sender_port, slot_name, pg_stat_wal_receiver.status 및 recovery_target_timeline을 확인합니다."\n'''
if old not in s: raise SystemExit('section text not found')
s=s.replace(old,new,1)
old='''        printf '  Standby Server %s/%s: application_name=%s, client_addr=%s, slot_name=%s\\n' "$usc_i" "$usc_count" "$usc_app" "$usc_client" "${usc_slot:-}"\n        usc_host=$(ask "Standby Server SSH host or 'local'" "$usc_client") || usage_die "Input cancelled."\n        [ -n "$usc_host" ] || usage_die "Standby Server host is required."\n'''
new='''        printf '  Validation target %s/%s (Unselected Standby; not a promotion candidate): application_name=%s, client_addr=%s, slot_name=%s\\n' "$usc_i" "$usc_count" "$usc_app" "$usc_client" "${usc_slot:-}"\n        usc_host=$(ask "Unselected Standby validation SSH host or 'local'" "$usc_client") || usage_die "Input cancelled."\n        [ -n "$usc_host" ] || usage_die "Unselected Standby validation host is required."\n'''
if old not in s: raise SystemExit('host prompt block not found')
s=s.replace(old,new,1)
old='''            usc_user=$(ask "Standby Server SSH user" "$(id -un 2>/dev/null || echo '')") || usage_die "Input cancelled."\n            [ -n "$usc_user" ] || usage_die "Standby Server SSH user is required."\n'''
new='''            usc_user=$(ask "Unselected Standby validation SSH user" "$(id -un 2>/dev/null || echo '')") || usage_die "Input cancelled."\n            [ -n "$usc_user" ] || usage_die "Unselected Standby validation SSH user is required."\n'''
if old not in s: raise SystemExit('user prompt block not found')
s=s.replace(old,new,1)
old='''            usc_pick=$(ask "Standby Server instance number for $usc_app" "") || usage_die "Input cancelled."\n'''
new='''            usc_pick=$(ask "Unselected Standby instance number for validation ($usc_app)" "") || usage_die "Input cancelled."\n'''
if old not in s: raise SystemExit('instance prompt not found')
s=s.replace(old,new,1)
p.write_text(s)
