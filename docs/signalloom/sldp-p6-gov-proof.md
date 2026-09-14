# SLDP-P6-GOV — Mission Governor execution proof

**Card:** SLDP-P6-GOV (governor) · **Phase:** 6 · **Depends on:** P6-1, P6-2
**Worktree:** `/home/andy/src/.worktrees/osramp-demo/sldp-v0.1.0/governor` (dedicated governor worktree)
**Branch:** `integration/sldp-v0.1.0` · **HEAD at start of run:** `bd2545468b58b60e6a808197b2caa6a9e9a47226`
**Executed:** 2026-09-15 · **Status:** **PASS**

**Primary deliverables:**
[`sldp-mission-certification.md`](./sldp-mission-certification.md) ·
[`sldp-downstream-contract.md`](./sldp-downstream-contract.md)

---

## 1. Merge state — nothing to merge

Every Phase-6 commit is already an ancestor of the integration HEAD. Verified with
`git merge-base --is-ancestor <sha> HEAD`:

| Commit | Card | Ancestor of `bd254546` |
|---|---|:---:|
| `086ac1f3` | P6-PRE preflight proof | YES |
| `f9b08ace` | P6-2 self-hosted install proof | YES |
| `a0429ea2` | P6-2 integration merge | YES |
| `c9ae419a` | P6-1 retention controller | YES |
| `37830bba` | P6-1 integration merge | YES |

The branch moved from `37830bba` to `bd254546` during this run — a concurrent controller commit
(`chore: record controller tick 103, SLDP-P6-1 approval, launch SLDP-P6-GOV`). Re-checked rather
than assumed; both SHAs were read from `git rev-parse`, never retyped.

**No merge was performed by this card, because none was outstanding.** The deliverable "clean merge
to the integration branch" is satisfied by the certification commit landing on a branch that
already carries all phase work.

---

## 2. Required tests — actual output

| Command | Exit | Evidence |
|---|:---:|---|
| `make test-signal-ingest` | **0** | 28 packages `ok`; `--- PASS` × 1329; `--- FAIL` × 0; `^FAIL` × 0 |
| `cd d2-signalloom/apps/signal-ingest && go test ./...` | **0** | the target above wraps exactly this, plus `test-signal-segment-verifier` |
| `bats test/acceptance-spec-coverage.bats` | **0** | `ok` × 7, `not ok` × 0 |
| `make demo-signalloom-api-test TIER=contract` | **0** | `56 passed, 1 warning in 1.26s` |
| `go test -tags frostdb -run 'P95\|VolumeBenchmark\|Pruning' ./store/...` | **0** | `KPI Result: p95=2.096155ms @ N=12000 observations`; guard `p95=1.92249ms (ceiling=10ms), selectivity=1.33%` |
| `scripts/kanban-check.sh doctor --repo … --shortcode SLDP` | **1** | 1 exception — proved SLDP-disjoint, §5 |

`GOFLAGS=-buildvcs=false` was exported for every Go invocation: `go build`/`go test` fail in a git
worktree without it.

---

## 3. Falsification harness

Two scripts, run in a **dedicated detached worktree**
(`/home/andy/src/.worktrees/osramp-demo/sldp-v0.1.0/gov-falsify`, detached at `bd254546`) so no
mutation could reach the governor worktree. Confirmed after each round: the governor tree showed
only `correlation/redteam_cascade_ceiling.json` (a test-run artefact, §6) and the two new docs.

Design decisions that matter:

- **Positive control per probe.** A mutation is only evaluated if the unmutated test produced
  `--- PASS: <name>`. A zero-match test filter therefore cannot read as a survived mutant.
- **Kill requires an observed `--- FAIL: <name>` line**, not merely a non-zero exit. A build
  failure, a panic in an unrelated test, or a package-level `FAIL` without the named test is
  reported INCONCLUSIVE.
- **Write-site assertion before mutating.** The literal must occur exactly once in the target file
  or the harness refuses to write. This fired twice in round 1 and prevented two wrong-site
  mutations from being reported as kills.
- **Occurrence counting in Python, not `grep -F -c`.** `grep` on a multi-line literal counts lines
  matching any constituent line. Round 1 used `grep` and mis-reported a single-occurrence site as 2.
- **`trap ... EXIT INT TERM` reverts every edit**, and `set -e` is deliberately *not* used, because
  an expected non-zero test exit must not abort the run.

Round 1: 4 KILLED, 3 INCONCLUSIVE. Round 2 (after fixing the two site literals and the counting
defect): 4 KILLED, 0 INCONCLUSIVE.

**Round 3 was commissioned by the commitment-boundary advisor review and changed the verdict.** The
review asked two questions rounds 1–2 had not: *are all the Property-2 kills rejection tests, so a
verifier that rejected everything would pass?* and *are all the Property-1 kills blind to the tenant
predicate?* Both answers were yes.

- **M2c** (positive control) — inverting the digest comparison so valid segments are rejected turns
  `TestVerifyCorpusGeneratedByWriter` red. **KILLED.** The acceptance direction is live.
- **M1d** (tenant predicate) — removing `r.TenantID == tenantID` from `subjectkey/store.go:293`
  leaves `TestErasureSaga_ErasesOneSubjectOnly` green. **SURVIVED.**

**Final state: 9 mutations, 8 killed, 1 SURVIVED.** The survivor narrowed the certification:
cross-tenant erasure isolation is not certified. Rounds 1–2 would have certified it.

**The operative lesson, recorded because it is the reusable part: a falsification round that never
produces a survivor has not finished.** Seven consecutive kills read as thoroughness and were in
fact a sign that the mutations had all been chosen from the same mental model as the tests.

Full table with observed failure lines: certification §2.

---

## 4. Deliverables

| Deliverable | Location | Status |
|---|---|:---:|
| Mission certification with per-property evidence | `docs/signalloom/sldp-mission-certification.md` | Delivered |
| Published downstream contract (5 elements + evidence integrity) | `docs/signalloom/sldp-downstream-contract.md` | Delivered |
| Reconciled boundary map with per-verdict card attribution | certification §3 — 14 changed, 3 unchanged, 1 ownerless | Delivered |
| Per-property falsification results | certification §2 — 7/7 killed | Delivered |
| Consumability check naming each consumer file | contract §8 — 7 rows, all verified present | Delivered |
| Errata completeness, probe-derived | certification §5 — 28 cards, 28 covered, 0 missing | Delivered |
| Headline claims restated with measurement conditions | certification §1 — three figures reconciled for latency | Delivered |
| Qualifications | certification §6 — Q1, Q2, Q3 | Delivered |
| Passed downstream unresolved | certification §7 — 9 items | Delivered |
| Assumed rather than tested | certification §8 — 7 items | Delivered |
| Proposal errata block + Work Decomposition Result | Proposal Appendix `#### Errata — SLDP-P6-GOV` | Delivered |

---

## 5. The doctor exception, and why it is not an SLDP defect

`doctor` exits 1 with one exception: `FAST-EXIT / AGENT CRASH DETECTED: 29 task(s) finished
suspiciously fast (< 5.0s)`.

**Probe, not assertion.** The 29 task IDs were extracted from the doctor output, sorted, and
intersected two ways against the SLDP board: against the extracted SLDP card-ID list, and by
substring search of each ID against the full SLDP board dump. **Both intersections are empty.** The
tasks belong to `cpai-opencode`, `cpai-opencode-deep`, `cpai-opencode-fast`, two `antigravity`
`__home_agent__` pseudo-tasks, one `unknown` agent, and two literal `test-*` fixture cards.

This matches the known behaviour that `kanban doctor` mixes board and repo scope — several of its
checks ignore `--shortcode` entirely. Remediating tasks owned by other boards is explicitly outside
this card ("Do not touch these. Each is owned by another card or predates this board").

**This proof does not claim the doctor is green.** It claims, and shows, that its single exception
contains no SLDP card.

---

## 6. Working-tree hygiene

`make test-signal-ingest` rewrites the tracked artefact
`d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json`. The diff was inspected
before reverting: 12 changed lines, all of them `generated_at` and microsecond cycle latencies
(max 78 µs → 14 µs). **No verdict field changed** — every row still reads `<5ms SLA` and
`false-merge=0`. Reverted with `git checkout --` before staging, so it does not enter the
certification commit.

---

## 7. What this governor did NOT do

1. **Did not modify SLER, AMXD or SLCD source.** This mission defines contracts they consume.
2. **Did not change `P95GuardCeiling`.** Certification §6 Q1 recommends tightening it; changing a
   threshold is an implementation decision outside a governor's role boundary.
3. **Did not contact live infrastructure.** All evidence is from local harnesses and static probes.
4. **Did not alter any prior errata block.** The P6-GOV entry is appended; the pre-existing
   `#### Errata — SLDP-P6-GOV (bootstrap)` stub and the duplicate `SLDP-P6-1 (bootstrap)` stub were
   left in place per the shared-file rule.
5. **Did not push.** Merging is local-only; the principal pushes after review.
6. **Did not re-derive each merged card's internal findings from scratch.** Certification is from
   the proof documents plus a full independent re-run of the suites and the falsification probes.
