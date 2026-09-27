\echo '## 05. Table Privileges'

SELECT
    table_schema,
    table_name,
    grantee,
    privilege_type,
    is_grantable
FROM information_schema.table_privileges
WHERE table_schema !~ :'excluded_schema_regex'
ORDER BY table_schema, table_name, grantee, privilege_type;
