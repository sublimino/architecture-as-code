# d2-infra

Infrastructure logical source directory for the Acme Co. OSRAMP demo. It defines the Kubernetes cluster add-ons that the applications depend on, delivered as signed OCI artifacts and reconciled by Flux as the cluster admin. It pairs with `d2-osramp-fleet` (cluster and tenant definitions) and `d2-osramp-apps` (the OSRAMP application services); these are monorepo directories, not separate Git repositories.

## Scope and access control

This logical source directory is owned by the platform team. It defines infrastructure components such as:

- Cluster add-ons (CRD controllers, admission controllers, monitoring)
- Cluster-wide definitions (namespaces, gateway classes, RBAC)

It is reconciled on the cluster fleet by Flux as the cluster admin, so access is restricted to the platform team.

## Components

| Component | Contents |
| --- | --- |
| `cert-manager` | cert-manager controller plus a self-signed cluster issuer and a wildcard cluster certificate. A production deployment would swap the issuer for ACME with a DNS01 solver. |
| `ingress` | Envoy Gateway with a cluster-wide Gateway (HTTP redirected to HTTPS, TLS from the cluster certificate). |
| `monitoring` | kube-prometheus-stack (Prometheus and Grafana with the Flux dashboards) and metrics-server. Monitors opt in with the `osramp.acme.co/scrape: Enabled` label. |

## Directory structure

- The `components` dir contains the Flux HelmReleases for cluster add-ons with custom configuration per environment.
- The `update-policies` dir contains the Flux configuration for automating OCI chart updates of the Helm releases.

A cluster component is defined in a directory with the following structure:

```sh
component/
├── controllers # CRD definitions and controllers
│   ├── base # common definitions (Namespaces, RBAC, HelmRepositories, HelmReleases)
│   ├── preview # ephemeral preview environment values
│   ├── production # production specific HelmRelease values
│   └── staging # staging specific HelmRelease values
└── configs # Custom Resources of controllers
    ├── base # common definitions
    ├── preview # ephemeral preview environment values
    ├── production # production specific values
    └── staging # staging specific values
```

The CRDs and their controllers are reconciled before the custom resources so the controllers are ready to process them.

## OCI artifacts

Each component is published to a dedicated OCI repository under this project's registry namespace and is tagged as:

- `latest` for main branch commits that modify the component.
- `vX.Y.Z` for release tags matching the Git tag format `<component>/vX.Y.Z`.
- `latest-stable`, which points to the latest `vX.Y.Z` artifact.

The workflows in `.github/workflows` publish and sign the artifacts:

- `push-artifact`: on commits to main, publishes the component artifact tagged `latest` to GHCR and signs it with cosign keyless.
- `release-artifact`: on `<component>/vX.Y.Z` tags, publishes the versioned artifact and moves `latest-stable`.
- `image-updates`: opens the PR to main when Flux update automation pushes the `image-updates` branch.
