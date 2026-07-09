\echo '## 04. Schema Privileges'

SELECT
    n.nspname AS schema_name,
    pg_get_userbyid(n.nspowner) AS owner,
    has_schema_privilege(:'public_grantee', n.oid, 'USAGE') AS configured_grantee_usage,
    has_schema_privilege(:'public_grantee', n.oid, 'CREATE') AS configured_grantee_create,
    n.nspacl
FROM pg_namespace n
WHERE n.nspname !~ :'excluded_schema_regex'
ORDER BY n.nspname;
