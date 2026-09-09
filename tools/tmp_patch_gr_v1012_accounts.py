from pathlib import Path

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()
marker = 'export_source_accounts() {'
if marker in s:
    print('account export already present')
    raise SystemExit(0)

insert_before = 'prepare_reprovision_dump() {'
if insert_before not in s:
    raise SystemExit('prepare_reprovision_dump marker not found')

fn = r'''
export_source_accounts() {
    dir=$1
    account_list="$dir/source_accounts.list"
    account_sql="$dir/source_accounts.sql"
    default_roles="$dir/source_default_roles.sql"
    sql 1 "SELECT CONCAT(QUOTE(u.User),'@',QUOTE(u.Host)) FROM mysql.user u LEFT JOIN (SELECT DISTINCT FROM_USER,FROM_HOST FROM mysql.role_edges) r ON r.FROM_USER=u.User AND r.FROM_HOST=u.Host WHERE u.User NOT IN ('mysql.infoschema','mysql.session','mysql.sys') ORDER BY CASE WHEN r.FROM_USER IS NULL THEN 1 ELSE 0 END,u.User,u.Host;" > "$account_list" || die 'Cannot enumerate Source accounts/roles for logical reprovisioning'
    : > "$account_sql"
    printf '%s\n' '-- Generated from authoritative node 1. Contains authentication hashes; protect this file.' >> "$account_sql"
    printf '%s\n' 'SET SESSION sql_log_bin=0;' >> "$account_sql"
    while IFS= read -r account; do
        [ -n "$account" ] || continue
        case $account in *';'*) die 'Unexpected account literal from Source';; esac
        printf 'DROP USER IF EXISTS %s;\n' "$account" >> "$account_sql"
        if hasvar 1 print_identified_with_as_hex; then
            create=$(sql 1 "SET SESSION print_identified_with_as_hex=ON; SHOW CREATE USER $account;" | cut -f2-)
        else
            create=$(sql 1 "SHOW CREATE USER $account;" | cut -f2-)
        fi
        [ -n "$create" ] || die "SHOW CREATE USER returned no definition for $account"
        printf '%s;\n' "${create%;}" >> "$account_sql"
    done < "$account_list"
    while IFS= read -r account; do
        [ -n "$account" ] || continue
        sql 1 "SHOW GRANTS FOR $account;" | while IFS= read -r grant_line; do
            [ -n "$grant_line" ] || continue
            printf '%s;\n' "${grant_line%;}" >> "$account_sql"
        done
    done < "$account_list"
    : > "$default_roles"
    if sql 1 "SELECT CONCAT('SET DEFAULT ROLE ',GROUP_CONCAT(CONCAT(QUOTE(DEFAULT_ROLE_USER),'@',QUOTE(DEFAULT_ROLE_HOST)) ORDER BY DEFAULT_ROLE_USER,DEFAULT_ROLE_HOST SEPARATOR ','),' TO ',QUOTE(USER),'@',QUOTE(HOST),';') FROM mysql.default_roles GROUP BY USER,HOST ORDER BY USER,HOST;" > "$default_roles" 2>/dev/null; then
        cat "$default_roles" >> "$account_sql"
    else
        : > "$default_roles"
        log 'WARNING: Source default-role metadata could not be exported automatically; logical reprovisioning must not be executed until roles are reviewed.'
        printf '%s\n' '-- DEFAULT ROLE EXPORT UNAVAILABLE: REVIEW REQUIRED' >> "$account_sql"
    fi
    printf '%s\n' 'SET SESSION sql_log_bin=1;' >> "$account_sql"
    chmod 600 "$account_list" "$account_sql" "$default_roles"
    sha256sum "$account_sql" > "$account_sql.sha256"
    printf '%s' "$account_sql"
}

'''
s = s.replace(insert_before, fn + insert_before, 1)

old = '    dump="$dir/source_application.sql"\n'
new = '    accounts=$(export_source_accounts "$dir")\n    dump="$dir/source_application.sql"\n'
if old not in s:
    raise SystemExit('dump assignment not found')
s = s.replace(old, new, 1)

old = '    sha256sum "$dump" > "$dump.sha256"\n'
new = '    sha256sum "$dump" > "$dump.sha256"\n    printf \'ACCOUNT_SQL\\t%s\\n\' "$accounts" > "$dir/logical_reprovision_components.tsv"\n    printf \'APPLICATION_DUMP\\t%s\\n\' "$dump" >> "$dir/logical_reprovision_components.tsv"\n'
s = s.replace(old, new, 1)

old = "            printf '  5. Restore %s into STAGING and verify GTID exactly equals %s.\\n' \"$dump\" \"$target\"\n            printf '  6. Recreate/verify an administrative account before final swap; never leave a passwordless root account exposed.\\n'\n"
new = "            printf '  5. Restore %s into STAGING. Then execute source_accounts.sql through the isolated local socket with binary logging disabled.\\n' \"$dump\"\n            printf '     Account SQL contains authentication hashes and GRANT/role state; keep mode 600 and never print it to an unprotected terminal/log.\\n'\n            printf '  6. Verify application objects, Source account/role state, and GTID exactly equals %s before final swap.\\n' \"$target\"\n            printf '     If account/default-role export was incomplete, stop and use external/reviewed provisioning rather than marking all Source GTIDs executed.\\n'\n"
if old not in s:
    raise SystemExit('plan account step marker not found')
s = s.replace(old, new, 1)

note = '# v1.0.12: reversible reprovision package generation, staging/swap rollback plan, and stable abort TSV output.'
if note in s:
    s = s.replace(note, note + '\n#           Logical reprovision package also exports Source users/roles/grants because partial mysqldump GTID metadata covers the full Source GTID set.', 1)

p.write_text(s)
print('patched source account/role export into GR v1.0.12 candidate')
