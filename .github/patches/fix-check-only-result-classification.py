from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()

s=s.replace('EXIT_CANCELLED=4\n', 'EXIT_CANCELLED=4\nEXIT_MANUAL_CHECKS=5\n', 1)

old='''finalize_result_report() {
    frr_code=$1
    [ "$RESULT_INITIALIZED" -eq 1 ] 2>/dev/null || return 0
    if [ "$frr_code" -eq 0 ]; then
        frr_status=$(awk -F '\\t' '$1=="FAILED" {failed=1} $1=="WARNING" {warning=1} $1=="MANUAL CHECK" {manual=1} END {if(failed) print "FAILED"; else if(warning) print "WARNING"; else if(manual) print "MANUAL CHECK"; else print "PASSED"}' "$RESULT_FILE")
        case "$frr_status" in
            PASSED) frr_detail="all automated checks passed" ;;
            MANUAL\\ CHECK) frr_detail="automated checks completed; manual verification remains" ;;
            WARNING) frr_detail="automated checks completed with warnings; review before any role change" ;;
            *) frr_detail="an earlier check failed; review the report" ;;
        esac
    elif [ "$frr_code" -eq "$EXIT_USAGE" ]; then
'''
new='''finalize_result_report() {
    frr_code=$1
    [ "$RESULT_INITIALIZED" -eq 1 ] 2>/dev/null || return 0
    if [ "$frr_code" -eq 0 ]; then
        frr_status="PASSED"
        frr_detail="all automated checks passed"
    elif [ "$frr_code" -eq "$EXIT_MANUAL_CHECKS" ]; then
        frr_status="PASSED WITH MANUAL CHECKS"
        frr_detail="automated blocking checks passed; warnings or operator verification remain"
    elif [ "$frr_code" -eq "$EXIT_USAGE" ]; then
'''
if old not in s:
    raise SystemExit('finalize_result_report block not found')
s=s.replace(old,new,1)

old='''    awk -F '\\t' 'NF >= 2 && ($1=="PASSED" || $1=="WARNING" || $1=="FAILED" || $1=="MANUAL CHECK" || $1=="CANCELLED") {printf "  %-12s %-28s %s\\n", "[" $1 "]", $2, $3}' "$RESULT_FILE" 2>/dev/null || true
'''
new='''    awk -F '\\t' 'NF >= 2 && ($1=="PASSED" || $1=="PASSED WITH MANUAL CHECKS" || $1=="WARNING" || $1=="FAILED" || $1=="MANUAL CHECK" || $1=="CANCELLED") {printf "  %-28s %-28s %s\\n", "[" $1 "]", $2, $3}' "$RESULT_FILE" 2>/dev/null || true
'''
if old not in s:
    raise SystemExit('print_result_summary line not found')
s=s.replace(old,new,1)

old='''    if [ "$CHECK_ONLY" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$RESULT_INITIALIZED" -eq 1 ]; then
        if awk -F '\\t' '$1=="FAILED" || $1=="WARNING" || $1=="MANUAL CHECK" {found=1} END {exit !found}' "$RESULT_FILE"; then
            rc=1
            LAST_ERROR="check-only has unresolved warnings or manual checks"
        fi
    fi
'''
new='''    if [ "$CHECK_ONLY" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$RESULT_INITIALIZED" -eq 1 ]; then
        if awk -F '\\t' '$1=="FAILED" {found=1} END {exit !found}' "$RESULT_FILE"; then
            rc=1
            LAST_ERROR="check-only has one or more blocking validation failures"
        elif awk -F '\\t' '$1=="WARNING" || $1=="MANUAL CHECK" {found=1} END {exit !found}' "$RESULT_FILE"; then
            rc=$EXIT_MANUAL_CHECKS
            LAST_ERROR="check-only automated blocking checks passed; warnings or manual checks remain"
        fi
    fi
'''
if old not in s:
    raise SystemExit('on_exit check-only block not found')
s=s.replace(old,new,1)

p.write_text(s)
