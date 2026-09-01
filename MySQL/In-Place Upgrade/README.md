# MySQL RPM Bundle In-place Upgrade

MySQL Community Server의 RPM Bundle TAR를 이용해 기존 `datadir`을 유지하면서 In-place Upgrade를 수행하는 자동화 프로젝트입니다.

스크립트는 특정 Patch 버전을 하드코딩하지 않고 현재 설치 RPM과 Bundle 파일명에서 버전을 자동 확인합니다. 지원 경로, 패키지 구성, 설정, 서비스, SQL 접속, 디스크 공간을 확인한 뒤 단계별로 작업합니다.

## 현재 검증 대상

```text
ASIS MySQL : 8.0.46
TOBE MySQL : 8.4.11 LTS
OS         : RHEL 8 계열 x86_64
설치 방식  : MySQL Community RPM Bundle
datadir    : /home/mysql/data
socket     : /home/mysql/mysqld/mysql.sock
log-error  : /home/mysql/log/mysqld.log
pid-file   : /home/mysql/mysqld/mysqld.pid
```

이 값들은 예시 환경이며 스크립트는 `/etc/my.cnf`, 설치 RPM과 Bundle에서 실제 값을 확인합니다.

## 안전 설계

- `/bin/sh`로 실행하면 Bash로 자동 재실행
- 현재 설치 버전과 Bundle 목표 버전 자동 확인
- 목표 버전이 현재 버전보다 높지 않으면 중단
- 공식 Release Series를 건너뛰는 경로는 기본 차단
- Server, Client, Common, Library 등 필수 RPM 동시 검증
- `debug`, `debuginfo`, `debugsource` RPM 자동 제외
- 실제 변경 전 정확한 확인 문구 요구
- `innodb_fast_shutdown=0` 적용 후 정상 종료
- ASIS에서 `mysqlcheck --check-upgrade` 수행
- MySQL이 정지된 상태에서 물리 백업 생성
- 기존 `my.cnf`, RPM 목록, Runtime 정보, 계정, Plugin, SELinux Context 저장
- 새 버전 최초 기동 실패 시 기존 Binary로 `datadir`을 자동 기동하지 않음
- 별도 `rollback` 단계에서 Old Bundle과 오프라인 백업을 사용
- 단계별 상태 파일과 로그 저장
- `--dry-run` 지원

## 지원 경로 정책

기본 안전 Matrix는 다음 경로를 허용합니다.

- 동일 Release Series 안의 상위 버전
- `5.7 → 8.0`
- `8.0 → 8.4`
- `8.1`, `8.2`, `8.3 → 8.4`
- `8.4 → 9.x`
- 동일한 9.x Major 안의 상위 Innovation/LTS Series

Matrix에 없는 경로는 기본적으로 중단합니다. 공식 문서에서 직접 경로를 확인한 경우에만 `--allow-unverified-path`를 사용할 수 있습니다.

> `8.0 → 9.x`처럼 중간 LTS인 8.4를 건너뛰는 직접 Upgrade는 차단됩니다.

## 디렉터리 구성

예시:

```text
/home/mysql/
├── data/
├── log/
├── mysqld/
├── mysql-8.0.46-1.el8.x86_64.rpm-bundle.tar
├── mysql-8.4.11-1.el8.x86_64.rpm-bundle.tar
├── mysql_inplace_upgrade_work/
├── mysql_inplace_upgrade_backup/
└── mysql_inplace_upgrade_logs/
```

백업 위치는 `datadir` 내부로 지정하면 안 됩니다. 운영에서는 가능하면 Data Filesystem과 다른 Filesystem을 사용합니다.

## 실행 전 준비

- MySQL이 정상 실행 중이어야 합니다.
- root MySQL 계정 또는 점검에 필요한 관리 계정의 비밀번호가 필요합니다.
- OS 명령은 `root`로 실행합니다. `mysql` OS 계정으로 `systemctl`이나 RPM 작업을 수행하지 않습니다.
- 목표 버전 RPM Bundle을 서버에 업로드합니다.
- 롤백을 검증하려면 현재 버전 Old Bundle도 보관합니다.
- 기존 백업과 복원 절차를 별도로 검증합니다.

현재 환경 예시:

```text
/home/mysql/mysql-8.0.46-1.el8.x86_64.rpm-bundle.tar
/home/mysql/mysql-8.4.11-1.el8.x86_64.rpm-bundle.tar
```

## 실행 단계

### precheck

현재 버전, Bundle 목표 버전, 지원 경로, MySQL 설정, 서비스, SQL 접속, `mysqlcheck --check-upgrade`, 필수 RPM과 백업 공간을 검사합니다.

MySQL Shell이 설치되어 있으면 목표 버전에 대한 Upgrade Checker 수행 필요성을 안내합니다. MySQL Shell이 없으면 운영 Upgrade 전에 별도로 설치하거나 다른 서버의 호환 버전 MySQL Shell에서 `util.checkForServerUpgrade()` 결과를 확보해야 합니다.

```bash
sh mysql_inplace_upgrade.sh --bundle /home/mysql/mysql-8.4.11-1.el8.x86_64.rpm-bundle.tar --old-bundle /home/mysql/mysql-8.0.46-1.el8.x86_64.rpm-bundle.tar precheck
```

### prepare

Bundle을 작업 디렉터리에 풀고 필수 RPM, 서명, 설치 대상 목록을 검증합니다. 현재 환경의 Metadata도 수집합니다. 서비스 중단은 없습니다.

```bash
sh mysql_inplace_upgrade.sh prepare
```

### upgrade

정확한 확인 문구를 입력하면 MySQL을 Clean Shutdown하고 오프라인 물리 백업을 만든 뒤 RPM을 Upgrade하고 새 버전을 기동합니다.

```bash
sh mysql_inplace_upgrade.sh upgrade
```

이 단계에서 서비스 중단이 발생합니다.

### postcheck

Runtime/RPM 버전, 서비스, SQL 접속, 전체 Database의 Upgrade 호환성, Metadata와 Error Log를 확인합니다.

```bash
sh mysql_inplace_upgrade.sh postcheck
```

### status

저장된 상태와 현재 Package/Service 상태를 확인합니다.

```bash
sh mysql_inplace_upgrade.sh status
```

### rollback

새 버전 기동 또는 검증에 실패한 경우에만 수행합니다. Upgrade된 `datadir`은 분석용으로 별도 이름에 보존하고, 오프라인 백업과 Old Bundle RPM을 복원합니다.

```bash
sh mysql_inplace_upgrade.sh rollback
```

롤백은 `precheck`에서 `--old-bundle`을 지정했고 물리 백업을 생성한 경우에만 가능합니다.

## 자동 Bundle 선택

`--bundle`을 생략하면 `BASE` 아래의 Bundle을 검색합니다. 여러 개가 있으면 번호를 표시하고 선택을 요구합니다.

```bash
sh mysql_inplace_upgrade.sh precheck
```

운영 자동화에서는 잘못된 Bundle 선택을 막기 위해 `--bundle`을 명시하는 것이 좋습니다.

## 주요 옵션

| 옵션 | 설명 | 기본값 |
|---|---|---|
| `--bundle` | 목표 버전 RPM Bundle | 자동 검색 |
| `--old-bundle` | 롤백용 현재 버전 Bundle | 없음 |
| `--base` | 작업 기준 경로 | `/home/mysql` |
| `--config` | MySQL 설정 파일 | `/etc/my.cnf` |
| `--service` | systemd Service | `mysqld` |
| `--socket` | MySQL Socket | `my.cnf`에서 확인 |
| `--backup-root` | 오프라인 백업 상위 경로 | `/home/mysql/mysql_inplace_upgrade_backup` |
| `--work-dir` | RPM 및 Metadata 작업 경로 | `/home/mysql/mysql_inplace_upgrade_work` |
| `--allow-unverified-path` | 기본 Matrix 외 경로 허용 | 비활성화 |
| `--skip-physical-backup` | 물리 백업 생략 | 비활성화 |
| `--dry-run` | 변경 명령 출력만 수행 | 비활성화 |

## 상태와 로그

기본 파일:

```text
/home/mysql/.mysql_inplace_upgrade.conf
/home/mysql/mysql_inplace_upgrade_logs/
/home/mysql/mysql_inplace_upgrade_work/
/home/mysql/mysql_inplace_upgrade_backup/
```

상태 파일에는 MySQL 비밀번호를 저장하지 않습니다.

## 물리 백업 정책

스크립트는 MySQL을 정상 종료한 후 `cp -a --reflink=auto`로 `datadir`을 복사합니다.

- Copy-on-write Reflink를 지원하는 Filesystem은 빠르게 Snapshot 성격의 복사가 가능할 수 있습니다.
- Reflink를 지원하지 않으면 일반 전체 복사가 수행됩니다.
- 운영 환경에서는 Filesystem Snapshot, MySQL Enterprise Backup, 검증된 물리 백업 도구 등 조직 표준을 우선할 수 있습니다.
- `--skip-physical-backup`은 별도의 검증된 백업이 있을 때만 사용합니다.
- 백업을 생략하면 스크립트의 `rollback`을 사용할 수 없습니다.

## 실패 시 원칙

새 버전이 기존 `datadir`로 한 번이라도 기동을 시도했다면 이전 MySQL Binary를 같은 `datadir`에 바로 연결하지 않습니다.

```text
잘못된 방식: 새 RPM 기동 실패 → 이전 RPM 설치 → 변경된 datadir 그대로 기동
안전한 방식: 새 RPM 기동 실패 → 변경된 datadir 격리 → 오프라인 백업 복원 → 이전 RPM 복원
```

## 현재 테스트 시나리오

```text
1. MySQL 8.0.46 정상 상태 확인
2. 8.4.11 Bundle precheck
3. Bundle 및 RPM prepare
4. 8.0.46 Clean Shutdown
5. /home/mysql/data 오프라인 백업
6. 8.4.11 관련 RPM 일괄 Upgrade
7. 기존 /home/mysql/data로 8.4.11 기동
8. postcheck
9. Rollback 리허설 또는 다음 단계 준비
```

## 공식 문서

- [MySQL 8.4 Upgrade Paths](https://dev.mysql.com/doc/refman/8.4/en/upgrade-paths.html)
- [MySQL 8.4 Upgrade Best Practices](https://dev.mysql.com/doc/refman/8.4/en/upgrade-best-practices.html)
- [Preparing Your Installation for Upgrade](https://dev.mysql.com/doc/refman/8.4/en/upgrade-prerequisites.html)
- [Binary and Package-based Upgrade on Unix/Linux](https://dev.mysql.com/doc/refman/8.4/en/upgrade-binary-package.html)

## 버전

현재 스크립트 버전: `1.0.0`

## 개발 검증

저장소의 테스트는 실제 MySQL Package를 변경하지 않습니다.

```bash
bash tests/version_paths_test.sh
bash tests/precheck_mock_test.sh
```

- `version_paths_test.sh`: 지원/차단 Upgrade Path와 Bundle 파일명 Parser 검증
- `precheck_mock_test.sh`: Mock 명령과 가상 RPM Bundle로 `8.0.46 → 8.4.11` Precheck 전체 흐름 검증
