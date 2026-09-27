# MySQL GTID Replication 자동화

`mysql_gtid_replication.sh`는 Oracle MySQL의 GTID 기반 비동기 Replication 구성을 자동화하기 위한 쉘입니다. 인스턴스 식별, GTID 이력, 설정 파일 변경, 초기 데이터 동기화, Replication 계정 생성, TLS 구성, 검증 과정을 단계별로 수행합니다.

## 지원 범위

- Oracle MySQL 8.0 / 8.4 / 9.x GTID Replication
- Source와 Replica가 동일 서버에 있는 구성
- Source와 Replica가 서로 다른 서버에 있는 구성
- Unix Socket 또는 TCP 기반 관리 접속
- 동일 서버의 다중 MySQL 인스턴스
- 기본 채널 또는 Named Replication Channel
- 로컬 `my.cnf` 자동 탐지 및 안전한 설정 반영
- 원격 서버에서 OS 설정 파일에 직접 접근할 수 없는 환경
- `mysqldump` 기반 Logical Provisioning
- Physical Backup / Clone 등 외부 Provisioning 연계

MariaDB GTID는 지원하지 않습니다.

## 전체 수행 흐름

```text
discover
  -> configure (필요한 경우)
  -> precheck
  -> initialize
  -> replicate
  -> validate
  -> status
```

단계별 실행 예시는 다음과 같습니다.

```bash
sh mysql_gtid_replication.sh discover
sh mysql_gtid_replication.sh configure
sh mysql_gtid_replication.sh precheck
sh mysql_gtid_replication.sh initialize
sh mysql_gtid_replication.sh replicate
sh mysql_gtid_replication.sh validate
sh mysql_gtid_replication.sh status
```

`all`은 일반적인 전체 흐름을 순차 실행합니다. 다만 재시작, GTID 충돌, 데이터 초기화처럼 운영 판단이 필요한 구간은 자동으로 강행하지 않고 사용자 확인 또는 별도 조치를 요구합니다.

## discover

실행 중인 MySQL 인스턴스와 접속 정보를 탐지합니다.

가능한 경우 다음 항목을 자동 탐지합니다.

- 실행 중인 `mysqld` 프로세스
- Unix Socket 후보
- MySQL 관련 systemd Service
- `my.cnf` 후보
- 실제 Runtime `port`
- `datadir`
- `server_id`
- `server_uuid`
- MySQL Version

단순히 입력한 Host/Port/Socket만 신뢰하지 않고 실제 Runtime 값을 통해 잘못된 인스턴스를 선택했는지 확인합니다.

TCP 접속의 경우 인스턴스 위치를 다음과 같이 구분합니다.

- `local` : 현재 쉘을 실행한 서버에 MySQL 인스턴스가 존재
- `remote` : 다른 서버에 MySQL 인스턴스가 존재

`remote`인 경우 컨트롤러 서버의 로컬 파일 경로를 해당 MySQL 서버의 설정 파일로 잘못 판단하지 않습니다.

## configure

GTID Replication에 필요한 설정을 확인하고, 필요한 경우 관리 블록을 생성합니다.

대표 설정은 다음과 같습니다.

```ini
server_id=<고유 값>
log_bin
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
log_replica_updates=ON
relay_log_recovery=ON
```

MySQL 버전에 따라 변수명이 변경된 항목은 Runtime에서 지원 여부를 확인한 후 사용합니다.

로컬 설정 파일을 변경할 때는 다음 순서로 처리합니다.

1. 실제 사용할 `my.cnf` 확인
2. 적용 예정 설정 출력
3. 기존 Script Managed Block 제거
4. 새 Candidate 설정 파일 생성
5. Option File 문법 검증
6. 지원되는 경우 `mysqld --validate-config` 수행
7. 원본 설정 파일 백업
8. 사용자 승인 후 실제 반영

기존 사용자 설정은 유지하고 Script가 관리하는 블록만 교체합니다.

## MySQL 재시작 처리

설정 변경 후 재시작이 필요한 경우 다음 방식 중 실제 환경을 탐지합니다.

- systemd
- `mysqld_safe`
- `mysqld --daemonize`
- 수동 관리 환경

안전한 재시작 방법을 판단할 수 없는 경우 임의의 명령으로 재시작하지 않고 필요한 명령과 다음 단계를 출력합니다.

동일 서버에 여러 인스턴스가 존재할 경우 선택한 인스턴스만 재시작하도록 Runtime PID, `datadir`, `my.cnf`, Service 정보를 함께 검증합니다.

## precheck

Replication 구성 전에 주요 필수 조건을 검증합니다.

주요 검증 항목:

- Source / Replica `server_uuid` 중복 여부
- Source / Replica `server_id` 중복 여부
- `server_id`가 0인지 여부
- Source -> Replica Version 호환성
- `log_bin`
- `gtid_mode=ON`
- `enforce_gtid_consistency=ON`
- `log_replica_updates`
- `binlog_format`
- Non-InnoDB Table 존재 여부
- Source Binary Log 보존 시간

자동 구성에서는 `ROW` Binary Logging을 기준으로 동작합니다.

## initialize

Replica의 초기 데이터를 구성합니다.

지원 방식:

- `online-dump`
  - `mysqldump`를 이용한 Logical 초기화
  - 테스트 또는 중소 규모 데이터 환경에 적합

- `already`
  - 데이터 복사 없이 현재 Replica를 사용
  - Source와 데이터 및 GTID 이력이 이미 일치한다고 검증된 경우에만 사용

- `external`
  - Physical Backup, Clone, Backup Tool 등 별도 Provisioning 사용

- `skip`
  - 초기화 작업을 수행하지 않고 종료

## GTID 비교 방식

GTID 문자열을 쉘에서 직접 파싱하지 않고 MySQL의 GTID 함수를 사용합니다.

```sql
GTID_SUBTRACT(replica_gtid_executed, source_gtid_executed)
```

위 결과는 Replica에만 존재하는 Extra GTID입니다.

```sql
GTID_SUBTRACT(source_gtid_executed, replica_gtid_executed)
```

위 결과는 Replica가 아직 수행하지 않은 Missing GTID입니다.

이를 기준으로 다음과 같이 판단합니다.

```text
Extra 없음 / Missing 없음
  -> GTID 기준 일치

Extra 없음 / Missing 있음
  -> Source 기준 Catch-up 가능 여부 확인

Extra 있음
  -> Diverged 상태
  -> 자동 GTID 삭제/초기화 금지
  -> Reprovision 또는 별도 정합성 검토 필요
```

## GTID 안전 정책

GTID는 단순 설정값이 아니라 트랜잭션 이력입니다.

따라서 다음 동작을 일반적인 자동 해결 방법으로 사용하지 않습니다.

```sql
RESET BINARY LOGS AND GTIDS;
```

또는 이전 버전의:

```sql
RESET MASTER;
```

이 명령은 Binary Log 및 GTID 실행 이력을 초기화하므로 복구 불가능한 변경이 될 수 있습니다.

또한:

```sql
RESET REPLICA;
RESET REPLICA ALL;
```

은 Replication Metadata와 Relay Log를 초기화하지만 기존 `gtid_executed`를 제거하는 용도가 아닙니다.

따라서 Replica에 Extra GTID가 존재하는 경우 단순히 Replication Channel을 Reset한 뒤 Dump를 다시 Restore하는 방식으로 해결하지 않습니다.

Extra GTID가 존재하면 다음 중 하나로 처리합니다.

- 현재 Extra GTID 내용을 검토하고 데이터 정합성 판단
- Source 기준 Replica Reprovision
- 별도 Backup / Restore 절차 수행
- 작업 중단

Extra GTID를 맞추기 위해 Empty Transaction을 자동 생성하지 않습니다.

## online-dump 초기화

Logical 초기화에서는 Source의 Application Database 전체를 대상으로 합니다.

기본 Dump 방식:

```text
--single-transaction
--quick
--skip-lock-tables
--triggers
--routines
--events
--hex-blob
--set-gtid-purged=ON
```

Replication Filter가 없는 기본 구성에서는 일부 Database만 초기화하지 않습니다.

Source Dump 후 Replica Restore까지 소요되는 동안 필요한 Binary Log가 삭제되지 않도록 Source의 Binary Log 보존 시간을 충분히 확보해야 합니다.

Non-InnoDB Table이 존재하면 `--single-transaction`만으로 완전한 시점 일관성을 보장할 수 없으므로 별도 경고를 출력합니다.

## Replica Write Protection

Restore 과정에서 Replica가 `read_only` 또는 `super_read_only` 상태인 경우 필요한 구간에 한해서 임시 해제합니다.

Restore 완료 후 기존 상태로 복원합니다.

운영 환경에서 Replica의 Event Scheduler 활성 여부도 반드시 검토해야 합니다.

## Replication 계정

Replication Connection 계정은 최소 권한을 기본으로 합니다.

```sql
GRANT REPLICATION SLAVE ON *.* TO '<user>'@'<host>';
```

지원 방식:

- 새 전용 계정 생성
- 기존 Replication 계정 선택
- SQL만 출력

기존 계정에 Replication 외의 과도한 권한이 존재하는 경우 경고합니다.

비밀번호는 대화형으로 입력하며 Persistent State File에 저장하지 않습니다.

## TLS

운영 환경에서는 TLS 사용을 기본 권장합니다.

지원 방식:

- CA + Hostname/IP 검증
- 암호화만 사용하고 Server Identity 검증 생략
- Plain TCP

`verify-identity` 사용 시 Replica 서버에서 CA 파일에 접근할 수 있어야 하며 Source 인증서의 SAN/CN과 실제 접속 Host/IP가 일치해야 합니다.

Plain TCP는 별도 보호망에서만 사용하도록 명시적인 확인 절차를 둡니다.

## 동일 서버 다중 인스턴스

동일 서버에 여러 MySQL 인스턴스가 존재하는 환경을 지원합니다.

예:

```text
3306 / /etc/my.cnf
3307 / /etc/my2.cnf
3308 / /etc/my3.cnf
```

이 경우 Socket, `datadir`, `server_id`, `server_uuid`, PID, 설정 파일을 함께 확인하여 잘못된 인스턴스를 변경하지 않도록 합니다.

## 서로 다른 서버 구성

Source와 Replica가 서로 다른 서버에 있어도 TCP 접속을 통해 Runtime 정보를 확인할 수 있습니다.

다만 Controller에서 원격 서버의 OS 파일 시스템에 접근할 수 없는 경우 `my.cnf`를 직접 수정할 수 없습니다.

이 경우 자동화 원칙은 다음과 같습니다.

```text
원격 OS 작업 필요
  -> Controller에서 직접 수행 가능한지 확인
  -> 직접 수행 불가능
  -> 실패하기 전에 필요한 설정/검증/재시작 명령 생성
  -> 사용자가 대상 서버에서 실행
  -> Runtime 재검증 후 다음 단계 진행
```

단순히 로컬 서버의 `/etc/my.cnf` 경로를 원격 서버에도 동일하게 적용하지 않습니다.

## 상태 및 작업 파일

기본 State File:

```text
.mysql_gtid_replication.state
```

기본 Work Root:

```text
mysql_gtid_replication_work/
```

실행 시 Timestamp 기준 작업 디렉터리를 생성하고 다음 자료를 저장합니다.

- 설정 Candidate
- 설정 검증 로그
- 설정 백업 경로
- Dump 파일
- SHA256 Checksum
- 계정 / 권한 확인 결과
- Replication 상태
- 오류 로그
- GTID 비교 결과

비밀번호는 Persistent State File에 저장하지 않습니다.

환경 변수로 경로를 변경할 수 있습니다.

```text
MYSQL_GTID_STATE_FILE
MYSQL_GTID_WORK_ROOT
```

## 재실행 시 주의사항

오류 발생 후에는 화면에 출력된 `NEXT STEP`과 Work Directory의 진단 파일을 먼저 확인합니다.

Replica에 Extra GTID가 존재하는 상태에서 `initialize`를 반복 수행해도 기존 GTID 이력은 사라지지 않습니다.

Replica를 새 인스턴스로 Reprovision하여 `server_uuid`가 변경된 경우 기존 State File을 그대로 사용하지 말고 `discover`부터 다시 수행해야 합니다.

## 운영 환경 주의사항

- Source는 사용자가 명시적으로 선택한 Authoritative Node를 기준으로 합니다.
- 대규모 운영 DB에서는 Logical Dump보다 Physical Backup 방식이 적합할 수 있습니다.
- Binary Log 보존 시간은 Dump + Restore + Catch-up 시간을 모두 포함해야 합니다.
- Non-InnoDB Table은 Online Logical Copy 시 별도 정합성 검증이 필요합니다.
- Event Scheduler가 Replica에서 실행되지 않도록 운영 정책을 확인해야 합니다.
- Replication Filter는 자동 추정하지 않습니다.
- GTID가 같다는 사실만으로 Row Data까지 동일하다고 판단하지 않습니다.

## 현재 버전

```text
mysql_gtid_replication.sh v1.0.14
```

현재 버전은 Replica의 GTID 이력을 임의로 초기화해서 진행하는 방식보다, 문제가 발견되면 증적과 다음 조치를 출력하고 안전하게 중단하는 방식을 우선합니다.