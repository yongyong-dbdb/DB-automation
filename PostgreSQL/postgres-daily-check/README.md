# PostgreSQL Daily Check

Run this inside the `agent2` container as the `postgres` user.

## Files

- `postgres_daily_check.sh`: daily check shell script.
- `sql/`: SQL files for each check item.

## Checks

- DB connectivity and postmaster restart within 24 hours
- PostgreSQL logs with `FATAL`, `PANIC`, `ERROR`
- Disk usage and WAL directory usage
- WAL archiver and replication slot backlog
- Long-running queries
- `idle in transaction`
- Blocking locks
- Replication lag
- Dead tuples and autovacuum delay
- XID age
- `pg_stat_statements` TOP SQL

## Run Manually

```bash
cd /home/postgres/postgres-daily-check
chmod +x postgres_daily_check.sh
./postgres_daily_check.sh
```

The script prints the generated report path, for example:

```text
/home/postgres/postgres_daily_reports/postgres_daily_check_agent2_postgres_20260707_193000.log
```

## Environment Variables

```bash
export DB_NAME=postgres
export DB_USER=postgres
export DB_PORT=5432
export PGDATA=/home/postgres/data
export LOG_DIR=/home/postgres/data/log
export REPORT_DIR=/home/postgres/postgres_daily_reports
export LONG_QUERY_THRESHOLD='5 minutes'
export IDLE_XACT_THRESHOLD='5 minutes'
export AUTOVACUUM_DELAY_THRESHOLD='1 day'
export DEAD_TUPLE_MIN=10000
export DEAD_TUPLE_PCT=20
export TOP_SQL_LIMIT=20
```

## Cron Example

Run every day at 08:00.

```cron
0 8 * * * /home/postgres/postgres-daily-check/postgres_daily_check.sh >/tmp/postgres_daily_check.cron.log 2>&1
```

## Copy Into agent2

From Windows PowerShell:

```powershell
docker cp .\postgres-daily-check agent2:/home/postgres/postgres-daily-check
docker exec -i agent2 su - postgres -c "chmod +x /home/postgres/postgres-daily-check/postgres_daily_check.sh"
docker exec -i agent2 su - postgres -c "/home/postgres/postgres-daily-check/postgres_daily_check.sh"
```

