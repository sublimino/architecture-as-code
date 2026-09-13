# AMXO-P3-1 atomic one-time host enrollment token exchange proof

**Evidence captured:** 2026-09-13T17:31:00+01:00  
**Task:** AMXO-P3-1 (Implement atomic one-time external host enrollment token exchange in fe-signalloom)  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  

## Prompt-to-artifact checklist

| Required outcome | Artifact | Positive evidence |
| :--- | :--- | :--- |
| Host enrollment router & token exchange service | `host_enrollment.py` | `POST /v1/external-agents/enroll`, `POST /v1/external-agents/registrations/{agent_id}/token` |
| Database migration for host enrollment tokens | `040_host_enrollment_tokens.sql` | `public.host_enrollment_tokens` table, single-use flags, indexes, trigger, audit event types |
| Cryptographic token validation & hashing | `host_enrollment.py` | SHA-256 hash storage (`hashlib.sha256`), constant-time comparison (`hmac.compare_digest`), CSPRNG entropy (`secrets.token_urlsafe(32)`) |
| Atomic transaction & replay prevention | `host_enrollment.py` | Compare-and-set row updates, immediate token invalidation, `409 Conflict` (`already_enrolled`) on replay |
| Multi-threaded concurrency protection | `test_host_enrollment.py` | `test_concurrent_redemption` verifies 1 winner out of 10 parallel threads, 9 receive 409 Conflict |
| Expiration enforcement & error responses | `host_enrollment.py`, `test_host_enrollment.py` | 400 Bad Request, 401 Unauthorized (`token_expired`, `invalid_token`), 403 Forbidden, 415 Unsupported Media Type |
| Attributable audit logging | `host_enrollment.py` | Audit events for `external_agent.token_issued` and `external_agent.enrolled` |
| API route compatibility & mounting | `api_compat.py` | Mounted `host_enrollment_router`, `host_enrollment_api_router`, and `host_enrollment_compat_router` |
| Documentation guide | `docs/signalloom/host-enrollment-protocol.md` | Protocol specification, threat model, endpoints, wire contracts, and concurrency invariants |
| Automated test coverage | `test_host_enrollment.py` | 13/13 pytest test cases passed, contract tests passed, zero failures |

## Required commands

```bash
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_enrollment.py -v
make demo-signalloom-api-test TIER=contract
make demo-agentmaxxing-contract-test
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_concurrent_redemption
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_expired_token
test -f docs/signalloom/host-enrollment-protocol.md
test -f docs/signalloom/amxo-p3-1-evidence.md
```

## Scope and safety gates

```text
WORKTREE=/home/andy/src/.worktrees/023d1/osramp-demo
BASE_REF_GATE=PASS
```

No remote repositories were touched, no branches pushed, and no sibling worktrees modified.
