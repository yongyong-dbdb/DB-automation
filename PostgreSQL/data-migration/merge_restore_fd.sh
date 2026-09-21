#!/bin/bash

set -u

# ============================================================
# PostgreSQL Merge Restore
#
# Full Dump (-Fd Directory Format):
#   source_db_dump/
#
# 하나의 Directory Format Dump에서
#   - Schema
#   - 전체 Data
#   - merge_table_01 / merge_table_02 Data
# 를 분리하여 Restore
#
# 주요 정책
#
# - Backup DB:
#     TARGET_DB_bk 존재 -> 유지 / SKIP
#     TARGET_DB_bk 없음 -> TARGET_DB TEMPLATE 복제
#
# - 기존 객체:
#     유지
#
# - 없는 객체:
#     생성
#
# - PRIMARY KEY:
#     Constraint 이름이 달라도 해당 TABLE에 PK가 있으면 SKIP
#
# - FUNCTION / PROCEDURE:
#     전체 Signature로 실제 DB 조회
#
# - DATA:
#     모든 TABLE DATA를 TEMP Stage로 COPY
#     Stage -> Target INSERT ... ON CONFLICT DO NOTHING
#
# - Transaction:
#     Schema + 전체 Data를 하나의 Single Transaction으로 수행
#
# - ERROR:
#     오류 발생 시 전체 ROLLBACK
# ============================================================


# ============================================================
# 함수
# ============================================================

print_line()
{
    echo "============================================================"
}


error_exit()
{
    echo
    print_line
    echo "[ERROR] $1"
    print_line
    echo

    unset PGPASSWORD
    exit 1
}


sql_escape()
{
    printf "%s" "$1" | sed "s/'/''/g"
}


map_exists()
{
    local MAP_FILE="$1"
    local VALUE="$2"

    grep -Fxq "${VALUE}" "${MAP_FILE}" 2>/dev/null
}


db_query()
{
    psql \
        -X \
        -w \
        -h "${PGHOST}" \
        -p "${PGPORT}" \
        -U "${ADMIN_USER}" \
        -d "${TARGET_DB}" \
        -Atq \
        -c "$1" \
        2>/dev/null \
        | tail -1
}


# ============================================================
# 시작
# ============================================================

clear

print_line
echo " PostgreSQL Merge Restore"
print_line
echo


# ============================================================
# 입력
# ============================================================

read -p "Target DB name [target_db] : " TARGET_DB
TARGET_DB=${TARGET_DB:-target_db}


if ! [[ "${TARGET_DB}" =~ ^[A-Za-z0-9_]+$ ]]; then
    error_exit "Target DB 이름은 영문/숫자/_ 만 사용할 수 있습니다."
fi


BACKUP_DB="${TARGET_DB}_bk"


read -p "Full Dump directory [./source_db_dump] : " FULL_DUMP
FULL_DUMP=${FULL_DUMP:-./source_db_dump}


read -p "PostgreSQL host [localhost] : " PGHOST
PGHOST=${PGHOST:-localhost}


# ============================================================
# PostgreSQL Port 입력
# 기본값 없음 - 반드시 직접 입력
# ============================================================

read -p "PostgreSQL port : " PGPORT

if [ -z "${PGPORT}" ]; then
    error_exit "PostgreSQL port는 반드시 입력해야 합니다."
fi

if ! [[ "${PGPORT}" =~ ^[0-9]+$ ]]; then
    error_exit "PostgreSQL port는 숫자만 입력해야 합니다."
fi

if [ "${PGPORT}" -lt 1 ] || [ "${PGPORT}" -gt 65535 ]; then
    error_exit "PostgreSQL port는 1~65535 사이여야 합니다."
fi


read -p "Admin user [postgres] : " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-postgres}


# ============================================================
# 작업 파일
# ============================================================

WORK_DIR=$(dirname "${FULL_DUMP}")


FULL_LIST="${WORK_DIR}/${TARGET_DB}_schema_full.list"

RESTORE_LIST="${WORK_DIR}/${TARGET_DB}_schema_restore.list"

SELECTED_SCHEMA_SQL="${WORK_DIR}/${TARGET_DB}_selected_schema.sql"

DATA_FILE="${WORK_DIR}/${TARGET_DB}_data_raw.sql"

FILTERED_DATA_SQL="${WORK_DIR}/${TARGET_DB}_merge_data.sql"

MERGE_SQL="${WORK_DIR}/${TARGET_DB}_merge_restore.sql"

RESTORE_LOG="${WORK_DIR}/${TARGET_DB}_restore.log"

CACHE_VERSION="1"
CACHE_META="${WORK_DIR}/${TARGET_DB}_dump_cache.meta"
CURRENT_TOC_SHA=""
CACHED_TOC_SHA=""
CACHED_VERSION=""
REUSE_DATA_RAW=0
REUSE_MERGE_DATA=0
CACHED_COPY_COUNT=""
CACHED_SETVAL_COUNT=""
CACHED_STAGE_CREATE_COUNT=""
CACHED_MERGE_INSERT_COUNT=""


TABLE_MAP="${WORK_DIR}/${TARGET_DB}_table.map"

PARTITION_MAP="${WORK_DIR}/${TARGET_DB}_partition.map"

SEQUENCE_MAP="${WORK_DIR}/${TARGET_DB}_sequence.map"

INDEX_MAP="${WORK_DIR}/${TARGET_DB}_index.map"

CONSTRAINT_MAP="${WORK_DIR}/${TARGET_DB}_constraint.map"

PK_TABLE_MAP="${WORK_DIR}/${TARGET_DB}_pk_table.map"

DEFAULT_MAP="${WORK_DIR}/${TARGET_DB}_default.map"

TRIGGER_MAP="${WORK_DIR}/${TARGET_DB}_trigger.map"

RULE_MAP="${WORK_DIR}/${TARGET_DB}_rule.map"

VIEW_MAP="${WORK_DIR}/${TARGET_DB}_view.map"

MATVIEW_MAP="${WORK_DIR}/${TARGET_DB}_matview.map"

DOMAIN_MAP="${WORK_DIR}/${TARGET_DB}_domain.map"

TYPE_MAP="${WORK_DIR}/${TARGET_DB}_type.map"


rm -f \
    "${FULL_LIST}" \
    "${RESTORE_LIST}" \
    "${SELECTED_SCHEMA_SQL}" \
    "${MERGE_SQL}" \ \ \ \
    "${RESTORE_LOG}" \ \
    "${TABLE_MAP}" \
    "${PARTITION_MAP}" \
    "${SEQUENCE_MAP}" \
    "${INDEX_MAP}" \
    "${CONSTRAINT_MAP}" \
    "${PK_TABLE_MAP}" \
    "${DEFAULT_MAP}" \
    "${TRIGGER_MAP}" \
    "${RULE_MAP}" \
    "${VIEW_MAP}" \
    "${MATVIEW_MAP}" \
    "${DOMAIN_MAP}" \
    "${TYPE_MAP}"


# ============================================================
# Restore 정보
# ============================================================

echo
print_line
echo " Restore 정보"
print_line

echo
echo "Target DB       : ${TARGET_DB}"
echo "Backup DB       : ${BACKUP_DB}"
echo "Full Dump Dir   : ${FULL_DUMP}"
echo "Host            : ${PGHOST}"
echo "Port            : ${PGPORT}"
echo "Admin User      : ${ADMIN_USER}"
echo "Restore Log     : ${RESTORE_LOG}"
echo


# ============================================================
# [1/12] 입력 파일 확인 / Dump Cache 확인
# ============================================================

echo "[1/12] 입력 파일 확인 / Dump Cache 확인"
echo


if [ ! -d "${FULL_DUMP}" ]; then
    error_exit "Full Dump 디렉토리가 존재하지 않습니다: ${FULL_DUMP}"
fi


if [ ! -f "${FULL_DUMP}/toc.dat" ]; then
    error_exit "Full Dump 디렉토리에 toc.dat가 없습니다: ${FULL_DUMP}"
fi


if ! command -v sha256sum >/dev/null 2>&1; then
    error_exit "sha256sum 명령어를 찾을 수 없습니다."
fi


echo "[Full Dump Directory]"
du -sh "${FULL_DUMP}"


CURRENT_TOC_SHA=$(sha256sum "${FULL_DUMP}/toc.dat" | awk '{print $1}')


if [ -z "${CURRENT_TOC_SHA}" ]; then
    error_exit "toc.dat SHA-256 계산 실패"
fi


echo
echo "[Dump Cache Key]"
echo "  toc.dat SHA256 : ${CURRENT_TOC_SHA}"
echo "  Cache Version  : ${CACHE_VERSION}"


if [ -f "${CACHE_META}" ]; then

    CACHED_TOC_SHA=$(awk -F= '$1=="TOC_SHA256"{print $2}' "${CACHE_META}" 2>/dev/null | tail -1)
    CACHED_VERSION=$(awk -F= '$1=="CACHE_VERSION"{print $2}' "${CACHE_META}" 2>/dev/null | tail -1)
    CACHED_COPY_COUNT=$(awk -F= '$1=="COPY_COUNT"{print $2}' "${CACHE_META}" 2>/dev/null | tail -1)
    CACHED_SETVAL_COUNT=$(awk -F= '$1=="SETVAL_COUNT"{print $2}' "${CACHE_META}" 2>/dev/null | tail -1)
    CACHED_STAGE_CREATE_COUNT=$(awk -F= '$1=="STAGE_CREATE_COUNT"{print $2}' "${CACHE_META}" 2>/dev/null | tail -1)
    CACHED_MERGE_INSERT_COUNT=$(awk -F= '$1=="MERGE_INSERT_COUNT"{print $2}' "${CACHE_META}" 2>/dev/null | tail -1)

fi


if [ "${CACHED_TOC_SHA}" = "${CURRENT_TOC_SHA}" ] && \
   [ "${CACHED_VERSION}" = "${CACHE_VERSION}" ]; then

    echo
    echo "[INFO] 동일한 Dump Cache 확인"

    if [ -s "${DATA_FILE}" ]; then
        REUSE_DATA_RAW=1
        echo "[REUSE] Raw Data SQL"
        echo "        ${DATA_FILE}"
    else
        echo "[MISS] Raw Data SQL 파일 없음/비어 있음"
    fi

    if [ -s "${FILTERED_DATA_SQL}" ] &&        [[ "${CACHED_COPY_COUNT}" =~ ^[0-9]+$ ]] &&        [[ "${CACHED_SETVAL_COUNT}" =~ ^[0-9]+$ ]] &&        [[ "${CACHED_STAGE_CREATE_COUNT}" =~ ^[0-9]+$ ]] &&        [[ "${CACHED_MERGE_INSERT_COUNT}" =~ ^[0-9]+$ ]]; then

        REUSE_MERGE_DATA=1

        echo "[REUSE] Merge Data SQL"
        echo "        ${FILTERED_DATA_SQL}"
        echo "[REUSE] Data Validation Count"
        echo "        COPY_COUNT         = ${CACHED_COPY_COUNT}"
        echo "        SETVAL_COUNT       = ${CACHED_SETVAL_COUNT}"
        echo "        STAGE_CREATE_COUNT = ${CACHED_STAGE_CREATE_COUNT}"
        echo "        MERGE_INSERT_COUNT = ${CACHED_MERGE_INSERT_COUNT}"

    else

        echo "[MISS] Merge Data SQL 또는 Count Cache 없음/불완전"

    fi

else

    echo
    echo "[INFO] Dump Cache 불일치 또는 최초 실행"
    echo "       Data SQL을 새로 생성합니다."

    rm -f "${DATA_FILE}" "${FILTERED_DATA_SQL}"

fi


pg_restore -l "${FULL_DUMP}" > "${FULL_LIST}"


if [ $? -ne 0 ]; then
    error_exit "Full Dump TOC 조회 실패"
fi


if [ "${REUSE_DATA_RAW}" -eq 0 ]; then

    echo
    echo "[INFO] Full Dump -> 전체 Data Plain SQL 변환"

    pg_restore \
        --data-only \
        --no-owner \
        --no-privileges \
        -f "${DATA_FILE}" \
        "${FULL_DUMP}"


    if [ $? -ne 0 ]; then
        error_exit "Full Dump Data SQL 변환 실패"
    fi


    if [ ! -s "${DATA_FILE}" ]; then
        error_exit "변환된 Data SQL 파일이 비어 있습니다: ${DATA_FILE}"
    fi


    echo "[OK] 전체 Data SQL 변환 완료"
    ls -lh "${DATA_FILE}"

else

    echo
    echo "[SKIP] Full Dump -> 전체 Data Plain SQL 변환"
    echo "       기존 Raw Data SQL 재사용"

fi


# Raw Data SQL이 새로 생성되었으면 기존 Merge Data SQL은 재생성 필요
if [ "${REUSE_DATA_RAW}" -eq 0 ]; then
    REUSE_MERGE_DATA=0
    rm -f "${FILTERED_DATA_SQL}"
fi


echo
echo "[OK] 입력 파일 확인 완료"

# ============================================================
# 비밀번호 최초 1회
# ============================================================

echo
read -s -p "Password for user ${ADMIN_USER}: " PG_PASSWORD
echo

export PGPASSWORD="${PG_PASSWORD}"


# ============================================================
# [2/12] Target DB 접속 확인
# ============================================================

echo
echo "[2/12] Target DB 접속 확인"
echo


CONNECTED_DB=$(psql \
    -X \
    -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq \
    -c "SELECT current_database();" \
    2>/dev/null)


if [ "${CONNECTED_DB}" != "${TARGET_DB}" ]; then
    error_exit "Target DB 접속 실패: ${TARGET_DB} (Host=${PGHOST}, Port=${PGPORT})"
fi


echo "[OK] Target DB 접속 성공"
echo "     DB   : ${TARGET_DB}"
echo "     Host : ${PGHOST}"
echo "     Port : ${PGPORT}"


# ============================================================
# [3/12] Backup DB 확인 / 생성
# ============================================================

echo
echo "[3/12] Backup DB 확인"
echo


BACKUP_EXISTS=$(psql \
    -X \
    -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d postgres \
    -Atq \
    -c "
SELECT count(*)
FROM pg_database
WHERE datname='${BACKUP_DB}';
" \
    2>/dev/null)


if [ "${BACKUP_EXISTS}" = "1" ]; then

    echo "[SKIP] Backup DB가 이미 존재합니다."
    echo "       ${BACKUP_DB}"
    echo
    echo "기존 Backup DB는 삭제하거나 변경하지 않습니다."

else

    echo "[INFO] Backup DB가 없습니다."
    echo "       ${TARGET_DB} -> ${BACKUP_DB}"
    echo


    ACTIVE_COUNT=$(psql \
        -X \
        -w \
        -h "${PGHOST}" \
        -p "${PGPORT}" \
        -U "${ADMIN_USER}" \
        -d postgres \
        -Atq \
        -c "
SELECT count(*)
FROM pg_stat_activity
WHERE datname='${TARGET_DB}'
  AND pid <> pg_backend_pid();
" \
        2>/dev/null)


    if [ -z "${ACTIVE_COUNT}" ]; then
        error_exit "Target DB Session 확인 실패"
    fi


    if [ "${ACTIVE_COUNT}" != "0" ]; then

        echo
        echo "[ERROR] ${TARGET_DB}에 접속 중인 Session이 있습니다."
        echo "Active Session : ${ACTIVE_COUNT}"
        echo
        echo "Backup DB를 생성하지 않았습니다."
        echo "Restore도 수행하지 않습니다."

        error_exit "Backup DB 생성 불가"

    fi


    psql \
        -X \
        -w \
        -h "${PGHOST}" \
        -p "${PGPORT}" \
        -U "${ADMIN_USER}" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "
CREATE DATABASE \"${BACKUP_DB}\"
WITH TEMPLATE \"${TARGET_DB}\"
OWNER "${ADMIN_USER}";
"


    if [ $? -ne 0 ]; then
        error_exit "Backup DB 생성 실패: ${BACKUP_DB}"
    fi


    BACKUP_CREATED=$(psql \
        -X \
        -w \
        -h "${PGHOST}" \
        -p "${PGPORT}" \
        -U "${ADMIN_USER}" \
        -d postgres \
        -Atq \
        -c "
SELECT count(*)
FROM pg_database
WHERE datname='${BACKUP_DB}';
" \
        2>/dev/null)


    if [ "${BACKUP_CREATED}" != "1" ]; then
        error_exit "Backup DB 생성 후 존재 검증 실패"
    fi


    echo
    echo "[OK] Backup DB 생성 완료"
    echo "     ${BACKUP_DB}"

fi


# ============================================================
# [4/12] Data SQL 형식 확인
# ============================================================

echo
echo "[4/12] 전체 Data SQL 형식 확인"
echo


if [ "${REUSE_MERGE_DATA}" -eq 1 ]; then

    COPY_COUNT="${CACHED_COPY_COUNT}"

    echo "[SKIP] Raw Data SQL 전체 grep 검사"
    echo "       동일 Dump Cache의 COPY_COUNT 재사용"
    echo "       COPY Count = ${COPY_COUNT}"

else

    COPY_COUNT=$(grep -cE \
        '^[[:space:]]*COPY[[:space:]]' \
        "${DATA_FILE}" \
        || true)


    if [ "${COPY_COUNT}" -eq 0 ]; then
        error_exit "Data SQL에 COPY 문이 없습니다. -Fd 기본 COPY 형식 Dump인지 확인하세요."
    fi


    echo "[OK] COPY Data 확인"
    echo "     COPY Count = ${COPY_COUNT}"

fi

# ============================================================
# [5/12] Metadata Cache 생성
# ============================================================

echo
echo "[5/12] Target DB Metadata Cache 생성"
echo


# TABLE
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname
FROM pg_class c
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','p','f')
ORDER BY 1,2;
" > "${TABLE_MAP}" || error_exit "TABLE Metadata 생성 실패"


# PARTITION
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname
FROM pg_class c
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE c.relispartition=true
ORDER BY 1,2;
" > "${PARTITION_MAP}" || error_exit "PARTITION Metadata 생성 실패"


# SEQUENCE
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname
FROM pg_class c
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE c.relkind='S'
ORDER BY 1,2;
" > "${SEQUENCE_MAP}" || error_exit "SEQUENCE Metadata 생성 실패"


# INDEX
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname
FROM pg_class c
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE c.relkind IN ('i','I')
ORDER BY 1,2;
" > "${INDEX_MAP}" || error_exit "INDEX Metadata 생성 실패"


# CONSTRAINT
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname,
       con.conname,
       con.contype
FROM pg_constraint con
JOIN pg_class c
  ON c.oid=con.conrelid
JOIN pg_namespace n
  ON n.oid=c.relnamespace
ORDER BY 1,2,3;
" > "${CONSTRAINT_MAP}" || error_exit "CONSTRAINT Metadata 생성 실패"


# PRIMARY KEY TABLE
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname
FROM pg_constraint con
JOIN pg_class c
  ON c.oid=con.conrelid
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE con.contype='p'
ORDER BY 1,2;
" > "${PK_TABLE_MAP}" || error_exit "PK Metadata 생성 실패"


# DEFAULT
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname,
       a.attname
FROM pg_attrdef d
JOIN pg_class c
  ON c.oid=d.adrelid
JOIN pg_namespace n
  ON n.oid=c.relnamespace
JOIN pg_attribute a
  ON a.attrelid=c.oid
 AND a.attnum=d.adnum
ORDER BY 1,2,3;
" > "${DEFAULT_MAP}" || error_exit "DEFAULT Metadata 생성 실패"


# TRIGGER
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname,
       t.tgname
FROM pg_trigger t
JOIN pg_class c
  ON c.oid=t.tgrelid
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal
ORDER BY 1,2,3;
" > "${TRIGGER_MAP}" || error_exit "TRIGGER Metadata 생성 실패"


# RULE
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname,
       r.rulename
FROM pg_rewrite r
JOIN pg_class c
  ON c.oid=r.ev_class
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE r.rulename <> '_RETURN'
ORDER BY 1,2,3;
" > "${RULE_MAP}" || error_exit "RULE Metadata 생성 실패"


# VIEW
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname
FROM pg_class c
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE c.relkind='v'
ORDER BY 1,2;
" > "${VIEW_MAP}" || error_exit "VIEW Metadata 생성 실패"


# MATERIALIZED VIEW
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       c.relname
FROM pg_class c
JOIN pg_namespace n
  ON n.oid=c.relnamespace
WHERE c.relkind='m'
ORDER BY 1,2;
" > "${MATVIEW_MAP}" || error_exit "MATVIEW Metadata 생성 실패"


# DOMAIN
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       t.typname
FROM pg_type t
JOIN pg_namespace n
  ON n.oid=t.typnamespace
WHERE t.typtype='d'
ORDER BY 1,2;
" > "${DOMAIN_MAP}" || error_exit "DOMAIN Metadata 생성 실패"


# TYPE
psql -X -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -Atq -F '|' \
    -c "
SELECT n.nspname,
       t.typname
FROM pg_type t
JOIN pg_namespace n
  ON n.oid=t.typnamespace
ORDER BY 1,2;
" > "${TYPE_MAP}" || error_exit "TYPE Metadata 생성 실패"


echo "[OK] Target DB Metadata Cache 생성 완료"


# ============================================================
# [6/12] Schema Restore List 생성
# ============================================================

echo
echo "[6/12] Schema Restore List 생성"
echo


> "${RESTORE_LIST}"


INCLUDE_COUNT=0
SKIP_COUNT=0
PK_SKIP_COUNT=0
FUNCTION_SKIP_COUNT=0
PROCEDURE_SKIP_COUNT=0


while IFS= read -r LINE
do

    case "${LINE}" in
        ""|\;*)
            continue
            ;;
    esac


    INFO=$(echo "${LINE}" \
        | sed -E \
        's/^[0-9]+;[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+//')


    INCLUDE=0


    # ========================================================
    # SCHEMA
    # ========================================================

    if echo "${INFO}" | grep -q '^SCHEMA '; then

        INCLUDE=0


    # ========================================================
    # EXTENSION
    # ========================================================

    elif echo "${INFO}" | grep -q '^EXTENSION '; then

        INCLUDE=0


    # ========================================================
    # TABLE DATA
    # Schema Restore List에는 절대 포함하지 않음
    # ========================================================

    elif echo "${INFO}" | grep -q '^TABLE DATA '; then

        INCLUDE=0


    # ========================================================
    # TABLE ATTACH
    # ========================================================

    elif echo "${INFO}" | grep -q '^TABLE ATTACH '; then

        set -- ${INFO}

        SCHEMA_NAME="${3:-}"
        TABLE_NAME="${4:-}"


        if ! map_exists \
            "${PARTITION_MAP}" \
            "${SCHEMA_NAME}|${TABLE_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # TABLE
    # ========================================================

    elif echo "${INFO}" | grep -q '^TABLE '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        TABLE_NAME="${3:-}"


        if ! map_exists \
            "${TABLE_MAP}" \
            "${SCHEMA_NAME}|${TABLE_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # SEQUENCE SET
    # ========================================================

    elif echo "${INFO}" | grep -q '^SEQUENCE SET '; then

        INCLUDE=0


    # ========================================================
    # SEQUENCE OWNED BY
    # ========================================================

    elif echo "${INFO}" | grep -q '^SEQUENCE OWNED BY '; then

        set -- ${INFO}

        SCHEMA_NAME="${4:-}"
        SEQUENCE_NAME="${5:-}"


        if ! map_exists \
            "${SEQUENCE_MAP}" \
            "${SCHEMA_NAME}|${SEQUENCE_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # SEQUENCE
    # ========================================================

    elif echo "${INFO}" | grep -q '^SEQUENCE '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        SEQUENCE_NAME="${3:-}"


        if ! map_exists \
            "${SEQUENCE_MAP}" \
            "${SCHEMA_NAME}|${SEQUENCE_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # INDEX
    # ========================================================

    elif echo "${INFO}" | grep -q '^INDEX '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        INDEX_NAME="${3:-}"


        if ! map_exists \
            "${INDEX_MAP}" \
            "${SCHEMA_NAME}|${INDEX_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # CONSTRAINT
    # ========================================================

    elif echo "${INFO}" | grep -q '^CONSTRAINT '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        TABLE_NAME="${3:-}"
        CONSTRAINT_NAME="${4:-}"


        if echo "${CONSTRAINT_NAME}" | grep -q '_pkey$'; then

            if map_exists \
                "${PK_TABLE_MAP}" \
                "${SCHEMA_NAME}|${TABLE_NAME}"
            then
                INCLUDE=0
                PK_SKIP_COUNT=$((PK_SKIP_COUNT + 1))
            else
                INCLUDE=1
            fi

        else

            if ! grep -Fq \
                "${SCHEMA_NAME}|${TABLE_NAME}|${CONSTRAINT_NAME}|" \
                "${CONSTRAINT_MAP}" \
                2>/dev/null
            then
                INCLUDE=1
            fi

        fi


    # ========================================================
    # FK CONSTRAINT
    # ========================================================

    elif echo "${INFO}" | grep -q '^FK CONSTRAINT '; then

        set -- ${INFO}

        SCHEMA_NAME="${3:-}"
        TABLE_NAME="${4:-}"
        CONSTRAINT_NAME="${5:-}"


        if ! grep -Fq \
            "${SCHEMA_NAME}|${TABLE_NAME}|${CONSTRAINT_NAME}|" \
            "${CONSTRAINT_MAP}" \
            2>/dev/null
        then
            INCLUDE=1
        fi


    # ========================================================
    # DEFAULT
    # ========================================================

    elif echo "${INFO}" | grep -q '^DEFAULT '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        TABLE_NAME="${3:-}"
        COLUMN_NAME="${4:-}"


        if ! map_exists \
            "${DEFAULT_MAP}" \
            "${SCHEMA_NAME}|${TABLE_NAME}|${COLUMN_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # TRIGGER
    # ========================================================

    elif echo "${INFO}" | grep -q '^TRIGGER '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        TABLE_NAME="${3:-}"
        TRIGGER_NAME="${4:-}"


        if ! map_exists \
            "${TRIGGER_MAP}" \
            "${SCHEMA_NAME}|${TABLE_NAME}|${TRIGGER_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # RULE
    # ========================================================

    elif echo "${INFO}" | grep -q '^RULE '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        TABLE_NAME="${3:-}"
        RULE_NAME="${4:-}"


        if ! map_exists \
            "${RULE_MAP}" \
            "${SCHEMA_NAME}|${TABLE_NAME}|${RULE_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # FUNCTION
    # ========================================================

    elif echo "${INFO}" | grep -q '^FUNCTION '; then

        FUNCTION_SCHEMA=$(echo "${INFO}" | awk '{print $2}')


        FUNCTION_SIGNATURE=$(echo "${INFO}" \
            | sed -E \
            "s/^FUNCTION[[:space:]]+${FUNCTION_SCHEMA}[[:space:]]+//" \
            | sed -E \
            's/[[:space:]]+[^[:space:]]+$//')


        FULL_SIGNATURE="${FUNCTION_SCHEMA}.${FUNCTION_SIGNATURE}"

        SIGNATURE_ESC=$(sql_escape "${FULL_SIGNATURE}")


        EXISTS=$(db_query "
SELECT CASE
         WHEN to_regprocedure('${SIGNATURE_ESC}') IS NULL
         THEN 0
         ELSE
             CASE
                 WHEN EXISTS
                 (
                     SELECT 1
                     FROM pg_proc
                     WHERE oid=to_regprocedure('${SIGNATURE_ESC}')
                       AND prokind IN ('f','w')
                 )
                 THEN 1
                 ELSE 0
             END
       END;
")


        if [ "${EXISTS}" = "0" ]; then
            INCLUDE=1
        else
            INCLUDE=0
            FUNCTION_SKIP_COUNT=$((FUNCTION_SKIP_COUNT + 1))
        fi


    # ========================================================
    # PROCEDURE
    # ========================================================

    elif echo "${INFO}" | grep -q '^PROCEDURE '; then

        PROCEDURE_SCHEMA=$(echo "${INFO}" | awk '{print $2}')


        PROCEDURE_SIGNATURE=$(echo "${INFO}" \
            | sed -E \
            "s/^PROCEDURE[[:space:]]+${PROCEDURE_SCHEMA}[[:space:]]+//" \
            | sed -E \
            's/[[:space:]]+[^[:space:]]+$//')


        FULL_SIGNATURE="${PROCEDURE_SCHEMA}.${PROCEDURE_SIGNATURE}"

        SIGNATURE_ESC=$(sql_escape "${FULL_SIGNATURE}")


        EXISTS=$(db_query "
SELECT CASE
         WHEN to_regprocedure('${SIGNATURE_ESC}') IS NULL
         THEN 0
         ELSE
             CASE
                 WHEN EXISTS
                 (
                     SELECT 1
                     FROM pg_proc
                     WHERE oid=to_regprocedure('${SIGNATURE_ESC}')
                       AND prokind='p'
                 )
                 THEN 1
                 ELSE 0
             END
       END;
")


        if [ "${EXISTS}" = "0" ]; then
            INCLUDE=1
        else
            INCLUDE=0
            PROCEDURE_SKIP_COUNT=$((PROCEDURE_SKIP_COUNT + 1))
        fi


    # ========================================================
    # VIEW
    # ========================================================

    elif echo "${INFO}" | grep -q '^VIEW '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        VIEW_NAME="${3:-}"


        if ! map_exists \
            "${VIEW_MAP}" \
            "${SCHEMA_NAME}|${VIEW_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # MATERIALIZED VIEW
    # ========================================================

    elif echo "${INFO}" | grep -q '^MATERIALIZED VIEW '; then

        set -- ${INFO}

        SCHEMA_NAME="${3:-}"
        VIEW_NAME="${4:-}"


        if ! map_exists \
            "${MATVIEW_MAP}" \
            "${SCHEMA_NAME}|${VIEW_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # DOMAIN
    # ========================================================

    elif echo "${INFO}" | grep -q '^DOMAIN '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        DOMAIN_NAME="${3:-}"


        if ! map_exists \
            "${DOMAIN_MAP}" \
            "${SCHEMA_NAME}|${DOMAIN_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # TYPE
    # ========================================================

    elif echo "${INFO}" | grep -q '^TYPE '; then

        set -- ${INFO}

        SCHEMA_NAME="${2:-}"
        TYPE_NAME="${3:-}"


        if ! map_exists \
            "${TYPE_MAP}" \
            "${SCHEMA_NAME}|${TYPE_NAME}"
        then
            INCLUDE=1
        fi


    # ========================================================
    # COMMENT / ACL / SECURITY LABEL
    # ========================================================

    elif echo "${INFO}" | grep -qE \
        '^(COMMENT |ACL |DEFAULT ACL |SECURITY LABEL )'
    then

        INCLUDE=0


    # ========================================================
    # 기타
    # ========================================================

    else

        INCLUDE=0

    fi


    # ========================================================
    # Restore List 기록
    # ========================================================

    if [ "${INCLUDE}" -eq 1 ]; then

        echo "${LINE}" >> "${RESTORE_LIST}"
        INCLUDE_COUNT=$((INCLUDE_COUNT + 1))

    else

        SKIP_COUNT=$((SKIP_COUNT + 1))

    fi


done < "${FULL_LIST}"


echo
echo "[OK] Restore List 생성 완료"

echo "     Restore Object       : ${INCLUDE_COUNT}"
echo "     Skip Existing Object : ${SKIP_COUNT}"
echo "     Skip Existing PK     : ${PK_SKIP_COUNT}"
echo "     Skip Existing Func   : ${FUNCTION_SKIP_COUNT}"
echo "     Skip Existing Proc   : ${PROCEDURE_SKIP_COUNT}"


# ============================================================
# [7/12] Restore List 안전 검증
# ============================================================

echo
echo "[7/12] Restore List 안전 검증"
echo


SCHEMA_IN_LIST=$(grep -c \
    ' SCHEMA ' \
    "${RESTORE_LIST}" \
    2>/dev/null \
    || true)


if [ "${SCHEMA_IN_LIST}" -ne 0 ]; then

    echo "[ERROR] Restore List에 SCHEMA가 포함되어 있습니다."

    grep ' SCHEMA ' "${RESTORE_LIST}"

    error_exit "SCHEMA Restore 차단"

fi


EXT_IN_LIST=$(grep -c \
    ' EXTENSION ' \
    "${RESTORE_LIST}" \
    2>/dev/null \
    || true)


if [ "${EXT_IN_LIST}" -ne 0 ]; then

    echo "[ERROR] Restore List에 EXTENSION이 포함되어 있습니다."

    grep ' EXTENSION ' "${RESTORE_LIST}"

    error_exit "EXTENSION Restore 차단"

fi


echo "[OK] SCHEMA Restore 없음"
echo "[OK] EXTENSION Restore 없음"


# ============================================================
# 기존 FUNCTION 최종 재검증
# ============================================================

echo
echo "[INFO] FUNCTION 최종 재검증"
echo


FUNCTION_ERROR=0


while IFS= read -r LINE
do

    case "${LINE}" in
        ""|\;*)
            continue
            ;;
    esac


    INFO=$(echo "${LINE}" \
        | sed -E \
        's/^[0-9]+;[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+//')


    if echo "${INFO}" | grep -q '^FUNCTION '; then

        FUNCTION_SCHEMA=$(echo "${INFO}" | awk '{print $2}')


        FUNCTION_SIGNATURE=$(echo "${INFO}" \
            | sed -E \
            "s/^FUNCTION[[:space:]]+${FUNCTION_SCHEMA}[[:space:]]+//" \
            | sed -E \
            's/[[:space:]]+[^[:space:]]+$//')


        FULL_SIGNATURE="${FUNCTION_SCHEMA}.${FUNCTION_SIGNATURE}"

        SIGNATURE_ESC=$(sql_escape "${FULL_SIGNATURE}")


        EXISTS=$(db_query "
SELECT CASE
         WHEN to_regprocedure('${SIGNATURE_ESC}') IS NULL
         THEN 0
         ELSE 1
       END;
")


        if [ "${EXISTS}" = "1" ]; then

            echo "[ERROR] 기존 FUNCTION이 Restore List에 포함됨:"
            echo "        ${FULL_SIGNATURE}"

            FUNCTION_ERROR=1

        fi

    fi

done < "${RESTORE_LIST}"


if [ "${FUNCTION_ERROR}" -ne 0 ]; then
    error_exit "기존 FUNCTION Restore List 포함 오류"
fi


echo "[OK] 기존 FUNCTION Restore 대상 없음"


# ============================================================
# PROCEDURE 최종 재검증
# ============================================================

echo
echo "[INFO] PROCEDURE 최종 재검증"
echo


PROCEDURE_ERROR=0


while IFS= read -r LINE
do

    case "${LINE}" in
        ""|\;*)
            continue
            ;;
    esac


    INFO=$(echo "${LINE}" \
        | sed -E \
        's/^[0-9]+;[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+//')


    if echo "${INFO}" | grep -q '^PROCEDURE '; then

        PROCEDURE_SCHEMA=$(echo "${INFO}" | awk '{print $2}')


        PROCEDURE_SIGNATURE=$(echo "${INFO}" \
            | sed -E \
            "s/^PROCEDURE[[:space:]]+${PROCEDURE_SCHEMA}[[:space:]]+//" \
            | sed -E \
            's/[[:space:]]+[^[:space:]]+$//')


        FULL_SIGNATURE="${PROCEDURE_SCHEMA}.${PROCEDURE_SIGNATURE}"

        SIGNATURE_ESC=$(sql_escape "${FULL_SIGNATURE}")


        EXISTS=$(db_query "
SELECT CASE
         WHEN to_regprocedure('${SIGNATURE_ESC}') IS NULL
         THEN 0
         ELSE 1
       END;
")


        if [ "${EXISTS}" = "1" ]; then

            echo "[ERROR] 기존 PROCEDURE가 Restore List에 포함됨:"
            echo "        ${FULL_SIGNATURE}"

            PROCEDURE_ERROR=1

        fi

    fi

done < "${RESTORE_LIST}"


if [ "${PROCEDURE_ERROR}" -ne 0 ]; then
    error_exit "기존 PROCEDURE Restore List 포함 오류"
fi


echo "[OK] 기존 PROCEDURE Restore 대상 없음"


# ============================================================
# [8/12] Schema SQL 생성
# ============================================================

echo
echo "[8/12] 선택된 Schema SQL 생성"
echo


if [ -s "${RESTORE_LIST}" ]; then

    pg_restore \
        --schema-only \
        -L "${RESTORE_LIST}" \
        --no-owner \
        --no-privileges \
        -f "${SELECTED_SCHEMA_SQL}" \
        "${FULL_DUMP}"


    if [ $? -ne 0 ]; then
        error_exit "선택 Schema SQL 생성 실패"
    fi

else

    echo "-- 신규 Schema Object 없음" \
        > "${SELECTED_SCHEMA_SQL}"

fi


echo "[OK] Schema SQL 생성 완료"

ls -lh "${SELECTED_SCHEMA_SQL}"


# ============================================================
# Schema SQL 안전 검증
# Schema SQL에는 COPY가 단 1개도 존재하면 안 됨
# ============================================================

SCHEMA_COPY_COUNT=$(grep -cE \
    '^[[:space:]]*COPY[[:space:]]+' \
    "${SELECTED_SCHEMA_SQL}" \
    || true)


if [ "${SCHEMA_COPY_COUNT}" -ne 0 ]; then

    echo
    echo "[ERROR] Schema SQL에 TABLE DATA COPY가 포함되어 있습니다."
    echo "COPY Count : ${SCHEMA_COPY_COUNT}"
    echo
    echo "문제 COPY:"
    grep -nE \
        '^[[:space:]]*COPY[[:space:]]+' \
        "${SELECTED_SCHEMA_SQL}" \
        | head -20

    error_exit "Schema SQL에 Data COPY 포함 - Restore 차단"

fi


echo "[OK] Schema SQL Data COPY 없음"


# ============================================================
# [9/12] 전체 Data COPY -> TEMP Stage Merge SQL 변환
# ============================================================

echo
echo "[9/12] 전체 Data를 TEMP Stage Merge SQL로 변환"
echo


if [ "${REUSE_MERGE_DATA}" -eq 1 ]; then

    SETVAL_COUNT="${CACHED_SETVAL_COUNT}"
    STAGE_CREATE_COUNT="${CACHED_STAGE_CREATE_COUNT}"
    MERGE_INSERT_COUNT="${CACHED_MERGE_INSERT_COUNT}"

    echo "[REUSE] 기존 Merge Data SQL 재사용"
    echo "        ${FILTERED_DATA_SQL}"

    echo "[SKIP] Raw/Merge Data SQL 전체 grep 검사"
    echo "       동일 Dump Cache의 검증 Count 재사용"

else

    SETVAL_COUNT=$(grep -cE \
        '^[[:space:]]*SELECT[[:space:]]+pg_catalog\.setval' \
        "${DATA_FILE}" \
        || true)


    awk -v total="${COPY_COUNT}" '
    BEGIN {
        in_copy = 0
        stage_no = 0
        target_table = ""
        column_list = ""
        stage_table = ""
    }

    # Sequence setval은 기존 Target sequence 값을 변경할 수 있으므로 제외
    /^[[:space:]]*SELECT[[:space:]]+pg_catalog\.setval/ {
        next
    }

    # COPY schema.table (col1, col2, ...) FROM stdin;
    # -> TEMP Stage 생성 후 Stage로 COPY
    /^[[:space:]]*COPY[[:space:]]+/ && /[[:space:]]FROM[[:space:]]stdin;[[:space:]]*$/ {
        line = $0

        tmp = line
        sub(/^[[:space:]]*COPY[[:space:]]+/, "", tmp)

        target_table = tmp
        sub(/[[:space:]]+\(.*/, "", target_table)

        column_list = tmp
        sub(/^[^(]*\(/, "", column_list)
        sub(/\)[[:space:]]+FROM[[:space:]]+stdin;[[:space:]]*$/, "", column_list)

        stage_no++
        stage_table = "merge_stage_" stage_no

        print ""
        print "-- ========================================================"
        print "-- MERGE TARGET: " target_table
        print "-- ========================================================"
        print "\\echo [DATA " stage_no "/" total "] " target_table
        print "CREATE TEMP TABLE " stage_table " (LIKE " target_table " INCLUDING DEFAULTS);"
        print "COPY " stage_table " (" column_list ") FROM stdin;"

        in_copy = 1
        next
    }

    # COPY 데이터 종료
    in_copy == 1 && $0 == "\\." {
        print $0
        print "INSERT INTO " target_table " (" column_list ")"
        print "SELECT " column_list
        print "FROM " stage_table
        print "ON CONFLICT DO NOTHING;"
        print "DROP TABLE " stage_table ";"
        print ""

        in_copy = 0
        target_table = ""
        column_list = ""
        stage_table = ""
        next
    }

    # COPY 본문 데이터
    in_copy == 1 {
        print
        next
    }

    # pg_restore가 출력한 나머지 SET/주석 등은 유지
    {
        print
    }
    ' "${DATA_FILE}" > "${FILTERED_DATA_SQL}"


    if [ $? -ne 0 ]; then
        error_exit "Data Stage Merge SQL 변환 실패"
    fi


    if [ ! -s "${FILTERED_DATA_SQL}" ]; then
        error_exit "변환된 Data Merge SQL이 비어 있습니다."
    fi


    STAGE_CREATE_COUNT=$(grep -cE \
        '^CREATE TEMP TABLE merge_stage_[0-9]+ ' \
        "${FILTERED_DATA_SQL}" \
        || true)


    MERGE_INSERT_COUNT=$(grep -cE \
        '^INSERT INTO ' \
        "${FILTERED_DATA_SQL}" \
        || true)


    if [ "${STAGE_CREATE_COUNT}" -ne "${COPY_COUNT}" ]; then
        echo "[ERROR] COPY Count와 Stage Table Count가 다릅니다."
        echo "COPY Count       : ${COPY_COUNT}"
        echo "Stage Table Count: ${STAGE_CREATE_COUNT}"
        error_exit "Data Merge SQL 변환 검증 실패"
    fi

fi


echo "[INFO] Sequence SETVAL 제외 : ${SETVAL_COUNT}"
echo "[OK] 전체 COPY -> TEMP Stage 준비 완료"
echo "     COPY Count        : ${COPY_COUNT}"
echo "     Stage Table Count : ${STAGE_CREATE_COUNT}"
echo "     Merge INSERT Count: ${MERGE_INSERT_COUNT}"


# Dump Cache Metadata 갱신
{
    echo "CACHE_VERSION=${CACHE_VERSION}"
    echo "TOC_SHA256=${CURRENT_TOC_SHA}"
    echo "COPY_COUNT=${COPY_COUNT}"
    echo "SETVAL_COUNT=${SETVAL_COUNT}"
    echo "STAGE_CREATE_COUNT=${STAGE_CREATE_COUNT}"
    echo "MERGE_INSERT_COUNT=${MERGE_INSERT_COUNT}"
} > "${CACHE_META}"


if [ $? -ne 0 ]; then
    error_exit "Dump Cache Metadata 저장 실패"
fi


echo "[OK] Dump Cache Metadata 저장"
echo "     ${CACHE_META}"

# ============================================================
# [10/12] Data Job SQL 생성
# ============================================================

echo
echo "[10/12] Data Job SQL 생성"
echo

JOB_DIR="${WORK_DIR}/${TARGET_DB}_data_jobs"
JOB_LOG_DIR="${WORK_DIR}/${TARGET_DB}_data_job_logs"
PROGRESS_FILE="${WORK_DIR}/${TARGET_DB}_data_progress.ok"
SCHEMA_RESTORE_LOG="${WORK_DIR}/${TARGET_DB}_schema_restore.log"
DATA_SUMMARY_LOG="${WORK_DIR}/${TARGET_DB}_data_summary.log"

mkdir -p "${JOB_DIR}" "${JOB_LOG_DIR}"

if [ $? -ne 0 ]; then
    error_exit "Data Job 디렉토리 생성 실패"
fi

# 동일 Dump Cache가 아니면 기존 progress를 무효화해야 함
PROGRESS_META="${WORK_DIR}/${TARGET_DB}_data_progress.meta"
PROGRESS_TOC_SHA=""
PROGRESS_CACHE_VERSION=""

if [ -f "${PROGRESS_META}" ]; then
    PROGRESS_TOC_SHA=$(awk -F= '$1=="TOC_SHA256"{print $2}' "${PROGRESS_META}" 2>/dev/null | tail -1)
    PROGRESS_CACHE_VERSION=$(awk -F= '$1=="CACHE_VERSION"{print $2}' "${PROGRESS_META}" 2>/dev/null | tail -1)
fi

if [ "${PROGRESS_TOC_SHA}" != "${CURRENT_TOC_SHA}" ] || \
   [ "${PROGRESS_CACHE_VERSION}" != "${CACHE_VERSION}" ]; then

    echo "[INFO] Dump 변경 또는 최초 실행"
    echo "       기존 Data Progress를 초기화합니다."

    rm -f "${PROGRESS_FILE}"
fi

{
    echo "CACHE_VERSION=${CACHE_VERSION}"
    echo "TOC_SHA256=${CURRENT_TOC_SHA}"
} > "${PROGRESS_META}"

# 기존 Job SQL 재생성
rm -f "${JOB_DIR}"/job_*.sql "${JOB_DIR}"/job_*.target 2>/dev/null

# ------------------------------------------------------------
# FILTERED_DATA_SQL을 TABLE 단위 Job SQL로 분리
# 각 Job은 독립 Transaction
# ------------------------------------------------------------

awk -v outdir="${JOB_DIR}" '
BEGIN {
    file=""
    meta=""
    job=0
    target=""
}

/^-- MERGE TARGET:/ {
    job++
    target=$0
    sub(/^-- MERGE TARGET:[[:space:]]*/, "", target)

    file=sprintf("%s/job_%06d.sql", outdir, job)
    meta=sprintf("%s/job_%06d.target", outdir, job)

    print target > meta
    close(meta)

    print "\\set ON_ERROR_STOP on" > file
    print "BEGIN;" >> file
    print "" >> file
}

file != "" {
    print $0 >> file
}

/^DROP TABLE merge_stage_[0-9]+;$/ {
    print "" >> file
    print "COMMIT;" >> file
    close(file)
    file=""
    meta=""
    target=""
}

END {
    print job
}
' "${FILTERED_DATA_SQL}" > "${JOB_DIR}/job_count.txt"

if [ $? -ne 0 ]; then
    error_exit "Data Job SQL 분리 실패"
fi

DATA_JOB_COUNT=$(cat "${JOB_DIR}/job_count.txt" 2>/dev/null)

if ! [[ "${DATA_JOB_COUNT}" =~ ^[0-9]+$ ]]; then
    error_exit "Data Job Count 확인 실패"
fi

if [ "${DATA_JOB_COUNT}" -ne "${COPY_COUNT}" ]; then
    echo "[ERROR] COPY Count와 Data Job Count가 다릅니다."
    echo "COPY Count     : ${COPY_COUNT}"
    echo "Data Job Count : ${DATA_JOB_COUNT}"
    error_exit "Data Job SQL 생성 검증 실패"
fi

GENERATED_JOB_COUNT=$(find "${JOB_DIR}" -maxdepth 1 -type f -name 'job_*.sql' | wc -l)

if [ "${GENERATED_JOB_COUNT}" -ne "${DATA_JOB_COUNT}" ]; then
    echo "[ERROR] 생성된 Data Job SQL 파일 수가 다릅니다."
    echo "Expected : ${DATA_JOB_COUNT}"
    echo "Actual   : ${GENERATED_JOB_COUNT}"
    error_exit "Data Job SQL 파일 수 검증 실패"
fi

echo "[OK] Data Job SQL 생성 완료"
echo "     Data Job Count : ${DATA_JOB_COUNT}"
echo "     Job Directory  : ${JOB_DIR}"


# ============================================================
# Data Job 안전 검증
# ============================================================

echo
echo "[INFO] Data Job SQL 안전 검증"

DIRECT_TARGET_COPY_COUNT=$(awk '
/^[[:space:]]*COPY[[:space:]]+/ {
    line=$0
    sub(/^[[:space:]]*/, "", line)

    if (line !~ /^COPY[[:space:]]+merge_stage_[0-9]+[[:space:]]*\(/) {
        count++
    }
}
END {
    print count+0
}
' "${JOB_DIR}"/job_*.sql)

if [ "${DIRECT_TARGET_COPY_COUNT}" -ne 0 ]; then
    echo "[ERROR] Data Job SQL에 Target Table 직접 COPY가 존재합니다."
    echo "Direct Target COPY Count : ${DIRECT_TARGET_COPY_COUNT}"
    error_exit "Target Table 직접 COPY 발견 - Restore 차단"
fi

STAGE_COPY_COUNT=$(grep -h -cE \
    '^[[:space:]]*COPY[[:space:]]+merge_stage_[0-9]+[[:space:]]*\(' \
    "${JOB_DIR}"/job_*.sql \
    | awk '{s+=$1} END {print s+0}')

if [ "${STAGE_COPY_COUNT}" -ne "${COPY_COUNT}" ]; then
    echo "[ERROR] Stage COPY Count와 원본 COPY Count가 다릅니다."
    echo "Original COPY Count : ${COPY_COUNT}"
    echo "Stage COPY Count    : ${STAGE_COPY_COUNT}"
    error_exit "Stage COPY 변환 검증 실패"
fi

echo "[OK] Target Table 직접 COPY 없음"
echo "[OK] 모든 Data COPY가 TEMP Stage 경유"
echo "[OK] 각 TABLE 단위 독립 Transaction"
echo "     Stage COPY Count : ${STAGE_COPY_COUNT}"


# ============================================================
# [11/12] 최종 확인
# ============================================================

echo
echo "[11/12] Restore 최종 확인"
echo

print_line
echo "[WARNING] 실제 '${TARGET_DB}' DB Restore"
print_line

echo
echo "Connection:"
echo "  Host : ${PGHOST}"
echo "  Port : ${PGPORT}"

echo
echo "Backup DB:"
echo "  ${BACKUP_DB}"
echo "  존재 -> 유지 / SKIP"
echo "  없음 -> TARGET_DB TEMPLATE 복제"

echo
echo "Schema:"
echo "  기존 객체 -> 유지"
echo "  없는 객체 -> 생성"
echo "  Schema DDL -> Single Transaction"

echo
echo "Data:"
echo "  모든 TABLE DATA 대상"
echo "  COPY -> TEMP Stage"
echo "  Stage -> Target INSERT ... ON CONFLICT DO NOTHING"
echo "  PK/UNIQUE 충돌 Row -> SKIP"
echo "  충돌 없는 Row -> INSERT"
echo "  TABLE 단위 Transaction"
echo "  이전 성공 TABLE -> Progress 기준 SKIP"

echo
echo "Sequence SETVAL:"
echo "  실행 안 함"

echo
echo "DROP / TRUNCATE / DELETE:"
echo "  Target DB 대상 작업 없음"
echo "  TEMP Stage Table만 DROP"

echo
echo "재수행 정책:"
echo "  성공 TABLE은 ${PROGRESS_FILE}에 기록"
echo "  동일 Dump 재수행 시 성공 TABLE 자동 SKIP"
echo "  실패 TABLE부터 다시 진행"

echo
echo "주의:"
echo "  Data 전체가 하나의 Transaction은 아닙니다."
echo "  이미 성공한 TABLE은 COMMIT 상태로 유지됩니다."
echo "  전체 작업 전 상태로 되돌려야 할 경우 Backup DB(${BACKUP_DB})를 사용하십시오."

read -p \
    "계속하려면 Target DB 이름 '${TARGET_DB}' 을 다시 입력하세요 : " \
    CONFIRM_DB

if [ "${CONFIRM_DB}" != "${TARGET_DB}" ]; then
    error_exit "입력값 불일치. Restore 취소"
fi


# ============================================================
# [12/12] 실제 Restore
# ============================================================

echo
echo "[12/12] Schema Restore + Resumable Data Merge"
echo

rm -f "${SCHEMA_RESTORE_LOG}" "${DATA_SUMMARY_LOG}"


# ------------------------------------------------------------
# 12-1. Schema Restore
# ------------------------------------------------------------

echo
print_line
echo "[SCHEMA] 신규 Schema Object Restore 시작"
print_line
echo

psql \
    -X \
    -w \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${ADMIN_USER}" \
    -d "${TARGET_DB}" \
    -v ON_ERROR_STOP=1 \
    -1 \
    -f "${SELECTED_SCHEMA_SQL}" \
    2>&1 | tee "${SCHEMA_RESTORE_LOG}"

SCHEMA_RC=${PIPESTATUS[0]}

if [ "${SCHEMA_RC}" -ne 0 ]; then
    echo
    print_line
    echo "[ERROR] Schema Restore 실패"
    print_line
    echo
    echo "Schema 변경은 Single Transaction이므로 ROLLBACK되었습니다."
    echo "Data Merge는 시작하지 않습니다."
    echo
    echo "Schema Log:"
    echo "  ${SCHEMA_RESTORE_LOG}"
    echo
    tail -100 "${SCHEMA_RESTORE_LOG}"
    unset PGPASSWORD
    exit 1
fi

echo
echo "[OK] Schema Restore COMMIT"


# ------------------------------------------------------------
# 12-2. Data 순차 Merge / 성공 Job 재수행 SKIP
# ------------------------------------------------------------

echo
print_line
echo "[DATA] TABLE 단위 Resumable Merge 시작"
print_line
echo

touch "${PROGRESS_FILE}"

SUCCESS_JOB_COUNT=0
SKIP_JOB_COUNT=0
FAILED_JOB_COUNT=0
CURRENT_JOB_NO=0

for JOB_FILE in "${JOB_DIR}"/job_*.sql
do
    [ -f "${JOB_FILE}" ] || continue

    CURRENT_JOB_NO=$((CURRENT_JOB_NO + 1))

    JOB_BASE=$(basename "${JOB_FILE}" .sql)
    TARGET_FILE="${JOB_DIR}/${JOB_BASE}.target"
    JOB_LOG="${JOB_LOG_DIR}/${JOB_BASE}.log"

    if [ ! -f "${TARGET_FILE}" ]; then
        echo "[ERROR] Job Target Metadata 없음: ${TARGET_FILE}"
        FAILED_JOB_COUNT=$((FAILED_JOB_COUNT + 1))
        break
    fi

    TARGET_TABLE=$(cat "${TARGET_FILE}")

    if grep -Fxq "${JOB_BASE}|${TARGET_TABLE}" "${PROGRESS_FILE}" 2>/dev/null; then

        echo "[DATA ${CURRENT_JOB_NO}/${DATA_JOB_COUNT}] ${TARGET_TABLE}"
        echo "[SKIP] 이전 실행 SUCCESS"

        SKIP_JOB_COUNT=$((SKIP_JOB_COUNT + 1))
        continue
    fi

    echo
    echo "[DATA ${CURRENT_JOB_NO}/${DATA_JOB_COUNT}] ${TARGET_TABLE}"
    echo "[START] ${JOB_BASE}"

    rm -f "${JOB_LOG}"

    psql \
        -X \
        -w \
        -h "${PGHOST}" \
        -p "${PGPORT}" \
        -U "${ADMIN_USER}" \
        -d "${TARGET_DB}" \
        -v ON_ERROR_STOP=1 \
        -f "${JOB_FILE}" \
        > "${JOB_LOG}" 2>&1

    JOB_RC=$?

    if [ "${JOB_RC}" -ne 0 ]; then

        echo "[ERROR] ${JOB_BASE} 실패"
        echo "        Target : ${TARGET_TABLE}"
        echo "        Log    : ${JOB_LOG}"
        echo
        echo "최근 오류:"
        tail -50 "${JOB_LOG}"

        FAILED_JOB_COUNT=$((FAILED_JOB_COUNT + 1))

        {
            echo "[FAILED] ${JOB_BASE}|${TARGET_TABLE}|RC=${JOB_RC}"
        } >> "${DATA_SUMMARY_LOG}"

        break
    fi

    if ! grep -qE '^COMMIT$' "${JOB_LOG}"; then

        echo "[ERROR] ${JOB_BASE} COMMIT 확인 실패"
        echo "        Target : ${TARGET_TABLE}"
        echo "        Log    : ${JOB_LOG}"

        FAILED_JOB_COUNT=$((FAILED_JOB_COUNT + 1))

        {
            echo "[FAILED] ${JOB_BASE}|${TARGET_TABLE}|COMMIT_NOT_FOUND"
        } >> "${DATA_SUMMARY_LOG}"

        break
    fi

    echo "${JOB_BASE}|${TARGET_TABLE}" >> "${PROGRESS_FILE}"

    SUCCESS_JOB_COUNT=$((SUCCESS_JOB_COUNT + 1))

    echo "[OK] ${TARGET_TABLE} COMMIT"

    {
        echo "[SUCCESS] ${JOB_BASE}|${TARGET_TABLE}"
    } >> "${DATA_SUMMARY_LOG}"

done


# ============================================================
# Data 결과
# ============================================================

echo
print_line
echo "Data Restore Summary"
print_line

echo "Total Jobs        : ${DATA_JOB_COUNT}"
echo "This Run Success  : ${SUCCESS_JOB_COUNT}"
echo "Previous SKIP     : ${SKIP_JOB_COUNT}"
echo "Failed            : ${FAILED_JOB_COUNT}"
echo "Progress File     : ${PROGRESS_FILE}"
echo "Job Log Directory : ${JOB_LOG_DIR}"

COMPLETED_TOTAL=$(wc -l < "${PROGRESS_FILE}" 2>/dev/null || echo 0)

echo "Completed Total   : ${COMPLETED_TOTAL}"

if [ "${FAILED_JOB_COUNT}" -ne 0 ]; then

    echo
    print_line
    echo "[ERROR] Data Merge 중단"
    print_line
    echo
    echo "이미 성공한 TABLE은 COMMIT되어 유지됩니다."
    echo
    echo "원인을 수정한 후 동일 스크립트를 다시 실행하면:"
    echo "  - 동일 Dump 확인"
    echo "  - 이전 SUCCESS TABLE 자동 SKIP"
    echo "  - 실패한 TABLE부터 재수행"
    echo
    echo "전체 작업을 취소하고 Restore 전 상태가 필요하면:"
    echo "  Backup DB : ${BACKUP_DB}"
    echo
    echo "실패 Job Log:"
    tail -20 "${DATA_SUMMARY_LOG}" 2>/dev/null || true

    unset PGPASSWORD
    exit 1
fi

if [ "${COMPLETED_TOTAL}" -ne "${DATA_JOB_COUNT}" ]; then
    echo "[ERROR] Progress 완료 건수와 전체 Job 수가 다릅니다."
    echo "Completed : ${COMPLETED_TOTAL}"
    echo "Total     : ${DATA_JOB_COUNT}"
    unset PGPASSWORD
    exit 1
fi

echo
print_line
echo "[OK] 전체 Data Merge 완료"
print_line


# ============================================================
# 완료
# ============================================================

echo
print_line
print_line
echo "[SUCCESS] 전체 Restore 완료"
print_line

echo
echo "Target DB:"
echo "  ${TARGET_DB}"

echo
echo "Backup DB:"
echo "  ${BACKUP_DB}"

echo
echo "PostgreSQL Host:"
echo "  ${PGHOST}"

echo
echo "PostgreSQL Port:"
echo "  ${PGPORT}"

echo
echo "Full Dump Directory:"
echo "  ${FULL_DUMP}"

echo
echo "Schema:"
echo "  Single Transaction"

echo
echo "Data Merge:"
echo "  TABLE 단위 Transaction"
echo "  재수행 시 이전 SUCCESS TABLE 자동 SKIP"

echo
echo "Data Job:"
echo "  Total            : ${DATA_JOB_COUNT}"
echo "  This Run Success : ${SUCCESS_JOB_COUNT}"
echo "  Previous SKIP    : ${SKIP_JOB_COUNT}"
echo "  Failed           : ${FAILED_JOB_COUNT}"

echo
echo "Restore Object:"
echo "  ${INCLUDE_COUNT}"

echo
echo "Skip Existing Object:"
echo "  ${SKIP_COUNT}"

echo
echo "Skip Existing PK:"
echo "  ${PK_SKIP_COUNT}"

echo
echo "Skip Existing Function:"
echo "  ${FUNCTION_SKIP_COUNT}"

echo
echo "Skip Existing Procedure:"
echo "  ${PROCEDURE_SKIP_COUNT}"

echo
echo "Sequence SETVAL Skip:"
echo "  ${SETVAL_COUNT}"

echo
echo "Schema Restore Log:"
echo "  ${SCHEMA_RESTORE_LOG}"

echo
echo "Data Progress:"
echo "  ${PROGRESS_FILE}"

echo
echo "Data Summary:"
echo "  ${DATA_SUMMARY_LOG}"

echo
echo "Data Job Logs:"
echo "  ${JOB_LOG_DIR}"

echo

unset PGPASSWORD

exit 0
