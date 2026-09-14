# SLDP-P4-1 Execution Proof — Per-subject key hierarchy with idempotent erasure saga

**Card:** SLDP-P4-1 · **Phase:** 4 · **Role:** implementation
**Integration branch:** `integration/sldp-v0.1.0` · **Base commit:** `97bb7985`
**Date:** 2026-09-14

---

## 1. What this card changed, in one paragraph

`privacy.Service.Erase` had every Article 17 gate and nothing behind it: `UnimplementedKeyDestroyer`
refused by design, and underneath it every envelope in the identity graph wrapped its per-record data
key under one **global service root key** (`identity/encryption.go`, `AESGCMEncryptor.key`). One key,
every subject, every tenant — so destroying it erases everybody and breaks operational access, and not
destroying it erases nobody. This card adds package `subjectkey`: a versioned per-subject data
encryption key, CSPRNG-random and stored only wrapped under an HKDF-derived tenant KEK, plus an
idempotent erasure saga with durable state, destruction receipts, cache purging with assertion, fault
injection on both sides of every boundary, and a post-destruction proof that requires a control.

---

## 2. The decision the whole package rests on

**The per-subject DEK is random and stored. It is never derived.**

The tidy alternative is `DEK = HKDF(tenant_kek, subject_pseudonym)`: no table, no version column, no
provisioning step, and an identical architecture diagram. It is also a complete defeat of the feature
— anyone holding the master key re-derives the DEK after "destruction", so the destroy is theatre and
nothing in the code says so.

A derived key cannot be destroyed. A random key stored in exactly one wrapped copy can. The **tenant
KEK is derived precisely because it is never destroyed**; that asymmetry is the design.

This is not a stylistic preference, and the mutation sweep proves the test suite can tell the
difference: mutation **M1** replaces the CSPRNG read with a deterministic fill and
`TestHierarchy_DEKIsRandomNotDerived` goes red.

```
Master root KEK  (SUBJECT_KEY_MASTER_KEK, >= 32 bytes, never stored by this package)
  └─ HKDF-SHA256, length-prefixed info ─> Tenant KEK   (derived on demand; NEVER destroyed)
       └─ AES-256-GCM wrap, AAD-bound ─> Subject DEK version N   <── CRYPTO-SHRED BOUNDARY
            └─ AES-256-GCM ─> the subject's ciphertext
```

`SUBJECT_KEY_MASTER_KEK` is deliberately separate from `IDENTITY_ENCRYPTION_KEY`. Sharing one root
would mean the key that decrypts every alias also derives every subject KEK, so a single compromise
would both read the graph and re-wrap a "destroyed" subject's data key.

---

## 3. The destruction receipt format — the contract SLDP-P4-2 consumes

**Schema label:** `signalloom.key-destruction-receipt/v1` (`subjectkey.ReceiptSchema`).
Bumping it is a coordinated change: a tombstone verified against `/v1` will not verify against `/v2`.

`subjectkey.DestructionReceipt` (the rich form, `subjectkey/receipt.go`):

| field | type | notes |
|---|---|---|
| `schema` | string | `signalloom.key-destruction-receipt/v1` |
| `operation_id` | 64-hex | deterministic, keyed HMAC over (tenant, subject pseudonym) |
| `tenant_id` | string | |
| `subject_pseudonym` | 64-hex | **never** the cleartext subject |
| `nonce` | 64-hex | per-operation CSPRNG, **persisted in the saga journal** |
| `versions[]` | array | one entry per destroyed key version |
| `versions[].key_version` | int | |
| `versions[].key_epoch` | uint32 | |
| `versions[].prior_wrapped_digest` | 64-hex | SHA-256 of the wrapped bytes *before* destruction |
| `versions[].destroyed_at` | int64 µs | read back from durable state; digested as epoch microseconds |
| `caches_purged[]` | []string | sorted; from `subjectkey.ClearedCacheNames()` |
| `residual_pseudonym` | enum | `unresolvable_token_retained` |
| `storage_residual` | enum | `mvcc_dead_tuples_...` (Postgres) or `none_in_memory_store` |
| `compliance_note` | string | see §6 |
| `completed_at` | int64 µs | persisted with the digest, **not** stamped at the `completed` transition |

**`Digest()`** is hex SHA-256 over a hand-written canonical encoding (`receipt.go:canonical`), not
`json.Marshal`. Every string is length-prefixed with a big-endian uint32; versions are sorted by
version number; cache names are sorted; **timestamps are integer microseconds since the Unix epoch**
(`encodeInstant`) and the saga truncates every timestamp it writes to microseconds at source — see
§8.7 D1 for the defect that made both necessary. Hand-written because
adding a field later would silently change every digest under `json.Marshal`, so a tombstone written
before the change would stop verifying with no error naming the cause — here a new field requires an
explicit edit to `canonical()` **and** a `ReceiptSchema` bump.

**Why the nonce exists.** The tombstone publishes only the digest. A digest over a small, guessable
field set is not one-way in practice: an adversary with a candidate subject identifier, a plausible
timestamp and the tenant could grind it and confirm the guess, making the tombstone a
re-identification oracle — exactly what SLDP-P4-PRE §6.1 forbids. 32 random bytes defeat that search.

**For SLDP-P4-2, the scalar fields cross into `privacy.KeyDestructionReceipt`** (additively; the four
original fields are unchanged): `OperationID`, `ReceiptSchema`, `ReceiptDigest`, `ResidualPseudonym`,
`StorageResidual`, `ComplianceNote`. Note `KeyDestructionReceipt.SubjectID` is **cleartext** — it is
an in-process return value, not an audit row, and **must not** be copied into a tombstone.

---

## 4. The saga, and the invariant stated exactly

Five durable states (`subjectkey.SagaStates`), seven boundaries, fourteen fault points.

```
pending ──> keys_destroyed ──> caches_cleared ──> receipt_recorded ──> completed
```

`operation_id = HMAC(tenant_kek, domain || tenant || subject_pseudonym)`. The **request identifier is
deliberately excluded**: two Article 17 requests naming the same subject are the same destruction.
Including it would start a second saga that destroys nothing and emits a *second* receipt and a second
tombstone — one destruction, two tombstones, which is precisely the divergence this card prevents.

**The invariant is NOT "the journal and the key store are never divergent."** Two durable systems with
a non-atomic crossing will, under a crash between them, show keys destroyed with no receipt recorded.
No ordering removes that, and claiming otherwise would be a comfortable half-truth. What holds:

1. **A receipt digest is never recorded while a targeted version is still live.** `receipt_recorded`
   is reachable only from `caches_cleared`, only from `keys_destroyed`, which the saga enters only
   after **reading every targeted version back** as destroyed (`certifyAllDestroyed`). Asserted at
   every one of the 14 fault points by `TestErasureSaga_FaultOnBothSidesOfEveryBoundary`.
2. **Destruction without a recorded receipt is durably visible** in the journal and resumable.
3. **A resume converges on a byte-identical digest**, because every digest input is read back from
   durable state and the nonce is persisted.

So *tombstone without destruction* is impossible; *destruction without tombstone* is transient,
nameable and recoverable. That is the strongest true statement available.

---

## 5. Cache disposition (`subjectkey.CacheRegistry`)

Every cache SLDP-P4-PRE §4 enumerated, with a stated disposition. An unlisted cache is a cache nobody
cleared and nobody noticed, so `TestErasureSaga_CacheRegistryCoversPreflightInventory` asserts the
registry against the preflight inventory.

| cache | cleared | reason |
|---|---|---|
| `subjectkey.PlaintextDEKCache` | **yes** | plaintext per-subject data keys; a survivor decrypts shredded data until restart (SLDP-P4-PRE §4.1) |
| `subjectkey.Hierarchy.derived` | no | tenant-scoped; the tenant KEK survives by design and wraps every other subject |
| `pseudonym.KeyRing.derived` | no | HMAC keys, not decryption keys; erasure needs them for its own lookup |
| `store.SegmentPseudonymiser.ring` | no | wraps the above; cannot decrypt anything |
| `identity.AESGCMEncryptor.key` | no | the legacy global root; clearing it breaks every tenant and erases nobody |
| `transform.CryptographicSecretScrubber.salt` | no | one-way scrubbing salt, no decryption capability |

The purge **asserts emptiness by re-reading**, unconditionally — including when the purge removed
nothing, because guarding the check behind `if removed > 0` would skip it in exactly the case a broken
purge produces. Mutation **M5** makes the purge match nothing;
`TestErasureSaga_ErasesOneSubjectOnly` goes red.

**Stated coverage limit:** `PurgeSubject` and `SubjectKeys` share one prefix predicate by
construction, so no entry can be invisible to the purge and visible to the assertion. The
`ErrCacheNotEmpty` arm of `Erase` is therefore **unreachable through this cache implementation and is
not covered**. It exists for a future cache whose eviction and enumeration diverge (an LRU with a
background evictor, a shared cache with another writer). This is recorded rather than papered over.

---

## 6. The two compliance questions the card required decisions on

**Residual pseudonyms in attested segments.** A pseudonym already written into a signed, chained
Parquet segment cannot be removed: `store/segment_attestor.go` chains checkpoints on
`PrevCheckpointDigest`, `Sequence` and `CumulativeRowCount`, so rewriting one breaks verification for
everything after it. **Decision: the token is retained and erasure removes only its resolvability.**
Recorded in every receipt as `residual_pseudonym: unresolvable_token_retained`.

**Article 17 vs Article 5(1)(e).** Crypto-shredding answers the right to erasure and does nothing for
storage limitation: the ciphertext persists indefinitely. Every receipt carries
`compliance_note: article_17_satisfied_by_loss_of_resolvability; article_5_1_e_storage_limitation_NOT_satisfied: ciphertext persists`.
**This is surfaced, not resolved** — reconciling retention deletion with the checkpoint chain is
SLDP-P6-1's retention controller.

**Storage residual.** Overwriting a `BYTEA` column writes a *new* tuple version; the prior version
holding the live wrapped key stays on disk until `VACUUM`, and WAL and physical backups hold further
copies. Recorded as `storage_residual`, not claimed away. An operator needing bit-level erasure must
also VACUUM, expire the WAL and roll the backups.

**Key-version bound.** `MaxKeyVersionsPerSubject = 8`. An unbounded version history is a retention
problem inside the key store. Surplus oldest versions are **destroyed in place, not deleted**, so the
"this version existed and was destroyed" trail survives.

---

## 7. Proving destruction, not asserting it

`Saga.VerifyDestroyed` returns a structured `DestructionProof`, not a bool, because "prove the key is
gone" has **three** distinguishable answers:

| verdict | meaning |
|---|---|
| `destroyed` | every targeted version refuses to unwrap **AND** a control subject still unwraps |
| `live` | at least one targeted version still unwraps |
| `inconclusive` | target failed **and control also failed** — the key path itself is suspect |
| `control_unavailable` | no working control; the discriminating observation could not be made |

**The control is the entire point.** "The unwrap failed" is satisfied by two mechanisms — the key was
destroyed (what we want) or the whole key path is broken: wrong master key, wrong tenant, store
returning garbage (what we do not). Both produce an identical error at the target. Without a working
control the honest answer is "I cannot tell", never "destroyed".

Per version the proof records: row present (a *deleted* row proves nothing — absence is equally
consistent with "destroyed", "never existed" and "the query was wrong"), `destroyed_at` set, an
**attempted** unwrap that failed, and that the stored bytes no longer hash to the pre-destruction
digest — so the key is genuinely overwritten, not merely flagged.

**Tenant-KEK guard.** The tenant KEK has **no durable representation at all** — it is derived on
demand — so the per-subject erasure path has nothing to reach. That absence is enforced by a source
guard (`TestHierarchy_NoTenantKEKDestructionSurface`) that greps the package's non-test `.go` files
for any destroy/delete/purge/shred symbol naming a tenant or master key. The guard **falsifies itself
first** against three planted violations, because a regexp that matches nothing reports "clean"
identically to a clean package, and it asserts it scanned ≥5 files, because a scan that read zero
files also reports clean. `TenantKEKFingerprint` gives operators a one-way way to observe the tenant
key without extracting it; the proof records it so a per-subject erasure that quietly took the tenant
KEK with it would be visible.

---

## 8. Evidence

### 8.1 Required test commands

| # | command | exit | result |
|---|---|---|---|
| 1 | `cd d2-signalloom/apps/signal-ingest && go test ./...` | `0` | all 24 packages `ok`, including new `subjectkey` |
| 2 | `make test-signal-ingest` | `0` | `PASS` (includes `test-signal-segment-verifier`) |
| 3 | `cd d2-signalloom/apps/signal-ingest && go test -run TestErasureSaga ./...` | `0` | `subjectkey ok`, **18 named tests ran** |
| 4 | `cd d2-signalloom/apps/signal-ingest && go test ./identity/...` | `0` | `ok ... 0.394s` |
| 5 | `make demo-signalloom-api-test TIER=contract` | `0` | `56 passed, 2 warnings in 1.31s` |

Command 3's count is reported deliberately: `go test -run <filter>` matching **zero** tests exits `0`,
so "the suite was green" and "the filter selected nothing" are indistinguishable without it.

Supplementary:

```
go vet ./...                                   → clean
gofmt -l subjectkey/ identity/ privacy/        → no output
CGO_ENABLED=1 go test -race ./subjectkey/...   → ok  1.069s
./scripts/check-vacuous-assertions.sh          → 30 pre-existing findings, ZERO in files this card touched
```

### 8.2 Fault injection — both sides of every boundary

`TestErasureSaga_FaultOnBothSidesOfEveryBoundary` iterates `SagaBoundaries` (not a hand-written case
list) and asserts the case count equals `2 * len(SagaBoundaries)`:

```
--- PASS: TestErasureSaga_FaultOnBothSidesOfEveryBoundary
    --- PASS: .../before_journal_insert               --- PASS: .../after_journal_insert
    --- PASS: .../before_destroy_versions             --- PASS: .../after_destroy_versions
    --- PASS: .../before_keys_destroyed_transition    --- PASS: .../after_keys_destroyed_transition
    --- PASS: .../before_cache_clear                  --- PASS: .../after_cache_clear
    --- PASS: .../before_caches_cleared_transition    --- PASS: .../after_caches_cleared_transition
    --- PASS: .../before_receipt_persist              --- PASS: .../after_receipt_persist
    --- PASS: .../before_completed_transition         --- PASS: .../after_completed_transition
--- PASS: TestErasureSaga_FaultInjectorIsWiredAtEveryPoint
```

Each case: inject a **one-shot** fault (a persistent one would fail the resume too, so nothing would
converge and every case would pass for the wrong reason) → assert the mid-flight invariant → resume →
assert `completed`, assert the returned digest equals the **persisted** digest, run a third time and
assert the digest is unchanged, assert the subject no longer unwraps and its cache is empty.
`TestErasureSaga_FaultInjectorIsWiredAtEveryPoint` separately proves a clean run reaches all 14 points
— a fault point the code never calls would make its two cases pass by doing nothing.

### 8.3 Post-destruction verification (proving unusability, not a success return)

```
--- PASS: TestErasureSaga_DestructionProofRequiresAControl
--- PASS: TestErasureSaga_ProofIsInconclusiveWhenTheControlAlsoFails
--- PASS: TestSubjectKeyPG_ErasesOneSubjectOnlyAndIsIdempotent   (verdict=destroyed against live PG)
```

Each asserts `RowPresent && UnwrapAttempted && UnwrapFailed && StoredBytesDiffer && DestroyedAtSet`
per version, `Control.UnwrapSucceeded`, and that a **live** subject is reported `live` — so the proof
is not a rubber stamp.

### 8.4 Single-subject erasure leaves other subjects readable

```
--- PASS: TestErasureSaga_ErasesOneSubjectOnly            (in-memory store)
--- PASS: TestSubjectKeyPG_ErasesOneSubjectOnlyAndIsIdempotent  (live PostgreSQL 16)
```

Both assert **preconditions first** (all three subjects readable), then after erasing `t1/alice`:
target refuses, `t1/bob` still unwraps, `t2/alice` still unwraps, target's cache empty, neighbour's
cache intact.

### 8.5 Live PostgreSQL 16 — the only check that separates valid SQL from plausible SQL

```
docker run -d --name sldp-p41-pg -e POSTGRES_PASSWORD=sldp -e POSTGRES_USER=sldp \
  -e POSTGRES_DB=sldp -p 55439:5432 postgres:16-alpine
SLDP_PG_DSN='postgres://sldp:sldp@127.0.0.1:55439/sldp?sslmode=disable' go test -run TestMigration009 -v ./identity/...
```

```
--- PASS: TestMigration009_AppliesToLiveDatabase (0.57s)
    --- PASS: .../destroyed_row_without_a_digest_is_refused
    --- PASS: .../completed_saga_without_a_digest_is_refused
    --- PASS: .../unknown_saga_state_is_refused
    --- PASS: .../cleartext_subject_identifier_is_refused
    --- PASS: .../wrong-length_wrapped_key_is_refused
--- PASS: TestSubjectKeyPG_ErasesOneSubjectOnlyAndIsIdempotent (0.12s)
--- PASS: TestSubjectKeyPG_RepeatDestroyPreservesTheOriginalTimestamp (0.05s)
--- PASS: TestSubjectKeyPG_SagaJournalIsIdempotentAndCompareAndSwapped (0.06s)
```

`ApplyMigrations` is run **twice** to prove idempotency, and RLS is verified from `pg_class`
(`relrowsecurity` **and** `relforcerowsecurity`) plus `pg_policies`, not from the migration text.

Both DSN-gated files carry an always-running `*_GateIsHonest` test that prints an explicit COVERAGE
GAP naming what was skipped, so a green suite on a machine without PostgreSQL cannot be mistaken for a
covered one.

### 8.6 Mutation sweep — every guard observed failing

`d2-signalloom/apps/signal-ingest/subjectkey/mutation-check.sh` — **14 killed, 0 survived, 0
build-breaks.** The harness verifies the baseline is green first (otherwise a "kill" is a pre-existing
failure wearing the mutation's clothes), refuses a sed that matched nothing, reports a non-compiling
mutation as `BUILD` rather than `KILLED`, requires an observed `--- FAIL`, and restores by **full
path** under an `EXIT INT TERM HUP` trap.

| # | mutation | killed by |
|---|---|---|
| M1 | per-subject DEK derived, not random | `TestHierarchy_DEKIsRandomNotDerived` |
| M2 | wrap AAD dropped | `TestHierarchy_WrapBindsScope` |
| M3 | receipt `CompletedAt` from the retry clock | `TestErasureSaga_IsIdempotent` |
| M4 | repeat destroy re-stamps `destroyed_at` | `TestErasureSaga_MemoryStoreRepeatDestroy...` |
| M5 | cache purge is a no-op | `TestErasureSaga_ErasesOneSubjectOnly` |
| M6 | proof passes with a failing control | `TestErasureSaga_ProofIsInconclusive...` |
| M7 | proof trusts the flag, never unwraps | `TestErasureSaga_DestructionProofRequiresAControl` |
| M8 | `keys_destroyed` reachable without certification | `TestErasureSaga_CertifiesDestructionByReadBack...` |
| M9 | a saga boundary removed | `TestErasureSaga_FaultOnBothSidesOfEveryBoundary` |
| M10 | Go saga states drift from SQL | `TestMigration009_StateCheckMatchesGo` |
| M11 | destroyed-carries-digest constraint removed | `TestMigration009_DeclaresSubjectKeySchema` |
| M12 | `FORCE ROW LEVEL SECURITY` removed | `TestMigration009_DeclaresSubjectKeySchema` |
| M13 | operation id unkeyed | `TestErasureSaga_OperationIDIsDeterministicAndKeyed` |
| M14 | receipt digest ignores the nonce | `TestErasureSaga_ReceiptDigestIsCanonicalAndSensitive` |

**The sweep found three real gaps on its first run, and they were fixed by adding tests, not by
weakening the mutations:**

- **M6 survived.** The proof's `inconclusive` arm — target fails *and* a control that HAS keys also
  fails — was never exercised; the existing cases (`no control`, `control with no keys`) both return
  before the verdict switch. Added `TestErasureSaga_ProofIsInconclusiveWhenTheControlAlsoFails`.
- **M8 survived.** `certifyAllDestroyed` could be deleted with nothing going red, because in the happy
  path the destroy really does destroy. Added
  `TestErasureSaga_CertifiesDestructionByReadBackNotByReturnValue`, driven by a `lyingStore` that
  returns a **plausible** result (real digest, real timestamp) while destroying nothing.
- **M4 was a no-op, and fixing it exposed** that `MemoryStore`'s repeat-destroy guard had no test at
  all — the property was covered only by the DSN-gated PostgreSQL test, so on any run without a
  database it was uncovered. The two stores share no code. Added
  `TestErasureSaga_MemoryStoreRepeatDestroyPreservesOriginalTimestamp`.

M1 and M13 additionally started as **build breaks**, which the harness correctly refused to score as
kills; both were rewritten to compile before they counted.

---

## 8.7 Defects this verification found in its own work

Recorded because a proof that reports only successes is a proof nobody should trust.

**D1 — a nanosecond clock diverged the receipt digest across a PostgreSQL round trip (REAL, fixed).**
Found by a commitment-boundary advisor call, not by any test. `timestamptz` holds MICROSECONDS and
rounds to nearest; Go's `time.Time` holds NANOSECONDS and truncates toward zero. `Erase` digested
`completed_at` from the in-memory value and then, on the final rebuild, from the value PostgreSQL
returned — so with production's `time.Now()` the two differed and `Erase`'s own consistency check
fired. **The code failed closed** (it errored rather than returning a wrong digest), but the effect
would have been that *every* Postgres-backed erasure failed at the last step.

Invisible to the whole suite because `fixedClock()` returns whole seconds, for which both rounding
rules agree. Fixed by `Saga.clock()` truncating to microseconds at source, plus `encodeInstant()`
encoding timestamps as integer epoch microseconds. Covered by
`TestSubjectKeyPG_NanosecondClockDoesNotDivergeTheReceiptDigest`, **falsified by reverting the fix**:

```
--- FAIL: TestSubjectKeyPG_NanosecondClockDoesNotDivergeTheReceiptDigest
    Erase with a nanosecond-precision clock: subjectkey: rebuilt receipt digest 20099954... does not
    match the digest recorded at receipt_recorded (8a119d69...); SLDP-P4-2's tombstone would disagree
```

**D1a — the first version of that test could not have caught it either.** Its clock advanced by
1234567ns per tick, which lands on sub-microsecond remainders *below* 500 — so both rounding rules
still agreed, and it passed against the reverted fix while its comment claimed to be hostile. The
remainder is now pinned at 750ns and asserted before the test body runs. Falsification above is from
the corrected fixture.

Honest scoping of the two halves, each falsified independently: **the truncation is the fix**
(removing it turns the test red); **the epoch-microsecond encoding is defence-in-depth** (removing it
alone leaves the test green, because with truncation in place no sub-microsecond digits exist). Both
are kept — the encoding removes formatting, location and monotonic-reading as future divergence
surfaces — but only one is load-bearing today and the doc says which.

**D2 — the destruction proof accepted a truncated column as destruction (fixed).** An emptied or
short `wrapped_dek` fails to unwrap, and unwrap failure is the evidence the proof looks for — so data
loss read as deliberate destruction. `VersionProof.BytesPresent` now asserts a full-length wrapped
key and the verdict is `inconclusive` without it.

**D3 — the live suites race each other against one database (pre-existing, documented not fixed).**
`go test ./subjectkey/... ./identity/...` with `SLDP_PG_DSN` set runs both packages concurrently
against one database, and `identity/alias_pg_live_test.go`'s `freshSchema` does
`DROP TABLE ... CASCADE` mid-flight. The identity package fails for reasons unrelated to either
package's code, and passes when run alone. Reproduced, confirmed, and documented at the top of
`subjectkey/postgres_live_test.go`; run one package at a time or pass `-p 1`. The default (no DSN)
path is unaffected because every live test skips. Fixing it means changing another card's file.

**D4 — the live suites were not isolated against a persistent database (fixed).** The second run of
the suite inherited the first run's rows, producing two failures that were the guards working
correctly on stale data — `ErrVersionDrift` because leftover versions appeared "after" a completed
saga, and `created=false` from `BeginSaga`. Each test now derives a unique tenant from `t.Name()` and
`resetTestTenant` deletes its rows first — **setting the tenant claim**, because under `FORCE ROW
LEVEL SECURITY` a claim-less `DELETE` matches zero rows and returns no error, and then verifies the
delete reached them.

---

## 9. Files

| file | lines | role |
|---|---|---|
| `subjectkey/hierarchy.go` | 362 | HKDF tenant KEK, random wrapped subject DEK, AAD binding |
| `subjectkey/receipt.go` | 200 | destruction receipt + canonical digest |
| `subjectkey/store.go` | 410 | `KeyStore` interface, saga states, in-memory store |
| `subjectkey/postgres.go` | 456 | Postgres store: CAS advance, ON CONFLICT journal, RLS claim |
| `subjectkey/saga.go` | 562 | the saga, fault points, boundaries |
| `subjectkey/cache.go` | 199 | plaintext DEK cache + cache registry |
| `subjectkey/proof.go` | 203 | `VerifyDestroyed` with control |
| `subjectkey/saga_test.go` | 1001 | erasure, idempotency, proof, registry, receipt |
| `subjectkey/fault_test.go` | 227 | 14-point fault sweep |
| `subjectkey/hierarchy_test.go` | 252 | crypto + tenant-KEK source guard |
| `subjectkey/postgres_live_test.go` | 301 | DSN-gated live PostgreSQL |
| `subjectkey/mutation-check.sh` | 191 | mutation harness |
| `identity/migrations/009_subject_keys.sql` | 240 | `subject_keys`, `subject_key_erasures`, RLS |
| `identity/migration_009_test.go` | 284 | migration text + live apply |
| `identity/migrations.go` | +14 | embed + `MigrationSQL()` + `ApplyMigrations` |
| `privacy/erasure.go` | +26 | additive fields on `KeyDestructionReceipt` |
| `main.go` | +55 | `buildKeyDestroyer`, wired into the erasure gate |

**Migration sequence 009 is claimed by this card**, per SLDP-P4-PRE §5.4 and the proposal errata.
SLDP-P4-2 runs concurrently in a separate worktree and must take **010**. The 008 collision
(`identity/migrations.go:59-61`) happened because two worktrees could not see each other's tree, so
the number is claimed in a document both can read.

No migration 001–008 was modified; `TestMigration009_DoesNotDisturbEarlierMigrations` asserts it. No
Parquet segment, checkpoint or DSSE statement was read, rewritten or deleted.

---

## 10. What this card did NOT do

- **No backfill.** Existing `aliases` and `segment_reidentification_map` ciphertext still wraps under
  the legacy global root key. The hierarchy ships alongside it. Migrating them is a separate card.
- **No HTTP surface** for erasure, no key-rotation scheduling, no KMS provider integration.
- **`ErrCacheNotEmpty` is unreachable** through the current cache; see §5.
- **`buildKeyDestroyer` falls back to `UnimplementedKeyDestroyer`** when `SUBJECT_KEY_MASTER_KEK` is
  unset or no database is configured, logging at `Error`. It is a refusing fallback, never a recording
  or passthrough one: a false "erased" is a misstatement to a data subject and a regulator, whereas a
  loud refusal is an unconfigured deployment.
- **`signal-ingest` still has no HTTP authentication** (`main.go:224`, bare `http.NewServeMux()`).
  That live hole is outside this card and is restated here because it is larger than anything this
  milestone closes.
