#!/usr/bin/env bash
# Wait for the local GitOps reconciliation to converge: the fleet sync, the
# tenant ResourceSets, and the per-tenant Kustomizations.
set -euo pipefail

resources=(
  Kustomization/flux-system/flux-system
  ResourceSet/flux-system/policies
  ResourceSet/flux-system/infra
  ResourceSet/flux-system/apps
  ResourceSet/flux-system/olly
  ResourceSet/flux-system/signalloom-infra
  ResourceSet/flux-system/signalloom-apps
  Kustomization/backend/apps
  Kustomization/frontend/apps
  Kustomization/trivy-system/infra-configs
  Kustomization/olly-replica/olly-configs
  Kustomization/inf-bao/infra-controllers
  Kustomization/inf-bao/infra-configs
  Kustomization/inf-signalloom/infra-controllers
  Kustomization/inf-signalloom/infra-configs
  Kustomization/fe-signalloom/apps
)

for resource in "${resources[@]}"; do
  kind=$(echo "$resource" | cut -d/ -f1)
  namespace=$(echo "$resource" | cut -d/ -f2)
  name=$(echo "$resource" | cut -d/ -f3)
  echo "waiting for ${kind}/${name} in ${namespace}"
  kubectl -n "$namespace" wait "$kind/$name" --for=condition=ready --timeout=10m
done

echo "reconciliation converged"
