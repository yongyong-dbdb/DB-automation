# PostgreSQL Account / Privilege Audit

PostgreSQL 계정과 권한 상태를 점검하는 간단한 감사 스크립트이다.

## 실행

```bash
cd /home/postgres
chmod +x postgres_privilege_audit.sh
bash postgres_privilege_audit.sh
```

접속 정보는 지정하지 않으면 psql 기본 동작과 PostgreSQL 환경변수를 사용한다.

```text
DB_NAME -> PGDATABASE -> psql default
DB_USER -> PGUSER -> psql default
DB_PORT -> PGPORT -> PG_PORT -> psql default
```

결과 파일은 기본적으로 아래 경로에 생성된다.

```text
$HOME/postgres_audit_reports/postgres_privilege_audit_HOST_DB_YYYYMMDD_HHMMSS.log
```

SQL 파일은 스크립트와 같은 경로의 `sql_audit` 디렉토리에 둔다.

## 환경별 설정

운영 정책에 따라 달라지는 값은 스크립트에 고정하지 않고 환경변수로 조정한다.

```bash
DB_NAME=postgres
DB_USER=postgres
DB_HOST=
DB_PORT=
ALLOWED_SUPERUSERS=postgres
SYSTEM_ROLE_REGEX='^pg_'
EXCLUDED_SCHEMA_REGEX='^(pg_|information_schema$)'
PUBLIC_GRANTEE=public
REPORT_DIR=$HOME/postgres_audit_reports
SQL_DIR=/path/to/sql_audit
```

- `DB_PORT`가 비어 있으면 `PGPORT`, `PG_PORT`, psql 기본값 순서로 접속한다.
- `ALLOWED_SUPERUSERS`는 허용할 superuser role 목록이다. 여러 개면 콤마로 구분한다.
- `SYSTEM_ROLE_REGEX`는 점검에서 제외할 시스템 role 정규식이다.
- `EXCLUDED_SCHEMA_REGEX`는 점검에서 제외할 schema 정규식이다.
- `PUBLIC_GRANTEE`는 database/schema 공개 권한을 확인할 grantee이다. PostgreSQL 기본값은 `public`이다.

## 점검 항목

- 허용 목록 외 superuser
- login role 중 `rolvaliduntil` 미설정
- replication role 중 `rolvaliduntil` 미설정
- 설정된 grantee의 database CONNECT/TEMP 권한
- 설정된 grantee의 schema CREATE/USAGE 권한
- 설정된 grantee 대상 default privilege
- role 속성 및 role membership
- database/schema/table/sequence/default privilege 상세
- schema/table/view/sequence owner

## Audit Findings Summary 해석 기준

`Audit Findings Summary`의 `severity`, `finding`, `detail`은 PostgreSQL 카탈로그에 존재하는 컬럼이 아니라, 점검 SQL에서 결과를 보기 쉽게 가공한 리포트용 컬럼이다.

| detail 문구 | 실제 조건 | 의미 |
|---|---|---|
| `superuser role exists outside configured allow list` | `pg_roles.rolsuper = true` 이고 `ALLOWED_SUPERUSERS`에 없는 role | 허용하지 않은 superuser가 존재함 |
| `login role has no password expiration timestamp` | `rolcanlogin = true` and `rolvaliduntil IS NULL` | 로그인 계정에 만료일이 없음 |
| `replication role has no password expiration timestamp` | `rolreplication = true` and `rolvaliduntil IS NULL` | replication 계정에 만료일이 없음 |
| `configured grantee has CONNECT privilege on database` | `PUBLIC_GRANTEE`가 DB에 `CONNECT` 권한 있음 | 설정된 공개 grantee가 DB 접속 권한을 가짐 |
| `configured grantee has TEMP privilege on database` | `PUBLIC_GRANTEE`가 DB에 `TEMP` 권한 있음 | 설정된 공개 grantee가 temp 객체 생성 가능 |
| `configured grantee has CREATE privilege on schema` | `PUBLIC_GRANTEE`가 schema에 `CREATE` 권한 있음 | 설정된 grantee가 schema에 객체 생성 가능 |
| `configured grantee has USAGE privilege on schema` | `PUBLIC_GRANTEE`가 schema에 `USAGE` 권한 있음 | schema 접근 경로가 열려 있음 |
| `default privilege grants ... to configured grantee` | default privilege가 `PUBLIC_GRANTEE`에 권한 부여 | 앞으로 생성될 객체에 자동 권한 부여됨 |

## 주의

`pg_authid`를 직접 조회하지 않기 때문에 password hash 존재 여부는 확인하지 않는다.
대신 운영에서 바로 확인 가능한 `rolvaliduntil`, superuser, replication, 공개 권한 중심으로 점검한다.
