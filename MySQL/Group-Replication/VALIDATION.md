# GR v1.0.12 검증 기준점

**main merge 금지 / production-ready 아님.**

- 회귀 검사 45/45, 추가 안전장치 검사 19/19 통과.
- main/helper POSIX sh 문법 검사 통과.
- DEFINER 계정 CREATE/ALTER 선복원, 객체 복원 후 GRANT/default role 적용 구현.
- 전체 schema/stored object/account 비교, 양방향 GTID 집합 비교 구현.
- bootstrap 이전 SET PERSIST runtime/persisted 분리 rollback 및 신규 recovery 계정/channel rollback 구현. 이 부분은 모의 검사이며 실제 실패 주입은 아직 미완료.
- TLS CA/SAN 검사, xa_detach_on_prepare 확인, local/remote include chain 변경 검사 구현.
- direct-launcher staging/swap/rollback 및 SSH 없이 전체 패키지를 복사해 실행하는 helper 구현.

## Node2 실서버 결과

서버 시각 2026-09-10, RHEL 8.6, MySQL 9.7.2, port 3307.
패키지 생성 → 별도 staging → 계정/역할/권한/전체 schema/stored object/data/GTID 검증 → swap → 새 UUID 및 내용 재검증 → rollback 모두 통과.

증거: `/home/mysql/gr_v1012_review/validation.5UwNFB/node_2.reprovision`
최종 상태 `ROLLED_BACK`. 원본 datadir 및 GTID는 삭제/reset하지 않았다.
원본 UUID `ca575c75-a690-11f1-ab7a-000c29452e0d`, 기존 extra GTID 5개 포함 원래 GTID 그대로, super_read_only=1, async receiver/applier=ON, receiver error=0으로 복귀했다.
검증에 사용한 새 datadir도 failed 경로에 보존했다.
원래 `/home/mysql/gr_migrate.sh` v1.0.11은 유지하고 후보는 `/home/mysql/gr_v1012_review`에 분리했다.

## TLS 실제 차단 요인

설정은 VERIFY_IDENTITY이나 세 CA 파일이 다르고, Node1 CA로 Node2 certificate 검증 시 unable to get local issuer certificate 발생. Node2 자동 생성 certificate에는 SAN이 없다.
GR bootstrap/join은 실행하지 않았다. CA/SAN 수정도 아직 적용하지 않았다.
Source CA key `/home/mysql/data/ca-key.pem` 존재 확인만 했다. 모든 advertise는 `128.10.50.221`, XCom 포트는 33061/33071/33081이다.

## 남은 작업

1. CA/SAN 신뢰를 해결하고 VERIFY_IDENTITY 재검증.
2. SET PERSIST/recovery rollback 실제 실패 주입 검증.
3. offline/중간 rename 실패 rollback, systemd launcher, 기존 persisted 설정/외부 스토리지 지원 완성.
4. SSH 없는 별도 원격 호스트 검증.
5. 최종 후보 Node2 재검증 및 GR 전환.

현재 helper는 direct mysqld + 명시적 --defaults-file만 지원하며 systemd MainPID 관리, 미지원 옵션, 기존 persisted 설정, 외부 로그/스토리지 및 datadir symlink는 사전 차단한다. 접속 불능 상태의 offline rollback과 kill/power-loss 중간 상태 복구는 미완료다. bootstrap 이후 자동 설정 rollback도 하지 않는다.
Node2의 성공한 swap/rollback 검증을 전체 환경의 production 인증으로 해석하지 않는다.
최종 remote include chain 추가는 회귀 검사 완료이며 Node2 실서버 당시 패키지는 위 증거 경로에 보존했다.

사용자 사용량 제한으로 여기서 저장 후 중단. 다음 작업은 HANDOFF.md 기준으로 재개한다.
