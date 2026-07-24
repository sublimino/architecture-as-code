# d2-osramp-apps

> [!NOTE]
> This repository is the application tenant of the Acme Co. OSRAMP demo,
> following the Flux D2 reference architecture together with the
> `d2-osramp-fleet` and `d2-infra` directories of the monorepo.

## Scope and Access Control

This repository is managed by the dev teams who are responsible for
the delivery of applications to the Kubernetes cluster fleet.

This repository is used to define the application components such as:

- Flux HelmRepositories (pointing to the application Helm charts in container registries)
- Flux HelmReleases for the applications with custom configuration per environment

This repository is reconciled on the cluster fleet by Flux as the **namespace admin**
and can't contain Kubernetes cluster-wide definitions such as CRDs, Cluster Roles, Namespaces, etc.

The platform team that manages the `d2-osramp-fleet` directory assigns the
namespaces to the dev teams and configures Flux with the RBAC to reconcile
these components across the cluster fleet. Cluster-wide resources the
applications depend on (CRD controllers, gateway classes, monitoring) live in
`d2-infra`.

Access is restricted to the dev teams and the Flux bot account; the bot should
be the only account with direct push access to the `main` branch.

## Quickstart

The full environment is built from the repository root:

```bash
cd ..            # the monorepo root
make up          # cluster, registry, keys, signed artifacts, Flux, images
make test        # end-to-end suite
```

For tight inner-loop work on the services themselves, this repository has a
direct path that bypasses GitOps:

```bash
make cluster-up      # kind cluster (skip if make up already created it)
kubectl create ns frontend
make signing-key     # ed25519 key the processor signs attestations with
make local-dev       # apply backend + frontend manifests directly
make build           # build the three images and load them into kind
make test            # bats end-to-end suite
```

## Repository Structure

This repository contains the following directories:

- The **components** dir contains Flux HelmReleases that define how the applications
  are deployed to the cluster fleet and which configuration should be used for each environment.
- The **update-policies** dir contains the Flux policies for automating the application's
  version updates of the OCI charts referred in Helm releases.

The application components are grouped by namespace, and are defined in a directory with the following structure:

```sh
./components/
└── namespace (e.g. frontend, backend)
    ├── base
    │   ├── kustomization.yaml
    │   └── release1.yaml
    │   └── release2.yaml
    ├── local (inherits from *staging*)
    │   ├── kustomization.yaml
    │   └── release1.yaml
    │   └── release2.yaml
    ├── production (inherits from base)
    │   ├── kustomization.yaml
    │   ├── release1-values.yaml
    │   └── release2-values.yaml
    └── staging (inherits from base)
        ├── kustomization.yaml
        ├── release1-values.yaml
        └── release2-values.yaml
```

Each namespace is independently reconciled on clusters and can
contain multiple HelmReleases with custom configuration per environment.
