---
created: 2026-08-03
reviewers:
  - "#stefan-prodan"
  - "#tom-cope"
capabilities:
  - "#cap-gitops"
  - "#cap-flux-taa"
  - "#cap-kubernetes"
  - "#cap-networking"
  - "#cap-incident-response"
  - "#cap-policy-as-code"
  - "#cap-threat-modelling"
  - "#cap-architecture"
practice:
  - GitOps & Continuous Delivery
  - Cloud Native Transformation & DevSecOps
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-07-signalloom-d2-platform-baseline/"
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q3-signal-loom-stun-under-flux
aliases:
  - "#proposal-2026-q3-signal-loom-stun-under-flux"
---
# Proposal — Signal Loom Stun under Flux Operator (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-08-03) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

ControlPlane today announced that Signal Loom's agent containment now survives GitOps reconciliation. When a Signal Loom operator stuns a misbehaving AI agent, the containment holds — and, critically, the *evidence* that it holds is not silently erased by the platform's own reconciler minutes later.

This is a problem the industry has not named. Every regulated organisation adopting agentic AI is also adopting GitOps, and the two have a defect at their intersection: a reconciler exists to drive live state back to what Git says, and an incident response exists to change live state *away* from what Git says. Where they meet, the reconciler wins — quietly, on its own schedule, with no error raised and no status degraded.

ControlPlane found this in its own platform by measuring rather than assuming, and is publishing both the failure and the remedy. Signal Loom now composes containment across the layers that a reconciler cannot reach and those it can, declares which is which, and proves the distinction with tests. The result is a containment control an auditor can believe: one whose enforcement and whose evidence have the same lifetime.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):**

Signal Loom (partner and design point). Downstream: the regulated-financial-services buyers the Agent Security Platform targets, for whom "we contained the agent" must be a demonstrable, auditable claim rather than an assertion.

|  |  |
| :---- | :---- |
| Our *…* | Signal Loom, and any regulated organisation running agentic workloads under GitOps |
| Have the problem/opportunity *…* | An agent containment action is silently reverted by the GitOps reconciler, so the enforcement and the evidence of enforcement have different lifetimes — the platform reports a contained agent as healthy |
| When *…* | On every reconcile of the owning Kustomization, i.e. within 30 minutes by schedule and immediately on any triggered reconcile |

**What's the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

2026-Q3, ahead of any customer-facing demonstration of the Agentic Killswitch capability. This is a subcomponent of area 4 (*Agentic Killswitch & Quarantine*) of the Signal Loom Agent Security Platform proposal. The parent's own adversarial critique already names the killswitch as "the headline differentiator ... the weakest technical claim"; this work is the specific remediation of that finding for the in-estate Kubernetes plane.

The urgency is not theoretical. The defect is live in the current demo path: a reconcile landing after the stun flips the agent back to healthy in front of an audience while the presenter explains it has been contained.

## Scope Summary

**TRL 2 (Alpha).** The individual enforcement primitives are measured and working on a live cluster; what does not yet exist is a composed, tested, documented control with an un-stun path and an audit trail. This proposal takes measured primitives to an alpha-quality control, not to production.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Reconciler-safe stun fields | Runtime-owned fields (`signalloom.ai/state` and the two stun annotations) are excluded from GitOps drift correction, via `Kustomization.spec.ignore` JSON Pointers and a stun-applied `reconcile: disabled` escalation. | Specific: the three paths survive a forced reconcile.<br/>Measurable: label and both annotations unchanged after `flux reconcile`; controller logs `skipped` not `configured`.<br/>Attainable: both mechanisms already verified working on `kind-osramp`.<br/>Realistic: no new components required.<br/>Time-Bound: M1. | Automated: forced-reconcile assertion in the e2e harness. |
| Static guard against regression | CI check that no runtime-owned field is re-declared in Flux-managed desired state, distinguishing a declaration from a policy selector. | Specific: check fails on a declaration, passes on a `matchLabels` selector.<br/>Measurable: 10+ unit tests, including the selector and mixed-file cases.<br/>Attainable: implemented and green.<br/>Realistic: pure static analysis, no cluster.<br/>Time-Bound: M1. | `make check-flux-dynamic-labels-test`. |
| Label-driven network quarantine | Committed NetworkPolicy selecting `signalloom.ai/state=stunned`, denying ingress and egress, plus the mandatory `NotIn: [stunned]` guard convention on every other allow policy. | Specific: labelling a running pod blocks it; unlabelling restores it.<br/>Measurable: reachable→blocked→reachable, no pod restart.<br/>Attainable: verified on kindnet; NetworkPolicy enforcement confirmed.<br/>Realistic: ~40 lines of committed YAML.<br/>Time-Bound: M2. | Automated network probe, both directions. |
| Guard-convention enforcement | Static check that every allow policy able to select an agent carries the `NotIn: [stunned]` guard. | Specific: an unguarded allow policy fails CI.<br/>Measurable: check proven to go red on a crafted policy.<br/>Attainable: same analysis approach as the field guard.<br/>Realistic: extends existing tooling.<br/>Time-Bound: M2. | Unit tests with a deliberately unguarded fixture. |
| Established-connection severing | Conntrack invalidation for the quarantined pod, closing the residual that policy alone leaves open. | Specific: an established TCP stream stops after stun.<br/>Measurable: stream dies within 5s; without the step it survives past 60s.<br/>Attainable: `conntrack -D` against the pod IP.<br/>Realistic: no CNI change.<br/>Time-Bound: M3. | Long-lived-stream probe, measured before and after. |
| Freeze-first containment | cgroup-v2 freeze as the first action of the stun, halting execution before any control the agent could observe and react to. | Specific: agent process is frozen before revocation begins.<br/>Measurable: freeze precedes revocation in the audit record; process state is `frozen`.<br/>Attainable: cgroup-v2 freezer on the node.<br/>Realistic: RBAC and runtime feasibility confirmed at M3.<br/>Time-Bound: M4. | Process-state assertion plus ordered audit record. |
| Un-stun path | Documented, tested reversal: rotate credentials rather than restore, unfreeze last, and mandatory removal of the `reconcile: disabled` annotation. | Specific: after un-stun the object is fully managed again.<br/>Measurable: controller log transitions `skipped`→`unchanged`; new credential serial differs from the revoked one.<br/>Attainable: reverse-order runbook.<br/>Realistic: scripted, not manual.<br/>Time-Bound: M4. | Automated stun→un-stun→stun cycle. |
| Containment audit trail | A first-class stun/un-stun event emitted to Kubernetes Events and to an immutable store, plus an alert on the `configured` drift-correction signature. | Specific: every stun produces an event that survives label reversion.<br/>Measurable: event present after a forced reconcile that reverts the label.<br/>Attainable: Events API plus existing audit path.<br/>Realistic: no new datastore.<br/>Time-Bound: M5. | Revert-then-query test. |
| Cross-engine portability note | Documented Argo CD equivalents (`ignoreDifferences.jsonPointers`, `managedFieldsManagers`, self-heal) so the pattern is not Flux-only. | Specific: each Flux mechanism has a named Argo counterpart or an explicit gap.<br/>Measurable: table covers all mechanisms used.<br/>Attainable: research complete.<br/>Realistic: documentation deliverable.<br/>Time-Bound: M5. | Peer review by a Flux/Argo principal. |

### Out of Scope

* Replacing the CNI. Cilium/eBPF is not adopted here — `kind` accepts `disableDefaultCNI` only at cluster creation, and the measured benefit does not justify rebuilding a working cluster. Revisit if L7 enforcement becomes a requirement.
* Cloud-runtime agents (Azure AI Foundry, Bedrock, Vertex). Containment there is provider-API-bound and is a separate deliverable in the parent proposal.
* Forensic/deception mode (parent area 4, mode 4) and irreversible decommission (mode 5).
* Multi-tenant containment isolation — the demo mutates one shared cluster by design.
* Production hardening, HA, and scale testing of the containment path.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Stun survives a forced reconcile | No — reverts to `idle` | Yes, 100% of trials | Forced-reconcile assertion, 20 trials |
| Silent drift-correction events on agent pods, unalerted | 36 observed, 0 alerted | 100% alerted | Alert on `configured` in controller logs |
| Time from stun to network denial (new connections) | Not measured | < 5s | Instrumented probe |
| Established connections surviving a stun | Indefinite (24h conntrack) | 0 beyond 5s | Long-lived-stream probe |
| Quarantine defeated by an unrelated allow policy | Yes, silently | No — CI-blocked | Crafted unguarded policy in CI |
| Un-stun leaving the object unmanaged | Untested failure mode | 0% | `skipped`→`unchanged` assertion |
| Containment events surviving label reversion | 0% (state only, no history) | 100% | Revert-then-query test |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Reconciler-safety of stun fields | Automated forced-reconcile assertion in the e2e harness, run unpinned | GitOps & Continuous Delivery |
| Network quarantine correctness | Bidirectional reachability probe, plus adversarial "defeat the quarantine" test | Cloud Native Transformation & DevSecOps |
| Guard-convention completeness | Static analysis with deliberately non-compliant fixtures proving the check goes red | GitOps & Continuous Delivery |
| Independent GitOps review | Flux principal review of the ignore/annotation strategy and the Argo mapping | #stefan-prodan |
| Adversarial review of the composed control | Red-team the stun: race windows, bypasses, ordering, un-stun failure modes | #tom-cope |
| Residual-risk statement | Published guaranteed-denial vs worst-case-residual per layer, not a single MTTK | Cloud Native Transformation & DevSecOps |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| Flux Operator / kustomize-controller | `spec.ignore` JSON Pointers; `reconcile: disabled`; drift-correction log signatures | Core ControlPlane practice; we sponsor Flux |
| Kubernetes NetworkPolicy | Label-selected quarantine, enforcement verified on the target CNI | Standard, portable, no new dependency |
| conntrack | Sever established connections that policy alone leaves open | Node-level, already present |
| cgroup-v2 freezer | Freeze-first containment (parent proposal's canonical mode 1) | Kernel primitive, no new component |
| OpenBao / SPIFFE | Credential and identity revocation | Existing Signal Loom stack; we sponsor OpenBao |
| Argo CD (documentation only) | Portability mapping for the pattern | Widens applicability beyond Flux estates |
| bats / vitest / Playwright | Static-guard, component and end-to-end validation | Existing repo test stack |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Implementation and tests | `osramp-demo` | Branch `feat/signal-loop-and-bootstrap-refactor` |
| Design research | `docs/signalloom/stun-under-flux.md` | Measured findings, five-mode taxonomy, open questions |
| Supporting research | `docs/signalloom/_research-ebpf-options.md`, `_research-flux-ignore.md` | Cluster-grounded evidence |
| Static guards | `scripts/check-flux-dynamic-labels.sh`, `test/flux-dynamic-labels.bats` | Wired into `make` |
| Target environment | local `kind` cluster `osramp` | Single node; NetworkPolicy enforcement confirmed |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Reconciler reverts the containment label | Contained agent reported healthy; operator stands down a live incident | `spec.ignore` on the runtime paths; `reconcile: disabled` escalation; alert on `configured` |
| Quarantine silently defeated by an unrelated allow policy | Agent regains network with no error and no visible change | Mandatory `NotIn: [stunned]` guard, enforced in CI |
| Agent retains established connections after quarantine | Exfiltration continues over an already-open socket for up to 24h | Conntrack invalidation as an explicit stun step |
| Agent observes its own containment and reacts | Exfiltration or re-auth in the race window | Freeze first; every later control acts on a process that cannot respond |
| `reconcile: disabled` left in place after un-stun | Object permanently unmanaged; drift accumulates while Flux reports Ready | Mandatory removal step; asserted by `skipped`→`unchanged` transition |
| Annotation used as an unauthorised GitOps opt-out | Any principal able to annotate a pod can exempt it from governance | Restrict the annotation via admission policy; treat as a privileged field |
| Policy enforcement fails open | CNI agent death silently disables all NetworkPolicy, cluster-wide | Liveness alerting on the CNI agent; documented as a residual |
| Node-local root and `hostNetwork` bypass | Quarantine does not contain node-root adversaries | Documented residual; out of scope for a network-layer control |
| Owning controller recreates the agent | Fresh, unstunned replacement | Apply containment at the owner, or scale to zero |
| Containment evidence is state, not history | "Never stunned" indistinguishable from "stun erased" | First-class events plus immutable audit record |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Every claim is measured on a live cluster, not inferred | Single-node `kind`; multi-node behaviour unvalidated |
| Uses primitives already present — no new CNI, no new workload | Network layer only; does not contain node-root adversaries |
| ControlPlane's Flux authority makes this a credible source | Depends on CNI-specific enforcement semantics |
| Findings are portable to Argo CD estates | cgroup-freeze feasibility not yet proven in this environment |

| Opportunities | Threats |
| :---- | :---- |
| Names a defect at the GitOps/incident-response intersection that the industry has not articulated | A vendor publishes the same analysis first |
| Directly remediates the parent proposal's weakest critiqued claim | Over-claiming again — the parent's "severs in-flight connections" is already wrong |
| Conference and written-content material with real measurements behind it | Auditors reading it as a completeness claim rather than a bounded control |
| Strengthens the Flux and OpenBao sponsorship narrative | Standards churn in agent runtimes changing the containment surface |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Reconciler-safe stun fields and static regression guard | | | | | #cap-gitops #cap-flux-taa #cap-policy-as-code |
| M2: Label-driven network quarantine with enforced `NotIn` guard convention | | | | | #cap-networking #cap-kubernetes #cap-policy-as-code |
| M3: Conntrack severing; cgroup-freeze feasibility spike and RBAC assessment | | | | | #cap-linux #cap-networking #cap-kubernetes |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 | | #cap-project-management |
| M4: Freeze-first composition and tested un-stun path | | | | | #cap-incident-response #cap-kubernetes #cap-architecture |
| M5: Containment audit trail, drift-correction alerting, Argo CD portability note | | | | | #cap-observability #cap-gitops #cap-documentation |
| M6: Adversarial review, residual-risk statement, parent-proposal errata | | | | | #cap-threat-modelling #cap-attackers-mindset |
| Signoff | | | | | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* A stun survives 20 consecutive forced reconciles with label and both annotations intact.
* An adversarial attempt to defeat the quarantine with an ordinary allow policy is blocked in CI.
* An established connection is severed within 5 seconds of a stun.
* A full stun → un-stun → stun cycle passes automatically, leaving the object fully managed.
* A containment event survives a reconcile that reverts the label.
* Published residual-risk statement naming every bypass found, including the fail-open CNI case.
* Parent proposal errata raised for the "severs in-flight connections" claim.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | GitOps & Continuous Delivery practice lead |
| Responsible | Signal Loom D2 platform team |
| Consulted | [Stefan Prodan](mailto:stefan.prodan@control-plane.io) (Flux), [Tom Cope](mailto:tom.cope@control-plane.io) (adversarial review) |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| None — uses existing local infrastructure and stack | £0 | — | — |
| Optional multi-node validation environment | TBD | One off | Nice-to-have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason  | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-08-03 | AJM | Do not adopt Cilium/eBPF for this deliverable | Measured benefit does not justify replacing the CNI on a working cluster; `kind` only accepts `disableDefaultCNI` at creation | Network layer stays L3/L4; L7 deferred |
| 2026-08-03 | AJM | Use both `spec.ignore` and stun-applied `reconcile: disabled` | Different granularity and different jobs: standing per-field protection vs reactive per-object escalation | Two mechanisms to document and test |
| 2026-08-03 | AJM | Freeze first, rather than revoke first | Every other control races a running adversary that can observe its own containment; freezing removes the ability to race | Reorders the stun; adds a cgroup dependency |
| 2026-08-03 | AJM | Rotate credentials on un-stun rather than restore | Revoked credentials may be compromised — restoring re-grants what the adversary may hold | Un-stun requires issuance, not just re-enablement |

## Appendix

### A. Useful Links

* `docs/signalloom/stun-under-flux.md` — the design research this proposal is drawn from
* `docs/signalloom/_research-ebpf-options.md` — enforcement options, measured against the node's nftables ruleset
* `docs/signalloom/_research-flux-ignore.md` — Flux field-ignore mechanisms in the running version
* `[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]` — parent, area 4
* `[[Proposal — Signal Loom Agent Security Platform — Critique Appendix (2026-Q3)]]` — B.0 findings 3 and 4

### B. Measured evidence summary

| Finding | Evidence |
| :---- | :---- |
| Flux reverts an imperatively-set stun label | `label → stunned`, forced reconcile, `read back → idle` |
| `reconcile: disabled` set by the stun protects it | Both label and annotation survived a forced reconcile; controller logged `skipped` |
| Label-change re-evaluation works on a running pod | `REACHABLE → BLOCKED` in ~6s, no restart; reversible |
| `kubectl exec` is unaffected by quarantine | Exec succeeded into a fully quarantined pod — forensic access is preserved for free |
| An ordinary allow policy silently defeats a quarantine | `BLOCKED → REACHABLE` on adding a routine app policy; `NotIn` guard restores `BLOCKED` |
| Established connections are never severed | Stream survived 14s+ past the stun; 24h conntrack timeout |
| Drift correction is silent but logged | 36 `configured` events on one agent pod, none alerted |
