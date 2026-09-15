
#### Errata — SLCD-P2-GOV Merge process tree detective engine and verify zero false-positive collisions
<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
**Created:** 2026-09-15 05:46:06+01:00
**Last Updated:** 2026-09-15 05:46:06+01:00
**Status:** Failed — certification withheld
**Commit:** `4fe9b66fb6424209b62ffa8a3b1472ee62b7ace5`
**Branch:** `integration/slcd-v0.1.0`
**Integration ref after commit:** `4fe9b66fb6424209b62ffa8a3b1472ee62b7ace5`
**Governor merge:** P2-1 `037884520788da7fddc6857c9ebb2eed0624400b` and P2-2 `dd031c681c6594abf7cb42e8d2607ba54c75cf5f` confirmed ancestors of HEAD; no re-merge and no conflict resolution required.
**Proof:** `docs/signalloom/slcd-p2-governor-proof.md` (duplicated as `slcd-p2-gov-proof.md`)

**Verdict:** Certification is **withheld**. Three defects found and fixed; three findings carried that block the zero-false-positive KPI.

**Decisions:**
1. **Defect A — cross-card call-signature drift (FIXED).** `collector.py` passed `pid=` to a classifier whose parameter is `candidate_pid=`, raising `TypeError` on every invocation of `ProcessTelemetryCollector.classify_process()`. Neither card's suite called this wrapper, so neither could observe it — exactly the class of defect only a merged-tree run surfaces.
2. **Defect B — a host-level fact used as a process-level signal (FIXED).** `corroborate_direct_harness()` admitted `check_session_marker()` — a `Path.exists()` under `$HOME` — into the *sufficient* set for a generic-runtime comm match. Reproduced: `comm=node exe=/usr/bin/node` → `Harness.CODEX @ 0.95`. Any ordinary Node.js process on any host where Codex was ever installed was attributed to Codex. P2-2's suite is structurally blind because `setUp` binds the corroborator to an empty temporary home. **Two of its tests described a byte-identical process and asserted opposite verdicts** (`test_benign_node_process_not_codex` → UNKNOWN; `test_true_positive_codex_with_session_marker` → CODEX ≥0.90), differing only by a directory in `$HOME`.
3. **Defect C — same category error on the unresolvable-exe path (FIXED).** When `/proc/<pid>/exe` is unreadable the classifier fell back to comm plus host marker. `comm` is attacker-controlled via `prctl(PR_SET_NAME)`. **61 live processes were attributed on nothing but a process name and a directory listing.** Post-fix the same sweep reports zero unjustified attributions.
4. **Recall cost of B and C verified, not assumed.** Real Codex resolves to `@openai/codex/bin/codex.js`, real Hermes to `.hermes/node/bin/node` — both match `exe_path_patterns` directly. Two P2-2 fixtures modelling Codex as `exe=/usr/bin/node` were corrected to the realistic install path; **no assertion changed, no test removed.**
5. **The prior 0/45 false-positive benchmark is a tautology.** `test_zero_false_positive_stress_benchmark` (P2-2 errata Decision 6) enumerates 45 ordinary tools and **omits `node` and `python3` — the only two comm names its own signature table matches.** It cannot fail. Recorded as an append-only observation; the prior entry is not altered.
6. **This Governor's own first stress reading was wrong and is corrected.** Tools spawned as children of the test runner inherit genuine harness ancestry and *should* be attributed. The population is now detached to PID 1 via `setsid --fork`, so any attribution is unjustified by construction.
7. **Each fix falsified by revert.** A→errors=2, B→failures=2, C→failures=1 with the fix reverted. The first C falsification returned a **false acquittal** because the scripted edit silently failed to match; re-run with an assertion on substitution count before writing, it failed correctly.

**Carried defects (blocking):**
- **D — renamed-binary spoof.** `cp /bin/sleep ./claude && ./claude` → `CLAUDE @ 1.0`. Binary provenance is satisfied by bare **basename equality**, and the path patterns are basename-equivalent (`(^|/)(claude|…)(/|$)` matches any path ending `/claude`). All 9 lookalikes attributed. Initially mis-filed as out of remit; **re-filed as in-remit and the single strongest reason certification is withheld.** `HARNESS_SIGNATURES` is P2-PRE's frozen artefact; the sound fix is P4-2's socket corroborator.
- **E — overhead, denominator-dependent.** Merged sweep 318.5 ms CPU over 1,469 PIDs; **the classifier adds 45.9 ms (+16.9%)**, so P2-1's figure does not still hold. At the 2 s cap: **15.10% of one core (fail) / 0.63% of host at 24 cores (pass)**. The KPI states no denominator — **open question for AJM.** The `continuous_scan` default of 0.5 s fails under both readings. Peak RSS 25.28 MB against <25 MB. An earlier claim that the latency and CPU KPIs are *mutually unsatisfiable* is **withdrawn as an overreach**; netlink `CN_IDX_PROC`, per-`(pid,starttime)` caching and new-PID-only scanning are unruled-out. `scan_processes()` already accepts a `candidate_filter` that **no caller anywhere passes**.
- **F — the engine detects nothing here; the gravest finding.** `/proc/<pid>/exe` is unreadable for **1432 of 1443 processes (99.2%)** in this context; every live harness (`agy`×12, `claude`, `hermes`, `opencode`×3) returns `None`. With binary provenance unavailable and the socket corroborator stubbed until P4-2, the fixed engine attributes **0 of 1441** — zero false positives *and* zero true positives. **The zero-FP headline is vacuous in this environment**, by the same standard applied to P2-2's benchmark above. The sensor is designed to run privileged (`agentmaxxing-agent.service`) where `exe` should resolve, so this may not be a production property — but it does mean **no Phase 2 run has ever demonstrated a true positive against a real agent**; every true positive claimed rests on synthetic mock-procfs fixtures.

**Deviations:**
- **`kanban-check.sh cost` could not run.** Both `cost --update-table --apply` and bare `cost` fail with `/usr/bin/python3: Argument list too long` at `kanban-check.sh:2772` — an argv `E2BIG` inside the tool, independent of this card. The Work Decomposition table was therefore **not** auto-populated and the Phase Spend table could not be generated. No figures are fabricated in its place.
- Cato cross-vendor audit (Algorithm Rule 2a, mandatory at E4) **could not fire** — the cross-vendor channel is blocked on this host. The commitment-boundary Advisor call did run and produced four corrections, all recorded in §14 of the proof document.
- Three tests carry `@unittest.expectedFailure` with explicit `CARRIED DEFECT` pointers (D, E). This keeps the suite green, which a reviewer may reasonably object to; each flips to *unexpected success* when fixed.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| SLCD-P2-GOV | (unresolved: `kanban-check.sh cost` fails E2BIG at line 2772) | (unresolved: same) | (unresolved: same) | N/A |

**Notes:** Merged-tree suite: **214 tests, OK (expected failures=3)** — 188 pre-existing plus 26 new in `test_p2_governor_integration.py`. P1-4 negative security **16/16 OK**. All P2-2 spoofing, true-positive, multihop and race tests pass unchanged. Static guard: zero `cmdline` references in `collector.py` and `classifier.py`; `PROHIBITED_PROC_ENTRIES` unchanged at 17 members. Runtime guard intercepts `_safe_proc_path` across a full merged scan+classify and asserts the interceptor fired before asserting absence. Separately found: **`test_hasher.py`'s 17 tests never run** under `unittest discover` (pytest-style, `rc=5 NO TESTS RAN`) — static 205 vs runtime 188; AMXO-owned (`d5005ee7`, `caaf7550`), out of scope, verified green under pytest (33 passed). `kanban-check.sh doctor` reports UNHEALTHY on 29 historically fast-exiting tasks — pre-existing, multi-board, no SLCD Phase 2 task involved. No remote push performed.

**P3-PRE gate:** P3-PRE's dependency on P2-GOV is satisfied by this committed `status=fail` artefact, not by intent. Phase 3 may proceed on the fixed tree for work not load-bearing on detection soundness; **any Phase 3 deliverable whose correctness rests on harness attribution being non-spoofable, or on the engine detecting a real agent, is void until D and F close.**
<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
