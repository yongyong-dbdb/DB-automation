from pathlib import Path

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()

def replace_once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    s = s.replace(old, new, 1)

replace_once('# mysql_gr_migrate.sh v1.0.7', '# mysql_gr_migrate.sh v1.0.8', 'header version')
replace_once('VERSION=1.0.7', 'VERSION=1.0.8', 'runtime version')

old_credential = r'''credential() (
    i=$1
    [ ! -f "$TEMP/$i.cnf" ] || exit 0
    pw=$(secret "Node $i password for $(get "$i" user)")
    {
        printf '[client]\nuser="%s"\npassword="%s"\n' "$(optq "$(get "$i" user)")" "$(optq "$pw")"
        if [ "$(get "$i" mode)" = socket ]; then
            printf 'protocol=SOCKET\nsocket="%s"\n' "$(optq "$(get "$i" socket)")"
        else
            printf 'protocol=TCP\nhost="%s"\nport=%s\nssl-mode=%s\n' "$(optq "$(get "$i" host)")" "$(get "$i" port)" "$(get "$i" admin_tls)"
            [ ! -s "$ROOT/$i/admin_ca" ] || printf 'ssl-ca="%s"\n' "$(optq "$(get "$i" admin_ca)")"
        fi
        printf 'connect-timeout=10\n'
    } > "$TEMP/$i.cnf"
)'''
new_credential = r'''credential() (
    i=$1
    [ ! -f "$TEMP/$i.cnf" ] || exit 0
    pw=$(secret "Node $i password for $(get "$i" user)")
    {
        # Keep [client] limited to options shared by MySQL client programs.
        # Program-specific options belong in their own group so mysqlbinlog/
        # mysqldump do not abort on a mysql-only option.
        printf '[client]\nuser="%s"\npassword="%s"\n' "$(optq "$(get "$i" user)")" "$(optq "$pw")"
        if [ "$(get "$i" mode)" = socket ]; then
            printf 'protocol=SOCKET\nsocket="%s"\n' "$(optq "$(get "$i" socket)")"
        else
            printf 'protocol=TCP\nhost="%s"\nport=%s\nssl-mode=%s\n' "$(optq "$(get "$i" host)")" "$(get "$i" port)" "$(get "$i" admin_tls)"
            [ ! -s "$ROOT/$i/admin_ca" ] || printf 'ssl-ca="%s"\n' "$(optq "$(get "$i" admin_ca)")"
        fi
        printf '\n[mysql]\nconnect-timeout=10\n'
    } > "$TEMP/$i.cnf"
)'''
replace_once(old_credential, new_credential, 'credential option groups')

old_sql = r'''sql() (
    i=$1; stmt=$2
    credential "$i"
    # SQL via stdin, never process arguments. No --force; stop on first error.
    printf "SET SESSION sql_mode='NO_ENGINE_SUBSTITUTION';\n%s\n" "$stmt" | "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --batch --raw --skip-column-names
)'''
new_sql = r'''tool_option_preflight() (
    i=$1; tool=$2; label=$3
    credential "$i"
    command -v "$tool" >/dev/null 2>&1 || exit 2
    err="$RUN/node_${i}.${label}_option_preflight.err"
    if ! "$tool" --defaults-file="$TEMP/$i.cnf" --no-login-paths --help >/dev/null 2> "$err"; then
        chmod 600 "$err" 2>/dev/null || :
        log "ERROR: $label rejected the generated client option file for node $i."
        log "Evidence: $err"
        exit 1
    fi
    rm -f "$err"
)

preflight_client_utilities() {
    # Run before initialize mutates/fences anything. Missing optional tools are
    # handled later only if their workflow is actually selected.
    for i in $(ids); do
        tool_option_preflight "$i" "$MYSQL" mysql || die "mysql option-file compatibility check failed for node $i"
        if command -v "$BINLOG" >/dev/null 2>&1; then
            tool_option_preflight "$i" "$BINLOG" mysqlbinlog || die "mysqlbinlog option-file compatibility check failed for node $i"
        fi
    done
    if command -v "$DUMP" >/dev/null 2>&1; then
        tool_option_preflight 1 "$DUMP" mysqldump || die 'mysqldump option-file compatibility check failed for node 1'
    fi
}

sql() (
    i=$1; stmt=$2
    credential "$i"
    # SQL via stdin, never process arguments. No --force; stop on first error.
    printf "SET SESSION sql_mode='NO_ENGINE_SUBSTITUTION';\n%s\n" "$stmt" | "$MYSQL" --defaults-file="$TEMP/$i.cnf" --no-login-paths --batch --raw --skip-column-names
)'''
replace_once(old_sql, new_sql, 'client utility preflight')

start = s.index('mysqlbinlog_tool() (')
end = s.index('\ncatchup() (', start)
old_block = s[start:end]
new_block = r'''mysqlbinlog_tool() (
    i=$1
    command -v "$BINLOG" >/dev/null 2>&1 || exit 1
    tool=$(command -v "$BINLOG")
    version_file="$RUN/node_${i}.mysqlbinlog_version.txt"
    "$tool" --version > "$version_file" 2>&1 || exit 1
    tool_version=$(sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' "$version_file" | head -n 1)
    server_version=$(get "$i" version | sed 's/[^0-9.].*//')
    [ -n "$tool_version" ] && [ "$tool_version" = "$server_version" ] || exit 1
    printf '%s' "$tool"
)

prepare_direct_binlogs() {
    i=$1; logs_file=$2; direct_file=$3
    : > "$direct_file"
    [ "$(get "$i" location)" = local ] || return 1
    binlog_basename=$(val "$i" log_bin_basename)
    [ -n "$binlog_basename" ] || return 1
    binlog_dir=$(dirname "$binlog_basename")
    tab=$(printf '\t')
    while IFS="$tab" read -r log_name file_size encrypted; do
        [ -n "$log_name" ] || continue
        case $log_name in */*|*'..'*) return 1;; esac
        case $encrypted in No|NO|no|0) :;; *) return 1;; esac
        full="$binlog_dir/$log_name"
        [ -f "$full" ] && [ ! -L "$full" ] && [ -r "$full" ] || return 1
        printf '%s\n' "$full" >> "$direct_file"
    done < "$logs_file"
    [ -s "$direct_file" ]
}

write_mysqlbinlog_command() {
    i=$1; include_gtids=$2; logs_file=$3; inspect_mode=$4; direct_file=$5
    cmd_file="$RUN/node_${i}.mysqlbinlog_command.sh"
    {
        printf '#!/bin/sh\n'
        printf '# Read-only GTID inspection helper. It never pipes mysqlbinlog output into mysql.\n'
        printf '# Use a mysqlbinlog client matching MySQL server version %s.\n' "$(get "$i" version)"
        printf 'mysqlbinlog --base64-output=DECODE-ROWS -vv '
        if [ "$inspect_mode" = direct ]; then
            shell_quote "--include-gtids=$include_gtids"; printf ' '
            while IFS= read -r full; do
                [ -n "$full" ] || continue
                shell_quote "$full"; printf ' '
            done < "$direct_file"
        else
            printf '%s ' '--read-from-remote-server'
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
            shell_quote "--include-gtids=$include_gtids"; printf ' '
            tab=$(printf '\t')
            while IFS="$tab" read -r log_name rest; do
                [ -n "$log_name" ] || continue
                shell_quote "$log_name"; printf ' '
            done < "$logs_file"
        fi
        printf '\n'
    } > "$cmd_file"
    chmod 700 "$cmd_file"
    printf '%s' "$cmd_file"
}

inspect_extra_gtids() {
    i=$1; target=$2
    gtid_compare "$i" "$target"
    extra=$GTID_EXTRA
    [ -n "$extra" ] || { log "Node $i has no extra GTIDs to inspect."; return 0; }

    logs_file="$RUN/node_${i}.binary_logs.tsv"
    direct_file="$RUN/node_${i}.binary_log_files.txt"
    summary_file="$RUN/node_${i}.errant_gtid_inspection.tsv"
    output_file="$RUN/node_${i}.errant_gtid.mysqlbinlog.txt"
    error_file="$RUN/node_${i}.errant_gtid.mysqlbinlog.err"
    sql "$i" 'SHOW BINARY LOGS;' > "$logs_file"
    binlog_basename=$(val "$i" log_bin_basename)
    available_extra=$(normalize_gtid "$(sql "$i" "SELECT GTID_SUBTRACT('$(q "$extra")',@@GLOBAL.gtid_purged);")")
    purged_extra=$(normalize_gtid "$(sql "$i" "SELECT GTID_SUBTRACT('$(q "$extra")',GTID_SUBTRACT(@@GLOBAL.gtid_executed,@@GLOBAL.gtid_purged));")")
    log_count=$(awk 'END{print NR+0}' "$logs_file")
    log_bytes=$(awk -F '\t' '{sum += $2} END{printf "%.0f",sum+0}' "$logs_file")
    inspect_mode=remote
    if prepare_direct_binlogs "$i" "$logs_file" "$direct_file"; then inspect_mode=direct; else rm -f "$direct_file"; fi

    {
        printf 'FIELD\tVALUE\n'
        printf 'NODE\t%s\n' "$i"
        printf 'EXTRA_GTID\t%s\n' "$extra"
        printf 'EXTRA_ORIGIN\t%s\n' "$GTID_ORIGIN"
        printf 'EXTRA_AVAILABLE_IN_CURRENT_BINLOGS\t%s\n' "$available_extra"
        printf 'EXTRA_PURGED_FROM_CURRENT_BINLOGS\t%s\n' "$purged_extra"
        printf 'LOG_BIN_BASENAME\t%s\n' "$binlog_basename"
        printf 'BINARY_LOG_COUNT\t%s\n' "$log_count"
        printf 'BINARY_LOG_BYTES_TO_SCAN\t%s\n' "$log_bytes"
        printf 'INSPECTION_MODE\t%s\n' "$inspect_mode"
    } > "$summary_file"

    log "Node $i read-only errant-GTID inspection:"
    log "  Available in current binary logs: ${available_extra:-NONE}"
    log "  Already purged from binary logs  : ${purged_extra:-NONE}"
    log "  Binary log list                  : $logs_file"
    log "  Current binary log bytes to scan : $log_bytes"
    if [ "$inspect_mode" = direct ]; then
        log '  Inspection path                  : local readable unencrypted binlog files (no replication privilege required)'
    else
        log '  Inspection path                  : server streaming (remote/inaccessible/encrypted binlog)'
    fi
    log "  Inspection summary               : $summary_file"
    [ -z "$purged_extra" ] || log '  NOTE: Purged GTIDs cannot be reconstructed from the current binary logs; use retained backups/audit evidence if transaction contents must be reviewed.'

    [ -n "$available_extra" ] || {
        log 'No extra GTID events remain in the current binary logs. No mysqlbinlog decoding was attempted.'
        return 0
    }

    cmd_file=$(write_mysqlbinlog_command "$i" "$available_extra" "$logs_file" "$inspect_mode" "$direct_file")
    log "  Read-only fallback command        : $cmd_file"
    if ! tool=$(mysqlbinlog_tool "$i"); then
        log 'Matching mysqlbinlog was not found on this controller. No package is installed automatically; use the generated read-only command with a matching MySQL client.'
        return 0
    fi

    set --
    if [ "$inspect_mode" = direct ]; then
        while IFS= read -r full; do
            [ -n "$full" ] || continue
            set -- "$@" "$full"
        done < "$direct_file"
        [ "$#" -gt 0 ] || { log "Node $i has no readable direct binary log files; automatic decoding skipped."; return 0; }
        if "$tool" --base64-output=DECODE-ROWS -vv --include-gtids="$available_extra" "$@" > "$output_file" 2> "$error_file"; then
            chmod 600 "$output_file" "$error_file"
            rm -f "$error_file"
            log "  mysqlbinlog evidence              : $output_file"
            log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'
            return 0
        fi
        # A local file may become inaccessible/rotated between SHOW BINARY LOGS and read.
        # Fall back to server streaming rather than changing any server state.
        log 'Direct local mysqlbinlog read failed; retrying through the server without executing any output.'
        inspect_mode=remote
        printf 'INSPECTION_MODE_FALLBACK\tremote\n' >> "$summary_file"
    fi

    credential "$i"
    set --
    tab=$(printf '\t')
    while IFS="$tab" read -r log_name rest; do
        [ -n "$log_name" ] || continue
        set -- "$@" "$log_name"
    done < "$logs_file"
    [ "$#" -gt 0 ] || { log "Node $i returned no binary log files; automatic decoding skipped."; return 0; }
    if "$tool" --defaults-file="$TEMP/$i.cnf" --no-login-paths --read-from-remote-server --base64-output=DECODE-ROWS -vv --include-gtids="$available_extra" "$@" > "$output_file" 2> "$error_file"; then
        chmod 600 "$output_file" "$error_file"
        rm -f "$error_file"
        log "  mysqlbinlog evidence              : $output_file"
        log '  WARNING: The evidence can contain SQL and row values; the file is stored under the protected run directory.'
    else
        chmod 600 "$error_file" 2>/dev/null || :
        log 'Automatic mysqlbinlog decoding failed. No server data was changed.'
        log "  mysqlbinlog error                 : $error_file"
        log "  Use the generated command         : $cmd_file"
    fi
}

divergence_abort_snapshot() {
    i=$1
    snapshot="$RUN/divergence_abort_state.tsv"
    {
        printf 'NODE\tREAD_ONLY\tSUPER_READ_ONLY\tEVENT_SCHEDULER\tGTID_EXECUTED\n'
        for j in $(ids); do
            if row=$(sql "$j" 'SELECT @@server_uuid,@@read_only,@@super_read_only,@@event_scheduler,@@gtid_executed;' 2>/dev/null); then
                printf '%s\t%s\n' "$j" "$row"
            else
                printf '%s\tUNAVAILABLE\n' "$j"
            fi
        done
    } > "$snapshot"
    chmod 600 "$snapshot"
    log "Abort state snapshot: $snapshot"
    log 'NEXT CHECKS:'
    if [ -s "$RUN/node_${i}.errant_gtid.mysqlbinlog.txt" ]; then
        log "  1) Review decoded extra-GTID evidence: $RUN/node_${i}.errant_gtid.mysqlbinlog.txt"
    elif [ -s "$RUN/node_${i}.errant_gtid.mysqlbinlog.err" ]; then
        log "  1) Review mysqlbinlog error: $RUN/node_${i}.errant_gtid.mysqlbinlog.err"
        [ ! -f "$RUN/node_${i}.mysqlbinlog_command.sh" ] || log "     Read-only retry command: $RUN/node_${i}.mysqlbinlog_command.sh"
    else
        log "  1) Review GTID evidence: $RUN/node_${i}.gtid_compare.tsv"
    fi
    log "  2) Review inspection summary: $RUN/node_${i}.errant_gtid_inspection.tsv"
    log '  3) Keep the migration stopped; do not run cutover while extra GTIDs remain.'
    log '  4) After reviewed reconciliation/reprovisioning, rerun precheck and initialize if instance identity is unchanged.'
    log '     If server_uuid/instance identity changed, use a fresh MYSQL_GR_WORK_ROOT and run discover again.'
}

divergence_workflow() {
    i=$1; target=$2
    gtid_compare "$i" "$target"
    [ -n "$GTID_EXTRA" ] || return 0
    log "Node $i has divergent GTID history. There is no automatic ignore, skip, GTID rewrite, or reset path."
    while :; do
        log '  inspect : read current binary logs and decode only the extra GTIDs; no SQL is applied (binary-log I/O/network reads may occur).'
        log '  external: stop here for reviewed reconciliation/reprovisioning from the authoritative source.'
        log '  abort   : stop without changing GTID history; save a read-only state snapshot and print next checks.'
        action=$(required "Node $i divergent GTID action (inspect/external/abort)" inspect)
        case $action in
            inspect)
                inspect_extra_gtids "$i" "$target"
                log 'Inspection complete. Review the saved evidence before deciding how to reconcile the member.'
                while :; do
                    log '  external: reconcile/reprovision outside this script, then rerun after identity and GTID checks pass.'
                    log '  abort   : save current state and print exactly what to review next; no GTID reconciliation is attempted.'
                    next_action=$(required "Node $i action after inspection (external/abort)" abort)
                    case $next_action in
                        external)
                            divergence_abort_snapshot "$i"
                            log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."
                            die "Node $i external reconciliation/reprovisioning required before GR migration";;
                        abort)
                            divergence_abort_snapshot "$i"
                            die "Node $i divergence left unchanged after read-only inspection";;
                        *) log 'Invalid action. Enter external or abort.';;
                    esac
                done
                ;;
            external)
                divergence_abort_snapshot "$i"
                log "Node $i must be reconciled or reprovisioned from authoritative node 1 using a separately validated procedure."
                die "Node $i external reconciliation/reprovisioning required before GR migration";;
            abort)
                divergence_abort_snapshot "$i"
                die "Node $i divergence left unchanged";;
            *) log 'Invalid action. Enter inspect, external, or abort.';;
        esac
    done
}
'''
s = s[:start] + new_block + s[end:]

replace_once('    precheck; fence\n', '    precheck; preflight_client_utilities; fence\n', 'initialize utility preflight')

# Keep the version notes near the final override section accurate.
replace_once(
    '# v1.0.5: state-based member initialization, GTID diagnostics, safer prompts and concise option guidance.\n',
    '# v1.0.5: state-based member initialization, GTID diagnostics, safer prompts and concise option guidance.\n# v1.0.8: client option-group compatibility, preflight checks, local-first binlog inspection and abort guidance.\n',
    'version note')

p.write_text(s)
