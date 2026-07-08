\echo '## 01. Instance Health / Restart Check'
SELECT
    current_database() AS database_name,
    pg_postmaster_start_time() AS postmaster_start_time,
    now() - pg_postmaster_start_time() AS uptime,
    CASE
        WHEN pg_postmaster_start_time() > now() - interval '1 day'
        THEN '[WARN] RESTARTED_WITHIN_24H'
        ELSE 'OK'
    END AS restart_status;
