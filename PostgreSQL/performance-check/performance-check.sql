\set ON_ERROR_STOP off
\pset pager off
\pset border 2
\pset null '-'
\timing on

\echo
\echo '=== Target database statistics ==='
\conninfo

\echo
\echo '[5/10] Sequential Scan'
WITH candidates AS (
    SELECT *
    FROM pg_stat_user_tables
    WHERE seq_scan > 0
    ORDER BY seq_tup_read DESC
    LIMIT :top_n
)
SELECT current_database() AS database_name,
       schemaname,
       relname AS table_name,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       seq_scan,
       seq_tup_read,
       CASE WHEN seq_scan > 0 THEN seq_tup_read / seq_scan END AS rows_per_seq_scan,
       idx_scan,
       n_live_tup
FROM candidates
ORDER BY seq_tup_read DESC;

\echo
\echo '[6/10] Missing Index review candidates'
WITH candidates AS (
    SELECT *
    FROM pg_stat_user_tables
    WHERE seq_scan > 0
    ORDER BY seq_tup_read DESC
    LIMIT :top_n
)
SELECT current_database() AS database_name,
       schemaname,
       relname AS table_name,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       seq_scan,
       seq_tup_read,
       n_live_tup,
       'EXPLAIN (ANALYZE, BUFFERS) 및 필터 조건 검토 필요' AS recommendation
FROM candidates
WHERE pg_total_relation_size(relid) >= 100 * 1024 * 1024
ORDER BY seq_tup_read DESC;

\echo
\echo '[7/10] Unused Index review candidates'
SELECT current_database() AS database_name,
       s.schemaname,
       s.relname AS table_name,
       s.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       s.idx_scan,
       s.idx_tup_read,
       s.idx_tup_fetch
FROM pg_stat_user_indexes AS s
JOIN pg_index AS i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND NOT EXISTS (
      SELECT 1
      FROM pg_constraint AS c
      WHERE c.contype = 'f'
        AND c.conrelid = s.relid
        AND NOT EXISTS (
            SELECT 1
            FROM unnest(c.conkey) AS fk_column(attnum)
            WHERE NOT (
                fk_column.attnum = ANY (
                    string_to_array(i.indkey::text, ' ')::smallint[]
                )
            )
        )
  )
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT :top_n;

\echo
\echo '[8/10] Hot Tables'
SELECT current_database() AS database_name,
       s.schemaname,
       s.relname AS table_name,
       io.heap_blks_hit,
       io.heap_blks_read,
       s.n_tup_ins,
       s.n_tup_upd,
       s.n_tup_del,
       s.n_live_tup,
       s.n_dead_tup
FROM pg_stat_user_tables AS s
JOIN pg_statio_user_tables AS io USING (relid)
ORDER BY (io.heap_blks_hit + io.heap_blks_read) DESC
LIMIT :top_n;

\echo
\echo '[9/10] Connections - current value only'
SELECT current_database() AS database_name,
       state,
       count(*) AS current_connections,
       max(clock_timestamp() - xact_start)
           FILTER (WHERE xact_start IS NOT NULL) AS oldest_transaction,
       current_setting('max_connections')::integer AS max_connections
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state
ORDER BY current_connections DESC;
SELECT 'Peak 값은 pg_stat_activity 이력 없이 계산할 수 없습니다.' AS note;

\echo
\echo '[10/10] Wait Events - current sample only'
SELECT current_database() AS database_name,
       wait_event_type,
       wait_event,
       count(*) AS waiting_sessions
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
  AND wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY waiting_sessions DESC
LIMIT :top_n;
SELECT 'Wait 비율은 주기 샘플링 이력 없이 계산할 수 없습니다.' AS note;

\echo
\echo 'Important:'
\echo '- SQL별 실제 CPU 시간은 제공되지 않으므로 non_io_elapsed_ms는 참고용 대리 지표입니다.'
\echo '- Seq Scan은 작은 테이블 또는 대량 조회에서는 정상일 수 있습니다.'
\echo '- Missing/Unused Index 결과는 자동 적용 대상이 아니라 검토 후보입니다.'
\echo '- 이 스크립트는 DB 객체나 데이터를 생성, 변경 또는 삭제하지 않습니다.'
