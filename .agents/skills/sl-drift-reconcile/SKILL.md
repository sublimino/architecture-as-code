---
name: sl-drift-reconcile
description: "Scheduled-run GitOps and cluster drift reconciler for #partner-signal-loom. Reconciles Flux ResourceSets and Kustomizations against git HEAD, audits JSON6902 patch indexes, and checks Zot artifacts. USE WHEN gitops drift, reconcile signal loom, flux drift, flux reconcile, patch index drift, cluster drift, sl-drift-reconcile, or on schedule '*/30 * * * *'."
---

# sl-drift-reconcile

Scheduled GitOps and cluster drift reconciliation for the **Signal Loom** (`#partner-signal-loom`) platform on Kind and cloud environments.

### Separation from Sibling Skills
- **`sl-drift-reconcile` (this skill)**: Audits live in-cluster Kubernetes state and Flux reconciliation against committed git artifacts (`git rev-parse HEAD`).
- **`sl-drift-sweep`**: Audits static codebase health, Fowler code smells, multi-agent file churn, and micro-proposal sprawl across git commit history.

## Loop Lens & Schedule Contract

- **Cadence**: `*/30 * * * *` (Every 30 minutes, or pre-flight before testing/demo).
- **Trigger**: Cron notification, `/sl-drift-reconcile`, or manual trigger "reconcile signal loom".
- **Checkpoint**: Push right. Perform full read-only inspection autonomously. Only halt with a brief if destructive reconciliation or git merge intervention is required.
- **Brief**: Emit a 4-bullet executive status: (1) Flux revision vs git HEAD, (2) Patch index integrity, (3) Variable substitution completeness, (4) Recommended heal command.

---

## Mandate & Non-Negotiable Invariants

1. **Git Authority (Zero Silent Drift)**:
   - In-cluster state must strictly track committed git artifacts (`git rev-parse HEAD`).
   - Manual `kubectl apply` interventions are treated as transient defects and surfaced immediately.

2. **Patch Index Stability**:
   - JSON6902 patch indexes in `tenants/local/kustomization.yaml` addressing `/spec/resources/N/spec/verify` must point strictly to `OCIRepository` targets. Any offset shift caused by inserted resources is a fatal blocking drift.

3. **Substitutions Complete**:
   - `postBuild.substituteFrom` tokens must resolve. Any literal `${VAR}` remaining in applied cluster objects indicates missing ConfigMap entries (`flux-runtime-info`) and triggers reconciliation failure.

4. **Signature & Image Verifiability**:
   - Container images and OCI artifacts must be signed via Cosign. Local artifacts must match local verification keys.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Reconcile.md`](Workflows/Reconcile.md)
- **Patch Rule Reference**: [`References/FluxPatchRules.md`](References/FluxPatchRules.md)
- **Executable Auditor**: [`Tools/drift-audit.sh`](Tools/drift-audit.sh)

---

## Execution Sequence

1. **Pre-flight & Authority Check**:
   - Verify cluster connectivity: `kubectl cluster-info`.
   - Check local git repository status: `git status --porcelain`.
   - Capture current HEAD commit SHA: `GIT_HEAD=$(git rev-parse HEAD)`.

2. **Flux Controller & Kustomization Inspection**:
   - Execute `flux get kustomizations -n flux-system`.
   - Check for stalled or failing Kustomizations (`Ready != True`).
   - Extract last applied revision and compare against `GIT_HEAD`.

3. **Kustomize JSON6902 Patch Index Audit**:
   - Inspect `d2-osramp-fleet/tenants/local/kustomization.yaml`.
   - Assert each `/spec/resources/N/spec/verify` targets an `OCIRepository`.
   - Run `bats d2-signalloom/test/fleet-patch-indexes.bats` if test harness present.

4. **Unresolved Variable Token Scan**:
   - Scan applied ConfigMaps, Deployments, and HTTPRoutes for raw `${` patterns.
   - If `${` exists, identify the missing ConfigMap or Secret in `substituteFrom`.

5. **Remediation & Report**:
   - If drift detected and safe to heal, trigger:
     ```bash
     flux reconcile kustomization tenants -n flux-system --with-source
     ```
   - If manual override conflict exists, report exact resource diff.

---

## Completion Criteria

- **Clarity**: Binary verdict (`DRIFT_FREE` or `DRIFT_DETECTED` with specific remediation action).
- **Demand**: All 4 invariant checks executed. Zero uninvestigated `${VAR}` tokens, patch indexes verified, and brief delivered.
