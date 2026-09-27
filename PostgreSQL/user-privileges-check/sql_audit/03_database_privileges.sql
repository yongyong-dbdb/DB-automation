\echo '## 03. Database Privileges'

SELECT
    d.datname,
    pg_get_userbyid(d.datdba) AS owner,
    d.datallowconn,
    has_database_privilege(:'public_grantee', d.datname, 'CONNECT') AS configured_grantee_connect,
    has_database_privilege(:'public_grantee', d.datname, 'TEMP') AS configured_grantee_temp,
    d.datacl
FROM pg_database d
ORDER BY d.datname;
