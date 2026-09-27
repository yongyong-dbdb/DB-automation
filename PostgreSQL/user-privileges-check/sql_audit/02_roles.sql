\echo '## 02. Role Attributes'

SELECT
    rolname,
    rolsuper,
    rolcreatedb,
    rolcreaterole,
    rolreplication,
    rolcanlogin,
    rolconnlimit,
    rolvaliduntil,
    ARRAY(
        SELECT b.rolname
        FROM pg_auth_members m
        JOIN pg_roles b ON b.oid = m.roleid
        WHERE m.member = r.oid
        ORDER BY b.rolname
    ) AS member_of
FROM pg_roles r
ORDER BY rolsuper DESC, rolcanlogin DESC, rolreplication DESC, rolname;
