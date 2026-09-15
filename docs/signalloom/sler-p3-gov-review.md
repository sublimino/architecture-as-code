# SLER-P3-GOV — Phase 3 Certification Review

**Card:** SLER-P3-GOV — Merge mesh and admission enforcement and prove netassert boundary denial
**Integration branch:** `integration/sler-v0.1.0`
**Reviewed at:** `14d56cef21f4e513e806d8869ce598a25b8341b1`
**Governor worktree:** `~/src/.worktrees/osramp-demo/sler-v0.1.0/governor`
**Date:** 2026-09-15
**Verdict:** **CONDITIONAL FAIL** — both planes are individually correct and unit-green; neither is
reachable in the deployed system. Phase 3 has produced two well-built enforcement clients that
nothing calls and one webhook that nothing deploys.

---

## 1. Merge state — no merge was outstanding

The card instructed this Governor to merge P3-1 and P3-2. Both were already on the integration
branch when this card started, merged by the phase controller:

| Card | Feature commit | Merge commit |
| :--- | :------------- | :----------- |
| SLER-P3-1 mesh isolation and TCP severance | `651bbbfc` | `a8ac3d1bb90c9c512a8f0cb8764078ff881c149a` |
| SLER-P3-2 admission webhook block | `f3d16505` | `9d5d0282da46513274813b469ac552600e961dd2` |

No merge conflict existed and no merge was performed by this card. The work of this card is
therefore entirely certification, regression testing, and defect reporting on the already-merged
tree.

**Card premise correction.** The card's "Verified facts" state that the guard "has no
contained-identity store, and there are zero ValidatingWebhookConfiguration manifests". That was
true when the card was compiled and is no longer true: `f3d16505` added
`pkg/webhook/store.go` and `base/validatingwebhookconfiguration.yaml`. The instruction to confirm
the admission half exists before certifying it was correct to issue, and the answer is that the
code exists. Whether it *runs* is section 4.

---

## 2. Certification results

| # | Required certification | Verdict | Basis |
| :- | :--------------------- | :------ | :---- |
| C1 | Admission webhook `failurePolicy` is `Fail` and documented | **PASS** | Literal `failurePolicy: Fail` at `validatingwebhookconfiguration.yaml`, with an 8-line block comment naming the readmission-bypass consequence of `Ignore`. Explicit, not defaulted. |
| C2 | Mesh isolation targets a confirmed mesh technology | **PASS** | Cilium, confirmed present in P3-PRE. `cilium-isolation-policy.yaml` selects `signalloom.ai/agent=true` + `signalloom.ai/state=stunned`. No speculative Istio/Linkerd superset. |
| C3 | Both planes share one contained-identity notion | **PASS (by shape), FAIL (by reach)** | See section 3. |
| C4 | netassert boundary proof ran, did not skip | **PASS as executed, DOES NOT PROVE CONTAINMENT** | See section 5. |
| C5 | End-to-end admission-deny test proving a contained pod cannot be recreated | **FAIL** | Not possible: the webhook is not deployed and no orchestrator writes to the store. Section 4. |
| C6 | IPv4-only mesh scope stated honestly, IPv6 named as residual | **PASS** | Section 6. Carried forward into this report, which is the artefact P5-2 reads. |
| C7 | Combined reversibility test — resume restores mesh AND admission together | **FAIL** | Section 4. Each plane has its own reversal unit test; there is no combined test and no code path that would exercise one. |
| C8 | Both planes' structured logging is attestation-ready in a compatible shape | **PASS** | Section 7. |

---

## 3. Contained-identity: one definition, two writers, one unreachable

The named failure mode — "P3-1 and P3-2 independently invented two different contained-identity
representations" — **did not occur at the store layer.** The two Go types are field-for-field
compatible:

| fleet-manager `StoredContainedAgent` | node-capability-guard `ContainedEntry` |
| :----------------------------------- | :------------------------------------- |
| `agent_id` | `agent_id` |
| `namespace` | `namespace` |
| `spiffe_id` | `spiffe_id` |
| `contained_at` | `contained_at` |
| `reason` | `reason` |
| `idempotency_key` | `idempotency_key` |
| `metadata` | `metadata` |

They share one physical store, not two:

```
fleet-manager K8sAdmissionClient.syncConfigMapEntry
   └─ writes ConfigMap fe-signalloom/signalloom-contained-agents, key contained-agents.json
        └─ mounted read-only at /etc/node-capability-guard/contained-agents.json
             └─ read by node-capability-guard FileIdentityStore  (cmd/main.go -store-file)
```

That is a genuine shared definition and it is the right design.

**However, containment is represented twice at a level above the store.** The mesh plane does not
consult the store at all — it enforces on the *pod label* `signalloom.ai/state=stunned`, written by
`SetPodState`. The admission plane enforces on the *store entry*, written by `BlockAdmission`. An
agent is therefore "contained" according to the mesh plane iff its pod carries a label, and
"contained" according to the admission plane iff a ConfigMap row exists. Nothing in the codebase
writes both, and nothing asserts they agree.

This is the divergence the card warned about, one layer higher than where it was looked for. It is
currently latent rather than live, because — as section 4 establishes — neither writer is invoked.

---

## 4. **Blocking finding: neither plane is reachable**

### 4a. No orchestrator calls either plane

`CascadeOrchestrator` dispatches containment through the `FleetClient` interface
(`cascade.go:148`). That interface declares five methods:

```
GetPodState  SetPodState  RevokeCredentials  RestoreCredentials  Health
```

Mesh isolation and admission blocking are **not among them**. `Stun()` calls exactly three —
`GetPodState`, `RevokeCredentials`, `SetPodState`. `Recover()` calls `GetPodState` and
`RestoreCredentials`.

The four plane entry points exist only as methods on the concrete `*k8sFleetClient`:

| Method | File | Production callers |
| :----- | :--- | :----------------- |
| `IsolateMeshPlane` | `k8sclient.go:620` | **0** |
| `RestoreMeshPlane` | `k8sclient.go:670` | **0** |
| `BlockAdmissionPlane` | `k8sclient.go:714` | **0** |
| `UnblockAdmissionPlane` | `k8sclient.go:765` | **0** |

Verified by `rg` across all non-test Go in `d2-signalloom/`: the only occurrences are the
definitions themselves. The seven HTTP routes in `main.go` reach `handleStun`/`handleRecover`,
which reach the cascade, which reaches the five-method interface. There is no path from any
request to either plane.

**Consequence.** A `POST /api/v1/fleet/stun/<agent>` today revokes credentials and relabels the pod.
It performs no conntrack severance and writes no admission-block entry. The mesh CiliumNetworkPolicy
*does* fire, because it selects on the label the cascade already writes — so the mesh plane is
partially live by accident of selector design, while its in-flight TCP severance (the actual P3-1
deliverable, the thing that produces the sub-2s guaranteed-denial number) never executes.

### 4b. The admission webhook is not deployed

`d2-signalloom/apps/node-capability-guard/base/` has a complete manifest set with its own
`kustomization.yaml`. **No other kustomization references it.** By contrast P3-1's
`cilium-isolation-policy.yaml` *is* wired, at `apps/fe-signalloom/base/kustomization.yaml:10`.

Confirmed live against `kind-osramp`:

```
$ kubectl get validatingwebhookconfiguration
NAME                   WEBHOOKS   AGE
cert-manager-webhook   1          15d          # ← node-capability-guard absent

$ kubectl -n fe-signalloom get deploy,cm | rg -i 'capability|contained'
(no output)
```

P3-2's card title claims "admission webhook block **and deployment surface**". The manifests were
authored; the deployment surface was not connected.

### 4c. Why C5 and C7 cannot pass

An end-to-end admission-deny proof requires a deployed webhook and a populated store. Neither
exists. A combined reversibility test requires a single call path that reverses both planes.
No such path exists — `Recover()` cannot reverse planes it never engaged.

These are not test-authoring gaps. Writing the tests would require first building the wiring, which
is P3-1 and P3-2 implementation work, not governor work. Recording the gap rather than silently
closing it is the correct governance action: a Governor that implements a sibling's missing
deliverable hides the gap from the board.

**Owner:** a phase-3 remediation card (recommended `P3-3: wire mesh and admission planes into the
cascade and the fe-signalloom kustomization`), landing before P4-GOV. P4's reversible stun/unstun
lifecycle inherits this defect directly — `P4-3: governance-gated resume` cannot restore admission
eligibility through a path that does not exist.

---

## 5. netassert: it ran, and it proves something else

The card's stated failure mode was certifying on a netassert run that had silently skipped. That did
not happen — the run was real and is worth recording precisely:

- Binary present: `/home/andy/bin/netassert`, NetAssert v2.1.5. Not skipped.
  (`d2-signalloom/Makefile:194` hard-fails when absent; `Makefile:791` is the caller that skips.)
- Cluster live: `kind-osramp`, `osramp-control-plane Ready v1.36.1`.
- Fixture present: `netassert-generic-agent-fixture-545f77f844-cfjss` Running.
- Real ephemeral containers were injected and real exit codes collected.
- **10 tests, 10 passes**, TAP written to `/tmp/results.tap`. Exit 0.

| Test | Result |
| :--- | :----- |
| dashboard-to-api-allowed | pass |
| dashboard-to-dex-allowed | pass |
| api-to-postgresql-allowed | pass |
| api-to-redis-allowed | pass |
| api-to-minio-allowed | pass |
| agents-to-api-denied | pass |
| agents-to-dashboard-denied | pass |
| agents-to-postgresql-denied | pass |
| dashboard-to-postgresql-denied | pass |
| dashboard-to-redis-denied | pass |

**What this does not prove.** Every one of the ten asserts the *baseline* namespace NetworkPolicy
posture that predates phase 3. Not one isolates an agent and then asserts denial. `test/netassert-signalloom.yaml`
contains no containment case. So this is a clean regression proof that phase 3 did not break the
existing network boundary — and it is **not** a boundary-denial proof for containment.

Reading a green `test-netassert` as certification of the containment boundary would be exactly the
error the card names, arrived at by a different route than expected: the harness was present and did
run, it simply tests a different boundary. A containment case (isolate agent → assert egress denied
→ resume → assert egress restored) has to be added to that config file before this deliverable is
real.

---

## 6. Network plane certified IPv4-only

`tc.FlushIP` (`stun-sentinel/pkg/tc/conntrack.go:393`) refuses any non-IPv4 target outright:

```go
if target == nil || target.To4() == nil {
    return 0, fmt.Errorf("conntrack: FlushIP requires an IPv4 address, got %v", target)
}
```

`CiliumMeshClient.IsolateAgentMesh` handles this honestly: an IPv6 or unparseable target skips the
flush, downgrades the outcome to `OutcomePartial`, sets the residual to
`MeshIPv6WorstCaseResidualMs = 120000`, and stamps provenance
`upstream-default (IPv6 conntrack severance unsupported; TCP timeout)`.

**The network plane is hereby certified IPv4-only. Dual-stack IPv6 is a named residual, not a
silently unhandled case.** This paragraph exists because P3-1 documented the scope in its own proof
and in the `mesh_client.go` header, but the phase-3 report is what P5-2 reads — the card correctly
predicted that this would be the place it got dropped.

**Defect (minor, reporting).** `MeshIsolationResponseToPlaneResult` declares `ipv4Scoped := true` and
never reassigns it, so the `ipv4_scoped` detail is a constant. On an IPv6 target the emitted record
carries `ipv4_scoped: true` alongside `conntrack_flushed: false` and a 120,000 ms residual. The
residual and provenance fields do carry the truth, so no attested record is *false* — but a P5-2
consumer that filters on `ipv4_scoped` to find unhandled targets will find none. Owner: P3-1
remediation.

---

## 7. Attestation-readiness: both planes conform

`SharedAttestationEventKeys` (`attestation_event_contract.go:51`) requires four keys of every
plane event: `event`, `outcome`, `latency_ms`, `worst_case_residual_ms`.

| Emitter | event name | 4 required keys | Extra fields |
| :------ | :--------- | :-------------- | :----------- |
| `MeshIsolationAuditLogEntry` | `mesh_isolation_audit` | present | `residual_provenance`, `conntrack_flushed`, `entries_deleted`, `target_ip`, `idempotency_key`, `timestamp`, `error?` |
| `AdmissionBlockAuditLogEntry` | `admission_block_audit` | present | `residual_provenance`, `block_enforced`, `rule_id`, `idempotency_key`, `timestamp`, `error?` |
| `AdmissionDecisionLogEntry` (webhook-side) | `admission_decision` | present | `uid`, `operation`, `pod_name`, `agent_id`, `spiffe_id`, `allowed`, … |

All three marshal via `encoding/json` through `slog`. Both planes carry `residual_provenance`, which
P5-1 needs and which is not in the required set. `error` is `omitempty` on all three, consistent with
the contract's documented instruction that P5-1 treat an absent `error` as "no error".

**C8 passes.** P5-1 can consume both planes without a shape adapter.

---

## 8. Denial matrix — phase 3 numbers for P5-2

Consume these with their qualifiers. Both planes' figures are **capability figures, not system
figures**, because section 4 establishes that neither plane is invoked in the deployed system.

| Plane | Guaranteed denial | Worst-case residual | Provenance | Scope / caveat |
| :---- | :---------------- | :------------------ | :--------- | :------------- |
| Mesh (IPv4) | policy immediate (eBPF, label-selected); conntrack flush in-kernel, typically <10 ms, ceiling <2 s | **0 ms** | measured (conntrack netlink severance) | IPv4 only. Conntrack severance code path has **no production caller** — the policy half fires via the existing `state=stunned` label, the severance half does not. |
| Mesh (IPv6) | policy only — no in-flight severance | **120 000 ms** | upstream-default (TCP keepalive/FIN timeout) | Named residual. `OutcomePartial` is returned. |
| Admission | synchronous, pre-scheduling, `failurePolicy: Fail` | **0 ms as coded** | config-derived | **Do not publish 0 ms.** See below. |

**Correction P5-2 must apply to the admission number.** `AdmissionWorstCaseResidualMs = 0` is
justified in code by "admission checks are synchronous before pod scheduling", which is true of the
*check*. It is not true of the *store update*. The deployed topology is
`fleet-manager → ConfigMap → kubelet volume projection → guard's FileIdentityStore`. Kubelet
ConfigMap propagation to a mounted volume is not instantaneous; the interval between
`BlockAdmission` returning success and the guard being able to see the new entry is the plane's real
worst-case residual, and it is bounded by kubelet sync behaviour, not by zero. During that window a
pod for a just-contained agent is admitted.

Publishing 0 ms would overstate the guarantee in exactly the way `SharedAttestationEventKeys`'
own comment warns against. The honest options are (a) measure the propagation delay on the target
cluster and publish it with `measured` provenance, or (b) have the guard read the ConfigMap through
the API server rather than a projected volume, which makes 0 ms true. Until one is done, the
admission residual should be published as **unmeasured**, not 0.

---

## 9. Test evidence on the merged tree

All commands run in the governor worktree at `14d56cef`.

| Command | Result |
| :------ | :----- |
| `cd d2-signalloom/apps/fleet-manager && go test ./...` | **ok** — 194 tests pass, 1.432s (14 of them mesh/admission-specific) |
| `cd d2-signalloom/apps/node-capability-guard && go test ./...` | **ok** — 12 tests pass |
| `cd d2-signalloom/apps/stun-sentinel && go test ./...` | **ok** — 4 packages |
| `make -C d2-signalloom test-netassert` | **pass** — 10/10, exit 0, see section 5 for what it proves |
| `bash scripts/run-redteam-suite.sh` | **pass** — 15/15 scenarios, 0 escapes, 0 leaks, exit 0 |

**The red-team suite does not exercise phase 3.** Its 15 scenarios are the CRKC phase-4 freeze,
Landlock, and TC set (CPU saturation, fork bomb, D-state, Landlock traversal, Flux drift, audited
resumption). Searching the emitted proof JSON for `mesh|admission|conntrack|readmission` returns
zero matches. It is a valid regression gate for the merge and no more than that.

The suite rewrites `docs/signalloom/evidence/adversarial-redteam-proof.json` on every run. The only
field that changed was `generated`; all 15 verdicts were byte-identical. Reverted, so this card's
commit stays scoped.

### 9a. **Build regression introduced by P3-1**

`cd d2-signalloom/apps/fleet-manager && go test ./...` — one of the two loop-until-green commands —
**fails on a clean checkout of this branch**:

```
../stun-sentinel/pkg/tc/bpf_embed.go:25:12: pattern tc_drop.bpf.o: no matching files found
FAIL  .../fleet-manager [setup failed]
```

The absent object is a pre-existing stun-sentinel condition, already recorded at proposal line 371
(owner P4-PRE) and in the SLER-P1-GOV review. What is *new* is its blast radius. Verified:

```
$ git grep -l 'stun-sentinel/pkg/tc' bcfbc39c -- d2-signalloom/apps/fleet-manager/   # pre-P3-1
rc=1                                                                                  # no match
$ git grep -l 'stun-sentinel/pkg/tc' HEAD    -- d2-signalloom/apps/fleet-manager/
HEAD:d2-signalloom/apps/fleet-manager/mesh_client.go
HEAD:d2-signalloom/apps/fleet-manager/mesh_client_test.go
```

`651bbbfc` imported `stun-sentinel/pkg/tc` into `mesh_client.go` to reach `tc.FlushIP` and
`tc.ErrNoConntrackEntries`, and thereby propagated stun-sentinel's build failure into fleet-manager,
which compiled cleanly before. Note that `mesh_client.go` needs only the conntrack helpers; the
eBPF ELF embed it drags in is unrelated to conntrack.

The object is untracked and always will be by accident: the developer's **global** gitignore carries
a bare `*.o` (`/home/andy/.gitignore_global:13`), so `bpf/build.sh` output is silently never added.
A prior errata entry (proposal line 475) claims the artefact was "placed in `pkg/tc/` to resolve the
pre-existing build dependency" — it was placed in the *principal checkout*, where it survives, and
is absent from every fresh worktree.

**How the green above was obtained, stated plainly.** I copied the object from the principal
checkout into this worktree as a build input:

```
sha256  f75e8790f9824a40fc71d12d66822ad965ef793b9540d7eea3a68a256284b4d9
file    ELF 64-bit LSB relocatable, eBPF, version 1 (SYSV), with debug_info, not stripped
```

`git status --porcelain` reports zero lines before and after, because the object is globally
ignored — nothing was committed and nothing can be. The fleet-manager green in the table above is
therefore **conditional on an untracked local artefact** and would not reproduce in CI or on another
machine. I did not commit a build artefact: prior governance recorded that as the principal's call,
and I have not overridden it.

**Owner:** P4-PRE already owns producing the object. Add to its scope, or to the P3 remediation
card, whichever lands first: either commit the artefact with a `!*.bpf.o` negation in the repo
`.gitignore`, or decouple `mesh_client.go` from the embedding package so conntrack does not require
an eBPF ELF.

---

## 10. Residuals carried into phase 4 and 5

1. **Neither plane is invoked by the cascade.** Blocks C5, C7. P4-3's governance-gated resume
   inherits it. (§4a)
2. **The admission webhook is in no kustomization and is not deployed.** (§4b)
3. **fleet-manager does not build from a clean checkout.** (§9a)
4. **netassert has no containment case.** The boundary proof this phase was asked for does not yet
   exist as a test. (§5)
5. **Admission worst-case residual is published as 0 ms and should not be.** P5-2 must not consume
   it as-is. (§8)
6. **`ipv4_scoped` is a hardcoded constant** in the mesh plane result. (§6)
7. **Two representations of "contained"** — pod label vs store entry — with no invariant asserting
   they agree. Latent while §4 holds; live the moment it is fixed. (§3)

---

## 11. Verdict

Phase 3 delivered two well-engineered enforcement clients. `failurePolicy: Fail` is explicit and
correctly reasoned. The contained-identity store is genuinely shared rather than duplicated. The
IPv4 scope is handled honestly in code. Both planes are attestation-ready. 206 Go tests pass.

None of that is enforcement, because nothing calls it and nothing deploys it. The phase is certified
as **built and correct, not integrated and not proven**. I am not signing off C5 or C7, and I am
qualifying C3 and C4 rather than passing them clean.

Phase 4 may proceed on the freeze plane, which is independent. **P4-GOV must not certify the
reversible stun/unstun lifecycle until residual 1 is closed**, because a resume that restores the
freeze plane while leaving a stale admission-store entry is the exact split-brain this card was
asked to prevent — and today it cannot even be tested.
