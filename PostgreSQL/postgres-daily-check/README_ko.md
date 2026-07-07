# PostgreSQL 일일 점검 스크립트 사용방법

이 폴더는 PostgreSQL 서버에서 매일 점검을 수행하기 위한 쉘 스크립트와 SQL 파일 모음입니다.

권장 실행 위치:

```text
/home/postgres/postgres-daily-check
```

권장 실행 유저:

```text
postgres
```

## 구성 파일

```text
postgres_daily_check.sh
sql/01_instance_health.sql
sql/02_wal_and_archiver.sql
sql/03_long_queries_idle_locks.sql
sql/04_replication_lag.sql
sql/05_dead_tuple_autovacuum.sql
sql/06_xid_age.sql
sql/07_pg_stat_statements_top.sql
```

## 점검 항목

### 00. DB 접속 가능 여부

`pg_isready` 또는 `psql SELECT 1`로 PostgreSQL에 접속 가능한지 확인합니다.

확인 목적:

- DB 프로세스가 살아있는지 확인
- 포트/소켓 접속이 가능한지 확인
- 인증 또는 접속 설정 문제가 있는지 빠르게 확인

이상 신호:

- `no response`
- `rejecting connections`
- `connection refused`
- 인증 실패

### 01. PostgreSQL 재기동 여부

`pg_postmaster_start_time()`을 조회해서 PostgreSQL 서버 기동 시각과 uptime을 확인합니다.

관련 파일:

```text
sql/01_instance_health.sql
```

확인 목적:

- DB가 최근 24시간 안에 재기동되었는지 확인
- 예상하지 못한 재시작 여부 확인
- 점검 시점의 PostgreSQL 버전 확인

주요 컬럼:

```text
postmaster_start_time  PostgreSQL 서버 기동 시각
uptime                 현재까지 가동 시간
restart_status         최근 24시간 내 재기동 여부
postgres_version       PostgreSQL 버전
```

### 02. PostgreSQL 로그 오류 확인

`postgresql.conf`의 `log_directory` 설정을 읽어서 최근 24시간 로그에서 아래 키워드를 검색합니다.

```text
FATAL
PANIC
ERROR
```

확인 목적:

- SQL 오류, 인증 실패, 장애성 오류 확인
- PostgreSQL 프로세스/스토리지/복구 관련 심각 오류 확인

이상 신호:

- `PANIC`: 매우 심각, 즉시 확인 필요
- `FATAL`: 접속 실패, 프로세스 종료, 설정 문제 가능
- `ERROR`: 쿼리 오류일 수도 있으나 반복 발생 여부 확인 필요

참고:

- `resolved_log_dir`는 스크립트가 실제로 읽은 로그 경로입니다.
- `script_started_at`은 점검 스크립트 시작 시각입니다. DB 기동 시각이 아닙니다.

### 03. 디스크 사용률 / WAL 디렉터리 사용량

`df`, `du`, `pg_wal` 파일 개수, `archive_status`를 확인합니다.

확인 목적:

- DB 서버 파일시스템 사용률 확인
- WAL 디렉터리 급증 여부 확인
- archive가 밀려 `.ready` 파일이 쌓이는지 확인

주요 확인 대상:

```text
df -h PGDATA
du -sh PGDATA
du -sh PGDATA/pg_wal
PGDATA/pg_wal/archive_status
```

이상 신호:

- 디스크 사용률 80~90% 이상
- `pg_wal` 급증
- `archive_status`에 `.ready` 파일 다량 적체

### 04. WAL / Archiver / Replication Slot 적체

WAL 현재 위치, archive 통계, replication slot의 WAL 보존량을 확인합니다.

관련 파일:

```text
sql/02_wal_and_archiver.sql
```

확인 목적:

- archive 실패 여부 확인
- replication slot 때문에 WAL이 삭제되지 못하고 쌓이는지 확인
- slot별 retained WAL 크기 확인

주요 뷰:

```text
pg_stat_archiver
pg_replication_slots
```

이상 신호:

- `failed_count` 증가
- `last_failed_time` 최근 발생
- 비활성 replication slot의 `retained_wal` 증가
- `wal_status` 이상

### 05. 장시간 쿼리 / idle in transaction / Lock

현재 실행 중인 쿼리, 오래 열린 트랜잭션, blocking lock을 확인합니다.

관련 파일:

```text
sql/03_long_queries_idle_locks.sql
```

확인 목적:

- 오래 실행되는 쿼리 확인
- `idle in transaction`으로 vacuum이나 lock을 방해하는 세션 확인
- blocking / blocked 세션 확인

주요 뷰:

```text
pg_stat_activity
pg_locks
```

기본 임계값:

```text
LONG_QUERY_THRESHOLD='5 minutes'
IDLE_XACT_THRESHOLD='5 minutes'
```

이상 신호:

- 장시간 실행 쿼리 다수
- 오래된 `idle in transaction`
- blocker 세션이 여러 쿼리를 막고 있음

### 06. Replication Lag

Replication 구성을 `single`, `primary`, `standby`로 판별하고 상태를 확인합니다.

관련 파일:

```text
sql/04_replication_lag.sql
```

확인 목적:

- 단일 인스턴스인지, primary인지, standby인지 구분
- standby가 primary를 얼마나 따라오고 있는지 확인
- write, flush, replay 단계별 지연 확인

주요 뷰:

```text
pg_is_in_recovery()
pg_stat_replication
pg_stat_wal_receiver
```

역할 판별:

```text
single   pg_is_in_recovery() = false 이고 pg_stat_replication 결과 없음
primary  pg_is_in_recovery() = false 이고 pg_stat_replication 결과 있음
standby  pg_is_in_recovery() = true
```

주요 컬럼:

```text
replication_role
write_lag_bytes
flush_lag_bytes
replay_lag_bytes
write_lag
flush_lag
replay_lag
sync_state
status
last_msg_send_time
last_msg_receipt_time
latest_end_lsn
latest_end_time
```

참고:

- `single`이면 `pg_stat_replication`, `pg_stat_wal_receiver` 결과가 비어 있는 것이 정상입니다.
- `primary`이면 `pg_stat_replication`에서 downstream standby 상태를 봅니다.
- `standby`이면 `pg_stat_wal_receiver`에서 upstream primary와의 수신 상태를 봅니다.

### 07. Dead Tuple / Autovacuum 지연

테이블별 dead tuple 비율과 autovacuum 수행 시각을 확인합니다.

관련 파일:

```text
sql/05_dead_tuple_autovacuum.sql
```

확인 목적:

- dead tuple이 많이 쌓인 테이블 확인
- autovacuum이 오랫동안 수행되지 않은 테이블 확인
- 현재 vacuum 진행 상황 확인

주요 뷰:

```text
pg_stat_user_tables
pg_stat_progress_vacuum
```

기본 임계값:

```text
DEAD_TUPLE_MIN=10000
DEAD_TUPLE_PCT=20
AUTOVACUUM_DELAY_THRESHOLD='1 day'
```

이상 신호:

- `n_dead_tup` 과다
- `dead_tuple_pct` 높음
- `last_autovacuum`이 오래됨
- vacuum이 오래 진행 중

### 08. XID Age

database와 table의 transaction ID age를 확인합니다.

관련 파일:

```text
sql/06_xid_age.sql
```

확인 목적:

- transaction ID wraparound 위험 확인
- vacuum freeze가 필요한 DB/테이블 확인

제외 대상:

```text
template% database
pg_toast schema
```

주요 컬럼:

```text
xid_age
datfrozenxid
relfrozenxid
```

이상 신호:

- `xid_age`가 매우 큼
- autovacuum freeze가 지연되는 테이블 존재

참고 기준:

- PostgreSQL wraparound 한계는 약 20억 XID입니다.
- 운영에서는 수억 단위부터 추세를 보고 선제 대응하는 것이 좋습니다.

### 09. pg_stat_statements TOP SQL

`pg_stat_statements` 기준으로 총 실행 시간이 큰 SQL을 집계합니다.

관련 파일:

```text
sql/07_pg_stat_statements_top.sql
```

확인 목적:

- DB 부하를 많이 유발한 SQL 확인
- 쿼리 유형별 SELECT/UPDATE/DELETE/INSERT 분류
- block read/write 지표 확인

주요 컬럼:

```text
query_sample
query_type
total_calls
total_exec_time
total_plan_time
exec_time_avg
plan_time_avg
shared_blks_hit
shared_blks_read
shared_blks_dirtied
shared_blks_written
```

기본 출력 개수:

```text
TOP_SQL_LIMIT=10
```

참고:

- `pg_stat_statements` extension이 없으면 안내 메시지만 출력합니다.
- extension 사용을 위해서는 보통 `shared_preload_libraries` 설정과 PostgreSQL 재기동이 필요합니다.

## 서버에 배포

로컬에서 서버로 복사:

```bash
scp -r postgres-daily-check postgres@<DB서버IP>:/home/postgres/
```

서버에서 권한 부여:

```bash
su - postgres
chmod +x /home/postgres/postgres-daily-check/postgres_daily_check.sh
```

Docker 컨테이너에 복사하는 경우:

```powershell
docker cp .\postgres-daily-check agent2:/home/postgres/postgres-daily-check
docker exec -i agent2 chown -R postgres:postgres /home/postgres/postgres-daily-check
docker exec -i agent2 su - postgres -c "chmod +x /home/postgres/postgres-daily-check/postgres_daily_check.sh"
```

## 수동 실행

```bash
su - postgres
/home/postgres/postgres-daily-check/postgres_daily_check.sh
```

실행하면 리포트 파일 경로가 출력됩니다.

```text
/home/postgres/postgres_daily_reports/postgres_daily_check_<hostname>_<dbname>_<timestamp>.log
```

## 리포트 주요 시간 값

```text
script_started_at      = 점검 쉘 시작 시각
script_finished_at     = 점검 쉘 종료 시각
postmaster_start_time  = PostgreSQL 서버 기동 시각
restart_status         = 최근 24시간 내 PostgreSQL 재기동 여부
```

## 기본 환경변수

대부분 기본값으로 실행 가능합니다.

```bash
export DB_NAME=postgres
export DB_USER=postgres
export DB_PORT=5432
export PGDATA=/home/postgres/data
export REPORT_DIR=/home/postgres/postgres_daily_reports
```

`LOG_DIR`는 기본적으로 직접 지정하지 않아도 됩니다. 스크립트가 PostgreSQL 설정값을 조회합니다.

```sql
current_setting('log_directory')
current_setting('data_directory')
```

로그 경로를 강제로 지정해야 하는 환경이면:

```bash
export LOG_DIR=/var/log/postgresql
```

## 원격 DB 점검

점검 서버에서 원격 PostgreSQL에 접속하는 경우:

```bash
export DB_HOST=10.10.10.20
export DB_PORT=5432
export DB_NAME=postgres
export DB_USER=postgres
/home/postgres/postgres-daily-check/postgres_daily_check.sh
```

주의: 원격 접속 방식은 SQL 기반 점검은 가능하지만, 로그/디스크/WAL 파일시스템 점검은 DB 서버 로컬에서 실행할 때 가장 정확합니다.

## 임계값 조정

```bash
export LONG_QUERY_THRESHOLD='5 minutes'
export IDLE_XACT_THRESHOLD='5 minutes'
export AUTOVACUUM_DELAY_THRESHOLD='1 day'
export DEAD_TUPLE_MIN=10000
export DEAD_TUPLE_PCT=20
export TOP_SQL_LIMIT=10
```

## crontab 등록

매일 오전 8시에 실행:

```bash
crontab -e
```

```cron
0 8 * * * /home/postgres/postgres-daily-check/postgres_daily_check.sh >/tmp/postgres_daily_check.cron.log 2>&1
```

## 이전 일자 리포트와 비교

두 개의 일일 점검 리포트를 비교할 때는 `postgres_daily_compare.sh`를 사용합니다.

비교 제외 항목:

```text
00. DB Connectivity
01. Instance Health / Restart Check
02. PostgreSQL Log FATAL / PANIC / ERROR In Last 24 Hours
```

비교 대상:

```text
03번 이후 전체 섹션
```

사용법:

인자 없이 실행하면 기본 리포트 경로를 읽고 파일을 두 번 선택합니다.

```bash
chmod +x /home/postgres/postgres-daily-check/postgres_daily_compare.sh

/home/postgres/postgres-daily-check/postgres_daily_compare.sh
```

기본 리포트 경로:

```text
/home/postgres/postgres_daily_reports
```

다른 리포트 경로에서 선택:

```bash
/home/postgres/postgres-daily-check/postgres_daily_compare.sh /data/postgres_daily_reports
```

파일 경로를 직접 지정:

```bash
chmod +x /home/postgres/postgres-daily-check/postgres_daily_compare.sh

/home/postgres/postgres-daily-check/postgres_daily_compare.sh \
  /home/postgres/postgres_daily_reports/postgres_daily_check_agent2_postgres_20260706.log \
  /home/postgres/postgres_daily_reports/postgres_daily_check_agent2_postgres_20260707.log
```

비교 결과를 파일로 저장:

```bash
/home/postgres/postgres-daily-check/postgres_daily_compare.sh \
  /home/postgres/postgres_daily_reports/postgres_daily_check_agent2_postgres_20260706.log \
  /home/postgres/postgres_daily_reports/postgres_daily_check_agent2_postgres_20260707.log \
  /home/postgres/postgres_daily_reports/compare_20260706_20260707.log
```

결과 해석:

```text
NO_DIFF                  해당 섹션 차이 없음
--- / +++                diff 기준 이전/신규 리포트
- 로 시작하는 줄          이전 리포트에만 있던 내용
+ 로 시작하는 줄          신규 리포트에만 생긴 내용
Only exists in old report 해당 섹션이 이전 리포트에만 있음
Only exists in new report 해당 섹션이 신규 리포트에만 있음
```

## agent2 컨테이너에서 실행

```powershell
docker exec -i agent2 su - postgres -c "/home/postgres/postgres-daily-check/postgres_daily_check.sh"
```

최근 생성 리포트 확인:

```powershell
docker exec -i agent2 su - postgres -c "ls -ltr /home/postgres/postgres_daily_reports | tail"
```

리포트 내용 확인:

```powershell
docker exec -i agent2 su - postgres -c "cat /home/postgres/postgres_daily_reports/<리포트파일명>"
```

agent2에서 리포트 비교:

```powershell
docker exec -i agent2 su - postgres -c "/home/postgres/postgres-daily-check/postgres_daily_compare.sh /home/postgres/postgres_daily_reports/<이전리포트> /home/postgres/postgres_daily_reports/<신규리포트>"
```
