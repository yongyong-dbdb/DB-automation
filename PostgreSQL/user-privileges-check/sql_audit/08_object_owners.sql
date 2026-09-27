\echo '## 08. Object Owners'

\echo '## 08. Schema Owners'
SELECT
    nspname AS schema_name,
    pg_get_userbyid(nspowner) AS owner
FROM pg_namespace
WHERE nspname !~ :'excluded_schema_regex'
ORDER BY schema_name;

\echo '## 08. Table / View / Sequence Owners'
SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'p' THEN 'partitioned_table'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized_view'
        WHEN 'S' THEN 'sequence'
        WHEN 'f' THEN 'foreign_table'
        ELSE c.relkind::text
    END AS object_type,
    pg_get_userbyid(c.relowner) AS owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname !~ :'excluded_schema_regex'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
ORDER BY schema_name, object_type, object_name;
