---
title: SLCD-P1-GOV — Phase 1 certification of the zero-payload, credential-leak, procfs-pin and wire-contract invariants
card: SLCD-P1-GOV
role: governor
integration_branch: integration/slcd-v0.1.0
verdict: BLOCKED — every technical invariant certified by test; the lawful basis is incomplete and workstation collection is gated off in code
certified_on: 2026-09-15
---

# SLCD-P1-GOV — Phase 1 Governor certification

> **Verdict: `status=blocked`.** Every technical invariant this card was asked to certify is
> certified, and certified **by executed test with an observed failure**, not by code review. The
> block is not a technical defect. It is `SLCD-P1-5`'s lawful basis: **40 `OPEN-SLCD-` items stand,
> 22 of which block collection.** Phase 2 may proceed on schema, allow-list and synthetic-fixture
> work; **workstation collection is gated off in code** by `lawful_basis.py`, delivered by this card.

## 0. What "certified by test" means here, and why it was necessary

The card's stated failure mode was *"certifying the zero-customer-payload invariant by reading the
collector code rather than running a test that goes red when an off-list field is added"*. Reading
would have produced a wrong answer twice over:

* `scripts/sync_coding_agent_schema.py` — the file that *looks* like the build-time guard — is
  **one-directional**. It asserts every *schema* property exists in the Go and Python models. It
  never asserts the converse. An off-list field added to a model passes it cleanly. A review that
  stopped at that file would have certified a guard that does not guard.
* The guard that actually holds is `telemetry_test.go:294`, which reflects over the Go struct and
  fails on any field absent from the schema. That is only discoverable by running it.

So every claim below is backed by a mutation that was applied, **asserted to have landed on disk**,
observed to turn the suite red, and then reverted with a verified `sha256`. A green suite after a
mutation that silently failed to apply is a false acquittal, not a survival; each sweep asserts the
mutation before trusting the verdict.

## 1. Baseline — the merged tree

| Fact | Value |
| :--- | :--- |
| Governor worktree | `/home/andy/src/.worktrees/osramp-demo/slcd-v0.1.0/governor` |
| Branch | `integration/slcd-v0.1.0` |
| Base commit at certification | `4d691f747b72e6812c4a4195efe107771637ca1d` |
| Branch tip when this card committed | `d2d85096840d71e0a1b3a78fe62a4c24d6c7f092` (see note) |

> **Concurrency note.** A sibling AMXD session advanced this shared branch by 7 commits
> (`a386350b`…`d2d85096`, AMXD-P2-1/P2-2 demo panels) while this certification was running.
> `4d691f74` is a verified ancestor of `d2d85096`, and
> `git diff 4d691f74..d2d85096 -- d2-signalloom/apps/agentmaxxing-host-sensor
> d2-signalloom/apps/signal-ingest/codingagent docs/signalloom/slcd-p1-5-lawful-basis.md`
> is **empty** — no SLCD-relevant path changed. The suites were re-run at the post-commit tip and
> reported below, so this certifies the actual merged tree rather than a pre-merge state.
| Go suite | `go test ./...` — **all 27 packages `ok`**, exit 0 |
| Python suite (pre-gate) | `python3 -m unittest discover -p 'test_*.py'` — **Ran 136 tests, OK** |
| Python suite (post-gate) | **Ran 146 tests, OK** (+10 delivered by this card) |

**P1-1 … P1-5 were already merged** into `integration/slcd-v0.1.0` before this card ran, by the
phase controller:

| Card | Feature commit | Merge commit |
| :--- | :--- | :--- |
| P1-1 schema + metadata dictionary | `88d30371` | `e1b0072e` |
| P1-2 payload validator + leak suite | `d7703326` | `86341513` |
| P1-3 `codingagent.v1` wire contract | `9b8b4b2d` | `e0cf674e` |
| P1-4 procfs pins + exe resolution | `747b2dc3` | `1789dcda` |
| P1-5 Art. 6(1)(f) LIA + Art. 88 register | `ec8c9569` | `ba3e4931` |

No merge was outstanding, so **no conflict resolution occurred and no stale allow-list copy could
be reintroduced** — the specific risk the card named. This was verified by re-deriving the allow-list
from the merged tree rather than trusting any card's report: `wire.allowed_keys()` has 41 entries and
the Python guard pins that number literally.

## 2. Zero-customer-payload invariant — CERTIFIED

The field set is a **structurally-enforced allow-list**, not a deny-list. Four independent
mechanisms, all exercised:

1. **Schema closure.** `additionalProperties: false` on all six objects — root, `process_info`,
   `kanban_info`, `metrics_info`, `tool_counts`, `network_info`.
2. **Go reflection converse-check** (`telemetry_test.go:280-294`) — fails on any struct field with no
   schema definition.
3. **Python exact-set + count pin** (`test_allow_list_matches_schema_exactly`) — asserts
   `sorted(want) == wire.allowed_keys()` **and** `len(...) == 41`.
4. **No-free-text invariant** (`ZeroPayloadInvariant`) — every string field must carry *both*
   `maxLength` and `pattern`; a length bound alone is not a content bound.

### Mutation M1 — off-list field on the Go struct

Added `PromptText string \`json:"prompt_text"\`` to `CodingAgentTelemetry`; confirmed present on disk.

```
--- FAIL: TestCodingAgentTelemetry_SchemaConformance_Allowlist (0.00s)
    telemetry_test.go:294: SCHEMA CONFORMANCE FAILURE: Go struct field "prompt_text"
                           has no matching definition in JSON schema allowlist
FAIL	.../signal-ingest/codingagent	0.022s
```

**The build-level guard fails on an off-list field, exercised live.** This is the card's deliverable
"a build-level guard confirmed to fail on an off-list field, exercised live rather than read from
source", and it is the claim that a source read would have got wrong.

### Mutation M2 — off-list field added to the frozen schema

Added a `prompt_text` string property (`maxLength: 100000`) to the frozen schema root. Seven distinct
assertions fired, including two that a narrower guard would have missed:

```
AssertionError: Lists differ: [... 'prompt_text', 'schema_version' ...] != [... 'schema_version' ...]
AssertionError: 1 != 0 : generated artefacts drifted from the schema
AssertionError: 'c08f6ad8…46fd' != '2000426d…48a4'          # schema digest pin
AssertionError: Lists differ: ['prompt_text'] != []          # unbounded-string detector
AssertionError: 100616 != 616 : the per-record free-text budget changed; update
                docs/signalloom/slcd-p1-3-wire-contract.md and justify it to P1-GOV
```

The **per-record free-text budget** (616 bytes total across every string field in the contract) is the
strongest single control in the freeze: widening any string bound anywhere moves one number, and that
number is pinned and addressed to this Governor by name.

Both mutations reverted; `sha256` verified identical; suites green again.

## 3. Credential-leak invariant (P1-2) — CERTIFIED

`test_leak_falsification.AdversarialLeakFalsificationTests` — **13 adversarial fixtures, 5 tests,
100% rejection, `OK`**, re-run against the merged tree at certification time rather than trusted from
P1-2's report. Coverage extends beyond the original `test_negative_security.py:71` fixture to AWS,
Anthropic and generic-bearer shapes.

The card's hard blocker — *"any credential-detection path that records the credential value in order
to detect it"* — is **not** present, and this is asserted rather than assumed:

* `test_zero_leakage_in_detection_report_and_metadata` — `DetectionReport` contains zero secret
  substrings across all fixtures.
* `test_zero_leakage_in_exception_messages_under_adversarial_injection` — `ZeroPayloadSecurityException`
  messages never carry candidate secret tokens. **This is the subtle one**: the obvious way to write a
  helpful error is to quote the offending value, which would turn the detector itself into the leak.
* `test_transient_buffer_memory_scrubbing_under_load` — transient match buffers are zeroed.

## 4. procfs pin coverage (P1-4) — CERTIFIED EXHAUSTIVELY

`PROHIBITED_PROC_ENTRIES` contains **exactly the 17 members the card enumerates**, none removed:

```
attr clear_refs cmdline cwd environ fd fdinfo io maps mem net pagemap
root smaps smaps_rollup stack syscall
```

Reading the test file would only show that *some* entries are covered. Instead, a **17-way deletion
sweep** was run: each entry removed in turn, the removal asserted against the imported module
(`'<entry>' in proc.PROHIBITED_PROC_ENTRIES` → `False`) before the verdict was trusted, the full
suite run, then restored.

```
attr  clear_refs  cmdline  cwd  environ  fd  fdinfo  io  maps
mem  net  pagemap  root  smaps  smaps_rollup  stack  syscall     -> all KILLED

SWEEP RESULT: killed=17  survived=0  not_applied=0  of 17
FINAL RESTORE: OK
```

**Every member is individually load-bearing**, each killing between 2 and 4 tests. Zero silently
unpinned. `proc.py:105` remains a genuine pre-`open()` chokepoint — it raises *before* the descriptor
exists, unlike `filter.py`, which is post-hoc.

## 5. Cross-language wire contract (P1-3) — CERTIFIED IN BOTH DIRECTIONS

The card warned against *"approving based on a partial test run (only the Go suite or only the Python
suite)"*. Both were run, and the contract is pinned bidirectionally by a **shared fixture corpus**
(`schemas/fixtures/{canonical,differential,go-encoded,reject,valid}`, plus `canonical-digests.json`):

| Direction | Test |
| :--- | :--- |
| Go decodes Python-encoded bytes | `TestCodingAgentWireContract_DecodesPythonEncoded` |
| Python decodes Go-encoded bytes | `test_go_encoded_bytes_decode_here` |
| Both record the same digest | `test_go_and_python_record_the_same_digest` |
| Codepoint-vs-byte length parity | `test_go_length_checks_count_codepoints_not_bytes` |
| Whole reject corpus refused in Go | `TestCodingAgentWireContract_RejectsEveryCorpusCase` |
| Canonical form is stable | `TestCodingAgentWireContract_CanonicalIsStable` |

The OpenAPI document is **generated, not hand-maintained** (`scripts/gen_wire_contract.py`, carries a
`DO NOT EDIT` marker) and is pinned to the frozen schema by digest — M2 proved that pin fires. Go
rejects unknown top-level fields at decode (`telemetry.go:369`), so the allow-list is enforced on the
ingest side too, not only at emit.

`coding_agent_wire.py` is itself generated and digest-pinned. **This is why the lawful-basis gate in
§7 is a separate module rather than a guard inside `canonical_json()`**: hand-editing a generated,
digest-pinned file would have broken the P1-3 freeze that this card exists to protect.

## 6. Lawful basis (P1-5) — INCOMPLETE. This is the block.

The assessment exists, is substantial (80 KB), and its own conclusion is that **collection is not
lawfully grounded today**:

```
collection_state: DISABLED — Workstation collection must not be enabled while any OPEN-SLCD item stands
status:           NOT ADOPTED — no controller has signed §8; no employee-representative
                  instrument has been started in any jurisdiction that requires one
```

**40 `OPEN-SLCD-` items, ids 1–40 contiguous and all present in the document. 22 block collection —
7 unconditionally and 15 for the jurisdictions or conditions they name.** No controller has adopted
it; no works council, CSE, OR, RSU or union has been approached in any jurisdiction; the in-scope
workstation roster does not exist, which is why no jurisdiction can currently be evidenced as out of
scope.

Jurisdictions carrying a hard gate rather than a notice duty include **Austria** (§96(1)(3) ArbVG —
absolute veto, *not* substitutable by the *Schlichtungsstelle*), **Germany**, the **Netherlands**
(WOR), **Italy** (Art. 4 St. Lav., where Art. 4(3) failure renders the data unusable *for any
purpose*), and **France** (failure to consult is *délit d'entrave*, a criminal offence).

§0.3 of the assessment anticipates this Governor by name:

> *"A Governor, phase gate or acceptance run must not mark SLCD-P1-5 'done' and thereby read the gate
> as lifted. This card delivers the assessment; the assessment's own conclusion is that collection
> stays off. Those are different facts."*

**This certification records those as different facts.** P1-5 is delivered; the gate is not lifted.

## 7. The gate is now enforced in code, not only in a document

The card's sharpest failure mode: *"if the lawful basis has an OPEN item, workstation collection must
be gated off **in code**, not just noted in a document."* Before this card, it was not. A repository
search for `collection_state`, `lawful`, or any workstation kill-switch returned nothing — and
`OPEN-SLCD-2` says so explicitly: *"the sensor has no technical mechanism to enforce that distinction
today."*

Delivered: **`d2-signalloom/apps/agentmaxxing-host-sensor/lawful_basis.py`** — fail-closed, with
**no environment variable, CLI flag or config key that opens it**. Opening the gate requires editing a
constant *and* the assessment, which is a reviewable two-file diff rather than an ops decision.

**`test_lawful_basis_gate.py` — 10 tests, all non-vacuous** (each reads the live gate or the live
assessment, so none can pass by describing something absent):

| Guard | What it catches |
| :--- | :--- |
| `test_assert_raises_and_names_the_call_site` | the gate refuses today, naming the blocked path |
| `test_no_environment_override_exists` | source-level — a future `os.getenv` bypass fails here |
| `test_frontmatter_collection_state_matches_code` | code/document drift, in **either** direction |
| `test_open_item_count_matches_code` | ids 1–40 contiguous; a dropped item fails |
| `test_blocking_count_matches_code` | the 40/22 totals cannot quietly change |
| `test_endpoint_reference_set_is_exactly_the_allowlist` | **any new module that touches the transmission endpoint without gating fails the build** |

Both gate guards were kill-proofed live:

```
COLLECTION_STATE = "DISABLED" -> "ENABLED"        =>  FAILED (failures=2)
added an ungated sender module _rogue_sender.py   =>  FAILED (failures=1), naming the file
both reverted                                     =>  Ran 146 tests, OK
```

This test caught a real defect in its own first draft — the allow-list was written from assumption
and named two modules that do not reference the endpoint. The pin rejected the guess. A vacuous
guard would have passed.

## 8. Carry-forward to Phase 2 — every OPEN item, closed by none

Nothing below is closed by omission at Governor level.

### 8.1 Lawful basis — `OPEN-SLCD-1` … `OPEN-SLCD-40` (all 40 carried forward)

All 40 remain OPEN; 22 block collection. They are **not** restated here in abridged form, because an
abridged restatement is how an item gets quietly dropped — `docs/signalloom/slcd-p1-5-lawful-basis.md`
§11 and §14 are the register of record, and `test_open_item_count_matches_code` now fails the build if
that register shrinks. Items of particular engineering consequence:

| Item | Why Phase 2+ must carry it |
| :--- | :--- |
| `OPEN-SLCD-1` | in-scope workstation roster does not exist → **no** jurisdiction can be evidenced out of scope |
| `OPEN-SLCD-2` | *partially addressed by this card* — `lawful_basis.py` is now the mechanism; the host-classification half (is this host an employee workstation?) remains open |
| `OPEN-SLCD-7` | continuous vs periodic sampling NOT ASSESSED — continuous `kanban.elapsed_s` reconstructs working hours directly |
| `OPEN-SLCD-8` | **the sharpest open question** — whether `metrics.*` is necessary at all. If not, it fails Art. 6(1)(f) Limb 2 outright regardless of balancing. Bears directly on P4-1 |
| `OPEN-SLCD-9` | dropping transcript reads would remove the F9 payload-proximity risk. Must be decided **with** `OPEN-SLCD-8`, not after. Bears directly on P4-1 |
| `OPEN-SLCD-12/13` | no DPO review; data-subject views not sought |
| `OPEN-SLCD-14/16/18/21` | Austria / France / Italy / Belgium instruments NOT STARTED |

**`OPEN-SLCD-8` and `OPEN-SLCD-9` are flagged to SLCD-P4-PRE as gating its scope**, not merely
informing it: if `metrics.*` is dropped, P4-1's transcript parser largely disappears with it. Building
P4-1 first and deciding later is the expensive order.

### 8.2 Routing gap — carried to SLCD-P5-1, and pinned by test

P1-3 flagged that the dashboard's nginx `/api/` prefix proxies to `fe-signalloom-api`, **not**
`signal-ingest`, so the frozen endpoint `/api/v1/telemetry/coding-agents` has **no route today**.

This is **not** resolved here, and it is not merely noted: `TestCodingAgentWireContract_RoutingGapIsStillOpen`
asserts the gap is still open — it fails if `/api/` moves off line 102, if the upstream stops being
`fe-signalloom-api`, if the block starts naming `signal-ingest`, or if `api/auth.go` / `api/handlers.go`
register the frozen path. **The gap cannot be closed silently, and it cannot be assumed closed.**
Recorded as a hard dependency of **SLCD-P5-1**.

### 8.3 Board health — `doctor` raises one exception

The required evidence names *"zero kickoff gate exceptions"*. It is **not** met, and this is reported
rather than rounded off:

```
━━━ [doctor] 1 EXCEPTION(S) RAISED ━━━
FAST-EXIT / AGENT CRASH DETECTED: 29 task(s) finished suspiciously fast (< 5.0s)
Doctor Status: UNHEALTHY (1 exception(s) require remediation)
```

**Scope, stated precisely so it is not over- or under-claimed:** the 29 tasks are board-wide and
historic, spanning `cpai-opencode*` and `antigravity` agents plus two synthetic fixtures
(`test-card-1788295874373`, `test-sqlite-1788296735358`). **None is an `SLCD-P1-*` card.** Every SLCD
Phase 1 card committed real artefacts, which is inconsistent with a fast-exit crash. The exception is
therefore a pre-existing board-hygiene condition, not a Phase 1 defect — but it is an open exception
against the literal required evidence, it is **not** waived here, and it is carried to **SLCD-P2-PRE**.

Note on method: `doctor`'s exit status is not a usable gate here — the observed `DOCTOR_RC=0` is the
status of the trailing `tail` in the pipeline, not of `doctor`. The verdict above is read from the
printed `Doctor Status:` line, which is the honest signal. Recorded so a later card does not read
`rc=0` as health.

## 9. Hard blockers — none triggered

| Blocker | Finding |
| :--- | :--- |
| A field that could carry prompt text, file contents, a credential or process memory | **Absent.** Every string field bounded by `maxLength` **and** `pattern`; total free-text budget 616 bytes/record, pinned |
| Field set is a deny-list rather than a structurally-enforced allow-list | **Not the case.** Allow-list, four mechanisms, mutation-proven |
| Credential detection that records the value in order to detect it | **Absent.** Asserted for reports, metadata and exception messages |
| An entry removed from the proc.py prohibited set | **None removed.** All 17 present, all 17 individually kill-proven |
| Absence of a LIA or works-council position before workstation collection is enabled | **LIA present; collection NOT enabled.** Gated off in code by `lawful_basis.py` |

No hard blocker fired, so this card did not stop. The `blocked` verdict is the lawful-basis gate
standing as designed, not a failure to deliver.

## 10. Verdict

**`status=blocked`** — the mission may not enable workstation collection. Phase 2 is cleared to
proceed on the permitted work defined at assessment §0: schema design, allow-list construction, unit
and leak tests against synthetic fixtures, and collection against hosts carrying no employee data
subject.

| Certification | Verdict |
| :--- | :--- |
| Zero-customer-payload invariant | **PASS** — by mutation, not review |
| Build-level off-list-field guard | **PASS** — exercised live (M1) |
| Credential-leak invariant | **PASS** — 13 fixtures, 100% rejection |
| procfs pin coverage | **PASS** — 17/17 individually kill-proven |
| Cross-language wire contract | **PASS** — both directions, shared corpus |
| Merge of P1-1…P1-5 | **PASS** — already merged; re-verified, no conflict |
| Lawful basis | **BLOCKED** — 40 OPEN, 22 blocking |
| Workstation collection gated off in code | **PASS** — delivered by this card |
| Zero doctor exceptions | **FAIL** — 1 exception, board-wide, carried to P2-PRE |
