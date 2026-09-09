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
run('GTID timeout stops migration','sql() { printf 1; }; catchup 2 abc',1)
run('errant GTID stops migration','sql() { case "$2" in *WAIT*) printf 0;; *) printf extra;; esac; }; catchup 2 abc',1)
run('GTID matched passes','sql() { case "$2" in *WAIT*) printf 0;; *) :;; esac; }; catchup 2 abc')
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
report=['# Validation v1.0.0','',f'Total: {len(results)}; passed: {sum(x[1] for x in results)}','', 'These are shell/mocked SQL regression tests. No live MySQL server was available.','']
for name,ok,rc,output in results: report.append(f'- {"PASS" if ok else "FAIL"}: {name}')
(script.parent / 'VALIDATION.md').write_text('\n'.join(report)+'\n')
if not all(x[1] for x in results): raise SystemExit(1)
