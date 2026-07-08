\echo '## 05. Dead Tuples / Autovacuum Delay'

WITH table_stats AS (
    SELECT
        schemaname,
        relname,
        n_live_tup,
        n_dead_tup,
        round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_tuple_pct,
        last_vacuum,
        last_autovacuum,
        last_analyze,
        last_autoanalyze,
        vacuum_count,
        autovacuum_count
    FROM pg_stat_user_tables
)
SELECT *
FROM table_stats
WHERE n_dead_tup >= :dead_tuple_min
   OR dead_tuple_pct >= :dead_tuple_pct
   OR (
        n_dead_tup > 0
        AND last_autovacuum IS NOT NULL
        AND last_autovacuum < now() - interval :'autovacuum_delay_threshold'
      )
ORDER BY n_dead_tup DESC, dead_tuple_pct DESC NULLS LAST
LIMIT 50;

\echo '## 05. Running Vacuum / Autovacuum'

SELECT
    pid,
    datname,
    relid::regclass AS relation_name,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    heap_blks_vacuumed,
    index_vacuum_count
FROM pg_stat_progress_vacuum
ORDER BY pid;
