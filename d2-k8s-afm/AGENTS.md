# AGENTS.md — d2-k8s-afm (KubeSec-AFM D2 integration)

KubeSec-AFM: formal-methods RBAC privilege-escalation analysis platform.
KTP with King's College London. Runs in isolation in `fe-k8s-afm` namespace.

## Stack

| Component | Tech | Path |
|-----------|------|------|
| Backend | FastAPI + Z3 BMC engine | `apps/k8s-afm/` |
| Tests | pytest (218 tests) | `apps/k8s-afm/tests/` |
| K8s manifests | Kustomize | `apps/k8s-afm/base/`, `local/` |
| BATS | Integration tests | `test/` |

## Lifecycle

```bash
make demo-k8s-afm-up        # Build image, kind-load, deploy, seed sample data
make demo-k8s-afm-status    # Check pods + /health
make demo-k8s-afm-test      # Run 218 backend tests (pytest)
make demo-k8s-afm-down      # Remove the slice
```

## What it does

The Z3-based bounded model checker analyses Kubernetes RBAC for:

1. **Self-escalation**: subjects that can elevate their own privileges (escalate verb)
2. **Impersonation**: cross-namespace impersonation (unscoped pre-1.36)
3. **Collusion**: pairs of subjects that can exchange permissions to jointly escalate
4. **Remediation priority**: min-cut / max-flow analysis weighted by CVSS + EPSS

## Pitfalls

- Z3 solver is CPU-intensive — 70 min on a 14-core laptop for a full production cluster
- Currently RBAC-only (no pod exec, node escape, secrets inference)
- Groups treated as entities — no user↔group membership inference
- The dashboard page at `/collusion-access` shows mock data; live engine output will plumb in later
