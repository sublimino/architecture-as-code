#!/usr/bin/env bash
# Composable, deliberately narrow lifecycle operations for the Signal Loom demo.
set -euo pipefail

# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"
# shellcheck source=scripts/lib/spire-trust-anchor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/spire-trust-anchor.sh"

readonly BAO_NAMESPACE="${BAO_NAMESPACE:-inf-bao}"
readonly BAO_ROOT_TOKEN="${BAO_ROOT_TOKEN:-signalloom-demo-root-token}"
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
  wait_flux_ready kustomization "$name" -n "$namespace" 600
}

reconcile_slice() {
  local namespace="$1"
  require_command kubectl
  require_command flux
  wait_k8s_exists namespace "$namespace" 120
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

bootstrap_spire_agent_join_token() {
  local output token
  output=$(kubectl -n "$BAO_NAMESPACE" exec deployment/spire-server -- /opt/spire/bin/spire-server token generate \
    -spiffeID "spiffe://signalloom.demo/agent/kind" 2>&1) || {
    printf 'failed to generate local SPIRE agent join token\n%s\n' "$output" >&2
    return 1
  }
  if [[ ! "$output" =~ Token:[[:space:]]+([^[:space:]]+) ]]; then
    printf 'SPIRE token generation returned no token\n%s\n' "$output" >&2
    return 1
  fi
  token="${BASH_REMATCH[1]}"
  kubectl -n "$BAO_NAMESPACE" create secret generic spire-agent-join-token \
    --from-literal=token="$token" --dry-run=client -o yaml | kubectl apply -f -
}

register_spire_proof_identity() {
  local server=(kubectl -n "$BAO_NAMESPACE" exec deployment/spire-server -- /opt/spire/bin/spire-server)
  if "${server[@]}" entry show -spiffeID "spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom" \
    -parentID "spiffe://signalloom.demo/agent/kind" -selector k8s:ns:fe-signalloom -selector k8s:sa:fe-signalloom \
    | grep -Fq 'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom'; then
    return 0
  fi
  "${server[@]}" entry create \
    -spiffeID "spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom" \
    -parentID "spiffe://signalloom.demo/agent/kind" \
    -selector k8s:ns:fe-signalloom -selector k8s:sa:fe-signalloom
}

configure_openbao_jwt_validation() {
  require_command jq
  require_command openssl
  sync_openbao_jwt_validation "$BAO_NAMESPACE" "$BAO_ROOT_TOKEN"
}

bao_up() {
  require_command kubectl
  require_command flux
  wait_k8s_exists namespace "$BAO_NAMESPACE" 120
  wait_kustomization "$BAO_NAMESPACE" infra-controllers
  # A Kustomization being Ready does not mean its pods are Ready — the exec-based
  # bootstrap below (into spire-server/openbao) fails if the pod is still
  # ContainerCreating. Wait for the deployments to be available first.
  wait_k8s_ready deployment spire-server -n "$BAO_NAMESPACE" --for condition=available 300
  wait_k8s_ready deployment openbao -n "$BAO_NAMESPACE" --for condition=available 300
  # A projected Secret update can start the agent before the replacement token
  # is ready. Remove the old secret first so its replacement pod stays pending,
  # then publish exactly one token for that new pod.
  kubectl -n "$BAO_NAMESPACE" delete secret spire-agent-join-token --ignore-not-found
  kubectl -n "$BAO_NAMESPACE" delete pod -l app.kubernetes.io/name=spire-agent --ignore-not-found --wait=true
  bootstrap_spire_agent_join_token
  # Everything below assumes the agent can actually talk to THIS server. If
  # spire-server was rebuilt, the agent's hostPath still trusts the old CA and
  # crash-loops — and re-running bao-up cannot fix it, because nothing here
  # clears that directory. Refuse with the recovery sequence instead of pressing
  # on to register entries and sync keys against an identity plane that is down.
  assert_spire_agent_trusts_server "$BAO_NAMESPACE"
  # OpenBao uses ephemeral local storage in this demo. Re-run its idempotent
  # bootstrap after reconciliation so a restarted server regains JWT auth.
  kubectl -n "$BAO_NAMESPACE" delete job openbao-spire-bootstrap --ignore-not-found --wait=true
  wait_kustomization "$BAO_NAMESPACE" infra-configs
  wait_k8s_ready job openbao-spire-bootstrap -n "$BAO_NAMESPACE" --for condition=complete 600
  register_spire_proof_identity
  configure_openbao_jwt_validation
}
bao_down() { delete_slice "$BAO_NAMESPACE" inf-bao; }
signalloom_up() {
  reconcile_slice inf-signalloom
  require_command kubectl
  require_command flux
  # ConfigMap-backed Dex credentials and locally rebuilt workload images do not
  # alter Deployment pod templates. Restart only these demo workloads so every
  # supported local up observes the just-reconciled configuration and images.
  kubectl -n inf-signalloom rollout restart deployment/dex
  sleep 2  # Avoid "restart already triggered within past second" race
  wait_rollout dex -n inf-signalloom 600
  # Proof Jobs may have reached a terminal state before the SPIRE registration
  # created by bao_up became available. Recreate both exact proofs so this run
  # observes current identity state and scores expected denial as success.
  kubectl -n "$SIGNALLOOM_NAMESPACE" delete job \
    bao-spire-positive-proof bao-spire-negative-proof \
    --ignore-not-found --wait=true
  flux reconcile kustomization apps -n "$SIGNALLOOM_NAMESPACE" --with-source
  wait_flux_ready kustomization apps -n "$SIGNALLOOM_NAMESPACE" 600
  kubectl -n "$SIGNALLOOM_NAMESPACE" rollout restart \
    deployment/fe-signalloom deployment/dashboard-signalloom
  wait_rollout fe-signalloom -n "$SIGNALLOOM_NAMESPACE" 600
  wait_rollout dashboard-signalloom -n "$SIGNALLOOM_NAMESPACE" 600
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
    wait_flux_ready kustomization "$name" -n "$namespace" 600
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
  if [[ "${DEMO_BAO_FORCE:-0}" != 1 ]]; then
    no_bao_consumers
  fi
  signalloom_down
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
