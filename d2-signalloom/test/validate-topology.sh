#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Single canonical Signal Loom tenant ResourceSet, owned by the fleet — Flux
# reconciles only files inside the fleet OCI artifact.
canonical="$root/d2-osramp-fleet/tenants/local/signalloom.yaml"

required=(
  d2-signalloom/infra/inf-bao/controllers/local/kustomization.yaml
  d2-signalloom/infra/inf-bao/configs/local/kustomization.yaml
  d2-signalloom/infra/inf-signalloom/controllers/local/kustomization.yaml
  d2-signalloom/infra/inf-signalloom/configs/local/kustomization.yaml
  d2-signalloom/apps/fe-signalloom/local/kustomization.yaml
  d2-osramp-fleet/tenants/local/signalloom.yaml
)

for path in "${required[@]}"; do
  test -f "$root/$path"
done

grep -Fqx '  - signalloom.yaml' "$root/d2-osramp-fleet/tenants/local/kustomization.yaml"
grep -Fq 'name: signalloom-infra' "$canonical"
grep -Fq 'name: signalloom-apps' "$canonical"
grep -Fq 'namespace: inf-signalloom' "$canonical"
grep -Fq 'bao.controlplane.io/consumer: fe-signalloom' "$canonical"
if grep -R --include='*.yaml' -Eq 'kind: (FluxInstance|HelmRelease).*' "$root/d2-signalloom"; then
  printf 'd2-signalloom delivery slice must not bootstrap a Flux control plane.\n' >&2
  exit 1
fi

if command -v kustomize >/dev/null 2>&1; then
  kustomize build "$root/d2-osramp-fleet/tenants/local" >/dev/null
  for path in \
    d2-signalloom/infra/inf-bao/controllers/local \
    d2-signalloom/infra/inf-bao/configs/local \
    d2-signalloom/infra/inf-signalloom/controllers/local \
    d2-signalloom/infra/inf-signalloom/configs/local \
    d2-signalloom/apps/fe-signalloom/local; do
    kustomize build "$root/$path" >/dev/null
  done
fi

printf 'Signalloom D2 topology validation passed.\n'
