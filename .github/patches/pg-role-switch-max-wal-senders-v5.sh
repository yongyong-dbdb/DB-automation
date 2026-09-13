#!/bin/sh
set -eu
BASE='.github/patches/pg-role-switch-max-wal-senders.sh'
TMP='/tmp/pg-role-switch-max-wal-senders.sh'
TARGET='PostgreSQL/postgresql_role_switch_v0.1.22.sh'

awk '
/^! grep -E / { next }
/index/ { print; next }
index($0,"reserve for table synchronization") && index($0,"-eq 1") { next }
{ print }
' "$BASE" > "$TMP"
chmod 700 "$TMP"
sh "$TMP"

[ "$(grep -F -c 'reserve for table synchronization' "$TARGET")" -ge 1 ]
if awk '!/^[[:space:]]*#/ {print}' "$TARGET" | grep -E '(^|[[:space:]])(python|python3|jq|yq|expect|perl|node|npm|pip)([[:space:]]|$)' >/dev/null 2>&1; then
    echo 'Prohibited separate runtime/package dependency found in executable target code.' >&2
    exit 1
fi
sh -n "$TARGET"
git diff --check -- "$TARGET"
