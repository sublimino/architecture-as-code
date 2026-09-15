# SLCD-P2-GOV — Phase 2 Governor Certification Proof

**Card:** SLCD-P2-GOV — Merge process tree detective engine and verify zero false-positive collisions
**Role:** governor
**Depends on:** SLCD-P2-1, SLCD-P2-2
**Integration branch:** `integration/slcd-v0.1.0`
**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/slcd-v0.1.0/governor`
**Executed:** 2026-09-15 05:38:15+01:00
**Verdict:** **FAIL — certification withheld.** Three defects found and fixed; three carried findings block certification, the gravest being that the merged engine detects **nothing at all** in this execution context.

---

## 1. Verdict summary

This card could not certify what it was chartered to certify. The merged tree is **materially better** than it was at the start — three real defects were found and fixed, two of which would have poisoned every downstream phase. But three findings remain that no amount of re-running makes green, and the third (§12) is severe enough that the zero-false-positive result reported below must be read as **vacuous in this environment**: the engine achieves zero false positives by attributing nothing whatsoever.

| Deliverable | Outcome |
| :--- | :--- |
| Zero false-positive collisions, mixed real-fixture stress test | **PARTIAL and VACUOUS** — zero against 1,466 live host processes, but see §12: zero true positives too; **fails** against renamed-binary lookalikes (carried defect D) |
| Merged tree passes every P2-1 cmdline-access guard | **PASS** |
| Merged tree passes every P2-2 spoofing test | **PASS** (unchanged; but see carried defect D for the case the suite does not model) |
| CPU/RSS overhead meets KPI after classifier integration | **FAIL** (carried defect E) |
| Merged output conforms to P1-1 frozen schema | **PASS** |
| Clean merge of P2-1 and P2-2 into `integration/slcd-v0.1.0` | **PASS** — already landed before this card ran |
| P1-4 negative-security regression against merged tree | **PASS** — 16/16 |

---

## 2. Merge state

The merge deliverable was already satisfied when this card began. Both merges are ancestors of the integration head; no re-merge was performed and no conflict resolution was required.

| Ref | SHA | Ancestor of HEAD |
| :--- | :--- | :--- |
| SLCD-P2-1 merge (`merge: integrate SLCD-P2-1 non-intrusive procfs process scanner`) | `037884520788da7fddc6857c9ebb2eed0624400b` | YES |
| SLCD-P2-2 merge (`merge: integrate SLCD-P2-2 multi-signal harness process ancestry classifier`) | `dd031c681c6594abf7cb42e8d2607ba54c75cf5f` | YES |
| `refs/heads/integration/slcd-v0.1.0` at card start | `14d56cef21f4e513e806d8869ce598a25b8341b1` | HEAD |

Verified by `git merge-base --is-ancestor` against each, exit status 0 in all four cases.

Because no conflict resolution occurred, the failure mode *"merging with a conflict resolution that silently drops one of P2-1's or P2-2's negative tests"* could not apply. Test-count regression was nonetheless checked directly — see §3.

---

## 3. Test-count integrity — a silent 17-test coverage hole

Running the required command alone is not sufficient evidence of coverage, because a suite that fails to load is silent. Static test-method count was compared against runtime count per file.

```
STATIC TOTAL (rg -c '^\s+def test_' over test_*.py) : 205
RUNTIME TOTAL (python3 -m unittest <module>, summed) : 188
DELTA                                                : 17
```

The 17 missing tests are the whole of `test_hasher.py`, which reports `rc=5 / NO TESTS RAN` under `unittest` and is silently omitted by `unittest discover`. Cause: `test_hasher.py` and `test_file_validator.py` are **pytest-style** suites — bare classes with fixture functions, no `unittest.TestCase` base — so `unittest` cannot collect them.

**Ownership:** both files arrive from the **AMXO** board (`AMXO-P4-3` at `caaf7550`, `AMXO-P4-4` at `d5005ee7`), not from SLCD Phase 2. This is not a P2 regression and it is explicitly out of this card's scope to change. It is recorded because it means **the card's own required test command under-reports coverage by 17 tests**, and any future SLCD card that adds a pytest-style suite will go silently uncovered.

Both were verified separately and pass:

```
$ PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python3 -m pytest test_hasher.py test_file_validator.py -q
33 passed in 0.10s
```

All SLCD Phase 2 suites (`test_proc`, `test_collector`, `test_classifier`) are `unittest`-native and are fully collected, so the P2 surface itself has no hole.

---

## 4. Defects found and fixed

### Defect A — cross-card call-signature drift (fixed)

`ProcessTelemetryCollector.classify_process()` — P2-1's wrapper around P2-2's classifier — passed `pid=` to a function whose parameter is `candidate_pid=`.

```
$ python3 -c "...collector.ProcessTelemetryCollector().classify_process(pid=os.getpid())"
TypeError: HarnessAncestryClassifier.classify_process() got an unexpected keyword argument 'pid'
```

Every invocation raised. Neither card's suite called this wrapper, so neither could see it. This is precisely the class of failure that only a merged-tree run surfaces.

**Fix:** `collector.py` — `candidate_pid=pid`. **Pinned by:** `CollectorClassifierWiringTests` (3 tests).

### Defect B — a host-level fact used as a process-level signal (fixed)

`corroborate_direct_harness()` admitted `check_session_marker()` into the *sufficient* set for a process that matched only a generic runtime comm. That function is a `Path.exists()` under `$HOME`. It says nothing whatsoever about the PID under evaluation.

Consequence, reproduced on this host:

```
comm=node exe=/usr/bin/node  ->  match=True harness=Harness.CODEX conf=0.95
  signals: ['comm_match', 'exe_provenance_verified', 'session_marker_verified']
control (identical process, no session marker) -> (False, Harness.UNKNOWN, 0.0)
```

**Any ordinary Node.js process on any host where Codex has ever been installed was attributed to Codex at 0.95 confidence.** `~/.codex` exists on this machine.

**Why P2-2's suite could not see it.** `setUp` binds `SessionMarkerCorroborator` to an empty `tempfile.TemporaryDirectory()`, so the marker is absent for every test that does not explicitly create it. The suite is structurally blind to a rule keyed on `$HOME`.

**The contradiction this exposes.** Two tests in P2-2's suite described a **byte-identical process** — `comm="node"`, `exe_target="/usr/bin/node"` — and asserted opposite verdicts:

| Test | Asserts |
| :--- | :--- |
| `test_benign_node_process_not_codex` (L233) | `UNKNOWN`, confidence `0.0` |
| `test_true_positive_codex_with_session_marker` (L294) | `CODEX`, confidence `≥0.90` |

The only difference is a directory in `$HOME`. On a real workstation that directory is present, so `test_benign_node_process_not_codex` described a state that **cannot occur on any host where Codex was ever installed**.

**Why the existing zero-false-positive benchmark could not catch it.** `test_zero_false_positive_stress_benchmark` enumerates 45 ordinary developer tools — and omits `node` and `python3`, the only two comm names its own signature table matches. It is a positive control that cannot fail. It passed while blind.

**Fix:** `classifier.py` — `has_session` removed from the sufficient set in the primary-comm and secondary-comm branches; retained as an additive corroboration signal.

**Recall cost: zero, and this was verified rather than assumed.** Ground truth on this host:

```
$ readlink -f "$(command -v codex)"
/home/andy/.local/lib/node_modules/@openai/codex/bin/codex.js     -> matches exe_path_patterns '@openai/codex'
real Hermes node (pid 50783): /home/andy/.hermes/node/bin/node    -> matches exe_path_patterns '\.hermes/node/bin/node'
```

Every genuine harness is identified by **binary provenance**, which is a process-specific signal and remains sufficient. The session marker was only ever load-bearing for a *fixture* that pretends Codex runs from `/usr/bin/node` — which is not how it is installed. The two affected fixtures were corrected to the realistic install path; **every assertion in them is unchanged**.

**Pinned by:** `HostMarkerSufficiencyTests` (7 tests) under a hostile `AllMarkersPresentCorroborator` in which every marker is present.

### Defect C — the same category error on the unresolvable-exe path (fixed)

The dominant real-world instance, and one that only the live-host sweep revealed. When `/proc/<pid>/exe` is unreadable — true for kernel threads and for every process owned by another user — the classifier fell back to **comm plus host-level session marker**:

```python
if has_session or proto_verdict is True:
    return (True, sig.harness, 0.85, ["comm_match"], ...)
```

`comm` is attacker-controlled via `prctl(PR_SET_NAME)`. This branch therefore attributed any comm-spoofed process on the machine, and it fired constantly. Measured on the live host before the fix:

```
61 live processes attributed with signals=('comm_match', 'session_marker_verified')
  e.g. pid=50783 -> codex, pid=288756 -> claude, pid=262174 -> antigravity,
       pid=521976 -> hermes, pid=46838 -> opencode
```

Sixty-one attributions resting on nothing but a process name and a directory listing. This directly contradicts the anti-spoofing property P2-2 claims.

**Fix:** with no binary provenance, the only admissible corroboration is an observed socket (`proto_verdict is True`). After the fix the same sweep reports **zero** unjustified attributions.

**Pinned by:** `test_whole_population_harness_attribution_is_justified`, which sweeps the entire live process table and requires every attribution to carry `exe_provenance_verified`, `process_tree_ancestry`, or `socket_protocol_verified`.

---

## 5. Zero-false-positive stress test

### 5.1 A correction to this Governor's own method

The first stress run reported 7 false positives among spawned ordinary tools (`git`, `make`, `sleep`, `python3` → `codex@0.7`). **That reading was wrong and the test was at fault, not the product.** The test runner is itself a descendant of a coding-agent session, so tools spawned as its children inherit *genuine* harness ancestry, and attributing them is the feature working correctly — linking child compiler/tool processes to the parent harness is the stated purpose of the engine.

The population is now detached to PID 1 via `setsid --fork`, giving every member an empty ancestry, so any harness attribution at all is by definition unjustified. PIDs are discovered by matching resolved exe against a starttime mark, because the `setsid` intermediate exits and the Popen PID is not the workload PID.

### 5.2 Population and results

| Arm | Population | False positives |
| :--- | ---: | ---: |
| Live whole-host sweep, every attribution must carry a justifying signal | 1,466 real processes | **0** |
| Detached ordinary developer tools (`node`, `python3`, `bash`, `sh`, `sleep`, …) | 4 resident | **0** |
| Detached run repeated under process churn, 6 rounds | 4 × 6 observations | **0** |
| Renamed-binary lookalikes (`claude`, `agy`, `codex`, `cpai`, `opencode`, `hermes`, `aider`, `node`, `python3`) | 9 | **9 — see carried defect D** |

**No silent cap.** The resident ordinary-tool population is 4, not the 14 listed: tools without a genuine idle mode (`git`, `make`, `find`, `grep`, `sed`, `awk`, …) exit immediately and cannot be observed by a scanner, and a FIFO-held stdin did not keep them resident reliably. Inflating the nominal count would have been dishonest. The **1,466-process live host sweep is the substantive population evidence**; the spawned arm is a controlled supplement.

**On repetition.** A single clean run does not prove the race-handling path was exercised. The contention arm sweeps six times while spawning churn, and P2-2's four deterministic race tests (PID reuse, orphan reparenting, mid-walk exit, cyclic table) pass unchanged on the merged tree.

---

## 6. Carried defect D — renamed-binary spoof via exe basename equality

**BLOCKING. IN REMIT. Unfixed.**

*Framing corrected after challenge.* An earlier draft filed this as "out of remit because the signature database is another card's artefact". That answers **where the fix lives**, not **whether the certified property holds on the merged tree** — and the certified property is zero false positives. D is a false positive, reproducible in one command, emitted at confidence 1.0. It is re-filed as in-remit and is **the single strongest reason certification is withheld**, ahead of defect E.

```
$ cp /bin/sleep /tmp/spoofbin/claude && /tmp/spoofbin/claude 90
-> Harness.CLAUDE, confidence 1.0
```

All nine lookalikes were attributed: `claude→claude`, `agy→antigravity`, `codex→codex`, `cpai→cpai`, `opencode→opencode`, `hermes→hermes`, `aider→aider`, and `node`/`python3` → `codex`.

**Root cause.** Binary provenance is satisfied by `clean_exe_base in sig.exe_basenames` — bare **basename equality**. Anyone can name a file `claude`. Worse, the path patterns do not discriminate either: `(^|/)(claude|claude-[0-9.]+)(/|$)` matches *any* path ending in `/claude`, including `/tmp/spoofbin/claude`. The signature database as frozen by P2-PRE cannot distinguish a real harness binary from a renamed one by path alone.

**Why P2-2's spoof test passes anyway.** `test_spoof_renamed_binary_mimicking_claude` models `/usr/bin/sleep` with `comm="claude"` — basename `sleep`, correctly rejected. It tests the easy half. It does not model naming the file `claude`, which is the actual attack.

**Why this Governor did not fix it.** Closing it requires one of: anchoring signatures to install locations only (removing the permissive basename-equivalent patterns, which risks real recall loss for installs in unusual locations), binary content attestation, or the socket corroboration that **P4-2 is chartered to deliver** — and `NullProtocolCorroborator` already documents that it "never returns True so that the classifier does NOT prematurely assume socket corroboration before P4-2 lands". `HARNESS_SIGNATURES` is P2-PRE's frozen artefact and a declared shared-file collision risk. Rewriting detection semantics unilaterally at Governor stage is out of remit.

**Tracked as** `@unittest.expectedFailure` on `test_zero_false_positives_on_renamed_binary_lookalikes`, which will flip to *unexpected success* the moment it is fixed.

**Recommendation:** assign to P4-2 as a hard dependency, or open a P2 follow-up to re-anchor `exe_path_patterns` to install roots.

---

## 7. Carried defect E — CPU and RSS overhead breach the KPI

**BLOCKING. Measured, not inherited from P2-1's figure.**

Host conditions: Linux `7.1.3+deb13-amd64`, Python `3.14.4`, 24 cores, **1,469 live PIDs**.

| Configuration | CPU per sweep | Wall per sweep |
| :--- | ---: | ---: |
| Scanner only (P2-1) | 272.6 ms | 272.7 ms |
| Scanner + classifier (merged) | 318.5 ms | 318.9 ms |
| **Classifier adds** | **+45.9 ms (+16.9%)** | |

This answers the question the card posed directly: **P2-1's overhead figure does not still hold.** Ancestry walking adds 16.9% CPU per sweep.

Duty cycle against the `<1.0% CPU` KPI. **The denominator is decisive and the KPI does not state one.** This host has 24 cores.

| Poll interval | % of ONE CORE | % of HOST (24 cores) |
| ---: | ---: | ---: |
| 0.5 s (`continuous_scan` default) | 60.42 % FAIL | 2.52 % FAIL |
| **2.0 s (proposal risk-mitigation cap)** | **15.10 % FAIL** | **0.63 % PASS** |
| 5.0 s | 6.04 % FAIL | 0.25 % PASS |
| 30.0 s | 1.01 % FAIL | 0.04 % PASS |

**Correction to this Governor's first reading.** An earlier draft of this document asserted a flat CPU failure without stating the denominator. That was wrong and is corrected here. At the proposal's own 2 s cap the merged engine consumes **0.63 % of host CPU, which PASSES the KPI**, and 15.10 % of a single core, which does not. Which reading the KPI intends is **an open question for the principal**; it is not this Governor's to decide. What is unambiguous is that the `continuous_scan` **default interval of 0.5 s fails under both readings** and must be raised.

Peak RSS: **25.28 MB** standalone against a `<25 MB` KPI — a marginal breach.

**A claim this Governor withdrew.** An earlier draft asserted that `<2 s discovery latency` and `<1.0% CPU` are *mutually unsatisfiable*. That was an overreach: it is a measurement of **this implementation**, not a lower bound on any implementation, and it is withdrawn. At least three approaches would satisfy both and none has been ruled out — a netlink `CN_IDX_PROC` proc-connector giving event-driven discovery with no poll loop at all; per-`(pid, starttime)` classification caching so steady-state processes cost nothing after first sight; and scanning only new PIDs per tick rather than re-walking 1,441. A fabricated impossibility would have been a worse defect than the one it excused.

**Available remediation this Governor did not apply.** `scan_processes()` already accepts a `candidate_filter` parameter and **no caller anywhere passes one**. Every sweep performs the full `statm` + `status` + cgroup resolution for all 1,469 processes before any filtering. A cheap comm/exe prefilter applied before the expensive reads would cut the dominant cost. That is a P2-1 design change, not a Governor edit.

**Caveat on generality.** 1,469 PIDs is an unusually heavy workstation (this host runs a large parallel-agent estate). The KPI may well hold on a typical developer machine. The figure is reported as measured, on the machine measured, with the process count stated — it is not extrapolated.

**Tracked as** `@unittest.expectedFailure` on `test_merged_scan_and_classify_within_cpu_budget` and `test_merged_engine_within_rss_budget`.

---

## 8. Guard re-verification on the merged tree

### 8.1 cmdline-access guards (P2-1), re-run across P2-2's code

```
$ rg -n 'cmdline' collector.py   -> no match
$ rg -n 'cmdline' classifier.py  -> no match
$ rg -n 'cmdline' proc.py        -> L17 (PROHIBITED_PROC_ENTRIES member), L330/L348 (docstrings)
```

P2-2's ancestry corroboration resolves identity through `/proc/<pid>/exe` (`os.readlink`) only. **No incidental cmdline read was introduced.**

New merged-surface guards in `MergedTreeAccessGuardTests`:

- `test_no_cmdline_string_literal_in_merged_modules` — AST walk over `collector.py`, `classifier.py`, `cgroups.py`; no string constant may contain `cmdline`.
- `test_no_prohibited_entry_literal_in_merged_modules` — no `/proc/<entry>` path literal for any prohibited entry.
- `test_runtime_scan_and_classify_touch_no_prohibited_entry` — intercepts `_safe_proc_path`, the single chokepoint every proc read passes through, across a full merged `scan_processes()` + `classify_scanned_processes()`. **Asserts the interceptor actually fired** before asserting absence, so the guard cannot be vacuous.
- `test_prohibited_set_is_not_weakened` — pins all 17 members of `PROHIBITED_PROC_ENTRIES`.

`proc.py`'s prohibited set is **unchanged**; no entry was removed. `_safe_proc_path` remains a genuine pre-collection chokepoint that raises `SecurityException` before `open()`.

### 8.2 Spoofing tests (P2-2) on the merged tree

All pass unchanged: `test_spoof_renamed_binary_mimicking_claude`, `test_spoof_prctl_set_name_mimicking_agy`, `test_spoof_prctl_set_name_mimicking_cpai`, `test_spoof_cross_harness_mimic`, `test_spoof_fake_parent_in_ancestry_tree`. See carried defect D for the case they do not model.

### 8.3 Frozen schema conformance (P1-1)

`MergedSchemaConformanceTests` runs against the merged code path, not spot-checked records:

- Every claim across the live host maps to an allowlisted `Harness` enum value.
- `ClassificationClaim.to_dict()` emits exactly the 7 expected keys — a structural allow-list, not a deny-list.
- `ProcessInfo` derived from the merged scan carries four bounded integers and one string; `comm` is asserted `≤16` chars and restricted to `[alnum]_.-`.
- `HARNESS_SIGNATURES` introduces no harness outside the frozen enum.

The Zero-Customer-Payload invariant is intact: no field added by this card can carry prompt text, file contents, a credential value, or process memory.

### 8.4 P1-4 negative-security regression

```
$ python3 -m unittest test_negative_security
Ran 16 tests in 0.003s
OK
```

Run because an indirect regression through a changed import or helper is possible even though `proc.py` was untouched.

---

## 9. Final test state

```
$ python3 -m unittest discover -p 'test_*.py'
Ran 214 tests in 34.133s
OK (expected failures=3)
```

188 pre-existing + 26 new governor tests. The 3 expected failures are carried defects D and E, tracked in §6 and §7.

```
$ PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python3 -m pytest test_hasher.py test_file_validator.py -q
33 passed
```

`scripts/kanban-check.sh doctor` reports `UNHEALTHY` on one exception: 29 historically fast-exiting tasks across `cpai-opencode` and `antigravity` agents. This is pre-existing board hygiene spanning multiple boards, predates this card, and contains no SLCD Phase 2 task. Historical durations cannot be remediated by this card.

---

## 10. Files changed

| File | Change |
| :--- | :--- |
| `collector.py` | Defect A — `candidate_pid=` keyword |
| `classifier.py` | Defects B and C — host-level marker removed from the sufficient set at three sites; retained as additive signal |
| `test_classifier.py` | Two fixtures re-pointed to the realistic Codex install path; **no assertion changed, no test removed** |
| `test_p2_governor_integration.py` | New — 26 merged-tree certification tests |
| `docs/signalloom/slcd-p2-governor-proof.md` | This document |

---

## 11. Blocking recommendation for P3-PRE

P3-PRE depends on P2-GOV. This Governor **withholds certification**, and the dependency is satisfied by this committed artefact recording a `fail`, not by intent.

Phase 3 may proceed on the merged tree — the three fixed defects made it materially safer, and the detection engine is now honest about what it does not know. But **no downstream phase may treat harness attribution as trustworthy against an adversary** until carried defect D is closed, and **workstation collection must not be enabled** until carried defect E is resolved, independently of the lawful-basis gate which remains a separate hard prerequisite.

---

*Generated by SLCD-P2-GOV, 2026-09-15 05:38:15+01:00, in the dedicated Governor worktree. No remote push performed.*


---

## 12. Carried defect F — the merged engine detects nothing in this environment

**BLOCKING, and the gravest finding in this report.**

After defects B and C were fixed, the live sweep attributes **0 processes out of 1,441**. Not one. Including the coding agents that were demonstrably running at the time.

The cause is that the two signals I left as admissible are both unavailable:

```
exe resolvable for 11 / 1443 scanned processes  (0.8%)

live harness comms present, all with read_exe() -> None:
  agy: 12    claude: 1    hermes: 1    opencode: 3
  node-MainThread: 42     bun: 20      python3: 3
```

`/proc/<pid>/exe` is unreadable for **99.2%** of the process table in this execution context, and `NullProtocolCorroborator` returns `None` by design until P4-2 lands. Binary provenance and socket corroboration are the entire admissible signal set, so the classifier correctly returns `UNKNOWN` for everything.

**This reframes the zero-false-positive result.** The engine now scores zero false positives the same way an unplugged smoke detector scores zero false alarms. I criticised P2-2's benchmark in §4 for passing while blind; this Governor must apply the same standard to its own headline number and does so here. **Zero false positives without a demonstrated true positive is not evidence of precision.**

**What this does not prove.** The sensor is designed to run as a privileged host agent (`agentmaxxing-agent.service`). Reading `/proc/<pid>/exe` requires `PTRACE_MODE_READ` and is expected to succeed there. The 0.8% figure is a property of **this sandboxed test context**, not necessarily of production, and is reported as such rather than extrapolated.

**What it does prove, and this part is not context-dependent:** the certification environment **cannot demonstrate true-positive detection at all**, so no run performed by this card — or by P2-1 or P2-2 before it — constitutes evidence that the engine detects a real coding agent on a real host. Every true positive claimed anywhere in Phase 2 rests on synthetic mock-procfs fixtures.

**Before this was fixed**, detection appeared to work: 61 processes were attributed. Every one of those attributions rested on `comm` — an attacker-controlled string settable by `prctl(PR_SET_NAME)` — plus a directory listing. The apparent detection capability of Phase 2 was, in this environment, **entirely an artefact of the defect**.

**Required before Phase 2 can be certified:**

1. Re-run this suite as the privileged host agent and record the actual `exe` resolvability figure and a demonstrated true positive against a real running agent.
2. If `exe` remains unresolvable under privilege, Phase 2's detection premise does not hold and P4-2's socket corroborator becomes a hard prerequisite rather than an enhancement.

---

## 13. Fix falsification

Each fix was falsified by reverting it and observing the corresponding test fail. A fix whose test passes against the reverted code is unwitnessed.

| Fix | Revert applied | Result with fix reverted |
| :--- | :--- | :--- |
| A — `candidate_pid=` keyword | `collector.py` | `CollectorClassifierWiringTests` — **FAILED (errors=2)** |
| B — host marker not sufficient, primary branch | `classifier.py` | `HostMarkerSufficiencyTests` — **FAILED (failures=2)** |
| C — host marker not sufficient, unresolvable-exe branch | `classifier.py` | `test_whole_population_harness_attribution_is_justified` — **FAILED (failures=1)** |

**A false acquittal caught in the act.** The first attempt at falsifying fix C reported `OK`, which would have certified the test as blind. The scripted revert had silently failed to match. Re-run with an assertion on the substitution count (`assert s.count(old)==1`) before writing, the revert applied and the test failed correctly. A scripted edit that does not assert before it writes can manufacture a passing falsification — the opposite of what falsification is for.

All three fixes are therefore witnessed. Tree restored and re-verified green after each revert.

---

## 14. Advisor challenge and corrections made

A commitment-boundary advisor call before declaring done produced four corrections that materially changed this report. They are recorded rather than silently absorbed:

1. **Defect D was mis-filed as out of remit.** Re-filed as in-remit and blocking (§6). "Where the fix lives" is not "whether the property holds".
2. **The CPU figure had no stated denominator.** At 24 cores the 2 s figure is 0.63% of host — a **pass** — not the flat failure first written (§7).
3. **The KPI-impossibility claim was an overreach** and is withdrawn; three viable approaches are named (§7).
4. **The false-negative cost was unreported.** Measuring it produced §12, the most important finding in this document.

A fifth point — that `@unittest.expectedFailure` keeps the suite green and is how a defect gets forgotten at the next merge — is accepted and **not** resolved here. The three markers carry explicit `CARRIED DEFECT` pointers to this document, and each flips to *unexpected success* if fixed, but a reviewer is right to note they do not make the suite red.
