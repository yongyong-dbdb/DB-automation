# MySQL GTID Replication Automation

`mysql_gtid_replication.sh` automates Oracle MySQL GTID-based asynchronous replication setup while keeping instance identity, GTID history, configuration changes, and destructive operations explicit.

## Scope

- Oracle MySQL 8.0 / 8.4 / 9.x GTID replication
- Source and Replica on the same server or on separate servers
- Local Unix socket or TCP management connections
- Multiple local MySQL instances
- Default or named replication channel
- Local `my.cnf` discovery and guarded configuration updates
- Remote instances where OS configuration is not directly accessible
- Logical provisioning with `mysqldump`, or externally managed provisioning

MariaDB GTID is not supported.

## Workflow

```text
discover
  -> configure (when required)
  -> precheck
  -> initialize
  -> replicate
  -> validate
  -> status
```

Run individual steps with:

```bash
sh mysql_gtid_replication.sh discover
sh mysql_gtid_replication.sh configure
sh mysql_gtid_replication.sh precheck
sh mysql_gtid_replication.sh initialize
sh mysql_gtid_replication.sh replicate
sh mysql_gtid_replication.sh validate
sh mysql_gtid_replication.sh status
```

`all` runs the normal setup sequence, but any restart or provisioning decision that requires review remains explicit.

## Discovery

The script detects active local MySQL sockets and configuration candidates where possible. It records Source and Replica management endpoints and validates the runtime instance after authentication.

The selected endpoint is not treated as sufficient identity by itself. Runtime values such as `server_uuid`, `server_id`, `datadir`, socket, port, product, and version are used to detect accidental cross-instance selection.

For TCP endpoints, the script distinguishes:

- `local`: mysqld is on the controller host, so local OS/config inspection can be used.
- `remote`: mysqld is on another server, so local filesystem assumptions are disabled.

## Configuration

The script can create a managed `[mysqld]` block for GTID replication requirements and preserve unrelated existing configuration.

Typical required settings include:

```ini
server_id=<unique value>
log_bin
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
log_replica_updates=ON
relay_log_recovery=ON
```

Actual variable names are capability-checked where MySQL version terminology differs.

Before a local configuration change, the script:

1. identifies the selected configuration file,
2. generates the proposed block,
3. validates option-file parsing,
4. uses `mysqld --validate-config` when available,
5. creates a backup beside the original file,
6. applies only after explicit approval.

Restart handling attempts to identify systemd, `mysqld_safe`, or a direct `mysqld --daemonize` launcher. If a safe restart cannot be determined, the script prints the required next action instead of guessing.

## Precheck

`precheck` validates at least:

- Source and Replica are different `server_uuid` values
- unique, non-zero `server_id`
- compatible Source -> Replica version direction
- binary logging enabled
- `gtid_mode=ON`
- `enforce_gtid_consistency=ON`
- replication update logging
- application-table engine considerations
- Source binary-log retention

`ROW` binary logging is expected for the automated setup.

## Initialization methods

`initialize` offers:

- `online-dump`: logical Source -> Replica provisioning for test and small-to-moderate environments
- `already`: no copy; use only when data and GTID history are already confirmed compatible
- `external`: physical backup, Clone, or another separately validated provisioning method
- `skip`: exit without changing initialization state

The logical path uses a consistent Source dump and includes GTID metadata for a clean Replica restore.

### GTID safety policy

GTID history is treated as transaction identity, not merely as a configuration value.

For Source and Replica, the script compares GTID sets using MySQL GTID functions rather than parsing UUID ranges in shell code:

```sql
GTID_SUBTRACT(replica_gtid_executed, source_gtid_executed) -- extra on Replica
GTID_SUBTRACT(source_gtid_executed, replica_gtid_executed) -- missing on Replica
```

The automation does **not** silently remove or rewrite extra Replica GTIDs.

In particular:

- `RESET REPLICA` / `RESET REPLICA ALL` clears replication metadata and relay logs, but does not clear GTID execution history.
- `RESET BINARY LOGS AND GTIDS` clears GTID execution history and binary logs and is therefore not used as a generic divergence fix.
- Existing extra GTIDs require reviewed reconciliation or controlled reprovisioning.
- The script does not inject dummy transactions to manufacture matching GTID sets.

A non-empty Replica can be valid, but it is not assumed to be compatible solely because application rows appear similar.

## Replication account

The replication connection account is designed for minimum privilege:

```sql
GRANT REPLICATION SLAVE ON *.* TO '<user>'@'<host>';
```

The script can create a dedicated account, reuse an existing reviewed account, or print SQL only.

Passwords are requested interactively and are not written to the persistent state file.

## Replication transport

TLS is the default recommendation.

Supported choices include:

- certificate/identity verification with a CA file
- encrypted connection without identity verification for controlled test use
- plain transport only after explicit acknowledgement

The Source address used by the Replica I/O thread is entered separately from the controller's management endpoint so NAT, proxy, or mapped-port environments can be represented explicitly.

## Remote server handling

When an instance is remote, the controller does not assume it can modify that server's filesystem.

If the required OS action cannot be performed from the controller, the automation must print or generate the exact validation/configuration/restart commands before the workflow stops for manual intervention.

Do not copy a local `my.cnf` path to a remote node merely because the path text is identical. Runtime instance identity must be validated on that server.

## Output and state

Default persistent state:

```text
.mysql_gtid_replication.state
```

Default work root:

```text
mysql_gtid_replication_work/
```

Each run creates a timestamped work directory for proposed configuration, validation logs, dump files, checksums, account/grant evidence, and diagnostics.

Passwords are not stored in the persistent state file.

Environment overrides:

```text
MYSQL_GTID_STATE_FILE
MYSQL_GTID_WORK_ROOT
```

## Re-running safely

After a failure, read the printed `NEXT STEP` and diagnostics before rerunning later phases.

Do not blindly repeat `initialize` when the Replica has extra GTIDs. Repeating the same logical restore does not erase prior GTID execution history.

If a Replica is rebuilt as a fresh MySQL instance and its `server_uuid` changes, run discovery again so persistent instance identity is not reused incorrectly.

## Important operational notes

- Source remains authoritative only when the operator has explicitly chosen that topology.
- A logical dump is not a universal replacement for a physical backup for very large production datasets.
- Binary-log retention must cover dump, restore, and catch-up duration.
- Non-InnoDB tables are not fully protected by a single-transaction online dump.
- Event Scheduler definitions require review so scheduled jobs do not execute unexpectedly on a Replica.
- Replication filters are not inferred. The automated logical path expects the initialized database scope to match the unfiltered channel scope.

## Version

Current script version: **1.0.14**

The current safety model intentionally prefers stopping with actionable diagnostics over automatically resetting GTID history.