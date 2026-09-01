#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../mysql_inplace_upgrade.sh
source "$SCRIPT_DIR/mysql_inplace_upgrade.sh"

passed=0
failed=0

expect_supported() {
    local current="$1"
    local target="$2"
    if is_supported_path "$current" "$target"; then
        printf 'PASS supported: %s -> %s\n' "$current" "$target"
        passed=$((passed + 1))
    else
        printf 'FAIL expected supported: %s -> %s\n' "$current" "$target"
        failed=$((failed + 1))
    fi
}

expect_blocked() {
    local current="$1"
    local target="$2"
    if is_supported_path "$current" "$target"; then
        printf 'FAIL expected blocked: %s -> %s\n' "$current" "$target"
        failed=$((failed + 1))
    else
        printf 'PASS blocked: %s -> %s\n' "$current" "$target"
        passed=$((passed + 1))
    fi
}

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

[[ "$(bundle_version_from_name 'mysql-8.4.11-1.el8.x86_64.rpm-bundle.tar')" == "8.4.11" ]] || {
    printf 'FAIL bundle filename parser: rpm-bundle format\n'
    failed=$((failed + 1))
}
[[ "$(bundle_version_from_name 'mysql-9.7.0-1.el8-x86_64-bundle.tar')" == "9.7.0" ]] || {
    printf 'FAIL bundle filename parser: bundle format\n'
    failed=$((failed + 1))
}

printf '\nPassed: %d\nFailed: %d\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
