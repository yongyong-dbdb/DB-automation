#!/bin/sh

set -u

SCRIPT_VERSION="2026.08.13-v11-optional-data_a-data_b"

# ============================================================
# 기본 설정
# ============================================================

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PID=$$

TMP_DATA_A_LIST="/tmp/source_db_data_a_${TIMESTAMP}_${PID}.list"
TMP_DATA_B_LIST="/tmp/source_db_data_b_${TIMESTAMP}_${PID}.list"

TMP_DATA_A_REVERSE_LIST="/tmp/source_db_data_a_reverse_${TIMESTAMP}_${PID}.list"
TMP_DATA_B_REVERSE_LIST="/tmp/source_db_data_b_reverse_${TIMESTAMP}_${PID}.list"

TMP_DATA_A_COLLISION_LIST="/tmp/source_db_data_a_collision_${TIMESTAMP}_${PID}.list"
TMP_DATA_B_COLLISION_LIST="/tmp/source_db_data_b_collision_${TIMESTAMP}_${PID}.list"

TMP_DATA_A_COPIED_LIST="/tmp/source_db_data_a_copied_${TIMESTAMP}_${PID}.list"
TMP_DATA_B_COPIED_LIST="/tmp/source_db_data_b_copied_${TIMESTAMP}_${PID}.list"

TMP_DATA_A_COPY_SOURCE_LIST="/tmp/source_db_data_a_copy_source_${TIMESTAMP}_${PID}.list"
TMP_DATA_B_COPY_SOURCE_LIST="/tmp/source_db_data_b_copy_source_${TIMESTAMP}_${PID}.list"

TMP_DATA_B_NON_NUMERIC_LIST="/tmp/source_db_data_b_non_numeric_${TIMESTAMP}_${PID}.list"

cleanup()
{
    rm -f \
        "${TMP_DATA_A_LIST}" \
        "${TMP_DATA_B_LIST}" \
        "${TMP_DATA_A_REVERSE_LIST}" \
        "${TMP_DATA_B_REVERSE_LIST}" \
        "${TMP_DATA_A_COLLISION_LIST}" \
        "${TMP_DATA_B_COLLISION_LIST}" \
        "${TMP_DATA_A_COPIED_LIST}" \
        "${TMP_DATA_B_COPIED_LIST}" \
        "${TMP_DATA_A_COPY_SOURCE_LIST}" \
        "${TMP_DATA_B_COPY_SOURCE_LIST}" \
        "${TMP_DATA_B_NON_NUMERIC_LIST}"
}

trap cleanup EXIT HUP INT TERM

# ============================================================
# 숫자 검증
# ============================================================

is_integer()
{
    case "$1" in
        '')
            return 1
            ;;
        *[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ============================================================
# DATA_B 비정수 디렉토리 목록
# ============================================================

make_data_b_non_numeric_list()
{
    BASE_DIR="$1"

    : > "${TMP_DATA_B_NON_NUMERIC_LIST}"

    if [ ! -d "${BASE_DIR}" ]; then
        return
    fi

    find "${BASE_DIR}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print 2>/dev/null |
    while IFS= read -r DIR_PATH
    do
        [ -z "${DIR_PATH}" ] && continue

        DIR_NAME=$(basename "${DIR_PATH}")

        if ! is_integer "${DIR_NAME}"; then
            echo "${DIR_PATH}"
        fi
    done > "${TMP_DATA_B_NON_NUMERIC_LIST}"
}

# ============================================================
# 시작
# ============================================================

echo "============================================================"
echo " Application DAT inst_no 변경"
echo " Version: ${SCRIPT_VERSION}"
echo "============================================================"
echo
echo "대상:"
echo "  DATA_A"
echo "  DATA_B"
echo
echo "작업 흐름:"
echo "  1. TARGET DAT -> dat_backup 백업"
echo "  2. SOURCE DAT의 SOURCE inst_no -> TARGET inst_no 변경"
echo "  3. 변경된 SOURCE DAT를 TARGET DAT에 병합"
echo
echo "※ DATA_A/DATA_B 중 SOURCE inst_no 디렉토리가 없으면 해당 영역은 SKIP합니다."
echo "※ dat_backup이 이미 존재하면 백업은 SKIP합니다."
echo "※ DATA_B 바로 아래에서 숫자가 아닌 디렉토리는 작업에서 제외합니다."
echo "※ 예: NON_NUMERIC_A, ABC, NON_NUMERIC_B -> SKIP"
echo

# ============================================================
# DAT 경로 입력
# ============================================================

printf "TARGET DAT 디렉토리 경로 입력 : "
IFS= read -r TARGET_DAT_DIR
TARGET_DAT_DIR=${TARGET_DAT_DIR%/}

printf "SOURCE DAT 디렉토리 경로 입력 : "
IFS= read -r SOURCE_DAT_DIR
SOURCE_DAT_DIR=${SOURCE_DAT_DIR%/}

if [ -z "${TARGET_DAT_DIR}" ] || [ -z "${SOURCE_DAT_DIR}" ]; then
    echo "[ERROR] TARGET DAT 경로와 SOURCE DAT 경로를 모두 입력해야 합니다."
    exit 1
fi

if [ ! -d "${TARGET_DAT_DIR}" ]; then
    echo "[ERROR] TARGET DAT 디렉토리가 존재하지 않습니다."
    echo "${TARGET_DAT_DIR}"
    exit 1
fi

if [ ! -d "${SOURCE_DAT_DIR}" ]; then
    echo "[ERROR] SOURCE DAT 디렉토리가 존재하지 않습니다."
    echo "${SOURCE_DAT_DIR}"
    exit 1
fi

if [ "${TARGET_DAT_DIR}" = "${SOURCE_DAT_DIR}" ]; then
    echo "[ERROR] TARGET DAT와 SOURCE DAT 경로가 동일합니다."
    exit 1
fi

# ============================================================
# 경로 설정
# ============================================================

TARGET_DAT_PARENT_DIR=$(dirname "${TARGET_DAT_DIR}")
DAT_BACKUP_DIR="${TARGET_DAT_PARENT_DIR}/dat_backup"

SOURCE_DATA_A_DIR="${SOURCE_DAT_DIR}/DATA_A"
SOURCE_DATA_B_DIR="${SOURCE_DAT_DIR}/DATA_B"

TARGET_DATA_A_DIR="${TARGET_DAT_DIR}/DATA_A"
TARGET_DATA_B_DIR="${TARGET_DAT_DIR}/DATA_B"

# 최상위 DATA_A / DATA_B 디렉토리는 존재해야 함
for DIR in \
    "${SOURCE_DATA_A_DIR}" \
    "${SOURCE_DATA_B_DIR}" \
    "${TARGET_DATA_A_DIR}" \
    "${TARGET_DATA_B_DIR}"
do
    if [ ! -d "${DIR}" ]; then
        echo "[ERROR] 필수 상위 디렉토리가 존재하지 않습니다."
        echo "${DIR}"
        exit 1
    fi
done

echo
echo "[OK] DAT 경로 확인"
echo "  TARGET DAT   : ${TARGET_DAT_DIR}"
echo "  SOURCE DAT   : ${SOURCE_DAT_DIR}"
echo "  DAT BACKUP : ${DAT_BACKUP_DIR}"
echo

# ============================================================
# DATA_B 비정수 디렉토리 검사
# ============================================================

echo "============================================================"
echo " SOURCE DATA_B 디렉토리 검사"
echo "============================================================"
echo

make_data_b_non_numeric_list "${SOURCE_DATA_B_DIR}"

DATA_B_NON_NUMERIC_COUNT=$(wc -l < "${TMP_DATA_B_NON_NUMERIC_LIST}" | tr -d ' ')

echo "DATA_B 비정수 디렉토리 수 : ${DATA_B_NON_NUMERIC_COUNT}"

if [ "${DATA_B_NON_NUMERIC_COUNT}" -gt 0 ]; then

    echo
    echo "[SKIP] 다음 DATA_B 디렉토리는 숫자가 아니므로 작업에서 제외합니다."

    while IFS= read -r DIR_PATH
    do
        [ -z "${DIR_PATH}" ] && continue
        echo "  [SKIP] ${DIR_PATH}"
    done < "${TMP_DATA_B_NON_NUMERIC_LIST}"
fi

echo

# ============================================================
# inst_no 입력
# ============================================================

printf "SOURCE inst_no 입력 : "
IFS= read -r SOURCE_INST

if ! is_integer "${SOURCE_INST}"; then
    echo "[ERROR] SOURCE inst_no는 숫자만 입력해야 합니다."
    exit 1
fi

printf "TARGET inst_no 입력 : "
IFS= read -r TARGET_INST

if ! is_integer "${TARGET_INST}"; then
    echo "[ERROR] TARGET inst_no는 숫자만 입력해야 합니다."
    exit 1
fi

if [ "${SOURCE_INST}" = "${TARGET_INST}" ]; then
    echo "[ERROR] SOURCE inst_no와 TARGET inst_no가 동일합니다."
    exit 1
fi

# ============================================================
# 대상 경로
# ============================================================

SOURCE_DATA_A_OLD="${SOURCE_DATA_A_DIR}/${SOURCE_INST}"
SOURCE_DATA_A_NEW="${SOURCE_DATA_A_DIR}/${TARGET_INST}"

SOURCE_DATA_B_OLD="${SOURCE_DATA_B_DIR}/${SOURCE_INST}"
SOURCE_DATA_B_NEW="${SOURCE_DATA_B_DIR}/${TARGET_INST}"

TARGET_DATA_A_TARGET="${TARGET_DATA_A_DIR}/${TARGET_INST}"
TARGET_DATA_B_TARGET="${TARGET_DATA_B_DIR}/${TARGET_INST}"

# ============================================================
# 작업 대상 존재 여부
# ============================================================

DATA_A_ENABLED=0
DATA_B_ENABLED=0

if [ -d "${SOURCE_DATA_A_OLD}" ]; then
    DATA_A_ENABLED=1
fi

if [ -d "${SOURCE_DATA_B_OLD}" ]; then
    DATA_B_ENABLED=1
fi

# ============================================================
# 원복
# ============================================================

rollback()
{
    echo
    echo "============================================================"
    echo "[ROLLBACK] 변경 내용 원복 시작"
    echo "============================================================"
    echo

    ROLLBACK_ERROR=0

    # --------------------------------------------------------
    # TARGET DATA_A 신규 복사 파일 제거
    # --------------------------------------------------------

    if [ -f "${TMP_DATA_A_COPIED_LIST}" ]; then

        while IFS= read -r COPIED_FILE
        do
            [ -z "${COPIED_FILE}" ] && continue

            if [ -f "${COPIED_FILE}" ]; then
                if rm -f -- "${COPIED_FILE}"; then
                    echo "[OK] 제거: ${COPIED_FILE}"
                else
                    echo "[ERROR] DATA_A 복사 파일 제거 실패"
                    ROLLBACK_ERROR=1
                fi
            fi

        done < "${TMP_DATA_A_COPIED_LIST}"
    fi

    # --------------------------------------------------------
    # TARGET DATA_B 신규 복사 파일 제거
    # --------------------------------------------------------

    if [ -f "${TMP_DATA_B_COPIED_LIST}" ]; then

        while IFS= read -r COPIED_FILE
        do
            [ -z "${COPIED_FILE}" ] && continue

            if [ -f "${COPIED_FILE}" ]; then
                if rm -f -- "${COPIED_FILE}"; then
                    echo "[OK] 제거: ${COPIED_FILE}"
                else
                    echo "[ERROR] DATA_B 복사 파일 제거 실패"
                    ROLLBACK_ERROR=1
                fi
            fi

        done < "${TMP_DATA_B_COPIED_LIST}"
    fi

    # --------------------------------------------------------
    # DATA_A 디렉토리 원복
    # --------------------------------------------------------

    if [ "${DATA_A_ENABLED}" -eq 1 ]; then

        if [ -d "${SOURCE_DATA_A_NEW}" ] && [ ! -e "${SOURCE_DATA_A_OLD}" ]; then

            if ! mv -- "${SOURCE_DATA_A_NEW}" "${SOURCE_DATA_A_OLD}"; then
                echo "[ERROR] DATA_A 디렉토리 원복 실패"
                ROLLBACK_ERROR=1
            fi
        fi

        if [ -d "${SOURCE_DATA_A_OLD}" ]; then

            find "${SOURCE_DATA_A_OLD}" \
                -depth \
                -type f \
                -name "*_${TARGET_INST}_*" \
                -print > "${TMP_DATA_A_REVERSE_LIST}"

            while IFS= read -r FILE
            do
                [ -z "${FILE}" ] && continue

                DIRNAME=$(dirname "${FILE}")
                BASENAME=$(basename "${FILE}")

                OLD_BASENAME=$(printf '%s\n' "${BASENAME}" | sed "s/_${TARGET_INST}_/_${SOURCE_INST}_/")
                OLD_FILE="${DIRNAME}/${OLD_BASENAME}"

                if [ -e "${OLD_FILE}" ]; then
                    echo "[ERROR] DATA_A 원복 대상 파일이 이미 존재합니다."
                    echo "${OLD_FILE}"
                    ROLLBACK_ERROR=1
                    continue
                fi

                if ! mv -- "${FILE}" "${OLD_FILE}"; then
                    echo "[ERROR] DATA_A 파일 원복 실패"
                    ROLLBACK_ERROR=1
                fi

            done < "${TMP_DATA_A_REVERSE_LIST}"
        fi
    fi

    # --------------------------------------------------------
    # DATA_B 디렉토리 원복
    # --------------------------------------------------------

    if [ "${DATA_B_ENABLED}" -eq 1 ]; then

        if [ -d "${SOURCE_DATA_B_NEW}" ] && [ ! -e "${SOURCE_DATA_B_OLD}" ]; then

            if ! mv -- "${SOURCE_DATA_B_NEW}" "${SOURCE_DATA_B_OLD}"; then
                echo "[ERROR] DATA_B 디렉토리 원복 실패"
                ROLLBACK_ERROR=1
            fi
        fi

        if [ -d "${SOURCE_DATA_B_OLD}" ]; then

            find "${SOURCE_DATA_B_OLD}" \
                -depth \
                -type f \
                -name "*_${TARGET_INST}_*" \
                -print > "${TMP_DATA_B_REVERSE_LIST}"

            while IFS= read -r FILE
            do
                [ -z "${FILE}" ] && continue

                DIRNAME=$(dirname "${FILE}")
                BASENAME=$(basename "${FILE}")

                OLD_BASENAME=$(printf '%s\n' "${BASENAME}" | sed "s/_${TARGET_INST}_/_${SOURCE_INST}_/")
                OLD_FILE="${DIRNAME}/${OLD_BASENAME}"

                if [ -e "${OLD_FILE}" ]; then
                    echo "[ERROR] DATA_B 원복 대상 파일이 이미 존재합니다."
                    echo "${OLD_FILE}"
                    ROLLBACK_ERROR=1
                    continue
                fi

                if ! mv -- "${FILE}" "${OLD_FILE}"; then
                    echo "[ERROR] DATA_B 파일 원복 실패"
                    ROLLBACK_ERROR=1
                fi

            done < "${TMP_DATA_B_REVERSE_LIST}"
        fi
    fi

    echo

    if [ "${ROLLBACK_ERROR}" -ne 0 ]; then
        echo "[ERROR] 자동 원복이 완전히 수행되지 않았습니다."
        echo
        echo "TARGET DAT 백업:"
        echo "${DAT_BACKUP_DIR}"
        exit 1
    fi

    echo "[OK] 자동 원복 완료"
    exit 1
}

# ============================================================
# 1. 기본 경로 검증
# ============================================================

echo "============================================================"
echo "[1/8] 기본 경로 검증"
echo "============================================================"
echo

echo "TARGET DAT 경로:"
echo "  ${TARGET_DAT_DIR}"
echo

echo "SOURCE DAT 경로:"
echo "  ${SOURCE_DAT_DIR}"
echo

echo "TARGET DAT 백업 경로:"
echo "  ${DAT_BACKUP_DIR}"
echo

echo "SOURCE inst_no:"
echo "  ${SOURCE_INST}"
echo

echo "TARGET inst_no:"
echo "  ${TARGET_INST}"
echo

# ------------------------------------------------------------
# DATA_A 대상 확인
# ------------------------------------------------------------

if [ "${DATA_A_ENABLED}" -eq 1 ]; then

    echo "[OK] SOURCE DATA_A 대상 존재"
    echo "     ${SOURCE_DATA_A_OLD}"

    if [ -e "${SOURCE_DATA_A_NEW}" ]; then
        echo "[ERROR] SOURCE DAT 내 TARGET DATA_A inst_no 디렉토리가 이미 존재합니다."
        echo "${SOURCE_DATA_A_NEW}"
        exit 1
    fi

else

    echo "[SKIP] SOURCE DATA_A inst_no 디렉토리가 존재하지 않습니다."
    echo "       ${SOURCE_DATA_A_OLD}"
fi

# ------------------------------------------------------------
# DATA_B 대상 확인
# ------------------------------------------------------------

if [ "${DATA_B_ENABLED}" -eq 1 ]; then

    echo "[OK] SOURCE DATA_B 대상 존재"
    echo "     ${SOURCE_DATA_B_OLD}"

    if [ -e "${SOURCE_DATA_B_NEW}" ]; then
        echo "[ERROR] SOURCE DAT 내 TARGET DATA_B inst_no 디렉토리가 이미 존재합니다."
        echo "${SOURCE_DATA_B_NEW}"
        exit 1
    fi

else

    echo "[SKIP] SOURCE DATA_B inst_no 디렉토리가 존재하지 않습니다."
    echo "       ${SOURCE_DATA_B_OLD}"
fi

echo

# 둘 다 없으면 정상 종료
if [ "${DATA_A_ENABLED}" -eq 0 ] && [ "${DATA_B_ENABLED}" -eq 0 ]; then

    echo "============================================================"
    echo " 작업 대상 없음"
    echo "============================================================"
    echo
    echo "[SKIP] SOURCE inst_no ${SOURCE_INST}에 해당하는 DATA_A/DATA_B 디렉토리가 없습니다."
    echo "[SKIP] 변경 및 백업을 수행하지 않습니다."
    echo

    exit 0
fi

echo "[OK] 기본 경로 검증 완료"
echo

# ============================================================
# 2. 파일 사용 여부 확인
# ============================================================

echo "============================================================"
echo "[2/8] SOURCE DAT 파일 사용 여부 확인"
echo "============================================================"
echo

if command -v lsof >/dev/null 2>&1; then

    OPEN_DATA_A_COUNT=0
    OPEN_DATA_B_COUNT=0

    if [ "${DATA_A_ENABLED}" -eq 1 ]; then

        OPEN_DATA_A_COUNT=$(lsof +D "${SOURCE_DATA_A_OLD}" 2>/dev/null |
            tail -n +2 |
            wc -l |
            tr -d ' ')

        echo "DATA_A 열린 파일 수  : ${OPEN_DATA_A_COUNT}"

    else

        echo "DATA_A 열린 파일 확인 : SKIP"
    fi

    if [ "${DATA_B_ENABLED}" -eq 1 ]; then

        OPEN_DATA_B_COUNT=$(lsof +D "${SOURCE_DATA_B_OLD}" 2>/dev/null |
            tail -n +2 |
            wc -l |
            tr -d ' ')

        echo "DATA_B 열린 파일 수 : ${OPEN_DATA_B_COUNT}"

    else

        echo "DATA_B 열린 파일 확인: SKIP"
    fi

    echo

    if [ "${OPEN_DATA_A_COUNT}" -gt 0 ] || [ "${OPEN_DATA_B_COUNT}" -gt 0 ]; then
        echo "[ERROR] 대상 파일이 사용 중입니다."
        exit 1
    fi

    echo "[OK] 열린 파일 없음"

else

    echo "[WARN] lsof 명령어가 없어 열린 파일 여부를 확인할 수 없습니다."
fi

echo

# ============================================================
# 3. 변경 대상 검증
# ============================================================

echo "============================================================"
echo "[3/8] SOURCE DAT 변경 대상 사전 검증"
echo "============================================================"
echo

DATA_A_TOTAL=0
DATA_A_TARGET=0
DATA_B_TOTAL=0
DATA_B_TARGET=0

# ------------------------------------------------------------
# DATA_A 검증
# ------------------------------------------------------------

if [ "${DATA_A_ENABLED}" -eq 1 ]; then

    DATA_A_TOTAL=$(find "${SOURCE_DATA_A_OLD}" \
        -type f \
        -print |
        wc -l |
        tr -d ' ')

    DATA_A_TARGET=$(find "${SOURCE_DATA_A_OLD}" \
        -type f \
        -name "*_${SOURCE_INST}_*" \
        -print |
        wc -l |
        tr -d ' ')

    echo "[DATA_A]"
    echo "전체 파일 수      : ${DATA_A_TOTAL}"
    echo "변경 대상 파일 수 : ${DATA_A_TARGET}"
    echo

    if [ "${DATA_A_TOTAL}" -eq 0 ]; then
        echo "[SKIP] SOURCE DATA_A 디렉토리에 파일이 없습니다."
        DATA_A_ENABLED=0
    elif [ "${DATA_A_TARGET}" -ne "${DATA_A_TOTAL}" ]; then

        echo "[ERROR] DATA_A에 SOURCE inst_no 패턴이 없는 파일이 존재합니다."
        echo

        find "${SOURCE_DATA_A_OLD}" \
            -type f \
            ! -name "*_${SOURCE_INST}_*" \
            -print

        exit 1
    else
        echo "[OK] DATA_A 변경 대상 검증 완료"
    fi

else

    echo "[DATA_A]"
    echo "[SKIP] SOURCE DATA_A/${SOURCE_INST} 없음"
fi

echo

# ------------------------------------------------------------
# DATA_B 검증
# ------------------------------------------------------------

if [ "${DATA_B_ENABLED}" -eq 1 ]; then

    DATA_B_TOTAL=$(find "${SOURCE_DATA_B_OLD}" \
        -type f \
        -print |
        wc -l |
        tr -d ' ')

    DATA_B_TARGET=$(find "${SOURCE_DATA_B_OLD}" \
        -type f \
        -name "*_${SOURCE_INST}_*" \
        -print |
        wc -l |
        tr -d ' ')

    echo "[DATA_B]"
    echo "전체 파일 수      : ${DATA_B_TOTAL}"
    echo "변경 대상 파일 수 : ${DATA_B_TARGET}"
    echo

    if [ "${DATA_B_TOTAL}" -eq 0 ]; then
        echo "[SKIP] SOURCE DATA_B 디렉토리에 파일이 없습니다."
        DATA_B_ENABLED=0
    elif [ "${DATA_B_TARGET}" -ne "${DATA_B_TOTAL}" ]; then

        echo "[ERROR] DATA_B에 SOURCE inst_no 패턴이 없는 파일이 존재합니다."
        echo

        find "${SOURCE_DATA_B_OLD}" \
            -type f \
            ! -name "*_${SOURCE_INST}_*" \
            -print

        exit 1
    else
        echo "[OK] DATA_B 변경 대상 검증 완료"
    fi

else

    echo "[DATA_B]"
    echo "[SKIP] SOURCE DATA_B/${SOURCE_INST} 없음"
fi

echo

# ------------------------------------------------------------
# DATA_B 비정수 목록
# ------------------------------------------------------------

echo "[DATA_B 비정수 디렉토리]"
echo "SKIP 디렉토리 수 : ${DATA_B_NON_NUMERIC_COUNT}"

if [ "${DATA_B_NON_NUMERIC_COUNT}" -gt 0 ]; then

    while IFS= read -r DIR_PATH
    do
        [ -z "${DIR_PATH}" ] && continue
        echo "[SKIP] ${DIR_PATH}"
    done < "${TMP_DATA_B_NON_NUMERIC_LIST}"
fi

echo

# 파일까지 검사한 후 둘 다 작업 불가면 종료
if [ "${DATA_A_ENABLED}" -eq 0 ] && [ "${DATA_B_ENABLED}" -eq 0 ]; then

    echo "[SKIP] 실제 변경할 DATA_A/DATA_B 파일이 없습니다."
    echo "[SKIP] 백업 및 변경 작업을 수행하지 않습니다."
    exit 0
fi

# ============================================================
# 작업 예정
# ============================================================

echo "============================================================"
echo " 작업 예정"
echo "============================================================"
echo

echo "[TARGET DAT BACKUP]"
echo "${TARGET_DAT_DIR}"
echo " -> ${DAT_BACKUP_DIR}"
echo

echo "[SOURCE -> TARGET inst_no]"
echo "${SOURCE_INST}"
echo " -> ${TARGET_INST}"
echo

if [ "${DATA_A_ENABLED}" -eq 1 ]; then
    echo "[DATA_A]"
    echo "${SOURCE_DATA_A_OLD}"
    echo " -> ${SOURCE_DATA_A_NEW}"
else
    echo "[DATA_A]"
    echo "[SKIP]"
fi

echo

if [ "${DATA_B_ENABLED}" -eq 1 ]; then
    echo "[DATA_B]"
    echo "${SOURCE_DATA_B_OLD}"
    echo " -> ${SOURCE_DATA_B_NEW}"
else
    echo "[DATA_B]"
    echo "[SKIP]"
fi

echo

printf "작업을 진행하시겠습니까? (yes 입력 시 진행) : "
IFS= read -r CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
    echo "[CANCEL] 작업을 취소했습니다."
    exit 0
fi

# ============================================================
# 4. TARGET DAT 백업
# ============================================================

echo
echo "============================================================"
echo "[4/8] TARGET DAT 백업"
echo "============================================================"
echo

if [ -e "${DAT_BACKUP_DIR}" ]; then

    if [ -d "${DAT_BACKUP_DIR}" ]; then

        echo "[SKIP] dat_backup 디렉토리가 이미 존재합니다."
        echo "[SKIP] 기존 백업을 유지합니다."
        echo "       ${DAT_BACKUP_DIR}"

    else

        echo "[ERROR] dat_backup 경로에 일반 파일이 존재합니다."
        echo "${DAT_BACKUP_DIR}"
        exit 1
    fi

else

    echo "[BACKUP] TARGET DAT 백업 시작"
    echo "${TARGET_DAT_DIR}"
    echo " -> ${DAT_BACKUP_DIR}"
    echo

    if ! cp -a -- "${TARGET_DAT_DIR}" "${DAT_BACKUP_DIR}"; then
        echo "[ERROR] TARGET DAT 백업 실패"
        exit 1
    fi

    if [ ! -d "${DAT_BACKUP_DIR}" ]; then
        echo "[ERROR] dat_backup 생성 확인 실패"
        exit 1
    fi

    echo "[OK] TARGET DAT 백업 완료"
fi

echo

# ============================================================
# 5. SOURCE DATA_A 변경
# ============================================================

echo "============================================================"
echo "[5/8] SOURCE DATA_A inst_no 변경"
echo "============================================================"
echo

if [ "${DATA_A_ENABLED}" -eq 0 ]; then

    echo "[SKIP] DATA_A/${SOURCE_INST} 작업 대상 없음"

else

    find "${SOURCE_DATA_A_OLD}" \
        -depth \
        -type f \
        -name "*_${SOURCE_INST}_*" \
        -print > "${TMP_DATA_A_LIST}"

    while IFS= read -r FILE
    do
        [ -z "${FILE}" ] && continue

        DIRNAME=$(dirname "${FILE}")
        BASENAME=$(basename "${FILE}")

        NEW_BASENAME=$(printf '%s\n' "${BASENAME}" |
            sed "s/_${SOURCE_INST}_/_${TARGET_INST}_/")

        NEW_FILE="${DIRNAME}/${NEW_BASENAME}"

        if [ -e "${NEW_FILE}" ]; then
            echo "[ERROR] 변경 대상 파일이 이미 존재합니다."
            echo "${NEW_FILE}"
            rollback
        fi

        if ! mv -- "${FILE}" "${NEW_FILE}"; then
            echo "[ERROR] DATA_A 파일명 변경 실패"
            rollback
        fi

    done < "${TMP_DATA_A_LIST}"

    if ! mv -- "${SOURCE_DATA_A_OLD}" "${SOURCE_DATA_A_NEW}"; then
        echo "[ERROR] DATA_A 디렉토리 변경 실패"
        rollback
    fi

    echo "[OK] DATA_A ${SOURCE_INST} -> ${TARGET_INST} 변경 완료"
fi

echo

# ============================================================
# 6. SOURCE DATA_B 변경
# ============================================================

echo "============================================================"
echo "[6/8] SOURCE DATA_B inst_no 변경"
echo "============================================================"
echo

if [ "${DATA_B_ENABLED}" -eq 0 ]; then

    echo "[SKIP] DATA_B/${SOURCE_INST} 작업 대상 없음"

else

    find "${SOURCE_DATA_B_OLD}" \
        -depth \
        -type f \
        -name "*_${SOURCE_INST}_*" \
        -print > "${TMP_DATA_B_LIST}"

    while IFS= read -r FILE
    do
        [ -z "${FILE}" ] && continue

        DIRNAME=$(dirname "${FILE}")
        BASENAME=$(basename "${FILE}")

        NEW_BASENAME=$(printf '%s\n' "${BASENAME}" |
            sed "s/_${SOURCE_INST}_/_${TARGET_INST}_/")

        NEW_FILE="${DIRNAME}/${NEW_BASENAME}"

        if [ -e "${NEW_FILE}" ]; then
            echo "[ERROR] 변경 대상 파일이 이미 존재합니다."
            echo "${NEW_FILE}"
            rollback
        fi

        if ! mv -- "${FILE}" "${NEW_FILE}"; then
            echo "[ERROR] DATA_B 파일명 변경 실패"
            rollback
        fi

    done < "${TMP_DATA_B_LIST}"

    if ! mv -- "${SOURCE_DATA_B_OLD}" "${SOURCE_DATA_B_NEW}"; then
        echo "[ERROR] DATA_B 디렉토리 변경 실패"
        rollback
    fi

    echo "[OK] DATA_B ${SOURCE_INST} -> ${TARGET_INST} 변경 완료"
fi

echo

# ============================================================
# 7. SOURCE DAT 변경 검증
# ============================================================

echo "============================================================"
echo "[7/8] SOURCE DAT 변경 검증"
echo "============================================================"
echo

FINAL_ERROR=0

DATA_A_AFTER=0
DATA_B_AFTER=0
DATA_A_OLD_REMAIN=0
DATA_B_OLD_REMAIN=0
DATA_A_NEW_COUNT=0
DATA_B_NEW_COUNT=0

if [ "${DATA_A_ENABLED}" -eq 1 ]; then

    DATA_A_AFTER=$(find "${SOURCE_DATA_A_NEW}" \
        -type f \
        -print 2>/dev/null |
        wc -l |
        tr -d ' ')

    DATA_A_OLD_REMAIN=$(find "${SOURCE_DATA_A_NEW}" \
        -type f \
        -name "*_${SOURCE_INST}_*" \
        -print 2>/dev/null |
        wc -l |
        tr -d ' ')

    DATA_A_NEW_COUNT=$(find "${SOURCE_DATA_A_NEW}" \
        -type f \
        -name "*_${TARGET_INST}_*" \
        -print 2>/dev/null |
        wc -l |
        tr -d ' ')

    echo "[DATA_A]"
    echo "변경 전           : ${DATA_A_TOTAL}"
    echo "변경 후           : ${DATA_A_AFTER}"
    echo "SOURCE inst_no 잔존 : ${DATA_A_OLD_REMAIN}"
    echo "TARGET inst_no 파일 : ${DATA_A_NEW_COUNT}"
    echo

    if [ "${DATA_A_TOTAL}" -ne "${DATA_A_AFTER}" ]; then
        FINAL_ERROR=1
    fi

    if [ "${DATA_A_OLD_REMAIN}" -ne 0 ]; then
        FINAL_ERROR=1
    fi

    if [ "${DATA_A_NEW_COUNT}" -ne "${DATA_A_TOTAL}" ]; then
        FINAL_ERROR=1
    fi

else

    echo "[DATA_A]"
    echo "[SKIP] 검증 대상 없음"
    echo
fi

if [ "${DATA_B_ENABLED}" -eq 1 ]; then

    DATA_B_AFTER=$(find "${SOURCE_DATA_B_NEW}" \
        -type f \
        -print 2>/dev/null |
        wc -l |
        tr -d ' ')

    DATA_B_OLD_REMAIN=$(find "${SOURCE_DATA_B_NEW}" \
        -type f \
        -name "*_${SOURCE_INST}_*" \
        -print 2>/dev/null |
        wc -l |
        tr -d ' ')

    DATA_B_NEW_COUNT=$(find "${SOURCE_DATA_B_NEW}" \
        -type f \
        -name "*_${TARGET_INST}_*" \
        -print 2>/dev/null |
        wc -l |
        tr -d ' ')

    echo "[DATA_B]"
    echo "변경 전           : ${DATA_B_TOTAL}"
    echo "변경 후           : ${DATA_B_AFTER}"
    echo "SOURCE inst_no 잔존 : ${DATA_B_OLD_REMAIN}"
    echo "TARGET inst_no 파일 : ${DATA_B_NEW_COUNT}"
    echo

    if [ "${DATA_B_TOTAL}" -ne "${DATA_B_AFTER}" ]; then
        FINAL_ERROR=1
    fi

    if [ "${DATA_B_OLD_REMAIN}" -ne 0 ]; then
        FINAL_ERROR=1
    fi

    if [ "${DATA_B_NEW_COUNT}" -ne "${DATA_B_TOTAL}" ]; then
        FINAL_ERROR=1
    fi

else

    echo "[DATA_B]"
    echo "[SKIP] 검증 대상 없음"
    echo
fi

if [ "${FINAL_ERROR}" -ne 0 ]; then
    echo "[ERROR] SOURCE DAT 변경 검증 실패"
    rollback
fi

echo "[OK] SOURCE DAT 변경 검증 완료"
echo

# ============================================================
# 8. TARGET DAT 병합
# ============================================================

echo "============================================================"
echo "[8/8] TARGET DAT 병합"
echo "============================================================"
echo

: > "${TMP_DATA_A_COLLISION_LIST}"
: > "${TMP_DATA_B_COLLISION_LIST}"
: > "${TMP_DATA_A_COPIED_LIST}"
: > "${TMP_DATA_B_COPIED_LIST}"
: > "${TMP_DATA_A_COPY_SOURCE_LIST}"
: > "${TMP_DATA_B_COPY_SOURCE_LIST}"

DATA_A_SKIP_COUNT=0
DATA_B_SKIP_COUNT=0

DATA_A_EXPECT_COPY=0
DATA_B_EXPECT_COPY=0

DATA_A_COPIED_COUNT=0
DATA_B_COPIED_COUNT=0

DATA_A_ACTUAL_SKIP_COUNT=0
DATA_B_ACTUAL_SKIP_COUNT=0

# ============================================================
# DATA_A 병합
# ============================================================

if [ "${DATA_A_ENABLED}" -eq 1 ]; then

    find "${SOURCE_DATA_A_NEW}" \
        -type f \
        -print > "${TMP_DATA_A_COPY_SOURCE_LIST}"

    while IFS= read -r SRC_FILE
    do
        [ -z "${SRC_FILE}" ] && continue

        REL_PATH=${SRC_FILE#"${SOURCE_DATA_A_NEW}/"}
        DEST_FILE="${TARGET_DATA_A_TARGET}/${REL_PATH}"

        if [ -e "${DEST_FILE}" ]; then
            echo "${DEST_FILE}" >> "${TMP_DATA_A_COLLISION_LIST}"
        fi

    done < "${TMP_DATA_A_COPY_SOURCE_LIST}"

    DATA_A_SKIP_COUNT=$(wc -l < "${TMP_DATA_A_COLLISION_LIST}" | tr -d ' ')
    DATA_A_EXPECT_COPY=$((DATA_A_AFTER - DATA_A_SKIP_COUNT))

    echo "[DATA_A]"
    echo "기존 파일 SKIP 예정 : ${DATA_A_SKIP_COUNT}"
    echo "신규 복사 예정      : ${DATA_A_EXPECT_COPY}"
    echo

    if ! mkdir -p -- "${TARGET_DATA_A_TARGET}"; then
        echo "[ERROR] TARGET DATA_A 대상 디렉토리 생성 실패"
        rollback
    fi

    while IFS= read -r SRC_FILE
    do
        [ -z "${SRC_FILE}" ] && continue

        REL_PATH=${SRC_FILE#"${SOURCE_DATA_A_NEW}/"}
        DEST_FILE="${TARGET_DATA_A_TARGET}/${REL_PATH}"
        DEST_PARENT=$(dirname "${DEST_FILE}")

        if [ -e "${DEST_FILE}" ]; then
            DATA_A_ACTUAL_SKIP_COUNT=$((DATA_A_ACTUAL_SKIP_COUNT + 1))
            continue
        fi

        if ! mkdir -p -- "${DEST_PARENT}"; then
            echo "[ERROR] DATA_A 하위 디렉토리 생성 실패"
            rollback
        fi

        if ! cp -a -- "${SRC_FILE}" "${DEST_FILE}"; then
            echo "[ERROR] DATA_A 파일 복사 실패"
            rollback
        fi

        echo "${DEST_FILE}" >> "${TMP_DATA_A_COPIED_LIST}"

        DATA_A_COPIED_COUNT=$((DATA_A_COPIED_COUNT + 1))

    done < "${TMP_DATA_A_COPY_SOURCE_LIST}"

    echo "[OK] DATA_A 병합 완료"
    echo "     신규 복사 : ${DATA_A_COPIED_COUNT}"
    echo "     기존 SKIP : ${DATA_A_ACTUAL_SKIP_COUNT}"
    echo

else

    echo "[DATA_A]"
    echo "[SKIP] 병합 대상 없음"
    echo
fi

# ============================================================
# DATA_B 병합
# ============================================================

if [ "${DATA_B_ENABLED}" -eq 1 ]; then

    find "${SOURCE_DATA_B_NEW}" \
        -type f \
        -print > "${TMP_DATA_B_COPY_SOURCE_LIST}"

    while IFS= read -r SRC_FILE
    do
        [ -z "${SRC_FILE}" ] && continue

        REL_PATH=${SRC_FILE#"${SOURCE_DATA_B_NEW}/"}
        DEST_FILE="${TARGET_DATA_B_TARGET}/${REL_PATH}"

        if [ -e "${DEST_FILE}" ]; then
            echo "${DEST_FILE}" >> "${TMP_DATA_B_COLLISION_LIST}"
        fi

    done < "${TMP_DATA_B_COPY_SOURCE_LIST}"

    DATA_B_SKIP_COUNT=$(wc -l < "${TMP_DATA_B_COLLISION_LIST}" | tr -d ' ')
    DATA_B_EXPECT_COPY=$((DATA_B_AFTER - DATA_B_SKIP_COUNT))

    echo "[DATA_B]"
    echo "기존 파일 SKIP 예정 : ${DATA_B_SKIP_COUNT}"
    echo "신규 복사 예정      : ${DATA_B_EXPECT_COPY}"
    echo

    if ! mkdir -p -- "${TARGET_DATA_B_TARGET}"; then
        echo "[ERROR] TARGET DATA_B 대상 디렉토리 생성 실패"
        rollback
    fi

    while IFS= read -r SRC_FILE
    do
        [ -z "${SRC_FILE}" ] && continue

        REL_PATH=${SRC_FILE#"${SOURCE_DATA_B_NEW}/"}
        DEST_FILE="${TARGET_DATA_B_TARGET}/${REL_PATH}"
        DEST_PARENT=$(dirname "${DEST_FILE}")

        if [ -e "${DEST_FILE}" ]; then
            DATA_B_ACTUAL_SKIP_COUNT=$((DATA_B_ACTUAL_SKIP_COUNT + 1))
            continue
        fi

        if ! mkdir -p -- "${DEST_PARENT}"; then
            echo "[ERROR] DATA_B 하위 디렉토리 생성 실패"
            rollback
        fi

        if ! cp -a -- "${SRC_FILE}" "${DEST_FILE}"; then
            echo "[ERROR] DATA_B 파일 복사 실패"
            rollback
        fi

        echo "${DEST_FILE}" >> "${TMP_DATA_B_COPIED_LIST}"

        DATA_B_COPIED_COUNT=$((DATA_B_COPIED_COUNT + 1))

    done < "${TMP_DATA_B_COPY_SOURCE_LIST}"

    echo "[OK] DATA_B 병합 완료"
    echo "     신규 복사 : ${DATA_B_COPIED_COUNT}"
    echo "     기존 SKIP : ${DATA_B_ACTUAL_SKIP_COUNT}"
    echo

else

    echo "[DATA_B]"
    echo "[SKIP] 병합 대상 없음"
    echo
fi

# ============================================================
# 최종 복사 검증
# ============================================================

COPY_VERIFY_ERROR=0

if [ "${DATA_A_ENABLED}" -eq 1 ]; then

    if [ "${DATA_A_COPIED_COUNT}" -ne "${DATA_A_EXPECT_COPY}" ]; then
        echo "[ERROR] DATA_A 예상 복사 수와 실제 복사 수 불일치"
        COPY_VERIFY_ERROR=1
    fi

    DATA_A_COPY_TOTAL=$((DATA_A_COPIED_COUNT + DATA_A_ACTUAL_SKIP_COUNT))

    if [ "${DATA_A_COPY_TOTAL}" -ne "${DATA_A_AFTER}" ]; then
        echo "[ERROR] DATA_A 복사+SKIP 수 불일치"
        COPY_VERIFY_ERROR=1
    fi
fi

if [ "${DATA_B_ENABLED}" -eq 1 ]; then

    if [ "${DATA_B_COPIED_COUNT}" -ne "${DATA_B_EXPECT_COPY}" ]; then
        echo "[ERROR] DATA_B 예상 복사 수와 실제 복사 수 불일치"
        COPY_VERIFY_ERROR=1
    fi

    DATA_B_COPY_TOTAL=$((DATA_B_COPIED_COUNT + DATA_B_ACTUAL_SKIP_COUNT))

    if [ "${DATA_B_COPY_TOTAL}" -ne "${DATA_B_AFTER}" ]; then
        echo "[ERROR] DATA_B 복사+SKIP 수 불일치"
        COPY_VERIFY_ERROR=1
    fi
fi

if [ "${COPY_VERIFY_ERROR}" -ne 0 ]; then
    rollback
fi

# ============================================================
# 완료
# ============================================================

echo
echo "============================================================"
echo " 작업 완료"
echo "============================================================"
echo

echo "TARGET DAT:"
echo "  ${TARGET_DAT_DIR}"
echo

echo "SOURCE DAT:"
echo "  ${SOURCE_DAT_DIR}"
echo

echo "TARGET DAT BACKUP:"
echo "  ${DAT_BACKUP_DIR}"
echo

echo "SOURCE inst_no : ${SOURCE_INST}"
echo "TARGET inst_no : ${TARGET_INST}"
echo

echo "[DATA_A]"

if [ "${DATA_A_ENABLED}" -eq 1 ]; then
    echo "  SOURCE 파일 수 : ${DATA_A_AFTER}"
    echo "  신규 복사    : ${DATA_A_COPIED_COUNT}"
    echo "  기존 SKIP    : ${DATA_A_ACTUAL_SKIP_COUNT}"
else
    echo "  [SKIP] SOURCE DATA_A/${SOURCE_INST} 없음"
fi

echo

echo "[DATA_B]"

if [ "${DATA_B_ENABLED}" -eq 1 ]; then
    echo "  SOURCE 파일 수         : ${DATA_B_AFTER}"
    echo "  신규 복사            : ${DATA_B_COPIED_COUNT}"
    echo "  기존 SKIP            : ${DATA_B_ACTUAL_SKIP_COUNT}"
else
    echo "  [SKIP] SOURCE DATA_B/${SOURCE_INST} 없음"
fi

echo "  비정수 디렉토리 SKIP : ${DATA_B_NON_NUMERIC_COUNT}"
echo

if [ "${DATA_B_NON_NUMERIC_COUNT}" -gt 0 ]; then

    echo "[DATA_B 비정수 디렉토리 SKIP 목록]"

    while IFS= read -r DIR_PATH
    do
        [ -z "${DIR_PATH}" ] && continue
        echo "  [SKIP] ${DIR_PATH}"
    done < "${TMP_DATA_B_NON_NUMERIC_LIST}"

    echo
fi

echo "[OK] 모든 변경 및 검증 완료"
echo

exit 0