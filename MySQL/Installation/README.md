# MySQL Community RPM Bundle 설치 자동화

`mysql_install_auto.sh`는 사용자가 미리 준비한 Oracle MySQL Community RPM Bundle(`*.rpm-bundle.tar`)을 이용해 신규 MySQL 인스턴스를 구성하는 POSIX `/bin/sh` 스크립트다.

현재 스크립트 버전: **v1.0.24**

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
readlink (GNU readlink -m 지원)
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
RPM 조회의 종료 상태를 기준으로 분기한다. 미설치 안내 문구를 설치 정보로 취급하지 않으며,
조회 실패 시 RPM 목록을 확인하여 실제 미설치와 RPM DB/메타데이터 오류를 구분한다.

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
/opt/mysql-8.0.46-mysql4/payload/usr/sbin/mysqld -> MySQL 8.0.46 (신규 private tree)
```

RPM DB와 `/usr/sbin/mysqld`는 변경하지 않는다.

## 사용자 입력 경로

다음 경로는 스크립트가 패턴화하지 않고 사용자가 직접 지정한다.

- Instance Root
- Different-version coexistence 시 Private MySQL Software Root
- `my.cnf`
- Data Directory
- Log Directory
- Socket/PID Directory
- `secure_file_priv` Directory

입력 경로는 `readlink -m`으로 정규화하여 후행 슬래시, `..`, 기존 심볼릭 링크가
가리키는 실제 경로를 기준으로 비교한다. 정규화된 경로는 최종 Plan에 표시한다.

- Data/Log/Socket-PID/secure_file_priv 디렉터리는 서로 같거나 포함 관계일 수 없다.
- `my.cnf`는 위 네 디렉터리와 private software tree 밖에 둔다.
- Private software tree와 Data/Log/Socket-PID/secure_file_priv는 서로 겹칠 수 없다.
- Instance Root는 네 디렉터리 안에 둘 수 없다. 상위 폴더이거나 독립 경로일 수 있다.
- 별도로 입력한 Instance Root는 다른 경로의 부모가 아니어도 명시적으로 생성한다.
- 기존 설정 파일의 경로도 정규화하여 비교하며, 기존 datadir과 포함 관계도 차단한다.

입력 경로의 기존 parent, write/execute 가능성, read-only filesystem, 충돌 여부를 검사한다.

## 자동 생성되는 my.cnf

Minimum Profile은 독립 기동에 필요한 기본 항목을 생성한다.

```text
basedir        # side-by-side 모드일 때
user
port
datadir
socket
pid-file
log-error
secure-file-priv
bind-address 또는 skip-networking
mysqlx 관련 항목
```

`[client]`에도 신규 인스턴스의 Port/Socket을 기록한다.

생성 후 대상 Version의 실제 `mysqld`로 `--validate-config`와 `--print-defaults` 검증을 수행한다.

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

Temporary root password 자체는 화면에 노출하지 않고 `initialize.log` 위치만 안내한다.

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

v1.0.24부터 로그 등 파일은 이번 실행에서 확보/생성한 목록만 정리한다.
Slow Log를 사용하지 않는 경우 기존 `slow.log`는 정리 대상에 포함하지 않는다.
설정/로그 파일 생성 시 기존 파일을 덮어쓰지 않는 방식으로 확보한다.
서비스 기동을 시도한 뒤 실패하면 정리 전에 종료 상태를 확인하며, 종료 실패 또는
실행 중인 프로세스가 남으면 파일/디렉터리를 보존하고 수동 확인을 안내한다.

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

## v1.0.24 검증 범위

미설치/동일 버전/다른 버전/RPM 조회 실패 분기, 기존 로그 보존과 생성 파일 정리,
종료 실패 시 자원 보존, 독립 Instance Root 생성, 정규화/포함 관계 충돌을
POSIX dash의 격리 회귀 검사로 확인했다. RPM/systemd/계정 변경 명령은 모의 처리했다.

이 버전에 대한 실제 RHEL/MySQL 설치·기동 및 SELinux 통합 시험은 수행하지 않았다.
위의 실제 검증 완료 사례는 v1.0.23에 대한 기존 기록이다.
