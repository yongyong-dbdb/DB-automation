# MySQL RPM Package-based In-place Upgrade

Oracle MySQL Community RPM 설치 환경의 대화형 In-place Upgrade 자동화.

## 범위

- Enterprise Linux 8/9 계열
- Oracle MySQL Community RPM Package-based Installation
- 현재 버전은 실행 중인 서버에서, 목표 버전은 선택한 RPM metadata에서 자동 확인
- 특정 MySQL 버전 또는 Upgrade Path를 코드에 고정하지 않음. 버전 상승 여부와 MySQL Shell Upgrade Checker 결과로 진행 통제
- `/bin/sh` 실행
- root 실행

Generic Binary Distribution과 Source Installation은 범위 제외.

## 실행

```sh
su -
sh upgrade.sh
```

실행 초기에 다음 항목 입력.

- MySQL option file
- systemd service 자동 감지 (`mysqld`, 기본 unit이 없을 때만 직접 입력)
- MySQL 접속용 DB 관리자 계정(OS 서비스 계정과 별개)
- Unix Socket 또는 TCP/IP 접속 정보
- 업그레이드 결과 및 백업 저장 경로(RPM Package Source 경로와 별개)
- Package Source
- Backup Method
- RPM GPG signature 검증 여부(기본값 N). 생략 시에도 RPM digest 검증과 Yum transaction test 수행

OS 서비스 계정과 MySQL DB 계정의 동일 여부를 가정하지 않음. datadir 소유자와 그룹은 실행 환경에서 확인.

## Package Source

1. MySQL Yum Repository
2. RPM Bundle (`*.rpm-bundle.tar` 파일 또는 Bundle 보관 디렉터리)
3. Local RPM Directory

RPM Bundle 디렉터리에서 Bundle 1개 발견 시 자동 선택, 여러 개 발견 시 번호 선택. RPM Bundle과 Local RPM Directory는 현재 설치된 `mysql-community-*` 패키지와 이름이 일치하는 목표 RPM만 선별.

## Backup Method

1. Online Logical Backup + Offline Physical Backup
   - `mysqldump` SQL 형식 백업
   - MySQL 정상 종료 후 전체 datadir의 파일 시스템 수준 백업
2. Offline Physical Backup
   - MySQL 정상 종료 후 전체 datadir 백업
3. Online Logical Backup
   - 실행 중인 MySQL에서 `mysqldump` 수행
4. Existing Backup
   - 기존 백업 경로와 무결성 확인
5. No New Backup
   - 명시적 `NO_BACKUP` 확인 필요

## 주요 안전 검사

- Upgrade Checker Utility의 `Errors: 0` 확인
- `mysqlcheck --all-databases --check-upgrade`
- Native Partitioning 미지원 Storage Engine 검사
- Logical/Physical Backup 완료 및 SHA-256 생성
- RPM digest 또는 GPG signature 검사
- Yum transaction test
- `innodb_fast_shutdown=0` 적용 후 정상 종료
- 기존 option file의 RPM 업그레이드 전후 byte comparison
- `${CONFIG_FILE}.rpmnew` 별도 보관
- 새 `mysqld --validate-config` 통과 전 서비스 기동 차단
- datadir 경로 및 소유권 변경 검사
- 첫 기동 후 실행 버전, `mysqlcheck`, RPM, 스키마·계정·플러그인 상태 저장

## 결과 경로

```text
${WORK_ROOT}/${CURRENT_VERSION}_to_${TARGET_VERSION}_${TIMESTAMP}/
```

Logical Backup, Offline Physical Backup, Upgrade Checker 결과, option file, RPM 목록, error log, 업그레이드 전후 상태 저장.

## 주의

- RPM GPG signature 검증 사용 권장
- In-place Upgrade 후 이전 버전으로의 단순 In-place Downgrade 불가
- 업그레이드 전 상태 Recovery에는 검증된 백업과 해당 버전 RPM 필요
- Replication topology는 단일 인스턴스 절차 외에 별도의 rolling upgrade 계획 필요
