# AMXO-P3-3 independent host revocation enforcement proof

**Evidence captured:** 2026-09-13T17:40:00+01:00
**Task:** AMXO-P3-3 (Implement independent host revocation enforcement in fe-signalloom)
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`

## Prompt-to-artifact checklist

| Required outcome | Artifact | Positive evidence |
| :--- | :--- | :--- |
| Database migration for revocation attribution | `041_external_host_revocation.sql` | `revoked_by_user_id`, `revoked_by_subject`, `revoked_by_issuer`, FK to `platform_users`, composite indexes |
| Host revocation endpoints | `external_agent_registration.py` | `POST /v1/external-agents/{agent_id}/revocations`, `POST /api/v1/external-agents/registrations/{agent_id}/revoke`, `POST /v1/external-agents/hosts/{host_id}/revoke` |
| Real-time upload revocation check | `external_agent_registration.py` | `is_external_agent_revoked`, `upload_external_agent_evidence_handler` returns 403 Forbidden with `host_revoked` |
| Ingestion middleware revocation check | `audit_ingest.py` | `ingest_signed_audit_session` and `verify_audit_session_probe` verify revocation status and reject revoked hosts |
| Operator account isolation | `test_host_revocation.py` | `test_host_revocation_does_not_affect_operator_account` asserts operator remains authenticated and authorized |
| Sibling host isolation | `test_host_revocation.py` | `test_host_revocation_does_not_affect_sibling_hosts` asserts sibling agents continue normal operation |
| Post-revocation denial assertions | `test_host_revocation.py` | `test_post_revocation_denial_of_evidence_upload`, `test_post_revocation_denial_of_audit_ingestion`, `test_post_revocation_denial_of_re_enrollment` |
| Spine delegation clamping & audit | `external_agent_registration.py` | `clamp_claim_delegation_in_spine`, `external_agent.revoked` audit event emitted with operator attribution |
| Contract schema conformance | `external-agent-server.v1.schema.json` | 202 Accepted `RevocationResult` schema validation passed in `contract-conformance.bats` |
| Automated test coverage | `test_host_revocation.py` | 8 dedicated pytest test cases passed, contract tests passed, full 1394-test suite passed |

## Required commands

```bash
pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_revocation.py
make demo-agentmaxxing-contract-test
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_post_revocation_denial
test -f docs/signalloom/amxo-p3-3-evidence.md
```

## Scope and safety gates

```text
WORKTREE=/home/andy/src/.worktrees/cbeba/osramp-demo
BASE_REF_GATE=PASS
```

No remote repositories were touched, no branches pushed, and no sibling worktrees modified.
