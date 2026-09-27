# Group Replication 검증 범위

이 문서는 Group Replication 전환 자동화의 검증 범위와 제한사항을 기록합니다. 서버 고유 IP, UUID, 절대 경로와 작업 세션 메모는 공개 문서에서 제외합니다.

## 구현 및 회귀 검증

- Group Replication 설정값과 Single / Multi Primary 분기 검증
- SQL / XCom Port 충돌 검증
- GTID Catch-up, Errant GTID, 양방향 GTID 집합 비교 검증
- 기존 Group 존재 시 중복 Bootstrap 차단
- DEFINER 계정 및 Stored Object 사전 검증
- SET PERSIST 변경 전 Runtime / Persisted 상태 Snapshot 및 실패 시 복원
- 신규 Recovery Account / Channel 생성 실패 시 Rollback
- Config include / includedir 변경과 순환 참조 검사
- 원격 Config 변경 전 Instance Identity 재검증
- 변경 전후 File Permission / 원본 Config 보존
- 동시 Config 변경 및 Lock 충돌 시 변경 차단
- TLS CA / SAN / VERIFY_IDENTITY 검증
- 실패 주입 시 Write Fence와 기존 Replication 상태 보존 검증

## 실환경에서 확인한 범위

- Multi-Instance 환경에서 별도 Staging Data Directory 생성
- 계정, 권한, Schema / Stored Object, Data, GTID 검증
- Data Directory Swap 후 상태 확인
- Rollback 후 기존 Data Directory와 GTID 보존 확인
- 기존 Async Replication Receiver / Applier 상태 복귀 확인

## 확인된 제한사항

- TLS 적용 과정에서 SELinux Enforcing의 File Context와 관련된 접근 실패 사례를 확인했으며, 자동 Rollback으로 기존 설정을 보존함
- Systemd / 기타 Launcher, 외부 Log·Storage, Data Directory Symlink 등은 환경별 추가 검증 필요
- Process 종료 또는 Host 장애가 발생한 중간 상태의 자동 복구는 모든 경우를 보장하지 않음
- Bootstrap 이후의 모든 설정 변경을 자동 Rollback하는 범용 도구가 아님

## 적용 원칙

- 실환경 적용 전 `discover / precheck / plan` 단계 결과 확인
- Backup 및 수동 복구 경로 확보
- 대상 인스턴스의 GTID, UUID, Config, TLS, Replication Channel 상태 재확인
- 검증되지 않은 환경에서는 자동 변경보다 Plan 출력과 수동 검토 우선
