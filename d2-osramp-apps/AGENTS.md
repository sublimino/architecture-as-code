# AGENTS.md — d2-osramp-apps (OSRAMP application slice)

Application tenant of the Acme Co. OSRAMP demo. Namespace-scoped app delivery
managed by dev teams; reconciled by Flux as namespace admin.

## Stack

| Component | Tech | Path |
|-----------|------|------|
| Archiver | Go | `apps/archiver/` |
| Listener | Go | `apps/listener/` |
| Processor | Go (witness attestation signer) | `apps/processor/` |
| HelmReleases | Flux HelmRelease CRDs | `components/` |
| Update policies | ImageUpdateAutomation | `update-policies/` |
| Tests | BATS | `test/` |

## Lifecycle

```bash
make demo-osramp-up          # Deploy OSRAMP frontend + backend
make demo-osramp-test         # Static manifests + acceptance BATS
make demo-osramp-down         # Remove OSRAMP; keep foundation
```

## Testing

```bash
make demo-osramp-test-config  # Validate manifests without a running slice
make demo-osramp-test         # Full acceptance (needs running cluster)
bats test/osramp.bats         # Direct BATS run
```

## Scope

This slice defines only namespace-scoped resources (HelmRepositories,
HelmReleases, application configs). It cannot contain cluster-wide
definitions (CRDs, ClusterRoles, Namespaces) — those live in `d2-infra/`.

## Pitfalls

- `LICENSE` is Apache 2.0 (differs from other slices which may not have one)
- Processor signs attestations with the ed25519 key from `make workload-key`
- Image update policies trigger on registry pushes — beware in local dev
