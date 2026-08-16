# Signal Loom D2 delivery slice

Split-ready, non-production delivery boundary. This subtree has no Flux
bootstrap configuration and cannot create a second control plane.
`d2-osramp-fleet` is the sole local fleet authority.

## Ownership

| Path | Owner | Responsibility |
| --- | --- | --- |
| `infra/` | Infrastructure | `inf-bao` and `inf-signalloom` component roots. |
| `apps/` | Application delivery | `fe-signalloom` API and discovery portal. `dashboard-signalloom` React SPA. |
| `contracts/` | Cross-slice | Generated and reviewed delivery contracts. |
| `test/` | Cross-slice | Static topology and render validation. |

The Signal Loom tenant ResourceSet is in the fleet only, at
`d2-osramp-fleet/tenants/local/signalloom.yaml`. Flux reconciles files
inside the fleet OCI artifact. This slice has no duplicate copy. `make test`
validates the fleet-owned source directly.

## Validation

```shell
make test
```

Validates the skeleton and local rendering boundary. Does not bootstrap Flux,
publish artifacts, create a cluster, or deploy workloads.

## Architecture

For a visual overview of all 28 services, their dependencies, and data flows,
see the [interactive isometric system map](../docs/system-map/).

```bash
python3 -m http.server 8901 -d docs/system-map   # from repo root
```
