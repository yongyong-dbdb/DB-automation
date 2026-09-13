from pathlib import Path

p = Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s = p.read_text()
old = '''    LOCAL_SYNC_STANDBY_NAMES=$(psql_call "SHOW synchronous_standby_names" 2>/dev/null | sed -n '1p') || LOCAL_SYNC_STANDBY_NAMES=""
    if [ -n "$LOCAL_SYNC_STANDBY_NAMES" ] || [ -n "$REMOTE_SYNC_STANDBY_NAMES" ]; then
        say ""
        say "synchronous_standby_names"
        say "  동기 복제를 위해 commit이 기다릴 Standby 이름/집합을 지정하는 PostgreSQL 설정입니다. Primary 역할이 바뀌면 새 Primary의 설정이 적용됩니다."
        printf '  Primary Server  : %s\n' "${LOCAL_SYNC_STANDBY_NAMES:-<empty>}"
        printf '  Standby Server  : %s\n' "${REMOTE_SYNC_STANDBY_NAMES:-<empty>}"
        if [ "$LOCAL_SYNC_STANDBY_NAMES" != "$REMOTE_SYNC_STANDBY_NAMES" ]; then
            warn "The current Primary Server and selected Standby Server have different synchronous_standby_names values. Promotion can change synchronous commit behavior."
        fi
        if [ -n "$REMOTE_SYNC_STANDBY_NAMES" ]; then
            warn "After promotion, the selected Standby Server's synchronous_standby_names becomes the new Primary Server policy. Required synchronous Standby Servers that are not connected can delay or block commits that request synchronous durability."
        fi
        if ! choose_yes_no "The selected Standby Server's synchronous replication policy has been reviewed" "no"; then
            die "Switchover cancelled because synchronous replication policy was not confirmed."
        fi
    fi
'''
new = '''    LOCAL_SYNC_STANDBY_NAMES=$(psql_call "SHOW synchronous_standby_names" 2>/dev/null | sed -n '1p') || LOCAL_SYNC_STANDBY_NAMES=""
    # Remote shell/transport output can carry a trailing CR or surrounding
    # whitespace even when SHOW synchronous_standby_names is logically empty.
    # Trim only the edges; preserve internal spaces in values such as
    # "ANY 2 (standby1, standby2)".
    LOCAL_SYNC_STANDBY_NAMES=$(printf '%s' "$LOCAL_SYNC_STANDBY_NAMES" | sed 's/\\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    REMOTE_SYNC_STANDBY_NAMES=$(printf '%s' "${REMOTE_SYNC_STANDBY_NAMES:-}" | sed 's/\\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')

    say ""
    say "synchronous_standby_names"
    say "  동기 복제를 위해 commit이 기다릴 Standby 이름/집합을 지정하는 PostgreSQL 설정입니다. Primary 역할이 바뀌면 새 Primary의 설정이 적용됩니다."
    printf '  Primary Server  : %s\n' "${LOCAL_SYNC_STANDBY_NAMES:-<empty>}"
    printf '  Standby Server  : %s\n' "${REMOTE_SYNC_STANDBY_NAMES:-<empty>}"
    if [ -z "$LOCAL_SYNC_STANDBY_NAMES" ] && [ -z "$REMOTE_SYNC_STANDBY_NAMES" ]; then
        record_check "PASSED" "synchronous_standby_names" "both current Primary and selected Standby are empty; no synchronous Standby policy will be introduced by promotion"
        info "Both servers have synchronous_standby_names=<empty>; no synchronous replication policy review is required."
    else
        if [ "$LOCAL_SYNC_STANDBY_NAMES" != "$REMOTE_SYNC_STANDBY_NAMES" ]; then
            warn "The current Primary Server and selected Standby Server have different synchronous_standby_names values. Promotion can change synchronous commit behavior."
        fi
        if [ -n "$REMOTE_SYNC_STANDBY_NAMES" ]; then
            warn "After promotion, the selected Standby Server's synchronous_standby_names becomes the new Primary Server policy. Required synchronous Standby Servers that are not connected can delay or block commits that request synchronous durability."
        fi
        if ! choose_yes_no "The selected Standby Server's synchronous replication policy has been reviewed" "no"; then
            die "Switchover cancelled because synchronous replication policy was not confirmed."
        fi
    fi
'''
if old not in s:
    raise SystemExit('target block not found')
s = s.replace(old, new, 1)
p.write_text(s)
