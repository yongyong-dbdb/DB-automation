#!/bin/sh
# MySQL Execution Plan Analysis
# Version: 0.1.0
#
# Oracle MySQL execution-plan / optimizer diagnostic collector.
# No Python / jq / external package dependency.

set -u

VERSION="0.1.0"

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
OPTIMIZER_TRACE=0
CHECK_ONLY=0
OUTPUT_DIR=""
SQL_TEXT=""
SQL_FILE=""

TMP_CNF=""
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage:
  sh explain.sh [SQL_FILE] [options]

SQL input:
  --sql SQL                  SQL text
  --file FILE                SQL file
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
  --analyze                   Run EXPLAIN ANALYZE for SELECT/TABLE only
  --analyze-dml               Run UPDATE/DELETE EXPLAIN ANALYZE in transaction + ROLLBACK
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

collect_plan() {
    log "[1/7] EXPLAIN FORMAT=TRADITIONAL"

    if ! mysql_exec "EXPLAIN FORMAT=TRADITIONAL $SQL_TEXT"         > "$OUTPUT_DIR/explain_traditional.txt"         2> "$OUTPUT_DIR/explain_traditional.err"; then
        die "EXPLAIN failed. See $OUTPUT_DIR/explain_traditional.err"
    fi

    log "[2/7] EXPLAIN FORMAT=JSON"

    if ! mysql_raw "EXPLAIN FORMAT=JSON $SQL_TEXT"         > "$OUTPUT_DIR/explain.json"         2> "$OUTPUT_DIR/explain_json.err"; then
        die "EXPLAIN FORMAT=JSON failed. See $OUTPUT_DIR/explain_json.err"
    fi

    log "[3/7] EXPLAIN FORMAT=TREE"

    if ! mysql_raw "EXPLAIN FORMAT=TREE $SQL_TEXT"         > "$OUTPUT_DIR/explain_tree.txt"         2> "$OUTPUT_DIR/explain_tree.err"; then
        warn "FORMAT=TREE unavailable or failed. See explain_tree.err"
        : > "$OUTPUT_DIR/explain_tree.txt"
    fi
}

extract_objects() {
    JSON_FILE="$OUTPUT_DIR/explain.json"
    OBJECT_FILE="$OUTPUT_DIR/objects.txt"

    sed -n 's/.*"table_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$JSON_FILE" |
        sort -u > "$OBJECT_FILE"

    if [ ! -s "$OBJECT_FILE" ]; then
        warn "No base table extracted from EXPLAIN JSON"
    fi
}

collect_object_stats() {
    : > "$OUTPUT_DIR/table_stats.txt"
    : > "$OUTPUT_DIR/index_definitions.txt"
    : > "$OUTPUT_DIR/index_io.txt"
    : > "$OUTPUT_DIR/column_histograms.txt"

    [ -s "$OUTPUT_DIR/objects.txt" ] || return 0

    DB_ESC="$(sql_quote "$MYSQL_DATABASE")"

    while IFS= read -r TBL; do
        [ -n "$TBL" ] || continue

        TBL_ESC="$(sql_quote "$TBL")"

        {
            printf '\n### %s.%s\n' "$MYSQL_DATABASE" "$TBL"

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
            printf '\n### %s.%s\n' "$MYSQL_DATABASE" "$TBL"

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
    VISIBLE,
    EXPRESSION
FROM information_schema.statistics
WHERE TABLE_SCHEMA='$DB_ESC'
  AND TABLE_NAME='$TBL_ESC'
ORDER BY INDEX_NAME, SEQ_IN_INDEX;
" 2>&1
        } >> "$OUTPUT_DIR/index_definitions.txt"

        {
            printf '\n### %s.%s\n' "$MYSQL_DATABASE" "$TBL"

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
            printf '\n### %s.%s\n' "$MYSQL_DATABASE" "$TBL"

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

    done < "$OUTPUT_DIR/objects.txt"
}

snapshot_index_io() {
    OUT="$1"
    : > "$OUT"

    [ -s "$OUTPUT_DIR/objects.txt" ] || return 0

    DB_ESC="$(sql_quote "$MYSQL_DATABASE")"

    while IFS= read -r TBL; do
        [ -n "$TBL" ] || continue
        TBL_ESC="$(sql_quote "$TBL")"

        mysql_raw "
SELECT
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COALESCE(INDEX_NAME, '<NO_INDEX>'),
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
  AND OBJECT_NAME='$TBL_ESC';
" >> "$OUT" 2>/dev/null || true

    done < "$OUTPUT_DIR/objects.txt"
}

make_index_delta() {
    BEFORE="$1"
    AFTER="$2"
    OUT="$OUTPUT_DIR/index_io_delta.txt"

    awk -F '\t' '
    BEGIN {
        OFS="\t"
        print "OBJECT_SCHEMA","OBJECT_NAME","INDEX_NAME",
              "COUNT_STAR_DELTA","COUNT_READ_DELTA","COUNT_WRITE_DELTA",
              "COUNT_FETCH_DELTA","COUNT_INSERT_DELTA","COUNT_UPDATE_DELTA",
              "COUNT_DELETE_DELTA","SUM_TIMER_WAIT_DELTA"
    }

    NR==FNR {
        k=$1 SUBSEP $2 SUBSEP $3
        for (i=4;i<=11;i++) b[k,i]=$i+0
        next
    }

    {
        k=$1 SUBSEP $2 SUBSEP $3
        printf "%s\t%s\t%s", $1,$2,$3
        for (i=4;i<=11;i++) printf "\t%.0f", ($i+0)-b[k,i]
        printf "\n"
    }
    ' "$BEFORE" "$AFTER" > "$OUT"
}

collect_optimizer_trace() {
    log "[6/7] Optimizer Trace"

    TRACE_SQL="SET optimizer_trace='enabled=on';
SET optimizer_trace_max_mem_size=1048576;
EXPLAIN FORMAT=JSON $SQL_TEXT;
SELECT TRACE FROM information_schema.optimizer_trace;
SET optimizer_trace='enabled=off';"

    if ! mysql_raw "$TRACE_SQL"         > "$OUTPUT_DIR/optimizer_trace.txt"         2> "$OUTPUT_DIR/optimizer_trace.err"; then
        warn "Optimizer Trace failed. See optimizer_trace.err"
    fi
}

run_explain_analyze() {
    TYPE="$1"
    BEFORE="$TMP_DIR/index_before.tsv"
    AFTER="$TMP_DIR/index_after.tsv"

    snapshot_index_io "$BEFORE"

    log "[5/7] EXPLAIN ANALYZE"

    case "$TYPE" in
        SELECT|TABLE)
            if ! mysql_raw "EXPLAIN ANALYZE $SQL_TEXT"                 > "$OUTPUT_DIR/explain_analyze.txt"                 2> "$OUTPUT_DIR/explain_analyze.err"; then
                warn "EXPLAIN ANALYZE failed. See explain_analyze.err"
            fi
            ;;

        UPDATE|DELETE)
            if [ "$ANALYZE_DML" -eq 1 ]; then
                if ! mysql_raw "START TRANSACTION; EXPLAIN ANALYZE $SQL_TEXT; ROLLBACK;"                     > "$OUTPUT_DIR/explain_analyze.txt"                     2> "$OUTPUT_DIR/explain_analyze.err"; then
                    warn "DML EXPLAIN ANALYZE failed or is unsupported for this statement form. See explain_analyze.err"
                fi
            else
                warn "DML EXPLAIN ANALYZE skipped. Use --analyze-dml for explicit transaction + ROLLBACK execution."
            fi
            ;;

        *)
            warn "EXPLAIN ANALYZE skipped for statement type: $TYPE"
            ;;
    esac

    snapshot_index_io "$AFTER"
    make_index_delta "$BEFORE" "$AFTER"
}

write_summary() {
    TYPE="$1"

    {
        printf 'MySQL Execution Plan Analysis\n'
        printf '=============================\n'
        printf 'Script Version : %s\n' "$VERSION"
        printf 'Statement Type : %s\n' "$TYPE"
        printf 'Database       : %s\n' "$MYSQL_DATABASE"
        printf 'Analyze        : %s\n' "$ANALYZE"
        printf 'Analyze DML    : %s\n' "$ANALYZE_DML"
        printf 'Optimizer Trace: %s\n' "$OPTIMIZER_TRACE"

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

        --analyze-dml)
            ANALYZE=1
            ANALYZE_DML=1
            shift
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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mysql-explain-work.XXXXXX")" || die "mktemp failed"

if [ -z "$LOGIN_PATH" ] && [ -z "$DEFAULTS_FILE" ]; then
    [ -n "$MYSQL_USER" ] || die "--user or MYSQL_USER required when login-path/defaults file is not used"
    make_temp_cnf
fi

read_sql
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
