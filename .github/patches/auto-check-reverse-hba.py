from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

# Add controller-side result interpreter before candidate_downstream_check.
marker='''candidate_downstream_check() {\n'''
insert=r'''check_reverse_streaming_authentication() {
    # Use the current Standby's observed upstream endpoint as the best available
    # non-destructive source-address hint for the former Primary. Broad HBA
    # ranges such as 0.0.0.0/0 remain conclusive regardless of route selection;
    # hostname/samehost/samenet/SSL-specific cases are deliberately manual.
    crsa_client=${REMOTE_SENDER_HOST:-}
    crsa_user=${CANDIDATE_REPL_USER:-}
    if [ -z "$crsa_client" ] || [ -z "$crsa_user" ]; then
        record_check "MANUAL CHECK" "Reverse Streaming Authentication" "source address or replication role could not be derived automatically"
        return 1
    fi

    crsa_output=$(remote_invoke --remote-hba-check "$REMOTE_PGDATA" "$crsa_client" "$crsa_user" 2>/dev/null)
    crsa_rc=$?
    if [ "$crsa_rc" -ne 0 ]; then
        record_check "MANUAL CHECK" "Reverse Streaming Authentication" "pg_hba_file_rules could not be evaluated automatically on the selected Standby Server"
        return 1
    fi
    crsa_line=$(printf '%s\n' "$crsa_output" | awk -F '\t' '$1=="HBA_RESULT" {print; exit}')
    [ -n "$crsa_line" ] || {
        record_check "MANUAL CHECK" "Reverse Streaming Authentication" "remote HBA evaluation returned no result"
        return 1
    }
    crsa_state=$(printf '%s\n' "$crsa_line" | awk -F '\t' '{print $2}')
    crsa_line_no=$(printf '%s\n' "$crsa_line" | awk -F '\t' '{print $3}')
    crsa_type=$(printf '%s\n' "$crsa_line" | awk -F '\t' '{print $4}')
    crsa_address=$(printf '%s\n' "$crsa_line" | awk -F '\t' '{print $5}')
    crsa_netmask=$(printf '%s\n' "$crsa_line" | awk -F '\t' '{print $6}')
    crsa_method=$(printf '%s\n' "$crsa_line" | awk -F '\t' '{print $7}')
    crsa_reason=$(printf '%s\n' "$crsa_line" | awk -F '\t' '{print $8}')

    case "$crsa_state" in
        PASS)
            record_check "PASSED" "Reverse Streaming Authentication" "pg_hba_file_rules first matching rule: line=${crsa_line_no:-unknown}, type=${crsa_type:-unknown}, address=${crsa_address:-unknown}, netmask=${crsa_netmask:-unknown}, auth_method=${crsa_method:-unknown}; source_hint=$crsa_client, role=$crsa_user"
            return 0
            ;;
        FAIL)
            die "Reverse streaming authentication is blocked by the selected Standby Server's pg_hba.conf: ${crsa_reason:-no matching physical replication rule}."
            ;;
        MANUAL)
            record_check "MANUAL CHECK" "Reverse Streaming Authentication" "${crsa_reason:-HBA rule requires operator verification}; line=${crsa_line_no:-unknown}, type=${crsa_type:-unknown}, address=${crsa_address:-unknown}, auth_method=${crsa_method:-unknown}"
            return 1
            ;;
        *)
            record_check "MANUAL CHECK" "Reverse Streaming Authentication" "unrecognized remote HBA evaluation result"
            return 1
            ;;
    esac
}

'''
if marker not in s: raise SystemExit('candidate_downstream_check marker not found')
s=s.replace(marker,insert+marker,1)

# Replace unconditional check-only MANUAL CHECK with automatic HBA evaluation.
old='''        record_check "PASSED" "Replication Topology" "local and remote state revalidated"\n        record_check "MANUAL CHECK" "Reverse Streaming Authentication" "pg_hba.conf, passfile or certificate must be confirmed before Planned Switchover"\n        section "Check-only Result"'''
new='''        record_check "PASSED" "Replication Topology" "local and remote state revalidated"\n        check_reverse_streaming_authentication || :\n        section "Check-only Result"'''
if old not in s: raise SystemExit('check-only auth marker not found')
s=s.replace(old,new,1)

# In interactive mode, only require the operator confirmation when automatic
# HBA evaluation cannot conclusively prove trust authentication.
old='''    if ! choose_yes_no "Reverse streaming 인증(pg_hba.conf/.pgpass/인증서 등)이 준비되어 있습니까" "no"; then\n        die "Prepare reverse streaming authentication before Switchover."\n    fi\n    record_check "MANUAL CHECK" "Reverse Streaming Authentication" "confirmed by operator"\n'''
new='''    if check_reverse_streaming_authentication; then\n        info "Reverse streaming HBA readiness was verified automatically."\n    else\n        if ! choose_yes_no "Reverse streaming 인증(pg_hba.conf/.pgpass/인증서 등)이 준비되어 있습니까" "no"; then\n            die "Prepare reverse streaming authentication before Switchover."\n        fi\n        record_check "MANUAL CHECK" "Reverse Streaming Authentication Confirmation" "confirmed by operator after automatic HBA evaluation remained inconclusive"\n    fi\n'''
if old not in s: raise SystemExit('interactive reverse auth block not found')
s=s.replace(old,new,1)

# Add remote evaluator before remote_preflight().
marker='''remote_preflight() {\n'''
remote=r'''remote_hba_check() {
    rhc_pgdata=$1
    rhc_client=$2
    rhc_user=$3
    remote_init_exact "$rhc_pgdata"

    # pg_hba_file_rules exists throughout the supported PostgreSQL 12-18 range.
    # Use only columns common to those releases. It reflects current file
    # contents, so refuse an automatic PASS when the main hba_file is newer than
    # the server's last configuration load. Includes are kept manual because
    # their modification times cannot be proven portably across all 12-18 views.
    rhc_hba=$(psql_call "SHOW hba_file" 2>/dev/null | sed -n '1p') || return 1
    [ -n "$rhc_hba" ] || return 1
    rhc_load=$(psql_call "SELECT extract(epoch FROM pg_conf_load_time())::bigint" 2>/dev/null | tr -d '[:space:]') || return 1
    rhc_mtime=$(psql_call "SELECT extract(epoch FROM modification)::bigint FROM pg_stat_file(current_setting('hba_file'))" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$rhc_load:$rhc_mtime" in *[!0-9:]*|:*|*:) printf 'HBA_RESULT\tMANUAL\t\t\t\t\t\tunable to compare hba_file modification time with pg_conf_load_time()\n'; return 0 ;; esac
    if [ "$rhc_mtime" -gt "$rhc_load" ] 2>/dev/null; then
        printf 'HBA_RESULT\tMANUAL\t\t\t\t\t\thba_file is newer than pg_conf_load_time(); current file contents may not be active\n'
        return 0
    fi
    if grep -E '^[[:space:]]*include(_if_exists|_dir)?[[:space:]]' "$rhc_hba" >/dev/null 2>&1; then
        printf 'HBA_RESULT\tMANUAL\t\t\t\t\t\thba_file uses include directives; cross-version automatic load-time proof is intentionally conservative\n'
        return 0
    fi

    # A physical replication connection has no database name; the special
    # database token replication must match. The all database token does not
    # match physical replication. HBA is first-match/no-fall-through, so an
    # earlier ambiguous rule must prevent us from claiming a later PASS.
    rhc_client_sql=$(printf '%s' "$rhc_client" | sed "s/'/''/g")
    rhc_user_sql=$(printf '%s' "$rhc_user" | sed "s/'/''/g")
    rhc_sql="WITH rules AS (\n        SELECT line_number,type,database,user_name,address,netmask,auth_method,error\n        FROM pg_hba_file_rules\n        WHERE error IS NULL AND type LIKE 'host%' AND database @> ARRAY['replication']::text[]\n    ), classified AS (\n        SELECT *,\n          CASE\n            WHEN type='host' THEN true\n            WHEN type IN ('hostssl','hostnossl','hostgssenc','hostnogssenc') THEN NULL\n            ELSE NULL\n          END AS type_match,\n          CASE\n            WHEN EXISTS (SELECT 1 FROM unnest(user_name) u WHERE u='all' OR u='$rhc_user_sql' OR (left(u,1)='+' AND pg_has_role('$rhc_user_sql',substr(u,2),'MEMBER'))) THEN true\n            WHEN EXISTS (SELECT 1 FROM unnest(user_name) u WHERE left(u,1) IN ('/','@')) THEN NULL\n            ELSE false\n          END AS user_match,\n          CASE\n            WHEN address='all' THEN true\n            WHEN address IN ('samehost','samenet') THEN NULL\n            WHEN address ~ '^[0-9A-Fa-f:.]+$' AND '$rhc_client_sql' ~ '^[0-9A-Fa-f:.]+$' THEN\n              CASE WHEN inet_same_family(address::inet,'$rhc_client_sql'::inet)\n                   THEN (address::inet & netmask::inet) = ('$rhc_client_sql'::inet & netmask::inet)\n                   ELSE false END\n            ELSE NULL\n          END AS addr_match\n        FROM rules\n    ), potential AS (\n        SELECT * FROM classified\n        WHERE user_match IS DISTINCT FROM false\n          AND type_match IS DISTINCT FROM false\n          AND addr_match IS DISTINCT FROM false\n        ORDER BY line_number\n        LIMIT 1\n    )\n    SELECT COALESCE(line_number::text,'') || E'\\t' || COALESCE(type,'') || E'\\t' || COALESCE(address,'') || E'\\t' || COALESCE(netmask,'') || E'\\t' || COALESCE(auth_method,'') || E'\\t' ||\n           CASE WHEN type_match IS NULL OR user_match IS NULL OR addr_match IS NULL THEN 'AMBIGUOUS' ELSE 'MATCH' END\n    FROM potential"
    rhc_row=$(psql_call "$rhc_sql" 2>/dev/null | sed -n '1p') || {
        printf 'HBA_RESULT\tMANUAL\t\t\t\t\t\tpg_hba_file_rules could not be evaluated with common PostgreSQL 12-18 columns\n'
        return 0
    }
    if [ -z "$rhc_row" ]; then
        printf 'HBA_RESULT\tFAIL\t\t\t\t\t\tno matching host rule for physical replication, source_hint=%s, role=%s\n' "$rhc_client" "$rhc_user"
        return 0
    fi
    rhc_line=$(printf '%s\n' "$rhc_row" | awk -F '\t' '{print $1}')
    rhc_type=$(printf '%s\n' "$rhc_row" | awk -F '\t' '{print $2}')
    rhc_address=$(printf '%s\n' "$rhc_row" | awk -F '\t' '{print $3}')
    rhc_netmask=$(printf '%s\n' "$rhc_row" | awk -F '\t' '{print $4}')
    rhc_method=$(printf '%s\n' "$rhc_row" | awk -F '\t' '{print $5}')
    rhc_match=$(printf '%s\n' "$rhc_row" | awk -F '\t' '{print $6}')
    if [ "$rhc_match" != "MATCH" ]; then
        printf 'HBA_RESULT\tMANUAL\t%s\t%s\t%s\t%s\t%s\tfirst potentially matching rule uses hostname/samehost/samenet, role pattern/file, or transport-specific host type\n' "$rhc_line" "$rhc_type" "$rhc_address" "$rhc_netmask" "$rhc_method"
        return 0
    fi
    case "$rhc_method" in
        reject)
            printf 'HBA_RESULT\tFAIL\t%s\t%s\t%s\t%s\t%s\tfirst matching HBA rule explicitly rejects the reverse physical replication connection\n' "$rhc_line" "$rhc_type" "$rhc_address" "$rhc_netmask" "$rhc_method"
            ;;
        trust)
            printf 'HBA_RESULT\tPASS\t%s\t%s\t%s\t%s\t%s\tfirst matching HBA rule permits the reverse physical replication connection without credentials\n' "$rhc_line" "$rhc_type" "$rhc_address" "$rhc_netmask" "$rhc_method"
            ;;
        *)
            printf 'HBA_RESULT\tMANUAL\t%s\t%s\t%s\t%s\t%s\tHBA rule matches, but auth_method=%s requires credential/certificate/external-auth verification\n' "$rhc_line" "$rhc_type" "$rhc_address" "$rhc_netmask" "$rhc_method" "$rhc_method"
            ;;
    esac
}

'''
if marker not in s: raise SystemExit('remote_preflight marker not found')
s=s.replace(marker,remote+marker,1)

# Add dispatcher.
old='''    --remote-preflight)\n        [ "$#" -eq 2 ] || exit 64\n        remote_preflight "$2"\n        exit $?\n        ;;'''
new='''    --remote-hba-check)\n        [ "$#" -eq 4 ] || exit 64\n        remote_hba_check "$2" "$3" "$4"\n        exit $?\n        ;;\n    --remote-preflight)\n        [ "$#" -eq 2 ] || exit 64\n        remote_preflight "$2"\n        exit $?\n        ;;'''
if old not in s: raise SystemExit('dispatcher marker not found')
s=s.replace(old,new,1)

p.write_text(s)
