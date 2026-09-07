# AGENTS.md — d2-osramp-apps (OSRAMP Application Slice)

This slice provides the application tenant for the Acme Co. OSRAMP demonstration.
It manages namespace-scoped application delivery. Flux reconciles these resources
using namespace-admin privileges.

## Stack

| Component | Technology | Path |
|---|---|---|
| Archiver | Go service | `apps/archiver/` |
| Listener | Go service | `apps/listener/` |
| Processor | Go service (Witness attestation signer) | `apps/processor/` |
| HelmReleases | Flux HelmRelease manifests | `components/` |
| Update policies | Flux ImageUpdateAutomation | `update-policies/` |
| Tests | BATS test suites | `test/` |

## Lifecycle

```bash
make demo-osramp-up          # Deploy OSRAMP frontend and backend
make demo-osramp-test         # Run manifest checks and BATS acceptance tests
make demo-osramp-down         # Remove OSRAMP while keeping foundation
```

## Testing

```bash
make demo-osramp-test-config  # Check manifests without a running cluster
make demo-osramp-test         # Run full acceptance tests against running cluster
bats test/osramp.bats         # Run BATS tests directly
```

## Resource Scope

This slice contains namespace-scoped resources only (HelmRepositories, HelmReleases,
and ConfigMaps). It does not contain cluster-scoped definitions (CRDs, ClusterRoles,
or Namespaces). Cluster-scoped resources belong in `d2-infra/`.

## Common Pitfalls

- License is Apache 2.0.
- The processor service signs attestations with the key created by `make workload-key`.
- Image update policies trigger on registry push events. Be aware during local development.
