# Changelog

## 1.0.0 - 2026-09-01

- MySQL RPM Bundle 기반 In-place Upgrade 자동화 최초 작성
- 현재/목표 버전 자동 판별
- 안전한 Upgrade Path Matrix 검증
- `precheck`, `prepare`, `upgrade`, `postcheck`, `rollback`, `status` 단계 제공
- Custom `datadir`, Socket, Log, PID 경로 자동 확인
- 필수 RPM 검증 및 Debug 계열 RPM 제외
- Clean Shutdown과 오프라인 물리 백업
- 상태 파일, Metadata와 단계별 로그 저장
- Old Bundle과 물리 백업을 이용한 명시적 Rollback
- Dry-run 지원
