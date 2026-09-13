# AMXO-P3-1 verification evidence

**Recorded:** 2026-09-13T17:31:00+01:00  
**Scope:** Atomic one-time external host enrollment token exchange, cryptographic token validation, single-use consumption, replay prevention, and concurrency protection in `fe-signalloom`.

## Test ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_enrollment.py -v` | 13 passed | 0 | Token hashing, happy path, single-use consumption, concurrency, expiration, unregistered/revoked/mismatched rejection, media type / malformed payload handling, operator token issuance |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | FastAPI tier 1 contract routes and all database migrations (including `040_host_enrollment_tokens.sql`) |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Operator identity and governance contract assertions |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_concurrent_redemption` | 1 passed | 0 | Multi-threaded race condition protection; exactly one parallel request succeeds, remainder receive 409 Conflict |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_expired_token` | 1 passed | 0 | Rejection of expired enrollment tokens with 401 Unauthorized (`token_expired`) |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py -v` | 18 passed | 0 | Pre-registration, claim validation, duplicate claim rejection, cross-tenant isolation, revocation |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_registration.py -v` | 7 passed | 0 | Registration CRUD lifecycle, duplicate claim rejection, unauthenticated rejection, audit logging |
| `git diff --check` | passed | n/a | Clean diff formatting with zero whitespace errors |

## Verification details

1. **Database Migration (`040_host_enrollment_tokens.sql`)**:
   - `public.host_enrollment_tokens` table created with `tenant_id` foreign key referencing `public.tenants(id) ON DELETE CASCADE`.
   - `token_hash VARCHAR(64) NOT NULL UNIQUE` enforcing uniqueness index on token hashes.
   - `is_consumed BOOLEAN NOT NULL DEFAULT FALSE`, `consumed_at`, and `consumed_by_host_id` fields for single-use tracking.
   - Credential columns added to `public.external_agent_registrations` (`enrolled_host_public_key`, `enrolled_host_mtls_san`, `enrolled_credential_kind`).
   - Audit event type check constraints updated to include `external_agent.token_issued` and `external_agent.enrolled`.

2. **Cryptographic Validation & Constant-Time Comparison**:
   - CSPRNG token generation using `secrets.token_urlsafe(32)` providing 256 bits of entropy.
   - Canonical SHA-256 token hashing (`hashlib.sha256(token.encode('utf-8')).hexdigest()`). Plaintext tokens are never stored.
   - Constant-time hash verification using `hmac.compare_digest` across all token lookup paths to eliminate timing side channels.
   - Strict `Authorization: Bearer <token>` header validation.

3. **Atomic Single-Use Redemption & Replay Protection**:
   - Atomic database compare-and-set query locking rows and invalidating tokens (`enrollment_token_hash = NULL`, `is_consumed = TRUE`, `status = 'enrolled'`).
   - Thread-safe process-level mutual exclusion fallback (`_HOST_ENROLL_LOCK`) ensuring that parallel requests are serialized and only the first caller succeeds while concurrent callers receive `409 Conflict` (`already_enrolled`).
   - Replay attempts immediately rejected with `409 Conflict` or `401 Unauthorized`.

4. **FastAPI Wire Contract & Operator Issuance**:
   - Operator token generation route `POST /v1/external-agents/registrations/{agent_id}/token` and `/api/v1/...` with tenant isolation and role checks.
   - External host redemption route `POST /v1/external-agents/enroll` and `/api/v1/...` returning scoped `audit-upload-only` credential definitions, SPIFFE IDs, and OpenBao role descriptors.
   - Comprehensive error mappings: 400 Bad Request (mismatched agent/host), 401 Unauthorized (invalid/expired token), 403 Forbidden (unregistered/revoked agent), 409 Conflict (already enrolled/claimed), 415 Unsupported Media Type.

5. **Attributable Audit Logging**:
   - Immutable audit entries created in `public.audit_events` for `external_agent.token_issued` and `external_agent.enrolled`.

## Delivery boundaries

- No remote push performed.
- No merge or rebase performed.
- No runtime deployment performed.
- No project-board state changed.
- No sibling worktree changed.
