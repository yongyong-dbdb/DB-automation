# PostgreSQL Performance Check — Read Only

DB에 스키마나 테이블을 만들지 않고 PostgreSQL 통계 뷰를 한 번 조회해 결과를 파일로 저장합니다.

## 실행

```sh
chmod +x postgres-performance-check.sh
./postgres-performance-check.sh
```

실행 권한을 부여하지 않은 경우에도 POSIX `sh`로 실행할 수 있습니다.

```sh
sh postgres-performance-check.sh
```

명령행 옵션은 없습니다. 실행 시 다음 두 값을 묻습니다.

1. 항목별 출력 건수(기본 20건)
2. 결과 파일 경로

결과는 기본적으로 다음 경로에 저장됩니다.

```text
results/postgres-performance-report_YYYYMMDD_HHMMSS.log
```

profile 탐색, 설정 파일 확인, 최종 접속 대상, 결과 파일 경로와 10개 조회 항목의 시작/완료 및 실행 시간을 verbose 형식으로 표시합니다. 진행 구간은 터미널과 결과 파일에 동시에 표시됩니다. 개별 SQL은 최대 5초, 전체 조회는 최대 60초로 제한되며 오래 걸리는 구간은 취소됩니다. 비밀번호는 표시하지 않습니다.

## DB 접속정보

접속정보를 하드코딩하지 않습니다. profile은 다시 source하거나 파싱하지 않습니다. 연결정보는 다음 순서로 확인합니다.

1. 로그인 Shell이 상속한 `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGDATA`, `PGSERVICE`
2. 현재 계정으로 실행 중인 postgres 프로세스의 `-D` 옵션
3. `postgres -D "$PGDATA" -C port`와 `-C unix_socket_directories`
4. 현재 계정 소유의 로컬 Unix socket
5. port를 찾지 못한 경우 대화형 입력

연결 후 실제 적용 중인 `port`, `data_directory`, `config_file`, `unix_socket_directories`를 PostgreSQL에서 직접 조회합니다.

`postgres` DB에 읽기 전용으로 잠깐 연결해 접속 가능한 일반 database 목록과 owner를 보여줍니다. `postgres` 연결이 실패하면 `template1`로 목록 조회를 재시도합니다. template database는 선택 목록에서 제외합니다. 메뉴의 `0) 전체 database`를 선택하면 목록의 모든 DB에 순차 접속해 한 결과 파일에 DB별 10개 항목을 기록합니다. 접속할 수 없는 DB는 오류를 기록하고 다음 DB를 계속 처리합니다.

본 성능 조회 전에 선택한 DB로 연결 테스트를 수행하고 실제 DB명, 사용자, port와 data directory를 출력합니다.

## 조회 범위

- Top SQL
- SQL 변화 분석 가능 여부와 통계 초기화 시점
- 실행 시간 기반 CPU 후보
- Temp 사용 SQL
- Sequential Scan
- Missing Index 검토 후보
- Unused Index 검토 후보
- Hot Table
- 현재 Connection
- 현재 Wait Event

각 조회 결과의 첫 번째 열에는 `database_name`이 표시됩니다. 전체 database 조회 시에도 한 결과 파일 안에서 어느 DB의 결과인지 행 단위로 확인할 수 있습니다. Top SQL, CPU 후보, Temp SQL의 SQL 본문은 보고서 가독성을 위해 120자로 줄여 표시합니다.

`pg_stat_statements`를 조회할 수 없으면 관련된 Top SQL, SQL 변화 분석, CPU 후보, Temp SQL을 건너뛰고 나머지 6개 항목은 각 대상 DB에서 조회합니다.

## 읽기 전용 보장

`performance-check.sql`에는 `SELECT`와 psql 출력 제어 명령만 있습니다. `CREATE`, `INSERT`, `UPDATE`, `DELETE`, `DROP` 또는 통계 초기화 명령을 실행하지 않습니다.

보고서에는 위 10개 항목만 출력합니다. 이력 테이블을 사용하지 않으므로 SQL 변화량, Connection Peak, Wait Event 비율은 계산하지 않으며 해당 항목에 현재 조회의 한계를 표시합니다.

## pg_stat_statements 전체 DB 조회

`pg_stat_statements` 통계는 클러스터의 전체 database를 추적하지만 조회 뷰는 extension을 생성한 database에만 존재합니다. 스크립트는 `pg_stat_statements` extension이 설치된 DB를 자동 탐색하며, 일반적으로 `postgres` DB를 중앙 조회원으로 사용합니다.

- Top SQL, SQL 변화 기준시각, CPU 후보, Temp SQL: 중앙 pg_stat_statements DB에서 대상 DB의 OID로 필터링
- Sequential Scan, Index, Hot Table, Connection, Wait Event: 각 대상 DB에 직접 접속해서 조회

따라서 각 업무 DB마다 `CREATE EXTENSION pg_stat_statements`를 실행할 필요가 없습니다.
