# PostgreSQL Automation

PostgreSQL 운영 점검, 성능 분석, Upgrade, 권한 감사, 데이터 이관, Physical Replication Planned Switchover를 다룹니다.

## 구성

| 디렉터리 | 목적 |
| --- | --- |
| `postgres-daily-check/` | 일일 운영 상태 점검 및 전일 결과 비교 |
| `performance-check/` | System Catalog / Statistics View 기반 성능 점검 |
| `execution-plan-analysis/` | SQL 실행계획 수집·분석 |
| `Major Version Upgrade/` | Major Upgrade와 Standby 재구성 |
| `Minor Version Upgrade/` | Minor Upgrade 전후 검증 |
| `user-privileges-check/` | 계정·권한 감사 |
| `data-migration/` | Dump/Restore 기반 병합 이관 |
| `failover/` | Physical Replication Planned Switchover |

## 설계 기준

- Version, Port, PGDATA, Role, Replication Topology 등 Runtime 상태 확인
- Primary / Standby / Cascading Standby 및 다중 인스턴스 환경 고려
- 조회 전용 진단 우선
- 변경 전후 상태 비교와 결과 기록
- 운영 환경 고유값 및 비밀번호의 코드 내 고정 방지
- Script별 범위 밖의 자동 Failover 또는 무검증 변경 수행 금지

각 자동화의 지원 범위와 제한사항은 해당 디렉터리의 README에서 확인합니다.
