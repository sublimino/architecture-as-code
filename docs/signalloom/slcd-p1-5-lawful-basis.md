---
title: SLCD — Article 6(1)(f) Legitimate Interest Assessment and Article 88 works-council position for developer-workstation coding-agent telemetry
card: SLCD-P1-5
status: NOT ADOPTED — no controller has signed §8; no employee-representative instrument has been started in any jurisdiction that requires one
collection_state: DISABLED — see §0. Workstation collection must not be enabled while any OPEN-SLCD item stands
supersedes: docs/signalloom/dpia-reference-pack.md §6, by operation of that pack's own flip condition F-1
assessed_on: 2026-09-15
assessed_against: worktree HEAD ebfa3dce513542034f51c27ba5815065f30559fa
review_due: on any §15 flip condition, otherwise 12 months from controller adoption
---

# SLCD — Legitimate Interest Assessment and works-council position for developer-workstation coding-agent telemetry

> **Read §0 first.** This assessment does not authorise collection. It records that collection is
> **not** lawfully grounded today, names precisely what would have to happen for it to become so,
> and lists every item still open with an owner against each. **40 items are OPEN, of which 22 block
> collection** — 7 unconditionally and 15 for the jurisdictions or conditions they name. No controller has adopted
> this assessment. No works council, CSE, OR, RSU
> or union has been approached in any jurisdiction. The in-scope workstation roster does not exist.
>
> **What this document is — and the label matters.** ControlPlane engineering states a position on
> each of the three Article 6(1)(f) limbs below, with the evidence that supports it and the evidence
> that undermines it. **The position is not the decision.** Article 6(1)(f) is a controller
> judgement and Article 88 is a negotiation with a body that can say no. Sections requiring
> engineering fact are answered; sections requiring controller judgement or counsel are left open on
> purpose, attributed, and identified so that leaving them open is visible rather than silent.
>
> **This is engineering evidence, not legal advice.**

---

## 0. Gating statement — collection remains DISABLED

**Workstation collection of coding-agent harness telemetry under the SLCD mission must not be
enabled — in any environment containing a real employee workstation — until every `OPEN-SLCD-`
item in §14 is resolved, and in particular until every jurisdiction in the §11 register carries a
non-OPEN status or is evidenced as containing no in-scope workstation.**

This is not a recommendation and it is not satisfied by partial progress. Three consequences follow
and each is deliberate:

1. **A jurisdiction whose employee-representative instrument is unresolved blocks collection on
   workstations in that jurisdiction**, not merely the reporting about them. In Germany, the
   Netherlands and Italy the relevant body holds a veto or a consent right, so "start collecting and
   consult in parallel" is not a lesser version of compliance — it is the unlawful version.
2. **Because the in-scope roster does not exist (`OPEN-SLCD-1`), no jurisdiction can currently be
   evidenced as out of scope.** Until the roster exists, the gate applies to all workstations.
3. **A Governor, phase gate or acceptance run must not mark SLCD-P1-5 "done" and thereby read the
   gate as lifted.** This card delivers the assessment; the assessment's own conclusion is that
   collection stays off. Those are different facts and P3-GOV's certification exists to catch
   exactly the confusion between them.

The permitted work while this gate stands: schema design, allow-list construction, unit and leak
tests against synthetic fixtures, and collection against hosts with **no employee data subject** —
that is, a machine on which the only person whose activity is observed is the person who
deliberately enrolled it for development purposes and who is not being monitored by an employer.
`OPEN-SLCD-2` covers the fact that the sensor has no technical mechanism to enforce that
distinction today.

---

## 1. Why this document exists, and what it supersedes

The repository already carries an Article 28(3)(f) DPIA assistance pack at
`docs/signalloom/dpia-reference-pack.md`, containing a three-limb Article 6(1)(f) Legitimate
Interest Assessment at its §6 and an Article 88 jurisdiction table at its §13.

**That pack expires when this mission ships, by its own terms.** Its §10 flip-condition register
records:

> **F-1 — SLCD ships.** Coding-agent detective telemetry adds procfs tree inspection, kanban loop
> watching, **disk transcript metadata**, and inference socket detection … Moves the processing from
> *process liveness* to *records of the subject's work product*. This is a materially different
> intrusion and §6.4's content argument does not survive it unchanged.

This document is the fresh assessment that flip condition requires under Article 35(11). It is
written as a **delta**: it does not restate the pack's Article 35 analysis, its storage-copy
inventory, its risk register or its pseudonymisation and erasure evidence, all of which stand. It
assesses what SLCD changes, and it re-runs the three limbs and the Article 88 register against the
changed facts, because the pack's own conclusion was that they do not survive the change unchanged.

**Where this document and the pack disagree, this document governs for SLCD processing** and the
pack governs for the pre-SLCD workstation plane. Neither governs the other's scope. Two
inheritances are carried forward explicitly rather than re-derived:

| Inherited from the pack | Why it still binds |
|---|---|
| **Consent is not available.** EDPB guidance treats employees as unable to give freely-given consent because of the employment power imbalance (pack §6.4) | The imbalance is a property of the employment relationship, not of the field set. SLCD does not change it. Consent must not be used as the basis for any part of this processing |
| **Controller/processor allocation** — the employing organisation is controller for workstation telemetry; ControlPlane is processor, except on its own estate where it is controller (pack §3) | Unchanged by SLCD, but `OPEN-SLCD-3` records that the pack's own OPEN-18 (who "operator" is at enrolment) is still unresolved and is load-bearing here too |
| **Article 36 prior consultation is currently REQUIRED** on eight unmitigated HIGH residuals (pack §11.1) | SLCD adds intrusion; it cannot subtract from that determination. The Art. 36(2) clock of up to 14 weeks sits on the same critical path as §11's works-council lead times |

---

## 2. The SLCD delta — what actually changes

The processing this assessment covers is the difference between what the sensor does today and what
the SLCD mission adds. Stating the delta precisely is what makes the balancing test assessable;
"telemetry" is not.

**Today's export surface, verified at `HEAD ebfa3dce`.** The widest field that can reach a persisted
record on the host-sensor path is a bounded integer:

- `filter.py:34-40` — `ALLOWLISTED_PROCESS_ATTRIBUTES` = `health_state`, `cpu_time_ms`,
  `resident_memory_bytes`, `exit_code`, `restart_count`. Every one is a bounded integer except
  `health_state`, which is a closed enum.
- `filter.py:43-48` — `EXTENDED_PROCESS_ATTRIBUTES` adds `cpu_percent`, `pid`, `ppid`.
- `filter.py:222-230` — `filter_attributes` **drops** unlisted keys. This is the load-bearing
  control, and it is an allow-list.
- `proc.py:14-32` — `PROHIBITED_PROC_ENTRIES`, 18 entries, consulted by `_safe_proc_path`
  (`proc.py:103-110`) which raises **before** the path is constructed, so no `open()` is reached.
  `cmdline`, `environ`, `fd`, `net`, `cwd`, `mem` and `maps` are all in that set.

**What SLCD adds**, from the proposal's Architectural Constitution envelope and from
`docs/signalloom/slcd-p1-pre-inventory.md` §6:

| New field group | Example fields | Category change |
|---|---|---|
| `kanban.*` | `task_id`, `shortcode`, `role`, `elapsed_s` | **What the individual was working on, and for how long** — a per-task duration attributed to a person |
| `metrics.*` | `step_count`, `tokens_in`, `tokens_out`, `tool_counts{}` | **Work-rate metrics** — volume of work produced per session, per person |
| Transcript metadata | field names and counts read from `~/.claude/projects/*.jsonl`, `~/.codex/sessions/**`, Antigravity's session tree, OpenCode's SQLite | **Records of the subject's work product**, read from files that also contain the work product itself |
| `harness` | closed enum of seven values | Which tool the individual chose to use |
| `network.*` | `inference_endpoint`, `egress_bytes` | **Not implementable** — `/proc/net` and `/proc/<pid>/fd` are both in `PROHIBITED_PROC_ENTRIES`; P1-PRE finding F3 |

**Three observations that the balancing test at §7 turns on.**

First, **`kanban` plus `metrics` is, in ordinary language, a productivity dataset.** Step count,
token volume and tool-call counts per task per person, with elapsed time, is the shape of a
work-rate measure. The mission's `outOfScope` forbids *inferring individual developer productivity*
from it. That prohibition is real and is restated as a prohibition at §12.4 — but it is a **policy
control over use**, sitting at the weakest available intervention level, while the data that makes
the inference trivial is **structurally admitted** by the schema. A reviewer should read the
prohibition as a commitment requiring audit, not as a property of the system.

Second, **the transcript-reading capability reaches around the `proc.py` chokepoint.** P1-PRE
finding F9 established that Antigravity's session records carry
`tool_calls[].args.CommandLine` — the same command-line data whose collection `proc.py:17` prohibits
— as an ordinary JSON string, and that none of the 38 `PROHIBITED_EXPORT_KEYS` entries spell any of
the camelCase or PascalCase payload keys the harnesses actually use (`newString`, `originalFile`,
`lastPrompt`, `ReplacementContent`, `AbsolutePath`). The deny-list would not catch them. **Only the
`ALLOWLISTED_*` construction can be relied on here**, and the mission's hard blocker requiring a
structurally-enforced allow-list rather than a deny-list is therefore correct on evidence rather
than on principle. This assessment's balancing conclusion at §7 is conditioned on that allow-list
existing in the form P1-1 delivers it; see flip condition F-SLCD-3.

Third, **`network.*` is not implementable within the current invariants.** P1-PRE escalated this
(F3) because delivering it would require removing `fd` or `net` from `PROHIBITED_PROC_ENTRIES`,
which is a declared hard blocker. This assessment assumes both fields are **dropped**. If the
capability is ever delivered by some other route, this assessment expires — flip condition
F-SLCD-4.

---

## 3. The processing purpose, stated precisely

A purpose that is not specific cannot be balanced against a right, because there is nothing concrete
on the other side of the scale. "Security", "visibility" and "governance" — the proposal's terms —
are not specific enough.

**The purpose is:** *to detect which autonomous coding-agent harnesses are running on
organisation-managed developer workstations, to attribute the actions those harnesses take to the
human whose delegated credentials authorised them, and to retain sufficient session metadata that an
action taken by an agent can be reconstructed and accounted for after the fact.*

**The purpose is not, and telemetry collected under this assessment must not be used for:**

- measuring, ranking, comparing or reporting individual developer output or productivity;
- capacity planning, utilisation measurement, or workforce sizing based on individual records;
- attrition or flight-risk prediction;
- any input to a decision about an individual's employment, remuneration, assignment or discipline;
- assessment of whether an individual is working at any given time.

This exclusion mirrors the mission's own `outOfScope` and the pack's §6.5 purpose-limitation
prohibition, and it is restated as an operative prohibition at §12.4 rather than as an intention.
**Nothing in the system technically prevents any of the above today** (`OPEN-SLCD-4`).

The distinction from productivity monitoring is not a matter of intent, and this document does not
ask a reviewer to take it on trust. It is the difference between *reconstructing a specific action
after a specific question is asked* and *maintaining a standing measure of a person's output*. The
first requires the data to be retrievable; the second requires it to be aggregated, compared and
reported. **The architectural test of the distinction is therefore whether any aggregate,
per-individual, cross-session view of `metrics.*` is ever built** — a dashboard that ranks
developers by token volume is the same data with a different purpose, and it would breach this
assessment on the day it shipped. `OPEN-SLCD-5` places that constraint on the dashboard card.

---

## 4. Article 6(1)(f) is the basis, and Recital 49 is not available

Recital 49 provides that processing strictly necessary for **network and information security** —
preventing unauthorised access, stopping denial-of-service, detecting malicious code — constitutes a
legitimate interest. It is routinely over-read, and it does not carry this processing.

**First, a recital is interpretive and creates no lawful basis of its own.** Even where Recital 49
is squarely engaged, the Article 6(1)(f) balancing test still has to be performed and documented.
Citing the recital does not remove a step; it supplies a factor to one.

**Second, and decisively, the scope does not match.** SLCD's stated purpose is to observe
autonomous coding agents on developer machines — agent governance and attribution, adjacent to
security but not the network-security purpose Recital 49 addresses. The moment the telemetry answers
*how a developer works with an agent* rather than *whether the estate is under attack*, Recital 49
is behind the argument rather than in front of it. SLCD moves decisively in that direction: neither
`metrics.step_count` nor `kanban.elapsed_s` has a network-security reading.

**Third, the network-security fields are the ones that are not being built.** `network.inference_endpoint`
and `network.egress_bytes` are the only two fields in the proposed envelope with a genuine Recital 49
character, and both are blocked (§2). The processing that survives is the processing Recital 49 does
not cover.

**Article 6(1)(c) where available.** Where a controller is subject to DORA Art. 11 or NIS2 and can
identify the specific obligation this processing discharges, Article 6(1)(c) may be available
instead and does not require a balancing test. That is a controller determination on the controller's
own regulatory perimeter, not an engineering one (`OPEN-SLCD-6`). It is named here because a
controller who has it should use it, and because a controller who *asserts* it without identifying
the specific obligation has done something worse than a weak balancing test.

**This assessment therefore relies on a full three-limb Article 6(1)(f) assessment and on nothing
else.**

---

## 5. Limb 1 — Purpose test

*Is there a legitimate interest, is it specific, and whose is it?*

| Interest | Party holding it | Why it is legitimate | Evidence |
|---|---|---|---|
| Establishing attributable authority for actions taken by autonomous coding agents operating under a developer's delegated credentials | The employing organisation (controller) | Agents execute shell commands, edit source and invoke build tooling under a human's authority. Without attribution the organisation cannot answer "who authorised this?" about changes to its own estate, and it carries the consequences | `docs/Signal Loom Workstation Sensor — Architecture, Verification, and Distribution Strategy.md` §1–2; the delegated-credential model is the premise of the whole mission |
| Knowing which autonomous tooling is running on managed endpoints at all | The controller | An organisation cannot govern, patch, licence or incident-respond to software it cannot enumerate. Harness discovery is asset inventory applied to agents | `slcd-p1-pre-inventory.md` §1.1 — seven candidate harnesses, of which four were live on a single host and one (`antigravity`) is not even a binary under the name the proposal uses |
| Reconstructing an incident in which an agent took a consequential action | The controller, and third parties relying on its audit | Attested segments and checkpoint chains already exist for this purpose (SLDP P1-3, P3-1) | pack §5.3 |
| Meeting sector obligations (DORA Art. 11, NIS2) requiring demonstrable operational-resilience evidence | The controller, where regulated | Where a specific obligation is identified, Art. 6(1)(c) is the better basis and balancing is not required — see §4 | `OPEN-SLCD-6` |

**Rejected as stated interests**, and restated as prohibitions at §12.4: developer performance
management, productivity ranking, capacity planning, attrition prediction.

**Position on Limb 1: PASSED.** The interests are real, current, specific, and lawfully held. The
first is the strongest: autonomous agents acting under delegated human credentials is not a
speculative threat model. Note what this does *not* establish — a legitimate interest is a
precondition for the balancing test, not a substitute for it. A reader tempted to stop here is
making the exact error §7 exists to prevent.

---

## 6. Limb 2 — Necessity test

*Is this processing necessary for those interests, or is there a less intrusive way?*

| Alternative | Verdict | Reasoning |
|---|---|---|
| **Network-only or proxy monitoring** | Insufficient, and more intrusive | Agent traffic is end-to-end TLS. Process ancestry and local filesystem interaction are invisible without MITM interception, which sees payload — the opposite of minimisation |
| **In-band MCP handshake or agent-side instrumentation** | Insufficient, and more intrusive | Sits in the data path and therefore necessarily sees prompt and code payload. The mission's "strictly detective posture" exists precisely to avoid this |
| **Aggregate-only, no per-host identifier** | Insufficient for the first interest | Attribution *is* the purpose; aggregation destroys it. But note this argument does not extend to frequency — see the next two rows |
| **Periodic sampling rather than continuous observation** | **NOT ASSESSED — `OPEN-SLCD-7`** | Inherited unresolved from pack OPEN-7 and materially worse under SLCD, because continuous `kanban.elapsed_s` sampling reconstructs working hours directly rather than by inference. No evidence exists that continuous sampling is necessary rather than convenient. **This is the weakest link in the necessity argument and it is stated as such** |
| **Drop `metrics.*` entirely and keep `harness` + `session_id` + `kanban.task_id`** | **NOT ASSESSED — `OPEN-SLCD-8`, and this is the assessment's sharpest open question** | Attribution — "which agent, under whose authority, on which task" — is satisfied without a single work-rate field. `step_count`, `tokens_in`, `tokens_out` and `tool_counts` are not required by any interest named at §5. If they are not necessary, they fail Limb 2 outright, regardless of how the balancing test comes out |
| **Drop transcript reading and derive `session_id` from the process tree** | **NOT ASSESSED — `OPEN-SLCD-9`** | P1-PRE §6 shows transcript reads are the only source for `metrics.*` on most harnesses and for `session_id` on some. If `metrics.*` goes (OPEN-SLCD-8), the transcript-reading requirement largely goes with it — and with it the F9 payload-proximity risk. The two questions should be decided together |
| **Collect only while an agent session is active, not continuously** | **NOT ASSESSED — `OPEN-SLCD-10`** | Would bound the working-hours inference to periods when the developer chose to run an agent |

**Position on Limb 2: NOT PASSED. Three necessity questions are open and two of them are
load-bearing.**

The *content* minimisation is well evidenced and the alternatives to it are genuinely worse. That is
not the same as showing the processing is necessary. `OPEN-SLCD-8` in particular asks whether four
of the proposed fields serve any stated interest at all; on the current record they do not, and a
field that serves no stated interest cannot be necessary for one. **A controller adopting this
assessment before OPEN-SLCD-7, -8 and -9 are answered is adopting an unresolved necessity limb, and
Article 5(1)(c) data minimisation is engaged independently of Article 6.**

---

## 7. Limb 3 — Balancing test

*Do the controller's interests override the interests, rights and freedoms of the data subject?*

The data subjects are employees and contractors. Their machine is the place they work.

### 7.1 Factors weighing toward the data subject

- **Employment power imbalance.** The same imbalance that makes consent unavailable makes the
  employee's reasonable expectations weigh *more*, not less. An employee cannot negotiate, decline,
  or meaningfully leave.
- **The data subject is not a party to the transaction.** The developer is not ControlPlane's
  customer, has no relationship with the vendor, and cannot influence what is collected.
- **The developer may never encounter a notice surface.** Enrolment is performed by a customer
  *operator* redeeming a one-time token; nothing in the enrolment flow requires the monitored
  individual to be informed. Notification is therefore an obligation this document must specify
  (§12), not a product feature it can assume.
- **SLCD collects records of the subject's work product, not merely of their machine's liveness.**
  This is the specific change that expired the previous assessment. `kanban.task_id` plus
  `elapsed_s` is "what this person was doing, and for how long".
- **The work-rate fields make productivity inference trivial, and only policy stands between the
  data and that use.** `step_count`, `tokens_in`, `tokens_out` and `tool_counts` per session per
  person is a work-rate measure whatever it is called. The prohibition at §12.4 is a policy control
  over a structurally-admitted dataset (`OPEN-SLCD-4`). A balancing test that treats a policy
  prohibition as equivalent to a structural exclusion has weighed something that does not exist.
- **Working hours, breaks, absence and out-of-hours working remain inferable, and more sharply than
  before.** The pack carried this as R-6 from process liveness alone. `elapsed_s` and continuous
  session observation reconstruct it directly. `OPEN-SLCD-7` and `-10` are the mitigations, and
  neither has been assessed.
- **Transcript reading places the sensor in the same files as the payload.** The developer's
  reasonable expectation about a file containing their prompts and their source diffs is not the
  same as their expectation about `/proc/<pid>/statm`. Even a perfectly-implemented metadata-only
  read is a read of that file. F9 establishes the deny-list would not catch a mistake here.
- **Special categories may be revealed by inference.** Working-pattern data can reveal religious
  observance, health-related absence and caring responsibilities without any special-category field
  being collected. Inherited as pack OPEN-23; unresolved.
- **No objection mechanism exists in the product** (§13). A right the subject cannot exercise is
  weightless in a balance that relies on it.
- **Home and personal-device blurring.** If the sensor reaches a personally-owned machine the
  balance changes materially and this assessment does not cover it (`OPEN-SLCD-11`; flip condition
  F-SLCD-2).

### 7.2 Factors weighing toward the controller

- **The content boundary is structural and test-asserted, not promised.** `filter_attributes`
  (`filter.py:222-230`) drops unlisted keys; `_safe_proc_path` (`proc.py:103-110`) raises before
  `open()`. A DPO can verify the boundary by reading two functions. This is materially stronger than
  a documented minimisation policy, because it fails closed by construction.
- **No prompt text, no source code, no model output, no argv, no environment — architecturally, not
  by policy.** The most-feared category of developer monitoring is excluded at the level that
  matters.
- **The field set is published in full** (§2 of this document and §12.2's notice), which is the
  cheapest and most effective thing available for moving reasonable expectations.
- **Pseudonymisation before the immutable store, and effective per-subject erasure that has been
  mutation-proven** (pack §5.2–5.3). Erasure that has been shown to fail when deliberately broken is
  unusual, and it materially improves the subject's position relative to a typical monitoring
  product.
- **The network-interception path is closed, not merely unused.** The two Recital-49-flavoured
  fields are blocked by the same prohibited set that blocks `cmdline`.
- **A real and current risk.** Agents executing under delegated credentials is happening now, on
  these machines, and the organisation carries the consequences of what they do.

### 7.3 The argument this assessment refuses to make

> **A bound on fields is not a bound on intrusiveness.**
>
> A closed schema bounds *field count*. It does not bound *inferential reach*. Session start and
> stop times from one person's laptop, accumulated across months and joined to `host_id` and
> `kanban.task_id`, yield working hours, break patterns, absence, out-of-hours and weekend working,
> and what that person was working on and when. WP29 Opinion 2/2017 on data processing at work, and
> the ECtHR line in *Bărbulescu v Romania* and *López Ribalda v Spain*, go directly at continuous
> employee monitoring on exactly this reasoning.
>
> **The "it's only metadata" argument is available to this assessment for the *content* dimension
> only, and is a category error if extended to intrusiveness as a whole.**

The Zero-Customer-Payload invariant and P1-1's field allow-list appear at §7.2 as **inputs** to the
balance — genuine ones, and unusually strong for this product category. They are not the balance.
A narrow field set makes the balancing test easier to win; it does not make the test unnecessary.
Any document, dashboard, sales deck or review that cites the invariant *in place of* the balancing
test has made the error this card exists to correct.

### 7.4 Where the balance sits, on the evidence available

**Split, and the split is the finding.**

| Dimension | Position | Basis |
|---|---|---|
| **Content** (no payload, structurally enforced) | Balances **clearly in the controller's favour**, on unusually strong evidence | §7.2, first three bullets |
| **Attribution** (`harness`, `session_id`, `kanban.task_id`, `role`) | Balances **in the controller's favour**, subject to notice (§12) and an operable objection route (§13) | The interest at §5 row 1 is strong and cannot be served a less intrusive way |
| **Work-rate metrics** (`metrics.*`) | **Does not balance.** No stated interest requires them (`OPEN-SLCD-8`), and they place a productivity dataset on the employee's machine behind a policy prohibition | §6, §7.1 bullet 5 |
| **Continuity** (continuous rather than session-scoped or sampled observation) | **Does not balance.** Unassessed necessity (`OPEN-SLCD-7`, `-10`) against a direct working-hours reconstruction | §7.1 bullet 6 |
| **Transcript reading** | **Open.** Depends entirely on whether the P1-1 allow-list is structural, and on whether `metrics.*` survives | §2 third observation; F9 |

---

## 8. LIA outcome

**ControlPlane engineering's assessed position**, stated so that a reviewer has something to
disagree with rather than a row of empty boxes:

| Limb | Position | Qualification |
|---|---|---|
| Purpose test | **Passed** | Interests are specific, current and lawfully held (§5) |
| Necessity test | **Not passed** | Three open questions, two load-bearing: `OPEN-SLCD-7`, `-8`, `-9` (§6) |
| Balancing test | **Passed for content and attribution; not passed for work-rate metrics or continuity; open for transcript reading** | §7.4 |
| **Overall** | **The processing as currently proposed does not have an established lawful basis.** A narrower processing — attribution fields only, session-scoped, with §12 notice and §13 objection in place — is assessed as capable of passing all three limbs | — |

**The three limbs are conjunctive, and this document does not pretend otherwise.** A failed
necessity limb is not a weak score to be offset by a strong balancing limb; it ends the assessment.
Because Limb 2 is not passed and consent (§1) and Recital 49 (§4) are both unavailable, **there is
no lawful basis for the processing as currently specified, and §0's gating statement is the
operative conclusion of this document rather than a precaution attached to it.** The balancing test
at §7 is nonetheless performed and published in full, for two reasons: it identifies *which* parts
of the processing would survive a fixed necessity limb (§7.4), and it is the input the controller
needs in order to choose between narrowing the processing and not deploying. It is not an argument
that the processing may proceed.

**The split balance at §7.4 is an instruction, not an average.** Where a balance differs by data
element, the processing must be split by data element and only the passing part deployed. Read
together with §6, the concrete implication is: **drop `metrics.step_count`, `tokens_in`,
`tokens_out` and `tool_counts`, and make collection session-scoped rather than continuous.** That is
the narrowed processing referred to in the Overall row, and on the evidence in this document it is
the only version that reaches a passing assessment.

**Per-purpose decomposition is required before adoption.** Security incident reconstruction, agent
asset inventory, licence and capacity management, and productivity measurement are four different
interests with four different balances. §5 names three and rejects the fourth outright. A controller
must not adopt a composite assessment across purposes it later adds; adding a purpose re-opens §5
through §8, and is flip condition F-SLCD-5 or F-SLCD-6 depending on which purpose.

**No covert monitoring.** The controller must declare, and this document records as a condition of
its conclusions, that the sensor is never deployed covertly. Every affected individual is notified
under §12 before collection begins. Covert deployment would breach the ICO's 2023 expectation
directly and would falsify the reasonable-expectations premise on which §7.2 rests.

### 8.1 Elements this assessment knows it is still missing

Listing them is cheaper than a reviewer finding them, and a document that claims completeness it
does not have is worse than one that does not claim it.

- **The harm has never been quantified** (`OPEN-SLCD-35`). Necessity is argued against a threat
  model, not against incidence data. This is very likely the root cause of the Limb 2 result rather
  than a separate defect.
- **Reasonable expectations are partly argued from our own notice** (`OPEN-SLCD-38`) — a circularity
  WP29 Opinion 06/2014 warns against specifically. Independent evidence is needed.
- **No Article 22 / automated-decision analysis** (`OPEN-SLCD-36`), which becomes load-bearing the
  moment `metrics.*` reaches an appraisal.
- **No Article 9 leakage control and no BetrVG §78 chilling-effect analysis** (`OPEN-SLCD-37`).
- **No Article 30 record-of-processing entry, no DPO advice, no named approver or review trigger**
  (`OPEN-SLCD-39`).
- **No vendor-chain position** — Art. 28, Chapter V, TIA, sub-processors — where a hosted coding
  agent touches this data (`OPEN-SLCD-40`). German and Dutch works councils commonly block here.
- **This assessment is an input to a DPIA, never a substitute for one.** The DPIA and the Article 36
  prior-consultation determination live in `dpia-reference-pack.md` §11.1, which currently records
  consultation as **required** on eight unmitigated HIGH residuals. SLCD adds intrusion and cannot
  subtract from that.

### 8.2 Controller adoption — UNSIGNED

An assessment is *made* when a controller adopts it. This one has not been.

| Field | Value |
|---|---|
| Purpose test accepted? | ☐ Yes ☐ No — *controller to complete* |
| Necessity test accepted? | ☐ Yes ☐ No ☐ Yes, for a narrowed field set — *controller to complete* |
| Balancing test outcome | ☐ Interests override ☐ Do not override ☐ Override for attribution only — *controller to complete* |
| Reasoning (mandatory free text — a tick with no reasoning is not a balancing test) | |
| Assessed by (name, role) | |
| Data Protection Officer consulted (Art. 35(2))? | ☐ Yes ☐ No — no DPO has reviewed this document (`OPEN-SLCD-12`) |
| Views of data subjects sought (Art. 35(9))? | ☐ Yes ☐ No ☐ Not appropriate, with reasons — not sought (`OPEN-SLCD-13`) |
| Date | |

> **Article 35(9) and Article 88 should be discharged together.** In the employment context the
> employee-representative consultation required by §10–11 **is** the natural vehicle for seeking the
> views of data subjects. Running them as separate workstreams duplicates effort and risks this
> document recording "views not sought" while a works council is being consulted on the same
> processing. Owner: legal + HR.

---

## 9. Which workstations are in scope — the roster does not exist

The card requires this assessment to enumerate every jurisdiction where in-scope developer
workstations are located. **That enumeration cannot be made from the evidence available, and saying
so is the honest answer rather than a gap to paper over.**

What is actually known, by probe:

| Evidence | Finding |
|---|---|
| `docs/signalloom/slcd-p1-pre-inventory.md` header | P1-PRE inventoried **exactly one host** — `andy`, Linux, observed 2026-09-15 |
| `git log --format='%ad' --date=format:'%z'` over 2,448 commits | 2,447 commits at `+0100` (UK/Western Europe summer offset); **one at `-0600`**, author `torinvdb@gmail.com`, commit `57769231` |
| `git log --format='%ae'` author domains | `gmail.com` throughout — no corporate domain, so email cannot establish employment status or location for any contributor |
| Proposal RACI | Names three ControlPlane individuals; states no locations |
| Repository search for a workstation roster, fleet inventory or enrolment register | None exists |

Two conclusions follow, and both are load-bearing:

1. **The in-scope roster is `OPEN-SLCD-1`, and it blocks the whole gate at §0.** A jurisdiction
   cannot be evidenced as out of scope while no one knows which machines are in scope. The `-0600`
   commit is not proof of a US-based in-scope workstation — it is proof that the contributor base is
   not UK-only, which is precisely why the assumption cannot be made in either direction.
2. **The §11 register is therefore written as a *capability* register, not an *exposure* register.**
   It records, for each jurisdiction, what would be required *if* an in-scope workstation is located
   there. Every jurisdiction is OPEN until the roster exists, because until then none can be
   excluded.

The roster must record, per workstation: jurisdiction of the employee's place of work (not of the
employing entity, and not of the server), employment status (employee, contractor, or neither),
device ownership (organisation-managed or personally owned — pack OPEN-26), and whether any
employee-representative body has competence over that employee.

---

## 10. Article 88 and national employment law — a separate instrument, on a separate clock

**Article 6(1)(f) is necessary and not sufficient, and this section is not a sub-clause of §7.**

Article 88(1) permits Member States to provide "more specific rules" for processing in the
employment context, and several have done so. Those rules are **not discharged by a balancing test**.
They are discharged by a different instrument — typically a works agreement, a consultation, or a
union negotiation — concluded with a **different body**, on a **different timeline**, with a
different failure mode. A balancing test is an assessment the controller performs and can complete
alone. A works agreement is a negotiation with a counterparty who can refuse.

**Four structural differences that make conflating them the most expensive single error available
here:**

| | Article 6(1)(f) balancing test | Article 88 / national instrument |
|---|---|---|
| **Who performs it** | The controller, alone | The controller *and* an employee-representative body |
| **Can it fail?** | It can conclude against the controller, who then does not proceed | The counterparty can **refuse**. In DE, NL and IT this is a veto or consent right, not a consultation |
| **Timeline** | Days — it is an authoring task | **Weeks to months.** It is on the critical path to deployment, not parallel to it |
| **Can it be retrofitted?** | A late LIA is defective but the defect is repairable going forward | **No.** Deploying before a required consultation is a breach that completing the consultation afterwards does not cure |

**Two further points that are frequently got wrong and are recorded here because they bear directly
on this mission:**

**A works agreement does not lower the GDPR floor.** In C-34/21 *Hauptpersonalrat der Lehrerinnen und
Lehrer* (30 March 2023) the CJEU held that a national provision adopted under Art. 88(1) which does
not satisfy Art. 88(2) — specific, suitable safeguards for human dignity, legitimate interests and
fundamental rights — is not applicable, and the processing falls to be assessed under Articles 5, 6
and 9 directly. C-65/23 *MK v K GmbH* (19 September 2024) confirmed that a **collective agreement's**
provisions on employee data are fully reviewable by national courts against Art. 88(1) and (2).
**The practical consequence: concluding a German *Betriebsvereinbarung* does not discharge §7, and
§7 passing does not make a *Betriebsvereinbarung* unnecessary.** Both are required and neither
substitutes for the other. This is the same point the card makes about timelines, sharpened by the
case law.

**Notice to the individual is a third, separate obligation.** Several jurisdictions impose an
individual-notification duty that is not satisfied by consulting a collective body — France's
*Code du travail* Art. L1222-4, Poland's *Kodeks pracy* Art. 22³ §7, and the Articles 13/14
transparency duty everywhere. §12 specifies it.

---

## 11. Per-jurisdiction works-council register

**Read this table with §9 in hand: no jurisdiction can currently be excluded, because the in-scope
roster does not exist.** A jurisdiction absent from this table would read as cleared, so the table
ends with a catch-all row that closes that gap explicitly rather than by omission.

Status values: **OPEN** = not started or unresolved. **NOT APPLICABLE** = evidenced as carrying no
in-scope workstation. No row may be **NOT APPLICABLE** while `OPEN-SLCD-1` stands.

| Jurisdiction | Instrument | Character | Position under SLCD | Status |
|---|---|---|---|---|
| **Austria** | **ArbVG §96(1)(3)** — control measures and technical systems touching human dignity require a **works agreement (*Betriebsvereinbarung*)**. Unlike §96a, it is **not substitutable by the arbitration board (*Schlichtungsstelle*)** | **Absolute veto.** No BV means the measure is **void** — the strictest row in this table | Austria is listed first precisely because it is the hardest gate and an earlier draft of this document buried it in the catch-all row. A workstation telemetry agent is a §96(1)(3) system; the works council can simply refuse, and there is no arbitration route around the refusal | **OPEN-SLCD-14 — NOT ASSESSED BY COUNSEL, NOT STARTED.** Owner: legal + local HR |
| **Germany** | **BetrVG §87(1)(6)** — works-council co-determination over the introduction and use of technical devices *suited to* monitoring employee behaviour or performance. **§94(2)** — co-determination over assessment principles (*Beurteilungsgrundsätze*), engaged once telemetry becomes an appraisal input. **§90** design consultation. **§26 BDSG**, subject to C-34/21 | **Co-determination, substitutable by arbitration.** **Not a permanent veto** — under §87(2) an impasse goes to the *Einigungsstelle*, whose decision replaces agreement. The council can delay and force arbitration; it cannot block indefinitely. This affects the **timeline**, not the requirement | A *Betriebsvereinbarung* must be concluded **before** deployment. SLCD strengthens the §87(1)(6) case: `metrics.*` is *Leistungskontrolle* on its face, which is the provision's second limb — and the moment it informs an appraisal, **§94(2)** engages as a separate co-determination right. Where a BV already covers the pre-SLCD sensor **it does not automatically extend**; a materially changed device or use requires a new or amended agreement. Note §78 — a works-council member's own activity must not be chilled by the telemetry | **OPEN-SLCD-15 — NOT STARTED.** Owner: legal + local HR. Lead time weeks to months including any *Einigungsstelle*; critical path for any German deployment |
| **France** | **C. trav. Art. L2312-8 II 4°** — the operative **consultation** duty, on introduction of new technologies and any important modification of working conditions. **Art. L2312-38** — information to the CSE on means or techniques permitting control of employee activity. **Art. L1222-3** — methods and techniques of *evaluation* must be disclosed to the employee in advance. **Art. L1222-4** — no information may be collected by a device not brought to the employee's prior knowledge. **Art. L1121-1** — proportionality, the French core test. CNIL employee-monitoring guidance; *règlement intérieur* entry | **Mandatory consultation** prior to the implementation decision, plus **two** individual-notice duties the consultation does not satisfy. **Failure to consult is *délit d'entrave* — a criminal offence** | L2312-38 alone is an information duty and is not the gate; **L2312-8 II 4° is.** An earlier draft cited only L2312-38. `metrics.*` is a *méthode d'évaluation* and therefore engages L1222-3 directly, which is the sharpest French hook for work-rate telemetry | **OPEN-SLCD-16 — NOT STARTED.** Owner: legal + local HR |
| **Netherlands** | **WOR Art. 27(1)(l)** — works-council (OR) **consent** for arrangements concerning facilities aimed at or suitable for observation of, or control over, presence, behaviour or performance. **Art. 27(1)(k)** for personal-data processing arrangements | **Consent.** Without OR consent the arrangement is voidable | OR consent required before deployment. Both (k) and (l) are engaged; (l) directly by `metrics.*` | **OPEN-SLCD-17 — NOT STARTED.** Owner: legal + local HR |
| **Italy** | **Art. 4 Statuto dei Lavoratori (L. 300/1970)** as amended by D.Lgs. 151/2015 — instruments from which remote monitoring may derive require **either** a collective agreement with the RSU/RSA **or** authorisation from the Ispettorato Nazionale del Lavoro. **Art. 4(3)** requires adequate individual information on use and on checks, failing which the data are **unusable for any purpose** | **Hard gate**, and Art. 4(3) is a separate usability condition on top of it | **The Art. 4(2) question must be answered explicitly and is answered here.** Art. 4(2) exempts "strumenti utilizzati dal lavoratore per rendere la prestazione lavorativa". Per **INL Circolare 2/2016**, software that adds monitoring *beyond the tool's ordinary operation* falls back under Art. 4(1). A sensor installed alongside the developer's tooling to count steps and tokens is monitoring beyond ordinary operation. **Conclusion: not exempt; the agreement or the authorisation is required.** An unrecorded Art. 4(2) assumption is the standard route to an Italian penalty | **OPEN-SLCD-18 — NOT ASSESSED BY COUNSEL, NOT STARTED.** Owner: legal + local HR |
| **Spain** | **LOPDGDD (LO 3/2018) Art. 87** — digital privacy in the use of devices made available in the workplace. **Art. 87(3)** requires criteria of use to be established **with the participation of workers' representatives**. **ET Art. 64.4(d)** (inserted by Ley 12/2021) — the works committee is entitled to be informed of the **parameters, rules and instructions of algorithms affecting working conditions**, including access to and maintenance of employment and profiling. **ET Art. 64.5** — prior report, 15 days, on work organisation and control systems. **ET Art. 20.3** — control measures | **Participation right** under LOPDGDD 87(3), plus an **algorithmic-transparency information right** under ET 64.4(d) | An earlier draft cited "Arts. 87–90"; Arts. 88 (disconnection), 89 (video) and 90 (geolocation) do not apply and the range concealed the actual gate. **ET 64.4(d) is squarely on point** — `metrics.*` feeding any ranking or assessment is an algorithm affecting working conditions | **OPEN-SLCD-19 — NOT ASSESSED BY COUNSEL, NOT STARTED.** Owner: legal + local HR |
| **Poland** | **Kodeks pracy Art. 22³§1** — forms of monitoring other than video, applying the machinery of **Art. 22²§6–§10**: purposes, scope and manner set out in the *układ zbiorowy*, *regulamin pracy* or an *obwieszczenie* (§6); employees informed in the customary manner **no later than 2 weeks before launch** (§7); each new hire informed **in writing before admission to work** (§8). **Art. 104²** — union consultation on the *regulamin pracy* | **Procedural hard gate** with a statutory notice period that cannot be compressed | An earlier draft asserted an equipment-**marking** duty; that is **Art. 22²§9 and applies to premises under video monitoring**, not to Art. 22³ telemetry. Corrected. The 2-week notice and the individual written notice are additional to §12 of this document | **OPEN-SLCD-20 — NOT ASSESSED BY COUNSEL, NOT STARTED.** Owner: legal + local HR |
| **Belgium** | **CBA No. 39** — prior information to the works council on the introduction of new technologies with collective consequences for employment, work organisation or working conditions (undertakings ≥50). **CBA No. 81** applies only to the monitoring of **electronic online communications data** | **Prior collective information duty** under CBA 39 | An earlier draft cited **CBA 81 as the instrument. That was wrong**: process metadata, task identifiers and token counts are not electronic online communications data. **CBA 39 is the gate**; CBA 81 is retained only against any future element that touches communications content | **OPEN-SLCD-21 — NOT ASSESSED BY COUNSEL, NOT STARTED.** Owner: legal |
| **Nordics — Sweden, Finland, Denmark, Norway** | **Sweden: MBL §11** — primary negotiation obligation with the union before important changes, which covers introducing monitoring. **Finland: Act on the Protection of Privacy in Working Life (759/2004) §21** — technical monitoring is subject to the **co-operation procedure**, now under the **Co-operation Act 1333/2021** (which repealed 334/2007 on 1 Jan 2022). **Denmark:** the DA/FH agreement on control measures requires justification and **6 weeks' notice** — but it **binds member organisations only**, so the entity's membership must be established before treating it as a gate. **Norway: Working Environment Act §9-2** — duty to discuss with the *tillitsvalgte* as early as possible, to inform, and to evaluate; ch. 9 generally; Hovedavtalen LO–NHO Tilleggsavtale V if organised | **Sweden and Finland are procedural gates**, not advisory. Finland's is the sharpest — the co-operation procedure must be **completed**, not merely started | Listed individually because "Nordics" as a block hides four different clocks, and because the Danish gate is conditional on a fact nobody has checked | **OPEN-SLCD-22 — NOT ASSESSED BY COUNSEL, NOT STARTED.** Owner: legal + local HR |
| **Luxembourg, Croatia, Slovakia** | **Luxembourg: Labour Code L.414-9** — staff delegation **co-decision** on general criteria for surveillance of activity and performance; **L.261-1** prior information. **Croatia:** Labour Act — works-council **prior consent** for decisions on collecting, processing and using employee personal data. **Slovakia: Labour Code §13(4)** — mandatory prior consultation with employee representatives on scope, manner and duration of monitoring | **Luxembourg and Croatia are consent/co-decision gates**, comparable to the Netherlands | Grouped because all three were absent from an earlier draft and each is a genuine pre-deployment gate. **Article numbers in this row are unverified and must be confirmed by local counsel** before reliance — they are recorded so the jurisdictions are not omitted, not because the citation has been checked | **OPEN-SLCD-23 — NOT ASSESSED BY COUNSEL, ARTICLE NUMBERS UNVERIFIED, NOT STARTED.** Owner: legal |
| **European Works Council (transnational)** | **Directive 2009/38/EC** (recast; amending Directive (EU) 2023/… in transposition) and the undertaking's own EWC agreement, or the subsidiary requirements in its absence | **Information and consultation on transnational matters**, separate from and additional to every national row above | A group-wide monitoring rollout across two or more Member States is the paradigm transnational matter. **An EWC obligation is not discharged by consulting national bodies one by one.** Whether one exists depends on headcount thresholds and group structure — facts this card cannot establish | **OPEN-SLCD-24 — NOT ASSESSED.** Owner: legal. First question: does an EWC or an Art. 13 pre-existing agreement exist for the group at all? |
| **Ireland** | **No works-council co-determination analogue.** Employees (Provision of Information and Consultation) Act 2006 creates a forum only where employees request one; where a forum exists, it is consulted. GDPR applies directly; DPC guidance on workplace monitoring sets the transparency expectation | Transparency and the LIA are the substantive instruments unless a forum exists | The §7 assessment plus the §12 notice is the instrument | **OPEN-SLCD-25 — position stated; DPC guidance not formally run; existence of an I&C forum not checked.** Owner: legal |
| **United Kingdom** | **UK GDPR Art. 6(1)(f)** (the same three-limb test) and **DPA 2018 Sch. 1 Pt. 2** where an employment-law condition is engaged. **There is no works-council co-determination analogue**, but the **Information and Consultation of Employees Regulations 2004 (ICE Regs)** create an information-and-consultation duty on request in undertakings of 50+ employees, on decisions likely to lead to substantial changes in work organisation. The ICO is the regulator, not an instrument; its **Employment practices and data protection — monitoring workers (2023)** guidance sets the expectation of a documented impact assessment, worker transparency and an explicit position against covert monitoring | The LIA at §5–8 plus the §12 notification *is* the substantive instrument — subject to ICE Regs where an agreement or a valid request exists | This is the **only jurisdiction with an evidenced in-scope workstation** (§9), and the jurisdiction where the absence of a co-determination gate makes §12 and §13 carry the entire weight. An earlier draft said "no analogue" without naming ICE Regs 2004, which overstated the position | **OPEN-SLCD-26 — ICO monitoring checklist not run; ICE Regs position not checked; §12 and §13 not implemented.** Owner: legal + Andrew Martin (§13) |
| **United States** | **No works-council analogue and no general federal employee-monitoring consent regime.** ECPA/SCA (18 U.S.C. §2510 *et seq.*) constrain interception rather than metadata collection. State notice statutes: **NY Civil Rights Law §52-c**, **Conn. Gen. Stat. §31-48d**, **19 Del. C. §705**. **California:** CCPA/CPRA covers employee personal information since 1 Jan 2023 — Civ. Code §1798.100(a) notice-at-collection, plus the **CCPA ADMT regulations** finalised 2025 (employment automated-decision pre-use notice, opt-out and risk assessments; compliance from 2027) | **Notice statutes, not gates — except at unionised sites**, where introducing monitoring is a **mandatory subject of bargaining** (*Colgate-Palmolive Co.*, 323 NLRB 515 (1997)). That duty survives the rescission of GC 23-02 by GC 25-05 (Feb 2025), because it is Board law rather than a General Counsel memo | Named because a US workstation is plausible (commit `57769231` at `-0600`, §9). An earlier draft treated the US as having **no gate at all**; at a unionised site it does, and unilateral installation would be an unfair labour practice. Notice obligations follow the **employee's** work location, not the employer's | **OPEN-SLCD-27 — NOT ASSESSED BY COUNSEL; union status of any US site not established.** Owner: legal |
| **Portugal, Switzerland — substantive prohibitions, not gates** | **Portugal: Labour Code Art. 20** — remote-surveillance means **may not be used to control employee performance**; Art. 21 CNPD notification. **Switzerland:** outside GDPR. **ArGV 3 Art. 26** — systems for surveilling *behaviour* at the workplace are **prohibited outright**; CO Art. 328b; revFADP Art. 22 (DPIA) | **Prohibition.** Stronger than a consultation gate — there is no body that can authorise it | Promoted out of the catch-all because an earlier draft mis-tiered both as "further hard gates". They are not gates: in Portugal a performance-control purpose is unlawful however it is consulted, and in Switzerland a behaviour-surveillance system is prohibited regardless of agreement. **`metrics.*` is the element that would make this processing fall foul of both** | **OPEN-SLCD-28 — NOT ASSESSED BY COUNSEL.** Owner: legal. If either jurisdiction is in scope, the correct response is very likely to **drop `metrics.*` entirely** rather than to seek an instrument |
| **EU AI Act — deployer obligation, where engaged** | **Regulation (EU) 2024/1689 Art. 26(7)** — before putting a high-risk AI system into service at the workplace, deployers who are employers must **inform workers' representatives and the affected workers**. **Annex III(4)(b)** covers AI systems used to monitor and evaluate performance and behaviour | **Pre-deployment information duty**, independent of GDPR and of every national row above | Engaged **if and only if** any inference, scoring or classification layer is built over the telemetry. The sensor as specified is not obviously an AI system; a dashboard that scores or ranks developers from `metrics.*` very likely is — which is the same boundary `OPEN-SLCD-5` polices | **OPEN-SLCD-29 — NOT ASSESSED.** Owner: legal + product. Determine whether any planned SLCD or dashboard component is an Annex III(4)(b) system |
| **Every other jurisdiction — including but not limited to Greece, Czechia, Romania, Hungary, Bulgaria, Canada, India, Australia, Brazil, Japan, Singapore, UAE** | **NOT ASSESSED** | — | **This row exists so that a jurisdiction absent from the rows above is not read as cleared.** It is the residual, and it is not a statement that the residual is low-risk | **OPEN-SLCD-30 — NOT ASSESSED.** Owner: legal. Resolution requires the §9 roster first: assess every jurisdiction the roster produces, and record an explicit nil return for the rest |

**The scheduling consequence, stated plainly.** In Germany, the Netherlands, Italy, Finland and
Austria the employee-representative instrument sits on the **critical path to deployment** with a
lead time measured in weeks or months, and in three of those the counterparty can refuse outright.
Poland and Denmark add fixed statutory notice periods. **Any SLCD deployment plan that treats the
lawful-basis work as the last compliance step before go-live is wrong for at least seven
jurisdictions**, and the Article 36 prior-consultation clock of up to 14 weeks (pack §11.1) runs on
that same path.

---

## 12. Pre-collection employee notification

**The notification fires before collection starts on a given workstation, not after.** Processing a
data subject does not reasonably expect cannot pass a balancing test, so notice is not only an
Articles 13/14 obligation — it is a precondition of §7's conclusion. An employee who first learns of
the sensor by finding the process is an employee whose reasonable expectations were not what §7.2
assumed.

### 12.1 Mechanism

| Step | Requirement | Owner |
|---|---|---|
| **N-1** | The employing organisation issues a written workstation-monitoring notice to each affected individual, through a channel that produces a **record of issue** — HR system acknowledgement, countersigned policy, or equivalent. Email alone is insufficient where a jurisdiction requires written individual notice (FR, PL) | Controller (employer) |
| **N-2** | The notice is issued **before** the sensor is installed, and no earlier than the point at which its content (§12.2) is final. Where a jurisdiction imposes a statutory minimum period, that period runs from N-1 — **Poland: 2 weeks minimum; Denmark: 6 weeks** | Controller |
| **N-3** | Where §11 requires a collective instrument, N-1 does not begin until that instrument is concluded. Individual notice does not substitute for collective consultation, and consultation does not substitute for individual notice | Controller + legal |
| **N-4** | Enrolment is technically gated on an attestation that N-1..N-3 are complete for the target host's jurisdiction. **This gate does not exist today** and is `OPEN-SLCD-31` — until it exists, N-1..N-3 are enforced by process alone | SLCD engineering |
| **N-5** | On the workstation itself, the sensor's presence is **locally discoverable by the developer** — a documented command that reports that the sensor is running, what it is collecting, and where the notice and objection route are. Poland additionally requires monitored equipment to be marked | SLCD engineering (`OPEN-SLCD-32`) |
| **N-6** | Any material change to the collected field set re-triggers N-1 for every affected individual, and re-opens §11 where the change affects a jurisdiction's instrument | Controller |

### 12.2 What the notice must say

1. That software runs on their workstation which observes coding-agent activity, and from when.
2. **The exact field list, published in full.** It is short enough to publish, and publishing it is
   the single cheapest thing available for moving reasonable expectations — see §2.
3. What is **never** collected — no prompt text, no source code, no file contents, no command lines,
   no environment variables, no credential values — and that this claim is enforced by an allow-list
   in code and asserted by tests, naming where a reader can check it.
4. The purpose, in the specific terms of §3, and the prohibition at §12.4 stated as a commitment.
5. The lawful basis relied on (Article 6(1)(f)), and that the balancing assessment is available to
   them on request. A subject cannot meaningfully object to a balance they have not seen.
6. The retention period and the erasure route.
7. **The objection route and the named individual who receives it** (§13).
8. The identity of the controller, and of the DPO where one is appointed.

### 12.3 What the notice must not do

It must not seek consent, or be phrased so that an employee could reasonably believe they have
agreed to something. Consent is not available here (§1), and a notice that reads as a consent
request both misstates the basis and damages the §7 balance by implying a choice that does not
exist.

### 12.4 Purpose limitation — written as a prohibition

Telemetry collected under this assessment **must not** be used for performance management,
productivity ranking or comparison, capacity planning, attrition prediction, presence or
working-hours monitoring, or as any input to a decision about an individual's employment.

**Nothing in the system technically prevents this today.** It is a policy control requiring an
access-control commitment and a periodic audit from the controller. It is recorded as a prohibition
rather than an intention precisely because §7.1 weighs it as a policy control and not as a
structural one. `OPEN-SLCD-4`.

---

## 13. Objection and complaint route

Where processing rests on Article 6(1)(f), Article 21(1) gives the data subject an **unconditional
right to object** on grounds relating to their particular situation. The controller must then stop
processing unless it demonstrates compelling legitimate grounds which override the subject's
interests, rights and freedoms. A right with no reachable person is not a route.

### 13.1 Named owner

| Role | Named individual | Responsibility |
|---|---|---|
| **Accountable owner — receives and resolves objections and complaints for ControlPlane's own estate** | **Andrew Martin**, AI & Data Security practice lead, ControlPlane — `andy@control-plane.io` | Receives the objection, decides it, and records the decision and its reasoning. Accountable for the outcome whether or not the analysis is delegated |
| Escalation and second view | **Elena Mikhalina**, ControlPlane — `elena.mikhalina@control-plane.io` | Receives an objection the accountable owner cannot decide impartially, including any objection concerning the accountable owner |
| Data Protection Officer | **None appointed** — `OPEN-SLCD-12` | Where appointed, the DPO advises on every objection and the appointment is published in the §12 notice |
| Accountable owner for a **customer** deployment | **The adopting controller names their own, and must** — `OPEN-SLCD-33` | ControlPlane is processor for customer deployments (§1) and cannot decide a customer's employee's objection. A deployment whose notice names no one on the customer side has not discharged §12.2 item 7 |

The ControlPlane designation is taken from the SLCD proposal's RACI, which names Andrew Martin as
Accountable for this mission and Elena Mikhalina as Informed. It is recorded here as an operative
appointment rather than a project role. **If the accountable owner changes, this section is amended
and every notice issued under §12 is reissued** — a notice naming someone who has left is a notice
with no route.

### 13.2 Route

1. The objection is made in writing to the named owner above, by any means. No form is required and
   no reason threshold applies — Article 21(1) requires only grounds relating to the subject's
   particular situation.
2. **Collection on that individual's workstation is suspended on receipt**, before the objection is
   decided, not after. The interim mechanism is un-enrolment of the host (§13.3).
3. The owner responds **without undue delay and in any event within one month** of receipt
   (Art. 12(3)), extendable by two further months where necessary given complexity, provided the
   subject is told of the extension and the reason within the first month.
4. If the objection is upheld, processing of that individual's data stops and their existing records
   are erased through the per-subject erasure route (pack §5.3).
5. If it is refused, the response states the **compelling legitimate grounds** relied on — a refusal
   that merely restates §7 has not discharged Art. 21(1), which requires grounds that override *this
   subject's particular situation*.
6. The subject is told in the same response of their right to complain to a supervisory authority
   (ICO in the UK; the competent authority elsewhere — pack OPEN-24) and to seek a judicial remedy.
7. Every objection, decision and reasoning is logged, and the log is the evidence that §7's balance
   is being operated rather than merely asserted.

### 13.3 The mechanism that exists today

**There is no per-subject exclusion, opt-out or suppression path in the product.** The pack
established this by probe over the sensor and privacy packages, and additionally established that
`Signal Fusion — Architecture and GDPR Reference.md` §7.4's claim that Article 21 is served by "a
host sensor allowlist/denylist filter" is **false** — `filter.py:34-48` enumerates permitted *field
names* and has no per-subject dimension whatever. A reviewer could easily mistake one control for
the other; they are not the same control.

**The only mechanism that exists today is un-enrolment of the host followed by per-subject
erasure, operated manually within the Article 12(3) deadline.** The controller must state that route
in its notice and must be resourced to operate it. `OPEN-SLCD-34` — a per-subject suppression
capability, owned by SLCD engineering and by SLDP-P5-3.

---

## 14. Open items register

Every `OPEN-SLCD-` identifier used anywhere above appears here with an owner. **Blocking** items gate
collection under §0. The counts below are parsed from this table, not written by hand — see the note
at the end of the section.

| ID | Item | Owner | Blocking |
|---|---|---|---|
| OPEN-SLCD-1 | **The in-scope workstation roster does not exist** — jurisdiction, employment status and device ownership per host (§9) | Adopting controller | **YES** |
| OPEN-SLCD-2 | No technical mechanism distinguishes a development host with no employee data subject from an employee workstation (§0) | SLCD engineering | **YES** |
| OPEN-SLCD-3 | Pin down who the "operator" is at enrolment — employer or the developer themselves (inherits pack OPEN-18) | Adopting controller | no |
| OPEN-SLCD-4 | Technical enforcement of the §12.4 purpose-limitation prohibition; access control plus periodic audit | Adopting controller | no |
| OPEN-SLCD-5 | Constrain the dashboard so no aggregate, per-individual, cross-session view of `metrics.*` is built (§3) | Dashboard card owner | no |
| OPEN-SLCD-6 | Determine whether Art. 6(1)(c) is available under DORA Art. 11 / NIS2, naming the specific obligation | Controller + legal | no |
| OPEN-SLCD-7 | **Is continuous sampling necessary, or is periodic sufficient?** (inherits pack OPEN-7, worse under SLCD) | Controller + engineering | **YES** |
| OPEN-SLCD-8 | **Do `metrics.step_count`, `tokens_in`, `tokens_out`, `tool_counts` serve any interest named at §5?** If not they fail Limb 2 | Controller + engineering | **YES** |
| OPEN-SLCD-9 | Is transcript reading necessary if `metrics.*` is dropped? Decide with OPEN-SLCD-8 | Controller + engineering | **YES** |
| OPEN-SLCD-10 | Session-scoped rather than continuous collection — assess | Engineering | no |
| OPEN-SLCD-11 | Establish whether any in-scope host is personally owned (BYOD); exclude or assess separately | Adopting controller | no |
| OPEN-SLCD-12 | **No DPO has advised on this assessment (Art. 35(2))** | Controller / DPO | no |
| OPEN-SLCD-13 | Views of data subjects not sought (Art. 35(9)); tie to §11 consultations | Controller | no |
| OPEN-SLCD-14 | **Austria — Betriebsvereinbarung under ArbVG §96(1)(3); absolute veto, no arbitration route** | Legal + local HR | **YES for AT** |
| OPEN-SLCD-15 | **Germany — Betriebsvereinbarung under BetrVG §87(1)(6), plus §94(2) once telemetry informs appraisal** | Legal + local HR | **YES for DE** |
| OPEN-SLCD-16 | **France — CSE consultation under L2312-8 II 4°, plus L2312-38, L1222-3 and L1222-4 notices** | Legal + local HR | **YES for FR** |
| OPEN-SLCD-17 | **Netherlands — OR consent (WOR Art. 27(1)(k),(l))** | Legal + local HR | **YES for NL** |
| OPEN-SLCD-18 | **Italy — Art. 4 St. Lav. union agreement or INL authorisation + Art. 4(3) notice; Art. 4(2) exemption assessed as unavailable** | Legal + local HR | **YES for IT** |
| OPEN-SLCD-19 | **Spain — LOPDGDD Art. 87(3) criteria set with workers' representatives; ET 64.4(d) algorithmic transparency; ET 64.5 prior report** | Legal + local HR | **YES for ES** |
| OPEN-SLCD-20 | **Poland — Kodeks pracy Art. 22³§1 via 22²§6–§10: regulation, 2-week notice, individual written notice** | Legal + local HR | **YES for PL** |
| OPEN-SLCD-21 | **Belgium — CBA No. 39 prior information to the works council** | Legal | **YES for BE** |
| OPEN-SLCD-22 | **Nordics — SE MBL §11, FI 759/2004 §21 co-operation procedure under 1333/2021, DK DA/FH 6-week notice (membership to be confirmed), NO WEA §9-2** | Legal + local HR | **YES for SE/FI/DK/NO** |
| OPEN-SLCD-23 | **Luxembourg, Croatia, Slovakia — co-decision / consent / consultation gates; ARTICLE NUMBERS UNVERIFIED** | Legal | **YES for LU/HR/SK** |
| OPEN-SLCD-24 | **European Works Council — Directive 2009/38/EC transnational information and consultation; does an EWC exist for the group at all?** | Legal | **YES if an EWC exists** |
| OPEN-SLCD-25 | Ireland — DPC workplace-monitoring guidance not run; existence of an I&C forum not checked | Legal | no |
| OPEN-SLCD-26 | **United Kingdom — ICO monitoring-workers checklist not run; ICE Regs 2004 position not checked; §12 notice and §13 route not implemented** | Legal + Andrew Martin | **YES for UK** |
| OPEN-SLCD-27 | **United States — NY §52-c, CT §31-48d, 19 Del. C. §705, CPRA §1798.100(a) and the 2025 ADMT regulations; and whether any US site is unionised (*Colgate-Palmolive* bargaining duty)** | Legal | **YES for US** |
| OPEN-SLCD-28 | **Portugal and Switzerland — substantive prohibitions, not gates. PT CT Art. 20 bars performance control; CH ArGV 3 Art. 26 bars behaviour surveillance outright** | Legal | **YES for PT/CH** |
| OPEN-SLCD-29 | **EU AI Act Art. 26(7) — inform workers' representatives before putting an Annex III(4)(b) system into service.** Determine whether any SLCD or dashboard component is one | Legal + product | **YES if engaged** |
| OPEN-SLCD-30 | **All remaining jurisdictions unassessed**; resolution requires the §9 roster and an explicit nil return for the rest | Legal | **YES** |
| OPEN-SLCD-31 | Enrolment is not technically gated on a notification attestation (§12 N-4) | SLCD engineering | no |
| OPEN-SLCD-32 | No local discoverability mechanism on the workstation (§12 N-5) | SLCD engineering | no |
| OPEN-SLCD-33 | Customer deployments must name their own objection owner; notice is not discharged without one | Adopting controller | no |
| OPEN-SLCD-34 | **No per-subject suppression or opt-out exists; interim route is manual un-enrolment** (§13.3) | SLCD engineering + SLDP-P5-3 | no |
| OPEN-SLCD-35 | **Incidence evidence for the harm being prevented has never been gathered.** Necessity cannot be evidenced against a threat whose frequency and impact are unquantified — this is very likely the root cause of the Limb 2 result at §6 | Controller + security | **YES** |
| OPEN-SLCD-36 | **Article 22 assessment.** If `metrics.*` ever informs appraisal, performance improvement or termination, the "similarly significant effects" threshold is engaged and consent is unavailable as an Art. 22(2) door. Requires human-in-the-loop design, meaningful-logic disclosure, and an Art. 6(4) compatibility analysis for any secondary use | Controller + DPO | no |
| OPEN-SLCD-37 | **Article 9 leakage and chilling effect.** Session-timing metadata can reveal health, religious observance, caring responsibilities and trade-union or works-council activity. Needs a filter control and, in Germany, a **BetrVG §78** analysis for works-council members whose own activity would be observable | Controller + DPO | no |
| OPEN-SLCD-38 | **Recital 47 reasonable-expectations analysis, evidenced independently.** §7 currently argues expectations partly from the §12 notice this document also specifies; WP29 Opinion 06/2014 warns against exactly that circularity. Evidence must come from somewhere other than our own notice | Controller + DPO | no |
| OPEN-SLCD-39 | **Article 30 record-of-processing entry** for this activity; **Article 39(1)(a)** DPO advice; version, author, approver and review trigger recorded on adoption | Controller | no |
| OPEN-SLCD-40 | **Vendor chain.** Where a hosted coding agent processes any of this data: Art. 28 DPA, Art. 44–49 transfer mechanism, TIA, sub-processor list and CLOUD Act exposure. German and Dutch works councils commonly block on precisely this point | ControlPlane legal + platform | no |

**Count, derived by parsing this table rather than by hand: 40 rows. 7 are unconditionally blocking
(`-1`, `-2`, `-7`, `-8`, `-9`, `-30`, `-35`). 15 are blocking for the jurisdiction or condition they
name (`-14`…`-24`, `-26`…`-29`). 18 are non-blocking. 7 + 15 + 18 = 40, and every row carries an
owner. No item in this table is closed.**

> **Why the arithmetic is shown.** An earlier draft of this section said "8 unconditionally
> blocking" and then listed six identifiers — a self-referential count written by hand and wrong on
> its face. It is corrected here rather than quietly fixed, because a reviewer who spots a count
> that disagrees with its own enumeration is right to distrust the rest of the document. Every
> figure in this section is now produced by parsing the table.

---

## 15. Flip conditions — what expires this assessment

Any of the following invalidates §5–8 and requires a fresh assessment under Article 35(11), in the
same way flip condition F-1 in the DPIA pack expired its predecessor and produced this document.

| ID | Condition | Why it flips the balance |
|---|---|---|
| **F-SLCD-1** | Any field is added to the telemetry envelope beyond those enumerated at §2 | The balance at §7.4 is field-specific; a new field has not been weighed |
| **F-SLCD-2** | The sensor is deployed to a personally-owned device | Destroys the organisation-managed-device assumption underpinning reasonable expectations |
| **F-SLCD-3** | P1-1's field control ships as a deny-list, or as an allow-list that is not structurally enforced | §7.2's first bullet is the strongest factor for the controller and it rests entirely on the allow-list failing closed. F9 shows a deny-list would not catch the real payload keys |
| **F-SLCD-4** | `network.inference_endpoint` or `network.egress_bytes` is delivered by any route | Assessed here as dropped; delivering them requires reaching `/proc/net` or `/proc/<pid>/fd` |
| **F-SLCD-5** | Any aggregate, per-individual, cross-session view of `metrics.*` is built in any surface | The purpose at §3 is breached; the stated interest is no longer the actual interest |
| **F-SLCD-6** | Telemetry is used for any purpose prohibited at §12.4 | Same |
| **F-SLCD-7** | ControlPlane aggregates telemetry across customers, or processes it for a vendor-own purpose | ControlPlane becomes a controller in its own right and needs its own basis, its own LIA and its own notice (inherits pack F-4, OPEN-20) |
| **F-SLCD-8** | **SLER ships** — containment or kill-switch acting on a developer's working environment | Automated action against a person's work strengthens the Art. 35(3)(a) reading and engages Art. 22 (inherits pack F-5) |
| **F-SLCD-9** | The retention controller (SLDP-P6-1) ships | A **favourable** flip — re-run §7.2 to claim it |
| **F-SLCD-10** | A works council, CSE, OR, RSU or union imposes conditions in any jurisdiction | Conditions agreed under §11 bind the processing and may narrow the field set assessed here |

---

## 16. Provenance and limits

**Sources.** `docs/signalloom/dpia-reference-pack.md` (Art. 28(3)(f) pack; §6, §10, §11.1, §13, §14
consumed directly); `docs/signalloom/slcd-p1-pre-inventory.md` (P1-PRE, read from commit `66be5c4e`
in `integration/slcd-v0.1.0`, findings F1, F3, F8, F9, F10 and §6 field map); the SLCD proposal's
Architectural Constitution and RACI; and direct source inspection of
`d2-signalloom/apps/agentmaxxing-host-sensor/filter.py` and `proc.py` at worktree HEAD `ebfa3dce`.

**An adversarial review pass was run against this document before commit, and it found real errors.**
They are recorded here rather than silently corrected, because the pattern of error is itself
information for the next reviewer — every one was a *mis-tiering* or a *wrong instrument*, not an
omitted jurisdiction, which suggests the register's coverage is sound and its characterisation is
the part to distrust.

| Corrected | Was | Is |
|---|---|---|
| Germany | "**Veto.** The works council can block" | Co-determination **substitutable by the *Einigungsstelle*** under §87(2). It delays and forces arbitration; it does not permanently block. Affects the timeline, not the requirement. §94(2) added |
| Belgium | CBA No. **81** cited as the instrument | **Wrong instrument.** CBA 81 governs electronic online communications data, which this is not. **CBA No. 39** is the gate |
| Spain | "LOPDGDD Arts. **87–90**" | **Art. 87 only** — 88, 89 and 90 do not apply, and the range concealed the actual participation gate at 87(3). **ET 64.4(d)** algorithmic transparency added, and is squarely on point |
| France | L2312-38 cited as the consultation gate | L2312-38 is an **information** duty. **L2312-8 II 4°** is the consultation. L1222-3 and L1121-1 added |
| Poland | "monitored equipment must be marked" | **Transplanted from video monitoring** (Art. 22²§9, premises). Art. 22³ incorporates 22²§6–§10; the marking duty is not among the telemetry obligations |
| Austria | Buried in the catch-all row | **Promoted to the first row.** ArbVG §96(1)(3) is *not* substitutable by the arbitration board, making it the only **absolute** veto in the table |
| Portugal, Switzerland | Named in the catch-all as "further hard gates" | **Mis-tiered.** Both are substantive **prohibitions**, which no consultation can cure |
| Ireland, UK | "no analogue" | Overstated. UK **ICE Regs 2004** and the Irish 2006 Act both create information-and-consultation duties on request |
| United States | Notice statutes only, no gate | At a **unionised** site, installing monitoring is a mandatory subject of bargaining (*Colgate-Palmolive*, 323 NLRB 515 (1997)) — a real gate |
| Missing entirely | — | **European Works Council** (Dir. 2009/38/EC), **Luxembourg**, **Croatia**, **Slovakia**, and the **EU AI Act Art. 26(7)** deployer duty |
| §8 | Reported a failed Limb 2 and continued without saying what that means | The limbs are **conjunctive**; a failed Limb 2 means there is no lawful basis, and §0 is the operative conclusion |
| §14 | "8 unconditionally blocking" followed by six identifiers | Counts are now parsed from the table |

**Five limits a reader must know.**

1. **This is engineering evidence, not legal advice.** The statutory instruments at §11 are named
   from the pack's existing research (DE, FR, NL, UK) and extended by this card (AT, IT, ES, PL, BE,
   Nordics, LU, HR, SK, EWC, IE, US, PT, CH, AI Act). **None has been reviewed by qualified counsel
   in its jurisdiction** — that is `OPEN-SLCD-14` through `-30`, and it is why every one of those
   rows is OPEN rather than merely "noted". The Luxembourg, Croatia and Slovakia article numbers are
   flagged **unverified** in the row itself; they are recorded so the jurisdictions are not omitted,
   which is a different claim from asserting the citation is right.
2. **The in-scope roster does not exist**, so §11 is a capability register and not an exposure
   register (§9). Nothing in it should be read as an assertion that ControlPlane employs anyone in
   any particular country.
3. **No live capture was taken.** The zero-payload boundary is evidenced by a closed schema, an
   enumerated allow-list in code, and the tests that assert it — not by observing a running sensor's
   wire traffic. A DPO wanting runtime assurance should ask for a packet capture.
4. **The SLCD components this assessment covers do not exist yet.** `detective.py`,
   `telemetry_handler.go` and `CodingAgentsTab.tsx` were all ABSENT at P1-PRE. This assessment is
   therefore made against the *proposed* envelope and the *observed* field sources, and it must be
   re-verified against the shipped implementation before adoption — which is what F-SLCD-1 and
   F-SLCD-3 exist to force.
5. **This card did not read any field value from any transcript.** Field names and record counts
   only, consistent with P1-PRE's method note and the Zero-Customer-Payload invariant.

**This assessment was authored by SLCD-P1-5 on 2026-09-15 against worktree HEAD `ebfa3dce`. It is
unadopted, unsigned, and does not authorise collection. See §0.**
