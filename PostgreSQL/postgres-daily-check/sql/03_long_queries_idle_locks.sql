\echo '## 03. Long Queries'
SELECT
    pid,
    usename,
    datname,
    application_name,
    client_addr,
    state,
    now() - query_start AS query_age,
    wait_event_type,
    wait_event,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND query_start IS NOT NULL
  AND now() - query_start > interval :'long_query_threshold'
ORDER BY query_age DESC;

\echo '## 03. Idle In Transaction'
SELECT
    pid,
    usename,
    datname,
    application_name,
    client_addr,
    now() - xact_start AS xact_age,
    now() - state_change AS idle_age,
    wait_event_type,
    wait_event,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND xact_start IS NOT NULL
  AND now() - xact_start > interval :'idle_xact_threshold'
ORDER BY xact_age DESC;

\echo '## 03. Blocking Locks'
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.datname AS blocked_db,
    now() - blocked.query_start AS blocked_query_age,
    left(blocked.query, 1000) AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.state AS blocker_state,
    now() - blocker.query_start AS blocker_query_age,
    left(blocker.query, 1000) AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_lock
  ON blocked_lock.pid = blocked.pid
 AND NOT blocked_lock.granted
JOIN pg_locks blocker_lock
  ON blocker_lock.locktype = blocked_lock.locktype
 AND blocker_lock.database IS NOT DISTINCT FROM blocked_lock.database
 AND blocker_lock.relation IS NOT DISTINCT FROM blocked_lock.relation
 AND blocker_lock.page IS NOT DISTINCT FROM blocked_lock.page
 AND blocker_lock.tuple IS NOT DISTINCT FROM blocked_lock.tuple
 AND blocker_lock.virtualxid IS NOT DISTINCT FROM blocked_lock.virtualxid
 AND blocker_lock.transactionid IS NOT DISTINCT FROM blocked_lock.transactionid
 AND blocker_lock.classid IS NOT DISTINCT FROM blocked_lock.classid
 AND blocker_lock.objid IS NOT DISTINCT FROM blocked_lock.objid
 AND blocker_lock.objsubid IS NOT DISTINCT FROM blocked_lock.objsubid
 AND blocker_lock.pid <> blocked_lock.pid
 AND blocker_lock.granted
JOIN pg_stat_activity blocker
  ON blocker.pid = blocker_lock.pid
ORDER BY blocked_query_age DESC NULLS LAST;

