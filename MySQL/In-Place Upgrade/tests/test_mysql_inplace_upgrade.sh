#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPGRADE_SCRIPT="$SCRIPT_DIR/mysql_inplace_upgrade.sh"
passed=0
failed=0

# shellcheck source=../mysql_inplace_upgrade.sh
source "$UPGRADE_SCRIPT"

pass() {
    printf 'PASS: %s\n' "$1"
    passed=$((passed + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1"
    failed=$((failed + 1))
}

expect_supported() {
    local current="$1"
    local target="$2"
    if is_supported_path "$current" "$target"; then
        pass "supported path $current -> $target"
    else
        fail "expected supported path $current -> $target"
    fi
}

expect_blocked() {
    local current="$1"
    local target="$2"
    if is_supported_path "$current" "$target"; then
        fail "expected blocked path $current -> $target"
    else
        pass "blocked path $current -> $target"
    fi
}

test_version_paths() {
    printf '\n[1/3] Upgrade path validation\n'

    expect_supported 8.0.32 8.0.46
    expect_supported 8.0.46 8.4.11
    expect_supported 8.3.0 8.4.11
    expect_supported 8.4.11 9.7.0
    expect_supported 9.1.0 9.7.0
    expect_supported 5.7.44 8.0.46

    expect_blocked 8.0.46 9.7.0
    expect_blocked 5.7.44 8.4.11
    expect_blocked 8.4.11 8.0.46
    expect_blocked 8.4.11 8.4.11
    expect_blocked 9.7.0 9.6.0
}

test_bundle_filename_parser() {
    printf '\n[2/3] Bundle filename parser validation\n'

    if [[ "$(bundle_version_from_name 'mysql-8.4.11-1.el8.x86_64.rpm-bundle.tar')" == "8.4.11" ]]; then
        pass "rpm-bundle filename format"
    else
        fail "rpm-bundle filename format"
    fi

    if [[ "$(bundle_version_from_name 'mysql-9.7.0-1.el8-x86_64-bundle.tar')" == "9.7.0" ]]; then
        pass "bundle filename format"
    else
        fail "bundle filename format"
    fi
}

test_mock_workflow() {
    local test_root fake_bin base_dir rpm_dir bundle state_file package_name command_name

    printf '\n[3/3] Mocked 8.0.46 -> 8.4.11 workflow\n'

    test_root="$(mktemp -d)"
    fake_bin="$test_root/bin"
    base_dir="$test_root/mysql"
    rpm_dir="$test_root/rpms"
    bundle="$base_dir/mysql-8.4.11-1.el8.x86_64.rpm-bundle.tar"

    cleanup_mock() {
        [[ -n "$test_root" && "$test_root" == /tmp/* ]] || return 0
        rm -rf -- "$test_root"
    }
    trap cleanup_mock RETURN

    mkdir -p "$fake_bin" "$base_dir/data" "$base_dir/log" "$base_dir/mysqld" "$rpm_dir"
    mkdir -p "$base_dir/data/mysql"
    touch "$base_dir/data/ibdata1" "$base_dir/data/auto.cnf" "$base_dir/log/mysqld.log"

    cat > "$base_dir/my.cnf" <<EOF
[mysqld]
datadir=$base_dir/data
socket=$base_dir/mysqld/mysql.sock
log-error=$base_dir/log/mysqld.log
pid-file=$base_dir/mysqld/mysqld.pid
EOF

    for package_name in common client-plugins libs icu-data-files client server; do
        touch "$rpm_dir/mysql-community-$package_name-8.4.11-1.el8.x86_64.rpm"
    done

    tar -cf "$bundle" -C "$rpm_dir" \
        mysql-community-common-8.4.11-1.el8.x86_64.rpm \
        mysql-community-client-plugins-8.4.11-1.el8.x86_64.rpm \
        mysql-community-libs-8.4.11-1.el8.x86_64.rpm \
        mysql-community-icu-data-files-8.4.11-1.el8.x86_64.rpm \
        mysql-community-client-8.4.11-1.el8.x86_64.rpm \
        mysql-community-server-8.4.11-1.el8.x86_64.rpm

    cat > "$fake_bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"mysql-community-server"* ]]; then
    printf '8.0.46\n'
fi
exit 0
EOF

    cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    cat) printf '[Service]\nExecStart=/usr/sbin/mysqld\n' ;;
    is-active) [[ "${2:-}" == "--quiet" ]] || printf 'active\n' ;;
esac
exit 0
EOF

    cat > "$fake_bin/mysql" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"SELECT VERSION();"*) printf '8.0.46\n' ;;
    *"SELECT 1;"*) printf '1\n' ;;
    *"replication_connection_configuration"*) printf '0\n' ;;
    *"replication_group_members"*) printf '0\n' ;;
    *"XA RECOVER"*) : ;;
esac
exit 0
EOF

    cat > "$fake_bin/my_print_defaults" <<EOF
#!/usr/bin/env bash
printf '%s\n' \
    '--datadir=$base_dir/data' \
    '--socket=$base_dir/mysqld/mysql.sock' \
    '--log-error=$base_dir/log/mysqld.log' \
    '--pid-file=$base_dir/mysqld/mysqld.pid'
EOF

    for command_name in mysqlcheck mysqld yum; do
        cat > "$fake_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    done
    chmod +x "$fake_bin"/*

    if PATH="$fake_bin:$PATH" MYSQL_PASSWORD='Mock#Password1!' \
        bash "$UPGRADE_SCRIPT" --base "$base_dir" --config "$base_dir/my.cnf" --bundle "$bundle" precheck; then
        pass "mocked precheck"
    else
        fail "mocked precheck"
        return
    fi

    state_file="$base_dir/.mysql_inplace_upgrade.conf"
    if [[ -f "$state_file" ]] && \
       grep -Fq 'CURRENT_VERSION=8.0.46' "$state_file" && \
       grep -Fq 'TARGET_VERSION=8.4.11' "$state_file" && \
       grep -Fq "DATADIR=$base_dir/data" "$state_file"; then
        pass "saved precheck state"
    else
        fail "saved precheck state"
    fi

    if PATH="$fake_bin:$PATH" MYSQL_PASSWORD='Mock#Password1!' \
        bash "$UPGRADE_SCRIPT" --base "$base_dir" --config "$base_dir/my.cnf" prepare; then
        pass "mocked prepare"
    else
        fail "mocked prepare"
        return
    fi

    if [[ -f "$base_dir/mysql_inplace_upgrade_work/target_rpms.txt" ]] && \
       [[ "$(wc -l < "$base_dir/mysql_inplace_upgrade_work/target_rpms.txt")" -eq 6 ]]; then
        pass "six required target RPMs selected"
    else
        fail "six required target RPMs selected"
    fi

    if printf 'UPGRADE 8.0.46 TO 8.4.11\n' | \
       PATH="$fake_bin:$PATH" MYSQL_PASSWORD='Mock#Password1!' \
       bash "$UPGRADE_SCRIPT" --base "$base_dir" --config "$base_dir/my.cnf" --dry-run upgrade; then
        pass "mocked dry-run upgrade"
    else
        fail "mocked dry-run upgrade"
    fi

    cleanup_mock
    trap - RETURN
}

main() {
    test_version_paths
    test_bundle_filename_parser
    test_mock_workflow

    printf '\n========================================\n'
    printf 'Passed: %d\n' "$passed"
    printf 'Failed: %d\n' "$failed"
    printf '========================================\n'
    [[ "$failed" -eq 0 ]]
}

main "$@"
