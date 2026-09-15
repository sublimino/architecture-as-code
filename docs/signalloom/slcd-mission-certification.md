# SLCD Mission Delivery Certification

**Card:** SLCD-P6-GOV — Reconcile acceptance wiring, run full test suite, and certify SLCD delivery
**Branch certified:** `integration/slcd-v0.1.0`
**Tip SHA at certification:** `87636da7f3652b64e2f9112d22709430d57ff494`
**Certified from:** `/home/andy/src/.worktrees/osramp-demo/slcd-v0.1.0/governor` (governor worktree, branch checked out — not a detached build)
**Date:** 2026-09-15
**Verdict:** **DELIVERED IN A NON-COLLECTING CONFIGURATION — NOT CERTIFIED CLEAN. Blocking items open.**

---

## 0. How to read this document, and how to falsify it

This is a re-verification, not a summary. Every phase Governor certified its own phase against the
tree as it stood at the time. Nothing in this document is carried forward from those records: every
suite named below was executed against the current merged tip in the session that produced this file,
and every figure quoted is from that execution. Where a run disagreed with a historical record, the
run wins and the disagreement is stated.

Every claim here is falsifiable by re-running the command printed beside it. If a command below
produces a different result on a later tree, this certification is wrong and should be superseded,
not patched.

**Three things this document deliberately does not do.** It does not average away the contradiction
between two performance measurements that disagree (§4.4). It does not describe the host-sensor suite
as green when it carries five expected failures (§3). And it does not relegate the lawful-basis gate
to an appendix (§6) — that gate is the single most consequential open item in the mission and it is
stated as a blocker, in the body, above the KPI table's good news.

---

## 1. Merge state — verified, not performed

P6-1 through P6-4 and P6-PRE were **already merged** into `integration/slcd-v0.1.0` by the phase
Governor loop before this card began. This card therefore discharged the "merge P6-1 through P6-4"
deliverable by **verifying** the merge, not by performing one. No merge commit was created here, and
no conflict resolution was required or attempted.

| Card | Implementation commit | Ancestor of tip | Probe |
| :--- | :--- | :--- | :--- |
| SLCD-P6-PRE | `82ac11f7` | YES | `git merge-base --is-ancestor 82ac11f7 HEAD` |
| SLCD-P6-1 | `b84a196b` | YES | `git merge-base --is-ancestor b84a196b HEAD` |
| SLCD-P6-2 | `041ac02a` | YES | `git merge-base --is-ancestor 041ac02a HEAD` |
| SLCD-P6-3 | `113edd26` | YES | `git merge-base --is-ancestor 113edd26 HEAD` |
| SLCD-P6-4 | `6108cf1f` | YES | `git merge-base --is-ancestor 6108cf1f HEAD` |

**Conflict-marker sweep:** `rg -l '^<<<<<<< '` across the tree (excluding `node_modules`,
`test-results`) returns **zero files**. No weakened-draft reintroduction occurred at any merge.

**No test surface was lost across the Phase 6 merges.** A shrunken suite still exits 0, so counts alone
prove nothing; the file set was diffed rather than counted. `git diff --diff-filter=D --name-only
82ac11f7..HEAD -- '*test*' '*spec*'` returns **zero deleted files**, and the host-sensor package grew
from **25** to **30** `test_*.py` files across the five Phase 6 merges (`f0781642`, `3d223e1b`,
`ef2c1b41`, `5522eb1e`, `b163a821`). Nothing was dropped in a conflict resolution.

**Anti-regression check on the load-bearing artefacts.** The two things a bad conflict resolution
would most plausibly have damaged were checked directly against the merged tip rather than assumed:

- `proc.py` `PROHIBITED_PROC_ENTRIES` parsed via `ast` → **exactly 17 entries**, matching the pinned
  count that `slcd-ci-parity` asserts. Members: `attr, clear_refs, cmdline, cwd, environ, fd, fdinfo,
  io, maps, mem, net, pagemap, root, smaps, smaps_rollup, stack, syscall`. Nothing removed.
- P4-2's CIDR artefact — see §5.

---

## 2. Required suites — all re-run against the merged tip

| Suite | Command | Result | Exit |
| :--- | :--- | :--- | :--- |
| Host sensor, confinement, anti-escape, TOCTOU | `make demo-agentmaxxing-host-test` | `Ran 457 tests in 41.257s` → `OK (expected failures=5)`; all bats suites `ok` | **0** |
| Go ingestion contract + correlation | `make test-signal-ingest` | all packages `PASS`/`ok` | **0** |
| Acceptance spec coverage guard | `bats test/acceptance-spec-coverage.bats` | `1..7`, `ok 1`–`ok 7`, zero failures | **0** |
| Browser acceptance (registry runner) | `make demo-signalloom-coding-agent-topology` | `8 passed (3.2s)` | **0** |
| Browser acceptance (repeat, independent) | `make demo-signalloom-coding-agent-topology` | `8 passed (3.1s)` | **0** |
| P5-GOV ingestion→render end-to-end | `bash d2-signalloom/scripts/slcd-p5-e2e.sh` | `Test Files 1 passed (1)`, `Tests 6 passed (6)` | **0** |

`bats test/acceptance-spec-coverage.bats` reports **zero coverage gaps** — test 2 (`every spec on disk
has exactly one registry row, and every row has a spec`) and test 7 (`every make: row names a target
whose recipe runs that spec`) both pass, so SLCD's new row is covered and no other mission's existing
rows regressed.

### 2.1 P6-3's spec is wired — verified live, and the one failing invocation is root-caused

The card required the spec be run "via the exact command the registry claims, not a developer
shortcut". `test/acceptance/SPEC-REGISTRY.tsv:69` declares the runner as
`make:demo-signalloom-coding-agent-topology`. That command was executed twice, independently, and
passed **8/8** both times. P6-4's wiring is verified live, not trusted from its own bats pass.

The card also lists a literal invocation, `cd test/acceptance && bunx playwright test
--config=playwright.config.ts coding-agent-topology.spec.ts`. **That invocation fails here**, and the
failure is reported rather than suppressed:

```
Error: browserType.launch: Failed to launch: Error: spawn /opt/google/chrome/chrome EACCES
1 failed · 7 did not run
```

It is not a flake and not a wiring defect. Five runs isolate it:

| # | Invocation | Result |
| :--- | :--- | :--- |
| A | `make demo-signalloom-coding-agent-topology` (registry runner) | **8 passed** |
| B | bare `bunx playwright test … ` + `PW_CHANNEL=chromium` | **8 passed** |
| C | bare, `--project` only, no `--config` | 1 failed, 7 did not run |
| D | bare, neither `--project` nor `--config` | 1 failed, 7 did not run |
| E | bare, both `--config` and `--project` | 1 failed, 7 did not run |

The discriminator is the browser channel, not the spec. `playwright.config.ts:13-15` defaults
`CHANNEL` to `"chrome"` unless `PW_CHANNEL` selects the bundled build. In this agent shell,
`test -x /opt/google/chrome/chrome` returns true (mode `0755 root:root`) while executing it returns
`Permission denied` — a sandbox exec restriction on `/opt`, not a file-permission or repository fact.
`PW_CHANNEL=chromium` is precisely the remedy the SPEC-REGISTRY row already documents for this case,
and it makes the bare command pass 8/8 (run B).

**Conclusion:** the spec is wired, runnable, and green. The bare-command failure is an execution-
environment precondition, documented in the registry, with a working remedy. It is recorded in §8.3 as
an environmental caveat rather than a product defect, because runs A and B both contradict a
product-defect reading.

**"8 passed" is the whole spec, not a subset a project happened to claim.** A Playwright project whose
`testMatch` claims no specs runs zero tests and exits 0, so the pass count was reconciled against the
source: `coding-agent-topology.spec.ts` declares **exactly 8** `test("…")` blocks (lines 287, 324, 396,
445, 498, 533, 594, 684), plus one `test.describe.configure` and one `test.beforeEach` which are not
tests. 8 declared, 8 run, 8 passed — no spec is silently unclaimed.

**One caveat on the run mode.** The spec sets `test.describe.configure({ mode: "serial" })`. Serial
mode aborts the remainder on first failure — which is exactly why the failing bare invocation reported
"1 failed, 7 did not run". A green serial run is a genuine green; a red one reports the status of only
one test. This does not affect the passing runs above, but a reader diagnosing a future failure should
know that the other seven results are absent rather than passing.

---

## 3. The green exit code carries five red assertions

`make demo-agentmaxxing-host-test` exits 0. Its unittest verdict line is **`OK (expected
failures=5)`**. Those five are not skips and not flakes — they are assertions that fail today and are
decorated `@unittest.expectedFailure` with a named carried-defect ID. A count-matched static sweep
(`rg -c 'expectedFailure'` = 5, run-reported = 5) confirms none is hidden:

| # | File : line | Test | Carried defect |
| :--- | :--- | :--- | :--- |
| 1 | `test_p2_governor_integration.py:435` | `test_zero_false_positives_on_renamed_binary_lookalikes` | **SLCD-P2-GOV-D** |
| 2 | `test_p2_governor_integration.py:611` | `test_merged_scan_and_classify_within_cpu_budget` | **SLCD-P2-GOV-E** |
| 3 | `test_p2_governor_integration.py:640` | `test_merged_engine_within_rss_budget` | **SLCD-P2-GOV-E** |
| 4 | `test_p3_governor_integration.py:280` | `test_combined_engines_within_cpu_and_rss_budget` | **SLCD-P3-GOV-E** |
| 5 | `test_p4_governor_integration.py:758` | `test_four_subsystem_overhead_against_kpi` | **SLCD-P4-GOV-E** |

**Two of the five are host-gated, and this bounds what the KPI-4 miss proves.** Rows 4 and 5 carry
`@unittest.skipUnless(LIVE_KANBAN.is_dir(), "no live kanban home")` *underneath* the
`expectedFailure` decorator. `functools.wraps` propagates `__unittest_skip__`, so on any host without
a live kanban home **those two become skips, not expected failures**, and the run would report
`expected failures=3`. The combined-subsystem overhead miss is therefore **measurable only on a host
with `~/.cline/kanban` present**. It was present here (verified: `test -d "$HOME/.cline/kanban"` →
exists), so rows 4 and 5 genuinely executed and genuinely failed in this session — but a CI lane
without that directory would report a *quieter* suite and a reader could mistake the reduced count for
progress. A static `rg -c 'expectedFailure'` sweep returns 5 either way and cannot detect this.

Related: the two files gate on `LIVE_KANBAN` differently. `test_p3_governor_integration.py:33` honours
a `KANBAN_HOME` environment override; `test_p4_governor_integration.py:84` hardcodes
`Path.home() / ".cline" / "kanban"`. The divergence means the two suites cannot be redirected to a
fixture kanban home together. Recorded as CERT-8.

Read plainly: **one of the five is the zero-false-positives KPI and four of the five are the
CPU/RSS overhead KPI.** Any certification that reports "`make demo-agentmaxxing-host-test` exits 0"
as evidence of KPI compliance would be reporting the process exit status of a suite whose KPI
assertions are red. That is stated here so no downstream reader can make that inference.

---

## 4. KPI table — each row evidenced by a named test result

The proposal's KPI table (§KPIs) states five targets. Each is evidenced below by the specific test
that measures it, with the measurement's definition stated, because in two cases the definition is
what decides the verdict.

| # | KPI (target) | Measured this session | Evidencing test | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| 1 | 6+ harnesses detected | **7** signatures | `classifier.py::HARNESS_SIGNATURES` (AST-parsed) + `test_classifier.py`, `test_p2_governor_integration.py` | **MET** |
| 2 | <2.0 s discovery latency | full merged sweep well inside 2.0 s | `test_p2_governor_integration.MergedOverheadTests::test_discovery_latency_within_two_seconds` → `ok` | **MET** |
| 3 | Exactly 0 bytes leaked | **0 canary hits / 7 canaries / 10,995 bytes scanned** | `test_p4_governor_integration.py` end-to-end leak audit + `test_mission_adversarial_leak_falsification.py` | **MET** |
| 4 | <1.0 % CPU, <25 MB RSS | **21.711 % duty cycle, 62.46 MB peak RSS** (combined 4-subsystem) | `test_p4_governor_integration.py:758` → **expectedFailure** | **NOT MET** |
| 5 | 100 % green acceptance suite | 457 python + all bats + 8/8 Playwright + 7/7 bats-coverage, **with 5 expected failures** | `make demo-agentmaxxing-host-test` | **MET WITH CARVE-OUT** |

### 4.1 KPI 1 — harness coverage

`HARNESS_SIGNATURES` in `classifier.py:65` parsed by `ast` yields **7** entries: `Harness.CLAUDE`,
`ANTIGRAVITY`, `CODEX`, `CPAI`, `OPENCODE`, `HERMES`, `AIDER`. Target is 6+; the proposal names six
(Claude, Agy, Codex, CPAI, OpenCode, Hermes) and the tree ships a seventh (Aider). A source count
alone would not evidence detection, so the classification tests in the 457-test run are the operative
evidence; the count establishes coverage breadth.

**Qualification carried from §3:** `SLCD-P2-GOV-D` is open. A **renamed binary lookalike is still
attributed to a harness**. Coverage is met; *soundness of attribution under adversarial rename is
not*. Any downstream use that treats a harness label as trustworthy against a motivated actor is
unsupported by this certification.

### 4.2 KPI 2 — discovery latency

`test_discovery_latency_within_two_seconds` asserts `elapsed < 2.0` on a full merged sweep
(`test_p2_governor_integration.py:662`) and returned `ok` in this session (`Ran 1 test in 0.278s`).
The measurement times a complete merged scan-and-classify sweep, not a single-process probe.

### 4.3 KPI 3 — zero bytes leaked

Re-run against the **fully merged Phase 6 tree**, not quoted from P4-GOV's earlier audit. This
matters because Phase 6 added new code (docs build tooling, acceptance fixtures) that had never been
inside the audited surface before. Results from this session's run:

```
[SLCD-P4-GOV] end-to-end leak audit: 15 records inspected over 5 concurrent rounds x 3 threads,
              10995 bytes scanned, 7 canaries, 0 hits
[SLCD-P4-GOV] pipeline mutation (to_network_info -> pass-through dst_ip): killed by leak audit
[SLCD-P4-GOV] non-export egress sweep: transcript.py + network.py emit no log, print or stderr write
[SLCD-P4-GOV] /proc/self sweep: 1 justified self-read(s) [('file_validator.py', 'fdinfo')], 0 unjustified
[SLCD-P4-GOV] procfs sweep: 55 modules scanned, 17 pinned entries, 0 observed-process reads
```

**Disagreement with the historical record, stated per §0.** P4-GOV's own errata records this audit as
scanning **11,025 bytes**; this session's re-run reports **10,995 bytes**. The re-run wins, per §0, and
the 30-byte difference is consistent with the audit's records carrying run-varying fields (timestamps,
elapsed values) rather than with a change in audited surface. The canary count (7) and hit count (0)
are identical across both runs, which is what the invariant actually turns on.

The audit is proven **able to fail**: the pipeline mutation control (`to_network_info` degraded to a
pass-through of `dst_ip`) is killed by it. A zero-hit result from an audit that cannot fail would be
worthless; this one is not that.

The procfs sweep scanned **55 modules** — up from 48 at P4-GOV — which is the Phase 6 surface growth
being audited rather than assumed. Zero observed-process reads of any prohibited entry. The single
`/proc/self` read (`file_validator.get_mount_id_from_proc_fdinfo`) is a self-read of a descriptor the
sensor already holds, pinned by set equality so both its removal and any new self-read turn the suite
red.

### 4.4 KPI 4 — CPU and memory overhead: **NOT MET**, and two tests disagree

This is the row that most needs the measurement definition stated, because **the merged tree contains
two overhead measurements that reach opposite verdicts**, and reporting either alone would be
misleading.

**Measurement A — `test_mission_performance_overhead.py` (P6-1). Passes.**
`test_cpu_duty_cycle_budget` computes `duty_cycle_pct = (avg_cpu_per_sweep / 5.0) * 100.0` and
asserts `< 1.0`. `test_memory_rss_envelope` asserts a **tracemalloc allocation** peak `< 25.0 MB`.
Both returned `ok` in this session. So this suite measures a **subset of subsystems**, normalises CPU
to a **5-second polling cadence**, and uses **allocation footprint** rather than process RSS.

**Measurement B — `test_p4_governor_integration.py:758` (P4-GOV). Fails, and is marked
expectedFailure.** `test_four_subsystem_overhead_against_kpi` measures the combined P2+P3+P4-1+P4-2
pipeline against process RSS at the shipped `collector.py` / `kanban_watcher.py` poll defaults. This
session's figures:

```
[BENCHMARK] Combined P2+P3, 10 sweeps:
            duty_cycle_cpu=12.581%  peak_rss=62.46MB   (KPI: <1.0% CPU, <25MB RSS)
[BENCHMARK] Combined P2+P3+P4-1+P4-2, 10 sweeps:
            duty_cycle_cpu=21.711%  peak_rss=62.46MB   throughput=9.21 sweeps/s
```

**The verdict follows Measurement B**, and the reason is a construct mismatch in A that was checked
rather than asserted:

- **A's cadence is not the shipped cadence.** A divides by `5.0`. B divides by
  `SWEEPS * POLL_INTERVAL_S` where `POLL_INTERVAL_S` is `0.5` — and
  `test_p4_governor_integration.py:746 test_duty_cycle_model_matches_the_shipped_default` *asserts*
  that `collector.py` ships `interval_s: float = 0.5` and `kanban_watcher.py` ships
  `poll_interval_s: float = 0.5`. A's divisor is therefore **ten times the interval that ships**, and
  a duty cycle is linear in that divisor. The KPI cannot be discharged by a projection under a
  configuration the product does not use.
- **A's memory metric is not RSS.** A asserts a **tracemalloc allocation** peak. B reads
  `resource.getrusage(RUSAGE_SELF).ru_maxrss`. A KPI stated in MB RSS is not satisfied by Python
  allocation accounting, which excludes interpreter overhead, C-extension allocations and arena
  fragmentation — precisely the memory an operator pays for.
- **A measures a subset; B measures the combination.** The KPI is about the sensor on a workstation.

**Honest qualification on B's RSS figure.** B's `62.46 MB` is **absolute process peak RSS, not a
baseline-subtracted delta**, so it includes the CPython interpreter. Measured on this host:
interpreter-only peak RSS is **10.59 MB**, and **merely importing the sensor modules**
(`collector`, `classifier`, `kanban_watcher`, `network`, `transcript`) takes it to **27.03 MB** —
already over the 25 MB KPI before a single sweep executes. The KPI is therefore missed on two
independent grounds: the import-time floor exceeds it, and the running figure exceeds it by ~2.5×.
Stating this makes the claim smaller and truer than "62.46 MB of telemetry overhead" would have been.

**The decisive evidence is not the arbitration at all.** Four `unittest.expectedFailure` decorators
sit on the KPI-4 assertions (§3). Those are a committed admission by the implementing phases that the
KPI does not hold. If Measurement A discharged KPI-4, the decorators would be wrong and would have
been removed; they were not. A is the outlier requiring reconciliation, not a counterweight.

**The alarm is not silenced.** A concern worth closing: if `unittest` treated an unexpected success
silently, those four decorators would permanently mask a future fix. It does not — verified directly
on this interpreter: an `@unittest.expectedFailure` test that passes yields
`FAILED (unexpected successes=1)` and `wasSuccessful() == False`. When someone fixes the overhead, the
suite goes red and forces the decorators off. The carve-out is self-expiring.

Measurement A remains a useful regression guard on its own slice. It is not evidence for this KPI and
is not used as such here.

P4-GOV's own errata records the same breach at **36.05 % CPU and 42–60 MB RSS** across three paired
runs. This session measured **21.711 % and 62.46 MB** on a differently-loaded host. The figures differ;
**the verdict does not, in either direction** — every measurement of the combined pipeline ever taken
on this tree exceeds the KPI by more than an order of magnitude on CPU and by roughly 2.5× on RSS.
The KPI was not loosened to reach a pass, and the failing assertions were left failing rather than
deleted.

### 4.5 KPI 5 — acceptance suite green

Green at the process boundary across every required runner (§2), **with the five-expected-failure
carve-out of §3 disclosed in the same breath**. Stated without that carve-out this row would be true
and misleading; stated with it, it is true and useful.

---

## 5. P4-2's CIDR list and false-positive rate — current, committed, and short of target

**Currency, proven by diff rather than by presence.** A file listing would show the artefact exists;
it would not show it survived four subsequent merges unchanged. Both were checked:

| Probe | Command | Result |
| :--- | :--- | :--- |
| Introducing commit is an ancestor | `git merge-base --is-ancestor 206a7fea HEAD` | **YES** |
| File unchanged since that commit | `git diff --quiet 206a7fea HEAD -- …/data/inference_providers.json` | **unchanged** |
| List version | JSON `list_version` | `2026-09-15.1` |
| Content scale | parsed JSON | **7 providers, 32 ranges** |

The list was neither dropped nor allowed to go stale by a later phase's conflict resolution. Its
tiered `attribution` model (`dedicated` / `loopback` / `shared`) is load-bearing, not advisory
metadata — a `shared`-tier match without harness corroboration must classify as `unknown`.

**False-positive rate, measured this session:**

```
[SLCD-P4-2] untiered CIDR:                              TP=11 FP=7  precision=61.1% recall=91.7%
[SLCD-P4-2] tiered:                                     TP=11 FP=1  precision=91.7% recall=91.7%
[SLCD-P4-2] shared-tier check suppresses 6 false positives; 1 residual
[SLCD-P4-2] tiered + cgroup-corroborated (SHIPPED):     attributed=12 TP=11 FP=1 FP-rate=8.3%
[SLCD-P4-2] residual false positive:                    160.79.104.10:443 (other-app)
[SLCD-P4-2] untiered (the proposal's method):           attributed=18 TP=11 FP=7 FP-rate=38.9%
```

The proposal's target is **zero** false positives. The shipped detector measures **8.3 %**. This is a
**KPI miss**, and it is recorded as one. It is worth noting what the tiering bought: the proposal's
own untiered method measures 38.9 %, so P4-2's design reduced the rate by a factor of ~4.7 — genuine
engineering progress that nonetheless does not reach the stated target. The residual FP is an
unrelated local application holding a socket inside Anthropic's dedicated range.

**Explicitly not relied upon:** the socket detector's own unit tests pass. They would also pass
against an empty or default range list, so they are not cited as evidence of list currency. The diff
against `206a7fea` is.

---

## 6. Lawful basis — **BLOCKING. Workstation collection must not be enabled.**

This section is in the body, above nothing and below only the test results it depends on, because a
final Governor that files this as a footnote has failed at the exact moment it mattered.

`docs/signalloom/slcd-p1-5-lawful-basis.md` exists in the merged tree. `rg -n 'OPEN'` returns
matches. Its frontmatter, quoted verbatim:

```yaml
status: NOT ADOPTED — no controller has signed §8; no employee-representative instrument has been
        started in any jurisdiction that requires one
collection_state: DISABLED — see §0. Workstation collection must not be enabled while any
        OPEN-SLCD item stands
```

A programmatic count of distinct `OPEN-SLCD-<n>` identifiers in that document returns **40**. The
assessment states that **22 of the 40 block collection** — 7 unconditionally and 15 for the
jurisdictions or conditions they name.

**Therefore, and as SLCD-P1-GOV required be carried forward to this gate:**

> **Workstation collection is NOT authorised and must remain DISABLED.** The mission's technical
> deliverables are complete and tested; its lawful basis is not established. No controller has adopted
> the assessment. No works council, CSE, OR, RSU or union has been approached in any jurisdiction. The
> in-scope workstation roster does not exist, so no jurisdiction can even be evidenced out of scope.

The assessment's §0.3 anticipates this Governor by name — *"a Governor, phase gate or acceptance run
must not mark SLCD-P1-5 'done' and thereby read the gate as lifted"*. SLCD-P1-5 is `done` on the
board. **The gate is not lifted.** Delivery of the assessment and lifting of the gate are different
facts and this certification records them as such.

The sharpest open questions inside the assessment, named because they are decision-forcing rather
than administrative:

- **`OPEN-SLCD-8`** — whether `metrics.*` (`step_count`, `tokens_in`, `tokens_out`, `tool_counts`) is
  necessary at all. Attribution is satisfied without a single work-rate field. If those fields are not
  necessary they fail Limb 2 outright, regardless of how the balancing test resolves.
- **`OPEN-SLCD-7`** — continuous rather than periodic sampling. `kanban.elapsed_s` sampled continuously
  reconstructs working hours directly rather than by inference. The assessment names this as the
  weakest link in its own necessity argument.
- **`OPEN-SLCD-9`** — transcript reading, which largely falls away if `OPEN-SLCD-8` resolves against
  `metrics.*`. The two should be decided together.
- **`OPEN-SLCD-1`** — the in-scope roster does not exist, which is why no jurisdiction can be scoped in
  or out.
- **`OPEN-SLCD-4`** — nothing in the system technically prevents the prohibited uses today.

---

## 7. P6-2 documentation — reflects the merged system, with one caveat

P6-2 shipped five documentation surfaces (`041ac02a`): the detection runbook, the inference-provider
range reference, the lawful-basis reference, the detective-telemetry architecture page, and the
zero-customer-payload page, plus `docs.spec.ts` and `docs-render-check.sh` wiring.

Spot-checked against the merged code rather than trusted:

| Doc claim | Checked against | Result |
| :--- | :--- | :--- |
| Runbook §"classification confidence score" describes score bands and an `unknown` class for generic runtimes in an isolated cgroup with egress to a known inference CIDR but no distinctive binary or transcript schema | `classifier.py`, `network.py` tiered attribution | **Consistent** — matches the shipped `shared`-tier-without-corroboration → `unknown` rule |
| Runbook cross-references the Inference Provider CIDR Reference for destination triage | `data/inference_providers.json`, `slcd-p4-2-cidr-ranges.md` | **Consistent** — target exists and is current (§5) |

**Caveat recorded, not resolved:** the documentation describes the detection and confidence model
accurately, but this certification did not find a documentation surface that states the two live KPI
misses — the 8.3 % socket false-positive rate (§5) and the CPU/RSS breach (§4.4). An operator reading
only the runbook would not learn that the shipped detector misses both. That is a documentation gap
against the *merged system's actual measured behaviour*, and it is listed in §8.

---

## 8. Outstanding items — the complete list across all six phases

This list is the point of this document. Nothing below is closed by this certification.

### 8.1 Blocking — must be resolved before workstation collection

| ID | Phase | Item |
| :--- | :--- | :--- |
| **OPEN-SLCD-1 … OPEN-SLCD-40** | P1 | 40 open items in the Legitimate Interest Assessment; **22 block collection** (7 unconditional, 15 jurisdictional). `collection_state: DISABLED`, `status: NOT ADOPTED`. See §6. |
| **SLCD-P4-GOV** | P4 | Governor verdict recorded as **BLOCKED**. Not cleared by P5-GOV, not cleared by this card. |
| **SLCD-P2-GOV** | P2 | Governor verdict recorded as **`status=fail proceed=no`**. A `proceed=no` gate is open upstream and four phases have now passed it. Explicitly *not* cleared here. **What it gated matters as much as that it is open:** P2-GOV's failure is in *harness attribution soundness* (`SLCD-P2-GOV-D`, renamed-binary spoofing) and in *overhead* (`SLCD-P2-GOV-E`). P2-GOV's own errata states the inheritance rule — "any Phase 3 deliverable whose correctness rests on harness attribution being non-spoofable, or on the engine detecting a real agent, is void until D and F close." That rule was written for Phase 3; **it applies with equal force to Phases 4, 5 and 6, which also passed the gate.** Every downstream conclusion that treats a harness label as trustworthy against a motivated actor — including the dashboard's rendered attribution and the socket detector's cgroup corroboration — inherits this defect. That inheritance is itself a finding and is recorded here as one. |

### 8.2 KPI misses — evidenced, not disputed

| ID | Item | Measured | Target |
| :--- | :--- | :--- | :--- |
| **SLCD-P2-GOV-E / P3-GOV-E / P4-GOV-E** | Combined-subsystem CPU and RSS overhead | 21.711 % CPU, 62.46 MB RSS (this session); 36.05 % / 42–60 MB (P4-GOV) | <1.0 % CPU, <25 MB RSS |
| **SLCD-P4-2 FP rate** | Socket attribution false positives | 8.3 % (shipped, tiered + cgroup-corroborated) | 0 |
| **SLCD-P2-GOV-D** | Renamed-binary lookalikes attributed to a harness | spoof succeeds | zero false positives |

### 8.3 Process and record-keeping gaps

| ID | Item |
| :--- | :--- |
| **CERT-1** | **Doctor is not zero-exception.** See §9. Two exceptions remain, neither remediable by this card. |
| **CERT-2** | **Errata trail is incomplete.** Ten merged cards have **no** errata block in the proposal Appendix: **P3-GOV, P4-PRE, P4-1, P5-PRE, P5-1, P5-2, P6-PRE, P6-1, P6-2, P6-3**. (List derived by `comm` of the `^#### Errata — SLCD-` headings against the 30-card board set, not written by hand.) |
| **CERT-2a** | **Two governor errata blocks exist only as uncommitted working-tree edits and are one `git checkout` from deletion.** The committed proposal at `HEAD` contains **17** errata blocks; the working tree contains **19**. The two that exist *only* in the working tree are **SLCD-P4-GOV and SLCD-P5-GOV** — including the `status=blocked` P4-GOV record that §8.1 of this certification relies on. Every card in this mission is instructed to edit the proposal and forbidden to commit it, so the durability of the mission's own audit trail depends entirely on the principal committing or otherwise preserving those edits. **This is the most fragile item in the record and it is not self-healing.** |
| **CERT-3** | **Work Decomposition `Result` cells are stale.** **Thirteen** rows read `Pending`: **P2-GOV, P3-GOV, P4-PRE, P4-1, P5-PRE, P5-1, P5-2, P6-PRE, P6-1, P6-2, P6-3, P6-4** — and **P6-GOV, this card's own row**, which is stated explicitly because a self-referential count that silently omits the author's row is the exact defect this list exists to catch. Note P2-GOV reads `Pending` in the table while its errata records `status=fail proceed=no` — the table understates a known-failed gate. |
| **CERT-4** | **Documentation does not disclose the live KPI misses** (§7). No shipped operator-facing page states the 8.3 % FP rate or the overhead breach. |
| **CERT-5** | **Two orphan worktrees remain registered** (§9): `/tmp/slcd-baseline-p4`, `/tmp/sler-baseline-p0`. Not removed — one belongs to another mission and removal is a destructive act outside this card's authority. |
| **CERT-6** | **The `/goal` command named in this card's One-shot execution protocol does not exist** in the executing harness. The stated budget and wall-clock ceiling were honoured as declared constraints instead. |

| **CERT-8** | **The two KPI-4 combined-overhead tests are host-gated, and gated inconsistently** (§3). `skipUnless(LIVE_KANBAN.is_dir())` sits under `expectedFailure` on `test_p3_governor_integration.py:281` and `test_p4_governor_integration.py:759`, so on a host without `~/.cline/kanban` the KPI-4 miss is silently unmeasured and the suite reports `expected failures=3`. `p3` honours a `KANBAN_HOME` override; `p4` hardcodes the path, so the pair cannot be redirected to a fixture home together. |
| **CERT-9** | **Two divergent implementations of SLCD-P6-3 now exist as refs.** `113edd26` is merged; `77e82c6d` was rescued from dangling state by this card (§9) and is confirmed **not** an ancestor of HEAD. Rescuing it was the right call — it was otherwise collectable — but the resulting condition is a record-keeping item: a future reader finds two P6-3 implementations and no note saying which is authoritative. **`113edd26` is authoritative;** `rescue-77e82c6d` is preserved evidence only and should be deleted or annotated once the principal has reviewed it. |
| **CERT-7** | **The card's literal bare `bunx playwright test` invocation fails in the agent execution shell** (§2.1). Not a product defect: `PW_CHANNEL=chromium` — the remedy the registry row documents — makes it pass 8/8, and the registry-declared `make` runner passes 8/8 unaided. Recorded so a future runner is not surprised. |

### 8.4 Structural caveat on this certification's own coverage

Several cards warned that a single clean run does not prove a race-handling path was exercised
(clock-skew, ancestry races, lock contention). This certification ran the browser acceptance suite
**twice** and the P2/P3 Governor suites as a separate targeted execution, which raises confidence but
does **not** constitute a soak test. **No claim is made here that the concurrency paths are proven by
repetition.** A future auditor wanting that assurance should run the suites under sustained repetition;
this document does not substitute for it.

---

## 9. Doctor — two exceptions remain, and why they are not clearable here

The doctor was run **against the merged branch tip from the governor worktree with
`integration/slcd-v0.1.0` checked out** — not against a detached build and not against a task
worktree. Tip: `87636da7f3652b64e2f9112d22709430d57ff494`.

**Two `kanban-check.sh` binaries exist and they disagree.** This is itself a finding. The repo copy
(`scripts/kanban-check.sh`, 13 KB) and the bundled supervisor copy
(`/tmp/council/skill-test2/Tools/kanban-check.sh`, ~5.7 k lines) have different `duration-check`
implementations: the repo copy iterates **all** of `sessions.json` with no board-membership or
shortcode filter; the bundled copy filters to active, non-trashed cards carrying the shortcode. Both
verdicts are reported.

| Doctor | Exceptions | Status |
| :--- | :--- | :--- |
| Bundled (board-filtered) | DOC-3, DOC-5 | UNHEALTHY (2) |
| Repo copy (unfiltered) | 29 fast-exit sessions | UNHEALTHY (1) |

**Remediated by this card:** **DOC-7** — 8 unreferenced commits at risk of loss on `git gc` were
rescued with `git branch rescue-<short-sha> <sha>`, the fix the doctor itself prescribes. This is
non-destructive (it creates refs only) and took the bundled doctor from 3 exceptions to 2. The rescued
set includes `77e82c6d`, an *unmerged* SLCD-P6-3 implementation commit distinct from the merged
`113edd26`, which would otherwise have been collectable.

**Not remediable by this card, with reasons:**

- **DOC-3 (principal checkout dirty)** — the two modified files are `Proposal — Signal Loom Coding
  Agent & Harness Detective Telemetry (2026-Q3).md` and `Proposal — Signal Loom Enforcement and
  Response (2026-Q3).md`. This card is **required** to edit the first (to append its errata) and
  **forbidden** to commit it. The second belongs to the SLER mission. DOC-3 is therefore structurally
  unclearable by any card operating under these instructions; clearing it requires the principal to
  commit or discard the proposal edits.
- **DOC-5 (orphan worktrees)** — `/tmp/slcd-baseline-p4` and `/tmp/sler-baseline-p0` are real,
  registered, detached-HEAD worktrees. Removing them is a delete of another card's working state; one
  belongs to a different mission entirely. Left in place and recorded as CERT-5.
- **Repo-copy fast-exit (29 sessions)** — the listed IDs include `test-card-1788295874373`,
  `test-sqlite-1788296735358`, `__home_agent__:kanban:antigravity` and `__home_agent__:osramp-demo:
  antigravity`, none of which are SLCD board cards. The bundled doctor's board-filtered duration-check
  does not raise on the SLCD board. This is cross-mission runtime residue in `sessions.json`, not a
  repository condition, and no change to this repository can clear it.

**The card's deliverable "a zero-exception doctor report against the merged branch tip" is therefore
NOT met.** It is recorded as CERT-1 rather than worked around by substituting a different ref or by
selectively quoting the doctor that happens to look better.

---

## 10. Certification statement

Against `integration/slcd-v0.1.0` at `87636da7f3652b64e2f9112d22709430d57ff494`:

**Delivered and verified.** The six-phase technical build is complete and merged. Every required suite
passes at the process boundary against the merged tip. The Zero-Customer-Payload invariant holds under
an audit re-run against the fully merged Phase 6 surface, with zero canary hits and a working mutation
control proving the audit can fail. The `proc.py` prohibited set is intact at 17 entries. P4-2's CIDR
artefact is present, current, and byte-identical to its introducing commit. P6-3's acceptance spec is
wired and green through the exact registry-declared runner, verified twice. Three of five KPIs are met.

**Not certified.** Two KPIs are missed and the misses are measured, not estimated: combined-subsystem
overhead exceeds its CPU budget by more than an order of magnitude and its RSS budget by ~2.5×, and
socket attribution runs an 8.3 % false-positive rate against a zero target. A `proceed=no` gate from
SLCD-P2-GOV and a `BLOCKED` verdict from SLCD-P4-GOV are both still open. The acceptance suite's green
exit code carries five failing assertions. The doctor is not zero-exception.

**Above all.** **Workstation collection is not lawfully grounded and must remain DISABLED.** Forty
items are open in the Legitimate Interest Assessment, twenty-two of them blocking. No controller has
adopted it. No employee-representative body has been approached anywhere. This is not a documentation
gap to be closed later — under GDPR it is the condition precedent for the system operating at all on a
real employee workstation, and this mission's technical success does nothing to satisfy it.

**Verdict: DELIVERED IN A NON-COLLECTING CONFIGURATION — NOT CERTIFIED CLEAN.**

The qualifier is load-bearing, not decorative. "Delivered" unqualified reads as *done*, and what
shipped cannot lawfully collect. It also forces a second admission that matters: **every measurement
in this document — the KPI-4 overhead figures, the 8.3 % false-positive rate, the latency, the leak
audit — was taken with collection enabled by test-only bypass.** No production-equivalent measurement
of this system exists, because no lawful production configuration of it exists. The engineering is
sound and well-tested against fixtures and a live host under test conditions. The system must not be
switched on.

---

*Produced by SLCD-P6-GOV. Every command cited above is re-runnable; any of them contradicting this
document supersedes it.*
