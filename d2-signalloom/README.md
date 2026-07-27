# Signalloom D2 delivery slice

This subtree is the split-ready, non-production Signalloom D2 delivery
boundary. It contains no Flux bootstrap configuration and cannot create a
second control plane. `d2-osramp-fleet` remains the sole local fleet authority.

## Ownership

| Path | Owner | Responsibility |
| --- | --- | --- |
| `infra/` | Infrastructure | `inf-bao` and `inf-signalloom` component roots. |
| `apps/` | Application delivery | `fe-signalloom` component root and future vendored portal source. |
| `contracts/` | Cross-slice | Generated and reviewed delivery contracts. |
| `test/` | Cross-slice | Static topology and render validation. |

The Signal Loom tenant ResourceSet lives solely in the fleet at
`d2-osramp-fleet/tenants/local/signalloom.yaml`: Flux can only reconcile files
inside the fleet OCI artifact. This slice carries no duplicate copy; `make test`
validates the fleet-owned source directly.

## Validation

```shell
make test
```

This validates only the skeleton and local rendering boundary. It does not
bootstrap Flux, publish artifacts, create a cluster, or deploy workloads.
