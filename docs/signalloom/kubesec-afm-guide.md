# KubeSec-AFM — Access & Understanding Guide

KubeSec-AFM is a formal-methods engine from ControlPlane (KTP with King's College
London) that model-checks Kubernetes RBAC for privilege escalation and **collusion**
— groups of subjects (users, groups, service accounts) that can *exchange*
permissions to jointly reach a higher-privileged role.

## Quick access

```bash
# Port-forward (if not already running)
kubectl -n fe-k8s-afm port-forward svc/afm-platform 18000:8000

# Dashboard (Next.js UI)
open http://localhost:18000/dashboard/

# API health
curl http://localhost:18000/health

# Swagger / OpenAPI docs
open http://localhost:18000/docs
```

The Signal Loom dashboard's **Collusion & Access** page
(`http://localhost:5173/collusion-access`) is the governance view that will
consume AFM data. Currently it shows mock data from the platform dashboard;
the bridge from AFM's API to Signal Loom is the next integration step.

## Architecture

Single pod (`fe-k8s-afm/afm-platform`), single-process:

| Component | Stack | Port |
| :---- | :---- | :---- |
| Backend API | FastAPI + Z3 bounded model checker | 8000 |
| Frontend dashboard | Next.js 16 (static export) | 8000 `/dashboard/` |
| Job queue | In-process (SQLite) | — |
| Cluster store | In-memory + SQLite | — |

No external database required. Clusters are seeded via the API and persisted in
SQLite within the pod.

## How it works

### Analysis phases

1. **Phase 1 — Admin & self-escalation removal**: Drop subjects who are already
   `cluster-admin` or can self-escalate via the `escalate` verb — they have no
   incentive to collude.

2. **Phase 1.5 — Impersonation check**: Test escalation through impersonation,
   including a group impersonating a service account in another namespace.

3. **Phase 2 — Collusion escalation (Z3 BMC)**: Bounded model checking over the
   RBAC graph. For each pair of non-admin subjects, the Z3 solver tests whether
   they can exchange permissions (via shared roles, role bindings, or transitive
   bindings) to jointly reach a goal role that neither could reach alone.

### Key outputs

- **Escalation paths**: Pairs of subjects that jointly escalate, with the pivot
  role, goal reached, and trace depth.
- **Shared-role pivot points**: Roles shared by multiple subjects that act as
  attack surface — the point where permissions transfer between colluders.
- **Remediation priorities**: Min-cut / max-flow analysis weighted by CVSS + EPSS
  to prioritise which bindings to remove or scope down.
- **RBAC conformance**: Verb validation, overprivileged roles, and CIS benchmark
  alignment.

## API reference (key routes)

```
GET  /clusters                              List all imported clusters
POST /clusters/upload                       Upload a cluster YAML/JSON (multipart)
POST /clusters/import                       Import a cluster (JSON body)
GET  /clusters/{id}/rbac                    Full RBAC data for a cluster
GET  /clusters/{id}/rbac/graph              RBAC graph (nodes + edges)
POST /clusters/{id}/analysis/escalation     Start a Z3 escalation analysis (async job)
GET  /clusters/{id}/analysis/status         Check if analysis is running
GET  /clusters/{id}/analysis/latest         Get the latest completed analysis result
GET  /clusters/{id}/analysis/overlaps       Role overlap analysis
GET  /clusters/{id}/analysis/shared_roles   Shared-role pivot points
GET  /clusters/{id}/analysis/guards         Generated OPA/Gatekeeper guards
POST /clusters/{id}/rbac/paths              Query reachability paths
POST /clusters/{id}/rbac/rightsizing        Right-sizing recommendations
GET  /clusters/{id}/rbac/conformance        RBAC conformance report
GET  /health                                Health check
GET  /docs                                  Swagger UI
```

## Lifecycle commands

```bash
# Full lifecycle via make targets
make demo-k8s-afm-up        # Build image, kind-load, deploy, seed sample data
make demo-k8s-afm-status    # Check pods + /health
make demo-k8s-afm-test      # Run 218 backend tests (pytest)
make demo-k8s-afm-down      # Remove the D2 slice

# Or directly via the lifecycle script
scripts/k8s-afm.sh up       # Build + deploy + seed
scripts/k8s-afm.sh down     # Remove
scripts/k8s-afm.sh test     # Backend pytest suite
scripts/k8s-afm.sh seed     # Re-seed sample clusters
scripts/k8s-afm.sh status   # Pods + health
```

## Seeding cluster data

AFM accepts cluster RBAC data in two formats:

```bash
# JSON (via /clusters/import)
curl -X POST http://localhost:18000/clusters/import \
  -H "Content-Type: application/json" \
  -d @cluster.json

# YAML (via /clusters/upload, multipart form)
curl -X POST http://localhost:18000/clusters/upload \
  -F "file=@cluster.yaml"
```

Sample clusters are in the source repo at
`$KUBESEC_AFM_ROOT/AFM/backend/samples/clusters/`.

To import the live osramp cluster's RBAC into AFM:

`/clusters/import` expects the **converted** AFM import object
(`{id, name, rbac: {subjects, roles, bindings}}`), not raw `kubectl -o json`
output. Posting the raw `List` is rejected with HTTP 400, so pipe the export
through `scripts/rbac-to-afm.py` first:

```bash
# Export current cluster RBAC and convert it to the AFM import shape
kubectl get clusterroles,clusterrolebindings,roles,rolebindings \
  -A -o json | python3 scripts/rbac-to-afm.py > /tmp/osramp-rbac.json

# Import into AFM
curl -X POST http://localhost:18000/clusters/import \
  -H "Content-Type: application/json" \
  -d @/tmp/osramp-rbac.json
```

## Running an analysis

```bash
# Start escalation analysis (async — returns a job_id)
curl -X POST http://localhost:18000/clusters/{cluster_id}/analysis/escalation

# Poll for completion
curl http://localhost:18000/clusters/{cluster_id}/analysis/status
# → {"has_running": false, "last_completed_job_id": "..."}

# Get results
curl http://localhost:18000/clusters/{cluster_id}/analysis/latest | jq .
```

Z3 analysis time depends on cluster complexity. Small clusters (< 20 subjects)
complete in seconds; production-sized clusters (200+ subjects, 50+ roles) may take
30–120 seconds.

## Source repository

```
$KUBESEC_AFM_ROOT    # default: /home/andy/src/cp/kubesec-afm
├── AFM/
│   ├── backend/     # FastAPI + Z3 engine
│   ├── frontend/    # Next.js dashboard
│   ├── docker/      # Dockerfiles
│   ├── Makefile     # setup, test, build, lint
│   └── scripts/     # seed-demo.sh, etc.
└── ai-pipeline/     # ML/AI pipeline (separate)
```

## Current state

| Item | Status |
| :---- | :---- |
| Backend API | Running in-cluster (`fe-k8s-afm`) |
| Frontend dashboard | Accessible at `/dashboard/` |
| Sample clusters seeded | 5 clusters (prod, demo, sample1, usage_sample, user) |
| Z3 analysis | Functional (tested on sample1) |
| Live cluster import | **Done** — `afm-cluster-import` CronJob (`*/30 * * * *`) imports the live cluster's own RBAC as cluster `local`; see `apps/afm-platform/base/cluster-import.yaml` |
| Signal Loom bridge — RBAC Explorer / Importer | **Done** — see `docs/signalloom/rbac-live-wiring.md` |
| Signal Loom bridge — Collusion & Access page | Not yet — still shows mock data (separate from the RBAC Explorer bridge above) |
| Persistent storage | SQLite in-pod (ephemeral — data lost on pod restart) |

## Next steps

1. **Bridge Collusion & Access page**: Replace the mock `COLLUSION_PAIRS` /
   `PIVOTS` / `REMEDIATIONS` in `CollusionAccessPage.tsx` with live data —
   the RBAC Explorer bridge (`docs/signalloom/rbac-live-wiring.md`) is a
   working reference for the same pattern (server-side correlation behind
   `/api/*`, not client-side stitching).

2. **Persistent storage**: Connect AFM to the shared PostgreSQL in `inf-signalloom`
   so cluster data and analysis results survive pod restarts.

3. **Guard generation**: AFM can generate OPA/Gatekeeper policies from its
   findings (`/clusters/{id}/analysis/guards`). Integrate these into the kyverno
   admission pipeline.
