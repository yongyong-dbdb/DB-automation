# GR v1.0.12 이어서 작업할 기준점

사용자 기준: `gr-v1.0.12-reprovision`은 **main merge 금지**.
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
2. bootstrap 전 SET PERSIST/recovery rollback에 실제 실패를 주입해 복원 검증.
3. offline/중간 rename 실패 rollback, systemd launcher, 기존 persisted 설정/외부 스토리지 지원 완성.
4. SSH 없는 별도 원격 호스트에서 전체 패키지 복사 실행 검증.
5. 최종 후보로 Node2 재검증 후 GR 전환. main merge는 별도 판단 전까지 금지.

서버의 원래 `/home/mysql/gr_migrate.sh`는 v1.0.11로 유지했다.
후보와 시험 도구는 `/home/mysql/gr_v1012_review`에 분리했다.
재개 전에 repository branch와 서버 runtime을 다시 대조한다.
