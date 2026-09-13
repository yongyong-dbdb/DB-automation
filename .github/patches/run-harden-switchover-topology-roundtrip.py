from pathlib import Path
helper = Path('.github/patches/harden-switchover-topology-roundtrip.py')
s = helper.read_text()
old = "    # primary_conninfo may intentionally omit application_name.\n'''"
new = "    # primary_conninfo may intentionally omit application_name. PostgreSQL's\n'''"
if old not in s:
    raise SystemExit('round-trip helper marker not found')
s = s.replace(old, new, 1)
exec(compile(s, str(helper), 'exec'))
