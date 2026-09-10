# PostgreSQL Execution Plan Analysis

PostgreSQL SQL 실행계획과 Planner 관련 정보를 한 번에 확인하기 위한 진단 스크립트.

단순 `EXPLAIN` 출력뿐 아니라 실행계획에 포함된 Relation 자동 식별, Table/Column 통계, Extended Statistics, Index 구성과 사용량, `EXPLAIN ANALYZE` 실행 전후 누적 통계 Delta 확인 기능 포함.

지원 범위: PostgreSQL 12 ~ 18

현재 스크립트 버전: `v1.2.25`

실행 파일:

```text
explain.sh
```

별도 Python/Perl/Node.js 런타임이나 `jq`, `yq`, pip 패키지 등 외부 패키지는 사용하지 않음.

## 핵심 구현 원칙

- `/bin/sh` 기준 실행
- PostgreSQL 기본 클라이언트 `psql` 사용
- JSON Plan 구조 처리는 PostgreSQL `jsonb` 함수와 `WITH RECURSIVE` 사용
- Plan Tree 표시 보조 처리는 기본 OS 유틸리티인 `awk`, `sed`, `grep`, `tr` 등을 사용
- PostgreSQL `FORMAT JSON`의 `Plan -> Plans[]` 구조만으로 Parent/Child Tree 생성
- SQL 문자열의 공백/들여쓰기를 역파싱하여 Plan 구조 추정하지 않음
- `Node Type` 이름으로 Parent/Child 구조를 임의 추정하지 않음
- PostgreSQL이 반환한 Node 속성 Key/Value를 기준으로 표시
- `EXPLAIN ANALYZE` 실제 실행 횟수 1회 보장
- Actual Raw JSON 원본 보존
- TEXT/YAML/XML 요청 시 비실행 Planned Raw Plan 별도 출력
- Bind SQL의 `PREPARE -> EXECUTE` 흐름 유지
- Bind Plan Mode `AUTO / CUSTOM / GENERIC` 선택 지원
- `ANALYZE=yes` 실행은 Transaction Wrapper 안에서 수행 후 `ROLLBACK`

## 실행 요구 사항

필수:

```text
/bin/sh
psql
PostgreSQL Server 12 ~ 18
```

사용하는 기본 OS 명령 예:

```text
awk
sed
grep
tr
sort
mktemp
stty
```

별도 설치 대상으로 보지 않는 일반적인 Linux 기본 사용자 공간 도구만 사용.

사용하지 않는 의존성:

```text
python / python3
perl
node / nodejs
jq
yq
pip module
별도 JSON parser package
```

## 실행

```sh
sh explain.sh
```

또는:

```sh
sh explain.sh /path/to/test.sql
```

## 접속 정보

우선 사용하는 환경변수:

```text
PSQL_BIN
PGHOST
PGPORT
PGUSER
PGDATABASE
PGDATA
PG_HOME
```

확인 불가 값만 실행 중 입력.

## PostgreSQL JSON Plan 처리

Tree와 Relation/DML 정보는 PostgreSQL 자체 JSON 기능으로 처리.

기본 구조:

```text
EXPLAIN (... FORMAT JSON)
        ↓
Top-level JSON Array
        ↓
Plan
        ↓
Plans[]
        ↓
Child Plan Node
```

`WITH RECURSIVE`와 `jsonb_array_elements()`를 이용해 Child Plan을 재귀 순회.

Relation 자동 식별은 Node의 다음 필드를 기준으로 처리.

```text
Schema
Relation Name
```

DML 여부는 Node의 `Operation` 값 중 다음을 기준으로 확인.

```text
Insert
Update
Delete
Merge
```

Quoted/Mixed-case Identifier는 `format('%I.%I', ...)`, `to_regclass()` 등을 이용해 처리.

## Plan Tree 출력

Plan Parent/Child 관계는 PostgreSQL JSON `Plans[]` 순서 기준.

대표 출력 형태:

```text
Nested Loop
├─ Seq Scan on public.orders
└─ Index Scan using customer_pkey on public.customer
```

Join Child의 경우 JSON 순서를 기준으로 Outer/Inner 표시를 보조할 수 있음.

Plan 상세 정보는 해당 JSON Node에 실제 존재하는 값을 기준으로 표시.

예:

```text
Node Type
Parent Relationship
Schema
Relation Name
Alias
Index Name
Sort Key
Index Cond
Recheck Cond
Hash Cond
Merge Cond
Join Filter
Filter
Actual Rows
Actual Loops
Workers
```

없는 속성의 의미를 임의 생성하지 않음.

## Bind Parameter 처리

기존 `$1`, `$2`, ... Bind 지원.

처리 흐름:

```text
SQL File / pg_stat_statements SQL
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

Bind 후보 탐색도 별도 Python Parser 없이 PostgreSQL Plan JSON, catalog, SQL 함수와 shell 기본 도구를 이용해 처리.

### Prepared Plan Mode

```text
AUTO    -> plan_cache_mode = auto
CUSTOM  -> plan_cache_mode = force_custom_plan
GENERIC -> plan_cache_mode = force_generic_plan
```

`AUTO`는 스크립트가 새 PostgreSQL Session에서 생성한 Prepared Statement 실행 이력을 기준으로 동작.
Application의 장기 Session에 누적된 Generic/Custom 선택 이력 자체를 재현하는 기능은 아님.

## EXPLAIN 옵션

| 옵션 | 내용 | Version/주의 |
| --- | --- | --- |
| ANALYZE | 실제 실행 + Actual 통계 | 대상 Statement 실제 실행 |
| VERBOSE | 상세 Plan 정보 | TRUE/FALSE 명시 |
| COSTS | Cost/Estimated Rows/Width | TRUE/FALSE 명시 |
| SETTINGS | 비기본 설정 | TRUE/FALSE 명시 |
| BUFFERS | Buffer 사용량 | ANALYZE 시 사용 |
| WAL | WAL 통계 | PostgreSQL 13+ |
| TIMING | Node별 Timing | ANALYZE 시 사용 |
| GENERIC_PLAN | Parameter 독립 Generic Plan | PostgreSQL 16+, Non-Bind EXPLAIN용 |
| SERIALIZE | 결과 직렬화 비용 | PostgreSQL 17+ |
| MEMORY | Planner Memory | PostgreSQL 17+ |
| SUMMARY | Planning/Execution Summary | TRUE/FALSE 명시 |
| RAW FORMAT | TEXT/JSON/YAML/XML | 기본 TEXT |

Version 미지원 옵션은 사용하지 않도록 분기.

## ANALYZE 실행 안전성

`ANALYZE=yes` 실행은 Transaction 안에서 수행.

```text
BEGIN
  ↓
EXPLAIN (ANALYZE TRUE, ..., FORMAT JSON)
  ↓
ROLLBACK
```

주의:

```text
Sequence 증가
외부 시스템 호출 함수
Transaction 외부 Side Effect
일부 Extension/외부 함수 동작
```

위 항목은 `ROLLBACK`으로 복구되지 않을 수 있음.

## Actual Plan 실행 횟수

Tree 생성을 위해 `EXPLAIN ANALYZE`를 재실행하지 않음.

```text
EXPLAIN ANALYZE FORMAT JSON
        ↓
실제 Statement 실행 1회
        ↓
JSON Raw 저장
        ├─ Tree 생성
        ├─ Relation/DML metadata 추출
        └─ Actual Raw JSON 출력
```

저장된 JSON을 PostgreSQL JSON 함수와 shell 기본 도구로 후처리.

## Raw Plan 보존 정책

### ANALYZE = yes

실제로 실행된 Plan의 기준 원본:

```text
Execution Plan Raw (JSON / Actual)
```

TEXT/YAML/XML을 추가 선택한 경우 비실행 Planned Raw Plan을 별도로 생성하여 Statement 재실행 방지.

### ANALYZE = no

JSON Planned Plan 기준 Tree 생성 및 Raw JSON 보존.
TEXT/YAML/XML 요청 시 동일 Statement의 비실행 Planned Raw 추가 출력.

## Relation 자동 추출

SQL 문자열에서 Table명을 직접 파싱하여 최종 Relation을 결정하지 않음.

PostgreSQL JSON Node의 다음 필드를 기준으로 추출.

```text
Schema
Relation Name
```

추출 Relation 기준으로 후속 Table/Column/Index 진단 수행.

## Table / Index Statistics Delta

`ANALYZE=yes`일 때 실행 전/후 `pg_stat_*` Snapshot 비교.

Table 주요 항목:

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

Index 주요 항목:

```text
idx_scan
idx_tup_read
idx_tup_fetch
idx_blks_read
idx_blks_hit
```

Delta는 누적 통계 Before/After 차이이므로 동일 Relation을 사용하는 다른 Session의 활동이 포함될 수 있음.
해당 SQL 자체의 I/O는 `EXPLAIN (ANALYZE, BUFFERS)`가 더 직접적인 기준.

## 추가 진단

Plan Relation별 다음 정보를 확인.

- Planner Settings
- Table Information
- Table Statistics
- Column Information
- Column Statistics (`pg_stats`)
- Extended Statistics (`pg_stats_ext`)
- Index Information / Columns / I/O

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
PostgreSQL JSON Plan/Plans Parent-Child 구조 기반 처리
Bind 값 기반 EXECUTE Plan 사용
Actual Plan 단일 실행
Raw Actual JSON 보존
지원 Version별 옵션 분기
외부 Python/JSON Parser 비의존
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

## v1.2.25 기준 의존성 정리

- `plan_tree.py` 제거
- Python 3 런타임 의존 제거
- Plan metadata 추출: PostgreSQL `jsonb` + recursive SQL
- Plan Tree 구조 생성: PostgreSQL `WITH RECURSIVE`
- 출력 정리: POSIX shell + 기본 `awk`
- `explain.sh` 단일 실행 파일 구성
