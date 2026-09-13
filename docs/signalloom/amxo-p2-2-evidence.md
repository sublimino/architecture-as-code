# AMXO-P2-2 verification evidence

**Recorded:** 2026-09-13T16:45:00+01:00
**Scope:** Tenant-bound external Linux agent registration, global uniqueness, duplicate claim rejection, cross-tenant isolation, and audit logging.

## Test ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py -v` | 18 passed | 0 | Pre-registration, claim validation, duplicate claim rejection, cross-tenant isolation, revocation |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_registration.py -v` | 7 passed | 0 | Migration 039 structure, CRUD lifecycle, duplicate claim rejection, unauthenticated rejection, audit logging |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Operator identity and governance contract assertions |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_duplicate_claim` | 3 passed | 0 | Duplicate claim rejection within tenant and across tenants (409 Conflict) |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/ -k test_cross_tenant` | 7 passed | 0 | Cross-tenant claim rejection without leaking tenant identifiers |
| `git diff --check` | passed | n/a | Clean diff formatting with zero whitespace errors |

## Verification details

1. **Database Migration (`039_external_agent_registrations.sql`)**:
   - `public.external_agent_registrations` table created with `tenant_id` foreign key referencing `public.tenants(id) ON DELETE CASCADE`.
   - Global uniqueness constraint on `agent_id` preventing cross-tenant collision.
   - Foreign key linkage on `registered_by_user_id` and `(tenant_id, registered_by_user_id)` to `public.platform_users`.
   - Audit event type check constraints updated to include `external_agent.registered`, `external_agent.claimed`, `external_agent.claim_rejected`, and `external_agent.revoked`.

2. **Server-Side Tenant Scoping & Security**:
   - Strictly derived from authenticated operator credentials (`principal.tenant`).
   - Rejection of unregistered external agents attempting enrollment (403 Forbidden with `unregistered_agent`).
   - Cross-tenant claim and registration attempts rejected with 409 Conflict without leaking conflicting tenant names (`f"Agent '{agent_id}' is already registered or claimed by another tenant"`).

3. **Atomic Duplicate Claim Rejection**:
   - Rejection of duplicate claim attempts against an already-claimed active agent with 409 Conflict (`duplicate_claim`).
   - Full lifecycle status transitions from `pending` -> `enrolled` -> `revoked`.
   - Automatic release of active claims upon agent revocation.

4. **Audit and Delegation Spine Integration**:
   - Append-only audit records generated for registrations, claims, rejections, and revocations.
   - Non-blocking delegation synchronization to Signal Ingest Actor-Resolution Spine.

## Delivery boundaries

- No remote push performed.
- No merge or rebase performed.
- No runtime deployment performed.
- No project-board state changed.
- No sibling worktree changed.
