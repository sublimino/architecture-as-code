#!/usr/bin/env bash
# Composable, deliberately narrow lifecycle operations for the Signal Loom demo.
set -euo pipefail

readonly BAO_NAMESPACE="${BAO_NAMESPACE:-inf-bao}"
readonly SIGNALLOOM_NAMESPACE="${SIGNALLOOM_NAMESPACE:-fe-signalloom}"
readonly CONSUMER_LABEL="bao.controlplane.io/consumer"
readonly CONSUMER_QUERY='kustomizations.kustomize.toolkit.fluxcd.io,ocirepositories.source.toolkit.fluxcd.io'

usage() {
  cat <<'EOF'
Usage: demo-lifecycle.sh <bao-up|bao-down|bao-test|signalloom-up|signalloom-down|signalloom-test|flux-test|stack-purge>
EOF
}

require_command() { command -v "$1" >/dev/null 2>&1 || { printf 'required command unavailable: %s\n' "$1" >&2; exit 1; }; }

wait_kustomization() {
  local namespace="$1" name="$2"
  flux reconcile kustomization "$name" -n "$namespace" --with-source
  kubectl -n "$namespace" wait "kustomization/$name" --for=condition=ready --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
}

reconcile_slice() {
  local namespace="$1"
  require_command kubectl
  require_command flux
  kubectl get namespace "$namespace" >/dev/null
  wait_kustomization "$namespace" infra-controllers
  wait_kustomization "$namespace" infra-configs
}

delete_slice() {
  local namespace="$1" source_name="$2"
  require_command kubectl
  # These Flux-owned objects are exactly the selected slice. Deleting them asks
  # Flux to prune their owned resources without touching the shared Kind cluster.
  kubectl -n "$namespace" delete kustomization infra-configs infra-controllers --ignore-not-found --wait=true
  kubectl -n "$namespace" delete ocirepository "$source_name" --ignore-not-found --wait=true || true
  kubectl delete namespace "$namespace" --ignore-not-found --wait=true
}

bao_up() { reconcile_slice "$BAO_NAMESPACE"; }
bao_down() { delete_slice "$BAO_NAMESPACE" inf-bao; }
signalloom_up() {
  reconcile_slice inf-signalloom
  require_command kubectl
  require_command flux
  flux reconcile kustomization apps -n "$SIGNALLOOM_NAMESPACE" --with-source
  kubectl -n "$SIGNALLOOM_NAMESPACE" wait kustomization/apps --for=condition=ready --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
}
signalloom_down() {
  require_command kubectl
  kubectl -n "$SIGNALLOOM_NAMESPACE" delete kustomization apps --ignore-not-found --wait=true
  kubectl -n "$SIGNALLOOM_NAMESPACE" delete ocirepository fe-signalloom --ignore-not-found --wait=true
  kubectl delete namespace "$SIGNALLOOM_NAMESPACE" --ignore-not-found --wait=true
}

flux_test() {
  require_command kubectl
  kubectl get resourceset -n flux-system signalloom-infra signalloom-apps -o json >/dev/null
  for pair in "$BAO_NAMESPACE:infra-controllers" "$BAO_NAMESPACE:infra-configs" inf-signalloom:infra-controllers inf-signalloom:infra-configs "$SIGNALLOOM_NAMESPACE:apps"; do
    IFS=: read -r namespace name <<<"$pair"
    kubectl -n "$namespace" wait "kustomization/$name" --for=condition=ready --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
  done
}

no_bao_consumers() {
  require_command kubectl
  require_command jq
  local state
  if ! state=$(kubectl get "$CONSUMER_QUERY" -A -l "$CONSUMER_LABEL" -o json 2>&1); then
    printf 'refusing Bao removal: consumer state is unavailable or unknown\n%s\n' "$state" >&2
    return 1
  fi
  # Require structurally valid, exact-label observations before trusting an empty set.
  if ! jq -e --arg label "$CONSUMER_LABEL" '
      (.items | type == "array") and
      all(.items[]; (.metadata.labels[$label] | type == "string") and length > 0)
    ' <<<"$state" >/dev/null; then
    printf 'refusing Bao removal: consumer state is malformed or unknown\n' >&2
    return 1
  fi
  local consumers
  consumers=$(jq -r '.items[] | [.kind, .metadata.namespace, .metadata.name] | @tsv' <<<"$state")
  if [[ -n "$consumers" ]]; then
    printf 'refusing Bao removal: Bao consumers remain\n%s\n' "$consumers" >&2
    return 1
  fi
}

stack_purge() {
  signalloom_down
  if [[ "${DEMO_BAO_FORCE:-0}" != 1 ]]; then
    no_bao_consumers
  fi
  bao_down
}

case "${1:-}" in
  bao-up) bao_up ;;
  bao-down) bao_down ;;
  bao-test) exec "$(dirname "$0")/bao-spire-proof.sh" ;;
  signalloom-up) signalloom_up ;;
  signalloom-down) signalloom_down ;;
  signalloom-test) flux_test ;;
  flux-test) flux_test ;;
  stack-purge) stack_purge ;;
  *) usage; exit 64 ;;
esac
