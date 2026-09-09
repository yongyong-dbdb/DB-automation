from pathlib import Path

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()

def replace_once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    s = s.replace(old, new, 1)

replace_once('# mysql_gr_migrate.sh v1.0.9', '# mysql_gr_migrate.sh v1.0.10', 'header version')
replace_once('VERSION=1.0.9', 'VERSION=1.0.10', 'runtime version')
replace_once("total=$(awk 'END{print NR>0?NR-1:0}' \"$summary\")", "total=$(awk 'END{print (NR > 0 ? NR - 1 : 0)}' \"$summary\")", 'awk ternary')

old_main = '''main() {\n    case $STEP in help|--help|-h) help; return;; --version) printf '%s\\n' \"$VERSION\"; return;; discover|configure|precheck|initialize|cutover|join|release|validate|status|all) :;; *) help; exit 2;; esac\n    command -v \"$MYSQL\" >/dev/null 2>&1 || die 'mysql client not found; set MYSQL_GR_MYSQL'\n'''
new_main = '''platform_preflight() {\n    # Fail before any database/config mutation when the controller shell\n    # environment cannot support the portable code paths used by this script.\n    for c in awk sed grep sort cut tr head tail dirname basename mktemp cmp diff date cp mv rm mkdir cat chmod; do\n        command -v \"$c\" >/dev/null 2>&1 || die \"Required controller utility not found: $c\"\n    done\n    # Keep awk checks POSIX-compatible. The parentheses around a relational\n    # expression used by ?: are intentional; without them some awk parsers\n    # interpret '>' as output redirection.\n    awk_result=$(awk 'BEGIN { n=1; print (n > 0 ? n - 1 : 0) }' 2>/dev/null) || die 'Controller awk failed the required conditional-expression compatibility check'\n    [ \"$awk_result\" = 0 ] || die 'Controller awk returned an unexpected result in compatibility preflight'\n    awk -F '\\t' 'BEGIN { line=\"a\\tb\"; n=split(line,x,FS); if (n != 2 || x[1] != \"a\" || x[2] != \"b\") exit 1 }' >/dev/null 2>&1 || die 'Controller awk failed tab-field compatibility preflight'\n}\n\nmain() {\n    case $STEP in help|--help|-h) help; return;; --version) printf '%s\\n' \"$VERSION\"; return;; discover|configure|precheck|initialize|cutover|join|release|validate|status|all) :;; *) help; exit 2;; esac\n    platform_preflight\n    command -v \"$MYSQL\" >/dev/null 2>&1 || die 'mysql client not found; set MYSQL_GR_MYSQL'\n'''
replace_once(old_main, new_main, 'platform preflight')

replace_once(
    '# v1.0.9: generic per-GTID DML/DDL summaries and safe current-metadata comparison for divergent members.\n',
    '# v1.0.9: generic per-GTID DML/DDL summaries and safe current-metadata comparison for divergent members.\n# v1.0.10: POSIX-awk conditional fix and controller utility/awk compatibility preflight before mutation.\n',
    'version note')

p.write_text(s)
