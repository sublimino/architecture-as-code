# AGENTS.md — d2-k8s-afm (KubeSec-AFM Integration)

KubeSec-AFM is a formal-methods analysis platform for Kubernetes RBAC privilege escalation.
It runs as an isolated workload in the `fe-k8s-afm` namespace.

## Stack

| Component | Technology | Path |
|---|---|---|
| Backend | FastAPI with Z3 BMC engine | `apps/k8s-afm/` |
| Tests | Pytest test suite | `apps/k8s-afm/tests/` |
| Kubernetes manifests | Kustomize overlays | `apps/k8s-afm/base/`, `local/` |
| Integration tests | BATS test suites | `test/` |

## Lifecycle

```bash
make demo-k8s-afm-up        # Build image, load into Kind, deploy, and seed sample data
make demo-k8s-afm-status    # Check pod readiness and /health endpoint
make demo-k8s-afm-test      # Run backend pytest suite
make demo-k8s-afm-down      # Remove the slice
```

## Platform Capabilities

The Z3 bounded model checker analyzes Kubernetes RBAC for four risks:

1. **Self-escalation:** Subjects that can elevate their own privileges using the `escalate` verb.
2. **Impersonation:** Unscoped cross-namespace user and service account impersonation.
3. **Collusion:** Pairs of subjects that can combine permissions to escalate privileges.
4. **Remediation priority:** Min-cut and max-flow graph analysis weighted by CVSS and EPSS metrics.

## Common Pitfalls

- The Z3 solver is CPU-intensive. Full production cluster analysis requires significant time.
- The engine analyzes RBAC objects only. It does not inspect container escapes or secrets contents.
- Groups act as atomic entities. The engine does not infer user group memberships.
- The dashboard route `/collusion-access` displays mock data until live engine plumbing completes.
