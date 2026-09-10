"""Focused regression tests for candidate safeguards; no live DB mutation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('mysql_gr_migrate.sh').resolve()

class SafetyTests(unittest.TestCase):
    def shell(self, body, error=None):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, MYSQL_GR_LIB_ONLY='1', MYSQL_GR_WORK_ROOT=directory)
            head = f'. "{SCRIPT}"\nTEMP="$ROOT/temp"; RUN="$ROOT/run"; mkdir -p "$TEMP" "$RUN" "$ROOT/meta" "$ROOT/1" "$ROOT/2"\n'
            result = subprocess.run(['sh', '-c', head + body], env=env, capture_output=True, text=True)
            if error is None:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
            return result

    def test_exact_gtid_rejects_superset(self):
        self.shell('sql() { printf 0; }; exact_gtid 2 abc', 'GTID set differs')

    def test_exact_gtid_rejects_sql_error(self):
        self.shell('sql() { return 1; }; exact_gtid 2 abc', '')

    def test_exact_gtid_both_directions(self):
        self.shell('sql() { printf "%s" "$2" > "$RUN/query"; printf 1; }; exact_gtid 2 abc; [ "$(grep -o GTID_SUBSET "$RUN/query" | wc -l)" = 2 ]')

    def test_definer_orphan_stops(self):
        self.shell('sql() { printf 1; }; definer_guard 1', 'missing DEFINER accounts')

    def test_definer_accounts_present(self):
        self.shell('sql() { printf 0; }; definer_guard 1')

    def test_include_change_and_added_file_detected(self):
        self.shell('''mkdir "$ROOT/inc"
printf '!includedir %s/inc\n' "$ROOT" > "$ROOT/my.cnf"
printf '[mysqld]\nport=3307\n' > "$ROOT/inc/a.cnf"
cnf_chain_snapshot "$ROOT/my.cnf" "$RUN/before" "$ROOT"
printf '[mysqld]\nport=3308\n' > "$ROOT/inc/b.cnf"
cnf_chain_snapshot "$ROOT/my.cnf" "$RUN/after" "$ROOT"
! cmp -s "$RUN/before" "$RUN/after"
''')

    def test_relative_include_uses_process_cwd(self):
        self.shell('''mkdir "$ROOT/config"
printf '!include child.cnf\n' > "$ROOT/config/my.cnf"
printf '[mysqld]\nport=3307\n' > "$ROOT/child.cnf"
cnf_chain_snapshot "$ROOT/config/my.cnf" "$RUN/snapshot" "$ROOT"
grep -F "$ROOT/child.cnf" "$RUN/snapshot"
''')

    def test_include_cycle_stops(self):
        self.shell('printf "!include %s/my.cnf\\n" "$ROOT" > "$ROOT/my.cnf"; cnf_chain_snapshot "$ROOT/my.cnf" "$RUN/snapshot" "$ROOT"', 'include cycle')

    def test_missing_include_stops(self):
        self.shell('printf "!include %s/missing.cnf\\n" "$ROOT" > "$ROOT/my.cnf"; cnf_chain_snapshot "$ROOT/my.cnf" "$RUN/snapshot" "$ROOT"', 'Unreadable configuration include')

    def test_persist_snapshot_precedes_write_and_keeps_first_value(self):
        self.shell('''hasvar() { return 0; }
sql() {
 case "$2" in
  SELECT*) printf 'SET GLOBAL example=1;\nRESET PERSIST IF EXISTS example;\n';;
  'SET PERSIST '*) [ -s "$RUN/cutover_rollback/1.persist/example.sql" ]; printf '%s\n' "$2" >> "$RUN/writes";;
 esac
}
persist 1 example 2
persist 1 example 3
[ "$(wc -l < "$RUN/cutover_rollback/1.persist/order")" = 1 ]
grep -Fx 'SET GLOBAL example=1;' "$RUN/cutover_rollback/1.persist/example.sql"
''')

    def test_incomplete_persist_snapshot_stops_before_write(self):
        self.shell('hasvar() { return 0; }; sql() { printf "only one line\\n"; }; persist 1 example 2', 'Incomplete persisted-variable rollback snapshot')

    def test_existing_recovery_channel_not_overwritten(self):
        self.shell('put meta count 1; sql() { printf 1; }; cutover_snapshot', 'existing recovery channel metadata')

    def test_existing_null_plugin_setting_stops_before_mutation(self):
        self.shell('sql() { printf 1; }; persist_snapshot 1 group_replication_group_name', 'cannot be restored dynamically')

    def test_new_plugin_null_setting_uses_plugin_rollback(self):
        self.shell('''mkdir -p "$RUN/cutover_rollback"
: > "$RUN/cutover_rollback/1.new_gr_plugin"
sql() { case "$2" in *'IS NULL;'*) printf 1;; *) printf 'SELECT 1;\nRESET PERSIST IF EXISTS group_replication_group_name;\n';; esac; }
persist_snapshot 1 group_replication_group_name
! grep -q '=NULL' "$RUN/cutover_rollback/1.persist/group_replication_group_name.sql"
''')

    def test_failed_channel_creation_is_not_reset(self):
        self.shell('''put meta count 1
mkdir -p "$RUN/cutover_rollback"
: > "$RUN/cutover_rollback/1.new_recovery_channel"
sql() { case "$2" in *'SELECT COUNT(*)'*) printf 0;; *) printf '%s\n' "$2" >> "$RUN/actions";; esac; }
rollback_cutover
! grep -q 'RESET REPLICA' "$RUN/actions"
''')

    def test_recovery_password_length_before_account_creation(self):
        self.shell('''put meta count 1
required() { case $1 in 'Recovery accounts '*) printf create;; 'Dedicated recovery user') printf recovery;; *) printf localhost;; esac; }
secret() { printf 123456789012345678901234567890123; }
sql() { :; }
accounts
''', '32 bytes')

    def test_rollback_only_new_channel_and_accounts(self):
        self.shell('''put meta count 1
mkdir -p "$RUN/cutover_rollback/1.persist"
printf example > "$RUN/cutover_rollback/1.persist/order"
printf 'SET GLOBAL example=1;\nRESET PERSIST IF EXISTS example;\n' > "$RUN/cutover_rollback/1.persist/example.sql"
printf 'DROP USER IF EXISTS recovery;\n' > "$RUN/cutover_rollback/1.accounts.sql"
: > "$RUN/cutover_rollback/1.new_recovery_channel"
sql() { case "$2" in *"SELECT COUNT(*)"*) printf 1;; *) printf '%s\n' "$2" >> "$RUN/actions";; esac; }
local_write() { sql "$1" "$2"; }
rollback_cutover
grep -F "RESET REPLICA ALL FOR CHANNEL 'group_replication_recovery'" "$RUN/actions"
grep -F 'DROP USER IF EXISTS recovery' "$RUN/actions"
grep -F 'SET GLOBAL example=1' "$RUN/actions"
! grep -E 'RESET MASTER|RESET BINARY' "$RUN/actions"
''')

    def test_xa_generated_when_available(self):
        self.shell('put 1 advertise localhost; put 1 sql_port 3307; val() { printf 1; }; hasvar() { [ "$2" = xa_detach_on_prepare ]; }; config_lines 1 2 > "$RUN/cnf"; grep -Fx xa_detach_on_prepare=ON "$RUN/cnf"')

    ACCOUNT_FIXTURE = r'''
mkdir "$RUN/export"
hasvar() { return 1; }
sql() {
 case "$2" in
  *'LEFT JOIN'*) printf "'role1'@'%%'\n'root'@'localhost'\n";;
  *'CURRENT_USER()'*) printf "'root'@'localhost'\n";;
  'SHOW CREATE USER '*) printf "account\tCREATE USER %s IDENTIFIED WITH 'caching_sha2_password' AS 'hash' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT UNLOCK\n" "${2#SHOW CREATE USER }" | sed 's/; IDENTIFIED/ IDENTIFIED/' ;;
  'SHOW GRANTS '*) [ "${FAIL_GRANTS:-no}" != yes ] || return 1; printf "GRANT SELECT ON db.* TO 'root'@'localhost'\n";;
  *'mysql.default_roles'*) printf "'root'\t'localhost'\t'role1'\t'%%'\n";;
  *) return 1;;
 esac
}
'''

    def test_account_create_alter_and_deferred_grants(self):
        self.shell(self.ACCOUNT_FIXTURE + r'''
export_source_accounts "$RUN/export" >/dev/null
! grep -q 'DROP USER' "$RUN/export/source_accounts.sql"
grep -q 'CREATE USER IF NOT EXISTS' "$RUN/export/source_accounts.sql"
grep -q 'ALTER USER' "$RUN/export/source_accounts.sql"
! grep -q '^GRANT\|^SET DEFAULT ROLE' "$RUN/export/source_accounts.sql"
grep -q '^GRANT' "$RUN/export/source_grants.sql"
grep -q '^SET DEFAULT ROLE' "$RUN/export/source_grants.sql"
(cd "$RUN/export"; sha256sum -c source_accounts.sql.sha256)
''')

    def test_account_grant_export_failure_stops(self):
        self.shell(self.ACCOUNT_FIXTURE + 'FAIL_GRANTS=yes; export_source_accounts "$RUN/export"', 'SHOW GRANTS failed')

    TLS_FIXTURE = r'''
put meta count 1; put meta tls VERIFY_IDENTITY
put 1 location local; put 1 advertise localhost
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost -keyout "$ROOT/key.pem" -out "$ROOT/cert.pem" >/dev/null 2>&1
put 1 recovery_ca "$ROOT/cert.pem"
val() { case "$2" in ssl_ca|ssl_cert) printf '%s' "$ROOT/cert.pem";; ssl_key) printf '%s' "$ROOT/key.pem";; datadir) printf '%s' "$ROOT";; esac; }
'''

    def test_tls_trusted_san_passes(self):
        self.shell(self.TLS_FIXTURE + 'tls_preflight')

    def test_tls_wrong_san_stops(self):
        self.shell(self.TLS_FIXTURE + 'put 1 advertise otherhost; tls_preflight', 'TLS certificate/identity')

    def test_tls_untrusted_ca_stops(self):
        self.shell(self.TLS_FIXTURE + r'''
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=other -keyout "$ROOT/other.key" -out "$ROOT/other.pem" >/dev/null 2>&1
put 1 recovery_ca "$ROOT/other.pem"
tls_preflight
''', 'TLS certificate/identity')

if __name__ == '__main__':
    unittest.main(verbosity=2)
