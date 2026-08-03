# Multi-perspective technical audit — Stun under Flux

> Independent validation of `proposal-stun-under-flux.md` and `stun-under-flux.md` against upstream
> documentation and source. Every finding is traced to a citation; every URL was verified to resolve
> (HTTP 200) before inclusion. Confidence tags: `[HIGH]` confirmed in upstream source or two
> independent sources · `[MED]` one credible source · `[LOW]` inferred.
>
> Auditor: Alex Rivera (GeminiResearcher). Date: 2026-08-03.
> Baseline under test: kustomize-controller v1.9.4 (→ `fluxcd/pkg/ssa` v0.76.1), Kubernetes v1.36.1,
> single-node `kind`, kindnet CNI, flux-operator v0.57.0.

---

## Verdict summary

| # | Assertion under test | Verdict | Severity of gap |
|---|---|---|---|
| 1 | `spec.ignore` excludes a field from drift detection **and** apply | **Partly right; Q6 is a false dichotomy** — the real mechanism is *adopt-or-strip*, and neither candidate fix is correct as stated | Medium — the static guard currently enforces the wrong rule |
| 2 | `reconcile: disabled` read from the live object; suppresses prune | **Correct, confirmed in source** — plus one undocumented side effect the design misses (health checks) | Low, but the missed side effect is load-bearing |
| 3 | NetworkPolicy re-evaluates on label change of a running pod | **Holds on all four CNIs for new connections — but is nowhere guaranteed, and the ~6 s figure is not portable** | Medium — a KPI is written as if it were a spec property |
| 4 | Established connections survive a policy change | **Wrong for Cilium.** Right for Calico, AWS VPC CNI, kindnet | **High — the planned parent-proposal erratum is itself wrong** |
| 5 | NetworkPolicy is allow-only and additive; `NotIn` guard fixes it | **Additivity correct. The guard does *not* fully solve it** — five residual classes | High |
| 6 | ANP/BANP would be a better mechanism | **Yes — and it solves the problem properly at the API level. But ANP/BANP v1alpha1 is the dead branch**; the live API is `ClusterNetworkPolicy` v1alpha2 | **High value — actionable scope correction** |
| 7 | cgroup-v2 freezer is feasible for containment | **Feasible, but the milestone is mis-framed (not an RBAC problem) and a liveness probe destroys the frozen container** | High — breaks "freeze first" on any probed workload |

Two findings are worth the whole audit: **item 4** (the proposal is about to publish an erratum
correcting a claim that was true) and **item 6** (a better mechanism exists, is supported by the CNIs
that matter, and can be tested on the existing `kind` cluster without rebuilding it — unlike the
Cilium option that was ruled out of scope).

---

## 1. `Kustomization.spec.ignore` — drift detection *and* apply, but not the way Q6 assumes

**Verdict: the design's Q6 poses a false dichotomy. Neither "delete the declaration" nor "declare it
with a placeholder" is the correct rule.** `[HIGH]`

### What the mechanism actually is

The path, traced end to end at the exact pinned versions:

`obj.Spec.Ignore` → `applyOpts.DriftIgnoreRules`
([`kustomization_controller.go`:873–891, v1.9.4](https://raw.githubusercontent.com/fluxcd/kustomize-controller/v1.9.4/internal/controller/kustomization_controller.go)),
consumed by `ssa.ResourceManager.Apply`
([`manager_apply.go`, ssa v0.76.1](https://raw.githubusercontent.com/fluxcd/pkg/ssa/v0.76.1/ssa/manager_apply.go)).
The field doc is explicit that this is an *apply-side* option, not only a diff option:

> `DriftIgnoreRules` defines a list of JSON pointer ignore rules that are used to **remove specific
> fields from objects before applying them**.

`Apply()` then does two distinct things with the compiled rules:

1. **Drift gate.** `hasDriftedWithIgnore` strips the ignored paths from deep copies of *both* the live
   object and the dry-run object before comparing. If the ignored path is the *only* difference, the
   object is not considered drifted, `Apply` returns `UnchangedAction`, and **no apply request is
   issued at all**. Nothing can be pruned because nothing is sent.

2. **Payload rewrite, when an apply does happen for some other reason.** `computeDriftedPaths` walks
   each ignored path and picks one of two actions per path:

   - `driftStrip` — remove the path from the payload, **iff another field manager with
     `operation: Apply` owns it** (`isFieldOwnedByOtherApplyManager`, gated by
     `parseManagedFieldsApply`, which skips every entry where
     `mf.Operation != metav1.ManagedFieldsOperationApply`);
   - `driftAdopt` — **replace the payload value with the live in-cluster value**, when Flux is the
     sole Apply owner.

   The in-source rationale is the answer to Q6 verbatim:

   > For each drifted ignored field, either strip it from the payload (when another Apply manager owns
   > it) or adopt the in-cluster value (when Flux is the sole owner) **to avoid API errors and silent
   > value corruption**.

### Consequences for the design

- **The field may stay declared, and declaring it is safe.** A stun applied with `kubectl label` /
  `kubectl annotate` uses `operation: Update` (managers `kubectl-label` / `kubectl-annotate`), not
  `Apply`. `parseManagedFieldsApply` therefore never sees it, `isFieldOwnedByOtherApplyManager`
  returns `false`, and the `driftAdopt` branch fires: **the runtime value is copied into Flux's own
  payload and re-applied**. The stun value survives *and* Flux retains ownership. It is not pruned.
  `[HIGH]`
- **`scripts/check-flux-dynamic-labels.sh` currently enforces the wrong rule.** It requires the
  declaration be deleted. With an `ignore` rule present, deleting the declaration is unnecessary, and
  it removes the placeholder that makes the field's existence legible in git. Recommend inverting the
  check: *a runtime-owned path must be covered by an `ignore` rule*, and the declaration is optional.
- **§10's "apply the stun with a distinct field manager" recommendation silently changes the code
  path.** If the stun switches to `kubectl apply --server-side --field-manager=signalloom-stun`, it
  becomes an *Apply* manager, `driftStrip` fires instead of `driftAdopt`, and Flux removes the path
  from its payload entirely. The outcome is still correct (the other manager holds the field), but it
  is a different branch with different failure modes and must be tested separately. The advice is good;
  the analysis behind it is incomplete. `[HIGH]`
- **The literal Q6 question — "drift correction only, or also pruning?" — has no single answer.**
  It is neither. When the ignored path is the only difference, no apply is issued (nothing to prune).
  When an apply is issued, `driftAdopt` explicitly exists to prevent the prune-and-corrupt outcome
  Q6 fears.

### Where the design's contrary evidence probably comes from

The supporting evidence that "annotations are wiped on reconcile unless declared with placeholder
values" is inconsistent with the source above. Three discriminating explanations, in order of
likelihood:

1. the `ignore` rule did not match — RFC 6901 escaping (`~1` for `/` in
   `signalloom.ai~1state`) or a `target` selector that does not select the pod;
2. the observation predates the `ignore` rule being applied at all;
3. the write that got wiped went through the **ResourceSet**, not the Kustomization — see below.

The decisive test the design already proposes is the right one. Add one assertion to it: check
`.metadata.managedFields` for a `kustomize-controller` entry with `operation: Apply` covering the
path. If `driftAdopt` fired, that entry is present *and* carries the runtime value.

### Portability

- `spec.ignore` is recent. Estates on older kustomize-controller get nothing — there is no fallback
  and no graceful degradation, the field is simply rejected by the CRD schema. Any published guidance
  must state a Flux version floor. `[HIGH]`
- **Q7 is confirmed and is worse than the design suggests.** `ignore` is a field of `Kustomization`
  only ([Kustomize API v1 reference](https://fluxcd.io/flux/components/kustomize/api/v1/), `IgnoreRule`
  appears on `KustomizationSpec` and nowhere else). The second declaration in
  `d2-osramp-fleet/tenants/local/signalloom.yaml` is a flux-operator **ResourceSet**, which has no
  equivalent field. For that path only `reconcile: disabled` is available — the whole-object
  escalation, with all of its costs. This is a structural asymmetry in the design, not a gap to be
  closed. `[HIGH]`

---

## 2. `kustomize.toolkit.fluxcd.io/reconcile: disabled` — correct, plus one missed side effect

**Verdict: correct on every stated point, confirmed in source rather than inferred. One material side
effect is absent from the design.** `[HIGH]`

### Confirmed: read from the live object

[`manager_apply.go`, ssa v0.76.1](https://raw.githubusercontent.com/fluxcd/pkg/ssa/v0.76.1/ssa/manager_apply.go),
`shouldSkipApply` checks **both** the rendered desired object and the live object:

```go
if utils.AnyInMetadata(desiredObject, opts.ExclusionSelector) ||
   utils.AnyInMetadata(existingObject, opts.ExclusionSelector) {
        return true, m.changeSetEntry(source, SkippedAction)
}
```

with the selector populated at
[`kustomization_controller.go`:860–863](https://raw.githubusercontent.com/fluxcd/kustomize-controller/v1.9.4/internal/controller/kustomization_controller.go)
as `{reconcile: Disabled, ssa: Ignore}`. `AnyInMetadata` matches labels *or* annotations, which is why
the [Flux docs](https://fluxcd.io/flux/components/kustomize/kustomizations/#suspending-and-resuming)
say "annotate **or label** the resource in-cluster". The stun's imperative annotation is honoured
without any pre-provisioning. Design claim upheld.

### Confirmed: pruning is suppressed

Traced, not taken on faith. `deleteObjects` (v1.9.4) sets:

```go
Exclusions: map[string]string{
    ".../prune":     "disabled",
    ".../reconcile": "disabled",
    ".../ssa":       "ignore",
}
```

and `ResourceManager.Delete`
([`manager_delete.go`, ssa v0.76.1](https://raw.githubusercontent.com/fluxcd/pkg/ssa/v0.76.1/ssa/manager_delete.go))
short-circuits to `SkippedAction` on `AnyInMetadata(existingObject, opts.Exclusions)`. Matches the
docs: *"the controller will no longer apply changes, nor will it prune the resource."*

The design's stated risk — object stays unmanaged if the annotation is not removed at un-stun — is
real and correctly identified.

### Missed side effect: the object drops out of health checks

Not in the design's threat model, and it changes the operator experience during an incident:

> `// We should not check the health of skipped objects, as they are chosen to be ignored by the user`
> `// and may not be in a healthy state.`
> — `kustomization_controller.go`:1008–1016, which builds `changeSetWithoutSkipped` and passes only
> that to the health checker.

A `reconcile: disabled` pod is a `SkippedAction` and is therefore **excluded from the Kustomization's
health evaluation entirely**. The Kustomization goes `Ready=True` while holding a quarantined,
unmanaged, possibly-crashlooping pod. This is the mechanism behind the design's own
"Flux reports Ready" risk row — worth naming explicitly, because it means the *absence* of a health
signal is expected behaviour rather than a bug to chase.

**Recommendation:** the un-stun assertion should not be `skipped`→`unchanged` alone. Add a check that
the object reappears in the health-check set, which is the only signal that management genuinely
resumed.

### Additional note

`kustomize.toolkit.fluxcd.io/ssa: Ignore` sits in the *same* exclusion maps as `reconcile: disabled`
for both apply and delete, and additionally in `IfNotPresentSelector`. The research doc's §5 table
treats `ssa: ignore` as a distinct, narrower option ("one object, drift ignored"). At v1.9.4 it is
not narrower for these purposes — both land on `SkippedAction`. The table overstates the difference.

---

## 3. NetworkPolicy re-evaluation on label change of a running pod

**Verdict: holds on all four CNIs for *new* connections, but is not guaranteed by any specification,
and the measured latency is a kindnet artefact that must not be promoted to a KPI.** `[HIGH]`

### The specification says less than the design assumes

The Kubernetes NetworkPolicy API is declarative and selector-based; there is no language anywhere
binding a pod's policy set at admission time, so an implementation that ignored a label change on a
running pod would plainly be non-conformant for new connections. That much is safe. `[MED]`

But the docs are explicit that anything touching *in-flight* traffic is out of scope, and the sentence
covers label changes, not just policy changes
([Kubernetes NetworkPolicy — "NetworkPolicy's impact on existing connections"](https://kubernetes.io/docs/concepts/services-networking/network-policies/)):

> When the set of NetworkPolicies that applies to an existing connection changes — this could happen
> either due to a change in NetworkPolicies **or if the relevant labels of the namespaces/pods
> selected by the policy (both subject and peers) are changed in the middle of an existing
> connection** — **it is implementation defined** as to whether the change will take effect for that
> existing connection or not. […] **It is recommended not to modify policies/pods/namespaces in ways
> that might affect existing connections.`**

The design's central mechanism is precisely the practice the upstream docs recommend against. That is
not a reason to abandon it — it is a reason to state the dependency loudly and to test it per CNI,
because upstream has explicitly declined to guarantee it.

### Per-CNI behaviour for new connections

| CNI | Re-evaluates on label change? | Path | Latency character |
|---|---|---|---|
| kindnet / kube-network-policies | Yes | nftables resync (`table inet kindnet-network-policies`) | periodic sync; the observed ~6 s is a resync-interval artefact |
| Calico | Yes | Felix watches endpoint labels, recomputes selectors, reprograms chains | node-local, sub-second typical `[MED]` |
| Cilium | Yes — **via identity change** | label change → security identity re-resolved → endpoint `waiting-for-identity` → `regenerating` → `ready` ([Endpoint Lifecycle](https://docs.cilium.io/en/stable/security/policy/lifecycle/)) | involves cluster-wide identity allocation; slowest and most variable |
| AWS VPC CNI | Yes | Network Policy **Controller** resolves policies into `PolicyEndpoints` CRs; the agent derives from those ([agent README](https://raw.githubusercontent.com/aws/aws-network-policy-agent/main/README.md)) | adds a full control-plane round trip |

### Sharp edge specific to Cilium

On Cilium a label change is not a policy-selector change, it is an **identity change**. Adding
`signalloom.ai/state=stunned` mints a *new* security identity for that pod. Two consequences the
design does not consider:

- during the `waiting-for-identity` → `regenerating` window the endpoint's policy is in flux; the
  containment is not atomic;
- the new identity is evaluated against *all* policies. If any existing policy's selector happens to
  match the new label set more permissively, the stun can widen access rather than narrow it. On the
  other CNIs a label change is a selector re-match; on Cilium it is an identity re-derivation, and
  those are not the same operation. `[MED]`

### Recommendation

Reword the KPI. "Time from stun to network denial (new connections) < 5 s" is not achievable as a
portable guarantee — it is a per-CNI, per-configuration measurement. State it as a measured value with
the CNI named, and add a conformance probe to the harness that measures it rather than asserting it.

---

## 4. Established connections survive a policy change — **wrong for Cilium**

**Verdict: the strongest finding in this audit. The design and the parent proposal are each wrong, in
opposite directions, about the same CNI.** `[HIGH]`

The research doc §11 states: *"Verified: established connections survive a network quarantine with a
24-hour timeout, on kindnet **and Cilium**."* The proposal's SWOT lists as an opportunity: *"the
parent's 'severs in-flight connections' is already wrong"*, and M6 commits to raising an erratum
against it.

**The parent proposal's claim is correct for Cilium. The erratum, as scoped, would introduce an error
rather than fix one.**

### Cilium: policy IS re-evaluated on established connections

From [`bpf/bpf_lxc.c`](https://raw.githubusercontent.com/cilium/cilium/main/bpf/bpf_lxc.c) — the
egress (from-container) path, `handle_ipv4_from_lxc` and `handle_ipv6_from_lxc`:

```c
/* Apply network policy: */
switch (ct_status) {
case CT_NEW:
case CT_ESTABLISHED:
        ...
        verdict = policy_can_egress4(ctx, tuple, l4_off, SECLABEL_IPV4,
                                     *dst_sec_identity, &policy_match_type, &audited,
                                     ext_err, &proxy_port, &cookie);
```

`CT_ESTABLISHED` **falls through into the same policy evaluation as `CT_NEW`**. Cilium evaluates the
policy verdict on every packet of an established flow, not just on the first. The ingress path
(`__tail_handle_ipv4` → `policy_can_ingress4`) reaches the same verdict call through its `default:`
branch, which likewise covers established status.

Cilium does not need a conntrack flush because it never trusts the conntrack entry as an authorisation
decision in the first place. Confirming the same conclusion from the other side: Cilium's only
CT-scrubbing call, `scrubIPsInConntrackTable`, is gated on `if !e.ctCleaned` — it runs on an endpoint's
**first ever regeneration**, i.e. at endpoint creation, not on policy change
([`pkg/endpoint/bpf.go`](https://raw.githubusercontent.com/cilium/cilium/main/pkg/endpoint/bpf.go)).
If policy were only applied at CT_NEW, that would leave every established flow permanently
un-revocable, which is plainly not Cilium's security model.

**Exceptions where a Cilium flow would survive** — and these are the likely explanation for the
contrary measurement:

- **hairpin / loopback flows.** The policy switch explicitly `break`s out before the verdict for
  `hairpin_flow`, and again for `ct_state->loopback` under `ENABLE_PER_PACKET_LB`. A pod reaching
  itself, or reaching itself via a Service ClusterIP, is not policy-enforced.
- **L7-proxy-redirected flows** (`proxy_port > 0` under `ENABLE_L7_LB`) break before the verdict and
  are handled by the proxy instead.
- **The endpoint was not actually selected by the policy** — the most probable cause, given item 3's
  identity-change subtlety.
- **`installNoConntrackIptablesRules`** and `hostNetwork` pods with `no-track-host-ports` take
  different paths entirely
  ([tuning docs](https://raw.githubusercontent.com/cilium/cilium/main/Documentation/operations/performance/tuning.rst)).

### Calico: survives — confirmed in source

[`felix/rules/endpoints.go`, `appendConntrackRules`](https://raw.githubusercontent.com/projectcalico/calico/master/felix/rules/endpoints.go):

```go
// Allow return packets for established connections.
rules = append(rules,
    generictables.Rule{
        Match:  r.NewMatch().ConntrackState("RELATED,ESTABLISHED"),
        Action: allowAction,
    },
)
```

This is emitted at the **head of every workload endpoint chain**, terminally, ahead of any policy
rule. Policy is never consulted for an established flow. Calico severs nothing on policy change. The
same pattern appears in the static forward chains
([`felix/rules/static.go`](https://raw.githubusercontent.com/projectcalico/calico/master/felix/rules/static.go)),
including an nftables flow-offload variant whose comment notes *"the per-workload dispatch chains
terminally accept established traffic"*. `[HIGH]`

### AWS VPC CNI: survives — by design

The agent maintains **its own eBPF conntrack cache**. Its cleanup knob,
`conntrack-cache-cleanup-period` (default 300 s), is documented as:

> Network Policy agent maintains a local conntrack cache. This configuration (in seconds) will
> determine how fast the local conntrack cache should be cleaned up from **stale/expired** entries.
> Based on the time interval set, network policy agent checks every entry in the local conntrack cache
> with kernel conntrack table and determine if the entry has to be deleted.

Invalidation is keyed on staleness relative to the kernel table, **not on policy change**. Established
flows continue. `[HIGH]`

### kindnet: survives

nftables with the same conntrack-accept model. Consistent with the measurement.

### Corrected picture

| CNI | Established flow survives a deny? | Flush required? |
|---|---|---|
| kindnet / kube-network-policies | Yes | Yes |
| Calico (iptables & nftables) | Yes | Yes |
| AWS VPC CNI | Yes | Yes |
| **Cilium** | **No — cut at next packet** | No (harmless, redundant) |

### Second-order defect in milestone M3

M3 specifies `conntrack -D` against the pod IP. That command manipulates the **node's netfilter
conntrack table**. It does not touch:

- **Cilium's BPF CT maps** — a separate datapath structure; the netfilter table may not even be
  populated for pod-to-pod traffic under kube-proxy replacement. (Moot for severing, since Cilium
  severs anyway, but it means the M3 *assertion* would pass for the wrong reason.)
- **the AWS agent's local eBPF conntrack cache** — flushing the kernel table does not invalidate the
  agent's cache, and the agent's own cleanup is what governs. `conntrack -D` alone may not sever on
  EKS.

So the M3 deliverable as written is correct only for Calico and kindnet. Restate it as a per-CNI
capability with a named mechanism for each, and make the long-lived-stream probe part of the
acceptance criteria rather than a one-off measurement.

---

## 5. Allow-only and additive — correct; the `NotIn` guard is necessary but not sufficient

**Verdict: additivity is correct. The guard convention leaves five residual classes, two of which are
exploitable by an ordinary namespace user during an incident.** `[HIGH]`

Additivity is confirmed by the API semantics: NetworkPolicy contains no deny primitive; a pod becomes
isolated for a direction when at least one policy selects it, and the permitted set is the **union** of
all allow rules across all selecting policies
([Kubernetes NetworkPolicy docs](https://kubernetes.io/docs/concepts/services-networking/network-policies/)).
Any additional allow can only widen. The measured `BLOCKED → REACHABLE` result is exactly what the API
mandates.

### Residual cases the `NotIn: [stunned]` guard does not close

1. **A policy created after the stun.** The guard is enforced by a static CI check —
   a build-time gate. Nothing prevents `kubectl apply` of an unguarded allow policy while the
   quarantine is live. Any principal with `create networkpolicies` in that namespace defeats the
   containment in one command, silently, with no error. **This is the largest hole and CI cannot close
   it.** Closing it requires admission enforcement (ValidatingAdmissionPolicy or Kyverno) — a different
   deliverable from the one in M2.
2. **CNI-native policy types outside the check's scope.** `CiliumNetworkPolicy`,
   `CiliumClusterwideNetworkPolicy`, Calico `NetworkPolicy` / `GlobalNetworkPolicy` are separate APIs
   that also grant allow and would carry no `NotIn` guard. Cilium's own documentation warns that
   running multiple policy types concurrently makes the effective allow-set hard to reason about
   ([Cilium network policy docs](https://raw.githubusercontent.com/cilium/cilium/main/Documentation/network/kubernetes/policy.rst)).
   A static check over `networking.k8s.io/v1` NetworkPolicy sees none of them.
3. **`ipBlock`-based allows.** These do not select by label at all, so a `NotIn` guard on a
   `podSelector` has nothing to attach to. An egress allow to `0.0.0.0/0` minus private ranges is a
   routine, legitimate-looking policy that fully defeats an egress quarantine and cannot be expressed
   as guarded. On Cilium there is a further wrinkle: `ipBlock` does not match intra-cluster IPs unless
   `--policy-cidr-match-mode` is set to `pods`/`nodes`, so the same manifest behaves differently
   across CNIs.
4. **A policy in another namespace.** Worth stating precisely, because the design's framing is
   imprecise. NetworkPolicy is namespaced and `podSelector` selects only within its own namespace, so a
   foreign-namespace policy **cannot** subject the stunned pod and cannot widen its egress. It *can*
   name the stunned pod as a *peer*, widening the counterparty's side of a flow — which matters for
   ingress-to-a-third-party but not for containing the agent's own egress. The guard's true scope is
   therefore "every allow policy in the stunned pod's namespace" — enforceable only where you control
   that namespace's admission path.
5. **AdminNetworkPolicy / ClusterNetworkPolicy `Allow` in the Admin tier.** *"Users cannot block
   traffic which has been matched by an 'Allow' rule in an AdminNetworkPolicy"*
   ([API spec](https://network-policy-api.sigs.k8s.io/reference/spec/)). An Admin-tier Allow overrides
   the quarantine outright and no NetworkPolicy — guarded or not — can counter it. Symmetrically, this
   is the door that item 6 walks through.

**Net:** the guard convention materially reduces the surface and is worth keeping. Describing it as
*the* mitigation for "quarantine silently defeated by an unrelated allow policy" overstates it. It is
a lint, and a lint is not a control.

---

## 6. AdminNetworkPolicy — yes, and this is the most valuable correction available

**Verdict: the right mechanism, for exactly the reason the design suspects. But ANP/BANP v1alpha1 is
the *dead branch* — the live API is `ClusterNetworkPolicy` v1alpha2. Adopting ANP v1alpha1 now would
be building on a deprecated surface.** `[HIGH]`

### It solves the additive-defeat problem properly

Two guarantees, both from the API definition rather than from convention
([API overview](https://network-policy-api.sigs.k8s.io/api-overview/),
[API spec](https://network-policy-api.sigs.k8s.io/reference/spec/)):

> **Tiers.** Policy tiers are evaluated in the following order: `Admin` tier → NetworkPolicy tier →
> `Baseline` tier. […] The `Admin` tier will help administrators set strict security rules for the
> cluster, i.e. **a developer CANNOT override these rules by creating NetworkPolicies** that apply to
> the same workloads.

> **Deny.** Matching traffic will be denied **before** being checked against NetworkPolicy or
> BaselineAdminNetworkPolicy rules. **Pods will never receive traffic which has been matched by a
> "Deny" rule.** […] Those traffic restrictions can only be lifted once the Deny rules are deleted,
> modified by the admin, or overridden by a higher priority rule.

A quarantine expressed as an **Admin-tier `Deny` selecting `signalloom.ai/state=stunned`** eliminates
residual classes 1, 3 and 4 from item 5 outright, and — on Cilium — class 2 as well:

> Rules in the Admin tier take precedence over all policies at the NetworkPolicy tier level,
> **including CiliumClusterwideNetworkPolicy, CiliumNetworkPolicy, and standard NetworkPolicy
> resources and cannot be overridden by them.**
> — [Cilium network policy docs](https://raw.githubusercontent.com/cilium/cilium/main/Documentation/network/kubernetes/policy.rst)

That is a strictly stronger guarantee than the `NotIn` guard, obtained from the API rather than from a
convention that every future policy author must remember and a linter must police. **It also removes
the need for the guard on NetworkPolicy entirely** — which retires an entire milestone's worth of
static-analysis tooling (M2's guard-convention enforcement).

What it does **not** solve: who may create an Admin-tier `Allow` (residual 5 inverts into a new
privilege that needs admission control), and node-local / `hostNetwork` bypass (unchanged).

### Maturity — the trap

As of [network-policy-api v0.2.0, released 2026-04-21](https://github.com/kubernetes-sigs/network-policy-api/releases/tag/v0.2.0),
the project's own site classifies `AdminNetworkPolicy` and `BaselineAdminNetworkPolicy` (v1alpha1)
under **"Previous (APIs that have evolved to the next stage and are no longer actively developed)"**.
The active API is **`ClusterNetworkPolicy` (v1alpha2)**, which merges ANP and BANP into a single kind
carrying a `tier: Admin | Baseline` field.

It remains **v1alpha2** — alpha, out-of-tree CRD, installed separately, no GA date. This is not a
stable foundation; it is the right direction with real version risk.

### Support matrix

From [`site-src/implementations.md`](https://raw.githubusercontent.com/kubernetes-sigs/network-policy-api/main/site-src/implementations.md)
(upstream's own list, updated 21-April-2026), cross-checked against vendor docs:

| Implementation | ANP/BANP v1alpha1 | ClusterNetworkPolicy v1alpha2 |
|---|---|---|
| kube-network-policies (used by kindnet) | Yes | Yes |
| Calico | Yes (standard fields; `Networks` peer experimental in v3.29–3.31) | **Yes — standard support in v3.32** |
| OVN-Kubernetes | Yes (+ Nodes/Networks experimental) | not listed |
| Antrea | Yes (standard fields) | not listed |
| Kube-OVN | Yes (standard fields) | Experimental |
| **Cilium** | **No — [tracking issue #23380](https://github.com/cilium/cilium/issues/23380) only** | **Yes — Cilium 1.20+, opt-in** |
| AWS VPC CNI | not listed | **Yes** — documented with `tier: Admin` in the [EKS user guide](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html) |

Cilium's support is off by default and requires two steps
([Cilium docs](https://raw.githubusercontent.com/cilium/cilium/main/Documentation/network/kubernetes/policy.rst),
[`values.yaml`](https://raw.githubusercontent.com/cilium/cilium/main/install/kubernetes/cilium/values.yaml)
shows `k8sClusterNetworkPolicy.enabled: false`):

```
--enable-k8s-cluster-network-policy=true    # or k8sClusterNetworkPolicy.enabled=true
kubectl apply -f .../policy.networking.k8s.io_clusternetworkpolicies.yaml   # CRD, installed separately
--policy-cidr-match-mode=pods,nodes         # required for full conformance
```

**Cilium never shipped ANP v1alpha1 and went straight to CNP v1alpha2.** Anyone who builds on ANP
v1alpha1 gets a design that cannot run on Cilium at all, ever.

### Recommendation

1. **Target `ClusterNetworkPolicy` v1alpha2 Admin-tier `Deny`. Do not adopt ANP/BANP v1alpha1** — it
   is the deprecated branch and excludes Cilium permanently.
2. **Keep NetworkPolicy + `NotIn` guard as the documented portable fallback** for estates below the
   version floor (Calico < 3.32, Cilium < 1.20, anything without the CRD). This is a two-tier design,
   not a replacement, and the fallback tier is the one most estates are on today.
3. **Test it on the existing cluster.** `kubectl api-resources --api-group=policy.networking.k8s.io`
   currently returns empty — no CRDs installed, and kindnet alone does not enforce them. But
   [kube-network-policies](https://raw.githubusercontent.com/kubernetes-sigs/kube-network-policies/main/README.md)
   ships an ANP/CNP daemonset installable with two `kubectl apply` commands. **This does not require
   rebuilding the cluster** — unlike the Cilium swap that was correctly ruled out of scope because
   `kind` accepts `disableDefaultCNI` only at creation. The strongest available claim in this whole
   programme is reachable for roughly the cost of one afternoon. Recommend adding it to M2.
4. **One semantic to note:** CNP is *"logically enforced outside the Pod network namespace"* — a pod
   connecting to its own Pod IP is not subject to CNP, though the same pod reaching itself via a
   Service IP is. Irrelevant to quarantine, but it will surface as a surprising conformance-test
   result.
5. **`Pass` is the forensic carve-out.** An Admin-tier `Pass` rule delegates a specific flow back to
   the NetworkPolicy tier — the clean way to preserve an investigator's access path without punching a
   hole in the Deny.

---

## 7. cgroup-v2 freezer — feasible, but the milestone is mis-framed and a liveness probe kills it

**Verdict: the primitive works and the design's core claim about it (invisible to the reconciler,
invisible to the process) is correct. Two of the surrounding assumptions are wrong.** `[HIGH]`

### The primitive

From the [kernel cgroup-v2 documentation](https://raw.githubusercontent.com/torvalds/linux/master/Documentation/admin-guide/cgroup-v2.rst):

> `cgroup.freeze` — A read-write single value file which exists on non-root cgroups. Allowed values are
> "0" and "1". […] Writing "1" to the file causes freezing of the cgroup **and all descendant
> cgroups**. This means that all belonging processes will be stopped and will not run until the cgroup
> will be explicitly unfrozen. **Freezing of the cgroup may take some time**; when this action is
> completed, the "frozen" value in the `cgroup.events` control file will be updated to "1".
>
> **Processes in the frozen cgroup can be killed by a fatal signal.** They also can enter and leave a
> frozen cgroup […] **If a process is moved to a frozen cgroup, it stops.**
>
> Frozen status of a cgroup doesn't affect any cgroup tree operations.

Confirmed present on the target node (`cgroup2fs`, `cgroup.freeze` in the root controller listing).

Four properties that matter, two helpful and two harmful:

- ✅ **Descendant inheritance.** Writing to the pod-level slice freezes every container including the
  sandbox — one write contains the whole pod.
- ✅ **Not observable as job control.** Unlike `SIGSTOP`/`SIGCONT`, there is no signal the process can
  trap or detect. The design's "the agent cannot observe its own containment" claim holds.
- ❌ **`SIGKILL` still lands.** The freeze is not armour. Anything that force-kills the container
  succeeds.
- ❌ **Freezing is not instantaneous.** "May take some time"; completion must be confirmed by polling
  `cgroup.events`. A stun that writes `1` and immediately proceeds has not actually won the race it
  claims to have won. **Add an explicit wait-for-`frozen=1` step to the M4 composition.**

### The milestone is mis-framed: this is not an RBAC question

M3 commits to a *"cgroup-freeze feasibility spike and **RBAC assessment**"*. Q5 asks *"what RBAC does
it need?"*

**Kubernetes RBAC is irrelevant to this operation.** Freezing a cgroup is a write to
`/sys/fs/cgroup/<pod slice>/<container>/cgroup.freeze` on the host filesystem. It never touches the API
server, so no Role, ClusterRole or binding governs it. What is actually required:

- a `hostPath` mount of `/sys/fs/cgroup` **read-write** (the default in-container mount is read-only);
- a container privileged enough to write it — `privileged: true`, or a carefully-scoped equivalent
  with no AppArmor/SELinux denial on cgroupfs writes;
- consequently, a namespace at PodSecurity level **`privileged`**;
- resolution of the container's cgroup path from the container ID, which is runtime- and
  cgroup-driver-specific (systemd vs cgroupfs driver produce different slice paths).

The correct framing is **host privilege and PodSecurity admission**, not RBAC. The distinction is not
pedantic: it changes who must approve the deployment, what the blast radius of compromising the stun
agent is (node-root, not namespace-scoped), and which control plane governs it. **A node agent that can
freeze arbitrary cgroups is functionally node-root and must be threat-modelled as such.** Recommend
rewording M3 and Q5 before the spike starts, because the spike as scoped would answer the wrong
question. `[HIGH]`

### There is no supported Kubernetes path to freeze a container

The [CRI RuntimeService](https://raw.githubusercontent.com/kubernetes/cri-api/master/pkg/apis/runtime/v1/api.proto)
exposes no `PauseContainer` / `FreezeContainer` RPC. The nearest thing is inside the checkpoint flow —
`CheckpointContainer`, `CheckpointPod`, `RestorePod`, where `CheckpointPod`'s contract states the
runtime *"must pause every selected container before capturing any of them, keep all selected
containers paused until every selected […]"*. So a pause primitive exists in the CRI contract, but only
as an implementation detail of checkpointing, not as an addressable verb.

[KEP-2008 Forensic Container Checkpointing](https://raw.githubusercontent.com/kubernetes/enhancements/master/keps/sig-node/2008-forensic-container-checkpointing/README.md)
is the sanctioned mechanism in this space and remains short of GA — its release signoff still has
unchecked GA e2e/conformance and Production Readiness Review boxes. **Worth flagging as a strategic
alternative:** checkpointing is a better architectural fit for the parent proposal's mode 4 (forensic)
than a raw freeze is, it is standards-track, and it produces a durable artefact rather than ephemeral
state. It does not replace mode 1 (a checkpoint is not a containment), but it deserves a row in the
taxonomy table.

### Kubelet reaction — the failure that breaks "freeze first"

This is absent from the design and it is decisive.

**Probe behaviour depends on probe type, and one type fails silently:**

| Probe type | Behaviour against a frozen container |
|---|---|
| `exec` | The probe process is spawned **into the container's cgroup** → *"If a process is moved to a frozen cgroup, it stops"* → never returns → timeout → **failure** |
| `httpGet` | TCP connect may succeed (SYN accepted by the kernel backlog) but no response is ever written → timeout → **failure** |
| `tcpSocket` | The listen backlog is kernel-side and the freeze does not close the socket → **the probe passes**. The freeze is invisible to it |

So a `tcpSocket` liveness probe never notices, and `exec`/`httpGet` always do. Whether the freeze
survives is a function of a field in someone else's Deployment.

**The kill chain, when a liveness probe does fail**
([Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)):

1. liveness failures reach `failureThreshold` → kubelet restarts the container;
2. the runtime sends `TERM` to PID 1 — which is frozen and cannot handle it;
3. `terminationGracePeriodSeconds` elapses (**default 30 s**);
4. *"When the grace period expires, if there is still any container running in the Pod, the kubelet
   triggers forcible shutdown. The container runtime sends `SIGKILL` to any processes still running in
   any container in the Pod."* — and per the kernel docs, **`SIGKILL` is delivered to frozen tasks**;
5. the container dies, its memory state (the forensic value of the freeze) is destroyed, and the owning
   Deployment/ReplicaSet creates a fresh, unstunned replacement.

**A frozen container with an `exec` or `httpGet` liveness probe is destroyed roughly
`periodSeconds × failureThreshold + 30 s` after the freeze.** For default settings that is under two
minutes. "Freeze first, then take the other steps at leisure against a target that cannot respond" does
not hold on any probed workload.

**And the mitigation collides with item 1.** Removing or extending the probe is a change to
`spec.containers[].livenessProbe` — a *spec* field, squarely inside Flux's drift-correction blast
radius, and therefore requiring either its own `ignore` rule or the `reconcile: disabled` escalation.
The design treats mode 1 as having *"Reconciler friction: None"* precisely because "execution state is
not configuration state". That is true of the freeze itself and **false of the change needed to make
the freeze durable**. This coupling between items 1 and 7 is not acknowledged anywhere in either
document and it undermines the taxonomy table's cleanest row.

**Other kubelet interactions:**

- **Eviction.** Memory remains charged to the frozen cgroup, so node memory-pressure eviction stays
  possible; the freeze offers no protection. Eviction's graceful-termination step fails for the same
  `SIGTERM` reason and falls through to `SIGKILL`.
- **Readiness.** A failing readiness probe removes the pod from Service endpoints — useful for
  containment, and a visible signal.
- **PLEG / cadvisor.** A frozen container's state remains `running`; `kubectl get pod` shows Ready
  until a probe flips it. This confirms the design's "Flux cannot see it" claim, and carries the
  corollary that **there is no API-visible evidence a freeze ever happened** — reinforcing §11's point 7
  about needing a first-class audit event. For the freeze specifically, an event is not a nice-to-have;
  it is the *only* record.

---

## Consolidated recommendations

**Correct before publishing**

1. **Withdraw the planned Cilium erratum (M6).** The parent proposal's "severs in-flight connections"
   claim is correct for Cilium. Re-run the measurement, expecting the flow to die; if it survives,
   the cause is one of the documented policy-enforcement exceptions (hairpin, loopback, L7 proxy,
   endpoint not selected), not conntrack.
2. **Restate every conntrack claim per-CNI.** "Established connections are never severed" is true for
   Calico, AWS VPC CNI and kindnet, and false for Cilium. Upstream declares the whole area
   implementation-defined; the design must not carry a universal claim here.
3. **Reframe M3/Q5 from RBAC to host privilege and PodSecurity.** The spike as scoped answers the
   wrong question.
4. **Invert `check-flux-dynamic-labels.sh`.** With an `ignore` rule present, the declaration may stay;
   what must be enforced is that every runtime-owned path is *covered* by a rule.

**Add**

5. **`ClusterNetworkPolicy` v1alpha2 Admin-tier `Deny` as the target quarantine mechanism**, with
   NetworkPolicy + `NotIn` as the documented portable fallback. Validate on the existing `kind` cluster
   via the kube-network-policies ANP/CNP daemonset — no cluster rebuild required.
6. **Admission enforcement of the guard convention** (ValidatingAdmissionPolicy / Kyverno). CI cannot
   stop a policy applied during an incident, and that is the case that matters.
7. **A wait-for-`cgroup.events: frozen=1` step** in the M4 freeze composition — the write is
   asynchronous.
8. **A liveness-probe interaction test** in the M4 harness: freeze a pod carrying a default `httpGet`
   liveness probe and measure time-to-destruction. Expect under two minutes.
9. **Health-check re-entry assertion** at un-stun, alongside `skipped`→`unchanged`. A
   `reconcile: disabled` object is dropped from health evaluation entirely, so `Ready=True` proves
   nothing while the annotation is present.
10. **A Flux version floor** in any published guidance. `spec.ignore` and its adopt/strip semantics are
    recent; older estates get no graceful degradation.

**Note as residual, do not attempt to solve**

11. Cilium's label-change-as-identity-change semantics make containment non-atomic during endpoint
    regeneration and can, in principle, widen access. Document it; do not design around it.
12. `ipBlock`-based allow rules cannot carry a label guard and behave differently across CNIs.
13. `ClusterNetworkPolicy` remains v1alpha2 — alpha, out-of-tree, no GA date. Adoption is a bet on
    direction, and should be stated as one.

---

## Appendix — sources

All verified HTTP 200 on 2026-08-03.

**Flux**
- [Kustomization docs — suspending and resuming](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- [Kustomize API v1 reference — `IgnoreRule`](https://fluxcd.io/flux/components/kustomize/api/v1/)
- [`kustomize-controller` v1.9.4 — `kustomization_controller.go`](https://raw.githubusercontent.com/fluxcd/kustomize-controller/v1.9.4/internal/controller/kustomization_controller.go)
- [`fluxcd/pkg` ssa v0.76.1 — `manager_apply.go`](https://raw.githubusercontent.com/fluxcd/pkg/ssa/v0.76.1/ssa/manager_apply.go)
- [`fluxcd/pkg` ssa v0.76.1 — `manager_delete.go`](https://raw.githubusercontent.com/fluxcd/pkg/ssa/v0.76.1/ssa/manager_delete.go)

**Kubernetes**
- [NetworkPolicy concepts](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Pod lifecycle — termination and probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [`cri-api` RuntimeService proto](https://raw.githubusercontent.com/kubernetes/cri-api/master/pkg/apis/runtime/v1/api.proto)
- [KEP-2008 Forensic Container Checkpointing](https://raw.githubusercontent.com/kubernetes/enhancements/master/keps/sig-node/2008-forensic-container-checkpointing/README.md)

**Network Policy API**
- [API object overview — tiers and actions](https://network-policy-api.sigs.k8s.io/api-overview/)
- [API specification](https://network-policy-api.sigs.k8s.io/reference/spec/)
- [Implementations list (updated 21-April-2026)](https://raw.githubusercontent.com/kubernetes-sigs/network-policy-api/main/site-src/implementations.md)
- [Release v0.2.0](https://github.com/kubernetes-sigs/network-policy-api/releases/tag/v0.2.0)
- [kube-network-policies README](https://raw.githubusercontent.com/kubernetes-sigs/kube-network-policies/main/README.md)

**CNIs**
- [Cilium `bpf/bpf_lxc.c`](https://raw.githubusercontent.com/cilium/cilium/main/bpf/bpf_lxc.c)
- [Cilium `pkg/endpoint/bpf.go`](https://raw.githubusercontent.com/cilium/cilium/main/pkg/endpoint/bpf.go)
- [Cilium Kubernetes network policy docs](https://raw.githubusercontent.com/cilium/cilium/main/Documentation/network/kubernetes/policy.rst)
- [Cilium endpoint lifecycle](https://docs.cilium.io/en/stable/security/policy/lifecycle/)
- [Cilium Helm `values.yaml`](https://raw.githubusercontent.com/cilium/cilium/main/install/kubernetes/cilium/values.yaml)
- [Cilium ANP tracking issue #23380](https://github.com/cilium/cilium/issues/23380)
- [Calico `felix/rules/endpoints.go`](https://raw.githubusercontent.com/projectcalico/calico/master/felix/rules/endpoints.go)
- [Calico `felix/rules/static.go`](https://raw.githubusercontent.com/projectcalico/calico/master/felix/rules/static.go)
- [AWS Network Policy Agent README](https://raw.githubusercontent.com/aws/aws-network-policy-agent/main/README.md)
- [Amazon EKS — Limit Pod traffic with network policies](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html)

**Kernel**
- [cgroup v2 admin guide](https://raw.githubusercontent.com/torvalds/linux/master/Documentation/admin-guide/cgroup-v2.rst)
