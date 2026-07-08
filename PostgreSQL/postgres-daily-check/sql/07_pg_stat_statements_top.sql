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
    psd.datname,
    pss.queryid,
    CASE
        WHEN MAX(pss.query) ILIKE 'select%' THEN 'SELECT'
        WHEN MAX(pss.query) ILIKE 'update%' THEN 'UPDATE'
        WHEN MAX(pss.query) ILIKE 'delete%' THEN 'DELETE'
        WHEN MAX(pss.query) ILIKE 'insert%' THEN 'INSERT'
        ELSE 'OTHER'
    END AS query_type,
    SUM(pss.calls) AS calls,
    ROUND(SUM(pss.total_exec_time)::numeric, 2) AS total_exec_ms,
    ROUND((SUM(pss.total_exec_time) / NULLIF(SUM(pss.calls), 0))::numeric, 2) AS avg_exec_ms,
    SUM(pss.rows) AS rows,
    SUM(pss.shared_blks_read) AS shared_blks_read,
    SUM(pss.shared_blks_hit) AS shared_blks_hit,
    substring(MAX(pss.query), 1, 200) AS query_sample
FROM pg_stat_statements pss
JOIN pg_stat_database psd ON pss.dbid = psd.datid
GROUP BY psd.datname, pss.queryid
ORDER BY SUM(pss.total_exec_time) DESC
LIMIT :top_sql_limit;

\else
\echo 'pg_stat_statements extension is not installed'
\endif
