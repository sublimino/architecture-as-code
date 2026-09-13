# AMXO-P3-3 verification evidence

**Recorded:** 2026-09-13T17:40:00+01:00
**Scope:** Independent host revocation enforcement, real-time upload denial, operator & sibling isolation, and audit logging.

## Test ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_revocation.py -v` | 8 passed | 0 | Full host enrollment, revocation lifecycle, operator & sibling isolation, upload denial, audit ingest denial, re-enrollment denial, cross-tenant protection |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_host_revocation.py -k test_host_revocation` | 3 passed | 0 | Dedicated host revocation tests (operator isolation, sibling agent isolation, upload denial) |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Attributable AgentMaxxing operator identity and governance contract assertions |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_post_revocation_denial` | 2 passed | 0 | Post-revocation upload denial and audit ingest denial (403 Forbidden with `host_revoked`) |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py -v` | 109 passed | 0 | Complete tenant isolation and authenticated API route coverage sweep |
| `make demo-signalloom-api-test` | 56 passed | 0 | Tier 1 contract tests and database migration ordering/idempotency tests |
| `bats test/signalloom/contract-conformance.bats` | 9 passed | 0 | OpenAPI and JSON schema conformance across enrollment, upload, and revocation routes |
| `git diff --check` | passed | n/a | Clean diff formatting with zero whitespace errors |

## Verification details

1. **Database Migration (`041_external_host_revocation.sql`)**:
   - `public.external_agent_registrations` extended with revocation attribution columns: `revoked_by_user_id UUID`, `revoked_by_subject TEXT`, `revoked_by_issuer TEXT`.
   - Foreign key constraint `fk_external_agent_revoked_by_user` referencing `public.platform_users(id, tenant_id)`.
   - Composite indexes `idx_external_agent_registrations_revocation` (`tenant_id, enrollment_status`) and `idx_external_agent_registrations_revoked_by` (`tenant_id, revoked_by_user_id`).
   - Verified idempotent across repeated discovery and execution via `test_migrations.py`.

2. **Revocation Handlers and OpenAPI Contract Conformance**:
   - `POST /v1/external-agents/{agent_id}/revocations`: Conforms strictly to `external-agent-server.v1.schema.json` (202 Accepted, returning `RevocationResult` with `schema_version="1.0.0"`, `revocation_state="revoked"`, `revoked_at` ISO timestamp, and `revocation_reason`).
   - `POST /api/v1/external-agents/registrations/{agent_id}/revoke`: Returns updated `ExternalAgentRegistrationResponse` with `enrollment_status="revoked"`.
   - `POST /v1/external-agents/hosts/{host_id}/revoke`: Revokes all agents associated with a given host ID in batch.
   - Operator credentials required; tenant derived strictly server-side from `principal.tenant`.

3. **Real-Time Ingestion and Upload Blocking**:
   - `is_external_agent_revoked(tenant_id, agent_id)` checks both PostgreSQL database state and thread-safe in-memory cache.
   - Evidence upload handler (`POST /v1/external-agents/evidence-uploads` and `POST /v1/external-agents/{agent_id}/uploads`) rejects revoked agents immediately with HTTP 403 Forbidden and code `host_revoked`.
   - Audit ingestion pipeline (`ingest_signed_audit_session` and `verify_audit_session_probe`) checks host revocation status and blocks session ingestion with HTTP 403 Forbidden (`host_revoked`).
   - Re-enrollment of revoked agents (`POST /v1/external-agents/enroll`) is denied with HTTP 403 Forbidden (`host_revoked`).

4. **Operator and Sibling Host Isolation**:
   - Revoking a host or agent terminates its credentials and active claims without affecting the revoking operator or any platform user account.
   - Sibling agents residing on different hosts or distinct agent IDs remain active, enrolled, and capable of uploading evidence without disruption.
   - Active claims in `public.agent_claims` are released atomically upon revocation, and Actor-Resolution Spine delegation is clamped via `clamp_claim_delegation_in_spine`.
   - Append-only audit record `external_agent.revoked` is emitted with complete attribution metadata.

## Delivery boundaries

- No remote push performed.
- No merge or rebase performed.
- No runtime deployment performed.
- No project-board state changed.
- No sibling worktree changed.
