# MySQL Community RPM Bundle 설치 자동화

`mysql_install_auto.sh`는 Oracle MySQL Community RPM Bundle을 기준으로 신규 MySQL 인스턴스 설치를 자동화하는 POSIX `/bin/sh` 스크립트다.

현재 스크립트 버전: **v1.0.11**

## 목적

- `bundle.tar` 내부 RPM 메타데이터 기반 대상 MySQL Version/Release/Architecture 자동 판별
- 특정 Version, Port, Socket, Data Directory, option file, Service, OS 계정 하드코딩 최소화
- 동일 서버 다중 인스턴스 및 별도 서버 환경 고려
- 실제 변경 전 Precheck/Dry-run/Plan 출력
- 기존 MySQL 인스턴스와의 충돌 사전 검증
- Custom Path/Port 사용 시 SELinux 정책 적용 선택
- 설치 실패 시 인스턴스 단위 Rollback
- 설치 후 Service/PID/User/Binary/Port/Socket/Error Log/SELinux 검증

## 지원 범위

- Oracle MySQL Community RPM Bundle
- RHEL 호환 EL RPM 환경
- `systemd` 기반 서비스 관리
- MySQL 8.x / 9.x
- 동일 서버 복수 `mysqld` 환경
- 별도 `my.cnf`, Data Directory, Log, Socket/PID Directory 구성
- Classic Protocol 및 선택적 MySQL X Protocol
- SELinux Enforcing/Permissive 환경
- 외부 Repository 미사용 Local RPM 설치와 활성 OS Repository 사용 방식

스크립트 자체는 Python, Node.js 등의 외부 Runtime을 요구하지 않는다.

## 실행 조건

- `root` 실행
- `rpm`, `tar`, `systemctl` 사용 가능 상태
- 실제 Package 설치 시 `dnf` 또는 `yum` 사용 가능 상태
- SELinux 정책 적용 선택 시 `semanage`, `restorecon` 사용 가능 상태
- Oracle MySQL Community RPM Bundle 사전 준비

예시 Bundle:

```text
mysql-8.0.46-1.el8.x86_64.rpm-bundle.tar
```

파일명에 Version이 포함되어 있을 필요는 없다. 실제 Version은 Bundle 내부 `mysql-community-server` RPM 메타데이터에서 판별한다.

## 실행 모드

### 1. Precheck

변경 없이 Bundle/Host/기존 Package/실행 중인 인스턴스 상태 확인.

```sh
sh mysql_install_auto.sh \
  --bundle /path/mysql-8.0.xx-1.el8.x86_64.rpm-bundle.tar \
  --precheck-only
```

### 2. Dry-run

사용자 입력과 충돌 검증까지 수행하고 최종 `my.cnf` 및 systemd Plan 출력. 실제 Package/Config/Directory/SELinux/systemd 변경 없음.

```sh
sh mysql_install_auto.sh \
  --bundle /path/mysql-8.0.xx-1.el8.x86_64.rpm-bundle.tar \
  --dry-run
```

### 3. Install

최종 Plan 확인 후 사용자 승인 시 실제 설치 및 인스턴스 초기화 수행.

```sh
sh mysql_install_auto.sh \
  --bundle /path/mysql-8.0.xx-1.el8.x86_64.rpm-bundle.tar
```

## 처리 흐름

1. RPM Bundle 자동 탐지 또는 경로 입력
2. Bundle 압축 해제 및 RPM 메타데이터 판별
3. Version/Release/Architecture/Vendor 검증
4. Host OS/Architecture 호환성 검증
5. RPM Signature 검증
6. 기존 MySQL/MariaDB/Percona Package 및 실행 프로세스 검증
7. 기존 MySQL Package와 Bundle Version 비교
8. 실행 중인 `mysqld`, TCP Port, Unix Socket 확인
9. 기존/중지 systemd Unit의 `--defaults-file` 및 option file 확인
10. 사용자 입력 수집
11. Port/Socket/Path/Service/SELinux 충돌 검증
12. Minimum 또는 Production Profile 선택
13. 최종 설치 Plan 및 생성 예정 `my.cnf` 출력
14. 사용자 승인
15. Package 신규 설치 또는 동일 Version Package 재사용
16. OS 계정 확인/선택적 생성
17. Directory 및 option file 생성
18. SELinux Context/Port Policy 선택적 적용
19. `mysqld --validate-config` 기반 Config 검증
20. `mysqld --initialize` 기반 Data Directory 초기화
21. 전용 systemd Unit 생성 및 기동
22. Service/PID/User/Binary/Port/Socket/Error Log/SELinux 사후 검증

## 주요 사용자 입력

- MySQL OS 계정
- Instance Root Directory
- systemd Service Name
- 별도 `my.cnf` 경로
- Data Directory
- Log Directory
- Socket/PID Directory
- `secure_file_priv` Directory
- MySQL SQL Port
- TCP 사용 여부 및 `bind-address`
- MySQL X Protocol 사용 여부, Port 및 Bind Address
- `minimum` / `production` Profile
- SELinux Context/Port Policy 적용 여부
- Package 신규 설치 시 Local-only / Enabled Repository 의존성 처리 방식

## my.cnf Profile

### Minimum

신규 인스턴스 기동에 필요한 최소 항목 중심 구성.

```text
user
port
datadir
socket
pid-file
log-error
secure-file-priv
bind-address 또는 skip-networking
mysqlx 관련 설정
```

### Production

Minimum 항목에 운영 기본값 선택 항목 추가.

```text
innodb_flush_log_at_trx_commit=1
sync_binlog=1
max_connections=<USER_INPUT>
local_infile=OFF
```

추가 선택:

- Dedicated Server/VM: `innodb_dedicated_server=ON`
- 공유 Host: `innodb_buffer_pool_size` 직접 입력 또는 MySQL 기본값 유지
- Slow Query Log 사용 여부
- `long_query_time` 입력

이미 다른 `mysqld` 또는 기존 MySQL Config가 발견된 Host에서 `innodb_dedicated_server` 선택 시 추가 확인 수행.

## 다중 인스턴스 충돌 검증

동일 서버에 여러 MySQL 인스턴스가 존재할 수 있음을 기본 전제로 검증.

검사 대상:

- 실행 중인 모든 `mysqld` PID
- Classic Protocol Port
- MySQL X Protocol Port
- Unix Socket / Socket Lock
- PID File
- Data Directory
- Error Log / Slow Query Log / Initialization Log
- `secure_file_priv` Directory
- option file
- systemd Service Name
- 실행 중인 프로세스의 `--defaults-file`
- 중지된 MySQL systemd Unit의 `--defaults-file`
- `/etc/sysconfig/mysql*`의 설정파일 지정
- SELinux Port Type 충돌

사용 중이거나 기존 Config에 예약된 Port 입력 시 다른 Port 재입력 요구.

## Package 안전장치

RPM 설치 환경에서는 `/usr/sbin/mysqld` 등의 공용 Binary가 서버 전체 인스턴스에 영향을 줄 수 있다.

현재 설치된 `mysql-community-server` Version과 Bundle Version이 다르면 자동 Package 교체 차단.

예시:

```text
Installed : mysql-community-server 9.7.2
Bundle    : mysql-community-server 8.0.46
Result    : BLOCK
```

기존 다중 인스턴스의 공용 Binary를 신규 Bundle Version으로 임의 Upgrade/Downgrade하지 않는 목적.

## SELinux

SELinux 비활성화 작업 없음.

SELinux 활성 환경에서 사용자가 정책 적용을 선택한 경우 Custom Path와 Port에 필요한 MySQL Context 적용.

| 대상 | SELinux Type |
|---|---|
| Data Directory | `mysqld_db_t` |
| Log Directory | `mysqld_log_t` |
| Socket/PID Directory | `mysqld_var_run_t` |
| `secure_file_priv` Directory | `mysqld_db_t` |
| 별도 option file | Host의 `/etc/my.cnf` 정책 기준 자동 판별 |
| 비기본 SQL/X Port | `mysqld_port_t` |

다른 서비스의 특정 SELinux Port Type 또는 기존 local fcontext 발견 시 자동 재할당 차단.

## Rollback

실제 설치 단계 진입 후 실패 발생 시 이번 실행에서 생성·변경한 인스턴스 자원 중심 Rollback 수행.

대상:

- 생성한 systemd Unit
- 생성한 Config
- 생성한 Log/Socket/PID 파일
- 신규 Data Directory 내용
- 신규 Directory
- 신규 OS 계정/그룹
- 이번 실행에서 추가한 SELinux fcontext
- 이번 실행에서 추가한 `mysqld_port_t`
- 기존 빈 Directory를 사용한 경우 기존 UID/GID/Mode/SELinux Context 복원

RPM Transaction은 다른 인스턴스 또는 공유 의존성에 영향을 줄 수 있으므로 자동 제거하지 않음.

## 종료 코드

| 코드 | 의미 |
|---:|---|
| `0` | 검증 또는 작업 성공 |
| `1` | 실행 오류/사용자 취소/설치 실패 |
| `2` | Precheck 또는 Dry-run Blocker 발견 |

## 현재 검증 범위

v1.0.11 기준 다음 항목 실제 검증 완료.

- `/bin/sh` 문법
- Same-version Bundle Package 재사용
- 다른 Version Bundle의 공용 RPM 교체 차단
- Minimum Profile 실제 기동
- Production Profile 실제 기동
- Classic Protocol / MySQL X Protocol 분리
- Custom `my.cnf`
- Custom Data/Log/Socket/PID Directory
- SELinux Enforcing
- 신규 OS 계정 생성
- 실행/중지 인스턴스 충돌 탐지
- Port/Socket/Log/Lock File 충돌 탐지
- 기동 실패 시 Rollback
- 기존 빈 Directory Metadata 원복
- Dry-run 무변경
- 기존 3개 MySQL 인스턴스 무영향 확인

검증 환경에서 이미 MySQL 9.7.2 공용 RPM과 다중 인스턴스가 존재하여 **MySQL Package가 전혀 없는 Fresh Host의 최초 RPM 설치 분기는 실제 Package 설치까지 수행하지 않고 Precheck/Dependency 경로까지만 검증**.

## 운영 적용 기준

- 대상 OS와 Bundle의 EL Major/Architecture 일치 확인
- 실제 운영과 동일한 MySQL Version/Topology의 테스트 환경 선행 검증
- 기존 Package/Config/Data Directory 백업 확인
- Port/Socket/Service 충돌 여부 확인
- SELinux 정책 적용 범위 확인
- 최종 Plan 검토 후 실행 승인

설치 후 출력되는 임시 `root` Password 위치 확인 후 별도 로그인으로 초기 Password 변경 수행.
