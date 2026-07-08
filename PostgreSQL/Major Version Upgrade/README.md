# PostgreSQL Major Upgrade Runbook

이 문서는 PostgreSQL major version upgrade 자동화 스크립트 사용 방법을 정리한 문서이다.
기본 경로는 `/home/postgres`, 기본 운영 포트는 `5444` 기준이다.

## 파일 구성

- `postgresql_major_upgrade.sh`: primary 또는 single 서버에서 `pg_upgrade` 수행
- `postgresql_standby_rebuild.sh`: physical standby 서버를 `pg_basebackup`으로 재구성

physical standby 서버는 일반적으로 `pg_upgrade`를 직접 수행하지 않는다. primary 업그레이드 완료 후 새 버전 binary로 `pg_basebackup`을 다시 받는다.

## Primary 또는 Single 서버 업그레이드

### 1. 스크립트 배치

```bash
cd /home/postgres
cp postgresql_major_upgrade.sh major_upgrade.sh
chmod +x major_upgrade.sh
```

### 2. 설정 확인

```bash
sh major_upgrade.sh config
```

`config`와 `prepare` 단계에서는 저장된 설정이 있어도 주요 값을 다시 물어본다.
Enter만 입력하면 현재 저장된 값을 그대로 사용하고, 값을 입력하면 새 값으로 갱신한다.

예시: `18.4 -> 19beta1` 업그레이드

```text
Enter old PostgreSQL home [current: /home/postgres/pgsql]: /home/postgres/pgsql_18.4
Enter old PostgreSQL data directory [current: /home/postgres/data]: /home/postgres/data_18
Enter old PostgreSQL port [current: 5444]: 5444
Enter new PostgreSQL version [current: 18.4]: 19beta1
Enter new PostgreSQL port [current: 5444]: 5444
```

이 경우 기본 경로는 다음처럼 계산된다.

```text
PG_HOME_OLD=/home/postgres/pgsql_18.4
PGDATA_OLD=/home/postgres/data_18
PG_HOME_NEW=/home/postgres/pgsql_19beta1
PGDATA_NEW=/home/postgres/data_19
SRC_TAR=/home/postgres/postgresql-19beta1.tar.gz
SRC_DIR=/home/postgres/postgresql-19beta1
WORK_DIR=/home/postgres/pg_upgrade_work_19beta1
```

입력한 값은 아래 파일에 저장된다.

```bash
/home/postgres/.postgresql_major_upgrade.conf
```

### 3. prepare

기존 DB가 떠 있는 상태에서 수행한다.

```bash
sh major_upgrade.sh prepare
```

`prepare`는 내부적으로 아래 순서로 수행된다.

```text
precheck -> build -> backup -> initdb
```

주요 작업:

- old 서버 버전, binary 버전, data directory, port 검증
- source tar 압축 해제 및 build
- `make install`, `make -C contrib install`
- `pg_dumpall` 백업 및 기존 conf 백업
- old cluster와 동일한 checksum, encoding, locale 기준으로 new PGDATA 생성
- new `postgresql.conf`에 `NEW_PORT` 반영

주의: old 서버가 18.4인데 `PG_HOME_OLD/bin/pg_dumpall`이 17.4이면 백업이 실패한다.
스크립트는 이제 `server major`와 `pg_dumpall major`가 다르면 백업 전에 중단한다.

### 4. Downtime 단계

애플리케이션 접속을 차단한 뒤 수행한다.

```bash
sh major_upgrade.sh stop-old
sh major_upgrade.sh check
sh major_upgrade.sh upgrade
sh major_upgrade.sh start-new
sh major_upgrade.sh postcheck
sh major_upgrade.sh env
source ~/.bash_profile
hash -r
```

각 단계가 끝나면 다음 수행할 단계를 출력한다.

`stop-old`와 `upgrade`는 실수 방지를 위해 확인 문구를 입력해야 한다.

```text
STOP OLD
UPGRADE
```

### 5. pg_upgrade 옵션

`upgrade` 단계는 실행할 때마다 `--link`와 `--jobs`를 다시 물어본다.
저장된 설정이 있어도 이 두 옵션은 매번 선택한다.

```text
Use --link option for pg_upgrade? [y/N]
Set --jobs for pg_upgrade parallel workers.
  Detected physical CPU cores: 8
  Recommended: 4, about 50% of physical CPU cores.
Enter jobs value [recommended: 4]:
```

`--link` 설명:

- `y`: hard link 방식. 빠르고 추가 디스크 사용량이 적지만, 새 cluster에 write 발생 후 old cluster로 파일 단위 rollback이 어렵다.
- `n`: copy 방식. 느리고 데이터 크기만큼 추가 디스크가 필요하지만, old cluster 보존성이 더 좋다.

`--jobs`는 물리 코어의 약 50%를 권장한다.

## postcheck와 analyze

`postcheck`는 새 DB의 버전, data directory, port, listen address를 확인한다.

또한 `pg_upgrade`가 생성한 `analyze_new_cluster.sh`를 실행한다.
스크립트 위치가 `$WORK_DIR`에 없으면 `/home/postgres` 아래에서 최신 파일을 찾아 실행한다.

파일을 찾지 못하면 아래 대체 명령을 출력한다.

```bash
/home/postgres/pgsql_<NEW_VERSION>/bin/vacuumdb -p <NEW_PORT> -U postgres --all --analyze-in-stages
```

## env 단계

`env` 단계는 shell 환경을 새 PostgreSQL 기준으로 변경한다.

```bash
sh major_upgrade.sh env
source ~/.bash_profile
hash -r
which psql
psql --version
alias pp
```

수정 전 아래 파일을 백업한다.

- `~/.bash_profile`
- `~/.bashrc`가 있으면 함께 백업

변경 내용:

- alias 안의 old PostgreSQL 경로를 new PostgreSQL 경로로 치환
- old `PGDATA` 경로를 new `PGDATA` 경로로 치환
- `-p OLD_PORT`를 `-p NEW_PORT`로 치환
- `.bash_profile` 하단에 관리 블록 추가

추가되는 관리 블록 예시:

```bash
# Added by postgresql_major_upgrade.sh
export PG_HOME=/home/postgres/pgsql_19beta1
export PGDATA=/home/postgres/data_19
export PGPORT=5444
export PG_PORT=5444
export PATH=$PG_HOME/bin:$PATH
# End postgresql_major_upgrade.sh
```

## 주요 에러 대응

### pg_dumpall server version mismatch

에러 예시:

```text
pg_dumpall: error: aborting because of server version mismatch
pg_dumpall: detail: server version: 18.4; pg_dumpall version: 17.4
```

원인:

- running old server는 18.4인데 `PG_HOME_OLD`가 17.4 binary 경로를 보고 있다.

조치:

```text
PG_HOME_OLD=/home/postgres/pgsql_18.4
PGDATA_OLD=/home/postgres/data_18
```

`prepare`를 다시 실행하고 old home/data 입력값을 올바르게 지정한다.

### checksum mismatch

에러 예시:

```text
old cluster does not use data checksums but the new one does
```

원인:

- old cluster와 new cluster의 checksum 설정이 다르다.

스크립트는 old cluster의 `Data page checksum version`을 읽어 `initdb`에 `--data-checksums` 또는 `--no-data-checksums`를 자동 반영한다.
이미 잘못 만든 new PGDATA가 있으면 다시 생성한다.

```bash
sh major_upgrade.sh reinitdb
sh major_upgrade.sh check
```

### loadable libraries missing

에러 예시:

```text
Checking for presence of required libraries fatal
loadable_libraries.txt
```

`check` 실패 시 스크립트가 최신 `loadable_libraries.txt` 내용을 출력한다.

contrib module이면:

```bash
sh major_upgrade.sh contrib
sh major_upgrade.sh check
```

외부 extension이면 PostgreSQL 새 버전용 라이브러리를 별도로 설치해야 한다.
예: `repmgr`, PostGIS, TimescaleDB, Citus

더 이상 사용하지 않는 extension이면 old cluster에서 제거 후 다시 진행한다.

```bash
<OLD_PG_HOME>/bin/psql -p <OLD_PORT> -U postgres -d <DB_NAME> -c "DROP EXTENSION IF EXISTS repmgr CASCADE;"
```

## Physical Standby 재구성

standby 서버는 새 PostgreSQL binary가 필요하다.
standby 서버에서 build가 어렵고 OS/library 구성이 primary와 같다면 primary에서 build한 binary directory를 복사할 수 있다.

primary:

```bash
cd /home/postgres
tar -czf pgsql_19beta1_binary.tar.gz pgsql_19beta1
scp pgsql_19beta1_binary.tar.gz postgres@<STANDBY_IP>:/home/postgres/
```

standby:

```bash
cd /home/postgres
tar -xzf pgsql_19beta1_binary.tar.gz
/home/postgres/pgsql_19beta1/bin/postgres --version
ldd /home/postgres/pgsql_19beta1/bin/postgres | grep "not found" || true
```

standby rebuild 예시:

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

## Cascading Replication 용어

예시 구성:

```text
128.10.41.133 primary
├── 128.10.41.135 standby
└── 128.10.41.134 cascading standby
    ├── 128.10.41.136 downstream standby
    └── 128.10.41.138 downstream standby
```

- `128.10.41.134`는 `128.10.41.133`의 standby이다.
- 동시에 `128.10.41.136`, `128.10.41.138`의 upstream 서버 역할을 한다.
- `128.10.41.136`, `128.10.41.138`은 `128.10.41.134`에서 `pg_basebackup`을 받는다.

downstream standby 생성 예시:

```bash
/home/postgres/pgsql_19beta1/bin/pg_basebackup -h 128.10.41.134 -p 5444 -U repl -D /home/postgres/data -P -v -X stream -S physical_cascade1 -R
```

## 최종 확인

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

shell:

```bash
source ~/.bash_profile
hash -r
which psql
psql --version
echo "$PG_HOME"
echo "$PGDATA"
echo "$PGPORT"
alias pp
```
