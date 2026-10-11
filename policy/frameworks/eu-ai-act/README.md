# eu-ai-act — citation anchoring and known limits

This pack claims compliance with **Regulation (EU) 2024/1689** (the AI Act).
Every article, paragraph and annex it cites was checked against the
authenticated Official Journal text before this file was written.

**Source used.** `http://publications.europa.eu/resource/celex/32024R1689` with
`Accept: application/xhtml+xml` — the Publications Office CELLAR rendering of
CELEX `32024R1689`, i.e. the OJ text itself (OJ L, 2024/1689, 12.7.2024). The
EUR-Lex HTML endpoints (`/legal-content/EN/TXT/HTML/?uri=OJ:L_202401689`,
`/eli/reg/2024/1689/oj/eng`) answer `202` with an empty body to a non-browser
client and cannot be used as a verification channel; CELLAR serves the same
document and can. Articles 9, 10, 11, 12, 13, 14, 15, 17, 26 and 50 and
Annex IV were read in full from that document.

**Result in one line.** No citation in this pack is fabricated: every article,
paragraph and annex it names exists and concerns the subject claimed. Four
paragraph-level citations in v2.1 were **wrong** and are corrected below. Three
article-level attributions in v1.0/v2.0 are **mis-attributed** and are now
labelled as such in the pack rather than renumbered. Most checks are
**declarations or proxies**, not evidence; which is which is stated per check.

## Citation table

Verdicts: **correct** — the cited paragraph exists and states the obligation the
check tests. **mis-cited** — the article is right, the paragraph is wrong.
**mis-attributed** — the obligation the check tests is not in the cited article
at all. **fabricated** — the citation does not exist. There are no fabrications.

### v2.1 (strict tier)

| Control (claimed) | Check | Claimed citation | Verified citation | Verdict |
|---|---|---|---|---|
| `ART-9.2` "Risk Identification and Analysis" | `container-run-as-non-root`, `no-privilege-escalation` | Art. 9(2) | Art. 9(2)(d) — "the adoption of appropriate and targeted risk management measures" | **mis-cited** (paragraph right, point wrong: 9(2)(a) is *identification and analysis*; these checks are *measures*). Corrected to `ART-9(2)(d)`. |
| `ART-10.2` "Training, Validation and Testing Data Quality" | `training-data-provenance` | Art. 10(2) | Art. 10(2)(b) — "data collection processes and the origin of data" | **correct**, sharpened to the point that carries provenance. |
| `ART-11.1` "Annex IV Technical Documentation" | `annex-iv-technical-documentation` | Art. 11(1), Annex IV | Art. 11(1): documentation "shall contain, at a minimum, the elements set out in Annex IV"; Annex IV is titled "Technical documentation referred to in Article 11(1)" | **correct**. |
| `ART-12.1` "Automatic Event Logging" | `automatic-record-keeping` | Art. 12(1) | Art. 12(1) — "shall technically allow for the automatic recording of events (logs) over the lifetime of the system" | **correct**. |
| `ART-13.1` "Clear User Instructions and Transparency" | `user-instructions-transparency` | Art. 13(1) | Art. 13(2) — "shall be accompanied by instructions for use …"; contents listed in 13(3) | **mis-cited.** 13(1) is the *design*-transparency obligation and says nothing about instructions. Corrected to `ART-13.2`. |
| `ART-14.4` "Human-in-the-Loop Authorization" | `block-unauthorized-host-exec` | Art. 14(4) | Art. 14(4)(a)–(e) enables an oversight person to understand, monitor, interpret, **disregard/override/reverse** and **interrupt**. No paragraph of Art. 14 requires ex-ante authorisation of an action, except 14(5), which is scoped to Annex III point 1(a) (remote biometric identification) and requires separate verification by **two** natural persons. | **mis-attributed obligation.** Article and paragraph exist; the *pre-authorisation* obligation the check enforces is not in them. Kept at `ART-14.4`, renamed "Human Oversight Enablement", and the proxy is stated in the control description. A pass must not be represented as Art. 14(5) compliance. |
| `ART-15.4` "Cybersecurity Measures" | `drop-all-capabilities` | Art. 15(4) | Art. 15(5) — "resilient against attempts by unauthorised third parties to alter their use, outputs or performance by exploiting system vulnerabilities" | **mis-cited.** Cybersecurity is 15(5). Moved to a new control `ART-15.5`. |
| `ART-15.4` "Cybersecurity Measures" | `resource-limits-set` | Art. 15(4) | Art. 15(4) — "as resilient as possible regarding errors, faults or inconsistencies … technical redundancy solutions, which may include backup or fail-safe plans" | **correct article and paragraph, wrong label.** 15(4) is robustness, not cybersecurity. The single control bundling both checks under one cybersecurity label was split into `ART-15.4` (robustness) and `ART-15.5` (cybersecurity). |
| `ART-26.1` "Operational Oversight and Monitoring" | `deployer-monitoring-active` | Art. 26(1) | Art. 26(5) — "Deployers shall monitor the operation of the high-risk AI system on the basis of the instructions for use" | **mis-cited.** 26(1) is about *using the system in accordance with the instructions for use*; assignment of oversight is 26(2). Corrected to `ART-26.5`. |
| `ART-50.1` "Synthetic Content Marking and AI Disclosure" | `synthetic-content-marking` | Art. 50(1) | Art. 50(2) — outputs "marked in a machine-readable format and detectable as artificially generated or manipulated" | **mis-cited**, and the name conflated two obligations: marking is 50(2), *informing a person they are interacting with an AI system* is 50(1) and is **not checked by this pack at all**. Corrected to `ART-50.2`. |

**Scope caveat on ART-50.** Articles 9–15 and 26 are Chapter III high-risk
obligations. Article 50 is in **Chapter IV** and binds providers and deployers of
*certain* AI systems regardless of high-risk classification. The v2.1 framework
is named "EU AI Act: High-Risk AI System Requirements", so an ART-50 control set
inside it is in scope by subject, not by the high-risk trigger. Stated in the
framework description so a reader does not infer that a failing
`synthetic-content-marking` is a high-risk finding.

### v1.0 and v2.0 (lax and standard tiers)

These tiers cite at **article granularity only** — no paragraph is claimed, so
there is nothing to renumber. The control-set names and descriptions now name
the paragraph actually engaged.

| Control set (claimed) | Checks | Verified citation | Verdict |
|---|---|---|---|
| "Art. 9 — Risk Management System" | `container-run-as-non-root`, `no-privilege-escalation`, `no-privileged-mode`, `read-only-rootfs`, `drop-all-capabilities`, `liveness-probe-present` | Art. 9(2)(d) is the only hook — adoption of "appropriate and targeted risk management measures". Art. 9 names no technical control. | **weak proxy.** Container hardening is more directly Art. 15(5); a liveness probe is more directly Art. 15(4). Relabelled "Art. 9(2)(d) — Risk Management Measures". |
| "Art. 10 — Data Governance" | `data-classification-label` | Art. 10(2)(a)/(e) — design choices, assessment of data suitability | **weak proxy** for a data-set governance practice. |
| "Art. 10 — Data Governance" | `pii-handling-annotation` | Art. 10 regulates training/validation/testing **data sets**. Its only personal-data provision is 10(5), permitting special-category processing *strictly for bias detection and correction*. | **mis-attributed.** Runtime PII handling is a GDPR obligation, not an Art. 10 one. |
| "Art. 10 — Data Governance" | `data-retention-annotation` | Art. 10 imposes **no retention period**; 10(5)(e) requires deletion of special-category bias data only. Log retention of ≥6 months is **Art. 26(6)**; QMS data retention is **Art. 17(1)(f)**. | **mis-attributed.** |
| "Art. 14 — Human Oversight" | `hitl-label`, `approval-gate-annotation`, `override-contact-annotation` | Art. 14(4)(d)–(e) and 14(3)(b) | **correct article**, checks are declarations. |
| "Art. 15 — Accuracy, Robustness & Cybersecurity" | `resource-limits-set`, `resource-requests-set`, `readiness-probe-present`, `min-replicas` | Art. 15(4) — resilience, redundancy, fail-safe | **correct**, narrowed to 15(4). No check in this set evidences 15(5) cybersecurity despite the set's name. Relabelled "Art. 15(4) — Robustness and Resilience". |
| "Art. 17 — Quality Management System" | `image-digest-required`, `trusted-registry`, `policy-version-label` | Art. 17(1)(a) "procedures for the management of modifications"; 17(1)(e) "technical specifications … to be applied" | **proxy.** Art. 17 is a *documented QMS* obligation; a pod spec cannot evidence that a QMS exists. Supply-chain integrity is also engaged by Art. 15(5) ("pre-trained components used in training (model poisoning)"). |

## Evidence or proxy, per check

An **evidence** check reads a fact about the workload that the obligation is
about. A **proxy** check reads something adjacent. A **declaration** check reads
a boolean or an annotation in which the operator asserts compliance; it proves
that the assertion was made, nothing more.

| Check | Obligation | Kind |
|---|---|---|
| `container-run-as-non-root`, `no-privilege-escalation`, `no-privileged-mode`, `read-only-rootfs`, `drop-all-capabilities` | Art. 15(5) resilience against third parties (via 9(2)(d)) | **evidence** of the stated hardening measure, and **admissibility-equivalent** to Pod Security Admission restricted for the five fields the external oracle covers; **proxy** for the paragraph, which names poisoning/evasion/confidentiality attacks a pod spec cannot speak to |
| `resource-limits-set`, `resource-requests-set` | Art. 15(4) resilience to faults | **evidence** (an unbounded container is the fault mode) |
| `liveness-probe-present`, `readiness-probe-present` | Art. 15(4) fail-safe | **proxy** — tests that the field is *present*, not that the probe is meaningful. `livenessProbe: {}` passes (the API server rejects it, so it is not a reachable state). |
| `min-replicas` | Art. 15(4) redundancy | **not evaluable** — `status: placeholder`; `replicas` is a controller-level fact, absent from a pod |
| `image-digest-required`, `trusted-registry` | Art. 17(1)(a)/(e), Art. 15(5) | **evidence** of immutability and registry provenance; **proxy** for the QMS obligation |
| `policy-version-label`, `data-classification-label`, `hitl-label`, `pii-handling-annotation`, `data-retention-annotation`, `approval-gate-annotation`, `override-contact-annotation` | assorted | **declaration** — a non-empty label or annotation. A pass means the operator wrote a value, not that the practice exists |
| `training-data-provenance`, `annex-iv-technical-documentation`, `automatic-record-keeping`, `user-instructions-transparency`, `deployer-monitoring-active` | Art. 10(2)(b), 11(1), 12(1), 13(2), 26(5) | **declaration** — one operator-supplied boolean in the agent context. These are the five paths this repo invented; they are not regulatory artefacts. See `v2.1/AGENT-CONTEXT.md` |
| `synthetic-content-marking` | Art. 50(2) | **declaration**, and conditional: it passes when `agent.model_type` is absent, so an undeclared model type is never gated |
| `block-unauthorized-host-exec` | no exact paragraph; see table above | **proxy** for Art. 14(4) oversight enablement |

## Ephemeral containers: an exclusion, not a gap

Four checks read `containers` (+ `initContainers`) but **not**
`ephemeralContainers`: `resource-limits-set`, `resource-requests-set`,
`liveness-probe-present`, `readiness-probe-present`. This is required, not
missing. The Kubernetes `EphemeralContainer` schema **forbids** `resources`,
`livenessProbe`, `readinessProbe`, `lifecycle` and `ports` — "Resources are not
allowed for ephemeral containers. Ephemeral containers use spare resources
already allocated to the pod"
([Pod v1 API reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)).
A check demanding them would fail every pod carrying a debug container. The five
checks whose obligation *is* per-container and schema-legal on an ephemeral
container (`container-run-as-non-root`, `no-privilege-escalation`,
`no-privileged-mode`, `read-only-rootfs`, `drop-all-capabilities`,
`image-digest-required`, `trusted-registry`) all read all three lists, in all
three versions. Both halves are pinned by fixtures
(`*--ephemeral-container-violates`, `*--ephemeral-container-carries-no-resources`,
`probes-present--ephemeral-container-carries-no-probes`).

## Version tiers are not a chain

`../README.md` describes v1.0 → v2.0 → v2.1 as lax → standard → strict, and
v2.1 as "workload checks plus agent and request governance". That is true of the
`agent` and `request` dimension and **false of the workload dimension**:

| | v1.0 | v2.0 | v2.1 |
|---|---|---|---|
| checks | 7 | 19 (1 placeholder) | 11 |
| workload (`object`) checks | 7 | 19 | 5 |
| `agent`/`request` checks | 0 | 0 | 6 |

v2.0 **is** a strict superset of v1.0: all 7 of v1.0's checks are present, plus
12 more. v2.1 **is not** a superset of v2.0 — it drops 14 workload checks that
v2.0 enforces: `no-privileged-mode`, `read-only-rootfs`, `liveness-probe-present`,
`readiness-probe-present`, `resource-requests-set`, `min-replicas`,
`image-digest-required`, `trusted-registry`, `policy-version-label`,
`data-classification-label`, `pii-handling-annotation`,
`data-retention-annotation`, `hitl-label`, `approval-gate-annotation`,
`override-contact-annotation`.

**Finding, open.** A workload that fails `no-privileged-mode` and
`trusted-registry` under the "standard" tier passes the "strict" tier, because
the strict tier does not look. Either v2.1 should absorb v2.0's workload checks,
or the tier table should stop describing v2.1 as stricter. This is a pack-content
decision, not a defect to patch silently, so it is recorded and left to the
principal.

## Pricing: v1.0 and v2.0 are UNPRICED

Every check in **v1.0 (7 of 7)** and **v2.0 (19 of 19)** carries a `riskTriple`
and a frequency triple of `{min: 0, mode: 0, max: 0}`. `fair.Simulate`
short-circuits an all-zero frequency to a zero result, so **every failing check
in these two versions prices at £0.00** and a scan of them reports zero total
exposure however many controls fail. v2.1 carries real frequency triples and
prices correctly.

The zero was previously **implicit**: the two versions omitted `freqTriple`
entirely and Go's zero value supplied `{0,0,0}` silently. It is now declared in
three places, and the third one is enforced:

1. **In the pack data.** Every check in v1.0 and v2.0 writes
   `"freqTriple": {"min": 0, "mode": 0, "max": 0}`, so a reader sees a
   declaration instead of an absence. An `unpriced` schema key is not an
   option: the loader runs `DisallowUnknownFields`, so a new key breaks pack
   loading.
2. **In words**, in each version's `framework.description`: "Do not quote a
   figure from this version."
3. **In `catalogue/unpriced.tsv`**, checked by `catalogue/pricing-test.sh`
   (`cd policy/frameworks/eu-ai-act/catalogue && ./pricing-test.sh`). That is
   the same test `nist-800-53/catalogue/pricing-test.sh` runs, kept byte-wise
   identical apart from its header so the two packs cannot drift into two
   patterns; it derives the pack from its own location, so the only
   pack-specific state is the `.tsv` beside it. It fails three ways: a check
   that is **neither priced nor declared** (the silence this exists to stop), a
   **declaration whose check has since been calibrated** (so the list cannot
   rot into a blanket exemption), and a **declaration naming a check that does
   not exist**. All three proved by mutation. Current state:
   `PASS -- 37 check(s): 11 priced, 26 declared unpriced`.

The engine's behaviour is unchanged (the money goldens are byte-identical,
`make verify-cel-money` green), which is the point: the data now says what the
engine already did.

No frequency triples were invented. Loss-event-frequency calibration is the
principal's call, not a worker's, and a fabricated frequency is worse than a
declared zero because it would look like evidence. The remedy for a long
`unpriced.tsv` is calibration, not fabrication.

`min-replicas` (v2.0) is declared with a different reason code,
`placeholder-not-evaluated`: it is `status: placeholder`, never evaluated, and
excluded from exposure by the engine, so its zero is correct rather than
missing. It is still declared, so the test needs no special case and a future
decision to evaluate it must also price it.

`TestConformance_MoneyPacksWithoutFreqTriplePriceAtZero`
(`d2-signalloom/apps/policy-engine/compliance_money_test.go`) pins the exact set
of packs that price every check at zero and separates "zero because the single
check is a placeholder" (`dora/v1.0`, `nis2/v1.0`, where zero is correct) from
"zero because real evaluated checks have no frequency" (`eu-ai-act/v1.0`,
`eu-ai-act/v2.0`, `nist-800-53/v1.0`, `nist-800-53/v2.0` — the finding). A pack
leaving that set must have its golden regenerated and its new figures proved, and
a pack joining it has lost its frequency data. That is the enforcement the
declaration needs: the data declares, the test makes the declaration impossible
to change quietly.

## Admissibility: what the external PSA oracle settled

`d2-signalloom/apps/policy-engine/oracle` runs this pack's object-reading checks
against upstream `k8s.io/pod-security-admission` on a shared fixture corpus. PSA
is authoritative on **admissibility**: the dangerous error is calling a pod
compliant that a cluster will reject. It found three classes here, all now
closed, and the eleven exception entries that recorded them are stale:

| Class | Check | What was wrong |
|---|---|---|
| **D (high)** | `drop-all-capabilities` (v2.0, v2.1) | A container that dropped ALL and re-added `SYS_ADMIN` (mount, ptrace, kernel-module loading — a container-escape primitive) was reported **compliant**. PSS restricted is a conjunction over drop **and** add; only the drop half was checked. Fixed with an add allow-list of `{NET_BIND_SERVICE}`. |
| **C (high)** | `container-run-as-non-root` (all three) | `runAsUser: 0` alongside `runAsNonRoot: true` **passed**, at pod and container level. PSS forbids `runAsUser: 0` outright. Fixed. |
| **B (low, opposite direction)** | `no-privilege-escalation` (all three) | A conformant Windows workload was permanently non-compliant and could not be made compliant: `allowPrivilegeEscalation` is Linux-only and PSA exempts `spec.os.name == 'windows'`. Fixed, and the same exemption added to `drop-all-capabilities`. |

One consequence worth recording, because it reversed a decision made earlier in
the same branch. A pod that sets `runAsNonRoot: false` at pod level while every
container overrides it to `true` **would run non-root**, but PSA restricted
rejects it on the pod-level value. On the admissibility frame the pack must
therefore **fail** it, and an earlier fixture asserting `pass` was wrong. See
`container-run-as-non-root--pod-false-container-true-still-fails`, and
`--pod-absent-container-true` for the boundary: an *absent* pod securityContext
is not an explicit false.

The surviving eu-ai-act divergences are all `*--no-containers` fixtures in the
`pack=fail, oracle=allow` direction. Those are deliberate: this pack's checks
begin `size(object.spec.containers) > 0`, so a pod asserting zero containers
fails closed where PSA admits it. Recorded as the oracle's class A.

## Two checks report `pass` when they cannot assess

`block-unauthorized-host-exec` and `synthetic-content-marking` (both v2.1) end
`… : true`. When the precondition is absent — no `request.tool_call.action`, or
no `agent.model_type` — they return `pass`. Measured through the engine: a
maximally hostile privileged pod submitted with empty `agent` and `request`
passes both and is counted into posture as compliant with zero exposure. These
are the only 2 of 127 checks in the estate with that shape; the `finos-aigf`
pack fails closed on 16 of 16, so the estate is internally inconsistent.

A guard that cannot be evaluated is not a pass. Three ways out, in preference
order:

1. **`not_evaluated`.** The verdict vocabulary already has it, the conformance
   suite enforces it bidirectionally, and the money tier already excludes it
   from exposure. The obstacle is that `not_evaluated` is today reached only via
   `status: placeholder`, which is a *static* property of a check, and this needs
   to be decided per input. That is an engine change.
2. **A new `not_applicable` verdict.** Semantically the most honest — Article
   50(2) genuinely does not bind a non-generative model, and a tool call that is
   not `exec`/`write_file`/`modify_iam` is genuinely outside the gate. Also an
   engine change, and it widens the verdict vocabulary that four test suites
   pin.
3. **Fail closed**, i.e. require the precondition to be *declared*: an absent
   `agent.model_type` becomes a fail, and so does a `request` with no
   `tool_call`. Pack-local, no Go change — but it would fail every object-only
   scan of v2.1, which is a real workflow, so it is not a free change either.

Not implemented. Option 1 or 2 touches Go that this pack does not own, and
option 3 changes what a scan means. Recorded for the principal. Until then, a
`pass` on either of these two checks must not be read as evidence; the
AGENT-CONTEXT table marks both as passing when their trigger is absent.

## Checks that error

Per `../CONFORMANCE.md`, `error` on an ordinary valid input is a defect. The
pack was probed with 16 synthetic inputs per version (48 runs) covering an absent
`spec`, an empty `containers` list, absent `metadata`, agent sub-objects replaced
by scalars, `request.context.claims` as a map / scalar / empty list / list of
empty objects, a non-string `tool_call.action`, empty and partial `resources`
maps, and empty probe objects. **No check errors on any schema-valid input.**
The battery was re-run unchanged after the PSA-oracle fixes added `runAsUser`,
`capabilities.add` and `spec.os` reads, with the same result: no new error
class, so the probes are left out of the permanent fixture set and only the
three cases below are pinned as fixtures.

Three inputs do produce `error`, all of them schema violations:

| Input | Checks | Status |
|---|---|---|
| `securityContext.capabilities.drop` as a string instead of an array | `drop-all-capabilities` (v2.0, v2.1) | Pod schema violation; the API server rejects it. Left as-is. |
| `metadata.annotations` as a string instead of a map | the four `osramp.io/*` annotation checks (v2.0) | Pod schema violation. Note the asymmetry: the `has(object.metadata.labels.x)` idiom used by the label checks *fails* on the same garbage, while the `'k' in object.metadata.annotations` idiom *errors*. Left as-is; recorded. |
| `request.context.claims` as a scalar instead of a list | `block-unauthorized-host-exec` (v2.1) | `request` is assembled by this repo, not by Kubernetes, so this boundary is ours. Pinned by `block-unauthorized-host-exec--claims-is-a-scalar` as a deliberate `error` expectation, so adding a type guard later is a proven change rather than drift. A `claims` **map** fails closed, which is pinned too. |

## Pricing coverage

The table below is produced from `framework.json`. It is not typed by hand.
`make policy-pricing-counts` fails if it drifts from the packs.

A check is priced when its `freqTriple` has a non-zero `min`, `mode`, or `max`.
A check with no frequency triple, or an all-zero one, is unpriced. An unpriced
check contributes GBP 0.00 to every reported total however often it fails. That
state is allowed, because a loss magnitude with no calibrated frequency is not a
price. It is not a small-print detail, because a reader who adds up a scan gets
a total over the priced checks only.

### What these figures are a share of

A `riskTriple` mode here is the **attributable share of one loss event assigned
to one failed control**. It is not the cost of the loss event. Published
single-event loss medians sit one to two orders of magnitude above these modes
(IRIS 2022, <https://www.cyentia.com/iris-2022/>). The event-level figures are
the `SCN-*` magnitudes in [`risk/org/acme.yaml`](../../../risk/org/acme.yaml).

Every priced check carries a derivation entry in `v2.1/CALIBRATION.md`. It
names the anchor classes behind both triples, the scenario the check is a share
of, and a confidence letter. The registry is [ANCHORS.md](../ANCHORS.md).

### Five v2.1 checks are off the technical loss path

`training-data-provenance`, `annex-iv-technical-documentation`,
`automatic-record-keeping`, `user-instructions-transparency` and
`synthetic-content-marking` defend against a **penalty**, not a breach. A
documentation gap does not cause a technical loss event. Their technical
frequency was zeroed on 2026-10-11 and each is declared in
`catalogue/unpriced.tsv` with the reason code `penalty-path-not-technical`.

Their statutory ceilings are facts and are tabulated in
[PENALTIES.md](../PENALTIES.md#eu-ai-act). Art. 99(4) is the applicable row for
a deployer, at €15,000,000 or 3 per cent. A ceiling is a `max` and never a
`mode`. Pricing them needs the secondary-loss model in section 4 of
[the open decisions](../../../docs/fair-methodology-open-decisions.md).

Read [the calibration statement](../README.md#the-calibration-statement) before you quote
any figure in this table or any figure the engine produces from this pack.

<!-- pricing-counts:begin -->
| Version | Checks | Priced | Unpriced | Placeholder |
| :--- | ---: | ---: | ---: | ---: |
| `v1.0.0` | 7 | 0 | 7 | 0 |
| `v2.0.0` | 19 | 0 | 19 | 1 |
| `v2.1.0` | 11 | 11 | 0 | 0 |
| **Pack total** | **37** | **11** | **26** | **1** |

An unpriced check contributes GBP 0.00 to every total however often it
fails. Of 37 check(s) on this page, 11 are priced and 26 are not.
Written by `policy/frameworks/pricing-counts-test.sh`. Do not edit by hand.
<!-- pricing-counts:end -->
