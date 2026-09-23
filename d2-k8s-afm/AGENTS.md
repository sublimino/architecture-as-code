# AGENTS.md — d2-k8s-afm (KubeSec-AFM integration)

KubeSec-AFM is a formal-methods analysis platform for Kubernetes RBAC privilege
escalation. It runs as an isolated workload in the `fe-k8s-afm` namespace. The
human guide is [`README.md`](README.md).

The backend source is not in this repository. It is in the separate
`kubesec-afm` checkout. `make demo-k8s-afm-up` builds the image from
`$KUBESEC_AFM_ROOT` (see the caution in the [root guide](../AGENTS.md#d2-slices)).

## Stack

| Component | Technology | Path |
|---|---|---|
| Backend (external) | FastAPI with a Z3 bounded model checker | `$KUBESEC_AFM_ROOT` |
| Kubernetes manifests | Kustomize base and local overlay | [`apps/afm-platform/base/`](apps/afm-platform/base/), [`apps/afm-platform/local/`](apps/afm-platform/local/) |
| Integration tests | BATS suites | [`test/`](test/) |

## Lifecycle

```bash
make demo-k8s-afm-up        # Build the image, load it into Kind, deploy, and seed sample data
make demo-k8s-afm-status    # Show the pods and the /health endpoint
make demo-k8s-afm-test      # Run the backend pytest suite from the external source
make demo-k8s-afm-down      # Remove the slice
```

## Platform capabilities

The Z3 bounded model checker analyses Kubernetes RBAC for four risks:

1. **Self-escalation:** a subject can raise its own privileges with the `escalate` verb.
2. **Impersonation:** unscoped cross-namespace impersonation of users and service accounts.
3. **Collusion:** two subjects can combine their permissions to escalate.
4. **Remediation priority:** min-cut and max-flow graph analysis, weighted by CVSS and EPSS.

## Pitfalls

- The Z3 solver uses much CPU. An analysis of a full production cluster takes a long time.
- The engine analyses RBAC objects only. It does not examine container escapes or the contents of Secrets.
- The engine treats a group as one entity. It does not find the members of a group.
- The dashboard route `/collusion-access` shows mock data until the live engine connection is complete.
