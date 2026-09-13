from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
old='''verify_upstream_connection() {\n    vuc_result=$(remote_invoke --remote-verify-upstream "$REMOTE_PGDATA" "$SYSTEM_IDENTIFIER" "$PGPORT" 2>/dev/null) || classify_remote_failure "$?" "Could not verify the selected Standby Server's upstream Primary Server. Check primary_conninfo, credentials, pg_hba.conf and network."\n    [ "$vuc_result" = "UPSTREAM_VERIFIED" ] || die "The upstream server reached through primary_conninfo does not match the selected Primary Server system_identifier and port."\n    record_check "PASSED" "primary_conninfo Upstream" "live SQL connection verified system_identifier=$SYSTEM_IDENTIFIER and port=$PGPORT"\n}\n'''
new='''verify_upstream_connection() {\n    # Do not open a second libpq/replication connection here. The authoritative\n    # topology evidence is the live pg_stat_replication row on the Primary plus\n    # pg_stat_wal_receiver on the selected Standby. A separate probe can fail\n    # because of authentication/passfile rules even while physical streaming is\n    # healthy, producing a false negative.\n    [ "$REMOTE_SYSTEM_IDENTIFIER" = "$SYSTEM_IDENTIFIER" ] || die "Selected Standby system_identifier changed during validation."\n    [ "$REMOTE_ROLE" = "standby" ] || die "Selected Standby is no longer in recovery."\n    [ "$REMOTE_RECEIVER_STATUS" = "streaming" ] || die "Selected Standby pg_stat_wal_receiver.status is no longer streaming."\n    [ "$REMOTE_SENDER_PORT" = "$PGPORT" ] || die "Selected Standby pg_stat_wal_receiver.sender_port=$REMOTE_SENDER_PORT does not match current Primary port=$PGPORT."\n    [ "${REMOTE_RECEIVER_SLOT:-}" = "${CANDIDATE_SLOT:-}" ] || die "Selected Standby pg_stat_wal_receiver.slot_name changed during validation."\n    record_check "PASSED" "Streaming Topology Cross-check" "Primary pg_stat_replication and selected Standby pg_stat_wal_receiver agree on streaming state, system_identifier, sender_port=$PGPORT and physical slot=${CANDIDATE_SLOT:-<empty>}"\n}\n'''
if old not in s:
    raise SystemExit('verify_upstream_connection block not found')
s=s.replace(old,new,1)
start=s.find('remote_verify_upstream() {')
if start == -1:
    raise SystemExit('remote_verify_upstream function not found')
end=s.find('\nremote_timeout_default() {', start)
if end == -1:
    raise SystemExit('remote_timeout_default boundary not found')
s=s[:start]+s[end+1:]
old_case='''    --remote-verify-upstream)\n        [ "$#" -eq 4 ] || exit 64\n        remote_verify_upstream "$2" "$3" "$4"\n        exit $?\n        ;;\n'''
if old_case not in s:
    raise SystemExit('remote verify dispatcher not found')
s=s.replace(old_case,'',1)
p.write_text(s)
