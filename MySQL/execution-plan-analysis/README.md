# MySQL Execution Plan Analysis

MySQL SQL 실행계획, Optimizer 통계, Table·Index 상태 통합 분석 스크립트.

단순 `EXPLAIN` 출력뿐 아니라 JSON Plan 기반 Table 자동 식별, Table/Index 통계, Column Histogram, Index I/O, `EXPLAIN ANALYZE` 전후 Index I/O Delta, Optimizer Trace 수집 기능 포함.

> 현재 구현 버전: `v0.1.0`

실행 파일:

```text
explain.sh
```

별도 Python/Perl/Node.js 런타임이나 `jq`, `yq` 등 외부 JSON Parser 미사용.

## 분석 영역

- `EXPLAIN FORMAT=TRADITIONAL`
- `EXPLAIN FORMAT=JSON`
- `EXPLAIN FORMAT=TREE`
- `EXPLAIN ANALYZE`
- JSON Plan 기반 Base Table 자동 추출
- `INFORMATION_SCHEMA.TABLES` Table 상태
- `mysql.innodb_table_stats` InnoDB Persistent Statistics
- `INFORMATION_SCHEMA.STATISTICS` Index 정의 / Cardinality
- `INFORMATION_SCHEMA.COLUMN_STATISTICS` Column Histogram
- `performance_schema.table_io_waits_summary_by_index_usage` Index I/O
- `EXPLAIN ANALYZE` 전후 Index I/O Delta
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
  --login-path=local_mysql \
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
| `--analyze` | SELECT/TABLE 대상 `EXPLAIN ANALYZE` 수행 |
| `--analyze-dml` | UPDATE/DELETE 대상 Transaction + ROLLBACK 방식 분석 시도 |
| `--optimizer-trace` | Optimizer Trace 수집 |
| `--check-only` | 접속 / 기본 Capability 확인만 수행 |
| `--output DIR` | 결과 Directory 지정 |

Password Command Line Argument 미지원.

기본 실행 시 Password Prompt 후 Permission `600` 임시 Option File 사용 및 종료 시 삭제.

## 기본 분석 흐름

```text
SQL 입력
  ↓
Connection / Version / Performance Schema Precheck
  ↓
EXPLAIN TRADITIONAL
  ↓
EXPLAIN JSON
  ↓
EXPLAIN TREE
  ↓
JSON Plan의 table_name 기반 Base Table 추출
  ↓
Table / InnoDB Statistics
  ↓
Index Definition / Cardinality
  ↓
Column Histogram
  ↓
Index I/O
  ↓
EXPLAIN ANALYZE 선택 수행
  ↓
Index I/O Snapshot 전후 Delta
  ↓
Optimizer Trace 선택 수집
  ↓
결과 Directory 생성
```

## EXPLAIN ANALYZE 안전 처리

`EXPLAIN ANALYZE`는 실제 Statement 실행 발생.

기본 `--analyze` 허용 대상:

```text
SELECT
TABLE
```

UPDATE / DELETE:

```text
--analyze-dml
  ↓
START TRANSACTION
  ↓
EXPLAIN ANALYZE
  ↓
ROLLBACK
```

주의 사항:

- MySQL 공식 지원 범위상 `EXPLAIN ANALYZE`의 DML 지원 형태 제한 가능성
- Trigger, UDF, Non-transactional Engine 등 Transaction Rollback만으로 모든 외부 Side Effect를 되돌릴 수 없는 구조 존재 가능
- 운영 환경 DML 분석 전 별도 검토 필요
- INSERT / REPLACE의 `EXPLAIN ANALYZE` 자동 수행 미지원
- `ANALYZE TABLE` 자동 수행 미지원

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
| `explain_traditional.txt` | TRADITIONAL Plan |
| `explain.json` | JSON Plan 원본 |
| `explain_tree.txt` | TREE Plan |
| `explain_analyze.txt` | Actual Plan |
| `objects.txt` | JSON Plan에서 추출한 Table |
| `table_stats.txt` | Table / InnoDB Statistics |
| `index_definitions.txt` | Index 정의 / Cardinality |
| `column_histograms.txt` | Column Histogram |
| `index_io.txt` | 누적 Index I/O |
| `index_io_delta.txt` | ANALYZE 전후 Index I/O Delta |
| `optimizer_trace.txt` | Optimizer Trace |

## 현재 제한 사항

- JSON Plan의 `table_name` 기반 Table 식별
- Cross-Schema SQL의 동일 Table Name 중복 식별 보강 필요
- CTE 선행 SQL의 Statement Type 상세 판별 보강 필요
- `?` Parameter Marker 기반 Prepared Statement 자동 Bind 미구현
- Estimated Rows ↔ Actual Rows 자동 오차율 계산 미구현
- Join Node별 Estimated / Actual 비교 자동화 미구현
- Version별 JSON Plan 구조 차이 추가 검증 필요
- 운영 서버 실측 기반 성능 영향 검증 필요

## 공식 문서

- EXPLAIN  
  https://dev.mysql.com/doc/refman/9.7/en/explain.html
- Optimizing Queries with EXPLAIN  
  https://dev.mysql.com/doc/refman/9.7/en/using-explain.html
- Optimizer Trace  
  https://dev.mysql.com/doc/refman/9.7/en/optimizer-trace.html
- Optimizer Statistics / Histogram  
  https://dev.mysql.com/doc/refman/9.7/en/optimizer-statistics.html
- Performance Schema Table I/O Summary  
  https://dev.mysql.com/doc/refman/9.7/en/performance-schema-table-wait-summary-tables.html
