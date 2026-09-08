# PostgreSQL Execution Plan Analysis

PostgreSQL SQL 실행계획과 Planner 관련 정보를 한 번에 확인하기 위한 진단 스크립트.

단순 `EXPLAIN` 출력뿐 아니라 실행계획에 포함된 Relation 자동 식별, Table/Column 통계, Extended Statistics, Index 구성과 사용량, `EXPLAIN ANALYZE` 실행 전후 누적 통계 Delta 확인 기능 포함.

지원 범위: PostgreSQL 12 ~ 18

현재 스크립트 버전: `v1.1.9`

실행 파일:

```text
explain.sh
plan_tree.py
```

`plan_tree.py`는 `explain.sh`와 동일 디렉터리 배치 필요.

## v1.1.9 핵심 변경 사항

- Tree 원천의 PostgreSQL `FORMAT JSON` 전환
- TEXT 들여쓰기 역파싱 제거
- PostgreSQL JSON `Plan -> Plans[]` 구조만을 이용한 Parent/Child Tree 생성
- `Node Type`별 의미 추정 로직 미사용
- PostgreSQL이 반환한 Node 속성 Key/Value의 원문 출력
- 알 수 없는 신규 Node Type/속성의 임의 분류 금지
- JSON 구조 검증 실패 시 Tree 생성 중단
- `EXPLAIN ANALYZE` 실제 실행 횟수 1회 보장
- Actual Raw JSON 원본 항상 보존
- TEXT/YAML/XML 요청 시 비실행 Planned Raw Plan 별도 출력
- Bind SQL의 `PREPARE -> EXECUTE` 흐름 유지
- Bind Plan Mode `AUTO / CUSTOM / GENERIC` 선택 지원
- 모든 `ANALYZE=yes` 실행의 `BEGIN -> EXPLAIN ANALYZE -> ROLLBACK` 적용
- `yes/no` 대소문자 미구분 및 잘못된 입력 재요청
- Python 3 기반 JSON Parser 자체 Structural Self-test 수행

## 정확성 원칙

### 1. PostgreSQL 공식 구조만 사용

Tree Renderer의 구조 판단 기준:

```text
PostgreSQL EXPLAIN FORMAT JSON
        ↓
Top-level array
        ↓
Plan
        ↓
Plans[]
        ↓
Child Plan Node
```

Tree Parent/Child 관계는 오직 PostgreSQL이 반환한 `Plans` 배열 기준 처리.

다음과 같은 주관적 규칙 미사용:

```text
Node Type 이름을 보고 Parent 추정
TEXT 공백 수를 보고 Parent 추정
특정 Scan/Join 이름을 하드코딩하여 구조 생성
현재 테스트 SQL 형태에 맞춘 예외 처리
없는 속성의 의미 추정
```

Node에 존재하는 `Node Type` 외 속성은 PostgreSQL JSON Key 이름과 값을 그대로 출력.

예:

```text
Node Type: Nested Loop
├─ Node Type: Seq Scan
│  · Parent Relationship: "Outer"
└─ Node Type: Index Scan
   · Parent Relationship: "Inner"
   · Index Name: "example_pkey"
```

`Parent Relationship`, `Subplan Name`, `CTE Name`, `Workers`, `Actual Rows`, `Actual Loops`, `Index Cond`, `Hash Cond` 등은 해당 JSON 필드가 실제 존재할 때만 표시.

### 2. 신규/알 수 없는 Node Type 대응

Tree Parser는 Node Type 이름으로 분기하지 않음.

따라서 PostgreSQL이 새로운 Node Type을 추가하더라도 다음 조건만 충족하면 동일 방식의 구조 처리 가능.

```text
Node = JSON Object
Node Type = String
Child = Plans Array
```

알 수 없는 속성도 삭제하거나 의미를 변경하지 않고 JSON Key/Value 그대로 출력.

### 3. 구조 검증 실패 시 추정 금지

다음 경우 Tree 생성 실패 처리.

```text
Top-level JSON 형식 오류
Plan Object 부재
Node Type 부재/비문자열
Plans가 Array가 아닌 경우
JSON Decode 실패
```

실패 시 임의 Tree 생성 금지.

Actual/Planned Raw JSON은 PostgreSQL 원본 확인 기준.

## 공식 문서 기준

주요 참고 문서:

- PostgreSQL 18 `EXPLAIN`: https://www.postgresql.org/docs/18/sql-explain.html
- PostgreSQL 18 `Using EXPLAIN`: https://www.postgresql.org/docs/18/using-explain.html
- PostgreSQL 18 `PREPARE`: https://www.postgresql.org/docs/18/sql-prepare.html
- PostgreSQL 18 `Query Planning`: https://www.postgresql.org/docs/18/runtime-config-query.html
- PostgreSQL 17 `EXPLAIN`: https://www.postgresql.org/docs/17/sql-explain.html
- PostgreSQL 16 `EXPLAIN`: https://www.postgresql.org/docs/16/sql-explain.html
- PostgreSQL 12 `EXPLAIN`: https://www.postgresql.org/docs/12/sql-explain.html

공식 문서 기준 적용 사항:

- Query Plan의 Plan Node Tree 구조
- 프로그램 분석 목적의 JSON/XML/YAML 등 Machine-readable Format 사용
- `ANALYZE` 선택 시 대상 Statement 실제 실행
- Data-modifying Statement 분석 시 Transaction Rollback 활용
- Prepared Statement의 Custom/Generic Plan 동작
- `plan_cache_mode = auto / force_custom_plan / force_generic_plan`
- Version별 EXPLAIN Option 지원 여부

## 실행 요구 사항

### Shell

```text
/bin/sh
```

### Python

Tree Parsing을 위한 Python 3 필요.

자동 탐지 순서:

```text
PYTHON3_BIN 환경변수
python3
/usr/libexec/platform-python
python 명령이 Python 3인 경우
```

Python 3 미탐지 시 Tree 정확성을 낮추는 TEXT fallback을 사용하지 않고 실행 중단.

목적:

```text
정확하지 않은 Tree 출력 방지
```

## 실행

```sh
sh explain.sh
```

또는:

```sh
sh explain.sh /path/to/test.sql
```

## Yes / No 입력 처리

대소문자 미구분.

```text
yes
YES
Yes
yEs

no
NO
No
```

잘못된 입력 시 종료하지 않고 동일 질문 재요청.

```text
Use ANALYZE? yes/no [no]: yse
ERROR: enter yes or no. Please retry.
Use ANALYZE? yes/no [no]: YES
```

## 접속 정보

우선 사용 환경변수:

```text
PSQL_BIN
PYTHON3_BIN
PGHOST
PGPORT
PGUSER
PGDATABASE
PGDATA
PG_HOME
```

확인 불가 값만 실행 중 입력.

## Bind Parameter 처리

기존 `$1`, `$2`, ... Bind 지원 유지.

처리 흐름:

```text
SQL File
   ↓
PREPARE pg_explain_target
   ↓
Parameter Type 확인
   ↓
Bind 후보/기본값 확인
   ↓
사용자 Bind 값 입력
   ↓
EXECUTE pg_explain_target(...)
   ↓
EXPLAIN (... FORMAT JSON) EXECUTE ...
```

사용된 Bind 값은 결과 파일의 `Bind Values Used`에 기록.

### Prepared Plan Mode

Bind SQL에서는 다음 선택 지원.

```text
AUTO
CUSTOM
GENERIC
```

매핑:

```text
AUTO    -> plan_cache_mode = auto
CUSTOM  -> plan_cache_mode = force_custom_plan
GENERIC -> plan_cache_mode = force_generic_plan
```

입력값 대소문자 미구분 및 잘못된 값 재요청.

### AUTO Mode 주의

스크립트는 각 EXPLAIN 작업마다 새로운 PostgreSQL Session에서 Prepared Statement 생성.

따라서 `AUTO`는 해당 새 Session의 Prepared Statement 실행 이력 기준 동작.

장기간 유지된 Application Session에서 이미 누적된 Prepared Statement 실행 횟수와 Generic/Custom Plan 선택 이력을 재현하지 않음.

장기 Session의 실제 Cache History 재현이 필요한 경우 Application Session 자체의 실행환경 확인 필요.

Custom/Generic 비교 목적에서는 `CUSTOM`, `GENERIC` 명시 선택 가능.

## 다양한 Plan 구조 처리

Parser는 다음 Node 이름을 특별 취급하지 않음.

따라서 아래 구조 모두 동일한 `Plans[]` 재귀 처리 방식 적용.

```text
Seq Scan
Index Scan
Index Only Scan
Bitmap Heap Scan
Bitmap Index Scan
BitmapAnd / BitmapOr
Nested Loop
Hash Join
Merge Join
Hash
Sort / Incremental Sort
Aggregate
Group
WindowAgg
Unique
SetOp
Append / Merge Append
Result
Limit
Materialize
Memoize
Gather / Gather Merge
Parallel Scan 계열
CTE Scan
Subquery Scan
Function Scan
Values Scan
ModifyTable
Partition 관련 Plan
SubPlan / InitPlan 관련 Child Plan
기타 PostgreSQL이 반환하는 Node Type
```

위 목록은 지원 Node Type을 하드코딩한 목록이 아니라 대표적인 검증 대상 예시.

실제 Parser 동작은 모든 Node에 동일하게 `Node Type + Plans[] + 나머지 JSON 속성` 규칙 적용.

## plan_tree.py Structural Self-test

스크립트 시작 시 다음 실행.

```sh
python3 plan_tree.py self-test
```

Structural fixture 검증 대상:

```text
단일 Scan
Nested Loop + Outer/Inner Child
Hash Join + Hash Child
Bitmap Tree
Append Multiple Child
ModifyTable
SubPlan 형태
InitPlan/CTE 형태
Parallel Worker 속성
Memoize
알 수 없는 미래 Node/속성
Quoted Relation Identifier
```

Self-test 목적:

```text
Parser 기본 재귀 구조 및 Format 검증
```

실제 PostgreSQL Server별 Planner 결과 전체를 대체하는 통합 테스트가 아님.

## EXPLAIN 옵션

| 옵션 | 내용 | Version/주의 |
| --- | --- | --- |
| ANALYZE | 실제 실행 + Actual 통계 | 대상 Statement 실제 실행 |
| VERBOSE | 상세 Plan 정보 | TRUE/FALSE 명시 |
| COSTS | Cost/Estimated Rows/Width | TRUE/FALSE 명시 |
| SETTINGS | 비기본 설정 | TRUE/FALSE 명시 |
| BUFFERS | Buffer 사용량 | ANALYZE 시 TRUE/FALSE 명시 |
| WAL | WAL 통계 | PostgreSQL 13+ |
| TIMING | Node별 Timing | ANALYZE 시 TRUE/FALSE 명시 |
| GENERIC_PLAN | Parameter 독립 Generic Plan | PostgreSQL 16+, Non-Bind EXPLAIN용 |
| SERIALIZE | 결과 직렬화 비용 | PostgreSQL 17+ |
| MEMORY | Planner Memory | PostgreSQL 17+ |
| SUMMARY | Planning/Execution Summary | TRUE/FALSE 명시 |
| RAW FORMAT | TEXT/JSON/YAML/XML | 기본 TEXT |

Version 미지원 옵션의 출력 금지.

## ANALYZE 실행 안전성

`ANALYZE=yes`인 모든 지원 Statement에 다음 Wrapper 적용.

```text
BEGIN
  ↓
EXPLAIN (ANALYZE TRUE, ..., FORMAT JSON)
  ↓
ROLLBACK
```

특정 SQL 문자열을 직접 파싱하여 DML 여부를 추정한 뒤 Wrapper 적용 여부를 결정하지 않음.

목적:

```text
INSERT/UPDATE/DELETE/MERGE 외 실행 가능한 EXPLAIN ANALYZE Statement 고려
주관적 SQL 분류 최소화
Transaction 범위 내 Side Effect 복구
```

주의:

```text
Sequence 증가
외부 시스템 호출 함수
Transaction 외부 Side Effect
일부 Extension/외부 함수 동작
```

위 항목은 ROLLBACK으로 복구되지 않을 수 있음.

`ANALYZE=yes` 시 추가로 `EXECUTE` 문자열 입력 필요.

## Actual Plan 실행 횟수

Tree 출력을 위한 `EXPLAIN ANALYZE` 재실행 없음.

```text
EXPLAIN ANALYZE FORMAT JSON
        ↓
실제 Statement 실행 1회
        ↓
JSON Raw 저장
        ├─ Tree 생성
        └─ Actual Raw JSON 출력
```

Tree 생성은 저장된 JSON 파일만 읽는 과정.

## Raw Plan 보존 정책

### ANALYZE = yes

실제로 실행된 Plan의 원본:

```text
Execution Plan Raw (JSON / Actual)
```

해당 JSON이 Actual Rows/Time/Loops/Buffer 등 실제 실행정보의 기준.

사용자가 RAW FORMAT으로 TEXT/YAML/XML 선택 시 추가 출력:

```text
Execution Plan Raw (TEXT / Planned Only)
Execution Plan Raw (YAML / Planned Only)
Execution Plan Raw (XML / Planned Only)
```

이 추가 Raw Plan은 `ANALYZE` 없이 생성.

따라서 Statement 재실행 없음.

`ANALYZE=yes`일 때 Planned Raw와 Actual Raw의 혼동 방지를 위한 안내문 출력.

### ANALYZE = no

JSON Planned Plan 기준 Tree 생성 및 Raw JSON 보존.

TEXT/YAML/XML 요청 시 동일 Statement의 비실행 Planned Raw 추가 출력.

## Tree 출력

예시:

```text
Node Type: Nested Loop
· Join Type: "Left"
· Startup Cost: 4.38
· Total Cost: 6.61
· Plan Rows: 1
· Plan Width: 360
└─ Node Type: Index Scan
   · Parent Relationship: "Inner"
   · Schema: "public"
   · Relation Name: "orders"
   · Index Name: "orders_pkey"
```

`ANALYZE=yes`인 경우 PostgreSQL JSON에 존재하는 Actual 필드도 그대로 출력.

```text
· Actual Startup Time: 0.015
· Actual Total Time: 0.020
· Actual Rows: 1
· Actual Loops: 10
```

Tree Renderer에서 다음과 같은 해석 문구 생성 금지.

```text
GOOD PLAN
BAD PLAN
INDEX SHOULD BE USED
HASH JOIN SHOULD BE USED
NEVER EXECUTED BECAUSE ...
CARDINALITY ERROR
```

해석은 별도 분석 단계에서 Raw 수치와 공식 의미를 기반으로 수행.

## Relation 자동 추출

SQL 문자열에서 Table명 직접 파싱하지 않음.

PostgreSQL JSON Node의 다음 필드만 사용.

```text
Schema
Relation Name
```

Quoted/Mixed-case Identifier 고려.

추출 Relation 기준 후속 진단 수행.

## Table / Index Statistics Delta

`ANALYZE=yes`일 때 실행 전/후 `pg_stat_*` Snapshot 비교.

### Table

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

### Index

```text
idx_scan
idx_tup_read
idx_tup_fetch
idx_blks_read
idx_blks_hit
```

Delta는 누적 통계 Before/After 차이.

동일 Relation을 사용하는 다른 Session의 활동이 포함될 수 있음.

해당 SQL 자체의 I/O는 `EXPLAIN (ANALYZE, BUFFERS)`가 더 직접적인 기준.

## 추가 진단

Plan Relation별 다음 정보 출력.

### Planner Settings

```text
seq_page_cost
random_page_cost
cpu_tuple_cost
cpu_index_tuple_cost
cpu_operator_cost
effective_cache_size
work_mem
default_statistics_target
effective_io_concurrency
max_parallel_workers
max_parallel_workers_per_gather
parallel_setup_cost
parallel_tuple_cost
enable_seqscan
enable_indexscan
enable_indexonlyscan
enable_bitmapscan
enable_tidscan
enable_sort
enable_incremental_sort
enable_hashagg
enable_material
enable_memoize
enable_nestloop
enable_hashjoin
enable_mergejoin
enable_partition_pruning
jit
plan_cache_mode
```

### Table Information

```text
Owner
Tablespace
Persistence
Relation Type
Estimated Rows
Relation Pages
All Visible Pages
Index 존재 여부
Row Level Security
Replica Identity
Table/Index/Total Size
```

### Table Statistics

`pg_stat_all_tables` 기준 누적 통계.

### Column Information

Column Type/Nullable/Default/Identity/Generated/Statistics Target 확인.

### Column Statistics

`pg_stats` 기준:

```text
null_frac
avg_width
n_distinct
most_common_vals
most_common_freqs
histogram_bounds
correlation
```

Relation 문자열 단순 `split_part()` 대신 `regclass -> pg_class -> pg_namespace` 해석 적용으로 Quoted Identifier 대응 보강.

### Extended Statistics

`pg_stats_ext` 기준 출력.

### Index Information / Columns / I/O

`pg_index`, `pg_stat_all_indexes`, `pg_statio_all_indexes` 기준 출력.

## 출력 흐름

### ANALYZE = no

```text
Connection
   ↓
SQL / Bind 입력
   ↓
EXPLAIN Option 입력
   ↓
PostgreSQL Planned JSON Precheck
   ↓
Relation 추출
   ↓
PostgreSQL Planned JSON
   ↓
JSON Plans[] 기반 Tree
   ↓
Raw JSON / Planned
   ↓
Requested Raw Format / Planned
   ↓
Additional Diagnostics
```

### ANALYZE = yes

```text
Connection
   ↓
SQL / Bind 입력
   ↓
EXPLAIN Option 입력
   ↓
PostgreSQL Planned JSON Precheck
   ↓
Relation 추출
   ↓
Before Snapshot
   ↓
BEGIN
   ↓
EXPLAIN ANALYZE FORMAT JSON
   ↓
ROLLBACK
   ↓
Actual JSON Plans[] 기반 Tree
   ↓
Raw JSON / Actual
   ↓
Requested Raw Format / Planned Only
   ↓
After Snapshot
   ↓
Table / Index Delta
   ↓
Additional Diagnostics
```

## 정확성 범위 및 한계

보장 대상:

```text
PostgreSQL이 반환한 JSON Plan/Plans Parent-Child 구조의 그대로 반영
Node 속성 Key/Value의 변경 없는 표시
Bind 값 기반 EXECUTE Plan 사용
Actual Plan의 단일 실행
Raw Actual JSON 보존
지원 Version별 옵션 분기
```

의도적으로 수행하지 않는 항목:

```text
Planner가 왜 해당 Plan을 선택했는지 자동 추정
Plan의 좋음/나쁨 자동 판정
없는 필드의 의미 추정
Application 장기 Prepared Plan Cache History 재현
TEXT Plan을 역파싱하여 구조 추정
```

운영 환경에서는 PostgreSQL Server Version, 실제 Session 설정, 통계 변경, Concurrent Activity에 따라 Plan 및 누적 통계 값 변동 가능.

## 버전 이력

### v1.1.9

- Tree Source의 PostgreSQL `FORMAT JSON` 전환
- `Plans[]` 기반 구조 재귀 처리
- `plan_tree.py` 추가
- Unknown Node/Property 보존
- Bind `AUTO/CUSTOM/GENERIC` Mode 추가
- Actual Raw JSON 보존
- TEXT/YAML/XML Planned-only Raw 구분
- 모든 ANALYZE 실행 Transaction Wrapper 적용
- Boolean EXPLAIN Option의 TRUE/FALSE 명시
- Quoted Relation 진단 보강

### v1.1.8

- TEXT Plan Structural Tree 강화
- InitPlan/SubPlan/CTE 구조 보존 시도
- 구조 불명확 시 Fail-safe 처리

### v1.1.7

- TEXT Plan Simplified Tree 최초 추가
- yes/no 대소문자 미구분 및 재입력 처리

이전 기능의 Bind 후보, Bind 기본값, Bind 사용값 기록, Column Statistics Summary, Partition 진단 제한, Table/Index Delta 기능 유지.
