from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
old='''    OLD_PRIMARY_APP_DEFAULT=$(psql_call "SHOW cluster_name" 2>/dev/null | sed -n '1p')\n    if [ -z "$OLD_PRIMARY_APP_DEFAULT" ]; then\n        OLD_PRIMARY_APP_DEFAULT=$(hostname 2>/dev/null || echo old_primary)\n    fi\n    say "application_name"\n    say "  역할 전환 후 former Primary가 새 Standby로 연결될 때 pg_stat_replication에 표시될 이름입니다."\n    OLD_PRIMARY_APP=$(ask "Former Primary application_name" "$OLD_PRIMARY_APP_DEFAULT") || usage_die "Input cancelled."\n\n    ci_host=$(conninfo_quote_value "$NEW_PRIMARY_DB_HOST")\n    ci_user=$(conninfo_quote_value "$CANDIDATE_REPL_USER")\n    ci_app=$(conninfo_quote_value "$OLD_PRIMARY_APP")\n    REVERSE_CONNINFO="host='$ci_host' port='$REMOTE_PORT' user='$ci_user' application_name='$ci_app'"\n'''
new='''    # Preserve an unset application_name. Do not invent a hostname-based value\n    # during role reversal; an empty value means primary_conninfo omits the\n    # application_name parameter entirely. cluster_name is not the same setting\n    # and must not be repurposed as an implicit replication application_name.\n    OLD_PRIMARY_APP_DEFAULT=""\n    say "application_name"\n    say "  역할 전환 후 former Primary가 새 Standby로 연결될 때 pg_stat_replication에 표시할 선택적 이름입니다."\n    say "  기존에 별도 application_name을 사용하지 않았다면 빈 값으로 유지합니다. Enter만 입력하면 primary_conninfo에 application_name을 추가하지 않습니다."\n    OLD_PRIMARY_APP=$(ask "Former Primary application_name (empty = omit)" "$OLD_PRIMARY_APP_DEFAULT") || usage_die "Input cancelled."\n\n    ci_host=$(conninfo_quote_value "$NEW_PRIMARY_DB_HOST")\n    ci_user=$(conninfo_quote_value "$CANDIDATE_REPL_USER")\n    REVERSE_CONNINFO="host='$ci_host' port='$REMOTE_PORT' user='$ci_user'"\n    if [ -n "$OLD_PRIMARY_APP" ]; then\n        ci_app=$(conninfo_quote_value "$OLD_PRIMARY_APP")\n        REVERSE_CONNINFO="$REVERSE_CONNINFO application_name='$ci_app'"\n    fi\n'''
if old not in s: raise SystemExit('application_name block not found')
s=s.replace(old,new,1)
old='''    say "  host, hostaddr, port, user, application_name은 자동 탐지/입력한 값을 사용하므로 여기서는 다시 지정하지 않습니다."\n'''
new='''    say "  host, hostaddr, port, user는 자동 탐지/입력한 값을 사용하므로 여기서는 다시 지정하지 않습니다."\n    say "  application_name은 위에서 비워 두었다면 여기서도 추가하지 않습니다."\n'''
if old not in s: raise SystemExit('additional params text not found')
s=s.replace(old,new,1)
old='''    printf '  Generated connection : host=%s port=%s user=%s application_name=%s\\n' "$NEW_PRIMARY_DB_HOST" "$REMOTE_PORT" "$CANDIDATE_REPL_USER" "$OLD_PRIMARY_APP"\n'''
new='''    if [ -n "$OLD_PRIMARY_APP" ]; then\n        printf '  Generated connection : host=%s port=%s user=%s application_name=%s\\n' "$NEW_PRIMARY_DB_HOST" "$REMOTE_PORT" "$CANDIDATE_REPL_USER" "$OLD_PRIMARY_APP"\n    else\n        printf '  Generated connection : host=%s port=%s user=%s | application_name=<omitted>\\n' "$NEW_PRIMARY_DB_HOST" "$REMOTE_PORT" "$CANDIDATE_REPL_USER"\n    fi\n'''
if old not in s: raise SystemExit('generated connection text not found')
s=s.replace(old,new,1)
# Slot default must not depend on an empty optional application_name.
old='''        slot_default=$(sanitize_identifier "${OLD_PRIMARY_APP}_slot")\n'''
new='''        slot_identity=${OLD_PRIMARY_APP:-$(hostname 2>/dev/null || echo former_primary)}\n        slot_default=$(sanitize_identifier "${slot_identity}_slot")\n'''
count=s.count(old)
if count != 2: raise SystemExit(f'expected two slot default blocks, found {count}')
s=s.replace(old,new)
p.write_text(s)
