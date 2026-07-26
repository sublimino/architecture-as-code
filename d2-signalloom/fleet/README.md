# Signalloom fleet source

This directory defines the ResourceSets that the existing local OSRAMP fleet
composes. It deliberately contains neither a `FluxInstance` nor Flux Operator
bootstrap resources. The materialized local-fleet copy lives at
`../../d2-osramp-fleet/tenants/local/signalloom.yaml` so it is present in the
fleet OCI artifact consumed by the single active control plane.

`local/signalloom.yaml` owns namespace creation, runtime configuration,
registry credentials, Flux service accounts/RBAC, verified OCI sources and
ordered Kustomizations for `inf-bao`, `inf-signalloom`, and `fe-signalloom`.

## Tenant boundary

All three namespaces carry `toolkit.fluxcd.io/role: tenant`, so the fleet's
fail-closed Flux source allowlist applies to infrastructure as well as the
application. Each tenant `flux` service account is tokenless by default and is
bound to the namespace-scoped `admin` ClusterRole through a `RoleBinding`; no
Signalloom ResourceSet grants `cluster-admin` or a `ClusterRoleBinding`.

The component manifests are deliberately namespaced. A future component that
needs a cluster-scoped resource must be split into a separately reviewed
platform-owned reconciliation boundary rather than widening this tenant role.

## Network and verification boundary

Each Signalloom namespace starts with ingress and egress default deny.
`fe-signalloom` can resolve DNS and reach only PostgreSQL, Redis, MinIO, and
the selected OpenBao endpoint; the dependency namespace accepts only the three
declared backing-service ports from the portal; Bao/SPIRE permits local control
traffic plus the labelled portal consumer to OpenBao port 8200. Gateway ingress
is limited to `envoy-gateway-system`.

The bounded Bao proof is intentionally two-sided: `fe-signalloom` must read
its one seeded non-production secret, while `fe-signalloom-negative` must fail
identity issuance. The runtime proof script requires the positive Job to
complete and the negative Job to fail with `denied as expected`. Static
regression coverage lives in `test/least-privilege.bats`; it is not a claim
that the policies have been exercised against a live cluster.
