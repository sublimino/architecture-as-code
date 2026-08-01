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

# This build check is the only thing that catches a positional JSON patch whose
# index has drifted — tenants/local/kustomization.yaml attaches cosign verify to
# each ResourceSet's OCIRepository BY ARRAY INDEX, and any commit that inserts a
# resource earlier in the list silently retargets the patch. That is exactly how
# signalloom-apps came to patch /spec/resources/10 (a ClusterRole, which has no
# .spec) after 141a757 shifted its OCIRepository to 12, breaking every deploy
# from the integration branch with "doc is missing path ... missing value".
#
# It was gated behind `command -v kustomize`, so on any host without the
# standalone binary the entire check evaporated silently and the drift shipped.
# kubectl has an equivalent built in, so there is no excuse for skipping: prefer
# standalone kustomize, fall back to `kubectl kustomize`, and fail loudly if
# neither exists rather than reporting a pass that was never actually tested.
if command -v kustomize >/dev/null 2>&1; then
  kustomize_build() { kustomize build --load-restrictor=LoadRestrictionsNone "$1" >/dev/null; }
elif command -v kubectl >/dev/null 2>&1; then
  kustomize_build() { kubectl kustomize --load-restrictor LoadRestrictionsNone "$1" >/dev/null; }
else
  printf 'neither kustomize nor kubectl found; cannot validate kustomize builds.\n' >&2
  exit 1
fi

kustomize_build "$root/d2-osramp-fleet/tenants/local"
for path in \
  d2-signalloom/infra/inf-bao/controllers/local \
  d2-signalloom/infra/inf-bao/configs/local \
  d2-signalloom/infra/inf-signalloom/controllers/local \
  d2-signalloom/infra/inf-signalloom/configs/local \
  d2-signalloom/apps/fe-signalloom/local; do
  kustomize_build "$root/$path"
done

printf 'Signalloom D2 topology validation passed.\n'
