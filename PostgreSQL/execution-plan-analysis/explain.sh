#!/bin/sh
set -u

SCRIPT_VERSION="1.2.9"
SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
DEFAULT_OUTPUT_DIR="$SCRIPT_DIR/results"
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
[ -x "$PSQL_BIN" ] || { echo "ERROR: psql not found: $PSQL_BIN" >&2; exit 1; }

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
    _v=$(read_conf_value port "$PGDATA/postgresql.conf" 2>/dev/null || true)
    case $_v in ''|*[!0-9]*) ;; *) PGPORT=$_v ;; esac
fi
if [ -z "${PGHOST:-}" ] && [ -n "${PGDATA:-}" ]; then
    _v=$(read_conf_value unix_socket_directories "$PGDATA/postgresql.conf" 2>/dev/null || true)
    case $_v in ''|'*') ;; *) PGHOST=$(printf '%s' "$_v" | awk -F, '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}') ;; esac
fi
if [ -z "${PGHOST:-}" ]; then printf 'PGHOST [local socket/default]: ' >&2; IFS= read -r _v; [ -z "$_v" ] || PGHOST=$_v; fi
if [ -z "${PGPORT:-}" ]; then printf 'PGPORT [5432]: ' >&2; IFS= read -r _v; PGPORT=${_v:-5432}; fi
if [ -z "${PGUSER:-}" ]; then printf 'PGUSER [%s]: ' "${USER:-postgres}" >&2; IFS= read -r _v; PGUSER=${_v:-${USER:-postgres}}; fi
if [ -z "${PGDATABASE:-}" ]; then printf 'PGDATABASE [%s]: ' "$PGUSER" >&2; IFS= read -r _v; PGDATABASE=${_v:-$PGUSER}; fi
export PGPORT PGUSER PGDATABASE
[ -n "${PGHOST:-}" ] && export PGHOST

echo
echo "Connection"
echo "  version  : $SCRIPT_VERSION"
echo "  psql     : $PSQL_BIN"
echo "  host     : ${PGHOST:-default/local socket}"
echo "  port     : $PGPORT"
echo "  user     : $PGUSER"
echo "  database : $PGDATABASE"
echo

work_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/pg_explain.XXXXXXXX") || exit 1
tty_state=
cleanup() {
    [ -z "$tty_state" ] || stty "$tty_state" </dev/tty 2>/dev/null || :
    rm -rf -- "$work_dir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_psql() { "$PSQL_BIN" -w "$@"; }
password_prompted=no
prompt_password_once() {
    [ "$password_prompted" = no ] || return 1
    password_prompted=yes
    tty_state=$(stty -g </dev/tty) || return 1
    printf 'Password for user %s: ' "$PGUSER" >/dev/tty
    stty -echo </dev/tty || return 1
    IFS= read -r _password </dev/tty
    _status=$?
    stty "$tty_state" </dev/tty || return 1
    tty_state=
    printf '\n' >/dev/tty
    [ "$_status" -eq 0 ] || return 1
    (
        umask 077
        printf '*:'
        for _field in "$PGPORT" "$PGDATABASE" "$PGUSER"; do
            printf '%s' "$_field" | sed 's/\\/\\\\/g; s/:/\\:/g'
            printf ':'
        done
        printf '%s' "$_password" | sed 's/\\/\\\\/g; s/:/\\:/g'
        printf '\n'
    ) > "$work_dir/pgpass" || return 1
    unset _password
    chmod 600 "$work_dir/pgpass" || return 1
    unset PGPASSWORD
    PGPASSFILE=$work_dir/pgpass
    export PGPASSFILE
}
check_connection() {
    if LC_ALL=C run_psql -X -Atqc 'SELECT 1;' >/dev/null 2>"$work_dir/connection.err"; then return 0; fi
    if grep -Eq 'no password supplied|password authentication failed' "$work_dir/connection.err" && [ "$password_prompted" = no ]; then
        prompt_password_once || return 1
        run_psql -X -Atqc 'SELECT 1;' >/dev/null
        return $?
    fi
    cat "$work_dir/connection.err" >&2
    return 1
}
if ! check_connection; then
    echo "Initial connection failed."
    printf 'Retry with PGHOST (example: localhost or socket directory): ' >&2
    IFS= read -r _retry_host
    [ -n "$_retry_host" ] || { echo "ERROR: PostgreSQL connection failed." >&2; exit 1; }
    PGHOST=$_retry_host; export PGHOST
    check_connection || { echo "ERROR: PostgreSQL connection failed." >&2; exit 1; }
fi

SQL_FILE=${1:-}
while :; do
    if [ -z "$SQL_FILE" ]; then
        printf 'Target SQL file path (empty to cancel): ' >&2
        IFS= read -r SQL_FILE || exit 1
        [ -n "$SQL_FILE" ] || { echo "Cancelled."; exit 1; }
    fi
    [ -f "$SQL_FILE" ] && [ -r "$SQL_FILE" ] && break
    printf 'ERROR: cannot read SQL file: %s\n' "$SQL_FILE" >&2
    SQL_FILE=
done

SERVER_VERSION_NUM=$(run_psql -X -Atqc 'SHOW server_version_num') || exit 1
case $SERVER_VERSION_NUM in ''|*[!0-9]*) echo "ERROR: invalid server_version_num" >&2; exit 1 ;; esac

ask() {
    prompt=$1; default=$2
    while :; do
        printf '%s [%s]: ' "$prompt" "$default" >&2
        IFS= read -r ans || return 1
        [ -n "$ans" ] || ans=$default
        ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $ans in yes|no) printf '%s' "$ans"; return 0 ;; *) echo "ERROR: enter yes or no." >&2 ;; esac
    done
}
ask_bind_plan_mode() {
    while :; do
        printf 'Prepared plan mode (AUTO/CUSTOM/GENERIC) [AUTO]: ' >&2
        IFS= read -r ans || return 1
        [ -n "$ans" ] || ans=AUTO
        ans=$(printf '%s' "$ans" | tr '[:lower:]' '[:upper:]')
        case $ans in AUTO) printf auto; return 0 ;; CUSTOM) printf force_custom_plan; return 0 ;; GENERIC) printf force_generic_plan; return 0 ;; *) echo "ERROR: enter AUTO, CUSTOM, or GENERIC." >&2 ;; esac
    done
}
section() { echo; echo "============================================================"; echo "$1"; echo "============================================================"; }

json_sql_prefix() {
    _json_file=$1
    _tag="PGPLAN_$$_$(date +%s)"
    while grep -F "\$${_tag}\$" "$_json_file" >/dev/null 2>&1; do _tag="${_tag}X"; done
    printf 'WITH RECURSIVE plan_source AS (SELECT $%s$\n' "$_tag"
    cat "$_json_file"
    printf '\n$%s$::jsonb AS doc),\n' "$_tag"
}

extract_plan_metadata() {
    _json_file=$1; _rel_file=$2; _dml_file=$3
    _meta="$work_dir/meta.out"
    {
        json_sql_prefix "$_json_file"
        cat <<'SQL'
nodes(node) AS (
    SELECT doc->0->'Plan' FROM plan_source
  UNION ALL
    SELECT child
    FROM nodes n
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(n.node->'Plans','[]'::jsonb)) AS c(child)
), rows AS (
    SELECT DISTINCT 'R' AS kind,
           format('%I.%I', node->>'Schema', node->>'Relation Name') AS value
    FROM nodes
    WHERE node ? 'Schema' AND node ? 'Relation Name'
    UNION ALL
    SELECT DISTINCT 'D', node->>'Operation'
    FROM nodes
    WHERE node->>'Operation' IN ('Insert','Update','Delete','Merge')
)
SELECT kind || '|' || value FROM rows ORDER BY kind, value;
SQL
    } | run_psql -X -qAt -v ON_ERROR_STOP=1 > "$_meta" || return 1
    awk -F'|' '$1=="R" {sub(/^[^|]*\|/,""); print}' "$_meta" > "$_rel_file"
    awk -F'|' '$1=="D" {print $2}' "$_meta" > "$_dml_file"
}

render_plan_summary() {
    _json_file=$1
    _rows="$work_dir/plan-summary-rows.tsv"
    _sep=$(printf '\t')
    {
        json_sql_prefix "$_json_file"
        cat <<'SQL'
nodes(path, node, is_last, depth, prefix) AS (
    SELECT ARRAY[]::integer[], doc->0->'Plan', true, 0, ''::text
    FROM plan_source
  UNION ALL
    SELECT n.path || c.ord::integer,
           c.child,
           c.ord = jsonb_array_length(COALESCE(n.node->'Plans','[]'::jsonb)),
           n.depth + 1,
           n.prefix || CASE
               WHEN n.depth = 0 THEN ''
               WHEN n.is_last THEN '    '
               ELSE '|   '
           END
    FROM nodes n
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(n.node->'Plans','[]'::jsonb)) WITH ORDINALITY AS c(child,ord)
), formatted AS (
    SELECT path,
           depth,
           concat(
               prefix,
               CASE WHEN depth=0 THEN '' WHEN is_last THEN '`-- ' ELSE '|-- ' END,
               COALESCE(node->>'Node Type',''),
               CASE WHEN node ? 'Index Name' THEN concat(' using ', node->>'Index Name') ELSE '' END,
               CASE WHEN node ? 'Relation Name' THEN concat(' on ', CASE WHEN node ? 'Schema' THEN concat(node->>'Schema','.') ELSE '' END, node->>'Relation Name') ELSE '' END
           ) AS node_line,
           concat(prefix, CASE WHEN depth=0 THEN '  ' WHEN is_last THEN '    ' ELSE '|   ' END) AS detail_prefix,
           COALESCE(array_to_string(ARRAY(SELECT jsonb_array_elements_text(COALESCE(node->'Sort Key','[]'::jsonb))), ', '), '') AS sort_key,
           COALESCE(node->>'Index Cond','') AS index_cond,
           COALESCE(node->>'Recheck Cond','') AS recheck_cond,
           COALESCE(node->>'Hash Cond','') AS hash_cond,
           COALESCE(node->>'Merge Cond','') AS merge_cond,
           COALESCE(node->>'Join Filter','') AS join_filter,
           COALESCE(node->>'Filter','') AS filter
    FROM nodes
)
SELECT node_line, detail_prefix, sort_key, index_cond, recheck_cond, hash_cond, merge_cond, join_filter, filter
FROM formatted
ORDER BY path;
SQL
    } | run_psql -X -qAt -F "$_sep" -v ON_ERROR_STOP=1 > "$_rows" || return 1

    [ -s "$_rows" ] || {
        echo "ERROR: Plan Tree rows were not generated." >&2
        return 1
    }

    awk -F '\t' '
function clip(s,n) {
    if (n < 20) n=20
    return length(s)<=n ? s : substr(s,1,n-3) "..."
}
function detail(prefix,label,value,    room) {
    if (value=="") return
    room=120-length(prefix)-length(label)-3
    printf "%s%-13s : %s\n", prefix, label, clip(value,room)
}
{
    print $1
    detail($2,"Sort Key",$3)
    detail($2,"Index Cond",$4)
    detail($2,"Recheck Cond",$5)
    detail($2,"Hash Cond",$6)
    detail($2,"Merge Cond",$7)
    detail($2,"Join Filter",$8)
    detail($2,"Filter",$9)
}' "$_rows"
}

build_bind_map() {
    bind_map="$work_dir/bind-map.txt"
    if ! {
        cat "$prepare_file"
        cat <<'SQL'
BEGIN;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS map_timeout \gset
SET plan_cache_mode = force_generic_plan;
CREATE TEMP TABLE explain_bind_plan (plan jsonb) ON COMMIT DROP;
DO $map$
DECLARE args text; result json;
BEGIN
  SELECT string_agg('NULL', ', ' ORDER BY n) INTO args
  FROM pg_prepared_statements p, generate_series(1, cardinality(p.parameter_types)) n
  WHERE p.name='pg_explain_target';
  EXECUTE 'EXPLAIN (VERBOSE, COSTS FALSE, FORMAT JSON) EXECUTE pg_explain_target' || CASE WHEN args IS NULL THEN '' ELSE '('||args||')' END INTO result;
  INSERT INTO explain_bind_plan VALUES (result::jsonb);
END $map$;
WITH RECURSIVE nodes(node) AS (
 SELECT plan->0->'Plan' FROM explain_bind_plan
 UNION ALL SELECT child FROM nodes, LATERAL jsonb_array_elements(COALESCE(node->'Plans','[]'::jsonb)) child
), rels AS (
 SELECT DISTINCT node->>'Alias' alias, format('%I.%I',node->>'Schema',node->>'Relation Name') relation,
        to_regclass(format('%I.%I',node->>'Schema',node->>'Relation Name')) relid
 FROM nodes WHERE node ? 'Schema' AND node ? 'Relation Name' AND node ? 'Alias'
), expr AS (
 SELECT DISTINCT e.value txt FROM nodes, LATERAL jsonb_each_text(node) e
 WHERE e.key IN ('Filter','Index Cond','Recheck Cond','Hash Cond','Merge Cond','Join Filter')
), refs AS (
 SELECT (regexp_matches(txt,'([a-zA-Z_][a-zA-Z0-9_$]*)\.([a-zA-Z_][a-zA-Z0-9_$]*)[^$]*\$([1-9][0-9]*)','g')) m FROM expr
), cand AS (
 SELECT m[3] parameter, r.relid, m[2] column_name
 FROM refs JOIN rels r ON r.alias=m[1]
 JOIN pg_attribute a ON a.attrelid=r.relid AND a.attname=m[2] AND a.attnum>0 AND NOT a.attisdropped
)
SELECT parameter, format('%I.%I',n.nspname,c.relname), column_name
FROM cand x JOIN pg_class c ON c.oid=x.relid JOIN pg_namespace n ON n.oid=c.relnamespace
ORDER BY parameter::int,2,3;
ROLLBACK;
SQL
    } | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 -v sample_timeout="$BIND_SAMPLE_TIMEOUT" > "$bind_map" 2>/dev/null; then : > "$bind_map"; fi
}

build_bind_type_map() {
    bind_type_map="$work_dir/bind-type-map.txt"
    {
        cat "$prepare_file"
        cat <<'SQL'
SELECT n, p.parameter_types[n]::text,
       CASE WHEN COALESCE(bt.typcategory,pt.typcategory)='S' THEN 'yes' ELSE 'no' END
FROM pg_prepared_statements p
CROSS JOIN LATERAL generate_subscripts(p.parameter_types,1) n
JOIN pg_type pt ON pt.oid=p.parameter_types[n]::oid
LEFT JOIN pg_type bt ON bt.oid=NULLIF(pt.typbasetype,0)
WHERE p.name='pg_explain_target' ORDER BY n;
SQL
    } | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 > "$bind_type_map" || return 1
}

show_bind_candidates() {
    bind_default_available=no; bind_default_value=
    bind_type=$(awk -F'|' -v n="$bind_index" '$1==n{print $2;exit}' "$bind_type_map")
    bind_empty_string_allowed=$(awk -F'|' -v n="$bind_index" '$1==n{print $3;exit}' "$bind_type_map")
    [ -n "$bind_type" ] || bind_type=unknown
    [ -n "$bind_empty_string_allowed" ] || bind_empty_string_allowed=no
    printf 'Parameter $%s type: %s\n' "$bind_index" "$bind_type"
    bind_candidate_file="$work_dir/bind-candidates-$bind_index.txt"
    awk -F'|' -v n="$bind_index" '$1==n{print $2"|"$3}' "$bind_map" | sort -u > "$bind_candidate_file"
    count=$(awk 'END{print NR+0}' "$bind_candidate_file")
    sample_relation=; sample_column=
    if [ "$count" -eq 1 ]; then
        line=$(sed -n '1p' "$bind_candidate_file"); sample_relation=${line%%|*}; sample_column=${line#*|}
        printf 'Auto-detected $%s -> %s / %s\n' "$bind_index" "$sample_relation" "$sample_column"
    elif [ "$count" -gt 1 ]; then
        echo "Multiple candidate relations found for parameter \$$bind_index:"
        n=1; while IFS='|' read -r r c; do printf '  %s) %s / %s\n' "$n" "$r" "$c"; n=$((n+1)); done < "$bind_candidate_file"
        printf 'Select candidate for $%s [1]: ' "$bind_index" >&2; IFS= read -r choice; [ -n "$choice" ] || choice=1
        line=$(sed -n "${choice}p" "$bind_candidate_file"); sample_relation=${line%%|*}; sample_column=${line#*|}
    else
        echo "No automatic relation candidate found for this parameter." >&2
    fi
    if [ -z "$sample_relation" ]; then
        printf 'Candidate source table for $%s (schema.table, empty to skip): ' "$bind_index" >&2; IFS= read -r sample_relation
        [ -n "$sample_relation" ] || return 0
        printf 'Candidate source column (exact name, empty to skip): ' >&2; IFS= read -r sample_column
        [ -n "$sample_column" ] || return 0
    fi
    echo
    printf 'Table value candidates for $%s (up to %s distinct values; not historical bind values)\n' "$bind_index" "$BIND_SAMPLE_LIMIT"
    run_psql -X -q -P pager=off -v ON_ERROR_STOP=1 -v sample_relation="$sample_relation" -v sample_column="$sample_column" -v sample_limit="$BIND_SAMPLE_LIMIT" <<'SQL' || return 0
SELECT format('SELECT DISTINCT %1$I AS candidate_value FROM %2$s WHERE %1$I IS NOT NULL LIMIT %3$s', :'sample_column', :'sample_relation'::regclass, :'sample_limit'::integer) \gexec
SQL
    bind_default_value=$(run_psql -X -qAt -v ON_ERROR_STOP=1 -v sample_relation="$sample_relation" -v sample_column="$sample_column" <<'SQL'
SELECT format('SELECT DISTINCT %1$I::text FROM %2$s WHERE %1$I IS NOT NULL LIMIT 1', :'sample_column', :'sample_relation'::regclass) \gexec
SQL
    ) || bind_default_value=
    if [ -n "$bind_default_value" ]; then bind_default_available=yes; printf 'Default for $%s: %s\n' "$bind_index" "$bind_default_value"; fi
    echo 'Candidates are distinct current table values and do not apply the original SQL filters.'
}

BIND=$(ask 'Use bind parameters ($1, $2, ...)? yes/no' no) || exit 1
prepare_file="$work_dir/prepare.sql"; execute_file="$work_dir/execute.sql"; bind_values_file="$work_dir/bind-values-used.txt"; : > "$bind_values_file"; BIND_PLAN_MODE=auto
if [ "$BIND" = yes ]; then
    printf 'Parameter types, comma-separated [auto infer]: ' >&2; IFS= read -r bind_types
    { printf 'SET standard_conforming_strings = on;\nPREPARE pg_explain_target'; [ -z "$bind_types" ] || printf ' (%s)' "$bind_types"; printf ' AS\n'; cat "$SQL_FILE"; printf '\n;\n'; } > "$prepare_file"
    BIND_COUNT=$({ cat "$prepare_file"; echo "SELECT cardinality(parameter_types) FROM pg_prepared_statements WHERE name='pg_explain_target';"; } | run_psql -X -qAt -v ON_ERROR_STOP=1) || { echo "ERROR: Could not prepare SQL." >&2; exit 1; }
    case $BIND_COUNT in ''|*[!0-9]*) echo "ERROR: invalid parameter count" >&2; exit 1 ;; esac
    BIND_SAMPLE_LIMIT=${BIND_SAMPLE_LIMIT:-3}; BIND_SAMPLE_TIMEOUT=${BIND_SAMPLE_TIMEOUT:-5s}
    build_bind_map; build_bind_type_map || exit 1
    echo "Bind parameter count: $BIND_COUNT"
    echo 'Enter each value as plain text (no SQL quotes). \N means SQL NULL. If a default is shown, Enter accepts it.'
    printf 'EXECUTE pg_explain_target' > "$execute_file"
    [ "$BIND_COUNT" -eq 0 ] || printf '(' >> "$execute_file"
    bind_index=1
    while [ "$bind_index" -le "$BIND_COUNT" ]; do
        show_bind_candidates
        while :; do
            if [ "$bind_default_available" = yes ]; then printf 'Value for $%s [%s]: ' "$bind_index" "$bind_default_value" >&2; else printf 'Value for $%s (\\N for NULL): ' "$bind_index" >&2; fi
            IFS= read -r bind_value
            if [ -z "$bind_value" ] && [ "$bind_default_available" = yes ]; then bind_value=$bind_default_value; fi
            if [ -z "$bind_value" ] && [ "$bind_empty_string_allowed" != yes ]; then echo "ERROR: value required for $bind_type." >&2; continue; fi
            break
        done
        [ "$bind_index" -eq 1 ] || printf ', ' >> "$execute_file"
        if [ "$bind_value" = '\N' ]; then printf 'NULL' >> "$execute_file"; display=NULL; else printf "'" >> "$execute_file"; printf '%s' "$bind_value" | sed "s/'/''/g" >> "$execute_file"; printf "'" >> "$execute_file"; display=${bind_value:-<empty string>}; fi
        printf '$%s [%s] = %s\n' "$bind_index" "$bind_type" "$display" >> "$bind_values_file"
        bind_index=$((bind_index+1))
    done
    [ "$BIND_COUNT" -eq 0 ] || printf ')' >> "$execute_file"; printf ';\n' >> "$execute_file"
    echo; echo "Bind Values Used"; echo "----------------"; cat "$bind_values_file"; echo
    BIND_PLAN_MODE=$(ask_bind_plan_mode) || exit 1
fi

ANALYZE=$(ask 'Use ANALYZE? yes/no' no)
if [ "$ANALYZE" = yes ]; then
    echo
    echo "WARNING: EXPLAIN ANALYZE executes the target SQL."
    echo "         The target SQL will actually be executed."
    echo
fi
VERBOSE=$(ask 'Use VERBOSE? yes/no' no)
COSTS=$(ask 'Use COSTS? yes/no' yes)
SETTINGS=$(ask 'Use SETTINGS? yes/no' yes)
BUFFERS=no; WAL=no; TIMING=no; GENERIC_PLAN=no; SERIALIZE=no; MEMORY=no
if [ "$ANALYZE" = yes ]; then
    BUFFERS=$(ask 'Use BUFFERS? yes/no' yes)
    [ "$SERVER_VERSION_NUM" -lt 130000 ] || WAL=$(ask 'Use WAL? yes/no' no)
    TIMING=$(ask 'Use TIMING? yes/no' yes)
    [ "$SERVER_VERSION_NUM" -lt 170000 ] || SERIALIZE=$(ask 'Use SERIALIZE TEXT? yes/no' no)
else
    if [ "$BIND" = no ] && [ "$SERVER_VERSION_NUM" -ge 160000 ]; then GENERIC_PLAN=$(ask 'Use GENERIC_PLAN? yes/no' no); fi
fi
[ "$SERVER_VERSION_NUM" -lt 170000 ] || MEMORY=$(ask 'Use MEMORY? yes/no' no)
SUMMARY=$(ask 'Use SUMMARY? yes/no' yes)

base_plan_opts=""
add_opt() { [ -z "$base_plan_opts" ] && base_plan_opts="$1" || base_plan_opts="$base_plan_opts, $1"; }
[ "$ANALYZE" = yes ] && add_opt 'ANALYZE TRUE'
[ "$VERBOSE" = yes ] && add_opt 'VERBOSE TRUE' || add_opt 'VERBOSE FALSE'
[ "$COSTS" = yes ] && add_opt 'COSTS TRUE' || add_opt 'COSTS FALSE'
[ "$SETTINGS" = yes ] && add_opt 'SETTINGS TRUE' || add_opt 'SETTINGS FALSE'
if [ "$ANALYZE" = yes ]; then
    [ "$BUFFERS" = yes ] && add_opt 'BUFFERS TRUE' || add_opt 'BUFFERS FALSE'
    [ "$SERVER_VERSION_NUM" -lt 130000 ] || { [ "$WAL" = yes ] && add_opt 'WAL TRUE' || add_opt 'WAL FALSE'; }
    [ "$TIMING" = yes ] && add_opt 'TIMING TRUE' || add_opt 'TIMING FALSE'
    if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then [ "$SERIALIZE" = yes ] && add_opt 'SERIALIZE TEXT' || add_opt 'SERIALIZE NONE'; fi
fi
[ "$GENERIC_PLAN" = yes ] && add_opt 'GENERIC_PLAN TRUE'
if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then [ "$MEMORY" = yes ] && add_opt 'MEMORY TRUE' || add_opt 'MEMORY FALSE'; fi
[ "$SUMMARY" = yes ] && add_opt 'SUMMARY TRUE' || add_opt 'SUMMARY FALSE'
raw_text_opts="$base_plan_opts, FORMAT TEXT"

tree_plan_opts=""
add_tree_opt() { [ -z "$tree_plan_opts" ] && tree_plan_opts="$1" || tree_plan_opts="$tree_plan_opts, $1"; }
[ "$VERBOSE" = yes ] && add_tree_opt 'VERBOSE TRUE' || add_tree_opt 'VERBOSE FALSE'
[ "$COSTS" = yes ] && add_tree_opt 'COSTS TRUE' || add_tree_opt 'COSTS FALSE'
[ "$SETTINGS" = yes ] && add_tree_opt 'SETTINGS TRUE' || add_tree_opt 'SETTINGS FALSE'
[ "$GENERIC_PLAN" = yes ] && add_tree_opt 'GENERIC_PLAN TRUE'
if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then [ "$MEMORY" = yes ] && add_tree_opt 'MEMORY TRUE' || add_tree_opt 'MEMORY FALSE'; fi
[ "$SUMMARY" = yes ] && add_tree_opt 'SUMMARY TRUE' || add_tree_opt 'SUMMARY FALSE'
tree_json_opts="$tree_plan_opts, FORMAT JSON"

tree_plan_json="$work_dir/tree-plan.json"; rel_file="$work_dir/relations.txt"; dml_file="$work_dir/dml.txt"; plan_error="$work_dir/plan.err"; plan_summary="$work_dir/summary.txt"; raw_plan_output="$work_dir/raw-plan.txt"; tmp="$work_dir/explain.sql"
table_before="$work_dir/table.before"; table_after="$work_dir/table.after"; index_before="$work_dir/index.before"; index_after="$work_dir/index.after"
RESULT_DIR=${EXPLAIN_RESULT_DIR:-$DEFAULT_OUTPUT_DIR}; mkdir -p "$RESULT_DIR" || exit 1
result_database=$(printf '%s' "$PGDATABASE" | tr -c '[:alnum:]_.-' '_'); RESULT_FILE="$RESULT_DIR/explain_${result_database}_$(date '+%Y%m%d_%H%M%S').log"

emit_plan() {
    opts=$1
    if [ "$BIND" = yes ]; then
        cat "$prepare_file"
        printf 'SET plan_cache_mode = %s;\nEXPLAIN (%s)\n' "$BIND_PLAN_MODE" "$opts"
        cat "$execute_file"
        printf '\n'
    else
        printf 'EXPLAIN (%s)\n' "$opts"
        cat "$SQL_FILE"
        printf '\n;\n'
    fi
}

emit_plan "$tree_json_opts" | run_psql -X -qAt -v ON_ERROR_STOP=1 > "$tree_plan_json" 2>"$plan_error" || { cat "$plan_error" >&2; exit 1; }
extract_plan_metadata "$tree_plan_json" "$rel_file" "$dml_file" || { echo "ERROR: PostgreSQL JSON metadata parsing failed." >&2; exit 1; }
DML_OPERATION=$(sed -n '1p' "$dml_file")
render_plan_summary "$tree_plan_json" > "$plan_summary" 2>"$plan_error" || { cat "$plan_error" >&2; echo "ERROR: Plan Tree Summary generation failed." >&2; exit 1; }

snapshot_stats() {
    tf=$1; inf=$2; : > "$tf"; : > "$inf"
    while IFS= read -r rel; do [ -n "$rel" ] || continue
        printf "SELECT relid,schemaname||'.'||relname,COALESCE(seq_scan,0),COALESCE(seq_tup_read,0),COALESCE(idx_scan,0),COALESCE(idx_tup_fetch,0),COALESCE(n_tup_ins,0),COALESCE(n_tup_upd,0),COALESCE(n_tup_del,0),COALESCE(n_tup_hot_upd,0) FROM pg_stat_all_tables WHERE relid=:'rel'::regclass;\n" | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 -v rel="$rel" >> "$tf"
        printf "SELECT s.indexrelid,s.indexrelid::regclass::text,COALESCE(s.idx_scan,0),COALESCE(s.idx_tup_read,0),COALESCE(s.idx_tup_fetch,0),COALESCE(io.idx_blks_read,0),COALESCE(io.idx_blks_hit,0) FROM pg_stat_all_indexes s LEFT JOIN pg_statio_all_indexes io ON io.indexrelid=s.indexrelid WHERE s.relid=:'rel'::regclass ORDER BY s.indexrelid;\n" | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 -v rel="$rel" >> "$inf"
    done < "$rel_file"
}

print_table_delta() {
    [ -s "$table_before" ] && [ -s "$table_after" ] || return 0
    awk -F'|' 'NR==FNR {for(i=3;i<=10;i++) b[$1,i]=$i; name[$1]=$2; next} {id=$1; printf "\n%s\n",name[id]; printf "%-24s %15s %15s %15s\n","metric","before","after","delta"; printf "%-24s %15s %15s %15s\n","------------------------","---------------","---------------","---------------"; label[3]="seq_scan";label[4]="seq_tup_read";label[5]="idx_scan";label[6]="idx_tup_fetch";label[7]="n_tup_ins";label[8]="n_tup_upd";label[9]="n_tup_del";label[10]="n_tup_hot_upd"; for(i=3;i<=10;i++){before=(b[id,i]==""?0:b[id,i]);after=$i;delta=after-before;printf "%-24s %15s %15s %+15d\n",label[i],before,after,delta}}' "$table_before" "$table_after"
}

print_index_delta() {
    [ -s "$index_before" ] && [ -s "$index_after" ] || return 0
    awk -F'|' 'NR==FNR {for(i=3;i<=7;i++) b[$1,i]=$i; name[$1]=$2; next} {id=$1; printf "\n%s\n",name[id]; printf "%-24s %15s %15s %15s\n","metric","before","after","delta"; printf "%-24s %15s %15s %15s\n","------------------------","---------------","---------------","---------------"; label[3]="idx_scan";label[4]="idx_tup_read";label[5]="idx_scan";label[4]="idx_tup_read";label[5]="idx_tup_fetch";label[6]="idx_blks_read";label[7]="idx_blks_hit"; for(i=3;i<=7;i++){before=(b[id,i]==""?0:b[id,i]);after=$i;delta=after-before;printf "%-24s %15s %15s %+15d\n",label[i],before,after,delta}}' "$index_before" "$index_after"
}

if [ "$ANALYZE" = yes ]; then
    echo
    [ -z "$DML_OPERATION" ] || echo "DML detected: $DML_OPERATION"
    echo "Safety     : BEGIN -> EXPLAIN ANALYZE -> ROLLBACK"
    printf 'Type EXECUTE to continue: ' >&2; IFS= read -r confirm; [ "$confirm" = EXECUTE ] || { echo "Cancelled."; exit 1; }
    [ ! -s "$rel_file" ] || snapshot_stats "$table_before" "$index_before"
    { printf 'BEGIN;\n'; emit_plan "$raw_text_opts"; printf 'ROLLBACK;\n'; } > "$tmp"
else
    emit_plan "$raw_text_opts" > "$tmp"
fi

{
 echo "PostgreSQL execution plan analysis"; echo "script_version=$SCRIPT_VERSION"; echo "database=$PGDATABASE"; echo "sql_file=$SQL_FILE"; echo
} > "$RESULT_FILE"

section "Execution Plan Summary" | tee -a "$RESULT_FILE"
cat "$plan_summary" | tee -a "$RESULT_FILE"

if ! run_psql -X -qAt -P pager=off -v ON_ERROR_STOP=1 -f "$tmp" > "$raw_plan_output" 2>"$plan_error"; then
    cat "$plan_error" | tee -a "$RESULT_FILE" >&2
    echo "ERROR: Raw execution plan generation failed." | tee -a "$RESULT_FILE" >&2
    exit 1
fi

if [ "$ANALYZE" = yes ]; then
    section "Execution Plan Raw (TEXT / Actual)" | tee -a "$RESULT_FILE"
else
    section "Execution Plan Raw (TEXT / Planned)" | tee -a "$RESULT_FILE"
fi
cat "$raw_plan_output" | tee -a "$RESULT_FILE"

if [ "$ANALYZE" = yes ] && [ -s "$rel_file" ]; then
    snapshot_stats "$table_after" "$index_after"
    section "Table Statistics Delta" | tee -a "$RESULT_FILE"
    print_table_delta | tee -a "$RESULT_FILE"
    section "Index Statistics / I/O Delta" | tee -a "$RESULT_FILE"
    print_index_delta | tee -a "$RESULT_FILE"
fi

echo "Current result saved: $RESULT_FILE"
DIAG=$(ask 'Show additional Plan diagnostics? yes/no' yes)
if [ "$DIAG" = yes ] && [ -s "$rel_file" ]; then
    section "Referenced Relations" | tee -a "$RESULT_FILE"; cat "$rel_file" | tee -a "$RESULT_FILE"
    while IFS= read -r rel; do [ -n "$rel" ] || continue
        section "Table / Index Diagnostic : $rel" | tee -a "$RESULT_FILE"
        run_psql -X -P pager=off -P format=wrapped -P columns=160 -v ON_ERROR_STOP=1 -v rel="$rel" <<'SQL' | tee -a "$RESULT_FILE"
SELECT c.oid::regclass relation, c.reltuples, c.relpages, pg_size_pretty(pg_total_relation_size(c.oid)) total_size
FROM pg_class c WHERE c.oid=:'rel'::regclass;
SELECT indexrelid::regclass index_name, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_all_indexes WHERE relid=:'rel'::regclass ORDER BY idx_scan DESC NULLS LAST;
SQL
    done < "$rel_file"
fi

echo "Final result file: $RESULT_FILE" | tee -a "$RESULT_FILE"
