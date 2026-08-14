#!/usr/bin/env bash
# Explicit, bounded lifecycle for the opt-in Agent Trust Flux ResourceSet.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly repo_root
# shellcheck disable=SC1091 # resolved relative to this script at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"
# shellcheck disable=SC1091 # resolved relative to this script at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/spire-trust-anchor.sh"

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
  local fleet_suspended tenants_suspended
  fleet_suspended="$(kubectl -n "$flux_namespace" get kustomization flux-system -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  tenants_suspended="$(kubectl -n "$flux_namespace" get kustomization tenants -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  if [[ "$fleet_suspended" == true && "$tenants_suspended" == true ]]; then return 0; fi
  if [[ "$fleet_suspended" != true ]]; then
    flux suspend kustomization flux-system -n "$flux_namespace"
  fi
  # `tenants` owns the ResourceSet manifests. Suspending only flux-system
  # leaves it free to reconcile the declarative empty inputs during activation.
  if [[ "$tenants_suspended" != true ]]; then
    flux suspend kustomization tenants -n "$flux_namespace"
  fi
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
    flux resume kustomization tenants -n "$flux_namespace"
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

# The one table both creation and verification read: `spiffeID|namespace|serviceAccount`.
#
# Shared deliberately. Verification used to carry its own hardcoded list of
# SPIFFE IDs and assert only that an entry existed, so the selectors -- the
# actual workload-attestation property -- could be changed or dropped at
# creation with nothing noticing. Two lists would drift; one cannot.
agent_trust_identity_table() {
  cat <<'EOF'
spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner|agent-trust-acme-payments|agent-trust-planner
spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/triage|agent-trust-acme-payments|agent-trust-triage
spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/risk/agent/risk-reader|agent-trust-acme-risk|agent-trust-risk-reader
spiffe://signalloom.demo/platform/signalloom/tenant/northstar/project/investigations/agent/investigator|agent-trust-northstar-investigations|agent-trust-investigator
EOF
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
  done < <(agent_trust_identity_table)
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
          user_claim=sub policies=agent-trust-acme-payments token_ttl=5m token_max_ttl=5m token_period=0 token_type=batch >/dev/null
      done
    '
  # A role bound to the right SPIFFE subject is useless if OpenBao cannot verify
  # the signature on the SVID presenting it. SPIRE rotates its JWT signing key
  # on the CA schedule, so the validation keys are part of the identity plane and
  # are re-derived here on every up — not copied once at cluster bootstrap.
  require_command openssl
  sync_openbao_jwt_validation "$bao_namespace" "$bao_token"
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
  local pod spiffe_id bao_token agent role_json entry_show entry_ns entry_sa
  require_command jq
  pod="$(spire_server_pod)"
  bao_token="$(bao_admin_token)"
  while IFS='|' read -r spiffe_id entry_ns entry_sa; do
    # The SELECTORS are the workload-attestation property, not the entry's
    # existence. `grep -Fq 'Entry ID'` passed for any entry at this SPIFFE ID,
    # so deleting `-selector k8s:sa:...` at entry creation left every pod in
    # agent-trust-acme-payments -- triage included -- able to fetch the
    # PLANNER's SVID and log into OpenBao as the planner, with this gate, the
    # network probes, bats and test_contracts.py all still green.
    entry_show="$(kubectl -n "$bao_namespace" exec "$pod" -- \
      /opt/spire/bin/spire-server entry show -spiffeID "$spiffe_id")"
    grep -Fq 'Entry ID' <<<"$entry_show"
    grep -Fq "k8s:ns:${entry_ns}" <<<"$entry_show" || {
      printf 'SPIRE entry for %s is missing selector k8s:ns:%s\n' "$spiffe_id" "$entry_ns" >&2; return 1; }
    grep -Fq "k8s:sa:${entry_sa}" <<<"$entry_show" || {
      printf 'SPIRE entry for %s is missing selector k8s:sa:%s — any pod in the namespace could assume this identity\n' "$spiffe_id" "$entry_sa" >&2; return 1; }
  done < <(agent_trust_identity_table)
  for agent in planner triage; do
    role_json="$(kubectl -n "$bao_namespace" exec deployment/openbao -- \
      env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
      bao read -format=json "auth/jwt/role/agent-trust-${agent}")"
    # Lifetime alone said the token was short-lived, never that it was THIS
    # agent's. bound_subject/bound_audiences/policies are what bind the role to
    # one SPIFFE ID; without bound_subject any workload holding any SVID with
    # the openbao-supercredential audience logs in as the planner and reads the
    # payments KV path — and every gate stayed green.
    jq -e --arg sub "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/${agent}" '
      .data.token_type == "batch" and .data.token_ttl == 300
      and .data.token_max_ttl == 300 and .data.token_period == 0
      and .data.bound_subject == $sub
      and (.data.bound_audiences == ["openbao-supercredential"])
      and ((.data.token_policies // .data.policies) | index("agent-trust-acme-payments") != null)
    ' <<<"$role_json" >/dev/null || {
      printf 'OpenBao role agent-trust-%s is not bound to its SPIFFE subject, audience and policy\n' "$agent" >&2
      return 1; }
  done
  kubectl -n "$bao_namespace" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$bao_token" \
    bao policy read agent-trust-acme-payments >/dev/null
  # Everything above proves WHOSE identity the role admits. None of it proves
  # OpenBao can still check the signature, and on 2026-08-14 that is exactly what
  # broke: SPIRE rotated its JWT signing key, auth/jwt/config kept the snapshot
  # taken at bring-up, and openbao-planner and planner-triage-a2a failed every
  # five minutes for three and a half hours with every assertion above green.
  # Asserted, never repaired — a gate that silently fixes what it measures
  # reports success for a demo that was broken until the gate ran.
  require_command openssl
  assert_openbao_accepts_spire_jwt_keys "$bao_namespace" "$bao_token"
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
  suspend_root_reconciliation
  # Refresh reapplies declarative empty inputs. Restore only after both owning
  # reconcilers are suspended, otherwise their in-flight reconciliation can
  # erase the restored prerequisite inputs before the Bao preflight.
  restore_active_resourcesets
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

verify_nonrenewable_planner_token() {
  local planner planner_state fetched jwt login client_token renew_output renew_status
  planner_state="$(kubectl -n agent-trust-acme-payments get pods \
    -l app.kubernetes.io/name=agent-trust-planner,app.kubernetes.io/component!=probe -o json)"
  planner="$(jq -er '
    [.items[] | select(
      (.status.containerStatuses // []) as $statuses |
      ($statuses | length) > 0 and
      all($statuses[]; .ready == true)
    ) | .metadata.name] |
    if length == 1 then .[0] else error("expected one ready planner pod") end
  ' <<<"$planner_state")"
  fetched="$(kubectl -n agent-trust-acme-payments exec "$planner" -- \
    /usr/local/bin/spire-agent api fetch jwt \
      -audience openbao-supercredential \
      -socketPath /run/spire/sockets/agent.sock \
      -output json)"
  jwt="$(jq -er '
    if type == "array" then
      [.[] | .svids? // empty] | flatten | .[0].svid
    else
      .svids[0].svid
    end
  ' <<<"$fetched")"
  # shellcheck disable=SC2016 # JWT expands only inside the remote OpenBao shell.
  login="$(printf '%s\n' "$jwt" | kubectl -n "$bao_namespace" exec -i deployment/openbao -- \
    sh -ec '
      IFS= read -r jwt
      export BAO_ADDR=http://127.0.0.1:8200
      bao write -format=json auth/jwt/login role=agent-trust-planner jwt="$jwt"
    ')"
  jq -e '.auth.renewable == false and .auth.lease_duration == 300' \
    <<<"$login" >/dev/null || {
      printf 'OpenBao planner token is renewable or exceeds five minutes\n' >&2
      return 1
    }
  client_token="$(jq -er '.auth.client_token' <<<"$login")"
  set +e
  # shellcheck disable=SC2016 # Token expands only inside the remote OpenBao shell.
  renew_output="$(printf '%s\n' "$client_token" | kubectl -n "$bao_namespace" exec -i deployment/openbao -- \
    sh -ec '
      IFS= read -r token
      export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token"
      bao token renew
    ' 2>&1)"
  renew_status=$?
  set -e
  if [[ "$renew_status" -eq 0 ]]; then
    printf 'OpenBao unexpectedly renewed the planner batch token\n' >&2
    return 1
  fi
  if [[ "$renew_output" != *'batch tokens cannot be renewed'* ]]; then
    printf 'OpenBao batch-token renewal denial could not be proven\n' >&2
    return 1
  fi
  printf 'OpenBao planner token is a five-minute non-renewable batch token\n'
}

# A denial is only evidence if the probe that produced it was capable of
# succeeding. `nc` exits 1 for a packet the CNI dropped AND for a hostname it
# could not resolve AND for a binary that isn't there AND for a pod that isn't
# running — verified against the exact image these scaffolds use:
#
#   busybox:1.36 $ nc -z -w 2 240.0.0.1 9999   -> exit 1   (blackholed: a real block)
#   busybox:1.36 $ nc -z -w 2 nope.invalid 9999 -> exit 1  (nc: bad address 'nope.invalid')
#
# Identical status, different stderr. The old implementation inspected only the
# status and discarded stderr, so every `deny` assertion passed on any breakage.
# That is this repo's named failure mode — "a gate that always passes" — sitting
# in the one place the demo exists to prove something: that a packet was refused.
#
# Concretely, deleting the `allow-dns` NetworkPolicy for agent-trust-acme-risk
# left every deny assertion green while proving nothing whatsoever about
# reachability to triage, and the run still printed "enforced NetworkPolicy
# evidence passed".
#
# So: capture stderr, and refuse to call a resolution failure or a missing probe
# a denial. Those are UNVERIFIED — the same fail-closed vocabulary the CNI
# preflight already uses — never a silent pass.
expect_tcp() {
  local deployment="$1" namespace="$2" host="$3" port="$4" expected="$5"
  local output status

  # set +e around the capture is load-bearing. Under `set -e` an assignment whose
  # command substitution exits non-zero terminates the script THERE — so the
  # first deny probe would abort the run before its status could be inspected,
  # printing nothing. The previous `if kubectl ...; then` form was protected by
  # the `if` context; a bare capture is not. Same idiom as
  # verify_nonrenewable_planner_token above.
  set +e
  output="$(kubectl -n "$namespace" exec "deployment/${deployment}" -- \
    nc -z -w 5 "$host" "$port" 2>&1)"
  status=$?
  set -e

  # Breakage masquerading as denial. Checked before the allow/deny branch so it
  # cannot be absorbed by an `expected=deny` assertion.
  case "$output" in
    *'bad address'*|*'getaddrinfo'*|*'Name or service not known'*|*'Temporary failure in name resolution'*)
      printf 'UNVERIFIED: %s could not resolve %s — DNS failed, so this is not proof of a network denial\n' \
        "$deployment" "$host" >&2
      return 1 ;;
    # Pod-absent BEFORE probe-unusable, and no bare *'not found'* pattern: kubectl
    # says `container not found ("risk-reader")` for a dead pod, which a greedy
    # 'not found' match would misreport as a missing nc binary. Both are
    # UNVERIFIED either way, but a wrong diagnosis sends the next engineer to
    # rebuild an image when the pod simply is not up.
    *'unable to upgrade connection'*|*'container not found'*|*'is not running'*|*'pods '*' not found'*)
      printf 'UNVERIFIED: %s is not running, so nothing was proven about %s:%s — %s\n' \
        "$deployment" "$host" "$port" "$output" >&2
      return 1 ;;
    *'executable file not found'*|*'no such file or directory'*|*'OCI runtime exec'*)
      printf 'UNVERIFIED: the probe itself is unusable in %s (nc missing or container not execable): %s\n' \
        "$deployment" "$output" >&2
      return 1 ;;
  esac

  if [[ "$status" -eq 0 ]]; then
    [[ "$expected" == allow ]] || { printf 'network assertion unexpectedly allowed: %s -> %s:%s\n' "$deployment" "$host" "$port" >&2; return 1; }
  else
    [[ "$expected" == deny ]] || { printf 'network assertion unexpectedly denied: %s -> %s:%s (%s)\n' "$deployment" "$host" "$port" "$output" >&2; return 1; }
  fi
}

network_test() {
  require_command kubectl
  network_dataplane_preflight
  verify
  verify_nonrenewable_planner_token
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
  # Empty ResourceSet inputs intentionally render no template values, so Ready
  # becomes false. Verify the deactivation state directly rather than waiting
  # for a Ready condition that cannot exist without an input row.
  _wait_retry 600 "inactive resourceset/${resource_set}" \
    "test \"\$(kubectl -n '$flux_namespace' get 'resourceset/${resource_set}' -o jsonpath='{.spec.inputs}')\" = '[]'"
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
