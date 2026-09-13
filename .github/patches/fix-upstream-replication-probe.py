from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
start=s.index('remote_verify_upstream() {')
end=s.index('\nremote_timeout_default() {', start)
new=r'''remote_verify_upstream() {
    rvu_data=$1
    rvu_system=$2
    rvu_port=$3
    remote_init_exact "$rvu_data"
    [ "$LOCAL_ROLE" = "standby" ] || return 1
    rvu_conninfo_output=$(psql_call "SHOW primary_conninfo" 2>/dev/null) || return 22
    rvu_conninfo=$(printf '%s\n' "$rvu_conninfo_output" | sed -n '1p')
    [ -n "$rvu_conninfo" ] || return 1

    # primary_conninfo is a physical streaming-replication connection, not a
    # normal SQL database connection. Reusing it with dbname=<local database>
    # can fail even while WAL streaming is healthy because pg_hba.conf and
    # .pgpass commonly use the special "replication" database match. Expand the
    # original conninfo through dbname, then override replication=true so URI
    # and keyword/value primary_conninfo formats are handled uniformly without
    # exposing credentials in argv.
    case "$rvu_conninfo" in
        *'\n'*|*'\r'*) return 22 ;;
    esac
    rvu_nested=$(conninfo_quote_value "$rvu_conninfo") || return 22
    rvu_dsn="dbname='$rvu_nested' replication=true"

    mktemp_safe || return 22
    rvu_input=$SAFE_TMP
    # psql meta-command quoting interprets backslashes; escape the complete
    # outer conninfo before placing it in the private command file.
    rvu_quoted=$(printf '%s' "$rvu_dsn" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g")
    {
        printf '\\connect -reuse-previous=off '\''%s'\''\n' "$rvu_quoted"
        printf '\\echo __PG_ROLE_SWITCH_UPSTREAM_CONNECTED__\n'
        printf 'IDENTIFY_SYSTEM;\n'
        printf 'SHOW port;\n'
    } > "$rvu_input" || return 22

    rvu_output=$(PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" "$PSQL_BIN" -X -q -A -t -v ON_ERROR_STOP=1 -f "$rvu_input" 2>/dev/null)
    rvu_code=$?
    case "$rvu_code" in
        0) printf '%s\n' "$rvu_output" | grep -Fx '__PG_ROLE_SWITCH_UPSTREAM_CONNECTED__' >/dev/null || return 22 ;;
        2) return 21 ;;
        *)
            if printf '%s\n' "$rvu_output" | grep -Fx '__PG_ROLE_SWITCH_UPSTREAM_CONNECTED__' >/dev/null; then
                return 22
            fi
            return 21
            ;;
    esac

    # IDENTIFY_SYSTEM in replication protocol returns
    # systemid|timeline|xlogpos|dbname in unaligned mode. SHOW port returns the
    # numeric port as a separate line.
    rvu_actual_system=$(printf '%s\n' "$rvu_output" | awk -F '|' 'NF >= 3 && $1 ~ /^[0-9]+$/ {print $1; exit}')
    rvu_actual_port=$(printf '%s\n' "$rvu_output" | awk '/^[0-9]+$/ {print; exit}')
    [ -n "$rvu_actual_system" ] && [ -n "$rvu_actual_port" ] || return 22
    if [ "$rvu_actual_system" != "$rvu_system" ] || [ "$rvu_actual_port" != "$rvu_port" ]; then
        printf 'UPSTREAM_MISMATCH\n'
        return 0
    fi
    printf 'UPSTREAM_VERIFIED\n'
}
'''
s=s[:start]+new+s[end:]
p.write_text(s)
