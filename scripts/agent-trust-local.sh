#!/usr/bin/env bash
# Explicit, bounded lifecycle for the opt-in Agent Trust Flux ResourceSet.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly repo_root
# shellcheck disable=SC1091 # resolved relative to this script at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

readonly resource_set="agent-trust"
readonly flux_namespace="flux-system"
readonly bao_namespace="inf-bao"
readonly spire_parent_id="spiffe://signalloom.demo/agent/kind"
declare -A active_resourceset_inputs=()
readonly -a owned_namespaces=(
  agent-trust-platform
  agent-trust-tenant-acme-control
  agent-trust-tenant-northstar-control
  agent-trust-acme-payments
  agent-trust-acme-risk
  agent-trust-northstar-investigations
)
activation_pending=false
identity_configured=false
a2a_keys_created=false
a2a_namespace_created=false
root_reconciliation_suspended=false

rollback_failed_activation() {
  local status=$?
  trap - ERR
  if [[ "$activation_pending" == true ]]; then
    printf 'Agent Trust activation failed; restoring ResourceSet inputs to []\n' >&2
    if [[ "$identity_configured" == true ]]; then cleanup_identity_plane || true; fi
    kubectl -n "$flux_namespace" patch "resourceset/${resource_set}" --type merge \
      -p '{"spec":{"inputs":[]}}' >/dev/null 2>&1 || true
    kubectl -n "$flux_namespace" annotate "resourceset/${resource_set}" \
      reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null 2>&1 || true
    if [[ "$a2a_keys_created" == true ]]; then
      kubectl -n agent-trust-acme-payments delete secret agent-trust-a2a-private --ignore-not-found >/dev/null 2>&1 || true
      kubectl -n agent-trust-acme-payments delete configmap agent-trust-a2a-public --ignore-not-found >/dev/null 2>&1 || true
    fi
    if [[ "$a2a_namespace_created" == true ]]; then
      kubectl delete namespace agent-trust-acme-payments --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
  fi
  resume_root_reconciliation || true
  return "$status"
}

suspend_root_reconciliation() {
  local already_suspended
  already_suspended="$(kubectl -n "$flux_namespace" get kustomization flux-system -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  if [[ "$already_suspended" == true ]]; then return 0; fi
  flux suspend kustomization flux-system -n "$flux_namespace"
  root_reconciliation_suspended=true
  kubectl -n "$flux_namespace" annotate "resourceset/${resource_set}" \
    agent-trust.signalloom.io/resume-root-on-down=true --overwrite >/dev/null
}

resume_root_reconciliation() {
  local owned="$root_reconciliation_suspended"
  if [[ "$owned" != true ]]; then
    owned="$(kubectl -n "$flux_namespace" get "resourceset/${resource_set}" -o jsonpath='{.metadata.annotations.agent-trust\.signalloom\.io/resume-root-on-down}' 2>/dev/null || true)"
  fi
  if [[ "$owned" == true ]]; then
    flux resume kustomization flux-system -n "$flux_namespace"
    kubectl -n "$flux_namespace" annotate "resourceset/${resource_set}" \
      agent-trust.signalloom.io/resume-root-on-down- >/dev/null 2>&1 || true
    root_reconciliation_suspended=false
  fi
}

usage() {
  cat <<'EOF'
Usage: agent-trust-local.sh <up|verify|test|network-test|down>

up           preflight inf-bao, activate and wait for Agent Trust.
verify       fail closed unless every owned object is ready.
test         run static contracts, readiness, then enforced network evidence.
network-test prove policy outcomes; exits UNVERIFIED without a known enforcing CNI.
down         prune Agent Trust and delete only its six owned namespaces.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { printf 'required command unavailable: %s\n' "$1" >&2; exit 1; }
}

activate() {
  local nonce="${AGENT_TRUST_ACTIVATION_NONCE:-$(date -u +%Y%m%dT%H%M%S%N)}"
  kubectl -n "$flux_namespace" patch "resourceset/${resource_set}" --type merge \
    -p "{\"spec\":{\"inputs\":[{\"activationNonce\":\"${nonce}\",\"artifactSubjectGitRef\":\"local\",\"artifactSubjectWorkflow\":\"local\",\"component\":\"agent-trust\",\"environment\":\"local\",\"tag\":\"latest\",\"tenant\":\"agent-trust-platform\"}]}}"
  kubectl -n "$flux_namespace" annotate "resourceset/${resource_set}" \
    reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
}

snapshot_active_resourcesets() {
  require_command jq
  local state name inputs
  state=$(kubectl -n "$flux_namespace" get resourceset -o json) || {
    printf 'refusing fleet refresh: cannot read current ResourceSet inputs\n' >&2
    return 1
  }
  while IFS=$'\t' read -r name inputs; do
    [[ -n "$name" && -n "$inputs" ]] || continue
    active_resourceset_inputs["$name"]="$inputs"
  done < <(jq -r --arg excluded "$resource_set" '
    .items[] | select(.metadata.name != $excluded) |
    select((.spec.inputs // []) | length > 0) |
    [.metadata.name, (.spec.inputs | tojson)] | @tsv
  ' <<<"$state")
}

restore_active_resourcesets() {
  local name inputs
  for name in "${!active_resourceset_inputs[@]}"; do
    inputs="${active_resourceset_inputs[$name]}"
    kubectl -n "$flux_namespace" patch "resourceset/${name}" --type merge \
      -p "{\"spec\":{\"inputs\":${inputs}}}"
    kubectl -n "$flux_namespace" annotate "resourceset/${name}" \
      reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
  done
  for name in "${!active_resourceset_inputs[@]}"; do
    wait_flux_ready resourceset "$name" -n "$flux_namespace" 600
  done
}

preflight_bao() {
  wait_flux_ready resourceset signalloom-infra -n "$flux_namespace" 600
  wait_flux_ready kustomization infra-configs -n "$bao_namespace" 600
  wait_rollout openbao -n "$bao_namespace" 300
  wait_rollout spire-server -n "$bao_namespace" 300
}

refresh_fleet() {
  # The canonical local fleet Kustomization consumes OCIRepository/flux-system.
  # Reconcile it after the bounded fleet artifact push so this new ResourceSet
  # exists before any activation patch is attempted.
  flux reconcile kustomization flux-system -n "$flux_namespace" --with-source
  wait_flux_ready kustomization flux-system -n "$flux_namespace" 600
  wait_k8s_exists resourceset "$resource_set" -n "$flux_namespace" 300
}

wait_owned_namespaces() {
  local namespace
  for namespace in "${owned_namespaces[@]}"; do
    wait_k8s_exists namespace "$namespace" 180
  done
}

wait_runtime() {
  wait_rollout agent-trust-planner -n agent-trust-acme-payments 300
  wait_rollout agent-trust-triage -n agent-trust-acme-payments 300
  wait_rollout agent-trust-risk-reader -n agent-trust-acme-risk 300
  wait_rollout agent-trust-investigator -n agent-trust-northstar-investigations 300
  wait_k8s_exists service agent-trust-triage -n agent-trust-acme-payments 180
}

prepare_a2a_keys() {
  require_command openssl
  local namespace=agent-trust-acme-payments private_exists=false public_exists=false temporary
  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    kubectl create namespace "$namespace" >/dev/null
    a2a_namespace_created=true
  fi
  kubectl label namespace "$namespace" agent-trust.signalloom.io/tenant=acme agent-trust.signalloom.io/project=payments --overwrite >/dev/null
  if kubectl -n "$namespace" get secret agent-trust-a2a-private >/dev/null 2>&1; then private_exists=true; fi
  if kubectl -n "$namespace" get configmap agent-trust-a2a-public >/dev/null 2>&1; then public_exists=true; fi
  if [[ "$private_exists" == true && "$public_exists" == true ]]; then return 0; fi
  if [[ "$private_exists" != "$public_exists" ]]; then
    printf 'refusing partial A2A key state; remove both agent-trust-a2a key objects\n' >&2
    return 1
  fi
  temporary="$(mktemp -d)"
  openssl genpkey -algorithm ED25519 -out "$temporary/private.pem"
  openssl pkey -in "$temporary/private.pem" -pubout -out "$temporary/public.pem"
  kubectl -n "$namespace" create secret generic agent-trust-a2a-private \
    --from-file=private.pem="$temporary/private.pem" >/dev/null
  kubectl -n "$namespace" create configmap agent-trust-a2a-public \
    --from-file=public.pem="$temporary/public.pem" >/dev/null
  rm -rf "$temporary"
  a2a_keys_created=true
}

spire_server_pod() {
  kubectl -n "$bao_namespace" get pod -l app.kubernetes.io/name=spire-server \
    -o jsonpath='{.items[0].metadata.name}'
}

bao_admin_token() {
  kubectl -n "$bao_namespace" get deployment openbao -o json | jq -er '
    .spec.template.spec.containers[] | select(.name == "openbao") |
    .env[] | select(.name == "BAO_DEV_ROOT_TOKEN_ID") | .value
  '
}

configure_identity_plane() {
  local pod spiffe_id namespace service_account existing bao_token
  bao_token="$(bao_admin_token)"
  pod="$(spire_server_pod)"
  [[ -n "$pod" ]] || { printf 'SPIRE server pod unavailable\n' >&2; return 1; }
  while IFS='|' read -r spiffe_id namespace service_account; do
    existing="$(kubectl -n "$bao_namespace" exec "$pod" -- /opt/spire/bin/spire-server entry show -spiffeID "$spiffe_id" 2>/dev/null || true)"
    if [[ "$existing" != *"Entry ID"* ]]; then
      kubectl -n "$bao_namespace" exec "$pod" -- /opt/spire/bin/spire-server entry create \
        -spiffeID "$spiffe_id" -parentID "$spire_parent_id" \
        -selector "k8s:ns:${namespace}" -selector "k8s:sa:${service_account}"
    fi
  done <<'EOF'
spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner|agent-trust-acme-payments|agent-trust-planner
spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/triage|agent-trust-acme-payments|agent-trust-triage
spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/risk/agent/risk-reader|agent-trust-acme-risk|agent-trust-risk-reader
spiffe://signalloom.demo/platform/signalloom/tenant/northstar/project/investigations/agent/investigator|agent-trust-northstar-investigations|agent-trust-investigator
EOF
  # ${agent} intentionally expands inside the remote OpenBao shell.
  # shellcheck disable=SC2016
  kubectl -n "$bao_namespace" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" sh -ec '
      cat >/tmp/agent-trust-acme-payments.hcl <<POLICY
path "kv/data/signalloom/agent-trust/acme/payments/*" { capabilities = ["read"] }
POLICY
      bao policy write agent-trust-acme-payments /tmp/agent-trust-acme-payments.hcl >/dev/null
      for agent in planner triage; do
        bao write "auth/jwt/role/agent-trust-${agent}" role_type=jwt \
          bound_audiences=openbao-supercredential \
          bound_subject="spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/${agent}" \
          user_claim=sub policies=agent-trust-acme-payments token_ttl=5m token_max_ttl=5m token_period=0 token_renewable=false >/dev/null
      done
    '
  identity_configured=true
}

cleanup_identity_plane() {
  local pod spiffe_id entry_id bao_token
  bao_token="$(bao_admin_token 2>/dev/null || true)"
  pod="$(spire_server_pod 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    for spiffe_id in \
      spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner \
      spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/triage \
      spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/risk/agent/risk-reader \
      spiffe://signalloom.demo/platform/signalloom/tenant/northstar/project/investigations/agent/investigator; do
      entry_id="$(kubectl -n "$bao_namespace" exec "$pod" -- /opt/spire/bin/spire-server entry show -spiffeID "$spiffe_id" 2>/dev/null | awk '/Entry ID/{print $NF; exit}' || true)"
      if [[ -n "$entry_id" ]]; then
        kubectl -n "$bao_namespace" exec "$pod" -- /opt/spire/bin/spire-server entry delete -entryID "$entry_id" >/dev/null
      fi
    done
  fi
  if [[ -n "$bao_token" ]]; then
    kubectl -n "$bao_namespace" exec deployment/openbao -- \
      env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
      bao delete auth/jwt/role/agent-trust-planner >/dev/null 2>&1 || true
    kubectl -n "$bao_namespace" exec deployment/openbao -- \
      env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
      bao delete auth/jwt/role/agent-trust-triage >/dev/null 2>&1 || true
    kubectl -n "$bao_namespace" exec deployment/openbao -- \
      env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
      bao policy delete agent-trust-acme-payments >/dev/null 2>&1 || true
  fi
  identity_configured=false
}

verify_identity_plane() {
  local pod spiffe_id bao_token
  pod="$(spire_server_pod)"
  bao_token="$(bao_admin_token)"
  for spiffe_id in \
    spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner \
    spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/triage \
    spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/risk/agent/risk-reader \
    spiffe://signalloom.demo/platform/signalloom/tenant/northstar/project/investigations/agent/investigator; do
    kubectl -n "$bao_namespace" exec "$pod" -- /opt/spire/bin/spire-server entry show -spiffeID "$spiffe_id" | grep -Fq 'Entry ID'
  done
  kubectl -n "$bao_namespace" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
    bao read auth/jwt/role/agent-trust-planner >/dev/null
  kubectl -n "$bao_namespace" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
    bao read auth/jwt/role/agent-trust-triage >/dev/null
  kubectl -n "$bao_namespace" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
    bao policy read agent-trust-acme-payments >/dev/null
}

verify() {
  require_command kubectl
  wait_flux_ready resourceset "$resource_set" -n "$flux_namespace" 600
  wait_flux_ready kustomization agent-trust -n agent-trust-platform 600
  wait_owned_namespaces
  wait_runtime
  verify_identity_plane
  printf 'Agent Trust Flux readiness verified\n'
}

up() {
  trap rollback_failed_activation ERR
  require_command kubectl
  require_command flux
  snapshot_active_resourcesets
  refresh_fleet
  restore_active_resourcesets
  suspend_root_reconciliation
  preflight_bao
  prepare_a2a_keys
  activation_pending=true
  activate
  wait_flux_ready resourceset "$resource_set" -n "$flux_namespace" 600
  flux reconcile kustomization agent-trust -n agent-trust-platform --with-source
  if [[ "$a2a_keys_created" == true ]]; then
    kubectl -n agent-trust-acme-payments rollout restart deployment/agent-trust-planner deployment/agent-trust-triage
    wait_rollout agent-trust-planner -n agent-trust-acme-payments 300
    wait_rollout agent-trust-triage -n agent-trust-acme-payments 300
  fi
  configure_identity_plane
  verify
  activation_pending=false
  trap - ERR
  printf 'Agent Trust local reconciliation converged\n'
}

network_dataplane_preflight() {
  require_command jq
  local daemonsets
  daemonsets=$(kubectl -n kube-system get daemonset -o json) || {
    printf 'UNVERIFIED: cannot inspect CNI daemonsets before dataplane probes\n' >&2
    return 1
  }
  jq -e '[.items[].metadata.name] | length > 0' <<<"$daemonsets" >/dev/null || {
    printf 'UNVERIFIED: no CNI daemonset is present for dataplane probes\n' >&2
    return 1
  }
  kubectl api-resources --api-group=networking.k8s.io -o name 2>/dev/null \
    | grep -Eq '^networkpolicies(\.networking\.k8s\.io)?$' || {
    printf 'UNVERIFIED: NetworkPolicy API is unavailable for dataplane probes\n' >&2
    return 1
  }
  # A CNI name is not evidence of enforcement. The allow/deny probes below are
  # the capability gate, including kindnet when it is present on this cluster.
}

expect_tcp() {
  local deployment="$1" namespace="$2" host="$3" port="$4" expected="$5"
  if kubectl -n "$namespace" exec "deployment/${deployment}" -- nc -z -w 5 "$host" "$port"; then
    [[ "$expected" == allow ]] || { printf 'network assertion unexpectedly allowed: %s -> %s:%s\n' "$deployment" "$host" "$port" >&2; return 1; }
  else
    [[ "$expected" == deny ]] || { printf 'network assertion unexpectedly denied: %s -> %s:%s\n' "$deployment" "$host" "$port" >&2; return 1; }
  fi
}

network_test() {
  require_command kubectl
  network_dataplane_preflight
  verify
  wait_pods_ready app.kubernetes.io/name=agent-trust-triage -n agent-trust-acme-payments 180
  expect_tcp agent-trust-planner agent-trust-acme-payments agent-trust-triage 8080 allow
  kubectl -n agent-trust-acme-payments exec deployment/agent-trust-planner -- \
    /usr/local/bin/signalloom-spire-proof call-a2a \
      -audience openbao-supercredential \
      -socket /run/spire/sockets/agent.sock \
      -target http://agent-trust-triage:8080/a2a
  expect_tcp agent-trust-risk-reader agent-trust-acme-risk agent-trust-triage.agent-trust-acme-payments.svc 8080 deny
  expect_tcp agent-trust-investigator agent-trust-northstar-investigations agent-trust-triage.agent-trust-acme-payments.svc 8080 deny
  expect_tcp agent-trust-planner agent-trust-acme-payments openbao.inf-bao.svc 8200 allow
  expect_tcp agent-trust-triage agent-trust-acme-payments openbao.inf-bao.svc 8200 allow
  expect_tcp agent-trust-risk-reader agent-trust-acme-risk openbao.inf-bao.svc 8200 deny
  expect_tcp agent-trust-planner agent-trust-acme-payments 1.1.1.1 443 deny
  printf 'Agent Trust authenticated A2A and enforced NetworkPolicy evidence passed\n'
}

wait_namespace_absent() {
  local namespace="$1"
  _wait_retry 180 "namespace absent ${namespace}" "! kubectl get namespace '${namespace}' >/dev/null 2>&1"
}

down() {
  require_command kubectl
  require_command flux
  trap 'resume_root_reconciliation || true' EXIT
  cleanup_identity_plane
  kubectl -n "$flux_namespace" patch "resourceset/${resource_set}" --type merge -p '{"spec":{"inputs":[]}}'
  kubectl -n "$flux_namespace" annotate "resourceset/${resource_set}" \
    reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
  wait_flux_ready resourceset "$resource_set" -n "$flux_namespace" 600
  local namespace
  for namespace in "${owned_namespaces[@]}"; do
    kubectl delete namespace "$namespace" --ignore-not-found --wait=true
    wait_namespace_absent "$namespace"
  done
  resume_root_reconciliation
  trap - EXIT
  printf 'Agent Trust teardown verified; pre-existing inf-bao deployment remains intact\n'
}

test_all() {
  make -C "$repo_root/d2-agent-trust" test
  verify
  network_test
}

case "${1:-}" in
  up) up ;;
  verify) verify ;;
  test) test_all ;;
  network-test) network_test ;;
  down) down ;;
  *) usage; exit 64 ;;
esac
