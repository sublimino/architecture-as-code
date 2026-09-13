# Security Architecture Note: External Linux Host Credential Scoping & Isolation

**Document Version:** 1.0.0  
**Phase Contract:** `AMXO-P3-2`  
**Classification:** Internal Security Architecture  
**Target Systems:** `fe-signalloom`, `signal-ingest`, external Linux host sensors (`nono-0.73.0`)

---

## 1. Executive Summary

This architecture specification documents the cryptographic scoping, tenant-agent binding, least-privilege invariants, and lifetime management for external Linux host identities enrolled into Signal Loom.

External host credentials grant permission **exclusively** to upload execution evidence for a single pre-registered agent. All operator control-plane actions, user data access, agent lifecycle management, tenant settings, and cross-tenant interactions are strictly denied.

---

## 2. Workload Identity & SPIFFE Binding Pattern

External Linux host workloads operate under the SPIFFE trust domain `signalloom.demo`:
```
spiffe://signalloom.demo/platform/signalloom/tenant/{tenant_id}/agent/{agent_id}
```

### 2.1 Credential Claims Schema
Host credentials are cryptographically signed JWT tokens carrying immutable tenant-agent-host-key bindings:

| Claim | Type | Semantics & Security Invariant |
| :--- | :--- | :--- |
| `iss` | `string` | Authoritative Signal Loom issuer (e.g. `https://signalloom.demo/issuer`) |
| `sub` | `string` | Workload SPIFFE ID pattern binding tenant and agent |
| `aud` | `string` | Restricted audience (`signalloom-audit-ingest`) |
| `tenant_id` | `string` | Authenticated tenant boundary (derived server-side, never caller-supplied) |
| `agent_id` | `string` | Immutable pre-registered external agent identifier |
| `host_id` | `string` | Immutable external Linux host identifier |
| `key_id` | `string` | Ed25519 public key identifier bound during pre-registration/enrollment |
| `scope` | `string` | Strictly `"audit-upload-only"` |
| `identity_type` | `string` | Strictly `"external-host"` |
| `credential_kind` | `string` | `"existing-mtls-identity"` |
| `credential_bootstrap` | `string` | `"pre-provisioned-out-of-band"` |
| `iat` | `integer` | Unix timestamp of issuance |
| `nbf` | `integer` | Unix timestamp not-before |
| `exp` | `integer` | Unix timestamp expiration (default TTL: 3600s / 1 hour, max 30 days) |
| `jti` | `string` | CSPRNG unique token identifier (minimum 128 bits entropy) |

---

## 3. Least-Privilege Authorization Matrix

The authorization plane enforces complete isolation between human operator principals and external host credentials.

| API Category / Route | Operator (Admin/Editor) | External Host Credential | Denial Outcome |
| :--- | :---: | :---: | :--- |
| **Evidence Upload** (`POST /v1/external-agents/evidence-uploads`) | DENIED (403) | **ALLOWED (202)** (for bound agent) | 403 Forbidden if mismatched agent/host/key |
| **Credential Rotation** (`POST /v1/external-agents/credentials/rotate`) | DENIED (403) | **ALLOWED (200)** (for bound host) | 403 Forbidden if expired/revoked |
| **Privacy Contract** (`GET /v1/external-agents/privacy`) | ALLOWED (200) | **ALLOWED (200)** | Public / unauthenticated or authenticated |
| **User Directory** (`GET /api/v1/tenant/users`, `/api/platform-users`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Operator Identities** (`/api/operator-identities/*`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Agent Creation** (`POST /api/v1/agents`) | ALLOWED (201) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Agent Registration** (`POST /api/v1/external-agents/register`) | ALLOWED (201) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Agent Claim** (`POST /api/v1/external-agents/{agent_id}/claim`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Agent Revocation** (`POST /api/v1/external-agents/{agent_id}/revoke`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Tenant Settings** (`/api/v1/tenant/settings/*`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Compliance & Scans** (`/api/v1/compliance/*`, `/api/v1/nhi/*`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Superadmin Audit** (`/api/v1/superadmin/audit`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Support & Feedback** (`POST /api/v1/support`) | ALLOWED (200) | **DENIED (403)** | `host_credential_scope_restricted` |
| **Cross-Tenant Access** (Any route targeting foreign tenant) | DENIED (403) | **DENIED (403)** | `cross_tenant_forbidden` / `tenant_forbidden` |

---

## 4. Enforcement Architecture

1. **`HostCredentialScopeMiddleware` & `authenticated_principal` Interception:**
   - The middleware inspects incoming `Authorization: Bearer <token>` headers.
   - If the token carries `scope="audit-upload-only"` or `identity_type="external-host"`, access to any non-upload, non-rotation route is immediately rejected with `403 Forbidden` (`host_credential_scope_restricted`).
   - `authenticated_principal` verifies that host credentials cannot masquerade as platform users or operators.

2. **Tenant-Agent-Host-Key Binding Verification:**
   - On evidence upload (`POST /v1/external-agents/evidence-uploads`), the server extracts the authenticated `HostIdentityClaims`.
   - The assertion envelope's `key_id` must match `claims.key_id`.
   - Every individual assertion's `agent_id` and `host_id` must match `claims.agent_id` and `claims.host_id`.
   - If a caller attempts to upload assertions claiming another agent or host, the server rejects with `403 Forbidden` (`tenant_agent_binding_mismatch` / `tenant_host_binding_mismatch`).

3. **Revocation Fail-Closed Gate:**
   - When an operator revokes an agent via `POST /api/v1/external-agents/{agent_id}/revoke`, the agent's status in `external_agent_registrations` is set to `revoked`.
   - `verify_host_credential` checks the registration status on every upload and rotation request.
   - Any upload or renewal request for a revoked agent is rejected with `403 Forbidden` (`agent_revoked`).

4. **Credential Rotation & Renewal Mechanics:**
   - Long-running host processes renew credentials via `POST /v1/external-agents/credentials/rotate` prior to token expiration (`exp`).
   - The rotation service verifies the validity of the current token and confirms the agent is not revoked.
   - A new JWT is issued preserving the exact `tenant_id`, `agent_id`, `host_id`, `key_id`, and `audit-upload-only` scope, with a new `exp`, `iat`, and `jti`.
