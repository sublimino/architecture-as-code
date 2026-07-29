# d2-k8s-afm — KubeSec-AFM D2 Integration

Standalone deployment of the [KubeSec-AFM](https://github.com/controlplaneio/kubesec-afm)
RBAC privilege-escalation analysis platform in the OSRAMP demo cluster.
Runs in isolation in the `fe-k8s-afm` namespace.

## Quick start

```bash
make demo-k8s-afm-up      # Build image, kind-load, deploy, seed sample data
make demo-k8s-afm-status   # Check pods + /health
make demo-k8s-afm-test     # Run 218 backend tests (pytest)
make demo-k8s-afm-down     # Remove the D2 slice
```

## What's inside

| Component | Stack | Details |
|-----------|-------|---------|
| Backend | FastAPI + Z3 BMC engine | RBAC escalation analysis, job queue, MCP server |
| Frontend | Next.js 16 (static export) | Served at `/dashboard` by the backend |
| API | 29 routes | `/clusters`, `/clusters/{id}/rbac`, `/clusters/{id}/analysis/escalation`, etc. |
| Image | `kubesec-afm:latest` | Built from `controlplaneio/kubesec-afm` v1 branch |

## Access

```bash
kubectl -n fe-k8s-afm port-forward svc/afm-platform 8000:8000
# Dashboard: http://localhost:8000/dashboard
# API health: http://localhost:8000/health
# Swagger:   http://localhost:8000/docs
```

Or via the cluster gateway: `https://afm.osramp.acme.local/dashboard`

## Architecture

Single pod, single-process topology: FastAPI serves the Next.js static export
+ the Z3 BMC engine + the optional MCP server — all on port 8000. No external
database: uses SQLite for job storage + in-memory cluster store. Sample clusters
auto-load at boot from bundled YAML.

## Tests

- **Backend pytest**: 218 tests (unit + integration + e2e + API) — `make demo-k8s-afm-test`
- **Frontend**: TypeScript typecheck (`npm run typecheck`)
- **Smoke**: `bats d2-k8s-afm/test/afm-smoke.bats` (5 live-cluster assertions)
- **Contract**: `scripts/check-types.sh` in the source repo (OpenAPI ↔ frontend types drift)

## Bridging (future)

This D2 is allowed to bridge to Signal Loom's shared infrastructure:
- **Postgres** (`inf-signalloom`) for persistent cluster storage
- **Redis** (`inf-signalloom`) for job queue
- **OpenBao** (`inf-bao`) for SPIFFE workload identity (KTP integration)
