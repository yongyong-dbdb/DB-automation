from pathlib import Path

p = Path('MySQL/InnoDB-Cluster/mysql_innodb_cluster_migrate.sh')
s = p.read_text()

s = s.replace('# mysql_innodb_cluster_migrate.sh v1.0.15', '# mysql_innodb_cluster_migrate.sh v1.0.16', 1)
s = s.replace('VERSION=1.0.15', 'VERSION=1.0.16', 1)

old = 'MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQLSH" --no-wizard --login-path="$lp" --js --execute="$code"'
new = 'MYSQL_TEST_LOGIN_FILE="$lf" "$MYSQLSH" --login-path="$lp" --no-wizard --js --execute="$code"'
if old not in s:
    raise SystemExit('mysqlsh_exec login-path pattern missing')
s = s.replace(old, new, 1)

old = 'MYSQL_TEST_LOGIN_FILE="$(get "$i" login_file)" "$MYSQLSH" --no-wizard --login-path="$(get "$i" login_path)" --js -f "$js"'
new = 'MYSQL_TEST_LOGIN_FILE="$(get "$i" login_file)" "$MYSQLSH" --login-path="$(get "$i" login_path)" --no-wizard --js -f "$js"'
if old not in s:
    raise SystemExit('configure-admin login-path pattern missing')
s = s.replace(old, new, 1)

marker = 'configure_admin(){\n'
if marker not in s:
    raise SystemExit('configure_admin marker missing')
func = r'''show_existing_admin_candidates(){
    out="$ROOT/existing_admin_candidates.txt"
    accounts="$TMP/existing_accounts.tsv"
    : > "$out"
    sql 1 "SELECT User,Host FROM mysql.user WHERE User<>'' AND User NOT IN ('mysql.infoschema','mysql.session','mysql.sys') ORDER BY User,Host;" > "$accounts"
    log 'Existing AdminAPI account candidates:'
    log '  Candidate means the same user@host exists on every registered node.'
    log '  Listed privileges are informational only; roles and release-specific AdminAPI requirements can change effective privileges.'
    log '  Final acceptance always requires the supplied password plus dba.checkInstanceConfiguration() on every node.'
    found=0
    tab=$(printf '\t')
    while IFS="$tab" read -r u h; do
        [ -n "$u" ] && [ -n "$h" ] || continue
        all=yes
        for i in $(ids); do
            c=$(sql "$i" "SELECT COUNT(*) FROM mysql.user WHERE User='$(q "$u")' AND Host='$(q "$h")';")
            [ "$c" -eq 1 ] || { all=no; break; }
        done
        [ "$all" = yes ] || continue
        found=$((found+1))
        printf '  %s@%s\n' "$u" "$h" >> "$out"
        gp=$(sql 1 "SELECT COALESCE(GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ','),'') FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=CONCAT(CHAR(39),'$(q "$u")',CHAR(39),'@',CHAR(39),'$(q "$h")',CHAR(39));")
        dp=$(sql 1 "SELECT COALESCE(GROUP_CONCAT(PRIV ORDER BY PRIV SEPARATOR ','),'') FROM mysql.global_grants WHERE USER='$(q "$u")' AND HOST='$(q "$h")';" 2>/dev/null || printf '')
        [ -n "$gp" ] || gp='(none shown; effective privileges may be role-based)'
        printf '    global/static: %s\n' "$gp" >> "$out"
        [ -z "$dp" ] || printf '    global/dynamic: %s\n' "$dp" >> "$out"
    done < "$accounts"
    [ "$found" -gt 0 ] || printf '  (no identical user@host account exists on every registered node)\n' >> "$out"
    cat "$out" >&2
}

recommended_admin_host_pattern(){
    members=$(grmembers 1)
    [ -n "$members" ] || { printf ''; return 0; }
    first=$(printf '%s\n' "$members" | awk 'NF{print $2; exit}')
    [ -n "$first" ] || { printf ''; return 0; }
    same=yes
    while IFS= read -r h; do [ "$h" = "$first" ] || same=no; done <<EOF
$(printf '%s\n' "$members" | awk 'NF{print $2}')
EOF
    [ "$same" = yes ] || { printf ''; return 0; }
    case $first in localhost|127.0.0.1|::1) printf '';; *) printf '%s' "$first";; esac
}

'''
s = s.replace(marker, func + marker, 1)

old = """    log '  existing : reuse an existing account. The script validates it and never broadens privileges automatically.'
    action=$(choice 'Cluster admin account action' create create existing)

    au=$(ask 'Cluster admin account name' 'icadmin')
"""
new = """    log '  existing : reuse an existing account. The script validates it and never broadens privileges automatically.'
    show_existing_admin_candidates
    action=$(choice 'Cluster admin account action' create create existing)

    au=$(ask 'Cluster admin account name' 'icadmin')
"""
if old not in s:
    raise SystemExit('admin action block missing')
s = s.replace(old, new, 1)

old = """    log "Examples: exact management IP for same-host multi-instance; 10.0.0.% or an appropriate subnet pattern for distributed members. '%' is broad and requires extra confirmation."
    ah=$(ask 'Cluster admin account host pattern' '')
"""
new = """    log "Examples: exact management IP for same-host multi-instance; 10.0.0.% or an appropriate subnet pattern for distributed members. '%' is broad and requires extra confirmation."
    rec_ah=$(recommended_admin_host_pattern)
    if [ -n "$rec_ah" ]; then log "Auto-detected narrow Host candidate from current GR MEMBER_HOST: $rec_ah"; fi
    ah=$(ask 'Cluster admin account host pattern' "$rec_ah")
"""
if old not in s:
    raise SystemExit('admin host prompt block missing')
s = s.replace(old, new, 1)

p.write_text(s)
