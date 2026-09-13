from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
start=s.index('remote_hba_check() {')
end=s.index('\nremote_preflight() {', start)
new=r'''ipv4_octets_valid() {
    iov_ip=$1
    case "$iov_ip" in *[!0-9.]*|'') return 1 ;; esac
    old_ifs=$IFS
    IFS=.
    set -- $iov_ip
    IFS=$old_ifs
    [ "$#" -eq 4 ] || return 1
    for iov_o in "$@"; do
        case "$iov_o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$iov_o" -ge 0 ] 2>/dev/null && [ "$iov_o" -le 255 ] 2>/dev/null || return 1
    done
}

ipv4_matches_netmask() {
    imn_client=$1
    imn_address=$2
    imn_mask=$3
    ipv4_octets_valid "$imn_client" || return 2
    ipv4_octets_valid "$imn_address" || return 2
    ipv4_octets_valid "$imn_mask" || return 2

    old_ifs=$IFS
    IFS=.; set -- $imn_client; IFS=$old_ifs
    imn_c1=$1; imn_c2=$2; imn_c3=$3; imn_c4=$4
    IFS=.; set -- $imn_address; IFS=$old_ifs
    imn_a1=$1; imn_a2=$2; imn_a3=$3; imn_a4=$4
    IFS=.; set -- $imn_mask; IFS=$old_ifs
    imn_m1=$1; imn_m2=$2; imn_m3=$3; imn_m4=$4

    [ $((imn_c1 & imn_m1)) -eq $((imn_a1 & imn_m1)) ] &&
    [ $((imn_c2 & imn_m2)) -eq $((imn_a2 & imn_m2)) ] &&
    [ $((imn_c3 & imn_m3)) -eq $((imn_a3 & imn_m3)) ] &&
    [ $((imn_c4 & imn_m4)) -eq $((imn_a4 & imn_m4)) ]
}

remote_hba_check() {
    rhc_pgdata=$1
    rhc_client=$2
    rhc_user=$3
    remote_init_exact "$rhc_pgdata"

    # pg_hba_file_rules exists throughout PostgreSQL 12-18. Use only the
    # columns common to all supported releases. HBA matching is first-match and
    # has no fall-through, so rules must be evaluated in line order.
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

    rhc_user_sql=$(printf '%s' "$rhc_user" | sed "s/'/''/g")
    rhc_rows=$(psql_call "SELECT line_number::text || E'\\t' || COALESCE(type,'') || E'\\t' || array_to_string(database,',') || E'\\t' || array_to_string(user_name,',') || E'\\t' || COALESCE(address,'') || E'\\t' || COALESCE(netmask,'') || E'\\t' || COALESCE(auth_method,'') || E'\\t' || COALESCE(error,'') FROM pg_hba_file_rules ORDER BY line_number" 2>/dev/null) || {
        printf 'HBA_RESULT\tMANUAL\t\t\t\t\t\tpg_hba_file_rules could not be queried with PostgreSQL 12-18 common columns\n'
        return 0
    }

    while IFS="$TAB" read -r rhc_line rhc_type rhc_db rhc_users rhc_address rhc_netmask rhc_method rhc_error; do
        [ -z "$rhc_error" ] || continue
        case "$rhc_type" in
            host) rhc_type_state=yes ;;
            hostssl|hostnossl|hostgssenc|hostnogssenc) rhc_type_state=manual ;;
            *) continue ;;
        esac

        # For physical replication, the special database token "replication"
        # must match. The "all" database token does not match physical replication.
        rhc_db_match=0
        old_ifs=$IFS; IFS=,
        for rhc_d in $rhc_db; do [ "$rhc_d" = "replication" ] && rhc_db_match=1; done
        IFS=$old_ifs
        [ "$rhc_db_match" -eq 1 ] || continue

        rhc_user_state=no
        old_ifs=$IFS; IFS=,
        for rhc_u in $rhc_users; do
            case "$rhc_u" in
                all|"$rhc_user") rhc_user_state=yes; break ;;
                +*)
                    rhc_group=${rhc_u#+}
                    rhc_group_sql=$(printf '%s' "$rhc_group" | sed "s/'/''/g")
                    rhc_member=$(psql_call "SELECT CASE WHEN pg_has_role('$rhc_user_sql','$rhc_group_sql','MEMBER') THEN 'yes' ELSE 'no' END" 2>/dev/null | tr -d '[:space:]') || rhc_member=manual
                    [ "$rhc_member" = yes ] && { rhc_user_state=yes; break; }
                    [ "$rhc_member" = manual ] && rhc_user_state=manual
                    ;;
                @*|/*) rhc_user_state=manual ;;
            esac
        done
        IFS=$old_ifs
        [ "$rhc_user_state" != no ] || continue

        rhc_addr_state=no
        case "$rhc_address" in
            all) rhc_addr_state=yes ;;
            samehost|samenet|'') rhc_addr_state=manual ;;
            *:*)
                case "$rhc_client" in *:*) rhc_addr_state=manual ;; *) rhc_addr_state=no ;; esac
                ;;
            *[!0-9.]*) rhc_addr_state=manual ;;
            *)
                case "$rhc_client" in
                    *:*) rhc_addr_state=no ;;
                    *)
                        if ipv4_matches_netmask "$rhc_client" "$rhc_address" "$rhc_netmask"; then
                            rhc_addr_state=yes
                        else
                            rhc_ip_rc=$?
                            [ "$rhc_ip_rc" -eq 2 ] && rhc_addr_state=manual || rhc_addr_state=no
                        fi
                        ;;
                esac
                ;;
        esac
        [ "$rhc_addr_state" != no ] || continue

        # This is the first potentially matching rule. If any dimension is
        # transport/address/user ambiguous, do not skip to a later rule because
        # PostgreSQL itself would never fall through after a real match.
        if [ "$rhc_type_state" = manual ] || [ "$rhc_user_state" = manual ] || [ "$rhc_addr_state" = manual ]; then
            printf 'HBA_RESULT\tMANUAL\t%s\t%s\t%s\t%s\t%s\tfirst potentially matching rule needs transport, hostname/samehost/samenet, IPv6, or role-file verification\n' "$rhc_line" "$rhc_type" "$rhc_address" "$rhc_netmask" "$rhc_method"
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
        return 0
    done <<EOF
$rhc_rows
EOF

    printf 'HBA_RESULT\tFAIL\t\t\t\t\t\tno matching host rule for physical replication, source_hint=%s, role=%s\n' "$rhc_client" "$rhc_user"
}
'''
s=s[:start]+new+s[end:]
p.write_text(s)
