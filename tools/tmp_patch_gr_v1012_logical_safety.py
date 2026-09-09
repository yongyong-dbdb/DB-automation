from pathlib import Path
import re

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()

# Idempotence: this marker is added only after all logical-provisioning safety
# changes below are present.
marker = '# v1.0.12-logical-safety2: NEW_EMPTY account restore + fail-fast grants/default roles + dump version guard.'
if marker in s:
    print('logical safety2 patch already present')
    raise SystemExit(0)

helpers = r'''
mysqldump_version_guard() {
    command -v "$DUMP" >/dev/null 2>&1 || die 'Matching mysqldump executable required'
    version_file="$RUN/mysqldump_version.txt"
    "$DUMP" --version > "$version_file" 2>&1 || die 'Cannot execute mysqldump --version'
    dump_version=$(sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' "$version_file" | head -n 1)
    source_version=$(get 1 version | sed 's/[^0-9.].*//')
    [ -n "$dump_version" ] && [ "$dump_version" = "$source_version" ] || die "mysqldump version ${dump_version:-UNKNOWN} does not match Source server $source_version; set MYSQL_GR_MYSQLDUMP"
}

source_admin_target_credential() {
    i=$1
    credential 1
    candidate="$TEMP/$i.source_admin.cnf"
    {
        printf '[client]\n'
        sed -n '/^user=/p; /^password=/p' "$TEMP/1.cnf"
        if [ "$(get "$i" mode)" = socket ]; then
            printf 'protocol=SOCKET\nsocket="%s"\n' "$(optq "$(get "$i" socket)")"
        else
            printf 'protocol=TCP\nhost="%s"\nport=%s\nssl-mode=%s\n' "$(optq "$(get "$i" host)")" "$(get "$i" port)" "$(get "$i" admin_tls)"
            [ ! -s "$ROOT/$i/admin_ca" ] || printf 'ssl-ca="%s"\n' "$(optq "$(get "$i" admin_ca)")"
        fi
        printf '\n[mysql]\nconnect-timeout=10\n'
    } > "$candidate"
    chmod 600 "$candidate"
    if ! target_current=$(printf 'SELECT CURRENT_USER();\n' | "$MYSQL" --defaults-file="$candidate" --no-login-paths --batch --raw --skip-column-names 2>/dev/null); then
        rm -f "$candidate"
        return 1
    fi
    source_current=$(sql 1 'SELECT CURRENT_USER();')
    if [ "$target_current" != "$source_current" ]; then
        rm -f "$candidate"
        return 1
    fi
    mv -f "$candidate" "$TEMP/$i.cnf"
}

'''

if 'mysqldump_version_guard() {' not in s:
    anchor = 'export_source_accounts() {'
    if anchor not in s:
        raise SystemExit('export_source_accounts marker not found')
    s = s.replace(anchor, helpers + anchor, 1)

new_export = r'''export_source_accounts() {
    dir=$1
    account_list="$dir/source_accounts.list"
    account_sql="$dir/source_accounts.sql"
    default_roles="$dir/source_default_roles.sql"
    role_rows="$dir/.source_default_roles.rows"

    if ! sql 1 "SELECT CONCAT(QUOTE(u.User),'@',QUOTE(u.Host)) FROM mysql.user u LEFT JOIN (SELECT DISTINCT FROM_USER,FROM_HOST FROM mysql.role_edges) r ON r.FROM_USER=u.User AND r.FROM_HOST=u.Host WHERE u.User NOT IN ('mysql.infoschema','mysql.session','mysql.sys') ORDER BY CASE WHEN r.FROM_USER IS NULL THEN 1 ELSE 0 END,u.User,u.Host;" > "$account_list"; then
        die 'Cannot enumerate Source accounts/roles for logical reprovisioning'
    fi
    [ -s "$account_list" ] || die 'Source account list is empty; logical provisioning cannot safely mark the full Source GTID set executed'

    source_admin=$(sql 1 "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.user WHERE CONCAT(User,'@',Host)=CURRENT_USER();")
    [ -n "$source_admin" ] || die 'Cannot resolve the Source administrative account in mysql.user'
    grep -Fx "$source_admin" "$account_list" >/dev/null 2>&1 || die 'Source administrative account was not included in the account export'

    : > "$account_sql"
    printf '%s\n' '-- Generated from authoritative node 1. Contains authentication hashes; protect this file.' >> "$account_sql"
    printf '%s\n' 'SET SESSION sql_log_bin=0;' >> "$account_sql"

    account_no=0
    while IFS= read -r account; do
        [ -n "$account" ] || continue
        case $account in *';'*) die 'Unexpected account literal from Source';; esac
        account_no=$((account_no+1))
        create_file="$dir/.source_create_user_$account_no.tsv"
        printf 'DROP USER IF EXISTS %s;\n' "$account" >> "$account_sql"
        if hasvar 1 print_identified_with_as_hex; then
            if ! sql 1 "SET SESSION print_identified_with_as_hex=ON; SHOW CREATE USER $account;" > "$create_file"; then
                rm -f "$create_file"
                die "SHOW CREATE USER failed for $account"
            fi
        else
            if ! sql 1 "SHOW CREATE USER $account;" > "$create_file"; then
                rm -f "$create_file"
                die "SHOW CREATE USER failed for $account"
            fi
        fi
        create=$(cut -f2- "$create_file")
        rm -f "$create_file"
        [ -n "$create" ] || die "SHOW CREATE USER returned no definition for $account"
        printf '%s;\n' "${create%;}" >> "$account_sql"
    done < "$account_list"

    grant_no=0
    while IFS= read -r account; do
        [ -n "$account" ] || continue
        grant_no=$((grant_no+1))
        grant_file="$dir/.source_grants_$grant_no.tsv"
        if ! sql 1 "SHOW GRANTS FOR $account;" > "$grant_file"; then
            rm -f "$grant_file"
            die "SHOW GRANTS failed for $account; refusing an incomplete account package"
        fi
        [ -s "$grant_file" ] || { rm -f "$grant_file"; die "SHOW GRANTS returned no rows for $account"; }
        while IFS= read -r grant_line; do
            [ -n "$grant_line" ] || continue
            printf '%s;\n' "${grant_line%;}" >> "$account_sql"
        done < "$grant_file"
        rm -f "$grant_file"
    done < "$account_list"

    if ! sql 1 "SELECT QUOTE(USER),QUOTE(HOST),QUOTE(DEFAULT_ROLE_USER),QUOTE(DEFAULT_ROLE_HOST) FROM mysql.default_roles ORDER BY USER,HOST,DEFAULT_ROLE_USER,DEFAULT_ROLE_HOST;" > "$role_rows"; then
        rm -f "$role_rows"
        die 'Cannot export Source default-role metadata; refusing an incomplete account package'
    fi
    : > "$default_roles"
    tab=$(printf '\t')
    current_account=''
    current_roles=''
    while IFS="$tab" read -r role_user role_host default_user default_host; do
        [ -n "$role_user" ] || continue
        account="$role_user@$role_host"
        role="$default_user@$default_host"
        if [ -n "$current_account" ] && [ "$account" != "$current_account" ]; then
            printf 'SET DEFAULT ROLE %s TO %s;\n' "$current_roles" "$current_account" >> "$default_roles"
            current_roles=''
        fi
        current_account=$account
        if [ -n "$current_roles" ]; then current_roles="$current_roles,$role"; else current_roles=$role; fi
    done < "$role_rows"
    [ -z "$current_account" ] || printf 'SET DEFAULT ROLE %s TO %s;\n' "$current_roles" "$current_account" >> "$default_roles"
    rm -f "$role_rows"
    cat "$default_roles" >> "$account_sql"

    printf '%s\n' 'SET SESSION sql_log_bin=1;' >> "$account_sql"
    chmod 600 "$account_list" "$account_sql" "$default_roles"
    (cd "$dir" && sha256sum source_accounts.sql > source_accounts.sql.sha256)
    printf '%s' "$account_sql"
}
'''

pattern = re.compile(r'export_source_accounts\(\) \{\n.*?\n\}\n\nprepare_reprovision_dump\(\) \{', re.S)
m = pattern.search(s)
if not m:
    raise SystemExit('cannot locate export_source_accounts function')
s = s[:m.start()] + new_export + '\nprepare_reprovision_dump() {' + s[m.end():]

# Reprovision and NEW_EMPTY must use exactly the mysqldump version matching Source.
s = s.replace(
    '    command -v "$DUMP" >/dev/null 2>&1 || die \'Matching mysqldump executable required for reprovision package\'\n    accounts=$(export_source_accounts "$dir")\n',
    '    mysqldump_version_guard\n    accounts=$(export_source_accounts "$dir")\n',
    1,
)

# Make dump checksums relocatable so copied remote packages can be verified from
# their destination directory.
s = s.replace(
    '    sha256sum "$dump" > "$dump.sha256"\n    printf \'ACCOUNT_SQL\\t%s\\n\' "$accounts" > "$dir/logical_reprovision_components.tsv"\n',
    '    (cd "$dir" && sha256sum source_application.sql > source_application.sql.sha256)\n    printf \'ACCOUNT_SQL\\t%s\\n\' "$accounts" > "$dir/logical_reprovision_components.tsv"\n',
    1,
)

old_new_empty = r'''                dbs=$(sql 1 "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY schema_name;")
                [ -n "$dbs" ] || die 'Authoritative source has no application DBs; use external/preprovisioned verification for this intentionally empty topology'
                for db in $dbs; do case $db in *[!A-Za-z0-9_\$]*) die 'Database name requires external provisioning';; esac; done
                command -v "$DUMP" >/dev/null 2>&1 || die 'Matching mysqldump executable required'
                "$DUMP" --version > "$RUN/mysqldump_version.txt"
                dv=$(sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' "$RUN/mysqldump_version.txt")
                sv=$(get 1 version | sed 's/[^0-9.].*//')
                [ "$dv" = "$sv" ] || die "mysqldump version $dv does not match server $sv; set MYSQL_GR_MYSQLDUMP"
                confirm "INITIALIZE EMPTY NODE $i"
                dump="$RUN/full_application_node_$i.sql"
                set -f; set -- $dbs; set +f
                "$DUMP" --defaults-file="$TEMP/1.cnf" --no-login-paths --single-transaction --quick --skip-lock-tables --routines --events --triggers --hex-blob --set-gtid-purged=ON --databases "$@" > "$dump" 2> "$RUN/node_$i.dump.log"
                [ -s "$dump" ] || die 'Empty dump'
                sha256sum "$dump" > "$dump.sha256"
                [ "$(normalize_gtid "$(val 1 gtid_executed)")" = "$target" ] || die 'Source changed during initialization'
                mkdir -p "$TEMP/unfenced"; : > "$TEMP/unfenced/$i"
                sql "$i" 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;'
                if ! "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --binary-mode < "$dump" > "$RUN/node_$i.restore.log" 2>&1; then
                    sql "$i" 'SET GLOBAL super_read_only=ON;' || :
                    die "Restore failed; node $i requires external clean reprovisioning before retry"
                fi
                events=$(sql "$i" "SELECT CONCAT('ALTER EVENT ',CHAR(96),REPLACE(EVENT_SCHEMA,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),'.',CHAR(96),REPLACE(EVENT_NAME,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),' DISABLE;') FROM information_schema.events;")
                sql "$i" "SET SESSION sql_log_bin=0; $events SET GLOBAL super_read_only=ON;"
                rm -f "$TEMP/unfenced/$i"
                catchup "$i" "$target"
                put "$i" initialized dump
'''

new_new_empty = r'''                confirm "INITIALIZE EMPTY NODE $i"
                package="$RUN/node_${i}.new_empty_provision"
                mkdir -p "$package"; chmod 700 "$package"
                dump=$(prepare_reprovision_dump "$i" "$target" "$package")
                account_sql="$package/source_accounts.sql"
                (cd "$package" && sha256sum -c source_application.sql.sha256 >/dev/null) || die 'Source application dump checksum verification failed before restore'
                (cd "$package" && sha256sum -c source_accounts.sql.sha256 >/dev/null) || die 'Source account package checksum verification failed before restore'
                mkdir -p "$TEMP/unfenced"; : > "$TEMP/unfenced/$i"
                # Keep read_only=ON so ordinary application accounts remain fenced while
                # the administrative provisioning session temporarily disables super_read_only.
                sql "$i" 'SET GLOBAL read_only=ON; SET GLOBAL super_read_only=OFF;'
                if ! "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --binary-mode < "$dump" > "$RUN/node_$i.restore.log" 2>&1; then
                    sql "$i" 'SET GLOBAL super_read_only=ON;' || :
                    die "Application restore failed; node $i requires external clean reprovisioning before retry"
                fi
                if ! "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --binary-mode < "$account_sql" >> "$RUN/node_$i.restore.log" 2>&1; then
                    sql "$i" 'SET GLOBAL super_read_only=ON;' || :
                    die "Source account/role restore failed; node $i requires external clean reprovisioning before retry"
                fi
                if ! source_admin_target_credential "$i"; then
                    die "Source accounts were restored but Source administrative credentials cannot reconnect to node $i; keep read_only=ON and externally verify/reprovision before retry"
                fi
                sql "$i" 'SET GLOBAL super_read_only=ON;'
                events=$(sql "$i" "SELECT CONCAT('ALTER EVENT ',CHAR(96),REPLACE(EVENT_SCHEMA,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),'.',CHAR(96),REPLACE(EVENT_NAME,CHAR(96),CONCAT(CHAR(96),CHAR(96))),CHAR(96),' DISABLE;') FROM information_schema.events;")
                sql "$i" "SET SESSION sql_log_bin=0; $events SET GLOBAL super_read_only=ON;"
                rm -f "$TEMP/unfenced/$i"
                catchup "$i" "$target"
                put "$i" initialized dump
'''

if old_new_empty not in s:
    raise SystemExit('NEW_EMPTY logical dump block not found')
s = s.replace(old_new_empty, new_new_empty, 1)

note = '#           Logical reprovision package also exports Source users/roles/grants because partial mysqldump GTID metadata covers the full Source GTID set.'
if note not in s:
    raise SystemExit('v1.0.12 account note not found')
s = s.replace(note, note + '\n' + marker, 1)

p.write_text(s)
print('patched GR v1.0.12 logical provisioning safety2')
