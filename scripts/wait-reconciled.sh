#!/usr/bin/env bash
# Wait for the shared cluster foundation: fleet sync, policy/infra ResourceSets,
# and shared infrastructure Kustomizations. Demo resources are deliberately
# excluded and start only through their explicit lifecycle targets.
set -euo pipefail

resources=(
  Kustomization/flux-system/flux-system
  ResourceSet/flux-system/policies
  ResourceSet/flux-system/infra
  Kustomization/cert-manager/infra-controllers
  Kustomization/cert-manager/infra-configs
  Kustomization/ingress/infra-controllers
  Kustomization/ingress/infra-configs
  Kustomization/monitoring/infra-controllers
  Kustomization/monitoring/infra-configs
  Kustomization/trivy-system/infra-controllers
  Kustomization/trivy-system/infra-configs
)

for resource in "${resources[@]}"; do
  kind=$(echo "$resource" | cut -d/ -f1)
  namespace=$(echo "$resource" | cut -d/ -f2)
  name=$(echo "$resource" | cut -d/ -f3)
  echo "waiting for ${kind}/${name} in ${namespace}"
  kubectl -n "$namespace" wait "$kind/$name" --for=condition=ready --timeout=10m
done

echo "reconciliation converged"
