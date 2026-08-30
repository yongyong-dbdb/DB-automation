# PostgreSQL Minor Version Upgrade

PostgreSQL 소스 tar 파일을 이용해 같은 메이저 버전 안에서 마이너 업그레이드를 수행하는 자동화 스크립트입니다. 현재 실행 중인 버전을 자동 확인하므로 특정 PostgreSQL 버전에 종속되지 않습니다.

## 주요 기능

- 현재 PostgreSQL과 같은 메이저 버전의 소스 tar만 검색하고 번호로 선택
- RHEL 계열, Debian 계열, SUSE 계열 빌드 의존성 확인
- 기존 `pg_config --configure` 옵션 계승 및 OpenSSL 기본 활성화
- PostgreSQL 본체와 `contrib` 빌드·설치, `make check` 수행
- DB 접속 및 비밀번호를 빌드 전에 검증
- 같은 `PGDATA`를 신규 바이너리로 기동하며, 기동 실패 시 기존 바이너리 자동 재기동
- 설치된 확장 모듈의 업데이트 필요 여부 확인 및 업데이트
- 기존 프로필 경로를 주석 처리하고 신규 PostgreSQL 경로 등록

## 준비 사항

- 현재 PostgreSQL이 정상 실행 중이어야 합니다.
- 업그레이드할 버전의 공식 소스 tar 파일을 기본 경로 아래에 준비합니다.
- 실행 계정이 기존 PostgreSQL과 데이터 디렉터리의 소유자여야 합니다.
- `prepare` 단계에서 PostgreSQL 관리 사용자 비밀번호를 입력합니다.

## 실행

```bash
sh minor_upgrade.sh prepare
sh minor_upgrade.sh upgrade
sh minor_upgrade.sh postcheck
sh minor_upgrade.sh env
```

### 1. prepare

소스 선택, DB 접속 확인, OS 의존성 확인, OpenSSL 빌드, 회귀 테스트, 설치, 확장 라이브러리 검사 및 메타데이터 백업을 수행합니다. 데이터베이스는 중단되지 않습니다.

자동 실행에서는 소스 파일을 명시할 수 있습니다.

```bash
sh minor_upgrade.sh --source-tar /path/to/postgresql-VERSION.tar.gz prepare
```

### 2. upgrade

기존 PostgreSQL을 중지하고 같은 `PGDATA`를 신규 바이너리로 시작합니다. 이 단계에서만 서비스 중단이 발생합니다. 진행하려면 화면에 표시된 확인 문구를 정확히 입력해야 합니다.

### 3. postcheck

서버 버전, 데이터 디렉터리, 포트를 확인하고 설치된 확장 모듈 중 업데이트가 필요한 항목만 갱신합니다.

### 4. env

기존 PostgreSQL 환경변수와 PATH 설정을 백업·주석 처리하고 신규 바이너리 경로를 등록합니다. 완료 후 화면에 안내되는 명령으로 현재 셸 환경을 다시 읽습니다.

## 버전 범위

이 스크립트는 같은 메이저 버전의 마이너 업그레이드 전용입니다. 예를 들어 12.x에서 12.x, 15.x에서 15.x 업그레이드에 사용합니다. 메이저 버전이 달라지는 업그레이드는 `pg_upgrade` 기반 Major Version Upgrade 절차를 사용해야 합니다.

## 선택 환경변수

- `BASE`: PostgreSQL 소스와 설치 경로의 기준 디렉터리
- `PG_HOME_OLD`: 현재 PostgreSQL 바이너리 경로
- `PGDATA`: 데이터 디렉터리
- `PGPORT`: PostgreSQL 포트
- `PGUSER_NAME`: 관리 사용자명, 기본값 `postgres`
- `JOBS`: 병렬 빌드 작업 수
- `ENABLE_OPENSSL`: OpenSSL 빌드 활성화 여부, 기본값 `true`
- `RUN_MAKE_CHECK`: 회귀 테스트 실행 여부, 기본값 `true`

값을 지정하지 않으면 현재 셸 환경과 프로필, 기존 PostgreSQL 설정에서 가능한 값을 자동 확인합니다.
