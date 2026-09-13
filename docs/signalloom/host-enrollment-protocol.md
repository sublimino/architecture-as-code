# Host Enrollment and Single-Use Token Exchange Protocol

**Contract:** AMXO-P3-1  
**Version:** 1.0.0  
**Scope:** One-time external Linux host enrollment token exchange, cryptographic verification, atomic single-use redemption, and replay protection in Signal Loom (`fe-signalloom`).

---

## 1. Protocol Overview

The Signal Loom Host Enrollment Protocol governs the secure bootstrapping of external Linux agents onto the Signal Loom governance platform. Enrollment binds pre-registered external Linux workloads to authorized tenant domains through cryptographically validated, one-time bearer enrollment tokens.

### Core Invariants
1. **Single-Use Redemption:** An enrollment token is redeemed exactly once. Upon successful redemption, the token is atomically consumed and invalidated, permanently preventing replay attacks.
2. **Cryptographic Secrecy:** Plaintext tokens are transmitted exclusively in the `Authorization: Bearer <token>` HTTP header over TLS. Tokens are hashed using canonical SHA-256 prior to persistence; plaintext tokens are never stored, logged, or cached.
3. **Constant-Time Verification:** Token comparison is performed in constant time using `hmac.compare_digest` to prevent timing side-channel attacks.
4. **Atomic State Transition:** Token redemption, agent status transition (`pending` -> `enrolled`), credential registration, and audit emission occur within an atomic database transaction.
5. **Least Privilege:** Successfully enrolled external hosts receive scoped, audit-upload-only credential authorization. No administrative or cross-tenant capabilities are granted.

---

## 2. Cryptographic and Storage Architecture

### 2.1 Token Generation and Entropy
- **Generator:** Cryptographically Secure Pseudo-Random Number Generator (`secrets.token_urlsafe(32)`).
- **Entropy:** 256 bits of CSPRNG entropy encoded as an unpadded base64url string (43–44 ASCII characters).
- **TTL:** Default lifetime of 1 hour (3600 seconds), configurable at issuance up to 24 hours (86400 seconds).

### 2.2 Token Storage Schema (`public.host_enrollment_tokens` and `public.external_agent_registrations`)
Plaintext tokens are transformed immediately upon generation:
$$\text{token\_hash} = \text{SHA-256}(\text{token\_utf8})$$
Stored as a 64-character lowercase hexadecimal string.

```sql
CREATE TABLE IF NOT EXISTS public.host_enrollment_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    agent_id VARCHAR(128) NOT NULL,
    token_hash VARCHAR(64) NOT NULL UNIQUE,
    issued_by_user_id UUID REFERENCES public.platform_users(id) ON DELETE SET NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    is_consumed BOOLEAN NOT NULL DEFAULT FALSE,
    consumed_at TIMESTAMPTZ,
    consumed_by_host_id VARCHAR(256),
    consumed_by_ip INET,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_host_enrollment_tokens_hash UNIQUE (token_hash)
);
```

In addition, `public.external_agent_registrations` stores the active enrollment token hash, expiration timestamp, and enrolled host public key bindings:
- `enrollment_token_hash`: `VARCHAR(64)`
- `enrollment_token_expires_at`: `TIMESTAMPTZ`
- `enrolled_host_public_key`: `VARCHAR(256)`
- `enrolled_host_mtls_san`: `VARCHAR(512)`
- `enrolled_credential_kind`: `VARCHAR(64)`

---

## 3. Wire Protocol and Endpoints

### 3.1 Operator Token Issuance (`POST /v1/external-agents/registrations/{agent_id}/token`)
Authorized tenant operators issue single-use enrollment tokens for pre-registered external agents.

- **Authentication:** Authenticated tenant operator with `admin` or `editor` role.
- **Tenant Derivation:** Derived strictly from `principal.tenant`.
- **Request Parameters:**
  - `agent_id` (path): Identifier of pre-registered agent.
  - `ttl_seconds` (query, optional): Lifetime in seconds (default `3600`, max `86400`).
- **Response (`201 Created`):**
```json
{
  "agent_id": "ext-agent-linux-prod-01",
  "enrollment_token": "u4_kX9vL...<plaintext_token_returned_once>",
  "expires_at": "2026-09-13T18:30:00Z",
  "enrollment_url": "/v1/external-agents/enroll",
  "instructions": "Redeem this token once via POST /v1/external-agents/enroll with Authorization: Bearer <token>"
}
```

### 3.2 External Host Enrollment (`POST /v1/external-agents/enroll`)
The external Linux agent presents the single-use bearer token along with host metadata and identity public keys.

- **Authentication:** `Authorization: Bearer <enrollment_token>`
- **Request Body:**
```json
{
  "agent_id": "ext-agent-linux-prod-01",
  "host_id": "host-linux-node-42",
  "host_os": "linux",
  "runtime_profile": "systemd-sandbox-v1",
  "public_key": "c2lnbmFsbG9vbS1lZDI1NTE5LXBrLXRlc3QtMDAx",
  "mtls_san": "spiffe://signalloom.demo/platform/signalloom/tenant/acme-corp/agent/ext-agent-linux-prod-01",
  "credential_kind": "existing-mtls-identity",
  "metadata": {
    "kernel": "6.8.0-40-generic",
    "arch": "x86_64"
  }
}
```

- **Response (`200 OK`):**
```json
{
  "agent_id": "ext-agent-linux-prod-01",
  "tenant_id": "acme-corp",
  "enrollment_status": "enrolled",
  "enrolled_at": "2026-09-13T17:30:00Z",
  "credential_scope": "audit-upload-only",
  "spiffe_id": "spiffe://signalloom.demo/platform/signalloom/tenant/acme-corp/agent/ext-agent-linux-prod-01",
  "spiffe_trust_domain": "signalloom.demo",
  "openbao_role": "auth/jwt/role/agent-trust-ext-agent-linux-prod-01",
  "audit_upload_endpoint": "/api/v1/telemetry/audit-upload"
}
```

### 3.3 Error Responses

| Scenario | HTTP Status | Code | Message |
| :--- | :---: | :--- | :--- |
| Missing Bearer Header | `401 Unauthorized` | `unauthorized` | Missing Bearer enrollment token in Authorization header |
| Invalid / Unknown Token | `401 Unauthorized` | `invalid_token` | Enrollment token is invalid, unrecognized, or already consumed |
| Expired Token | `401 Unauthorized` | `token_expired` | Enrollment token has expired |
| Unregistered Agent | `403 Forbidden` | `unregistered_agent` | Agent '<agent_id>' is not registered |
| Revoked Agent | `403 Forbidden` | `agent_revoked` | Agent '<agent_id>' has been revoked |
| Already Enrolled / Replay | `409 Conflict` | `already_enrolled` | Agent is already enrolled or token already consumed |
| Agent ID Mismatch | `400 Bad Request` | `agent_mismatch` | Agent ID in payload does not match token reservation |

---

## 4. Concurrency and Atomic Replay Prevention

### 4.1 Database Compare-and-Set (CAS)
Token consumption uses atomic database row locking (`SELECT ... FOR UPDATE`) and conditional CAS updates:
```sql
UPDATE public.external_agent_registrations
SET enrollment_status = 'enrolled',
    enrolled_at = NOW(),
    enrollment_token_hash = NULL,
    enrollment_token_expires_at = NULL,
    host_id = COALESCE($host_id, host_id),
    enrolled_host_public_key = $public_key,
    enrolled_host_mtls_san = $mtls_san,
    enrolled_credential_kind = $credential_kind
WHERE agent_id = $agent_id
  AND enrollment_status = 'pending'
  AND enrollment_token_hash = $token_hash;
```
If the row count updated is `0`, the transaction aborts and returns `409 Conflict` (`already_enrolled`) or `401 Unauthorized` (`invalid_token`).

### 4.2 Single-Use Token Table Consumption
Concurrently, the `host_enrollment_tokens` record is updated atomically:
```sql
UPDATE public.host_enrollment_tokens
SET is_consumed = TRUE,
    consumed_at = NOW(),
    consumed_by_host_id = $host_id
WHERE token_hash = $token_hash
  AND is_consumed = FALSE
  AND expires_at > NOW();
```

### 4.3 Process-Level Mutual Exclusion Fallback
For environments running without distributed row locks (such as in-memory test mocks), `fe-signalloom` provides an internal `asyncio.Lock` (`_HOST_ENROLL_LOCK`) ensuring that parallel redemption coroutines execute sequentially across token validation and record mutation.

---

## 5. Attributable Audit Logging

Every lifecycle step emits structured, immutable audit log events into `public.audit_events`:

| Event Type | Trigger | Key Audit Attributes |
| :--- | :--- | :--- |
| `external_agent.token_issued` | Operator generates enrollment token | `agent_id`, `tenant_id`, `issued_by_user_id`, `token_hash_prefix`, `expires_at` |
| `external_agent.enrolled` | External host successfully redeems token | `agent_id`, `tenant_id`, `host_id`, `host_os`, `runtime_profile`, `credential_kind` |
| `external_agent.enrollment_rejected` | Invalid, expired, or replayed redemption | `agent_id`, `reason`, `client_ip`, `status_code` |

---

## 6. Security Invariants & Containment

1. **Zero Secret Leakage:** Plaintext tokens are returned only once at issuance to the authenticated operator.
2. **Payload Containment:** Signal Loom ingests only host metadata and signed attestations; zero customer application payloads, local memories, or sensitive files are collected.
3. **Credential Scoping:** Issued SPIFFE IDs and OpenBao JWT roles allow only `read` on agent-specific trust keys and `audit-upload` on telemetry routes.
