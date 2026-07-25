# Signalloom D2 delivery slice

This subtree is the split-ready, non-production Signalloom D2 delivery
boundary. It contains no Flux bootstrap configuration and cannot create a
second control plane. `d2-osramp-fleet` remains the sole local fleet authority.

## Ownership

| Path | Owner | Responsibility |
| --- | --- | --- |
| `fleet/` | Fleet integration | ResourceSet source and local composition contract only. |
| `infra/` | Infrastructure | `inf-bao` and `inf-signalloom` component roots. |
| `apps/` | Application delivery | `fe-signalloom` component root and future vendored portal source. |
| `contracts/` | Cross-slice | Generated and reviewed delivery contracts. |
| `test/` | Cross-slice | Static topology and render validation. |

The active local-fleet copy is intentionally kept at
`d2-osramp-fleet/tenants/local/signalloom.yaml`: Flux can only reconcile files
inside the fleet OCI artifact. Keep it byte-for-byte aligned with
`fleet/local/signalloom.yaml`; `make test` verifies that composition boundary.

## Validation

```shell
make test
```

This validates only the skeleton and local rendering boundary. It does not
bootstrap Flux, publish artifacts, create a cluster, or deploy workloads.
