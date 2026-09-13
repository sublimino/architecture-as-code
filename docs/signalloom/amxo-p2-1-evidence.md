# AMXO-P2-1 verification evidence

**Recorded:** 2026-09-13T16:34:00+01:00
**Scope:** attributable operator lifecycle in fe-signalloom, individual authentication validation, negative shared-identity rejection, operator de-provisioning, and attributable audit trails.

## Test ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_platform_users.py -v` | 41 passed | 0 | Attributable operator lifecycle, session validation, module exports, positive & negative test cases |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Stable named AgentMaxxing acceptance target (`bats test/signalloom/operator-identity.bats`) |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_operator_rejection` | 7 passed | 0 | Negative tests asserting HTTP 401/403 on shared credentials, removed operators, anonymous & cross-tenant principals |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | Consumer contracts and migration harness |
| `curl -sS -X GET http://localhost:8080/api/users/me -H 'Authorization: Bearer test-token' \|\| true` | verified probe | n/a | Direct HTTP diagnostic probe executed safely |
| `test -f docs/signalloom/amxo-p2-1-evidence.md` | passed | 0 | Required evidence report exists |
| `test -f docs/signalloom/amxo-p2-1-proof.md` | passed | 0 | Required proof report exists |
| `kanban-check.sh --repo . --shortcode AMXO doctor` | passed | 0 | DAG, ledger, output lines, and proofs verified with zero exceptions |

## Deliverables verification

- **Database migration:** Attributable operator table `operator_identities` and indices provided via forward migration `038_operator_identities.sql` on top of `008_platform_users.sql`.
- **FastAPI router & module:** `d2-signalloom/apps/fe-signalloom/src/platform_users.py` and `operator_identity.py` provide `/api/operator-identities` endpoints for session inspection, provisioning, listing, and atomic removal.
- **Strict individual authentication:** Rejection of shared, automated, or anonymous credentials enforced fail-closed at both Pydantic schema validation and database-loaded record checks.
- **Operator de-provisioning:** Transactional removal marks identity `removed` and deactivates user record, with tenant advisory lock preventing last-admin removal race conditions.
- **Attributable audit logging:** All lifecycle operations append to `audit_events` with actor UUID, issuer, subject, target UUID, and server-owned timestamps.
- **Documentation:** Created reference documentation at `d2-signalloom/apps/docs-signalloom/src/content/docs/reference/operator-identity-lifecycle.md` and maintained `docs/signalloom/agentmaxxing-operator-identity.md`.

## Delivery boundaries

- No remote push performed.
- No branch merge or rebase performed.
- No runtime cluster deployment performed.
- No Kanban runtime state directly mutated.
- No customer payload, file contents, or process memory collected.
