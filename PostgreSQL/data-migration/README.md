# PostgreSQL Data Migration Automation

기존 Target 데이터와 객체를 유지하면서 PostgreSQL 데이터를 병합 이관하기 위한 Shell Script 모음입니다.

공개 저장소용으로 서버, Database, Schema, Table, 계정, 경로 및 Instance 식별값을 모두 일반화했습니다. 저장소의 이름은 실제 운영 환경을 나타내지 않습니다.

## 구성

| 파일 | 역할 |
| --- | --- |
| `update_instance.sh` | Source Instance 번호 변경, 관련 Table Rename, 사전/사후 검증 및 Backup Database 생성 |
| `dump_database.sh` | Schema와 Data 분리 Dump, 충돌 제외 대상과 별도 병합 Table Dump 생성 |
| `merge_restore_fc.sh` | Custom Format Schema Dump와 SQL Data Dump 기반 Merge Restore |
| `merge_restore_fd.sh` | Directory Format Dump 기반 병렬 Data 처리 및 Merge Restore |
| `merge_data_files.sh` | 애플리케이션 데이터 디렉터리의 Instance 번호 변경, 백업, 병합 및 결과 검증 |

## 처리 흐름

1. Source 환경과 Target 환경의 Database, Schema, Object 및 Instance 매핑 확인
2. `update_instance.sh`를 이용한 Instance 번호와 Table 이름 변경
3. `dump_database.sh`를 이용한 Schema/Data 분리 Dump
4. `merge_restore_fc.sh` 또는 `merge_restore_fd.sh`를 이용한 Target 병합 복원
5. 필요한 경우 `merge_data_files.sh`를 이용한 파일 데이터 병합
6. Object, Data, 파일 경로 및 처리 결과 검증

## 주요 설계

- 기존 Target Object와 Data 유지
- 존재하는 Object 제외 및 없는 Object만 생성
- Primary Key와 Unique Key 충돌 데이터 제외
- Function/Procedure 전체 Signature 기반 존재 여부 판별
- 임시 Stage Table을 이용한 Data 병합
- 변경 작업의 Transaction 처리 및 오류 발생 시 Rollback
- 기존 Backup Database와 Backup Directory 보존
- Host, Port, Database, 계정, 경로 및 Instance 번호의 실행 시 입력
- 비밀번호의 명령행 인자와 파일 저장 방지

## 공개용 Placeholder

다음 값은 실제 운영 명칭이 아닌 공개용 예시입니다.

- Source Database: `source_db`
- Target Database: `target_db`
- Schema: `app_schema`
- 별도 병합 Table: `merge_table_01`, `merge_table_02`
- 제외 대상: `excluded_table_*`, `excluded_prefix*`, `excluded_event*`
- 파일 데이터 영역: `DATA_A`, `DATA_B`
- 예시 경로: `/opt/example-app/data`
- 예시 IP: `192.0.2.10`

실행 전 스크립트의 Placeholder를 실제 환경의 입력값 또는 별도 설정값으로 연결하고, 테스트 환경에서 먼저 검증해야 합니다.

## 안전 주의사항

- 운영 환경에서 바로 실행하지 않습니다.
- Source/Target 방향과 Database, Schema, Port 및 Instance 매핑을 먼저 확인합니다.
- 충분한 Database/File Backup과 복구 절차를 확보합니다.
- 실행 중인 애플리케이션과 파일 사용 여부를 확인합니다.
- 생성되는 SQL과 실행 계획을 검토한 뒤 적용합니다.
- PostgreSQL Version과 Object 구성 차이를 사전에 검증합니다.

## 검증

공개 전 다음 항목을 확인했습니다.

- Shell 문법 검사
- 실제 서버, Database, Schema, Table, 계정 및 경로 제거
- 비밀번호와 접속 문자열 미포함
- 운영 환경 고유 식별값 제거

이 코드는 특정 운영 이관 작업을 일반화한 참고 구현이며, 환경별 검증 없이 실행할 수 있는 범용 도구를 의미하지 않습니다.
