# AMXO-P2-2 tenant-bound external agent registration proof

**Evidence captured:** 2026-09-13T16:45:00+01:00
**Task:** AMXO-P2-2 (Implement tenant-bound external agent registration and duplicate claim rejection in fe-signalloom)
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`

## Prompt-to-artifact checklist

| Required outcome | Artifact | Positive evidence |
| :--- | :--- | :--- |
| External Linux agent record extension | `agent_claim.py` | `ExternalAgentRecord`, `is_external_linux_agent`, `build_external_agent_containment_claims` |
| Database migration for registration metadata | `039_external_agent_registrations.sql` | `host_id`, `host_os`, `runtime_profile`, `enrollment_status`, `allocated_token_budget`, `metadata` |
| Tenant-bound registration endpoints | `external_agent_registration.py` | `/api/v1/external-agents/register`, `/registrations`, `/registrations/{agent_id}` |
| Strict server-side tenant scoping | `external_agent_registration.py` | Derived exclusively from `principal.tenant`; authenticated credentials required |
| Atomic duplicate-claim rejection | `external_agent_registration.py` | Returns 409 Conflict (`duplicate_claim`) if agent already has active granted claim |
| Global agent uniqueness & isolation | `external_agent_registration.py` | Returns 409 Conflict (`claim_conflict`) on cross-tenant claims without leaking tenant names |
| Mandatory pre-registration check | `external_agent_registration.py` | Returns 403 Forbidden (`unregistered_agent`) if external agent is not pre-registered |
| Revocation and claim cleanup | `external_agent_registration.py` | Status transitioned to `revoked` and active claims released atomically |
| Audit event vocabulary and logging | Migration 039 & `_audit_log_external_agent` | `external_agent.registered`, `external_agent.claimed`, `external_agent.claim_rejected`, `external_agent.revoked` |
| Automated test coverage | `test_agent_claim.py`, `test_external_agent_registration.py` | 25 pytest test cases passed, contract tests passed, zero failures |

## Required commands

```bash
pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_registration.py -v
make demo-agentmaxxing-contract-test
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_duplicate_claim
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_cross_tenant
test -f docs/signalloom/amxo-p2-2-evidence.md
```

## Scope and safety gates

```text
WORKTREE=/home/andy/src/.worktrees/6ca5a/osramp-demo
BASE_REF_GATE=PASS
```

No remote repositories were touched, no branches pushed, and no sibling worktrees modified.
