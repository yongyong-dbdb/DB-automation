\echo '## 07. Default Privileges'

SELECT
    defaclrole::regrole AS owner,
    COALESCE(defaclnamespace::regnamespace::text, '<database>') AS schema_name,
    CASE defaclobjtype
        WHEN 'r' THEN 'table'
        WHEN 'S' THEN 'sequence'
        WHEN 'f' THEN 'function'
        WHEN 'T' THEN 'type'
        WHEN 'n' THEN 'schema'
        ELSE defaclobjtype::text
    END AS object_type,
    defaclacl AS privileges
FROM pg_default_acl
ORDER BY owner, schema_name, object_type;
