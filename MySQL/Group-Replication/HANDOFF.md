# GR v1.0.12 이어서 작업할 기준점

사용자 최신 지시(2026-09-10): 혼동 방지를 위해 GR v1.0.12 작업 내용을 main에 저장한다. 기존 main merge 금지는 해제되었다. **검증 미완료 / production-ready 아님**.
원본 datadir/GTID는 자동 삭제·reset하지 않는다. 실서버 검증 없이 production-ready로 판단하지 않는다.

원래 우선순위:
DEFINER-aware 계정 복원 → 전체 schema/stored object 검증 → SET PERSIST rollback →
recovery account/channel rollback → TLS CA/SAN → GTID exact equality →
xa_detach_on_prepare → include chain → Local staging/swap/rollback → SSH 없는 copyable helper → Node2 실서버 검증.

이번 작업에서 안전장치와 direct-launcher helper를 추가했고 Node2 staging/swap/rollback을 실제 수행했다.
Node2는 원본 상태로 복구했으므로 기존 extra GTID 5개는 그대로다. 최종 재프로비저닝 적용 상태가 아니다.
증거와 검증 범위는 VALIDATION.md에 기록했다.

다음 작업:

1. CA/SAN 불일치를 해결하고 `VERIFY_IDENTITY`를 유지한 채 인증서 신뢰 검증.
2. 실제 실패 주입 검증은 완료. 기존 설치 GR plugin의 NULL setting 재초기화와 기타 미지원 실패 경로 보완.
3. offline/중간 rename 실패 rollback, systemd launcher, 기존 persisted 설정/외부 스토리지 지원 완성.
4. SSH 없는 별도 원격 호스트에서 전체 패키지 복사 실행 검증.
5. 최종 후보로 Node2 재검증 후 GR 전환. main 저장과 운영 검증 완료는 별개이며, 아직 production-ready가 아니다.

서버의 원래 `/home/mysql/gr_migrate.sh`는 v1.0.11로 유지했다.
후보와 시험 도구는 `/home/mysql/gr_v1012_review`에 분리했다.
재개 전에 repository branch와 서버 runtime을 다시 대조한다.

추가 기준점: rollback 실제 실패 주입 3종 완료, 회귀 45+안전장치23 통과.
TLS 계획 `/home/mysql/gr_v1012_review/tls_validation.W9C0k5/tls_change`은 생성/검증 완료.
사용자가 3306/3307/3308 TLS 적용 및 reload를 명시적으로 승인했다. 승인 재요청 불필요.
승인 후 실제 적용을 시도했으나 Node1 인증서 읽기 ERROR 29 / errno 13으로 실패했다.
자동 rollback 후 3개 노드의 runtime 및 active TLS context가 기존 server-cert.pem임을 확인했다.
새 인증서 디렉터리 mysql:mysql 0700, 인증서 0644, 키 0600. SELinux Enforcing, 새 파일/디렉터리 user_home_t.
SELinux 거부 가능성이 있으나 AVC 로그로 아직 확정하지 않았다. 다음 작업은 AVC 및 기존 인증서 context 대조, 적절한 영구 label/배치 수정 후 승인된 reload 재시도. SELinux 비활성화/과도한 chmod 금지.
적용 로그: /home/mysql/gr_v1012_review/tls_apply_result.log. 실행 harness: /home/mysql/gr_v1012_review/apply_verified_tls.sh.
실패 후 3개 UUID/GTID, super_read_only=1 유지 및 Node2 receiver/applier ON, last_error=0 확인.
실험 staging은 종료했고 원래 3개 인스턴스의 UUID/GTID는 유지된다.

SELinux는 사용자가 의도적으로 설정한 보안 정책이다. Enforcing 및 기존 접근 정책을 유지하고, AVC 근거에 따라 인증서 배치/컨텍스트를 맞춘다. 정책 완화 또는 비활성화 금지.
