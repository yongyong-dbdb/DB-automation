\echo '## 01. Audit Findings Summary'

WITH configured_grantee AS (
    SELECT
        CASE
            WHEN :'public_grantee' = 'public' THEN 0::oid
            ELSE (
                SELECT oid
                FROM pg_roles
                WHERE rolname = :'public_grantee'
            )
        END AS grantee_oid
),
findings AS (
    SELECT
        'CRITICAL' AS severity,
        'UNEXPECTED_SUPERUSER' AS finding,
        rolname AS object_name,
        'superuser role exists outside configured allow list' AS detail
    FROM pg_roles
    WHERE rolsuper
      AND rolname NOT IN (
          SELECT btrim(value)
          FROM regexp_split_to_table(:'allowed_superusers', ',') AS value
          WHERE btrim(value) <> ''
      )

    UNION ALL
    SELECT
        'WARN',
        'LOGIN_ROLE_WITHOUT_VALID_UNTIL',
        rolname,
        'login role has no password expiration timestamp'
    FROM pg_roles
    WHERE rolcanlogin
      AND rolvaliduntil IS NULL
      AND rolname !~ :'system_role_regex'

    UNION ALL
    SELECT
        'WARN',
        'REPLICATION_ROLE_WITHOUT_VALID_UNTIL',
        rolname,
        'replication role has no password expiration timestamp'
    FROM pg_roles
    WHERE rolreplication
      AND rolvaliduntil IS NULL

    UNION ALL
    SELECT
        'WARN',
        'CONFIGURED_GRANTEE_DATABASE_CONNECT',
        datname,
        'configured grantee has CONNECT privilege on database'
    FROM pg_database
    WHERE datallowconn
      AND has_database_privilege(:'public_grantee', datname, 'CONNECT')

    UNION ALL
    SELECT
        'WARN',
        'CONFIGURED_GRANTEE_DATABASE_TEMP',
        datname,
        'configured grantee has TEMP privilege on database'
    FROM pg_database
    WHERE datallowconn
      AND has_database_privilege(:'public_grantee', datname, 'TEMP')

    UNION ALL
    SELECT
        'CRITICAL',
        'CONFIGURED_GRANTEE_SCHEMA_CREATE',
        nspname,
        'configured grantee has CREATE privilege on schema'
    FROM pg_namespace
    WHERE nspname !~ :'excluded_schema_regex'
      AND has_schema_privilege(:'public_grantee', oid, 'CREATE')

    UNION ALL
    SELECT
        'WARN',
        'CONFIGURED_GRANTEE_SCHEMA_USAGE',
        nspname,
        'configured grantee has USAGE privilege on schema'
    FROM pg_namespace
    WHERE nspname !~ :'excluded_schema_regex'
      AND has_schema_privilege(:'public_grantee', oid, 'USAGE')

    UNION ALL
    SELECT
        'WARN',
        'DEFAULT_PRIVILEGE_TO_CONFIGURED_GRANTEE',
        COALESCE(d.defaclnamespace::regnamespace::text, '<database>'),
        'default privilege grants ' || a.privilege_type || ' to configured grantee'
    FROM pg_default_acl d
    CROSS JOIN LATERAL aclexplode(d.defaclacl) a
    JOIN configured_grantee g ON g.grantee_oid = a.grantee
)
SELECT
    severity,
    finding,
    object_name,
    detail
FROM findings
ORDER BY
    CASE severity
        WHEN 'CRITICAL' THEN 1
        WHEN 'WARN' THEN 2
        ELSE 3
    END,
    finding,
    object_name;
