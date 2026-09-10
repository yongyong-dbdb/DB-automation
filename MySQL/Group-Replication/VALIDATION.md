# GR v1.0.12 검증 기준점

**사용자 승인으로 main 저장 / 검증 미완료 / production-ready 아님.**

- 회귀 검사 45/45, 추가 안전장치 검사 23/23 통과.
- main/helper POSIX sh 문법 검사 통과.
- DEFINER 계정 CREATE/ALTER 선복원, 객체 복원 후 GRANT/default role 적용 구현.
- 전체 schema/stored object/account 비교, 양방향 GTID 집합 비교 구현.
- bootstrap 이전 SET PERSIST runtime/persisted 분리 rollback 및 신규 recovery 계정/channel rollback 구현. 설정 및 신규 계정/channel에 실제 오류를 주입한 staging 검증도 완료.
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
GR bootstrap/join은 실행하지 않았다. CA/SAN 인증서 생성과 cross-member 검증은 완료했으나 실행 중인 TLS/cnf에는 아직 적용하지 않았다.
Source CA `/home/mysql/data/ca.pem`과 해당 CA key로 SAN leaf certificate를 준비했다. 모든 advertise는 `128.10.50.221`, XCom 포트는 33061/33071/33081이다.

## 남은 작업

1. CA/SAN 신뢰를 해결하고 VERIFY_IDENTITY 재검증.
2. 기존에 설치되어 있으면서 group_name=NULL인 GR plugin의 안전한 재초기화 경로 보완.
3. offline/중간 rename 실패 rollback, systemd launcher, 기존 persisted 설정/외부 스토리지 지원 완성.
4. SSH 없는 별도 원격 호스트 검증.
5. 최종 후보 Node2 재검증 및 GR 전환.

현재 helper는 direct mysqld + 명시적 --defaults-file만 지원하며 systemd MainPID 관리, 미지원 옵션, 기존 persisted 설정, 외부 로그/스토리지 및 datadir symlink는 사전 차단한다. 접속 불능 상태의 offline rollback과 kill/power-loss 중간 상태 복구는 미완료다. bootstrap 이후 자동 설정 rollback도 하지 않는다.
Node2의 성공한 swap/rollback 검증을 전체 환경의 production 인증으로 해석하지 않는다.
최종 remote include chain 추가는 회귀 검사 완료이며 Node2 실서버 당시 패키지는 위 증거 경로에 보존했다.

TLS 실서버 적용은 자동 승인 검토가 명시적 승인 부족으로 차단했다. 준비/검증까지만 수행했으며 우회 적용하지 않았다. 다음 작업은 HANDOFF.md 기준으로 재개한다.

## 이어서 수행한 실제 실패 주입 검증

- 초기 GR plugin이 없던 상태에서 설치/SET PERSIST 후 잘못된 UUID로 실패: persisted 항목과 신규 plugin을 제거해 원래 상태 복구. 증거 `/home/mysql/gr_v1012_review/rollback-test.PwHODy`.
- runtime group UUID=3333..., persisted UUID=2222...인 상태에서 변경 후 실패: 두 값을 각각 원래 값으로 복구. 증거 `/home/mysql/gr_v1012_review/rollback-test.Crthfo`.
- recovery 계정/channel 생성이 각각 1개임을 확인한 뒤 잘못된 system variable SQL로 실패: 두 객체 모두 0개로 복구. 증거 `/home/mysql/gr_v1012_review/rollback-test.LJQ4sc`.
- 모든 경우 staging GTID는 Source 1-7 그대로, super_read_only=1 유지. 시험 staging은 종료했다.
- 실제 시험에서 NULL group_name은 SET NULL/DEFAULT/빈 문자열로 복원이 안 되는 점, 복제 SOURCE_PASSWORD 32바이트 제한, 생성 실패한 채널의 RESET 오류를 발견해 수정했다.
- 기존 GR plugin의 NULL setting은 사전 중단한다. 이번 실행에서 신규 설치한 plugin은 실패 시 제거해 설치 전 상태로 복구한다.

## 준비 완료된 TLS 적용 계획

계획: `/home/mysql/gr_v1012_review/tls_validation.W9C0k5/tls_change`

- Node1: `/home/mysql/gr_tls_1_20260910_091833_57470`
- Node2: `/home/mysql2/gr_tls_2_20260910_091833_57470`
- Node3: `/home/mysql3/gr_tls_3_20260910_091833_57470`
- SAN IP 128.10.50.221, serverAuth/clientAuth, 365일, Source CA 서명.
- 기존 각 노드 CA 신뢰도 bundle에 유지. CA private key는 원래 위치에 유지.
- 3x3 서버 인증서 신뢰/SAN 및 client certificate 용도 검증 통과.
- candidate cnf, 원본 cnf, runtime 복원 SQL, include-chain 기록, 인증서/키 checksum manifest 준비.
- 적용 시 3306/3307/3308 ssl_ca/ssl_cert/ssl_key 및 cnf를 변경하고 ALTER INSTANCE RELOAD TLS 수행. 실패 시 원본 cnf/runtime 복원. 기존 연결은 유지되며 새 연결부터 새 인증서 사용.
- 실행 중인 3개 인스턴스는 아직 기존 server-cert.pem을 사용한다. 원래 UUID/GTID 유지.
- `tls` 기본 동작은 plan-only. 승인 후 MYSQL_GR_TLS_ACTION=apply로 **저장된 계획**을 검증/적용하며 새 인증서를 다시 발급하지 않는다.


## Approved TLS reload attempt (2026-09-10)

User explicitly authorized applying/reloading the prepared certificates on ports 3306/3307/3308. Application failed on Node1 with ERROR 29 (HY000), OS errno 13 reading the new server-cert.pem. Automatic rollback restored the old configuration; all three active TLS contexts still report server-cert.pem. UUID/GTID and super_read_only=1 were unchanged; Node2 replication receiver/applier remained ON with connection error 0. New files have appropriate Unix ownership/modes, but SELinux is Enforcing and the new certificate directory/files have user_home_t labels. SELinux is a suspected cause, pending AVC and existing certificate label comparison. No security policy was disabled or relaxed. Next: diagnose labels, implement an appropriate persistent file placement/label fix, then retry the already-authorized reload and verify active contexts. Server evidence: /home/mysql/gr_v1012_review/tls_apply_result.log. TLS deployment is NOT complete; the user subsequently authorized saving this work to main; production readiness remains unverified.
