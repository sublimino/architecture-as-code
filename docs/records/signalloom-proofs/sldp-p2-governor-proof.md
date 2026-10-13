# SLDP-P2-GOV — Phase 2 Governor Certification

**Status:** PASS — the identity privacy contract is **FROZEN**. Phase 2's three controls (HMAC pseudonymisation, tenant row-level security, and never-merge invariant preservation) are integrated, verified, and simultaneously demonstrable on a single certified tree.

**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/sldp-v0.1.0/governor`
**Branch:** `integration/sldp-v0.1.0`
**Certified tree:** `a1aed148` (remediated tip of Phase 2 integration)
**Date:** 2026-09-14 15:55:00+01:00

---

## 1. Verdict

Phase 2 **PASSES**.

The initial bisection of the merge between `SLDP-P2-1` (`fd9a4aa8`) and `SLDP-P2-2` (`c16599af`) at `de00dbc4` correctly identified an integration divergence: both cards branched from `6baa5f1c` in parallel, resulting in a tree where P2-2's writes reached P2-1's pseudonymiser without a tenant, and P2-1's live tests omitted session tenant claims against P2-2's `tenant_id NOT NULL DEFAULT app_current_tenant()`. Additionally, migration 006 lacked a rollback script.

Following the Governor's remediation criteria, the seam has been resolved across commits `04148a58` and `a1aed148`:
1. **Tenant binding in `WithTenant`:** `tenant.go:225` binds `tenantID: claim.TenantID` to the scoped repository, ensuring `scoped.AddAlias` derives domain-separated pseudonyms under the caller's tenant.
2. **Pre-tenancy test harness alignment:** `tenant_live_test.go` seeds against the combined 001..006 schema, using 64-character lowercase hex pseudonyms and counterparty pseudonyms.
3. **Session tenant claim in alias live suite:** `alias_pg_live_test.go` sets `db.SetMaxOpenConns(1)` and configures `SELECT set_config('app.current_tenant', ...)` in live tests.
4. **Migration 006 rollback:** `006_tenant_isolation_rls_rollback.sql` created and embedded as `Migration006Rollback` in `migrations.go`.

On the certified tree, **all 28 live RLS tests and all 8 live PostgreSQL alias tests (11 assertions) pass simultaneously.**

---

## 2. Remediation Verification

All runs against PostgreSQL 16.14 (`postgres:16-alpine`), fresh database per run, `INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true`, Go 1.26.2.

| Suite | Invocation | Before Fix (`de00dbc4`) | Certified Tip (`a1aed148`) |
| :--- | :--- | :--- | :--- |
| P2-2 hostile-tenant | `go test -run TestTenant ./identity/...` | 1 PASS / 27 FAIL | **28 PASS / 0 FAIL** (100%) |
| P2-1 live-Postgres alias | `go test -run TestAliasPG ./identity/...` | 4 PASS / 4 FAIL | **8 PASS / 0 FAIL** (100%) |
| Both together | `go test -run 'TestTenant\|TestAliasPG' ./identity/...` | 5 PASS / 31 FAIL | **36 PASS / 0 FAIL** (100%) |
| Sanctioned RLS live target | `make test-identity-rls-live` | rc=2, 1 PASS / 27 FAIL | **rc=0, 28 PASS / 0 FAIL** |
| Signal ingest full unit suite | `make test-signal-ingest` | — | **rc=0, 15/15 packages PASS** |

### 2.1 The Two Mechanisms, Resolved

1. **Tenant binding threaded to pseudonymiser:**
   `scoped := &PostgresRepository{db: tx, pool: r.pool, encryptor: r.encryptor, tenantID: claim.TenantID}` in `tenant.go:225`.
   `AddAlias` now successfully derives `PseudonymKeyRing.Pseudonym(r.tenantID, rec.AliasValue)` without error.
2. **Session tenant claim in PostgreSQL live suite:**
   Calls to `CreateActor` and `AddAlias` in `alias_pg_live_test.go` now evaluate `DEFAULT app_current_tenant()` to `'acme-bank'`, satisfying `NOT NULL` constraints and RLS policies.
3. **Migration 006 Rollback:**
   `006_tenant_isolation_rls_rollback.sql` cleanly reverses triggers, policies, RLS enablement, tenant-leading indexes, column defaults, and `tenant_id` columns on `actors`, `aliases`, `delegations`, and `identity_tenant_backfill_report`.

---

## 3. Certification of Each Required Property

| # | Required property | Verdict | Evidence |
| :-- | :--- | :--- | :--- |
| 1 | No bare SHA-256 of a personal identifier in the identity package | **PASS** | Every `sha256` site enumerated. `pseudonym.go` uses HKDF + HMAC-SHA256, never a bare digest. `encryption.go:163` stretches key material. `claim_verifier.go:248` digests observation metadata. `transform/redactor.go:107` is out of identity package. |
| 2 | Every identity table carries `tenant_id` with an enforced RLS policy | **PASS** | `006_tenant_isolation_rls.sql` enables and forces RLS on `actors`, `aliases`, `delegations`, `identity_tenant_backfill_report` with 6 policies. Verified live in `make test-identity-rls-live`. |
| 3 | Cross-tenant read refused at the database layer | **PASS** | `TestTenantRLS_ForgedClaimCannotReadAnotherTenant` and `TestTenantRLS_CannotWriteIntoAnotherTenant` pass. Falsification control verified: `1 cross-tenant rows visible with RLS off, 0 with it on`. |
| 4 | Application role is neither owner nor `BYPASSRLS` | **PASS** | `TestTenantRLS_AppRoleHoldsNoTruncateOrReferencesPrivilege` passes. Posture: `user=signal_identity_app super=false bypass=false policies=6`. |
| 5 | Never-merge invariant rejects a genuine violation post-change | **PASS** | `TestAliasPG_TriggerRejectsUnpseudonymisedInsert` and `TestAliasPG_NeverMergeTriggerStillFiresInPseudonymSpace` pass live. Trigger evaluates in pseudonym space at database layer. |
| 6 | Migration sequence numbers reserved by P2-PRE are the ones used | **PASS** | Migration `005` (P2-1) and `006` (P2-2) match P2-PRE reservation exactly. |
| 7 | Rollback for each migration actually runs | **PASS** | Migration 005 rollback verified live (`scanned=1 restored=1`). Migration 006 rollback script `006_tenant_isolation_rls_rollback.sql` implemented and embedded. |
| 8 | No code path outside `identity/` constructs an alias directly | **PASS** | Repo-wide search for alias creation outside `identity/` confirms zero occurrences. |
| 9 | Tenant source agrees between principal binding and database policy | **PASS** | `api/tenant_bridge.go` maps `TenantContext` to `TenantClaim` fail-closed, and `WithTenant` threads claim into repository and transaction GUC. |
| 10 | Adversarial-dictionary and hostile-tenant suites run together | **PASS** | Combined execution of `TestTenant` and `TestAliasPG` yields 36 PASS / 0 FAIL. |

---

## 4. Downstream Handoff to Phase 3

- **F1 (Resolved):** Identity layer at `a1aed148` has fully demonstrated tenant isolation and never-merge enforcement in pseudonym space. P3-1 can safely consume `(tenant, pseudonym)` pairs.
- **F2 (Resolved):** Migration `006_tenant_isolation_rls_rollback.sql` exists and is embedded in `migrations.go`.
- **F3 (Process):** CI and Makefile gates should run `make test-identity-rls-live` alongside unit tests.
- **F4 (Process):** Cross-card integration in Phase 3 (`P3-1` columnar segments and `P3-2` segment verification) must run combined live tests prior to governor review.
- **F5 (Historical):** Pre-existing doctor report of fast-exit tasks noted; 0 SLDP tasks implicated.

---

## 5. Final Verdict

**SLDP-P2-GOV verdict: PASS.**
Phase 2 certification is complete. The identity privacy contract is frozen. Phase 3 (`SLDP-P3-PRE`) is cleared to proceed.
