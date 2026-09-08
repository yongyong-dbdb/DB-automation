#!/bin/sh
set -u

SCRIPT_VERSION="1.1.8"
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

    while :
    do
        printf '%s [%s]: ' "$prompt" "$default" >&2
        IFS= read -r ans || {
            echo "ERROR: input stream closed." >&2
            return 1
        }

        [ -n "$ans" ] || ans=$default
        ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        case $ans in
            yes|no)
                printf '%s' "$ans"
                return 0
                ;;
            *)
                echo "ERROR: enter yes or no. Please retry." >&2
                ;;
        esac
    done
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

build_bind_map() {
    bind_map="$work_dir/bind-map.txt"
    if ! {
        cat "$prepare_file"
        cat <<'BIND_MAP_SQL'
BEGIN;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS map_timeout
\gset
SET plan_cache_mode = force_generic_plan;
CREATE TEMP TABLE explain_bind_plan (plan jsonb) ON COMMIT DROP;
DO $map$
DECLARE
    args text;
    result json;
BEGIN
    SELECT string_agg('NULL', ', ' ORDER BY n)
      INTO args
      FROM pg_prepared_statements p,
           generate_series(1, cardinality(p.parameter_types)) n
     WHERE p.name = 'pg_explain_target';
    EXECUTE 'EXPLAIN (VERBOSE, COSTS FALSE, FORMAT JSON) EXECUTE pg_explain_target'
         || CASE WHEN args IS NULL THEN '' ELSE '(' || args || ')' END
      INTO result;
    INSERT INTO explain_bind_plan VALUES (result::jsonb);
END
$map$;
WITH RECURSIVE nodes(node) AS (
    SELECT plan->0->'Plan' FROM explain_bind_plan
    UNION ALL
    SELECT child FROM nodes,
         LATERAL jsonb_array_elements(COALESCE(node->'Plans', '[]'::jsonb)) child
), relations AS (
    SELECT DISTINCT node->>'Alias' AS alias,
           format('%I.%I', node->>'Schema', node->>'Relation Name') AS relation,
           to_regclass(format('%I.%I', node->>'Schema', node->>'Relation Name')) AS relid
    FROM nodes
    WHERE node ? 'Schema' AND node ? 'Relation Name' AND node ? 'Alias'
), expressions AS (
    SELECT DISTINCT term
    FROM nodes, LATERAL jsonb_each_text(node) e,
         LATERAL regexp_split_to_table(e.value, '\s+(?:AND|OR)\s+') term
    WHERE e.key IN ('Filter', 'Index Cond', 'Recheck Cond', 'Hash Cond', 'Merge Cond', 'Join Filter')
), patterns AS (
    SELECT '(?:[a-z_][a-z_0-9$]*|"(?:[^"]|"")+")' AS ident,
           '(?:::(?:text|integer|bigint|smallint|numeric|boolean|date|uuid|character varying|double precision))?' AS cast_pattern
), qualified_matches AS (
    SELECT regexp_match(term,
      '^\s*\(*\s*(' || ident || '\.' || ident || ')\)*' || cast_pattern ||
      '\)*\s*(?:=|<>|!=|<=|>=|<|>|~~\*?|!~~\*?)\s*\(*\$([1-9][0-9]*)\)*' || cast_pattern || '\)*\s*$') AS m,
      false AS reversed
    FROM expressions, patterns
    UNION ALL
    SELECT regexp_match(term,
      '^\s*\(*\$([1-9][0-9]*)\)*' || cast_pattern ||
      '\)*\s*(?:=|<>|!=|<=|>=|<|>)\s*\(*(' || ident || '\.' || ident || ')\)*' || cast_pattern || '\)*\s*$'),
      true
    FROM expressions, patterns
), qualified_refs AS (
    SELECT CASE WHEN reversed THEN m[1] ELSE m[2] END AS parameter,
           parse_ident(CASE WHEN reversed THEN m[2] ELSE m[1] END) AS names
    FROM qualified_matches WHERE m IS NOT NULL
), unqualified_matches AS (
    SELECT regexp_match(term,
      '^\s*\(*\s*(' || ident || ')\)*' || cast_pattern ||
      '\)*\s*(?:=|<>|!=|<=|>=|<|>|~~\*?|!~~\*?)\s*\(*\$([1-9][0-9]*)\)*' || cast_pattern || '\)*\s*$') AS m,
      false AS reversed
    FROM expressions, patterns
    UNION ALL
    SELECT regexp_match(term,
      '^\s*\(*\$([1-9][0-9]*)\)*' || cast_pattern ||
      '\)*\s*(?:=|<>|!=|<=|>=|<|>)\s*\(*(' || ident || ')\)*' || cast_pattern || '\)*\s*$'),
      true
    FROM expressions, patterns
), unqualified_refs AS (
    SELECT CASE WHEN reversed THEN m[1] ELSE m[2] END AS parameter,
           (parse_ident(CASE WHEN reversed THEN m[2] ELSE m[1] END))[1] AS column_name
    FROM unqualified_matches WHERE m IS NOT NULL
), direct_candidates AS (
    SELECT DISTINCT q.parameter, r.relid, q.names[2] AS column_name, 1 AS priority
    FROM qualified_refs q
    JOIN relations r ON r.alias = q.names[1]
    JOIN pg_attribute a ON a.attrelid = r.relid
                       AND a.attname = q.names[2]
                       AND a.attnum > 0 AND NOT a.attisdropped
), unqualified_candidates AS (
    SELECT DISTINCT u.parameter, r.relid, u.column_name, 2 AS priority
    FROM unqualified_refs u
    CROSS JOIN relations r
    JOIN pg_attribute a ON a.attrelid = r.relid
                       AND a.attname = u.column_name
                       AND a.attnum > 0 AND NOT a.attisdropped
), all_candidates AS (
    SELECT * FROM direct_candidates
    UNION ALL
    SELECT * FROM unqualified_candidates
), normalized AS (
    SELECT DISTINCT c.parameter,
           CASE WHEN pc.relispartition THEN pg_partition_root(c.relid) ELSE c.relid END AS normalized_relid,
           c.column_name,
           c.priority
    FROM all_candidates c
    JOIN pg_class pc ON pc.oid = c.relid
), best_priority AS (
    SELECT parameter, min(priority) AS priority
    FROM normalized
    GROUP BY parameter
)
SELECT n.parameter,
       format('%I.%I', ns.nspname, cls.relname) AS relation,
       n.column_name,
       n.priority
FROM normalized n
JOIN best_priority b USING (parameter, priority)
JOIN pg_class cls ON cls.oid = n.normalized_relid
JOIN pg_namespace ns ON ns.oid = cls.relnamespace
WHERE format('%I.%I', ns.nspname, cls.relname) !~ E'[|\n\r]'
  AND n.column_name !~ E'[|\n\r]'
ORDER BY n.parameter::integer, n.priority, relation, n.column_name;
ROLLBACK;
BIND_MAP_SQL
    } | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -v sample_timeout="$BIND_SAMPLE_TIMEOUT" > "$bind_map" 2>"$work_dir/bind-map.err"; then
        : > "$bind_map"
        echo 'Automatic bind-column mapping unavailable; manual selection will be offered.' >&2
    fi
}

build_bind_constant_map() {
    bind_constant_map="$work_dir/bind-constant-map.txt"
    if ! {
        cat "$prepare_file"
        cat <<'BIND_CONSTANT_SQL'
BEGIN;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS map_timeout
\gset
SET plan_cache_mode = force_generic_plan;
CREATE TEMP TABLE explain_bind_constant_plan (plan jsonb) ON COMMIT DROP;
DO $map$
DECLARE
    args text;
    result json;
BEGIN
    SELECT string_agg('NULL', ', ' ORDER BY n)
      INTO args
      FROM pg_prepared_statements p,
           generate_series(1, cardinality(p.parameter_types)) n
     WHERE p.name = 'pg_explain_target';
    EXECUTE 'EXPLAIN (VERBOSE, COSTS FALSE, FORMAT JSON) EXECUTE pg_explain_target'
         || CASE WHEN args IS NULL THEN '' ELSE '(' || args || ')' END
      INTO result;
    INSERT INTO explain_bind_constant_plan VALUES (result::jsonb);
END
$map$;
WITH RECURSIVE nodes(node) AS (
    SELECT plan->0->'Plan' FROM explain_bind_constant_plan
    UNION ALL
    SELECT child FROM nodes,
         LATERAL jsonb_array_elements(COALESCE(node->'Plans', '[]'::jsonb)) child
), expressions AS (
    SELECT DISTINCT term
    FROM nodes, LATERAL jsonb_each_text(node) e,
         LATERAL regexp_split_to_table(e.value, '\s+(?:AND|OR)\s+') term
    WHERE e.key IN ('Filter', 'Index Cond', 'Recheck Cond', 'Hash Cond', 'Merge Cond', 'Join Filter', 'One-Time Filter')
), patterns AS (
    SELECT '(?:NULL|true|false|[-+]?[0-9]+(?:\.[0-9]+)?|''(?:[^'']|'''')*'')' AS literal,
           '(?:::(?:text|integer|bigint|smallint|numeric|boolean|date|uuid|character varying|double precision))?' AS cast_pattern
), matches AS (
    SELECT regexp_match(term,
      '^\s*\(*\s*(' || literal || ')\)*' || cast_pattern ||
      '\)*\s*(?:=|<>|!=|<=|>=|<|>)\s*\(*\$([1-9][0-9]*)\)*' || cast_pattern || '\)*\s*$') AS m,
      false AS reversed
    FROM expressions, patterns
    UNION ALL
    SELECT regexp_match(term,
      '^\s*\(*\$([1-9][0-9]*)\)*' || cast_pattern ||
      '\)*\s*(?:=|<>|!=|<=|>=|<|>)\s*\(*(' || literal || ')\)*' || cast_pattern || '\)*\s*$'),
      true
    FROM expressions, patterns
), normalized AS (
    SELECT CASE WHEN reversed THEN m[1] ELSE m[2] END AS parameter,
           CASE WHEN reversed THEN m[2] ELSE m[1] END AS literal
    FROM matches
    WHERE m IS NOT NULL
), literal_values AS (
    SELECT parameter,
           CASE
             WHEN literal = 'NULL' THEN '\N'
             WHEN literal LIKE '''%''' THEN replace(substr(literal, 2, length(literal) - 2), '''''', '''')
             ELSE literal
           END AS default_value
    FROM normalized
), unique_value AS (
    SELECT parameter, min(default_value) AS default_value
    FROM literal_values
    GROUP BY parameter
    HAVING count(DISTINCT default_value) = 1
)
SELECT parameter, default_value
FROM unique_value
WHERE default_value !~ E'[|\n\r]'
ORDER BY parameter::integer;
ROLLBACK;
BIND_CONSTANT_SQL
    } | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -v sample_timeout="$BIND_SAMPLE_TIMEOUT" > "$bind_constant_map" 2>"$work_dir/bind-constant-map.err"; then
        : > "$bind_constant_map"
    fi
}

build_bind_type_map() {
    bind_type_map="$work_dir/bind-type-map.txt"
    if ! {
        cat "$prepare_file"
        cat <<'BIND_TYPE_SQL'
SELECT n,
       p.parameter_types[n]::text AS parameter_type,
       CASE
         WHEN COALESCE(base_type.typcategory, param_type.typcategory) = 'S' THEN 'yes'
         ELSE 'no'
       END AS empty_string_allowed
FROM pg_prepared_statements p
CROSS JOIN LATERAL generate_subscripts(p.parameter_types, 1) AS n
JOIN pg_type param_type
  ON param_type.oid = p.parameter_types[n]::oid
LEFT JOIN pg_type base_type
  ON base_type.oid = NULLIF(param_type.typbasetype, 0)
WHERE p.name = 'pg_explain_target'
ORDER BY n;
BIND_TYPE_SQL
    } | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 > "$bind_type_map"; then
        echo 'ERROR: Could not determine bind parameter types.' >&2
        exit 1
    fi
}

show_bind_candidates() {
    bind_default_available=no
    bind_default_value=
    bind_type=$(awk -F'|' -v n="$bind_index" '$1 == n {print $2; exit}' "$bind_type_map")
    bind_empty_string_allowed=$(awk -F'|' -v n="$bind_index" '$1 == n {print $3; exit}' "$bind_type_map")
    [ -n "$bind_type" ] || bind_type=unknown
    [ -n "$bind_empty_string_allowed" ] || bind_empty_string_allowed=no

    printf 'Parameter $%s type: %s\n' "$bind_index" "$bind_type"

    constant_line=$(awk -F'|' -v n="$bind_index" '$1 == n {print; exit}' "$bind_constant_map")
    if [ -n "$constant_line" ]; then
        bind_default_value=${constant_line#*|}
        bind_default_available=yes
        printf 'Auto-detected $%s -> SQL constant default: %s\n' "$bind_index" "$bind_default_value"
        return 0
    fi

    bind_candidate_file="$work_dir/bind-candidates-$bind_index.txt"
    awk -F'|' -v n="$bind_index" '$1 == n {print $2 "|" $3}' "$bind_map" | sort -u > "$bind_candidate_file"
    bind_candidate_count=$(awk 'END {print NR+0}' "$bind_candidate_file")

    sample_relation=
    sample_column=

    if [ "$bind_candidate_count" -eq 1 ]; then
        candidate_line=$(sed -n '1p' "$bind_candidate_file")
        sample_relation=${candidate_line%%|*}
        sample_column=${candidate_line#*|}
        printf 'Auto-detected $%s -> %s / %s\n' "$bind_index" "$sample_relation" "$sample_column"
    elif [ "$bind_candidate_count" -gt 1 ]; then
        echo "Multiple candidate relations found for parameter \$$bind_index:"
        candidate_no=1
        while IFS='|' read -r candidate_relation candidate_column
        do
            printf '  %s) %s / %s\n' "$candidate_no" "$candidate_relation" "$candidate_column"
            candidate_no=$((candidate_no + 1))
        done < "$bind_candidate_file"

        while :; do
            printf 'Select candidate for $%s [1]: ' "$bind_index" >&2
            IFS= read -r candidate_choice || return 1
            [ -n "$candidate_choice" ] || candidate_choice=1
            case $candidate_choice in
                *[!0-9]*|'')
                    echo "ERROR: enter a candidate number." >&2
                    continue
                    ;;
            esac
            if [ "$candidate_choice" -lt 1 ] || [ "$candidate_choice" -gt "$bind_candidate_count" ]; then
                printf 'ERROR: choose 1-%s.\n' "$bind_candidate_count" >&2
                continue
            fi
            candidate_line=$(sed -n "${candidate_choice}p" "$bind_candidate_file")
            sample_relation=${candidate_line%%|*}
            sample_column=${candidate_line#*|}
            printf 'Selected $%s -> %s / %s\n' "$bind_index" "$sample_relation" "$sample_column"
            break
        done
    else
        echo "No automatic relation candidate found for this parameter." >&2
        echo "The following table/column is only used to look up example values; press Enter to skip candidate lookup." >&2
    fi

    while :; do
        if [ -z "$sample_relation" ] || [ -z "$sample_column" ]; then
            printf 'Candidate source table for $%s (schema.table, empty to skip): ' "$bind_index" >&2
            IFS= read -r sample_relation || return 1
            [ -n "$sample_relation" ] || return 0
            printf 'Candidate source column (exact name, empty to skip): ' >&2
            IFS= read -r sample_column || return 1
            [ -n "$sample_column" ] || return 0
        fi

        printf '\nTable value candidates for $%s (up to %s distinct values; not historical bind values)\n' "$bind_index" "$BIND_SAMPLE_LIMIT"
        if run_psql -X -q -P pager=off -v ON_ERROR_STOP=1 \
            -v sample_relation="$sample_relation" -v sample_column="$sample_column" \
            -v sample_limit="$BIND_SAMPLE_LIMIT" -v sample_timeout="$BIND_SAMPLE_TIMEOUT" <<'SQL'
BEGIN READ ONLY;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS sample_timeout
\gset
SELECT format(
    'SELECT DISTINCT %1$I AS candidate_value FROM %2$s WHERE %1$I IS NOT NULL LIMIT %3$s',
    :'sample_column', :'sample_relation'::regclass, :'sample_limit'::integer)
\gexec
COMMIT;
SQL
        then
            bind_default_value=$(
                run_psql -X -qAt -v ON_ERROR_STOP=1 \
                    -v sample_relation="$sample_relation" -v sample_column="$sample_column" \
                    -v sample_timeout="$BIND_SAMPLE_TIMEOUT" <<'SQL'
BEGIN READ ONLY;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS sample_timeout
\gset
SELECT format(
    'SELECT DISTINCT %1$I::text FROM %2$s WHERE %1$I IS NOT NULL AND %1$I::text !~ E''[\n\r]'' LIMIT 1',
    :'sample_column', :'sample_relation'::regclass)
\gexec
COMMIT;
SQL
            ) || bind_default_value=
            if [ -n "$bind_default_value" ]; then
                bind_default_available=yes
                printf 'Default for $%s: %s\n' "$bind_index" "$bind_default_value"
            fi
            echo 'Candidates are distinct current table values and do not apply the original SQL filters.'
            return 0
        fi

        echo 'Could not read candidates. Check table/column/permissions or retry; empty table skips candidates.' >&2
        sample_relation=
        sample_column=
    done
}

BIND=$(ask 'Use bind parameters ($1, $2, ...)? yes/no' no) || exit 1
prepare_file="$work_dir/prepare.sql"
execute_file="$work_dir/execute.sql"
bind_values_file="$work_dir/bind-values-used.txt"
: > "$bind_values_file"
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

    BIND_SAMPLE_LIMIT=${BIND_SAMPLE_LIMIT:-3}
    BIND_SAMPLE_TIMEOUT=${BIND_SAMPLE_TIMEOUT:-5s}
    if ! printf '%s\n' "$BIND_SAMPLE_LIMIT" | grep -Eq '^[0-9]*[1-9][0-9]*$'; then
        echo "ERROR: BIND_SAMPLE_LIMIT must be a positive integer." >&2
        exit 1
    fi

    build_bind_map
    build_bind_constant_map
    build_bind_type_map

    echo "Bind parameter count: $BIND_COUNT"
    echo 'Enter each value as plain text (no SQL quotes). \N means SQL NULL. If a default is shown, Enter accepts it.'
    echo 'Without a default, empty input is allowed only for PostgreSQL string types; non-string types require a value or \N.'

    printf 'EXECUTE pg_explain_target' > "$execute_file"
    if [ "$BIND_COUNT" -gt 0 ]; then
        printf '(' >> "$execute_file"
        bind_index=1
        while [ "$bind_index" -le "$BIND_COUNT" ]; do
            show_bind_candidates || exit 1

            while :; do
                if [ "$bind_default_available" = yes ]; then
                    printf 'Value for $%s [%s]: ' "$bind_index" "$bind_default_value" >&2
                elif [ "$bind_empty_string_allowed" = yes ]; then
                    printf 'Value for $%s (empty string allowed, \\N for NULL): ' "$bind_index" >&2
                else
                    printf 'Value for $%s (required, \\N for NULL): ' "$bind_index" >&2
                fi

                IFS= read -r bind_value || exit 1

                if [ -z "$bind_value" ] && [ "$bind_default_available" = yes ]; then
                    bind_value=$bind_default_value
                    break
                fi

                if [ -z "$bind_value" ] && [ "$bind_empty_string_allowed" != yes ]; then
                    printf 'ERROR: $%s type %s does not accept an implicit empty-string input here. Enter a value or \\N for SQL NULL.\n' \
                        "$bind_index" "$bind_type" >&2
                    continue
                fi

                break
            done

            if [ "$bind_value" = '\N' ]; then
                bind_display_value=NULL
            elif [ -z "$bind_value" ]; then
                bind_display_value='<empty string>'
            else
                bind_display_value=$bind_value
            fi
            printf '$%s [%s] = %s\n' "$bind_index" "$bind_type" "$bind_display_value" >> "$bind_values_file"

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

    if [ -s "$bind_values_file" ]; then
        echo
        echo "Bind Values Used"
        echo "----------------"
        cat "$bind_values_file"
        echo
    fi

    unset bind_value bind_types bind_display_value
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
diag_map_file="$work_dir/diagnostic-relation-map.txt"
diag_rel_file="$work_dir/diagnostic-relations.txt"
table_before="$work_dir/table_before.txt"
table_after="$work_dir/table_after.txt"
index_before="$work_dir/index_before.txt"
index_after="$work_dir/index_after.txt"
plan_output="$work_dir/plan-output.txt"
plan_tree_output="$work_dir/plan-tree-output.txt"
report_output="$work_dir/report-output.txt"
PARTITION_DIAG_LIMIT=${PARTITION_DIAG_LIMIT:-3}
case $PARTITION_DIAG_LIMIT in
    ''|*[!0-9]*|0)
        echo "ERROR: PARTITION_DIAG_LIMIT must be a positive integer." >&2
        exit 1
        ;;
esac

result_timestamp=$(date '+%Y%m%d_%H%M%S')
result_database=$(printf '%s' "$PGDATABASE" | tr -c '[:alnum:]_.-' '_')
RESULT_DIR=${EXPLAIN_RESULT_DIR:-$DEFAULT_OUTPUT_DIR}
RESULT_FILE="$RESULT_DIR/explain_${result_database}_${result_timestamp}.log"
mkdir -p "$RESULT_DIR" || {
    echo "ERROR: Could not create result directory: $RESULT_DIR" >&2
    exit 1
}
{
    echo "PostgreSQL execution plan analysis"
    echo "script_version=$SCRIPT_VERSION"
    echo "generated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "database=$PGDATABASE"
    echo "host=${PGHOST:-default/local socket}"
    echo "port=$PGPORT"
    echo "user=$PGUSER"
    echo "sql_file=$SQL_FILE"
    echo "explain_options=$opts"
    echo "partition_diagnostic_limit=$PARTITION_DIAG_LIMIT"
    echo
} > "$RESULT_FILE" || {
    echo "ERROR: Could not create result file: $RESULT_FILE" >&2
    exit 1
}

if [ "$BIND" = yes ] && [ -s "$bind_values_file" ]; then
    {
        echo "Bind Values Used"
        echo "----------------"
        cat "$bind_values_file"
        echo
    } >> "$RESULT_FILE"
fi

echo "Result file: $RESULT_FILE"

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

print_plan_tree() {
    input_file=$1

    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        function leading_spaces(s) {
            match(s, /^[[:space:]]*/)
            return RLENGTH
        }

        function mark_never(s) {
            gsub(/\(never executed\)/, "[NEVER EXECUTED]", s)
            return s
        }

        function is_structure_label(s) {
            return (s ~ /^InitPlan[[:space:]]+[0-9]+/ ||
                    s ~ /^SubPlan[[:space:]]+[0-9]+/ ||
                    s ~ /^CTE[[:space:]]+[^[:space:]]+/)
        }

        function is_detail_line(s) {
            return (s ~ /^(Index Cond|Recheck Cond|Filter|Hash Cond|Merge Cond|Join Filter|One-Time Filter|Heap Fetches|Heap Blocks|Sort Key|Sort Method|Presorted Key|Group Key|Rows Removed by Filter|Rows Removed by Join Filter|Rows Removed by Index Recheck|Function Call|Workers Planned|Workers Launched|Disabled|Buckets|Batches|Memory Usage|Peak Memory Usage|Disk Usage|Cache Key|Cache Mode|Hits|Misses|Evictions|Overflows|Full-sort Groups|Pre-sorted Groups|Buffers|I\/O Timings|WAL):/)
        }

        function add_node(indent, text, kind,    i, p) {
            node_count++
            node_indent[node_count] = indent
            node_text[node_count] = mark_never(text)
            node_kind[node_count] = kind

            if (node_count == 1) {
                node_parent[node_count] = 0
                return node_count
            }

            p = 0
            for (i = node_count - 1; i >= 1; i--) {
                if (node_indent[i] < indent) {
                    p = i
                    break
                }
            }

            if (p == 0) {
                parse_error = 1
                parse_error_line = text
            }

            node_parent[node_count] = p
            return node_count
        }

        function attach_detail(indent, text,    i, p, key) {
            p = 0
            for (i = node_count; i >= 1; i--) {
                if (node_indent[i] < indent) {
                    p = i
                    break
                }
            }

            if (p > 0) {
                detail_count[p]++
                key = p SUBSEP detail_count[p]
                detail_text[key] = text
            } else {
                global_detail_count++
                global_detail[global_detail_count] = text
            }
        }

        function is_last_child(i,    p, j) {
            p = node_parent[i]
            for (j = i + 1; j <= node_count; j++) {
                if (node_parent[j] == p) return 0
            }
            return 1
        }

        function ancestor_prefix(i, include_self,    p, n, j, a, prefix) {
            n = 0
            p = node_parent[i]
            while (p > 0) {
                chain[++n] = p
                p = node_parent[p]
            }

            prefix = ""
            for (j = n; j >= 1; j--) {
                a = chain[j]
                if (node_parent[a] == 0) continue
                prefix = prefix (is_last_child(a) ? "   " : "│  ")
            }

            if (include_self && node_parent[i] != 0) {
                prefix = prefix (is_last_child(i) ? "   " : "│  ")
            }

            return prefix
        }

        BEGIN {
            in_plan = 0
            root_done = 0
            node_count = 0
            parse_error = 0
        }

        {
            raw = $0
            text = trim(raw)

            if (!in_plan) {
                if (text == "QUERY PLAN") in_plan = 1
                next
            }

            if (!root_done && text ~ /^-+$/) next

            if (text ~ /^\([0-9]+ rows?\)$/) {
                in_plan = 0
                next
            }

            if (!in_plan || text == "") next

            if (!root_done) {
                if (text ~ /^(Planning Time|Execution Time):/) next
                add_node(leading_spaces(raw), text, "plan")
                root_done = 1
                next
            }

            if (text ~ /^->/) {
                indent = leading_spaces(raw)
                sub(/^->[[:space:]]*/, "", text)
                add_node(indent, text, "plan")
                next
            }

            if (is_structure_label(text)) {
                add_node(leading_spaces(raw), text, "group")
                next
            }

            if (is_detail_line(text)) {
                attach_detail(leading_spaces(raw), text)
                next
            }

            if (text ~ /^(Planning Time|Execution Time):/) {
                global_detail_count++
                global_detail[global_detail_count] = text
                next
            }
        }

        END {
            if (node_count == 0) {
                print "(tree parsing unavailable: no PostgreSQL plan nodes found)"
                exit 2
            }

            if (parse_error) {
                print "(tree parsing unavailable: structural indentation could not be resolved)"
                if (parse_error_line != "") print "unresolved: " parse_error_line
                exit 2
            }

            for (i = 1; i <= node_count; i++) {
                if (node_parent[i] == 0) {
                    print node_text[i]
                } else {
                    print ancestor_prefix(i, 0) (is_last_child(i) ? "└─ " : "├─ ") node_text[i]
                }

                for (k = 1; k <= detail_count[i]; k++) {
                    key = i SUBSEP k
                    if (node_parent[i] == 0) {
                        print "   · " detail_text[key]
                    } else {
                        print ancestor_prefix(i, 1) "· " detail_text[key]
                    }
                }
            }

            for (i = 1; i <= global_detail_count; i++) {
                print "· " global_detail[i]
            }
        }
    ' "$input_file"
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

build_diagnostic_relation_list() {
    : > "$diag_map_file"
    : > "$diag_rel_file"

    while IFS= read -r rel
    do
        [ -n "$rel" ] || continue
        printf '%s\n' "
WITH RECURSIVE ancestors AS (
    SELECT i.inhparent AS parent_oid, 1 AS depth
    FROM pg_inherits i
    WHERE i.inhrelid = :'rel'::regclass
  UNION ALL
    SELECT i.inhparent, a.depth + 1
    FROM ancestors a
    JOIN pg_inherits i ON i.inhrelid = a.parent_oid
), top_parent AS (
    SELECT parent_oid
    FROM ancestors
    ORDER BY depth DESC
    LIMIT 1
)
SELECT :'rel' AS relation_name,
       COALESCE(
           (SELECT format('%I.%I', n.nspname, c.relname)
              FROM top_parent t
              JOIN pg_class c ON c.oid = t.parent_oid
              JOIN pg_namespace n ON n.oid = c.relnamespace),
           :'rel'
       ) AS family_name,
       EXISTS (SELECT 1 FROM ancestors) AS is_partition;
" | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 -v rel="$rel" >> "$diag_map_file" || {
            echo "ERROR: Could not inspect partition hierarchy for relation: $rel" >&2
            return 1
        }
    done < "$rel_file"

    awk -F'|' -v limit="$PARTITION_DIAG_LIMIT" '
        $3 == "t" {
            if (selected[$2] < limit) {
                print $1
                selected[$2]++
            }
            next
        }
        { print $1 }
    ' "$diag_map_file" > "$diag_rel_file"
}

print_diagnostic_selection() {
    awk -F'|' -v limit="$PARTITION_DIAG_LIMIT" '
        {
            relation[NR]=$1
            family[NR]=$2
            partitioned[NR]=$3
            if ($3 == "t") total[$2]++
        }
        END {
            for (i=1; i<=NR; i++) {
                if (partitioned[i] != "t") {
                    printf "Standalone relation : %s -> detailed diagnostic\n", relation[i]
                    continue
                }
                f=family[i]
                if (!shown[f]) {
                    selected=(total[f] < limit ? total[f] : limit)
                    printf "Partition family    : %s (plan partitions=%d, detailed=%d)\n", f, total[f], selected
                    count=0
                    for (j=1; j<=NR && count<limit; j++) {
                        if (partitioned[j] == "t" && family[j] == f) {
                            printf "  selected          : %s\n", relation[j]
                            count++
                        }
                    }
                    shown[f]=1
                }
            }
        }
    ' "$diag_map_file"
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

section "Execution Plan" | tee -a "$RESULT_FILE"
{
    echo "Generated: EXPLAIN ($opts)"
    if [ "$DML_ANALYZE" = yes ]; then
        echo "DML safety: BEGIN -> EXPLAIN ANALYZE -> ROLLBACK"
    fi
} | tee -a "$RESULT_FILE"

if run_psql -X -q -P pager=off -v ON_ERROR_STOP=1 -f "$tmp" > "$plan_output" 2>&1; then
    if [ "$FORMAT" = TEXT ]; then
        section "Execution Plan Tree (Structural)" | tee -a "$RESULT_FILE"
        if print_plan_tree "$plan_output" > "$plan_tree_output"; then
            cat "$plan_tree_output" | tee -a "$RESULT_FILE"
            {
                echo
                echo "NOTE: Structural hierarchy is parsed from the captured PostgreSQL TEXT plan."
                echo "      The SQL / EXPLAIN ANALYZE is not executed again for Tree output."
                echo "      Plan nodes and InitPlan/SubPlan/CTE groups are preserved; selected node attributes are summarized."
                echo "      Ancillary details remain available in Execution Plan (Raw)."
                echo "      [NEVER EXECUTED] means the node was planned but not run during this execution."
            } | tee -a "$RESULT_FILE"
        else
            tree_status=$?
            cat "$plan_tree_output" | tee -a "$RESULT_FILE" >&2
            {
                echo "WARNING: Structural Tree generation was stopped instead of guessing an unresolved hierarchy."
                echo "         Use Execution Plan (Raw) as the authoritative output for this plan."
            } | tee -a "$RESULT_FILE" >&2
        fi
    else
        section "Execution Plan Tree (Structural)" | tee -a "$RESULT_FILE"
        echo "Structural Tree is available when FORMAT=TEXT. Raw $FORMAT output is preserved below." | tee -a "$RESULT_FILE"
    fi

    section "Execution Plan (Raw)" | tee -a "$RESULT_FILE"
    cat "$plan_output" | tee -a "$RESULT_FILE"
else
    plan_status=$?
    cat "$plan_output" | tee -a "$RESULT_FILE" >&2
    echo "Execution plan failed. Result file: $RESULT_FILE" >&2
    exit "$plan_status"
fi

if [ "$ANALYZE" = yes ] && [ -s "$rel_file" ]; then
    snapshot_stats "$table_after" "$index_after"

    section "Table Statistics Delta" | tee -a "$RESULT_FILE"
    print_table_delta | tee -a "$RESULT_FILE"

    section "Index Statistics / I/O Delta" | tee -a "$RESULT_FILE"
    print_index_delta | tee -a "$RESULT_FILE"

    {
        echo
        echo "NOTE: Delta is calculated from cumulative pg_stat_* counters before/after this run."
        echo "      Concurrent sessions using the same relation can be included in the delta."
        echo "      The per-query I/O shown by EXPLAIN (ANALYZE, BUFFERS) is more specific to this execution."
    } | tee -a "$RESULT_FILE"
fi

echo "Current result saved: $RESULT_FILE"
DIAG=$(ask "Show additional Plan diagnostics? yes/no" yes)
if [ "$DIAG" != yes ]; then
    echo "Final result file: $RESULT_FILE"
    exit 0
fi

COLUMN_STATS_DETAIL=$(ask "Show full Column Statistics arrays? yes/no" no)
{
    echo "column_statistics_detail=$COLUMN_STATS_DETAIL"
    echo
} >> "$RESULT_FILE"

section "Planner Settings" | tee -a "$RESULT_FILE"
if run_psql -X -P pager=off -P format=wrapped -P columns=160 -v ON_ERROR_STOP=1 > "$report_output" 2>&1 <<'SQL'
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
then
    cat "$report_output" | tee -a "$RESULT_FILE"
else
    report_status=$?
    cat "$report_output" | tee -a "$RESULT_FILE" >&2
    exit "$report_status"
fi

if [ ! -s "$rel_file" ]; then
    {
        echo
        echo "Referenced relation could not be identified automatically from the plan."
        echo "Final result file: $RESULT_FILE"
    } | tee -a "$RESULT_FILE"
    exit 0
fi

section "Referenced Relations (Plan Base Relations)" | tee -a "$RESULT_FILE"
cat "$rel_file" | tee -a "$RESULT_FILE"

build_diagnostic_relation_list || exit 1
section "Detailed Diagnostic Selection" | tee -a "$RESULT_FILE"
print_diagnostic_selection | tee -a "$RESULT_FILE"

run_relation_report() {
    rel=$1
    title=$2
    sql=$3

    section "$title : $rel" | tee -a "$RESULT_FILE"
    if printf '%s\n' "$sql" | \
        run_psql -X -P pager=off -P format=wrapped -P columns=160 \
            -v ON_ERROR_STOP=1 -v rel="$rel" > "$report_output" 2>&1; then
        cat "$report_output" | tee -a "$RESULT_FILE"
    else
        report_status=$?
        cat "$report_output" | tee -a "$RESULT_FILE" >&2
        return "$report_status"
    fi
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

SQL_COLUMN_STATS_SUMMARY='
SELECT attname,
       null_frac,
       avg_width,
       n_distinct,
       correlation,
       cardinality(most_common_vals) AS mcv_count,
       cardinality(histogram_bounds) AS histogram_count,
       CASE
         WHEN most_common_vals IS NULL THEN NULL
         WHEN length(most_common_vals::text) <= 60 THEN most_common_vals::text
         ELSE left(most_common_vals::text,57) || '\''...'\''
       END AS mcv_sample,
       CASE
         WHEN most_common_freqs IS NULL THEN NULL
         WHEN length(most_common_freqs::text) <= 60 THEN most_common_freqs::text
         ELSE left(most_common_freqs::text,57) || '\''...'\''
       END AS mcv_freq_sample,
       CASE
         WHEN histogram_bounds IS NULL THEN NULL
         WHEN length(histogram_bounds::text) <= 60 THEN histogram_bounds::text
         ELSE left(histogram_bounds::text,57) || '\''...'\''
       END AS histogram_sample
FROM pg_stats
WHERE schemaname = split_part(:'\''rel'\'','\''.'\'',1)
  AND tablename  = split_part(:'\''rel'\'','\''.'\'',2)
ORDER BY attname;
'

SQL_COLUMN_STATS_DETAIL='
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
    run_relation_report "$rel" "Column Statistics Summary" "$SQL_COLUMN_STATS_SUMMARY"
    if [ "$COLUMN_STATS_DETAIL" = yes ]; then
        run_relation_report "$rel" "Column Statistics Detail" "$SQL_COLUMN_STATS_DETAIL"
    fi
    run_relation_report "$rel" "Extended Statistics" "$SQL_EXT_STATS"
    run_relation_report "$rel" "Index Information" "$SQL_INDEX_INFO"
    run_relation_report "$rel" "Index Columns" "$SQL_INDEX_COLUMNS"
    run_relation_report "$rel" "Index Usage / I/O" "$SQL_INDEX_IO"
done < "$diag_rel_file"

echo "Final result file: $RESULT_FILE" | tee -a "$RESULT_FILE"
