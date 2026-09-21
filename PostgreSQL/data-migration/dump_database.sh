#!/bin/bash

set -u

read -r -p "Source Database 이름 입력 : " DB_NAME
read -r -p "PostgreSQL User 입력 [기본값: postgres] : " DB_USER
DB_USER="${DB_USER:-postgres}"
read -r -p "PostgreSQL Host 입력 [기본값: localhost] : " DB_HOST
DB_HOST="${DB_HOST:-localhost}"
read -r -p "PostgreSQL Port 입력 [기본값: 5432] : " DB_PORT
DB_PORT="${DB_PORT:-5432}"
read -r -p "작업 Schema 이름 입력 : " SCHEMA_NAME
read -r -p "Dump 파일 Prefix 입력 [기본값: migration] : " DUMP_PREFIX
DUMP_PREFIX="${DUMP_PREFIX:-migration}"

if ! [[ "${DB_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
    echo "[ERROR] Database 이름 형식이 올바르지 않습니다."
    exit 1
fi

if ! [[ "${SCHEMA_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "[ERROR] Schema 이름 형식이 올바르지 않습니다."
    exit 1
fi

if ! [[ "${DB_PORT}" =~ ^[0-9]+$ ]] || [ "${DB_PORT}" -lt 1 ] || [ "${DB_PORT}" -gt 65535 ]; then
    echo "[ERROR] PostgreSQL Port는 1~65535 사이의 숫자여야 합니다."
    exit 1
fi

SCHEMA_DUMP="./${DUMP_PREFIX}_schema.dump"
DATA_DUMP="./${DUMP_PREFIX}_data.sql"
TIMETABLE_DUMP="./${DUMP_PREFIX}_merge_tables.dump"

echo "============================================================"
echo " Application Migration Dump"
echo "============================================================"
echo
echo "Database       : ${DB_NAME}"
echo "User           : ${DB_USER}"
echo "Host           : ${DB_HOST}"
echo "Port           : ${DB_PORT}"
echo "Schema Dump    : ${SCHEMA_DUMP}"
echo "Data Dump      : ${DATA_DUMP}"
echo "Timetable Dump : ${TIMETABLE_DUMP}"
echo

# ============================================================
# PostgreSQL 비밀번호 최초 1회 입력
# ============================================================

read -s -p "PostgreSQL Password for ${DB_USER}: " PGPASSWORD
echo

export PGPASSWORD

cleanup()
{
    unset PGPASSWORD
}

trap cleanup EXIT

# ============================================================
# [1/5] DB 접속 확인
# ============================================================

echo
echo "[1/5] PostgreSQL 접속 확인"
echo

psql \
    -X \
    -w \
    -U "${DB_USER}" \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -c "SELECT current_database(), current_user;" \
    >/dev/null

if [ $? -ne 0 ]; then
    echo
    echo "============================================================"
    echo "[ERROR] PostgreSQL 접속 실패"
    echo "============================================================"
    exit 1
fi

echo "[OK] PostgreSQL 접속 성공"

# ============================================================
# [2/5] 기존 Dump 파일 확인
#
# 기존 파일이 있어도 삭제/중단하지 않음.
# pg_dump -f가 동일 파일명으로 새로 작성함.
# ============================================================

echo
echo "[2/5] 기존 Dump 파일 확인"
echo

if [ -f "${SCHEMA_DUMP}" ]; then
    echo "[INFO] 기존 Schema Dump 존재"
    echo "       ${SCHEMA_DUMP}"
    echo "       -> 동일 파일명으로 덮어씁니다."
else
    echo "[INFO] 기존 Schema Dump 없음"
fi

echo

if [ -f "${DATA_DUMP}" ]; then
    echo "[INFO] 기존 Data Dump 존재"
    echo "       ${DATA_DUMP}"
    echo "       -> 동일 파일명으로 덮어씁니다."
else
    echo "[INFO] 기존 Data Dump 없음"
fi

echo

if [ -f "${TIMETABLE_DUMP}" ]; then
    echo "[INFO] 기존 Timetable Dump 존재"
    echo "       ${TIMETABLE_DUMP}"
    echo "       -> 동일 파일명으로 덮어씁니다."
else
    echo "[INFO] 기존 Timetable Dump 없음"
fi

# ============================================================
# [3/5] Schema Dump
#
# 제외 대상
#
# excluded_table_01
# excluded_table_02
# excluded_prefix*
# excluded_table_03
# excluded_table_04
# excluded_table_05
# excluded_table_06
# merge_table_01
# merge_table_02
# excluded_event*
#
# merge_table_01 / merge_table_02
#   -> Schema는 신규서버 기존 객체 사용
#   -> Data만 별도 timetable_data.dump로 생성
# ============================================================

echo
echo "[3/5] Schema Dump 시작"
echo

pg_dump \
    -U "${DB_USER}" \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    -Fc \
    -v \
    --schema-only \
    -T "${SCHEMA_NAME}.excluded_table_01" \
    -T "${SCHEMA_NAME}.excluded_table_02" \
    -T "${SCHEMA_NAME}.excluded_prefix*" \
    -T "${SCHEMA_NAME}.excluded_table_03" \
    -T "${SCHEMA_NAME}.excluded_table_04" \
    -T "${SCHEMA_NAME}.excluded_table_05" \
    -T "${SCHEMA_NAME}.excluded_table_06" \
    -T "${SCHEMA_NAME}.merge_table_01" \
    -T "${SCHEMA_NAME}.merge_table_02" \
    -T "${SCHEMA_NAME}.excluded_event*" \
    -f "${SCHEMA_DUMP}"

if [ $? -ne 0 ]; then
    echo
    echo "============================================================"
    echo "[ERROR] Schema Dump 실패"
    echo "============================================================"
    exit 1
fi

echo
echo "[OK] Schema Dump 완료"
echo

ls -lh "${SCHEMA_DUMP}"

# ============================================================
# [4/5] 일반 Data Dump
#
# INSERT 방식
# 1000 rows / INSERT
# PK/UNIQUE 충돌 발생 시 해당 INSERT SKIP
#
# merge_table_01 / merge_table_02 제외
# -> 별도 Timetable Dump에서 처리
# ============================================================

echo
echo "[4/5] 일반 Data Dump 시작"
echo

pg_dump \
    -U "${DB_USER}" \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    --data-only \
    --rows-per-insert=1000 \
    --on-conflict-do-nothing \
    -T "${SCHEMA_NAME}.excluded_table_01" \
    -T "${SCHEMA_NAME}.excluded_table_02" \
    -T "${SCHEMA_NAME}.excluded_prefix*" \
    -T "${SCHEMA_NAME}.excluded_table_03" \
    -T "${SCHEMA_NAME}.excluded_table_04" \
    -T "${SCHEMA_NAME}.excluded_table_05" \
    -T "${SCHEMA_NAME}.excluded_table_06" \
    -T "${SCHEMA_NAME}.merge_table_01" \
    -T "${SCHEMA_NAME}.merge_table_02" \
    -T "${SCHEMA_NAME}.excluded_event*" \
    -f "${DATA_DUMP}"

if [ $? -ne 0 ]; then
    echo
    echo "============================================================"
    echo "[ERROR] 일반 Data Dump 실패"
    echo "============================================================"
    exit 1
fi

echo
echo "[OK] 일반 Data Dump 완료"
echo

ls -lh "${DATA_DUMP}"

# ============================================================
# [5/5] Timetable Data Dump
#
# 대상
#   app_schema.merge_table_01
#   app_schema.merge_table_02
#
# Custom Format + Data Only
#
# Restore 시:
#   pg_restore -> COPY SQL
#   -> TEMP Stage
#   -> INSERT ... ON CONFLICT DO NOTHING
# ============================================================

echo
echo "[5/5] Timetable Data Dump 시작"
echo

pg_dump \
    -U "${DB_USER}" \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    -Fc \
    --data-only \
    -t "${SCHEMA_NAME}.merge_table_01" \
    -t "${SCHEMA_NAME}.merge_table_02" \
    -f "${TIMETABLE_DUMP}"

if [ $? -ne 0 ]; then
    echo
    echo "============================================================"
    echo "[ERROR] Timetable Data Dump 실패"
    echo "============================================================"
    exit 1
fi

echo
echo "[OK] Timetable Data Dump 완료"
echo

ls -lh "${TIMETABLE_DUMP}"

# ============================================================
# 최종 결과
# ============================================================

echo
echo "============================================================"
echo " Dump 완료"
echo "============================================================"
echo

echo "[Schema Dump]"
ls -lh "${SCHEMA_DUMP}"

echo
echo "[General Data Dump]"
ls -lh "${DATA_DUMP}"

echo
echo "[Timetable Data Dump]"
ls -lh "${TIMETABLE_DUMP}"

echo

exit 0
