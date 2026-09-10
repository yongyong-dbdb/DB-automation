import os, subprocess, tempfile
from pathlib import Path
script=Path(__file__).resolve().parent / 'mysql_gr_migrate.sh'
results=[]
def run(name,body,want=0):
    with tempfile.TemporaryDirectory() as d:
        env=os.environ.copy();env.update(MYSQL_GR_LIB_ONLY='1',MYSQL_GR_WORK_ROOT=d)
        header=f'. "{script}"\nTEMP="$ROOT/temp"; RUN="$ROOT/run"; mkdir -p "$TEMP" "$RUN" "$ROOT/meta" "$ROOT/1" "$ROOT/2"\n'
        r=subprocess.run(['sh','-c',header+body],env=env,text=True,capture_output=True)
        ok=(r.returncode==0) if want==0 else r.returncode!=0
        results.append((name,ok,r.returncode,r.stdout+r.stderr))
        print(('PASS' if ok else 'FAIL'), name)
        if not ok: print(r.stdout,r.stderr)
run('version supported matrix', 'for v in 8.0.27 8.0.45 8.4.11 9.7.2; do version_guard "$v" || exit 1; done')
run('reject unsupported and too-old', 'for v in 5.7.44 8.0.26 9.8.0 10.11-MariaDB; do if version_guard "$v"; then exit 1; fi; done')
run('port range validation','port_ok 43127; if port_ok 0 || port_ok 65536 || port_ok abc; then exit 1; fi')
run('quote values','[ "$(q "a\047b\\c")" != "" ]; [ "$(optq \'a"b\\c\')" = \'a\\"b\\\\c\' ]')
for mode in ('single','multi'):
    on,checks=('ON','OFF') if mode=='single' else ('OFF','ON')
    run('GR settings '+mode,f'''put meta count 2; put meta primary_mode {mode}; put meta group aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
put meta allowlist 127.0.0.1; put meta tls REQUIRED
put 1 xcom localhost:43001; put 2 xcom localhost:43002; put 1 recovery_ca /data/ca.pem
plugin() {{ :; }}; hasvar() {{ return 0; }}
persist() {{ printf '%s=%s\\n' "$2" "$3" >> "$RUN/settings"; }}
group_settings 1
grep -Fx 'group_replication_single_primary_mode={on}' "$RUN/settings"
grep -Fx 'group_replication_enforce_update_everywhere_checks={checks}' "$RUN/settings"
grep -Fx 'group_replication_group_seeds=localhost:43001,localhost:43002' "$RUN/settings"
grep -Fx 'group_replication_bootstrap_group=OFF' "$RUN/settings"
''')
run('8.4 config excludes removed vars, preserves log filename','''
val() { printf 1; }; hasvar() { return 1; }
put 1 advertise localhost; put 1 sql_port 43801
config_lines 1 42 > "$RUN/config"
! grep -E 'transaction_write_set_extraction|master_info_repository|relay_log_info_repository|^log_bin' "$RUN/config"
grep -Fx 'skip_replica_start=ON' "$RUN/config"
grep -Fx 'report_port=43801' "$RUN/config"
''')
run('8.0 config includes available vars','''
val() { printf 1; }; hasvar() { return 0; }
put 1 advertise localhost; put 1 sql_port 43801
config_lines 1 42 > "$RUN/config"
grep -Fx 'transaction_write_set_extraction=XXHASH64' "$RUN/config"
grep -Fx 'master_info_repository=TABLE' "$RUN/config"
''')
base='''put meta count 2
for i in 1 2; do put "$i" location local; put "$i" advertise localhost; done
put 1 sql_port 43801; put 2 sql_port 43802
hasvar() { return 1; }
'''
run('same host separate dynamic ports',base+'put 1 xcom localhost:43901; put 2 xcom localhost:43902; endpoints_check')
run('same host duplicate XCom blocks',base+'put 1 xcom localhost:43901; put 2 xcom localhost:43901; endpoints_check',1)
run('cross-instance SQL/XCom conflict blocks',base+'put 1 xcom localhost:43802; put 2 xcom localhost:43901; endpoints_check',1)
gtid_base = """put 1 uuid source; put 2 uuid replica
val() { :; }
"""
run('GTID timeout stops migration',gtid_base+'''sql() { case "$2" in *WAIT*) printf 1;; *"GTID_SUBTRACT('"*) printf missing;; *) :;; esac; }; catchup 2 abc''',1)
run('errant GTID stops migration',gtid_base+'''sql() { case "$2" in *"GTID_SUBTRACT(@@GLOBAL.gtid_executed,'"*) printf extra;; *) :;; esac; }; catchup 2 abc''',1)
run('GTID matched passes',gtid_base+'''sql() { :; }; catchup 2 abc''')
run('existing group blocks rebootstrap','put meta count 2; sql() { printf 1; }; no_group',1)
run('bootstrap attempt marker blocks retry','put meta initialized yes; put meta bootstrap_attempted yes; cutover',1)
run('schema rejection','put meta primary_mode single; sql() { printf "db.bad engine=MyISAM"; }; schema_check 1',1)
run('multi SERIALIZABLE rejection','put meta primary_mode multi; sql() { :; }; val() { printf SERIALIZABLE; }; schema_check 1',1)
run('multi cascading FK rejection','put meta primary_mode multi; sql() { case "$2" in *referential_constraints*) printf db.fk;; esac; }; val() { printf REPEATABLE-READ; }; schema_check 1',1)
run('local write failure refences and propagates','''
sql() { printf '%s\\n' "$2" >> "$RUN/actions"; case "$2" in *CREATE*) return 1;; esac; }
(local_write 1 'CREATE USER x;' secret) && exit 1
grep -Fx 'SET GLOBAL super_read_only=ON;' "$RUN/actions"
[ -f "$TEMP/unfenced/1" ]
''')
run('local write success removes marker','sql() { :; }; local_write 1 "INSTALL PLUGIN x;"; [ ! -f "$TEMP/unfenced/1" ]')
# trap test: run actual cleanup and inspect persistent evidence after child exits
with tempfile.TemporaryDirectory() as d:
    body=f'''MYSQL_GR_LIB_ONLY=1; . "{script}"
ROOT="{d}"; TEMP="$ROOT/temp"; mkdir -p "$TEMP/unfenced"; touch "$TEMP/unfenced/2"
BOOT_NODE=1
sql() {{ printf '%s %s\\n' "$1" "$2" >> "$ROOT/actions"; }}
trap cleanup 0
exit 9
'''
    r=subprocess.run(['sh','-c',body],capture_output=True,text=True)
    a=Path(d,'actions').read_text();ok=r.returncode==9 and 'bootstrap_group=OFF' in a and '2 SET GLOBAL super_read_only=ON;' in a and not Path(d,'temp').exists()
    results.append(('cleanup disables bootstrap, refences, deletes secrets',ok,r.returncode,a));print('PASS' if ok else 'FAIL',results[-1][0])
run('partial registration archived before retry', '''
put meta count 3; put 1 uuid preserved; mkdir -p "$ROOT/runs"; printf keep > "$ROOT/runs/evidence"
prepare_discovery
[ ! -e "$ROOT/meta" ]; [ ! -e "$ROOT/1" ]
[ "$(cat "$ROOT"/discovery_backups/*/meta/count)" = 3 ]
[ "$(cat "$ROOT"/discovery_backups/*/1/uuid)" = preserved ]
[ "$(cat "$ROOT/runs/evidence")" = keep ]
''')
run('completed registration preserved', '''
put meta complete yes
(prepare_discovery) && exit 1
[ "$(get meta complete)" = yes ]; [ ! -e "$ROOT/discovery_backups" ]
''')
run('migration marker prevents re-registration', '''
put meta initialized yes
(prepare_discovery) && exit 1
[ "$(get meta initialized)" = yes ]; [ ! -e "$ROOT/discovery_backups" ]
''')
run('legacy node write-fence marker preserved', '''
put 2 before_read_only 0
(prepare_discovery) && exit 1
[ "$(get 2 before_read_only)" = 0 ]; [ ! -e "$ROOT/discovery_backups" ]
''')
run('registration-only failure message', '''
( PHASE=discover; trap cleanup 0; exit 7 ) 2> "$RUN/cleanup.log" && exit 1
grep -F 'did not change databases' "$RUN/cleanup.log"
! grep -F 'Write fences' "$RUN/cleanup.log"
''')

run('SSH quoting preserves literal metacharacters', r"""
value="a'b \$(touch SHOULD_NOT_EXIST) \`id\` \\ space"
quoted=$(shell_quote "$value")
actual=$(printf 'v=%s\nprintf "%%s" "$v"\n' "$quoted" | sh)
[ "$actual" = "$value" ]; [ ! -e SHOULD_NOT_EXIST ]
""")
run('legacy GTID state matches endpoint without sourcing', r"""
put 1 mode tcp; put 1 host dbhost; put 1 port 45873
MYSQL_GR_GTID_STATE_FILE="$ROOT/legacy.state"
cat > "$MYSQL_GR_GTID_STATE_FILE" <<'STATE'
SOURCE_MODE='tcp'
SOURCE_HOST='dbhost'
SOURCE_PORT='45873'
SOURCE_CNF='/etc/my_custom.cnf'
touch SHOULD_NOT_EXIST
STATE
[ "$(legacy_cnf_candidate 1)" = /etc/my_custom.cnf ]
[ ! -e SHOULD_NOT_EXIST ]
put 1 port 45874
[ -z "$(legacy_cnf_candidate 1)" ]
""")
run('legacy socket maps instance rather than node order', r"""
MYSQL_GR_GTID_STATE_FILE="$ROOT/legacy.state"
printf "REPLICA_MODE='socket'\nREPLICA_SOCKET='/data/custom.sock'\nREPLICA_CNF='/etc/custom2.cnf'\n" > "$MYSQL_GR_GTID_STATE_FILE"
val() { printf /data/custom.sock; }
[ "$(legacy_cnf_candidate 1)" = /etc/custom2.cnf ]
""")
run('manual helper has no controller password and is valid sh', r"""
put 1 user admin; put 1 uuid uuid-one; put 1 cnf /etc/my_custom.cnf
val() { case $2 in datadir) printf /data/;; socket) printf /data/custom.sock;; pid_file) printf /data/custom.pid;; basedir) printf /usr;; esac; }
ask() { printf no; }
printf '[mysqld]\nserver_id=72\n' > "$RUN/snippet"
printf 'password="CONTROLLER_SECRET"\n' > "$TEMP/1.cnf"
configure_manual 1 "$RUN/snippet"
sh -n "$RUN/node_1_apply_config.sh"
! grep -F CONTROLLER_SECRET "$RUN/node_1_apply_config.sh"
grep -F "ACTION='manual'" "$RUN/node_1_apply_config.sh"
grep -F 'Current cnf merged with proposed settings' "$RUN/node_1_apply_config.sh"
""")
agent = r"""
remote_agent > "$TEMP/agent.sh"
sed '$d' "$TEMP/agent.sh" > "$TEMP/functions.sh"
. "$TEMP/functions.sh"
"""
run('remote identity rejects wrong socket UUID before writes', agent+r"""
EXPECTED_UUID=expected; EXPECTED_DATA=/data/; EXPECTED_SOCKET=/sock; EXPECTED_PID_FILE=/pid
r_sql() { printf 'wrong|/data/|/sock|/pid'; }
r_identity
""", 1)
run('unknown remote launcher blocks automatic restart', agent+r"""
RMETHOD=unknown
r_restart_guard
""", 1)
run('remote cnf path mismatch blocks editing', agent+r"""
CNF="$ROOT/actual.cnf"; RDEFAULT="$ROOT/other.cnf"
printf '[mysqld]\n' > "$CNF"; cp "$CNF" "$RDEFAULT"
r_config_guard
""", 1)
fixture = agent+r"""
CNF="$ROOT/current.cnf"; BASEDIR="$ROOT"; EXPECTED_SOCKET=/unused
mkdir -p "$ROOT/bin"; ln -s /bin/true "$ROOT/bin/mysql"
CLIENT_AUTH='user=fixture'; EXPECTED_UUID=testuuid; VERSION=1.0.2
SNIPPET='[mysqld]
server_id=72'
DO_RESTART=no
printf '[mysqld]\nport=45873\nlog_bin=/keep/binlog\n' > "$CNF"
chmod 640 "$CNF"
r_identity() {
    RDEFAULT=$CNF; RPID=$$; REXE=/not-executed; RMETHOD=direct; RSERVICE=''; RCWD=$ROOT
    printf '%s\n' "$CNF" > "$RTMP/candidates"
    printf '/not-executed\n--defaults-file=%s\n' "$CNF" > "$RTMP/argv"
}
r_same_process() { :; }
r_validate_candidate() { printf validated > "$VALIDATE_LOG"; }
"""
run('remote plan leaves original unchanged',fixture+r"""
ACTION=plan
(r_main)
grep -Fx 'port=45873' "$CNF"
! grep -F server_id "$CNF"
[ "$(stat -c %a "$CNF")" = 640 ]
[ ! -d "$CNF.gr_lock" ]
""")
run('remote apply preserves content permissions and exact backup',fixture+r"""
ACTION=apply
cp "$CNF" "$ROOT/before"
(r_main)
grep -Fx 'port=45873' "$CNF"
grep -Fx 'log_bin=/keep/binlog' "$CNF"
grep -Fx 'server_id=72' "$CNF"
[ "$(stat -c %a "$CNF")" = 640 ]
cmp "$ROOT/before" "$CNF".before_gr_*
[ ! -d "$CNF.gr_lock" ]
""")
run('validation failure never modifies remote cnf',fixture+r"""
ACTION=apply
cp "$CNF" "$ROOT/before"
r_validate_candidate() { r_die 'simulated validation failure'; }
(r_main) && exit 1
cmp "$CNF" "$ROOT/before"
[ ! -d "$CNF.gr_lock" ]
""")
run('remote concurrent edit blocks stale replacement',fixture+r"""
ACTION=apply
r_validate_candidate() { printf 'external-edit\n' >> "$CNF"; }
(r_main) && exit 1
grep -Fx external-edit "$CNF"
! grep -F server_id "$CNF"
""")
run('remote config lock collision preserves other lock',fixture+r"""
ACTION=apply
mkdir "$CNF.gr_lock"
(r_main) && exit 1
[ -d "$CNF.gr_lock" ]
! grep -F server_id "$CNF"
""")
run('remote changed include blocks config replacement',fixture+r"""
ACTION=apply
printf '!include %s/child.cnf\n' "$ROOT" >> "$CNF"
printf '[mysqld]\nport=45873\n' > "$ROOT/child.cnf"
cp "$CNF" "$ROOT/before"
r_validate_candidate() { printf '# concurrent included-file edit\n' >> "$ROOT/child.cnf"; }
(r_main) && exit 1
cmp "$CNF" "$ROOT/before"
! grep -F server_id "$CNF"
""")
run('manual user refusal leaves current cnf unchanged',fixture+r"""
ACTION=manual
cp "$CNF" "$ROOT/before"
printf '\nNO\n' | (r_main)
cmp "$CNF" "$ROOT/before"
""")
run('manual approval merges current cnf and makes backup',fixture+r"""
ACTION=manual
printf '\nAPPLY\nno\n' | (r_main)
grep -Fx 'port=45873' "$CNF"
grep -Fx 'server_id=72' "$CNF"
[ ! -d "$CNF.gr_lock" ]
""")

run('SSH transport uses selected port and host-key verification', r"""
put 1 ssh_port 45999; put 1 ssh_user mysqlops; put 1 ssh_key ''; put 1 ssh_privilege sudo; put 1 ssh_host dbhost
ssh() { printf '%s\n' "$@" > "$RUN/ssh_args"; cat > "$RUN/ssh_stdin"; }
printf 'payload\n' | ssh_transport 1
grep -Fx 45999 "$RUN/ssh_args"
grep -Fx StrictHostKeyChecking=ask "$RUN/ssh_args"
grep -Fx 'sudo -n sh -s' "$RUN/ssh_args"
grep -Fx payload "$RUN/ssh_stdin"
""")
run('remote runtime settings match generated configuration',agent+r"""
RTMP="$TEMP/runtime"; mkdir -p "$RTMP"
SNIPPET='[mysqld]
server_id=72
log_bin'
r_sql() { case $1 in *server_id*) printf 72;; *log_bin*) printf 1;; esac; }
r_runtime_check
""")
run('remote runtime override is detected',agent+r"""
RTMP="$TEMP/runtime"; mkdir -p "$RTMP"
SNIPPET='[mysqld]
server_id=72'
r_sql() { printf 73; }
r_runtime_check
""", 1)
report=['# Shell/mocked SQL regression results','',f'Total: {len(results)}; passed: {sum(x[1] for x in results)}','', 'These results cover mocked regressions only; live validation is documented separately in VALIDATION.md.','']
for name,ok,rc,output in results: report.append(f'- {"PASS" if ok else "FAIL"}: {name}')
if os.environ.get('MYSQL_GR_TEST_REPORT'):
    Path(os.environ['MYSQL_GR_TEST_REPORT']).write_text('\n'.join(report)+'\n')
if not all(x[1] for x in results): raise SystemExit(1)
