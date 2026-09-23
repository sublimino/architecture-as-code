# AGENTS.md — d2-osramp-apps (OSRAMP application slice)

This slice is the application tenant of the Acme Co. OSRAMP demonstration. Flux
reconciles it into the `frontend` and `backend` namespaces. The human guide is
[`README.md`](README.md).

## Stack

| Component | Technology | Path |
|---|---|---|
| Archiver | Go service | [`apps/archiver/`](apps/archiver/) |
| Listener | Go service | [`apps/listener/`](apps/listener/) |
| Processor | Go service (Witness attestation signer) | [`apps/processor/`](apps/processor/) |
| Components | Kustomize and Flux HelmRelease manifests for `frontend` and `backend` | [`components/`](components/) |
| Image policies | Flux `ImageRepository` and `ImagePolicy` objects | [`update-policies/`](update-policies/) |
| Tests | BATS suites | [`test/`](test/) |

The `ImageUpdateAutomation` that uses the image policies is in
[`../d2-osramp-fleet/clusters/update/`](../d2-osramp-fleet/clusters/update/).

## Lifecycle

```bash
make demo-osramp-up           # Deploy the OSRAMP frontend and backend
make demo-osramp-test         # Run the manifest checks and the BATS acceptance tests
make demo-osramp-down         # Remove OSRAMP. The foundation stays.
```

## Testing

```bash
make demo-osramp-test-config        # Check the manifests without a running slice
make demo-osramp-test               # Run the full acceptance tests on a running cluster
bats d2-osramp-apps/test/osramp.bats  # Run the BATS suite directly
```

## Resource scope

Flux applies this slice with the ServiceAccount `flux` in each tenant namespace.
That account has only the namespace `admin` role
([`../d2-osramp-fleet/tenants/base/apps.yaml`](../d2-osramp-fleet/tenants/base/apps.yaml)).
It cannot make a cluster-scoped object. Put CRDs, ClusterRoles, and Namespaces
in [`../d2-infra/`](../d2-infra/).

CAUTION: `components/backend/base/` contains `minio-operator.yaml` and
`minio-tenant.yaml`. These files define Namespaces, CRDs, a ClusterRole, and a
ClusterRoleBinding. No `kustomization.yaml` includes them, so Flux does not
apply them. Do not add them to the backend kustomization. The tenant identity
cannot apply them, and the reconciliation then fails.

## Pitfalls

- The licence is Apache 2.0.
- The processor signs attestations with an ed25519 key. `make workload-key` at
  the repository root makes it. The slice target `make -C d2-osramp-apps signing-key`
  makes the Secret `signing-key` in `frontend` directly with `kubectl`.
- The image policies poll their registries. `frontend-podinfo` polls every 10
  minutes. `backend-redis` and `backend-memcached` poll every 12 hours.
