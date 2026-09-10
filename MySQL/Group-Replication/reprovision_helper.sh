#!/bin/sh
# Host-side reprovision executor. Copy the complete package to the target host.
# No package installation, GTID reset, or original-directory deletion.
set -eu
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ACTION=${1:-help}
case $ACTION in stage|swap|rollback) :;; *) printf 'Usage: sh reprovision_helper.sh stage|swap|rollback PACKAGE TARGET_AUTH SOURCE_AUTH\nAUTH: absolute client option file, or login-path:NAME\n'; exit 2;; esac
PKG=$(readlink -f "${2:?Package directory required}")
TARGET_AUTH=${3:?Target authentication required}
SOURCE_AUTH=${4:?Source authentication required}
MYSQL=${MYSQL_GR_MYSQL:-mysql}
MYSQLDUMP=${MYSQL_GR_MYSQLDUMP:-mysqldump}
for utility in "$MYSQL" "$MYSQLDUMP" sha256sum readlink stat awk sed cmp cp mv mkdir chmod chown id mktemp; do command -v "$utility" >/dev/null 2>&1 || fail "Missing existing utility $utility"; done
[ -d "$PKG" ] && [ ! -L "$PKG" ] || fail 'Invalid package directory'
[ "$(stat -c %u "$PKG")" = "$(id -u)" ] || fail 'Package must be owned by the executing OS account'
LOCK="$PKG/.executor.lock"
mkdir "$LOCK" || fail 'Executor lock exists; inspect previous operation before retry'
WORK=$(mktemp -d "$PKG/.executor.XXXXXX")
STAGED_RUNNING=no
cleanup_executor() {
    code=$?
    trap - 0 1 2 15
    if [ "$STAGED_RUNNING" = yes ]; then
        # Both auth paths are needed if import failed during account restoration.
        if ! db "$SOURCE_AUTH" "$STAGE_SOCKET" 'SHUTDOWN;' >/dev/null 2>&1; then
            "$MYSQL" --no-defaults --no-login-paths --protocol=SOCKET --socket="$STAGE_SOCKET" -uroot -e 'SHUTDOWN;' >/dev/null 2>&1 || printf 'Staging may still be running at %s; inspect it.\n' "$STAGE_SOCKET" >&2
        fi
    fi
    # Evidence and every datadir are retained, including failed staging directories.
    rmdir "$LOCK" 2>/dev/null || :
    exit "$code"
}
trap cleanup_executor 0
trap 'exit 130' 2
trap 'exit 143' 1 15
db() (
    auth=$1; socket=$2; statement=$3
    case $auth in login-path:*) set -- "--login-path=${auth#login-path:}";; /*) [ -r "$auth" ] || fail 'Unreadable auth file'; set -- "--defaults-file=$auth" --no-login-paths;; *) fail 'AUTH must be an absolute option file or login-path:NAME';; esac
    printf '%s\n' "$statement" | "$MYSQL" "$@" --protocol=SOCKET --socket="$socket" --connect-timeout=5 --batch --raw --skip-column-names
)
field() { [ -f "$PKG/$1" ] || fail "Missing package field $1"; cat "$PKG/$1"; }
save() { printf '%s\n' "$2" > "$PKG/$1"; }
OLD_UUID=$(field expected_uuid)
SOCKET=$(field expected_socket)
DATA=$(field expected_datadir); DATA=${DATA%/}
VERSION=$(field source_version)
GTID=$(field target_gtid)
CNF=$(field expected_cnf)
case $DATA in /*) :;; *) fail 'Datadir must be absolute';; esac
[ "$DATA" != / ] && [ -n "$DATA" ] || fail 'Unsafe datadir'
check_package() (
    cd "$PKG"
    sha256sum -c package.sha256 > "$WORK/checksums" 2>&1 || fail 'Package checksum mismatch'
)
identity() (
    expected=$1; auth=$2
    actual=$(db "$auth" "$SOCKET" 'SELECT @@server_uuid;') || fail 'Cannot query target identity'
    [ "$actual" = "$expected" ] || fail 'Server UUID changed'
    current=$(db "$auth" "$SOCKET" 'SELECT @@datadir;')
    [ "${current%/}" = "$DATA" ] || fail 'Target datadir changed'
    [ "$(db "$auth" "$SOCKET" 'SELECT @@version;')" = "$VERSION" ] || fail 'Version differs from source'
    [ "$(db "$auth" "$SOCKET" 'SELECT @@super_read_only;')" = 1 ] || fail 'Target must remain write fenced'
    [ "$(db "$auth" "$SOCKET" "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE IN ('ONLINE','RECOVERING');")" = 0 ] || fail 'Target is already a GR member'
)
wait_down() (
    pid=$1; start=$2; attempt=0
    while [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start" ]; do
        [ "$attempt" -lt 120 ] || fail 'Process did not stop; refusing duplicate startup or datadir move'
        sleep 1; attempt=$((attempt+1))
    done
)
capture_launcher() {
    pidfile=$(db "$TARGET_AUTH" "$SOCKET" 'SELECT @@pid_file;')
    PID=$(cat "$pidfile")
    case $PID in ''|*[!0-9]*) fail 'Invalid server PID';; esac
    EXE=$(readlink -f "/proc/$PID/exe")
    case ${EXE##*/} in mysqld|mysqld-debug) :;; *) fail 'PID is not mysqld';; esac
    CWD=$(readlink -f "/proc/$PID/cwd")
    tr '\000' '\n' < "/proc/$PID/cmdline" > "$PKG/launcher.argv"
    # Unknown command-line options could write outside staging or defeat fences.
    first=yes
    while IFS= read -r arg; do
        if [ "$first" = yes ]; then first=no; continue; fi
        case $arg in --defaults-file=*|--daemonize|--user=*|--skip-replica-start=ON|--event-scheduler=OFF|--super-read-only=ON) :;; *) fail "Launcher option needs explicit support before swap: $arg";; esac
    done < "$PKG/launcher.argv"
    grep -Fx -- "--defaults-file=$CNF" "$PKG/launcher.argv" >/dev/null || fail 'Explicit matching --defaults-file is required for this direct executor'
    parent=$(awk '{print $4}' "/proc/$PID/stat")
    parent_name=$(cat "/proc/$parent/comm")
    case $parent_name in systemd|init|bash|sh|dash) :;; *) fail 'Unsupported supervisor; do not stop this instance automatically';; esac
    service=$(sed -n 's#.*\/\([^/]*\.service\)$#\1#p' "/proc/$PID/cgroup" | head -n 1)
    if [ -n "$service" ] && [ "$(systemctl show "$service" -p MainPID --value)" = "$PID" ]; then
        fail 'Systemd-managed instance requires a separately reviewed launcher; direct executor will not bypass it'
    fi
    save expected_pid_file "$pidfile"
    save launcher_exe "$EXE"; save launcher_cwd "$CWD"
    save original_inode "$(stat -c '%d:%i' "$DATA")"
    save original_gtid "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT REPLACE(@@gtid_executed,CHAR(10),"");')"
    db "$TARGET_AUTH" "$SOCKET" "SELECT CONCAT('START REPLICA IO_THREAD FOR CHANNEL ',QUOTE(CHANNEL_NAME),';') FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON'; SELECT CONCAT('START REPLICA SQL_THREAD FOR CHANNEL ',QUOTE(CHANNEL_NAME),';') FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME NOT LIKE 'group_replication_%' AND SERVICE_STATE='ON';" > "$PKG/original_async.sql"
}
start_original() (
    exe=$(field launcher_exe); cwd=$(field launcher_cwd)
    set --
    first=yes
    while IFS= read -r arg; do
        if [ "$first" = yes ]; then first=no; continue; fi
        case $arg in --daemonize) continue;; esac
        set -- "$@" "$arg"
    done < "$PKG/launcher.argv"
    cd "$cwd"
    "$exe" "$@" --daemonize --skip-replica-start=ON --event-scheduler=OFF --super-read-only=ON
)
wait_up() (
    auth=$1; expected=$2; attempt=0
    while [ "$attempt" -lt 120 ]; do
        if uuid=$(db "$auth" "$SOCKET" 'SELECT @@server_uuid;' 2>/dev/null); then
            [ "$uuid" = "$expected" ] || fail 'Unexpected UUID after startup'
            exit 0
        fi
        sleep 1; attempt=$((attempt+1))
    done
    fail 'Instance did not reconnect'
)
stage_paths() {
    STAGE=$(field stage_path)
    STAGE_SOCKET=$(field stage_socket)
    BACKUP=$(field backup_path)
    FAILED=$(field failed_path)
    for path in "$STAGE" "$BACKUP" "$FAILED"; do
        case $path in "$DATA".gr_stage_*|"$DATA".gr_backup_*|"$DATA".gr_failed_*) :;; *) fail 'Invalid saved staging/backup path';; esac
        [ ! -L "$path" ] || fail 'Staging/backup path is a symlink'
    done
}
staging_validate() (
    auth=$1; socket=$2
    [ "$(db "$auth" "$socket" "SELECT GTID_SUBSET(@@gtid_executed,'$GTID') AND GTID_SUBSET('$GTID',@@gtid_executed);")" = 1 ] || fail 'GTID is not exactly equal to source snapshot'
    [ "$(db "$auth" "$socket" 'SELECT @@super_read_only;')" = 1 ] || fail 'New instance is not write fenced'
    [ "$(db "$auth" "$socket" 'SELECT @@event_scheduler;')" = OFF ] || fail 'Event scheduler must remain OFF'
    case $auth in login-path:*) set -- "--login-path=${auth#login-path:}";; *) set -- "--defaults-file=$auth" --no-login-paths;; esac
    # Canonical source dump includes rows ordered by primary key, full stored
    # objects, schemas, indexes, constraints, and DEFINER clauses.
    databases=$(cat "$PKG/databases")
    set -f
    for database in $databases; do case $database in *[!A-Za-z0-9_\$]*) fail 'Unsupported schema name';; esac; done
    "$MYSQLDUMP" "$@" --protocol=SOCKET --socket="$socket" --skip-comments --skip-dump-date --no-tablespaces --set-gtid-purged=OFF --routines --events --triggers --hex-blob --order-by-primary --skip-extended-insert --databases $databases > "$WORK/actual.sql" 2> "$WORK/dump.err" || fail 'Full validation dump failed'
    cmp -s "$PKG/source_validation.sql" "$WORK/actual.sql" || fail 'Full schema/stored-object/data validation differs; inspect protected executor evidence'
    # Reuse the same export logic to compare account authentication, grants,
    # role edges and default roles without printing authentication hashes.
    (
        MYSQL_GR_LIB_ONLY=1
        . "$PKG/mysql_gr_migrate.sh"
        RUN="$WORK/account_validation"; TEMP="$WORK"; mkdir -p "$RUN" "$RUN/actual"
        sql() { db "$auth" "$socket" "$2"; }
        export_source_accounts "$RUN/actual" 1 >/dev/null || fail "Account export failed during validation"
        for file in source_accounts.list source_accounts.sql source_grants.sql source_default_roles.sql; do
            cmp -s "$PKG/$file" "$RUN/actual/$file" || fail "Account validation differs: $file"
        done
    )
)
check_package
case $ACTION in
stage)
    [ ! -e "$PKG/stage_path" ] || fail 'Staging already attempted; preserve evidence and build a new package to retry'
    identity "$OLD_UUID" "$TARGET_AUTH"
    [ "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT COUNT(*) FROM performance_schema.persisted_variables;')" = 0 ] || fail "Persisted target settings require explicit reprovision migration; original is unchanged"
    [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'Original datadir is not a plain directory'
    capture_launcher
    [ "$(id -u)" = 0 ] || [ "$(id -u)" = "$(stat -c %u "$DATA")" ] || fail 'Run as original datadir owner or root'
    [ -z "$(find "$DATA" -type l -print -quit)" ] || fail 'Datadir symlinks require a reviewed storage executor'
    for variable in log_bin_basename relay_log_basename; do
        external=$(db "$TARGET_AUTH" "$SOCKET" "SELECT @@$variable;")
        case $external in "$DATA"/*) :;; *) fail "External $variable requires an explicit retention/rollback plan";; esac
    done
    stamp=$(date +%Y%m%d_%H%M%S)_$$
    STAGE="$DATA.gr_stage_$stamp"
    STAGE_SOCKET="$STAGE/gr.sock"
    [ "${#STAGE_SOCKET}" -lt 100 ] || fail 'Staging socket pathname is too long'
    save stage_path "$STAGE"; save stage_socket "$STAGE_SOCKET"
    save backup_path "$DATA.gr_backup_$stamp"; save failed_path "$DATA.gr_failed_$stamp"
    owner=$(stat -c %U "$DATA"); group=$(stat -c %G "$DATA")
    mkdir "$STAGE"
    chmod "$(stat -c %a "$DATA")" "$STAGE"
    chown "$owner:$group" "$STAGE"
    # Reject external tablespaces and nondefault storage layouts. A fresh
    # datadir cannot safely replace files living outside it.
    [ "$(db "$TARGET_AUTH" "$SOCKET" "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES WHERE SPACE_TYPE='General' AND NAME<>'mysql';")" = 0 ] || fail 'External/general tablespaces require a reviewed executor'
    lower=$(db "$TARGET_AUTH" "$SOCKET" 'SELECT @@lower_case_table_names;')
    "$EXE" --no-defaults --initialize-insecure --user="$owner" --datadir="$STAGE" --lower-case-table-names="$lower" > "$WORK/initialize.log" 2>&1
    # Staging reads no original option files, has no network listener, and
    # writes logs only inside its own directory.
    "$EXE" --no-defaults --user="$owner" --datadir="$STAGE" --socket="$STAGE_SOCKET" --pid-file="$STAGE/gr.pid" --log-error="$STAGE/gr.log" --skip-networking --mysqlx=OFF --event-scheduler=OFF --skip-replica-start=ON --gtid-mode=ON --enforce-gtid-consistency=ON --log-bin=gr-stage-bin --server-id=4294967294 --lower-case-table-names="$lower" --daemonize
    STAGED_RUNNING=yes
    { printf 'SET SESSION sql_log_bin=0;\n'; cat "$PKG/source_accounts.sql" "$PKG/source_application.sql" "$PKG/source_grants.sql"; printf 'SET GLOBAL super_read_only=ON;\n'; } | "$MYSQL" --no-defaults --no-login-paths --protocol=SOCKET --socket="$STAGE_SOCKET" -uroot --binary-mode > "$WORK/restore.log" 2>&1
    staging_validate "$SOURCE_AUTH" "$STAGE_SOCKET"
    new_uuid=$(db "$SOURCE_AUTH" "$STAGE_SOCKET" 'SELECT @@server_uuid;')
    [ "$new_uuid" != "$OLD_UUID" ] || fail 'Staging UUID unexpectedly equals original'
    save new_uuid "$new_uuid"
    pid=$(cat "$STAGE/gr.pid"); start=$(awk '{print $22}' "/proc/$pid/stat")
    db "$SOURCE_AUTH" "$STAGE_SOCKET" 'SHUTDOWN;'
    wait_down "$pid" "$start"
    STAGED_RUNNING=no
    # Original TLS files remain authoritative; preserve certificate identity.
    for name in ca.pem server-cert.pem server-key.pem; do
        [ ! -f "$DATA/$name" ] || cp -p "$DATA/$name" "$STAGE/$name"
    done
    # Capture the entire include chain using the reviewed library parser.
    ( MYSQL_GR_LIB_ONLY=1; . "$PKG/mysql_gr_migrate.sh"; TEMP="$WORK"; cnf_chain_snapshot "$CNF" "$PKG/include_chain.before" "$CWD" )
    save state STAGED_VALIDATED
    printf 'STAGED_VALIDATED: %s. Original instance and datadir unchanged.\n' "$STAGE"
    ;;
swap)
    [ "$(field state)" = STAGED_VALIDATED ] || fail 'Validated staging is required'
    stage_paths
    identity "$OLD_UUID" "$TARGET_AUTH"
    [ "$(stat -c '%d:%i' "$DATA")" = "$(field original_inode)" ] || fail 'Original directory identity changed'
    [ "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT REPLACE(@@gtid_executed,CHAR(10),"");')" = "$(field original_gtid)" ] || fail 'Original GTID changed after staging'
    [ ! -e "$BACKUP" ] && [ ! -e "$FAILED" ] || fail 'Backup/failed path collision'
    [ "$(stat -c %d "$DATA")" = "$(stat -c %d "$STAGE")" ] || fail 'Swap must stay on the same filesystem'
    ( MYSQL_GR_LIB_ONLY=1; . "$PKG/mysql_gr_migrate.sh"; TEMP="$WORK"; cnf_chain_snapshot "$CNF" "$WORK/include_chain.current" "$(field launcher_cwd)" )
    cmp -s "$PKG/include_chain.before" "$WORK/include_chain.current" || fail 'Configuration/include chain changed since staging'
    # Refuse a live staging process before any rename.
    if [ -S "$STAGE_SOCKET" ]; then fail 'Staging socket still exists; verify clean shutdown'; fi
    pidfile=$(db "$TARGET_AUTH" "$SOCKET" 'SELECT @@pid_file;'); pid=$(cat "$pidfile")
    [ "$(readlink -f "/proc/$pid/exe")" = "$(field launcher_exe)" ] || fail 'Launcher changed'
    start=$(awk '{print $22}' "/proc/$pid/stat")
    save state STOPPING_ORIGINAL
    db "$TARGET_AUTH" "$SOCKET" 'SHUTDOWN;'
    wait_down "$pid" "$start"
    save state ORIGINAL_STOPPED
    mv -T "$DATA" "$BACKUP"
    save state ORIGINAL_BACKED_UP
    if ! mv -T "$STAGE" "$DATA"; then mv -T "$BACKUP" "$DATA"; start_original; fail 'Staging move failed; original directory restored'; fi
    save state SWAPPED
    if start_original && wait_up "$SOURCE_AUTH" "$(field new_uuid)" && staging_validate "$SOURCE_AUTH" "$SOCKET"; then
        save state SWAP_VALIDATED
        printf 'SWAP_VALIDATED. Retained original: %s. New instance remains fenced.\n' "$BACKUP"
    else
        printf 'Post-swap validation failed. Run rollback using this same package; original is retained at %s.\n' "$BACKUP" >&2
        exit 1
    fi
    ;;
rollback)
    stage_paths
    case $(field state) in ORIGINAL_BACKED_UP|SWAPPED|SWAP_VALIDATED) :;; *) fail 'State requires manual inspection; no paths moved';; esac
    [ -d "$BACKUP" ] && [ ! -e "$FAILED" ] || fail 'Rollback backup missing or failed path occupied'
    [ "$(stat -c '%d:%i' "$BACKUP")" = "$(field original_inode)" ] || fail 'Backup directory identity mismatch'
    if [ -d "$DATA" ]; then
        # Never move an unverified or still-running current datadir.
        identity "$(field new_uuid)" "$SOURCE_AUTH"
        [ "$(db "$SOURCE_AUTH" "$SOCKET" "SELECT GTID_SUBSET(@@gtid_executed,'$GTID') AND GTID_SUBSET('$GTID',@@gtid_executed);")" = 1 ] || fail 'New transactions exist; rollback requires reconciliation'
        pidfile=$(db "$SOURCE_AUTH" "$SOCKET" 'SELECT @@pid_file;'); pid=$(cat "$pidfile")
        start=$(awk '{print $22}' "/proc/$pid/stat")
        db "$SOURCE_AUTH" "$SOCKET" 'SHUTDOWN;'
        wait_down "$pid" "$start"
        mv -T "$DATA" "$FAILED"
    fi
    mv -T "$BACKUP" "$DATA"
    start_original
    wait_up "$TARGET_AUTH" "$OLD_UUID"
    identity "$OLD_UUID" "$TARGET_AUTH"
    [ "$(db "$TARGET_AUTH" "$SOCKET" 'SELECT REPLACE(@@gtid_executed,CHAR(10),"");')" = "$(field original_gtid)" ] || fail 'Original GTID changed during rollback'
    [ ! -s "$PKG/original_async.sql" ] || db "$TARGET_AUTH" "$SOCKET" "$(cat "$PKG/original_async.sql")"
    save state ROLLED_BACK
    printf 'ROLLED_BACK. Original UUID restored; writes, replication auto-start and events remain fenced.\n'
    ;;
esac
