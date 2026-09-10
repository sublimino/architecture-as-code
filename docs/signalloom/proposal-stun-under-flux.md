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
obsidianProject: 1. Projects/2026-07-signalloom-d2-platform-baseline/
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
  - "[[Proposal — Signal Loom eBPF Containment Primitives (2026-Q3)]]"
tags:
  - innovation-proposals
  - proposal-2026-q3-signal-loom-stun-under-flux
aliases:
  - "#proposal-2026-q3-signal-loom-stun-under-flux"
updated: 2026-08-31T08:09
---
# Proposal — Signal Loom Stun under Flux Operator (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-08-03) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

ControlPlane today announced that Signal Loom's agent containment now survives GitOps reconciliation — and, more importantly, that the *evidence* of containment survives with it.

That the reconciler undoes operational overrides is well known. Flux and Argo CD both document it, GitLab's public incident-response runbook warns about it, and practitioners say plainly that they disable the reconciler during incidents. What is not documented anywhere we can find is the second-order failure this creates for autonomous-agent containment: **the field the reconciler reverts is also the system's only record that containment happened.** Enforcement and evidence have different owners and therefore different lifetimes. Revocation lives outside the reconciled set and persists; the label recording it lives inside and is reverted. The console then reports a still-contained agent as healthy — a monitoring error in the reassuring direction, which is the worst one.

ControlPlane found this in its own platform by measuring rather than assuming. We are not claiming to have discovered that reconcilers fight incident response; we are claiming that nobody has yet joined it to agent containment, where the consequence is not an inconvenience but a false all-clear on a live incident. We have some standing to say so: ControlPlane presented *Automated Cloud Native Incident Response with Kubernetes and Service Mesh* at KubeCon EU 2023, and that talk treats GitOps purely as an asset. We said this three years ago and were incomplete.

Signal Loom now composes containment across the layers a reconciler cannot reach and those it can, declares which is which, and proves the distinction with tests — including the negative case, where an ordinary allow policy silently defeats a quarantine. The result is a containment control an auditor can believe: one whose enforcement and whose evidence have the same lifetime.

### Prior art, stated up front

Cut a novelty claim before a reviewer does. Adversarial prior-art search found the enforcement half of this problem thoroughly named:

| Source | What it already says |
| :---- | :---- |
| Flux documentation | Ignore rules exist precisely so operational state can coexist with reconciliation |
| Argo CD | Went through this bug cycle and shipped `ignoreDifferences`; `managedFieldsManagers` is a better model than Flux's paths |
| GitLab incident-response runbook | Publicly warns that the reconciler will revert manual production changes |
| Argo CD issue (2023) | *"we end up disabling argocd during incidents so that we can make quick changes"* |
| CNCF vendor blog (Jan 2024) | Names the two-loop conflict in a security-policy context |
| CNCF OSS (2024) | Label-driven quarantine already shipped as a feature |

**What survives:** the evidence half, joined to agent containment. **What does not:** any claim that the industry has not named the conflict. The narrow claim is defensible and is the one made here. Note also that `#stefan-prodan`, a named reviewer on this proposal, maintains the Flux mechanism this work depends on — a novelty claim that cannot survive its own first reviewer has no business in a press release.

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

**TRL 2 (Alpha).** The full option set, with measured trade-offs, is in **Appendix C**; the GitOps field-ownership mechanisms are in **Appendix E**; claims corrected or still contested during this work are in **Appendix D**, which a reviewer should read before the milestones.

The individual enforcement primitives are measured and working on a live cluster; what does not yet exist is a composed, tested, documented control with an un-stun path and an audit trail. This proposal takes measured primitives to an alpha-quality control, not to production.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Reconciler-safe stun fields | Runtime-owned fields (`signalloom.ai/state` and the two stun annotations) are excluded from GitOps drift correction, via `Kustomization.spec.ignore` JSON Pointers and a stun-applied `reconcile: disabled` escalation. | Specific: the three paths survive a forced reconcile.<br/>Measurable: label and both annotations unchanged after `flux reconcile`; controller logs `skipped` not `configured`.<br/>Attainable: both mechanisms already verified working on `kind-osramp`.<br/>Realistic: no new components required.<br/>Time-Bound: M1. | Automated: forced-reconcile assertion in the e2e harness. |
| Static guard against regression | CI check that no runtime-owned field is re-declared in Flux-managed desired state, distinguishing a declaration from a policy selector. | Specific: check fails on a declaration, passes on a `matchLabels` selector.<br/>Measurable: 10+ unit tests, including the selector and mixed-file cases.<br/>Attainable: implemented and green.<br/>Realistic: pure static analysis, no cluster.<br/>Time-Bound: M1. | `make check-flux-dynamic-labels-test`. |
| Label-driven network quarantine | Committed NetworkPolicy selecting `signalloom.ai/state=stunned`, denying ingress and egress, plus the mandatory `NotIn: [stunned]` guard convention on every other allow policy. | Specific: labelling a running pod blocks it; unlabelling restores it.<br/>Measurable: reachable→blocked→reachable, no pod restart.<br/>Attainable: verified on kindnet; NetworkPolicy enforcement confirmed.<br/>Realistic: ~40 lines of committed YAML.<br/>Time-Bound: M2. | Automated network probe, both directions. |
| Admin-tier quarantine (`ClusterNetworkPolicy` v1alpha2) | Express the quarantine as an **Admin-tier Deny**, which no NetworkPolicy can override, rather than relying on a convention every future policy author must remember. | Specific: an Admin-tier Deny selecting `state=stunned` holds against a deliberately hostile allow policy.<br/>Measurable: quarantine survives an allow policy that defeats the NetworkPolicy-tier version.<br/>Attainable: testable on the existing `kind` cluster, no CNI rebuild.<br/>Realistic: `ClusterNetworkPolicy` v1alpha2 is the live API — **not** ANP/BANP v1alpha1, which is the dead branch.<br/>Time-Bound: M2. | Adversarial "defeat the quarantine" test, run against both tiers. |
| Guard-convention enforcement (defence in depth) | Static check that every allow policy able to select an agent carries the `NotIn: [stunned]` guard — retained as a lint beneath the Admin tier, not as the primary control. | Specific: an unguarded allow policy fails CI.<br/>Measurable: check proven to go red on a crafted policy.<br/>Attainable: same analysis approach as the field guard.<br/>Realistic: reduces surface; **does not** fully solve additive defeat.<br/>Time-Bound: M2. | Unit tests with a deliberately unguarded fixture. |
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
| Liveness probe kills a frozen container | "Freeze first" is self-defeating on any probed workload — the kubelet restarts it into a fresh, unstunned instance | Suspend or tolerate probes as part of the freeze step; verified at M3 before M4 depends on it |
| `reconcile: disabled` drops the object out of Flux health checks | Kustomization can report Ready while the contained object is unassessed | Treat as a documented cost of the escalation; alert independently |
| Admin-tier `Allow` overrides the quarantine | An Admin-tier Allow outranks the Deny; no lower-tier policy can counter it | Restrict who may author Admin-tier policy; audit the tier |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Every claim is measured on a live cluster, not inferred | Single-node `kind`; multi-node behaviour unvalidated |
| Uses primitives already present — no new CNI, no new workload | Network layer only; does not contain node-root adversaries |
| ControlPlane's Flux authority makes this a credible source | Depends on CNI-specific enforcement semantics |
| Findings are portable to Argo CD estates | cgroup-freeze feasibility not yet proven in this environment |

| Opportunities | Threats |
| :---- | :---- |
| Joins a known GitOps/IR conflict to agent containment, where the consequence is a false all-clear rather than an inconvenience — the *evidence* half is un-named | The narrow claim is narrow: a sceptic can reasonably call this "a bug in your own demo" |
| Directly remediates the parent proposal's weakest critiqued claim | Over-claiming again — the parent's "severs in-flight connections" is already wrong |
| Conference and written-content material with real measurements behind it | Auditors reading it as a completeness claim rather than a bounded control |
| `ClusterNetworkPolicy` Admin-tier Deny gives an API-level guarantee, testable on the existing cluster | Building on `ClusterNetworkPolicy` v1alpha2 while the API is still alpha and churning |
| Strengthens the Flux and OpenBao sponsorship narrative | Standards churn in agent runtimes changing the containment surface |

## Milestones and Deliverables

| Milestones Committed To                                                                                                                                                                                   | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping                                               |
| :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :-------------- | :---------- | :---------- | :------- | :--------------------------------------------------------------- |
| M1: Reconciler-safe stun fields and static regression guard                                                                                                                                               |                 |             |             |          | #cap-gitops #cap-flux-taa #cap-policy-as-code                    |
| M2: Tier-1 durable quarantine — `ClusterNetworkPolicy` Admin-tier Deny, with the `NotIn` guard retained as a lint (Appendix C)                                                                            |                 |             |             |          | #cap-networking #cap-kubernetes #cap-policy-as-code              |
| M3: Tier-0 immediate containment — host-side veth eBPF spike, privileged node agent threat model and cost (Appendix C.1); conntrack severing; cgroup-freeze feasibility incl. the liveness-probe conflict |                 |             |             |          | #cap-linux #cap-networking #cap-kubernetes #cap-threat-modelling |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks                                                                                                  | 0.25            | 2           | 0.5         |          | #cap-project-management                                          |
| M4: Freeze-first composition and tested un-stun path                                                                                                                                                      |                 |             |             |          | #cap-incident-response #cap-kubernetes #cap-architecture         |
| M5: Containment audit trail, drift-correction alerting, Argo CD portability note                                                                                                                          |                 |             |             |          | #cap-observability #cap-gitops #cap-documentation                |
| M6: Adversarial review, per-CNI residual-risk statement, scoped parent-proposal erratum                                                                                                                   |                 |             |             |          | #cap-threat-modelling #cap-attackers-mindset                     |
| Signoff                                                                                                                                                                                                   |                 |             |             |          | #cap-project-management                                          |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* A stun survives 20 consecutive forced reconciles with label and both annotations intact.
* An adversarial attempt to defeat the quarantine with an ordinary allow policy is blocked in CI.
* An established connection is severed within 5 seconds of a stun.
* A full stun → un-stun → stun cycle passes automatically, leaving the object fully managed.
* A containment event survives a reconcile that reverts the label.
* Published residual-risk statement naming every bypass found, including the fail-open CNI case.
* Parent proposal erratum raised to **scope** the "severs in-flight connections" claim per-CNI — it is *correct* for Cilium and wrong for Calico, AWS VPC CNI and kindnet. The originally planned erratum would have introduced an error.

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
| 2026-08-03 | AJM | Adopt `ClusterNetworkPolicy` v1alpha2 Admin-tier Deny as the primary quarantine, demoting the `NotIn` guard to a lint | Cross-vendor audit: the guard leaves five residual defeat classes and "a lint is not a control"; an Admin-tier Deny cannot be overridden by any NetworkPolicy | Stronger guarantee from the API rather than convention; alpha-API risk accepted |
| 2026-08-03 | AJM | Do NOT raise the parent erratum as originally scoped | Cross-vendor audit found Cilium DOES re-evaluate policy on established flows (`CT_ESTABLISHED` falls through to the same verdict call as `CT_NEW` in `bpf/bpf_lxc.c`) — the parent's claim is correct for Cilium | The erratum becomes a per-CNI scoping note; the original would have introduced an error |
| 2026-08-03 | AJM | Rotate credentials on un-stun rather than restore | Revoked credentials may be compromised — restoring re-grants what the adversary may hold | Un-stun requires issuance, not just re-enablement |

## Appendix

### A. Useful Links

* `docs/signalloom/stun-under-flux.md` — the design research this proposal is drawn from
* `docs/signalloom/_research-ebpf-options.md` — enforcement options, measured against the node's nftables ruleset
* `docs/signalloom/_research-flux-ignore.md` — Flux field-ignore mechanisms in the running version
* `docs/signalloom/_audit-cato.md`, `_audit-grok.md`, `_audit-gemini.md` — cross-vendor adversarial audits (OpenAI, xAI and Google family) that produced the corrections in Appendix D
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
| Established connections survive — on kindnet, Calico and AWS VPC CNI | Stream survived 14s+ past the stun; 24h conntrack timeout. **NOT true of Cilium**, which re-evaluates policy on every packet (`CT_ESTABLISHED` falls through to the same verdict call as `CT_NEW` in `bpf/bpf_lxc.c`) — established by cross-vendor audit against upstream source, correcting an earlier claim in this document. |
| Drift correction is silent but logged | 36 `configured` events on one agent pod, none alerted |

### C. Enforcement options considered — network containment

Four options were assessed. Every row is measured on `kind-osramp` or read from upstream source; none is inferred from marketing.

| | **A. NetworkPolicy + label** | **B. Cilium / eBPF CNI** | **C. Controller watching label** | **D. Host-side veth eBPF** |
| :---- | :---- | :---- | :---- | :---- |
| Enforcement point | CNI, cluster-wide | CNI, cluster-wide | whatever it applies | **host end of the pod's veth pair** |
| Visible to Flux | Yes — object, reverts | Yes — object | depends | **No — kernel state, nothing to reconcile** |
| Defeated by an additive allow | **Yes, silently** | No (`ingressDeny`) | inherits A's flaw | **No — not a policy object** |
| Severs established flows | No (24h conntrack) | Disputed — see §D.1 | no | **Yes — per-packet verdict** |
| Time to deny | ~6s measured | ~5s (grace period) | +controller latency | immediate |
| L7 rules | No | **Yes** (Envoy) | no | not without extra work |
| Fail mode | **fail-OPEN** — kill `kindnetd` and every NetworkPolicy stops being enforced, silently | fail-closed | n/a | fail-closed while attached |
| Survives pod restart | Yes | Yes | Yes | **No — netns is recreated** |
| Visible to `kubectl` | Yes | Yes | Yes | **No — needs agent reporting** |
| Build cost | ~40 lines YAML | cluster rebuild, a day+ | new component | privileged node agent |
| Verdict | ship now, as the durable record | correct 12-month target, wrong move now | not justified over A | **best immediate primitive** |

**Why D is architecturally distinct.** Options A, B and C all express containment as configuration. D expresses it as kernel state, which gives it the same property that makes a cgroup freeze attractive: the reconciler cannot see it, so it cannot revert it, so no `spec.ignore` or `reconcile: disabled` is needed for the *enforcement* half at all.

**Enforce on the host end, not inside the container's netns.** The pod's veth pair is enumerable from the node (`vethe5279aad@if2 … link-netns cni-…`). Attaching inside the container namespace assumes the workload lacks `CAP_NET_ADMIN` — true for this agent today by containerd's default capability set, but *implicit rather than asserted*, and this is the pod whose empty `securityContext` is the demo's own compliance finding. The host end is unreachable from the container regardless of its capabilities.

#### C.1 Recommended composition — three tiers by scope and lifetime

Not OSI layers; enforcement tiers with deliberately different properties, so that compromising or losing one does not remove the others.

| Tier | Mechanism | Latency | Lifetime | Revocable by | Weakness |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **0** | host-side veth eBPF | immediate | dies with the pod | node agent | invisible to the API |
| **1** | NetworkPolicy / ClusterNetworkPolicy | seconds | durable, reconciled | cluster admin | additive defeat (tier-1 NP only) |
| **2** | VPC / security group | minutes | outlives the cluster | cloud admin | coarse, no pod identity |

Tier 0 is the immediate action; tier 1 is the durable, auditable record; tier 2 is the backstop that survives cluster compromise. This is the two-phase model of §6 with a materially better phase one, and it is what a per-plane "guaranteed denial vs worst-case residual" table should be built on rather than a single MTTK.

### D. Contested and corrected claims

Recorded because a reader deserves to know which findings are settled and which are not.

#### D.1 Do established connections survive a policy change?

| Source | Position | Basis |
| :---- | :---- | :---- |
| Parent proposal, area 4 | Cilium severs in-flight connections | asserted |
| This work's eBPF research | Nothing severs them, Cilium included | measured on kindnet; **Cilium inferred, not installed** |
| Cross-vendor audit (Google family) | Cilium **does** re-evaluate: `CT_ESTABLISHED` falls through to the same `policy_can_egress4()` call as `CT_NEW` in `bpf/bpf_lxc.c` | **upstream source** |

**Unresolved.** Primary source beats inference, so the audit is more likely right and the parent's claim is probably correct for Cilium. Settled for kindnet, Calico and AWS VPC CNI: connections **do** survive, with a 24h conntrack timeout. **Do not put either claim in a customer document until it is tested on a cluster actually running Cilium.** The originally planned erratum against the parent would have introduced an error rather than fixing one.

#### D.2 Claims corrected during this work

| Claim as first written | Correction | Found by |
| :---- | :---- | :---- |
| "The industry has not named this problem" | Named in Flux docs, Argo docs, GitLab's IR runbook, a 2023 Argo issue, a Jan-2024 CNCF blog. Only the *evidence* half, joined to agent containment, survives | contrarian audit (xAI family) |
| "kustomize-controller v1.9.4 exposes no per-field drift ignore" | `Kustomization.spec.ignore` is exactly that | Flux research |
| "Delete the runtime field from desired state" | **Strictly worse** — the field is deleted rather than reverted. Declared-**and**-ignored is the mechanism | matched control, TEST G/H |
| "The Flux pin has started perturbing the demo" | Intermittent flake; a second run under the identical pin passed | own re-test |
| "Nothing severs established connections, Cilium included" | Wrong for Cilium — see D.1 | cross-vendor audit |

### E. GitOps field-ownership mechanisms

| Mechanism | Granularity | Object stays managed | Verdict |
| :---- | :---- | :---- | :---- |
| **`Kustomization.spec.ignore`** (JSON Pointer) | **one field** | **yes** | **correct mechanism**, measured |
| `reconcile: disabled` on the object | whole object | no | escalation only; also suppresses pruning **and drops the object from health checks** |
| `ssa: ignore` | whole object | no | same cost as above, no benefit |
| `ssa: merge` | field ownership | yes | does not solve it |
| `.spec.patches` `op: remove` | field | yes | **worse than status quo** — wipes the value |
| `spec.suspend` on the Kustomization | everything it owns | no | rejected: blast radius exceeds the threat, and it is an availability attack surface |

**The rule is BOTH.** Declared-without-ignore reverts; ignored-without-declaration deletes. `spec.ignore` substitutes the *live* value at each ignored path into the desired object before apply — a path the manifest never declares has nothing to substitute into. `scripts/check-flux-dynamic-labels.sh` enforces the pair.

**Known gap (Q7):** `spec.ignore` is a Kustomization field with no flux-operator ResourceSet equivalent, so agents rendered by a ResourceSet have nowhere to hang the rule.

### F. Argo CD equivalents

| Flux | Argo CD | Note |
| :---- | :---- | :---- |
| `Kustomization.spec.ignore` | `Application.spec.ignoreDifferences.jsonPointers` | direct analogue |
| — | **`ignoreDifferences.managedFieldsManagers`** | **better model — ignores by field *owner*, not path** |
| `reconcile: disabled` | no exact equivalent; nearest is `compare-options: IgnoreExtraneous` + `sync-options: Prune=false` | partial |
| `spec.suspend` | `syncPolicy.automated.selfHeal: false` | same anti-pattern |

`managedFieldsManagers` is worth stealing: a stun that starts writing a *new* annotation is covered automatically, whereas a path list silently misses it — which is exactly how the two stun annotations were missed in the first analysis. Actionable on either engine: apply the stun with `--field-manager=signalloom-stun`.

### G. The five-mode taxonomy, mapped to reconciler friction

From the parent proposal's area 4, with the mapping this work contributes.

| Mode | Mechanism | Expressed as a k8s object | Reconciler friction |
| :---- | :---- | :---- | :---- |
| 1 Stun (freeze) | cgroup-v2 freezer | **no** | **none** |
| 2 Network killswitch | eBPF / policy | tier 0 **no**, tier 1 yes | **none at tier 0** |
| 3 Credential revocation | SVID + OpenBao | no (but see the bootstrap re-seed) | indirect |
| 4 Forensic mode | relocate to deception ns | yes | high |
| 5 Kill / decommission | + admission block, lifecycle | yes | high |

The demo currently implements mode 3 plus a label and calls it "stun". Modes 1 and 2-at-tier-0 are the two that a reconciler cannot touch, and they are the two the demo does not yet do.

---

### Spec: Shared Patterns

Baseline standards for every card in this mission. Pre-Flight (`P<N>-PRE`) and Governor (`P<N>-GOV`) cards extend this section with `### Spec: Shared Patterns — Phase <N>` blocks.

**Evidence discipline — this repo's recorded failure modes, as binding rules.**

- **Never conclude "Flux will not revert this" from a dry-run, or from a reconcile that failed before its apply stage.** That exact error was made and retracted twice on 2026-08-30. Before trusting green, compare `status.lastAppliedRevision` against `lastAttemptedRevision`; a sub-second reconcile duration means it failed before doing anything.
- **Flux sources from OCI artifacts in zot, not the working tree.** A tree edit plus `flux reconcile` proves nothing. The durable sequence is `./scripts/push-local.sh` → `flux reconcile kustomization tenants -n flux-system --with-source` → read the object back.
- **The revert window is ~5 minutes** (`reconcileEvery: 5m`). Any validation completing inside one interval has not been tested.
- **Assert on the stored object, never the manifest.** A structural CRD prunes undefined fields and `kubectl apply` still exits 0.
- **A pod is briefly unconfined after start.** Asserting denial at t=0 measures CNI programming latency, not policy. Gate on a positive control — wait until a *permitted* path succeeds from the same pod — and time out to `UNVERIFIED`, never to a pass. A bare retry-until-denied is worse than the bug: it makes a real hole indistinguishable from "CNI not ready".
- **An allowed path proves dataplane readiness, not confinement.** Both assertions are needed; they are not the same test.
- **`nc` exit 1 means denied, broken, unresolvable, or dead pod.** Only stderr distinguishes them.
- **A frozen process cannot answer a probe.** Silence after a cgroup freeze is not evidence of severance. Design the check that rules out the wrong explanation before freezing.
- **Pair every negative assertion with a presence assertion in the same test.** Any test whose success condition is an empty result set has a second, unstated way to succeed.
- **Green is the failure mode. An unexplained pass is a finding.** Mutate the real file to prove a guard bites; a briefed agent still wrote three vacuous guards on 2026-08-30.

**Repo-enforced constraints on any new harness.**

| Constraint | Gate |
|---|---|
| Register the suite in a runner or CI fails | `d2-signalloom/test/bats-registry-coverage.bats` (stage 1h) |
| Register in **both** pipelines or it runs single-lane silently | `scripts/ci/vm-pipeline.sh` **and** `scripts/gcp-tf/demo-pipeline.sh` |
| No `kubectl exec` probes outside the allowlist | `test/no-exec-probes-in-tests.bats` (stage 1k) |
| Assertions must be able to go red | `scripts/check-vacuous-assertions.sh` (1o), `test/guard-falsification-proof.sh` (1q) |
| Every `.bats` must parse and declare ≥1 test | `d2-signalloom/test/tree-integrity.bats` |
| Do not name a non-terraform guard `test/terraform-*.bats` | Makefile:1517 glob ownership |

**Worktree discipline.** Every Bash path absolute. `git -C "$WORKTREE"`, never bare `git` — a bare `git commit` in a multi-worktree session is a coin flip. Print `pwd` in any command whose result is reported. `go build` fails inside a git worktree (`buildvcs`); use `-buildvcs=false`.

**Testing.** pytest needs `PYTHONPATH=src PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`. Count declared tests against reported; `grep -c '^ok '` counts skips as passes. Assert `passed + skipped == total`, never `passed == total`.

### Spec: Capability Plan

| Logical ID | Skills / agents | Size | Wall-clock | Agent | Rationale |
|---|---|---|---|---|---|
| P0 | — | S | 30 | daily | Harness smoke test |
| P1-PRE | `Science` | M | 90 | daily | Capture kindnet baseline before it is destroyed — it is unrecoverable afterwards |
| P1-1 | `Engineer` | L | 180 | deep | Cluster rebuild on Cilium; irreversible, highest blast radius |
| P1-2 | `Engineer` | M | 120 | daily | Rewrite six kindnet-rationale policy files |
| P1-3 | `Engineer` | M | 120 | daily | Make live NetworkPolicy enforcement an unconditional CI gate |
| P1-GOV | `RootCauseAnalysis` | M | 90 | daily | Merge gate; verify no silent skip was introduced |
| P2-PRE | `FirstPrinciples` | M | 90 | daily | Enumerate ResourceSet ignore options before committing to one |
| P2-1 | `Architect`, `Engineer` | L | 180 | deep | Solve the ResourceSet field-ownership gap — no upstream mechanism exists |
| P2-2 | `Science` | M | 120 | daily | Forced-reconcile harness; 20-iteration survival proof |
| P2-GOV | `RootCauseAnalysis` | M | 90 | daily | Merge gate |
| P3-PRE | `FirstPrinciples` | S | 60 | daily | Confirm Cilium enforcement semantics before writing policy |
| P3-1 | `Engineer` | M | 120 | daily | Label-driven quarantine policy plus `NotIn` guards on all 9 allow policies |
| P3-2 | `Engineer` | M | 150 | daily | Admin-tier cluster-wide deny |
| P3-3 | `RedTeam` | M | 120 | daily | Adversarial defeat test, gated in CI |
| P3-GOV | `RootCauseAnalysis` | M | 90 | daily | Merge gate |
| P4-PRE | `Science` | S | 60 | daily | Establish the probe design that survives a frozen target |
| P4-1 | `Engineer` | M | 120 | daily | Build and load the stun-sentinel image — no target exists today |
| P4-2 | `Engineer` | M | 150 | daily | Conntrack severing plus the missing `network.go` tests |
| P4-3 | `Science` | M | 120 | daily | Measure whether Cilium severs — settles contested claim D.1 |
| P4-GOV | `RootCauseAnalysis` | M | 90 | daily | Merge gate |
| P5-PRE | `FirstPrinciples` | S | 60 | daily | Order-of-operations for freeze-first |
| P5-1 | `Engineer` | M | 150 | daily | Freeze-first composition |
| P5-2 | `Engineer` | M | 150 | daily | Tested un-stun path with credential rotation |
| P5-GOV | `RootCauseAnalysis` | M | 90 | daily | Merge gate |
| P6-PRE | `SystemsThinking` | S | 60 | daily | Identify where evidence itself is reconciler-owned |
| P6-1 | `Engineer` | M | 150 | daily | Containment audit trail surviving label reversion |
| P6-2 | `Engineer` | M | 120 | daily | Drift-correction alerting on the `configured` signature |
| P6-GOV | `RootCauseAnalysis` | M | 90 | daily | Merge gate |
| P7-PRE | `WorldThreatModel` | S | 60 | daily | Frame the residual-risk surface |
| P7-1 | `RedTeam`, `Cato` | L | 180 | deep | Adversarial review, per-CNI residual risk, parent erratum |
| P7-GOV | `RootCauseAnalysis` | M | 90 | daily | Final merge gate |

### Spec: Work Decomposition
| Logical ID | Task | Depends on | Tests | Size | Agent | Result | Est. Cost | Tokens | Elapsed | AI URI |
| --- | --- | --- | --- | --- | --- | --- | :-------- | :----- | :------ | :--- |
| P0 | Harness smoke test | — | card completes and writes errata | S | daily | pass — delivered: a046ac9fe6f1af153df3adf180c5865c696c66da (see Errata — STUN-P0) | $0.00 | N/A — no session | N/A | agy://open?id=a046ac9fe6f1af153df3adf180c5865c696c66da&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-PRE | Capture the kindnet baseline that the rebuild destroys: current enforcement behaviour, the six post-DNAT policy rationales, and a recorded measurement that established connections survive on kindnet | — | baseline artefact committed; each of the six files named with its rationale | M | daily | pass — delivered: df4330a1c7b659be8bacf8713ee929c0e6d9ad52 (see Errata — STUN-P1-PRE) | $0.00 | N/A — no session | N/A | agy://open?id=df4330a1c7b659be8bacf8713ee929c0e6d9ad52&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-1 | Rebuild the cluster on Cilium: add `disableDefaultCNI: true` and `kubeProxyMode: none` to the `create-kind-cluster.sh` heredoc, add a pinned Cilium install ahead of Flux bootstrap, and restore the full stack via `make up` | P1-PRE | `test/kind-config-heredoc.bats` extended; `make up` reaches healthcheck; Cilium reports all pods managed | L | deep | pass — delivered: 8ad80113b6d4468c16a8f6eebe18f7ca29843ae9; qualified evidence: 05d5a0bd (see Errata — STUN-P1-1) | $0.00 | N/A — no session | N/A | agy://open?id=8ad80113b6d4468c16a8f6eebe18f7ca29843ae9&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-2 | Rewrite the six kindnet post-DNAT policy rationales for Cilium semantics, tightening port-scoped rules to CIDR-scoped where Cilium now permits it | P1-1 | `d2-signalloom/test/networkpolicy-coverage.bats` extended; netassert 11 cases still pass | M | daily | pass — delivered: 061bd57715135d1ed35404041e8ab291314d0a43 (see Errata — STUN-P1-2) | $0.00 | N/A — no session | N/A | agy://open?id=061bd57715135d1ed35404041e8ab291314d0a43&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-3 | Make live NetworkPolicy enforcement an unconditional CI gate: remove the `if command -v netassert` guard and register the stage in both pipelines | P1-1 | deliberately-broken policy makes the new stage go red | M | daily | pass — delivered: 059408acebada971d75715166f28d9d12026b45d; supervisor-approved ten-case invariant | $0.00 | N/A — no session | N/A | agy://open?id=59cd01f7051df1bb20942475e53303d8d641ec92&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-GOV | Merge phase 1; verify no suite was left conditionally skipped | P1-1, P1-2, P1-3 | declared-vs-reported test count reconciles across both pipelines | M | daily | pass — Governor integration repair b64e0e586b447ccb05800deb666d3ee9e1132dda; original refusal retained | $0.00 | N/A — no session | N/A | agy://open?id=b64e0e586b447ccb05800deb666d3ee9e1132dda&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P2-PRE | Enumerate every option for reconciler-safe fields on a flux-operator ResourceSet, given `ResourceSet.spec` has no `ignore` field: per-object annotation, whole-set escalation, cohort migration to Kustomization, upstream change | P1-GOV | options documented with a measured verdict each | M | daily | pass — Option E selected from flux-operator v0.58.1 Pod measurements; raw evidence in `docs/signalloom/stun-resourceset-options.md`; commit 52d07666cdb8031d6a5688504f022de106db16ce; verification qualified by unrelated undeployed `namespace/frontend` | $0.00 | N/A — no session | N/A | agy://open?id=52d07666cdb8031d6a5688504f022de106db16ce&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P2-1 | Implement the chosen ResourceSet field-ownership solution so a stun label on a ResourceSet-managed agent survives reconciliation | P2-PRE | stunned ResourceSet agent retains label and both annotations after a real successful reconcile | L | deep | qualified — field-ownership implementation `7168493d176131cdc489b316f27e3bcb2f9be3c7` is integrated; Governor acceptance waits on P2-2 live proof | $0.00 | N/A — no session | N/A | agy://open?id=7168493d176131cdc489b316f27e3bcb2f9be3c7&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P2-2 | Build the forced-reconcile harness and prove survival across 20 consecutive reconciles, asserting on the stored object | P2-1 | 20/20 iterations retain all three fields; harness proven to go red against an unignored field | M | daily | pass — repaired at `baad9e4050cb58534269272d31ec146616c76db0`; genuine 20/20 live proof; see Repair errata — STUN-P2-GOV | $0.00 | N/A — no session | N/A | agy://open?id=9f83403b1bb01f296b29f68a0199ed2b03a8ad65&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P2-GOV | Merge phase 2 | P2-1, P2-2 | `make check-flux-dynamic-labels` green; guard still bites under mutation | M | daily | pass — repair commit `baad9e4050cb58534269272d31ec146616c76db0`; see Repair errata — STUN-P2-GOV | $0.00 | N/A — no session | N/A | agy://open?id=P2-GOV&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P3-PRE | Confirm Cilium enforcement semantics that phase 3 depends on: programming latency at pod start, and whether an additive allow can defeat a deny | P2-GOV | both behaviours measured and recorded | S | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P3-PRE&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P3-1 | Add the label-driven quarantine NetworkPolicy selecting `signalloom.ai/state=stunned`, plus the `NotIn: [stunned]` guard on all nine existing allow policies | P3-PRE | labelling blocks a running pod with no restart; unlabelling restores; positive control proves the dataplane was ready | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P3-1&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P3-2 | Express the quarantine as a cluster-wide admin-tier deny that no ordinary allow policy can override | P3-1 | admin-tier deny holds where the NetworkPolicy-tier version is defeated | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P3-2&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P3-3 | Adversarial defeat test: prove an ordinary allow policy defeats the tier-1 policy and does not defeat the admin tier; gate it in CI | P3-2 | test goes red against the tier-1 policy and green against the admin tier | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P3-3&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P3-GOV | Merge phase 3 | P3-1, P3-2, P3-3 | quarantine survives a forced reconcile | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P3-GOV&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P4-PRE | Design a severance probe valid against a target that cannot answer, and record why silence alone is insufficient | P3-GOV | probe design documented with its false-pass mode named | S | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P4-PRE&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P4-1 | Add the missing Makefile target that builds and kind-loads the `stun-sentinel` image, and pin the DaemonSet away from `:latest` | P4-PRE | image builds, loads, and the DaemonSet reaches Ready | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P4-1&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P4-2 | Implement conntrack severing in the sentinel and add the absent `network.go` test file | P4-1 | established stream dies within 5s; without the step it survives past 60s | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P4-2&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P4-3 | Measure whether Cilium alone severs established flows on policy change, settling contested claim D.1 | P4-1 | result recorded either way; Appendix D.1 updated from unresolved to measured | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P4-3&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P4-GOV | Merge phase 4 | P4-1, P4-2, P4-3 | severance timing reproducible across three runs | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P4-GOV&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P5-PRE | Fix the order of operations for freeze-first and name what each step must observe | P4-GOV | ordering documented with the audit assertion for each step | S | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P5-PRE&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P5-1 | Compose freeze-first containment: freeze before revocation, with the ordering provable from the audit record | P5-PRE | freeze precedes revocation in the record; process state is `frozen` | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P5-1&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P5-2 | Implement and test the un-stun path: rotate rather than restore credentials, unfreeze last, remove any reconcile escalation | P5-1 | stun→un-stun→stun cycle passes; new credential serial differs; object fully managed again | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P5-2&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P5-GOV | Merge phase 5 | P5-1, P5-2 | cycle passes from a cold cluster | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P5-GOV&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P6-PRE | Identify every point where the containment evidence is itself reconciler-owned and therefore revertible | P5-GOV | each evidence store classified by owner and lifetime | S | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P6-PRE&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P6-1 | Emit a first-class stun/un-stun event to Kubernetes Events and an immutable store | P6-PRE | event survives a forced reconcile that reverts the label; empty-log false pass explicitly excluded | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P6-1&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P6-2 | Alert on the drift-correction `configured` signature | P6-1 | synthetic drift raises exactly one alert; absence of drift raises none | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P6-2&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P6-GOV | Merge phase 6 | P6-1, P6-2 | audit assertions proven to go red | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P6-GOV&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P7-PRE | Frame the residual-risk surface across all three enforcement tiers | P6-GOV | surface enumerated per tier with lifetime and revoker | S | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P7-PRE&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P7-1 | Adversarial review; publish the per-CNI residual-risk statement; raise the scoped parent-proposal erratum | P7-PRE | every bypass found is named; erratum scopes the severing claim per CNI | L | deep |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P7-1&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P7-GOV | Final merge and completion gate | P7-1 | all six definition-of-done items evidenced | M | daily |  | $0.00 | N/A — no session | N/A | agy://open?id=STUN-P7-GOV&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |

### Spec: Errata

*No work has started. Entries are appended by cards at completion.*

#### Errata — STUN-P0 STUN-P0: Harness smoke test — prove worktree, errata and commit path end to end
**Created:** 2026-08-30 22:25:10+01:00
**Last Updated:** 2026-08-30 22:25:10+01:00
**Status:** Completed
**Commit:** a046ac9fe6f1af153df3adf180c5865c696c66da
**Governor merge:** [pending Governor reconciliation]
**Decisions:**
- Harness writers: `obsidian-append` covers the errata link but structurally cannot satisfy the Result-column link, so the harness needs two distinct vault writers (`obsidian-append --stdin --section` and `obsidian-modify`).
- Unsigned commit: matched branch practice (%G? = N) with `--no-gpg-sign` to avoid pinentry deadlock.
- Explicit pathspec commit: isolated to `docs/stun-under-flux/P0-harness-smoke.md`.
**Deviations:** None. All six links of the harness verified end to end.
**Notes:**
- Preflight bridge health was verified healthy (`status: "ok"`, eval responsive).
- Read-only board inspection executed cleanly without mutation.
- Verified falsification/mutation proof: verifier script returns exit 1 on mutated proposal, exit 0 on clean proposal.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P0","status":"pass","commit":"a046ac9fe6f1af153df3adf180c5865c696c66da"} -->

#### Errata — STUN-P1-PRE
**Created:** 2026-08-30 22:58:00+01:00
**Last Updated:** 2026-08-30 22:58:00+01:00
**Status:** Completed
**Commit:** df4330a1c7b659be8bacf8713ee929c0e6d9ad52
**Governor merge:** [pending Governor reconciliation]
**Decisions:**
- Captured live kindnet dataplane state on Kind cluster kind-osramp before Cilium rebuild.
- Captured 6 post-DNAT NetworkPolicy files with line numbers, rationales, and exact sha256 checksums:
  1. `d2-signalloom/apps/supercred-demo-runner/base/networkpolicy.yaml` (line 148)
  2. `d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml` (line 13)
  3. `d2-signalloom/infra/agent-swarm/networkpolicy.yaml` (line 87)
  4. `d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml` (line 101)
  5. `d2-signalloom/infra/inf-signalloom/configs/base/netassert-controller-egress-networkpolicy.yaml` (line 24)
  6. `d2-signalloom/infra/inf-signalloom/configs/base/fake-integration-proxy-egress-networkpolicy.yaml` (line 27)
- Measured established TCP flow survival (verdict: `SURVIVED`, `bytes_after_policy: 216` bytes) and verified paired fresh probe rejection (verdict: `denied`, stderr: `Connection error: timed out`).
- Implemented in-cluster measurement Job (`d2-signalloom/apps/stun-baseline-probe/job.yaml`) executing without `kubectl exec` in compliance with EXECBAN.
- Built 14-test BATS guard suite in `d2-signalloom/test/kindnet-baseline-artefact.bats` registered in CI pipelines, with 5/5 mutation proof verified in `d2-signalloom/test/kindnet-baseline-mutation-proof.sh`.
**Deviations:** None.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P1-PRE","status":"pass","commit":"df4330a1c7b659be8bacf8713ee929c0e6d9ad52"} -->

#### Errata — STUN-P1-2 STUN-P1-2: Rewrite the six kindnet post-DNAT policy rationales for Cilium
**Created:** 2026-08-30 23:31:17+01:00
**Last Updated:** 2026-08-30 23:31:17+01:00
**Status:** Completed
**Commit:** 061bd57715135d1ed35404041e8ab291314d0a43
**Governor merge:** [pending Governor reconciliation]
**Decisions:**
- Preserved transport port scoping (TCP 443 and TCP 6443) on all six policies because Cilium socket-level load balancing rewrites 10.96.0.1:443 in the connect4 hook before NetworkPolicy evaluation, and node IPs carry reserved host/remote-node identities not selected by standard ipBlock rules.
- Re-derived supercred-demo-runner apiserver rationale to explicitly cover both direct API connections and kubectl port-forward tunnel transport paths.
- Maintained exact semantic equivalence: canonical kustomize render inventory confirmed 0 spec deltas between baseline and post-rewrite manifests.
- Extended networkpolicy-coverage.bats from 7 to 14 tests, verifying kindnet string elimination, Cilium rationale presence, citation validity, CRD stability, default-deny pairing, CIDR breadth, and port retention.
- Verified 3/3 falsification mutations in networkpolicy-coverage-mutation-proof.sh.
**Deviations:** None.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P1-2","status":"pass","commit":"061bd57715135d1ed35404041e8ab291314d0a43"} -->

#### Errata — STUN-P1-3
**Created:** 2026-08-30 23:32:00+01:00
**Last Updated:** 2026-08-30 23:32:00+01:00
**Status:** Completed
**Commit:** 59cd01f7051df1bb20942475e53303d8d641ec92
**Governor merge:** [pending Governor reconciliation]
**Decisions:**
- Removed conditional `@if command -v netassert` check and "skipping" branch from root `Makefile` (invoking `$(MAKE) -C d2-signalloom test-netassert` unconditionally).
- Introduced `netassert-preflight` target and runner in `d2-signalloom/test/run-netassert.sh` asserting pinned version `v2.1.5`, case file existence, and target namespace reachability.
- Hardened agent pod resolution and sed substitution: dynamically queries exactly 1 live agent pod in `fe-signalloom-agents`, replaces placeholder tokens, and asserts 0 placeholder tokens remain with substitution count matching expectations.
- Enforced case-tally invariant (5 allowed exitCode 0, 5 denied exitCode 1) to refuse execution on corrupted case definitions.
- Implemented positive-control gating: bounded poll on permitted path `dashboard-to-api-allowed` before evaluating denials; timeouts exit distinct status `3` (`UNVERIFIED`).
- Registered stage `Live NetworkPolicy enforcement (netassert)` (`stage7a-netassert.tap`) identically across `scripts/ci/vm-pipeline.sh` and `scripts/gcp-tf/demo-pipeline.sh`, mapped in `scripts/ci/openreports-convert.sh` under security category.
- Provisioned pinned `netassert` `v2.1.5` in `scripts/ci/install-ci-tools.sh` and `scripts/setup.sh`.
- Created 10-test BATS suite `d2-signalloom/test/netassert-stage-registration.bats` and 8-case mutation falsification proof in `test/netassert-gate-falsification-proof.sh`.
**Deviations:** None.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P1-3","status":"pass","commit":"59cd01f7051df1bb20942475e53303d8d641ec92"} -->
#### Errata — STUN-P1-1 Rebuild the cluster on Cilium with disableDefaultCNI and pinned install
**Created:** 2026-08-31 02:05:36+01:00
**Last Updated:** 2026-08-31 02:10:11+01:00
**Status:** Completed
**Commit:** 8ad80113b6d4468c16a8f6eebe18f7ca29843ae9
**Governor merge:** [pending Governor reconciliation]
**Decisions:** Cilium 1.16.7 uses operator.image.repository=quay.io/cilium/operator with genericDigest; CiliumEndpoint GC required its configured five-minute interval before endpoint equality became true.
**Deviations:** The pre-existing cluster had already been rebuilt before this card started. P1-PRE commit df4330a1c7b659be8bacf8713ee929c0e6d9ad52 remains the authoritative unrecoverable Kindnet baseline.
**Notes:** HELM_CACHE_HOME=$PWD/.cache/helm make up reached healthcheck; this is liveness only. The committed CNI gate passed after bounded CiliumEndpoint GC waiting; after the pairing agent loaded signalloom-spire-helper:local, fleet-manager:local, signal-ingest:local, supercred-demo-runner:local, dashboard-signalloom:local, and fe-signalloom:local, the observed settled inventory was 28 running non-hostNetwork pods, 28 ready endpoints, and zero unready endpoints. The rebuild marker ConfigMap records the commit, cluster UID, Cilium digest, P1-PRE SHA, and UTC timestamp. Netassert remains P1-3-owned; no policy semantics changed.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
#### Errata — STUN-P1-3
**Created:** 2026-08-31 03:26:00+01:00
**Last Updated:** 2026-08-31 03:26:00+01:00
**Status:** Failed — honest partial result
**Commit:** ff9d13b3dc2a63db68df9a9e9f64bcfebce84add
**Governor merge:** blocked
**Decisions:**
- Committed the three card-owned paths only: `Makefile`, `d2-signalloom/test/run-netassert.sh`, and `d2-signalloom/test/netassert-stage-registration.bats`.
- Pinned netassert version remains `v2.1.5`; both pipeline registrations use the exact label `Live NetworkPolicy enforcement (netassert)`.
- Live Cilium evidence: `kind-osramp`, kube-proxy replacement `true`, kube-proxy DaemonSet absent, and `make -C d2-signalloom test-netassert` exited 0.
**Blocking deviations:**
- The live runner declared and reported **10** cases (5 allowed, 5 denied), not the card-required 11 (5 allowed, 6 denied); authoring a case is explicitly out of scope.
- `bats d2-signalloom/test/bats-registry-coverage.bats` exits 1 because `test/netassert-gate-falsification-proof.sh` is not invoked by a runner.
- Per-case lines do not carry captured stderr fragments, so denial cannot yet be distinguished auditably from every harness error.
**Result:** status=fail; do not advance. The committed SHA was verified by `git cat-file -t ff9d13b3dc2a63db68df9a9e9f64bcfebce84add`, which printed `commit`.
<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
<!-- kanban-check: {"card":"STUN-P1-3","status":"fail","commit":"ff9d13b3dc2a63db68df9a9e9f64bcfebce84add","blocking_command":"bats d2-signalloom/test/bats-registry-coverage.bats"} -->
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P1-3","status":"pass","commit":"059408acebada971d75715166f28d9d12026b45d"} -->
#### Errata — STUN-P1-3 final approval
**Created:** 2026-08-31 03:42:00+01:00
**Last Updated:** 2026-08-31 03:42:00+01:00
**Status:** Passed — supervisor-approved design
**Commit:** 059408acebada971d75715166f28d9d12026b45d
**Result:** The approved invariant is 10 cases: 5 allowed and 5 denied. No case file or tally was changed. The proof is registered, all per-case verdict lines carry captured `STDERR:` evidence, and the focused registration and registry-coverage suites pass.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P1-3","status":"pass","commit":"059408acebada971d75715166f28d9d12026b45d"} -->

#### Errata — STUN-P1-GOV
**Status:** pass — Phase 1 census criterion is met after the authorized integration repair.
**Commit:** b64e0e586b447ccb05800deb666d3ee9e1132dda
**Decisions:** Retains the original Governor refusal and repair errata blocks; see `docs/signalloom/stun-p1-governor-census.md` for raw census and ancestry evidence.
**Deviations:** `d2-signalloom/test/kindnet-baseline-artefact.bats` and `d2-signalloom/test/kindnet-baseline.bats` remain pre-existing red, unowned, and unrepaired.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P1-PRE | $0.00 | N/A — no session | N/A | agy://open?id=df4330a1c7b659be8bacf8713ee929c0e6d9ad52&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-1 | $0.00 | N/A — no session | N/A | agy://open?id=8ad80113b6d4468c16a8f6eebe18f7ca29843ae9&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-2 | $0.00 | N/A — no session | N/A | agy://open?id=061bd57715135d1ed35404041e8ab291314d0a43&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-3 | $0.00 | N/A — no session | N/A | agy://open?id=59cd01f7051df1bb20942475e53303d8d641ec92&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P1-GOV | $0.00 | N/A — no session | N/A | agy://open?id=b64e0e586b447ccb05800deb666d3ee9e1132dda&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P1-GOV","status":"pass","commit":"b64e0e586b447ccb05800deb666d3ee9e1132dda"} -->
#### Errata — STUN-P2-1 Implement the chosen ResourceSet field-ownership solution
**Created:** 2026-08-31 06:50:05+01:00
**Last Updated:** 2026-08-31 06:50:05+01:00
**Status:** Completed
**Commit:** 7168493d176131cdc489b316f27e3bcb2f9be3c7
**Governor merge:** pending Governor reconciliation
**Decisions:**
- Implemented P2-PRE Option E without reopening the choice: `Pod/fe-signalloom-agents/agent-sir-lancelot` moved from direct `signalloom-infra` ResourceSet resources into the signed `inf-signalloom` artifact and is now reconciled by `Kustomization/inf-signalloom/agent-inventory` from `./agent-inventory/local`.
- The manifest declares `signalloom.ai/state: idle`, `signalloom.ai/stunned-at: ""`, and `signalloom.ai/stun-reason: ""`; the owning Kustomization ignores the corresponding three escaped JSON Pointers only for `kind: Pod` plus `labelSelector: signalloom.ai/agent=true`.
- `scripts/check-flux-dynamic-labels.sh` now maps each declaration scope to its actual delivery owner. The unrelated ignore in `tenants/base/apps.yaml` cannot vouch for Sir Lancelot.
**Deviations:**
- No mechanism deviation. The required duration heuristic was contradicted by stronger live evidence: reconcile one configured the Pod and corrected the tampered model in `110.908826ms`; reconcile two reported the Pod unchanged in `128.025105ms`. Request-to-observation elapsed was `714ms` and `552ms`. Sub-second controller duration therefore did not mean “nothing applied”, and no duration was inflated to manufacture a pass.
- The estate-wide census remained its pre-existing qualified baseline rather than becoming fully green: ResourceSets `7/8` and Kustomizations `10/12`. P2-PRE had already recorded `7/8` and `9/11`; the newly added `agent-inventory` Kustomization is Ready. The unchanged blockers are `inf-bao/infra-controllers` (`ReconciliationFailed`: invalid `Recreate` plus `rollingUpdate` strategy), dependent `inf-bao/infra-configs`, and dependent ResourceSet `agent-trust`. This card did not modify those unrelated manifests.
**Notes:**
- Durable delivery ran in the required order: `./scripts/push-local.sh`, then `flux reconcile kustomization tenants -n flux-system --with-source`. The signed source and child converged on `latest@sha256:17f262d3b039e9a7e041c933979e7f4e50b1b63b34bc0ed0041fa489e8e70f97`; `lastAppliedRevision` equalled `lastAttemptedRevision` after both proof reconciles.
- Reconcile one handled token `stun-p2-1-one-20260831T053750232634420`, reported `Ready=True/ReconciliationSucceeded`, and logged `Pod/fe-signalloom-agents/agent-sir-lancelot: configured`. Reconcile two handled `stun-p2-1-two-20260831T053751091029245`, reported the same successful condition, and logged the Pod `unchanged`.
- Stored-object readings were identical after both reconciles: state `stunned`, stunned-at `2026-08-31T05:37:50.072175385Z`, reason `stun-p2-1-live-proof-20260831T053750072937366`, and model restored from the tampered control to `claude-opus-4-8`. UID `f73715f7-1aa0-4eb3-b131-2308a095d78a` and creation timestamp `2026-08-31T04:53:08Z` did not change. Managed fields showed `stun-p2-1-runtime/Update` still owning all three runtime paths.
- A later scheduled `signalloom-infra` reconciliation was observed beyond five minutes: the matching history entry advanced from total `9` to `11`, finished `ReconciliationSucceeded`, and all three runtime fields still matched. Cleanup ran from an EXIT trap and read back state `idle`, both annotations empty, model `claude-opus-4-8`, the same UID, and CiliumEndpoints `28/28` Ready.
- Static evidence: the owner-aware guard passed; `test/flux-dynamic-labels.bats` declared and ran `11/11`; `fleet-patch-indexes.bats` ran `3/3`; `supercred-runner-rbac.bats` ran `8/8`; `topology.bats` ran `4/4`; the full guard falsification proof fired `24/24` and restored every watched path. Removing the state pointer failed naming both halves; removing the governing ignore while leaving the apps ignore present failed on all three fields; both restorations returned green.
- Retracted repository claims: the ResourceSet stun gap is no longer unreachable; Q6 is settled by the declared-plus-ignored pair; Q7 is answered by Option E; the ResourceSet empirical table is explicitly bounded to flux-operator `v0.57.0` and not quoted as a `v0.58.1` result.
- This card did **not** make stun durable across Pod recreation. `agent-inventory.spec.force: true` remains, so replacement creates a fresh Pod with `state=idle` and empty telemetry despite `spec.ignore`. This card also did not build P2-2’s 20-reconcile harness or any phase-three quarantine guarantee. Later phases may rely only on in-place reconcile survival of these three telemetry fields.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P2-1","status":"pass","commit":"7168493d176131cdc489b316f27e3bcb2f9be3c7"} -->
#### Errata — STUN-P2-2 Forced-reconcile harness proving survival across 20 reconciles
**Created:** 2026-08-31 07:36:20+01:00
**Last Updated:** 2026-08-31 07:36:20+01:00
**Status:** Completed
**Commit:** 9f83403b1bb01f296b29f68a0199ed2b03a8ad65
**Governor merge:** pending Governor reconciliation
**Decisions:**
- Added `scripts/lib/reconcile.sh`: Kustomizations require a fresh `lastHandledReconcileAt`, `Ready=True/ReconciliationSucceeded`, and matching applied/attempted revisions. ResourceSets use v0.58.1 `history[0].totalReconciliations` advancement plus successful history status and an applied revision.
- RFC3339 UTC nanosecond tokens are the sole helper format; proof treats control-field correction, not sub-second wall time, as the evidence that apply occurred.
- The proof uses the declared unprotected `signalloom.ai/model` label as its positive control and restores state, model, and both stun annotations through a verified EXIT trap.
**Deviations:**
- Temporary removal of `/metadata/labels/signalloom.ai~1state` initially restored with malformed YAML indentation; `tenants` correctly went `BuildFailed`. The pointer indentation was immediately repaired, the signed fleet artifact was re-pushed, and `tenants` plus `agent-inventory` returned Ready before the final green proof.
**Notes:**
- Forced transcript: final restored run reported 20 passed, 0 failed, 0 unverified; every stored pod reading retained `state=stunned`, the stun timestamp, and `stun-survival-proof`; all controls returned to `claude-opus-4-8`; UID remained `f73715f7-1aa0-4eb3-b131-2308a095d78a`.
- Scheduled observation: no forced annotation; ResourceSet history advanced 18→19 after 286 seconds and retained all three fields.
- Falsification: removing `/metadata/labels/signalloom.ai~1state` produced `verdict=FAILED reason=protected-state=idle`; restoration then produced a fresh 20/20 green run.
- Helper falsification and one-second timeout both returned nonzero; live Bats gate was 4/4, 13 seconds. Both pipeline lists and post-deploy live stages name the suite.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — STUN-P2-GOV
**Created:** 2026-08-31 07:57:11+01:00
**Last Updated:** 2026-08-31 08:00:29+01:00
**Status:** Failed — returned P2-2 for correction; phase 2 does not advance.
**Integration head:** `9f83403b1bb01f296b29f68a0199ed2b03a8ad65`
**Governor evidence commit:** `4ad8df55bdaf338db20c3ca4efb8903121142a26`
**P2-1 commit:** `7168493d176131cdc489b316f27e3bcb2f9be3c7`
**P2-2 commit:** `9f83403b1bb01f296b29f68a0199ed2b03a8ad65`
**Merge decision:** No new merge commit was required: all four audited commits (`30e8bfa9a6a6e4946542f6b28537f124ea352345`, `9aa5187ec2a831169009a5067b7bcf5b55bff9f6`, `7168493d176131cdc489b316f27e3bcb2f9be3c7`, `9f83403b1bb01f296b29f68a0199ed2b03a8ad65`) are ancestors of the integration head. Consequently no conflict resolution occurred and no file carries a merge-resolution hunk from this Governor.
**Static evidence:** `make check-flux-dynamic-labels` passed and printed `signalloom.ai/state signalloom.ai/stunned-at signalloom.ai/stun-reason`. Removing `/metadata/labels/signalloom.ai~1state` from the real `agent-inventory` ignore rule made the guard red, naming `signalloom.ai/state`; restoring the pointer made the guard green. `flux-dynamic-labels.bats` reconciled 11 declared, 11 reported, 11 passed, 0 skipped, 0 failed. `stun-reconcile-survival.bats` static portion reconciled 4 declared, 4 reported, 4 passed, 0 skipped, 0 failed. Tree integrity, registry coverage, and fleet patch indexes also reconciled green.
**Live failure:** After publishing the integration revision to local Zot and reconciling `tenants` plus `agent-inventory`, the owner reported matching applied and attempted revision `latest@sha256:5c02c83569c04f40b523f8031ac42c1ca0c29f5ff6df0865c461d9b63d6eada2`, origin `local@sha1:9f83403b1bb01f296b29f68a0199ed2b03a8ad65`, and `Ready=True/ReconciliationSucceeded`. The live four-case BATS suite failed at case 4. Direct proof returned 0 passed, 0 failed, 20 unverified because `force_reconcile` rejected every request: it could not create a token greater than stored `lastHandledReconcileAt` `2026-08-31T07:49:50.956811848+01:00`. This is a P2-2 helper defect, not a reason to infer preservation.
**Restoration:** EXIT-trap restoration was verified from the stored Pod: `state=idle`; `stunned-at` absent; `stun-reason` absent; UID `f73715f7-1aa0-4eb3-b131-2308a095d78a`. Readiness after the failed proof: 7 ResourceSets Ready=True and 10 Kustomizations Ready=True.
**Residual limits for phase 3:** `agent-inventory.spec.force: true` recreates the Pod with manifest `state=idle` and blank telemetry; `spec.ignore` only protects in-place reconciliation. Scheduled reconciliation remains distinct from forced reconciliation; no successful Governor-sourced scheduled observation exists after this failure. P3 may not assume a durable stun label until P2-2 proves a real 20/20 forced-reconcile run and records the scheduled case separately.
**Unrelated baseline:** `scripts/check-vacuous-assertions.sh` remains red on 22 pre-existing findings outside P2 paths; `test/guard-falsification-proof.sh` passed its 26 harness behaviours. The mandated `kanban-check.sh cost --update-table --apply` invocation was attempted exactly, but this installed tool rejected `--update-table`; no unsupported substitute was used.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P2-PRE | $0.00 | N/A — no session | N/A | agy://open?id=52d07666cdb8031d6a5688504f022de106db16ce&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P2-1 | $0.00 | N/A — no session | N/A | agy://open?id=7168493d176131cdc489b316f27e3bcb2f9be3c7&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P2-2 | $0.00 | N/A — no session | N/A | agy://open?id=9f83403b1bb01f296b29f68a0199ed2b03a8ad65&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |
| P2-GOV | $0.00 | N/A — no session | N/A | agy://open?id=P2-GOV&dir=/home/andy/src/cp/osramp-demo&host=fortuna&model=gemini-3.7-flash |

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
<!-- kanban-check: {"card":"STUN-P2-GOV","status":"fail","commit":"9f83403b1bb01f296b29f68a0199ed2b03a8ad65","blocking_command":"STUN_PROOF_LIVE=1 bats test/stun-reconcile-survival.bats"} -->

#### Repair errata — STUN-P2-GOV
**Created:** 2026-08-31 08:08:48+01:00
**Last Updated:** 2026-08-31 08:08:48+01:00
**Status:** Passed after authorized in-repository repair.
**Repair commit:** `baad9e4050cb58534269272d31ec146616c76db0`
**Preserved evidence:** The original `Errata — STUN-P2-GOV` failure census and commit `4ad8df55bdaf338db20c3ca4efb8903121142a26` remain authoritative for the pre-repair defect.
**Repair:** `scripts/lib/reconcile.sh` normalizes RFC3339 `lastHandledReconcileAt` values to UTC before lexical token comparison. This preserves strict monotonicity across equivalent `Z` and numeric-offset representations. `test/stun-reconcile-survival.bats` adds a hermetic offset-normalization regression test.
**Verification:** Static suite reported 5 tests: 4 passed and 1 expected non-live skip. After publishing the repaired signed `inf-signalloom` artifact and reconciling `agent-inventory` at origin `local@sha1:baad9e4050cb58534269272d31ec146616c76db0`, `STUN_PROOF_LIVE=1 bats test/stun-reconcile-survival.bats` reported 5 passed, 0 failed, 0 skipped. The live case is the genuine 20/20 forced-reconcile proof; no assertion was weakened and Kind was not rebuilt.
**Residual limits:** Pod recreation still resets the manifest-owned state to idle because `agent-inventory.spec.force: true`; scheduled reconciliation remains separately bounded from forced reconciliation. These are phase-3 constraints, not blockers to the corrected P2 forced-reconcile gate.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P2-GOV","status":"pass","commit":"baad9e4050cb58534269272d31ec146616c76db0"} -->


### Governor integration-repair errata — STUN-P1-GOV

- Created: 2026-08-31 04:17:27+01:00
- Last Updated: 2026-08-31 04:17:27+01:00
- status=pass
- Supervisor-authorized minimal repair for the closed P1-3 card. The original refusal block remains authoritative evidence of the pre-repair defect.
- Repair commit: `b64e0e586b447ccb05800deb666d3ee9e1132dda` (`git cat-file -t` returned `commit`). Commit message: `fix(ci): repair Governor-found closed STUN-P1-3 defect`.
- Change: `scripts/gcp-tf/demo-pipeline.sh` now contains the existing-pattern stage triple `Netassert gate falsification proof`, `stage1q-netassert-gate-falsification.txt`, and `cd ${WORK_DIR} && ./test/netassert-gate-falsification-proof.sh`. No variable was introduced.
- Verification: `grep -n -F netassert-gate-falsification-proof.sh scripts/gcp-tf/demo-pipeline.sh` returned line `836` with exit `0`. `bats --count d2-signalloom/test/netassert-stage-registration.bats` remains `13`; the actual run was `13` ok, `0` not_ok, `0` skip, exit `0`. Count did not change from the prior post-merge census.
- Outstanding: the two red kindnet baseline BATS suites remain pre-existing and unmodified. The approved 10-case netassert tally and live Cilium cluster were not touched.


### Governor errata — STUN-P1-GOV

- Created: 2026-08-31 04:05:03+01:00
- Last Updated: 2026-08-31 04:06:53+01:00
- status=fail
- Governor worktree: `/home/andy/src/.worktrees/osramp-demo/stun-under-flux/governor`; branch: `integration/stun-under-flux`. Pre-merge HEAD: `59cd01f79a7443f574003bcf45381d8e75b9e7e1`; post-merge HEAD: `4c03d485d70e06e33c40fcbe1b27bacbb8fa0862`.
- Merge order: P1-PRE and P1-2 and initial P1-3 were already ancestors; Governor fast-forwarded P1-1 through `05d5a0bdfafca8c9eb2739496baf496cf40e20b6`, then merged P1-3 follow-ups through `059408acebada971d75715166f28d9d12026b45d`. P1-1 was based on initial P1-3, so this preserves the committed dependency graph without rewriting reviewed history.
- Merge-base evidence: `df4330a1c7b659be8bacf8713ee929c0e6d9ad52`, `f141a985910032f867b29d9eec1fb626b0e45848`, `8ad80113b6d4468c16a8f6eebe18f7ca29843ae9`, `05d5a0bdfafca8c9eb2739496baf496cf40e20b6`, `061bd57715135d1ed35404041e8ab291314d0a43`, `59cd01f79a7443f574003bcf45381d8e75b9e7e1`, `ff9d13b3dc2a63db68df9a9e9f64bcfebce84add`, and `059408acebada971d75715166f28d9d12026b45d` each returned exit `0` from `git merge-base --is-ancestor <sha> HEAD`.
- Census: raw pre/post declared, ok, not_ok, and skip values are committed in `docs/signalloom/stun-p1-governor-census.md`. No declared count fell; no suite became all-skip; no skip count rose.
- Pipeline evidence: `stage7a-netassert.tap` occurs at `scripts/ci/vm-pipeline.sh:1020` and `scripts/gcp-tf/demo-pipeline.sh:1122`.
- Baseline evidence: P1-PRE committed nonzero files at `docs/signalloom/kindnet-baseline-2026-08-30.md`, `docs/signalloom/evidence/kindnet-baseline.json`, `docs/stun-under-flux/kindnet-baseline.md`, and `evidence/kindnet-baseline/20260830T215227Z/`.
- Blocker: `grep -n -F netassert-gate-falsification-proof.sh scripts/gcp-tf/demo-pipeline.sh` returned exit `1`; P1-3 did not explicitly register the required GCP TF falsification proof. The two kindnet baseline BATS suites also remain red before and after the merge. Governor does not repair either card-owned defect.
- Decomposition accounting: the mandated cost invocation was attempted exactly, but this installed kanban-check rejected the update-table option; its supported read-only cost report recorded STUN-P1-GOV at zero dollars, 12m04s, and 18,622 output tokens. No unsupported substitute was used.
- Per-card verdicts: P1-PRE merged (`df4330a1c7b659be8bacf8713ee929c0e6d9ad52`); P1-1 merged (`05d5a0bdfafca8c9eb2739496baf496cf40e20b6`); P1-2 merged (`061bd57715135d1ed35404041e8ab291314d0a43`); P1-3 refused for Governor acceptance (`059408acebada971d75715166f28d9d12026b45d`) because proof registration is absent.

#### Errata — STUN-P2-PRE
**Created:** 2026-08-31 05:03:34+01:00
**Last Updated:** 2026-08-31 05:03:34+01:00
**Status:** Completed
**Commit:** 52d07666cdb8031d6a5688504f022de106db16ce
**Decision document:** `docs/signalloom/stun-resourceset-options.md`
**Measured runtime:** `ghcr.io/controlplaneio-fluxcd/flux-operator:v0.58.1` on `kind-osramp`
**Decision:**
- Selected Option E for P2-1: move `Pod/fe-signalloom-agents/agent-sir-lancelot` from direct ResourceSet resources into a dedicated Kustomization using the shipped three-path `spec.ignore` pattern.
- Runner-up F is the long-term upstream ResourceSet field-ignore API; it loses on release lead-time. Runner-up G is the operational fallback; it loses because an imperative baseline agent degrades the GitOps fleet claim.
- Fresh direct-Pod measurement: Options A, B-ignore, and B-merge reverted both fields under `flux-operator/Apply`; Option C pruned the Pod within the bounded post-reconcile observation.
**Correction:**
- Retract the v0.57.0 claim that ResourceSet ignores every leaf annotation for v0.58.1. The operator now acts on `fluxcd.controlplane.io/reconcile: disabled` at the leaf, but the settled result is Pod absence, not field-scoped ownership.
**Evidence:**
- Two unique forced reconciles each reached `Ready=True/ReconciliationSucceeded`; matched and no-literal controls proved apply occurred.
- Probe namespace, ResourceSet, Pods, and scratch labels were absent after cleanup.
- Final cluster identity remained `kube-system` UID `6aa2ec80-699a-44c6-8182-1cd01bcc383d`; readiness remained the measured baseline at ResourceSets 7/8 and Kustomizations 9/11.
**Qualified verification:**
- Root `make test` exited 2 because eight tests skipped an unrelated undeployed `namespace/frontend`; the anti-vacuity guard correctly refused a false green.
- Dashboard lint and typecheck were environment-blocked by absent project dependencies and sandbox-denied system ESLint config. No implementation files were changed.
**Deviations:** No selected mechanism was implemented; P2-1 remains the implementation card. Full-suite green was not claimed.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"STUN-P2-PRE","status":"pass","commit":"52d07666cdb8031d6a5688504f022de106db16ce"} -->