# MySQL Community RPM Bundle 설치 자동화

`mysql_install_auto.sh`는 사용자가 미리 준비한 Oracle MySQL Community RPM Bundle(`*.rpm-bundle.tar`)을 이용해 신규 MySQL 인스턴스를 구성하는 POSIX `/bin/sh` 스크립트다.

현재 스크립트 버전: **v1.0.27**

## 핵심 원칙

- 인터넷 연결이 없는 폐쇄망(air-gapped) 환경을 기본 고려한다.
- `dnf`, `yum`, `apt`, `curl`, `wget`, `pip`, `npm` 등을 호출해 외부 패키지나 Runtime을 설치하지 않는다.
- Bundle 파일명에 Version을 하드코딩하지 않고 내부 RPM 메타데이터에서 Version/Release/Architecture/Vendor를 판별한다.
- `my.cnf`, Instance Root, Data/Log/Socket/PID/`secure_file_priv` 경로는 사용자가 직접 지정한다.
- 스크립트가 경로 네이밍 패턴을 추측하거나 강제하지 않는다.
- 입력된 경로를 기반으로 독립 실행 가능한 전용 `my.cnf`를 자동 생성한다.
- 동일 서버 다중 인스턴스와 서로 다른 MySQL Version 공존을 고려한다.
- 기존 인스턴스와 기존 RPM 설치본을 임의 Upgrade/Downgrade하지 않는다.
- SELinux는 비활성화하지 않으며, 정책 적용 여부는 사용자가 선택한다.
- 기동 방식도 사용자가 선택한다.

## 지원 범위

- Oracle MySQL Community RPM Bundle
- RHEL 호환 EL RPM 환경
- MySQL 8.x / 9.x
- x86_64 및 Bundle/Host RPM Architecture가 일치하는 환경
- systemd 기반 Linux
- 동일 서버 복수 `mysqld`
- 동일 Version 추가 인스턴스
- 다른 Version의 side-by-side 인스턴스
- SELinux Enforcing / Permissive / Disabled
- 폐쇄망 설치

Ubuntu/Debian APT/DEB 설치는 현재 범위가 아니다.

## 실행 전 Host 요구사항

스크립트는 필요한 도구를 자동 설치하지 않는다. 필요한 항목이 없으면 경고 또는 Block 후 종료한다.

기본:

```text
/bin/sh
rpm
tar
systemctl
```

다른 MySQL Version을 기존 RPM과 공존시키는 side-by-side 모드:

```text
rpm2cpio
cpio
ldd
```

SELinux 정책 자동 적용 선택 시:

```text
semanage
restorecon
```

이 도구들이 없더라도 스크립트가 Repository에 접속하거나 패키지를 설치하지 않는다.

## 실행 모드

### Precheck

```sh
sh mysql_install_auto.sh \
  --bundle /path/mysql-8.0.xx-1.el8.x86_64.rpm-bundle.tar \
  --precheck-only
```

Bundle/Host/Package/기존 인스턴스를 검사하고 변경하지 않는다.

### Dry-run

```sh
sh mysql_install_auto.sh \
  --bundle /path/mysql-8.0.xx-1.el8.x86_64.rpm-bundle.tar \
  --dry-run
```

사용자 입력, 충돌 검사, 최종 `my.cnf`, systemd Unit 또는 direct-start command까지 출력하지만 실제 변경하지 않는다.

### Install

```sh
sh mysql_install_auto.sh \
  --bundle /path/mysql-8.0.xx-1.el8.x86_64.rpm-bundle.tar
```

최종 Plan 확인과 사용자 승인 후 실제 설치한다.

## Package 처리 모드

### 1. Fresh install

Host에 `mysql-community-server`가 없으면 Bundle RPM만 대상으로 `rpm --test` 후 설치한다.

OS 의존성이 부족하면 외부 Repository를 사용하지 않고 누락 dependency를 출력한 뒤 중단한다.

### 2. Same-version reuse

Host에 Bundle과 동일한 `mysql-community-server` Version/Release/Architecture가 이미 있으면 기존 공용 Binary를 재사용하고 별도 인스턴스만 생성한다.

### 3. Different-version coexistence

기존 Oracle MySQL RPM Version과 Bundle Version이 다르면 기존 RPM을 교체하지 않는다.

예:

```text
Installed RPM : MySQL 9.7.2
Bundle        : MySQL 8.0.46
```

이 경우 Bundle RPM payload를 사용자가 지정한 **Private MySQL Software Root**에 추출하고 신규 인스턴스가 해당 전용 `mysqld`를 사용한다.

개념 예:

```text
/usr/sbin/mysqld                                  -> MySQL 9.7.2 (기존 RPM)
/opt/mysql-8.0.46-mysql4/usr/sbin/mysqld         -> MySQL 8.0.46 (신규 private tree)
```

RPM DB와 `/usr/sbin/mysqld`는 변경하지 않는다.

## 사용자 입력 경로

SELinux 상태를 먼저 확인하고, Enforcing/Permissive이면 사용자에게 정책 적용 여부를 묻는다. 그 선택을 확정한 뒤 instance별 경로를 입력받아 최종 정책 적용 계획을 구성한다.

다음 경로는 고정값으로 하드코딩하지 않고 사용자가 직접 지정한다.

- Instance Root
- Different-version coexistence 시 Private MySQL Installation Root
- `my.cnf`
- Data Directory
- Log Directory
- Error Log file path — Error Log 활성화 시
- Binary Log basename — Binary Log 활성화 시
- SQL Socket file
- PID file
- MySQL X Socket file — X Protocol 활성화 시
- `secure_file_priv` Directory

입력 경로의 기존 parent, write/execute 가능성, read-only filesystem, 다른 인스턴스와의 충돌 여부를 검사한다.
Binary Log를 활성화한 경우 해당 디렉터리도 소유권/권한, SELinux Context, Rollback 추적 대상에 포함한다.

## 자동 생성되는 my.cnf

Minimum Profile은 독립 기동에 필요한 기본 항목을 생성한다.

```text
basedir                 # side-by-side 모드일 때
user
port
datadir
socket
pid-file
performance_schema
secure-file-priv
log-error               # Error Log 활성화 시
log-bin                 # Binary Log 활성화 시
skip-log-bin            # Binary Log 비활성화 시
bind-address 또는 skip-networking
mysqlx 관련 항목
```

각 기능은 설치 중 개별 선택한다.

```text
Enable Error Log file (log-error) (yes/no) [yes]:
Enable Binary Log (log-bin) (yes/no) [yes]:
Enable Performance Schema (performance_schema) (yes/no) [yes]:
```

- Error Log = `yes`: 사용자가 지정한 전체 파일 경로를 `log-error`에 기록한다.
- Error Log = `no`: `log-error`를 명시하지 않는다.
- Binary Log = `yes`: 사용자가 지정한 절대경로 basename을 `log-bin`에 기록한다.
- Binary Log = `no`: `skip-log-bin`을 명시하여 Binary Log를 비활성화한다.
- Performance Schema = `yes`: `performance_schema=ON`
- Performance Schema = `no`: `performance_schema=OFF`

`[client]`에도 신규 인스턴스의 Port/Socket을 기록한다.

생성 후 대상 Version의 실제 `mysqld`로 `--validate-config`와 `--print-defaults` 검증을 수행하고,
선택한 Error Log / Binary Log / Performance Schema 설정이 effective option에 반영됐는지 확인한다.

## 기동 방식

사용자가 선택한다.

### 1. systemd custom unit

Oracle RPM/systemd Linux에서 권장되는 방식이다.

```text
systemctl start <service>
```

Boot enable 여부도 사용자가 선택한다.

### 2. mysqld --daemonize

전용 `--defaults-file`을 사용하는 direct-start 방식이다.

SELinux Enforcing/Permissive 상태에서 direct mode를 선택하면 `mysqld_t`가 아닌 다른 process domain으로 실행될 가능성을 경고하고 계속 진행 여부를 다시 확인한다.

SELinux 정책 적용 여부와 direct-start 사용 여부는 서로 별개의 사용자 선택이다.

`mysqld_safe`, `mysql.server`는 현재 Oracle RPM/systemd 설치기 범위에서는 선택 불가 안내만 제공한다.

## SELinux

SELinux를 자동으로 비활성화하지 않는다.

SELinux가 Enforcing/Permissive이면 다음을 사용자에게 묻는다.

```text
Apply MySQL SELinux file/port contexts ...? yes/no
```

`yes` 선택 시 Host의 기존 MySQL SELinux 정책을 기준으로 다음 Context를 적용한다.

| 대상 | Type |
|---|---|
| Data Directory | `mysqld_db_t` |
| Log Directory | `mysqld_log_t` |
| Binary Log Directory | `mysqld_db_t` |
| Socket/PID Directory | `mysqld_var_run_t` |
| `secure_file_priv` | `mysqld_db_t` |
| 별도 option file | Host `/etc/my.cnf` 정책에서 판별 |
| SQL/X Port | `mysqld_port_t` |
| private `mysqld` | Host `/usr/sbin/mysqld` executable type에서 판별 |
| private MySQL library tree | Host MySQL library type에서 판별 |

기존 local fcontext 또는 다른 서비스의 특정 Port Type과 충돌하면 자동 재할당하지 않는다.

## 다중 인스턴스 충돌 검사

- 실행 중인 모든 `mysqld`
- 기존 option file
- systemd Unit의 `--defaults-file`
- `/etc/sysconfig/mysql*`
- SQL Port
- MySQL X Port
- Unix Socket / `.lock`
- PID File
- Data Directory
- Error/Slow/Initialization Log
- Binary Log basename / index / existing numbered files
- `secure_file_priv`
- Service Name
- Private Software Root
- SELinux Port Type

`ss`가 없는 최소 설치 Host에서는 Linux `/proc`를 이용한 Port/Unix Socket fallback 검사를 사용한다.

## 초기화 및 사후 검증

신규 Data Directory는 대상 Version의 `mysqld --initialize`로 초기화한다.

기동 후 다음을 검증한다.

- Service 또는 PID 존재
- 실행 OS User
- 실제 `/proc/<pid>/exe`와 목표 `mysqld` 일치
- Unix Socket
- SQL Port
- 선택적 MySQL X Port/Socket
- Error Log
- SELinux file/port context
- systemd + SELinux 정책 적용 환경의 `mysqld_t` process domain
- 실제 MySQL Version

초기화가 성공하면 이번 실행에서 생성한 `initialize.log`만 읽어 `root@localhost`의 Temporary Password를 화면에 표시한다.
사용자는 첫 로그인 후 즉시 비밀번호를 변경해야 한다.

## Rollback

실패 시 이번 실행에서 만든 인스턴스 자원을 중심으로 Rollback한다.

- 생성한 systemd Unit
- 생성한 `my.cnf`
- Log/Socket/PID
- 신규 Data Directory 내용
- 신규 Directory
- 신규 OS 계정/그룹
- 이번 실행에서 추가한 SELinux fcontext/Port
- side-by-side private software tree
- 기존 빈 Directory를 사용한 경우 원래 metadata 복원

기존 공유 RPM을 자동 제거하는 Rollback은 수행하지 않는다.

## 실제 검증 완료 사례

v1.0.23 기준 테스트 Host에서 기존 MySQL 9.7.2 인스턴스 3개가 실행 중인 상태에서 MySQL 8.0.46 RPM Bundle을 사용해 다른 Version 인스턴스를 추가했다.

```text
3306 -> /usr/sbin/mysqld                         MySQL 9.7.2
3307 -> /usr/sbin/mysqld                         MySQL 9.7.2
3308 -> /usr/sbin/mysqld                         MySQL 9.7.2
3309 -> private software root .../usr/sbin/mysqld MySQL 8.0.46
```

검증 결과:

- 기존 9.7.2 RPM DB 유지
- 기존 `/usr/sbin/mysqld` 9.7.2 유지
- 기존 3개 인스턴스 Active 상태 유지
- 신규 8.0.46 전용 Binary 정상 기동
- 신규 3309 Listen 확인
- 전용 `my.cnf` 적용값 검증
- SELinux Enforcing에서 systemd 기동 시 `mysqld_t` 확인
- `/bin/sh` 문법 검사 통과
- 외부 Package Manager/Downloader 호출 없음 확인
- direct `mysqld --daemonize` 입력 흐름 및 SELinux 경고/명시 승인 Dry-run 검증

## 종료 코드

| 코드 | 의미 |
|---:|---|
| `0` | 성공 |
| `1` | 실행 오류 / 사용자 취소 / 설치 실패 |
| `2` | Precheck 또는 Dry-run Blocker |

## 운영 적용 시 주의

- Bundle과 대상 Host의 EL Major/Architecture가 맞아야 한다.
- Bundle 자체와 Host에 이미 설치된 OS prerequisite는 사전에 준비한다.
- 스크립트는 부족한 dependency를 인터넷에서 설치하지 않는다.
- Production 적용 전 동일한 OS/MySQL Version/Topology에서 Dry-run과 테스트를 선행한다.
- 사용자 지정 경로와 Port는 최종 Plan에서 반드시 확인한다.
- SELinux 활성 환경에서는 systemd 기동이 가장 예측 가능한 MySQL process domain을 제공한다.

## v1.0.27 입력 변경

버전 공존 모드에서는 설치 root 대신 mysqld 실행 파일의 전체 목적지 경로를 입력한다.
예: `/opt/mysql-8.0.46-mysql4/usr/sbin/mysqld`.
RPM에서 확인한 실행 파일 경로를 접미사로 유지해야 하며, 나머지를 설치 root로 계산한다.
임의 파일명 변경이나 RPM 구조와 다른 재배치는 지원하지 않는다. 기존 설치 디렉터리는 덮어쓰지 않는다.
이 경로는 socket/PID 경로와 별개다. SQL socket 및 PID 파일은 파일명을 포함해 각각 입력하고,
MySQL X socket은 X Protocol을 활성화한 경우에만 입력한다.

검증: POSIX sh 문법, 설치 root 계산, 잘못된 접미사 및 공유 경로 거부 테스트 통과.
실서버 RPM 설치 검증은 별도로 필요하다.


## v1.0.35 변경사항

Error Log, Binary Log, Performance Schema를 각각 독립적으로 활성화/비활성화할 수 있도록 입력 흐름을 추가했다.

### Error Log

```text
Enable Error Log file (log-error) (yes/no) [yes]:
```

`yes`이면 전체 Error Log 파일 경로를 입력받고 `log-error=<path>`를 생성한다.
`no`이면 별도의 `log-error` 항목을 생성하지 않는다.

### Binary Log

```text
Enable Binary Log (log-bin) (yes/no) [yes]:
Binary log basename (absolute path including basename, e.g. /path/mysql-bin):
```

`yes`이면 사용자가 입력한 절대경로 basename을 `log-bin`에 사용한다.
`no`이면 `skip-log-bin`을 명시적으로 생성한다.

Binary Log 활성화 시 다음 검증을 수행한다.

- 절대경로 및 정규화 경로 검사
- Data/Log/Runtime/`secure_file_priv`/Private Software Root와의 경로 중첩 검사
- 기존 `log-bin` 설정 충돌 검사
- 기존 `.index` 및 numbered Binary Log 파일 충돌 검사
- Directory 생성 및 OS User 소유권/쓰기 권한 검사
- SELinux `mysqld_db_t` 적용 및 사후 검증
- 이번 실행에서 생성한 Directory Rollback 추적

### Performance Schema

```text
Enable Performance Schema (performance_schema) (yes/no) [yes]:
```

선택에 따라 `performance_schema=ON` 또는 `performance_schema=OFF`를 생성한다.

### 설정 검증

생성된 `my.cnf`는 대상 MySQL Version의 실제 `mysqld`로 검증한다.

- 지원 Version: `mysqld --validate-config`
- Effective option 확인: `mysqld --print-defaults`
- Error Log 활성화 시 `log-error` 값 검증
- Error Log 비활성화 시 의도하지 않은 `log-error` 존재 여부 검사
- Binary Log 활성화 시 `log-bin` basename 검증
- Binary Log 비활성화 시 `skip-log-bin` 존재 여부 검사
- Performance Schema ON/OFF 값 검증

경로, Port, Service Name 등은 특정 인스턴스 값으로 하드코딩하지 않는다.
외부 Package 설치나 별도 Runtime 추가도 하지 않는다.

실제 RHEL 8.6 + SELinux Enforcing Host에서의 v1.0.35 전체 설치/기동 검증은 별도 실서버 검증 항목으로 남아 있다.
