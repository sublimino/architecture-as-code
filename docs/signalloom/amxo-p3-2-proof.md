# AMXO-P3-2 Audit-Only Credential Scope & Tenant-Agent Binding Proof

**Evidence captured:** 2026-09-13T17:30:00+01:00  
**Task:** AMXO-P3-2 (Implement audit-only credential scope and tenant-agent binding for enrolled external Linux hosts)  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Worktree:** `/home/andy/src/.worktrees/59e47/osramp-demo` (detached HEAD)

---

## 1. Prompt-to-Artifact Checklist

| Required Outcome | Artifact | Positive Evidence / Invariant |
| :--- | :--- | :--- |
| **JWT credential issuance and verification service** | `host_credential.py` | `issue_host_credential`, `verify_host_credential`, `HostIdentityClaims`, `format_spiffe_id` |
| **Audit-upload-only scope enforcement** | `host_credential.py` | Tokens strictly carry `scope="audit-upload-only"`; non-audit tokens rejected |
| **Tenant-agent-host-key binding** | `host_credential.py` | `HostIdentityClaims` binds `(tenant_id, agent_id, host_id, key_id)` to SPIFFE SVID pattern |
| **Control-plane access denial middleware** | `host_credential.py`, `api_compat.py` | `HostCredentialScopeMiddleware` and `authenticated_principal` reject host tokens with 403 Forbidden |
| **Negative action matrix test suite** | `test_host_enrollment.py` | `test_denied_actions_*` verifies denial across user directory, agents, settings, superadmin, and cross-tenant |
| **Tenant-agent binding upload test suite** | `test_host_enrollment.py` | `test_tenant_agent_binding_*` verifies matching uploads accepted (202) and spoofed/mismatched rejected (403) |
| **Credential rotation & renewal mechanics** | `host_credential.py` | `rotate_host_credential` and `/v1/external-agents/credentials/rotate` endpoint |
| **Revocation fail-closed enforcement** | `host_credential.py` | Uploads and renewals for revoked agents rejected with 403 Forbidden (`agent_revoked`) |
| **Security architecture documentation** | `docs/signalloom/host-credential-scoping.md` | Documents SPIFFE identity pattern, claims schema, least-privilege matrix, and rotation lifecycle |
| **Evidence report** | `docs/signalloom/amxo-p3-2-evidence.md` | Comprehensive test ledger and authorization denial matrix |
| **Tenant isolation & API contract suite** | `test_tenant_isolation.py`, `test_contract_tier1.py` | 109/109 tenant isolation tests passed; 56/56 contract tests passed |

---

## 2. Required Commands Execution Matrix

```bash
# 1. Credential scope unit tests
pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_enrollment.py -k test_credential_scope
# Result: 6 passed, 0 failures

# 2. Operator identity contract test
make demo-agentmaxxing-contract-test
# Result: 6 passed, 0 failures

# 3. Negative action denial matrix tests
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_denied_actions
# Result: 6 passed, 0 failures

# 4. Tenant-agent binding tests
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_tenant_agent_binding
# Result: 7 passed, 0 failures

# 5. Evidence file existence check
test -f docs/signalloom/amxo-p3-2-evidence.md
# Result: PASS (exit 0)
```

---

## 3. Scope and Safety Gates

```text
WORKTREE=/home/andy/src/.worktrees/59e47/osramp-demo
BASE_REF_GATE=PASS (derived from integration/agentmaxxing-onboarding-v0.1.0)
REMOTE_PUSH=NONE
MERGE_REBASE=NONE
SIBLING_WORKTREE_TOUCH=NONE
```

All deliverables for AMXO-P3-2 are verified and ready for commit and Governor reconciliation.
