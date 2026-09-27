\echo '## 06. Sequence Privileges'

SELECT
    object_schema,
    object_name,
    grantee,
    privilege_type,
    is_grantable
FROM information_schema.usage_privileges
WHERE object_type = 'SEQUENCE'
  AND object_schema !~ :'excluded_schema_regex'
ORDER BY object_schema, object_name, grantee, privilege_type;
