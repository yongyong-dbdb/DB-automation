from pathlib import Path
p=Path('PostgreSQL/postgresql_role_switch_v0.1.22.sh')
s=p.read_text()
old='''    while IFS='|' read -r urp_transport urp_target urp_pgdata urp_app urp_client urp_user urp_old_slot urp_nested_count urp_relations; do
'''
new='''    # Read plan metadata from fd 3 so interactive ask()/choose_yes_no() keep stdin on the operator terminal.
    while IFS='|' read -r urp_transport urp_target urp_pgdata urp_app urp_client urp_user urp_old_slot urp_nested_count urp_relations <&3; do
'''
if old not in s:
    raise SystemExit('reparent candidate loop marker not found')
s=s.replace(old,new,1)
old='''    done < "$UNSELECTED_REPARENT_CANDIDATES"
    record_check "PASSED" "Unselected Standby Placement" "operator chose to reparent all unselected Direct Standbys to the New Primary"
'''
new='''    done 3< "$UNSELECTED_REPARENT_CANDIDATES"
    record_check "PASSED" "Unselected Standby Placement" "operator chose to reparent all unselected Direct Standbys to the New Primary"
'''
if old not in s:
    raise SystemExit('reparent candidate loop redirect marker not found')
s=s.replace(old,new,1)
p.write_text(s)
