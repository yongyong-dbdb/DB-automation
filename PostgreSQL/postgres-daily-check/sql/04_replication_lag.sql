\echo '## 04. Replication Lag'
\echo '## 04. Replication Role'
WITH role_check AS (
    SELECT
        pg_is_in_recovery() AS is_standby,
        EXISTS (SELECT 1 FROM pg_stat_replication) AS has_downstream
)
SELECT
    CASE
        WHEN is_standby THEN 'standby'
        WHEN has_downstream THEN 'primary'
        ELSE 'single'
    END AS replication_role,
    is_standby,
    has_downstream
FROM role_check;

\echo '## 04. Primary: Downstream Replication Lag'
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn)) AS flush_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication
ORDER BY pg_wal_lsn_diff(sent_lsn, replay_lsn) DESC NULLS LAST;

\echo '## 04. Standby: WAL Receiver Status'
SELECT
    pid,
    status,
    receive_start_lsn,
    receive_start_tli,
    written_lsn,
    flushed_lsn,
    received_tli,
    last_msg_send_time,
    last_msg_receipt_time,
    latest_end_lsn,
    latest_end_time,
    slot_name,
    sender_host,
    sender_port,
    conninfo
FROM pg_stat_wal_receiver;
