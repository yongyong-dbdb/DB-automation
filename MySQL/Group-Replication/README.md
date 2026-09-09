# MySQL GR 전환 자동화 v1.0.2

작성 기준: 2026-09-09. 전체 실행 코드: `mysql_gr_migrate.sh`.

GTID 비동기 복제 또는 Standalone에서 Group Replication을 구성하는 대화형 POSIX `/bin/sh` 스크립트. 동일 서버 다중 인스턴스와 서버별 인스턴스를 구분하며, Primary 모드를 별도로 선택한다.

| 선택 항목 | 지원 값 |
|---|---|
| 전환 방식 | GTID replication → GR / Standalone → GR |
| GR 모드 | Single Primary / Multi Primary |
| 멤버 수 | 2~9개, 실행 시 입력 |
| 인스턴스 접속 | 로컬 Unix Socket / 원격 MySQL TCP |
| 원격 OS 설정 | SSH 자동 적용 / 대상 서버에서 실행할 전체 Helper 복사 |
| 초기 데이터 | 비어 있는 인스턴스에 전체 업무 DB dump / 이미 준비된 데이터 / 외부 초기화 |
| 설정 Profile | minimum / production |
| 복구 계정 | 신규 최소 권한 계정 / 기존 계정 검증 |
| TLS | VERIFY_IDENTITY / REQUIRED(인증서 신원 미검증을 명시적으로 선택) |

## 현재 환경에서 선택할 내용

이전에 제공한 구성은 같은 서버의 3306·3307 GTID 복제와 새로 설치한 3308 인스턴스다. 아래 표는 그 구성에서의 선택 예시이며 코드에 고정된 값이 아니다. 실제 서버 현재 상태는 실행 시 다시 조회한다.

| 등록 순서 | 기존 역할 | 선택 |
|---|---|---|
| Node 1 | 권위 있는 GTID Source(이전 3306) | Source, 실제 Socket 선택 |
| Node 2 | 기존 Replica(이전 3307) | replica, 실제 복제 Channel 선택 |
| Node 3 | 신규 인스턴스(이전 3308) | new, 빈 인스턴스이면 dump 선택 |

모든 인스턴스가 같은 서버에 있으면 각 인스턴스의 **Socket 접속**을 선택한다. 런타임 Port·Socket·Datadir·UUID·server_id를 출력한 후 등록한다. 관리 TCP를 선택하면 로컬 파일·서비스를 잘못 수정하지 않도록 원격 관리 경로로 취급한다.

SQL 포트와 XCom 포트는 별개다. XCom 포트는 직접 입력하고 같은 호스트의 다른 SQL·X Protocol·XCom 포트와 충돌하는지 검사한다. DNS 별칭이 같은 IP로 해석되는 경우도 비교한다. 로컬에서 `ss`를 사용할 수 있으면 선택 포트의 기존 Listen 여부도 확인한다. 서로 다른 서버에서는 각 서버의 동일 포트 번호를 사용할 수 있다.

한 서버의 여러 인스턴스 구성은 서버 한 대의 장애를 견디는 구성이 아니다.

## 실행

외부 Python·Node 패키지나 MySQL Shell은 필요하지 않다. MySQL 배포본의 `mysql`, dump 초기화 시 동일 버전 `mysqldump`, Linux 기본 유틸리티를 사용한다. 검증용 `test_gr.py`만 Python 표준 라이브러리를 사용한다.

같은 작업 디렉터리에서 단계별로 실행한다.

```sh
sh mysql_gr_migrate.sh discover
sh mysql_gr_migrate.sh configure
sh mysql_gr_migrate.sh precheck
sh mysql_gr_migrate.sh initialize
sh mysql_gr_migrate.sh cutover
sh mysql_gr_migrate.sh status
```

전체 대화형 흐름을 처음부터 실행할 때:

```sh
sh mysql_gr_migrate.sh all
```

작업 위치와 클라이언트 경로가 필요하면 실행 환경에서 지정한다. 아래 경로는 설명용 자리표시자이므로 실제 경로로 변경한다.

```sh
export MYSQL_GR_WORK_ROOT=/absolute/path/mysql_gr_work
export MYSQL_GR_MYSQL=/absolute/path/mysql
export MYSQL_GR_MYSQLDUMP=/absolute/path/mysqldump
sh mysql_gr_migrate.sh discover
```

기본 작업 위치는 현재 디렉터리의 `mysql_gr_work`다. 이후 단계에서도 같은 경로를 사용한다. 비밀번호는 매 실행 시 다시 입력한다. 상태 파일은 쉘 코드로 `source`하지 않는다.

## 단계별 동작

| 단계 | 동작과 변경 범위 |
|---|---|
| discover | 전환 방식·Primary 모드·멤버·접속·광고 주소·XCom 포트·TLS 수집. DB 변경 없음 |
| configure | 버전별 런타임 변수 확인 후 필수 cnf 조각 생성. 로컬 및 SSH 원격 적용은 선택. SSH 미사용 시 복사할 Helper 출력. 원본 옆 백업과 실제 mysqld 바이너리의 `--validate-config` 확인 후 적용 |
| precheck | UUID·server_id·동일 버전·GR 필수 변수·필터·직접 Source 연결·테이블 키·엔진·XA·TLS·포트 검사 |
| initialize | 애플리케이션 중단 확인, 전체 멤버 쓰기 차단·Event Scheduler 중지, Source GTID 고정, 기존 Replica 추격 또는 신규 노드 dump 적재, 스키마/업무 검증 |
| cutover | 사전 조건 재확인, 선택한 async Channel만 STOP, GR Plugin·SET PERSIST·복구 계정 설정, Node 1 한 번만 Bootstrap, 나머지 Join, 모드별 검증 |
| join | 부트스트랩 노드가 ONLINE인 기존 그룹에 Join 재개. 새 Bootstrap 없음 |
| validate | 예상 UUID 전체·ONLINE 개수·모드별 역할·GTID 추격·Applier 오류·Secondary 쓰기 차단·Multi AUTO_INCREMENT 검증 |
| release | 검증 후 확인 문구 입력 시 Single의 Node 1 또는 Multi 전체 멤버 쓰기 차단 해제 |
| status | 각 노드의 GR 멤버·복제 채널·Worker 오류·쓰기 차단·Event Scheduler 조회 |

`all`도 사용자 입력 없이 변경하지 않는다. 설정 적용·재시작·데이터 적재·전환 등 변경 단계에서 실제 작업 내용을 확인한다. configure에서 재시작을 생략했다면 이후 precheck가 변경 전 런타임값을 발견하고 중단할 수 있다. 재시작 후 해당 단계부터 진행한다.

## 설정 및 재시작

- 기존 설정을 유지하면서 전용 `[mysqld]` 블록을 추가/교체한다. 기존 `log_bin`이 ON이면 파일 이름을 바꾸는 `log_bin` 설정을 추가하지 않는다.
- 변수 지원 여부는 실제 인스턴스에서 확인한다. `transaction_write_set_extraction`, `replica_parallel_type`, `master_info_repository`, `relay_log_info_repository`는 존재할 때만 넣는다.
- production은 `sync_binlog=1`, `innodb_flush_log_at_trx_commit=1`, `binlog_row_image=FULL`과 입력한 Binary Log 보존 기간을 추가한다. I/O 증가 가능성을 안내한다.
- 여러 로컬 인스턴스가 같은 cnf를 사용하는 경우에는 자동 편집을 차단한다. 인스턴스별 그룹 구성을 확인한 뒤 직접 적용한다.
- 실제 PID의 cgroup과 systemd MainPID가 일치할 때 선택한 서비스만 재시작한다.
- 단독 직접 기동은 원래 바이너리·인자·`--defaults-file`·Datadir 소유자를 확인한 경우에만 선택적으로 재시작한다. `mysqld_safe` 등 Supervisor 또는 기동 방식이 불명확하면 해당 Launcher를 통해 수동 재시작한다.
- 원격 인스턴스는 `configure`에서 `ssh/manual`을 선택한다. SSH로 실제 cnf·PID·UUID를 확인한 뒤 백업·검증·적용·재시작하거나, 동일 검증을 수행하는 Helper를 해당 서버로 복사해 실행한다.
- GR Plugin은 `INSTALL PLUGIN`으로 설치한다. 추가적인 `plugin_load_add` 중복 설정을 만들지 않는다.
- GR 자체 설정은 지원 변수를 확인한 후 `SET PERSIST`로 저장한다. 기존 `mysqld-auto.cnf` 값이 cnf보다 우선할 수 있으므로 최종 런타임 검증을 통과해야 한다.

## Single / Multi Primary

| 항목 | Single | Multi |
|---|---|---|
| group_replication_single_primary_mode | ON | OFF |
| group_replication_enforce_update_everywhere_checks | OFF | ON |
| 완료 시 역할 | Node 1 PRIMARY, 나머지 SECONDARY | 전체 PRIMARY |
| 쓰기 차단 해제 대상 | Node 1 | 전체 멤버 |
| AUTO_INCREMENT | 기존 값 유지 | 간격=멤버 수, Offset=등록 순서(1부터) |

Multi에서는 SERIALIZABLE 기본 격리 수준과 CASCADE/SET NULL 외래키를 차단한다. 세션별 SERIALIZABLE 사용, 다른 멤버에서 같은 테이블에 동시에 수행하는 DDL/DML, 쓰기 충돌 재시도는 애플리케이션 검토 대상이다. AUTO_INCREMENT 설정 변경 이후 기존 세션은 재연결해야 한다. 멤버 수 변경 자동화는 이 버전의 범위가 아니므로 이후 증설 시 Offset 계획을 다시 검토한다.

## 초기 데이터와 계정

권위 있는 데이터를 가진 인스턴스는 항상 Node 1이다. 서로 다른 Standalone DB의 데이터를 자동 병합하지 않는다.

- `dump`: GTID 이력과 업무 Database가 없는 새 인스턴스만 허용한다. Source의 **전체 업무 Database**, Trigger·Routine·Event를 포함하며 시스템 DB의 계정/권한은 복사하지 않는다. Source 쓰기 차단 상태에서 수행한다.
- Dump와 SHA-256, Restore 로그를 보관한다. Restore 중에는 해당 새 인스턴스의 쓰기 차단을 일시 해제하고 성공·실패/일반 종료 신호 시 복구한다.
- 복원된 Event는 `sql_log_bin=0` 세션에서 개별 DISABLE한다. 완료 후에도 Scheduler를 자동 활성화하지 않는다.
- 기존 계정·DEFINER 및 업무 권한은 대상 인스턴스에 준비되어 있어야 한다.
- `already`: 신뢰할 수 있는 방식으로 전체 데이터와 GTID 이력이 준비된 경우에만 선택한다.
- `external`: Physical Backup/Clone 등 외부 초기화를 완료한 뒤 `already`로 확인한다. 스크립트가 Clone을 실행하지 않는다.
- 동일 GTID가 동일 데이터를 증명하지는 않는다. 테이블·컬럼 Manifest를 비교하고, 선택한 업무 검증 SQL의 결과도 비교한다. 검증 SQL을 제공하지 않으면 전체 데이터 정합성을 외부에서 검증했다는 확인이 필요하다.
- 업무 검증 SQL은 각 서버에서 동일한 순서의 결과를 내는 SELECT로 작성한다. READ ONLY 트랜잭션으로 감싸지만, 임의 관리 SQL을 안전한 SELECT로 변환/분석하는 도구는 아니다.

XCom의 Incremental Recovery 계정에는 `REPLICATION SLAVE`, `CONNECTION_ADMIN`을 사용한다. 신규 계정은 각 서버에서 `sql_log_bin=0`으로 생성해 계정 작업이 Errant GTID를 만들지 않게 한다. 기본 인증 플러그인을 사용하며 `mysql_native_password`를 강제하지 않는다. 기존 계정은 권한·잠금·TLS 요구 조건을 조회하고 사용자가 검토한다.

관리 비밀번호는 권한 600인 임시 Client Option File에 저장하고 종료 시 삭제한다. 복구 비밀번호는 프로세스 인자나 영구 작업 로그에 출력하지 않는다. 다만 `CHANGE REPLICATION SOURCE TO`로 설정한 복구 자격 증명은 **MySQL 복제 메타데이터에 저장된다**.

## 실패 및 재시작 정책

- `RESET MASTER`, `RESET BINARY LOGS AND GTIDS`, `RESET REPLICA ALL`을 실행하지 않는다.
- 기존 async Channel은 선택한 것만 STOP하고 메타데이터를 남긴다.
- `skip_replica_start=ON`을 사전 설정해 서버 재기동으로 기존 async 복제가 자동 재개되는 것을 방지한다. 초기화 단계에서는 선택한 기존 Channel을 명시적으로 START하고 GTID 추격 후 전환 시 STOP한다.
- `group_replication_start_on_boot=OFF`, `group_replication_bootstrap_group=OFF`가 기본이다. 재기동 이후 GR 운영 기동/전체 그룹 장애 복구는 별도 절차로 처리한다.
- 실패 시 이전 복제 모드로 자동 되돌리지 않는다. 쓰기 차단과 중지한 Channel을 보존하고 실제 상태를 확인한다.
- Bootstrap 시도 기록이 있으면 cutover 재실행으로 또 Bootstrap하지 않는다. Node 1이 ONLINE이면 `join`을 사용한다. Node 1이 OFFLINE이거나 전체 그룹이 중단되었다면 가장 최신 멤버 판정이 필요한 별도 복구 작업이다.
- SIGKILL, 서버/OS 장애에서는 종료 Trap을 실행할 수 없다. 남은 작업 잠금·임시 자격 증명·쓰기 차단·Bootstrap 값을 확인해야 한다.
- 일부 Restore 실패는 대상에 데이터와 GTID가 남을 수 있다. 임의로 GTID만 지우지 말고 대상의 재초기화 범위를 검토한다.

## 지원·검증 범위

- Oracle MySQL **8.0.27 이상 8.0.x, 8.4.x, 9.7.x**를 지원 대상으로 구현했다. 초기 그룹 구성은 정확히 같은 서버 버전만 허용한다. 다른 9.x 버전, MariaDB, Percona 및 업그레이드 중 혼합 버전은 차단한다.
- IPv4/DNS, XCom 사용. IPv6, NAT/외부 포트 매핑, MYSQL 통신 Stack, Multi-source/복제 필터, 기존 활성 그룹 재구성은 별도 구현 대상이다.
- 인증서 생성·배포, 자동 Failover/Router 설정, Physical Backup/Clone 자체 수행은 포함하지 않는다. 활성 Clone Plugin이 있으면 의도치 않은 Clone 복구를 방지하기 위해 사전 검증에서 중단한다.
- 셸 문법 및 모의 SQL 회귀 검증은 수행했다. 이 개발 환경에는 MySQL 서버가 없어 **실제 3개 인스턴스에서 GTID/Standalone → Single/Multi 전환을 수행한 통합 검증은 미실시**다. 이 버전을 실서버 검증 완료로 간주하면 안 된다.
- `VALIDATION.md`에 통과한 검증 항목과 범위를 기록했다. `python3 test_gr.py`로 모의 검증을 재현할 수 있다.

## 참고한 문서

사용자 문서:

- [Replication(GTID) 구축 자동화 v1.0.23](https://app.notion.com/p/Replication-GTID-3d0dd8bb770e80ac92b5d2431c0242e8)
- [Group Replication](https://app.notion.com/p/Group-Replication-35fdd8bb770e80148b96e507cb48246d)
- [Group Replication 구성](https://app.notion.com/p/363dd8bb770e808f9cd0f6c48aa0ab54)

공식 문서:

- [MySQL 8.0 GR Requirements](https://dev.mysql.com/doc/refman/8.0/en/group-replication-requirements.html)
- [MySQL 8.4 GR Requirements](https://dev.mysql.com/doc/refman/8.4/en/group-replication-requirements.html)
- [MySQL 9.7 GR Requirements](https://dev.mysql.com/doc/refman/9.7/en/group-replication-requirements.html)
- [Multi-Primary Mode](https://dev.mysql.com/doc/refman/8.4/en/group-replication-multi-primary-mode.html)
- [Deploying Group Replication Locally](https://dev.mysql.com/doc/refman/8.4/en/group-replication-deploying-locally.html)
- [Distributed Recovery Credentials](https://dev.mysql.com/doc/refman/8.4/en/group-replication-user-credentials.html)
- [GR TLS](https://dev.mysql.com/doc/refman/8.4/en/group-replication-secure-socket-layer-support-ssl.html)
- [GR System Variables](https://dev.mysql.com/doc/refman/8.4/en/group-replication-system-variables.html)
- [Replica Options / skip_replica_start](https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html)


## v1.0.1 — 미완료 등록 재시도

`discover` 도중 중단되어 `meta/count`만 남은 경우, 등록 정보를 `discovery_backups/시간_PID/`에 보존하고 처음부터 다시 입력받는다. 기존 작업 디렉터리 전체를 삭제하거나 DB를 초기화하지 않는다. 등록 완료 파일이나 설정·초기화·전환 진행 흔적이 있으면 자동 재등록을 차단한다. `discover` 실패 안내는 DB 변경을 수행하지 않았음을 구분해 표시한다.

기존 파일을 v1.0.2 전체 코드로 교체한 뒤 같은 작업 디렉터리에서 재실행한다. 파일명을 `gr_migrate.sh`로 저장한 경우:

```sh
sh gr_migrate.sh --version
sh gr_migrate.sh discover
```

## v1.0.2 — 원격 cnf 적용 및 복사 방식

기존 `discover` 등록을 유지한 채 `sh gr_migrate.sh configure`를 실행한다. 원격으로 등록된 각 인스턴스에서 `ssh/manual`을 선택한다. Primary부터 등록 순서대로 처리하며, Secondary의 수동 작업을 마친 후 `precheck`로 전체 런타임을 확인한다.

### 이전 GTID 설정 정보 활용

기존 GTID 쉘의 `.mysql_gtid_replication.state`에는 `SOURCE_CNF`, `REPLICA_CNF`가 있다. 다만 원격 처리에서 값이 비어 있을 수 있으므로 존재 여부를 확인한다. 접속 Socket 또는 Host·Port가 일치하는 항목의 경로만 후보로 가져온다. 해당 경로가 현재 사용 중인지 실제 대상 서버에서 다시 검증한다. 새로 추가하는 세 번째 인스턴스의 경로는 별도로 탐지한다.

기존 상태 파일이 다른 위치에 있으면:

```sh
export MYSQL_GR_GTID_STATE_FILE=/actual/path/.mysql_gtid_replication.state
sh gr_migrate.sh configure
```

상태 파일을 쉘 코드로 실행하거나 `source/eval`하지 않는다. 기존 스크립트가 쓴 단순 따옴표 값만 읽는다. 복잡한 인용 형태는 자동으로 해석하지 않고 경로를 직접 선택한다.

### SSH 사용 가능

1. SSH Host·Port·OS 계정과 선택적인 개인키 경로 입력. SSH Port 기본값은 현재 SSH 설정에서 조회한다.
2. 현재 OS 권한 또는 `sudo -n` 사용 선택. SSH 비밀번호/키 암호는 OpenSSH가 처리한다. `sshpass`를 사용하지 않는다.
3. 대상 서버의 로컬 Socket으로 재접속해 Controller가 조회한 UUID·Datadir·Socket·PID File과 일치하는지 확인. Socket 인증이 다르면 별도 MySQL 계정을 입력한다.
4. 실행 중인 PID·바이너리·`--defaults-file`·런타임 변수의 `VARIABLE_PATH`로 현재 cnf 후보 확인 및 선택.
5. 현재 cnf 내용으로 수정 후보를 만들고, 실제 mysqld 바이너리의 `--validate-config`로 검증. 기존 명령행 Override를 유지한다.
6. 적용 확인 후 원본 옆에 버전/시간별 백업 생성·내용 비교, 파일 권한과 소유권·파일 메타데이터를 보존한 후보로 교체.
7. 선택한 경우 해당 인스턴스만 재시작. 재접속 후 UUID와 생성한 설정의 실제 Runtime 값까지 비교한다.

systemd는 실제 MainPID가 일치하는 서비스만 사용한다. 직접 기동은 기존 실행 인자를 재사용하고, mysqld_safe는 확인된 기존 Wrapper 인자·작업 디렉터리·실행 OS 계정을 유지한다. Launcher가 불명확하거나 OS 권한이 부족하면 자동 재시작을 차단한다. SSH Host Key 검증은 해제하지 않는다.

### SSH 불가 / 사용자가 복사하여 적용

`manual`을 선택하면 `runs/실행번호/node_번호_apply_config.sh`를 생성하고 전체 내용을 화면에 출력할지 묻는다. SSH 점검 실패 또는 ssh 명령 미설치 시에도 이 경로를 제공한다. 파일 전송이 어려우면 화면의 Helper 전체 내용을 복사해서 Secondary 서버에 파일로 저장한다.

예를 들어 Node 2에서는:

```sh
sh node_2_apply_config.sh
```

Helper는 해당 서버에서 아래 순서로 실행한다.

1. 로컬 Socket 접속용 MySQL 계정·비밀번호 입력. 생성된 Helper에는 비밀번호가 없다.
2. 실제 인스턴스 정보와 현재 사용하는 cnf 확인·경로 선택.
3. **현재 cnf 내용을 복사해 기존 설정을 유지하는 후보 파일 생성 → 필요한 설정 병합 → 전체 수정 후보 내용을 화면에 출력.**
4. 실제 mysqld로 검증 후 사용자가 `APPLY`를 입력했을 때만 원본 백업·내용 비교·교체.
5. 재시작 여부를 별도로 선택. 재시작했다면 UUID와 실제 설정값 검증.

원본을 새 설정 조각으로 통째로 덮어쓰지 않는다. 중복 실행 잠금, 기존 cnf 공유 여부, 동시 외부 수정 여부를 검사한다. 심볼릭 링크·하드 링크, 그룹별 옵션 파일 등 자동 편집 대상을 확정하기 어려운 구성은 중단한다.

**SSH 접속 불가와 MySQL/GR 통신 불가는 구분한다.** Controller의 MySQL TCP 접속은 원격 인스턴스 등록·검증에 필요하다. 그룹 구성 완료에는 멤버 간 MySQL 복구 연결과 XCom 통신이 필요하다. 네트워크가 모두 차단된 상태를 파일 복사만으로 GR 정상 구성 상태로 만들 수는 없다.

### 의존성과 검증 범위

실행은 POSIX sh·기존 MySQL 클라이언트·Linux 기본 명령을 사용한다. SSH 방식을 선택할 때만 기존 OpenSSH를 사용한다. sudo는 선택 사항이다. `pip`, `npm`, `sshpass`, MySQL Shell 및 외부 Python 모듈을 설치/사용하지 않는다.

추가 검증은 임시 파일과 모의 명령으로 수행했다. 실제 원격 SSH 로그인·systemd/mysqld_safe 재기동·실제 MySQL GR 전환 통합 검증은 미실시다. 구체적인 검증 항목은 `VALIDATION.md`를 참조한다.

추가 공식 참고:

- [OpenSSH ssh](https://man.openbsd.org/ssh)
- [MySQL Server Configuration Validation](https://dev.mysql.com/doc/refman/8.4/en/server-configuration-validation.html)
- [MySQL variables_info](https://dev.mysql.com/doc/refman/8.0/en/performance-schema-variables-info-table.html)
