# PostgreSQL Execution Plan Analysis

PostgreSQL SQL 실행계획과 Planner 관련 정보를 한 번에 확인하기 위한 진단 스크립트입니다.

단순 `EXPLAIN` 출력뿐 아니라 실행계획에 실제로 사용된 Relation을 자동으로 추출하고, 해당 Table의 통계와 Column 통계, Extended Statistics, Index 구성과 Index 사용량까지 함께 확인합니다.

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

출력 예시:

```text
Connection
  psql     : /home/pg17/pgsql/bin/psql
  host     : default/local socket
  port     : 51700
  user     : pg17
  database : postgres
```

## EXPLAIN 옵션 선택

실행 시 PostgreSQL 버전을 확인한 뒤 해당 버전에서 사용 가능한 옵션만 선택할 수 있도록 구성되어 있습니다.

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

`ANALYZE` 선택 시 SQL이 실제로 실행되므로 추가 확인 후 수행합니다.

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

예:

```text
Update on public.pgbench_accounts
  -> Seq Scan on public.pgbench_accounts
       Filter: (aid >= 999009)
```

## 2. Planner Settings

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

설정값과 함께 PostgreSQL이 해당 값을 어디에서 읽었는지 확인할 수 있도록 `source`도 출력합니다.

예:

```text
name                    setting    source
random_page_cost        4          default
work_mem                4096       default
plan_cache_mode         auto       default
```

## 3. Referenced Relations

대상 SQL 문자열에서 Table명을 단순 파싱하지 않습니다.

추가 `EXPLAIN (FORMAT JSON)` 결과의 `Schema`와 `Relation Name`을 기준으로 실제 Plan Base Relation을 자동 추출합니다.

예:

```text
Referenced Relations (Plan Base Relations)
public.pgbench_accounts
```

### View 사용 시

View가 Planner에서 펼쳐지는 경우 원본 SQL에 작성한 View명이 아니라 실제 하위 Relation이 표시될 수 있습니다.

예를 들어 `pg_stat_activity` 같은 시스템 View를 조회하면 다음과 같은 객체가 Plan에 나타날 수 있습니다.

```text
pg_catalog.pg_database
pg_catalog.pg_authid
pg_stat_get_activity()
```

따라서 이 목록은 **원본 SQL에 작성한 Table 목록이 아니라 실제 실행계획에서 사용된 Base Relation 목록**입니다.

## 4. Table Information

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

주요 컬럼:

```text
relation
owner
tablespace
relpersistence
relkind
reltuples
relpages
relallvisible
relhasindex
relrowsecurity
relforcerowsecurity
replica_identity
table_size
indexes_size
total_size
```

`reltuples`, `relpages`는 Planner가 사용하는 추정 통계 확인에 사용합니다.

## 5. Table Statistics

`pg_stat_all_tables` 기준으로 Table의 누적 접근 및 변경 통계를 출력합니다.

```text
Sequential Scan 횟수
Sequential Scan에서 읽은 Tuple 수
Index Scan 횟수
Index Scan을 통해 Fetch한 Tuple 수
Live Tuple
Dead Tuple
Analyze 이후 변경 Tuple 수
INSERT 수
UPDATE 수
DELETE 수
HOT Update 수
마지막 VACUUM 시각
마지막 Auto Vacuum 시각
마지막 ANALYZE 시각
마지막 Auto Analyze 시각
VACUUM 횟수
Auto Vacuum 횟수
ANALYZE 횟수
Auto Analyze 횟수
```

주요 컬럼:

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

## 6. Column Information

대상 Table의 Column 구조를 출력합니다.

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

주요 컬럼:

```text
no
column_name
data_type
nullable
default_value
identity
generated
statistics_target
```

## 7. Column Statistics

`pg_stats` 기준으로 Planner의 Column 통계를 출력합니다.

```text
Null 비율
평균 Column Width
Distinct 추정값
Most Common Values
Most Common Frequencies
Histogram Bounds
Correlation
```

주요 컬럼:

```text
null_frac
avg_width
n_distinct
most_common_vals
most_common_freqs
histogram_bounds
correlation
```

### 주요 활용

- Estimated Rows와 Actual Rows 차이 분석
- 특정 값 분포 편향 확인
- Index Scan 미선택 원인 검토
- Join Cardinality 추정 오류 분석
- ANALYZE 필요 여부 검토

## 8. Extended Statistics

`pg_stats_ext` 기준으로 다중 Column Statistics를 확인합니다.

출력 항목:

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

주요 활용:

- 여러 WHERE 조건 Column 사이의 상관관계
- 다중 Column Distinct 값 추정
- 독립성 가정으로 인한 Cardinality 오류 확인

Extended Statistics가 생성되지 않은 Table은 `0 rows`로 출력될 수 있습니다.

## 9. Index Information

대상 Table에 생성된 Index의 상세 정보를 출력합니다.

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

주요 컬럼:

```text
index_name
method
unique
primary_key
exclusion
clustered
valid
ready
live
replica_identity
key_columns
include_columns
index_size
predicate
expressions
definition
```

Access Method 예:

```text
btree
hash
gin
gist
spgist
brin
```

## 10. Index Columns

Oracle의 Index Column 조회와 유사한 목적으로 Index를 구성하는 Column을 순서대로 출력합니다.

```text
Index Name
Column Position
KEY / INCLUDE 구분
Column 또는 Expression
Unique 여부
Primary Key 여부
```

예:

```text
index_name               position  column_type  column_or_expression
pgbench_accounts_pkey    1         KEY          aid
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

## 11. Index Usage / I/O

`pg_stat_all_indexes`, `pg_statio_all_indexes`를 이용해 Index 누적 사용량과 Block I/O를 출력합니다.

```text
Index Scan 횟수
Index Entry Read 수
Table Tuple Fetch 수
Index Block Physical Read
Index Block Cache Hit
Index Cache Hit %
```

주요 컬럼:

```text
idx_scan
idx_tup_read
idx_tup_fetch
idx_blks_read
idx_blks_hit
cache_hit_pct
```

예:

```text
index_name               idx_scan  idx_blks_read  idx_blks_hit  cache_hit_pct
pgbench_accounts_pkey    10        30165          410900        93.16
```

## 출력 순서

전체 실행 흐름은 다음과 같습니다.

```text
PostgreSQL 연결
        ↓
대상 SQL 파일 선택
        ↓
PostgreSQL Version 확인
        ↓
EXPLAIN 옵션 선택
        ↓
Execution Plan
        ↓
Planner Settings
        ↓
Referenced Relations 자동 추출
        ↓
Table Information
        ↓
Table Statistics
        ↓
Column Information
        ↓
Column Statistics
        ↓
Extended Statistics
        ↓
Index Information
        ↓
Index Columns
        ↓
Index Usage / I/O
```

여러 Table이 Plan에 포함된 경우 각 Relation별로 위 진단 항목을 반복 출력합니다.

## ANALYZE 사용 시 주의

`EXPLAIN`과 `EXPLAIN ANALYZE`는 동작이 다릅니다.

```text
EXPLAIN
→ SQL을 실제 수행하지 않고 Planner의 예상 실행계획 확인

EXPLAIN ANALYZE
→ SQL 실제 수행 후 Actual Rows / Actual Time 확인
```

특히 다음 SQL에 `ANALYZE`를 사용할 경우 실제 변경이 발생할 수 있습니다.

```text
INSERT
UPDATE
DELETE
MERGE
```

스크립트는 `ANALYZE=yes` 선택 시 `EXECUTE` 문자열을 추가로 입력해야 진행되도록 구성되어 있습니다.

Transaction으로 감싸더라도 Sequence 증가, 외부 함수 호출 등 Transaction 외부 부수효과는 완전히 복구되지 않을 수 있으므로 운영 환경에서 주의가 필요합니다.

## 통계 해석 시 주의

다음 값은 대부분 누적 통계이므로 특정 SQL 한 번의 결과로 해석하면 안 됩니다.

```text
seq_scan
idx_scan
n_tup_ins
n_tup_upd
n_tup_del
idx_blks_read
idx_blks_hit
```

또한 `reltuples`, `n_live_tup`, `n_dead_tup` 등은 정확한 실시간 Row Count가 아니라 통계 기반 추정값일 수 있습니다.

## 분석 예시

실행계획에서 다음과 같이 대량 Seq Scan이 확인된 경우:

```text
Seq Scan on public.pgbench_accounts
  Filter: (aid >= 999009)
```

함께 출력되는 정보를 기준으로 다음 항목을 확인할 수 있습니다.

```text
1. Table 전체 크기
2. Planner 예상 Row 수
3. Column의 n_distinct / Histogram
4. 해당 조건 Column의 Index 존재 여부
5. 복합 Index의 Column 순서
6. Index 사용 횟수
7. random_page_cost / seq_page_cost
8. effective_cache_size
9. Statistics 최신 여부
```

따라서 단순히 `Seq Scan이므로 Index 필요`라고 판단하는 대신 Planner 통계와 Table 크기, 조건 선택도, Index 구성까지 함께 확인하는 용도로 사용합니다.
