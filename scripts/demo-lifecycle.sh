#!/usr/bin/env bash
# Composable, deliberately narrow lifecycle operations for the Signal Loom demo.
set -euo pipefail

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
  local bundle x y der public_key public_keys_csv coordinate value jwk
  local -a jwks public_keys
  bundle=$(kubectl -n "$BAO_NAMESPACE" exec deployment/spire-server -- \
    /opt/spire/bin/spire-server bundle show -format spiffe)
  mapfile -t jwks < <(jq -r '.keys[] | select(.use == "jwt-svid" and .kty == "EC" and .crv == "P-256") | [.x, .y] | @tsv' <<<"$bundle")
  ((${#jwks[@]} > 0)) || {
    printf 'SPIRE bundle contains no P-256 JWT-SVID validation key\n' >&2
    return 1
  }
  for jwk in "${jwks[@]}"; do
    IFS=$'\t' read -r x y <<<"$jwk"
    der=$(mktemp)
    {
      # SubjectPublicKeyInfo header for an uncompressed P-256 public key.
      printf '\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00\x04'
      for coordinate in "$x" "$y"; do
        value="${coordinate//-/+}"
        value="${value//_/\/}"
        case $((${#value} % 4)) in
          2) value="${value}==" ;;
          3) value="${value}=" ;;
        esac
        printf '%s' "$value" | base64 -d
      done
    } >"$der"
    public_key=$(openssl pkey -pubin -inform DER -in "$der" -outform PEM) || {
      rm -f "$der"
      return 1
    }
    rm -f "$der"
    public_keys+=("$public_key")
  done
  printf -v public_keys_csv '%s,' "${public_keys[@]}"
  public_keys_csv="${public_keys_csv%,}"
  kubectl -n "$BAO_NAMESPACE" exec deployment/openbao -- env \
    BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_ROOT_TOKEN" \
    bao write auth/jwt/config jwt_validation_pubkeys="$public_keys_csv"
}

bao_up() {
  require_command kubectl
  require_command flux
  kubectl get namespace "$BAO_NAMESPACE" >/dev/null
  wait_kustomization "$BAO_NAMESPACE" infra-controllers
  # SPIRE join tokens are single-use. Delete the agent pod FIRST so no
  # CrashLoopBackOff pod can consume the token we're about to generate.
  kubectl -n "$BAO_NAMESPACE" delete pod -l app.kubernetes.io/name=spire-agent --ignore-not-found --wait=true
  bootstrap_spire_agent_join_token
  # The DaemonSet recreates the agent pod, which reads the fresh token.
  # OpenBao uses ephemeral local storage in this demo. Re-run its idempotent
  # bootstrap after reconciliation so a restarted server regains JWT auth.
  kubectl -n "$BAO_NAMESPACE" delete job openbao-spire-bootstrap --ignore-not-found --wait=true
  wait_kustomization "$BAO_NAMESPACE" infra-configs
  kubectl -n "$BAO_NAMESPACE" wait job/openbao-spire-bootstrap --for=condition=complete --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
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
  kubectl -n inf-signalloom rollout status deployment/dex --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
  # Proof Jobs may have reached a terminal state before the SPIRE registration
  # created by bao_up became available. Recreate both exact proofs so this run
  # observes current identity state and scores expected denial as success.
  kubectl -n "$SIGNALLOOM_NAMESPACE" delete job \
    bao-spire-positive-proof bao-spire-negative-proof \
    --ignore-not-found --wait=true
  flux reconcile kustomization apps -n "$SIGNALLOOM_NAMESPACE" --with-source
  kubectl -n "$SIGNALLOOM_NAMESPACE" wait kustomization/apps --for=condition=ready --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
  kubectl -n "$SIGNALLOOM_NAMESPACE" rollout restart \
    deployment/fe-signalloom deployment/dashboard-signalloom
  kubectl -n "$SIGNALLOOM_NAMESPACE" rollout status deployment/fe-signalloom --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
  kubectl -n "$SIGNALLOOM_NAMESPACE" rollout status deployment/dashboard-signalloom --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
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
