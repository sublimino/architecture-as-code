# SLDP-P5-2 Execution Proof — DPIA and Legitimate-Interest Assessment Pack

**Date:** 2026-09-14 · **Card:** `SLDP-P5-2` · **Base ref:** `refs/heads/integration/sldp-v0.1.0`
**Worktree HEAD at start:** `e382ef570b2f79bf2156593edb8a16705642a87d`
**Deliverable:** [`dpia-reference-pack.md`](./dpia-reference-pack.md) — 640 lines, 15 sections

**Status: PASS.** The pack exists, both acceptance probes pass, both required test commands exit 0,
and the completeness checklist is delivered **failing 10 of its 34 rows** — which is the card's
requirement, not a shortfall. Two defects were found by this card's own probes *after* the document
was written and both were fixed (§5).

---

## 1. What this card built, and the one decision it rests on

The card asked for a DPIA "as evidence rather than as a document". The structural choice that
follows from that, and which shapes everything else, is:

> **The completeness checklist is the spine, not the appendix.** Each row names the artefact whose
> absence makes it fail and the reviewer role accountable for marking it. Prose sections exist to
> support checklist rows. A row the author cannot close is delivered marked `FAIL` rather than
> softened into prose.

The second load-bearing decision is in §3 of the pack and is the one most likely to be contested:

> **ControlPlane is almost certainly the *processor* for workstation telemetry, and the employing
> organisation the controller.** Enrolment is initiated by a customer operator redeeming a one-time
> token, not by ControlPlane and not by the monitored developer. **The Article 6(1)(f) balancing
> test therefore belongs to the customer.** The LIA in §6 is written as a template for the adopting
> controller to complete and sign, with ControlPlane's evidence supplied against each limb. §6.6 is
> deliberately left blank and is the pack's single largest incompleteness.

Writing §6 as ControlPlane's own concluded assessment would have been easier, would have read as
more complete, and would have asserted an authority ControlPlane does not have.

---

## 2. Required tests — executed, with exit status

| # | Command | Exit | Result |
|---|---|---:|---|
| 1 | `test -f docs/signalloom/dpia-reference-pack.md` | `0` | PASS |
| 2 | `rg -c 'legitimate interest\|Article 6' docs/signalloom/dpia-reference-pack.md` | `0` | `8` matches (`legitimate interest` ×2, `Article 6` ×6) |
| 3 | `make test-signal-ingest` | `0` | PASS — full module suite green; tail shows `ok .../transform 0.007s` |
| 4 | `bats test/acceptance-spec-coverage.bats` | `0` | **7/7 ok** |

```
ok 1 the guard can read every project in playwright.config.ts
ok 2 every spec on disk has exactly one registry row, and every row has a spec
ok 3 every registry runner is a known kind, and every non-CI row gives a reason
ok 4 a spec matches a playwright project if and only if the registry says so
ok 5 every ci: row names a stage that really runs that spec
ok 6 every spec a CI stage runs is registered as ci:
ok 7 every make: row names a target whose recipe runs that spec
```

**Note on commands 3 and 4:** this card writes no code, so neither suite can regress from it. They
were run because the card requires them, and because a green suite before a docs-only commit is the
cheapest evidence that the worktree was not already broken. They prove the tree's health, **not**
the pack's correctness — the pack's correctness is proved by §3 and §4.

---

## 3. Absence probes — the claims that needed positive evidence

The pack asserts that three controls **do not exist**. Per the project's own standing rule that a
tool which cannot see is indistinguishable from a world that is empty, each absence was probed and
the command recorded rather than inferred from a search that returned nothing.

| Claim | Probe | Result |
|---|---|---|
| **No Article 21 objection mechanism exists** | `grep -rniE 'object\|opt.?out\|denylist\|exclusion'` over `agentmaxxing-host-sensor/` and `signal-ingest/privacy/` | Only Go/Python `object` **type** declarations (`Dict[str, object]`, `"type": "object"`) and an unrelated telemetry-**field** allow-list. **No per-subject exclusion path.** |
| **No Article 18 restriction control exists** | `grep -rn 'frozen' d2-signalloom/apps/signal-ingest/identity/` | **Zero lines.** No `frozen` actor status |
| **`comm` is not collected**, contradicting an internal reference doc | `grep -rn "comm" models.py filter.py schemas/*.json \| grep -vi 'command\|comment'` | **Zero matches.** The v1 export carries no process name |

The Article 21 probe is the important one, because the falsified claim is *adjacent to a real
control*. `filter.py:33-48` genuinely is an allow-list — over **field names**. It has no per-subject
dimension and cannot exclude a person. A reviewer grepping for "allowlist" finds it and could
reasonably conclude the Art. 21 claim in `Signal Fusion — Architecture and GDPR Reference.md` §7.4
is substantiated. It is not.

---

## 4. Positive-evidence probes — the citations the pack makes

| Assertion in the pack | Probe | Result |
|---|---|---|
| All 17 SLDP-P0 storage sinks are inventoried | loop over each sink name, `grep -cF` | 17/17 present, zero `MISSING` |
| Threat model is cited by path | `grep -c 'demo-to-hosted-threat-model.md'` | `3` |
| Every phase proof P0–P4 is cited | `grep -cF` per filename | `sldp-p0-boundary-map` 3, `p1-1` 1, `p1-2` 1, `p3-1` 2, `p3-2` 1, `p4-1` 1, `p4-2` 1, `p4-governor` 1 |
| Art. 35(7)(a)–(d) all present | `grep -cF` per subsection | 2, 2, 2, 2 |
| Art. 35(1)/(3)/(9)/(11)/(2) and Article 36 present | `grep -cF` | 3, 5, 2, 1, 4, 2 |
| Three LIA limbs present | `grep -ciF 'Limb N'` | 1 each |
| Recital 49 addressed | `grep -ciF 'Recital 49'` | `6` — all in §6.1, which **refuses** it |
| Employment power imbalance addressed | `grep -ciF 'power imbalance'` | `2` |
| Schema closure cited as a minimisation control | `grep -ciF 'additionalProperties'` | `2` |
| Four jurisdictions with named instruments | `grep -cF` Germany/France/Netherlands/UK, BetrVG/CSE/WOR/ICO | 2,2,2,1 and 2,2,2,2 |
| Open items registered | `grep -oE 'OPEN-[0-9]+' \| sort -u \| wc -l` | **17** |
| Checklist is failable and failing | `awk` §12 range, count rows and markers | **34 rows: 24 PASS, 10 FAIL** |
| Markdown structurally sound | `grep -c '^```'` | `0` fences — parity even, no unclosed block |

---

## 4a. Adversarial review at the commitment boundary — eleven findings, all applied

Before committing, the pack was put to an independent advisor with three deliberately hostile
questions: is the controller/processor inversion wrong; is a conditional Article 36 position a
cop-out; and what would a DPO reject this for that is not already an open item. **It found a
legally dispositive framing error and an arithmetic incoherence, plus nine substantive gaps.** All
eleven were applied. They are listed because they are the most valuable output of this card.

| # | Finding | Severity | Applied as |
|---|---|---|---|
| 1 | **The document called itself a DPIA. Article 35 is a *controller* obligation and a processor cannot discharge it.** The correct instrument is the **Article 28(3)(f)** processor-assistance artefact | **Dispositive** | Retitled; `instrument:` frontmatter key; framing rewritten. This also makes the blank LIA at §6.6 *correct* rather than a gap |
| 2 | **The Article 36 conditional was arithmetically incoherent.** It said consultation was avoidable by closing four risks; there were seven (now eight) HIGH residuals, so four would still stand at deployment and consultation would be required anyway | **Dispositive** | §11.1 rewritten to **default to REQUIRED**, turning on "measures *taken*, not planned", with the error recorded rather than quietly corrected |
| 3 | **Article 9 by inference was entirely absent.** Working-hour patterns reveal religious observance, health and union activity; C-184/20 engages Art. 9 without intent, and 6(1)(f) is not a 9(2) condition | **High** | New risk **R-13**, checklist row **A-8**, **OPEN-23** |
| 4 | **"Only metadata" was doing work it cannot do.** A closed schema bounds field *count*, not inferential *reach* — WP29 Op. 2/2017, *Bărbulescu*, *López Ribalda* | **High** | Explicit call-out in §6.4 naming it a category error if extended beyond the content dimension |
| 5 | **Key custody unstated.** If ControlPlane holds the pseudonymisation key or per-subject KEKs it can re-identify — an essential means and the strongest argument against processorship | **High** | New §3.1, **OPEN-19**, row **C-11** |
| 6 | **Vendor-own-purpose processing not excluded.** Analytics, debugging, benchmarking or training on customer telemetry makes ControlPlane a *separate* controller | **High** | New §3.2, **OPEN-20**, row **C-12** |
| 7 | **Chapter V transfers had zero coverage** — a top-three DPIA rejection reason | **High** | §4.5 expanded, **OPEN-25**, row **B-8** |
| 8 | **"ControlPlane is a processor" cited no Art. 28(3) DPA** — circular as written | Medium | Circularity stated explicitly in **OPEN-2**, row **C-13** |
| 9 | **Negative controls prove the *tested* build only** — not the shipped binary, not future versions, not crash dumps | Medium | Four-part limits note in §4.3; **R-14**/**OPEN-21**; sensor-update vector as **R-15**/**OPEN-22** with the concrete fix (ingest rejects unknown `schema_version`) |
| 10 | **"Enrolment is operator-initiated" is a technical fact standing in for a legal argument**, and is ambiguous — if the operator *is* the developer, it smuggles in consent | Medium | §3 reasoning re-grounded on **the decision to deploy**; **OPEN-18** |
| 11 | **UK row confused a regulator with an instrument**; **no top-line verdict**; **Art. 35(9) and Art. 88 run as separate workstreams** when the works council can discharge both; **BYOD** was only a future flip condition | Low–Medium | UK row cites DPA 2018 Sch. 1 Pt. 2; `verdict:` frontmatter and a top-line disposition block; §11.1 tie note and row **F-3**; new §4.6 and **OPEN-26** |

**Net effect: the checklist grew from 34 rows to 45, and failures from 10 to 19.** Nine of the eleven
added rows fail. A review that adds only passing rows has not reviewed anything.

**The advisor's closing caution is recorded in the pack itself**, because it applies to this proof
too: the acceptance probes are presence checks, so a green run proves headings exist, not that the
prose beneath them is adequate. Findings 1, 3, 4, 5 and 6 would all have passed every probe in §4.

---

## 5. Two defects this card's own probes found after the document was written

Both are recorded because they are the most useful output of the verification pass — a document
that passes every probe on the first run usually means the probes were written to fit it.

**Defect 1 — the statutory reference a reviewer would grep for was absent.** The Article 36
consultation decision was written throughout as `Art. 36`. `grep -c 'Article 36'` returned **0**.
The decision was present and reasoned; it was simply not findable under its own name. Fixed at the
§11.1 heading and the C-4 checklist row; `grep -c 'Article 36'` now returns `2`.

**Defect 2 — the completeness checklist's own totals were wrong.** The §12 header claimed
"22 PASS, 9 FAIL" and the closing paragraph said "Nine rows cannot be closed". The table actually
holds **34 rows, 24 PASS, 10 FAIL**. The breakdown sentence also summed to 9, not 10. Fixed to the
counted values, with the corrected attribution: five controller decisions (C-1, C-4, C-9, G-1, G-2),
one DPO (G-3), one legal+HR (F-2), two platform-operations (B-6, B-7), one SLDP-P5-3 (C-8).

A completeness checklist that miscounts itself is precisely the failure mode this pack was written
to criticise elsewhere. Counting it with `awk` over the section range rather than trusting the
prose is what caught it.

---

## 6. A tracked file was mutated by the test run and was reverted, not committed

`make test-signal-ingest` rewrote `d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json`.
`redteam_cascade_test.go:70,172` writes it as a run artefact. The diff is **timestamps and measured
microsecond latencies only** — `total_caught` stayed `24/24`, every case stayed `CAUGHT`,
`false_merges` stayed `0`. It is a benign side effect of running the suite and is not this card's
work, so it was reverted with `git checkout --` before staging. `git status --porcelain` afterwards
showed exactly one line: the untracked pack.

Its prior `generated_at` was `2026-09-14T19:38:55Z`, roughly 40 minutes before this run — consistent
with a sibling P5 card having run the same suite. No action needed; recorded so a future reader does
not read the timestamp as evidence of a change this card made.

---

## 7. What the pack refuses to claim, and why that is the deliverable

| Refusal | Reason |
|---|---|
| §6.6 LIA outcome left **blank** | The balancing test belongs to the controller (§3). A filled-in outcome would be engineering putting words in a controller's mouth |
| §11.1/§11.2 approval and residual-risk blocks left **unsigned** | Same. Nine residual risks need a named human to accept or mitigate them |
| `Signal Fusion — Architecture and GDPR Reference.md` §7.4 **not cited as authority** anywhere | Three of its five rights claims are false (§3 above). SLDP-P5-PRE's warning was explicit: "shipping a DPIA pack citing an inaccurate rights table is worse than shipping none" |
| §7.4 **not edited by this card** | SLDP-P5-3 was `in_progress` concurrently and owns the Art. 15/20/21 mechanisms §7.4 describes. Editing it here is a live shared-file collision with the card best placed to fix it correctly. Logged as `OPEN-3` with SLDP-P5-3 named |
| Recital 49 **rejected** as a basis | It addresses network and information security. Signal Loom's workstation purpose is agent governance on developer machines — adjacent, not identical. A recital is also interpretive and creates no lawful basis on its own |
| Necessity on the **frequency** axis conceded as unproven | `OPEN-7`. No evidence exists that *continuous* sampling is necessary rather than convenient. This is the weakest link in the necessity argument and the pack says so rather than papering it |
| Article 36 recorded as **conditional**, not decided | Consultation is not required *only if* the controller closes R-6, R-8, R-9 and R-12 before deployment. Deploying with any of the four open makes it required. That is a controller decision; C-4 fails until taken |

---

## 8. Findings the next card should not have to re-derive

1. **Article 18 has no owner on the current board.** `frozen` does not exist, and restriction is not
   in any P5 or P6 row — P5-3 covers Articles 15, 20 and 21 only. `OPEN-10`. This is a genuine gap
   in the programme plan, not just in the code.
2. **Article 88 is on the critical path, not in parallel.** Germany (BetrVG §87(1)(6), a
   **co-determination veto**, not a consultation right), France (CSE, L2312-38) and the Netherlands
   (WOR Art. 27(1)(l), consent) each require an employee-representative instrument concluded
   **before** deployment, with lead times in weeks to months. Any plan treating the DPIA as the last
   compliance step is wrong for those three jurisdictions. Italy (Art. 4 Statuto dei Lavoratori) and
   Spain (LOPDGDD Art. 87–90) are known hard gates and have not been reviewed at all (`OPEN-17`).
3. **Seven risks carry a HIGH residual** (R-6, R-7, R-8, R-9, R-10, R-12, with R-2 medium-high).
   Four have an owner and a scheduled card. **R-6 (working-hours inference), R-8 and R-9 (unproven
   log and backup sinks) and R-12 (repurposing) have no mitigation in flight at all** — these four
   drive the Article 36 condition.
4. **R-6 is the principal unmitigated *privacy* risk and it is not a code defect.** Continuous
   process liveness plus `host_id` reconstructs an individual's working hours no matter how good the
   content minimisation is. Content minimisation cannot address it; only sampling frequency can.
5. **Seven flip conditions are enumerated in §10.** The two that matter soonest: **SLCD** adds disk
   transcript metadata from `~/.claude/` and `~/.gemini/antigravity-cli/`, moving the processing from
   *process liveness* to *records of the subject's work product* — §6.4's content argument does not
   survive it unchanged. **SLER** adds a cgroup-freezer kill switch, which strengthens the
   Art. 35(3)(a) "similarly significant effects" reading and engages Art. 22.
6. **OPEN-4 and OPEN-5 are where an unassessed copy of personal data most likely lives today** —
   application/container log retention, and volume snapshots. Both are outside the code boundary,
   which is exactly why a code-derived inventory cannot close them. Platform operations owns both.
7. **A warning for whoever writes the Art. 15 acceptance test (SLDP-P5-3).** A test asserting
   "returns 200 with the subject's data" passes against a handler reading **one** store. The graph
   spans PostgreSQL *and* FrostDB. Assert cross-store completeness with a negative fixture — a
   subject having FrostDB rows but no PostgreSQL rows — that fails a partial implementation.

---

## 9. Assumptions forced by a missing prerequisite

**`docs/signalloom/sldp-p5-pre-proof.md` does not exist in this worktree.** `ls docs/signalloom/sldp-p5*`
→ `No such file or directory`. SLDP-P5-PRE committed `a6974f6b` to its own task worktree pending
Governor reconciliation, which has not happened, so its artefacts are not on
`integration/sldp-v0.1.0`.

Its seam confirmations were consumed instead from the `Errata — SLDP-P5-PRE` block in the proposal,
which carries them in full. **Every P5-PRE finding this pack relies on was independently re-probed**
(§3) rather than taken on trust, so the missing file cost verification effort but did not force an
unverified assumption. Recorded rather than treated as a blocker.

One assumption genuinely remains open: **the controller/processor allocation in §3 is inferred from
the enrolment architecture, not read from an executed contract or DPA.** `OPEN-2`, owner
ControlPlane legal. If that allocation is wrong, §6 needs rewriting — which is why it is stated
first in the pack rather than buried.

---

## 10. Scope discipline

| Constraint | Evidence |
|---|---|
| No migration created | `identity/migrations/` still ends at `009_subject_keys.sql` |
| No `.go`, `.py` or `.sql` under `d2-signalloom/` modified | `git status --porcelain` after revert: one line, the untracked pack |
| No sibling worktree touched | All work in `/home/andy/src/.worktrees/8e959/osramp-demo` |
| No push, no PR, no merge to the integration branch | Committed to the task worktree only; Governor reconciles |
| Proposal file not staged | It lives in the Obsidian vault outside this repo; edited with file tools only |
| No attested segment or checkpoint affected | This card writes no code |
| Board inspected read-only once | `kanban-check.sh progress` — confirmed P5-1 and P5-3 concurrent |

**`/goal` could not be invoked.** The card mandates
`/goal with token budget of 200000 and 100 auto-retries`, but no `goal` skill is registered in this
harness. SLDP-P5-PRE recorded the identical finding. The stated budget and the 180-minute ceiling
were respected regardless; the run finished well inside both.
