# Validation v1.0.2

Total: 44; passed: 44

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
- PASS: SSH quoting preserves literal metacharacters
- PASS: legacy GTID state matches endpoint without sourcing
- PASS: legacy socket maps instance rather than node order
- PASS: manual helper has no controller password and is valid sh
- PASS: remote identity rejects wrong socket UUID before writes
- PASS: unknown remote launcher blocks automatic restart
- PASS: remote cnf path mismatch blocks editing
- PASS: remote plan leaves original unchanged
- PASS: remote apply preserves content permissions and exact backup
- PASS: validation failure never modifies remote cnf
- PASS: remote concurrent edit blocks stale replacement
- PASS: remote config lock collision preserves other lock
- PASS: manual user refusal leaves current cnf unchanged
- PASS: manual approval merges current cnf and makes backup
- PASS: SSH transport uses selected port and host-key verification
- PASS: remote runtime settings match generated configuration
- PASS: remote runtime override is detected
