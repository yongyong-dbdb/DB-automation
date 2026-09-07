#!/bin/sh
set -u

PSQL_BIN=${PSQL_BIN:-}

if [ -z "$PSQL_BIN" ]; then
    if command -v psql >/dev/null 2>&1; then
        PSQL_BIN=$(command -v psql)
    elif [ -n "${PG_HOME:-}" ] && [ -x "${PG_HOME}/bin/psql" ]; then
        PSQL_BIN="${PG_HOME}/bin/psql"
    else
        printf 'psql path: ' >&2
        IFS= read -r PSQL_BIN
    fi
fi

[ -x "$PSQL_BIN" ] || {
    echo "ERROR: psql not found: $PSQL_BIN" >&2
    exit 1
}

read_conf_value() {
    key=$1
    file=$2
    [ -r "$file" ] || return 1
    sed -n \
        -e "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
        -e "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\([^#[:space:]]*\).*/\1/p" \
        "$file" | tail -1
}

if [ -z "${PGPORT:-}" ] && [ -n "${PGDATA:-}" ]; then
    _detected_port=$(read_conf_value port "$PGDATA/postgresql.conf" 2>/dev/null || true)
    case $_detected_port in
        ''|*[!0-9]*) ;;
        *) PGPORT=$_detected_port ;;
    esac
fi

if [ -z "${PGHOST:-}" ] && [ -n "${PGDATA:-}" ]; then
    _detected_socket=$(read_conf_value unix_socket_directories "$PGDATA/postgresql.conf" 2>/dev/null || true)
    case $_detected_socket in
        ''|'*') ;;
        *)
            PGHOST=$(printf '%s' "$_detected_socket" | awk -F, '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}')
            ;;
    esac
fi

if [ -z "${PGHOST:-}" ]; then
    printf 'PGHOST [local socket/default]: ' >&2
    IFS= read -r _v
    [ -z "$_v" ] || PGHOST=$_v
fi

if [ -z "${PGPORT:-}" ]; then
    printf 'PGPORT [5432]: ' >&2
    IFS= read -r _v
    PGPORT=${_v:-5432}
fi

if [ -z "${PGUSER:-}" ]; then
    printf 'PGUSER [%s]: ' "${USER:-postgres}" >&2
    IFS= read -r _v
    PGUSER=${_v:-${USER:-postgres}}
fi

if [ -z "${PGDATABASE:-}" ]; then
    printf 'PGDATABASE [%s]: ' "$PGUSER" >&2
    IFS= read -r _v
    PGDATABASE=${_v:-$PGUSER}
fi

export PGPORT PGUSER PGDATABASE
[ -n "${PGHOST:-}" ] && export PGHOST

echo
echo "Connection"
echo "  psql     : $PSQL_BIN"
echo "  host     : ${PGHOST:-default/local socket}"
echo "  port     : $PGPORT"
echo "  user     : $PGUSER"
echo "  database : $PGDATABASE"
echo


# Private temporary files for this invocation.
work_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/pg_explain.XXXXXXXX") || exit 1
tty_state=
cleanup() {
    if [ -n "$tty_state" ]; then
        stty "$tty_state" </dev/tty 2>/dev/null || :
    fi
    rm -rf -- "$work_dir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_psql() {
    "$PSQL_BIN" -w "$@"
}

password_prompted=no
prompt_password_once() {
    [ "$password_prompted" = no ] || return 1
    password_prompted=yes
    tty_state=$(stty -g </dev/tty) || {
        echo "ERROR: No terminal; configure PGPASSFILE for unattended execution." >&2
        return 1
    }
    printf 'Password for user %s: ' "$PGUSER" >/dev/tty
    stty -echo </dev/tty || return 1
    IFS= read -r _password </dev/tty
    _read_status=$?
    stty "$tty_state" </dev/tty || return 1
    tty_state=
    printf '\n' >/dev/tty
    [ "$_read_status" -eq 0 ] || { unset _password; return 1; }
    # Host wildcard covers PGHOST retry and local sockets.
    (
        umask 077
        for _field in "$PGPORT" "$PGDATABASE" "$PGUSER" "$_password"; do
            case $_field in
                *'
'*) exit 1 ;;
            esac
        done
        printf '*:'
        for _field in "$PGPORT" "$PGDATABASE" "$PGUSER"; do
            printf '%s' "$_field" | sed 's/\\/\\\\/g; s/:/\\:/g'
            printf ':'
        done
        printf '%s' "$_password" | sed 's/\\/\\\\/g; s/:/\\:/g'
        printf '\n'
    ) > "$work_dir/pgpass"
    _write_status=$?
    unset _password
    [ "$_write_status" -eq 0 ] || return 1
    chmod 600 "$work_dir/pgpass" || return 1
    unset PGPASSWORD
    PGPASSFILE=$work_dir/pgpass
    export PGPASSFILE
}

check_connection() {
    if LC_ALL=C run_psql -X -Atqc "SELECT 1;" >/dev/null 2>"$work_dir/connection.err"; then
        return 0
    fi
    # Socket/network/database errors must not trigger a password prompt.
    if grep -Eq 'no password supplied|password authentication failed' "$work_dir/connection.err" &&
       [ "$password_prompted" = no ]; then
        prompt_password_once || return 1
        run_psql -X -Atqc "SELECT 1;" >/dev/null
        return $?
    fi
    cat "$work_dir/connection.err" >&2
    return 1
}

if ! check_connection; then
    echo "Initial connection failed."
    printf 'Retry with PGHOST (example: localhost or socket directory): ' >&2
    IFS= read -r _retry_host
    [ -n "$_retry_host" ] || {
        echo "ERROR: PostgreSQL connection failed." >&2
        exit 1
    }
    PGHOST=$_retry_host
    export PGHOST
    check_connection || {
        echo "ERROR: PostgreSQL connection failed." >&2
        exit 1
    }
fi

SQL_FILE=${1:-}
while :
do
    if [ -z "$SQL_FILE" ]; then
        printf 'Target SQL file path (empty to cancel): ' >&2
        IFS= read -r SQL_FILE || {
            echo "Cancelled." >&2
            exit 1
        }
        [ -n "$SQL_FILE" ] || {
            echo "Cancelled." >&2
            exit 1
        }
    fi
    if [ -f "$SQL_FILE" ] && [ -r "$SQL_FILE" ]; then
        break
    fi
    printf 'ERROR: cannot read SQL file: %s\n' "$SQL_FILE" >&2
    SQL_FILE=
done

SERVER_VERSION_NUM=$(run_psql -X -Atqc "SHOW server_version_num") || exit 1
case $SERVER_VERSION_NUM in
    ''|*[!0-9]*)
        echo "ERROR: invalid server_version_num" >&2
        exit 1
        ;;
esac

ask() {
    prompt=$1
    default=$2
    printf '%s [%s]: ' "$prompt" "$default" >&2
    IFS= read -r ans
    [ -n "$ans" ] || ans=$default
    case $ans in
        yes|no) printf '%s' "$ans" ;;
        *)
            echo "ERROR: yes/no only" >&2
            exit 1
            ;;
    esac
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

# Let PostgreSQL parse placeholders; do not count $n in comments or strings.
BIND=$(ask 'Use bind parameters ($1, $2, ...)? yes/no' no) || exit 1
prepare_file="$work_dir/prepare.sql"
execute_file="$work_dir/execute.sql"
if [ "$BIND" = yes ]; then
    printf 'Parameter types, comma-separated [auto infer]: ' >&2
    IFS= read -r bind_types || exit 1
    {
        printf 'SET standard_conforming_strings = on;\n'
        printf 'PREPARE pg_explain_target'
        [ -z "$bind_types" ] || printf ' (%s)' "$bind_types"
        printf ' AS\n'
        cat "$SQL_FILE"
        printf '\n;\n'
    } > "$prepare_file"
    BIND_COUNT=$(
        {
            cat "$prepare_file"
            printf "SELECT cardinality(parameter_types) FROM pg_prepared_statements WHERE name = 'pg_explain_target';\n"
        } | run_psql -X -qAt -v ON_ERROR_STOP=1
    ) || {
        echo "ERROR: Could not prepare SQL. Check the SQL and parameter types." >&2
        exit 1
    }
    case $BIND_COUNT in
        ''|*[!0-9]*) echo "ERROR: invalid parameter count" >&2; exit 1 ;;
    esac
    echo "Bind parameter count: $BIND_COUNT"
    echo 'Enter each value as plain text (no SQL quotes). \N means SQL NULL; empty input means an empty string.'
    printf 'EXECUTE pg_explain_target' > "$execute_file"
    if [ "$BIND_COUNT" -gt 0 ]; then
        printf '(' >> "$execute_file"
        bind_index=1
        while [ "$bind_index" -le "$BIND_COUNT" ]; do
            printf 'Value for $%s: ' "$bind_index" >&2
            IFS= read -r bind_value || exit 1
            [ "$bind_index" -eq 1 ] || printf ', ' >> "$execute_file"
            if [ "$bind_value" = '\N' ]; then
                printf 'NULL' >> "$execute_file"
            else
                printf "'" >> "$execute_file"
                printf '%s' "$bind_value" | sed "s/'/''/g" >> "$execute_file"
                printf "'" >> "$execute_file"
            fi
            bind_index=$((bind_index + 1))
        done
        printf ')' >> "$execute_file"
    fi
    printf ';\n' >> "$execute_file"
    unset bind_value bind_types
fi

echo "PostgreSQL server_version_num: $SERVER_VERSION_NUM"
echo
echo "ANALYZE  : SQL 실제 실행 + Actual Rows/Time. DML은 실제 변경 발생 가능."
ANALYZE=$(ask "Use ANALYZE? yes/no" no)

echo "VERBOSE  : Output column, schema-qualified object 등 상세 표시."
VERBOSE=$(ask "Use VERBOSE? yes/no" no)

echo "COSTS    : Startup/Total Cost, Estimated Rows/Width 표시. 기본 ON."
COSTS=$(ask "Use COSTS? yes/no" yes)

echo "SETTINGS : Plan에 영향을 준 비기본 설정을 Plan 출력에 포함."
SETTINGS=$(ask "Use SETTINGS? yes/no" yes)

BUFFERS=no
WAL=no
TIMING=no
GENERIC_PLAN=no
SERIALIZE=no
MEMORY=no

if [ "$ANALYZE" = yes ]; then
    echo "BUFFERS   : shared/local/temp Buffer hit/read/write 및 I/O timing."
    BUFFERS=$(ask "Use BUFFERS? yes/no" yes)

    if [ "$SERVER_VERSION_NUM" -ge 130000 ]; then
        echo "WAL       : WAL record/FPI/bytes. PostgreSQL 13+."
        WAL=$(ask "Use WAL? yes/no" no)
    fi

    echo "TIMING    : Plan Node별 실제 수행시간. 측정 오버헤드 존재."
    TIMING=$(ask "Use TIMING? yes/no" yes)

    if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then
        echo "SERIALIZE : Query 결과 직렬화 비용 측정. PostgreSQL 17+."
        SERIALIZE=$(ask "Use SERIALIZE TEXT? yes/no" no)
    fi
else
    if [ "$BIND" = yes ] || [ "$SERVER_VERSION_NUM" -ge 160000 ]; then
        echo "GENERIC_PLAN : Parameter 값과 무관한 Generic Plan. ANALYZE와 동시 사용 불가."
        GENERIC_PLAN=$(ask "Use GENERIC_PLAN? yes/no" no)
    fi
fi

if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then
    echo "MEMORY    : Planner Memory 사용량. PostgreSQL 17+."
    MEMORY=$(ask "Use MEMORY? yes/no" no)
fi

echo "SUMMARY   : Planning/Execution 요약."
SUMMARY=$(ask "Use SUMMARY? yes/no" yes)

printf 'FORMAT (TEXT/JSON/YAML/XML) [TEXT]: ' >&2
IFS= read -r FORMAT
[ -n "$FORMAT" ] || FORMAT=TEXT
case $FORMAT in
    TEXT|JSON|YAML|XML) ;;
    *)
        echo "ERROR: invalid format" >&2
        exit 1
        ;;
esac

opts=""
addopt() {
    [ -z "$opts" ] && opts="$1" || opts="$opts, $1"
}

[ "$ANALYZE" = yes ] && addopt "ANALYZE"
[ "$VERBOSE" = yes ] && addopt "VERBOSE"
[ "$COSTS" = yes ] && addopt "COSTS TRUE" || addopt "COSTS FALSE"
[ "$SETTINGS" = yes ] && addopt "SETTINGS"
[ "$BUFFERS" = yes ] && addopt "BUFFERS"
[ "$WAL" = yes ] && addopt "WAL"
[ "$TIMING" = yes ] && addopt "TIMING TRUE"
[ "$ANALYZE" = yes ] && [ "$TIMING" = no ] && addopt "TIMING FALSE"
[ "$GENERIC_PLAN" = yes ] && [ "$BIND" = no ] && addopt "GENERIC_PLAN"
[ "$SERIALIZE" = yes ] && addopt "SERIALIZE TEXT"
[ "$MEMORY" = yes ] && addopt "MEMORY"
[ "$SUMMARY" = yes ] && addopt "SUMMARY"
addopt "FORMAT $FORMAT"

tmp="$work_dir/explain.sql"
plan_json="$work_dir/plan.json"
rel_file="$work_dir/relations.txt"
table_before="$work_dir/table_before.txt"
table_after="$work_dir/table_after.txt"
index_before="$work_dir/index_before.txt"
index_after="$work_dir/index_after.txt"

# PREPARE belongs to a connection: recreate it before each EXPLAIN.
emit_plan() {
    plan_options=$1
    if [ "$BIND" = yes ]; then
        cat "$prepare_file"
        if [ "$GENERIC_PLAN" = yes ]; then
            printf 'SET plan_cache_mode = force_generic_plan;\n'
        else
            printf 'SET plan_cache_mode = force_custom_plan;\n'
        fi
        printf 'EXPLAIN (%s)\n' "$plan_options"
        cat "$execute_file"
    else
        printf 'EXPLAIN (%s)\n' "$plan_options"
        cat "$SQL_FILE"
        printf '\n'
    fi
}

json_options='VERBOSE, COSTS FALSE, FORMAT JSON'
if [ "$GENERIC_PLAN" = yes ] && [ "$BIND" = no ]; then
    json_options="$json_options, GENERIC_PLAN"
fi
emit_plan "$json_options" | run_psql -X -qAt -v ON_ERROR_STOP=1 > "$plan_json" || {
    echo "ERROR: Could not generate JSON plan for relation extraction." >&2
    exit 1
}

awk '
    /"Schema"[[:space:]]*:/ {
        line=$0
        sub(/^.*"Schema"[[:space:]]*:[[:space:]]*"/,"",line)
        sub(/".*$/,"",line)
        schema=line
    }
    /"Relation Name"[[:space:]]*:/ {
        line=$0
        sub(/^.*"Relation Name"[[:space:]]*:[[:space:]]*"/,"",line)
        sub(/".*$/,"",line)
        rel=line
        if (schema != "" && rel != "") {
            print schema "." rel
        }
    }
' "$plan_json" | sort -u > "$rel_file"

DML_OPERATION=$(awk -F'"' '
    /"Operation"[[:space:]]*:[[:space:]]*"(Insert|Update|Delete|Merge)"/ {
        print $4
        exit
    }
' "$plan_json")

DML_ANALYZE=no
if [ "$ANALYZE" = yes ]; then
    echo
    echo "WARNING: EXPLAIN ANALYZE executes the statement."

    if [ -n "$DML_OPERATION" ]; then
        DML_ANALYZE=yes
        echo "DML detected : $DML_OPERATION"
        echo "Execution    : BEGIN -> EXPLAIN ANALYZE -> ROLLBACK"
        echo "Table row changes are rolled back automatically."
        echo "Sequence increments, external functions, or other non-transactional side effects may remain."
    else
        echo "Read-only/non-DML plan detected: no automatic ROLLBACK wrapper."
    fi

    printf 'Type EXECUTE to continue: ' >&2
    IFS= read -r confirm
    [ "$confirm" = EXECUTE ] || {
        echo "Cancelled."
        exit 1
    }
fi

snapshot_stats() {
    table_file=$1
    index_file=$2
    : > "$table_file"
    : > "$index_file"

    while IFS= read -r rel
    do
        [ -n "$rel" ] || continue

        printf '%s\n' "
SELECT st.relid,
       st.schemaname || '.' || st.relname,
       COALESCE(st.seq_scan,0),
       COALESCE(st.seq_tup_read,0),
       COALESCE(st.idx_scan,0),
       COALESCE(st.idx_tup_fetch,0),
       COALESCE(st.n_tup_ins,0),
       COALESCE(st.n_tup_upd,0),
       COALESCE(st.n_tup_del,0),
       COALESCE(st.n_tup_hot_upd,0)
FROM pg_stat_all_tables st
WHERE st.relid=:'rel'::regclass;
" | run_psql -X -At -F '|' -v ON_ERROR_STOP=1 -v rel="$rel" >> "$table_file"

        printf '%s\n' "
SELECT si.indexrelid,
       si.indexrelid::regclass::text,
       COALESCE(si.idx_scan,0),
       COALESCE(si.idx_tup_read,0),
       COALESCE(si.idx_tup_fetch,0),
       COALESCE(io.idx_blks_read,0),
       COALESCE(io.idx_blks_hit,0)
FROM pg_stat_all_indexes si
LEFT JOIN pg_statio_all_indexes io
  ON io.indexrelid=si.indexrelid
WHERE si.relid=:'rel'::regclass
ORDER BY si.indexrelid;
" | run_psql -X -At -F '|' -v ON_ERROR_STOP=1 -v rel="$rel" >> "$index_file"
    done < "$rel_file"
}

print_table_delta() {
    [ -s "$table_before" ] && [ -s "$table_after" ] || return 0
    awk -F'|' '
        NR==FNR {
            for (i=3;i<=10;i++) b[$1,i]=$i
            name[$1]=$2
            next
        }
        {
            id=$1
            printf "\n%s\n", name[id]
            printf "%-24s %15s %15s %15s\n", "metric", "before", "after", "delta"
            printf "%-24s %15s %15s %15s\n", "------------------------", "---------------", "---------------", "---------------"
            label[3]="seq_scan"
            label[4]="seq_tup_read"
            label[5]="idx_scan"
            label[6]="idx_tup_fetch"
            label[7]="n_tup_ins"
            label[8]="n_tup_upd"
            label[9]="n_tup_del"
            label[10]="n_tup_hot_upd"
            for (i=3;i<=10;i++) {
                before=(b[id,i]==""?0:b[id,i])
                after=$i
                delta=after-before
                printf "%-24s %15s %15s %+15d\n", label[i], before, after, delta
            }
        }
    ' "$table_before" "$table_after"
}

print_index_delta() {
    [ -s "$index_before" ] && [ -s "$index_after" ] || return 0
    awk -F'|' '
        NR==FNR {
            for (i=3;i<=7;i++) b[$1,i]=$i
            name[$1]=$2
            next
        }
        {
            id=$1
            printf "\n%s\n", name[id]
            printf "%-24s %15s %15s %15s\n", "metric", "before", "after", "delta"
            printf "%-24s %15s %15s %15s\n", "------------------------", "---------------", "---------------", "---------------"
            label[3]="idx_scan"
            label[4]="idx_tup_read"
            label[5]="idx_tup_fetch"
            label[6]="idx_blks_read"
            label[7]="idx_blks_hit"
            for (i=3;i<=7;i++) {
                before=(b[id,i]==""?0:b[id,i])
                after=$i
                delta=after-before
                printf "%-24s %15s %15s %+15d\n", label[i], before, after, delta
            }
        }
    ' "$index_before" "$index_after"
}

if [ "$ANALYZE" = yes ] && [ -s "$rel_file" ]; then
    snapshot_stats "$table_before" "$index_before"
fi

if [ "$DML_ANALYZE" = yes ]; then
    {
        printf 'BEGIN;\n'
        emit_plan "$opts"
        printf '\nROLLBACK;\n'
    } > "$tmp"
else
    {
        emit_plan "$opts"
    } > "$tmp"
fi

section "Execution Plan"
echo "Generated: EXPLAIN ($opts)"
if [ "$DML_ANALYZE" = yes ]; then
    echo "DML safety: BEGIN -> EXPLAIN ANALYZE -> ROLLBACK"
fi
run_psql -X -q -v ON_ERROR_STOP=1 -f "$tmp" || exit 1

if [ "$ANALYZE" = yes ] && [ -s "$rel_file" ]; then
    snapshot_stats "$table_after" "$index_after"

    section "Table Statistics Delta"
    print_table_delta

    section "Index Statistics / I/O Delta"
    print_index_delta

    echo
    echo "NOTE: Delta is calculated from cumulative pg_stat_* counters before/after this run."
    echo "      Concurrent sessions using the same relation can be included in the delta."
    echo "      The per-query I/O shown by EXPLAIN (ANALYZE, BUFFERS) is more specific to this execution."
fi

DIAG=$(ask "Show additional Plan diagnostics? yes/no" yes)
[ "$DIAG" = yes ] || exit 0

section "Planner Settings"
run_psql -X -P pager=off -v ON_ERROR_STOP=1 <<'SQL'
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN (
 'seq_page_cost','random_page_cost','cpu_tuple_cost','cpu_index_tuple_cost',
 'cpu_operator_cost','effective_cache_size','work_mem','default_statistics_target',
 'effective_io_concurrency','max_parallel_workers','max_parallel_workers_per_gather',
 'parallel_setup_cost','parallel_tuple_cost',
 'enable_seqscan','enable_indexscan','enable_indexonlyscan','enable_bitmapscan',
 'enable_tidscan','enable_sort','enable_incremental_sort','enable_hashagg',
 'enable_material','enable_memoize','enable_nestloop','enable_hashjoin',
 'enable_mergejoin','enable_partition_pruning','jit','plan_cache_mode'
)
ORDER BY name;
SQL

if [ ! -s "$rel_file" ]; then
    echo
    echo "Referenced relation could not be identified automatically from the plan."
    exit 0
fi

section "Referenced Relations (Plan Base Relations)"
cat "$rel_file"

run_relation_report() {
    rel=$1
    title=$2
    sql=$3

    section "$title : $rel"
    printf '%s\n' "$sql" | \
        run_psql -X -P pager=off -v ON_ERROR_STOP=1 -v rel="$rel"
}

SQL_TABLE_INFO='
SELECT c.oid::regclass AS relation,
       pg_get_userbyid(c.relowner) AS owner,
       COALESCE(ts.spcname, dt.spcname) AS tablespace,
       c.relpersistence,
       c.relkind,
       c.reltuples,
       c.relpages,
       c.relallvisible,
       c.relhasindex,
       c.relrowsecurity,
       c.relforcerowsecurity,
       CASE c.relreplident
         WHEN '\''d'\'' THEN '\''DEFAULT'\''
         WHEN '\''n'\'' THEN '\''NOTHING'\''
         WHEN '\''f'\'' THEN '\''FULL'\''
         WHEN '\''i'\'' THEN '\''INDEX'\''
       END AS replica_identity,
       pg_size_pretty(pg_relation_size(c.oid)) AS table_size,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indexes_size,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
LEFT JOIN pg_tablespace ts
  ON ts.oid = NULLIF(c.reltablespace,0)
LEFT JOIN pg_database db
  ON db.datname = current_database()
LEFT JOIN pg_tablespace dt
  ON dt.oid = db.dattablespace
WHERE c.oid=:'\''rel'\''::regclass;
'

SQL_TABLE_STATS='
SELECT schemaname, relname,
       seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
       n_live_tup, n_dead_tup, n_mod_since_analyze,
       n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
       vacuum_count, autovacuum_count, analyze_count, autoanalyze_count
FROM pg_stat_all_tables
WHERE relid=:'\''rel'\''::regclass;
'

SQL_COLUMN_INFO='
SELECT a.attnum AS no,
       a.attname AS column_name,
       format_type(a.atttypid,a.atttypmod) AS data_type,
       NOT a.attnotnull AS nullable,
       pg_get_expr(ad.adbin,ad.adrelid) AS default_value,
       a.attidentity AS identity,
       a.attgenerated AS generated,
       a.attstattarget AS statistics_target
FROM pg_attribute a
LEFT JOIN pg_attrdef ad
  ON ad.adrelid=a.attrelid AND ad.adnum=a.attnum
WHERE a.attrelid=:'\''rel'\''::regclass
  AND a.attnum>0
  AND NOT a.attisdropped
ORDER BY a.attnum;
'

SQL_COLUMN_STATS='
SELECT attname,
       null_frac,
       avg_width,
       n_distinct,
       most_common_vals,
       most_common_freqs,
       histogram_bounds,
       correlation
FROM pg_stats
WHERE schemaname = split_part(:'\''rel'\'','\''.'\'',1)
  AND tablename  = split_part(:'\''rel'\'','\''.'\'',2)
ORDER BY attname;
'

SQL_EXT_STATS='
SELECT schemaname,
       tablename,
       statistics_name,
       attnames,
       exprs,
       kinds,
       n_distinct,
       dependencies
FROM pg_stats_ext
WHERE schemaname = split_part(:'\''rel'\'','\''.'\'',1)
  AND tablename  = split_part(:'\''rel'\'','\''.'\'',2)
ORDER BY statistics_name;
'

SQL_INDEX_INFO='
SELECT i.indexrelid::regclass AS index_name,
       am.amname AS method,
       i.indisunique AS unique,
       i.indisprimary AS primary_key,
       i.indisexclusion AS exclusion,
       i.indisclustered AS clustered,
       i.indisvalid AS valid,
       i.indisready AS ready,
       i.indislive AS live,
       i.indisreplident AS replica_identity,
       i.indnkeyatts AS key_columns,
       i.indnatts-i.indnkeyatts AS include_columns,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
       pg_get_expr(i.indpred,i.indrelid) AS predicate,
       pg_get_expr(i.indexprs,i.indrelid) AS expressions,
       pg_get_indexdef(i.indexrelid) AS definition
FROM pg_index i
JOIN pg_class x ON x.oid=i.indexrelid
JOIN pg_am am ON am.oid=x.relam
WHERE i.indrelid=:'\''rel'\''::regclass
ORDER BY i.indisprimary DESC, i.indisunique DESC, i.indexrelid::regclass::text;
'

SQL_INDEX_COLUMNS='
WITH idx AS (
  SELECT i.indexrelid, i.indrelid, i.indnkeyatts,
         i.indisunique, i.indisprimary,
         i.indkey::int2[] AS indkey
  FROM pg_index i
  WHERE i.indrelid=:'\''rel'\''::regclass
)
SELECT x.indexrelid::regclass AS index_name,
       k.ordinality AS position,
       CASE WHEN k.ordinality<=x.indnkeyatts THEN '\''KEY'\'' ELSE '\''INCLUDE'\'' END AS column_type,
       CASE
         WHEN k.attnum=0 THEN pg_get_indexdef(x.indexrelid,k.ordinality::int,true)
         ELSE a.attname
       END AS column_or_expression,
       x.indisunique,
       x.indisprimary
FROM idx x
CROSS JOIN LATERAL unnest(x.indkey) WITH ORDINALITY AS k(attnum,ordinality)
LEFT JOIN pg_attribute a
  ON a.attrelid=x.indrelid
 AND a.attnum=k.attnum
ORDER BY x.indexrelid::regclass::text,k.ordinality;
'

SQL_INDEX_IO='
SELECT s.indexrelid::regclass AS index_name,
       s.idx_scan,
       s.idx_tup_read,
       s.idx_tup_fetch,
       io.idx_blks_read,
       io.idx_blks_hit,
       round(
         100.0*io.idx_blks_hit/
         NULLIF(io.idx_blks_hit+io.idx_blks_read,0),
         2
       ) AS cache_hit_pct
FROM pg_stat_all_indexes s
LEFT JOIN pg_statio_all_indexes io
  ON io.indexrelid=s.indexrelid
WHERE s.relid=:'\''rel'\''::regclass
ORDER BY s.idx_scan DESC NULLS LAST,s.indexrelid::regclass::text;
'

while IFS= read -r rel
do
    [ -n "$rel" ] || continue

    run_relation_report "$rel" "Table Information" "$SQL_TABLE_INFO"
    run_relation_report "$rel" "Table Statistics" "$SQL_TABLE_STATS"
    run_relation_report "$rel" "Column Information" "$SQL_COLUMN_INFO"
    run_relation_report "$rel" "Column Statistics" "$SQL_COLUMN_STATS"
    run_relation_report "$rel" "Extended Statistics" "$SQL_EXT_STATS"
    run_relation_report "$rel" "Index Information" "$SQL_INDEX_INFO"
    run_relation_report "$rel" "Index Columns" "$SQL_INDEX_COLUMNS"
    run_relation_report "$rel" "Index Usage / I/O" "$SQL_INDEX_IO"
done < "$rel_file"
