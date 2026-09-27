#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
PGSS_SQL_FILE="$SCRIPT_DIR/pgss-check.sql"
DATABASE_SQL_FILE="$SCRIPT_DIR/performance-check.sql"
DEFAULT_OUTPUT_DIR="$SCRIPT_DIR/results"
TEMP_FILES=""

cleanup() {
  for cleanup_file in $TEMP_FILES; do
    rm -f "$cleanup_file"
  done
}
trap cleanup 0
trap 'cleanup; exit 1' 1 2 15

log_step() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_step 'PostgreSQL 성능 조회 스크립트를 시작합니다.'

if [ "$#" -ne 0 ]; then
  echo '명령행 옵션을 사용하지 않습니다. sh postgres-performance-check.sh 로 실행하십시오.' >&2
  exit 2
fi
if [ ! -t 0 ]; then
  echo '대화형 입력이 필요합니다. 터미널에서 실행하십시오.' >&2
  exit 2
fi
if ! command -v psql >/dev/null 2>&1; then
  echo 'psql을 PATH에서 찾을 수 없습니다.' >&2
  exit 127
fi
log_step "psql 확인: $(command -v psql)"

inspect_current_environment() {
  log_step '[1/4] PostgreSQL 연결 환경 확인을 완료했습니다.'
  log_step 'profile은 로그인 시 이미 적용되므로 다시 실행하거나 파싱하지 않습니다.'
  log_step "PGHOST=${PGHOST:-libpq-default}"
  log_step "PGPORT=${PGPORT:-libpq-default}"
  log_step "PGDATABASE=${PGDATABASE:-libpq-default}"
  log_step "PGUSER=${PGUSER:-libpq-default}"
  log_step "PGSERVICE=${PGSERVICE:-not-used}"
  log_step "PGDATA=${PGDATA:-not-set}"
  if [ -n "${PGDATA:-}" ] && [ -f "$PGDATA/postgresql.conf" ]; then
    log_step "postgresql.conf 확인: $PGDATA/postgresql.conf"
  fi
  log_step '실제 서버 설정은 연결 후 PostgreSQL current_setting()으로 조회합니다.'
  log_step '비밀번호 값은 출력하지 않습니다.'
}

prompt_database_if_needed() {
  ALL_DATABASES=0
  DATABASE_TARGETS_FILE=$(mktemp "${TMPDIR:-/tmp}/pg-performance-targets.XXXXXX")
  TEMP_FILES="$TEMP_FILES $DATABASE_TARGETS_FILE"
  DATABASE_LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/pg-performance-databases.XXXXXX")
  TEMP_FILES="$TEMP_FILES $DATABASE_LIST_FILE"
  catalog_query="SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;"
  catalog_database=""

  for catalog_candidate in postgres template1; do
    if PGCONNECTTIMEOUT="${PGCONNECTTIMEOUT:-5}" \
       PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on -c statement_timeout=5000" \
       psql -X -A -t -q -F '|' -d "$catalog_candidate" -c "$catalog_query" \
       >"$DATABASE_LIST_FILE" 2>/dev/null; then
      catalog_database=$catalog_candidate
      break
    fi
  done

  if [ -n "$catalog_database" ] && [ -s "$DATABASE_LIST_FILE" ]; then
    log_step "database 목록 조회용 임시 연결: $catalog_database"
    echo
    echo '조회할 데이터베이스를 선택하십시오.'
    echo '  0) 전체 database'
    awk -F'|' '{ printf "  %d) %-30s owner=%s\n", NR, $1, $2 }' "$DATABASE_LIST_FILE"
    database_count=$(awk 'END { print NR }' "$DATABASE_LIST_FILE")
    while [ ! -s "$DATABASE_TARGETS_FILE" ]; do
      printf 'Database 번호 입력: ' >&2
      IFS= read -r database_selection
      case "$database_selection" in
        ''|*[!0-9]*) echo '목록의 번호를 입력하십시오.' >&2 ;;
        0)
          cut -d'|' -f1 "$DATABASE_LIST_FILE" >"$DATABASE_TARGETS_FILE"
          ALL_DATABASES=1
          DATABASE_SCOPE=all-databases
          unset PGDATABASE
          ;;
        *)
          if [ "$database_selection" -ge 1 ] && [ "$database_selection" -le "$database_count" ]; then
            selected_database=$(sed -n "${database_selection}p" "$DATABASE_LIST_FILE")
            PGDATABASE=${selected_database%%|*}
            export PGDATABASE
            printf '%s\n' "$PGDATABASE" >"$DATABASE_TARGETS_FILE"
            DATABASE_SCOPE=$PGDATABASE
          else
            echo "0~$database_count 사이의 번호를 입력하십시오." >&2
          fi
          ;;
      esac
    done
  else
    log_step 'database 목록을 자동 조회하지 못해 이름을 직접 입력받습니다.'
    if [ -n "${PGDATABASE:-}" ]; then
      printf '%s\n' "$PGDATABASE" >"$DATABASE_TARGETS_FILE"
      DATABASE_SCOPE=$PGDATABASE
    fi
    while [ -z "${PGDATABASE:-}" ]; do
      printf '조회할 PostgreSQL 데이터베이스 이름: ' >&2
      IFS= read -r database_input
      if [ -n "$database_input" ]; then
        PGDATABASE=$database_input
        export PGDATABASE
        printf '%s\n' "$PGDATABASE" >"$DATABASE_TARGETS_FILE"
        DATABASE_SCOPE=$PGDATABASE
      else
        echo '데이터베이스 이름은 필수입니다.' >&2
      fi
    done
  fi
  if [ "$ALL_DATABASES" -eq 1 ]; then
    target_count=$(awk 'END { print NR }' "$DATABASE_TARGETS_FILE")
    log_step "전체 database 선택: ${target_count}개"
  else
    log_step "사용자가 선택한 데이터베이스: $PGDATABASE"
  fi
}

find_pgss_database() {
  PGSS_DATABASE=""
  PGSS_CANDIDATES_FILE=$(mktemp "${TMPDIR:-/tmp}/pg-performance-pgss-candidates.XXXXXX")
  TEMP_FILES="$TEMP_FILES $PGSS_CANDIDATES_FILE"
  {
    echo postgres
    cut -d'|' -f1 "$DATABASE_LIST_FILE" 2>/dev/null || true
    cat "$DATABASE_TARGETS_FILE"
  } | awk 'NF && !seen[$0]++' >"$PGSS_CANDIDATES_FILE"

  while IFS= read -r pgss_candidate; do
    [ -n "$pgss_candidate" ] || continue
    if pgss_present=$(PGCONNECTTIMEOUT="${PGCONNECTTIMEOUT:-5}" \
        PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on -c statement_timeout=5000" \
        psql -X -A -t -q -d "$pgss_candidate" \
        -c "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements');" \
        2>/dev/null); then
      if [ "$pgss_present" = t ]; then
        PGSS_DATABASE=$pgss_candidate
        break
      fi
    fi
  done <"$PGSS_CANDIDATES_FILE"

  if [ -n "$PGSS_DATABASE" ]; then
    log_step "중앙 pg_stat_statements 조회 database: $PGSS_DATABASE"
  else
    log_step 'pg_stat_statements extension이 설치된 database를 찾지 못했습니다.'
  fi
}

verify_connection() {
  log_step '[2/4] 본 조회 전에 PostgreSQL 연결을 확인합니다.'
  if [ "${ALL_DATABASES:-0}" -eq 1 ]; then
    log_step '전체 대상은 본 조회 단계에서 DB별 연결을 각각 확인합니다.'
    return 0
  fi
  if connection_info=$(PGCONNECTTIMEOUT="${PGCONNECTTIMEOUT:-5}" \
      PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on -c statement_timeout=5000" \
      psql -X -A -t -q -c \
      "SELECT current_database() || '|' || current_user || '|' || current_setting('port') || '|' || current_setting('data_directory');" \
      2>&1); then
    connection_database=$(printf '%s' "$connection_info" | awk -F'|' '{print $1}')
    connection_user=$(printf '%s' "$connection_info" | awk -F'|' '{print $2}')
    connection_port=$(printf '%s' "$connection_info" | awk -F'|' '{print $3}')
    connection_data=$(printf '%s' "$connection_info" | awk -F'|' '{print $4}')
    log_step "연결 성공: database=$connection_database user=$connection_user port=$connection_port"
    log_step "서버 data_directory=$connection_data"
  else
    echo 'PostgreSQL 연결 확인에 실패했습니다.' >&2
    echo "$connection_info" >&2
    exit 2
  fi
}

discover_pgdata() {
  if [ -n "${PGDATA:-}" ] && [ -f "$PGDATA/postgresql.conf" ]; then
    return 0
  fi

  process_pgdata=$(ps -u "$(id -un)" -o args= 2>/dev/null | awk '
    $1 ~ /(^|\/)postgres$/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "-D" && (i + 1) <= NF) print $(i + 1)
        if ($i ~ /^--pgdata=/) {
          sub(/^--pgdata=/, "", $i)
          print $i
        }
      }
    }
  ' | sort -u)
  pgdata_count=$(printf '%s\n' "$process_pgdata" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$pgdata_count" -eq 1 ]; then
    PGDATA=$(printf '%s\n' "$process_pgdata" | awk 'NF { print; exit }')
    export PGDATA
    log_step "실행 중인 postgres 프로세스에서 PGDATA 확인: $PGDATA"
    return 0
  fi

  psql_home=$(CDPATH='' cd "$(dirname "$(command -v psql)")/.." && pwd)
  for derived_pgdata in "$psql_home/data" "$(dirname "$psql_home")/data"; do
    if [ -f "$derived_pgdata/postgresql.conf" ]; then
      PGDATA=$derived_pgdata
      export PGDATA
      log_step "psql 설치 경로 기준 PGDATA 확인: $PGDATA"
      return 0
    fi
  done

  if [ "$pgdata_count" -gt 1 ]; then
    log_step '현재 계정에서 여러 PostgreSQL 데이터 디렉터리를 발견했습니다.'
    printf '%s\n' "$process_pgdata"
    printf '사용할 PGDATA 경로: ' >&2
    IFS= read -r selected_pgdata
    if [ -f "$selected_pgdata/postgresql.conf" ]; then
      PGDATA=$selected_pgdata
      export PGDATA
    fi
  fi
}

read_server_setting_from_config() {
  requested_setting=$1
  postgres_bin="$(dirname "$(command -v psql)")/postgres"
  if [ -x "$postgres_bin" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout -s TERM 3 "$postgres_bin" -D "$PGDATA" -C "$requested_setting" 2>/dev/null
    else
      "$postgres_bin" -D "$PGDATA" -C "$requested_setting" 2>/dev/null
    fi
  else
    awk -F= -v key="$requested_setting" '
      $0 !~ /^[[:space:]]*#/ && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        value = $2
      }
      END {
        sub(/#.*/, "", value)
        gsub(/^[[:space:]\047\042]+|[[:space:]\047\042]+$/, "", value)
        print value
      }
    ' "$PGDATA/postgresql.conf"
  fi
}

discover_socket() {
  SOCKET_LIST=$(mktemp "${TMPDIR:-/tmp}/pg-performance-sockets.XXXXXX")
  TEMP_FILES="$TEMP_FILES $SOCKET_LIST"
  for socket_dir in /tmp /var/run/postgresql; do
    if [ -d "$socket_dir" ]; then
      find "$socket_dir" -maxdepth 1 -type s -user "$(id -un)" \
        -name '.s.PGSQL.*' -print 2>/dev/null >>"$SOCKET_LIST" || true
    fi
  done
  socket_count=$(sort -u "$SOCKET_LIST" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$socket_count" -eq 1 ]; then
    socket_path=$(sort -u "$SOCKET_LIST" | awk 'NF { print; exit }')
    PGHOST=$(dirname "$socket_path")
    PGPORT=${socket_path##*.s.PGSQL.}
    export PGHOST PGPORT
    log_step "실행 중인 Unix socket에서 연결 확인: host=$PGHOST port=$PGPORT"
  fi
}

discover_connection_environment() {
  log_step '[1/3] 현재 환경과 postgresql.conf에서 연결정보를 확인합니다.'
  discover_pgdata

  if [ -f "${PGDATA:-}/postgresql.conf" ]; then
    if [ -z "${PGPORT:-}" ]; then
      config_port=$(read_server_setting_from_config port || true)
      case "$config_port" in
        ''|*[!0-9]*) ;;
        *) PGPORT=$config_port; export PGPORT; log_step "postgresql.conf에서 port 확인: $PGPORT" ;;
      esac
    fi
    if [ -z "${PGHOST:-}" ]; then
      config_socket=$(read_server_setting_from_config unix_socket_directories || true)
      config_socket=$(printf '%s' "$config_socket" | awk -F, '{gsub(/[[:space:]\047\042]/, "", $1); print $1}')
      if [ -d "$config_socket" ]; then
        PGHOST=$config_socket
        export PGHOST
        log_step "postgresql.conf에서 socket 경로 확인: $PGHOST"
      fi
    fi
  fi

  if [ -z "${PGPORT:-}" ]; then
    discover_socket
  fi
  while [ -z "${PGPORT:-}" ]; do
    printf 'PGPORT를 자동 확인하지 못했습니다. PostgreSQL 포트 입력: ' >&2
    IFS= read -r port_input
    case "$port_input" in
      ''|*[!0-9]*) echo '숫자 포트를 입력하십시오.' >&2 ;;
      *) PGPORT=$port_input; export PGPORT ;;
    esac
  done
}

prompt_positive_integer() {
  prompt_text=$1
  prompt_default=$2
  while true; do
    printf '%s [%s]: ' "$prompt_text" "$prompt_default" >&2
    IFS= read -r prompt_input
    if [ -z "$prompt_input" ]; then
      prompt_input=$prompt_default
    fi
    case "$prompt_input" in
      *[!0-9]*|'') echo '1 이상의 정수를 입력하십시오.' >&2 ;;
      0) echo '1 이상의 정수를 입력하십시오.' >&2 ;;
      *) printf '%s\n' "$prompt_input"; return 0 ;;
    esac
  done
}

discover_connection_environment
prompt_database_if_needed
find_pgss_database
inspect_current_environment
verify_connection

echo
echo 'PostgreSQL 성능 현황을 읽기 전용으로 한 번 조회합니다.'
TOP_N=$(prompt_positive_integer '항목별 출력 건수' 20)
timestamp=$(date '+%Y%m%d_%H%M%S')
default_result="$DEFAULT_OUTPUT_DIR/postgres-performance-report_${timestamp}.log"
printf '결과 파일 경로 [%s]: ' "$default_result" >&2
IFS= read -r result_input
RESULT_FILE=${result_input:-$default_result}
mkdir -p "$(dirname "$RESULT_FILE")"
log_step "[3/4] 결과 파일 준비: $RESULT_FILE"

{
  echo 'PostgreSQL performance check (read only)'
  echo "executed_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "host=${PGHOST:-libpq-default}"
  echo "port=${PGPORT:-libpq-default}"
  echo "database_scope=${DATABASE_SCOPE:-${PGDATABASE:-libpq-default}}"
  echo "user=${PGUSER:-libpq-default}"
  echo
} >"$RESULT_FILE"

log_step '[4/4] PostgreSQL 연결 및 성능 조회를 시작합니다.' | tee -a "$RESULT_FILE"
log_step '각 SQL 제목과 실행 시간이 화면과 결과 파일에 동시에 표시됩니다.' | tee -a "$RESULT_FILE"

psql_options="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=2000"
STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/pg-performance-status.XXXXXX")
TEMP_FILES="$TEMP_FILES $STATUS_FILE"

run_database_report() {
  report_database=$1
  pgss_source_database=${PGSS_DATABASE:-$report_database}
  : >"$STATUS_FILE"
  {
    echo
    echo '================================================================================'
    echo "DATABASE: $report_database"
    echo '================================================================================'
  } | tee -a "$RESULT_FILE"
  log_step "[$report_database] 성능 조회 시작" | tee -a "$RESULT_FILE"

  set +e
  if command -v timeout >/dev/null 2>&1; then
    (
      combined_status=0
      PGOPTIONS="$psql_options" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        timeout -s TERM 60 psql -X -d "$pgss_source_database" \
        -v "top_n=$TOP_N" -v "target_database=$report_database" \
        -f "$PGSS_SQL_FILE" || combined_status=$?
      PGOPTIONS="$psql_options" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        timeout -s TERM 60 psql -X -d "$report_database" \
        -v "top_n=$TOP_N" -f "$DATABASE_SQL_FILE" || combined_status=$?
      printf '%s\n' "$combined_status" >"$STATUS_FILE"
    ) 2>&1 | tee -a "$RESULT_FILE"
  else
    (
      combined_status=0
      PGOPTIONS="$psql_options" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        psql -X -d "$pgss_source_database" \
        -v "top_n=$TOP_N" -v "target_database=$report_database" \
        -f "$PGSS_SQL_FILE" || combined_status=$?
      PGOPTIONS="$psql_options" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        psql -X -d "$report_database" -v "top_n=$TOP_N" \
        -f "$DATABASE_SQL_FILE" || combined_status=$?
      printf '%s\n' "$combined_status" >"$STATUS_FILE"
    ) 2>&1 | tee -a "$RESULT_FILE"
  fi
  set -e

  report_status=$(cat "$STATUS_FILE")
  if [ -z "$report_status" ]; then
    report_status=1
  fi
  if [ "$report_status" -eq 0 ]; then
    log_step "[$report_database] 성능 조회 완료" | tee -a "$RESULT_FILE"
    return 0
  fi
  if [ "$report_status" -eq 124 ]; then
    echo "[$report_database] 제한시간 60초 초과" | tee -a "$RESULT_FILE" >&2
  else
    echo "[$report_database] 조회 실패(status=$report_status)" | tee -a "$RESULT_FILE" >&2
  fi
  return "$report_status"
}

success_count=0
failure_count=0
while IFS= read -r target_database; do
  [ -n "$target_database" ] || continue
  if run_database_report "$target_database"; then
    success_count=$((success_count + 1))
  else
    failure_count=$((failure_count + 1))
  fi
done <"$DATABASE_TARGETS_FILE"

log_step "전체 조회 종료: 성공=${success_count}, 실패=${failure_count}, 결과=$RESULT_FILE" | tee -a "$RESULT_FILE"
if [ "$success_count" -eq 0 ]; then
  exit 2
fi
