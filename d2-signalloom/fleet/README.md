# Signalloom fleet source

This directory defines the ResourceSets that the existing local OSRAMP fleet
composes. It deliberately contains neither a `FluxInstance` nor Flux Operator
bootstrap resources. The materialized local-fleet copy lives at
`../../d2-osramp-fleet/tenants/local/signalloom.yaml` so it is present in the
fleet OCI artifact consumed by the single active control plane.

`local/signalloom.yaml` owns namespace creation, runtime configuration,
registry credentials, Flux service accounts/RBAC, verified OCI sources and
ordered Kustomizations for `inf-bao`, `inf-signalloom`, and `fe-signalloom`.
