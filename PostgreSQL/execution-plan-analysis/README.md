# PostgreSQL Execution Plan Analysis

PostgreSQL SQL 실행계획과 Planner 관련 정보를 한 번에 확인하기 위한 진단 스크립트입니다.

단순 `EXPLAIN` 출력뿐 아니라 실행계획에 실제로 사용된 Relation을 자동 추출하고, 해당 Table의 통계와 Column 통계, Extended Statistics, Index 구성과 Index 사용량까지 함께 확인합니다.

`EXPLAIN ANALYZE` 사용 시에는 실행 직전/직후의 Table 및 Index 누적 통계를 Snapshot으로 저장한 뒤 Delta를 계산해 이번 실행 구간에서 증가한 통계도 함께 출력합니다.

지원 범위: PostgreSQL 12 ~ 18

실행 파일:

```text
explain.sh
```

## 주요 목적

- SQL 실행계획 확인
- Planner Cost 및 설정값 확인
- 실행계획에 사용된 Table 자동 식별
- Table 통계 상태 확인
- Column Statistics 확인
- Extended Statistics 확인
- Index 구성 및 Index Column 확인
- Index 사용량 및 I/O 확인
- `EXPLAIN ANALYZE` 실행 구간의 Table/Index 통계 Delta 확인
- DML `EXPLAIN ANALYZE` 수행 시 데이터 변경 자동 Rollback
- Cardinality 추정 오류 및 Index 사용 여부 분석 보조

## 실행

```sh
sh explain.sh
```

또는 대상 SQL 파일을 인자로 전달할 수 있습니다.

```sh
sh explain.sh /path/to/test.sql
```

스크립트는 `/bin/sh` 기준으로 작성되어 있습니다.

## 접속 정보 확인

다음 환경변수를 우선 사용합니다.

```text
PSQL_BIN
PGHOST
PGPORT
PGUSER
PGDATABASE
PGDATA
PG_HOME
```

환경변수에서 확인할 수 없는 값만 실행 중 입력받습니다.

## EXPLAIN 옵션 선택

| 옵션 | 출력 내용 | 주의사항 |
| --- | --- | --- |
| ANALYZE | 실제 실행 결과, Actual Rows, Actual Time | SQL 실제 실행 발생 |
| VERBOSE | Output Column, Schema 등 상세 Plan 정보 | 출력량 증가 |
| COSTS | Startup Cost, Total Cost, Estimated Rows, Width | 기본 ON |
| SETTINGS | Planner에 영향을 준 비기본 설정 | 환경 차이 확인 |
| BUFFERS | Shared/Local/Temp Buffer hit/read/write | ANALYZE와 함께 사용 |
| WAL | WAL Record, FPI, Bytes | PostgreSQL 13+ |
| TIMING | Plan Node별 실제 수행시간 | ANALYZE 사용 시 측정 오버헤드 가능 |
| GENERIC_PLAN | Parameter 값과 무관한 Generic Plan | PostgreSQL 16+, ANALYZE와 동시 사용 불가 |
| SERIALIZE | 결과 직렬화 비용 | PostgreSQL 17+ |
| MEMORY | Planner Memory 사용량 | PostgreSQL 17+ |
| SUMMARY | Planning/Execution 요약 | Planning Time 등 확인 |
| FORMAT | TEXT / JSON / YAML / XML | 기본 TEXT |

`ANALYZE=yes` 선택 시 SQL이 실제로 실행되므로 `EXECUTE` 문자열을 추가로 입력해야 진행됩니다.

## DML 자동 Rollback

`ANALYZE=yes`일 때 비실행 JSON Plan의 `Operation`을 확인해 DML 여부를 판별합니다.

대상:

```text
INSERT
UPDATE
DELETE
MERGE
```

DML로 판별되면 다음 방식으로 실행합니다.

```text
BEGIN
  ↓
EXPLAIN ANALYZE DML
  ↓
ROLLBACK
```

즉 `UPDATE`, `DELETE`, `INSERT`, `MERGE`의 실제 실행계획과 Actual Rows/Time을 확인하되, Table Row 변경은 자동으로 Rollback합니다.

예:

```text
DML detected : Update
Execution    : BEGIN -> EXPLAIN ANALYZE -> ROLLBACK
DML safety   : BEGIN -> EXPLAIN ANALYZE -> ROLLBACK
```

단, Transaction Rollback으로 복구되지 않는 부수효과는 남을 수 있습니다.

```text
Sequence 증가
외부 시스템 호출 함수
Transaction 외부 Side Effect
일부 Extension/외부 함수 동작
```

따라서 DML에 대한 `EXPLAIN ANALYZE`는 자동 Rollback을 사용하더라도 운영 환경에서 주의가 필요합니다.

## 1. Execution Plan

선택한 EXPLAIN 옵션에 따라 실행계획을 출력합니다.

주요 확인 항목:

```text
Scan Type
Join Type
Join Order
Filter
Index Cond
Rows
Cost
Sort
Hash
Aggregate
Parallel Plan
Planning Time
Execution Time
Buffers
WAL
Memory
```

## 2. Table / Index Statistics Delta

`ANALYZE=yes`일 때만 출력합니다.

실행 순서:

```text
비실행 JSON Plan 생성
        ↓
Plan Base Relation 자동 추출
        ↓
Table / Index Before Snapshot
        ↓
EXPLAIN ANALYZE 실행
        ↓
DML이면 ROLLBACK
        ↓
Table / Index After Snapshot
        ↓
After - Before Delta 계산
```

### Table Statistics Delta

`pg_stat_all_tables` 기준으로 다음 항목의 Before / After / Delta를 출력합니다.

```text
seq_scan
seq_tup_read
idx_scan
idx_tup_fetch
n_tup_ins
n_tup_upd
n_tup_del
n_tup_hot_upd
```

### Index Statistics / I/O Delta

`pg_stat_all_indexes`, `pg_statio_all_indexes` 기준으로 다음 항목을 출력합니다.

```text
idx_scan
idx_tup_read
idx_tup_fetch
idx_blks_read
idx_blks_hit
```

### Delta 해석

Delta는 PostgreSQL 누적 통계를 실행 직전/직후에 조회해 계산한 값입니다.

동일 Relation을 다른 Session에서도 동시에 사용하면 다른 Session의 증가분이 일부 포함될 수 있습니다.

이번 SQL 자체의 Buffer 사용량은 `EXPLAIN (ANALYZE, BUFFERS)` 결과가 더 직접적인 기준이며, `pg_stat_*` Delta는 보조 진단값으로 사용합니다.

`ANALYZE=no`에서는 대상 SQL이 실제 실행되지 않으므로 의미 있는 실행 구간 Delta를 만들 수 없습니다. 이 경우 현재 누적 통계를 그대로 출력합니다.

DML을 Rollback하더라도 Scan/Index/I/O와 같은 실행 통계 카운터는 실제 실행으로 인해 증가할 수 있으므로 Delta 분석에 사용할 수 있습니다. 반면 DML 변경 Row 자체는 Rollback되므로 최종 데이터 변경량과 `n_tup_*` Delta를 동일한 의미로 해석하면 안 됩니다.

## 3. Planner Settings

실행계획 선택에 영향을 줄 수 있는 주요 Planner 설정값을 출력합니다.

### Cost 관련

```text
seq_page_cost
random_page_cost
cpu_tuple_cost
cpu_index_tuple_cost
cpu_operator_cost
```

### Memory / Cache 관련

```text
work_mem
effective_cache_size
default_statistics_target
effective_io_concurrency
```

### Parallel 관련

```text
max_parallel_workers
max_parallel_workers_per_gather
parallel_setup_cost
parallel_tuple_cost
```

### Scan 활성화 설정

```text
enable_seqscan
enable_indexscan
enable_indexonlyscan
enable_bitmapscan
enable_tidscan
```

### Join 활성화 설정

```text
enable_nestloop
enable_hashjoin
enable_mergejoin
```

### 기타 Planner 설정

```text
enable_sort
enable_incremental_sort
enable_hashagg
enable_material
enable_memoize
enable_partition_pruning
jit
plan_cache_mode
```

설정값과 함께 `source`도 출력합니다.

## 4. Referenced Relations

대상 SQL 문자열에서 Table명을 단순 파싱하지 않습니다.

`EXPLAIN (VERBOSE, COSTS FALSE, FORMAT JSON)` 결과의 `Schema`와 `Relation Name`을 기준으로 실제 Plan Base Relation을 자동 추출합니다.

예:

```text
Referenced Relations (Plan Base Relations)
public.pgbench_accounts
```

View가 Planner에서 펼쳐지는 경우 원본 SQL에 작성한 View명이 아니라 실제 하위 Relation이 표시될 수 있습니다.

따라서 이 목록은 원본 SQL에 작성한 Table 목록이 아니라 실제 실행계획에서 사용된 Base Relation 목록입니다.

## 5. Table Information

Plan에서 추출된 각 Relation에 대해 다음 정보를 출력합니다.

```text
Relation Name
Owner
Tablespace
Persistence
Relation Type
Estimated Rows
Relation Pages
All Visible Pages
Index 존재 여부
Row Level Security 여부
Force Row Level Security 여부
Replica Identity
Table Size
Indexes Size
Total Relation Size
```

## 6. Table Statistics

`pg_stat_all_tables` 기준 현재 누적 통계를 출력합니다.

```text
seq_scan
seq_tup_read
idx_scan
idx_tup_fetch
n_live_tup
n_dead_tup
n_mod_since_analyze
n_tup_ins
n_tup_upd
n_tup_del
n_tup_hot_upd
last_vacuum
last_autovacuum
last_analyze
last_autoanalyze
vacuum_count
autovacuum_count
analyze_count
autoanalyze_count
```

`ANALYZE=yes`에서는 현재 누적값과 별도로 실행 전/후 Delta도 출력합니다.

## 7. Column Information

```text
Column 순서
Column Name
Data Type
Nullable
Default Value
Identity 여부
Generated Column 여부
Statistics Target
```

## 8. Column Statistics

`pg_stats` 기준 Planner 통계를 출력합니다.

```text
null_frac
avg_width
n_distinct
most_common_vals
most_common_freqs
histogram_bounds
correlation
```

주요 활용:

- Estimated Rows와 Actual Rows 차이 분석
- 특정 값 분포 편향 확인
- Index Scan 미선택 원인 검토
- Join Cardinality 추정 오류 분석
- ANALYZE 필요 여부 검토

## 9. Extended Statistics

`pg_stats_ext` 기준으로 다중 Column Statistics를 확인합니다.

```text
Schema
Table
Statistics Name
대상 Column
Expression
Statistics 종류
n_distinct
Dependencies
```

Extended Statistics가 생성되지 않은 Table은 `0 rows`로 출력될 수 있습니다.

## 10. Index Information

```text
Index Name
Access Method
Unique 여부
Primary Key 여부
Exclusion Index 여부
Clustered 여부
Valid 여부
Ready 여부
Live 여부
Replica Identity 여부
Key Column 개수
INCLUDE Column 개수
Index Size
Partial Index 조건
Expression Index 식
Index Definition
```

## 11. Index Columns

Index를 구성하는 Column을 순서대로 출력합니다.

```text
Index Name
Column Position
KEY / INCLUDE 구분
Column 또는 Expression
Unique 여부
Primary Key 여부
```

다음 유형을 구분할 수 있습니다.

```text
일반 Index Key Column
복합 Index Column 순서
INCLUDE Column
Expression Index
Primary Key Index
Unique Index
```

## 12. Index Usage / I/O

`pg_stat_all_indexes`, `pg_statio_all_indexes`의 현재 누적값을 출력합니다.

```text
idx_scan
idx_tup_read
idx_tup_fetch
idx_blks_read
idx_blks_hit
cache_hit_pct
```

`ANALYZE=yes`에서는 누적값과 별도로 실행 구간 Delta도 함께 확인할 수 있습니다.

## 출력 순서

### ANALYZE = no

```text
PostgreSQL 연결
        ↓
대상 SQL 파일 선택
        ↓
PostgreSQL Version 확인
        ↓
EXPLAIN 옵션 선택
        ↓
비실행 JSON Plan 생성
        ↓
Plan Base Relation 자동 추출
        ↓
Execution Plan
        ↓
Planner Settings
        ↓
Table / Column / Statistics / Index 누적 정보
```

### ANALYZE = yes / SELECT 등 비 DML

```text
Plan Base Relation 자동 추출
        ↓
Before Snapshot
        ↓
EXPLAIN ANALYZE 실제 실행
        ↓
After Snapshot
        ↓
Table / Index Statistics Delta
        ↓
상세 진단
```

### ANALYZE = yes / DML

```text
Plan Base Relation 및 DML Operation 자동 확인
        ↓
Before Snapshot
        ↓
BEGIN
        ↓
EXPLAIN ANALYZE INSERT / UPDATE / DELETE / MERGE
        ↓
ROLLBACK
        ↓
After Snapshot
        ↓
Table / Index Statistics Delta
        ↓
상세 진단
```

여러 Table이 Plan에 포함된 경우 각 Relation별로 진단 항목을 반복 출력합니다.

## ANALYZE 사용 시 주의

```text
EXPLAIN
→ SQL을 실제 수행하지 않고 Planner의 예상 실행계획 확인

EXPLAIN ANALYZE SELECT
→ SELECT 실제 수행 후 Actual Rows / Actual Time 확인

EXPLAIN ANALYZE DML
→ DML 실제 수행 후 Actual Rows / Actual Time 확인
→ 스크립트에서 자동 BEGIN / ROLLBACK 적용
```

DML의 Table Row 변경은 자동 Rollback하지만, Sequence 증가나 외부 함수 호출 등 Transaction 외부 부수효과는 완전히 복구되지 않을 수 있습니다.

## 통계 해석 시 주의

`ANALYZE=no`에서 표시되는 `pg_stat_*` 값은 누적 통계입니다.

`ANALYZE=yes`에서는 실행 직전/직후 Snapshot을 이용해 Delta를 추가로 출력하지만, 해당 Relation에 대한 동시 Session의 활동이 섞일 수 있습니다.

따라서 다음 기준으로 해석합니다.

```text
Actual Rows / Actual Time
→ EXPLAIN ANALYZE

해당 실행의 Buffer 사용
→ EXPLAIN ANALYZE + BUFFERS

Table / Index 누적 상태
→ pg_stat_* 현재값

실행 구간 Table / Index 변화량
→ pg_stat_* Before / After Delta
```

또한 `reltuples`, `n_live_tup`, `n_dead_tup` 등은 정확한 실시간 Row Count가 아니라 통계 기반 추정값일 수 있습니다.
