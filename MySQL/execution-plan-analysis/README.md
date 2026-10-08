# MySQL Execution Plan Analysis

MySQL Optimizer 실행계획과 Connection / Thread 기반 Performance Schema 통계 진단 스크립트.

검증 환경: MySQL Community Server **9.7.2**, Linux, `mysql` OS 계정, 기존 MySQL Login Path로 3306 인스턴스 접속.

선택한 `EXPLAIN FORMAT` 출력, 내부 JSON Plan 기반 Object 진단, Table/Index 통계, Column Histogram, Index I/O 누적값, 동일 Connection에서 수집한 `EXPLAIN ANALYZE` Statement Event, Optimizer Trace 원본 수집 기능 포함.

> 현재 구현 버전: `v0.2.1`

실행 파일:

```text
explain.sh
```

별도 Python/Perl/Node.js 런타임이나 `jq`, `yq` 등 외부 JSON Parser 미사용.

## 분석 영역

- `--format TRADITIONAL|TREE|JSON|ALL` 출력 형식 선택
- 대화형 메뉴 선택 지원(TTY), 비대화형 기본값 `TRADITIONAL`
- 내부 Table 추출용 JSON Plan 별도 수집
- `--analyze-format TREE|JSON` 실제 실행계획 형식 별도 선택
- `EXPLAIN ANALYZE`
- JSON Plan 기반 Base Table 자동 추출
- `INFORMATION_SCHEMA.TABLES` Table 상태
- `mysql.innodb_table_stats` InnoDB Persistent Statistics
- `INFORMATION_SCHEMA.STATISTICS` Index 정의 / Cardinality
- `INFORMATION_SCHEMA.COLUMN_STATISTICS` Column Histogram
- `performance_schema.table_io_waits_summary_by_index_usage` Index I/O
- `CONNECTION_ID()` / `performance_schema.threads.THREAD_ID` 매핑
- `events_statements_history`의 동일 Thread Statement Event 조회
- Global Index I/O 통계와 Thread-local SQL 실행 통계 분리
- `INFORMATION_SCHEMA.OPTIMIZER_TRACE` Optimizer Trace
- Connection / Version / Performance Schema Precheck

## 실행 요구 사항

```text
/bin/sh
mysql client
Oracle MySQL Server
```

기본 OS 명령:

```text
awk
sed
sort
mktemp
stty
```

## 실행

SQL File 기준:

```sh
sh explain.sh query.sql \
  --format TREE \
  --host <HOST> \
  --port 3306 \
  --user <USER> \
  --database tuning_lab
```

SQL 직접 입력:

```sh
sh explain.sh \
  --sql "SELECT * FROM customers WHERE city = '서울'" \
  --host <HOST> \
  --port 3306 \
  --user <USER> \
  --database tuning_lab
```

Unix Socket 기준:

```sh
sh explain.sh query.sql \
  --socket /path/to/mysql.sock \
  --user <USER> \
  --database tuning_lab
```

`mysql_config_editor` Login Path 사용:

```sh
sh explain.sh query.sql \
  --login-path local_mysql \
  --database tuning_lab
```

## 주요 옵션

| 옵션 | 내용 |
| --- | --- |
| `--sql SQL` | SQL 직접 입력 |
| `--file FILE` | SQL File 입력 |
| `--host HOST` | MySQL Host |
| `--port PORT` | MySQL Port |
| `--socket PATH` | Unix Socket |
| `--user USER` | MySQL User |
| `--database DB` | Default Database |
| `--login-path NAME` | `mysql_config_editor` Login Path 사용 |
| `--defaults-extra-file FILE` | 기존 Client Option File 사용 |
| `--no-password` | Password Prompt 생략 |
| `--format NAME` | `TRADITIONAL`, `TREE`, `JSON`, `ALL` 중 선택 |
| `--analyze-format NAME` | `TREE`(기본) / `JSON`(지원 버전의 JSON v2 필요) |
| `--analyze` | SELECT/TABLE 대상 `EXPLAIN ANALYZE` 수행 |
| `--analyze-dml` | 안전 문제로 차단. DML은 기본 `EXPLAIN`만 수행 |
| `--optimizer-trace` | Optimizer Trace 수집 |
| `--check-only` | 접속 / 기본 Capability 확인만 수행 |
| `--output DIR` | 결과 Directory 지정 |

Password Command Line Argument 미지원.

기본 실행 시 Password Prompt 후 Permission `600` 임시 Option File 사용 및 종료 시 삭제.

## 분석 흐름

```text
SQL 입력 / MySQL 접속
  ↓
EXPLAIN FORMAT 선택(명시적 옵션 또는 대화형 메뉴)
  ├─ TRADITIONAL
  ├─ TREE
  ├─ JSON
  └─ ALL
  ↓
내부 JSON Plan 기반 Object 식별(출력 형식과 독립)
  ↓
InnoDB Table / Index Statistics, Histogram 조회
  ↓
Performance Schema Index I/O 누적 통계 확인
  ↓
선택적 EXPLAIN ANALYZE (TREE 또는 JSON v2)
  ↓
동일 Connection ID → Performance Schema THREAD_ID 매핑
  ↓
동일 Thread의 Statement Event 조회(수집 활성화 시)
  ↓
Optimizer Trace(별도 동일 세션 흐름) 및 결과 저장
```

## MySQL Thread 기반 진단

- MySQL 클라이언트 접속 = Foreground Connection. `CONNECTION_ID()`와 `performance_schema.threads.PROCESSLIST_ID` 대응
- `performance_schema.threads.THREAD_ID`: Performance Schema 내부 Thread 식별자. Connection ID와 동일값으로 간주 금지
- `EXPLAIN ANALYZE` 실행과 `events_statements_history` 조회를 **한 mysql 접속 세션에서 수행**
- Thread Event 수집 비활성화 시 `NOT_COLLECTED`로 표시(임의 추정 금지)
- `table_io_waits_summary_by_index_usage`: 인스턴스 전체 Thread가 공유하는 누적 통계. 개별 SQL 실행량으로 귀속 금지
- Global Index I/O Delta 출력 중지. Thread 단위 Statement Event 중심 분석

## EXPLAIN FORMAT 선택

| 옵션 | Planned Plan | Actual Plan |
| --- | --- | --- |
| `--format TRADITIONAL` | Tabular | `--analyze-format TREE` 선택 가능 |
| `--format TREE` | Iterator Tree | `--analyze-format TREE` |
| `--format JSON` | JSON Plan | `--analyze-format JSON`(JSON v2 지원 시) |
| `--format ALL` | 3가지 전체 | Actual Plan 별도 지정 |

예:

```sh
sh explain.sh query.sql --format TREE --analyze --analyze-format TREE \
  --login-path local_mysql --database tuning_lab
```

```sh
sh explain.sh query.sql --format JSON --analyze --analyze-format JSON \
  --login-path local_mysql --database tuning_lab
```

- `EXPLAIN ANALYZE FORMAT=TRADITIONAL` 미지원
- `EXPLAIN ANALYZE FORMAT=JSON`: `explain_json_format_version=2` 설정 지원 환경만 가능
- 미지원 형식인 경우 임의 형식으로 대체하지 않고 오류 보고
- `EXPLAIN ANALYZE` 실제 SQL 실행. 운영 환경에서는 비용과 부하 검토 필요

## DML 안전 처리

- `EXPLAIN`: SELECT / INSERT / REPLACE / UPDATE / DELETE / TABLE의 비실행 예상 Plan 분석
- `EXPLAIN ANALYZE`: SELECT / TABLE 대상으로 자동 수행 허용
- MySQL의 DML `EXPLAIN ANALYZE` 지원 범위는 **Multi-table UPDATE / DELETE**에 한정. 단일 테이블 DML은 대상이 아님
- 단순 `START TRANSACTION → EXPLAIN ANALYZE → ROLLBACK`의 무조건적인 안전성 가정 금지
- `--analyze-dml` 옵션 차단. 향후 Storage Engine / Trigger / Side Effect 검증 후 별도 구현 필요

## Optimizer Trace

`--optimizer-trace` 사용 시 동일 Session에서 다음 흐름 수행.

```text
optimizer_trace = enabled
  ↓
EXPLAIN FORMAT=JSON
  ↓
INFORMATION_SCHEMA.OPTIMIZER_TRACE
  ↓
optimizer_trace = disabled
```

Optimizer Trace 활용 영역:

- Access Path 후보
- Range Optimizer 판단
- Cost 비교
- Join Order 검토
- Query Transformation
- Index 선택 / 미선택 근거

Optimizer Trace 내부 형식은 MySQL Version에 따라 변경 가능하므로 원본 Trace 보존 중심 구성.

## 출력 파일

| 파일 | 내용 |
| --- | --- |
| `summary.txt` | 실행 요약 |
| `precheck.txt` | Version / Server / Optimizer 기본 정보 |
| `explain_traditional.txt` | TRADITIONAL Plan (선택 시) |
| `explain.json` | JSON Plan 원본 (JSON/ALL 선택 시) |
| `explain_internal.json` | Object 진단용 내부 JSON Plan (TRADITIONAL/TREE 선택 시) |
| `explain_tree.txt` | TREE Plan (선택 시) |
| `explain_analyze.txt` | Actual Plan |
| `objects.txt` | JSON Plan에서 추출한 Table |
| `table_stats.txt` | Table / InnoDB Statistics |
| `index_definitions.txt` | Index 정의 / Cardinality |
| `column_histograms.txt` | Column Histogram |
| `index_io.txt` | 누적 Index I/O |
| `index_io_delta.txt` | 비수집 안내(전역 지표의 SQL별 귀속 오류 방지) |
| `analyze_session.txt` | 실제 ANALYZE Connection ID / P_S THREAD_ID |
| `thread_statement_event.txt` | 실제 ANALYZE의 동일 Thread Statement Event |
| `optimizer_trace.txt` | Optimizer Trace 및 실행계획 수집 원본 |
| `diagnostic_errors.txt` | Table/Index/Histogram 진단 SQL 오류(발생 시) |

## 현재 제한 사항

- JSON Plan의 `table_name` 기반 Table 식별(내부 JSON 형식·객체 종류별 정확성 추가 검증 필요)
- Cross-Schema SQL의 동일 Table Name 중복 식별 보강 필요
- CTE 선행 SQL의 Statement Type 상세 판별 보강 필요
- `?` Parameter Marker 기반 Prepared Statement 자동 Bind 미구현
- Estimated Rows ↔ Actual Rows 자동 오차율 계산 미구현
- Join Node별 Estimated / Actual 비교 자동화 미구현
- Version별 JSON Plan 구조 차이 추가 검증 필요
- Performance Schema Consumer/Instrument 수집 설정 의존
- MySQL 9.7.2에서 TRADITIONAL / TREE / JSON / ALL, ANALYZE TREE / JSON v2, 동일 Thread 이벤트, Optimizer Trace 및 JOIN SQL 검증 완료
- 다른 MySQL 버전에서 JSON Plan 구조 및 Analyzer 옵션 호환성 추가 검증 필요
- 운영 서버 실측 기반 성능 영향 검증 필요

## 실제 서버 검증

| 테스트 항목 | MySQL 9.7.2 결과 |
| --- | --- |
| Login Path 접속 / Precheck | 통과 |
| FORMAT=TRADITIONAL / TREE / JSON / ALL | 통과 |
| EXPLAIN ANALYZE FORMAT=TREE | 통과 |
| EXPLAIN ANALYZE FORMAT=JSON v2 | 통과 |
| CONNECTION_ID / THREAD_ID / Statement Event | 통과 |
| Table / InnoDB Statistics | 통과 |
| Index Definition / I/O | 통과(`IS_VISIBLE` 컬럼 사용) |
| Optimizer Trace | 통과 |
| 두 테이블 JOIN 자동 추출 | 통과 |
| DML ANALYZE 자동 실행 차단 | 통과 |
| Shell `sh -n` | 통과 |

- SELECT / JOIN 실습 쿼리만 실제 실행
- DML / DDL / Server 설정 변경 미수행
- `EXPLAIN`에서 Relation이 상수로 치환되면 JSON Plan에 Table Node가 없을 수 있으며, 이는 분석 오류와 구분
- Performance Schema의 Statement History Consumer가 비활성화된 환경에서는 Thread Event 누락 가능
- 인스턴스 전역 Index I/O 통계를 단일 SQL의 I/O로 해석하지 않음

## 공식 문서

- EXPLAIN  
  https://dev.mysql.com/doc/refman/9.7/en/explain.html
- Optimizing Queries with EXPLAIN  
  https://dev.mysql.com/doc/refman/9.7/en/using-explain.html
- Optimizer Trace  
  https://dev.mysql.com/doc/refman/9.7/en/optimizer-trace.html
- Optimizer Statistics / Histogram  
  https://dev.mysql.com/doc/refman/9.7/en/optimizer-statistics.html
- Performance Schema Thread Table  
  https://dev.mysql.com/doc/refman/9.7/en/performance-schema-threads-table.html
- Performance Schema Statement History  
  https://dev.mysql.com/doc/refman/9.7/en/performance-schema-events-statements-history-table.html
- Performance Schema Table I/O Summary  
  https://dev.mysql.com/doc/refman/9.7/en/performance-schema-table-wait-summary-tables.html
