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
   Non-zero exit codes halt deployment and propagate immediately.

2. **Git Authority and Commit Invariants**:
   Flux OCI source artifacts track Git commits (`local@sha1:<git-rev>`).
   Uncommitted working tree changes produce `-dirty` fingerprints.
   Use the tool auto-commit mode to commit with scope-less conventional messages (`feat: ...`) and `--no-gpg-sign`.

3. **Kustomization Tag Synchronization**:
   Local overlays in `d2-signalloom/apps/fe-signalloom/local/kustomization.yaml` must stay aligned with current source fingerprints.
   Hardcoded legacy tags will cause Flux to roll back newly built images.
   Deployments such as `signal-ingest` must have their immutable source tags pinned in manifests before GitOps packaging.

4. **Supply Chain Integrity**:
   Images and OCI artifacts must be signed with Cosign using `.keys/cosign.key`.
   The cluster trusts the matching public key in `flux-system/cosign-pub`.

5. **SPDY Port-Forward Healing**:
   Every deployment rollout terminates active `kubectl port-forward` streams.
   The deployment tool verifies HTTP responses on port 19080 and restarts listeners if severed.

6. **Node CRI Image Preflight**:
   Before restarting any deployment, the tool inspects whether required container images exist in the Kind cluster image store (`crictl inspecti` or `crictl images`).
   Missing image tags abort deployment immediately before rollout, preventing `ImagePullBackOff`.

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
.agents/skills/sl-local-deploy/Tools/local-deploy.sh -w ingest
.agents/skills/sl-local-deploy/Tools/local-deploy.sh -w fleet
.agents/skills/sl-local-deploy/Tools/local-deploy.sh -w warden
.agents/skills/sl-local-deploy/Tools/local-deploy.sh -w supercred-runner

# Deploy everything, including fleet, warden and supercred-runner
.agents/skills/sl-local-deploy/Tools/local-deploy.sh -w all
```

### Fleet, Warden and SuperCred-Runner Workloads

Three workloads beyond the core dashboard/backend/docs/ingest set, each wrapping an
existing make/script entry point rather than reimplementing it:

- **`fleet`** — `d2-osramp-fleet/**` changes (e.g. the agent-swarm ResourceSet). Pushes
  the fleet artifact (`scripts/push-local.sh fleet`) and reconciles the `tenants`
  Flux Kustomization. Without this, the cluster keeps running the old ResourceSet.
- **`warden`** — the signalloom-warden (sentinel) DaemonSet image. Runs
  `make -C d2-signalloom sentinel-image-publish CLUSTER_NAME=<cluster>`. Auto-detection
  reuses `scripts/sentinel-image-tag.sh`'s own COPY-source derivation
  (`scripts/lib/source-id.sh`'s `source_id_copied_paths`), so the detection glob
  cannot drift from the fingerprint the image tag is actually built from.
- **`supercred-runner`** — the `supercred-demo-runner` image. Runs
  `make demo-signalloom-supercred-runner-image`. Auto-detection likewise reuses the
  Dockerfile's own COPY sources (the same set `scripts/supercred-images.sh` builds
  from), which span `d2-signalloom/apps/{cardvault,policy-engine,fe-signalloom}` and
  `scripts/supercred-*.sh`/`scripts/lib`, not just its own app directory.

All three are included in `-w all` and honour `--dry-run` (inspect-only, no build/push).
`--no-reconcile` skips fleet's push+reconcile entirely. Warden and supercred-runner
still build and load under `--no-reconcile`, since neither depends on Flux. Their
underlying make/script binaries are injectable via `MAKE_BIN`, `PUSH_LOCAL_BIN` and
`FLUX_BIN` for testing, same as every other workload.
