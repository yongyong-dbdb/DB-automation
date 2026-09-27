# MySQL Automation

MySQL 설치, In-place Upgrade, GTID Replication, Group Replication, InnoDB Cluster 구성을 자동화한 프로젝트 모음입니다.

## 구성

| 디렉터리 | 목적 |
| --- | --- |
| `Installation/` | RPM Bundle 기반 Standalone / Multi-Instance 설치 |
| `In-place Version Upgrade/` | Package 기반 In-place Upgrade |
| `Replication(GTID)/` | GTID 기반 Source / Replica 구성 |
| `Group-Replication/` | Standalone 또는 GTID Replication의 Group Replication 전환 |
| `InnoDB-Cluster/` | 신규 InnoDB Cluster 구성 또는 기존 Group Replication Adopt |

## 설계 기준

- Host, Port, Socket, Data Directory, Service, Version 자동 탐지 또는 명시적 입력
- 동일 서버 다중 인스턴스와 서로 다른 Version 공존 고려
- 기존 Package, Config, Data Directory와 SELinux 설정의 임의 변경 방지
- `Precheck → Plan → Apply → Validation` 단계 분리
- 변경 전 상태 Snapshot과 실패 시 Rollback 가능성 검토
- 폐쇄망 환경과 외부 Repository 미사용 시나리오 고려
- 비밀번호와 민감정보 노출 방지

실행 전 각 디렉터리의 README에서 지원 Version과 제한사항을 확인합니다.
