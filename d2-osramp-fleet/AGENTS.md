# AGENTS.md — d2-osramp-fleet (Flux fleet definitions)

Platform team's fleet configuration. Defines clusters, tenants, and
ResourceSets for the Flux Operator. Reconciled as cluster admin.

## Stack

| Component | Tech | Path |
|-----------|------|------|
| Cluster definitions | Flux Operator CRDs | `clusters/` |
| Tenant definitions | ResourceSets + RBAC | `tenants/` |
| Local overlay | Kind-specific config | `local/` |
| Terraform (optional) | AWS/GCP fleet | `terraform/` |
| Makefile | Fleet-specific targets | `Makefile` |

## Key Concepts

- **ResourceSets** define which D2 slices deploy to which clusters/namespaces
- Tenant files at `tenants/local/signalloom.yaml` are the **sole** source for
  Signal Loom's Flux reconciliation — `d2-signalloom/` carries no duplicate
- The fleet Makefile validates rendering without a cluster

## Pitfalls

- This directory has **admin** cluster access — changes here can break all slices
- ResourceSet `readyExpr` gates need careful validation (`status.observedGeneration >= 0` is not a readiness proof)
- The `signalloom.yaml` tenant file must remain byte-identical to any copy in `d2-signalloom/fleet/` — topology BATS enforces this
- Terraform state is not committed; `terraform/` is for reference/bootstrap only
