# AGENTS.md — d2-osramp-fleet (Flux fleet definitions)

This slice is the fleet configuration of the platform team. It defines the
clusters, the tenants, and the ResourceSets of the Flux Operator. The human
guide is [`README.md`](README.md).

## Stack

| Component | Technology | Path |
|---|---|---|
| Cluster definitions | Flux Operator CRDs, one directory per cluster | [`clusters/`](clusters/) |
| Tenant definitions | ResourceSets and RBAC | [`tenants/`](tenants/) |
| Local registry | The in-cluster Zot registry | [`local/zot.yaml`](local/zot.yaml) |
| Terraform | Cloud fleet bootstrap | [`terraform/`](terraform/) |
| Makefile | Registry and bootstrap targets | [`Makefile`](Makefile) |

## Key concepts

- A ResourceSet tells Flux which D2 slices to deploy to which clusters and namespaces.
- [`tenants/local/signalloom.yaml`](tenants/local/signalloom.yaml) is the one
  source for the Signal Loom Flux reconciliation. It has no copy in another
  fleet directory.
- The tenant files in [`tenants/base/`](tenants/base/) set the identity of each
  tenant. The `infra` and `olly` tenants get `cluster-admin`. The `apps` tenant
  gets only the namespace `admin` role.

## Makefile targets

Each target in the fleet Makefile changes a cluster or a registry. None of them
is a dry run.

| Target | Action |
|---|---|
| `make -C d2-osramp-fleet zot-up` | Deploy the in-cluster Zot registry |
| `make -C d2-osramp-fleet bootstrap-local` | Install the Flux Operator and sync from Zot |
| `make -C d2-osramp-fleet push` | Push the manifests to GitHub Container Registry |
| `make -C d2-osramp-fleet bootstrap-staging` | Install the Flux Operator on the staging cluster |
| `make -C d2-osramp-fleet bootstrap-production` | Install the Flux Operator on the production cluster |
| `make -C d2-osramp-fleet bootstrap-update` | Install the Flux Operator on the image-update cluster |

For local work, use `make up` at the repository root. It runs the local steps.

## Pitfalls

- The manifests in this directory apply with `cluster-admin` access.
- Review each ResourceSet `readyExpr` with care. The expression
  `status.observedGeneration >= 0` does not prove readiness.
- Git does not hold the Terraform state files.
