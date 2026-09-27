# PostgreSQL Physical Replication Planned Switchover

Physical Streaming Replication 환경의 Topology와 상태를 확인하고 Primary와 Direct Standby 사이의 계획 절체를 지원합니다.

## 범위

- PostgreSQL 12~18
- Primary / Standby / Cascading Standby Topology 확인
- Multi-Instance 환경 고려
- WAL Replay pause / resume
- WAL Receiver 연결 stop / resume
- Primary → Direct Standby Planned Switchover
- `--check-only` 사전 검증

## 제외 범위

- 장애 Primary를 대상으로 한 Automatic Failover
- HA Manager 대체
- 검증 없이 Cascading Standby를 직접 승격하는 동작

## 의존성

PostgreSQL 제공 Binary와 기본 OS 유틸리티를 사용하며 Python, jq, yq, 별도 HA Manager 설치를 요구하지 않습니다.

실행 환경의 PGDATA, Port, Version, Role, System Identifier, Replication Topology를 Runtime 기준으로 확인합니다.
