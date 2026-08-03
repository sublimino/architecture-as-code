# Cross-vendor adversarial audit — `proposal-stun-under-flux.md`

> Auditor: Cato (OpenAI-family check on Anthropic-family work). Date: 2026-08-03.
> Target: `docs/signalloom/proposal-stun-under-flux.md`
> Evidence base read in full: `stun-under-flux.md`, `_research-ebpf-options.md`,
> `_research-flux-ignore.md`, `agent-security-platform-critique-appendix.md`, plus the live repo
> (`d2-osramp-fleet/tenants/base/apps.yaml`, `d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml`,
> `scripts/check-flux-dynamic-labels.sh`, `test/flux-dynamic-labels.bats`).

## Verdict

**FAIL as written.** Not because the work is wrong — the research underneath it is unusually good — but
because the proposal has drifted away from its own evidence in three load-bearing places:

1. The shipped configuration implements the option the research **falsified with a matched control**, and
   the proposal's second deliverable institutionalises that falsified option as a CI gate that blocks the
   correct fix (F1).
2. The composed control's centrepiece (freeze + conntrack) requires a **privileged `hostPID` node agent**
   that appears in no threat row, no technology row, no milestone and no cost line — while the proposal
   asserts "no new workload" and "£0" (F2).
3. **Freeze-first is not sound as a strict ordering.** The research names the defect that breaks it
   (kubelet restart), and the threat the parent platform exists to counter (exfiltrated credentials,
   in-flight remote tool calls) is precisely the one freeze-first does not touch (F3).

Three CRITICAL, ten MAJOR, three MINOR. Every one is fixable inside the existing scope. My funding
recommendation is at F10: **fund M1–M3, refuse M4–M6 as written**.

Findings are labelled `wrong` (contradicted by evidence), `unproven` (asserted without measurement), or
`phrasing` (I would say it differently). I have not padded — style notes are confined to F16.

---

## F1 — CRITICAL — `wrong` — The shipped fix implements the falsified option, and two deliverables are mutually exclusive

**Text at fault (two places):**

> Reconciler-safe stun fields … **Attainable: both mechanisms already verified working on `kind-osramp`.**

> Static guard against regression | CI check that **no runtime-owned field is re-declared** in
> Flux-managed desired state … *Specific: check fails on a declaration, passes on a `matchLabels` selector.*

**What the evidence says.** `_research-flux-ignore.md`, TEST G with matched control TEST H:

> **The literal must stay in the manifest and be ignored.** Declaring the field and ignoring it is the
> mechanism; deleting the field defeats it.

and, for the undeclared case, six variants A–F all producing the same result:

> `state='stunned'  annotations WIPED`

The inferred mechanism — `.spec.ignore` substitutes the *live* value at each ignored path into the desired
object before applying, so a path the manifest never declares cannot be substituted and is dropped by the
apply — is stated as a hypothesis and then confirmed against a control.

**What is actually committed right now:**

| Artefact | State |
| :--- | :--- |
| `d2-osramp-fleet/tenants/base/apps.yaml:120-127` | three-path `ignore` rule present (label + `stunned-at` + `stun-reason`) |
| `d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml:25` | `signalloom.ai/state` **"DELIBERATELY NOT DECLARED HERE"** |
| `d2-signalloom/`, `d2-osramp-fleet/` | **zero** placeholder declarations for `stunned-at` / `stun-reason` (grepped) |
| `test/flux-dynamic-labels.bats:42` | `@test "FAILS when signalloom.ai/state is declared with a value"` |

So as shipped, the ignore rule protects nothing for the two annotations, and the label is *deleted* rather
than reverted — which the research measured as **strictly worse than the baseline**
(`_research-flux-ignore.md` §8: "§7.2's 'one-line fix' is wrong in its second half … The first option is
measured here to make things *worse* — the label is deleted outright rather than reverted").

**It gets sharper.** `scripts/check-flux-dynamic-labels.sh` already contains its own kill switch, unfired:

> `# … See stun-under-flux.md Q6 for the open question of whether the declaration must also be present for`
> `# annotations to survive pruning — if Q6 resolves toward "declare and ignore", THIS CHECK MUST BE NARROWED`
> `# to allow declarations covered by an ignore rule.`

Q6 has resolved toward declare-and-ignore. The check was not narrowed. And `agents-cardvault.yaml:39-41`
still asserts, verbatim, the claim that `stun-under-flux.md` §7.2 formally retracts:

> `# kustomize-controller v1.9.4 exposes no per-field drift ignore`
> `# (.spec.driftDetection is absent from the CRD; .spec.ignore is source`
> `# paths, not fields), so the only correct fix is to not declare a`
> `# runtime-owned field in desired state at all.`

This is the exact blind spot a same-family reviewer misses: the correction is written beautifully in the
docs, so the reviewer reads the correction and assumes the code follows it. It does not.

**Concrete replacement.**

- Deliverable 1 acceptance: *"All three paths are declared in the manifest with placeholder values **and**
  covered by `spec.ignore` JSON Pointers. Measurable: label and both annotations unchanged after
  `flux reconcile`, verified against a matched control with the ignore rule removed."*
- Deliverable 2 becomes: *"CI check that every runtime-owned field declared in Flux-managed desired state
  is **paired with** a `spec.ignore` JSON Pointer in the owning Kustomization, and that no such field is
  declared without one."* Invert the bats fixtures accordingly.
- Add an M0 task: fix `agents-cardvault.yaml` (re-declare the label, add the two placeholder annotations,
  delete the retracted comment block).
- KPI row 1's Current Value is not "No — reverts to `idle`". It is **"label deleted, both annotations
  wiped on every reconcile"** — a worse starting point than the proposal states.

---

## F2 — CRITICAL — `wrong` — "No new workload / £0" is false; the containment control plane is absent from the threat model

**Text at fault (five places):**

> SWOT Strengths: *Uses primitives already present — **no new CNI, no new workload***
> Technologies: *conntrack | … | **Node-level, already present*** ; *cgroup-v2 freezer | … | **Kernel primitive, no new component***
> Deliverable 1: *Realistic: **no new components required***
> Finances: *None — uses existing local infrastructure and stack | **£0***

**What the evidence says.** `_research-ebpf-options.md` §4, under "Costs, stated honestly":

> A **privileged, `hostPID` DaemonSet** with write access to the node cgroup hierarchy is a **very**
> high-value target. Compromise it and you can freeze or kill any container on any node — **a cluster-wide
> DoS primitive. It needs its own threat model**, tight RBAC, a signed image, and ideally an admission
> policy restricting which pods it may act on.
>
> Build cost: a small privileged DaemonSet plus a watch loop. **Days, not hours** …

`conntrack -D` against a pod IP needs the node network namespace — same delivery vehicle, same privilege
class. Neither primitive is reachable from the existing workload set.

The threat model has ten rows. **None of them is "the containment control plane is compromised."** The
research asked for that row by name and the proposal did not carry it across. Nor did it carry across the
RBAC question the stun path itself raises: the stun's service account needs `patch pods` cluster-wide
*plus* node cgroup write *plus* `NET_ADMIN` — that standing capability set **is** the escalation primitive.
The existing mitigation for row 6 ("Restrict the annotation via admission policy") cannot distinguish the
legitimate stun controller from a stolen stun-controller token.

**Concrete replacement.**

- Add the node agent to the Technologies table and to the Milestones table — it is the M3/M4 critical path,
  not an implementation detail.
- Move "no new workload" out of SWOT Strengths into Weaknesses: *"M4 introduces a privileged `hostPID` node
  agent — a cluster-wide freeze/kill primitive that requires its own threat model, signed image, and
  admission scoping."*
- Replace the Finances line with a real build + security-review estimate.
- Add three threat rows:

| Threat | Impact | Mitigation |
| :--- | :--- | :--- |
| Containment node agent compromised | Cluster-wide freeze/kill of any container on any node | Signed image, admission policy restricting which pods it may act on, node-agent RBAC scoped to the agent label selector, dual control on freeze |
| Stun service-account token stolen | Attacker holds a standing GitOps opt-out plus cluster-wide pod-patch; admission policy cannot distinguish it from the real caller | Short-lived bound tokens, distinct field manager (F7), alert on any stun not correlated to an approved trigger |
| Stun invoked maliciously or on a false positive | Freeze + full network deny is a hard outage of an arbitrary workload; the node agent generalises it cluster-wide | Dual control above a workload-criticality threshold, rate limit, blast-radius cap |

---

## F3 — CRITICAL — `wrong` — Freeze-first is unsound as a strict ordering, and the case it optimises for is not the platform's threat

**Text at fault:**

> Freeze-first containment | cgroup-v2 freeze as the first action of the stun, **halting execution before
> any control the agent could observe and react to.**

> Decision Log: *Freeze first, rather than revoke first | Every other control races a running adversary
> that can observe its own containment; **freezing removes the ability to race***

Five problems, in descending order of seriousness.

**(a) The kubelet undoes it.** `_research-ebpf-options.md` §4:

> A frozen container's **liveness probe will fail**, so the kubelet will restart it and undo the freeze.
> Any real implementation must handle this … **This is unverified and is the first thing to test.**

The M4 acceptance criteria — *"freeze precedes revocation in the audit record; process state is `frozen`"* —
are satisfied in full by a control that self-defeats one `failureThreshold` later. Worse, the restart
**destroys the in-memory forensic state that is freeze's stated advantage** and returns an *unstunned*
process. There is no KPI for freeze persistence anywhere in the proposal.

**(b) Freeze stops userspace, not the kernel.** Bytes the agent has already handed to a socket send buffer
continue to be transmitted after the freeze. The research is precise about the receive side ("the kernel
keeps ACKing until the receive buffer fills"); the proposal generalises this into "cannot respond". The
residual is bounded by unacked send-buffer bytes, not zero.

**(c) "Cannot observe its own containment" is true only in-process.** The parent platform's headline threat
is prompt injection leading to credential exfiltration and downstream misuse. If the SVID or OpenBao token
is already outside the pod, freezing the pod stops nothing — and freeze-first **delays the only control
that works** (revocation). Freeze also *emits* a silence signal that an external watchdog or dead-man's
switch can trigger on. The adversary who matters is out of process; freeze does not reach them.

**(d) Freeze does not stop the in-flight tool call.** For an agent platform the action executes on a
*remote* MCP/A2A tool server. `stun-under-flux.md` §11 item 6 names this — *"Credential revocation does not
close MCP/A2A sessions already established"* — and the proposal drops it from scope, threat model **and**
out-of-scope. For a financial-services buyer this is the decisive gap: the blast radius is downstream of
the pod, and nothing in the composed control touches it.

**(e) Serialisation inverts the availability ordering.** Freeze-first makes the fastest and most reliable
controls (API calls to OpenBao/SPIRE, a label write) wait on the slowest and least available one — a
privileged node-local write, unavailable on GKE Autopilot, EKS Fargate, and any node the DaemonSet is not
scheduled on.

**Where freezing first is *actively wrong*:**

1. **Credential-theft compromise** — (c) above. Revocation must not wait.
2. **False positive on a critical-path workload** — freeze is a hard outage with no graceful degradation;
   network quarantine and credential revocation both degrade. A restart-on-freeze is worse than either.
3. **Agent holds a distributed lock, DB transaction, or Kubernetes Lease** — freeze holds it for the
   duration of the freeze, converting containment of one agent into a self-inflicted outage of a shared
   resource. Revocation fails it fast and releases server-side.

**Concrete replacement.**

- Decision Log entry becomes: *"Dispatch revocation, network deny and freeze **concurrently**, freeze
  carrying the earliest deadline. Nothing waits on freeze — it is the least available control."*
- Acceptance criterion becomes: *"the audit record captures the **achieved** order and per-control latency"*
  — an assertion about what happened, not a precondition asserted in advance.
- Add acceptance: *"the freeze survives N liveness-probe intervals without a container restart"*, and make
  the M3 spike gate M4 on it explicitly.
- Rephrase the claim: *"Freeze removes the agent's **in-process** ability to react. It does not contain an
  adversary operating on exfiltrated credentials, an in-flight remote tool invocation, or an external
  watchdog triggered by the agent's silence."*

---

## F4 — MAJOR — `wrong` — Two claimed properties of the composed control are mutually exclusive

**Text at fault (Appendix B):**

> `kubectl exec` is unaffected by quarantine | Exec succeeded into a fully quarantined pod — **forensic
> access is preserved for free**

**Evidence.** `_research-ebpf-options.md` §5 comparison table, cgroup-freeze column:

> Forensic `kubectl exec` preserved | **No — exec into a frozen cgroup hangs**

The proposal presents free forensic access as a headline measured benefit of the control it is proposing,
while adopting freeze-first as that control's first action. Exec into a frozen cgroup spawns a process that
is immediately frozen.

**The unlisted half.** `pods/exec`, `pods/portforward` and ephemeral containers (`kubectl debug`) all
bypass NetworkPolicy entirely — they traverse apiserver → kubelet → CRI, never the pod network. The same
fact that makes forensics free makes them an **unmitigated interactive C2 and exfiltration channel into a
"quarantined" pod** for anyone holding those verbs. There is no threat row. In a regulated-FS assessment
this is the first residual an assessor asks about.

**Concrete replacement.** Scope the Appendix B row to *"network-quarantine-only mode; destroyed by
freeze-first (measured)"*, and add:

| Threat | Impact | Mitigation |
| :--- | :--- | :--- |
| `exec` / `port-forward` / ephemeral container bypasses the quarantine | Interactive channel in and out of a contained pod, invisible to NetworkPolicy | Deny `pods/exec`, `pods/portforward`, `pods/ephemeralcontainers` on `state=stunned` workloads by admission policy except to a named forensic role; audit-log every exec against a stunned pod |

---

## F5 — MAJOR — `unproven` — Conntrack severing is unmeasured and does not port off netfilter

**Text at fault:**

> Established-connection severing … *Measurable: **stream dies within 5s; without the step it survives past
> 60s.** Attainable: `conntrack -D` against the pod IP. **Realistic: no CNI change.***

> KPI: Established connections surviving a stun | Indefinite (24h conntrack) | **0 beyond 5s**

**What is actually measured** (Appendix B): *"Stream survived **14s+** past the stun"*. Neither the 60s
control figure nor any post-`conntrack -D` figure exists in either research document. **`conntrack -D` is
never executed anywhere in `_research-ebpf-options.md`** — the remedy is proposed but never tested. This is
the proposal's only deliverable with a hard numeric target and no measurement behind it.

**Two mechanism problems the single-node netfilter rig hides:**

1. **`conntrack -D` deletes state; it does not send an RST.** With the deny policy in place the stream
   stalls and retransmits until an application-layer timeout. "Dies within 5s" is a claim about the
   *peer's* observation, not the kernel's, and the probe semantics need stating before the number means
   anything.
2. **It does not port to eBPF dataplanes.** On Cilium the verdict lives in a BPF conntrack map that
   netfilter `conntrack` does not touch. The research names the only lever and its cost
   (`_research-ebpf-options.md` §3.2): `cilium-dbg bpf ct flush` is **node-wide** — *"Flushing to contain
   one agent discards conntrack for every workload on the node."* So on the CNI a regulated bank is most
   likely to run, this step is either a no-op or a node-wide availability event.

**Concrete replacement.** Demote to an M3 spike with its own acceptance: *"measure the effect of
`conntrack -D` on an established stream against a matched no-op control, and record peer-observed
time-to-stall."* Restate the KPI as *"peer observes no further application data within X s of stun"*. Add
to Out of Scope: *"eBPF-dataplane conntrack invalidation — the only available lever is node-wide and is not
adopted."* Change *"Realistic: no CNI change"* to *"no CNI change; requires the privileged node agent (F2)."*

---

## F6 — MAJOR — `wrong` — A whole class of managed object has no fix and is not mentioned

**Evidence.** `_research-flux-ignore.md` §2.6: *"flux-operator ResourceSet — **no per-field ignore exists**,
and annotations are ignored"*, confirmed by server-side dry run:

> `strict decoding error: unknown field "spec.ignore"`

`stun-under-flux.md` Q7 is open: *"The second declaration lives in a flux-operator **ResourceSet**
(`d2-osramp-fleet/tenants/local/signalloom.yaml`) … `spec.ignore` is a Kustomization field, so it does not
apply there. **What protects the inert demo-agent cohort?**"*

The word "ResourceSet" appears **zero times** in the proposal. Deliverable 1 claims "the three paths survive
a forced reconcile" and KPI 1 claims 100% of 20 trials, with no statement that this holds only for
Kustomization-managed objects. And the ResourceSet `reconcileEvery` is **5m** (measured, Q4) — the tightest
revert cadence in the cluster, six times faster than the 30m the Opportunity section quotes as the exposure
window.

**Concrete replacement.** Add to deliverable 1: *"Scope: Kustomization-managed objects only. The
flux-operator ResourceSet path has no per-field ignore mechanism (measured); the ResourceSet-generated
agent cohort is covered by the `reconcile: disabled` escalation or is out of scope."* Add
*"ResourceSet-generated agents"* to Out of Scope, or add a deliverable. Correct the Opportunity table's
"within 30 minutes by schedule" to note the 5m ResourceSet cadence.

---

## F7 — MAJOR — `wrong` — `spec.ignore` removes GitOps as a compensating control against tampering with the quarantine selector

The threat model's first row protects the label *from* the reconciler. It does not model the consequence:
once `/metadata/labels/signalloom.ai~1state` is ignored, **Flux will never correct that field in either
direction**. Anyone with `patch pods` can write `signalloom.ai/state=idle` onto a stunned agent, and the
compensating control that existed before this change — the reconciler noticing — is now configured not to.

Combined with the `NotIn: [stunned]` guard convention, which is a *negative* selector, **one label write
simultaneously drops the deny policy and re-arms every allow policy in the namespace**. The inverse is a
denial of service: writing `stunned` onto arbitrary pods quarantines them, and Git cannot correct it back.

The research already handed over the remedy and the proposal did not take it —
`_research-ebpf-options.md`/`stun-under-flux.md` §10:

> **Actionable regardless of GitOps engine:** the stun should apply with a **distinct field manager name**
> (`kubectl --field-manager=signalloom-stun ...`). **It costs nothing today**, makes ownership legible in
> `managedFields`, and is a precondition for the Argo model.

Note the second-order cost: the proposal ships the Argo CD portability note, whose most valuable row is
`ignoreDifferences.managedFieldsManagers`, **without the one-line change that makes that row usable.**

**Concrete replacement.** Add the field-manager change to M1 (it is free). Add:

| Threat | Impact | Mitigation |
| :--- | :--- | :--- |
| Quarantine selector tampered while under `spec.ignore` | One label write un-quarantines a contained agent or quarantines an arbitrary workload — and drift correction is disabled on that field by design | Restrict `patch pods` on `signalloom.ai/agent=true` via admission policy; alert on any `signalloom.ai/state` transition whose field manager is not `signalloom-stun` |

---

## F8 — MAJOR — `wrong` — `spec.force: true` is live and silently clears stuns; the "owning controller" row does not cover it

**Evidence.** `_research-flux-ignore.md` §2.5: *"`fe-signalloom/apps` has `force: true`. Worth flagging
separately: a failed patch on that pod causes a **delete-and-recreate**, which is a second, independent way
the stun evidence disappears — and a pod restart is visible to the audience."* And §6: *"a freshly created
pod gets the manifest's literal … combined with `spec.force: true` it means **a pod recreation still clears
a stun**."* Independently, `stun-under-flux.md` Q3 records the pod being resurrected by Flux **4 minutes
after a teardown that asserted clean**.

The threat row *"Owning controller recreates the agent | Fresh, unstunned replacement | Apply containment at
the owner, or scale to zero"* is written for a Deployment/ReplicaSet. Here the owner is **Flux plus Git** —
"apply containment at the owner" means a commit (minutes), and a bare Pod has no owner object to scale to
zero. The stated mitigation is not executable for the actual topology.

**Concrete replacement.** Split the row:

| Threat | Impact | Mitigation |
| :--- | :--- | :--- |
| Flux recreates the Pod (`spec.force: true` delete-and-recreate, prune-and-recreate, or post-teardown resurrection) | New pod carries the manifest literal — stun silently cleared, with a pod restart visible to a demo audience | Containment state must be reconstructible from the audit record, not from pod metadata; the stun controller re-applies containment on pod-create for any agent with an open containment event |

That re-apply loop is a real deliverable and is currently unscoped. It is also the strongest argument for
the audit trail (M5) being a *dependency* of the containment control rather than a reporting nicety.

---

## F9 — MAJOR — `unfalsifiable` — Four of seven KPIs cannot fail, or can only be measured where they cannot fail

The parent's critique appendix burned the platform for exactly this class
(`agent-security-platform-critique-appendix.md` B.0 #2 and #6: seeded-estate KPIs, *"Self-graded 'mock
auditor' KPIs are unfalsifiable"*). The pattern is partly repeated one level down.

**"Silent drift-correction events on agent pods, unalerted | 36 observed, 0 alerted | 100% alerted"** —
*vacuous by construction*. Once `spec.ignore` works there are no `configured` verbs on the agent pod, so the
denominator goes to zero and "100% alerted" is true by absence. It also grades your own alert against your
own log grep.
→ *Replace with fault injection: "N injected drift-corrections; 100% detected within X s, measured by a
consumer independent of the alerting rule."*

**"Quarantine defeated by an unrelated allow policy | Yes, silently | No — CI-blocked"** — CI is not a
runtime property. A tenant with `create networkpolicies` in their own namespace defeats the quarantine
without ever touching the repo, and the `NotIn` guard convention is unenforceable in namespaces you do not
own.
→ *Replace with: "No NetworkPolicy **admitted to the cluster** may select a `state=stunned` pod without the
guard — enforced by ValidatingAdmissionPolicy." Scope the CI check honestly as "no policy in this repo".*

**"Un-stun leaving the object unmanaged | Untested failure mode | 0%"** — measured by an automated
stun→un-stun cycle. But the named failure mode is human: `stun-under-flux.md` §13 step 5, *"**This is the
step most likely to be forgotten**"*. A script cannot forget. The KPI is measured in the only environment
that structurally cannot exhibit the failure.
→ *Replace with a detection KPI: "any object in `skipped` state for more than X minutes raises an alert;
MTTD < X."*

**"Containment events surviving label reversion | 0% | 100%"** — Kubernetes Events are TTL'd (kube-apiserver
`--event-ttl`, default 1h) and subject to server-side spam filtering and aggregation. "100%" holds only
inside the TTL. And the parent critique already landed the kill-shot on this deliverable class (B.20: *"the
'attested forensic trail' KPI collapses the moment the record of record leaves the platform into the
customer's **mutable** Splunk/ServiceNow"*) — yet the deliverable says *"Realistic: **no new datastore**"*
and *"Attainable: Events API plus **existing audit path**"* without naming that path or stating whether the
customer can mutate it.
→ *Replace with: "100% of stun/un-stun events present in the immutable store after N days and after a
reconcile that reverts the label; Kubernetes Events are a convenience copy with a stated TTL." **Name the
store and state who can write to it.***

**"Stun survives a forced reconcile | 100% of trials, 20 trials"** — 20 sequential forced reconciles of a
deterministic field-substitution mechanism carry no statistical content, and they do not exercise the real
failure mode: **a reconcile whose apply-set was built before the stun wrote the annotation.**
`reconcile: disabled` is read from the **live** object (`stun-under-flux.md` §9), so a reconcile already in
flight can still correct.
→ *Augment with a race test: "stun issued at randomised offsets within the reconcile window, 100+ trials,
zero reverted stuns." If there is an irreducible window, publish it as a residual rather than a 100%.*

---

## F10 — MAJOR — `scope` — M4–M6 is a different proposal, and the effort table is empty

Every Duration, Consultants, Person-days and Deadline cell in the Milestones table is blank. *"Total
Estimated Effort: to be estimated with team."* Additional costs: *"None … £0."* The parent's commercial
kill-shot was *"Finances are three 'TBD' lines … non-fundable as a commercial proposal"*. This is the same
shape one level down, and F2 shows the £0 is not merely unestimated but wrong.

- **M1–M3** — reconciler-safe fields, committed NetworkPolicy quarantine + guard convention, conntrack
  spike. Coherent, cheap, resting on measured primitives, and directly remediating the parent's weakest
  critiqued claim.
- **M4** — introduces a privileged `hostPID` node agent whose feasibility gate (Q5, RBAC and runtime) sits
  *inside the project* at M3 with **no defined fallback**. The acceptance criteria already hedge it
  (*"Realistic: RBAC and runtime feasibility confirmed at M3"*) while SWOT admits *"cgroup-freeze
  feasibility not yet proven in this environment"*. That is a conditional deliverable presented as
  committed.
- **M5** — audit trail, immutable store, alerting. Different owner, different buyer conversation, and it
  inherits the parent's B.20 kill-shot (F9).

**Would I fund it as written? M1–M3 yes. M4–M6 no** — not because they are wrong, but because M4 commits to
a deliverable gated on an unresolved feasibility question, on an undeclared privileged component, with a £0
cost line and no threat model.

**Concrete replacement.** Split. *This* proposal = M1–M3 + a trimmed M6 (residual-risk statement and parent
errata), with real person-days. A *second* proposal = freeze-first + the privileged node agent + the audit
trail, gated on M3's spike outcome, carrying the node agent's own threat model and a real cost.

**On the TRL label.** *"TRL 2 (Alpha)"* — the ControlPlane proposal template defines no house TRL scale
(grepped: zero occurrences of "TRL"), so the standard reading applies, and under it TRL 2 is concept
formulation with **no** experimental proof. This work has measured experimental results on a live cluster
(TRL 3) and M1–M3 deliver validated components in a lab environment (TRL 4); M4–M6 reach for TRL 5. State it
as *"TRL 3 → TRL 4: measured primitives to a composed, tested control in a lab environment"* — which both
credits the evidence and makes F10's split-the-proposal argument self-evident.

---

## F11 — MAJOR — `wrong` — "The industry has not named this problem" is demolishable in one search

**Text at fault:**

> Press Release: *"**This is a problem the industry has not named.**"*
> SWOT Opportunities: *"Names a defect at the GitOps/incident-response intersection **that the industry has
> not articulated**"*

What a competitor produces in about ninety seconds:

- **Argo CD ships `argocd.argoproj.io/skip-reconcile: "true"`, and incident response is a documented use
  case** — "you made manual changes to fix a production issue and need Argo CD not to revert them."
- **`ignoreDifferences`** (including `jsonPointers` and `managedFieldsManagers`) is the documented mechanism
  for fields legitimately owned outside Git. The proposal's own portability note concedes the direct
  analogue exists — which undercuts the novelty claim two sections later in the same document.
- **AWS Well-Architected DevOps Guidance [AG.SAD.5] "Implement break-glass procedures"** — a named,
  published practice for exactly this conflict.
- **The un-managed-object trap the proposal treats as a novel finding is published guidance:** "monitor
  paused applications so you don't forget to re-enable reconciliation — a fail-open Argo CD app is a silent
  time bomb after the incident closes." So is the drift alert — a Prometheus rule on sustained
  `argocd_app_info{sync_status="OutOfSync"}`.
- **Wiz's Kubernetes incident-response playbook documents the containment pattern itself** — apply a
  deny-all NetworkPolicy to the pod and **remove the pod's labels** — i.e. the same label mutation, carrying
  the same exposure.

A hostile reviewer will land that list and use it to discredit the parts that *are* new. What is genuinely
defensible on this evidence:

1. The **measured** observation that enforcement and evidence have different lifetimes, so the failure
   presents as a *monitoring lie in the dangerous direction* (contained agent reported healthy) rather than
   as a lost fix.
2. The **additive-allow NetworkPolicy trap** silently defeating a quarantine, with the `NotIn` guard
   convention as the remedy. This is the strongest technically novel content in the whole package.
3. `configured` as the machine-readable signature of a reverted containment.
4. The Flux-side measurement that `.spec.ignore` requires **declare-and-ignore**, with a matched control.

**Concrete replacement for the press release paragraph:**

> The GitOps break-glass problem is documented — Argo CD ships `skip-reconcile` for it, and AWS
> Well-Architected names break-glass as a practice. What is not documented, and what we measured, is what
> happens when the reverted field is a *security control's evidence*: the enforcement persists, the evidence
> is erased, and the platform reports a contained agent as healthy. That is a monitoring failure in the most
> dangerous direction, and no published guidance treats it.

That version survives contact with a competitor. The current one does not.

---

## F12 — MAJOR — `wrong` — The argument that kills the pause is not applied to the chosen design

`stun-under-flux.md` §4 rejects `spec.suspend` on three grounds, the third being:

> **A security control whose activation degrades other security controls is not a control; it is a lever for
> the attacker.**

The proposal then adopts (a) `reconcile: disabled`, which un-manages the object **completely** — smaller
blast radius, identical class of defect, and the research's own §9 flags two sharp edges (it also suppresses
pruning, and anyone who can annotate a pod can opt it out of GitOps); and (b) a privileged node agent that
is a cluster-wide freeze/kill primitive (F2). Neither is measured against §4's own test, and "stun as an
availability attack" appears nowhere in the threat model.

**Concrete replacement.** Add a sentence to the `reconcile: disabled` Decision Log entry applying §4's test
explicitly and stating why the residual is accepted (per-object, time-boxed, asserted removed by the
`skipped`→`unchanged` transition). Add the malicious-stun threat row from F2.

---

## F13 — MAJOR — `wrong` — The `~6s` figure has no provenance, and the same metric is simultaneously "Not measured"

**Text at fault:**

> Appendix B: *Label-change re-evaluation works on a running pod | `REACHABLE → BLOCKED` in **~6s**, no restart; reversible*
> KPI: *Time from stun to network denial (new connections) | **Not measured** | < 5s*

The string `~6s` appears **nowhere** in `_research-ebpf-options.md`, `_research-flux-ignore.md` or
`stun-under-flux.md` (grepped across the whole `docs/signalloom/` tree — the only other `6s` hit is an
unrelated `~60s` GCP figure in `ebpf-enforcer-spec.md`). What was measured is **sub-second**:

> `_research-ebpf-options.md` §2.1: *"blocked within the same wall-clock second"*; *"**Enforcement latency:
> sub-second.** Bounded above by 1.0s"* (the probe clock had 1-second granularity because BusyBox `date`
> lacks `%3N`). §5 table: *"Re-evaluates on label change | **Yes, sub-second (verified)**"*.

The ~5s figure in that research belongs to **Cilium**, not kindnet: *"lands at ~5s or more, against the
sub-second figure measured for kindnet in §2.1."*

So the proposal prints a number that does not exist in its evidence base, labels the same metric
"Not measured" eight lines earlier, and sets a target (<5s) that the real measurement beats by an order of
magnitude — while the ~6s it prints would *fail* that target. In a proposal whose SWOT leads with *"Every
claim is measured on a live cluster, not inferred"*, this is the finding most likely to be found by a
reviewer and used to discount everything else.

**Concrete replacement.** Appendix B → *"`REACHABLE → BLOCKED` **sub-second** (bounded above by 1.0s; probe
clock granularity 1s)"*. KPI Current Value → *"sub-second on kindnet (measured); ~5s default on Cilium
(documented)"*. Target → *"< 2s on the deployed CNI, restated per CNI."*

---

## F14 — MAJOR — `wrong` — The validity envelope: what does not survive leaving single-node `kind` + kindnet

The SWOT admits *"Single-node `kind`; multi-node behaviour unvalidated"* in one line, and then the
deliverable table, the Technologies table and the KPIs generalise anyway. Item by item, this is the honest
scope statement:

1. **Sub-second policy re-evaluation — does not generalise.** kindnet's mechanism is specific: nftables +
   **nfqueue to userspace**, verdict per new connection against a live pod informer cache
   (`_research-ebpf-options.md` §1.1, §2.1: *"kindnetd does not compile pod IPs into per-policy nftables
   rules"*). Calico and Cilium compile selectors into rules/identities; Cilium's identity-propagation path
   is measured at "~5s or more". On multi-node, egress is enforced at the source node and ingress at the
   destination, so convergence is a *distribution across N nodes*, not a single number.
   → *"Sub-second on kindnet (nfqueue userspace evaluation); ~5s on Cilium default; unmeasured on
   Calico and managed CNIs; multi-node convergence is per-node and unmeasured."*
2. **Fail-open — a kindnet property, not a NetworkPolicy property.** `queue flags bypass` means killing
   kindnetd silently disables all enforcement cluster-wide (§1.2). **Cilium fails closed** (§3.3). The
   threat row states fail-open as if it were universal.
   → *"kindnet fails open; Cilium fails closed; must be re-established per dataplane."*
3. **Conntrack severing** — F5. Netfilter only, single netns. A multi-node flow has entries in both node
   netns and possibly a kube-proxy NAT entry; one `conntrack -D` on one node is insufficient.
4. **cgroup freeze — impossible on restricted data planes.** A privileged `hostPID` DaemonSet is not
   admissible on **GKE Autopilot, EKS Fargate, or virtual-node/serverless data planes**. That is a live
   constraint for the regulated-financial-services buyer the proposal names as its downstream customer.
   → *"Self-managed and standard managed node pools only."*
5. **`.spec.ignore` semantics — version-bound and mechanism-inferred.** Measured on kustomize-controller
   **v1.9.4** / flux-operator **v0.57.0**, and the declare-and-ignore requirement is an *inferred* mechanism
   (*"Hypothesis: `.spec.ignore` works by substituting the live value at each ignored path"*), not a
   documented contract. It can change across a controller upgrade without notice.
   → *Pin the version in the proposal and add a regression test that runs on controller upgrade.*
6. **NetworkPolicy enforcement at all.** Some managed data planes do not enforce NetworkPolicy without an
   explicit add-on. *"Standard, portable, no new dependency"* in the Technologies table is too strong.

Also worth one line: single-node `kind` keeps all pod-to-pod traffic on one bridge, so **nothing in this
evidence base exercises encapsulation, cross-node NAT, or policy-propagation lag.**

**Concrete replacement.** Add a **"Validity envelope"** subsection under Technical Overview carrying the six
items above verbatim, and repoint the SWOT weakness at it. This costs half a page and converts the single
largest attack surface on the proposal into a strength — it is exactly the *"guaranteed-denial vs
worst-case-residual, per plane"* discipline the parent critique demanded (B.0 #4), applied to CNIs.

---

## F15 — MINOR — `wrong` (omission) — Four remedies the research named are silently absent

- **`--field-manager=signalloom-stun`** (§10) — free, and a precondition for the Argo `managedFieldsManagers`
  row the proposal ships. See F7.
- **Admission block so the workload cannot be readmitted** (§11 item 5).
- **Session revocation at the MCP/A2A gateway** (§11 item 6) — see F3(d). This is the highest-impact of the
  four for a financial-services buyer.
- **Dual control on irreversible steps** (§11 item 8) and the un-stun **gate** (§13 step 1: *"Confirm the
  triggering condition is resolved; dual control; record who and why"*) and step 4 (*"Flush conntrack again
  if any deny-era connections were established"*). The un-stun deliverable carries steps 2, 3, 5 and 6 only.

An omission reads as an oversight to any reviewer who has read the research — and #stefan-prodan and
#tom-cope both will.

**Concrete replacement.** Put the field-manager change in M1 (one line, zero cost). Name the other three in
**Out of Scope** explicitly rather than dropping them, so the reviewer sees a decision instead of a gap.

---

## F16 — MINOR — `phrasing` — "Quietly" is not the right word, and a Flux maintainer is a named reviewer

> Press Release: *"…the reconciler wins — **quietly**, on its own schedule, **with no error raised and no
> status degraded.**"*

"No status degraded" is correct. "Quietly" is not: the signal exists, the proposal's own KPI counts it
(36 `configured` verbs in the controller log), and Flux ships notification-controller Alerts as a
first-class mechanism for surfacing exactly this. As written, a Flux maintainer reads it as a criticism of
Flux rather than of the estate's alerting — and #stefan-prodan is a named reviewer.

**Concrete replacement:** *"…with no error raised and no status degraded. The signal exists —
kustomize-controller logs a `configured` verb per corrected object — but nothing alerts on it, and no
published guidance says it should when the corrected field is a security control's evidence."*

The revised version is a *stronger* claim, because it makes the remedy cheap and the omission systemic
rather than tooling-specific.

---

## Checked and found sound

Recorded for calibration — this is not a weak document, and the failures above are drift from the evidence,
not absence of it.

- **The `.spec.ignore` measurement is better evidence than most proposals carry.** Tests B/C/D include a
  real apply in the same reconcile (correcting `model` while leaving `state` alone), which rules out the
  obvious alternative explanation that the ignore rule merely suppressed the apply. Test H is a matched
  control. Reversibility was verified and the cluster restored.
- **The retraction of the "no per-field ignore" claim is handled honestly** in `stun-under-flux.md` §7.2
  and in the script header — the docs correct themselves in place and name the misreading. (The code and
  CI gate were not updated to match; that is F1, and it does not diminish the intellectual honesty of the
  retraction.)
- **The additive-allow NetworkPolicy trap is the strongest novel content in the package** — measured,
  non-obvious, with a concrete remedy, and not (on my search) published anywhere.
- **The refusal to attribute the intermittent step-2 flake to the pin** (§4, *"It is not: a second harness
  run under the identical pin passed 1/1 clean … they do not need this observation, which is why it is
  reported rather than leaned on"*) is exactly the restraint the parent critique was asking for. Keep it.
- **The decision not to adopt Cilium is well-argued**, and the correction of the parent's *"severs in-flight
  connections including established ones"* claim is correct on the mechanism (verdict cached in the CT map
  on first packet) and should stand as written.
- **"Rotate, do not restore" on un-stun is correct** and correctly reasoned.
- **`configured` as a machine-readable signature of a reverted containment** is a genuinely good, cheap
  detection primitive and survives everything above.

---

## Priority order for remediation

| # | Finding | Why first |
| :--- | :--- | :--- |
| 1 | **F1** | The shipped config does not do what the proposal claims, and CI blocks the fix. Everything else is downstream of getting M1 actually correct. |
| 2 | **F13** | Cheapest to fix, highest credibility cost if found by a reviewer. One number. |
| 3 | **F2** | Determines cost, milestone shape and threat model. Blocks F10's funding decision. |
| 4 | **F3** | Changes the composed control's architecture from a sequence to a parallel dispatch. |
| 5 | **F14** | Half a page; converts the largest attack surface into a strength. |
| 6 | **F11** | One paragraph; the difference between a claim that survives a competitor and one that does not. |
| 7 | F6, F7, F8, F4 | Threat-model and scope completeness. |
| 8 | F9, F10 | KPI falsifiability and the proposal split. |
| 9 | F5, F12, F15, F16 | Remaining. |
