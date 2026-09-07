# AGENTS.md — d2-osramp-fleet (Flux Fleet Definitions)

This slice provides the fleet configuration for the platform team.
It defines clusters, tenants, and ResourceSets for the Flux Operator.
Flux reconciles these manifests with cluster-admin privileges.

## Stack

| Component | Technology | Path |
|---|---|---|
| Cluster definitions | Flux Operator CRDs | `clusters/` |
| Tenant definitions | ResourceSets and RBAC | `tenants/` |
| Local overlay | Kind cluster configuration | `local/` |
| Terraform | Cloud fleet automation | `terraform/` |
| Makefile | Fleet build targets | `Makefile` |

## Key Concepts

- **ResourceSets** specify which D2 slices deploy to target clusters and namespaces.
- The file `tenants/local/signalloom.yaml` is the single source for Signal Loom Flux reconciliation.
- The fleet Makefile checks manifest rendering without connecting to a cluster.

## Common Pitfalls

- Manifests in this directory apply with cluster-admin access.
- Review ResourceSet `readyExpr` expressions carefully. The expression `status.observedGeneration >= 0` does not prove readiness.
- Keep `signalloom.yaml` aligned across fleet directories. Topology tests enforce matching contents.
- Terraform state files are not committed to git.
