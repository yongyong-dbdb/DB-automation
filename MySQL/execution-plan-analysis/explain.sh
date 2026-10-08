#!/bin/sh
# MySQL Execution Plan Analysis
# Version: 0.4.2
#
# Oracle MySQL execution-plan / optimizer diagnostic collector.
# No Python / jq / external package dependency.

set -u

VERSION="0.4.2"

MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQL_HOST="${MYSQL_HOST:-}"
MYSQL_PORT="${MYSQL_TCP_PORT:-3306}"
MYSQL_SOCKET="${MYSQL_SOCKET:-}"
MYSQL_USER="${MYSQL_USER:-}"
MYSQL_DATABASE="${MYSQL_DATABASE:-}"

LOGIN_PATH=""
DEFAULTS_FILE=""
NO_PASSWORD=0
ANALYZE=0
ANALYZE_DML=0
EXPLAIN_FORMAT=""
ANALYZE_FORMAT="TREE"
OPTIMIZER_TRACE=0
DIAG_ERRORS=0
CHECK_ONLY=0
OUTPUT_DIR=""
SQL_TEXT=""
SQL_FILE=""
BIND_VALUES=""
BIND_SETUP=""
BIND_USING=""
BIND_COUNT=0

TMP_CNF=""
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage:
  sh explain.sh [SQL_FILE] [options]

SQL input:
  --sql SQL                  SQL text
  --file FILE                SQL file
  --bind TYPE:VALUE          Repeatable INT / DECIMAL / STR / DATE / NULL
  positional FILE            Same as --file FILE

Connection:
  --host HOST                MySQL host
  --port PORT                MySQL port (default: 3306)
  --socket PATH              Unix socket
  --user USER                MySQL user
  --database DB              Default database
  --login-path NAME          mysql_config_editor login path
  --defaults-extra-file FILE Existing MySQL option file
  --no-password              Do not prompt for a password

Analysis:
  --format NAME               TRADITIONAL | TREE | JSON | ALL
  --analyze                   EXPLAIN ANALYZE for SELECT/TABLE only (executes SQL)
  --analyze-format NAME       TREE | JSON (JSON requires explain_json_format_version=2)
  --analyze-dml               Disabled for safety in v0.2
  TTY without --format       Choose interactively; otherwise TRADITIONAL
  --optimizer-trace           Collect INFORMATION_SCHEMA.OPTIMIZER_TRACE
  --check-only                Connection / capability precheck only
  --output DIR                Report output directory

Other:
  -h, --help                  Show help
  -v, --version               Show version

Password is never accepted as a command-line option.
EOF
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [ -n "$TMP_CNF" ] && [ -f "$TMP_CNF" ] && rm -f "$TMP_CNF"
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

escape_cnf_value() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

make_temp_cnf() {
    PASS=""

    if [ "$NO_PASSWORD" -eq 0 ]; then
        printf 'MySQL password: ' >&2
        if command -v stty >/dev/null 2>&1 && [ -t 0 ]; then
            stty -echo
            IFS= read -r PASS
            stty echo
            printf '\n' >&2
        else
            IFS= read -r PASS
        fi
    fi

    TMP_CNF="$(mktemp "${TMPDIR:-/tmp}/mysql-explain.XXXXXX.cnf")" || die "mktemp failed"
    chmod 600 "$TMP_CNF"

    {
        printf '[client]\n'
        [ -n "$MYSQL_USER" ] && printf 'user="%s"\n' "$(escape_cnf_value "$MYSQL_USER")"
        [ -n "$MYSQL_HOST" ] && printf 'host="%s"\n' "$(escape_cnf_value "$MYSQL_HOST")"
        [ -n "$MYSQL_PORT" ] && printf 'port=%s\n' "$MYSQL_PORT"
        [ -n "$MYSQL_SOCKET" ] && printf 'socket="%s"\n' "$(escape_cnf_value "$MYSQL_SOCKET")"
        [ -n "$PASS" ] && printf 'password="%s"\n' "$(escape_cnf_value "$PASS")"
    } > "$TMP_CNF"
}

mysql_base() {
    if [ -n "$LOGIN_PATH" ]; then
        "$MYSQL_BIN" --login-path="$LOGIN_PATH" --connect-timeout=5 "$@"
    elif [ -n "$DEFAULTS_FILE" ]; then
        "$MYSQL_BIN" --defaults-extra-file="$DEFAULTS_FILE" --connect-timeout=5 "$@"
    else
        "$MYSQL_BIN" --defaults-extra-file="$TMP_CNF" --connect-timeout=5 "$@"
    fi
}

mysql_exec() {
    QUERY="$1"
    shift

    if [ -n "$MYSQL_DATABASE" ]; then
        mysql_base --database="$MYSQL_DATABASE" "$@" -e "$QUERY"
    else
        mysql_base "$@" -e "$QUERY"
    fi
}

mysql_raw() {
    mysql_exec "$1" --batch --raw --skip-column-names
}

sql_quote() {
    printf '%s' "$1" | sed "s/'/''/g"
}

read_sql() {
    if [ -n "$SQL_TEXT" ] && [ -n "$SQL_FILE" ]; then
        die "Use only one of --sql or --file"
    fi

    if [ -n "$SQL_FILE" ]; then
        [ -r "$SQL_FILE" ] || die "Cannot read SQL file: $SQL_FILE"
        SQL_TEXT="$(cat "$SQL_FILE")"
    fi

    [ -n "$SQL_TEXT" ] || [ "$CHECK_ONLY" -eq 1 ] || die "SQL input required"

    if [ -n "$SQL_TEXT" ]; then
        SQL_TEXT="$(printf '%s' "$SQL_TEXT" | sed 's/[[:space:]]*;[[:space:]]*$//')"
    fi
}

statement_type() {
    printf '%s\n' "$SQL_TEXT" |
        awk '
        BEGIN { in_comment=0 }
        {
            line=$0

            if (in_comment) {
                if (line ~ /\*\//) {
                    sub(/^.*\*\//, "", line)
                    in_comment=0
                } else {
                    next
                }
            }

            sub(/^[[:space:]]+/, "", line)

            if (line ~ /^\/\*/) {
                if (line !~ /\*\//) {
                    in_comment=1
                    next
                }
                sub(/^\/\*.*\*\//, "", line)
                sub(/^[[:space:]]+/, "", line)
            }

            if (line == "" || line ~ /^--/ || line ~ /^#/) next

            split(line, a, /[[:space:](]/)
            print toupper(a[1])
            exit
        }'
}

hex_utf8() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}
compile_bind_values() {
    [ -n "$BIND_VALUES" ] || return 0
    OLD_IFS="$IFS"
    IFS='
'
    set -f
    for ENTRY in $BIND_VALUES; do
        [ -n "$ENTRY" ] || continue
        BIND_COUNT=$((BIND_COUNT + 1))
        case "$ENTRY" in
            INT:*)
                VALUE="${ENTRY#INT:}"
                printf '%s\n' "$VALUE" | grep -Eq '^[-+]?[0-9]+$' ||
                    die "Invalid INT bind at position $BIND_COUNT"
                EXPR="$VALUE"
                ;;
            DECIMAL:*)
                VALUE="${ENTRY#DECIMAL:}"
                printf '%s\n' "$VALUE" | grep -Eq '^[-+]?[0-9]+([.][0-9]+)?$' ||
                    die "Invalid DECIMAL bind at position $BIND_COUNT"
                EXPR="$VALUE"
                ;;
            STR:*)
                VALUE="${ENTRY#STR:}"
                HEX="$(hex_utf8 "$VALUE")"
                if [ -n "$HEX" ]; then
                    EXPR="CONVERT(0x$HEX USING utf8mb4)"
                else
                    EXPR="''"
                fi
                ;;
            DATE:*)
                VALUE="${ENTRY#DATE:}"
                printf '%s\n' "$VALUE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ||
                    die "Invalid DATE bind at position $BIND_COUNT"
                EXPR="CAST(CONVERT(0x$(hex_utf8 "$VALUE") USING utf8mb4) AS DATE)"
                ;;
            NULL)
                EXPR="NULL"
                ;;
            *)
                die "Use --bind INT:value, DECIMAL:value, STR:value, DATE:value, or NULL"
                ;;
        esac
        BIND_SETUP="$BIND_SETUP
SET @diag_bind_$BIND_COUNT = $EXPR;"
        if [ -n "$BIND_USING" ]; then BIND_USING="$BIND_USING,"; fi
        BIND_USING="$BIND_USING@diag_bind_$BIND_COUNT"
    done
    IFS="$OLD_IFS"
    set +f
    if [ "$BIND_COUNT" -gt 0 ] && ! printf '%s' "$SQL_TEXT" | grep -q '?'; then
        die "Bind values provided, but no ? Parameter Marker found in SQL"
    fi
}
prepare_diagnostic_sql() {
    STATEMENT="$1"
    if [ "$BIND_COUNT" -eq 0 ]; then
        printf '%s;\n' "$STATEMENT"
        return 0
    fi
    HEX="$(hex_utf8 "$STATEMENT")"
    printf '%s\n' "$BIND_SETUP"
    printf 'SET @diag_prepared_sql=CONVERT(0x%s USING utf8mb4);\n' "$HEX"
    printf 'PREPARE diag_explain_stmt FROM @diag_prepared_sql;\n'
    printf 'EXECUTE diag_explain_stmt USING %s;\n' "$BIND_USING"
    printf 'DEALLOCATE PREPARE diag_explain_stmt;\n'
}

make_output_dir() {
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="./mysql-plan-report-$(date '+%Y%m%d_%H%M%S')"
    fi

    mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"
}

collect_precheck() {
    PRECHECK_FILE="$OUTPUT_DIR/precheck.txt"

    {
        printf 'script_version\t%s\n' "$VERSION"
        mysql_raw "
SELECT 'server_version', VERSION()
UNION ALL SELECT 'version_comment', @@version_comment
UNION ALL SELECT 'hostname', @@hostname
UNION ALL SELECT 'port', @@port
UNION ALL SELECT 'database', COALESCE(DATABASE(), '')
UNION ALL SELECT 'performance_schema', @@performance_schema
UNION ALL SELECT 'optimizer_switch', @@optimizer_switch;
" 2>&1
    } > "$PRECHECK_FILE"
}

choose_explain_format() {
    if [ -z "$EXPLAIN_FORMAT" ]; then
        if [ -t 0 ]; then
            printf 'EXPLAIN FORMAT: 1) TRADITIONAL  2) TREE  3) JSON  4) ALL [1]: ' >&2
            IFS= read -r CHOICE
            case "$CHOICE" in
                ""|1) EXPLAIN_FORMAT="TRADITIONAL" ;;
                2) EXPLAIN_FORMAT="TREE" ;;
                3) EXPLAIN_FORMAT="JSON" ;;
                4) EXPLAIN_FORMAT="ALL" ;;
                *) die "Invalid EXPLAIN FORMAT selection" ;;
            esac
        else
            EXPLAIN_FORMAT="TRADITIONAL"
        fi
    fi

    EXPLAIN_FORMAT="$(printf '%s' "$EXPLAIN_FORMAT" | tr '[:lower:]' '[:upper:]')"
    ANALYZE_FORMAT="$(printf '%s' "$ANALYZE_FORMAT" | tr '[:lower:]' '[:upper:]')"

    case "$EXPLAIN_FORMAT" in
        TRADITIONAL|TREE|JSON|ALL) ;;
        *) die "--format must be TRADITIONAL, TREE, JSON, or ALL" ;;
    esac

    case "$ANALYZE_FORMAT" in
        TREE|JSON) ;;
        *) die "--analyze-format must be TREE or JSON" ;;
    esac
}

collect_plan() {
    # MySQL JSON plan remains internal input for object diagnostics, even
    # when a different human-readable EXPLAIN FORMAT is selected.
    PLAN_JSON_FILE="$OUTPUT_DIR/explain_internal.json"
    case "$EXPLAIN_FORMAT" in
        JSON|ALL) PLAN_JSON_FILE="$OUTPUT_DIR/explain.json" ;;
    esac

    log "[PLAN] Internal MySQL JSON plan"
    if ! mysql_raw "$(prepare_diagnostic_sql "EXPLAIN FORMAT=JSON $SQL_TEXT")" \
        > "$PLAN_JSON_FILE" 2> "$OUTPUT_DIR/explain_json.err"; then
        die "EXPLAIN FORMAT=JSON failed: $OUTPUT_DIR/explain_json.err"
    fi

    case "$EXPLAIN_FORMAT" in
        TRADITIONAL|ALL)
            log "[PLAN] FORMAT=TRADITIONAL"
            if ! mysql_exec "$(prepare_diagnostic_sql "EXPLAIN FORMAT=TRADITIONAL $SQL_TEXT")" \
                > "$OUTPUT_DIR/explain_traditional.txt" 2> "$OUTPUT_DIR/explain_traditional.err"; then
                die "FORMAT=TRADITIONAL failed: $OUTPUT_DIR/explain_traditional.err"
            fi
            ;;
    esac

    case "$EXPLAIN_FORMAT" in
        TREE|ALL)
            log "[PLAN] FORMAT=TREE"
            if ! mysql_raw "$(prepare_diagnostic_sql "EXPLAIN FORMAT=TREE $SQL_TEXT")" \
                > "$OUTPUT_DIR/explain_tree.txt" 2> "$OUTPUT_DIR/explain_tree.err"; then
                if [ "$EXPLAIN_FORMAT" = "TREE" ]; then
                    die "FORMAT=TREE failed: $OUTPUT_DIR/explain_tree.err"
                fi
                warn "FORMAT=TREE unavailable; see explain_tree.err"
                DIAG_ERRORS=1
            fi
            ;;
    esac

    if [ "$EXPLAIN_FORMAT" = "JSON" ]; then
        log "[PLAN] FORMAT=JSON"
    fi
}

extract_objects() {
    OBJECT_FILE="$OUTPUT_DIR/objects.tsv"

    # MySQL 9.x JSON v2 includes schema_name for every base relation.
    # The same server session holds the plan in @diag_plan and pairs the
    # schema/table arrays by ordinality. Avoid shell regex JSON parsing.
    EXTRACT_SQL="$(prepare_diagnostic_sql "EXPLAIN FORMAT=JSON INTO @diag_plan $SQL_TEXT")

SET @diag_tables=JSON_EXTRACT(@diag_plan, '\$**.table_name');
SET @diag_schemas=JSON_EXTRACT(@diag_plan, '\$**.schema_name');
SELECT DISTINCT COALESCE(s.schema_name, DATABASE()), t.table_name
FROM JSON_TABLE(
  CASE
    WHEN @diag_tables IS NULL THEN JSON_ARRAY()
    WHEN JSON_TYPE(@diag_tables)='ARRAY' THEN @diag_tables
    ELSE JSON_ARRAY(@diag_tables)
  END, '\$[*]' COLUMNS(n FOR ORDINALITY, table_name VARCHAR(128) PATH '\$')
) AS t
LEFT JOIN JSON_TABLE(
  CASE
    WHEN @diag_schemas IS NULL THEN JSON_ARRAY()
    WHEN JSON_TYPE(@diag_schemas)='ARRAY' THEN @diag_schemas
    ELSE JSON_ARRAY(@diag_schemas)
  END, '\$[*]' COLUMNS(n FOR ORDINALITY, schema_name VARCHAR(128) PATH '\$')
) AS s ON s.n=t.n
WHERE t.table_name IS NOT NULL
ORDER BY 1,2;"

    if ! mysql_raw "$EXTRACT_SQL" > "$OBJECT_FILE" \
      2> "$OUTPUT_DIR/objects.err"; then
        DIAG_ERRORS=1
        warn "MySQL JSON object extraction failed; see objects.err"
        : > "$OBJECT_FILE"
    fi

    awk -F '\t' 'NF>=2 {print $1 "." $2}' "$OBJECT_FILE" > "$OUTPUT_DIR/objects.txt"
    if [ ! -s "$OBJECT_FILE" ]; then
        warn "No base relation in JSON plan, or extraction unavailable"
    fi
}

collect_object_stats() {
    : > "$OUTPUT_DIR/table_stats.txt"
    : > "$OUTPUT_DIR/index_definitions.txt"
    : > "$OUTPUT_DIR/index_io.txt"
    : > "$OUTPUT_DIR/column_histograms.txt"

    [ -s "$OUTPUT_DIR/objects.tsv" ] || return 0

    while IFS="$(printf '\t')" read -r OBJ_SCHEMA TBL; do
        DB_ESC="$(sql_quote "$OBJ_SCHEMA")"
        [ -n "$TBL" ] || continue

        TBL_ESC="$(sql_quote "$TBL")"

        {
            printf '\n### %s.%s\n' "$OBJ_SCHEMA" "$TBL"

            mysql_exec "
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    ENGINE,
    TABLE_ROWS,
    AVG_ROW_LENGTH,
    DATA_LENGTH,
    INDEX_LENGTH,
    DATA_FREE,
    UPDATE_TIME
FROM information_schema.tables
WHERE TABLE_SCHEMA='$DB_ESC'
  AND TABLE_NAME='$TBL_ESC';

SELECT
    database_name,
    table_name,
    last_update,
    n_rows,
    clustered_index_size,
    sum_of_other_index_sizes
FROM mysql.innodb_table_stats
WHERE database_name='$DB_ESC'
  AND table_name='$TBL_ESC';
" 2>&1
        } >> "$OUTPUT_DIR/table_stats.txt"

        {
            printf '\n### %s.%s\n' "$OBJ_SCHEMA" "$TBL"

            mysql_exec "
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    INDEX_NAME,
    NON_UNIQUE,
    SEQ_IN_INDEX,
    COLUMN_NAME,
    COLLATION,
    CARDINALITY,
    SUB_PART,
    NULLABLE,
    INDEX_TYPE,
    IS_VISIBLE,
    EXPRESSION
FROM information_schema.statistics
WHERE TABLE_SCHEMA='$DB_ESC'
  AND TABLE_NAME='$TBL_ESC'
ORDER BY INDEX_NAME, SEQ_IN_INDEX;
" 2>&1
        } >> "$OUTPUT_DIR/index_definitions.txt"

        {
            printf '\n### %s.%s\n' "$OBJ_SCHEMA" "$TBL"

            mysql_exec "
SELECT
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COALESCE(INDEX_NAME, '<NO_INDEX>') AS INDEX_NAME,
    COUNT_STAR,
    COUNT_READ,
    COUNT_WRITE,
    COUNT_FETCH,
    COUNT_INSERT,
    COUNT_UPDATE,
    COUNT_DELETE,
    SUM_TIMER_WAIT
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA='$DB_ESC'
  AND OBJECT_NAME='$TBL_ESC'
ORDER BY COUNT_STAR DESC;
" 2>&1
        } >> "$OUTPUT_DIR/index_io.txt"

        {
            printf '\n### %s.%s\n' "$OBJ_SCHEMA" "$TBL"

            mysql_exec "
SELECT
    SCHEMA_NAME,
    TABLE_NAME,
    COLUMN_NAME,
    JSON_PRETTY(HISTOGRAM) AS HISTOGRAM
FROM information_schema.column_statistics
WHERE SCHEMA_NAME='$DB_ESC'
  AND TABLE_NAME='$TBL_ESC'
ORDER BY COLUMN_NAME;
" 2>&1
        } >> "$OUTPUT_DIR/column_histograms.txt"

    done < "$OUTPUT_DIR/objects.tsv"

    : > "$OUTPUT_DIR/diagnostic_errors.txt"
    for DIAG_FILE in table_stats.txt index_definitions.txt index_io.txt column_histograms.txt; do
        if grep -Eq '^ERROR [0-9]+' "$OUTPUT_DIR/$DIAG_FILE"; then
            warn "Diagnostic SQL failed in $DIAG_FILE; see report"
            grep -E '^ERROR [0-9]+' "$OUTPUT_DIR/$DIAG_FILE" >> "$OUTPUT_DIR/diagnostic_errors.txt"
            DIAG_ERRORS=1
        fi
    done
}

collect_optimizer_trace() {
    log "[6/7] Optimizer Trace"

    TRACE_SQL="SET optimizer_trace='enabled=on';
SET optimizer_trace_max_mem_size=1048576;
SELECT CONCAT('diagnostic_connection=', CONNECTION_ID(),
              ',ps_thread=', COALESCE(PS_CURRENT_THREAD_ID(), 'NULL'));
$(prepare_diagnostic_sql "EXPLAIN FORMAT=JSON $SQL_TEXT")
SELECT TRACE FROM information_schema.optimizer_trace;
SET optimizer_trace='enabled=off';"

    if ! mysql_raw "$TRACE_SQL"         > "$OUTPUT_DIR/optimizer_trace.txt"         2> "$OUTPUT_DIR/optimizer_trace.err"; then
        warn "Optimizer Trace failed. See optimizer_trace.err"
        DIAG_ERRORS=1
    fi
}

run_explain_analyze() {
    TYPE="$1"
    case "$TYPE" in
        SELECT|TABLE) ;;
        *)
            warn "EXPLAIN ANALYZE skipped: SELECT/TABLE only in safe mode"
            return 0
            ;;
    esac

    log "[ANALYZE] $ANALYZE_FORMAT (same MySQL session)"
    INIT=""
    ANALYZE_STATEMENT="EXPLAIN ANALYZE FORMAT=$ANALYZE_FORMAT $SQL_TEXT"
    AFTER_SQL=""
    if [ "$ANALYZE_FORMAT" = "JSON" ]; then
        INIT="SET SESSION explain_json_format_version=2;"
        ANALYZE_STATEMENT="EXPLAIN ANALYZE FORMAT=JSON INTO @diag_actual $SQL_TEXT"
        AFTER_SQL="
SELECT JSON_PRETTY(@diag_actual);
SET @diag_ops=JSON_EXTRACT(@diag_actual, '\$**.operation');
SET @diag_est=JSON_EXTRACT(@diag_actual, '\$**.estimated_rows');
SET @diag_act=JSON_EXTRACT(@diag_actual, '\$**.actual_rows');
SET @diag_loops=JSON_EXTRACT(@diag_actual, '\$**.actual_loops');
SELECT CONCAT('##METRIC##',o.n,CHAR(9),
              REPLACE(o.operation,CHAR(9),' '),CHAR(9),
              e.est,CHAR(9),a.act,CHAR(9),l.loops,CHAR(9),
              COALESCE(ROUND(a.act/NULLIF(e.est,0),3),0))
FROM JSON_TABLE(
  IF(JSON_TYPE(@diag_ops)='ARRAY',@diag_ops,JSON_ARRAY(@diag_ops)),
  '\$[*]' COLUMNS(n FOR ORDINALITY, operation VARCHAR(512) PATH '\$')
) o
JOIN JSON_TABLE(
  IF(JSON_TYPE(@diag_est)='ARRAY',@diag_est,JSON_ARRAY(@diag_est)),
  '\$[*]' COLUMNS(n FOR ORDINALITY, est DOUBLE PATH '\$')
) e ON e.n=o.n
JOIN JSON_TABLE(
  IF(JSON_TYPE(@diag_act)='ARRAY',@diag_act,JSON_ARRAY(@diag_act)),
  '\$[*]' COLUMNS(n FOR ORDINALITY, act DOUBLE PATH '\$')
) a ON a.n=o.n
JOIN JSON_TABLE(
  IF(JSON_TYPE(@diag_loops)='ARRAY',@diag_loops,JSON_ARRAY(@diag_loops)),
  '\$[*]' COLUMNS(n FOR ORDINALITY, loops DOUBLE PATH '\$')
) l ON l.n=o.n
ORDER BY o.n;"
    fi

    # EXPLAIN and the Performance Schema snapshot share one server session.
    # A prepared EXPLAIN is tracked as execute_sql, not dealloc_sql.
    ANALYZE_SQL="$INIT
SET @diag_thread = (
  SELECT THREAD_ID FROM performance_schema.threads
  WHERE PROCESSLIST_ID = CONNECTION_ID()
);
SELECT CONCAT('##SESSION##', CONNECTION_ID(), '|', COALESCE(@diag_thread,'NULL'));
$(prepare_diagnostic_sql "$ANALYZE_STATEMENT")
$AFTER_SQL
SELECT CONCAT('##EVENT##',COALESCE((
  SELECT CONCAT_WS('|',EVENT_ID,EVENT_NAME,
    ROUND(TIMER_WAIT/1000000000,3),
    ROUND(LOCK_TIME/1000000000,3),
    ROWS_EXAMINED,ROWS_SENT,MYSQL_ERRNO)
  FROM performance_schema.events_statements_history
  WHERE THREAD_ID = @diag_thread
    AND SQL_TEXT LIKE 'EXPLAIN ANALYZE%'
    AND EVENT_NAME IN ('statement/sql/select', 'statement/sql/execute_sql')
  ORDER BY EVENT_ID DESC LIMIT 1
),'NOT_COLLECTED'));"

    if ! mysql_raw "$ANALYZE_SQL" > "$TMP_DIR/analyze_all.txt" \
      2> "$OUTPUT_DIR/explain_analyze.err"; then
        warn "EXPLAIN ANALYZE unavailable; see explain_analyze.err"
        DIAG_ERRORS=1
        return 0
    fi

    awk '/^##SESSION##/ {print}' "$TMP_DIR/analyze_all.txt" > "$OUTPUT_DIR/analyze_session.txt"
    awk '/^##EVENT##/ {print}' "$TMP_DIR/analyze_all.txt" > "$OUTPUT_DIR/thread_statement_event.txt"
    awk '/^##METRIC##/ {sub(/^##METRIC##/,"");print}' \
      "$TMP_DIR/analyze_all.txt" > "$OUTPUT_DIR/estimated_actual.tsv"
    awk 'NR>1 && $0 !~ /^##SESSION##/ && $0 !~ /^##EVENT##/ && $0 !~ /^##METRIC##/ {print}' \
      "$TMP_DIR/analyze_all.txt" > "$OUTPUT_DIR/explain_analyze.txt"

    printf '%s\n' 'Not collected: index I/O counters are global across all server threads.' \
      > "$OUTPUT_DIR/index_io_delta.txt"
}

write_summary() {
    TYPE="$1"

    {
        printf 'MySQL Execution Plan Analysis\n'
        printf '=============================\n'
        printf 'Script Version : %s\n' "$VERSION"
        printf 'Statement Type : %s\n' "$TYPE"
        printf 'Database       : %s\n' "$MYSQL_DATABASE"
        printf 'EXPLAIN Format : %s\n' "$EXPLAIN_FORMAT"
        printf 'Analyze Format : %s\n' "$ANALYZE_FORMAT"
        printf 'Analyze        : %s\n' "$ANALYZE"
        printf 'DML Analyze    : disabled (safety / SQL restrictions)\n'
        printf 'P_S metrics    : same-session THREAD_ID statement event\n'
        printf 'Optimizer Trace: %s\n' "$OPTIMIZER_TRACE"
        printf 'Bind Count     : %s\n' "$BIND_COUNT"
        printf 'Stats SQL errors: %s\n' "$DIAG_ERRORS"

        printf '\nBase Tables\n'
        printf '%s\n' '-----------'

        if [ -s "$OUTPUT_DIR/objects.txt" ]; then
            cat "$OUTPUT_DIR/objects.txt"
        else
            printf '(none extracted)\n'
        fi

        printf '\nOutput Directory\n'
        printf '%s\n' '----------------'
        printf '%s\n' "$OUTPUT_DIR"

    } > "$OUTPUT_DIR/summary.txt"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sql)
            [ "$#" -ge 2 ] || die "--sql requires a value"
            SQL_TEXT="$2"
            shift 2
            ;;

        --file)
            [ "$#" -ge 2 ] || die "--file requires a value"
            SQL_FILE="$2"
            shift 2
            ;;

        --bind)
            [ "$#" -ge 2 ] || die "--bind requires TYPE:VALUE"
            BIND_VALUES="$BIND_VALUES
$2"
            shift 2
            ;;

        --bind=*)
            BIND_VALUES="$BIND_VALUES
${1#*=}"
            shift
            ;;

        --host)
            [ "$#" -ge 2 ] || die "--host requires a value"
            MYSQL_HOST="$2"
            shift 2
            ;;

        --port)
            [ "$#" -ge 2 ] || die "--port requires a value"
            MYSQL_PORT="$2"
            shift 2
            ;;

        --socket)
            [ "$#" -ge 2 ] || die "--socket requires a value"
            MYSQL_SOCKET="$2"
            shift 2
            ;;

        --user)
            [ "$#" -ge 2 ] || die "--user requires a value"
            MYSQL_USER="$2"
            shift 2
            ;;

        --database)
            [ "$#" -ge 2 ] || die "--database requires a value"
            MYSQL_DATABASE="$2"
            shift 2
            ;;

        --login-path)
            [ "$#" -ge 2 ] || die "--login-path requires a value"
            LOGIN_PATH="$2"
            shift 2
            ;;

        --defaults-extra-file)
            [ "$#" -ge 2 ] || die "--defaults-extra-file requires a value"
            DEFAULTS_FILE="$2"
            shift 2
            ;;

        --no-password)
            NO_PASSWORD=1
            shift
            ;;

        --analyze)
            ANALYZE=1
            shift
            ;;

        --format|--explain-format)
            [ "$#" -ge 2 ] || die "--format requires a value"
            EXPLAIN_FORMAT="$2"
            shift 2
            ;;

        --format=*|--explain-format=*)
            EXPLAIN_FORMAT="${1#*=}"
            shift
            ;;

        --analyze-format)
            [ "$#" -ge 2 ] || die "--analyze-format requires a value"
            ANALYZE_FORMAT="$2"
            shift 2
            ;;

        --analyze-format=*)
            ANALYZE_FORMAT="${1#*=}"
            shift
            ;;

        --analyze-dml)
            die "--analyze-dml disabled: only multi-table UPDATE/DELETE supported by MySQL EXPLAIN ANALYZE; rollback alone cannot guarantee isolation"
            ;;

        --optimizer-trace)
            OPTIMIZER_TRACE=1
            shift
            ;;

        --check-only)
            CHECK_ONLY=1
            shift
            ;;

        --output)
            [ "$#" -ge 2 ] || die "--output requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        -v|--version)
            printf '%s\n' "$VERSION"
            exit 0
            ;;

        -*)
            die "Unknown option: $1"
            ;;

        *)
            [ -z "$SQL_FILE" ] || die "Multiple SQL files specified"
            SQL_FILE="$1"
            shift
            ;;
    esac
done

need_cmd "$MYSQL_BIN"
need_cmd awk
need_cmd sed
need_cmd sort
need_cmd mktemp
need_cmd tr
need_cmd od

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mysql-explain-work.XXXXXX")" || die "mktemp failed"

if [ -z "$LOGIN_PATH" ] && [ -z "$DEFAULTS_FILE" ]; then
    [ -n "$MYSQL_USER" ] || die "--user or MYSQL_USER required when login-path/defaults file is not used"
    make_temp_cnf
fi

read_sql
choose_explain_format
compile_bind_values
make_output_dir

log "[0/7] Connection / capability precheck"

if ! mysql_raw "SELECT 1;" >/dev/null 2> "$OUTPUT_DIR/connection.err"; then
    die "MySQL connection failed. See $OUTPUT_DIR/connection.err"
fi

collect_precheck

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "Precheck complete: $OUTPUT_DIR"
    exit 0
fi

[ -n "$MYSQL_DATABASE" ] || die "--database or MYSQL_DATABASE required for object statistics"

TYPE="$(statement_type)"
[ -n "$TYPE" ] || TYPE="UNKNOWN"

collect_plan
if [ "$TYPE" = "WITH" ]; then
    # EXPLAIN JSON v2 reports the final statement type, even for CTE SQL.
    CTE_TYPE="$(sed -n 's/^[[:space:]]*"query_type":[[:space:]]*"\([^"]*\)".*/\1/p' "$PLAN_JSON_FILE" | head -n 1)"
    case "$CTE_TYPE" in
        select) TYPE="SELECT" ;;
        *) warn "WITH statement type not confidently SELECT; EXPLAIN ANALYZE disabled" ;;
    esac
fi

log "[4/7] Base table / statistics / index diagnostics"
extract_objects
collect_object_stats

if [ "$ANALYZE" -eq 1 ]; then
    run_explain_analyze "$TYPE"
else
    : > "$OUTPUT_DIR/explain_analyze.txt"
    : > "$OUTPUT_DIR/index_io_delta.txt"
fi

if [ "$OPTIMIZER_TRACE" -eq 1 ]; then
    collect_optimizer_trace
else
    : > "$OUTPUT_DIR/optimizer_trace.txt"
fi

log "[7/7] Report summary"
write_summary "$TYPE"

log "Done: $OUTPUT_DIR"
if [ "$DIAG_ERRORS" -ne 0 ]; then
    die "One or more requested diagnostics failed; inspect report .err files and diagnostic_errors.txt"
fi
