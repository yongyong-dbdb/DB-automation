#!/bin/bash

set -u

SCRIPT_VERSION="2026.08.13-v3-first-backup-only"

DB_USER=""
DB_HOST=""
SCHEMA_NAME=""

cleanup()
{
    unset PGPASSWORD
}

trap cleanup EXIT

echo "============================================================"
echo " inst_no 및 테이블명 실제 변경"
echo " Version: ${SCRIPT_VERSION}"
echo "============================================================"
echo
echo "처리 순서:"
echo "  1. PostgreSQL 접속 및 작업 Database 선택"
echo "  2. 대상 테이블 확인"
echo "  3. 작업 전 최종 확인"
echo "  4. UPDATE 전 Database 백업 DB 생성"
echo "  5. inst_no UPDATE / TABLE RENAME"
echo "  6. 최종 검증"
echo
echo "※ 백업은 pg_dump가 아니라 Database 복제 방식입니다."
echo "※ 작업 DB가 source_db이면 백업 DB는 source_db_bk로 생성됩니다."
echo "※ 백업 DB가 없을 때 최초 1회만 생성합니다."
echo "※ 기존 백업 DB가 있으면 삭제/덮어쓰기하지 않고 그대로 사용합니다."
echo "※ 최초 백업 생성 성공 또는 기존 백업 DB 확인 후 UPDATE / RENAME을 수행합니다."
echo

# ============================================================
# PostgreSQL Port 입력
# ============================================================

read -r -p "PostgreSQL Host 입력 [기본값: localhost] : " DB_HOST
DB_HOST="${DB_HOST:-localhost}"

read -r -p "PostgreSQL User 입력 [기본값: postgres] : " DB_USER
DB_USER="${DB_USER:-postgres}"

read -r -p "작업 Schema 이름 입력 : " SCHEMA_NAME

if ! [[ "${SCHEMA_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "[ERROR] Schema 이름은 영문 또는 _로 시작하고 영문/숫자/_만 사용할 수 있습니다."
    exit 1
fi

read -r -p "PostgreSQL Port 입력 [기본값: 5432] : " DB_PORT

DB_PORT="${DB_PORT:-5432}"

if ! [[ "${DB_PORT}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] PostgreSQL Port는 숫자만 입력해야 합니다."
    exit 1
fi

if [ "${DB_PORT}" -lt 1 ] || [ "${DB_PORT}" -gt 65535 ]; then
    echo "[ERROR] PostgreSQL Port는 1~65535 사이여야 합니다."
    exit 1
fi

# ============================================================
# 비밀번호 최초 1회
# ============================================================

read -s -r -p "PostgreSQL Password: " PGPASSWORD
echo

export PGPASSWORD

# ============================================================
# [1/6] PostgreSQL 접속 및 Database 선택
# ============================================================

echo
echo "[1/6] PostgreSQL 접속 및 Database 선택"
echo

psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -Atc "SELECT 1;" \
    >/dev/null

if [ $? -ne 0 ]; then
    echo "[ERROR] PostgreSQL 접속 실패"
    echo "[INFO] Host=${DB_HOST}, Port=${DB_PORT}, User=${DB_USER}"
    exit 1
fi

echo "[OK] PostgreSQL 접속 성공"
echo
echo "[선택 가능한 Database]"

psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d postgres \
    -P pager=off \
    -c "
SELECT
    datname AS database,
    pg_get_userbyid(datdba) AS owner,
    pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
WHERE datallowconn
  AND NOT datistemplate
ORDER BY datname;
"

if [ $? -ne 0 ]; then
    echo "[ERROR] Database 목록 조회 실패"
    exit 1
fi

echo
read -r -p "작업할 Database 이름 입력 [기본값: source_db] : " DB_NAME
DB_NAME="${DB_NAME:-source_db}"

# 이 스크립트에서 SQL literal/DB명으로 안전하게 사용할 운영 DB 이름만 허용
if ! [[ "${DB_NAME}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "[ERROR] Database 이름은 영문/숫자/_,.,- 문자만 사용할 수 있습니다."
    exit 1
fi

DB_EXISTS=$(psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -Atc "SELECT count(*) FROM pg_database WHERE datname = '${DB_NAME}' AND datallowconn;")

if [ $? -ne 0 ]; then
    echo "[ERROR] Database 존재 여부 확인 실패"
    exit 1
fi

if [ "${DB_EXISTS}" -ne 1 ]; then
    echo "[ERROR] 작업할 Database가 존재하지 않거나 접속할 수 없습니다: ${DB_NAME}"
    exit 1
fi

psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -Atc "SELECT 1;" \
    >/dev/null

if [ $? -ne 0 ]; then
    echo "[ERROR] 선택한 Database 접속 실패"
    echo "[INFO] Database=${DB_NAME}"
    exit 1
fi

echo "[OK] 작업 Database 선택 완료: ${DB_NAME}"
echo "[INFO] 생성 예정 백업 DB: ${DB_NAME}_bk"

# ============================================================
# inst_no 입력
# ============================================================

read -r -p "기존 inst_no 입력 : " OLD_INST

if ! [[ "${OLD_INST}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] 기존 inst_no는 숫자만 입력해야 합니다."
    exit 1
fi

read -r -p "변경할 inst_no 입력 : " NEW_INST

if ! [[ "${NEW_INST}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] 변경할 inst_no는 숫자만 입력해야 합니다."
    exit 1
fi

if [ "${OLD_INST}" = "${NEW_INST}" ]; then
    echo "[ERROR] 기존 inst_no와 변경할 inst_no가 같습니다."
    exit 1
fi

# ============================================================
# 대상 패턴
# ============================================================

TARGET_PATTERN="_${OLD_INST}(_[0-9]{6}|_[0-9]{8})?$"

echo
echo "============================================================"
echo " Database : ${DB_NAME}"
echo " Backup   : ${DB_NAME}_bk"
echo " User     : ${DB_USER}"
echo " Host     : ${DB_HOST}"
echo " Port     : ${DB_PORT}"
echo " Schema   : ${SCHEMA_NAME}"
echo " inst_no  : ${OLD_INST} -> ${NEW_INST}"
echo
echo " 대상 테이블:"
echo "   *_${OLD_INST}"
echo "   *_${OLD_INST}_YYYYMM"
echo "   *_${OLD_INST}_YYYYMMDD"
echo
echo " 처리 조건:"
echo
echo "   NEW_INST 테이블 이미 존재"
echo "     -> 해당 OLD_INST 테이블 UPDATE / RENAME 모두 SKIP"
echo
echo "   inst_no 컬럼 존재"
echo "     -> inst_no UPDATE 후 TABLE RENAME"
echo
echo "   inst_no 컬럼 없음"
echo "     -> UPDATE만 SKIP 후 TABLE RENAME"
echo
echo "   사용자 Trigger 존재"
echo "     -> 전체 작업 중단 / ROLLBACK"
echo
echo "   inst_no 컬럼이 있는 실제 처리 대상 내부에"
echo "   inst_no=${NEW_INST} 데이터 존재"
echo "     -> 전체 작업 중단 / ROLLBACK"
echo
echo "   UPDATE 실행 전"
echo "     -> ${DB_NAME}_bk Database 생성"
echo "     -> 백업 실패 시 UPDATE / RENAME 수행 안 함"
echo "============================================================"
echo
# ============================================================
# [2/6] 대상 테이블 확인
# ============================================================

echo
echo "[2/6] 대상 테이블 확인"

TARGET_COUNT=$(psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -Atc "
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname = '${SCHEMA_NAME}'
  AND c.relkind IN ('r','p')
  AND c.relname ~ '${TARGET_PATTERN}';
")

if [ $? -ne 0 ]; then
    echo "[ERROR] 대상 테이블 조회 실패"
    exit 1
fi

echo "[INFO] 전체 OLD_INST 대상 테이블 수: ${TARGET_COUNT}"

if [ "${TARGET_COUNT}" -eq 0 ]; then
    echo "[ERROR] 변경 대상 테이블이 없습니다."
    exit 1
fi

echo
echo "[INFO] 대상 테이블 및 처리 예정 상태"
echo

psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    -P pager=off \
    -c "
WITH target AS
(
    SELECT
        c.oid,
        c.relname AS old_table_name,

        CASE
            WHEN c.relname ~ '_${OLD_INST}_[0-9]{8}$'
            THEN regexp_replace(
                     c.relname,
                     '_${OLD_INST}_([0-9]{8})$',
                     '_${NEW_INST}_\1'
                 )

            WHEN c.relname ~ '_${OLD_INST}_[0-9]{6}$'
            THEN regexp_replace(
                     c.relname,
                     '_${OLD_INST}_([0-9]{6})$',
                     '_${NEW_INST}_\1'
                 )

            WHEN c.relname ~ '_${OLD_INST}$'
            THEN regexp_replace(
                     c.relname,
                     '_${OLD_INST}$',
                     '_${NEW_INST}'
                 )
        END AS new_table_name

    FROM pg_class c

    JOIN pg_namespace n
      ON n.oid = c.relnamespace

    WHERE n.nspname = '${SCHEMA_NAME}'
      AND c.relkind IN ('r','p')
      AND c.relname ~ '${TARGET_PATTERN}'
)
SELECT
    t.old_table_name,
    t.new_table_name,

    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM pg_class c2
            JOIN pg_namespace n2
              ON n2.oid = c2.relnamespace
            WHERE n2.nspname = '${SCHEMA_NAME}'
              AND c2.relname = t.new_table_name
        )
        THEN 'SKIP - NEW TABLE EXISTS'

        WHEN NOT EXISTS
        (
            SELECT 1
            FROM pg_attribute a
            WHERE a.attrelid = t.oid
              AND a.attname = 'inst_no'
              AND a.attnum > 0
              AND NOT a.attisdropped
        )
        THEN 'RENAME ONLY - NO inst_no'

        ELSE 'UPDATE + RENAME'
    END AS action

FROM target t

ORDER BY t.old_table_name;
"

if [ $? -ne 0 ]; then
    echo "[ERROR] 대상 테이블 목록 조회 실패"
    exit 1
fi

# ============================================================
# [3/6] 작업 전 안내
# ============================================================

echo
echo "[3/6] 실제 UPDATE / RENAME 전 안내"
echo

echo "처리 기준:"
echo
echo "1. 변경 후 NEW_INST 테이블이 이미 존재"
echo "   -> 해당 OLD_INST 테이블 UPDATE / RENAME 모두 SKIP"
echo
echo "2. inst_no 컬럼 존재"
echo "   -> inst_no ${OLD_INST} -> ${NEW_INST} UPDATE"
echo "   -> TABLE RENAME"
echo
echo "3. inst_no 컬럼 없음"
echo "   -> inst_no UPDATE SKIP"
echo "   -> TABLE RENAME만 수행"
echo
echo "4. 실제 처리 대상에 사용자 Trigger 존재"
echo "   -> 전체 작업 중단"
echo
echo "5. inst_no 컬럼이 있는 실제 처리 대상 내부에"
echo "   inst_no=${NEW_INST} 데이터 존재"
echo "   -> 전체 작업 중단"
echo
echo "전체 UPDATE / RENAME / 최종 검증은 하나의 Transaction입니다."
echo "중간에 오류가 발생하면 전체 ROLLBACK됩니다."
echo

read -p "계속 진행하려면 'yes' 입력 : " CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
    echo "[INFO] 사용자 취소"
    exit 0
fi

# ============================================================
# [4/6] UPDATE 전 Database 백업 DB 확인 / 최초 1회 생성
# ============================================================

echo
echo "[4/6] UPDATE 전 Database 백업 DB 확인 / 최초 1회 생성"
echo

BACKUP_DB="${DB_NAME}_bk"

echo "[INFO] 원본 Database : ${DB_NAME}"
echo "[INFO] 백업 Database : ${BACKUP_DB}"
echo

# 백업 DB 존재 여부 확인
BACKUP_DB_EXISTS=$(psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -Atc "SELECT count(*) FROM pg_database WHERE datname = '${BACKUP_DB}';")

if [ $? -ne 0 ]; then
    echo "[ERROR] 백업 Database 존재 여부 확인 실패"
    exit 1
fi

# ------------------------------------------------------------
# 기존 백업 DB가 있으면 최초 백업으로 간주하고 그대로 사용
# ------------------------------------------------------------

if [ "${BACKUP_DB_EXISTS}" -eq 1 ]; then

    echo "[OK] 기존 백업 Database가 존재합니다."
    echo "[INFO] 최초 백업 DB를 그대로 유지하고 새 백업은 생성하지 않습니다."
    echo "[INFO] Backup Database : ${BACKUP_DB}"

    BACKUP_SIZE=$(psql \
        -X \
        -w \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -Atc "SELECT pg_size_pretty(pg_database_size('${BACKUP_DB}'));" 2>/dev/null)

    BACKUP_OWNER=$(psql \
        -X \
        -w \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -Atc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${BACKUP_DB}';" 2>/dev/null)

    if [ -n "${BACKUP_OWNER}" ]; then
        echo "[INFO] Backup Owner    : ${BACKUP_OWNER}"
    fi

    if [ -n "${BACKUP_SIZE}" ]; then
        echo "[INFO] Backup Size     : ${BACKUP_SIZE}"
    fi

    echo "[OK] 기존 백업 DB 확인 완료 - UPDATE / RENAME을 계속 수행합니다."

elif [ "${BACKUP_DB_EXISTS}" -eq 0 ]; then

    echo "[INFO] 기존 백업 Database가 없습니다."
    echo "[INFO] 최초 1회 백업 DB를 생성합니다."
    echo

    # createdb 명령 확인
    if ! command -v createdb >/dev/null 2>&1; then
        echo "[ERROR] createdb 명령어를 찾을 수 없습니다."
        echo "[ERROR] 최초 백업 DB를 생성하지 못했으므로 UPDATE / RENAME을 수행하지 않습니다."
        exit 1
    fi

    # 원본 DB Owner 확인
    DB_OWNER=$(psql \
        -X \
        -w \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -Atc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DB_NAME}';")

    if [ $? -ne 0 ] || [ -z "${DB_OWNER}" ]; then
        echo "[ERROR] 원본 Database Owner 조회 실패"
        exit 1
    fi

    echo "[INFO] Database Owner : ${DB_OWNER}"
    echo

    # CREATE DATABASE ... TEMPLATE 수행 전 원본 DB 접속 세션 확인
    SOURCE_DATA_A_COUNT=$(psql \
        -X \
        -w \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname = '${DB_NAME}';")

    if [ $? -ne 0 ]; then
        echo "[ERROR] 원본 Database 접속 세션 확인 실패"
        exit 1
    fi

    echo "[INFO] 원본 Database 접속 세션 수 : ${SOURCE_DATA_A_COUNT}"

    if [ "${SOURCE_DATA_A_COUNT}" -ne 0 ]; then
        echo
        echo "[ERROR] 원본 Database에 접속 중인 세션이 존재합니다."
        echo "[ERROR] TEMPLATE 방식의 최초 백업 DB를 안전하게 생성할 수 없으므로 중단합니다."
        echo
        echo "[현재 접속 세션]"

        psql \
            -X \
            -w \
            -h "${DB_HOST}" \
            -p "${DB_PORT}" \
            -U "${DB_USER}" \
            -d postgres \
            -P pager=off \
            -c "
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    query_start,
    left(query, 120) AS query
FROM pg_stat_activity
WHERE datname = '${DB_NAME}'
ORDER BY pid;
"

        echo
        echo "[INFO] 세션을 정리한 후 다시 실행하십시오."
        echo "[INFO] 본 스크립트는 세션을 강제 종료하지 않습니다."
        exit 1
    fi

    echo "[OK] 원본 Database 접속 세션 없음"
    echo
    echo "[BACKUP] 최초 Database 복제 시작"
    echo "  ${DB_NAME} -> ${BACKUP_DB}"
    echo

    createdb \
        -w \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -T "${DB_NAME}" \
        -O "${DB_OWNER}" \
        "${BACKUP_DB}"

    BACKUP_RESULT=$?

    if [ ${BACKUP_RESULT} -ne 0 ]; then
        echo
        echo "[ERROR] 최초 Database 백업 생성 실패"
        echo "[ERROR] UPDATE / RENAME을 수행하지 않습니다."
        exit 1
    fi

    # 백업 DB 생성 검증
    BACKUP_VERIFY=$(psql \
        -X \
        -w \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -Atc "SELECT count(*) FROM pg_database WHERE datname = '${BACKUP_DB}';")

    if [ $? -ne 0 ] || [ "${BACKUP_VERIFY}" -ne 1 ]; then
        echo "[ERROR] 최초 백업 Database 생성 후 검증 실패"
        echo "[ERROR] UPDATE / RENAME을 수행하지 않습니다."
        exit 1
    fi

    BACKUP_SIZE=$(psql \
        -X \
        -w \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -Atc "SELECT pg_size_pretty(pg_database_size('${BACKUP_DB}'));" 2>/dev/null)

    echo
    echo "[OK] 최초 UPDATE 전 Database 백업 완료"
    echo "[OK] Backup Database : ${BACKUP_DB}"
    echo "[OK] Owner           : ${DB_OWNER}"

    if [ -n "${BACKUP_SIZE}" ]; then
        echo "[OK] Backup Size     : ${BACKUP_SIZE}"
    fi

else
    echo "[ERROR] 백업 Database 존재 여부 확인 결과가 비정상입니다: ${BACKUP_DB_EXISTS}"
    exit 1
fi

echo
# ============================================================
# [5/6] 트랜잭션 시작
# ============================================================

echo
echo "[5/6] 트랜잭션 시작 및 실제 변경"
echo

psql \
    -X \
    -w \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 <<EOF

\set VERBOSITY verbose
\set ON_ERROR_STOP on

BEGIN;

-- ============================================================
-- 사전 검증
-- ============================================================

DO \$\$
DECLARE
    r RECORD;
    v_new_table_name text;
    v_exists bigint;
    v_trigger_list text;
    v_process_count integer := 0;
    v_update_rename_count integer := 0;
    v_rename_only_count integer := 0;
    v_skip_count integer := 0;
    v_has_inst_no boolean;
BEGIN

    RAISE NOTICE '============================================================';
    RAISE NOTICE '사전 검증 시작';
    RAISE NOTICE '============================================================';

    ----------------------------------------------------------------
    -- 1. 대상 테이블 존재 확인
    ----------------------------------------------------------------

    SELECT count(*)
      INTO v_exists
      FROM pg_class c
      JOIN pg_namespace n
        ON n.oid = c.relnamespace
     WHERE n.nspname = '${SCHEMA_NAME}'
       AND c.relkind IN ('r','p')
       AND c.relname ~ '${TARGET_PATTERN}';

    IF v_exists = 0 THEN
        RAISE EXCEPTION
            '변경 대상 테이블이 존재하지 않습니다.';
    END IF;

    RAISE NOTICE
        '[OK] 전체 OLD_INST 대상 테이블 = %',
        v_exists;

    ----------------------------------------------------------------
    -- 2. 실제 처리 / SKIP 대상 분류
    ----------------------------------------------------------------

    FOR r IN
        SELECT
            c.oid,
            c.relname
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = '${SCHEMA_NAME}'
          AND c.relkind IN ('r','p')
          AND c.relname ~ '${TARGET_PATTERN}'
        ORDER BY c.relname
    LOOP

        ------------------------------------------------------------
        -- 변경 후 TABLE NAME 생성
        ------------------------------------------------------------

        IF r.relname ~ '_${OLD_INST}_[0-9]{8}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{8})$',
                    '_${NEW_INST}_\1'
                );

        ELSIF r.relname ~ '_${OLD_INST}_[0-9]{6}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{6})$',
                    '_${NEW_INST}_\1'
                );

        ELSIF r.relname ~ '_${OLD_INST}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}$',
                    '_${NEW_INST}'
                );

        ELSE

            RAISE EXCEPTION
                '지원하지 않는 테이블명 패턴: %',
                r.relname;

        END IF;

        ------------------------------------------------------------
        -- NEW_INST TABLE 존재 여부
        ------------------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM pg_class c2
            JOIN pg_namespace n2
              ON n2.oid = c2.relnamespace
            WHERE n2.nspname = '${SCHEMA_NAME}'
              AND c2.relname = v_new_table_name
        )
        THEN

            v_skip_count := v_skip_count + 1;

            RAISE NOTICE
                '[SKIP] %.% -> %.% : NEW_INST 테이블 이미 존재',
                '${SCHEMA_NAME}',
                r.relname,
                '${SCHEMA_NAME}',
                v_new_table_name;

            CONTINUE;
        END IF;

        ------------------------------------------------------------
        -- inst_no 컬럼 존재 여부
        ------------------------------------------------------------

        SELECT EXISTS
        (
            SELECT 1
            FROM pg_attribute a
            WHERE a.attrelid = r.oid
              AND a.attname = 'inst_no'
              AND a.attnum > 0
              AND NOT a.attisdropped
        )
        INTO v_has_inst_no;

        v_process_count := v_process_count + 1;

        IF v_has_inst_no THEN

            v_update_rename_count :=
                v_update_rename_count + 1;

            RAISE NOTICE
                '[UPDATE + RENAME] %.%',
                '${SCHEMA_NAME}',
                r.relname;

        ELSE

            v_rename_only_count :=
                v_rename_only_count + 1;

            RAISE NOTICE
                '[RENAME ONLY] %.% : inst_no 컬럼 없음',
                '${SCHEMA_NAME}',
                r.relname;

        END IF;

    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '[INFO] 실제 처리 대상 = %', v_process_count;
    RAISE NOTICE '[INFO] UPDATE + RENAME = %', v_update_rename_count;
    RAISE NOTICE '[INFO] RENAME ONLY = %', v_rename_only_count;
    RAISE NOTICE '[INFO] NEW_INST 이미 존재로 SKIP = %', v_skip_count;

    ----------------------------------------------------------------
    -- 3. inst_no 컬럼 확인
    ----------------------------------------------------------------

    FOR r IN
        SELECT
            c.oid,
            c.relname
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = '${SCHEMA_NAME}'
          AND c.relkind IN ('r','p')
          AND c.relname ~ '${TARGET_PATTERN}'
        ORDER BY c.relname
    LOOP

        IF r.relname ~ '_${OLD_INST}_[0-9]{8}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{8})$',
                    '_${NEW_INST}_\1'
                );

        ELSIF r.relname ~ '_${OLD_INST}_[0-9]{6}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{6})$',
                    '_${NEW_INST}_\1'
                );

        ELSE

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}$',
                    '_${NEW_INST}'
                );

        END IF;

        ------------------------------------------------------------
        -- NEW_INST TABLE 이미 존재하면 검증 제외
        ------------------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM pg_class c2
            JOIN pg_namespace n2
              ON n2.oid = c2.relnamespace
            WHERE n2.nspname = '${SCHEMA_NAME}'
              AND c2.relname = v_new_table_name
        )
        THEN
            CONTINUE;
        END IF;

        ------------------------------------------------------------
        -- inst_no 컬럼 없는 경우 NOTICE만 출력
        ------------------------------------------------------------

        IF NOT EXISTS
        (
            SELECT 1
            FROM pg_attribute a
            WHERE a.attrelid = r.oid
              AND a.attname = 'inst_no'
              AND a.attnum > 0
              AND NOT a.attisdropped
        )
        THEN

            RAISE NOTICE
                '[SKIP UPDATE] %.% : inst_no 컬럼 없음 - RENAME만 수행 예정',
                '${SCHEMA_NAME}',
                r.relname;

        END IF;

    END LOOP;

    RAISE NOTICE
        '[OK] inst_no 컬럼 검증 완료';

    ----------------------------------------------------------------
    -- 4. 실제 처리 대상 Trigger 확인
    ----------------------------------------------------------------

    SELECT string_agg(
               format(
                   '%I.%I -> %I',
                   n.nspname,
                   c.relname,
                   t.tgname
               ),
               E'\n'
               ORDER BY c.relname, t.tgname
           )
      INTO v_trigger_list
      FROM pg_trigger t
      JOIN pg_class c
        ON c.oid = t.tgrelid
      JOIN pg_namespace n
        ON n.oid = c.relnamespace
     WHERE n.nspname = '${SCHEMA_NAME}'
       AND c.relkind IN ('r','p')
       AND c.relname ~ '${TARGET_PATTERN}'
       AND NOT t.tgisinternal
       AND NOT EXISTS
       (
           SELECT 1
           FROM pg_class c2
           JOIN pg_namespace n2
             ON n2.oid = c2.relnamespace
           WHERE n2.nspname = '${SCHEMA_NAME}'
             AND c2.relname =
                 CASE
                     WHEN c.relname ~ '_${OLD_INST}_[0-9]{8}$'
                     THEN regexp_replace(
                              c.relname,
                              '_${OLD_INST}_([0-9]{8})$',
                              '_${NEW_INST}_\1'
                          )

                     WHEN c.relname ~ '_${OLD_INST}_[0-9]{6}$'
                     THEN regexp_replace(
                              c.relname,
                              '_${OLD_INST}_([0-9]{6})$',
                              '_${NEW_INST}_\1'
                          )

                     ELSE regexp_replace(
                              c.relname,
                              '_${OLD_INST}$',
                              '_${NEW_INST}'
                          )
                 END
       );

    IF v_trigger_list IS NOT NULL THEN

        RAISE NOTICE 'Trigger 목록:';
        RAISE NOTICE '%', v_trigger_list;

        RAISE EXCEPTION
            '실제 처리 대상 테이블에 Trigger가 존재하므로 작업을 중단합니다.';

    END IF;

    RAISE NOTICE
        '[OK] 실제 처리 대상 사용자 Trigger 없음';

    ----------------------------------------------------------------
    -- 5. inst_no 컬럼이 있는 실제 처리 대상 내부
    --    NEW_INST 데이터 확인
    ----------------------------------------------------------------

    FOR r IN
        SELECT
            c.oid,
            c.relname
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = '${SCHEMA_NAME}'
          AND c.relkind IN ('r','p')
          AND c.relname ~ '${TARGET_PATTERN}'
        ORDER BY c.relname
    LOOP

        IF r.relname ~ '_${OLD_INST}_[0-9]{8}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{8})$',
                    '_${NEW_INST}_\1'
                );

        ELSIF r.relname ~ '_${OLD_INST}_[0-9]{6}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{6})$',
                    '_${NEW_INST}_\1'
                );

        ELSE

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}$',
                    '_${NEW_INST}'
                );

        END IF;

        ------------------------------------------------------------
        -- 이미 처리된 대상 SKIP
        ------------------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM pg_class c2
            JOIN pg_namespace n2
              ON n2.oid = c2.relnamespace
            WHERE n2.nspname = '${SCHEMA_NAME}'
              AND c2.relname = v_new_table_name
        )
        THEN
            CONTINUE;
        END IF;

        ------------------------------------------------------------
        -- inst_no 컬럼 없는 테이블은 검사 SKIP
        ------------------------------------------------------------

        IF NOT EXISTS
        (
            SELECT 1
            FROM pg_attribute a
            WHERE a.attrelid = r.oid
              AND a.attname = 'inst_no'
              AND a.attnum > 0
              AND NOT a.attisdropped
        )
        THEN

            RAISE NOTICE
                '[SKIP CHECK] %.% : inst_no 컬럼 없음',
                '${SCHEMA_NAME}',
                r.relname;

            CONTINUE;
        END IF;

        ------------------------------------------------------------
        -- NEW_INST 데이터 존재 확인
        ------------------------------------------------------------

        EXECUTE format(
            'SELECT count(*)
               FROM %I.%I
              WHERE inst_no = \$1',
            '${SCHEMA_NAME}',
            r.relname
        )
        INTO v_exists
        USING ${NEW_INST};

        IF v_exists > 0 THEN

            RAISE EXCEPTION
                '%.% 테이블에 이미 inst_no=${NEW_INST} 데이터가 %건 존재합니다. PK/UNIQUE 충돌 가능성 때문에 중단합니다.',
                '${SCHEMA_NAME}',
                r.relname,
                v_exists;

        END IF;

    END LOOP;

    RAISE NOTICE
        '[OK] inst_no 컬럼 보유 대상 내부에 inst_no=${NEW_INST} 데이터 없음';

    RAISE NOTICE '============================================================';
    RAISE NOTICE '사전 검증 완료';
    RAISE NOTICE '============================================================';

END
\$\$;

-- ============================================================
-- 실제 UPDATE / RENAME
-- ============================================================

DO \$\$
DECLARE
    r RECORD;
    v_new_table_name text;
    v_update_count bigint;
    v_total_update_count bigint := 0;
    v_update_table_count integer := 0;
    v_rename_only_count integer := 0;
    v_rename_count integer := 0;
    v_skip_count integer := 0;
    v_has_inst_no boolean;
BEGIN

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '실제 UPDATE / RENAME 시작';
    RAISE NOTICE '============================================================';

    FOR r IN
        SELECT
            c.oid,
            c.relname
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = '${SCHEMA_NAME}'
          AND c.relkind IN ('r','p')
          AND c.relname ~ '${TARGET_PATTERN}'
        ORDER BY c.relname
    LOOP

        ------------------------------------------------------------
        -- 변경 후 TABLE NAME 생성
        ------------------------------------------------------------

        IF r.relname ~ '_${OLD_INST}_[0-9]{8}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{8})$',
                    '_${NEW_INST}_\1'
                );

        ELSIF r.relname ~ '_${OLD_INST}_[0-9]{6}$' THEN

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}_([0-9]{6})$',
                    '_${NEW_INST}_\1'
                );

        ELSE

            v_new_table_name :=
                regexp_replace(
                    r.relname,
                    '_${OLD_INST}$',
                    '_${NEW_INST}'
                );

        END IF;

        ------------------------------------------------------------
        -- NEW_INST TABLE 이미 존재하면 전체 SKIP
        ------------------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM pg_class c2
            JOIN pg_namespace n2
              ON n2.oid = c2.relnamespace
            WHERE n2.nspname = '${SCHEMA_NAME}'
              AND c2.relname = v_new_table_name
        )
        THEN

            v_skip_count := v_skip_count + 1;

            RAISE NOTICE
                '[SKIP] %.% -> %.% : NEW_INST 테이블 이미 존재',
                '${SCHEMA_NAME}',
                r.relname,
                '${SCHEMA_NAME}',
                v_new_table_name;

            CONTINUE;
        END IF;

        ------------------------------------------------------------
        -- inst_no 컬럼 존재 여부
        ------------------------------------------------------------

        SELECT EXISTS
        (
            SELECT 1
            FROM pg_attribute a
            WHERE a.attrelid = r.oid
              AND a.attname = 'inst_no'
              AND a.attnum > 0
              AND NOT a.attisdropped
        )
        INTO v_has_inst_no;

        ------------------------------------------------------------
        -- inst_no 컬럼 있으면 UPDATE 수행
        ------------------------------------------------------------

        IF v_has_inst_no THEN

            RAISE NOTICE
                '[UPDATE] %.% : inst_no ${OLD_INST} -> ${NEW_INST}',
                '${SCHEMA_NAME}',
                r.relname;

            EXECUTE format(
                'UPDATE %I.%I
                    SET inst_no = \$1
                  WHERE inst_no = \$2',
                '${SCHEMA_NAME}',
                r.relname
            )
            USING
                ${NEW_INST},
                ${OLD_INST};

            GET DIAGNOSTICS
                v_update_count = ROW_COUNT;

            v_total_update_count :=
                v_total_update_count + v_update_count;

            v_update_table_count :=
                v_update_table_count + 1;

            RAISE NOTICE
                '         updated rows = %',
                v_update_count;

        ELSE

            --------------------------------------------------------
            -- inst_no 컬럼 없으면 UPDATE SKIP
            --------------------------------------------------------

            v_rename_only_count :=
                v_rename_only_count + 1;

            RAISE NOTICE
                '[SKIP UPDATE] %.% : inst_no 컬럼 없음',
                '${SCHEMA_NAME}',
                r.relname;

        END IF;

        ------------------------------------------------------------
        -- TABLE RENAME
        ------------------------------------------------------------

        RAISE NOTICE
            '[RENAME] %.% -> %.%',
            '${SCHEMA_NAME}',
            r.relname,
            '${SCHEMA_NAME}',
            v_new_table_name;

        EXECUTE format(
            'ALTER TABLE %I.%I RENAME TO %I',
            '${SCHEMA_NAME}',
            r.relname,
            v_new_table_name
        );

        v_rename_count :=
            v_rename_count + 1;

    END LOOP;

    RAISE NOTICE '';

    RAISE NOTICE
        '[OK] UPDATE 수행 테이블 = %',
        v_update_table_count;

    RAISE NOTICE
        '[OK] RENAME ONLY 수행 테이블 = %',
        v_rename_only_count;

    RAISE NOTICE
        '[OK] 전체 RENAME 수행 테이블 = %',
        v_rename_count;

    RAISE NOTICE
        '[INFO] NEW_INST 존재로 전체 SKIP = %',
        v_skip_count;

    RAISE NOTICE
        '[OK] 전체 UPDATE 건수 = %',
        v_total_update_count;

END
\$\$;

-- ============================================================
-- 최종 검증
-- ============================================================

DO \$\$
DECLARE
    v_unprocessed_count bigint;
    v_unprocessed_list text;
    v_old_data_count bigint := 0;
    r RECORD;
    v_count bigint;
BEGIN

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '최종 검증';
    RAISE NOTICE '============================================================';

    ----------------------------------------------------------------
    -- 1. OLD_INST 테이블이 남아있는 경우
    --
    -- 대응 NEW_INST TABLE 존재
    -- -> 정상 SKIP
    --
    -- 대응 NEW_INST TABLE 없음
    -- -> 미처리 ERROR
    ----------------------------------------------------------------

    SELECT
        count(*),

        string_agg(
            x.old_table_name,
            E'\n'
            ORDER BY x.old_table_name
        )

    INTO
        v_unprocessed_count,
        v_unprocessed_list

    FROM
    (
        SELECT
            c.relname AS old_table_name,

            CASE
                WHEN c.relname ~ '_${OLD_INST}_[0-9]{8}$'
                THEN regexp_replace(
                         c.relname,
                         '_${OLD_INST}_([0-9]{8})$',
                         '_${NEW_INST}_\1'
                     )

                WHEN c.relname ~ '_${OLD_INST}_[0-9]{6}$'
                THEN regexp_replace(
                         c.relname,
                         '_${OLD_INST}_([0-9]{6})$',
                         '_${NEW_INST}_\1'
                     )

                ELSE regexp_replace(
                         c.relname,
                         '_${OLD_INST}$',
                         '_${NEW_INST}'
                     )
            END AS new_table_name

        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = '${SCHEMA_NAME}'
          AND c.relkind IN ('r','p')
          AND c.relname ~ '${TARGET_PATTERN}'

    ) x

    WHERE NOT EXISTS
    (
        SELECT 1
        FROM pg_class c2
        JOIN pg_namespace n2
          ON n2.oid = c2.relnamespace
        WHERE n2.nspname = '${SCHEMA_NAME}'
          AND c2.relname = x.new_table_name
    );

    IF v_unprocessed_count > 0 THEN

        RAISE NOTICE
            '처리되지 않은 OLD_INST 테이블:';

        RAISE NOTICE
            '%',
            v_unprocessed_list;

        RAISE EXCEPTION
            'NEW_INST 대응 테이블이 없는 OLD_INST 테이블이 %개 남아 있습니다.',
            v_unprocessed_count;

    END IF;

    ----------------------------------------------------------------
    -- 2. NEW_INST TABLE 내부 OLD_INST DATA 확인
    --
    -- inst_no 컬럼이 있는 테이블만 검사
    ----------------------------------------------------------------

    FOR r IN
        SELECT
            c.oid,
            c.relname
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = '${SCHEMA_NAME}'
          AND c.relkind IN ('r','p')
          AND c.relname ~ '_${NEW_INST}(_[0-9]{6}|_[0-9]{8})?$'
        ORDER BY c.relname
    LOOP

        IF EXISTS
        (
            SELECT 1
            FROM pg_attribute a
            WHERE a.attrelid = r.oid
              AND a.attname = 'inst_no'
              AND a.attnum > 0
              AND NOT a.attisdropped
        )
        THEN

            EXECUTE format(
                'SELECT count(*)
                   FROM %I.%I
                  WHERE inst_no = \$1',
                '${SCHEMA_NAME}',
                r.relname
            )
            INTO v_count
            USING ${OLD_INST};

            v_old_data_count :=
                v_old_data_count + v_count;

        ELSE

            RAISE NOTICE
                '[SKIP CHECK] %.% : inst_no 컬럼 없음',
                '${SCHEMA_NAME}',
                r.relname;

        END IF;

    END LOOP;

    IF v_old_data_count > 0 THEN

        RAISE EXCEPTION
            'NEW_INST 테이블 내부에 inst_no=${OLD_INST} 데이터가 %건 남아 있습니다.',
            v_old_data_count;

    END IF;

    RAISE NOTICE
        '[OK] 미처리 OLD_INST 테이블 없음';

    RAISE NOTICE
        '[OK] inst_no 컬럼 보유 NEW_INST 테이블 내부 inst_no=${OLD_INST} 데이터 없음';

END
\$\$;

COMMIT;

\echo
\echo '============================================================'
\echo '[SUCCESS] 전체 UPDATE / RENAME 완료 - COMMIT'
\echo '============================================================'

EOF

RESULT=$?

# ============================================================
# [6/6] 결과
# ============================================================

echo
echo "[6/6] 작업 결과"

if [ ${RESULT} -ne 0 ]; then

    echo
    echo "============================================================"
    echo "[FAILED] 작업 실패"
    echo "오류가 발생했으므로 PostgreSQL 트랜잭션은 ROLLBACK 되었습니다."
    echo "============================================================"

    exit 1

fi

echo
echo "============================================================"
echo "[SUCCESS] 작업 완료"
echo " Database : ${DB_NAME}"
echo " Host     : ${DB_HOST}"
echo " Port     : ${DB_PORT}"
echo " ${OLD_INST} -> ${NEW_INST}"
echo " inst_no 존재 테이블 : UPDATE + RENAME"
echo " inst_no 미존재 테이블 : RENAME ONLY"
echo " NEW_INST 기존 테이블 : SKIP"
echo "============================================================"

exit 0
