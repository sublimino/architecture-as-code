# Signal Loom Stun functionality under Flux Operator and the Modern GitOps Approach to Kubernetes

> Status: design research, 2026-08-03. Grounded in the live `kind-osramp` cluster, the
> `supercred-demo` scripts, and `Proposal — Signal Loom Agent Security Platform (2026-Q3)`
> § *Feature Architecture — 20 Capability Areas*, area 4.

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
   Flux-owned pod and can be reverted. The failure mode is therefore **split-brain**: the agent stays
   genuinely revoked while the dashboard quietly reports it healthy again. An operator looking at the UI
   would conclude the stun had been lifted when it had not — the most dangerous possible direction for a
   monitoring error, and one no current test would catch.
3. **A real mode-1 freeze demos better.** It is instant, visibly reversible, and needs no reconciler
   pin — so the demo stops depending on the very workaround that is now breaking it.
4. **Make the bootstrap idempotent.** Create-if-absent, so revocation is durable without suspending
   `inf-bao/infra-configs`.

## 8. Open questions requiring empirical confirmation

These are stated as unresolved rather than assumed, because the design depends on them:

- **Q1.** Does the running Flux version honour `kustomize.toolkit.fluxcd.io/reconcile: disabled` and
  `ssa: ignore` on an *individual* object, allowing one object to hold a stun without suspending its
  Kustomization? This is the single highest-value unknown in §5.
- ~~**Q2.** Does *anything* consume `signalloom.ai/state=stunned`?~~ **ANSWERED 2026-08-03.** Yes, as
  telemetry only — `fake-integration-proxy/server.py:372` and `api/supercredState.ts:19`. No enforcement
  consumer anywhere. See §7.2; this converts the question from "is it theatre" into "is the evidence
  channel reconciler-safe", which it is not.
- **Q3.** Under SSA, who owns `metadata.labels` on the agent pod, and is an imperatively-set label
  reverted or merged on the next reconcile? **Still open** — a `managedFields` query against the live
  pod returned nothing usable and needs a better probe. This is now the highest-value remaining unknown,
  because §7.2's split-brain risk is real only if Flux actually reverts the label. If SSA *merges*
  rather than reverts, the risk is void. **Do not design around §7.2 until this is settled.**
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
