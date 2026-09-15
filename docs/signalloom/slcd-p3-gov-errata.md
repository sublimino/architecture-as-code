# Errata — SLCD-P3-GOV (status=fail)

> **Placement note.** This block is intended for the proposal's Errata appendix at
> `/home/andy/src/cp/osramp-demo/docs/Proposal — Signal Loom Coding Agent & Harness Detective Telemetry (2026-Q3).md`.
> That file sits in the principal checkout, which is **read-only** from the Governor worktree
> (`PermissionError: [Errno 13]` on append, verified 2026-09-15). The block is committed here
> instead so the evidence is durable and the dependency for SLCD-P4-PRE is satisfied by a
> committed artefact rather than by intent. **Action required:** copy this block verbatim into
> the proposal's Errata appendix. No prior entry is altered by it.

- **Created:** 2026-09-15 07:09:55+01:00
- **Last Updated:** 2026-09-15 07:09:55+01:00
- **Card:** SLCD-P3-GOV — Merge kanban wrapper telemetry and verify non-interfering read locks
- **Status:** `fail`
- **Branch:** `integration/slcd-v0.1.0` | **Integration ref:** `97f859c7e3de7bf531f93541a1397909d36461e4` | **Certification commit:** `97f859c7e3de7bf531f93541a1397909d36461e4`
- **Proof:** `docs/signalloom/slcd-p3-gov-proof.md`

**Verdict.** FAIL. The merge is sound and two real defects were found and repaired, but one
deliverable is **false** and one **breaches its KPI**. A governor may certify PASS on defects it
repaired; it may not certify PASS on a criterion it has just falsified.

**Merge state.** P3-1 (`4a0e8d62`) and P3-2 (`9e4889ed`) were already ancestors of the
integration head when this card began. This run is certify-and-prove, not merge-and-hope.

**D2 — "zero write-capable file opens": FALSIFIED.** The card's grep (`rg -n 'open\(.*"w'`) has
zero production matches and source inspection of all 21 production modules finds no
write-capable `open()`. At runtime the claim is false. Under `strace -f -y` over 4 s / 19
sweeps against the live controller, the merged Phase 3 path performs **52 write-capable opens**
(`O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0664`) on `kanban.sqlite-wal` and `kanban.sqlite-shm`,
and **298 fcntl POSIX record locks**, **6 of them F_WRLCK** (exclusive) on the WAL-index
recovery byte. Zero `flock`. Single root cause: `kanban.py:533`
`sqlite3.connect("file:...?mode=ro")` — `mode=ro` constrains the main database only; a WAL
connection must still open `-wal`/`-shm` `O_RDWR` and lock them. **Re-running the grep-based
guard would not have caught this**, because the opens come from `libsqlite3`, not a Python
`open()`. Contradicts `kanban.py:8` ("zero locks … zero writes") and the phase constitution
("never acquiring exclusive locks"). **Deliberately not repaired** — every remedy
(`immutable=1`/`nolock=1` risks torn reads on a hot database; dropping the SQLite surface loses
413→302 observations; re-documenting weakens a constitutional invariant) is a phase-owner
decision. Options analysed in proof §3.7.

**D4 — combined P2+P3 overhead: MEASURED, KPI BREACHED.** First single-process measurement of
both engines, using P2's own duty-cycle model and thresholds read from P2's source:
**27.188% CPU** vs a **1.0%** KPI (27×) and **44.05 MB** peak RSS vs **25 MB** (1.76×).
Attribution between P2 and P3 is **not** apportioned and is not claimed: P3-1's watcher alone
measures 0.060%, and one of the suite's three expected failures is a carried P2 defect
(`CARRIED DEFECT SLCD-P2-GOV-E`), so the P2 baseline may already breach independently.

**D1 — timing half: NOT OBTAINED.** Stated plainly rather than substituting the mock's
`delta=+8.0%`. The instrument is built and validated (2,192 controller records, 1,261 usable
pairs, counter-reset exclusion exercised, refuses to run against a stale controller), but two
runs did not yield a verdict: one killed deliberately after a syscall sweep contaminated its
idle baseline; a second which I wrongly reported as reaped on session teardown — it was alive
the whole time and merely still in its idle phase, and that false forensic claim was published
in an earlier revision of this block and is corrected here. Acting on it launched a third,
leaving two probes racing one output path; the improperly-detached one was killed and the
`setsid` one retained. It writes `/tmp/slcd-p3-gov-live-concurrency.json`. This does not
change the verdict — D1's lock half is falsified independently at the syscall layer.

**Defects found and repaired (commit `97f859c7e3de7bf531f93541a1397909d36461e4`).** The live controller writes
`latestTurnCheckpoint` as an **object**; every P3-1/P3-2 fixture writes a bare integer. One
divergence, two failures, neither visible to 242 green tests: (A) `kanban.py:569` did
`int(<dict>)` → `TypeError`, taking out the entire sessions path — **302/302 live sessions**;
(B) `kanban_watcher.py:339` caught that `TypeError` and fell back to `0`, reporting
`turn_count == 0` for every live session — **worse than the crash, because a fabricated zero
reads as data**. Repaired via `coerce_turn_count()` in the shared dependency both modules
already import, reading only allowlisted integer keys and never stringifying (`ref`/`commit`
are free-text-shaped git identifiers; a `str(raw)` fallback would convert a shape bug into a
Zero-Customer-Payload breach while still returning a plausible integer). After repair: 302
sessions / 233 with real turn counts, 413 from SQLite.

**Passing deliverables.** D3 frozen-schema conformance — **set equality** (not subset, not
spot-check) over 604 live records, exactly `{task_id, shortcode, role, elapsed_s}`. D5 clean
merge — verified by ancestry. D6 clean-disable — re-verified through the *merged* pair. Suite:
256 tests, 3 pre-existing expected failures; `test_sensor_integration` 4/4 OK.

**Hard blockers:** none of the five declared blockers fired. No field can carry prompt text,
file contents, a credential value or process memory; the field set remains a
structurally-enforced allow-list; no `proc.py` prohibited entry was touched.

**Concurrency hazard.** Three concurrent `git reset --hard` operations ran in this worktree
mid-card (`e881bfe4` → `0de73fcb` → `413ec5d6` → `f96b7d14`), silently discarding uncommitted
edits. The branch moved *forward* (sibling governors landed; four integration branches share one
line) and Phase 3 content survived. Work was re-applied idempotently and committed immediately.

**Self-correction.** An earlier draft of the clean-disable test asserted
`extract_supervisor_state(...) == []` and recorded `None != []` as a defect. It is not one —
the method declares `-> Optional[Dict[str, Any]]`. The test was corrected rather than the false
finding published.

**Blocking for P4-PRE.** The §3.7 SQLite-posture decision and the §6 overhead apportionment are
owner decisions this card declined to make unilaterally.

**Spend and token use:**

| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| SLCD-P3-GOV | (unresolved: `kanban-check.sh cost` not run — token budget exhausted) | ~199k | ~75 min | N/A |
