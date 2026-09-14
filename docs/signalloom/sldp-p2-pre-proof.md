# SLDP-P2-PRE Execution Proof

**Status:** PASS — Phase 2 preflight complete; migration sequences reserved, never-merge invariant triggers verified, tenant-binding contract restated, cleartext identifier index inventory compiled, and unconfirmed assumptions documented.  
**Logical ID:** `SLDP-P2-PRE`  
**Role:** Preflight  
**Base Commit / Integration Ref:** `53e412b6de613efaa6e6c3b30e0e3cf574d44ff2`  
**Integration Branch:** `refs/heads/integration/sldp-v0.1.0`  
**Runtime Worktree:** `/home/andy/src/.worktrees/5117d/osramp-demo`  
**Recorded Date:** 2026-09-14 14:33:39+01:00  

---

## 1. Objective & Contract Interpretation

Phase 2 preflight (`SLDP-P2-PRE`) confirms the identity-graph seams, migration sequence allocations, never-merge trigger mechanics, tenant-binding contracts, and cleartext index mappings before pseudonymisation (`P2-1`), row-level security (`P2-2`), and never-merge pinning (`P2-3`) commence.

This preflight:
1. Audits the existing migration files under `d2-signalloom/apps/signal-ingest/identity/migrations/` and reserves unique sequence numbers per implementation card to eliminate merge conflicts.
2. Re-reads `check_never_merge_alias()` and `check_never_merge_delegation()` in `001_identity_graph.sql` to capture exact trigger logic and identify how pseudonymisation threatens to cause the never-merge check to fail OPEN.
3. Restates the P1-GOV tenant-binding contract as `P2-2` will consume and enforce it at the PostgreSQL database layer.
4. Identifies and documents all database indexes currently built on cleartext identifier columns (`actor_id`, `alias_value`, `delegate_actor_id`, `principal_actor_id`).
5. Evaluates and explicitly enumerates all unconfirmed assumptions entering Phase 2.
6. Asserts clean execution across all baseline and acceptance test suites.

---

## 2. Pre-Execution Safety & Environment Gates

| Gate | Command / Target | Observed Result | Verdict |
|---|---|---|---|
| **Isolated Runtime** | `pwd` | `/home/andy/src/.worktrees/5117d/osramp-demo` (isolated worktree) | **PASS** |
| **Principal Repo Guard** | `$PWD != /home/andy/src/cp/osramp-demo` | True; principal repository is untouched | **PASS** |
| **Clean Baseline** | `git status` | Clean working tree; no uncommitted changes | **PASS** |
| **Integration Lineage** | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | Exit 0; HEAD (`53e412b6...`) is direct descendant of integration branch | **PASS** |
| **Board State** | `kanban-check.sh progress` | `P2-PRE` in progress; board healthy; read-only inspection | **PASS** |

---

## 3. Deliverable 1: Identity Migration Sequence Numbers & Per-Card Reservation

### 3.1 Migration Directory Inventory
Inspection of `d2-signalloom/apps/signal-ingest/identity/migrations/`:

```
d2-signalloom/apps/signal-ingest/identity/migrations/
├── 001_identity_graph.sql           (6,067 bytes, core tables, btree temporal indexes, triggers)
├── 002_delegation_indices.sql       (830 bytes, composite & partial delegation traversal indexes)
├── 003_idempotent_seeding.sql       (388 bytes, unique constraints for atomic ON CONFLICT DO NOTHING)
└── 004_delegation_revocation.sql    (549 bytes, status column & revocation temporal indexes)
```

The current highest sequence number is `004`. The next available sequence number is `005`.

### 3.2 Sequence Allocation & Reservation Table

To prevent concurrent migration collisions upon merge, sequence numbers are allocated as follows:

| Card | Logical Task | Reserved Sequence & Filename | Target Schema Modification |
|---|---|---|---|
| **SLDP-P2-1** | Keyed HMAC pseudonyms and envelope-encrypted alias values | `005_pseudonymisation_and_encryption.sql` | Add `alias_value_encrypted BYTEA`, transition `alias_value_hash` to HMAC, adjust alias value constraints |
| **SLDP-P2-2** | Tenant column and enforced row-level security on identity graph | `006_tenant_isolation_rls.sql` | Add `tenant_id VARCHAR(255) NOT NULL`, enable RLS on `actors`, `aliases`, `delegations`, define tenant policies |
| **SLDP-P2-3** | Pin never-merge invariant across pseudonymisation change | `007_pin_never_merge_pseudonyms.sql` *(optional / if trigger replacement)* | Update `check_never_merge_alias` and `check_never_merge_delegation` to compare HMAC/actor mappings |
| **SLDP-P2-GOV** | Freeze identity privacy contract | N/A (Audits `001` through `007`) | Governance certification |

---

## 4. Deliverable 2: Current Text & Seam Analysis of `check_never_merge_alias`

### 4.1 Exact Trigger Text & Location
- **File:** `d2-signalloom/apps/signal-ingest/identity/migrations/001_identity_graph.sql`
- **Lines:** 63–87 (`check_never_merge_alias`) and 89–93 (`trg_aliases_never_merge`)

```sql
63: CREATE OR REPLACE FUNCTION check_never_merge_alias() RETURNS TRIGGER AS $$
64: BEGIN
65:     -- Prevent an alias from pointing an actor to an actor it delegates for
66:     IF EXISTS (
67:         SELECT 1 FROM delegations
68:         WHERE delegate_actor_id = NEW.actor_id
69:           AND principal_actor_id = NEW.alias_value
70:     ) THEN
71:         RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias delegate % to its delegation principal %', NEW.actor_id, NEW.alias_value
72:             USING ERRCODE = 'check_violation';
73:     END IF;
74: 
75:     -- Prevent an alias from pointing an actor to an actor delegating to it
76:     IF EXISTS (
77:         SELECT 1 FROM delegations
78:         WHERE principal_actor_id = NEW.actor_id
79:           AND delegate_actor_id = NEW.alias_value
80:     ) THEN
81:         RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias principal % to its delegate %', NEW.actor_id, NEW.alias_value
82:             USING ERRCODE = 'check_violation';
83:     END IF;
84: 
85:     RETURN NEW;
86: END;
87: $$ LANGUAGE plpgsql;
88: 
89: DROP TRIGGER IF EXISTS trg_aliases_never_merge ON aliases;
90: CREATE TRIGGER trg_aliases_never_merge
91:     BEFORE INSERT OR UPDATE ON aliases
92:     FOR EACH ROW
93:     EXECUTE FUNCTION check_never_merge_alias();
```

- **Complementary Trigger:** `check_never_merge_delegation` (`001_identity_graph.sql:95-114`) and `trg_delegations_never_merge` (`001_identity_graph.sql:117-120`):

```sql
95: CREATE OR REPLACE FUNCTION check_never_merge_delegation() RETURNS TRIGGER AS $$
96: BEGIN
97:     IF NEW.delegate_actor_id = NEW.principal_actor_id THEN
98:         RAISE EXCEPTION 'structural never-merge invariant violated: self-delegation % is forbidden', NEW.delegate_actor_id
99:             USING ERRCODE = 'check_violation';
100:     END IF;
101: 
102:     -- Prevent a delegation between actors that are already aliased to each other
103:     IF EXISTS (
104:         SELECT 1 FROM aliases
105:         WHERE (actor_id = NEW.delegate_actor_id AND alias_value = NEW.principal_actor_id)
106:            OR (actor_id = NEW.principal_actor_id AND alias_value = NEW.delegate_actor_id)
107:     ) THEN
108:         RAISE EXCEPTION 'structural never-merge invariant violated: cannot delegate between aliased identities % and %', NEW.delegate_actor_id, NEW.principal_actor_id
109:             USING ERRCODE = 'check_violation';
110:     END IF;
111: 
112:     RETURN NEW;
113: END;
114: $$ LANGUAGE plpgsql;
```

### 4.2 Critical Seam & Failure Mode Analysis for P2-1 and P2-3
1. **The Direct Cleartext Comparison:** `check_never_merge_alias` evaluates `principal_actor_id = NEW.alias_value` and `delegate_actor_id = NEW.alias_value`. Similarly, `check_never_merge_delegation` evaluates `alias_value = NEW.principal_actor_id` and `alias_value = NEW.delegate_actor_id`.
2. **The Fail-Open Hazard:** When P2-1 encrypts `alias_value` (e.g. envelope-encrypted ciphertext) or replaces `alias_value` with a keyed HMAC pseudonym, direct comparison against raw `actor_id` (`principal_actor_id` / `delegate_actor_id`) will fail to match. Because the `WHERE` clause fails to find matching rows, the `IF EXISTS (...)` condition evaluates to `FALSE`, and the trigger **silently permits illegal alias merges between delegation partners**.
3. **P2-3 Pinning Mandate:** P2-3 must establish comprehensive negative assertion tests (`TestStructuralNeverMerge_*`) against both in-memory and PostgreSQL implementations *before* P2-1 schema alterations, ensuring that never-merge validation remains enforced and cannot fail open once `alias_value` is pseudonymised.

---

## 5. Deliverable 3: P1-GOV Tenant-Binding Contract Restatement for P2-2

As published in `docs/signalloom/sldp-p1-gov-proof.md` §6 and certified under commit `53e412b6`, `SLDP-P2-2` consumes the following tenant-binding contract:

1. **Context Ingestion:**
   Authenticated HTTP handlers extract caller tenancy exclusively via:
   ```go
   tenantCtx, ok := api.TenantContextFromContext(r.Context())
   ```
2. **Authoritative Origin:**
   The `TenantContext.TenantID` is derived exclusively from the authenticated principal's verified SPIFFE identity (`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`) or cryptographically verified JWT claims.
3. **Strict Header & Parameter Prohibition:**
   Database repositories, stores, and HTTP handlers **MUST NEVER** read, trust, or branch on unverified `X-Tenant-ID` headers or query parameters to determine data isolation boundaries.
4. **PostgreSQL RLS Enforcement:**
   All SQL operations within `signal-ingest` must be tenant-scoped:
   - Tables (`actors`, `aliases`, `delegations`) must include `tenant_id VARCHAR(255) NOT NULL`.
   - Tables must enable Row-Level Security: `ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;`.
   - Tenant isolation policies must enforce:
     ```sql
     CREATE POLICY tenant_isolation_policy ON <table>
         USING (tenant_id = current_setting('app.current_tenant', true))
         WITH CHECK (tenant_id = current_setting('app.current_tenant', true));
     ```
   - All repository transaction sessions must execute `SET LOCAL app.current_tenant = $tenant_id` using the verified `TenantContext.TenantID`.

---

## 6. Deliverable 4: Inventory of Indexes on Cleartext Identifier Columns

Across all 4 active migration scripts, 10 indexes currently index cleartext identifier columns:

| # | Table | Index Name | Migration File & Line | Indexed Columns | Identifier Column(s) | Impact of P2-1 / P2-2 |
|---|---|---|---|---|---|---|
| 1 | `actors` | `actors_pkey` (Primary Key) | `001_identity_graph.sql:7` | `(actor_id)` | `actor_id` | P2-2 will composite with `tenant_id` or maintain tenant RLS. |
| 2 | `aliases` | `idx_aliases_actor_temporal` | `001_identity_graph.sql:47-48` | `(actor_id, valid_from, valid_to)` | `actor_id` | Temporal lookup by canonical actor ID. |
| 3 | `aliases` | `idx_aliases_value_temporal` | `001_identity_graph.sql:50-51` | `(alias_value, valid_from, valid_to)` | `alias_value` (email, username, SPIFFE ID) | **PRIMARY P2-1 TARGET:** Must transition away from cleartext `alias_value` index to HMAC/pseudonym index. |
| 4 | `aliases` | `idx_aliases_idempotent_seed` (Unique) | `003_idempotent_seeding.sql:4-5` | `(actor_id, alias_type, alias_value, valid_from)` | `actor_id`, `alias_value` | Must update to avoid indexing cleartext `alias_value`. |
| 5 | `delegations` | `idx_delegations_delegate_temporal` | `001_identity_graph.sql:56-57` | `(delegate_actor_id, valid_from, valid_to)` | `delegate_actor_id` | Cleartext delegate actor reference. |
| 6 | `delegations` | `idx_delegations_principal_temporal` | `001_identity_graph.sql:59-60` | `(principal_actor_id, valid_from, valid_to)` | `principal_actor_id` | Cleartext principal actor reference. |
| 7 | `delegations` | `idx_delegations_transitive_traversal` | `002_delegation_indices.sql:5-6` | `(delegate_actor_id, principal_actor_id, valid_from, valid_to)` | `delegate_actor_id`, `principal_actor_id` | Traversal composite index on actor IDs. |
| 8 | `delegations` | `idx_delegations_active_open_ended` | `002_delegation_indices.sql:9-11` | `(delegate_actor_id, principal_actor_id, valid_from) WHERE valid_to IS NULL` | `delegate_actor_id`, `principal_actor_id` | Partial index for active delegations. |
| 9 | `delegations` | `idx_delegations_reverse_transitive` | `002_delegation_indices.sql:14-15` | `(principal_actor_id, delegate_actor_id, valid_from, valid_to)` | `principal_actor_id`, `delegate_actor_id` | Reverse traversal index on actor IDs. |
| 10 | `delegations` | `idx_delegations_idempotent_seed` (Unique) | `003_idempotent_seeding.sql:7-8` | `(delegate_actor_id, principal_actor_id, valid_from)` | `delegate_actor_id`, `principal_actor_id` | Idempotent seeding index. |
| 11 | `delegations` | `idx_delegations_delegate_valid_to` | `004_delegation_revocation.sql:9-10` | `(delegate_actor_id, valid_to)` | `delegate_actor_id` | Revocation lookup index. |
| 12 | `delegations` | `idx_delegations_principal_valid_to` | `004_delegation_revocation.sql:12-13` | `(principal_actor_id, valid_to)` | `principal_actor_id` | Revocation lookup index. |

*(Note: `idx_aliases_hash_temporal` at `001:53` indexes `alias_value_hash`, `idx_actors_created_at` at `001:45` indexes `created_at`, and `idx_delegations_status` at `004:6` indexes `status`; these do not index cleartext identifiers directly).*

---

## 7. Deliverable 5: Explicit Statement of Unconfirmed Assumptions

In accordance with preflight doctrine, the following assumptions could not be empirically proven in preflight and are carried as explicit inspection targets for Phase 2 implementation cards:

1. **PostgreSQL RLS Query Latency Budget Impact:**
   - *Assumption:* Enabling Row-Level Security (`app.current_tenant`) and adding `tenant_id` to index composites will remain well within the 2.75ms p95 latency budget at 12,000 observations.
   - *Status:* Unconfirmed. Must be verified during `P2-2` and certified at `P2-GOV`.
2. **Dynamic Key & Salt Management for HMAC Pseudonyms:**
   - *Assumption:* OpenBao / environment secrets can supply dynamic per-tenant or global HMAC salt material without falling back to static in-code constants.
   - *Status:* Unconfirmed. `transform/secrets_scrubber.go` currently uses static fallback salt; `P2-1` must replace this with validated key material.
3. **Downstream Columnar Schema Isolation:**
   - *Assumption:* Pseudonymising `alias_value` in PostgreSQL does not break FrostDB queries in `store/frostdb.go` (which operates on observations and actor hints).
   - *Status:* Unconfirmed. Will be validated across `P2-1` and `P3-PRE`.

---

## 8. Test Execution Evidence

All required preflight checks and test suites executed with 100% pass rates:

1. **Migration Listing:**
   - Command: `ls -1 d2-signalloom/apps/signal-ingest/identity/migrations/`
   - Result: `001_identity_graph.sql`, `002_delegation_indices.sql`, `003_idempotent_seeding.sql`, `004_delegation_revocation.sql`. (0 failures).
2. **Never-Merge Trigger Inspection:**
   - Command: `rg -n -A8 'check_never_merge_alias' d2-signalloom/apps/signal-ingest/identity/migrations/001_identity_graph.sql`
   - Result: Confirmed lines 63–73 and 93.
3. **Alias Index Inspection:**
   - Command: `rg -n 'idx_aliases' d2-signalloom/apps/signal-ingest/identity/migrations/001_identity_graph.sql`
   - Result: Confirmed lines 47, 50, 53.
4. **Signal Ingest Test Suite:**
   - Command: `make test-signal-ingest`
   - Result: **PASS** (15 Go packages, all subtests green).
5. **Contract Test Suite:**
   - Command: `make demo-signalloom-api-test TIER=contract`
   - Result: **PASS** (56/56 tests passing, 0 failures).
6. **Acceptance Spec Coverage Guard:**
   - Command: `bats test/acceptance-spec-coverage.bats`
   - Result: **PASS** (7/7 checks green).

---

## 9. Preflight Verdict

**SLDP-P2-PRE is COMPLETE and PASSING.**  
Phase 2 implementation cards (`SLDP-P2-1`, `SLDP-P2-2`, `SLDP-P2-3`) have unambiguous migration sequence allocations, verified trigger definitions, concrete tenant-binding requirements, and indexed column inventories. Phase 2 is green to proceed.
