#!/bin/sh
set -eu
TARGET='PostgreSQL/postgresql_role_switch_v0.1.22.sh'
test -f "$TARGET"

# 1) Harden candidate capacity function: validate numeric downstream count before arithmetic,
#    and make reverse-slot reservation exact when the slot already exists.
awk '
BEGIN {infn=0}
/^candidate_switchover_safety_precheck\(\) \{/ {infn=1}
infn && /css_reserve_slots=\$\{1:-0\}/ {
  print
  print "    css_reverse_slot=${2:-}"
  print "    case \"$REMOTE_DOWNSTREAM_COUNT\" in \x27\x27|*[!0-9]*) die \"The selected Standby Server returned an invalid downstream count: ${REMOTE_DOWNSTREAM_COUNT:-<empty>}\" ;; esac"
  next
}
infn && /css_required_slots=\$\(\(REMOTE_REPLICATION_SLOT_COUNT \+ css_reserve_slots\)\)/ {
  print "    css_effective_reserve=$css_reserve_slots"
  print "    if [ \"$css_reserve_slots\" -eq 1 ] 2>/dev/null && [ -n \"$css_reverse_slot\" ]; then"
  print "        css_slot_state=$(remote_invoke --remote-slot-state \"$REMOTE_PGDATA\" \"$css_reverse_slot\" 2>/dev/null | awk -F \x27\\t\x27 \x27$1==\"SLOT_STATE\" {print $3; exit}\x27) || classify_remote_failure \"$?\" \"Could not inspect reverse replication slot state on the selected Standby Server.\""
  print "        case \"$css_slot_state\" in"
  print "            absent) css_effective_reserve=1 ;;"
  print "            physical) css_effective_reserve=0 ;;"
  print "            conflict) die \"Reverse slot name $css_reverse_slot already exists on the selected Standby Server but is not a physical replication slot. Choose another slot name.\" ;;"
  print "            *) die \"Unexpected reverse slot state for $css_reverse_slot: ${css_slot_state:-<empty>}\" ;;"
  print "        esac"
  print "    fi"
  print "    css_required_slots=$((REMOTE_REPLICATION_SLOT_COUNT + css_effective_reserve))"
  next
}
infn && /reserved_for_reverse=\$css_reserve_slots/ {
  gsub(/reserved_for_reverse=\$css_reserve_slots/, "reserved_for_reverse=$css_effective_reserve")
  print
  next
}
infn && /^}/ {infn=0}
{print}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# 2) Add remote slot-state helper before remote_switchover_safety.
awk '
/^remote_switchover_safety\(\) \{/ && !done {
  print "remote_slot_state() {"
  print "    rss_pgdata=$1"
  print "    rss_slot=$2"
  print "    remote_init_exact \"$rss_pgdata\""
  print "    rss_state=$(psql_call_var slot \"$rss_slot\" \"SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:\x27slot\x27) THEN \x27absent\x27 WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name=:\x27slot\x27 AND slot_type=\x27physical\x27) THEN \x27physical\x27 ELSE \x27conflict\x27 END\" 2>/dev/null | tr -d \x27[:space:]\x27) || exit 3"
  print "    printf \x27SLOT_STATE\\t%s\\t%s\\n\x27 \"$rss_slot\" \"$rss_state\""
  print "}"
  print ""
  done=1
}
{print}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# 3) Add dispatcher entry.
awk '
/^    --remote-switchover-safety\)/ && !done {
  print "    --remote-slot-state)"
  print "        [ \"$#\" -eq 3 ] || exit 64"
  print "        remote_slot_state \"$2\" \"$3\""
  print "        exit $?"
  print "        ;;"
  done=1
}
{print}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# 4) Pass the actual reverse slot name in the post-selection recheck.
awk '
/^[[:space:]]*candidate_switchover_safety_precheck 1$/ {sub(/ 1$/, " 1 \"$REVERSE_SLOT\"")}
{print}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# Static/structural validation.
sh -n "$TARGET"
grep -F 'case "$REMOTE_DOWNSTREAM_COUNT" in' "$TARGET" >/dev/null
grep -F 'candidate_switchover_safety_precheck 1 "$REVERSE_SLOT"' "$TARGET" >/dev/null
grep -F -- '--remote-slot-state' "$TARGET" >/dev/null
grep -F 'remote_slot_state() {' "$TARGET" >/dev/null
grep -F 'css_effective_reserve=0' "$TARGET" >/dev/null
grep -F 'slot_type='"'"'physical'"'"'' "$TARGET" >/dev/null
! grep -E '(^|[[:space:]])(python|python3|jq|yq|expect|pip|pip3|npm|node)([[:space:]]|$)' "$TARGET"

git config user.name 'chatgpt-automation'
git config user.email 'chatgpt-automation@users.noreply.github.com'
git add "$TARGET"
git rm '.github/workflows/patch-postgresql-role-switch-safety-v2.yml' '.github/patch-postgresql-role-switch-safety-v2.sh'
git commit -m 'fix: tighten switchover capacity validation ordering'
git push origin main
