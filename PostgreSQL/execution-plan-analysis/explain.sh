#!/bin/sh
set -u

SCRIPT_VERSION="1.2.26"
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
if [ -z "${PGUSER:-}" ]; then printf 'PGUSER [postgres]: ' >&2; IFS= read -r _v; PGUSER=${_v:-postgres}; fi
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

reset_script_pgpass() {
    if [ "${PGPASSFILE:-}" = "$work_dir/pgpass" ]; then
        rm -f "$work_dir/pgpass"
        unset PGPASSFILE
    fi
    password_prompted=no
}

switch_user() {
    _new_user=$1
    [ -n "$_new_user" ] || return 1
    [ "$_new_user" = "$PGUSER" ] && return 0

    _old_user=$PGUSER
    reset_script_pgpass
    PGUSER=$_new_user
    export PGUSER
    if check_connection; then
        echo "Analysis user switched: $_old_user -> $PGUSER"
        return 0
    fi

    echo "ERROR: could not connect as user $_new_user." >&2
    PGUSER=$_old_user
    export PGUSER
    reset_script_pgpass
    check_connection >/dev/null 2>&1 || true
    return 1
}

switch_database() {
    _new_database=$1
    [ -n "$_new_database" ] || return 1
    [ "$_new_database" = "$PGDATABASE" ] && return 0

    _old_database=$PGDATABASE
    reset_script_pgpass
    PGDATABASE=$_new_database
    export PGDATABASE
    if check_connection; then
        echo "Analysis database switched: $_old_database -> $PGDATABASE"
        return 0
    fi

    echo "ERROR: could not connect to source database $_new_database." >&2
    PGDATABASE=$_old_database
    export PGDATABASE
    reset_script_pgpass
    check_connection >/dev/null 2>&1 || true
    return 1
}

confirm_database_switch() {
    _from=$1
    _to=$2
    while :; do
        printf 'Query belongs to database %s. Switch analysis database from %s to %s? y/n [y]: ' "$_to" "$_from" "$_to" >&2
        IFS= read -r _ans || return 1
        [ -n "$_ans" ] || _ans=y
        _ans=$(printf '%s' "$_ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_ans in
            y) return 0 ;;
            n) return 1 ;;
            *) echo "ERROR: enter y or n." >&2 ;;
        esac
    done
}

confirm_continue_current_user() {
    _reason=$1
    echo
    [ -z "$_reason" ] || printf '주의: %s\n' "$_reason" >&2
    while :; do
        printf '현재 사용자 %s로 계속 진행하시겠습니까? y/n [n]: ' "$PGUSER" >&2
        IFS= read -r _ans || return 1
        [ -n "$_ans" ] || _ans=n
        _ans=$(printf '%s' "$_ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_ans in
            y) return 0 ;;
            n) return 1 ;;
            *) echo "ERROR: y 또는 n을 입력하세요." >&2 ;;
        esac
    done
}

prepare_pgss_execution_user() {
    [ "$PGUSER" != postgres ] || return 0
    echo
    echo "안내: pg_stat_statements에는 다른 데이터베이스 사용자가 실행한 SQL도 포함될 수 있습니다."
    echo "      query text 조회 단계에서는 권한 문제를 줄이기 위해 postgres 사용자를 권장합니다."
    echo "      query 정보를 확보한 뒤 실제 EXPLAIN 단계에서는 pg_stat_statements의 userid를 기준으로"
    echo "      원본 로그인 사용자로 재접속할 수 있습니다. SET ROLE 및 SET search_path는 사용하지 않습니다."
    while :; do
        printf 'Current user is %s. Switch query lookup user to postgres? y/n [y]: ' "$PGUSER" >&2
        IFS= read -r _ans || return 1
        [ -n "$_ans" ] || _ans=y
        _ans=$(printf '%s' "$_ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_ans in
            y)
                if switch_user postgres; then
                    return 0
                fi
                confirm_continue_current_user "postgres 사용자로 재접속하지 못했습니다." || return 1
                return 0
                ;;
            n)
                echo "주의: $PGUSER 사용자로 pg_stat_statements 조회를 계속합니다. 다른 사용자의 query text가 보이지 않을 수 있습니다."
                return 0
                ;;
            *) echo "ERROR: enter y or n." >&2 ;;
        esac
    done
}

prepare_pgss_source_execution_user() {
    _source_user=$1
    _source_userid=$2
    _source_canlogin=$3

    if [ -z "$_source_user" ]; then
        confirm_continue_current_user "pg_stat_statements의 userid=$_source_userid 에 해당하는 현재 role이 존재하지 않아 원본 사용자로 재접속할 수 없습니다." || return 1
        return 0
    fi

    [ "$PGUSER" != "$_source_user" ] || return 0

    if [ "$_source_canlogin" != yes ]; then
        confirm_continue_current_user "원본 실행 사용자 $_source_user 는 LOGIN 속성이 없어 직접 재접속할 수 없습니다." || return 1
        return 0
    fi

    echo
    echo "실행 사용자 전환"
    printf '  원본 실행 사용자 : %s (userid=%s)\n' "$_source_user" "$_source_userid"
    printf '  현재 접속 사용자 : %s\n' "$PGUSER"
    echo
    echo "안내: 스키마가 생략된 객체, 함수, 타입 등의 해석은 로그인 사용자의 기본 search_path 영향을 받습니다."
    echo "      원본 실행 사용자로 실제 재접속하면 ALTER ROLE / ALTER ROLE IN DATABASE 등에 설정된"
    echo "      로그인 시점의 기본 설정을 적용할 수 있습니다."
    echo "      단, 원본 세션에서 별도로 수행한 SET/SET LOCAL/search_path 변경은 pg_stat_statements에 저장되지 않습니다."
    echo "      SET ROLE 및 SET search_path는 수행하지 않습니다."

    while :; do
        printf '원본 실행 사용자 %s로 실제 재접속하시겠습니까? y/n [y]: ' "$_source_user" >&2
        IFS= read -r _ans || return 1
        [ -n "$_ans" ] || _ans=y
        _ans=$(printf '%s' "$_ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_ans in
            y)
                if switch_user "$_source_user"; then
                    return 0
                fi
                confirm_continue_current_user "원본 실행 사용자 $_source_user 로 재접속하지 못했습니다." || return 1
                return 0
                ;;
            n)
                echo "주의: 현재 사용자 $PGUSER 로 EXPLAIN을 계속합니다. 원본 사용자와 객체 해석/권한/RLS 결과가 달라질 수 있습니다."
                return 0
                ;;
            *) echo "ERROR: y 또는 n을 입력하세요." >&2 ;;
        esac
    done
}

PGSS_AVAILABLE=no
PGSS_RELATION=
PGSS_QUERY_COUNT=0
SQL_SOURCE_KIND=file
ORIGINAL_QUERY_USER=
ORIGINAL_QUERY_USERID=
ORIGINAL_QUERY_USER_CAN_LOGIN=
PGSS_LOOKUP_USER=
PGSS_LOOKUP_DATABASE=
PGSS_EXECUTE_USER=
PGSS_SEARCH_PATH=
PGSS_RAW_SQL_FILE=
PGSS_ORIGINAL_BIND_MAX=
PGSS_NORMALIZED_VALUES_FILE=
PGSS_NORMALIZED_NULL_USED=no
BIND_SAMPLE_LIMIT=${BIND_SAMPLE_LIMIT:-3}
BIND_SAMPLE_TIMEOUT=${BIND_SAMPLE_TIMEOUT:-5s}
if ! printf '%s\n' "$BIND_SAMPLE_LIMIT" | grep -Eq '^[0-9]*[1-9][0-9]*$'; then
    echo "ERROR: BIND_SAMPLE_LIMIT must be a positive integer." >&2
    exit 1
fi

detect_pg_stat_statements() {
    PGSS_RELATION=$(run_psql -X -qAt -v ON_ERROR_STOP=1 <<'SQL' 2>/dev/null || true
SELECT format('%I.pg_stat_statements', n.nspname)
FROM pg_extension e
JOIN pg_namespace n ON n.oid=e.extnamespace
WHERE e.extname='pg_stat_statements'
LIMIT 1;
SQL
    )
    [ -n "$PGSS_RELATION" ] || return 0
    PGSS_QUERY_COUNT=$(run_psql -X -qAt -v ON_ERROR_STOP=1 <<SQL 2>/dev/null || true
SELECT count(*)
FROM $PGSS_RELATION
WHERE query IS NOT NULL;
SQL
    )
    case $PGSS_QUERY_COUNT in ''|*[!0-9]*) PGSS_QUERY_COUNT=0 ;; esac
    [ "$PGSS_QUERY_COUNT" -gt 0 ] && PGSS_AVAILABLE=yes
}

pgss_first_keyword() {
    _file=$1
    awk '
    BEGIN { block_depth=0 }
    {
        line=$0
        if (NR==1) sub(/^\357\273\277/, "", line)
        i=1
        while (i <= length(line)) {
            two=substr(line,i,2)
            if (block_depth > 0) {
                if (two == "/*") { block_depth++; i+=2; continue }
                if (two == "*/") { block_depth--; i+=2; continue }
                i++; continue
            }
            if (two == "--") break
            if (two == "/*") { block_depth=1; i+=2; continue }
            c=substr(line,i,1)
            if (c ~ /[[:space:]]/) { i++; continue }
            token=""
            while (i <= length(line)) {
                c=substr(line,i,1)
                if (c !~ /[A-Za-z_]/ && token == "") break
                if (c !~ /[A-Za-z0-9_$]/) break
                token=token c
                i++
            }
            if (token != "") { print toupper(token); exit }
            print toupper(c); exit
        }
    }' "$_file"
}

validate_pgss_explain_target() {
    _file=$1
    _keyword=$(pgss_first_keyword "$_file")

    case $_keyword in
        SELECT|INSERT|UPDATE|DELETE|MERGE|VALUES)
            # PostgreSQL EXPLAIN and PREPARE both support these statement classes.
            return 0
            ;;
        WITH|TABLE)
            # WITH/TABLE are SELECT-family syntax forms. PostgreSQL itself performs
            # the final parse/prepare validation later in the normal execution flow.
            return 0
            ;;
        EXECUTE|DECLARE|CREATE)
            echo >&2
            echo "Selected statement is in PostgreSQL EXPLAIN's documented scope," >&2
            echo "but pg_stat_statements replay cannot safely reconstruct it in this mode." >&2
            printf '  queryid        : %s\n' "$QUERYID" >&2
            printf '  statement type : %s\n' "$_keyword" >&2
            echo >&2
            echo "PostgreSQL EXPLAIN also documents EXECUTE, DECLARE, CREATE TABLE AS," >&2
            echo "and CREATE MATERIALIZED VIEW AS. This script does not replay those" >&2
            echo "from pg_stat_statements because they can depend on session state or" >&2
            echo "have object-creation side effects under EXPLAIN ANALYZE." >&2
            echo "Use a SQL file and review the execution context explicitly if needed." >&2
            ;;
        '')
            echo "ERROR: pg_stat_statements query text does not contain a SQL statement." >&2
            ;;
        *)
            echo >&2
            echo "Selected pg_stat_statements entry is not a supported EXPLAIN target." >&2
            printf '  queryid        : %s\n' "$QUERYID" >&2
            printf '  statement type : %s\n' "$_keyword" >&2
            echo >&2
            echo "PostgreSQL documents EXPLAIN for SELECT, INSERT, UPDATE, DELETE, MERGE," >&2
            echo "VALUES, EXECUTE, DECLARE, CREATE TABLE AS, and CREATE MATERIALIZED VIEW AS." >&2
            echo "Utility statements such as SET/SHOW/RESET are not EXPLAIN targets." >&2
            ;;
    esac
    return 1
}

load_pg_stat_statements_query() {
    PGSS_LOOKUP_USER=$(run_psql -X -qAt -v ON_ERROR_STOP=1 -c 'SELECT current_user;' 2>/dev/null || printf '%s' "$PGUSER")
    PGSS_LOOKUP_DATABASE=$PGDATABASE

    while :; do
        printf 'Query ID (signed bigint, empty to cancel): ' >&2
        IFS= read -r QUERYID || return 1
        [ -n "$QUERYID" ] || { echo "Cancelled."; return 1; }
        if ! printf '%s\n' "$QUERYID" | grep -Eq '^-?[0-9]+$'; then
            echo "ERROR: queryid must be a signed integer." >&2
            continue
        fi

        _pgss_source_file="$work_dir/pgss-sources.txt"
        : > "$_pgss_source_file"
        if ! run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 -v queryid="$QUERYID" <<SQL > "$_pgss_source_file" 2>"$work_dir/pgss.err"
SELECT s.dbid,
       COALESCE(d.datname, ''),
       s.userid,
       COALESCE(r.rolname, ''),
       CASE WHEN r.rolname IS NULL THEN 'missing'
            WHEN r.rolcanlogin THEN 'yes'
            ELSE 'no'
       END
FROM $PGSS_RELATION s
LEFT JOIN pg_database d ON d.oid=s.dbid
LEFT JOIN pg_roles r ON r.oid=s.userid
WHERE s.queryid=:'queryid'::bigint
  AND s.query IS NOT NULL
GROUP BY s.dbid,d.datname,s.userid,r.rolname,r.rolcanlogin
ORDER BY d.datname NULLS LAST, r.rolname NULLS LAST, s.dbid, s.userid;
SQL
        then
            cat "$work_dir/pgss.err" >&2
            echo "ERROR: invalid queryid or pg_stat_statements query failed." >&2
            continue
        fi

        _source_count=$(awk 'END{print NR+0}' "$_pgss_source_file")
        if [ "$_source_count" -eq 0 ]; then
            echo "ERROR: Query ID not found in pg_stat_statements." >&2
            continue
        fi

        if [ "$_source_count" -eq 1 ]; then
            _source_line=$(sed -n '1p' "$_pgss_source_file")
        else
            echo "Query ID found for multiple database/user entries:"
            _n=1
            while IFS='|' read -r _dbid _dbname _userid _username _canlogin; do
                [ -n "$_dbname" ] || _dbname="<database oid $_dbid no longer exists>"
                _display_user=$_username
                [ -n "$_display_user" ] || _display_user="<user oid $_userid no longer exists>"
                printf '  %s) database=%s (dbid=%s), user=%s (userid=%s, login=%s)\n' "$_n" "$_dbname" "$_dbid" "$_display_user" "$_userid" "$_canlogin"
                _n=$((_n+1))
            done < "$_pgss_source_file"
            while :; do
                printf 'Select source entry [1]: ' >&2
                IFS= read -r _choice || return 1
                [ -n "$_choice" ] || _choice=1
                case $_choice in ''|*[!0-9]*) echo "ERROR: enter a valid number." >&2; continue ;; esac
                [ "$_choice" -ge 1 ] && [ "$_choice" -le "$_source_count" ] || { echo "ERROR: selection out of range." >&2; continue; }
                _source_line=$(sed -n "${_choice}p" "$_pgss_source_file")
                break
            done
        fi

        IFS='|' read -r _source_dbid _source_database _source_userid _source_user _source_canlogin <<EOF
$_source_line
EOF
        if [ -z "$_source_database" ]; then
            echo "ERROR: pg_stat_statements entry refers to database oid $_source_dbid, but that database no longer exists." >&2
            continue
        fi
        _source_user_display=$_source_user
        [ -n "$_source_user_display" ] || _source_user_display="<user oid $_source_userid no longer exists>"

        _count=$(run_psql -X -qAt -v ON_ERROR_STOP=1 -v queryid="$QUERYID" -v dbid="$_source_dbid" -v userid="$_source_userid" <<SQL 2>"$work_dir/pgss.err" || true
SELECT count(*)
FROM (
    SELECT DISTINCT query
    FROM $PGSS_RELATION
    WHERE dbid=:'dbid'::oid
      AND userid=:'userid'::oid
      AND queryid=:'queryid'::bigint
      AND query IS NOT NULL
) q;
SQL
        )
        if [ -s "$work_dir/pgss.err" ]; then
            cat "$work_dir/pgss.err" >&2
            echo "ERROR: pg_stat_statements query lookup failed." >&2
            continue
        fi
        case $_count in ''|*[!0-9]*) echo "ERROR: could not validate queryid." >&2; continue ;; esac
        if [ "$_count" -eq 0 ]; then
            echo "ERROR: Query ID disappeared from pg_stat_statements during lookup." >&2
            continue
        fi
        if [ "$_count" -gt 1 ]; then
            echo "ERROR: multiple different query texts share this queryid for database $_source_database / user $_source_user_display; use a SQL file to avoid ambiguity." >&2
            continue
        fi

        _pgss_sql="$work_dir/pgss-query.sql"
        if ! run_psql -X -qAt -v ON_ERROR_STOP=1 -v queryid="$QUERYID" -v dbid="$_source_dbid" -v userid="$_source_userid" <<SQL > "$_pgss_sql" 2>"$work_dir/pgss.err"
SELECT DISTINCT query
FROM $PGSS_RELATION
WHERE dbid=:'dbid'::oid
  AND userid=:'userid'::oid
  AND queryid=:'queryid'::bigint
  AND query IS NOT NULL
LIMIT 1;
SQL
        then
            cat "$work_dir/pgss.err" >&2
            continue
        fi
        [ -s "$_pgss_sql" ] || { echo "ERROR: pg_stat_statements query text is empty." >&2; continue; }
        if grep -Fx '<insufficient privilege>' "$_pgss_sql" >/dev/null 2>&1; then
            echo "ERROR: insufficient privilege to read this pg_stat_statements query text." >&2
            if [ "$PGUSER" != postgres ]; then
                echo "       Re-run this source as postgres or use a SQL file." >&2
            fi
            continue
        fi

        if ! validate_pgss_explain_target "$_pgss_sql"; then
            echo >&2
            echo "안내: 현재 queryid는 실행계획 분석 대상이 아니므로 bind 입력 단계로 진행하지 않습니다." >&2
            echo "      다른 queryid를 입력하세요." >&2
            echo >&2
            continue
        fi

        ORIGINAL_QUERY_USER=$_source_user_display
        ORIGINAL_QUERY_USERID=$_source_userid
        ORIGINAL_QUERY_USER_CAN_LOGIN=$_source_canlogin
        PGSS_RAW_SQL_FILE=$_pgss_sql
        SQL_FILE=$_pgss_sql
        SQL_SOURCE_KIND=pgss
        SQL_SOURCE_DESC="pg_stat_statements queryid=$QUERYID"

        if [ "$_source_database" != "$PGDATABASE" ]; then
            if confirm_database_switch "$PGDATABASE" "$_source_database"; then
                switch_database "$_source_database" || return 1
            else
                echo "Cancelled: EXPLAIN should run in the query's source database." >&2
                return 1
            fi
        fi

        prepare_pgss_source_execution_user "$_source_user" "$_source_userid" "$_source_canlogin" || {
            echo "Cancelled: execution user context was not accepted." >&2
            return 1
        }

        PGSS_EXECUTE_USER=$(run_psql -X -qAt -v ON_ERROR_STOP=1 -c 'SELECT current_user;' 2>/dev/null || printf '%s' "$PGUSER")
        PGSS_SEARCH_PATH=$(run_psql -X -qAt -v ON_ERROR_STOP=1 -c 'SHOW search_path;' 2>/dev/null || printf '<unavailable>')

        echo
        echo "pg_stat_statements Query Information"
        printf '  queryid              : %s\n' "$QUERYID"
        printf '  lookup database      : %s\n' "$PGSS_LOOKUP_DATABASE"
        printf '  lookup user          : %s\n' "$PGSS_LOOKUP_USER"
        printf '  source database      : %s\n' "$PGDATABASE"
        printf '  original user        : %s (userid=%s, login=%s)\n' "$ORIGINAL_QUERY_USER" "$ORIGINAL_QUERY_USERID" "$ORIGINAL_QUERY_USER_CAN_LOGIN"
        printf '  execute user         : %s\n' "$PGSS_EXECUTE_USER"
        printf '  current search_path  : %s\n' "$PGSS_SEARCH_PATH"
        printf '  historical search_path : unavailable in pg_stat_statements\n'
        echo
        echo "안내: pg_stat_statements의 query/dbid/userid 조회는 lookup 환경에서 먼저 완료했습니다."
        echo "      이후 EXPLAIN은 source database와 위 execute user의 실제 로그인 연결로 수행합니다."
        echo "      SET ROLE 및 SET search_path는 수행하지 않습니다."
        echo "      원본 세션에서 별도로 변경된 search_path/세션 GUC/임시 객체 등은 pg_stat_statements만으로 복원할 수 없습니다."
        echo "      pg_stat_statements의 query는 정규화된 대표 SQL이며 원래 literal 값은 저장되지 않습니다."
        echo
        return 0
    done
}

pgss_parameter_context() {
    _file=$1
    _n=$2
    if grep -Eiq "[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp][[:space:]]+[Ww][Ii][Tt][Hh][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'timestamptz'; return 0; fi
    if grep -Eiq "[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp][[:space:]]+[Ww][Ii][Tt][Hh][Oo][Uu][Tt][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'timestamp'; return 0; fi
    if grep -Eiq "[Tt][Ii][Mm][Ee][[:space:]]+[Ww][Ii][Tt][Hh][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'timetz'; return 0; fi
    if grep -Eiq "[Tt][Ii][Mm][Ee][[:space:]]+[Ww][Ii][Tt][Hh][Oo][Uu][Tt][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'time'; return 0; fi
    if grep -Eiq "[Ii][Nn][Tt][Ee][Rr][Vv][Aa][Ll][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'interval'; return 0; fi
    if grep -Eiq "[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'timestamp'; return 0; fi
    if grep -Eiq "[Dd][Aa][Tt][Ee][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'date'; return 0; fi
    if grep -Eiq "[Tt][Ii][Mm][Ee][[:space:]]+\\\$${_n}([^0-9]|$)" "$_file"; then printf 'time'; return 0; fi
    printf ''
}

pgss_render_sql_value() {
    _value=$1
    _context=$2
    if [ "$_value" = '\N' ]; then
        printf 'NULL'
        return 0
    fi
    _escaped=$(printf '%s' "$_value" | sed "s/'/''/g")
    if [ -n "$_context" ]; then
        printf "'%s'" "$_escaped"
        return 0
    fi
    if printf '%s\n' "$_value" | grep -Eq '^[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?$'; then
        printf '%s' "$_value"
        return 0
    fi
    case $(printf '%s' "$_value" | tr '[:upper:]' '[:lower:]') in
        true) printf 'TRUE'; return 0 ;;
        false) printf 'FALSE'; return 0 ;;
    esac
    printf "'%s'" "$_escaped"
}

pgss_rewrite_typed_literals() {
    _src=$1
    _dst=$2
    sed -E \
        -e 's/[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp][[:space:]]+[Ww][Ii][Tt][Hh][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+(\$[1-9][0-9]*)/(\1)::timestamptz/g' \
        -e 's/[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp][[:space:]]+[Ww][Ii][Tt][Hh][Oo][Uu][Tt][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+(\$[1-9][0-9]*)/(\1)::timestamp/g' \
        -e 's/[Tt][Ii][Mm][Ee][[:space:]]+[Ww][Ii][Tt][Hh][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+(\$[1-9][0-9]*)/(\1)::timetz/g' \
        -e 's/[Tt][Ii][Mm][Ee][[:space:]]+[Ww][Ii][Tt][Hh][Oo][Uu][Tt][[:space:]]+[Tt][Ii][Mm][Ee][[:space:]]+[Zz][Oo][Nn][Ee][[:space:]]+(\$[1-9][0-9]*)/(\1)::time/g' \
        -e 's/[Ii][Nn][Tt][Ee][Rr][Vv][Aa][Ll][[:space:]]+(\$[1-9][0-9]*)/(\1)::interval/g' \
        -e 's/[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp][[:space:]]+(\$[1-9][0-9]*)/(\1)::timestamp/g' \
        -e 's/[Dd][Aa][Tt][Ee][[:space:]]+(\$[1-9][0-9]*)/(\1)::date/g' \
        -e 's/[Tt][Ii][Mm][Ee][[:space:]]+(\$[1-9][0-9]*)/(\1)::time/g' \
        "$_src" > "$_dst"
}

build_pgss_normalized_candidate_map() {
    _src_file=$1
    _first_param=$2
    _last_param=$3
    _out_file=$4
    : > "$_out_file"
    [ "$_first_param" -le "$_last_param" ] || return 0

    _source_sql=$(cat "$_src_file")
    if ! run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -v source_sql="$_source_sql" -v first_param="$_first_param" -v last_param="$_last_param" <<'SQL' > "$_out_file" 2>"$work_dir/pgss-normalized-candidates.err"
WITH RECURSIVE
src AS (
    SELECT regexp_replace(:'source_sql', E'[\n\r\t]+', ' ', 'g') AS q
), params AS (
    SELECT generate_series(:'first_param'::integer, :'last_param'::integer) AS n
), patterns AS (
    SELECT '(?:"(?:[^"]|"")+"|[a-z_][a-z_0-9$]*)'::text AS ident,
           '(?:::(?:text|integer|bigint|smallint|numeric|boolean|date|uuid|character varying|double precision|timestamp(?: with(?:out)? time zone)?|time(?: with(?:out)? time zone)?|interval))?'::text AS cast_pattern,
           '(?:(?:date|time(?: with(?:out)? time zone)?|timestamp(?: with(?:out)? time zone)?|interval)\s+)?'::text AS typed_prefix
), refs AS (
    SELECT p.n, (z.m)[1] AS ref
    FROM src s
    CROSS JOIN params p
    CROSS JOIN patterns x
    CROSS JOIN LATERAL regexp_matches(
        s.q,
        '(' || x.ident || '(?:\.' || x.ident || ')?)\s*' || x.cast_pattern ||
        '\s*(?:=|<>|!=|<=|>=|<|>|~~\*?|!~~\*?)\s*' || x.typed_prefix ||
        '\$' || p.n || '(?![0-9])' || x.cast_pattern,
        'gi') AS z(m)
    UNION ALL
    SELECT p.n, (z.m)[1] AS ref
    FROM src s
    CROSS JOIN params p
    CROSS JOIN patterns x
    CROSS JOIN LATERAL regexp_matches(
        s.q,
        x.typed_prefix || '\$' || p.n || '(?![0-9])' || x.cast_pattern ||
        '\s*(?:=|<>|!=|<=|>=|<|>|~~\*?|!~~\*?)\s*(' || x.ident || '(?:\.' || x.ident || ')?)\s*' || x.cast_pattern,
        'gi') AS z(m)
    UNION ALL
    SELECT p.n, (z.m)[1] AS ref
    FROM src s
    CROSS JOIN params p
    CROSS JOIN patterns x
    CROSS JOIN LATERAL regexp_matches(
        s.q,
        '(' || x.ident || '(?:\.' || x.ident || ')?)\s+(?:not\s+)?in\s*\([^)]*\$' || p.n || '(?![0-9])[^)]*\)',
        'gi') AS z(m)
), param_edges AS (
    SELECT (m)[1]::integer AS a, (m)[2]::integer AS b
    FROM src,
         LATERAL regexp_matches(q, '\$([1-9][0-9]*)\s*=\s*\$([1-9][0-9]*)', 'g') AS r(m)
    UNION
    SELECT (m)[2]::integer, (m)[1]::integer
    FROM src,
         LATERAL regexp_matches(q, '\$([1-9][0-9]*)\s*=\s*\$([1-9][0-9]*)', 'g') AS r(m)
), walk(origin, n, path) AS (
    SELECT p.n, p.n, ARRAY[p.n]
    FROM params p
    UNION ALL
    SELECT w.origin, e.b, w.path || e.b
    FROM walk w
    JOIN param_edges e ON e.a = w.n
    WHERE NOT e.b = ANY(w.path)
      AND cardinality(w.path) < 16
), columns AS (
    SELECT DISTINCT r.n,
           r.ref,
           (parse_ident(r.ref))[cardinality(parse_ident(r.ref))] AS column_name,
           CASE WHEN cardinality(parse_ident(r.ref)) >= 2
                THEN (parse_ident(r.ref))[cardinality(parse_ident(r.ref)) - 1]
                ELSE NULL
           END AS qualifier
    FROM refs r
    WHERE cardinality(parse_ident(r.ref)) BETWEEN 1 AND 3
), direct_candidates AS (
    SELECT DISTINCT c.n,
           cls.oid AS relid,
           format('%I.%I', ns.nspname, cls.relname) AS relation,
           c.column_name,
           CASE
             WHEN c.qualifier IS NOT NULL AND lower(c.qualifier) = lower(cls.relname) THEN 1
             WHEN pg_table_is_visible(cls.oid) THEN 2
             ELSE 3
           END AS priority
    FROM columns c
    CROSS JOIN src s
    JOIN pg_attribute a
      ON a.attname = c.column_name
     AND a.attnum > 0
     AND NOT a.attisdropped
    JOIN pg_class cls
      ON cls.oid = a.attrelid
     AND cls.relkind IN ('r','p','v','m','f')
    JOIN pg_namespace ns
      ON ns.oid = cls.relnamespace
    WHERE ns.nspname NOT IN ('pg_catalog','information_schema')
      AND position(lower(cls.relname) in lower(s.q)) > 0
      AND has_table_privilege(cls.oid, 'SELECT')
), propagated AS (
    SELECT DISTINCT w.origin AS parameter,
           d.relation,
           d.column_name,
           d.priority + CASE WHEN w.n = w.origin THEN 0 ELSE 10 END AS priority
    FROM walk w
    JOIN direct_candidates d ON d.n = w.n
), best AS (
    SELECT parameter, min(priority) AS priority
    FROM propagated
    GROUP BY parameter
)
SELECT p.parameter, p.relation, p.column_name, p.priority
FROM propagated p
JOIN best b USING (parameter, priority)
WHERE p.relation !~ E'[|\n\r]'
  AND p.column_name !~ E'[|\n\r]'
ORDER BY p.parameter, p.priority, p.relation, p.column_name;
SQL
    then
        : > "$_out_file"
        return 1
    fi
    unset _source_sql
    return 0
}

show_pgss_normalized_candidates() {
    _param=$1
    _candidate_map=$2
    PGSS_NORMALIZED_DEFAULT_AVAILABLE=no
    PGSS_NORMALIZED_DEFAULT_VALUE=

    _candidate_file="$work_dir/pgss-normalized-candidates-${_param}.txt"
    awk -F'|' -v n="$_param" '$1 == n {print $2 "|" $3}' "$_candidate_map" | sort -u > "$_candidate_file"
    _candidate_count=$(awk 'END {print NR+0}' "$_candidate_file")
    [ "$_candidate_count" -gt 0 ] || return 1

    _sample_relation=
    _sample_column=
    if [ "$_candidate_count" -eq 1 ]; then
        _candidate_line=$(sed -n '1p' "$_candidate_file")
        _sample_relation=${_candidate_line%%|*}
        _sample_column=${_candidate_line#*|}
        printf 'Auto-detected normalized constant $%s -> %s / %s\n' "$_param" "$_sample_relation" "$_sample_column"
    else
        printf '정규화 상수 $%s와 연결 가능한 테이블/컬럼 후보:\n' "$_param"
        _candidate_no=1
        while IFS='|' read -r _candidate_relation _candidate_column; do
            printf '  %s) %s / %s\n' "$_candidate_no" "$_candidate_relation" "$_candidate_column"
            _candidate_no=$((_candidate_no + 1))
        done < "$_candidate_file"
        while :; do
            printf '정규화 상수 $%s 후보 소스 선택 [1]: ' "$_param" >&2
            IFS= read -r _candidate_choice || return 1
            [ -n "$_candidate_choice" ] || _candidate_choice=1
            case $_candidate_choice in
                ''|*[!0-9]*) echo "ERROR: 후보 번호를 입력하세요." >&2; continue ;;
            esac
            if [ "$_candidate_choice" -lt 1 ] || [ "$_candidate_choice" -gt "$_candidate_count" ]; then
                printf 'ERROR: 1-%s 사이의 번호를 입력하세요.\n' "$_candidate_count" >&2
                continue
            fi
            _candidate_line=$(sed -n "${_candidate_choice}p" "$_candidate_file")
            _sample_relation=${_candidate_line%%|*}
            _sample_column=${_candidate_line#*|}
            break
        done
    fi

    _sample_file="$work_dir/pgss-normalized-values-${_param}.txt"
    : > "$_sample_file"
    if ! run_psql -X -qAt -v ON_ERROR_STOP=1 \
        -v sample_relation="$_sample_relation" -v sample_column="$_sample_column" \
        -v sample_limit="$BIND_SAMPLE_LIMIT" -v sample_timeout="$BIND_SAMPLE_TIMEOUT" <<'SQL' > "$_sample_file" 2>"$work_dir/pgss-normalized-values-${_param}.err"
BEGIN READ ONLY;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS sample_timeout \gset
SELECT format(
    'SELECT DISTINCT %1$I::text FROM %2$s WHERE %1$I IS NOT NULL AND %1$I::text <> '''' AND %1$I::text !~ E''[\n\r]'' LIMIT %3$s',
    :'sample_column', :'sample_relation'::regclass, :'sample_limit'::integer)
\gexec
COMMIT;
SQL
    then
        echo "주의: $_sample_relation / $_sample_column 후보값 조회에 실패했습니다. 직접 입력으로 진행합니다." >&2
        return 1
    fi

    _sample_count=$(awk 'END {print NR+0}' "$_sample_file")
    [ "$_sample_count" -gt 0 ] || {
        echo "안내: $_sample_relation / $_sample_column 에서 사용 가능한 비 NULL 후보값을 찾지 못했습니다." >&2
        return 1
    }

    echo
    printf '정규화 상수 $%s 후보값 (현재 테이블 DISTINCT, 최대 %s개)\n' "$_param" "$BIND_SAMPLE_LIMIT"
    printf '  source: %s / %s\n' "$_sample_relation" "$_sample_column"
    _sample_no=1
    while IFS= read -r _sample_value; do
        printf '  %s) %s\n' "$_sample_no" "$_sample_value"
        _sample_no=$((_sample_no + 1))
    done < "$_sample_file"
    PGSS_NORMALIZED_DEFAULT_VALUE=$(sed -n '1p' "$_sample_file")
    if [ -n "$PGSS_NORMALIZED_DEFAULT_VALUE" ]; then
        PGSS_NORMALIZED_DEFAULT_AVAILABLE=yes
        printf 'Default for normalized constant $%s: %s\n' "$_param" "$PGSS_NORMALIZED_DEFAULT_VALUE"
    fi
    echo '후보값은 과거 실제 literal 값이 아니라 현재 테이블의 DISTINCT 예시값입니다.'
    return 0
}

prepare_pgss_replay_sql() {
    [ "$SQL_SOURCE_KIND" = pgss ] || return 0
    [ -n "$PGSS_RAW_SQL_FILE" ] || return 0
    grep -Eq '\$[1-9][0-9]*' "$PGSS_RAW_SQL_FILE" || return 0

    _scan=$(awk '
    {
        s=$0
        while (match(s,/\$[1-9][0-9]*/)) {
            n=substr(s,RSTART+1,RLENGTH-1)+0
            pos++
            count[n]++
            if (!(n in first)) first[n]=pos
            if (n>maxn) maxn=n
            s=substr(s,RSTART+RLENGTH)
        }
    }
    END {
        guess=0
        for (n=1;n<=maxn;n++) {
            evidence=(count[n]>1)
            for (m=n+1;m<=maxn;m++)
                if ((m in first) && first[n]>first[m]) evidence=1
            if (evidence && n>guess) guess=n
        }
        printf "%d|%d\n",maxn,guess
    }' "$PGSS_RAW_SQL_FILE")
    _param_max=${_scan%%|*}
    _guess=${_scan#*|}
    case $_param_max in ''|*[!0-9]*) return 0 ;; esac
    [ "$_param_max" -gt 0 ] || return 0

    echo
    echo "pg_stat_statements 정규화 파라미터 처리"
    printf '  SQL 내 최대 파라미터 번호 : $%s\n' "$_param_max"
    if [ "$_guess" -gt 0 ]; then
        printf '  자동 분류 - 기존 bind 변수     : $1 ~ $%s\n' "$_guess"
    else
        echo '  자동 분류 - 기존 bind 변수     : 없음'
    fi
    if [ "$_guess" -lt "$_param_max" ]; then
        printf '  자동 분류 - 정규화 상수 후보   : $%s ~ $%s\n' "$((_guess + 1))" "$_param_max"
    else
        echo '  자동 분류 - 정규화 상수 후보   : 없음'
    fi
    echo
    echo "안내: pg_stat_statements는 원래 literal을 추가 \$n 파라미터로 정규화할 수 있습니다."
    echo "      정규화 상수가 테이블 컬럼과 직접 연결되거나 = 관계의 다른 파라미터를 통해 컬럼과 연결되면"
    echo "      현재 테이블에서 DISTINCT 후보값을 최대 $BIND_SAMPLE_LIMIT개 조회하여 먼저 보여줍니다."
    echo "      연결 컬럼을 찾을 수 없는 상수만 직접 입력합니다. 후보값은 과거 실제 literal 값은 아닙니다."

    if [ -n "${PGSS_ORIGINAL_BIND_MAX:-}" ]; then
        _bind_max=$PGSS_ORIGINAL_BIND_MAX
    else
        while :; do
            printf '자동 분류 결과가 맞습니까? y/n [y]: ' >&2
            IFS= read -r _class_ok || return 1
            [ -n "$_class_ok" ] || _class_ok=y
            _class_ok=$(printf '%s' "$_class_ok" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            case $_class_ok in
                y)
                    _bind_max=$_guess
                    break
                    ;;
                n)
                    while :; do
                        printf '기존 bind 변수의 마지막 번호 (예: $1~$6이면 6, 기존 bind가 없으면 0): ' >&2
                        IFS= read -r _bind_max || return 1
                        case $_bind_max in
                            ''|*[!0-9]*) echo "ERROR: 0부터 $_param_max 사이의 숫자를 입력하세요." >&2; continue ;;
                        esac
                        [ "$_bind_max" -ge 0 ] && [ "$_bind_max" -le "$_param_max" ] || { echo "ERROR: 0부터 $_param_max 사이의 숫자를 입력하세요." >&2; continue; }
                        if [ "$_bind_max" -eq 0 ]; then
                            printf '주의: 0을 선택하면 $1~$%s를 모두 정규화 상수로 처리합니다. 계속하시겠습니까? y/n [n]: ' "$_param_max" >&2
                            IFS= read -r _zero_ok || return 1
                            [ -n "$_zero_ok" ] || _zero_ok=n
                            _zero_ok=$(printf '%s' "$_zero_ok" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                            [ "$_zero_ok" = y ] || continue
                        fi
                        break
                    done
                    break
                    ;;
                *) echo "ERROR: y 또는 n을 입력하세요." >&2 ;;
            esac
        done
    fi

    _invalid=no
    _n=1
    while [ "$_n" -le "$_bind_max" ]; do
        _context=$(pgss_parameter_context "$PGSS_RAW_SQL_FILE" "$_n")
        if [ -n "$_context" ]; then
            echo "ERROR: \$$_n 은 $_context literal 위치에 있어 기존 bind로 분류할 수 없습니다." >&2
            _invalid=yes
            break
        fi
        _n=$((_n+1))
    done
    [ "$_invalid" = no ] || return 1
    PGSS_ORIGINAL_BIND_MAX=$_bind_max

    echo
    echo "최종 파라미터 분류"
    if [ "$PGSS_ORIGINAL_BIND_MAX" -gt 0 ]; then
        printf '  기존 bind 변수       : $1 ~ $%s\n' "$PGSS_ORIGINAL_BIND_MAX"
    else
        echo '  기존 bind 변수       : 없음'
    fi
    if [ "$PGSS_ORIGINAL_BIND_MAX" -lt "$_param_max" ]; then
        printf '  정규화 상수          : $%s ~ $%s\n' "$((PGSS_ORIGINAL_BIND_MAX + 1))" "$_param_max"
    else
        echo '  정규화 상수          : 없음'
    fi
    echo

    PGSS_NORMALIZED_VALUES_FILE="$work_dir/pgss-normalized-values-used.txt"
    _map="$work_dir/pgss-normalized-map.tsv"
    _typed="$work_dir/pgss-typed-rewrite.sql"
    _replay="$work_dir/pgss-replay.sql"
    _candidate_map="$work_dir/pgss-normalized-candidate-map.txt"
    : > "$PGSS_NORMALIZED_VALUES_FILE"
    : > "$_map"
    : > "$_candidate_map"

    _first_normalized=$((PGSS_ORIGINAL_BIND_MAX + 1))
    if [ "$_first_normalized" -le "$_param_max" ]; then
        if ! build_pgss_normalized_candidate_map "$PGSS_RAW_SQL_FILE" "$_first_normalized" "$_param_max" "$_candidate_map"; then
            echo "안내: 정규화 상수의 테이블/컬럼 후보 자동 탐색에 실패하여 직접 입력 fallback을 사용합니다." >&2
        fi
    fi

    _n=$_first_normalized
    while [ "$_n" -le "$_param_max" ]; do
        if grep -Eq "\\\$${_n}([^0-9]|$)" "$PGSS_RAW_SQL_FILE"; then
            _context=$(pgss_parameter_context "$PGSS_RAW_SQL_FILE" "$_n")
            PGSS_NORMALIZED_DEFAULT_AVAILABLE=no
            PGSS_NORMALIZED_DEFAULT_VALUE=
            show_pgss_normalized_candidates "$_n" "$_candidate_map" || true

            while :; do
                if [ "$PGSS_NORMALIZED_DEFAULT_AVAILABLE" = yes ]; then
                    if [ -n "$_context" ]; then
                        printf '정규화 상수 $%s 값 [%s] (context=%s, \\N=SQL NULL): ' "$_n" "$PGSS_NORMALIZED_DEFAULT_VALUE" "$_context" >&2
                    else
                        printf '정규화 상수 $%s 값 [%s] (\\N=SQL NULL): ' "$_n" "$PGSS_NORMALIZED_DEFAULT_VALUE" >&2
                    fi
                elif [ -n "$_context" ]; then
                    printf '정규화 상수 $%s 값 (context=%s, \\N=SQL NULL / 실제 원본 literal이 NULL인 경우만): ' "$_n" "$_context" >&2
                else
                    printf '정규화 상수 $%s 값 (\\N=SQL NULL / 실제 원본 literal이 NULL인 경우만): ' "$_n" >&2
                fi
                IFS= read -r _value || return 1
                if [ -z "$_value" ] && [ "$PGSS_NORMALIZED_DEFAULT_AVAILABLE" = yes ]; then
                    _value=$PGSS_NORMALIZED_DEFAULT_VALUE
                elif [ -z "$_value" ]; then
                    echo "ERROR: pg_stat_statements에는 원래 literal 값이 없고 자동 후보도 없으므로 값을 입력해야 합니다." >&2
                    continue
                fi

                if [ "$_value" = '\N' ]; then
                    echo >&2
                    echo "주의: \\N은 원본 literal을 실제 SQL NULL로 복원합니다." >&2
                    echo "      NULL을 =, <>, <, > 등의 일반 비교식에 사용하면 결과가 TRUE가 아니라 UNKNOWN이 되어" >&2
                    echo "      WHERE 조건에서 제외되고 실행 계획의 해당 branch/relation scan이 제거될 수 있습니다." >&2
                    echo "      원래 literal이 실제 NULL이었다는 것이 확실한 경우에만 사용하세요." >&2
                    _null_confirmed=no
                    while :; do
                        printf '정규화 상수 $%s를 SQL NULL로 복원하시겠습니까? y/n [n]: ' "$_n" >&2
                        IFS= read -r _null_ok || return 1
                        [ -n "$_null_ok" ] || _null_ok=n
                        _null_ok=$(printf '%s' "$_null_ok" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                        case $_null_ok in
                            y) _null_confirmed=yes; break ;;
                            n) _null_confirmed=no; break ;;
                            *) echo "ERROR: y 또는 n을 입력하세요." >&2 ;;
                        esac
                    done
                    if [ "$_null_confirmed" != yes ]; then
                        echo "안내: SQL NULL 복원을 취소했습니다. 값을 다시 입력하세요." >&2
                        continue
                    fi
                    PGSS_NORMALIZED_NULL_USED=yes
                fi
                break
            done

            _sql_value=$(pgss_render_sql_value "$_value" "$_context")
            printf '%s\t%s\n' "$_n" "$_sql_value" >> "$_map"
            printf '$%s [normalized constant%s] = %s\n' "$_n" "${_context:+ / $_context}" "${_value}" >> "$PGSS_NORMALIZED_VALUES_FILE"
        fi
        _n=$((_n+1))
    done

    if [ ! -s "$_map" ]; then
        echo "안내: 정규화 상수로 분류된 파라미터가 없습니다. 원본 SQL을 그대로 사용합니다."
        return 0
    fi

    pgss_rewrite_typed_literals "$PGSS_RAW_SQL_FILE" "$_typed" || return 1
    awk -F '\t' '
    NR==FNR {
        p=index($0,"\t")
        if (p>0) {
            n=substr($0,1,p-1)
            repl[n]=substr($0,p+1)
        }
        next
    }
    {
        s=$0
        out=""
        while (match(s,/\$[1-9][0-9]*/)) {
            n=substr(s,RSTART+1,RLENGTH-1)
            out=out substr(s,1,RSTART-1)
            if (n in repl) out=out repl[n]
            else out=out substr(s,RSTART,RLENGTH)
            s=substr(s,RSTART+RLENGTH)
        }
        print out s
    }' "$_map" "$_typed" > "$_replay" || return 1

    SQL_FILE=$_replay
    echo
    echo "안내: 정규화 상수는 입력값으로 SQL에 복원했습니다."
    if [ "$PGSS_ORIGINAL_BIND_MAX" -gt 0 ]; then
        printf '      기존 bind로 분류된 $1~$%s는 기존 후보값/기본값 탐색 절차로 처리합니다.\n' "$PGSS_ORIGINAL_BIND_MAX"
    else
        echo "      기존 bind로 분류된 파라미터가 없어 모든 \$n 값을 literal로 복원했습니다."
    fi
    echo
}

detect_pg_stat_statements
SQL_FILE=${1:-}
SQL_SOURCE_DESC="SQL file"
if [ -z "$SQL_FILE" ] && [ "$PGSS_AVAILABLE" = yes ]; then
    echo "Target SQL source"
    echo "  1) SQL file"
    echo "  2) pg_stat_statements queryid"
    printf 'Select [1]: ' >&2
    IFS= read -r _source_choice || exit 1
    [ -n "$_source_choice" ] || _source_choice=1
    case $_source_choice in
        1) ;;
        2) prepare_pgss_execution_user || exit 1; load_pg_stat_statements_query || exit 1 ;;
        *) echo "ERROR: enter 1 or 2." >&2; exit 1 ;;
    esac
fi
while :; do
    if [ -z "$SQL_FILE" ]; then
        printf 'Target SQL file path (empty to cancel): ' >&2
        IFS= read -r SQL_FILE || exit 1
        [ -n "$SQL_FILE" ] || { echo "Cancelled."; exit 1; }
        SQL_SOURCE_DESC="SQL file"
    fi
    [ -f "$SQL_FILE" ] && [ -r "$SQL_FILE" ] && break
    printf 'ERROR: cannot read SQL file: %s\n' "$SQL_FILE" >&2
    SQL_FILE=
done

if [ "$SQL_SOURCE_KIND" = pgss ]; then
    prepare_pgss_replay_sql || { echo "ERROR: pg_stat_statements SQL replay preparation failed." >&2; exit 1; }
fi

SERVER_VERSION_NUM=$(run_psql -X -Atqc 'SHOW server_version_num') || exit 1
case $SERVER_VERSION_NUM in ''|*[!0-9]*) echo "ERROR: invalid server_version_num" >&2; exit 1 ;; esac

ask() {
    prompt=$1; default=$2
    while :; do
        printf '%s [%s]: ' "$prompt" "$default" >&2
        IFS= read -r ans || return 1
        [ -n "$ans" ] || ans=$default
        ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $ans in
            y) printf 'yes'; return 0 ;;
            n) printf 'no'; return 0 ;;
            *) echo "ERROR: enter y or n." >&2 ;;
        esac
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
    _json_file=$1; _rel_file=$2; _rel_oid_file=$3; _dml_file=$4
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
           to_regclass(format('%I.%I', node->>'Schema', node->>'Relation Name'))::oid::text AS objid,
           format('%I.%I', node->>'Schema', node->>'Relation Name') AS value
    FROM nodes
    WHERE node ? 'Schema' AND node ? 'Relation Name'
    UNION ALL
    SELECT DISTINCT 'D', '', node->>'Operation'
    FROM nodes
    WHERE node->>'Operation' IN ('Insert','Update','Delete','Merge')
)
SELECT kind || '|' || objid || '|' || value FROM rows ORDER BY kind, value;
SQL
    } | run_psql -X -qAt -v ON_ERROR_STOP=1 > "$_meta" || return 1
    awk -F'|' '$1=="R" {print $3}' "$_meta" > "$_rel_file"
    awk -F'|' '$1=="R" && $2!="" {print $2"|"$3}' "$_meta" > "$_rel_oid_file"
    awk -F'|' '$1=="D" {print $3}' "$_meta" > "$_dml_file"
}

render_plan_summary() {
    _json_file=$1
    _text_file=$2
    _structure="$work_dir/plan-structure.tsv"
    _sep=$(printf '\t')

    {
        json_sql_prefix "$_json_file"
        cat <<'SQL'
nodes(path, node, depth, prefix, is_last, child_index, parent_node_type) AS (
    SELECT ARRAY[]::integer[], doc->0->'Plan', 0, ''::text, true, 0, ''::text
    FROM plan_source
  UNION ALL
    SELECT n.path || c.ord::integer,
           c.child,
           n.depth + 1,
           n.prefix || CASE WHEN n.depth=0 THEN '' WHEN n.is_last THEN '    ' ELSE '|   ' END,
           c.ord = jsonb_array_length(COALESCE(n.node->'Plans','[]'::jsonb)),
           c.ord::integer,
           COALESCE(n.node->>'Node Type','')
    FROM nodes n
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(n.node->'Plans','[]'::jsonb)) WITH ORDINALITY AS c(child,ord)
)
SELECT array_to_string(path,'.'), depth, prefix,
       CASE WHEN is_last THEN '1' ELSE '0' END,
       CASE
           WHEN parent_node_type IN ('Nested Loop','Hash Join','Merge Join') AND child_index=1 THEN '[Outer] '
           WHEN parent_node_type IN ('Nested Loop','Hash Join','Merge Join') AND child_index=2 THEN '[Inner] '
           ELSE ''
       END
FROM nodes
ORDER BY path;
SQL
    } | run_psql -X -qAt -F "$_sep" -v ON_ERROR_STOP=1 > "$_structure" || return 1

    [ -s "$_structure" ] || { echo "ERROR: JSON plan structure was not generated." >&2; return 1; }

    _summary_width=${PLAN_SUMMARY_WIDTH:-}
    case $_summary_width in ''|*[!0-9]*) _summary_width= ;; esac
    if [ -z "$_summary_width" ]; then
        _tty_cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
        case $_tty_cols in
            ''|*[!0-9]*) _summary_width=120 ;;
            *)
                if [ "$_tty_cols" -gt 142 ]; then _summary_width=140
                elif [ "$_tty_cols" -ge 52 ]; then _summary_width=$((_tty_cols - 2))
                else _summary_width=$_tty_cols
                fi
                ;;
        esac
    fi
    [ "$_summary_width" -lt 40 ] && _summary_width=40

    awk -F '\t' -v width="$_summary_width" '
NR==FNR {
    struct_count++
    struct_depth[struct_count]=$2+0
    struct_prefix[struct_count]=$3
    struct_last[struct_count]=$4+0
    struct_role[struct_count]=$5
    next
}
function add_detail(i,text) { if (i>0) { detail_count[i]++; detail[i,detail_count[i]]=text } }
function spaces(n,    s) { s=""; while (n-->0) s=s " "; return s }
function trimleft(s) { sub(/^[[:space:]]+/,"",s); return s }
function wrap_line(first,cont,text,    avail,cut,j,piece) {
    text=trimleft(text)
    while (text!="") {
        avail=width-length(first); if (avail<20) avail=20
        if (length(text)<=avail) { print first text; return }
        cut=0
        for (j=avail; j>=1; j--) if (substr(text,j,1)==" ") { cut=j; break }
        if (cut==0) cut=avail
        piece=substr(text,1,cut); sub(/[[:space:]]+$/,"",piece); print first piece
        text=substr(text,cut+1); text=trimleft(text); first=cont
    }
}
function wrap_node(first,cont,text,    p,head,tail) {
    if (length(first)+length(text)<=width) { print first text; return }
    p=index(text," (actual ")
    if (p>0) { head=substr(text,1,p-1); tail=substr(text,p+1); wrap_line(first,cont,head); wrap_line(cont,cont,tail); return }
    p=index(text," (never executed)")
    if (p>0) { head=substr(text,1,p-1); tail=substr(text,p+1); wrap_line(first,cont,head); wrap_line(cont,cont,tail); return }
    wrap_line(first,cont,text)
}
{
    raw=$0; t=raw; sub(/^[[:space:]]+/,"",t)
    if (!root_seen && t!="") { node_count++; node_text[node_count]=t; current_node=node_count; root_seen=1; next }
    if (t ~ /^->/) { node_count++; sub(/^->[[:space:]]*/,"",t); node_text[node_count]=t; current_node=node_count; next }
    if (t ~ /^(Sort Key|Index Cond|Recheck Cond|Hash Cond|Merge Cond|Join Filter|Filter):/) { add_detail(current_node,t); next }
    if (t ~ /^(CTE|InitPlan|SubPlan)([[:space:]]|$)/) { add_detail(current_node,t); next }
}
END {
    if (node_count != struct_count) {
        printf "WARNING: JSON plan node count (%d) and TEXT plan node count (%d) differ; structured summary omitted to avoid an incorrect tree.\n", struct_count, node_count
    } else {
        for (i=1; i<=node_count; i++) {
            role=struct_role[i]
            if (struct_depth[i]==0) { first=""; cont="    "; detail_prefix="    " }
            else {
                connector=(struct_last[i] ? "`-- " : "|-- ")
                first=struct_prefix[i] connector role
                detail_prefix=struct_prefix[i] (struct_last[i] ? "    " : "|   ")
                cont=detail_prefix spaces(length(role))
            }
            wrap_node(first,cont,node_text[i])
            for (j=1; j<=detail_count[i]; j++) {
                dtext=detail[i,j]; colon=index(dtext,":")
                if (colon>0) {
                    label=substr(dtext,1,colon-1); value=substr(dtext,colon+1)
                    detail_label=sprintf("%-13s : ",label)
                    wrap_line(detail_prefix detail_label, detail_prefix spaces(length(detail_label)), value)
                } else wrap_line(detail_prefix,detail_prefix "    ",dtext)
            }
        }
    }
}' "$_structure" "$_text_file"
}

build_bind_map() {
    bind_map="$work_dir/bind-map.txt"
    if ! {
        cat "$prepare_file"
        cat <<'BIND_MAP_SQL'
BEGIN;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS map_timeout \gset
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
        echo 'Automatic bind-column mapping unavailable; SQL text fallback will be used.' >&2
    fi
}

build_bind_constant_map() {
    bind_constant_map="$work_dir/bind-constant-map.txt"
    if ! {
        cat "$prepare_file"
        cat <<'BIND_CONSTANT_SQL'
BEGIN;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS map_timeout \gset
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

build_bind_text_fallback_maps() {
    bind_text_map="$work_dir/bind-text-map.txt"
    bind_text_constant_map="$work_dir/bind-text-constant-map.txt"
    : > "$bind_text_map"
    : > "$bind_text_constant_map"

    _source_sql=$(cat "$SQL_FILE")

    if ! run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -v source_sql="$_source_sql" -v bind_count="$BIND_COUNT" <<'SQL' > "$bind_text_map" 2>"$work_dir/bind-text-map.err"
WITH src AS (
    SELECT regexp_replace(:'source_sql', E'[\n\r\t]+', ' ', 'g') AS q
), params AS (
    SELECT generate_series(1, :'bind_count'::integer) AS n
), patterns AS (
    SELECT '(?:"(?:[^"]|"")+"|[a-z_][a-z_0-9$]*)'::text AS ident,
           '(?:::(?:text|integer|bigint|smallint|numeric|boolean|date|uuid|character varying|double precision))?'::text AS cast_pattern
), refs AS (
    SELECT p.n, m.ref
    FROM src s
    CROSS JOIN params p
    CROSS JOIN patterns x
    CROSS JOIN LATERAL (
        SELECT (z.m)[1] AS ref
        FROM regexp_matches(
                 s.q,
                 '(' || x.ident || '(?:\.' || x.ident || ')?)\s*' || x.cast_pattern ||
                 '\s*(?:=|<>|!=|<=|>=|<|>|~~\*?|!~~\*?)\s*\$' || p.n || '(?![0-9])' || x.cast_pattern,
                 'gi') AS z(m)
        UNION ALL
        SELECT (z.m)[1] AS ref
        FROM regexp_matches(
                 s.q,
                 '\$' || p.n || '(?![0-9])' || x.cast_pattern ||
                 '\s*(?:=|<>|!=|<=|>=|<|>)\s*(' || x.ident || '(?:\.' || x.ident || ')?)\s*' || x.cast_pattern,
                 'gi') AS z(m)
    ) m
), columns AS (
    SELECT DISTINCT n,
           ref,
           (parse_ident(ref))[cardinality(parse_ident(ref))] AS column_name
    FROM refs
    WHERE cardinality(parse_ident(ref)) BETWEEN 1 AND 3
), candidates AS (
    SELECT DISTINCT c.n,
           format('%I.%I', ns.nspname, cls.relname) AS relation,
           c.column_name
    FROM columns c
    CROSS JOIN src s
    JOIN pg_attribute a
      ON a.attname = c.column_name
     AND a.attnum > 0
     AND NOT a.attisdropped
    JOIN pg_class cls
      ON cls.oid = a.attrelid
     AND cls.relkind IN ('r','p','v','m','f')
    JOIN pg_namespace ns
      ON ns.oid = cls.relnamespace
    WHERE ns.nspname NOT IN ('pg_catalog','information_schema')
      AND position(lower(cls.relname) in lower(s.q)) > 0
      AND has_table_privilege(cls.oid, 'SELECT')
)
SELECT n, relation, column_name
FROM candidates
WHERE relation !~ E'[|\n\r]'
  AND column_name !~ E'[|\n\r]'
ORDER BY n, relation, column_name;
SQL
    then
        : > "$bind_text_map"
    fi

    if ! run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -v source_sql="$_source_sql" -v bind_count="$BIND_COUNT" <<'SQL' > "$bind_text_constant_map" 2>"$work_dir/bind-text-constant-map.err"
WITH src AS (
    SELECT regexp_replace(:'source_sql', E'[\n\r\t]+', ' ', 'g') AS q
), params AS (
    SELECT generate_series(1, :'bind_count'::integer) AS n
), patterns AS (
    SELECT '(NULL|true|false|[-+]?[0-9]+(?:\.[0-9]+)?|''(?:[^'']|'''')*'')'::text AS literal,
           '(?:::(?:text|integer|bigint|smallint|numeric|boolean|date|uuid|character varying|double precision))?'::text AS cast_pattern
), found AS (
    SELECT p.n, (z.m)[1] AS literal
    FROM src s
    CROSS JOIN params p
    CROSS JOIN patterns x
    CROSS JOIN LATERAL regexp_matches(
        s.q,
        x.literal || x.cast_pattern || '\s*(?:=|<>|!=|<=|>=|<|>)\s*\$' || p.n || '(?![0-9])' || x.cast_pattern,
        'gi') AS z(m)
    UNION ALL
    SELECT p.n, (z.m)[1] AS literal
    FROM src s
    CROSS JOIN params p
    CROSS JOIN patterns x
    CROSS JOIN LATERAL regexp_matches(
        s.q,
        '\$' || p.n || '(?![0-9])' || x.cast_pattern || '\s*(?:=|<>|!=|<=|>=|<|>)\s*' || x.literal || x.cast_pattern,
        'gi') AS z(m)
), normalized AS (
    SELECT n,
           CASE
             WHEN lower(literal) = 'null' THEN '\N'
             WHEN literal LIKE '''%''' THEN replace(substr(literal, 2, length(literal)-2), '''''', '''')
             WHEN lower(literal) = 'true' THEN 'true'
             WHEN lower(literal) = 'false' THEN 'false'
             ELSE literal
           END AS default_value
    FROM found
), unique_value AS (
    SELECT n, min(default_value) AS default_value
    FROM normalized
    GROUP BY n
    HAVING count(DISTINCT default_value) = 1
)
SELECT n, default_value
FROM unique_value
WHERE default_value !~ E'[|\n\r]'
ORDER BY n;
SQL
    then
        : > "$bind_text_constant_map"
    fi

    if [ -s "$bind_text_map" ]; then
        while IFS='|' read -r _p _rel _col; do
            [ -n "$_p" ] && [ -n "$_rel" ] && [ -n "$_col" ] || continue
            if ! awk -F'|' -v n="$_p" '$1==n {found=1} END{exit found?0:1}' "$bind_map"; then
                printf '%s|%s|%s|3\n' "$_p" "$_rel" "$_col" >> "$bind_map"
            fi
        done < "$bind_text_map"
    fi

    if [ -s "$bind_text_constant_map" ]; then
        while IFS='|' read -r _p _value; do
            [ -n "$_p" ] || continue
            if ! awk -F'|' -v n="$_p" '$1==n {found=1} END{exit found?0:1}' "$bind_constant_map"; then
                printf '%s|%s\n' "$_p" "$_value" >> "$bind_constant_map"
            fi
        done < "$bind_text_constant_map"
    fi

    unset _source_sql
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
        while IFS='|' read -r candidate_relation candidate_column; do
            printf '  %s) %s / %s\n' "$candidate_no" "$candidate_relation" "$candidate_column"
            candidate_no=$((candidate_no + 1))
        done < "$bind_candidate_file"
        while :; do
            printf 'Select candidate for $%s [1]: ' "$bind_index" >&2
            IFS= read -r candidate_choice || return 1
            [ -n "$candidate_choice" ] || candidate_choice=1
            case $candidate_choice in
                *[!0-9]*|'') echo "ERROR: enter a candidate number." >&2; continue ;;
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
        echo "안내: \$$bind_index 와 직접 연결되는 테이블/컬럼을 자동으로 찾지 못했습니다." >&2
        echo "      테이블명을 수동 입력받지 않고 bind 값을 직접 입력하는 단계로 진행합니다." >&2
        return 0
    fi

    printf '\nTable value candidates for $%s (up to %s distinct values; not historical bind values)\n' "$bind_index" "$BIND_SAMPLE_LIMIT"
    if run_psql -X -q -P pager=off -v ON_ERROR_STOP=1 \
        -v sample_relation="$sample_relation" -v sample_column="$sample_column" \
        -v sample_limit="$BIND_SAMPLE_LIMIT" -v sample_timeout="$BIND_SAMPLE_TIMEOUT" <<'SQL'
BEGIN READ ONLY;
SELECT set_config('statement_timeout', :'sample_timeout', true) AS sample_timeout \gset
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
SELECT set_config('statement_timeout', :'sample_timeout', true) AS sample_timeout \gset
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

    echo "주의: $sample_relation / $sample_column 후보 조회에 실패했습니다. bind 값 직접 입력으로 진행합니다." >&2
    return 0
}

_bind_default=n
[ "$SQL_SOURCE_KIND" = pgss ] && grep -Eq '\$[1-9][0-9]*' "$SQL_FILE" && _bind_default=y
BIND=$(ask 'Use bind parameters ($1, $2, ...)? y/n' "$_bind_default") || exit 1
prepare_file="$work_dir/prepare.sql"; execute_file="$work_dir/execute.sql"; bind_values_file="$work_dir/bind-values-used.txt"; : > "$bind_values_file"; BIND_PLAN_MODE=auto
if [ "$BIND" = yes ]; then
    printf 'Parameter types, comma-separated [auto infer]: ' >&2; IFS= read -r bind_types
    { printf 'SET standard_conforming_strings = on;\nPREPARE pg_explain_target'; [ -z "$bind_types" ] || printf ' (%s)' "$bind_types"; printf ' AS\n'; cat "$SQL_FILE"; printf '\n;\n'; } > "$prepare_file"
    if ! BIND_COUNT=$({ cat "$prepare_file"; echo "SELECT cardinality(parameter_types) FROM pg_prepared_statements WHERE name='pg_explain_target';"; } | run_psql -X -qAt -v ON_ERROR_STOP=1); then
        if [ "$SQL_SOURCE_KIND" = pgss ]; then
            echo "안내: 현재 실행 사용자/DB/search_path 환경에서 SQL PREPARE에 실패했습니다." >&2
            echo "      원본 사용자로 전환한 상태라면 원본 세션의 별도 SET search_path, 세션 GUC, 임시 객체 등은" >&2
            echo "      pg_stat_statements만으로 복원할 수 없습니다." >&2
            echo "      또한 pg_stat_statements에는 원본 bind의 데이터 타입이 저장되지 않습니다." >&2
            echo "      필요한 경우 Parameter types에 원본 bind 타입을 쉼표로 직접 지정하세요." >&2
        fi
        echo "ERROR: Could not prepare SQL." >&2
        exit 1
    fi
    case $BIND_COUNT in ''|*[!0-9]*) echo "ERROR: invalid parameter count" >&2; exit 1 ;; esac
    build_bind_map
    build_bind_constant_map
    build_bind_type_map || exit 1
    build_bind_text_fallback_maps
    echo "Bind parameter count: $BIND_COUNT"
    echo 'Enter each value as plain text (no SQL quotes). \N means SQL NULL. If a default is shown, Enter accepts it.'
    printf 'EXECUTE pg_explain_target' > "$execute_file"
    [ "$BIND_COUNT" -eq 0 ] || printf '(' >> "$execute_file"
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
            IFS= read -r bind_value
            if [ -z "$bind_value" ] && [ "$bind_default_available" = yes ]; then bind_value=$bind_default_value; break; fi
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

ANALYZE=$(ask 'Use ANALYZE? y/n' n)
if [ "$ANALYZE" = yes ]; then
    echo
    echo "WARNING: EXPLAIN ANALYZE executes the target SQL."
    echo "         DML is executed inside BEGIN -> EXPLAIN ANALYZE -> ROLLBACK."
    echo "         DML data changes are rolled back after plan collection."
    echo
fi
VERBOSE=$(ask 'Use VERBOSE? y/n' n)
COSTS=$(ask 'Use COSTS? y/n' y)
SETTINGS=$(ask 'Use SETTINGS? y/n' y)
BUFFERS=no; WAL=no; TIMING=no; GENERIC_PLAN=no; SERIALIZE=no; MEMORY=no
if [ "$ANALYZE" = yes ]; then
    BUFFERS=$(ask 'Use BUFFERS? y/n' y)
    [ "$SERVER_VERSION_NUM" -lt 130000 ] || WAL=$(ask 'Use WAL? y/n' n)
    TIMING=$(ask 'Use TIMING? y/n' y)
    [ "$SERVER_VERSION_NUM" -lt 170000 ] || SERIALIZE=$(ask 'Use SERIALIZE TEXT? y/n' n)
else
    if [ "$BIND" = no ] && [ "$SERVER_VERSION_NUM" -ge 160000 ]; then GENERIC_PLAN=$(ask 'Use GENERIC_PLAN? y/n' n); fi
fi
[ "$SERVER_VERSION_NUM" -lt 170000 ] || MEMORY=$(ask 'Use MEMORY? y/n' n)
SUMMARY=$(ask 'Use SUMMARY? y/n' y)

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

option_tf() { [ "$1" = yes ] && printf 'TRUE' || printf 'FALSE'; }
write_option_summary() {
    echo "Selected EXPLAIN Options"
    printf '  %-12s : %s\n' ANALYZE "$(option_tf "$ANALYZE")"
    printf '  %-12s : %s\n' VERBOSE "$(option_tf "$VERBOSE")"
    printf '  %-12s : %s\n' COSTS "$(option_tf "$COSTS")"
    printf '  %-12s : %s\n' SETTINGS "$(option_tf "$SETTINGS")"
    if [ "$ANALYZE" = yes ]; then
        printf '  %-12s : %s\n' BUFFERS "$(option_tf "$BUFFERS")"
        if [ "$SERVER_VERSION_NUM" -ge 130000 ]; then printf '  %-12s : %s\n' WAL "$(option_tf "$WAL")"; fi
        printf '  %-12s : %s\n' TIMING "$(option_tf "$TIMING")"
        if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then
            if [ "$SERIALIZE" = yes ]; then printf '  %-12s : TEXT\n' SERIALIZE; else printf '  %-12s : NONE\n' SERIALIZE; fi
        fi
    elif [ "$BIND" = no ] && [ "$SERVER_VERSION_NUM" -ge 160000 ]; then
        printf '  %-12s : %s\n' GENERIC_PLAN "$(option_tf "$GENERIC_PLAN")"
    fi
    if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then printf '  %-12s : %s\n' MEMORY "$(option_tf "$MEMORY")"; fi
    printf '  %-12s : %s\n' SUMMARY "$(option_tf "$SUMMARY")"
    printf '  %-12s : TEXT\n' FORMAT
    if [ "$BIND" = yes ]; then printf '  %-12s : %s\n' PLAN_MODE "$BIND_PLAN_MODE"; fi
}
options_summary="$work_dir/explain-options.txt"
write_option_summary > "$options_summary"
echo
cat "$options_summary"
echo

tree_plan_opts=""
add_tree_opt() { [ -z "$tree_plan_opts" ] && tree_plan_opts="$1" || tree_plan_opts="$tree_plan_opts, $1"; }
[ "$VERBOSE" = yes ] && add_tree_opt 'VERBOSE TRUE' || add_tree_opt 'VERBOSE FALSE'
[ "$COSTS" = yes ] && add_tree_opt 'COSTS TRUE' || add_tree_opt 'COSTS FALSE'
[ "$SETTINGS" = yes ] && add_tree_opt 'SETTINGS TRUE' || add_tree_opt 'SETTINGS FALSE'
[ "$GENERIC_PLAN" = yes ] && add_tree_opt 'GENERIC_PLAN TRUE'
if [ "$SERVER_VERSION_NUM" -ge 170000 ]; then [ "$MEMORY" = yes ] && add_tree_opt 'MEMORY TRUE' || add_tree_opt 'MEMORY FALSE'; fi
[ "$SUMMARY" = yes ] && add_tree_opt 'SUMMARY TRUE' || add_tree_opt 'SUMMARY FALSE'
tree_json_opts="$tree_plan_opts, FORMAT JSON"

tree_plan_json="$work_dir/tree-plan.json"; rel_file="$work_dir/relations.txt"; rel_oid_file="$work_dir/relation-oids.txt"; dml_file="$work_dir/dml.txt"; plan_error="$work_dir/plan.err"; plan_summary="$work_dir/summary.txt"; raw_plan_output="$work_dir/raw-plan.txt"; tmp="$work_dir/explain.sql"
table_before="$work_dir/table.before"; table_after="$work_dir/table.after"; index_before="$work_dir/index.before"; index_after="$work_dir/index.after"; stat_index_file="$work_dir/stat-indexes.txt"
RESULT_DIR=${EXPLAIN_RESULT_DIR:-$DEFAULT_OUTPUT_DIR}; mkdir -p "$RESULT_DIR" || exit 1
result_database=$(printf '%s' "$PGDATABASE" | tr -c '[:alnum:]_.-' '_'); RESULT_FILE="$RESULT_DIR/explain_${result_database}_$(date '+%Y%m%d_%H%M%S').log"

emit_bind_prelude() {
    [ "$BIND" = yes ] || return 0
    cat "$prepare_file"
    printf 'SET plan_cache_mode = %s;\n' "$BIND_PLAN_MODE"
}
emit_plan_body() {
    opts=$1
    if [ "$BIND" = yes ]; then
        printf 'EXPLAIN (%s)\n' "$opts"
        cat "$execute_file"
        printf '\n'
    else
        printf 'EXPLAIN (%s)\n' "$opts"
        cat "$SQL_FILE"
        printf '\n;\n'
    fi
}
emit_plan() {
    opts=$1
    emit_bind_prelude
    emit_plan_body "$opts"
}

emit_plan "$tree_json_opts" | run_psql -X -qAt -v ON_ERROR_STOP=1 > "$tree_plan_json" 2>"$plan_error" || { cat "$plan_error" >&2; exit 1; }
extract_plan_metadata "$tree_plan_json" "$rel_file" "$rel_oid_file" "$dml_file" || { echo "ERROR: PostgreSQL JSON metadata parsing failed." >&2; exit 1; }
DML_OPERATION=$(sed -n '1p' "$dml_file")

build_stat_index_map() {
    : > "$stat_index_file"
    [ -s "$rel_oid_file" ] || return 0
    {
        echo 'WITH rels(relid) AS (VALUES'
        awk -F'|' 'BEGIN{first=1} {if(!first) printf ",\n"; printf "(%s::oid)",$1; first=0} END{print ""}' "$rel_oid_file"
        cat <<'SQL'
)
SELECT i.indexrelid,
       format('%I.%I', n.nspname, c.relname),
       i.indrelid
FROM pg_index i
JOIN rels r ON r.relid=i.indrelid
JOIN pg_class c ON c.oid=i.indexrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
ORDER BY i.indrelid,i.indexrelid;
SQL
    } | run_psql -X -qAt -F '|' -v ON_ERROR_STOP=1 > "$stat_index_file" || return 1
}

sql_literal() { printf '%s' "$1" | sed "s/'/''/g"; }

emit_table_snapshot_sql() {
    while IFS='|' read -r oid name; do
        [ -n "$oid" ] || continue
        qname=$(sql_literal "$name")
        idx_expr="0"
        while IFS='|' read -r idxoid idxname relid; do
            [ "$relid" = "$oid" ] || continue
            idx_expr="$idx_expr + COALESCE(pg_stat_get_numscans($idxoid::oid),0)"
        done < "$stat_index_file"
        printf "SELECT %s::oid, '%s', COALESCE(pg_stat_get_numscans(%s::oid),0), COALESCE(pg_stat_get_tuples_returned(%s::oid),0), (%s), COALESCE(pg_stat_get_tuples_fetched(%s::oid),0), COALESCE(pg_stat_get_tuples_inserted(%s::oid),0), COALESCE(pg_stat_get_tuples_updated(%s::oid),0), COALESCE(pg_stat_get_tuples_deleted(%s::oid),0), COALESCE(pg_stat_get_tuples_hot_updated(%s::oid),0);\n" "$oid" "$qname" "$oid" "$oid" "$idx_expr" "$oid" "$oid" "$oid" "$oid" "$oid"
    done < "$rel_oid_file"
}

emit_index_snapshot_sql() {
    while IFS='|' read -r idxoid idxname relid; do
        [ -n "$idxoid" ] || continue
        qname=$(sql_literal "$idxname")
        printf "SELECT %s::oid, '%s', COALESCE(pg_stat_get_numscans(%s::oid),0), COALESCE(pg_stat_get_tuples_returned(%s::oid),0), COALESCE(pg_stat_get_tuples_fetched(%s::oid),0), GREATEST(COALESCE(pg_stat_get_blocks_fetched(%s::oid),0)-COALESCE(pg_stat_get_blocks_hit(%s::oid),0),0), COALESCE(pg_stat_get_blocks_hit(%s::oid),0);\n" "$idxoid" "$qname" "$idxoid" "$idxoid" "$idxoid" "$idxoid" "$idxoid" "$idxoid"
    done < "$stat_index_file"
}

emit_stats_sync_sql() {
    if [ "$SERVER_VERSION_NUM" -ge 150000 ]; then
        printf 'SELECT pg_stat_force_next_flush();\nSELECT pg_stat_clear_snapshot();\n'
    else
        _settle=${PG_STAT_SETTLE_SECONDS:-1}
        case $_settle in ''|*[!0-9.]*) _settle=1 ;; esac
        printf 'SELECT pg_sleep(%s);\nSELECT pg_stat_clear_snapshot();\n' "$_settle"
    fi
}

build_measurement_sql() {
    {
        printf '\\pset tuples_only on\n\\pset format unaligned\n\\pset fieldsep |\n'
        emit_bind_prelude
        printf '\\o /dev/null\n'
        emit_stats_sync_sql
        printf '\\o %s\n' "$table_before"
        emit_table_snapshot_sql
        printf '\\o %s\n' "$index_before"
        emit_index_snapshot_sql
        printf '\\o %s\n' "$raw_plan_output"
        if [ -n "$DML_OPERATION" ]; then printf 'BEGIN;\n'; fi
        emit_plan_body "$raw_text_opts"
        if [ -n "$DML_OPERATION" ]; then printf 'ROLLBACK;\n'; fi
        printf '\\o /dev/null\n'
        emit_stats_sync_sql
        printf '\\o %s\n' "$table_after"
        emit_table_snapshot_sql
        printf '\\o %s\n' "$index_after"
        emit_index_snapshot_sql
        printf '\\o\n'
    } > "$tmp"
}

print_table_delta() {
    [ -s "$table_before" ] && [ -s "$table_after" ] || return 0
    awk -F'|' 'NR==FNR {for(i=3;i<=10;i++) b[$1,i]=$i; name[$1]=$2; next} {id=$1; printf "\n%s\n",name[id]; printf "%-24s %15s %15s %15s\n","metric","before","after","delta"; printf "%-24s %15s %15s %15s\n","------------------------","---------------","---------------","---------------"; label[3]="seq_scan";label[4]="seq_tup_read";label[5]="idx_scan";label[6]="idx_tup_fetch";label[7]="n_tup_ins";label[8]="n_tup_upd";label[9]="n_tup_del";label[10]="n_tup_hot_upd"; for(i=3;i<=10;i++){before=(b[id,i]==""?0:b[id,i]);after=$i;delta=after-before;printf "%-24s %15s %15s %+15d\n",label[i],before,after,delta}}' "$table_before" "$table_after"
}

print_index_delta() {
    [ -s "$index_before" ] && [ -s "$index_after" ] || return 0
    awk -F'|' 'NR==FNR {for(i=3;i<=7;i++) b[$1,i]=$i; name[$1]=$2; next} {id=$1; printf "\n%s\n",name[id]; printf "%-24s %15s %15s %15s\n","metric","before","after","delta"; printf "%-24s %15s %15s %15s\n","------------------------","---------------","---------------","---------------"; label[3]="idx_scan";label[4]="idx_tup_read";label[5]="idx_tup_fetch";label[6]="idx_blks_read";label[7]="idx_blks_hit"; for(i=3;i<=7;i++){before=(b[id,i]==""?0:b[id,i]);after=$i;delta=after-before;printf "%-24s %15s %15s %+15d\n",label[i],before,after,delta}}' "$index_before" "$index_after"
}

if [ "$ANALYZE" = yes ]; then
    echo
    if [ -n "$DML_OPERATION" ]; then
        echo "DML detected: $DML_OPERATION"
        echo "Safety     : BEGIN -> EXPLAIN ANALYZE -> ROLLBACK"
    fi
    printf 'Type EXECUTE to continue: ' >&2; IFS= read -r confirm; [ "$confirm" = EXECUTE ] || { echo "Cancelled."; exit 1; }
fi

{
 echo "PostgreSQL execution plan analysis"
 echo "script_version=$SCRIPT_VERSION"
 echo "database=$PGDATABASE"
 echo "sql_source=$SQL_SOURCE_DESC"
 echo "sql_file=$SQL_FILE"
 if [ "$SQL_SOURCE_KIND" = pgss ]; then
     echo "pgss_lookup_database=$PGSS_LOOKUP_DATABASE"
     echo "pgss_lookup_user=$PGSS_LOOKUP_USER"
     echo "original_query_user=$ORIGINAL_QUERY_USER"
     echo "original_query_userid=$ORIGINAL_QUERY_USERID"
     echo "original_query_user_can_login=$ORIGINAL_QUERY_USER_CAN_LOGIN"
     echo "execute_user=$PGSS_EXECUTE_USER"
     echo "execute_search_path=$PGSS_SEARCH_PATH"
     echo "original_search_path=unavailable"
     echo "pgss_normalized_null_used=$PGSS_NORMALIZED_NULL_USED"
     [ -z "$PGSS_ORIGINAL_BIND_MAX" ] || echo "pgss_original_bind_max=$PGSS_ORIGINAL_BIND_MAX"
     if [ -n "$PGSS_NORMALIZED_VALUES_FILE" ] && [ -s "$PGSS_NORMALIZED_VALUES_FILE" ]; then
         echo "pgss_normalized_values:"
         sed 's/^/  /' "$PGSS_NORMALIZED_VALUES_FILE"
     fi
 fi
 echo
 cat "$options_summary"
 echo
} > "$RESULT_FILE"

stats_measured=no
if [ "$ANALYZE" = yes ] && [ -s "$rel_oid_file" ]; then
    build_stat_index_map || { echo "ERROR: statistics object discovery failed." >&2; exit 1; }
    build_measurement_sql
    if ! run_psql -X -q -v ON_ERROR_STOP=1 -f "$tmp" >/dev/null 2>"$plan_error"; then
        cat "$plan_error" | tee -a "$RESULT_FILE" >&2
        echo "ERROR: execution plan/statistics measurement failed." | tee -a "$RESULT_FILE" >&2
        exit 1
    fi
    stats_measured=yes
else
    if [ "$ANALYZE" = yes ] && [ -n "$DML_OPERATION" ]; then
        { printf 'BEGIN;\n'; emit_plan "$raw_text_opts"; printf 'ROLLBACK;\n'; } > "$tmp"
    else
        emit_plan "$raw_text_opts" > "$tmp"
    fi
    if ! run_psql -X -qAt -P pager=off -v ON_ERROR_STOP=1 -f "$tmp" > "$raw_plan_output" 2>"$plan_error"; then
        cat "$plan_error" | tee -a "$RESULT_FILE" >&2
        echo "ERROR: Raw execution plan generation failed." | tee -a "$RESULT_FILE" >&2
        exit 1
    fi
fi

if [ "$BIND" = yes ] && grep -Eiq 'One-Time Filter:[[:space:]]*false' "$raw_plan_output"; then
    {
        echo
        echo "주의: 실행 계획에 One-Time Filter: false가 확인되었습니다."
        echo "      입력한 bind 값 조합으로 상수 조건이 FALSE가 되어 하위 relation scan이 제거된 상태입니다."
        echo "      이는 EXPLAIN 오류가 아니라 해당 bind 값에 대한 실제 계획 결과입니다."
        echo "      SQL 상수와 비교되는 bind는 표시된 자동 기본값을 사용했는지 확인하세요."
        if [ "$SQL_SOURCE_KIND" = pgss ] && [ "$PGSS_NORMALIZED_NULL_USED" = yes ]; then
            echo "      또한 정규화 상수에 SQL NULL을 복원했습니다. NULL의 일반 비교는 TRUE가 되지 않아 branch가 제거될 수 있습니다."
        fi
        echo
    } | tee -a "$RESULT_FILE"
fi

render_plan_summary "$tree_plan_json" "$raw_plan_output" > "$plan_summary" || { echo "ERROR: Plan Summary generation failed." >&2; exit 1; }

section "Execution Plan Summary" | tee -a "$RESULT_FILE"
cat "$plan_summary" | tee -a "$RESULT_FILE"

if [ "$ANALYZE" = yes ]; then
    section "Execution Plan Raw (TEXT / Actual)" | tee -a "$RESULT_FILE"
else
    section "Execution Plan Raw (TEXT / Planned)" | tee -a "$RESULT_FILE"
fi
cat "$raw_plan_output" | tee -a "$RESULT_FILE"

if [ "$stats_measured" = yes ]; then
    section "Statistics Delta Scope" | tee -a "$RESULT_FILE"
    echo "Before/target/after were collected in one PostgreSQL session using direct pg_stat_get_* counters." | tee -a "$RESULT_FILE"
    if [ "$SERVER_VERSION_NUM" -ge 150000 ]; then
        echo "Pending local statistics were forced to flush before each snapshot." | tee -a "$RESULT_FILE"
    else
        echo "PostgreSQL < 15: a settle delay was used because pg_stat_force_next_flush() is unavailable." | tee -a "$RESULT_FILE"
    fi
    echo "Concurrent activity from other sessions can still contribute to cumulative-statistics deltas." | tee -a "$RESULT_FILE"
    section "Table Statistics Delta" | tee -a "$RESULT_FILE"
    print_table_delta | tee -a "$RESULT_FILE"
    section "Index Statistics / I/O Delta" | tee -a "$RESULT_FILE"
    print_index_delta | tee -a "$RESULT_FILE"
fi

echo "Current result saved: $RESULT_FILE"
DIAG=$(ask 'Show additional Plan diagnostics? y/n' y)
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
