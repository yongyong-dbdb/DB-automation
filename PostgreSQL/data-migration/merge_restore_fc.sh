#!/bin/bash

set -u

# ============================================================
# PostgreSQL Merge Restore
#
# Schema:
#   source_db_schema.dump
#
# Data:
#   source_db_data.sql
#
# Timetable Data:
#   timetable_data.dump
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
#     INSERT ... ON CONFLICT DO NOTHING
#
# - Transaction 1:
#     Schema + 일반 Data 전체 Single Transaction
#
# - Transaction 2:
#     merge_table_01 / merge_table_02
#     Stage COPY + Merge 전체 Single Transaction
#
# - ERROR:
#     각 Transaction 단위 전체 ROLLBACK
#     Transaction 1 실패 시 Transaction 2 미수행
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


read -p "Schema Dump file [./source_db_schema.dump] : " SCHEMA_DUMP
SCHEMA_DUMP=${SCHEMA_DUMP:-./source_db_schema.dump}


read -p "Data SQL file [./source_db_data.sql] : " DATA_FILE
DATA_FILE=${DATA_FILE:-./source_db_data.sql}


read -p "Timetable Data Dump file [./timetable_data.dump] : " TIMETABLE_DUMP
TIMETABLE_DUMP=${TIMETABLE_DUMP:-./timetable_data.dump}


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

WORK_DIR=$(dirname "${SCHEMA_DUMP}")


FULL_LIST="${WORK_DIR}/${TARGET_DB}_schema_full.list"

RESTORE_LIST="${WORK_DIR}/${TARGET_DB}_schema_restore.list"

SELECTED_SCHEMA_SQL="${WORK_DIR}/${TARGET_DB}_selected_schema.sql"

FILTERED_DATA_SQL="${WORK_DIR}/${TARGET_DB}_filtered_data.sql"

MERGE_SQL="${WORK_DIR}/${TARGET_DB}_merge_restore.sql"

TIMETABLE_RAW_SQL="${WORK_DIR}/${TARGET_DB}_timetable_raw.sql"

TIMETABLE_COPY_SQL="${WORK_DIR}/${TARGET_DB}_timetable_copy.sql"

TIMETABLE_MERGE_SQL="${WORK_DIR}/${TARGET_DB}_timetable_merge.sql"

RESTORE_LOG="${WORK_DIR}/${TARGET_DB}_restore.log"

TIMETABLE_RESTORE_LOG="${WORK_DIR}/${TARGET_DB}_timetable_restore.log"


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
    "${FILTERED_DATA_SQL}" \
    "${MERGE_SQL}" \
    "${TIMETABLE_RAW_SQL}" \
    "${TIMETABLE_COPY_SQL}" \
    "${TIMETABLE_MERGE_SQL}" \
    "${RESTORE_LOG}" \
    "${TIMETABLE_RESTORE_LOG}" \
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
echo "Schema Dump     : ${SCHEMA_DUMP}"
echo "Data SQL        : ${DATA_FILE}"
echo "Timetable Dump  : ${TIMETABLE_DUMP}"
echo "Host            : ${PGHOST}"
echo "Port            : ${PGPORT}"
echo "Admin User      : ${ADMIN_USER}"
echo "Restore Log     : ${RESTORE_LOG}"
echo


# ============================================================
# [1/12] 입력 파일 확인
# ============================================================

echo "[1/12] 입력 파일 확인"
echo


if [ ! -f "${SCHEMA_DUMP}" ]; then
    error_exit "Schema Dump 파일이 존재하지 않습니다: ${SCHEMA_DUMP}"
fi


if [ ! -s "${SCHEMA_DUMP}" ]; then
    error_exit "Schema Dump 파일 크기가 0입니다: ${SCHEMA_DUMP}"
fi


if [ ! -f "${DATA_FILE}" ]; then
    error_exit "Data SQL 파일이 존재하지 않습니다: ${DATA_FILE}"
fi


if [ ! -s "${DATA_FILE}" ]; then
    error_exit "Data SQL 파일 크기가 0입니다: ${DATA_FILE}"
fi


if [ ! -f "${TIMETABLE_DUMP}" ]; then
    error_exit "Timetable Data Dump 파일이 존재하지 않습니다: ${TIMETABLE_DUMP}"
fi


if [ ! -s "${TIMETABLE_DUMP}" ]; then
    error_exit "Timetable Data Dump 파일 크기가 0입니다: ${TIMETABLE_DUMP}"
fi


echo "[Schema Dump]"
ls -lh "${SCHEMA_DUMP}"

echo
echo "[Data SQL]"
ls -lh "${DATA_FILE}"

echo
echo "[Timetable Data Dump]"
ls -lh "${TIMETABLE_DUMP}"


pg_restore -l "${SCHEMA_DUMP}" > "${FULL_LIST}"


if [ $? -ne 0 ]; then
    error_exit "Schema Dump TOC 조회 실패"
fi


pg_restore -l "${TIMETABLE_DUMP}" >/dev/null

if [ $? -ne 0 ]; then
    error_exit "Timetable Data Dump TOC 조회 실패"
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
# [4/12] Data SQL 형식 검증
# ============================================================

echo
echo "[4/12] Data SQL 형식 검증"
echo


COPY_COUNT=$(grep -cE \
    '^[[:space:]]*COPY[[:space:]]' \
    "${DATA_FILE}" \
    || true)


if [ "${COPY_COUNT}" -gt 0 ]; then

    echo
    echo "[ERROR] Data SQL에 COPY 문이 존재합니다."
    echo "COPY Count : ${COPY_COUNT}"

    error_exit "COPY 기반 Data SQL 사용 불가"

fi


CONFLICT_COUNT=$(grep -c \
    "ON CONFLICT DO NOTHING" \
    "${DATA_FILE}" \
    || true)


if [ "${CONFLICT_COUNT}" -eq 0 ]; then

    echo
    echo "[ERROR] ON CONFLICT DO NOTHING이 없습니다."
    echo "중복 데이터 SKIP이 보장되지 않습니다."

    error_exit "Data SQL 형식 검증 실패"

fi


echo "[OK] COPY 없음"
echo "[OK] ON CONFLICT DO NOTHING 확인"
echo "     Count = ${CONFLICT_COUNT}"


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
        -L "${RESTORE_LIST}" \
        --no-owner \
        --no-privileges \
        -f "${SELECTED_SCHEMA_SQL}" \
        "${SCHEMA_DUMP}"


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
# [9/12] Data SQL 안전 필터링
# ============================================================

echo
echo "[9/12] Data SQL 안전 필터링"
echo


SETVAL_COUNT=$(grep -cE \
    '^[[:space:]]*SELECT[[:space:]]+pg_catalog\.setval' \
    "${DATA_FILE}" \
    || true)


sed \
    '/^[[:space:]]*SELECT[[:space:]]\+pg_catalog\.setval/d' \
    "${DATA_FILE}" \
    > "${FILTERED_DATA_SQL}"


if [ $? -ne 0 ]; then
    error_exit "Data SQL 필터링 실패"
fi


echo "[INFO] Sequence SETVAL 제외 : ${SETVAL_COUNT}"
echo "[OK] Data SQL 필터링 완료"


# ============================================================
# [10/12] Merge SQL / Timetable SQL 생성
# ============================================================

echo
echo "[10/12] 최종 Merge SQL / Timetable SQL 생성"
echo


# ------------------------------------------------------------
# Transaction 1 SQL
# Schema DDL + 일반 Data INSERT
# ------------------------------------------------------------

{
    echo '\set ON_ERROR_STOP on'

    echo

    echo '-- ========================================================'
    echo '-- SELECTED SCHEMA DDL'
    echo '-- ========================================================'

    echo

    cat "${SELECTED_SCHEMA_SQL}"

    echo

    echo '-- ========================================================'
    echo '-- GENERAL DATA INSERT'
    echo '-- merge_table_01 / merge_table_02 제외'
    echo '-- ON CONFLICT DO NOTHING'
    echo '-- ========================================================'

    echo

    cat "${FILTERED_DATA_SQL}"

} > "${MERGE_SQL}"


if [ $? -ne 0 ]; then
    error_exit "Merge SQL 생성 실패"
fi


echo "[OK] Transaction 1 Merge SQL 생성 완료"
ls -lh "${MERGE_SQL}"


# ------------------------------------------------------------
# Timetable Custom Dump -> Plain COPY SQL 변환
# ------------------------------------------------------------

pg_restore \
    --data-only \
    --no-owner \
    --no-privileges \
    -f "${TIMETABLE_RAW_SQL}" \
    "${TIMETABLE_DUMP}"


if [ $? -ne 0 ]; then
    error_exit "Timetable Data SQL 생성 실패"
fi


TIMETABLE_COPY_COUNT=$(grep -cE \
    '^COPY[[:space:]]+app_schema\.merge_table_01[[:space:]]*\(' \
    "${TIMETABLE_RAW_SQL}" \
    || true)

TIMETABLE_M_COPY_COUNT=$(grep -cE \
    '^COPY[[:space:]]+app_schema\.merge_table_02[[:space:]]*\(' \
    "${TIMETABLE_RAW_SQL}" \
    || true)


if [ "${TIMETABLE_COPY_COUNT}" -eq 0 ]; then
    error_exit "Timetable Dump에 app_schema.merge_table_01 COPY 데이터가 없습니다."
fi


if [ "${TIMETABLE_M_COPY_COUNT}" -eq 0 ]; then
    error_exit "Timetable Dump에 app_schema.merge_table_02 COPY 데이터가 없습니다."
fi


sed \
    -e '/^[[:space:]]*SELECT[[:space:]]\+pg_catalog\.setval/d' \
    -e 's/^COPY app_schema\.merge_table_01 (/COPY merge_table_01_stage (/' \
    -e 's/^COPY app_schema\.merge_table_02 (/COPY merge_table_02_stage (/' \
    "${TIMETABLE_RAW_SQL}" \
    > "${TIMETABLE_COPY_SQL}"


if [ $? -ne 0 ]; then
    error_exit "Timetable COPY SQL 변환 실패"
fi


DIRECT_TIMETABLE_COPY=$(grep -cE \
    '^COPY[[:space:]]+app_schema\.merge_table_01(_m)?[[:space:]]*\(' \
    "${TIMETABLE_COPY_SQL}" \
    || true)


if [ "${DIRECT_TIMETABLE_COPY}" -ne 0 ]; then
    error_exit "Timetable COPY SQL에 Target Table 직접 COPY 문장이 남아 있습니다."
fi


# ------------------------------------------------------------
# Transaction 2 SQL
# TEMP Stage COPY + Target Merge
# ------------------------------------------------------------

{
    echo '\set ON_ERROR_STOP on'

    echo

    echo '-- ========================================================'
    echo '-- TEMP STAGE TABLE'
    echo '-- Target 컬럼 구조만 복제, Constraint/Index 없음'
    echo '-- ========================================================'

    echo

    echo 'CREATE TEMP TABLE merge_table_01_stage AS'
    echo 'SELECT * FROM app_schema.merge_table_01 WITH NO DATA;'

    echo

    echo 'CREATE TEMP TABLE merge_table_02_stage AS'
    echo 'SELECT * FROM app_schema.merge_table_02 WITH NO DATA;'

    echo

    echo '-- ========================================================'
    echo '-- COPY -> TEMP STAGE'
    echo '-- ========================================================'

    echo

    cat "${TIMETABLE_COPY_SQL}"

    echo

    echo '-- ========================================================'
    echo '-- STAGE -> TARGET MERGE'
    echo '-- 기존 PK/UNIQUE ROW SKIP'
    echo '-- ========================================================'

    echo

    echo 'INSERT INTO app_schema.merge_table_01'
    echo 'SELECT * FROM merge_table_01_stage'
    echo 'ON CONFLICT DO NOTHING;'

    echo

    echo 'INSERT INTO app_schema.merge_table_02'
    echo 'SELECT * FROM merge_table_02_stage'
    echo 'ON CONFLICT DO NOTHING;'

} > "${TIMETABLE_MERGE_SQL}"


if [ $? -ne 0 ]; then
    error_exit "Timetable Merge SQL 생성 실패"
fi


echo
echo "[OK] Transaction 2 Timetable Merge SQL 생성 완료"
ls -lh "${TIMETABLE_MERGE_SQL}"


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
echo
echo "  존재 -> 유지 / SKIP"
echo "  없음 -> Restore 전에 TARGET_DB TEMPLATE 복제"
echo
echo "  Backup DB 생성/확인이 모든 실제 Restore보다 먼저 수행됨"
echo
echo "Schema:"
echo "  기존 SCHEMA       -> 유지"
echo "  기존 EXTENSION    -> 유지"
echo "  기존 TABLE        -> 유지"
echo "  기존 INDEX        -> 유지"
echo "  기존 PRIMARY KEY  -> 이름 달라도 유지"
echo "  기존 CONSTRAINT   -> 유지"
echo "  기존 FUNCTION     -> Signature 기준 유지"
echo "  기존 PROCEDURE    -> Signature 기준 유지"
echo "  기존 SEQUENCE     -> 유지"
echo "  없는 객체         -> 생성"
echo
echo "General Data:"
echo "  merge_table_01 / merge_table_02 제외"
echo "  기존 PK/UNIQUE ROW -> SKIP"
echo "  없는 ROW           -> INSERT"
echo
echo "Timetable Data:"
echo "  timetable_data.dump"
echo "  COPY -> TEMP Stage"
echo "  Stage -> Target INSERT ... ON CONFLICT DO NOTHING"
echo
echo "Sequence SETVAL:"
echo "  실행 안 함"
echo
echo "DROP / TRUNCATE / DELETE:"
echo "  없음"
echo
echo "Transaction 1:"
echo "  Schema DDL + 일반 Data INSERT"
echo "  하나의 Single Transaction"
echo "  오류 -> Transaction 1 전체 ROLLBACK"
echo "  실패 시 Transaction 2 시작하지 않음"
echo
echo "Transaction 2:"
echo "  Timetable Stage COPY + Merge"
echo "  하나의 Single Transaction"
echo "  오류 -> Transaction 2 전체 ROLLBACK"
echo
echo "Backup DB:"
echo "  ${BACKUP_DB}에는 Transaction 1/2 모두 영향 없음"
echo


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
echo "[12/12] Transaction 단위 Restore"
echo


rm -f "${RESTORE_LOG}" "${TIMETABLE_RESTORE_LOG}"


# ------------------------------------------------------------
# Transaction 1
# Schema + 일반 Data
# ------------------------------------------------------------

echo "[Transaction 1] Schema + 일반 Data Restore 시작"
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
    -f "${MERGE_SQL}" \
    >"${RESTORE_LOG}" 2>&1


RESTORE_RC=$?


if [ "${RESTORE_RC}" -ne 0 ]; then

    echo

    print_line
    echo "[ERROR] Transaction 1 실패"
    print_line

    echo
    echo "Return Code:"
    echo "  ${RESTORE_RC}"

    echo
    echo "Schema DDL + 일반 Data INSERT 전체가"
    echo "하나의 Transaction으로 수행되었습니다."

    echo
    echo "따라서 Transaction 1 변경은 전체 ROLLBACK됩니다."

    echo
    echo "Transaction 2 Timetable Restore는 수행하지 않습니다."

    echo
    echo "Backup DB:"
    echo "  ${BACKUP_DB}"
    echo "Backup DB에는 영향이 없습니다."

    echo
    echo "Restore Log:"
    echo "  ${RESTORE_LOG}"

    echo
    echo "최근 오류:"
    echo

    tail -100 "${RESTORE_LOG}"

    echo

    print_line
    echo "[OK] Transaction 1 ROLLBACK"
    print_line

    echo

    unset PGPASSWORD
    exit 1

fi


echo
print_line
echo "[OK] Transaction 1 COMMIT"
print_line


# ------------------------------------------------------------
# Transaction 2
# Timetable Stage COPY + Merge
# ------------------------------------------------------------

echo
echo "[Transaction 2] Timetable Stage COPY + Merge 시작"
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
    -f "${TIMETABLE_MERGE_SQL}" \
    >"${TIMETABLE_RESTORE_LOG}" 2>&1


TIMETABLE_RESTORE_RC=$?


if [ "${TIMETABLE_RESTORE_RC}" -ne 0 ]; then

    echo

    print_line
    echo "[ERROR] Transaction 2 Timetable Restore 실패"
    print_line

    echo
    echo "Return Code:"
    echo "  ${TIMETABLE_RESTORE_RC}"

    echo
    echo "Timetable Stage COPY + Merge 전체가"
    echo "하나의 Transaction으로 수행되었습니다."

    echo
    echo "따라서 Transaction 2 변경은 전체 ROLLBACK됩니다."

    echo
    echo "주의:"
    echo "  Transaction 1은 이미 COMMIT된 상태입니다."

    echo
    echo "Backup DB:"
    echo "  ${BACKUP_DB}"
    echo "Backup DB에는 영향이 없습니다."

    echo
    echo "Timetable Restore Log:"
    echo "  ${TIMETABLE_RESTORE_LOG}"

    echo
    echo "최근 오류:"
    echo

    tail -100 "${TIMETABLE_RESTORE_LOG}"

    echo

    print_line
    echo "[OK] Transaction 2 ROLLBACK"
    print_line

    echo

    unset PGPASSWORD
    exit 1

fi


# ============================================================
# 완료
# ============================================================

echo

print_line
echo "[OK] Transaction 2 COMMIT"
print_line


echo
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
echo "Schema Dump:"
echo "  ${SCHEMA_DUMP}"

echo
echo "General Data SQL:"
echo "  ${DATA_FILE}"

echo
echo "Timetable Data Dump:"
echo "  ${TIMETABLE_DUMP}"

echo
echo "Transaction 1:"
echo "  COMMIT - Schema + 일반 Data"

echo
echo "Transaction 2:"
echo "  COMMIT - Timetable Stage COPY + Merge"

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
echo "General Data Sequence SETVAL Skip:"
echo "  ${SETVAL_COUNT}"

echo
echo "Restore Log:"
echo "  ${RESTORE_LOG}"

echo
echo "Timetable Restore Log:"
echo "  ${TIMETABLE_RESTORE_LOG}"

echo


unset PGPASSWORD

exit 0
