---
title: SLCD-P4-GOV — Phase 4 certification of zero payload harvesting across a combined session, with combined four-subsystem overhead measured
card: SLCD-P4-GOV
role: governor
integration_branch: integration/slcd-v0.1.0
certified_against: 77a7e665834e8f864a9ad6179a7030676561b278
verdict: BLOCKED — the combined-session leak audit passes and is proven able to fail; the combined overhead KPI is breached 36x, the lawful basis is unresolved, and the invariant is not proven through storage or query
---

# SLCD-P4-GOV — Phase 4 Governor certification

> **Verdict: `status=blocked`.** Phase 4's merge is clean and its zero-payload work is the
> strongest in the mission so far. Three things block: the lawful basis is unresolved (40 open
> items, 22 blocking, collection disabled), the combined overhead KPI is breached by 35× on CPU
> and 2.4× on RSS, and the mission's headline invariant is **not** proven end-to-end because
> Phases 5 and 6 have not yet exercised a record through storage and query.
>
> | | |
> |---|---|
> | **Card** | `SLCD-P4-GOV` |
> | **Integration branch** | `integration/slcd-v0.1.0` |
> | **Certified against** | the branch tip, not a worktree — see §1 |
> | **Governor worktree** | `/home/andy/src/.worktrees/osramp-demo/slcd-v0.1.0/governor` |
> | **New evidence** | `d2-signalloom/apps/agentmaxxing-host-sensor/test_p4_governor_integration.py` |
> | **Date** | 2026-09-15 |

---

## 0. What this certification does and does not claim

The failure this card was written to avoid is certifying "zero payload harvesting" by re-running
each subsystem's own isolated falsification suite. P4-1 proved its parser leaks nothing. P4-2
proved its detector leaks nothing. Neither proof covers the shipped configuration, which is all
four detective subsystems in one process against one developer session at once.

So a new audit was built. It drives a live transcript, an active kanban cycle and an outbound
inference socket **concurrently**, assembles the real export record from their real outputs,
serialises it through the real wire encoder, and scans the emitted bytes for canaries planted in
all three fixtures. That is §4.

The claim it licenses is narrower than "zero payload harvesting", and the narrowing is the point.
An advisor challenge at this card's commitment boundary identified five surfaces a canary audit at
the export boundary is structurally blind to. Three were closed by new controls before signing
(§4.3, §4.4, §5.3); the remaining two are enumerated as **not certified** in §9. The honest
statement of what was proven is:

> No verbatim occurrence of any of 7 canaries in the serialised export record, over the branches
> this audit exercised, with the audit's own detector proven able to see a canary planted in the
> real encoder's own output and a mutation of the real pipeline proven to be killed by it.

**Not certified by this card:** payload-derived metadata (digests, lengths, timings — P4-1's
differencing attack remains unmitigated); transport-envelope fields; unexercised
fallback/spill/dead-letter paths; cross-session attribution; and the storage and query spans.

---

## 1. The merged tree — certified against the branch, not a worktree

All values below were resolved by `git rev-parse` and pasted as literals; none was retyped.

| Fact | Value |
|---|---|
| Branch in the governor worktree | `integration/slcd-v0.1.0` |
| Branch tip at certification | `77a7e665834e8f864a9ad6179a7030676561b278` |
| P4-1 implementation commit | `5a231d58690ef72a3cd3aa040883a3ffee36e486` — **ancestor of tip** |
| P4-2 implementation commit | `206a7fea70a2472836b47f49dab4316da01ca41b` — **ancestor of tip** |
| P4-1 merge commit | `5a801408b6a857a754a64ce6c9bff9119f7b0731` — **ancestor of tip** |
| P4-2 merge commit | `1bd481d994df544905a2c5755487c1cf4fc7eef4` — **ancestor of tip** |

**The merge had already landed before this card ran.** The controller merged both cards
(`5a801408`, `1bd481d9`). This card therefore certifies the merged state rather than performing
the merge; no conflict resolution was required and none was performed, so the failure mode
"a conflict resolution that reintroduces a weakened `proc.py` prohibited set" could not occur —
and §6 proves the set is intact by equality regardless.

**The branch moved under this card, mid-run.** At session start the tip was `2187e4f8`; at
certification it is `77a7e665`. Five commits landed from concurrent sessions during this card's
execution:

```
77a7e665 docs: record Controller Tick #131 in governor log
7f99d3e0 chore: record review ledger verdicts for AMXD-P6-PRE and SLER-P5-GOV
84db0acc Merge commit '499d0ef9' into feat/signal-loop-and-bootstrap-refactor
499d0ef9 docs(signalloom): record SLER-P5-GOV forensic ledger certification and review
0a845000 docs(signalloom): record AMXD-P6-PRE preflight harness and fixture audit
```

None touches `d2-signalloom/apps/agentmaxxing-host-sensor/` — the diff over that range is five
files, all documentation and ledger records for the AMXD and SLER missions. Every test result in
this document was produced against the tree at `77a7e665` or later. Recorded because a
certification that names a tip without noticing it moved is certifying a state it never measured.

### 1.1 Finding — a committed conflict marker in the proposal

`git grep` for conflict markers across tracked `*.py`, `*.go`, `*.ts`, `*.tsx` and `*.md` returned
one genuine hit and two false positives (markdown `=======` underlines in `docs/amxd-p0-baseline.md`
and `docs/signalloom/sler-p0-baseline.md`). The genuine hit is an **orphaned** `<<<<<<< HEAD` at
line 753 of the proposal, immediately above the SLCD-P3-1 errata block, with no matching
`=======` or `>>>>>>>` anywhere in the 831-line file. It is the residue of a hand-resolved merge
whose first marker was not deleted. No errata content is lost or duplicated.

This card removed that one line and nothing else. That is a repair of corruption, not an
alteration of a prior errata entry, and it is recorded here so the change is attributable.

**Zero source-code conflict markers.** The sensor, the ingest service and the dashboard are clean.

---

## 2. Regression gates, re-run against the merged tree

Every figure below is from a run on the merged tree in the governor worktree.

| Gate | Command | Result |
|---|---|---|
| Full sensor suite | `python3 -m unittest discover -p 'test_*.py'` | **430 tests, 2 failures, 3 expected failures, 0 skipped** |
| Negative-security pins (P1-4) | `python3 -m unittest test_negative_security -v` | **20 tests, OK** |
| Go ingest suite | `go test ./...` | **15 packages, all `ok`** |
| Leak falsification (P1-2) | `test_leak_falsification` | 5 tests, OK |
| Transcript falsification (P4-1) | `test_transcript_falsification` | 17 tests, OK |
| Transcript parser (P4-1) | `test_transcript_parser` | 67 tests, OK |
| Socket detector (P4-2) | `test_network_socket_detector` | 49 tests, OK |
| P2 governor integration | `test_p2_governor_integration` | 26 tests, OK (3 expected failures) |
| P3 governor integration | `test_p3_governor_integration` | 14 tests, **1 failure** (§7) |
| **P4 governor (new, this card)** | `test_p4_governor_integration` | **37 tests, 1 failure** (§7) |

**Both failures are the same finding**, asserted twice: the combined-overhead KPI (§7). There is
no other failure in the tree.

**Zero tests were skipped.** Recorded explicitly because the combined-overhead tests are guarded
by `@unittest.skipUnless(LIVE_KANBAN.is_dir(), ...)`, and on a host without a live kanban home
they vanish silently — a check that never ran is indistinguishable from a check that passed. The
kanban home exists here, so they ran.

**The Go field-emission guard executed.** The guard that actually holds, per P1-GOV §0, is
`codingagent/telemetry_test.go`, which reflects over the Go struct rather than reading the schema
file. It is in `go test ./...`'s green set. Schema conformance is certified by re-running that
guard, not by spot-checking emitted records.

---

## 3. P4-2 — CIDR list, measured false-positive rate, and the fd question

### 3.1 The artefact exists and is versioned

| Artefact | State |
|---|---|
| `docs/signalloom/slcd-p4-2-cidr-ranges.md` | **present**, committed |
| `d2-signalloom/apps/agentmaxxing-host-sensor/data/inference_providers.json` | **present**, committed, parses |
| List version | `2026-09-15.1` |
| Declared inference endpoints | `aiplatform.googleapis.com`, `api.anthropic.com`, `api.openai.com`, `generativelanguage.googleapis.com`, `ollama.localhost`, `vllm.localhost` |
| Consumer symbol | `network.InferenceProviderRanges` — confirmed present |

A claimed KPI with a missing artefact is a blocked state, not a pass. Both are present, so this
deliverable is a **pass**.

### 3.2 The false-positive rate is measured, by a test, and the proposal's own method fails it

Printed by `test_network_socket_detector` on every run:

```
[SLCD-P4-2] untiered CIDR: TP=11 FP=7 TN=28 FN=1 precision=61.1% recall=91.7%
[SLCD-P4-2] tiered: TP=11 FP=1 TN=34 FN=1 precision=91.7% recall=91.7%
[SLCD-P4-2] shared-tier check suppresses 6 false positives; 1 residual
[SLCD-P4-2] tiered + cgroup-corroborated (shipped): attributed=12 TP=11 FP=1 FP-rate=8.3%
[SLCD-P4-2] residual false positives: 160.79.104.10:443(other-app)
[SLCD-P4-2] untiered CIDR matching (the proposal's method): attributed=18 TP=11 FP=7 FP-rate=38.9%
```

| Method | FP rate |
|---|---|
| **Shipped** (tiered + cgroup-corroborated) | **8.3%** — one residual, named |
| The proposal's literal "match against provider CIDR ranges" | **38.9%** |

Two things must be said plainly. First, the residual false positive is **named**
(`160.79.104.10:443`, another application inside Anthropic's dedicated range), not aggregated
away. Second, **8.3% is not zero**, and the proposal's KPI says zero false positives. The shipped
method is a 4.7× improvement on the method the proposal specifies, and the proposal's own method
is not certifiable at all. This is recorded as a **carried defect**, not a pass.

### 3.3 fd-avoidance succeeded — no `stopAndReport` escalation was required

P4-2's own document states the escalation was not needed. Prose is not evidence, so it was
corroborated in code by `test_socket_detection_path_never_reads_proc_pid_fd`:

- **Zero** string literals in `network.py` reference `/proc/<pid>/fd` or any other prohibited
  per-pid entry (AST-based, so the module's several docstrings *about* avoiding fd reads are not
  mistaken for reads — see §6.2).
- `NETLINK_SOCK_DIAG` and `INET_DIAG_CGROUP_ID` are both present, which is the fd-free mechanism
  that replaces the fd walk.

**Honest record: the `stopAndReport` path was NOT exercised, because it was not needed.** The
netlink `INET_DIAG_CGROUP_ID` route proved sufficient and socket-to-process correlation happens in
cgroup-id space. Netlink was confirmed live on this host during the four-way benchmark
(`netlink=True`).

---

## 4. The end-to-end leak audit

`CombinedSessionLeakAuditTests` in `test_p4_governor_integration.py`.

### 4.1 What it drives

| Surface | Fixture | Canary it carries |
|---|---|---|
| **Transcript (P4-1)** | Three-record `CLAUDE_JSONL_V1` slice: a user turn, an assistant turn with `usage`, a `thinking` block, two `tool_use` blocks | prompt text, assistant response, a unified code diff, a thinking-block string, and an Anthropic-shaped API key inside a tool input |
| **Kanban (P3)** | A kanban home with `board.json`, a task card, a lockfile and a SQLite session row | the card's free-text `prompt`/`description` prose |
| **Socket (P4-2)** | An established socket to `160.79.105.231:443`, inside Anthropic's dedicated `160.79.104.0/23` | the destination address, which `SocketClassification` deliberately retains for operator diagnostics |

The fixture is built from the store layouts P1-PRE inventoried, and the payload sits where a real
session puts it — inside `message.content[].text` and inside a tool input — not in a synthetic
field invented for the test.

### 4.2 The result

```
[SLCD-P4-GOV] end-to-end leak audit: 15 records inspected over 5 concurrent rounds x 3 threads,
              11025 bytes scanned, 7 canaries, 0 hits
```

Five properties make that number mean something:

1. **The fixtures are asserted hostile** before the property is asserted. `test_transcript_fixture_is_hostile`
   requires all five transcript canaries to be present in the raw bytes; a later edit cannot
   disarm the audit by making the payload absent.
2. **The canary constant is asserted absent from the sensor's own source**, so it cannot match by
   sharing an input with the code.
3. **The run is asserted non-vacuous.** `records_parsed == 3`, `tokens_in > 0`, `tokens_out > 0`,
   `bytes_consumed > 900`, and the emitted record is asserted to carry a real endpoint and a real
   egress byte count. A zero-record audit is not a zero-leak audit, and this one cannot report
   zero by parsing nothing.
4. **Both byte forms are scanned.** A leak through a JSON encoder arrives escaped, so the scanner
   checks the raw form and `json.dumps`'s escaped form. Scanning only the raw form would miss
   exactly the leak most likely to happen.
5. **It runs concurrently and repeatedly.** Three threads × five rounds. Transcript tailing and
   socket correlation are both timing-dependent, and a single sequential run does not exercise
   the contended paths. Every one of the 15 emissions is scanned independently.

### 4.3 The audit is proven able to fail — three negative controls on the *real* encoder

A sensitivity control that plants a canary in a synthetic blob proves the scanner matches a
string. It does not prove the scanner is pointed at the bytes the real encoder emits. If the
encoder escaped, normalised or chunked differently, "0 hits" and "scanner aimed at the wrong
bytes" would be indistinguishable. Raised at this card's advisor boundary and closed before
signing:

| Control | What it refutes |
|---|---|
| `test_negative_control_scanner_sees_the_real_encoders_own_output` | Values the pipeline *demonstrably emitted* (`session_id`, `inference_endpoint`, `harness`) must be findable by the scanner in the real `canonical_json` bytes |
| `test_negative_control_canary_spliced_into_the_real_record_is_caught` | Each of the 7 canaries, planted into the real serialised record, is detected — one subtest per canary |
| `test_negative_control_pipeline_mutation_makes_the_audit_fail` | `SocketDetector.to_network_info` is swapped for a pass-through that carries `dst_ip`; the audit must catch it |

The mutation result is printed on every run:

```
[SLCD-P4-GOV] pipeline mutation (to_network_info -> pass-through dst_ip): killed by leak audit
```

### 4.4 Finding — the wire contract does **not** catch a raw IP in `inference_endpoint`

The mutation in §4.3 was expected to be refused by the export pipeline. **It was not.** The
mutant record passed `filter_coding_agent_telemetry`, passed the zero-payload validator, passed
`decode_wire`, and reached the emitted bytes carrying `160.79.105.231` in
`network.inference_endpoint`. Only the leak audit's scanner caught it.

The cause is stated in `network.py`'s own docstring and is now proven by test:
`INFERENCE_ENDPOINT_REGEX` is `^[a-zA-Z0-9.-]{1,128}$`, which an IPv4 literal satisfies. The
single thing standing between a retained diagnostic address and the wire is
`to_network_info`'s membership check against the committed provider artefact. There is no
defence in depth behind it.

This is **not a live defect** — the shipped `to_network_info` performs that check correctly, and
the audit confirms the clean pipeline emits nothing. It is a **single point of failure recorded
by assertion**: the test pins the current behaviour, so the day the wire contract changes, the
pin goes red and the finding is revisited rather than forgotten.

### 4.5 Fields are enumerated, not merely canary-checked

Canaries corroborate; they do not enumerate. `test_exported_fields_are_enumerated_not_merely_canary_checked`
walks every leaf of the emitted record and requires each to be a bounded scalar: no list, no
string over 128 characters, no string containing a newline or a space. A free-text field would
fail this whether or not any canary happened to land in it. It passes.

Top-level keys are additionally asserted to be a subset of `coding_agent_wire.allowed_keys()`.

### 4.6 The allow-list is structural, not a deny-list

An off-list key is not *rejected* — it is not *constructed*. `filter_coding_agent_event` builds
the exported dict key-by-key from a typed model, so an attacker-supplied `prompt` has no path
into it. `test_control_b_off_list_field_never_reaches_the_output` asserts the allow-list property
directly, which is a stronger statement than "a deny-list fired".

Payload smuggled into a key that **is** on the list is the dangerous case, and it is refused:
`test_control_b2` (into `kanban.task_id`) and `test_control_b3` (into `network.inference_endpoint`)
both confirm the bounded-format contract rejects it.

### 4.7 The credential detector does not retain the credential

`test_control_d_credential_detector_does_not_retain_the_value` asserts the
`ZeroPayloadSecurityException` raised on a credential carries neither the credential nor its
sentinel in `str()` or `repr()`. A detection path that records the value in order to detect it is
a hard blocker for this card; it does not occur.

---

## 5. Prohibited procfs entries, swept across the *whole* merged sensor

### 5.1 The pin is intact

`test_prohibited_set_matches_p1_4_pins_exactly` asserts **set equality** — not a subset — between
`proc.PROHIBITED_PROC_ENTRIES` and the 17 entries P1-4 pinned:

```
mem environ cmdline maps smaps smaps_rollup stack syscall io fd fdinfo net cwd root
clear_refs pagemap attr
```

Equality is the right relation: a subset check would pass if an entry were added, and a
superset check would pass if one were removed. Every one of the 17 is then exercised
individually — not sampled — through `ProcReader._safe_proc_path`, and every one raises
`SecurityException` before `open()`.

`test_negative_security` additionally carries
`test_the_three_entries_p4_2_was_tempted_to_remove_are_still_present`, which is green.

### 5.2 The sweep covers 48 modules, and it parses code rather than prose

```
[SLCD-P4-GOV] procfs sweep: 48 modules scanned (AST string literals, docstrings and comments
              excluded), 17 pinned entries, 0 observed-process reads
```

The first version of this sweep was a regex over raw source and reported four offenders —
`collector.py`, `file_validator.py`, `network.py` and `test_network_socket_detector.py`. Three
were **prose**: docstrings and comments explaining that the module deliberately avoids those
reads, which is exactly the documentation P4-2 ships. A guard that cannot tell a comment from a
call would have blocked this certification on a false positive.

The sweep now parses each module to an AST and scans only non-docstring string literals.
Comments never reach the tree; docstrings are dropped by identity; the string literals a genuine
read would have to use are kept. A sensitivity control asserts the extractor surfaces a planted
`/proc/%d/environ` exactly once from a fixture whose docstring and comment both mention the same
path, so the guard is proven able to fire and proven able to ignore prose.

### 5.3 Finding — one justified `/proc/self` read the chokepoint cannot see

The `proc.py` chokepoint takes a pid, so `/proc/self/<entry>` never passes through it. Swept
separately:

```
[SLCD-P4-GOV] /proc/self sweep: 1 justified self-read(s) [('file_validator.py', 'fdinfo')],
              0 unjustified
```

`file_validator.get_mount_id_from_proc_fdinfo` reads the mount id of a descriptor **the sensor
itself already holds**, as the second source in a TOCTOU identity check. It observes no other
process and harvests nothing. It was introduced by commit `caaf7550` (`AMXO-P4-3`), which
predates the entire SLCD mission.

It is pinned by **set equality** against an explicit justified set, so both a new self-read and
the removal of this one turn the suite red.

### 5.4 Non-export egress

```
[SLCD-P4-GOV] non-export egress sweep: transcript.py + network.py emit no log, print or stderr write
```

Payload can leave through a channel an export-boundary audit never sees: a `log.warning("%s", line)`
in a parser is an independent egress with its own encoder. Raised at the advisor boundary and
bounded for the two Phase 4 modules by an AST sweep showing they emit **nothing at all** — no
logging call, no `print`, no `sys.stderr.write`. This bounds the channel for Phase 4's own
modules; it does not bound it for the rest of the sensor, and §9 records that.

---

## 6. P4-1 fail-closed, re-exercised against the merged tree

The risk is that an import-path change introduced by the merge silently breaks the fallback and
nothing notices, because P4-1's own suite imports the module directly.

`test_unsupported_harness_fails_closed_via_package_surface` therefore loads the package through
`__init__.py` with `importlib`, exercising the relative-import path the package actually ships,
and asserts:

- `poll_unsupported_harness` is still exported and still in `__all__`;
- `UNSUPPORTED_HARNESSES` is non-empty (an empty set would make the fallback unreachable — the
  vacuous-pass failure mode);
- for **every** declared-unsupported harness: `status == SKIPPED_UNSUPPORTED_HARNESS`,
  `fmt == UNRECOGNISED`, `records_parsed == 0`, `tokens_in == 0`, `session_uuid is None`.

Four more fail-closed probes run against the merged tree:

| Probe | Result |
|---|---|
| An **undeclared** harness raises rather than guessing | pass — fail-closed means a named outcome or an error, never a plausible guess |
| An unrecognised format carrying payload | skipped, `records_parsed == 0`, zero canary bytes in `to_json()` |
| A **Codex** rollout record read as Claude JSONL | does not half-parse: `tokens_in == 0`, `tokens_out == 0`, zero canary bytes |
| A **truncated** transcript (torn trailing line) | no exception across the poll boundary, zero canary bytes |

---

## 7. Combined overhead across all four subsystems — **KPI BREACHED**

P3-GOV measured P2+P3 and recorded a breach. No figure had ever included P4-1 and P4-2. This card
measured both, on the same host, in the same session, so the comparison is like-for-like.

Three paired runs:

| Run | P2+P3 duty-cycle CPU | P2+P3+P4-1+P4-2 duty-cycle CPU |
|---|---|---|
| 1 | 27.729% | 36.115% |
| 2 | 27.583% | 35.754% |
| 3 | 27.565% | 36.290% |
| **Mean** | **27.63%** | **36.05%** |

| Metric | P2+P3 | **All four** | KPI | Result |
|---|---|---|---|---|
| Duty-cycle CPU (0.5 s poll) | 27.63% | **36.05%** | < 1.0% | **FAIL — 36×** |
| Peak RSS | 44.6–59.8 MB | **42.3–60.0 MB** | < 25 MB | **FAIL — 1.7–2.4×** |
| Throughput | — | **5.5 sweeps/s** | — | recorded |

**Apportionment.** Phase 4 adds **+8.4 percentage points**, about 42 ms of CPU per combined
sweep. Phase 4's own contribution alone is therefore ~8.4% duty cycle — **eight times the
whole-sensor KPI on its own**, before P2 and P3 are counted.

**The breach predates Phase 4 and is not caused by it.** Proven by direct measurement, not
inference: a detached worktree at `479ac67f` (the last commit before the P4-1 merge) fails the
same P2+P3 assertion at **29.865%**. P2-GOV recorded it as carried defect E; P3-GOV recorded
27.188% and 44.05 MB and explicitly left the apportionment open. That worktree was removed after
the measurement.

**The duty-cycle model is the shipped one.** `test_duty_cycle_model_matches_the_shipped_default`
asserts the 0.5 s interval against `collector.py`'s and `kanban_watcher.py`'s own defaults, so the
percentage cannot be made to look better by quietly modelling a slower poll. The KPI thresholds
are read out of `test_p2_governor_integration.py`'s source rather than restated, so the two cannot
drift apart.

**The KPI was not loosened and the figure was not omitted because it fails.** Both combined
overhead tests assert and both are red. That is the record.

**What it would take to close.** The dominant costs are the 100-pid procfs walk, the SQLite
session read, and — new in Phase 4 — a full re-parse of a 2,000-record transcript per sweep. The
transcript parser already has a bookmark that makes an unchanged file cost nearly nothing; the
benchmark deliberately clears it each sweep to measure the worst case. A realistic fix is
per-subsystem poll intervals rather than one 0.5 s tick for everything. That is engineering work
this card measures and escalates; it is out of scope here.

---

## 8. Cross-subsystem interference — none detected

P3-GOV's concurrency tests were re-run with the Phase 4 detectors merged and loaded:

```
[BENCHMARK] Controller 40 cycles: baseline=49.8ms, concurrent=51.1ms, delta=+2.6%, watcher_polls=37
[BENCHMARK] Watcher 100 sweeps: wall=30.1ms, cpu=30.2ms, duty_cycle_cpu=0.060%, peak_rss=48.45MB
```

A +2.6% controller-tick delta over 40 cycles with 37 watcher polls interleaved is within the
noise band P3-1 (−9.4%) and P3-GOV (−4.6%) already observed; the sign varies run to run. The
watcher's own duty cycle is unchanged at 0.060%.

The combined-session audit additionally ran three threads × five rounds with no deadlock, no
exception, and all 15 emissions produced — asserted, not assumed, with a 60-second join timeout
and an explicit liveness check on every thread.

---

## 9. Carried forward — every open item, closed by none

### 9.1 Lawful basis — `OPEN-SLCD-1` … `OPEN-SLCD-40`

Machine-derived from `docs/signalloom/slcd-p1-5-lawful-basis.md`, not hand-copied:

| Fact | Value |
|---|---|
| Distinct `OPEN-SLCD-` items | **40** |
| Of which block workstation collection | **22** |
| `collection_state` in the document's frontmatter | **`DISABLED`** |

**Workstation collection remains disabled.** Nothing in Phase 4 changes this, and nothing in
Phase 4 was permitted to. The sharpest of these remains `OPEN-SLCD-8` — whether `metrics.*` is
necessary at all — which, if answered "no", largely removes the transcript-reading requirement
and with it the payload-proximity risk that Phase 4's parser exists to manage. `OPEN-SLCD-7`
(continuous versus periodic sampling) is named by the assessment itself as the weakest link in
the necessity argument.

This is recorded here, in a Phase 4 certification, precisely because the failure mode is to drop
it as "Phase 1's problem". The mission-wide gate requires every open item to remain visible until
resolved.

### 9.2 Carried defects from earlier phases

| Source | Defect | State after Phase 4 |
|---|---|---|
| P2-GOV, defect E | CPU/RSS overhead fails KPI after classifier integration | **worse** — §7 |
| P2-GOV, defect D | Renamed-binary lookalikes defeat the classifier | unchanged; untouched by Phase 4 |
| P3-GOV | Combined P2+P3 overhead breach, apportionment open | **apportioned** — §7 |
| P4-2 | Shipped FP rate 8.3%, not the proposal's zero | unchanged — §3.2 |

### 9.3 Board health

`scripts/kanban-check.sh doctor --shortcode SLCD` reports **UNHEALTHY**: one exception,
"29 task(s) finished suspiciously fast (< 5.0s)".

**This is not attributable to SLCD-P4-GOV, and it is not attributable to the SLCD mission.** The
29 entries are board-wide history and include `test-card-1788295874373`, `test-sqlite-1788296735358`,
two `__home_agent__:*:antigravity` entries, and a majority with `Duration: 0.00s | Reason: exit`
across `cpai-opencode`, `cpai-opencode-deep` and `cpai-opencode-fast`. P1-GOV §8.3 recorded the
same exception. No remediation was performed, because deleting historical fast-exit records to
make a health check green would destroy the only evidence that they happened. It is carried
forward, unchanged, for the same reason P1-GOV carried it.

### 9.4 Not certified by this card — the enumeration

Named so that this certification's scope cannot be read wider than its evidence:

1. **Payload-derived metadata.** Zero canary hits proves no *verbatim* payload. It says nothing
   about byte counts, token counts, microsecond timestamps, ordering, cardinality, or any digest
   of content. A hash never trips a substring scanner and is invertible for low-entropy inputs.
   **P4-1's differencing attack remains unmitigated**; nothing here retires it.
2. **Transport envelope.** The audit's boundary is the encoder's output, not the socket write.
   Request headers, gRPC metadata and trailers, query parameters, retry and idempotency keys are
   not covered.
3. **Unexercised branches.** 15 records on the happy path. Oversize truncation, decode-error
   fallback, unknown-schema-version fallback, backpressure spill and dead-letter re-serialisation
   were not exercised and may serialise a different, less-filtered record.
4. **Cross-session attribution.** Five rounds × three threads bought race coverage on *presence*.
   With zero hits there is no observable that could distinguish correct attribution from
   misattribution, so no tenancy claim is made.
5. **Non-export egress beyond Phase 4's own modules.** §5.4 bounds `transcript.py` and
   `network.py`. The rest of the sensor was not swept for log, print or exception-string egress.
6. **Storage and query.** §10.

---

## 10. Decision — Phase 5 and Phase 6 must re-exercise the leak audit

**Decision: YES. Phase 4's audit does not cover the full pipeline, and Phase 5/6 may not treat it
as though it does.**

The reasoning is structural rather than cautious. This card's audit terminates at
`canonical_json(decode_wire(exported))` — the bytes the sensor hands to the transport. Three
distinct spans lie beyond it and each has its own serialisation, its own storage format and its
own projection:

1. **Ingestion (P5-1).** `signal-ingest` decodes the wire record into a Go struct and writes it.
   The Go field-emission guard covers the *struct*; it does not cover what the ingest path logs,
   traces, or writes to a dead-letter queue when decoding fails. A rejected record's error text
   is a plausible carrier and nothing has scanned it.
2. **Storage.** The record lands in a store with its own encoding. FrostDB Parquet is externally
   readable; a leak that reaches disk is a leak that persists, and no test in this mission has yet
   read a persisted record back and scanned it.
3. **Query and UI (P5-2, P6-3).** The dashboard projects records into `CodingAgentsTab.tsx`. A
   query that returns a column the export never intended to expose, or a UI that renders a
   debugging field, is a leak the sensor-side audit is structurally blind to.

**Concretely, Phase 5-GOV must run a leak audit that feeds a canary-bearing session in at the
sensor and reads the record back out through the query API, scanning at both ends.** Phase 6's
acceptance suite should carry the same audit as a browser-level assertion. Until that exists, the
mission's zero-customer-payload invariant is **proven at the sensor's export boundary and nowhere
else**, and this certification must not be cited as proving more.

---

## 11. Hard blockers — none triggered

| Blocker | State |
|---|---|
| A collected field that could carry prompt text, file contents, a credential value or process memory | **not present** — §4.5 enumerates every leaf as a bounded scalar |
| A field set that is a deny-list rather than a structurally-enforced allow-list | **not present** — §4.6 |
| A credential-detection path that records the value in order to detect it | **not present** — §4.7 |
| A change that removes an entry from the `proc.py` prohibited set | **not present** — §5.1, asserted by set equality |
| Absence of a Legitimate Interest Assessment or works-council position before workstation collection is enabled | **present, and it is the block** — §9.1. Collection is `DISABLED`, so the gate holds |

---

## 12. Verdict

**`status=blocked`.**

| Deliverable | Outcome |
|---|---|
| Zero payload harvesting across an end-to-end combined session | **PASS, with scope stated** — 15 records, 7 canaries, 0 hits, proven able to fail by three negative controls on the real encoder (§4). Scope enumerated at §9.4 |
| P4-2 CIDR list and measured false-positive rate both present and committed | **PASS on presence; CARRIED DEFECT on the rate** — 8.3%, not the proposal's zero (§3) |
| Combined overhead across all four merged subsystems | **MEASURED, KPI BREACHED** — 36.05% CPU against 1.0%, 42–60 MB RSS against 25 MB (§7) |
| Merged tree passes every `PROHIBITED_PROC_ENTRIES` pin | **PASS** — set equality, all 17 exercised, 48-module sweep clean (§5) |
| Honest record of whether P4-2's `stopAndReport` path was exercised | **PASS — it was not, because fd-avoidance fully succeeded** (§3.3) |
| Clean merge of P4-1 and P4-2 into `integration/slcd-v0.1.0` | **PASS** — both ancestors of `77a7e665`; zero source conflict markers; one orphaned marker repaired in the proposal (§1) |
| Merged Phase 4 emissions conform to P1-1's frozen schema | **PASS** — both guards re-run, not spot-checked (§2) |
| P4-1 fail-closed on an unrecognised format, on the merged tree | **PASS** — via the package's public import surface (§6) |
| Phase 1 OPEN/blocked items carried forward | **PASS** — 40 items, 22 blocking, collection `DISABLED` (§9.1) |
| Decision on Phase 5/6 re-exercising the leak audit | **RECORDED — YES** (§10) |

Phase 5 is cleared to proceed on the permitted work defined at P1-5 §0: schema design, pipeline
construction, and tests against synthetic fixtures on hosts carrying no employee data subject.
**It is not cleared to enable workstation collection**, and it must not cite this document as
proving the zero-payload invariant beyond the sensor's export boundary.
