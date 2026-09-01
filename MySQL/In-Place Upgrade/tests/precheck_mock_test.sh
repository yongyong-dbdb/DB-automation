#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
BASE_DIR="$TEST_ROOT/mysql"
RPM_DIR="$TEST_ROOT/rpms"
BUNDLE="$BASE_DIR/mysql-8.4.11-1.el8.x86_64.rpm-bundle.tar"

cleanup() {
    [[ -n "$TEST_ROOT" && "$TEST_ROOT" == /tmp/* ]] || return 0
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$BASE_DIR/data" "$BASE_DIR/log" "$BASE_DIR/mysqld" "$RPM_DIR"
touch "$BASE_DIR/data/ibdata1" "$BASE_DIR/log/mysqld.log"

cat > "$BASE_DIR/my.cnf" <<EOF
[mysqld]
datadir=$BASE_DIR/data
socket=$BASE_DIR/mysqld/mysql.sock
log-error=$BASE_DIR/log/mysqld.log
pid-file=$BASE_DIR/mysqld/mysqld.pid
EOF

for package_name in common client-plugins libs icu-data-files client server; do
    touch "$RPM_DIR/mysql-community-$package_name-8.4.11-1.el8.x86_64.rpm"
done

tar -cf "$BUNDLE" -C "$RPM_DIR" \
    mysql-community-common-8.4.11-1.el8.x86_64.rpm \
    mysql-community-client-plugins-8.4.11-1.el8.x86_64.rpm \
    mysql-community-libs-8.4.11-1.el8.x86_64.rpm \
    mysql-community-icu-data-files-8.4.11-1.el8.x86_64.rpm \
    mysql-community-client-8.4.11-1.el8.x86_64.rpm \
    mysql-community-server-8.4.11-1.el8.x86_64.rpm

cat > "$FAKE_BIN/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"mysql-community-server"* ]]; then
    printf '8.0.46\n'
    exit 0
fi
exit 0
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    cat) printf '[Service]\nExecStart=/usr/sbin/mysqld\n' ;;
    is-active) [[ "${2:-}" == "--quiet" ]] || printf 'active\n' ;;
esac
exit 0
EOF

cat > "$FAKE_BIN/mysql" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"SELECT VERSION();"*) printf '8.0.46\n' ;;
    *"SELECT 1;"*) printf '1\n' ;;
esac
exit 0
EOF

cat > "$FAKE_BIN/my_print_defaults" <<EOF
#!/usr/bin/env bash
printf '%s\n' \
    '--datadir=$BASE_DIR/data' \
    '--socket=$BASE_DIR/mysqld/mysql.sock' \
    '--log-error=$BASE_DIR/log/mysqld.log' \
    '--pid-file=$BASE_DIR/mysqld/mysqld.pid'
EOF

for command_name in mysqlcheck mysqld yum; do
    cat > "$FAKE_BIN/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done

chmod +x "$FAKE_BIN"/*

PATH="$FAKE_BIN:$PATH" MYSQL_PASSWORD='Mock#Password1!' \
    bash "$SCRIPT_DIR/mysql_inplace_upgrade.sh" \
    --base "$BASE_DIR" \
    --config "$BASE_DIR/my.cnf" \
    --bundle "$BUNDLE" \
    precheck

STATE_FILE="$BASE_DIR/.mysql_inplace_upgrade.conf"
[[ -f "$STATE_FILE" ]]
grep -Fq 'CURRENT_VERSION=8.0.46' "$STATE_FILE"
grep -Fq 'TARGET_VERSION=8.4.11' "$STATE_FILE"
grep -Fq "DATADIR=$BASE_DIR/data" "$STATE_FILE"

printf 'PASS mocked precheck: 8.0.46 -> 8.4.11\n'

PATH="$FAKE_BIN:$PATH" MYSQL_PASSWORD='Mock#Password1!' \
    bash "$SCRIPT_DIR/mysql_inplace_upgrade.sh" \
    --base "$BASE_DIR" \
    --config "$BASE_DIR/my.cnf" \
    prepare

[[ -f "$BASE_DIR/mysql_inplace_upgrade_work/target_rpms.txt" ]]
[[ "$(wc -l < "$BASE_DIR/mysql_inplace_upgrade_work/target_rpms.txt")" -eq 6 ]]
printf 'PASS mocked prepare: six required target RPMs selected\n'

printf 'UPGRADE 8.0.46 TO 8.4.11\n' | PATH="$FAKE_BIN:$PATH" MYSQL_PASSWORD='Mock#Password1!' \
    bash "$SCRIPT_DIR/mysql_inplace_upgrade.sh" \
    --base "$BASE_DIR" \
    --config "$BASE_DIR/my.cnf" \
    --dry-run \
    upgrade

printf 'PASS mocked dry-run upgrade workflow\n'
