\echo '## 01. Instance Health / Restart Check'
SELECT
    current_database() AS database_name,
    pg_postmaster_start_time() AS postmaster_start_time,
    CASE
        WHEN pg_postmaster_start_time() > now() - interval '1 day'
        THEN chr(27) || '[31m' || (now() - pg_postmaster_start_time())::text || chr(27) || '[0m'
        ELSE (now() - pg_postmaster_start_time())::text
    END AS uptime,
    CASE
        WHEN pg_postmaster_start_time() > now() - interval '1 day'
        THEN 'RESTARTED_WITHIN_24H'
        ELSE 'NO_RESTART_WITHIN_24H'
    END AS restart_status;
