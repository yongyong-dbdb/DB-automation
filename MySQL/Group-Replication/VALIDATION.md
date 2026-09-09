# Validation v1.0.1

Total: 27; passed: 27

These are shell/mocked SQL regression tests. No live MySQL server was available.

- PASS: version supported matrix
- PASS: reject unsupported and too-old
- PASS: port range validation
- PASS: quote values
- PASS: GR settings single
- PASS: GR settings multi
- PASS: 8.4 config excludes removed vars, preserves log filename
- PASS: 8.0 config includes available vars
- PASS: same host separate dynamic ports
- PASS: same host duplicate XCom blocks
- PASS: cross-instance SQL/XCom conflict blocks
- PASS: GTID timeout stops migration
- PASS: errant GTID stops migration
- PASS: GTID matched passes
- PASS: existing group blocks rebootstrap
- PASS: bootstrap attempt marker blocks retry
- PASS: schema rejection
- PASS: multi SERIALIZABLE rejection
- PASS: multi cascading FK rejection
- PASS: local write failure refences and propagates
- PASS: local write success removes marker
- PASS: cleanup disables bootstrap, refences, deletes secrets
- PASS: partial registration archived before retry
- PASS: completed registration preserved
- PASS: migration marker prevents re-registration
- PASS: legacy node write-fence marker preserved
- PASS: registration-only failure message
