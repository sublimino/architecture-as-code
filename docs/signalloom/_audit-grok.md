# Contrarian audit — `proposal-stun-under-flux.md`

> Auditor: Johannes (GrokResearcher). Date: 2026-08-03.
> Scope: market and novelty claims only. The technical measurements are not in dispute and were not re-tested.
> Method: adversarial prior-art search, primary-source verification, sceptical-buyer simulation.
> Every URL below returned HTTP 200 on 2026-08-03. Findings tagged `[HIGH]` / `[MED]` / `[LOW]`.

---

## Verdict in one paragraph

The engineering is sound and the measurements are the most valuable thing in the document. The
**novelty claim is not survivable** and should be cut before this goes anywhere near a reviewer, let
alone a bank. The problem is thoroughly named — it is named in Flux's own documentation, in Argo CD's
own documentation, in GitLab's public production incident-response runbook, in a CNCF vendor blog from
January 2024, and in an Argo CD issue from 2023 where users say outright that they disable the
reconciler during incidents. What is genuinely un-named is a much narrower thing: the *evidence*
half of the failure, in the specific context of autonomous-agent containment. That narrow claim is
defensible. The broad one is not, and asserting it costs more credibility than the narrow one earns.

---

## 1. Novelty — the claim fails, decisively

> Press release: *"This is a problem the industry has not named."*
> SWOT Opportunities: *"Names a defect at the GitOps/incident-response intersection that the industry has not articulated"*

Both lines are false as written. The strongest counter-evidence, in descending order of damage:

### 1.1 GitLab publishes this exact warning in its production incident-response runbook `[HIGH]`

GitLab's Runway platform documentation, under **"Incident response"** for Kubernetes runtimes, states
that Flux reconciliation *"can undo ad-hoc fixes, preventing mitigation of the incident"* — and
prescribes `flux suspend kustomization` as the first step of any manual mitigation. It further warns
that *"other controllers are still active and may interfere with your changes."*

That is the proposal's core finding, named, published, and operationalised by a public company on its
public docs site.

- https://docs.runway.gitlab.com/runtimes/kubernetes/incident-response/

### 1.2 The remedy is an off-the-shelf, documented Flux feature — with the rationale spelled out `[HIGH]`

Flux's Kustomization documentation says drift ignore rules exist so that *"external controllers or
tools [can] manage certain fields on Kubernetes resources without having those changes reverted by
the kustomize-controller during reconciliation."* The doc gives HPA replicas, external-dns
annotations and VPA resources as worked examples.

`kustomize.toolkit.fluxcd.io/reconcile: disabled` — the proposal's second mechanism — is likewise
documented: the controller *"will no longer apply changes from the source, nor will it prune the
resource,"* and is resumed by setting `enabled` or removing it.

A feature whose documentation opens by explaining the exact problem it solves is, definitionally, a
named problem.

- https://fluxcd.io/flux/components/kustomize/kustomizations/
- https://fluxcd.io/flux/cheatsheets/troubleshooting/

### 1.3 Argo CD has already been through this bug cycle and shipped the fix `[HIGH]`

Argo CD's `ignoreDifferences` originally applied *only* at diff time; the desired state was still
applied as-is during sync, so "ignored" fields were clobbered anyway. `RespectIgnoreDifferences` was
added as a separate sync option to close that. Argo also ships `skip_reconcile`, sync windows,
system-level `resource.customizations.ignoreDifferences.all`, and the ability to ignore any field
owned by a named `managedFields` manager.

In other words: another project hit the "my ignore rule did not actually protect the field" defect
years ago, named it, and fixed it upstream.

- https://argo-cd.readthedocs.io/en/latest/user-guide/sync-options/
- https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- https://argo-cd.readthedocs.io/en/stable/user-guide/skip_reconcile/
- https://argo-cd.readthedocs.io/en/stable/user-guide/sync_windows/
- https://github.com/argoproj/argo-cd/issues/21973 (open, 2025-02-24 — promote skip-reconcile to beta)

### 1.4 Users named the operational consequence in an Argo CD issue in 2023 `[HIGH]`

Issue #13598, opened 2023-05-15 (closed as not planned). Reporters state plainly:

> *"we end up disabling argocd during incidents so that we can make quick changes"*
> *"we can end up fighting against it — it's an unwanted extra entity making changes to production."*

- https://github.com/argoproj/argo-cd/issues/13598
- https://github.com/argoproj/argo-cd/issues/10679 (related: auto-sync on a monorepo is effectively self-heal)
- https://github.com/argoproj/argo-cd/issues/26426 (open: pause reconciliation cluster-wide)

### 1.5 A vendor named the two-loop conflict in January 2024, in a security-policy context `[HIGH]`

Nirmata, **"GitOps and Mutating Policies: The Tale of Two Loops"** (2024-01-03), frames precisely two
competing control loops — the GitOps reconciliation loop and the policy control loop that mutates
cluster state in near-real-time — and asks whether mutation violates GitOps principles. It covers
security mutations specifically (image digest pinning, service-account token mounting, pod security
context defaults).

The proposal's framing ("a reconciler exists to drive live state back to what Git says, and an
incident response exists to change live state *away* from what Git says") is a restatement of the
same structure with a different second loop.

- https://nirmata.com/2024/01/03/gitops-and-mutating-policies-the-tale-of-two-loops/
- https://kyverno.io/docs/installation/platform-notes/ (Kyverno's own Argo coexistence guidance)
- https://github.com/kyverno/kyverno/issues/2234 (2021 — policies constantly OutOfSync under Argo)

### 1.6 The label-driven quarantine deliverable is a shipped CNCF OSS feature from 2024 `[HIGH]`

Falco Talon — Falco's response engine, announced v0.1.0 in 2024 and covered on the CNCF blog in
November 2024 — ships a `kubernetes:label` actionner whose documented canonical use is applying
`quarantine: true` to a pod, plus a committed default-deny NetworkPolicy selecting that label. It also
ships `kubernetes:networkpolicy`, `cilium:networkpolicy`, `calico:networkpolicy`,
`kubernetes:terminate` and `kubernetes:drain`.

That is the proposal's **"Label-driven network quarantine"** deliverable, as open source, two years
earlier.

- https://falco.org/blog/falco-network-security/
- https://falco.org/blog/falco-talon-v0-1-0/
- https://github.com/falcosecurity/falco-talon
- https://www.cncf.io/blog/2024/11/06/why-falcos-new-response-engine-is-a-game-changer-for-open-source-cloud-native-security/

### 1.7 The silent-skip observability gap is an open upstream issue `[HIGH]`

`fluxcd/kustomize-controller#794` — "Feature request: Log skipped objects." Flux v1 logged objects
skipped due to an ignore annotation; v2 does not. The proposal's "silent" characterisation is
correct — and already filed.

- https://github.com/fluxcd/kustomize-controller/issues/794
- https://github.com/fluxcd/kustomize-controller/issues/870 (controller-vs-controller field ownership fight)

### 1.8 Standard practitioner guidance already prescribes the whole remedy `[MED]`

Pulumi's GitOps best-practices post advises building **exclusion lists before turning on auto-sync**,
because Istio, cert-manager and Crossplane legitimately modify resources. The DoD Platform One Big
Bang ADR-0006 documents per-package `driftDetection.ignore` for the same reason, with measured
overhead figures. Flux even added an "incident management" section to its image-automation docs in
February 2021 (PR #871).

- https://www.pulumi.com/blog/gitops-best-practices-i-wish-i-had-known-before/
- https://docs-bigbang.dso.mil/latest/docs/adrs/0006-drift-detection/
- https://github.com/fluxcd/flux2/pull/871

### 1.9 Two facts that are specifically awkward for this document

**ControlPlane's own prior art contradicts the framing.** Matt Turner and Francesco Beltramini
(ControlPlane) presented *Automated Cloud Native Incident Response with Kubernetes and Service Mesh*
at KubeCon EU 2023. I read it: it does **not** name the conflict — it treats GitOps purely as an asset,
*"provid[ing] an audit trail and the ability to automate deployments and responses reproducibly."*
So ControlPlane has published on automated cloud-native incident response and missed this. That is a
fair story to tell ("we said this three years ago and were incomplete"). It is not a story about the
industry's blind spot; it is a story about yours. `[HIGH]`

- https://control-plane.io/posts/automated-cloud-native-incident-response/

**Your named reviewer wrote the remedy.** Stefan Prodan (`#stefan-prodan`, listed as a reviewer on
this proposal) is the Flux maintainer behind the ignore-rules mechanism and maintains a public
`gitops-kyverno` repository demonstrating Flux's coexistence with a mutating policy controller. A
novelty claim that cannot survive its own first reviewer should not be in the press release. `[HIGH]`

- https://github.com/stefanprodan/gitops-kyverno

### 1.10 What I could **not** find — the narrow claim that does survive

I searched issue trackers (Flux, Argo CD, Falco Talon, Kyverno), vendor material, CNCF blogs and
conference archives and found **no** source that:

- joins **AI-agent containment** to **GitOps reconciliation** as a named problem; `[MED — absence of evidence]`
- names the **evidence** half — that the reverted field is also the system's only record that
  containment occurred, so the dashboard reports a contained agent as healthy. Every source found
  names the *enforcement* half ("your fix gets undone"). `[MED — absence of evidence]`

That gap is real and it is the honest core of this work. Note the caveat that a sceptic will
immediately raise: the evidence point is a **specific instance of a general rule the audit
profession already teaches** — mutable object state is unsuitable as audit evidence; audit trails
must be append-only event logs with independent retention. Kubernetes audit-log guidance says this
directly, and DORA/NIS2 evidencing obligations assume it. So it is un-named in the sense that nobody
bothered to write down this particular application of a rule everyone already knows.

**Verdict: un-productised, not unnamed.** Those are different claims and only one of them is true.

---

## 2. Is anyone already selling the remedy?

Short answer: **the components are commodity; the composition is not sold by anyone I could find.**
That is the narrow claim, and it holds.

| Who | What they actually ship | Addresses the reconciler conflict? |
|---|---|---|
| **Falco Talon** (CNCF OSS, free) | `kubernetes:label` → `quarantine: true`; committed default-deny NetworkPolicy; `terminate`, `drain`, `exec`, Cilium/Calico policy actionners | **No.** `[HIGH]` — its issue tracker's only GitOps-adjacent item is #769, about Kubernetes Events not rendering in the Argo CD UI. Nothing on drift, self-heal or reverted labels. It also leaves its own NetworkPolicy behind after the pod is deleted. |
| **Microsoft Agent 365 / Entra Agent ID** (GA 2026-05-01) | "Kill switch" = **blueprint disablement** — blocks token issuance for every agent derived from that blueprint. Conditional Access, continuous risk evaluation, full sign-in audit | **No.** Identity-layer only; never touches a Kubernetes reconciler. Microsoft's own Zero Trust guidance names *"slow revocation and incomplete containment"* as an unsolved problem, and recommends measuring mean-time-to-revoke *including token invalidation* — i.e. already-issued tokens survive. `[HIGH]` |
| **Palo Alto Prisma AIRS 3.0** | Agent artifact scanning, agent red-teaming, runtime detection for memory poisoning / prompt injection / tool misuse; agentic identity provider; scoped identity + gateway policy that can deny an action | **No.** No isolated execution environment documented. `[MED — partly from competitor-authored comparisons]` |
| **Wiz** | Agentless multi-cloud posture, attack-path graph, agentless K8s scanning, optional admission controller | **No.** Posture, not runtime containment. `[MED]` |
| **CrowdStrike Falcon** | Single-sensor EDR + CWPP + container runtime protection; Charlotte AI / IBM ATOM agentic-SOC containment | **No.** Workload-layer, not agent-layer, and not reconciler-aware. `[MED]` |

Market context worth quoting to a buyer, with the caveat that it is vendor-published survey data:
Kiteworks' *Data Security and Compliance Risk: 2026 Forecast* (n=225 security/IT/risk leaders,
10 industries, 8 regions) reports **60% cannot quickly terminate a misbehaving agent**, **55% cannot
isolate an AI system from the broader network**, and **63% cannot enforce purpose limitations** —
a 15-to-20-point gap between governance controls and containment controls. `[MED — single vendor survey,
figures verified against both the vendor's own PDF and its summary article]`

- https://www.kiteworks.com/cybersecurity-risk-management/ai-agent-data-governance-why-organizations-cant-stop-their-own-ai/
- https://www.kiteworks.com/sites/default/files/resources/kiteworks-report-2026-data-security-compliance-risk-forecast.pdf
- https://learn.microsoft.com/en-us/security/zero-trust/sfi/least-privilege-for-ai-agents
- https://learn.microsoft.com/en-us/microsoft-agent-365/admin/capabilities-entra

**The useful evaluation question for an RFP** — worth stealing: *"when you flip the switch, what happens
to an agent mid-tool-call?"* If the answer is "its next call is denied," that is policy blocking, not
termination. The proposal's freeze-first ordering is the correct answer to that question, and is a
better headline than the reconciler story.

---

## 3. Commercial credibility — arguing the sceptical bank buyer's position

I am going to be unkind here because the alternative is being unkind in front of a client.

**"Our containment survives our own reconciler" is not a differentiator. It reads as a changelog entry.**
A bank's security architect parses that sentence as: *it previously did not survive your own reconciler,
you shipped a containment control whose evidence path was broken, and you are now telling me about it.*
The first question is not "how interesting" — it is **"what else did you not test?"** The proposal's own
Threats box already anticipates this ("Auditors reading it as a completeness claim rather than a bounded
control") and then the press release walks straight into it.

**The TRL/audience mismatch is the sharpest commercial risk.** Scope Summary says **TRL 2 (Alpha)**,
explicitly not production, single-node `kind`, cgroup-freeze feasibility unproven. The stated buyer is
regulated financial services. Regulated FS does not buy alpha containment controls; under DORA it buys
*evidence that controls work*, tested continuously, not a one-time demonstration. Publishing a defect
narrative at TRL 2 into that market is a negative-signal trade unless it is framed as research, not product.

**The press release conflates enforcement and evidence, which is the one thing this work exists to
separate.** *"the containment holds — and, critically, the evidence that it holds is not silently erased"*
implies enforcement was also at risk. Per the measured evidence, it was not: the NetworkPolicy keeps
selecting on the label, and the label is what reverted — so enforcement and evidence *both* went. An
architect will ask what was actually enforced during the window and will not get a clean answer from
the current text. Fix the sentence or expect to lose the room on it.

**"Table stakes" is the wrong worry; "why is this a proposal" is the right one.** No architect thinks
reconciler-safe security labels are table stakes — most have never thought about it. But they *will*
think the remedy is table stakes once you describe it, because the remedy is three documented Flux
features and a NetworkPolicy. The gap between "surprising problem" and "obvious fix" is where this
proposal is commercially exposed.

**Where it does land — and it is not the architect.** The buyer for "enforcement and evidence must have
the same lifetime" is the **audit, GRC and model-risk function**, not the security architect. *"Prove to
me, six months later, that agent X was contained at 14:03 on 3 August"* is a DORA Art. 9–12 and NIS2
Art. 21 question with a 12-month retention obligation attached. Retarget the narrative there and it goes
from defensive to compelling.

**Two details a bank's model-risk team will poke:**

- **KPI "Yes, 100% of trials" from 20 trials.** Twenty consecutive passes bounds the failure rate at
  roughly ≤14% at 95% confidence (rule of three). Presenting that as "100%" to a regulated-FS audience
  is exactly the over-claiming the document elsewhere warns against. Either raise n or state the bound.
- **The `reconcile: disabled` escalation is a governance hole the deliverables table does not close.**
  The Threat register correctly names it ("Any principal able to annotate a pod can exempt it from
  governance") and mitigates it with "restrict the annotation via admission policy" — but no admission
  policy appears in the In-Scope deliverables, and the stun controller's service account must retain the
  ability to set it. So the integrity of the containment control depends on a component that is not
  being built. A bank's third-line will find that.

---

## 4. Longevity — the problem is permanent, the *gap* closes within 12 months

**The differentiator has roughly a 12-month shelf life. The problem does not.** These are separable and
the proposal should say so explicitly.

**Closing now, upstream `[HIGH]`:** The Flux 2026 roadmap lists, under **v2.9 (Q2 2026), currently
In Progress**, the item *"Extend Server-Side Apply with field ignore rules"* — under Kustomize
integrations. Upstream Flux is actively widening the exact mechanism this proposal is built on, inside
this proposal's own delivery window. Any bespoke semantics invented on top of `spec.ignore` risk being
superseded before M5 lands.

- https://fluxcd.io/roadmap/
- https://github.com/fluxcd/flux2/discussions/5671 (2026-01-07, maintainer announcement)
- https://github.com/fluxcd/flux2/blob/main/rfcs/README.md (the RFC path if you want to *shape* it rather than route around it)

**Already closed on the Argo side `[HIGH]`:** `ignoreDifferences` (Application + system-level +
`managedFields` manager), `RespectIgnoreDifferences`, `skip_reconcile`, sync windows, server-side diff.
The "Cross-engine portability note" deliverable is documentation of features that already exist —
useful, but it is a research write-up, not a differentiator.

**Never closing, structurally `[MED]`:** A reconciler whose contract is *"live state must equal Git"*
cannot distinguish an unauthorised mutation from a legitimate incident-response override, because the
distinction is semantic and lives outside the reconciler's inputs. No release fixes that. What upstream
will keep doing is making the escape hatches better, more granular, and better documented — which erodes
the *novelty* without erasing the *problem*.

**Strategic read:** anything you build on "Flux does not let you do X" is depreciating. Anything you
build on "here is the tested composition, the un-stun path, the residual-risk statement and the audit
trail with an independent lifetime" is durable, because upstream will never ship that — it is a control,
not a feature. Weight the milestones accordingly: M5 (audit trail) and M6 (adversarial review + residual
risk) are the durable assets. M1 is the perishable one.

There is also a live opportunity here the proposal misses entirely: **file the RFC.** ControlPlane
sponsors Flux, employs the maintainer, and has measured evidence. "Named the problem" is weak.
"Wrote the upstream RFC that closed it" is unassailable, and converts a 12-month differentiator into a
permanent citation.

---

## 5. The uncomfortable question — answered plainly

**Yes. The strongest honest framing is closer to "we found and fixed a design defect in our own demo,"
of a class that the GitOps community has documented for years but that the agent-security community has
not connected to.**

The defect is the composition of two well-known anti-patterns:

1. **Writing runtime-owned state into GitOps-managed desired state without declaring field ownership.**
   Documented in Flux's docs, Argo's docs, Pulumi's best-practice guidance ("build exclusion lists
   *before* turning on auto-sync"), and Big Bang's ADR. This is a first-day GitOps design decision that
   was skipped.
2. **Using mutable object state as the audit record instead of an append-only event log.** Basic audit
   doctrine, and the reason Kubernetes has an audit log at all. `kubectl get` shows what *is*, not what
   *happened*.

The most damning number in the entire document is not the reversion. It is **"36 `configured` events on
one agent pod, none alerted."** The platform's own drift-correction telemetry was firing correctly,
thirty-six times, into a void. The reconciler was not silent. Nobody was listening. That is an
observability finding about Signal Loom, and dressing it as an industry finding will not survive a
reviewer who reads the KPI table.

None of which makes the work low-value. It makes the *claim* wrong-sized.

### The framing that survives contact with a sceptical reviewer

Cut this:

> ~~"This is a problem the industry has not named."~~

Replace with something in this shape:

> GitOps practitioners have documented for years that reconciliation reverts out-of-band changes —
> Flux and Argo CD both ship escape hatches for it, and GitLab's own incident-response runbook warns
> that reconciliation "can undo ad-hoc fixes, preventing mitigation of the incident." What has not been
> documented is what that means when the out-of-band change *is a security containment action against an
> autonomous agent*, and when the field the reconciler reverts is also the only record that containment
> ever happened. We measured it on a live cluster, found thirty-six silent drift-corrections on a single
> agent pod, and are publishing both the measurements and the composition: enforcement in layers the
> reconciler cannot reach, declared field ownership for the layers it can, and an audit trail whose
> lifetime is independent of both.

**Three claims that survive a hostile reviewer:**

1. **Measured, not asserted.** 36 unalerted drift-corrections; 24h conntrack survival of an established
   stream; ~6s policy re-evaluation with no pod restart; `kubectl exec` unaffected by quarantine.
   Nobody else publishes numbers on this. This is the asset.
2. **Enforcement and evidence must have independent lifetimes.** A novel *framing* of a known rule,
   applied to a context nobody has applied it to. Sell the framing, not a discovery.
3. **Nobody ships the composed control.** Falco Talon does the label. Microsoft does the token. Prisma
   does the deny. None of them do freeze-first ordering, un-stun with credential rotation, guard-convention
   CI enforcement, or an audit trail that outlives the state it describes. Falco Talon does not even
   garbage-collect its own NetworkPolicy.

**Kill these:**

- Press release: *"a problem the industry has not named"* — five minutes of searching disproves it.
- SWOT Opportunity: *"Names a defect ... that the industry has not articulated"* — same.
- SWOT Threat: *"A vendor publishes the same analysis first"* — obsolete. GitLab published the
  operational half; Nirmata published the structural half in January 2024. Replace with the real
  threat: **"Flux v2.9 ships extended field ignore rules in Q2 2026 and the mechanism becomes
  commodity."**

**Add this:**

- An honest-provenance line. *"We found this in our own platform"* is already in the press release and
  is the most credible sentence in the document. Lean into it harder, and drop the industry-blindspot
  claim that sits next to it and undercuts it.

---

## Confidence summary

| Claim under audit | Verdict | Confidence |
|---|---|---|
| "The industry has not named this problem" | **False** — named in Flux docs, Argo docs, GitLab runbook, Nirmata (2024-01), Argo #13598 (2023) | `[HIGH]` |
| The agent-containment × GitOps-reconciler intersection is unnamed | **Probably true** — no source found joining them | `[MED — absence of evidence]` |
| The enforcement-vs-evidence-lifetime framing is unnamed | **Narrowly true**, but a known audit rule applied to a new instance | `[MED]` |
| Someone already sells the remedy | **No** — components commodity, composition unsold | `[MED]` |
| Falco Talon already ships label-driven quarantine | **True**, OSS, CNCF, since 2024 | `[HIGH]` |
| No vendor addresses the reconciler conflict | **True as far as searched** | `[MED — absence of evidence]` |
| A bank architect finds it compelling | **No** — reads as a bug fix; retarget at audit/GRC | `[MED — reasoned, not sourced]` |
| Upstream closes the gap within 12 months | **Partially** — Flux v2.9 Q2 2026 extends field ignore rules; the structural conflict is permanent | `[HIGH]` on the roadmap item, `[MED]` on the consequence |
| "Bug in our own demo" is the honest framing | **Substantially yes**, with a genuinely novel framing attached | `[HIGH]` |

## Sources (all verified HTTP 200, 2026-08-03)

**Primary — GitOps projects**
- https://fluxcd.io/flux/components/kustomize/kustomizations/
- https://fluxcd.io/flux/cheatsheets/troubleshooting/
- https://fluxcd.io/roadmap/
- https://github.com/fluxcd/flux2/discussions/5671
- https://github.com/fluxcd/flux2/blob/main/rfcs/README.md
- https://github.com/fluxcd/flux2/pull/871
- https://github.com/fluxcd/kustomize-controller/issues/794
- https://github.com/fluxcd/kustomize-controller/issues/870
- https://argo-cd.readthedocs.io/en/latest/user-guide/sync-options/
- https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- https://argo-cd.readthedocs.io/en/stable/user-guide/skip_reconcile/
- https://argo-cd.readthedocs.io/en/stable/user-guide/sync_windows/
- https://argo-cd.readthedocs.io/en/stable/operator-manual/reconcile/
- https://github.com/argoproj/argo-cd/issues/13598
- https://github.com/argoproj/argo-cd/issues/10679
- https://github.com/argoproj/argo-cd/issues/21973
- https://github.com/argoproj/argo-cd/issues/26426
- https://opengitops.dev/

**Prior art — the problem, named**
- https://docs.runway.gitlab.com/runtimes/kubernetes/incident-response/
- https://nirmata.com/2024/01/03/gitops-and-mutating-policies-the-tale-of-two-loops/
- https://kyverno.io/docs/installation/platform-notes/
- https://kyverno.io/docs/policy-types/cluster-policy/mutate/
- https://github.com/kyverno/kyverno/issues/2234
- https://github.com/stefanprodan/gitops-kyverno
- https://www.pulumi.com/blog/gitops-best-practices-i-wish-i-had-known-before/
- https://docs-bigbang.dso.mil/latest/docs/adrs/0006-drift-detection/
- https://oneuptime.com/blog/post/2026-02-26-how-to-handle-kubectl-edit-vs-gitops-conflicts/view

**Prior art — the remedy, shipped**
- https://falco.org/blog/falco-network-security/
- https://falco.org/blog/falco-talon-v0-1-0/
- https://github.com/falcosecurity/falco-talon
- https://www.cncf.io/blog/2024/11/06/why-falcos-new-response-engine-is-a-game-changer-for-open-source-cloud-native-security/

**Agent containment vendors**
- https://learn.microsoft.com/en-us/microsoft-agent-365/admin/capabilities-entra
- https://learn.microsoft.com/en-us/security/zero-trust/sfi/least-privilege-for-ai-agents
- https://www.kiteworks.com/cybersecurity-risk-management/ai-agent-data-governance-why-organizations-cant-stop-their-own-ai/
- https://www.kiteworks.com/sites/default/files/resources/kiteworks-report-2026-data-security-compliance-risk-forecast.pdf

**ControlPlane prior art**
- https://control-plane.io/posts/automated-cloud-native-incident-response/

**Excluded — did not resolve**
- `https://mt165.co.uk/talks/cloud-native-incident-response-kubecon-eu-23/` — HTTP 403. Same talk is
  available at the control-plane.io link above; cite that instead.
