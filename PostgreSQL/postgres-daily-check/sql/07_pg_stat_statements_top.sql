\echo '## 07. pg_stat_statements TOP SQL'
SELECT
    EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'pg_stat_statements'
    ) AS has_pg_stat_statements
\gset

\if :has_pg_stat_statements
\echo 'pg_stat_statements extension is installed'
SELECT
    pss.dbid,
    psd.datname,
    pss.queryid,
    substring(MAX(pss.query), 1, 200) AS query_sample,
    CASE
        WHEN MAX(pss.query) ILIKE 'select%' THEN 'SELECT'
        WHEN MAX(pss.query) ILIKE 'update%' THEN 'UPDATE'
        WHEN MAX(pss.query) ILIKE 'delete%' THEN 'DELETE'
        WHEN MAX(pss.query) ILIKE 'insert%' THEN 'INSERT'
        ELSE 'OTHER'
    END AS query_type,
    SUM(pss.calls) AS total_calls,
    ROUND(SUM(pss.total_exec_time)::numeric, 2) AS total_exec_time,
    ROUND(SUM(pss.total_plan_time)::numeric, 2) AS total_plan_time,
    ROUND((SUM(pss.total_exec_time) / NULLIF(SUM(pss.calls), 0))::numeric, 2) AS exec_time_avg,
    ROUND((SUM(pss.total_plan_time) / NULLIF(SUM(pss.calls), 0))::numeric, 2) AS plan_time_avg,
    SUM(pss.shared_blks_hit) AS shared_blks_hit,
    SUM(pss.shared_blks_read) AS shared_blks_read,
    SUM(pss.shared_blks_dirtied) AS shared_blks_dirtied,
    SUM(pss.shared_blks_written) AS shared_blks_written
FROM pg_stat_statements pss
JOIN pg_stat_database psd ON pss.dbid = psd.datid
GROUP BY pss.dbid, psd.datname, pss.queryid
ORDER BY SUM(pss.total_exec_time) DESC
LIMIT :top_sql_limit;
\else
\echo 'pg_stat_statements extension is NOT installed'
\echo 'Enable it with shared_preload_libraries and CREATE EXTENSION pg_stat_statements if TOP SQL is required.'
\endif
