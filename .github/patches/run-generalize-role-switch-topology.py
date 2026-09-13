from pathlib import Path
helper = Path('.github/patches/generalize-role-switch-topology.py')
s = helper.read_text()
old = """old='''    if ! verify_preserved_topology_snapshot \"Unselected Standby cascading downstream\" \"${UNSELECTED_TOPOLOGY_SNAPSHOT:-}\"; then
        die \"One or more preserved Unselected Standby cascading relationships changed during Switchover. The role reversal remains active; inspect the affected downstream chain.\"
    fi
    CURRENT_PHASE=\"topology_verified\"
    record_check \"PASSED\" \"Cascading Topology Preservation\" \"pre-Switchover downstream relationships and nested downstream counts remained streaming after role reversal\"
'''
"""
new = """old='''    if ! verify_preserved_topology_snapshot \"Unselected Standby cascading downstream\" \"${UNSELECTED_TOPOLOGY_SNAPSHOT:-}\"; then
        die \"Post-Switchover validation failed: one or more cascading relationships below an Unselected Standby were not preserved.\"
    fi
    CURRENT_PHASE=\"topology_verified\"
    record_check \"PASSED\" \"Preserved Cascading Topology\" \"selected-candidate downstreams and unselected-standby nested downstream counts remain streaming after role reversal\"
'''
"""
if old not in s:
    raise SystemExit('outdated topology post-check marker not found in helper')
s = s.replace(old, new, 1)
exec(compile(s, str(helper), 'exec'))
