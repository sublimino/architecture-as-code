# SLDP-P4-GOV — Phase 4 Governor Certification

**Verdict: FAIL (one property of four).** Phase 4 does not certify.

| | |
| :--- | :--- |
| Card | SLDP-P4-GOV |
| Integration branch | `integration/sldp-v0.1.0` |
| Certified at | `ef2acd00dd152279939363f9b5c72b6217412506` |
| SLDP-P4-1 | impl `2e576206682af463fbf5c1590df817722fb4dc88`, merged `10b8057457c4190e2677df473c677acc04c10ced` |
| SLDP-P4-2 | impl `9956a2393641e3d421b3c123be36b0a6c6203054`, merged `d3845467e0bdcacf93713dcf2b0968ed2d86aaf8` |
| Date | 2026-09-14 19:48:18+01:00 |

---

## 1. Summary

Phase 4 asked for three properties that make crypto-shredding meaningful rather than nominal:
erasure reaches exactly one subject, destruction is idempotent under retry, and a tombstone cannot
recreate the association it removes. All three hold, and each is proved by a test that fails when
the property is removed — verified by mutation, not by reading the assertion.

A fourth property is not in that list but is in this card's deliverables, and it is the one that
fails: **"Evidence that tombstones reference real destruction receipts."** That evidence does not
exist, because the mechanism does not exist. SLDP-P4-1 produces a destruction receipt with a
canonical digest. SLDP-P4-2 publishes a tombstone. Nothing connects them. Each card is
independently green and jointly unwired.

This is the exact failure mode this card was briefed to expect: *"A governor that certifies each
card in isolation misses the seam between them, which here is whether the receipt and the
tombstone actually refer to the same destruction."* Certifying the phase on the strength of the
two cards' own green suites would have done precisely that.

---

## 2. Properties certified PASS

Each property below was mutation-tested: the mechanism was deliberately broken and the test
observed to fail. A green test is not evidence that a property is asserted; an observed failure is.

### Property A — erasure reaches exactly one subject · **PASS**

`TestErasureSaga_ErasesOneSubjectOnly` (`subjectkey/saga_test.go:129`) does not merely assert that
the erasure call succeeded. It provisions three subjects — the target, a **neighbour in the same
tenant**, and **the same subject name in a different tenant** — asserts all three start readable,
and after erasure requires the target to fail while both controls still unwrap. Without those two
controls, "the target failed to unwrap" would be equally consistent with a broken key path.

It further asserts the target's plaintext DEK cache is empty *and the neighbour's is not*, which is
what distinguishes a subject-scoped purge from a global one.

**Mutation (governor-run):** `PlaintextDEKCache.PurgeSubject` altered to ignore the subject prefix
and purge every entry.

```
--- FAIL: TestErasureSaga_ErasesOneSubjectOnly (0.00s)
    saga_test.go:143: Erase: subjectkey: plaintext key cache still holds entries for the subject
    after purge; erasure would be cosmetic: 3 entries remain: [t1 41a2f274... 0 1 | t1 41a2f274... 0 2
    | t2 42a1c9357... 0 1]
```

Killed. Note it was killed by the saga's *unconditional emptiness re-read* before the test's own
neighbour assertion was reached — two independent mechanisms catch the same defect, which is
stronger than the single guard the test alone would imply.

### Property B — destruction is idempotent under retry · **PASS**

The saga is a 5-state journal (`StatePending → StateKeysDestroyed → StateCachesCleared →
StateReceiptRecorded → StateCompleted`) keyed by a deterministic HMAC operation id over
`(tenantID, pseudonym)` under the tenant KEK. The request id is deliberately excluded, so two
requests naming one subject are one destruction and emit one tombstone.

**Fault injection on both sides of every durable boundary** is `SagaBoundaries` × `{Before, After}`
= **14 fault points**, exercised by `TestErasureSaga_FaultOnBothSidesOfEveryBoundary`
(`subjectkey/fault_test.go:38`). Three things make this a real proof rather than a shape:

1. **It replays.** Each case crashes at the injected point, then re-runs the saga from whatever
   durable state it reached, and requires convergence on the no-fault reference receipt digest.
   This is the replay-from-each-durable-state evidence the deliverable asks for; idempotency
   claimed but never replayed would be untested.
2. **It refuses to be vacuous.** A fault point that never fires makes its case assert nothing, so
   the test fails explicitly on that condition rather than passing quietly — with exactly one
   documented exception (`FaultAfterCompletedTransition`, which fires on the last statement).
   `TestErasureSaga_FaultInjectorIsWiredAtEveryPoint` independently pins the wiring.
3. **It pins the one-directional invariant.** A receipt digest must never be recorded while a
   targeted key version is still live — destruction without a recorded receipt is transient and
   resumable, but a recorded receipt beside a usable key would be a tombstone attesting to
   something that did not happen.

**Mutation (governor-run):** 8 random bytes mixed into the operation-id HMAC, making it
non-deterministic.

```
--- FAIL: TestErasureSaga_IsIdempotent            receipt digest changed on re-run:
                                                    first:  b1609804b75ce118...  second: fe860783c7070bb6...
--- FAIL: TestErasureSaga_OperationIDIsDeterministicAndKeyed   operation id is not deterministic
--- FAIL: TestErasureSaga_ConcurrentInvocationsDestroyOnce     concurrent invocations produced
                                                               DIFFERENT receipt digests
```

Killed, by three independent tests.

### Property C — tombstones are not joinable to retained evidence · **PASS**

`TestTombstoneNonJoinability` (`privacy/tombstone/linkage_probe_test.go:527`) attempts to join a
published tombstone back to a retained-evidence corpus across six strategies, and requires every
strategy to leave at least `MinAnonymitySet` (5) candidates. It tracks narrowing **per join
predicate rather than per strategy**, so a genuine one-row link cannot be diluted by scope-level
tenant matches.

The design is sound on the three mechanisms by which a link travels — direct carriage, a
recomputation oracle, and a selector — and SLDP-P4-2 correctly *refused* two fields SLDP-P4-PRE
§6.2 had allow-listed (`receipt_digest` over the subject-carrying receipt, and `erased_at` at
RFC3339Nano) because each is itself such a mechanism. Refusing a preflight allow-list entry on
stated reasoning is the right call and is recorded here as such.

**Positive controls are shipped, not assumed.** Six tests plant a specific defect and require the
same code path to find it (`...DetectsPlantedPseudonym`, `...DetectsNanosecondTimestamp`,
`...DetectsPlantedReceiptDigest`, `...DetectsCoarseOnlyReceiptDigest`,
`...DetectsUnbandedQuasiIdentifier`, `...DetectsGenerationCollision`).

**Mutation (governor-run):** `attemptJoin` stubbed to report no narrowing under any condition.

```
FAIL github.com/.../privacy/tombstone   [all six positive controls fail]
```

Killed. The probe is not inert; a green run is distinguishable from a probe that cannot see.

### Property D — every enumerated cache is empty after destruction · **PASS, with one caveat**

`subjectkey/cache.go` carries an enumerated `CacheRegistry` of all six caches SLDP-P4-PRE §4
inventoried, each with `Cleared` and a stated `Reason`.
`TestErasureSaga_CacheRegistryCoversPreflightInventory` requires every inventoried cache to appear
with a reason, and requires **exactly one** (`subjectkey.PlaintextDEKCache`) to be cleared. The
five not-cleared entries are tenant- or service-scoped by design; clearing them would be a
cross-subject side effect dressed as hygiene.

Emptiness is asserted by **unconditional re-read**, not inferred from a purge count —
`TestErasureSaga_CacheAssertionIsNotVacuous` pins that a purge which silently matched zero entries
is distinguishable from one that correctly evicted everything.

**Caveat (accepted, not proven):** the test **transcribes** the P4-PRE inventory as a Go literal
rather than deriving it from the preflight document. A guard that copies its source of truth drifts
from it silently. If P4-PRE §4 is ever amended, this test will keep passing against the stale copy.
Recorded as residual R3 below.

### Property E — P3-2 hold gates still bind the new erasure path · **PASS**

The erasure path SLDP-P4-1 built sits *behind* the Phase 3 gates rather than beside them.
`privacy/erasure_test.go` carries 20 tests over the gate surface; the load-bearing one for this
card is `TestErasureHold_OrderingHoldCheckPrecedesKeyDestruction`, which pins that the hold check
runs **before** any key destruction — ordering, not mere presence.
`TestErasureHold_AuditFailureRefusesAndDoesNotDestroy` and
`TestErasureHold_NoDevelopmentOptInRelaxesAnyGate` close the two fail-open shapes.
`api/erasure_test.go` (9 tests) confirms the HTTP surface is permission-gated and actor-scoped, and
that the requester identity comes from the credential rather than the request body.

---

## 3. Property F — tombstones reference real destruction receipts · **FAIL**

This is the seam between SLDP-P4-1 and SLDP-P4-2, and it is open.

### The finding (G1, severity HIGH)

`privacy.KeyDestructionReceipt` carries three fields that identify a specific destruction —
`OperationID`, `ReceiptSchema` and `ReceiptDigest` — the last documented in its own source as
*"the hex SHA-256 a tombstone references."* The saga persists that digest to the journal at
`StateReceiptRecorded` and guards it at `saga.go:477` with a comment naming the consequence of
drift: *"SLDP-P4-2's tombstone would disagree with this receipt."*

`tombstone.MintRequest` accepts **none of those three fields**. The binding those comments describe
has no parameter to travel through.

Three consequences, each verified:

1. **No published tombstone field joins to any receipt.** `ReceiptCommitment` is
   `SHA-256(nonce ‖ canonical(ReceiptProjection))` where the nonce is **freshly drawn inside
   `Mint`** and the projection is built from `MintRequest`'s own caller-supplied scalars. It is
   never the saga's persisted nonce and never covers the saga's persisted digest.
2. **`ProjectReceipt` — the one function that takes a real `privacy.KeyDestructionReceipt` — has no
   production caller.** Its only caller in the tree is `tombstone_test.go:290`.
3. **`VerifyReceiptCommitment` cannot fail for a well-formed document.** It recomputes the
   commitment from *the tombstone's own published fields and its own published nonce*. It is a
   self-consistency check, not a proof of anything external.

### Why this is a hard blocker rather than a defect to note

The phase constitution names as a hard blocker *"any acceptance criterion that would pass whether
or not the control works. State this rather than satisfying it."* `VerifyReceiptCommitment` is that
criterion exactly. A tombstone minted for a subject who was never erased, by an operator who ran no
saga, against a key that was never destroyed, verifies and validates identically to a genuine one.
The published artefact attests only that somebody called `Mint` with well-formed arguments.

**Additionally: `privacy/tombstone` has zero non-test importers.** Nothing on the production
erasure path mints a tombstone at all. The package is complete, well-built and unreached.

### Evidence

`privacy/tombstone/governor_seam_test.go` (added by this card, 3 tests, all passing):

| Test | Proves |
| :--- | :--- |
| `TestGovernorSeam_MintCannotAcceptReceiptIdentity` | The receipt carries all three identity fields; `MintRequest` accepts none. |
| `TestGovernorSeam_TombstoneCarriesNoJoinToAReceipt` | No marshalled tombstone field contains the receipt's operation id, digest or schema. |
| `TestGovernorSeam_VerificationPassesOnAFabricatedTombstone` | A tombstone for a destruction that never happened passes both `VerifyReceiptCommitment` and `ValidateDocument`. |

These are **characterisation tests**: they assert the seam as it currently stands and are written to
fail the moment it is wired, with a failure message directing the reader back to this section. A
test that tolerated the gap silently would let Phase 5 inherit it by omission; a test that simply
failed would break the phase's loop-until-green contract and be muted within a day.

### What closing it requires

Not a governor decision, and deliberately not attempted here — improvising a wiring across two
sibling cards' contracts is precisely what this card is instructed not to do. The shape is:
`MintRequest` gains the receipt's `OperationID` and `ReceiptDigest`; the receipt nonce persisted in
the saga journal becomes the commitment nonce rather than a fresh draw; `VerifyReceiptCommitment`
takes the receipt (or its digest) as a **second, external** input so it can disagree. SLDP-P4-2's
own errata already anticipates the constraint: **I3 — the key must live outside the crypto-shred
boundary, or erasure destroys the proof of its own erasure.**

---

## 4. Residuals — published, not implied

| ID | Residual | Status |
| :--- | :--- | :--- |
| R1 | **Pseudonyms survive in attested segments.** A pseudonym already written into a signed, chained Parquet segment cannot be removed without breaking checkpoint continuity (`store/segment_attestor.go` chains on `PrevCheckpointDigest`, `Sequence`, `CumulativeRowCount`). The token is retained and only its *resolvability* is destroyed. Recorded in every receipt as `ResidualUnresolvableToken`. **Article 17 is satisfied by loss of resolvability; Article 5(1)(e) storage limitation is NOT.** | Published, by design |
| R2 | **MVCC dead tuples, WAL and backups retain the prior wrapped key** until VACUUM and backup expiry. Recorded in every receipt as `StorageResidualMVCCAndBackup`. An operator needing bit-level erasure must also VACUUM, expire WAL and roll backups. | Published, by design |
| R3 | **The cache-registry test transcribes the P4-PRE inventory** rather than deriving it. Drifts silently if §4 is amended. | Accepted, not proven |
| R4 | **The differencing attack across two corpus snapshots bypasses every tombstone field.** No field-level control addresses it; it makes *k* a scheduling constraint on the erasure batch. SLDP-P4-2 raised this against SLDP-P4-1's batching (invariants I6/I7). **Not implemented by either card.** | Open, inherited by Phase 5 |
| R5 | **Locally signed tombstone forgery is not externally detectable** — Rekor refuses at `anchor.py:407` and Archivista is optional. | Published limit |

---

## 5. Assumed rather than tested

Stated so a later reader can tell a proven property from an accepted one.

- **Postgres-backed behaviour** is proven for migration 009 against live PostgreSQL 16 by SLDP-P4-1,
  but every mutation and property test this governor ran used the **in-memory store**. The
  `StorageResidualNone` / `StorageResidualMVCCAndBackup` split exists precisely so a memory-store
  test cannot masquerade as covering the Postgres claim, which is the right guard — but it means
  Property A and Property B are certified against the memory store only.
- **"Returned once and never persisted"** for the confirmation key is an operational claim about
  callers, not a property this package can enforce (SLDP-P4-2 invariant I8). No caller exists yet to
  violate it.
- **`MinAnonymitySet = 5`** is the conventional small-cell suppression floor, defensible but named
  by no regulation. A stricter DPO position needs a stricter build.
- **Doctor status.** `scripts/kanban-check.sh doctor` returns **UNHEALTHY (exit 1)** on 29
  fast-exit tasks belonging to `cpai-opencode*` and `antigravity` agents. **No SLDP card is among
  them**; the SLDP board itself reports `HEALTH: ✓ healthy`. The exception is pre-existing,
  global-scope, and unrelated to Phase 4 — recorded rather than cleared, because clearing another
  board's runtime records is not this card's authority.

---

## 6. Handed downstream to Phase 5, explicitly

So the next phase inherits these by name rather than by omission:

1. **G1 — the receipt/tombstone seam is unbound** (§3). Until it is closed, "attested erasure
   tombstone" overstates what the artefact proves.
2. **`privacy/tombstone` has no production caller.** The erasure path does not publish tombstones.
3. **R4 — the differencing attack** and SLDP-P4-2 invariants **I6** (batch so ≥5 subjects' rows
   vanish together) and **I7** (publish as a randomly ordered daily batch under one Merkle root;
   chain position is a total order, and position + tenant + day is a quasi-identifier no random
   `tombstone_id` fixes).
4. **R3 — the transcribed cache inventory.**
5. **Property A and B are certified against the in-memory store only** (§5).

---

## 7. Test commands and results

| Command | Result |
| :--- | :--- |
| `cd d2-signalloom/apps/signal-ingest && go test ./...` | **PASS** — all packages ok, 0 failures |
| `make test-signal-ingest` | **PASS** — exit 0 |
| `scripts/kanban-check.sh doctor --repo … --shortcode SLDP` | **UNHEALTHY (exit 1)** — 29 pre-existing fast-exit tasks on other agents; no SLDP card affected; SLDP board `✓ healthy`. See §5. |

Governor mutation runs (Properties A, B, C) are recorded inline in §2 with their observed failure
output. All mutations were reverted and the tree confirmed clean (`git status --porcelain` empty)
before any commit.

---

## 8. Certification

**Phase 4 does NOT certify.** Properties A, B, C, D and E pass, each with an observed mutation kill
or shipped positive control. Property F fails: the deliverable *"Evidence that tombstones reference
real destruction receipts"* cannot be satisfied, because no such reference exists, and the control
that would report it (`VerifyReceiptCommitment`) cannot fail.

Per the phase constitution this is a hard blocker and is **stated rather than satisfied**. No
substitute ref, file or approach was used to get past it, and no wiring was improvised across the
two sibling cards' contracts.

Phase 5 must not be opened on the assumption that Phase 4's tombstones are evidentially bound to
Phase 4's destructions.
