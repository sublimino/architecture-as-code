# SLDP-P6-1 — Retention controller with deletion receipts across every sink

**Card:** SLDP-P6-1 (implementation) · **Phase:** 6 · **Depends on:** SLDP-P6-PRE
**Worktree:** `/home/andy/src/.worktrees/89630/osramp-demo` · **Base:** `integration/sldp-v0.1.0` (`ace7c954`, ancestor verified)

## 1. What was built

`d2-signalloom/apps/signal-ingest/retention/` — a retention state machine over the storage-copy
inventory, plus migration `010_retention_receipts.sql` and wiring in `main.go`.

| File | Purpose |
|---|---|
| `doc.go` | Package doctrine: four-outcomes rule, precedence, continuity resolution, clock trust |
| `policy.go` | Bounded policy; `MaxRetentionPeriod` as a **const**; sentinel refusal at parse |
| `clock.go` | `Clock` interface, `LocalClock`, `TrustedClock` (staleness / drift / backwards-step) |
| `receipt.go` | `DeletionReceipt`, five dispositions, canonical binary encoding, digest, nonce |
| `sink.go` | 35-entry inventory as data; `Sink` interface; row / partition / continuity / external adapters |
| `ledger.go` | `Ledger` interface, `MemoryLedger`, `Outstanding`, `Overdue`, `EarliestOpenDeadline` |
| `postgres.go` | `PostgresLedger` — idempotent upsert, tenant-scoped reads, hand-rolled `text[]` codec |
| `controller.go` | `Controller.Sweep`, `SubmitExternalReceipt`, `Reconcile`, `Reaper` |
| `metrics.go` | Overdue gauge and six sibling series, hand-rendered Prometheus exposition |
| `gate.go` | `AcceptanceGate` — fails on any overdue object, **and** on a vacuous pass |

Before this card there was no deletion code to extend, exactly as P6-PRE recorded:
`audit.EventPartitionDropped` had one call site (`privacy/erasure.go:495`, an Article 17 decision),
`FrostDBStore.DropPartition` advanced an in-memory timestamp and unlinked nothing, the only reaper
flipped `delegations.status`, and there is no `DELETE FROM` anywhere in `d2-signalloom`. This was
sized and built as new work.

## 2. Finding that changed the build: the inventory is 23 rows, not 15 — and 23 is not enough

**The most consequential result of this card is not the controller, it is the denominator.**

A first draft of this package read **15** sinks from a windowed extract of the P6-PRE document.
Re-derived by parsing the markdown:

| Source | Rows | Probe |
|---|---|---|
| SLDP-P6-PRE §3 reconciled inventory | **23** numbered rows | `inventory_parity_test.go` parses `sldp-p6-pre-proof.md` |
| SLDP-P0 boundary map, personal-data storage-copy inventory | **21** unnumbered rows (lines 103–123) | same test parses `sldp-p0-boundary-map.md` |

**Neither is a subset of the other.** P6-PRE added eleven copies P0 predates. P0 lists **nine copies
the P6-PRE reconciliation dropped**:

`portal_audit_events` · `audit_anchor_local_output` · `rekor_transparency_log` ·
`segment_attestor_queues` · `identity_event_bus` · `redis_shared` · `minio_object_store` ·
`postgres_physical_backup` (P0: *"Backups/snapshots — Not found for target datasets"*) ·
`application_container_logs` (P0: *"Emission confirmed; retention external and unproven"*)

Why this is worse than a missing feature: **the sink set is the denominator of every coverage and
overdue figure.** A forgotten copy does not present as a hole — it presents as *higher* coverage,
because it lowers the denominator. And the overdue gauge iterates the outstanding set, which is built
from the enumeration, so a copy never enumerated can never go overdue. The strongest correcting loop
in the design would have been blind to precisely the failure that defeats it. Building against 15
would have shipped twenty copies with a gauge reading zero because nothing evaluated them.

`AllSinkSpecs()` is therefore the **union**: 23 + 9 + 3 card-named copy classes the card's approach
names and neither document enumerates (`postgres_wal`, `filesystem_snapshot`,
`subject_access_export`) = **35**.

```
inventory provenance: 12 in both documents, 11 P6-PRE-only,
                      9 P0-only (dropped by the reconciliation), 3 card-named, 35 total
```

**The parity test derives its expectation by parsing both documents, not from the Go table.** If
either gains a row `AllSinkSpecs` does not carry, the test fails. That flips the sign of the loop: a
new sink now *raises* the denominator and coverage falls until an adapter exists.

## 3. The retention-versus-checkpoint-continuity resolution

**Deleting an expired Parquet segment is not available.** Verified by inspection, not assumed:

- `store/verify/verify.go:203` → `verifySegmentRecord` re-reads each segment's bytes to re-verify its
  DSSE claim. A missing file is a hard error.
- `store/verify/verify.go:650-656` → `segmentInventory(cfg.SegmentRoot)` must be **set-equal** to
  `high_water.HistoricalSegments ∪ journal.SegmentID`, else *"persisted segment inventory differs
  from protected history and journal"*.

So unlinking one expired segment turns `VerifyCorpus` from a pass into a hard error — this card's
first declared hard blocker. Crypto-shredding does not answer it either: it is an Article 17 tool, and
a shredded-but-retained blob is still retained.

**Resolution: retention on the columnar and attestation plane is enforced at the LINKAGE copies, not
at the attested bytes.** A segment payload holds an HMAC pseudonym; what makes it personal data is
`segment_reidentification_map` (pseudonym → actor_id) and `subject_keys` (the wrapped DEK). Neither is
read by any verifier nor chained into any attestation, so both are deletable without touching a byte
of evidence. Their default period is **90 days**, deliberately the shortest in the set and far shorter
than the 5-year evidence period, asserted by
`TestRetentionInventory_LinkageSinksExistAndAreShortest`.

Three things keep this from being a euphemism:

1. **The segment sink still carries a propagation deadline.** If the linkage purge does not complete,
   the segment goes outstanding and then overdue — the attested plane is covered by the gate, not
   excused from it (`TestRetentionController_ContinuitySinkGoesOverdueWhenLinkagePurgeFails`).
2. **The receipt does not claim compliance.** `ComplianceNoteRetainedToken` explicitly does not assert
   Article 5(1)(e) satisfaction and hands the Recital 26 assessment — *"by the controller or any other
   person"* — to the controller.
3. **The precondition is named.** An advisor review caught that the pseudonym is a **keyed**
   derivative: `identity.NewPseudonymKeyRing(rootKey, epoch)` produces an HMAC, not a random
   surrogate. While that epoch key exists, anyone holding it regenerates the map by enumerating a
   low-entropy actor-ID space, so purging the index destroys a convenience index rather than the
   linkage. The note now states unresolvability is **CONDITIONAL** on destruction of the pseudonym key
   epoch and expiry of PITR/replica windows, and
   `TestRetentionReceipt_RetainedTokenNoteNamesItsPrecondition` fails if any of those words is
   removed. The residual says *"linkage index purged … retain regenerable linkage"*, not
   *"linkage destroyed"*.

## 4. Required tests

| Command | Result |
|---|---|
| `cd d2-signalloom/apps/signal-ingest && go test ./...` | **PASS** — 25 packages `ok` |
| `go test -run TestRetention ./...` | **PASS** — 74 tests in `retention`; selector-match guarded (see §6) |
| `make test-signal-ingest` | **PASS** |
| `rg -c 'EventPartitionDropped' .../audit/audit.go` | **2** (unchanged — the enum was not edited) |
| `go test -tags frostdb ./retention/` | **PASS** |
| `go test -race ./retention/` | **PASS** |
| `go vet ./...` · `gofmt -l` on changed files | clean |

`make demo-signalloom-api-test TIER=contract` was **not run**: it requires a live cluster and this
card added no HTTP route. Recorded as deferred rather than claimed.

## 5. Required evidence

**Overdue metric — zero overdue across every sink** (full 35-sink inventory, external copies attested):

```
sweep 1 over the full 35-sink inventory: purged=18 already_absent=0 retained_token=6 unreachable=11 records=36
ACCEPTANCE GATE over all 35 sinks: evaluated=35 overdue=0 outstanding=0
signalloom_retention_overdue_objects{tenant="",sink="",disposition="",reach=""} 0
```

**Overdue metric observed firing for a deliberately held copy** — one copy held, clock advanced past
its anchored deadline, reconciled with **no sweep**:

```
observed overdue gauge firing:
signalloom_retention_overdue_objects{tenant="tenant-a",sink="postgres_actors",disposition="held",reach="in_process"} 1
```

**Gate falsification — one attestation withheld:**

```
retention acceptance gate: storage copies are past their retention propagation deadline:
1 of 35 copies overdue for tenant "tenant-a": postgres_physical_backup[unreachable overdue by 864h0m0s]
```

**Idempotent resume after a partial sweep** — `TestRetentionController_ResumeAfterPartialSweep…`:
sweep 1 purges the healthy sink (4 records) and records an `unreachable` receipt for the broken one;
the broken sink recovers; sweep 2 removes **6** (only the recovered sink), the already-complete sink is
purged **1** time across both sweeps, and the ledger holds **2** rows for 2 copies — neither
double-counted nor skipped.

**Receipt when a copy was already absent** — `TestRetentionController_AlreadyAbsentIsDistinguishableFromPurged`:
a zero-row sink earns `already_absent` with `ComplianceNoteAlreadyAbsent`, distinguishable in the
ledger from `purged`.

**Trusted clock source** — recorded per receipt in `clock_source` and per sweep in
`SweepResult.ClockSource`, read from the `Clock`, never a constant. Sources: `trusted_sync` and
`local_unverified`; an enforcing controller refuses the latter at construction.

## 6. Defects found and fixed during this card

All three were found by tests, not by review, and none was visible to a single-sweep test.

| Defect | Consequence | Regression test |
|---|---|---|
| **Sliding deadline.** The boundary is `now − period`, so it advanced every sweep and the deadline advanced with it. | A copy under a permanent legal hold received a fresh always-future deadline on every sweep, could **never** go overdue, and the gauge read zero indefinitely. Legal hold silently became unlimited retention. Only appears when a reaper keeps sweeping — i.e. only in production. | `TestRetentionRegression_DeadlineDoesNotSlideAcrossSweeps`; fixed by anchoring on `Ledger.EarliestOpenDeadline` |
| **Re-counted prior removals on resume.** A returned pre-existing complete receipt had its `RecordsRemoved` added to the new sweep's total. | Measured 10 records reported where 6 were removed — a **67% overstatement** that would have reached a regulator. | `TestRetentionRegression_ResumeDoesNotReCountPriorRemovals`; fixed with a `fresh` return value |
| **`OK()` true after a clock abort.** An aborted sweep has no failures, no unreachable sinks and no overdue copies yet. | A caller inspecting only `res.OK()` read a clean bill of health for a control that had not run. | `TestRetentionRegression_SweepResultAbortedMakesOKFalse`; fixed with `SweepResult.Aborted` |

Two further guard defects, both of the "prose parsed as data" class:

- The migration additive-check scanned the raw file and failed on the word *"truncates"* inside a
  comment. Fixed by stripping `--` comments **and** asserting the stripper leaves `CREATE TABLE`
  behind, so a stripper returning `""` cannot make the check pass vacuously.
- A metric assertion matched `signalloom_retention_state_unknown 1` as a substring and was satisfied
  by the metric's own `# HELP` text. Fixed by matching a whole sample line (`metricLine`) **and**
  rewording the HELP — appeasing the guard alone would have left the guard wrong.

## 7. Mutation testing — 15 mutations, 15 killed

Each mutation was applied to the real source, the named tests run, and the file restored. Every kill
is an **observed FAIL naming a specific test**, not an inference.

| # | Mutation | Verdict |
|---|---|---|
| 1 | Remove the `EarliestOpenDeadline` deadline anchoring | KILLED — *"deadline moved from 2026-09-17T12:00:00Z to …13:00:00Z"* |
| 2 | Drop `!r.Aborted` from `OK()` | KILLED |
| 3 | Re-record and re-count non-fresh receipts | KILLED |
| 4 | Move `held` into the complete set | KILLED |
| 5 | Make the overdue gauge always read zero | KILLED — *"overdue gauge = 0 after injecting one overdue copy"* |
| 6 | Tolerate `unreachable` in `OK()` | KILLED (after adding a per-clause test — see below) |
| 7 | Allow an empty sink set | KILLED |
| 8 | Let the gate pass vacuously | KILLED |
| 9 | Accept a `local_unverified` clock when enforcing | KILLED |
| 10 | Delete the nine P0-only sinks | KILLED |
| 11 | `encodeInstant` uses nanoseconds | KILLED — digest diverged |
| 12 | Invert the clock staleness comparison | KILLED |
| 13 | Drop `FORCE ROW LEVEL SECURITY` from migration 010 | KILLED |
| 14 | Replace `CONDITIONAL` with `assured_by` in the retained-token note | KILLED |
| 15 | Give the overdue deadline a one-hour grace period | KILLED (after adding a boundary test — see below) |

**Two mutations initially SURVIVED, and both surfaced something real.**

- #6 survived because every path producing an `unreachable` receipt also records a `Failures` entry,
  so that clause masked the mutation. The clause is therefore **redundant today**. It was kept rather
  than deleted — it is the clause that still holds if a future refactor records an unreachable receipt
  without a failure entry — and `TestRetentionRegression_OKIsFalseForEachConditionIndependently` now
  falsifies each clause directly, with a positive control that shares no construction with the
  negative cases.
- #15 survived because every other test advances the clock hours or days past the deadline, so a grace
  period nobody asked for was invisible. That is a **test insensitivity**, not a bug.
  `TestRetentionRegression_OverdueBoundaryIsExact` now pins the boundary to the microsecond: at the
  deadline not overdue, one microsecond later overdue.

## 8. Advisor review — findings accepted and findings recorded

An advisor pass at the commitment boundary returned *"not done"* with five blocker-class findings.
Four were closed in this card; the rest are recorded rather than silently deferred.

**Closed:**

1. **The keyed-pseudonym crux** (§3.3) — the retained-token note now names its precondition.
2. **The standing floor.** Eleven of 35 sinks have no in-process purger and go overdue by day 3, so an
   unlabelled gauge has a permanent non-zero floor and any alert threshold set above it hides real
   in-process failures underneath. The gauge now carries a **`reach`** label separating *we tried and
   failed* (`in_process`, alertable) from *we are forbidden to delete* (`continuity_bearing`) from *we
   have no purger here* (`external_attestation`, a coverage gap).
   `TestRetentionMetrics_ReachSeparatesDefectFromCoverageGap`.
3. **The clean-gauge-with-live-bytes path.** `retained_unresolvable_token` is a *complete* disposition,
   so those copies leave the outstanding set and a dashboard showing only the overdue gauge would read
   *"expired data remaining: 0"* while attested bytes sit on disk. Added
   `signalloom_retention_retained_past_period`, permanently non-zero by design.
   `TestRetentionMetrics_RetainedResidualStaysOnScreen`.
4. **Clock refusal froze the alarm.** Fail-closed on purging was fail-**silent** on detection: an
   aborted reconciliation left the last clean gauge value standing. Added
   `signalloom_retention_state_unknown`, set on refusal and cleared on recovery.
   `TestRetentionMetrics_ClockRefusalDoesNotFreezeACleanGauge`.

**Recorded for P6-GOV, not built here:**

- **`overdue_objects` counts COPIES, not records.** The gauge is per (tenant, sink, boundary), so it
  answers *"is any copy past its deadline?"* — not *"how many expired records survive?"* The metric
  name is the card's wording; the semantics are stated here so nobody reads it as an object count.
- **Receipts prove intent, not effect.** No sink performs a post-purge negative read-back, and the
  purger supplies its own counts, so a buggy purger could mint a receipt for a deletion it did not
  perform. The honest fix is a verifier-issued nonce plus a post-purge read-back; that requires a
  `Verify` method on every sink and belongs with whichever card wires the real purgers.
- **No per-sink retention *floor*.** `MinRetentionPeriod` is a global 1h. For a bank, premature
  destruction of MiFID/AML/SOX records is the larger exposure, so a per-sink `min` with
  `CHECK (min <= max)` is wanted. Deliberately not added unilaterally — it is a policy decision.
- **`EventPartitionDropped` is now overloaded.** Its pre-existing call site
  (`privacy/erasure.go:495`) means *"an Article 17 erasure decision was permitted"*; P6-PRE §6
  instructs the retention sweep to emit the same event type. Both now write to one
  `signal_audit_trail.event_type` value. Mitigated for a *reader* by `"cause":"retention"` in the
  detail payload, but the durable fix is a distinct event type with a widened CHECK constraint, which
  lives outside this card's boundary. **Cross-card dependency for P6-GOV.**
- **Only 1 of 35 sinks has a real in-process purger** (`frostdb_observations`, via
  `SignalStore.DropPartition`). The identity-table purgers need repository methods that belong to other
  cards. Rather than wiring a placeholder returning `(0, nil)` — which would make every identity sink
  report `already_absent` and the gauge read clean, a passthrough control the architectural
  constitution forbids — `buildRetentionSinks` registers each un-wired spec as
  **external-attestation**, so it stays outstanding, goes overdue, and is counted. A visible, dated
  gap instead of an invisible one.
- **Parity joins on prose.** The P0 half matches on the verbatim leading table cell. A relabelled row
  (*"container logs"* → *"stdout logs"*) would fail the test loudly, which is the right direction, but
  the join key is a document string rather than a stable ID.

## 9. Fail-closed inventory

Every refusal is tested by `TestRetentionController_RefusesEveryFailOpenConfiguration` and siblings.

| Condition | Behaviour |
|---|---|
| nil ledger / clock / evaluator / audit writer | construction refused |
| empty sink set | construction refused — *"every acceptance criterion would pass vacuously"* |
| `local_unverified` clock while enforcing | construction refused |
| policy gap, duplicate sink, unbounded period | construction refused |
| clock untrusted at sweep time | sweep aborts, **purges nothing**, `Aborted` makes `OK()` false, `state_unknown` set |
| hold lookup undetermined / no jurisdiction | that copy is not purged; `unreachable` receipt; reported in `Failures` |
| sink unreachable | `unreachable` receipt; copy stays outstanding; sweep returns `ErrSweepIncomplete` |
| ledger write fails | reported — *"deletion may have occurred and cannot be proven"* |
| audit write fails | reported, not swallowed |
| sink returns an empty residual | receipt refused |
| continuity sink with no completed linkage purge | `unreachable`, never `retained_unresolvable_token` |
| external sink, no attestation | `unreachable` until an operator attests (`Absent: true` for a genuine absence) |

## 10. Migration 010

Additive only; no prior migration edited; embedded in `identity/migrations.go` and executed by
`ApplyMigrations` — an existing repo guard, `TestMigrationSQL_EveryFileIsEmbeddedAndExecuted`, caught
the missing `//go:embed` and is the reason the migration is wired rather than inert.

`operation_id` is the PRIMARY KEY and is `SHA-256(tenant_id, sink_id, dropped_before)` — **nonce
excluded**, so it is stable across retries and `ON CONFLICT` enforces idempotence in the database
rather than in application bookkeeping. RLS is `ENABLE` + `FORCE` with a tenant policy matching the
006/008 pattern. Five CHECK constraints mirror the Go validation: the disposition enumeration, no
removal counts without `purged`, `held` must name holds, completion must match disposition, and
`retained_unresolvable_token` must name linkage receipts.

Note the failure direction, which differs from migration 008: reading zero receipt rows makes every
copy look **outstanding**, so a missing tenant claim inflates the overdue gauge rather than clearing
it. A retention ledger must fail toward *"we cannot prove deletion"*.

**Stale reservation corrected:** the comment on migration 009 states *"SLDP-P4-2 … takes 010"*. P4-2
shipped its tombstones as evidence-directory files and never added a migration; `git log --all
--name-only` over `identity/migrations/` shows 009 as the highest on every branch and no 010 existed.
The stale claim is annotated in `migrations.go` rather than silently overwritten.

## 11. Not done

- `make demo-signalloom-api-test TIER=contract` — needs a live cluster; no HTTP route added.
- `PostgresLedger` has **no live probe**: there is no DSN in this worktree. Its shape is verified
  statically and by compile-time interface assertion; its behaviour is verified against `MemoryLedger`,
  which is a real implementation rather than a mock for exactly this reason. **`[DEFERRED-VERIFY]` —
  follow-up owner: SLDP-P6-2**, whose self-hosted install proof stands up a real PostgreSQL and should
  run a retention sweep against it.
- The `TrustedClock` has no NTP/Roughtime transport. This card owns the trust *decision* (freshness,
  drift, fail-closed refusal); `SIGNAL_RETENTION_CLOCK_SYNC` seeds it once at boot and the freshness
  window then expires it after an hour, which **stops** the sweep rather than letting it run on a
  stale reading. Recorded as an unowned boundary.
