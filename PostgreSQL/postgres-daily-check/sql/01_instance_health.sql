\echo '## 01. Instance Health / Restart Check'
SELECT
    current_database() AS database_name,
    inet_server_addr() AS server_addr,
    inet_server_port() AS server_port,
    pg_postmaster_start_time() AS postmaster_start_time,
    now() - pg_postmaster_start_time() AS uptime,
    CASE
        WHEN pg_postmaster_start_time() > now() - interval '1 day'
        THEN 'RESTARTED_WITHIN_24H'
        ELSE 'NO_RESTART_WITHIN_24H'
    END AS restart_status,
    version() AS postgres_version;

