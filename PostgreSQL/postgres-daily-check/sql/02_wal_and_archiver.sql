\echo '## 02. WAL / Archiver / Replication Slot Backlog'
\echo '## 02. WAL Reference LSN'
WITH wal_ref AS (
    SELECT
        pg_is_in_recovery() AS is_standby,
        CASE
            WHEN pg_is_in_recovery()
                THEN COALESCE(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
            ELSE pg_current_wal_lsn()
        END AS reference_lsn
)
SELECT
    CASE
        WHEN is_standby THEN 'standby'
        ELSE 'primary'
    END AS server_role,
    reference_lsn,
    pg_wal_lsn_diff(reference_lsn, '0/0') AS reference_wal_bytes_from_origin
FROM wal_ref;

\echo '## 02. Archiver Stats'
SELECT
    archived_count,
    last_archived_wal,
    last_archived_time,
    failed_count,
    last_failed_wal,
    last_failed_time,
    stats_reset
FROM pg_stat_archiver;

\echo '## 02. Replication Slot Backlog'
WITH wal_ref AS (
    SELECT
        CASE
            WHEN pg_is_in_recovery()
                THEN COALESCE(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
            ELSE pg_current_wal_lsn()
        END AS reference_lsn
)
SELECT
    slot_name,
    slot_type,
    database,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    reference_lsn,
    pg_size_pretty(pg_wal_lsn_diff(reference_lsn, restart_lsn)) AS retained_wal,
    wal_status,
    safe_wal_size
FROM pg_replication_slots
CROSS JOIN wal_ref
ORDER BY pg_wal_lsn_diff(reference_lsn, restart_lsn) DESC NULLS LAST;

