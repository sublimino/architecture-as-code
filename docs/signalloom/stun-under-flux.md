# Signal Loom Stun functionality under Flux Operator and the Modern GitOps Approach to Kubernetes

> Status: design research, 2026-08-03. Grounded in the live `kind-osramp` cluster, the
> `supercred-demo` scripts, and `Proposal — Signal Loom Agent Security Platform (2026-Q3)`
> § *Feature Architecture — 20 Capability Areas*, area 4.
>
> **Dated record — read as of its date, not as current design.** Its analysis of Flux
> friction by response mode has not been contradicted. Two things around it have moved,
> and neither is a correction to the argument below:
>
> * **The audit half has changed and is settled.** The browser no longer writes an audit
>   event for a stun. It used to (`recordStunAudit()` in `SuperCredInstructorPanel.tsx`),
>   with the agent name, namespace and reason as string literals — so the row asserted a
>   reason regardless of which one applied. The server now records the privileged
>   *invocation* instead, from the token, before spawning, and deliberately claims no
>   outcome, because the process writing the row cannot observe the relabel or the lease
>   revocation. See [`audit-trail.md`](audit-trail.md).
> * **The stun API shape is a known post-demo item** as of 2026-08-14 — not designed, not
>   scheduled here. Do not take any request or response shape from this document, and do
>   not read the absence of a description as a description.

## Executive summary

Stunning an agent **does** create friction with Flux — but the friction is not uniform, and treating it
as one problem is what has made it hard to reason about. It is **asymmetric by response mode**. The
canonical Stun primitive has *no* friction at all, by construction. The modes that do have friction have
it because they express containment as Kubernetes objects, which is precisely the set of things a
reconciler exists to own.

Three findings drive everything below.

1. **We are demoing the wrong mode under the right name.** The proposal defines Stun as mode 1 of five —
   a cgroup-v2 freeze. `scripts/supercred-demo.sh` `demo_4()` implements mode 3, credential revocation,
   plus a pod label, and calls it "stun".
2. **A cgroup freeze is invisible to Flux.** Freezing a process changes no field of any Kubernetes
   object. There is nothing to reconcile against, so there is nothing to suspend. The reconciler and the
   security control do not intersect.
3. **Pausing the reconciler is the wrong primitive**, and we now have evidence it is actively harmful:
   the pin our own test harness applies has become a *source* of demo failure, not merely a workaround
   for one.

## 1. What the stun actually does today

`scripts/supercred-demo.sh` `demo_4()` performs four distinct actions, in two very different classes:

| # | Action | Layer | In Flux's desired state? |
|---|--------|-------|--------------------------|
| 1 | `bao kv delete kv/signalloom/cardvault-agent` | OpenBao KV | No — but see §3 |
| 2 | `bao delete auth/jwt/role/signalloom-cardvault-agent` | OpenBao auth | No — but see §3 |
| 3 | `kubectl label pod agent-cardvault signalloom.ai/state=stunned` | Pod metadata | **Yes** |
| 4 | `kubectl annotate pod agent-cardvault signalloom.ai/stunned-at=…` | Pod metadata | **Yes** |

Actions 1–2 are real enforcement: they remove the credential and the auth role, so the agent's next
attempt to authenticate fails. Actions 3–4 are **labels on an object Flux owns**, applied imperatively.

That distinction is the whole design question.

## 2. The five-mode taxonomy, and where each meets the reconciler

The proposal's area 4 defines five composable response modes, least-to-most severe. Mapping each onto
Flux is the core contribution of this document:

| # | Mode | Enforcement primitive | Expressed as a k8s object? | Reconciler friction |
|---|------|----------------------|---------------------------|---------------------|
| 1 | **Stun (freeze)** | cgroup-v2 freezer / `SIGSTOP` | **No** | **None** |
| 2 | Network killswitch | eBPF/Cilium kernel L3–L7 deny | Yes, if via CiliumNetworkPolicy | High — reverted unless committed |
| 3 | Credential revocation | SVID + x509 + OpenBao leases | No (see §3) | Indirect, via bootstrap |
| 4 | Forensic mode | relocate to deception namespace | Yes | High |
| 5 | Kill / decommission | eBPF + revoke + Kyverno + lifecycle | Yes | High |

**Mode 1 is the interesting one.** A cgroup freeze changes no `spec`, no `metadata`, no `status` that
Flux templates. `kubectl get pod -o yaml` is byte-identical before and after. Flux's drift detection
compares rendered desired state against live object state; a frozen process is neither. The reconciler
cannot revert what it cannot see.

This is not a loophole. It is the correct architectural property: **execution state is not configuration
state**, and containment that operates on execution state is orthogonal to a configuration reconciler by
construction. That orthogonality is the reason mode 1 is the right first-response primitive, quite apart
from its reversibility and forensic value.

## 3. Why credential revocation *appears* to fight Flux

Credentials are not Kubernetes objects, so mode 3 should be frictionless too. Empirically it is not, and
the reason is instructive.

`scripts/supercred-e2e.sh:80-95` records the observed failure:

> `inf-bao/infra-configs` owns `openbao-supercred-bootstrap.yaml`, annotated
> `kustomize.toolkit.fluxcd.io/force: "true"`, so every reconcile deletes and RECREATES that Job — which
> re-writes the OpenBao policy, the JWT role and the KV secret that step 4 revokes. A reconcile landing
> during step 4 silently un-does the stun and the agent authenticates successfully. Observed: reconcile
> Ready at 16:23:58Z, step 4 failed "credentials were not revoked" in the same second.

The credential is not in git. But the **Job that mints the credential** is, and it is force-annotated, so
Flux recreates it on every reconcile and it re-seeds identity material unconditionally.

This is not "GitOps versus security". It is a bootstrap Job that is not idempotent with respect to
revocation. A seeding job should create-if-absent; this one asserts unconditionally, which converts
"seed the demo" into "continuously re-grant the credential". **The re-seed path is a persistence
mechanism**: an adversary who is revoked need only wait for the next reconcile.

Fix the layering — make the bootstrap create-if-absent, or move seeding out of the reconciled set — and
mode 3's friction disappears without pausing anything.

## 4. Is a pause the right primitive? No.

The current operational answer to "make the stun stick" is to suspend reconciliation. Three arguments
against, in increasing order of seriousness.

**It doesn't hold.** `scripts/supercred-e2e.sh:105-115` documents that `spec.suspend=true` on
`inf-bao/infra-configs` is itself drift: the flux-operator ResourceSet that generates the Kustomization
re-creates it on a 5m `reconcileEvery`. Suspending the leaf is insufficient because the thing that
manages the leaf puts it back. The pin only holds when applied at the ResourceSet
(`fluxcd.controlplane.io/reconcile: disabled`) — a fact discovered only after a run reported
"suspended (verified)" at preflight and was still re-seeded by iteration 3.

**It is too coarse.** Suspending a Kustomization disables reconciliation for *everything* it owns.
Containing one agent stops drift correction for an entire tenant — NetworkPolicies, admission config,
image policy — at exactly the moment you have most reason to distrust what is running. The blast radius
of the control vastly exceeds the blast radius of the threat.

**It is an availability attack surface.** If the documented response to a misbehaving agent is "suspend
the reconciler", then inducing that response is itself an attack: the adversary trades their own
containment for estate-wide loss of drift correction. A security control whose activation degrades other
security controls is not a control; it is a lever for the attacker.

**An observation, deliberately not overstated, 2026-08-03.** Re-running `supercred-e2e.sh iterate 1`
after merging the demo-runner work, step 2 failed — the agent credential chain timed out after 300s. Run
directly against the same cluster with Flux **live**, the identical step passed immediately. That looked
like evidence the pin had begun perturbing the demo. **It is not: a second harness run under the
identical pin passed 1/1 clean.** The failure is intermittent — one occurrence in eight recorded 1→5
cycles — and is therefore *not* attributable to the pin on this evidence.

What it does establish is narrower and still worth recording: step 2 has a latent flake with a 300s
budget, and the pinned path is where it has so far manifested. Distinguishing "the pin causes this" from
"the pin is where we happened to see it" needs a controlled comparison — N runs pinned versus N unpinned
— which has not been done. The arguments against pausing in this section stand on their own without it;
they do not need this observation, which is why it is reported rather than leaned on.

## 5. What Flux actually offers instead of a pause

Ordered by granularity, coarsest first:

| Mechanism | Scope | Suitable for containment? |
|-----------|-------|---------------------------|
| `spec.suspend` on Kustomization | Everything the Kustomization owns | No — §4 |
| `fluxcd.controlplane.io/reconcile: disabled` on ResourceSet | Everything the ResourceSet generates | No — worse, wider |
| `kustomize.toolkit.fluxcd.io/reconcile: disabled` on an object | One object | Possibly — see caveat |
| `kustomize.toolkit.fluxcd.io/ssa: ignore` | One object, drift ignored | Possibly |
| SSA field ownership | One *field* of one object | Best fit, if honoured |
| Committed quarantine (desired state) | One object, reconciled *toward* | Best for durable modes |

The per-object annotations are the only mechanisms with a blast radius proportional to the threat. **This
needs empirical confirmation against the Flux version actually running before it is designed around** —
it is flagged as the open question in §8.

## 6. The GitOps-native counter-argument, and the synthesis

The strongest objection to out-of-band containment: an imperative `kubectl label` the reconciler will
revert is not a control, it is a race the adversary wins by waiting. If quarantine is real it should be
desired state — committed, reviewed, auditable, and continuously *enforced* by the reconciler rather than
fought by it.

That argument is correct for modes 2, 4 and 5, and wrong for modes 1 and 3 — and the disagreement
dissolves once you stop treating "stun" as one thing.

**Two-phase containment** is the synthesis:

- **Phase 1 — immediate, out-of-band, execution-layer.** Mode 1 freeze plus mode 3 revocation. Bounded by
  seconds. Touches no reconciled object, therefore needs no pause and creates no race.
- **Phase 2 — durable, committed, configuration-layer.** The quarantine is committed and reconciled
  toward: NetworkPolicy deny, admission block, lifecycle state. Bounded by the commit-and-reconcile loop,
  minutes.

Phase 1 survives until phase 2 lands *because it was never in the reconciled set to begin with*. That is
the property that makes the two phases composable, and it is the reason the layering matters more than
the mechanism.

## 7. Consequences for the SuperCred demo

1. **Rename or reimplement.** Either the demo implements a real mode-1 freeze, or the step is renamed to
   what it does — "revoke credentials". Demoing mode 3 as "Stun" to an audience that may have read the
   capability model is a credibility risk, and the critique appendix's own finding #3 warns that demoing
   mock controls "collapses confidence in the other areas".
2. **The label is telemetry, not enforcement — and that is a split-brain risk.** `signalloom.ai/state`
   *is* consumed, but only as an observation channel:
   - `d2-signalloom/apps/fake-integration-proxy/server.py:372` reads `labels.get("signalloom.ai/state")`
     and serves it as the agent's `state` on `GET /supercred-api/agents`.
   - `dashboard-signalloom/src/api/supercredState.ts:19` — "The `signalloom.ai/state` pod label is
     authoritative because both drivers…"

   Nothing selects on it in a NetworkPolicy, Kyverno policy, or admission configuration. So it is not
   security theatre — it is how the **dashboard knows** the agent is stunned, which is exactly what the
   demo's audience window depends on.

   That makes the Flux interaction worse, not better. The real enforcement (mode 3 credential
   revocation) lives outside the reconciled set and persists. The *evidence* (the label) lives on a
   Flux-owned pod and **is reverted** — measured, see Q3 in §8. The failure mode is therefore
   **split-brain, confirmed**: the agent stays genuinely revoked while the dashboard reports it `idle`
   again. An operator looking at the UI concludes the stun was lifted when it was not — the most
   dangerous direction for a monitoring error, and one no current test catches.

   **This is a live demo risk, not just a production one.** The demo's whole design has an audience
   watching a second window. If a reconcile of `fe-signalloom/apps` lands after step 4 — and any
   reconcile will do, scheduled or triggered — the agent flips back to `idle` in front of the room while
   the presenter is explaining that it has been contained. The e2e harness never sees this because it
   pins Flux for the duration, which is precisely the condition a live demo does not run under.

   **Root cause.** `agents-cardvault.yaml:25` declared `signalloom.ai/state: idle` as a literal, so a
   field whose value is *runtime state* was pinned to a constant in desired state.

   **CORRECTION, 2026-08-03.** An earlier revision of this document, and the commit message of
   `77f227e`, both stated that "kustomize-controller v1.9.4 exposes no per-field drift ignore". **That
   is wrong.** `Kustomization.spec.ignore` is exactly that mechanism. From the running CRD:

   > *Ignore is a list of rules for specifying which changes to ignore during drift detection. These
   > rules are applied to the resources managed by the Kustomization and are used to exclude specific
   > JSON pointer paths from the drift detection and apply process.*

   I mistook it for a source-path ignore (the `.sourceignore` sense the field has on `GitRepository`)
   and did not read the schema description before asserting otherwise. The fix now applied to
   `d2-osramp-fleet/tenants/base/apps.yaml` uses it:

   ```yaml
   ignore:
     - target: {kind: Pod, labelSelector: signalloom.ai/agent=true}
       paths:
         - /metadata/labels/signalloom.ai~1state
         - /metadata/annotations/signalloom.ai~1stunned-at
         - /metadata/annotations/signalloom.ai~1stun-reason
   ```

   Note the two **annotations**. The stun writes `stunned-at` and `stun-reason` as well as the label,
   and the original analysis missed them entirely — a fix covering only the label would still have lost
   the timestamp and the reason.

   **Open question, deliberately not resolved here (see §8 Q6):** whether the label should ALSO remain
   declared in the manifest alongside the ignore rule. Removing the declaration and ignoring the path
   are two different fixes and they are in tension; which is correct depends on whether Flux prunes an
   undeclared label it previously owned.
3. **A real mode-1 freeze demos better.** It is instant, visibly reversible, and needs no reconciler
   pin — so the demo stops depending on the very workaround that is now breaking it.
4. **Make the bootstrap idempotent.** Create-if-absent, so revocation is durable without suspending
   `inf-bao/infra-configs`.

## 8. Open questions requiring empirical confirmation

These are stated as unresolved rather than assumed, because the design depends on them:

- ~~**Q1.** Does the running Flux version support a per-object / per-field ignore?~~ **ANSWERED
  2026-08-03 — yes, and better than asked.** `Kustomization.spec.ignore` takes JSON Pointer paths with a
  target selector, giving per-*field* granularity while the rest of the object stays fully managed.
  `reconcile: disabled` and `ssa: ignore` also work but un-manage the whole object, which is a worse
  trade. Applied in `d2-osramp-fleet/tenants/base/apps.yaml`.
- **Q6 (NEW).** With an `ignore` rule in place, must the path ALSO remain declared in the manifest?
  Supporting evidence says the annotations are wiped on reconcile unless declared with placeholder
  values, which would mean "ignore" prevents *drift correction* but not *pruning of an owned field*.
  The two candidate fixes — delete the declaration, versus declare it and ignore it — are in direct
  tension, and `scripts/check-flux-dynamic-labels.sh` currently enforces the first. **Settle this before
  relying on either.** The decisive test: apply the ignore rule, set the label at runtime, force a
  reconcile, and check whether the label survives, is reverted, or is deleted.
- **Q7 (NEW).** The second declaration lives in a flux-operator **ResourceSet**
  (`d2-osramp-fleet/tenants/local/signalloom.yaml`), not a Kustomization. `spec.ignore` is a
  Kustomization field, so it does not apply there. What protects the inert demo-agent cohort?
- ~~**Q2.** Does *anything* consume `signalloom.ai/state=stunned`?~~ **ANSWERED 2026-08-03.** Yes, as
  telemetry only — `fake-integration-proxy/server.py:372` and `api/supercredState.ts:19`. No enforcement
  consumer anywhere. See §7.2; this converts the question from "is it theatre" into "is the evidence
  channel reconciler-safe", which it is not.
- ~~**Q3.** Is an imperatively-set label reverted or merged on the next reconcile?~~
  **ANSWERED 2026-08-03 — REVERTED. Measured, not inferred:**

  ```
  $ kubectl -n fe-signalloom get pod agent-cardvault \
      -o jsonpath='{.metadata.labels.signalloom\.ai/state}'
  idle
  $ kubectl -n fe-signalloom label pod agent-cardvault \
      signalloom.ai/state=stunned --overwrite
  stunned
  $ kubectl -n fe-signalloom annotate kustomization apps \
      reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite    # force reconcile
  $ kubectl -n fe-signalloom get pod agent-cardvault \
      -o jsonpath='{.metadata.labels.signalloom\.ai/state}'
  idle          # <-- the stun evidence is gone
  ```

  The manifest declares `signalloom.ai/state: idle` at
  `d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml:25`, so the label is *in* Flux's desired
  state with a fixed value. An imperative change to `stunned` is drift by definition, and the reconciler
  corrects it. §7.2's split-brain is therefore **confirmed, not hypothetical** — the do-not-design-around
  caveat is lifted.

  Two aggravating details found in the same experiment. The agent pod was found running in
  `fe-signalloom` **4 minutes after a teardown that had asserted clean** — Flux had already resurrected
  it, exactly as `supercred-state.sh:356` warns. And the revert needs no scheduled reconcile: *any*
  reconcile of `fe-signalloom/apps` does it, so the 30m interval is an upper bound on the lie, not a
  floor.
- ~~**Q4.** What are the real intervals?~~ **ANSWERED 2026-08-03**, measured on `kind-osramp`:
  `flux-system/flux-system` **10m**; `fe-signalloom/apps`, `inf-bao/infra-configs`,
  `inf-signalloom/infra-configs` and the rest **30m**; `flux-system/tenants` **12h**; every ResourceSet
  (`signalloom-infra`, `signalloom-apps`, `infra`, `policies`, `agent-trust`)
  `reconcileEvery` **5m**. SVID and OpenBao lease TTLs remain unmeasured.

  The 30m Kustomization interval is the number that matters for §7.2: it is the upper bound on how long
  a reverted evidence label could show the wrong state, and the 5m ResourceSet cadence is the upper
  bound on how long any leaf-level pin survives.
- **Q5.** Is cgroup-v2 freezer usable from the runner's security context, and what RBAC does it need?
  Mode 1's entire value rests on this being practical.

## References

- `scripts/supercred-demo.sh` — `demo_4()`, the current stun
- `scripts/supercred-e2e.sh:80-115` — observed reconciler interference and the ResourceSet pin
- `scripts/supercred-state.sh:356` — `assert-stays-clean`, teardown durability under a live reconciler
- `Proposal — Signal Loom Agent Security Platform (2026-Q3)` § Feature Architecture — 20 Capability Areas
- `Proposal — Signal Loom Agent Security Platform — Critique Appendix (2026-Q3)` § B.0 findings 3 and 4

---

## 9. `reconcile: disabled` applied *by* the stun — verified, and it works

Rather than pre-declaring an ignore rule, the stun can annotate the object it is containing. **Measured
on `kind-osramp`, 2026-08-03:**

```
annotate pod kustomize.toolkit.fluxcd.io/reconcile=disabled
label    pod signalloom.ai/state=stunned            -> stunned | disabled
<force reconcile of fe-signalloom/apps>
read back                                            -> stunned | disabled   # both survived
```

kustomize-controller reads the annotation from the **live** object, so the stun can protect itself
without any pre-provisioned configuration. This is a genuinely good option and it was not in the
original analysis.

**How it compares to `.spec.ignore`:**

| | `.spec.ignore` (Kustomization) | `reconcile: disabled` (on the object) |
|---|---|---|
| Applied | ahead of time, in git | reactively, by the stun |
| Granularity | **per field** (JSON Pointer) | whole object |
| Rest of object | stays fully managed | **completely unmanaged** |
| Needs pre-provisioning | yes | no |
| Survives if stun path is novel | only for enumerated paths | yes, anything |
| Risk on un-stun | none | **object stays unmanaged if not removed** |

**Use both, for different jobs.** `.spec.ignore` is the standing, narrow protection so an ordinary stun
needs no GitOps action at all. `reconcile: disabled` is an *escalation* for a hard quarantine where
freezing the object against all reconciliation is the intent — accepting that drift correction stops
entirely for that object.

**Two sharp edges.** It also suppresses pruning, so the object is not garbage-collected when removed
from git. And anyone who can annotate a pod can opt it out of GitOps — the annotation is a privilege,
and should be restricted like one.

## 10. The Argo CD equivalents

| Flux | Argo CD | Note |
|---|---|---|
| `Kustomization.spec.ignore` (JSON Pointer) | `Application.spec.ignoreDifferences` with `jsonPointers` | direct analogue |
| — | `ignoreDifferences.managedFieldsManagers` | **better than Flux's model** |
| `reconcile: disabled` on object | no exact single-object equivalent; nearest is `argocd.argoproj.io/compare-options: IgnoreExtraneous` + `sync-options: Prune=false` | partial |
| `spec.suspend` on Kustomization | `syncPolicy.automated.selfHeal: false` | the same anti-pattern, §4 applies |
| drift correction | "self-heal" | same concept, different name |

**`managedFieldsManagers` is the more elegant model and worth stealing.** It ignores fields by *field
owner* rather than by path: tell Argo to ignore whatever the field manager `signalloom-stun` owns, and
you never enumerate paths, so a stun that starts writing a new annotation is covered automatically.
Flux's path list would silently miss it — which is exactly how the two stun annotations went unnoticed
in the first analysis.

**Actionable regardless of GitOps engine:** the stun should apply with a **distinct field manager name**
(`kubectl --field-manager=signalloom-stun ...`). It costs nothing today, makes ownership legible in
`managedFields`, and is a precondition for the Argo model.

## 11. Is the composition enough? What is missing

Proposed: label → GitOps opt-out → eBPF network lockdown → credential revocation. Necessary, not
sufficient. Missing, in priority order:

1. **Freeze first (cgroup-v2), before anything else.** This is an ordering argument, not an extra step.
   Every other control races a *running* adversary that can observe its own containment and react —
   exfiltrate, re-auth, spawn. Freezing removes the ability to race, then the rest proceeds against a
   target that cannot respond. It is also the canonical mode-1 Stun.
2. **Conntrack flush.** Verified: established connections survive a network quarantine with a **24-hour**
   timeout, on kindnet *and* Cilium. Without `conntrack -D` for the pod IP, "network lockdown" does not
   touch the connections the agent already has open — which are the ones that matter.
3. **The `NotIn: [stunned]` guard on every other allow policy.** Verified: an ordinary application allow
   policy silently un-quarantines a stunned pod, because NetworkPolicy is allow-only and additive.
4. **Neutralise the owning controller.** If the pod is owned by a Deployment/ReplicaSet/Job, freezing or
   deleting it just yields a fresh, unstunned replacement. The quarantine must be applied at the owner,
   or the owner scaled to zero.
5. **Admission block** (Kyverno / ValidatingAdmissionPolicy) so the workload cannot be readmitted.
6. **Session revocation at the gateway.** Credential revocation does not close MCP/A2A sessions already
   established.
7. **An immutable audit record.** See §12 — the current evidence is *state*, not an event, and state can
   be reverted.
8. **Dual control** on the irreversible steps, per the proposal's own control list.

## 12. What the logs actually show

kustomize-controller emits a per-object verb on every reconcile. Extracted from this cluster:

```
$ kubectl -n flux-system logs deploy/kustomize-controller | grep -o '"Pod/fe-signalloom/agent-cardvault":"[a-z]*"' | sort | uniq -c
     36 "Pod/fe-signalloom/agent-cardvault":"configured"
      2 "Pod/fe-signalloom/agent-cardvault":"created"
      6 "Pod/fe-signalloom/agent-cardvault":"skipped"
     43 "Pod/fe-signalloom/agent-cardvault":"unchanged"
```

| Verb | Meaning |
|---|---|
| `unchanged` | no drift |
| **`configured`** | **drift corrected — this is the stun being undone** |
| `skipped` | `reconcile: disabled` honoured — the stun was protected |
| `created` | object (re)created, e.g. resurrection after teardown |

**`configured` on an agent pod is the machine-readable signature of a silently reverted stun**, and there
are 36 of them in this cluster's recent history. Nothing alerts on it. That is the cheapest available
detection for the split-brain in §7.2 and it should be wired to an alert.

**What does NOT show the stun:** Kubernetes Events on the pod carry only scheduling and container
lifecycle — nothing about containment. The agent's own logs carry nothing. There is no first-class stun
event anywhere; the entire record is the label plus two annotations, i.e. **state, not history**. When
the label is reverted the record does not become stale, it *disappears* — the system cannot distinguish
"never stunned" from "stun erased".

**Recommendation:** emit a Kubernetes Event on stun and un-stun, and write an immutable audit record
outside the cluster. State is not an audit trail.

## 13. How to un-stun

Un-stunning is **not** the stun reversed. Order is chosen so the agent is never running with controls
partially removed.

1. **Gate.** Confirm the triggering condition is resolved; dual control; record who and why.
2. **Rotate, do not restore.** Issue *new* credentials. The old SVID/token may be compromised — that is
   why they were revoked. Restoring the previous secret re-grants exactly what the attacker may hold.
3. **Lift the network quarantine** — remove the `stunned` label, or let the label removal do it.
4. **Flush conntrack again** if any deny-era connections were established.
5. **Remove the GitOps opt-out** — `kubectl annotate pod ... kustomize.toolkit.fluxcd.io/reconcile-`.
   **This is the step most likely to be forgotten**, and forgetting it leaves the object permanently
   unmanaged: drift then accumulates silently and Flux reports Ready throughout. Verify with the
   `skipped`→`unchanged` transition in §12.
6. **Unfreeze last.** The agent wakes into a fully restored, fully monitored state rather than into a
   half-lifted quarantine it could observe and exploit.
7. **Record the un-stun** with the same rigour as the stun.

An un-stun that skips step 5 is the mirror of the original defect: the first left the control without
evidence, this leaves the object without governance.
