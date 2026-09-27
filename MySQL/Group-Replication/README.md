# MySQL Group Replication 전환 자동화

GTID 비동기 Replication 또는 Standalone MySQL 인스턴스를 Group Replication으로 전환하기 위한 POSIX `/bin/sh` 기반 자동화입니다.

## 범위

- Standalone → Group Replication
- GTID Source / Replica → Group Replication
- Single Primary / Multi Primary
- 동일 서버 Multi-Instance 및 서로 다른 서버의 인스턴스
- Socket / TCP 접속
- GTID, Server Identity, Port, Config, Schema/Stored Object 사전 검증
- TLS CA / SAN 검증
- Recovery Account / Channel 구성과 Rollback 고려

## 운영 안전성

- 실행 환경의 Version, UUID, Port, Socket, Data Directory, Option File을 Runtime 기준으로 확인
- GTID 양방향 정합성 검증
- DEFINER 계정과 Stored Object 사전 검증
- SET PERSIST 변경 전 Runtime / Persisted 상태 Snapshot
- 신규 Recovery Account / Channel의 실패 시 복원 경로 관리
- Config include chain 변경 탐지
- 기존 Data Directory와 GTID의 무조건적인 삭제 또는 Reset 금지
- 변경 단계와 검증 단계를 분리하고 실패 시 기존 상태 보존을 우선

## Runtime 의존성

운영 Script는 MySQL 배포본의 `mysql`, 필요한 경우 동일 계열 `mysqldump`, POSIX shell과 기본 OS 유틸리티를 사용합니다. Script가 외부 Python 패키지나 별도 Runtime을 설치하지 않습니다.

`tests/`의 Python 코드는 개발 단계 회귀 테스트 전용이며 운영 Script 실행에는 필요하지 않습니다.

## 검증

개발 단계 회귀 테스트:

```sh
python3 tests/test_gr.py
python3 -m unittest tests/test_gr_safety.py -v
```

검증 범위와 아직 남아 있는 제한사항은 [VALIDATION.md](VALIDATION.md)를 참고합니다.

## 주의

환경별 Service Manager, TLS File Context, 기존 Persisted Setting, 외부 Storage 구성은 실제 적용 전에 별도 검증이 필요합니다. 저장소의 테스트 결과를 모든 운영 환경에 대한 Production 인증으로 해석하지 않습니다.
