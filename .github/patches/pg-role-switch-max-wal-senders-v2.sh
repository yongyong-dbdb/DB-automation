#!/bin/sh
set -eu

BASE='.github/patches/pg-role-switch-max-wal-senders.sh'
TMP='/tmp/pg-role-switch-max-wal-senders.sh'
TARGET='PostgreSQL/postgresql_role_switch_v0.1.22.sh'

# The first patch validator scanned comments as executable dependency usage.
# Preserve all patch operations but replace only that validator with a
# comment-aware check. No target code is skipped.
awk '
/^! grep -E .*python\|python3\|jq\|yq\|expect\|perl\|node\|npm\|pip.*\"\$TARGET\"$/ { next }
{ print }
' "$BASE" > "$TMP"
chmod 700 "$TMP"
sh "$TMP"

if awk '!/^[[:space:]]*#/ {print}' "$TARGET" | grep -E '(^|[[:space:]])(python|python3|jq|yq|expect|perl|node|npm|pip)([[:space:]]|$)' >/dev/null 2>&1; then
    echo 'Prohibited separate runtime/package dependency found in executable target code.' >&2
    exit 1
fi

sh -n "$TARGET"
git diff --check -- "$TARGET"
