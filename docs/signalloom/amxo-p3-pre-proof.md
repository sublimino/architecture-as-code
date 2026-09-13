# AMXO-P3-PRE — Phase 3 Host Enrollment and Credential Exchange Preflight Proof

**Status:** PASS — Phase 3 host enrollment and credential exchange implementation may start from frozen contracts  
**Verified at:** 2026-09-13 17:18:20+01:00  
**Logical ID:** `P3-PRE`  
**Role:** preflight  
**Launch base:** `39ac7da29a2201b4ad3893d111a2835180635d9a`  
**Integration tip inspected:** `39ac7da29a2201b4ad3893d111a2835180635d9a`  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Task worktree:** `/home/andy/src/.worktrees/82ac8/osramp-demo` (detached HEAD)

---

## 1. Executive Summary & Verdict

Phase 2 deliverables (attributable operator lifecycle, OIDC individual attribution, tenant-bound external Linux agent pre-registration, atomic duplicate-claim rejection, and cross-tenant conflict rejection) are merged and certified on `integration/agentmaxxing-onboarding-v0.1.0`.

Preflight verification confirms:
1. **Phase 2 Governance Merged:** All Phase 2 identity and registration migrations (`038_operator_identities.sql`, `039_external_agent_registrations.sql`), Python modules (`operator_identity.py`, `external_agent_registration.py`, `agent_claim.py`), and test suites are present and certified by `AMXO-P2-GOV`.
2. **OpenBao & SPIFFE Identity Integration Seams:** Workload identity SPIFFE ID patterns (`spiffe://signalloom.demo/platform/signalloom/tenant/{tenant}/agent/{agent}`), OpenBao JWT role definitions (`auth/jwt/role/agent-trust-${agent}`), and least-privilege audit-upload-only credential policies are verified against the frozen contract.
3. **Token Hashing & Single-Use Enrollment Seams:** Opaque bearer token generation via CSPRNG, canonical SHA-256 hashing, and compare-and-set database persistence in `external_agent_registrations` are verified for atomic single-use consumption.
4. **Storage Schema & Expiration Tracking:** Database columns in migration `039` (`enrollment_token_hash`, `enrollment_token_expires_at`, `enrollment_status`, `enrolled_at`, `revoked_at`, `revocation_reason`) provide comprehensive support for token redemption, expiration checks, and independent revocation.
5. **Runtime Isolation & Telemetry Boundaries:** Strict worktree sandbox confinement, attributable audit provenance, and zero customer payload/memory data collection are enforced.

---

## 2. Prompt-to-Artifact Verification Checklist

| Requirement | Evidence / Probe | Result |
| :--- | :--- | :---: |
| Isolated runtime worktree | Worktree `/home/andy/src/.worktrees/82ac8/osramp-demo` | PASS |
| Integration ancestry | `git merge-base --is-ancestor integration/agentmaxxing-onboarding-v0.1.0 HEAD` exited `0` | PASS |
| Phase 2 deliverables merged | Migrations `008`, `035`–`039`; `operator_identity.py`, `external_agent_registration.py` | PASS |
| Migration sequence audit | 24 ordered files (`001`–`012`, `020`–`021`, `030`–`039`); no duplicate prefixes; next `040` | PASS |
| OpenBao / SPIFFE role inventory | `openbao-role-intent.sh`, `spiffe-openbao-attestation.md`, contract schemas | PASS |
| Token hashing & storage schema | SHA-256 hash storage, timestamp expiry, atomic CAS status transition | PASS |
| Enrollment wire schema review | `external-agent-enrollment.v1.schema.json`, `external-agent-server.v1.schema.json` | PASS |
| Tenant isolation readiness | AST query analysis & runtime tests (109/109 passed in `test_tenant_isolation.py`) | PASS |
| Required focused pytest | 18 passed in `test_agent_claim.py`, 34 passed in registration/contract suites | PASS |
| AgentMaxxing contract suite | 6 passed in `make demo-agentmaxxing-contract-test` | PASS |
| Tier 1 API contract suite | 56 passed in `make demo-signalloom-api-test TIER=contract` | PASS |
| Acceptance spec coverage | 7 passed in `bats test/acceptance-spec-coverage.bats` | PASS |
| Root full test target | `make test` exited `0` (8 tests, 0 skipped) | PASS |
| Execution evidence | `docs/signalloom/amxo-p3-preflight-proof.md` and `docs/signalloom/amxo-p3-pre-proof.md` | PASS |
| Proposal errata | Qualified `AMXO-P3-PRE` block appended with `status=pass` | PASS |
| Implementation exclusion | Clean preflight proof and errata only; no Phase 3 product deliverables implemented | PASS |

---

## 3. OpenBao Policy and Role Inventory Report

### 3.1 Workload Identity Pattern
Signal Loom external agent identities are modeled under the SPIFFE trust domain `signalloom.demo`:
```
spiffe://signalloom.demo/platform/signalloom/tenant/{tenant_id}/agent/{agent_id}
spiffe://signalloom.demo/platform/signalloom/tenant/{tenant_id}/project/{project_id}/agent/{agent_id}
```

### 3.2 OpenBao Role Definitions and Policy Intent
As defined in `d2-agent-trust/contracts/openbao-role-intent.sh` and `d2-signalloom/infra/inf-bao`:
- **Policy:** `agent-trust-{tenant}`
  - Path: `kv/data/signalloom/agent-trust/{tenant}/*`
  - Capabilities: `["read"]`
- **JWT Auth Role:** `auth/jwt/role/agent-trust-${agent}`
  - `role_type`: `jwt`
  - `bound_audiences`: `openbao-supercredential`
  - `bound_subject`: SPIFFE SVID pattern matching the tenant-bound agent
  - `user_claim`: `sub`
  - `token_type`: `batch`
  - `token_ttl`: `5m`
  - `token_max_ttl`: `5m`
  - `token_period`: `0`

### 3.3 External Host Audit Credential Scope
Audited against `external-agent-enrollment.v1.schema.json` and `external-agent-server.v1.schema.json`:
- **Credential Kind:** `existing-mtls-identity`
- **Credential Scope:** `audit-upload-only`
- **Credential Bootstrap:** `pre-provisioned-out-of-band`
- **Key Algorithm:** `Ed25519` (raw 32-byte public key in canonical unpadded base64url)
- **Least-Privilege Invariants:**
  1. External host credentials possess **no read or management permissions** on the tenant management plane, operator directory, or claim registries.
  2. The enrollment exchange does not return private keys or certificate authorities; it activates and records server-side authorization for pre-provisioned mTLS / Ed25519 key bindings.
  3. All host uploads must sign assertions using Ed25519 over canonical signing bytes and pass mTLS identity validation.

---

## 4. Token Hashing and Storage Schema Verification Report

### 4.1 Token Generation and Transmission
- **Generation:** Single-use enrollment tokens must be generated via a Cryptographically Secure Pseudo-Random Number Generator (CSPRNG) with at least 256 bits of entropy (e.g. `secrets.token_urlsafe(32)`).
- **Transport:** Carried exclusively via standard HTTP header: `Authorization: Bearer <token>`. Request bodies and URL query parameters MUST NOT carry plaintext enrollment tokens.

### 4.2 Hashing Algorithm
- **Algorithm:** Canonical SHA-256 (`hashlib.sha256(token.encode('utf-8')).hexdigest()`).
- Stored exclusively as lowercase hexadecimal digests (64 characters). Plaintext tokens are never persisted in databases, logs, or cache layers.

### 4.3 Database Storage Schema (`public.external_agent_registrations`)
Delivered in migration `039_external_agent_registrations.sql`:
```sql
CREATE TABLE IF NOT EXISTS public.external_agent_registrations (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id                    TEXT        NOT NULL CHECK (btrim(agent_id) <> ''),
    tenant_id                   TEXT        NOT NULL CHECK (btrim(tenant_id) <> ''),
    host_id                     TEXT        NOT NULL CHECK (btrim(host_id) <> ''),
    host_os                     TEXT        NOT NULL DEFAULT 'linux'
                                            CHECK (host_os IN ('linux', 'ubuntu-24.04', 'debian-12', 'rhel-9', 'fedora-40', 'arch')),
    runtime_profile             TEXT        NOT NULL DEFAULT 'nono-0.73.0-standard'
                                            CHECK (btrim(runtime_profile) <> ''),
    enrollment_status           TEXT        NOT NULL DEFAULT 'pending'
                                            CHECK (enrollment_status IN ('pending', 'enrolled', 'revoked', 'failed')),
    registered_by_user_id       UUID,
    registered_by_subject       TEXT        NOT NULL CHECK (btrim(registered_by_subject) <> ''),
    registered_by_issuer        TEXT        NOT NULL CHECK (btrim(registered_by_issuer) <> ''),
    allocated_token_budget      INTEGER     NOT NULL DEFAULT 100000 CHECK (allocated_token_budget > 0),
    spiffe_id_pattern           TEXT,
    enrollment_token_hash       TEXT,
    enrollment_token_expires_at TIMESTAMPTZ,
    enrolled_at                 TIMESTAMPTZ,
    revoked_at                  TIMESTAMPTZ,
    revocation_reason           TEXT,
    metadata                    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_external_agent_registrations_agent_id UNIQUE (agent_id),
    CONSTRAINT fk_external_agent_registered_by_user
        FOREIGN KEY (registered_by_user_id, tenant_id)
        REFERENCES public.platform_users (id, tenant_id)
        ON DELETE RESTRICT
);
```

### 4.4 Atomic Compare-and-Set Consumption Semantics
For `AMXO-P3-1`, token consumption must execute as an atomic transaction:
```sql
UPDATE public.external_agent_registrations
   SET enrollment_status = 'enrolled',
       enrolled_at = NOW(),
       enrollment_token_hash = NULL,
       updated_at = NOW()
 WHERE tenant_id = $1
   AND agent_id = $2
   AND enrollment_status = 'pending'
   AND enrollment_token_hash = $3
   AND (enrollment_token_expires_at IS NULL OR enrollment_token_expires_at > NOW())
RETURNING id, agent_id, tenant_id, host_id, enrollment_status, enrolled_at;
```
If zero rows are updated, the exchange rejects with 401 Unauthorized (invalid/expired token) or 409 Conflict (already enrolled/revoked).

---

## 5. Phase 3 Task Readiness & Work Breakdown

| Task ID | Role | Focus Area | Entry Seams & Invariants |
| :--- | :--- | :--- | :--- |
| **AMXO-P3-1** | implementation | Atomic Host Enrollment Exchange | Route `POST /v1/external-agents/enroll`. Verify Bearer token against stored hash, validate nonce & public key, atomically transition `pending -> enrolled`, emit `external_agent.claimed` audit event. |
| **AMXO-P3-2** | implementation | Audit-Only Credential Scope & Binding | Restrict host credential capabilities exclusively to evidence upload. Bind `(tenant_id, agent_id, host_id, key_id)` to mTLS subject. Reject non-upload actions. |
| **AMXO-P3-3** | implementation | Independent Host Revocation Enforcement | Route `POST /v1/external-agents/{agent_id}/revocations`. Atomic transition to `revoked`, log `external_agent.revoked` audit event, reject subsequent upload requests. |
| **AMXO-P3-GOV** | governor | Enrollment Governance Certification | Validate end-to-end enrollment, credential least privilege, concurrent token redemption rejection, and merge into integration branch. |

---

## 6. Test Verification Matrix

| Test Suite | Scope | Command | Result |
| :--- | :--- | :--- | :--- |
| Agent Claim & Pre-registration | Claim lifecycle & registration validation | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py -v` | 18/18 PASS |
| External Agent Registration & Contracts | Migration 039, CRUD, duplicate rejection, schemas | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_registration.py d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_contract.py -v` | 34/34 PASS |
| AST & Runtime Tenant Isolation | Zero-IDOR validation across all API routes | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py` | 109/109 PASS |
| Operator Identity Contract Suite | OIDC attribution & policy invariants | `make demo-agentmaxxing-contract-test` | 6/6 PASS |
| API Consumer Contract Tier 1 | Signal Loom API contracts & migration ledger | `make demo-signalloom-api-test TIER=contract` | 56/56 PASS |
| Playwright Spec Coverage | Registry & CI stage cross-check | `bats test/acceptance-spec-coverage.bats` | 7/7 PASS |
| Foundation Integration Suite | End-to-end SBOM & witness attestation | `make test` | 8/8 PASS |

---

## 7. Conclusion

Preflight verification for Phase 3 (`AMXO-P3-PRE`) is complete. All identity and registration baselines are green, migration and schema contracts are verified, OpenBao/SPIFFE least-privilege policies are validated, and the database schema is prepared for atomic host enrollment and independent revocation. Phase 3 implementation is cleared to proceed.
