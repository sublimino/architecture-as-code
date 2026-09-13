# AMXO-P3-2 Verification Evidence

**Recorded:** 2026-09-13T17:30:00+01:00  
**Scope:** Audit-only credential scope, tenant-agent binding, negative action matrix denial, credential rotation, and revocation enforcement.

---

## 1. Test Ledger

| Command | Outcome | Skips | Evidence / Invariant Verified |
| :--- | :--- | :--- | :--- |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_enrollment.py -k test_credential_scope` | 6 passed | 0 | JWT issuance, claims, signature validation, expired token rejection, scope checks, token rotation |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Operator identity and governance contract assertions |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_denied_actions` | 6 passed | 0 | Negative action matrix: host credential denied across user directory, agent modifications, tenant settings, superadmin, support, and cross-tenant access |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_tenant_agent_binding` | 7 passed | 0 | Evidence upload binding: matching upload accepted, mismatched agent/host/key rejected, cross-tenant upload rejected, post-revocation upload rejected |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_enrollment.py -v` | 19 passed | 0 | Full host enrollment, credential scope, and authorization suite |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py` | 109 passed | 0 | Complete AST and runtime zero-IDOR tenant isolation sweep |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | API consumer contract and database migration ledger verification |
| `bats test/acceptance-spec-coverage.bats` | 7 passed | 0 | Playwright test spec coverage and CI stage alignment |
| `git diff --check` | passed | n/a | Clean diff formatting with zero whitespace errors |

---

## 2. Authorization & Scope Denial Matrix

| Category | Endpoint Tested | Principal Type | Scope | Expected HTTP Code | Actual Result |
| :--- | :--- | :--- | :--- | :---: | :---: |
| **Evidence Upload** | `POST /v1/external-agents/evidence-uploads` | Host Identity | `audit-upload-only` | `202 Accepted` | PASS (202) |
| **Evidence Upload (Spoofed Agent)** | `POST /v1/external-agents/evidence-uploads` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `tenant_agent_binding_mismatch`) |
| **Evidence Upload (Spoofed Host)** | `POST /v1/external-agents/evidence-uploads` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `tenant_host_binding_mismatch`) |
| **Evidence Upload (Spoofed Key)** | `POST /v1/external-agents/evidence-uploads` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `tenant_key_binding_mismatch`) |
| **Evidence Upload (Cross-Tenant)** | `POST /v1/external-agents/evidence-uploads` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `cross_tenant_forbidden`) |
| **Evidence Upload (Post-Revocation)** | `POST /v1/external-agents/evidence-uploads` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `agent_revoked`) |
| **Credential Rotation** | `POST /v1/external-agents/credentials/rotate` | Host Identity | `audit-upload-only` | `200 OK` | PASS (200) |
| **Privacy Contract** | `GET /v1/external-agents/privacy` | Anonymous / Host | N/A | `200 OK` | PASS (200) |
| **Platform Users List** | `GET /api/v1/tenant/users` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Operator Directory** | `GET /api/operator-identities` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Operator Session Probe** | `GET /api/operator-identities/session` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Agent Creation** | `POST /api/v1/agents` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **External Agent Register** | `POST /api/v1/external-agents/register` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **External Agent Claim** | `POST /api/v1/external-agents/{agent}/claim` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **External Agent Revoke** | `POST /api/v1/external-agents/{agent}/revoke` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Tenant Settings** | `GET /api/v1/tenant/settings` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Tenant Preferences** | `PATCH /api/v1/tenant/settings/preferences` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Tenant Frameworks** | `PATCH /api/v1/tenant/settings/frameworks` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Compliance Summary** | `GET /api/v1/compliance/summary` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Superadmin Audit** | `GET /api/v1/superadmin/audit` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Support Request** | `POST /api/v1/support` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Capabilities Query** | `GET /api/v1/capabilities` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |
| **Cross-Tenant Agent Read** | `GET /api/v1/agents/{other_agent}` | Host Identity | `audit-upload-only` | `403 Forbidden` | PASS (403 `host_credential_scope_restricted`) |

---

## 3. Verification Details

1. **Host Credential Issuance & Claims Structure (`host_credential.py`)**:
   - Cryptographically signed JWT tokens issued with `scope="audit-upload-only"` and `identity_type="external-host"`.
   - Immutable binding to `(tenant_id, agent_id, host_id, key_id)` with SPIFFE SVID subject pattern `spiffe://signalloom.demo/platform/signalloom/tenant/{tenant}/agent/{agent}`.
   - Bounded token lifetime (default 1 hour / 3600s, max 30 days) with unique `jti` nonce.

2. **Authorization Middleware & Endpoint Interception**:
   - `HostCredentialScopeMiddleware` and `authenticated_principal` intercept all incoming requests.
   - Any attempt to use host credentials on operator control plane routes or user management APIs is immediately rejected with `403 Forbidden` (`host_credential_scope_restricted`).
   - Only audit evidence upload and credential rotation/renewal endpoints accept host credentials.

3. **Tenant-Agent Binding Enforcement on Evidence Upload**:
   - `upload_evidence_handler` verifies that the caller's authenticated `HostIdentityClaims` match the uploaded `key_id`, `agent_id`, `host_id`, and `tenant_id` exactly.
   - Mismatches in any of these claims are rejected with explicit 403 Forbidden responses (`tenant_agent_binding_mismatch`, `tenant_host_binding_mismatch`, `tenant_key_binding_mismatch`, `cross_tenant_forbidden`).

4. **Credential Rotation and Renewal Mechanics**:
   - Long-running host processes can rotate credentials before expiration via `POST /v1/external-agents/credentials/rotate`.
   - Preserves exact tenant, agent, host, and key bindings while issuing refreshed `exp`, `iat`, and `jti` tokens.

5. **Revocation Fail-Closed Gate**:
   - Revoking an external agent in `external_agent_registrations` immediately causes all subsequent upload and renewal attempts to be rejected with `403 Forbidden` (`agent_revoked`).

---

## 4. Delivery Boundaries

- No remote push performed.
- No merge or rebase performed.
- No runtime deployment performed.
- No project-board state changed.
- No sibling worktree changed.
