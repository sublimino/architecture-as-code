---
name: sl-local-deploy
description: "Local development and in-flight deployment pipeline for #partner-signal-loom. Builds, signs, synchronizes Kustomizations, loads Kind images, reconciles Flux, and proves deployment freshness. USE WHEN local deploy, deploy in-flight, deploy in flight, deploy to cluster, sl-local-deploy, /sl-local-deploy, dev deploy."
---

# sl-local-deploy

Developer deployment pipeline for in-flight and committed code changes on the **Signal Loom** (`#partner-signal-loom`) platform.

### Sibling Skill Boundaries
- **`sl-local-deploy` (this skill)**: Builds, packages, and rolls out in-flight code changes to the local Kind cluster.
- **`sl-drift-reconcile`**: Audits static GitOps drift between cluster state and committed Git HEAD.
- **`sl-portforward-supervisor`**: Monitors long-running ingress port-forward streams and detects dead sockets.

## Loop Lens & Contract

- **Cadence**: On-demand during local iteration, after code changes, or before browser verification.
- **Trigger**: `/sl-local-deploy`, `local deploy`, or `deploy in-flight`.
- **Checkpoint**: Push right. Inspect working tree, auto-detect affected workloads, synchronize image patches, build, sign, and rollout.
- **Brief**: Emit a 4-bullet executive status: (1) Workloads built, (2) Image tags and signatures, (3) Rollout and port-forward status, (4) Staleness check proof.

---

## Core Invariants

1. **Zero Unobserved Drift**:
   Tests that inspect the source tree prove nothing about running pods.
   Every local deployment must finish with positive container readback proof via `scripts/check-deployed-staleness.sh`.

2. **Git Authority and Commit Invariants**:
   Flux OCI source artifacts track Git commits (`local@sha1:<git-rev>`).
   Uncommitted working tree changes produce `-dirty` fingerprints.
   Use the tool auto-commit mode to commit with scope-less conventional messages (`feat: ...`) and `--no-gpg-sign`.

3. **Kustomization Tag Synchronization**:
   Local overlays in `d2-signalloom/apps/fe-signalloom/local/kustomization.yaml` must stay aligned with current source fingerprints.
   Hardcoded legacy tags will cause Flux to roll back newly built images.

4. **Supply Chain Integrity**:
   Images and OCI artifacts must be signed with Cosign using `.keys/cosign.key`.
   The cluster trusts the matching public key in `flux-system/cosign-pub`.

5. **SPDY Port-Forward Healing**:
   Every deployment rollout terminates active `kubectl port-forward` streams.
   The deployment tool verifies HTTP responses on port 19080 and restarts listeners if severed.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/DeployInFlight.md`](Workflows/DeployInFlight.md)
- **Staleness Diagnostics**: [`Workflows/DiagnoseStaleness.md`](Workflows/DiagnoseStaleness.md)
- **Historical Pitfalls**: [`References/DeploymentPitfalls.md`](References/DeploymentPitfalls.md)
- **Executable Deployment Tool**: [`Tools/local-deploy.sh`](Tools/local-deploy.sh)

---

## Quick Usage

Run the deployment tool from repository root:

```bash
# Auto-detect modified workloads and deploy
.agents/skills/sl-local-deploy/Tools/local-deploy.sh

# Dry-run inspection of in-flight changes and deployed staleness
.agents/skills/sl-local-deploy/Tools/local-deploy.sh --dry-run

# Commit in-flight changes cleanly before deploying
.agents/skills/sl-local-deploy/Tools/local-deploy.sh --auto-commit

# Target specific workload
.agents/skills/sl-local-deploy/Tools/local-deploy.sh -w dashboard
.agents/skills/sl-local-deploy/Tools/local-deploy.sh -w backend
```
