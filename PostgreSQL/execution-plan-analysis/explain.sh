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

if ! "$PSQL_BIN" -X -Atqc "SELECT 1;" >/dev/null 2>&1; then
    echo "Initial connection failed."
    printf 'Retry with PGHOST (example: localhost or socket directory): ' >&2
    IFS= read -r _retry_host
    [ -n "$_retry_host" ] || {
        echo "ERROR: PostgreSQL connection failed." >&2
        exit 1
    }
    PGHOST=$_retry_host
    export PGHOST
    "$PSQL_BIN" -X -Atqc "SELECT 1;" >/dev/null 2>&1 || {
        echo "ERROR: PostgreSQL connection failed." >&2
        exit 1
    }
fi

SQL_FILE=${1:-}
if [ -z "$SQL_FILE" ]; then
    printf 'Target SQL file path: ' >&2
    IFS= read -r SQL_FILE
fi
[ -r "$SQL_FILE" ] || {
    echo "ERROR: cannot read SQL file: $SQL_FILE" >&2
    exit 1
}

SERVER_VERSION_NUM=$("$PSQL_BIN" -X -Atqc "SHOW server_version_num") || exit 1
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
    if [ "$SERVER_VERSION_NUM" -ge 160000 ]; then
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

if [ "$ANALYZE" = yes ]; then
    echo
    echo "WARNING: EXPLAIN ANALYZE executes the statement."
    echo "DML은 실제 변경을 발생시킬 수 있으며 Sequence/외부 함수 등은 ROLLBACK으로 복구되지 않을 수 있음."
    printf 'Type EXECUTE to continue: ' >&2
    IFS= read -r confirm
    [ "$confirm" = EXECUTE ] || {
        echo "Cancelled."
        exit 1
    }
fi

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
[ "$GENERIC_PLAN" = yes ] && addopt "GENERIC_PLAN"
[ "$SERIALIZE" = yes ] && addopt "SERIALIZE TEXT"
[ "$MEMORY" = yes ] && addopt "MEMORY"
[ "$SUMMARY" = yes ] && addopt "SUMMARY"
addopt "FORMAT $FORMAT"

tmp="${TMPDIR:-/tmp}/pg_explain_$$.sql"
plan_json="${TMPDIR:-/tmp}/pg_explain_plan_$$.json"
rel_file="${TMPDIR:-/tmp}/pg_explain_rel_$$.txt"
trap 'rm -f "$tmp" "$plan_json" "$rel_file"' EXIT HUP INT TERM

{
    printf 'EXPLAIN (%s)\n' "$opts"
    cat "$SQL_FILE"
    printf '\n'
} > "$tmp"

section "Execution Plan"
echo "Generated: EXPLAIN ($opts)"
"$PSQL_BIN" -X -v ON_ERROR_STOP=1 -f "$tmp" || exit 1

DIAG=$(ask "Show additional Plan diagnostics? yes/no" yes)
[ "$DIAG" = yes ] || exit 0

section "Planner Settings"
"$PSQL_BIN" -X -P pager=off -v ON_ERROR_STOP=1 <<'SQL'
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

{
    printf 'EXPLAIN (VERBOSE, COSTS FALSE, FORMAT JSON)\n'
    cat "$SQL_FILE"
    printf '\n'
} | "$PSQL_BIN" -X -At -v ON_ERROR_STOP=1 > "$plan_json" || {
    echo "WARNING: Could not generate JSON plan for relation extraction." >&2
    exit 0
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
        "$PSQL_BIN" -X -P pager=off -v ON_ERROR_STOP=1 -v rel="$rel"
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
