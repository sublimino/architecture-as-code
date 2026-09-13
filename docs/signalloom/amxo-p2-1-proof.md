# AMXO-P2-1 attributable operator lifecycle proof

**Evidence captured:** 2026-09-13T16:34:30+01:00
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`
**Worktree:** `/home/andy/src/.worktrees/9a9b6/osramp-demo`

## Prompt-to-artifact checklist

| Required outcome | Artifact | Positive evidence |
| :--- | :--- | :--- |
| Operator user management module | `platform_users.py`; `operator_identity.py` | Complete lifecycle router, request models, response models, session validation |
| Attributable operator database migration | `038_operator_identities.sql` | `operator_identities` table, foreign keys, unique constraint on `(issuer, subject)`, removal checks |
| Negative shared-identity rejection | `test_platform_users.py` (`test_operator_rejection_*`) | Pydantic validation rejects `identity_kind != 'individual'`, database checks return 403 `shared_identity_forbidden` |
| Negative removed-operator rejection | `test_platform_users.py` (`test_operator_rejection_of_removed_operators`) | Post-removal session checks return 403 `operator_removed` |
| Negative anonymous and cross-tenant rejection | `test_platform_users.py` (`test_operator_rejection_of_anonymous_principals`, `test_operator_rejection_of_cross_tenant_access`) | Returns 401 `anonymous_operator_forbidden` and 403 `operator_tenant_mismatch` |
| Operator de-provisioning & last admin protection | `operator_identity.py` (`remove_operator_identity`) | Advisory transaction locking, last-admin protection returning 409 `last_operator_admin` |
| Attributable audit records | `operator_identity.py` (`_audit_log`) | Generates `operator.created`, `operator.sign_in_succeeded`, `operator.sign_in_denied`, `operator.removed` events with immutable user UUID and actor details |
| Contract test suite | `test/signalloom/operator-identity.bats` | 6 of 6 tests pass without skips via `make demo-agentmaxxing-contract-test` |
| Operator identity documentation | `docs-signalloom/src/content/docs/reference/operator-identity-lifecycle.md` | Complete endpoint specifications, authorization matrix, and audit event mapping |
| Evidence report | `docs/signalloom/amxo-p2-1-evidence.md` | Test matrix and delivery verification ledger |

## Required test execution output

### 1. Pytest suite (`test_platform_users.py`)
```text
tests/test_platform_users.py ......................................... [100%]
41 passed, 2 warnings in 1.21s
```

### 2. Contract test suite (`make demo-agentmaxxing-contract-test`)
```text
bats test/signalloom/operator-identity.bats
operator-identity.bats
   operator policy records individual OIDC attribution1/6 ✓ operator policy records individual OIDC attribution
   operator policy records the approved authorization matrix2/6 ✓ operator policy records the approved authorization matrix
   operator policy names removal ownership and denial3/6 ✓ operator policy names removal ownership and denial
   database extension forbids shared rows and preserves attribution4/6 ✓ database extension forbids shared rows and preserves attribution
   wire models reject shared identity and tenant spoofing5/6 ✓ wire models reject shared identity and tenant spoofing
   focused operator lifecycle tests execute without skips6/6 ✓ focused operator lifecycle tests execute without skips

6 tests, 0 failures
```

### 3. Dedicated operator rejection negative tests (`-k test_operator_rejection`)
```text
tests/test_platform_users.py .......                                   [100%]
7 passed, 1434 deselected, 2 warnings in 4.82s
```

### 4. Consumer contract test suite (`make demo-signalloom-api-test TIER=contract`)
```text
56 passed, 2 warnings in 1.51s
```

## Scope and safety gates

```text
BASE_REF_GATE=PASS (derived from integration/agentmaxxing-onboarding-v0.1.0)
DOCTOR_CHECK=ALL CHECKS HEALTHY
NO_REMOTE_PUSH=ENFORCED
NO_DIRECT_BOARD_MUTATION=ENFORCED
NO_CUSTOMER_CONTENT_COLLECTED=ENFORCED
```
