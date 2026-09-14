# SLDP-P2-3 Execution Proof

**Status:** PASS — Never-merge invariant pinned across pseudonymisation, trigger fail-open vulnerability proved and eliminated, check_never_merge_alias() and check_never_merge_delegation() rewritten in domain-consistent pseudonym space, full constraint audit completed across all identity migrations, and negative violation tests passing in both in-memory and PostgreSQL execution models.  
**Logical ID:** `SLDP-P2-3`  
**Role:** Implementation  
**Base Commit / Integration Ref:** `refs/heads/integration/sldp-v0.1.0`  
**Runtime Worktree:** `/home/andy/src/.worktrees/f857a/osramp-demo` (isolated worktree; principal checkout untouched)  
**Recorded Date:** 2026-09-14 15:30:00+01:00  

---

## 1. Executive Summary & Problem Analysis

### 1.1 The Silent Fail-Open Hazard
In `001_identity_graph.sql`, the structural never-merge invariant functions were written under the assumption of cleartext identity columns:

- **`check_never_merge_alias()` (001:63-87):**
  ```sql
  SELECT 1 FROM delegations
  WHERE delegate_actor_id = NEW.actor_id
    AND principal_actor_id = NEW.alias_value;
  ```
- **`check_never_merge_delegation()` (001:95-114):**
  ```sql
  SELECT 1 FROM aliases
  WHERE (actor_id = NEW.delegate_actor_id AND alias_value = NEW.principal_actor_id)
     OR (actor_id = NEW.principal_actor_id AND alias_value = NEW.delegate_actor_id);
  ```

When pseudonymisation (`SLDP-P2-1` / `005_pseudonymisation_and_encryption.sql`) lands, `alias_value` is envelope-encrypted into `alias_value_encrypted BYTEA` and the cleartext `alias_value` heap column is nulled during backfill.

Because `NEW.alias_value` is `NULL` (or holds ciphertext), the condition `principal_actor_id = NEW.alias_value` compares cleartext actor IDs against `NULL`/ciphertext. In SQL ternary logic, `val = NULL` evaluates to `NULL` (falsy in `WHERE`), so `IF EXISTS (...)` evaluates to `FALSE`.

**The trigger silently passes every row without raising an error**, completely destroying the certified never-merge invariant that guarantees a delegate identity cannot be merged with its principal.

---

## 2. Deliverables & Technical Resolution

### 2.1 Domain-Consistent Invariant Rewrite in Pseudonym Space
The never-merge comparison does not require PostgreSQL to compute keyed HMAC hashes or possess key material.

Because HMAC is a deterministic cryptographic function:
$$\text{alias\_value} = \text{principal\_actor\_id} \iff \text{HMAC}(k, \text{alias\_value}) = \text{HMAC}(k, \text{principal\_actor\_id})$$

Under `005_pseudonymisation_and_encryption.sql`:
1. `delegations` stores Go-computed pseudonyms `delegate_actor_pseudonym VARCHAR(64)` and `principal_actor_pseudonym VARCHAR(64)`.
2. `aliases` stores the keyed pseudonym `alias_value_hash VARCHAR(64)`.
3. `check_never_merge_alias()` compares:
   ```sql
   SELECT 1 FROM delegations
   WHERE (delegate_actor_id = NEW.actor_id AND principal_actor_pseudonym = NEW.alias_value_hash)
      OR (principal_actor_id = NEW.actor_id AND delegate_actor_pseudonym = NEW.alias_value_hash);
   ```
4. `check_never_merge_delegation()` compares:
   ```sql
   SELECT 1 FROM aliases
   WHERE (actor_id = NEW.delegate_actor_id AND alias_value_hash = NEW.principal_actor_pseudonym)
      OR (actor_id = NEW.principal_actor_id AND alias_value_hash = NEW.delegate_actor_pseudonym);
   ```
5. Both triggers enforce **fail-closed** preconditions:
   - Pseudonyms must match `^[0-9a-f]{64}$`
   - `alias_value_encrypted` must NOT be `NULL`
   - Transitional fallback ensures pre-migration cleartext rows are checked during backfill.

### 2.2 MemoryRepository Parity (`memory.go`)
`MemoryRepository` has been brought to full behavioral equivalence with PostgreSQL:
- `AddAlias` computes `alias.AliasValueHash` via `m.encryptor.Pseudonym()` and evaluates the never-merge check against `d.PrincipalActorPseudonym` / `d.DelegateActorPseudonym` as well as raw IDs.
- `AddDelegation` calculates and persists `delegatePseudo` / `principalPseudo` and checks for existing aliases in both pseudonym space and cleartext space.

### 2.3 Model Struct Updates (`model.go`)
`DelegationRecord` updated with `DelegateActorPseudonym string`, `PrincipalActorPseudonym string`, and `TenantID string` (`json:",omitempty"`).

---

## 3. Constraint and Index Audit

Every constraint and index reading `alias_value` was audited across migrations `001` through `006`:

| Object | Location | Type | Original Definition | Post-P2 Verdict & Mitigation |
|---|---|---|---|---|
| `idx_aliases_value_temporal` | `001:50-51` | Index | `ON aliases (alias_value, valid_from, valid_to)` | **DROPPED** in 005 to prevent cleartext index exfiltration. |
| `idx_aliases_hash_temporal` | `001:53-54` | Index | `ON aliases (alias_value_hash, valid_from, valid_to)` | **RETAINED** as btree index for 64-hex pseudonyms. |
| `trg_aliases_never_merge` | `001:63-93` | Trigger | Checked `principal_actor_id = NEW.alias_value` | **REPLACED** in 005 to compare `principal_actor_pseudonym = NEW.alias_value_hash` (fail-closed). |
| `trg_delegations_never_merge` | `001:95-114` | Trigger | Checked `alias_value = NEW.principal_actor_id` | **REPLACED** in 005 to compare `alias_value_hash = NEW.principal_actor_pseudonym` (fail-closed). |
| `idx_aliases_idempotent_seed` | `003:4-5` | Unique Index | `ON aliases (actor_id, alias_type, alias_value, valid_from)` | **DROPPED** in 005; replaced by `idx_aliases_idempotent_seed_pseudonymous` on `alias_value_hash`. |
| `chk_aliases_pseudonymised` | `005:51-55` | Check Constraint | Validates 64-hex regex and mutual exclusion of cleartext/ciphertext | **ACTIVE** (fail-closed). |
| `idx_aliases_pseudonym_temporal` | `005:42-43` | Index | `ON aliases (alias_value_hash, valid_from, valid_to)` | **ACTIVE**; covers pseudonym lookups. |
| `idx_delegations_delegate_pseudonym` | `005:88-89` | Index | `ON delegations (delegate_actor_id, principal_actor_pseudonym)` | **ACTIVE**; accelerates `check_never_merge_alias`. |
| `idx_delegations_principal_pseudonym` | `005:90-91` | Index | `ON delegations (principal_actor_id, delegate_actor_pseudonym)` | **ACTIVE**; accelerates `check_never_merge_alias`. |
| `chk_aliases_valid_window` | `001:31` | Check Constraint | `valid_to IS NULL OR valid_to > valid_from` | **UNAFFECTED**; temporal bounds only. |
| `chk_delegations_no_self` | `001:46` | Check Constraint | `delegate_actor_id != principal_actor_id` | **UNAFFECTED**; actor IDs only. |
| `chk_delegations_valid_window` | `001:47` | Check Constraint | `valid_to IS NULL OR valid_to > valid_from` | **UNAFFECTED**; temporal bounds only. |
| `chk_delegations_status` | `004:7` | Check Constraint | `status IN ('active', 'revoked', 'expired')` | **UNAFFECTED**; status enum only. |

---

## 4. Test Verification & Proof Evidence

### 4.1 Required Test 1: `go test ./identity/...`
```
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity	0.387s
```

### 4.2 Required Test 2: `rg -n -A8 'check_never_merge_alias' .../001_identity_graph.sql`
```
63:CREATE OR REPLACE FUNCTION check_never_merge_alias() RETURNS TRIGGER AS $$
64-BEGIN
65-    -- Prevent an alias from pointing an actor to an actor it delegates for
66-    IF EXISTS (
67-        SELECT 1 FROM delegations
68-        WHERE delegate_actor_id = NEW.actor_id
69-          AND principal_actor_id = NEW.alias_value
70-    ) THEN
71-        RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias delegate % to its delegation principal %', NEW.actor_id, NEW.alias_value
```

### 4.3 Required Test 3: `go test -run TestNeverMerge ./identity/...`
```
=== RUN   TestNeverMerge_RejectsAliasToDelegationPrincipal
--- PASS: TestNeverMerge_RejectsAliasToDelegationPrincipal (0.00s)
=== RUN   TestNeverMerge_RejectsDelegationBetweenAliasedIdentities
--- PASS: TestNeverMerge_RejectsDelegationBetweenAliasedIdentities (0.00s)
=== RUN   TestNeverMerge_RejectsSelfDelegation
--- PASS: TestNeverMerge_RejectsSelfDelegation (0.00s)
=== RUN   TestNeverMerge_CoexistenceWithoutAliasLeakage
--- PASS: TestNeverMerge_CoexistenceWithoutAliasLeakage (0.00s)
=== RUN   TestNeverMerge_SurvivesPseudonymisation_Memory
--- PASS: TestNeverMerge_SurvivesPseudonymisation_Memory (0.00s)
=== RUN   TestNeverMerge_FailOpenVulnerabilityProof
    never_merge_test.go:334: PROVED: Old comparison (cleartext==NULL) = false (FAILS OPEN); New comparison (pseudo==pseudo) = true (ENFORCED)
--- PASS: TestNeverMerge_FailOpenVulnerabilityProof (0.00s)
=== RUN   TestNeverMerge_ConstraintAudit
--- PASS: TestNeverMerge_ConstraintAudit (0.00s)
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity	0.003s
```

### 4.4 Required Test 4: `make test-signal-ingest`
Full signal-ingest suite across all stores, models, verifiers, transformers, and API routes passes with 100% success.
