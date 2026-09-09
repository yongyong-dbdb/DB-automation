from pathlib import Path

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()

def replace_once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    s = s.replace(old, new, 1)

marker = r'''inspect_extra_gtids() {
    i=$1; target=$2'''
helper = r'''write_mysql_readonly_command() {
    i=$1; stmt=$2; out=$3
    {
        printf 'mysql '
        if [ "$(get "$i" mode)" = socket ]; then
            printf '%s ' '--protocol=SOCKET'
            shell_quote "--socket=$(get "$i" socket)"; printf ' '
        else
            printf '%s ' '--protocol=TCP'
            shell_quote "--host=$(get "$i" host)"; printf ' '
            shell_quote "--port=$(get "$i" port)"; printf ' '
            shell_quote "--ssl-mode=$(get "$i" admin_tls)"; printf ' '
            if [ -s "$ROOT/$i/admin_ca" ]; then
                shell_quote "--ssl-ca=$(get "$i" admin_ca)"; printf ' '
            fi
        fi
        shell_quote "--user=$(get "$i" user)"; printf ' '
        printf '%s ' '--password'
        printf '%s ' '-e'
        shell_quote "$stmt"
        printf '\n'
    } > "$out"
    chmod 700 "$out"
}

server_streaming_guidance() {
    i=$1; cmd_file=$2
    grants_file="$RUN/node_${i}.mysqlbinlog_streaming_grants.txt"
    check_file="$RUN/node_${i}.mysqlbinlog_streaming_check.sh"
    grant_file="$RUN/node_${i}.mysqlbinlog_streaming_grant.sql"
    account=$(sql "$i" 'SELECT CURRENT_USER();')
    sql "$i" 'SHOW GRANTS FOR CURRENT_USER;' > "$grants_file" 2>/dev/null || :
    write_mysql_readonly_command "$i" 'SHOW GRANTS FOR CURRENT_USER;' "$check_file"
    grant_stmt=$(sql "$i" "SELECT CONCAT('GRANT REPLICATION SLAVE ON *.* TO ',QUOTE(SUBSTRING_INDEX(CURRENT_USER(),'@',1)),'@',QUOTE(SUBSTRING_INDEX(CURRENT_USER(),'@',-1)),';');" 2>/dev/null || :)
    {
        printf '%s\n' '-- Run only through an authorized DBA account, and only if the streaming account lacks REPLICATION SLAVE.'
        printf '%s\n' "${grant_stmt:-GRANT REPLICATION SLAVE ON *.* TO '<mysql_user>'@'<account_host>'; }"
    } > "$grant_file"
    chmod 600 "$grants_file" "$grant_file" 2>/dev/null || :
    log 'SERVER-STREAMING PREREQUISITES (shown before automatic attempt):'
    log "  MySQL account                  : ${account:-UNKNOWN}"
    log '  Required privilege             : REPLICATION SLAVE'
    log "  Check current grants           : $check_file"
    log "  Captured grants                : $grants_file"
    log "  Authorized DBA grant template  : $grant_file"
    log "  Read-only mysqlbinlog command  : $cmd_file"
    log '  The script does NOT grant privileges automatically and never pipes mysqlbinlog output into mysql.'
}

external_manual_guidance() {
    i=$1; reason=$2
    guide="$RUN/node_${i}.external_reprovision_guide.txt"
    identity_cmd="$RUN/node_${i}.external_identity_check.sh"
    gtid_cmd="$RUN/node_${i}.external_gtid_check.sh"
    write_mysql_readonly_command "$i" 'SELECT @@hostname,@@port,@@socket,@@datadir,@@server_uuid,@@server_id;' "$identity_cmd"
    write_mysql_readonly_command "$i" 'SELECT @@GLOBAL.gtid_executed,@@GLOBAL.gtid_purged,@@GLOBAL.read_only,@@GLOBAL.super_read_only;' "$gtid_cmd"
    {
        printf 'Node %s requires external provisioning/reconciliation.\n' "$i"
        printf 'Reason: %s\n\n' "$reason"
        printf 'Run these read-only checks on/from a host that can reach the target before changing anything:\n'
        printf '  %s\n' "$identity_cmd"
        printf '  %s\n' "$gtid_cmd"
        printf '\nNo destructive restore/reset command is generated automatically. Select and validate the backup/provisioning method first.\n'
        printf 'After provisioning, verify server_uuid/instance identity and GTID state before rerunning migration.\n'
    } > "$guide"
    chmod 600 "$guide"
    log "Manual/external action guide          : $guide"
    log "  Identity check command             : $identity_cmd"
    log "  GTID/fence check command           : $gtid_cmd"
}

inspect_extra_gtids() {
    i=$1; target=$2'''
replace_once(marker, helper, 'manual guidance helpers')

old = r'''    cmd_file=$(write_mysqlbinlog_command "$i" "$available_extra" "$logs_file" "$inspect_mode" "$direct_file")
    log "  Read-only fallback command        : $cmd_file"
    if ! tool=$(mysqlbinlog_tool "$i"); then'''
new = r'''    cmd_file=$(write_mysqlbinlog_command "$i" "$available_extra" "$logs_file" "$inspect_mode" "$direct_file")
    log "  Read-only fallback command        : $cmd_file"
    if [ "$inspect_mode" = remote ]; then
        server_streaming_guidance "$i" "$cmd_file"
    fi
    if ! tool=$(mysqlbinlog_tool "$i"); then'''
replace_once(old, new, 'pre-stream guidance')

old = r'''        log 'Direct local mysqlbinlog read failed; retrying through the server without executing any output.'
        inspect_mode=remote
        printf 'INSPECTION_MODE_FALLBACK\tremote\n' >> "$summary_file"
    fi

    credential "$i"'''
new = r'''        log 'Direct local mysqlbinlog read failed; server streaming is required for the fallback.'
        inspect_mode=remote
        printf 'INSPECTION_MODE_FALLBACK\tremote\n' >> "$summary_file"
        cmd_file=$(write_mysqlbinlog_command "$i" "$available_extra" "$logs_file" remote "$direct_file")
        server_streaming_guidance "$i" "$cmd_file"
    fi

    credential "$i"'''
replace_once(old, new, 'direct fallback guidance')

replace_once(
    '                            log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."\n                            die "Node $i external reconciliation/reprovisioning required before GR migration";;',
    '                            external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"\n                            log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."\n                            die "Node $i external reconciliation/reprovisioning required before GR migration";;',
    'external after inspect')
replace_once(
    '                log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."\n                die "Node $i external reconciliation/reprovisioning required before GR migration";;',
    '                external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"\n                log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."\n                die "Node $i external reconciliation/reprovisioning required before GR migration";;',
    'direct external action')

replace_once(
    '                    log \'Restore the authoritative full data/GTID set, then rerun initialize. No GTID reset is performed by this script.\'\n                    die "Node $i external initialization pending"',
    '                    external_manual_guidance "$i" "NEW_EMPTY member selected external provisioning"\n                    log \'Restore the authoritative full data/GTID set, then rerun initialize. No GTID reset is performed by this script.\'\n                    die "Node $i external initialization pending"',
    'new empty external guidance')
replace_once(
    '                if [ "$method" = external ]; then\n                    die "Node $i external re-provisioning pending"\n                fi',
    '                if [ "$method" = external ]; then\n                    external_manual_guidance "$i" "PREPROVISIONED member selected external reprovisioning"\n                    die "Node $i external re-provisioning pending"\n                fi',
    'preprovisioned external guidance')
replace_once(
    '                gtid_compare "$i" "$target"\n                die "Node $i requires external provisioning from node 1 before GR migration; automatic merge/reset is not performed"',
    '                gtid_compare "$i" "$target"\n                external_manual_guidance "$i" "member is not empty and does not match the authoritative starting point"\n                die "Node $i requires external provisioning from node 1 before GR migration; automatic merge/reset is not performed"',
    'needs provisioning guidance')

p.write_text(s)
