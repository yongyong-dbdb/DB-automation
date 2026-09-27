\echo '## 06. Database XID Age'
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    datfrozenxid,
    pg_size_pretty(pg_database_size(datname)) AS database_size
FROM pg_database
WHERE datallowconn
  AND datname NOT LIKE 'template%'
ORDER BY age(datfrozenxid) DESC;

\echo '## 06. Table XID Age TOP 50'
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    age(c.relfrozenxid) AS xid_age,
    c.relfrozenxid,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_relation_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname <> 'pg_toast'
ORDER BY age(c.relfrozenxid) DESC
LIMIT 50;
