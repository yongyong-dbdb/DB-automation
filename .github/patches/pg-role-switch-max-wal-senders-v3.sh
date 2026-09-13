#!/bin/sh
set -eu

BASE='.github/patches/pg-role-switch-max-wal-senders.sh'
TMP='/tmp/pg-role-switch-max-wal-senders.sh'
TARGET='PostgreSQL/postgresql_role_switch_v0.1.22.sh'

# Remove only the original whole-file dependency grep. It falsely matched the
# target's design-constraint comments; all patch operations and other checks stay.
grep -v '^! grep -E ' "$BASE" > "$TMP"
chmod 700 "$TMP"
sh "$TMP"

if awk '!/^[[:space:]]*#/ {print}' "$TARGET" | grep -E '(^|[[:space:]])(python|python3|jq|yq|expect|perl|node|npm|pip)([[:space:]]|$)' >/dev/null 2>&1; then
    echo 'Prohibited separate runtime/package dependency found in executable target code.' >&2
    exit 1
fi

sh -n "$TARGET"
git diff --check -- "$TARGET"
