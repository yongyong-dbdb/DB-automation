# MySQL InnoDB Cluster Migration Automation

`mysql_innodb_cluster_migrate.sh`는 준비된 MySQL 인스턴스 또는 기존 Group Replication(GR) 구성을 **MySQL InnoDB Cluster**로 전환하기 위한 POSIX `/bin/sh` 자동화 스크립트다.

현재 스크립트 버전: **v1.0.45**

## 목적

- 기존 Standalone MySQL 인스턴스들을 신규 InnoDB Cluster로 구성
- 이미 ONLINE 상태인 Group Replication을 `adoptFromGR:true`로 InnoDB Cluster에 등록
- Single-primary / Multi-primary topology 보존
- 변경 전 SQL/GTID/GR/AdminAPI 검증
- MySQL Shell 기능 차이를 runtime capability detection으로 처리
- 동일 서버 다중 인스턴스 및 원격 인스턴스 고려
- 사용자 입력값과 자동 감지값을 분리해 명확하게 표시
- 실패 시 GTID reset, metadata drop, GR dissolve 같은 파괴적 복구를 자동 수행하지 않음

## 기본 원칙

- `/bin/sh` 호환
- 외부 패키지 및 별도 runtime 설치 금지
- `mysql`과 `mysqlsh`는 실행 전에 이미 설치되어 있어야 함
- Version, IP, Port, Socket, Hostname을 환경 고정값으로 하드코딩하지 않음
- MySQL Shell의 실제 AdminAPI help를 조회해 지원 옵션을 동적으로 판별
- 기존 데이터 디렉터리나 GTID를 자동 삭제/초기화하지 않음
- 기존 Group Replication을 임의로 중지/재구성하지 않음
- InnoDB Cluster metadata가 이미 존재하면 create/adopt로 덮어쓰지 않음
- `force:true`를 사용하지 않음
- 비밀번호는 파일/로그에 평문으로 남기지 않고 임시 권한 제한 파일을 사용
- mutation 단계는 명시적 사용자 confirmation 이후에만 실행

## 지원 범위

- Oracle MySQL GA 8.0+
- MySQL Shell AdminAPI
- Standalone/prepared instances → InnoDB Cluster
- Existing ONLINE Group Replication → InnoDB Cluster adoption
- Single-primary Group Replication
- Multi-primary Group Replication
- 동일 서버 다중 MySQL 인스턴스
- 서로 다른 서버의 MySQL 인스턴스
- TCP 접속 및 MySQL login-path 기반 bootstrap 인증

현재 스크립트는 자동 failover 테스트나 장애 주입 도구가 아니다. 실제 장애/복구 시나리오는 별도의 실서버 검증이 필요하다.

## 실행 전 요구사항

실행 호스트에 다음 명령이 이미 존재해야 한다.

```text
/bin/sh
mysql
mysqlsh
awk
sed
grep
sort
uniq
cmp
mktemp
stty
```

스크립트는 누락된 패키지를 설치하지 않는다.

MySQL 인스턴스는 AdminAPI 및 Group Replication 요구사항을 만족해야 하며 최종 판정은 `dba.checkInstanceConfiguration()`과 MySQL Shell 실행 결과를 기준으로 한다.

## Work Root

기본 작업 디렉터리:

```text
$(pwd)/mysql_innodb_cluster_work
```

변경하려면:

```sh
MYSQL_IC_WORK_ROOT=/path/to/work sh mysql_innodb_cluster_migrate.sh discover
```

사용할 binary를 명시적으로 변경할 수도 있다.

```sh
MYSQL_IC_MYSQL=/path/to/mysql \
MYSQL_IC_MYSQLSH=/path/to/mysqlsh \
sh mysql_innodb_cluster_migrate.sh discover
```

## 명령

```text
discover
capabilities
sql-precheck
strict-gtid
gr-restart-precheck
configure-admin
precheck
preflight [all|clone|tls|xcom]
configure
plan
create
adopt
validate
status
all
```

### `discover`

등록할 인스턴스를 탐색하고 다음 상태를 기록한다.

- server UUID
- server_id
- Version
- runtime port/socket
- hostname/report_host
- local / remote placement
- login-path 후보
- Group Replication 구성 여부
- Group Replication ONLINE membership
- Group name
- Single-primary / Multi-primary mode
- InnoDB Cluster metadata 존재 여부

동일 UUID, server_id, AdminAPI endpoint 중복을 이후 precheck에서 차단한다.

### `capabilities`

현재 설치된 MySQL Shell이 실제로 지원하는 AdminAPI option을 runtime에서 확인한다.

예:

- `adoptFromGR`
- `multiPrimary`
- `communicationStack`
- `localAddress`
- `memberSslMode`
- `ipAllowlist`
- `disableClone`
- `gtidSetIsComplete`
- `consistency`
- `exitStateAction`
- `expelTimeout`
- `autoRejoinTries`
- `memberWeight`
- `recoveryMethod`
- `cloneDonor`
- `waitRecovery`

지원하지 않는 옵션은 강제로 사용하지 않는다.

### `sql-precheck`

변경 없이 SQL/GR/topology 안전성 검사를 수행한다.

주요 검사:

- 등록 노드 identity 재검증
- GR member count / ONLINE 상태
- Group name / primary mode 일치
- GTID 관계 및 errant GTID 여부
- 동일 topology를 모든 노드에서 동일하게 관찰하는지 확인
- server_uuid / server_id / endpoint 중복
- cross-node 주요 system variable 일치
- `read_only` / `super_read_only` persistence 상태
- Single-primary / Multi-primary writeability
- Multi-primary cascade foreign key 제한
- Event Scheduler 사용 시 운영 정책 확인 요구
- 기존 InnoDB Cluster metadata 보호

### `strict-gtid`

애플리케이션 write가 정지된 시점에서 모든 등록 노드의 `@@GLOBAL.gtid_executed`가 정확히 동일한지 양방향 `GTID_SUBSET()` 비교로 검증한다.

운영 중 write가 계속 발생하는 환경에서는 순간적으로 GTID가 달라질 수 있으므로 planned cutover 직전에 사용하는 것이 적합하다.

### `gr-restart-precheck`

기존 GR configuration은 있으나 모든 member가 OFFLINE인 경우 읽기 전용으로 상태를 점검한다.

- 현재 active member가 없는지 재검증
- group name / primary mode가 discover 이후 변경되지 않았는지 확인
- bootstrap candidate 판단에 필요한 GTID superset 관계 확인

스크립트가 `group_replication_bootstrap_group=ON`을 자동 수행하지 않는다.

### `configure-admin`

InnoDB Cluster 관리용 AdminAPI 계정을 준비한다.

두 방식 중 선택한다.

- `create`: `dba.configureInstance(clusterAdmin=...)`를 통해 전용 계정 생성
- `existing`: 모든 등록 노드에 동일하게 존재하는 기존 계정을 검증 후 재사용

특징:

- 기존 계정 권한을 임의 확장하지 않음
- password policy를 약화하지 않음
- 일부 노드에만 계정이 생긴 partial state를 탐지
- 이번 실행에서 새로 만든 clusterAdmin만 선택적으로 rollback 가능
- 광범위한 `'user'@'%'` 사용 시 별도 확인 요구

### `precheck`

`sql-precheck` 결과와 함께 각 노드에서 `dba.checkInstanceConfiguration()`을 clusterAdmin으로 수행한다.

### `preflight [all|clone|tls|xcom]`

Clone/TLS/통신 사전 점검을 메인 스크립트에 통합했다. **실행용 쉘은
`mysql_innodb_cluster_migrate.sh` 하나만 필요하다.** 이전의 별도 preflight
쉘은 제거했으며, 외부 쉘을 source하거나 실행하지 않는다.

`discover` 완료 후 동일한 `MYSQL_IC_WORK_ROOT`를 사용한다.

```sh
sh mysql_innodb_cluster_migrate.sh preflight all
sh mysql_innodb_cluster_migrate.sh preflight clone
sh mysql_innodb_cluster_migrate.sh preflight tls
sh mysql_innodb_cluster_migrate.sh preflight xcom
sh mysql_innodb_cluster_migrate.sh preflight --help
```

- `clone`: OS/아키텍처, Clone 플러그인 상태, 확인 가능한 로컬 디스크 용량을 검사한다.
- `tls`: SSL 지원과 선택한 모드의 CA/호스트명 검증 접속을 확인한다.
- `xcom`: GR 통신 주소 형식/범위/중복과 가능한 TCP 연결을 검사한다. MYSQL 통신 스택도 처리한다.
- `all` 또는 생략: 위 세 점검을 실행한다.
- 실행 전에 discovery schema와 등록 노드 UUID를 재검증한다.
- DB/패키지/정책은 변경하지 않는다. 작업 폴더에는 제한된 임시 인증 파일과
  `preflight_gr_endpoints.tsv` 증적을 생성한다. 인증과 작업 잠금은 메인 스크립트를 사용한다.

선택 환경변수:

| 변수 | 의미 |
|---|---|
| `MYSQL_IC_CLONE_DONOR` | 등록된 donor 노드 번호, 기본 1 |
| `MYSQL_IC_CLONE_SPACE_MARGIN_PERCENT` | 디스크 여유율, 기본 10 |
| `MYSQL_IC_TLS_MODE` | AUTO / DISABLED / REQUIRED / VERIFY_CA / VERIFY_IDENTITY |
| `MYSQL_IC_TLS_CA` | 검증 접속에 사용할 실행 호스트의 CA 파일 |
| `MYSQL_IC_COMMUNICATION_STACK` | AUTO / XCOM / MYSQL |

이 변수는 **사전 점검에만 적용**된다. 이후 `create`의 실제 옵션 선택을 자동 변경하지 않는다.
실제 구성할 TLS/통신 옵션과 일치시켜 점검해야 한다.

결과는 `PASS`, `PASS_WITH_WARNINGS`, `PASS_WITH_MANUAL_CHECKS`로 구분한다.
오류는 비정상 종료하며, 경고/수동 확인이 남은 결과는 종료 코드 0이므로 출력도 확인한다.
원격 디스크와 노드 간 양방향 통신은 수동 검증이 남을 수 있다.
Clone 버전 호환성은 하드코딩하지 않고 실제 `addInstance()`의 AdminAPI 판정에 맡긴다.
이 명령은 SQL/AdminAPI 구성 요구사항을 검사하는 기존 `precheck`를 대체하지 않는다.
도움말은 MySQL 클라이언트나 discovery 정보 없이 조회할 수 있다.

### `configure`

명시적 확인 후 각 등록 노드에 다음을 실행한다.

```javascript
dba.configureInstance(undefined, {restart:false})
```

스크립트 자체는 MySQL Server restart를 자동 수행하지 않는다.

### `plan`

탐지된 상태에 따라 수행 가능한 다음 동작을 표시한다.

```text
GR state = none                -> create
GR state = online              -> adopt
GR state = configured-offline  -> restore existing GR first
GR state = partial-configured  -> manual review required
```

### `create`

GR에 속하지 않은 prepared instance들을 신규 InnoDB Cluster로 구성한다.

1. Node 1을 seed로 `dba.createCluster()` 실행
2. Node 2..N을 `Cluster.addInstance()`로 추가
3. 지원되는 경우 recovery method 선택
4. 모든 노드 추가 후 자동 `validate`

지원 가능한 선택 항목은 설치된 mysqlsh capability에 따라 달라진다.

예:

- single-primary / multi-primary
- XCOM / MYSQL communication stack
- XCOM `ipAllowlist`
- GR `localAddress`
- `memberSslMode`
- Clone enable/disable
- `recoveryMethod=auto|incremental|clone`

`clone` 선택 시 recipient dataset이 교체될 수 있으므로 별도의 파괴적 작업 confirmation을 요구한다.

### `adopt`

이미 ONLINE 상태인 unmanaged Group Replication을 InnoDB Cluster로 등록한다.

```javascript
dba.createCluster('<name>', {adoptFromGR:true})
```

보호 조건:

- 최소 3개 GR member
- 모든 member ONLINE
- 등록 node 수와 GR membership 완전 일치
- discover/precheck 당시 UUID와 membership 일치
- 기존 metadata 없음
- adoption 전/후 Single-primary / Multi-primary mode 동일
- adoption 전/후 GR membership/role snapshot 동일
- GTID convergence 확인

adoption은 기존 GR을 재생성하는 작업이 아니라 AdminAPI metadata를 생성해 관리 책임을 AdminAPI로 이관하는 작업이다.

## 최종 검증 (`validate`)

최종 검증은 AdminAPI와 Performance Schema를 함께 확인한다.

주요 항목:

- `dba.getCluster()` 성공
- `Cluster.status({extended:2})`
- `Cluster.describe()`
- `Cluster.options({all:true})`
- `Cluster.listRouters()`
- `mysql_innodb_cluster_metadata` 존재
- 모든 GR member ONLINE
- 등록 member 수 불변
- Single-primary / Multi-primary role 수 검증
- 모든 node에서 GR topology 동일
- GTID convergence 및 exact equality 확인
- Primary/Secondary `read_only` / `super_read_only` 상태 검증
- AdminAPI topology와 `performance_schema.replication_group_members` endpoint drift 검사
- `replication_group_member_stats` queue/conflict 관찰
- 최근 error log 필터 결과
- MySQL Router metadata 등록 상태

결과는 다음과 같이 분류한다.

```text
PASS
PASS_WITH_CHECKS
PASS_WITH_WARNINGS
FAIL
```

증적은 Work Root 아래에 저장된다.

```text
capabilities.txt
node_*.gtid.before
node_*.gtid.after
gr_members.before
gr_members.after
snapshots/
create.txt
adopt.txt
add_*.txt
validate.txt
status.txt
final_adminapi.txt
final_validation.txt
```

## 권장 실행 순서

### 신규 InnoDB Cluster

```sh
sh mysql_innodb_cluster_migrate.sh discover
sh mysql_innodb_cluster_migrate.sh capabilities
sh mysql_innodb_cluster_migrate.sh preflight all
sh mysql_innodb_cluster_migrate.sh sql-precheck
sh mysql_innodb_cluster_migrate.sh configure-admin
sh mysql_innodb_cluster_migrate.sh precheck
sh mysql_innodb_cluster_migrate.sh configure
sh mysql_innodb_cluster_migrate.sh precheck
sh mysql_innodb_cluster_migrate.sh plan

# planned cutover 시 write 정지 후 권장
sh mysql_innodb_cluster_migrate.sh strict-gtid

sh mysql_innodb_cluster_migrate.sh create
sh mysql_innodb_cluster_migrate.sh validate
sh mysql_innodb_cluster_migrate.sh status
```

### 기존 ONLINE Group Replication adoption

```sh
sh mysql_innodb_cluster_migrate.sh discover
sh mysql_innodb_cluster_migrate.sh capabilities
sh mysql_innodb_cluster_migrate.sh preflight all
sh mysql_innodb_cluster_migrate.sh sql-precheck
sh mysql_innodb_cluster_migrate.sh configure-admin
sh mysql_innodb_cluster_migrate.sh precheck
sh mysql_innodb_cluster_migrate.sh plan

# planned cutover 시 write 정지 후 권장
sh mysql_innodb_cluster_migrate.sh strict-gtid

sh mysql_innodb_cluster_migrate.sh adopt
sh mysql_innodb_cluster_migrate.sh validate
sh mysql_innodb_cluster_migrate.sh status
```

## 안전상 자동 수행하지 않는 작업

다음 작업은 자동화하지 않는다.

- `RESET MASTER` / `RESET BINARY LOGS AND GTIDS`
- GTID rewrite
- 기존 datadir 삭제
- InnoDB Cluster metadata drop
- GR dissolve
- 기존 GR의 강제 bootstrap
- `group_replication_force_members` 자동 설정
- password policy 완화
- 광범위 계정 자동 권한 상승
- package 설치
- MySQL/MySQL Shell 자동 upgrade
- 무조건적인 MySQL restart

## 운영 전 추가 검증

스크립트가 PASS라도 실제 운영 투입 전 다음 항목은 별도 검증이 필요하다.

1. MySQL Router를 통한 application read/write routing
2. Primary 장애 후 automatic election 및 Router failover
3. Secondary stop/start 및 auto-rejoin
4. Network partition / quorum loss 정책
5. complete outage 복구 절차
6. Clone recovery를 사용할 경우 실제 donor/recipient provisioning 및 disk capacity
7. TLS `VERIFY_CA` / `VERIFY_IDENTITY` 사용 시 실제 CA chain과 hostname/SAN 검증
8. SELinux/firewall 환경의 Classic/XCOM/MYSQL communication port reachability
9. backup/restore 및 PITR 절차
10. monitoring/alerting 기준과 `replication_group_member_stats` 추세 기준

## 주의사항

InnoDB Cluster로 관리되기 시작한 이후에는 Group Replication 설정을 SQL이나 option file로 임의 변경하지 않고 가능한 한 MySQL Shell AdminAPI를 통해 관리한다.

특히 다음 항목은 topology 전체와 장애 동작에 직접 영향을 줄 수 있으므로 운영 정책을 별도로 확정해야 한다.

- `group_replication_consistency`
- `group_replication_exit_state_action`
- `group_replication_autorejoin_tries`
- `group_replication_member_expel_timeout`
- `group_replication_unreachable_majority_timeout`
- `memberWeight`
- communication stack / localAddress
- TLS mode
- MySQL Router routing policy
