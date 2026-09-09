from pathlib import Path

p = Path('MySQL/Group-Replication/mysql_gr_migrate.sh')
s = p.read_text()

def replace_once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    s = s.replace(old, new, 1)

replace_once('# mysql_gr_migrate.sh v1.0.6', '# mysql_gr_migrate.sh v1.0.7', 'header version')
replace_once('VERSION=1.0.6', 'VERSION=1.0.7', 'runtime version')

old_cmd = r'''        printf 'mysqlbinlog --read-from-remote-server --base64-output=DECODE-ROWS -vv '
        if [ "$(get "$i" mode)" = socket ]; then
            printf '%s ' '--protocol=SOCKET'
            printf '%s ' "--socket=$(get "$i" socket)"
        else
            printf '%s ' '--protocol=TCP'
            printf '%s ' "--host=$(get "$i" host)"
            printf '%s ' "--port=$(get "$i" port)"
            printf '%s ' "--ssl-mode=$(get "$i" admin_tls)"
            if [ -s "$ROOT/$i/admin_ca" ]; then
                printf '%s ' "--ssl-ca=$(get "$i" admin_ca)"
            fi
        fi
        printf '%s ' "--user=$(get "$i" user)"
        printf '%s ' '--password'
        printf '%s ' "--include-gtids=$include_gtids"'''
new_cmd = r'''        printf 'mysqlbinlog --read-from-remote-server --base64-output=DECODE-ROWS -vv '
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
        shell_quote "--include-gtids=$include_gtids"; printf ' '''
replace_once(old_cmd, new_cmd, 'fallback command quoting')

old_size = r'''    log_count=$(awk 'END{print NR+0}' "$logs_file")

    {
        printf 'FIELD\tVALUE\n' '''
new_size = r'''    log_count=$(awk 'END{print NR+0}' "$logs_file")
    log_bytes=$(awk -F '\t' '{sum += $2} END{printf "%.0f",sum+0}' "$logs_file")

    {
        printf 'FIELD\tVALUE\n' '''
replace_once(old_size, new_size, 'binary log byte calculation')

old_summary = r'''        printf 'LOG_BIN_BASENAME\t%s\n' "$binlog_basename"
        printf 'BINARY_LOG_COUNT\t%s\n' "$log_count"
    } > "$summary_file"'''
new_summary = r'''        printf 'LOG_BIN_BASENAME\t%s\n' "$binlog_basename"
        printf 'BINARY_LOG_COUNT\t%s\n' "$log_count"
        printf 'BINARY_LOG_BYTES_TO_SCAN\t%s\n' "$log_bytes"
    } > "$summary_file"'''
replace_once(old_summary, new_summary, 'inspection summary bytes')

old_log = r'''    log "  Binary log list                  : $logs_file"
    log "  Inspection summary               : $summary_file"'''
new_log = r'''    log "  Binary log list                  : $logs_file"
    log "  Current binary log bytes to scan : $log_bytes"
    log "  Inspection summary               : $summary_file"'''
replace_once(old_log, new_log, 'inspection log bytes')

old_option = "        log '  inspect : read current binary logs and decode only the extra GTIDs; no SQL is applied.'"
new_option = "        log '  inspect : read current binary logs and decode only the extra GTIDs; no SQL is applied (binary-log I/O/network reads may occur).'"
replace_once(old_option, new_option, 'inspect load description')

p.write_text(s)
