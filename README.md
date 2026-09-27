# DB Automation

PostgreSQL과 MySQL의 반복 운영 작업을 Shell 기반으로 자동화한 저장소입니다.

단순 명령 모음보다 **환경 탐지 → 사전 검증 → 실행 계획 → 변경 → 사후 검증** 흐름과 운영 안전성을 우선합니다.

## 공통 설계 원칙

- 실행 환경의 Host, Port, Socket, Data Directory, Version, Role 등을 Runtime 기준으로 확인
- 특정 서버 경로·Port·Version 등 환경 종속 값의 하드코딩 방지
- Single / Replication / Multi-Instance / Multi-Version 환경 차이 고려
- 변경 작업의 `Precheck → Plan → Apply → Validation` 단계 분리
- 기존 설정과 데이터 보호, 실패 시 Rollback 또는 수동 복구 근거 보존
- 비밀번호와 민감정보의 명령행·로그·상태 파일 노출 방지
- 운영 스크립트는 DBMS 제공 도구와 기본 OS 유틸리티 중심으로 구성

## PostgreSQL

| 영역 | 내용 |
| --- | --- |
| [Daily Check](PostgreSQL/postgres-daily-check/) | 접속, WAL, Archiver, Long Query, Lock, Replication Lag, Vacuum/XID, Top SQL 점검 |
| [Performance Check](PostgreSQL/performance-check/) | Session, Wait Event, I/O, Scan, Connection, pg_stat_statements 기반 성능 점검 |
| [Execution Plan Analysis](PostgreSQL/execution-plan-analysis/) | EXPLAIN / EXPLAIN ANALYZE와 Relation·Index·Statistics 분석 |
| [Major Version Upgrade](PostgreSQL/Major%20Version%20Upgrade/) | pg_upgrade 기반 사전 점검, Upgrade, 사후 검증 및 Standby 재구성 |
| [Minor Version Upgrade](PostgreSQL/Minor%20Version%20Upgrade/) | Binary/Package 교체 전후 검증 |
| [Privilege Audit](PostgreSQL/user-privileges-check/) | Role, Membership, Object 권한, PUBLIC, Owner, Default Privilege 점검 |
| [Data Migration](PostgreSQL/data-migration/) | Dump/Restore 기반 병합 이관과 Object/Data 정합성 검증 |
| [Planned Switchover](PostgreSQL/failover/) | Physical Replication Topology 확인과 계획 절체 |

자세한 범위는 [PostgreSQL README](PostgreSQL/README.md)를 참고합니다.

## MySQL

| 영역 | 내용 |
| --- | --- |
| [Installation](MySQL/Installation/) | RPM Bundle 기반 신규/다중 인스턴스 설치 |
| [In-place Upgrade](MySQL/In-place%20Version%20Upgrade/) | Upgrade Checker, Backup, RPM Transaction, 사후 검증 |
| [GTID Replication](MySQL/Replication%28GTID%29/) | Source / Replica 구성과 GTID 동기화 검증 |
| [Group Replication](MySQL/Group-Replication/) | Standalone 또는 GTID Replication 환경의 GR 전환 |
| [InnoDB Cluster](MySQL/InnoDB-Cluster/) | 신규 Cluster 생성 또는 기존 Group Replication Adopt |

자세한 범위는 [MySQL README](MySQL/README.md)를 참고합니다.

## 검증 기준

이 저장소의 자동화는 환경 차이를 고려한 참고 구현입니다. 실제 운영 적용 전에는 각 디렉터리의 README와 검증 범위를 확인하고 대상 환경에서 별도 사전 검증이 필요합니다.

일부 Python 코드는 개발 단계 회귀 테스트에만 사용하며 운영 Script 실행에는 필요하지 않습니다.
