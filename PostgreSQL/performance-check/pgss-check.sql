\set ON_ERROR_STOP off
\pset pager off
\pset border 2
\pset null '-'
\timing on

\echo
\echo '=== Central pg_stat_statements source; target database:' :target_database '==='
\conninfo

SELECT EXISTS (
           SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'
       ) AS has_pg_stat_statements,
       COALESCE((
           SELECT quote_ident(n.nspname)
           FROM pg_extension AS e
           JOIN pg_namespace AS n ON n.oid = e.extnamespace
           WHERE e.extname = 'pg_stat_statements'
       ), 'public') AS pss_schema
\gset

\echo
\echo '[1/10] Top SQL'
\if :has_pg_stat_statements
SELECT :'target_database' AS database_name,
       queryid,
       calls,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round((total_exec_time / NULLIF(calls, 0))::numeric, 2) AS avg_exec_ms,
       rows,
       shared_blks_read,
       shared_blks_hit,
       left(regexp_replace(query, E'[\n\r\t]+', ' ', 'g'), 120) AS query
FROM :pss_schema.pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = :'target_database')
ORDER BY total_exec_time DESC
LIMIT :top_n;
\else
SELECT '중앙 조회 DB에 pg_stat_statements extension 객체가 없습니다.' AS message;
\endif

\echo
\echo '[2/10] SQL Change Analysis'
\if :has_pg_stat_statements
SELECT :'target_database' AS database_name,
       stats_reset,
       '누적 통계의 단발 조회입니다. 변화량은 이전 스냅샷 없이는 계산할 수 없습니다.' AS result
FROM :pss_schema.pg_stat_statements_info;
\else
SELECT 'pg_stat_statements 조회 뷰가 없어 변화 분석을 수행할 수 없습니다.' AS result;
\endif

\echo
\echo '[3/10] CPU-heavy SQL candidates - proxy only'
\if :has_pg_stat_statements
SELECT :'target_database' AS database_name,
       queryid,
       calls,
       round(total_exec_time::numeric, 2) AS elapsed_ms,
       round((blk_read_time + blk_write_time)::numeric, 2) AS measured_io_ms,
       round(GREATEST(total_exec_time - blk_read_time - blk_write_time, 0)::numeric, 2) AS non_io_elapsed_ms,
       round((total_exec_time / NULLIF(calls, 0))::numeric, 2) AS avg_exec_ms,
       left(regexp_replace(query, E'[\n\r\t]+', ' ', 'g'), 120) AS query
FROM :pss_schema.pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = :'target_database')
ORDER BY GREATEST(total_exec_time - blk_read_time - blk_write_time, 0) DESC
LIMIT :top_n;
\else
SELECT 'pg_stat_statements 조회 뷰가 없어 CPU 후보 SQL을 조회할 수 없습니다.' AS message;
\endif

\echo
\echo '[4/10] Temp-heavy SQL'
\if :has_pg_stat_statements
SELECT :'target_database' AS database_name,
       queryid,
       calls,
       temp_blks_read,
       temp_blks_written,
       pg_size_pretty((temp_blks_read * current_setting('block_size')::bigint)::bigint) AS temp_read,
       pg_size_pretty((temp_blks_written * current_setting('block_size')::bigint)::bigint) AS temp_written,
       left(regexp_replace(query, E'[\n\r\t]+', ' ', 'g'), 120) AS query
FROM :pss_schema.pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = :'target_database')
  AND (temp_blks_read > 0 OR temp_blks_written > 0)
ORDER BY temp_blks_written DESC, temp_blks_read DESC
LIMIT :top_n;
\else
SELECT 'pg_stat_statements 조회 뷰가 없어 Temp 사용 SQL을 조회할 수 없습니다.' AS message;
\endif
