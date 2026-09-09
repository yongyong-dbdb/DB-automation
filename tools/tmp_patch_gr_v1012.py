from pathlib import Path
import re

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()

s = s.replace('# mysql_gr_migrate.sh v1.0.11', '# mysql_gr_migrate.sh v1.0.12', 1)
s = s.replace('VERSION=1.0.11', 'VERSION=1.0.12', 1)

insert = r'''
capture_reprovision_evidence() {
    i=$1; target=$2
    dir="$RUN/node_${i}.reprovision"
    mkdir -p "$dir"; chmod 700 "$dir"
    sql "$i" "SELECT @@server_uuid,@@hostname,@@port,@@socket,@@datadir,@@pid_file,@@server_id,REPLACE(REPLACE(@@gtid_executed,CHAR(10),''),CHAR(13),''),REPLACE(REPLACE(@@gtid_purged,CHAR(10),''),CHAR(13),''),@@read_only,@@super_read_only,@@event_scheduler;" > "$dir/runtime_before.tsv"
    sql "$i" 'SELECT CURRENT_USER(),USER();' > "$dir/current_user.tsv"
    sql "$i" 'SHOW GRANTS FOR CURRENT_USER;' > "$dir/current_admin_grants.sql" 2>/dev/null || :
    sql "$i" "SELECT PLUGIN_NAME,PLUGIN_STATUS,PLUGIN_TYPE,PLUGIN_LIBRARY FROM information_schema.plugins ORDER BY PLUGIN_NAME;" > "$dir/plugins.tsv"
    sql "$i" "SELECT EVENT_SCHEMA,EVENT_NAME,DEFINER,STATUS,EVENT_TYPE,EXECUTE_AT,INTERVAL_VALUE,INTERVAL_FIELD FROM information_schema.events ORDER BY EVENT_SCHEMA,EVENT_NAME;" > "$dir/events.tsv"
    sql "$i" 'SELECT * FROM performance_schema.persisted_variables ORDER BY VARIABLE_NAME;' > "$dir/persisted_variables.tsv" 2>/dev/null || :
    sql "$i" 'SHOW REPLICA STATUS;' > "$dir/replica_status.tsv" 2>/dev/null || :
    sql "$i" "SELECT CHANNEL_NAME,HOST,PORT,AUTO_POSITION FROM performance_schema.replication_connection_configuration ORDER BY CHANNEL_NAME;" > "$dir/replication_connections.tsv" 2>/dev/null || :
    printf 'TARGET_GTID\t%s\n' "$target" > "$dir/target_gtid.tsv"
    if [ "$(get "$i" location)" = local ]; then
        pnow=$(local_pid "$i") || die "Node $i local runtime identity changed; reprovision package not generated"
        tr '\000' '\n' < "/proc/$pnow/cmdline" > "$dir/mysqld_argv.txt"
        cat "/proc/$pnow/cgroup" > "$dir/mysqld_cgroup.txt" 2>/dev/null || :
        readlink -f "/proc/$pnow/exe" > "$dir/mysqld_exe.txt"
        stat -c '%n|%U|%G|%u|%g|%a|%d|%i' "$(val "$i" datadir)" > "$dir/filesystem_identity.txt"
        cnf=$(get "$i" cnf)
        if [ -n "$cnf" ] && [ -f "$cnf" ] && [ ! -L "$cnf" ]; then
            cp -p "$cnf" "$dir/$(basename "$cnf").before_reprovision"
            sha256sum "$cnf" "$dir/$(basename "$cnf").before_reprovision" > "$dir/cnf.sha256"
            stat -c '%n|%U|%G|%u|%g|%a|%d|%i' "$cnf" >> "$dir/filesystem_identity.txt"
        fi
    else
        write_mysql_readonly_command "$i" 'SELECT @@server_uuid,@@hostname,@@port,@@socket,@@datadir,@@pid_file,@@server_id,@@gtid_executed,@@gtid_purged;' "$dir/remote_identity_check.sh"
    fi
    printf '%s' "$dir"
}

prepare_reprovision_dump() {
    i=$1; target=$2; dir=$3
    dbs=$(sql 1 "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY schema_name;")
    [ -n "$dbs" ] || die 'Authoritative source has no application DBs; automatic logical reprovision package cannot be built'
    for db in $dbs; do case $db in *[!A-Za-z0-9_\$]*) die 'Database name requires external provisioning';; esac; done
    command -v "$DUMP" >/dev/null 2>&1 || die 'Matching mysqldump executable required for reprovision package'
    dump="$dir/source_application.sql"
    set -f; set -- $dbs; set +f
    "$DUMP" --defaults-file="$TEMP/1.cnf" --no-login-paths --single-transaction --quick --skip-lock-tables --routines --events --triggers --hex-blob --set-gtid-purged=ON --databases "$@" > "$dump" 2> "$dir/source_dump.log"
    [ -s "$dump" ] || die 'Reprovision source dump is empty'
    sha256sum "$dump" > "$dump.sha256"
    [ "$(normalize_gtid "$(val 1 gtid_executed)")" = "$target" ] || die 'Authoritative source GTID changed while preparing reprovision package'
    printf '%s' "$dump"
}

write_reprovision_plan() {
    i=$1; target=$2; dir=$3; dump=$4
    plan="$dir/reprovision_plan.txt"
    datadir=$(val "$i" datadir); datadir=${datadir%/}
    cnf=$(get "$i" cnf)
    old_uuid=$(get "$i" uuid)
    stamp='$(date +%Y%m%d_%H%M%S)_$$'
    {
        printf 'Node %s clean reprovision plan\n' "$i"
        printf 'Authoritative node: 1\nOld UUID: %s\nTarget GTID: %s\nDatadir: %s\nCNF: %s\nDump: %s\n\n' "$old_uuid" "$target" "$datadir" "$cnf" "$dump"
        printf 'Safety rules:\n'
        printf '  - Do NOT run RESET BINARY LOGS AND GTIDS / RESET MASTER.\n'
        printf '  - Do NOT delete the original datadir. Preserve it by atomic rename on the same filesystem.\n'
        printf '  - Build and validate a fresh staging datadir before the final swap whenever OS access permits.\n'
        printf '  - auto.cnf from the old datadir remains only in the rollback backup; it must not be copied into the fresh datadir.\n'
        printf '  - Re-read PID/server_uuid/datadir immediately before any stop or swap; saved PID values are evidence only.\n\n'
        printf 'Recommended path layout at execution time:\n'
        printf '  STAGING=%s.gr_reprovision_stage_%s\n' "$datadir" "$stamp"
        printf '  BACKUP=%s.before_gr_reprovision_%s\n' "$datadir" "$stamp"
        printf '  FAILED=%s.failed_gr_reprovision_%s\n\n' "$datadir" "$stamp"
        if [ "$(get "$i" location)" = local ]; then
            pnow=$(local_pid "$i") || die "Node $i runtime identity changed while writing reprovision plan"
            exe=$(readlink -f "/proc/$pnow/exe")
            owner=$(stat -c %U "$datadir")
            pidfile=$(val "$i" pid_file); sock=$(val "$i" socket)
            service=$(sed -n 's#.*\/\([^/]*\.service\)$#\1#p' "/proc/$pnow/cgroup" | head -n 1)
            printf 'Local runtime evidence:\n  PID=%s\n  mysqld=%s\n  owner=%s\n  pid_file=%s\n  socket=%s\n  systemd_service=%s\n\n' "$pnow" "$exe" "$owner" "$pidfile" "$sock" "${service:-NONE}"
            printf 'Execution sequence:\n'
            printf '  1. Revalidate current UUID/datadir/PID and verify CNF checksum.\n'
            printf '  2. Create STAGING as a sibling of the current datadir with the same owner/group/mode.\n'
            printf '  3. Initialize STAGING with the same mysqld version using --initialize-insecure and isolated socket/pid/log/binlog paths.\n'
            printf '  4. Start only the STAGING instance with --skip-networking and event_scheduler=OFF.\n'
            printf '  5. Restore %s into STAGING and verify GTID exactly equals %s.\n' "$dump" "$target"
            printf '  6. Recreate/verify an administrative account before final swap; never leave a passwordless root account exposed.\n'
            printf '  7. Stop STAGING cleanly, stop the original instance using the proven launcher, then rename original datadir -> BACKUP and STAGING -> original datadir.\n'
            printf '  8. Start the original launcher, verify NEW server_uuid != %s, GTID == target, schema/data checks, and super_read_only=ON.\n' "$old_uuid"
            printf '  9. Keep BACKUP until GR validation and application smoke tests are complete.\n\n'
            printf 'Rollback sequence if the swapped instance fails validation:\n'
            printf '  - Stop the new instance with the same proven launcher.\n'
            printf '  - Rename current datadir -> FAILED.\n'
            printf '  - Rename BACKUP -> %s.\n' "$datadir"
            printf '  - Start the original launcher and verify server_uuid returns to %s before resuming any service.\n' "$old_uuid"
        else
            printf 'Remote-node handling:\n'
            printf '  - Controller cannot assume filesystem access. Use SSH only after host/instance identity verification.\n'
            printf '  - If SSH/OS access is unavailable, run the generated remote_identity_check.sh on/from an authorized host and execute the same STAGING/BACKUP/swap procedure there.\n'
            printf '  - Copy the dump and checksum to the target host before stopping the original instance, then verify checksum on that host.\n'
            printf '  - Do not infer a remote cnf/datadir path from the controller filesystem.\n'
        fi
        printf '\nAfter successful reprovision:\n'
        printf '  - A fresh server_uuid is expected. Do not continue with this migration state.\n'
        printf '  - Use a fresh MYSQL_GR_WORK_ROOT, run discover again, then configure/precheck/initialize.\n'
    } > "$plan"
    chmod 600 "$plan"
    printf '%s' "$plan"
}

prepare_reprovision() {
    i=$1; target=$2; reason=$3
    log "Preparing reversible clean-reprovision package for node $i. No datadir/config mutation is performed by this step."
    dir=$(capture_reprovision_evidence "$i" "$target")
    dump=$(prepare_reprovision_dump "$i" "$target" "$dir")
    plan=$(write_reprovision_plan "$i" "$target" "$dir" "$dump")
    printf 'REASON\t%s\n' "$reason" > "$dir/reason.tsv"
    log "Reprovision evidence : $dir"
    log "Source dump          : $dump"
    log "Reprovision plan     : $plan"
    log 'The original datadir has NOT been moved or deleted. Review/execute the generated plan only after OS launcher and rollback paths are proven.'
}

'''

marker = 'divergence_abort_snapshot() {'
if marker not in s:
    raise SystemExit('snapshot marker not found')
s = s.replace(marker, insert + marker, 1)

new_snapshot = r'''divergence_abort_snapshot() {
    i=$1
    snapshot="$RUN/divergence_abort_state.tsv"
    {
        printf 'NODE\tSERVER_UUID\tREAD_ONLY\tSUPER_READ_ONLY\tEVENT_SCHEDULER\tGTID_EXECUTED\n'
        for j in $(ids); do
            if row=$(sql "$j" "SELECT @@server_uuid,@@read_only,@@super_read_only,@@event_scheduler,REPLACE(REPLACE(@@gtid_executed,CHAR(10),''),CHAR(13),'');" 2>/dev/null); then
                printf '%s\t%s\n' "$j" "$row"
            else
                printf '%s\tUNAVAILABLE\tUNAVAILABLE\tUNAVAILABLE\tUNAVAILABLE\tUNAVAILABLE\n' "$j"
            fi
        done
    } > "$snapshot"
    chmod 600 "$snapshot"
    log "Abort state snapshot: $snapshot"
    log 'NEXT CHECKS:'
    if [ -s "$RUN/node_${i}.errant_gtid_summary.tsv" ]; then
        log "  1) Review automatic per-GTID DML/DDL summary: $RUN/node_${i}.errant_gtid_summary.tsv"
        [ ! -d "$RUN/node_${i}.ddl_metadata" ] || log "  2) Review Source/Node DDL metadata comparisons: $RUN/node_${i}.ddl_metadata"
        log "  3) Review raw decoded evidence if needed: $RUN/node_${i}.errant_gtid.mysqlbinlog.txt"
    elif [ -s "$RUN/node_${i}.errant_gtid.mysqlbinlog.err" ]; then
        log "  1) Review mysqlbinlog error: $RUN/node_${i}.errant_gtid.mysqlbinlog.err"
        [ ! -f "$RUN/node_${i}.mysqlbinlog_command.sh" ] || log "     Read-only retry command: $RUN/node_${i}.mysqlbinlog_command.sh"
        log "  2) Review GTID comparison: $RUN/node_${i}.gtid_compare.tsv"
    else
        log "  1) Review GTID evidence: $RUN/node_${i}.gtid_compare.tsv"
    fi
    log "  4) Review inspection summary: $RUN/node_${i}.errant_gtid_inspection.tsv"
    log '  5) Keep the migration stopped; do not run cutover while extra GTIDs remain.'
    log '  6) Choose reprovision to generate a reversible clean-rebuild package, or external for another reviewed method.'
    log '  7) After a rebuild changes server_uuid, use a fresh MYSQL_GR_WORK_ROOT and run discover again.'
}
'''
s, n = re.subn(r'divergence_abort_snapshot\(\) \{.*?\n\}\n\ndivergence_workflow\(\) \{', new_snapshot + '\n\ndivergence_workflow() {', s, count=1, flags=re.S)
if n != 1:
    raise SystemExit('snapshot replacement failed')

new_div = r'''divergence_workflow() {
    i=$1; target=$2
    gtid_compare "$i" "$target"
    [ -n "$GTID_EXTRA" ] || return 0
    log "Node $i has divergent GTID history. There is no automatic ignore, skip, GTID rewrite, or reset path."
    while :; do
        log '  inspect     : read current binary logs and decode only the extra GTIDs; no SQL is applied.'
        log '  reprovision : generate evidence + authoritative logical dump + reversible STAGING/BACKUP/rollback plan.'
        log '  external    : stop here for another reviewed reconciliation/reprovisioning method.'
        log '  abort       : stop without changing GTID history; save a read-only state snapshot.'
        action=$(required "Node $i divergent GTID action (inspect/reprovision/external/abort)" inspect)
        case $action in
            inspect)
                inspect_extra_gtids "$i" "$target"
                log 'Inspection complete. Review the saved evidence before deciding how to reconcile the member.'
                while :; do
                    log '  reprovision: prepare a reversible clean-rebuild package from authoritative node 1.'
                    log '  external   : use another separately reviewed reconciliation/provisioning method.'
                    log '  abort      : save current state and stop; no GTID reconciliation is attempted.'
                    next_action=$(required "Node $i action after inspection (reprovision/external/abort)" abort)
                    case $next_action in
                        reprovision)
                            divergence_abort_snapshot "$i"
                            prepare_reprovision "$i" "$target" "divergent GTID history ($GTID_ORIGIN)"
                            die "Node $i reprovision package prepared; execute/review it, then rediscover with a fresh work root";;
                        external)
                            divergence_abort_snapshot "$i"
                            external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"
                            die "Node $i external reconciliation/reprovisioning required before GR migration";;
                        abort)
                            divergence_abort_snapshot "$i"
                            die "Node $i divergence left unchanged after read-only inspection";;
                        *) log 'Invalid action. Enter reprovision, external, or abort.';;
                    esac
                done
                ;;
            reprovision)
                divergence_abort_snapshot "$i"
                prepare_reprovision "$i" "$target" "divergent GTID history ($GTID_ORIGIN)"
                die "Node $i reprovision package prepared; execute/review it, then rediscover with a fresh work root";;
            external)
                divergence_abort_snapshot "$i"
                external_manual_guidance "$i" "divergent GTID history ($GTID_ORIGIN)"
                die "Node $i external reconciliation/reprovisioning required before GR migration";;
            abort)
                divergence_abort_snapshot "$i"
                die "Node $i divergence left unchanged";;
            *) log 'Invalid action. Enter inspect, reprovision, external, or abort.';;
        esac
    done
}
'''
s, n = re.subn(r'divergence_workflow\(\) \{.*?\n\}\n\ncatchup\(\) \(', new_div + '\n\ncatchup() (', s, count=1, flags=re.S)
if n != 1:
    raise SystemExit('divergence replacement failed')

old = '''            NEEDS_PROVISIONING)\n                log "Node $i state: NEEDS_PROVISIONING - it is not empty and does not exactly match the authoritative GTID/data starting point."\n                gtid_compare "$i" "$target"\n                external_manual_guidance "$i" "member is not empty and does not match the authoritative starting point"\n                die "Node $i requires external provisioning from node 1 before GR migration; automatic merge/reset is not performed"\n                ;;'''
new = '''            NEEDS_PROVISIONING)\n                log "Node $i state: NEEDS_PROVISIONING - it is not empty and does not exactly match the authoritative GTID/data starting point."\n                gtid_compare "$i" "$target"\n                log '  reprovision: generate evidence + authoritative dump + reversible STAGING/BACKUP/rollback plan.'\n                log '  external   : use another separately reviewed provisioning method.'\n                method=$(required "Node $i provisioning (reprovision/external)" reprovision)\n                case $method in\n                    reprovision)\n                        prepare_reprovision "$i" "$target" 'member is not empty and does not match the authoritative starting point'\n                        die "Node $i reprovision package prepared; execute/review it, then rediscover with a fresh work root";;\n                    external)\n                        external_manual_guidance "$i" "member is not empty and does not match the authoritative starting point"\n                        die "Node $i requires external provisioning from node 1 before GR migration";;\n                    *) die 'Choose reprovision or external';;\n                esac\n                ;;'''
if old not in s:
    raise SystemExit('NEEDS_PROVISIONING block not found')
s = s.replace(old, new, 1)

s = s.replace('# v1.0.11: broader controller utility preflight and RENAME TABLE source/target metadata coverage.', '# v1.0.11: broader controller utility preflight and RENAME TABLE source/target metadata coverage.\n# v1.0.12: reversible reprovision package generation, staging/swap rollback plan, and stable abort TSV output.', 1)

p.write_text(s)
print('patched', p)
