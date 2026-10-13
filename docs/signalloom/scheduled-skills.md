# Scheduled-Run Skills for Signal Loom

This document defines the scheduled-run skills for the Signal Loom
platform (`#partner-signal-loom`). These skills extract recurring operational
routines from historical development and debugging sessions. They run on
deterministic schedules or on demand.

## Architecture

The skills follow the Matt Pocock skill design principles. They use leading words,
strict information hierarchy, progressive disclosure, and verified completion criteria.

```mermaid
flowchart TD
  CRON["Scheduled Triggers<br/>(Cron / Harness)"] --> RUNNER["Skill Invocation Layer"]
  MANUAL["Manual User / Agent Call<br/>(/cp-sl-*)"] --> RUNNER

  RUNNER --> DRIFT["cp-sl-drift-reconcile<br/>(GitOps & Flux Drift)"]
  RUNNER --> INGRESS["cp-sl-portforward-supervisor<br/>(Durable Port 5173 & Proxies)"]
  RUNNER --> AUDIT["cp-sl-silent-failure-audit<br/>(17 Silent Invariant Checks)"]
  RUNNER --> GUARD["cp-sl-containment-guard<br/>(Stun & GitOps Suspension)"]
  RUNNER --> PYRAMID["cp-sl-pyramid-verify<br/>(Offline Test Pyramid)"]
  RUNNER --> GOV["cp-sl-worktree-governor<br/>(Multi-Agent Worktrees)"]
  RUNNER --> SWEEP["cp-sl-eap-evidence-sweep<br/>(EAP Compliance Evidence)"]
  RUNNER --> DSWEEP["cp-sl-drift-sweep<br/>(Two-Axis Drift & Smell Sweep)"]

  DRIFT --> CLUSTER["Kind Cluster / Flux Control Plane"]
  INGRESS --> CLUSTER
  GUARD --> CLUSTER
  SWEEP --> EVIDENCE["Evidence Store<br/>(docs/signalloom/evidence/)"]
  PYRAMID --> REPO["Local Repository & Contracts"]
  DSWEEP --> REPO
  GOV --> WORKTREES["Worktree Storage<br/>(~/src/.worktrees/)"]
```

## Skill Catalog

The table lists the eight scheduled-run skills.

| Skill Name | Cadence | Trigger Phrase | Primary Invariants Checked |
|---|---|---|---|
| `cp-sl-drift-reconcile` | `*/30 * * * *` | `/cp-sl-drift-reconcile` | Flux Kustomization state, patch index drift, unresolved `${VAR}` tokens |
| `cp-sl-portforward-supervisor` | `*/15 * * * *` | `/cp-sl-portforward-supervisor` | Port 5173 binding, Dex redirect URI reachability, in-pod proxy responses |
| `cp-sl-silent-failure-audit` | `0 */4 * * *` | `/cp-sl-silent-failure-audit` | CRI layer verification (`crictl`), audit SQL AST match, route collisions |
| `cp-sl-containment-guard` | `*/15 * * * *` | `/cp-sl-containment-guard` | GitOps suspension annotation, H1 forensic probe suppression, DAG sync |
| `cp-sl-pyramid-verify` | `0 3 * * *` | `/cp-sl-pyramid-verify` | Documentation linting, Vitest suites, Go controller tests, schema sync |
| `cp-sl-worktree-governor` | `0 */6 * * *` | `/cp-sl-worktree-governor` | Dirty worktrees preservation, branch divergence, Kanban controller leases |
| `cp-sl-eap-evidence-sweep` | `0 6 * * *` | `/cp-sl-eap-evidence-sweep` | Cosign signatures, SLSA provenance, SPDX SBOMs, audit row continuity |
| `cp-sl-drift-sweep` | `0 4 * * *` | `/cp-sl-drift-sweep` | Two-axis Standards and Spec review, boilerplate deduplication, proposal sprawl |

## Skill Details

### 1. `cp-sl-drift-reconcile`

Reconciles in-cluster Flux state against committed git artifacts.
It audits array index drift in `d2-osramp-fleet/tenants/local/kustomization.yaml`.
It detects unexpanded `${VAR}` tokens in applied manifests.

Executable tool:
```bash
bash .agents/skills/cp-sl-drift-reconcile/Tools/drift-audit.sh
```

### 2. `cp-sl-portforward-supervisor`

Supervises the systemd user service `signalloom-portforward.service`.
It recovers dropped SPDY connections after pod rollouts.
It executes in-pod diagnostics across `/fleet-api/v1/fleet/topology` and `/api/v1/health`.

Executable tool:
```bash
bash .agents/skills/cp-sl-portforward-supervisor/Tools/portforward-check.sh
```

### 3. `cp-sl-silent-failure-audit`

Audits the 17 silent failure patterns cataloged from platform debugging.
It queries `crictl images` to confirm image layers exist in the container runtime.
It checks that all `_audit_log` call sites in `api_compat.py` match database constraints.
It verifies that no nginx proxy prefix shadows React Router paths in `App.tsx`.

Executable tool:
```bash
bash .agents/skills/cp-sl-silent-failure-audit/Tools/audit-invariants.sh
```

### 4. `cp-sl-containment-guard`

Enforces containment integrity on stunned agent workloads.
It verifies that each stunned deployment has `kustomize.toolkit.fluxcd.io/reconcile: disabled`.
Without this annotation, Flux reconciles the workload and destroys containment.
It confirms that Fleet Manager in-memory DAG state matches live topology endpoints.

Executable tool:
```bash
bash .agents/skills/cp-sl-containment-guard/Tools/check-containment.sh
```

### 5. `cp-sl-pyramid-verify`

Runs the entire offline test battery without requiring a running cluster.
It checks documentation style through `make docs-lint`.
It runs 160+ Vitest specs and Python contract tests through `make test-all-offline`.
It asserts zero drift between database migrations and `discovery-portal-bootstrap.sql`.

Executable tool:
```bash
bash .agents/skills/cp-sl-pyramid-verify/Tools/pyramid-runner.sh
```

### 6. `cp-sl-worktree-governor`

Audits active git worktrees across `~/src/.worktrees/` and `~/.cline/worktrees/`.
It identifies uncommitted files and unpushed commits before any cleanup.
It runs `scripts/kanban-check.sh doctor --repo .` to clear stale controller leases.

Executable tool:
```bash
bash .agents/skills/cp-sl-worktree-governor/Tools/worktree-audit.sh
```

### 7. `cp-sl-eap-evidence-sweep`

Audits cryptographic and supply chain evidence for EAP customer pilots.
It verifies SHA256 image digests, SPDX 2.3 SBOMs, and SLSA provenance files.
It verifies that the PostgreSQL `audit_events` table maintains active row insertion.

Executable tool:
```bash
bash .agents/skills/cp-sl-eap-evidence-sweep/Tools/evidence-sweep.sh
```

### 8. `cp-sl-drift-sweep`

Audits repository history across the Standards and Spec review axes.
It detects duplicated HTTP lifecycle boilerplate, file churn hotspots, and micro-proposal sprawl.
It pauses after generating the Cleanup Job Manifest unless `--auto` or `/goal` is set.
When approved or in `--auto` mode, it dispatches isolated worktree subagents with mutation proofs.

Executable tool:
```bash
bash .agents/skills/cp-sl-drift-sweep/Tools/drift-sweep.sh
```

## Concurrent Test Execution

The repository provides a parallel runner that executes all eight skills concurrently.
It captures isolated logs, reports an aggregated status table, and exits non-zero if any
invariant check fails:

```bash
make test-scheduled-skills-parallel
```

The script can also run directly:

```bash
./scripts/test-scheduled-skills-parallel.sh
```

## Scheduler Configuration

The schedules are registered in `.claude/scheduled_tasks.json`.
Each entry contains the cron expression, prompt contract, and target skill identifier.
