#!/usr/bin/env bash
# healthcheck.sh — verify the shared cluster foundation before any demo starts.
set -euo pipefail

# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

timeout="${CLUSTER_HEALTHCHECK_TIMEOUT:-5m}"

echo "checking Kubernetes API server"
kubectl get nodes >/dev/null || {
  echo "cluster healthcheck failed: Kubernetes API server is unreachable" >&2
  exit 1
}

echo "checking Kubernetes node readiness"
if ! kubectl wait --for=condition=Ready nodes --all --timeout="$timeout"; then
  echo "cluster healthcheck failed: one or more Kubernetes nodes are not Ready" >&2
  exit 1
fi

resources=(
  Kustomization/flux-system/flux-system
  ResourceSet/flux-system/policies
  ResourceSet/flux-system/infra
)

for resource in "${resources[@]}"; do
  kind="${resource%%/*}"
  remainder="${resource#*/}"
  namespace="${remainder%%/*}"
  name="${remainder##*/}"
  echo "checking ${kind}/${name} in ${namespace}"
  wait_flux_ready "$kind" "$name" -n "$namespace" 300
done

# Ready=True is necessary but NOT sufficient. Flux leaves an unsubstituted
# ${VAR} as a literal and still reports the object healthy, so every check above
# can pass against an estate that cannot actually reconcile. Assert that no
# tokens survived before declaring the foundation healthy.
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-flux-substitution.sh"

echo "cluster foundation is healthy; no demos are running"
