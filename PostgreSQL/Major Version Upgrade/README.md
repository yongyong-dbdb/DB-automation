# PostgreSQL Major Upgrade Runbook

이 문서는 PostgreSQL 15.7에서 18.4로 업그레이드할 때 사용한 절차를 정리한 것이다. 기본 경로는 `/home/postgres`이고, 기존 운영 포트는 `5444` 기준이다.

## 구성 요약

- primary/single 서버는 `scripts/postgresql_major_upgrade.sh`를 사용한다.
- physical standby 서버는 `pg_upgrade`를 수행하지 않고, primary 업그레이드 후 `pg_basebackup`으로 재구성한다.
- standby 재구성은 `scripts/postgresql_standby_rebuild.sh`를 사용한다.
- `repmgr` extension을 더 이상 사용하지 않는다면 old cluster에서 extension을 제거한 뒤 업그레이드한다.
- replication 계정 이름이 `repmgr`이거나 `repl`이어도 계정 자체는 계속 사용할 수 있다.

## Primary 또는 Single 서버

### 1. 스크립트 배치

```bash
cd /home/postgres
cp postgresql_major_upgrade.sh major_upgrade.sh
chmod +x major_upgrade.sh
./major_upgrade.sh config
```

기본값은 다음과 같다.

```text
PG_NEW_VERSION=18.4
PG_HOME_OLD=/home/postgres/pgsql
PG_HOME_NEW=/home/postgres/pgsql_18.4
PGDATA_OLD=/home/postgres/data
PGDATA_NEW=/home/postgres/data_18
OLD_PORT=5444
NEW_PORT=5444
USE_LINK=true
```

`NEW_PORT`를 지정하지 않으면 `OLD_PORT`와 같은 값을 사용한다. 기존 운영 포트가 `5444`이면 새 버전도 기본적으로 `5444`로 뜬다.

### 2. 온라인 준비 단계

아래 단계는 기존 DB가 떠 있는 상태에서 수행할 수 있다.

```bash
./major_upgrade.sh prepare
```

`prepare`는 내부적으로 아래 작업을 순서대로 수행한다.

```text
precheck -> build -> backup -> initdb
```

각 단계의 의미:

- `precheck`: 현재 버전, data_directory, port, listen_addresses, encoding, locale, checksum, replication, extension 확인
- `build`: `postgresql-18.4.tar.gz` 압축 해제 후 `./configure`, `make`, `make install`, `make -C contrib install`
- `backup`: `pg_dumpall`과 기존 conf 파일 백업
- `initdb`: 새 PGDATA 생성. old cluster의 checksum, encoding, locale을 최대한 맞춘다.

### 3. 다운타임 구간

애플리케이션 접속을 차단한 뒤 진행한다.

```bash
./major_upgrade.sh stop-old
./major_upgrade.sh check
./major_upgrade.sh upgrade
./major_upgrade.sh start-new
./major_upgrade.sh postcheck
./major_upgrade.sh env
source ~/.bash_profile
```

`stop-old`와 `upgrade`는 확인 문구를 요구한다.

```text
STOP OLD
UPGRADE
```

### 4. USE_LINK 옵션

빠른 업그레이드:

```bash
USE_LINK=true ./major_upgrade.sh upgrade
```

파일 복사 방식:

```bash
USE_LINK=false ./major_upgrade.sh upgrade
```

`USE_LINK=true`는 하드링크를 사용하므로 빠르고 추가 디스크 사용량이 적다. 단, 새 cluster가 기동되고 쓰기가 발생한 뒤에는 old cluster로 파일 레벨 롤백이 어렵다.

`USE_LINK=false`는 더 느리고 데이터 크기만큼 추가 디스크가 필요하지만, old data directory가 더 독립적으로 남는다.

## 주요 장애 대응

### checksum mismatch

에러 예:

```text
old cluster does not use data checksums but the new one does
```

old/new cluster의 checksum 설정이 달라서 발생한다. 스크립트는 old cluster의 `Data page checksum version`을 읽어 `initdb`에 `--no-data-checksums` 또는 `--data-checksums`를 자동 적용한다.

이미 잘못 생성한 new PGDATA가 있으면:

```bash
./major_upgrade.sh reinitdb
./major_upgrade.sh check
```

확인 문구:

```text
REINITDB
```

### loadable libraries missing

에러 예:

```text
Checking for presence of required libraries fatal
loadable_libraries.txt
```

스크립트는 `check` 실패 시 최신 `loadable_libraries.txt` 내용을 자동 출력한다.

`pg_stat_statements` 같은 contrib module이면:

```bash
./major_upgrade.sh contrib
./major_upgrade.sh check
```

`repmgr`, PostGIS, TimescaleDB, Citus 등 외부 extension이면 PostgreSQL 18.4용 라이브러리를 별도 설치해야 한다.

`repmgr`를 더 이상 사용하지 않을 경우 old cluster에서 제거한다.

```bash
/home/postgres/pgsql/bin/pg_ctl -D /home/postgres/data -l /home/postgres/data/server.log -w start
/home/postgres/pgsql/bin/psql -p 5444 -U postgres -d repmgr -c "DROP EXTENSION IF EXISTS repmgr CASCADE;"
/home/postgres/pgsql/bin/pg_ctl -D /home/postgres/data -m fast -w stop
./major_upgrade.sh check
```

`DROP DATABASE repmgr`는 repmgr 메타데이터를 더 이상 보관할 필요가 없을 때만 수행한다.

### port 또는 alias 문제

스크립트는 기본적으로 `NEW_PORT=$OLD_PORT`로 동작한다. 따라서 old port가 `5444`면 new port도 `5444`다.

`start-new` 단계는 새 `postgresql.conf`에 `port = $NEW_PORT`를 한 번 더 반영한다.

`env` 단계는 `~/.bash_profile`에서 다음 항목을 치환한다.

- old `PG_HOME` 경로를 new `PG_HOME`으로 변경
- old `PGDATA` 경로를 new `PGDATA`로 변경
- `PGPORT`를 `NEW_PORT`로 변경
- alias 내부의 `-p OLD_PORT`를 `-p NEW_PORT`로 변경

반영 후:

```bash
source ~/.bash_profile
which psql
psql --version
echo "$PGDATA"
echo "$PGPORT"
alias pp
```

## Standby 서버

physical standby 서버는 `pg_upgrade`를 실행하지 않는다. primary 업그레이드 완료 후 primary에서 다시 base backup을 받는다.

### 1. standby에도 PostgreSQL 18.4 바이너리 필요

standby에서도 `pg_basebackup`, `postgres`, `pg_ctl`, `psql`은 18.4 바이너리를 사용해야 한다.

빌드 도구가 있으면 standby에서 직접 빌드한다.

```bash
cd /home/postgres
tar -xzf postgresql-18.4.tar.gz
cd postgresql-18.4
./configure --prefix=/home/postgres/pgsql_18.4
make -j 2
make install
make -C contrib install
```

빌드 도구가 없고 yum도 불가하면, primary와 OS/라이브러리 구성이 같은 경우 primary에서 빌드된 binary directory를 복사할 수 있다.

primary:

```bash
cd /home/postgres
tar -czf pgsql_18.4_binary.tar.gz pgsql_18.4
scp pgsql_18.4_binary.tar.gz postgres@<STANDBY_IP>:/home/postgres/
```

standby:

```bash
cd /home/postgres
tar -xzf pgsql_18.4_binary.tar.gz
/home/postgres/pgsql_18.4/bin/pg_basebackup --version
ldd /home/postgres/pgsql_18.4/bin/postgres | grep "not found" || true
```

### 2. standby 재구성

standby에서:

```bash
cd /home/postgres
cp postgresql_standby_rebuild.sh standby_rebuild.sh
chmod +x standby_rebuild.sh

PRIMARY_HOST=128.10.41.133 \
PRIMARY_PORT=5444 \
REPL_USER=repl \
REPL_SLOT=physical_slot01 \
./standby_rebuild.sh rebuild
```

이 스크립트는 아래 순서로 수행한다.

```text
precheck -> stop-old -> move-data -> basebackup -> start-new -> postcheck
```

기존 standby data directory는 삭제하지 않고 timestamp가 붙은 경로로 이동한다.

### 3. primary 확인

primary에서:

```sql
select application_name, client_addr, state, sync_state, sent_lsn, replay_lsn
from pg_stat_replication;
```

standby에서:

```sql
select pg_is_in_recovery();
select status, sender_host, sender_port from pg_stat_wal_receiver;
```

## Cascading Replication

cascading 구성은 다음 구조다.

```text
primary -> standby1 -> standby2
```

standby1은 primary에서 basebackup을 받고, standby2는 standby1에서 basebackup을 받는다.

standby1에는 downstream standby를 받을 수 있도록 다음 설정이 필요하다.

```conf
hot_standby = on
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = '1GB'
```

standby1의 `pg_hba.conf`에는 standby2의 replication 접속을 허용한다.

```conf
host replication repl <STANDBY2_IP>/32 md5
```

standby2 재구성 예:

```bash
PRIMARY_HOST=<STANDBY1_IP> \
PRIMARY_PORT=5444 \
REPL_USER=repl \
REPL_SLOT=physical_slot02 \
./standby_rebuild.sh rebuild
```

primary에는 standby1만 보이고, standby1의 `pg_stat_replication`에는 standby2가 보여야 한다.

## 최종 점검

primary:

```bash
psql -p 5444 -d postgres -c "select version();"
psql -p 5444 -d postgres -c "show data_directory;"
psql -p 5444 -d postgres -c "show port;"
psql -p 5444 -d postgres -c "select application_name, client_addr, state, sync_state from pg_stat_replication;"
```

standby:

```bash
psql -p 5444 -d postgres -c "select pg_is_in_recovery();"
psql -p 5444 -d postgres -c "select status, sender_host, sender_port from pg_stat_wal_receiver;"
```

환경:

```bash
source ~/.bash_profile
which psql
psql --version
echo "$PG_HOME"
echo "$PGDATA"
echo "$PGPORT"
```
