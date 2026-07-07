# GitHub 업로드 방법

대상 저장소:

```text
https://github.com/yongyong-dbdb/DB-automation
```

업로드할 폴더:

```text
PostgreSQL
```

## Git이 설치되어 있고 인증되어 있는 환경

```bash
git clone https://github.com/yongyong-dbdb/DB-automation.git
cd DB-automation

mkdir -p PostgreSQL
cp -r /path/to/PostgreSQL/* PostgreSQL/

git add PostgreSQL
git commit -m "Add PostgreSQL automation scripts"
git push origin main
```

브랜치가 `main`이 아니라 `master`이면 마지막 줄은 다음처럼 바꿉니다.

```bash
git push origin master
```

## Windows PowerShell 예시

```powershell
git clone https://github.com/yongyong-dbdb/DB-automation.git
cd DB-automation

New-Item -ItemType Directory -Force PostgreSQL
Copy-Item "C:\Users\c4ic7\Documents\Codex\2026-07-06\new-chat\outputs\PostgreSQL\*" ".\PostgreSQL\" -Recurse -Force

git add PostgreSQL
git commit -m "Add PostgreSQL automation scripts"
git push origin main
```

## 포함 파일

```text
PostgreSQL/
  Dockerfile
  toss_chart_collect.py
  create_toss_chart_objects.sql
  alter_toss_chart_add_product_name.sql
  postgres-daily-check/
    postgres_daily_check.sh
    postgres_daily_compare.sh
    README.md
    README_ko.md
    sql/
      01_instance_health.sql
      02_wal_and_archiver.sql
      03_long_queries_idle_locks.sql
      04_replication_lag.sql
      05_dead_tuple_autovacuum.sql
      06_xid_age.sql
      07_pg_stat_statements_top.sql
```

