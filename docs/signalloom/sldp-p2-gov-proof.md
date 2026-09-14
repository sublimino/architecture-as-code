# SLDP-P2-GOV — Phase 2 Governor Certification

**Status:** FAIL — the identity privacy contract is **NOT** frozen. Phase 2's three controls are individually correct and individually proven, but **no tree exists in which they are simultaneously demonstrable.** P2-1 and P2-2 were developed in parallel from the same base, merged without a textual conflict, and the merged result fails 31 of the 39 live assertions that are the only evidence either control works.

**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/sldp-v0.1.0/governor`
**Branch:** `integration/sldp-v0.1.0`
**Certified tree:** `de00dbc49097cae004e088833b07705d98e241fd`
**Date:** 2026-09-14 15:39:46+01:00

---

## 1. Verdict

Phase 2 does not pass. The defect is not in any one card. Every implementation card did what it was asked, tested it properly against a real PostgreSQL server, and recorded honest evidence. The defect is in the **seam**, and it is precisely the seam this card was told to examine:

> *"Verify the tenant source agrees between P1-1's principal binding and P2-2's database policy, since two cards independently deciding where tenant identity comes from is how the estate ended up with three identity schemes."*

That is what happened, one layer lower than predicted — not between phases, but between two cards inside this phase.

---

## 2. The finding, bisected

### 2.1 Parentage — the cards never saw each other

```
$ git merge-base --is-ancestor fd9a4aa8 c16599af
NO - P2-2 was developed WITHOUT P2-1 in its tree

$ git rev-parse --short c16599af^@   ->  6baa5f1c
$ git rev-parse --short fd9a4aa8^@   ->  6baa5f1c
$ git rev-parse --short 8b808dbe^@   ->  fd9a4aa8 c16599af
```

Both implementation cards branched from `6baa5f1ce51185ebfabd24187e809dfc93da0fa9` (the P2-PRE integration commit). Confirmed by object presence rather than by inference:

```
$ git cat-file -e c16599af:.../identity/pseudonym.go                        -> ABSENT
$ git cat-file -e c16599af:.../migrations/005_pseudonymisation_and_encryption.sql -> ABSENT
```

P2-2 was written, run and proven against a tree that contained **no pseudonymiser and no migration 005**. Symmetrically, P2-1 was written against a tree that contained **no `tenant_id NOT NULL` column**. Merge `8b808dbe946e6ece234b8cab0125311b425358db` joined them with **zero textual conflicts**. Git was correct; the result is semantically broken.

### 2.2 Measured, both sides, same server

All runs against PostgreSQL 16.14 (`postgres:16-alpine`), fresh database per run, `INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true`, Go 1.26.2.

| Suite | Invocation | At its own commit | At phase tip `de00dbc4` |
| :--- | :--- | :--- | :--- |
| P2-2 hostile-tenant | `go test -run TestTenant ./identity/...` | **28 PASS / 0 FAIL** @ `c16599af` | **1 PASS / 27 FAIL** |
| P2-1 live-Postgres alias | `go test -run TestAliasPG ./identity/...` | **11 PASS / 0 FAIL** @ `fd9a4aa8` | **4 PASS / 4 FAIL** |
| Both together (the intersection) | `-run 'TestTenant\|TestAliasPG'` | — | **5 PASS / 31 FAIL** |

The repository's own sanctioned command reproduces it exactly:

```
$ make test-identity-rls-live
PASS=1 FAIL=27 SKIP=0
make: *** [Makefile:588: test-identity-rls-live] Error 1
```

against `docs/signalloom/sldp-p2-2-proof.md:414`, which records `**28/28 PASS**, exit 0, PostgreSQL 16.14`. **That proof was true when written.** It is no longer true of the tree it now sits in.

### 2.3 The two mechanisms

Each direction of the merge breaks the other card's control.

**P2-2's writes now hit P2-1's pseudonymiser with no tenant** — 27 failures, one message:

```
tenant_live_test.go:256: seed tenant tenant-alpha: failed to pseudonymise alias value:
  identity: pseudonym tenant identifier is required; an empty tenant would merge tenant
  correlation domains
```

P2-2's seeding path was authored when the alias write path did not pseudonymise. After the merge it does, and `PseudonymKeyRing.Pseudonym(tenantID, value)` refuses an empty tenant — correctly, and by design (`pseudonym.go:114`). The refusal is the control working. Nothing supplies it the tenant that P2-2 already knows.

**P2-1's writes now hit P2-2's NOT NULL constraint** — 4 failures, one message:

```
alias_pg_live_test.go:360: CreateActor(actor-delegate): failed to create actor:
  pq: null value in column "tenant_id" of relation "actors" violates not-null constraint (23502)
```

Migration 006 made `actors.tenant_id NOT NULL`. P2-1's live harness creates actors without one.

Both refusals are *correct behaviour by the newly added control*. Neither card is wrong. The contract between them was never written down, so neither card could satisfy it.

---

## 3. Why the required test passes anyway — stated, not satisfied

The card's Required Test is:

```
cd d2-signalloom/apps/signal-ingest && go test ./identity/...
```

It returns **rc=0**. It does so because **every live assertion skips when no DSN is set.** This is an acceptance criterion that passes whether or not the control works, which this card's instructions require me to **state rather than satisfy**. I am stating it.

The suites themselves say so in their own words, and both are honest about it — this is good engineering that the governor gate then failed to read:

- `alias_pg_live_test.go:44` — `TestAliasPG_GateIsHonest` always runs and logs `COVERAGE GAP: SLDP_PG_DSN is unset, so every live-Postgres assertion in this file was SKIPPED.`
- `tenant_live_test.go:76` — `SKIPPING LIVE ROW-LEVEL-SECURITY SUITE … These tests are the only evidence that tenant isolation is enforced rather than merely declared; the text assertions in tenant_test.go cannot substitute.`

A phase gate whose required command is satisfied by a run in which zero live tests executed cannot distinguish this phase from a phase in which the RLS policies do not exist. **The gate needs the live invocation, not the bare one.**

---

## 4. Certification of each required property

| # | Required property | Verdict | Evidence |
| :-- | :--- | :--- | :--- |
| 1 | No bare SHA-256 of a personal identifier in the identity package | **PASS** | Every `sha256` site enumerated. `pseudonym.go` uses HKDF + HMAC-SHA256, never a bare digest. `encryption.go:163` stretches *key material*, not identifiers. `claim_verifier.go:248` digests `claimID:delegate:principal:violationType:UnixNano()` to mint an observation ID — time-salted, truncated to 8 bytes, non-stable, therefore not a correlatable pseudonym. `transform/redactor.go:107` is a redaction marker, out of the identity package. |
| 2 | Every identity table carries `tenant_id` with an enforced RLS policy | **PASS (declaration)** / **FAIL (enforcement at tip)** | `006_tenant_isolation_rls.sql` does `ENABLE` **and `FORCE`** RLS on `actors`, `aliases`, `delegations`, `identity_tenant_backfill_report`, with 6 policies. Enforcement was demonstrated live at `c16599af` and cannot be demonstrated at `de00dbc4`. |
| 3 | Cross-tenant read refused **at the database layer** | **PASS at `c16599af` only** | `TestTenantRLS_ForgedClaimCannotReadAnotherTenant` + `..._CannotWriteIntoAnotherTenant` passed at `c16599af`. Falsification control fired: `tenant_live_test.go:1215: falsified correctly: 1 cross-tenant rows visible with RLS off, 0 with it on` — the criterion **can** fail, so it is not vacuous. Both tests FAIL at the tip. |
| 4 | Application role is neither owner nor `BYPASSRLS` | **PASS at `c16599af` only** | `tenant_live_test.go:279: posture: user=signal_identity_app super=false bypass=false policies=6` |
| 5 | Never-merge invariant rejects a **genuine** violation post-change | **FAIL — not demonstrable at tip** | `TestAliasPG_TriggerRejectsUnpseudonymisedInsert` and `TestAliasPG_NeverMergeTriggerStillFiresInPseudonymSpace` both abort in setup at the tip. They passed at `fd9a4aa8` — a tree with no tenant isolation. The invariant is proven only on a tree that is not the phase deliverable. |
| 6 | Migration sequence numbers reserved by P2-PRE are the ones used | **PASS** | P2-PRE reserved `005` → P2-1 and `006` → P2-2 (`sldp-p2-pre-proof.md:60-61`). Files on disk are exactly `005_pseudonymisation_and_encryption.sql` and `006_tenant_isolation_rls.sql`. No collision. |
| 7 | Rollback for each migration **actually runs** | **PARTIAL — 005 yes, 006 has none** | 005 rollback ran live at `fd9a4aa8`: `alias_pg_live_test.go:255: rollback data pass: scanned=1 restored=1` and `:289: rollback verified: cleartext restored, 2/2 indexes rebuilt, ciphertext column dropped`. **Migration 006 ships no rollback file at all** — `ls migrations/` yields one `*_rollback.sql`, for 005. An RLS migration with no reverse is a one-way door. |
| 8 | No code path outside `identity/` constructs an alias directly | **PASS** | Repo-wide grep for `Alias{`, `.Alias =`, `NewAlias`, `UpsertAlias`, `InsertAlias`, `INSERT INTO aliases` across `*.go`/`*.sql` excluding `/identity/` returns **no output**. |
| 9 | Tenant source agrees between principal binding and database policy | **PASS (design)** / **FAIL (wiring)** | `api/tenant_bridge.go` is a single, total, deliberately dumb conversion point: it reads only the `TenantContext` that `ProtectedRouter.authorize` placed on the request context, consults no header/query/path/body, and fails closed to `ok=false`. The design is right. The *pseudonymisation* path does not receive that tenant — finding 2.3. |
| 10 | Adversarial-dictionary and hostile-tenant suites run **together** | **RUN — 5 PASS / 31 FAIL** | Run 3 above. The card was right that the interesting failures are at the intersection; they are also, independently, at each suite alone. |

---

## 5. Merge status

**No merge was performed by this governor, and none was required.** All three implementation cards were already present on `integration/sldp-v0.1.0` when this card started:

```
de00dbc4 feat(identity): pin never-merge invariant across pseudonymisation (SLDP-P2-3)
8b808dbe Merge commit 'c16599af' into integration/sldp-v0.1.0
c16599af feat(signalloom): enforce tenant isolation … row-level security (SLDP-P2-2)
fd9a4aa8 feat(signal-ingest): keyed HMAC pseudonyms and envelope-encrypted alias values (SLDP-P2-1)
```

The governor worktree was clean at start (`git status --porcelain` empty) and the branch tip is unchanged by this certification apart from this document. **I did not attempt to repair P2-1 or P2-2.** Repairing them is implementation work owned by those cards; this card's role boundary is *"integrate approved phase work only"*, and the work is not approvable.

---

## 6. Assumed rather than tested

Recorded so a later reader can tell a proven property from an accepted one.

1. **Actor IDs are not direct personal identifiers.** Finding 4.1 clears `claim_verifier.go:248` on the basis that `PrincipalActorID` is an internal graph identifier. If actor IDs are ever derived from an email or username, that digest becomes a bare hash of a personal identifier. Not tested — no data-classification source exists in the repo.
2. **The `NoopEncryptor` warning is test-harness-only.** Every live run emitted `SECURITY WARNING: running in development mode with NoopEncryptor (insecure passthrough encryption)`. I set `INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true` because the sanctioned Makefile target does. I did **not** verify that production refuses to start with a passthrough encryptor; P1-2 claims that and I accepted it without re-probing.
3. **Migration 006 is idempotent under repeated application.** `TestTenantRLS_MigrationIsIdempotentAndDoesNotDuplicateTheReport` asserts it and passed at `c16599af`; it fails at the tip for the seam reason, so at the tip idempotency is unverified, not disproven.
4. **The 005 rollback restores semantically, not just structurally.** The live assertion checks cleartext restored, indexes rebuilt, ciphertext column dropped. It does not check that restored cleartext equals the original input for rows written *after* the forward migration.
5. **`go.sum` / dependency integrity.** Not audited this run.

---

## 7. Findings passed downstream to Phase 3, unresolved

Named explicitly so Phase 3 inherits them deliberately rather than by omission.

- **F1 (blocking).** The identity layer at `de00dbc4` has no demonstrated tenant isolation and no demonstrated never-merge enforcement. P3-1 removes cleartext identity from columnar segments and will need a working `(tenant, pseudonym)` pair from this layer. Building on it now means building on an untested binding.
- **F2 (blocking).** Migration `006_tenant_isolation_rls.sql` has no rollback script. Every other stateful change in this phase has one.
- **F3 (process).** The phase gate's required command (`go test ./identity/...`) is satisfied by a run in which zero live tests execute. Until the gate requires the live invocation, a governor can certify a phase whose only real evidence never ran. This is the mechanism that let the defect reach the governor at all.
- **F4 (process).** Parallel implementation cards in the same phase were allowed to branch from a common base and merge without any cross-card integration check. P2-PRE correctly de-conflicted *migration sequence numbers* and did not de-conflict *the write path they share*. Sequence-number reservation is necessary and was not sufficient.
- **F5 (inherited, out of scope).** `kanban-check.sh doctor` reports UNHEALTHY: 29 tasks finished in under 5 s. **Zero of them are SLDP tasks** (agents: `cpai-opencode`, `cpai-opencode-deep`, `cpai-opencode-fast`, `antigravity`, `unknown`). This is a pre-existing board-global condition. Clearing it would require editing historical task records, which the Governor authority boundary forbids. Not remediated; recorded.

---

## 8. Remediation shape (for the cards that own it, not performed here)

The smallest correct fix is a **contract**, not a patch to either suite:

1. Decide the single tenant source for the alias write path — `api/tenant_bridge.go` already is that source; the repository's alias write must thread the claim's `TenantID` into `PseudonymKeyRing.Pseudonym`.
2. Make the harnesses model it: P2-1's `CreateActor` calls must carry a tenant; P2-2's seed must carry the tenant it already has into pseudonymisation.
3. Add `006_tenant_isolation_rls_rollback.sql`.
4. Change the phase gate to the live invocation so the next governor cannot repeat this.

Re-certification requires `make test-identity-rls-live` **and** the `TestAliasPG` suite green **on the same tree**, run together.

---

## 9. Commands run

```
go version                                   -> go1.26.2 linux/amd64
docker info --format '{{.ServerVersion}}'    -> 29.7.1
docker run postgres:16-alpine                -> PostgreSQL 16.14
go test ./identity/...                       -> ok (rc=0, every live test skipped)
go test -run TestTenant   @ c16599af         -> 28 PASS / 0 FAIL
go test -run TestAliasPG  @ fd9a4aa8         -> 11 PASS / 0 FAIL
go test -run TestTenant   @ de00dbc4         ->  1 PASS / 27 FAIL
go test -run TestAliasPG  @ de00dbc4         ->  4 PASS / 4 FAIL
go test -run 'TestTenant|TestAliasPG' @ de00dbc4 -> 5 PASS / 31 FAIL
make test-identity-rls-live                  -> rc=2, 1 PASS / 27 FAIL
scripts/kanban-check.sh doctor               -> rc=1, UNHEALTHY (0 SLDP tasks implicated)
```

Temporary artefacts removed: bisect worktree `gov-bisect` and container `sldp-p2-gov-pg`.

---

**SLDP-P2-GOV verdict: FAIL.** The identity privacy contract is not frozen. Three correct controls, two honest proofs, one clean merge, and a phase tip on which none of it can be shown to work.
