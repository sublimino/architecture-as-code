#!/usr/bin/env bats
#
# @id      fleet-manager-caller-auth-manifest
# @target  d2-signalloom/apps/fleet-manager/base, d2-signalloom/infra/agent-swarm/signalloom-warden
# @doc     d2-signalloom/apps/fleet-manager/callerauth.go
#
# The caller-key contract as kustomize renders it: keys only from Secrets,
# least scope per caller, the sentinel wired to fleet-manager, and the node
# ipBlock confined to fleet-manager's http port.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export KUBECONFIG=/dev/null
  FM="${BATS_TEST_TMPDIR}/fleet-manager.yaml"
  SENTINEL="${BATS_TEST_TMPDIR}/sentinel.yaml"
  kubectl kustomize "${REPO_ROOT}/d2-signalloom/apps/fleet-manager/base" >"${FM}"
  kubectl kustomize "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden" >"${SENTINEL}"
}

# q EXPR FILE: yq over a multi-document render, without the blank line yq
# prints for every document the expression does not select.
q() { yq -N "$1" "$2" | sed '/^$/d'; }

# fm_env: fleet-manager container env as one "name|literal|secret" row each.
fm_env() {
  q 'select(.kind == "Deployment" and .metadata.name == "fleet-manager")
    | .spec.template.spec.containers[] | select(.name == "fleet-manager") | .env[]
    | [.name, (.value // ""), (.valueFrom.secretKeyRef.name // "")] | join("|")' "${FM}"
}

@test "caller-auth manifest: every caller key comes from a Secret, never a literal" {
  local rows; rows="$(fm_env | grep '^FLEET_MANAGER_KEY_' | grep -v '_SCOPES|')"
  [ "$(wc -l <<<"$rows")" -ge 4 ]
  while IFS='|' read -r name literal secret; do
    [ -z "$literal" ] || { echo "$name has a literal value"; return 1; }
    [ "$secret" = "fleet-manager-caller-keys" ] || { echo "$name: secret '$secret'"; return 1; }
  done <<<"$rows"
}

@test "caller-auth manifest: stun-only callers hold exactly the stun scope; only the operator may recover" {
  local scopes; scopes="$(fm_env | grep '_SCOPES|' | cut -d'|' -f1,2)"
  grep -qE 'FLEET_MANAGER_KEY_.*_SCOPES\|stun' <<<"$scopes"
  grep -qx 'FLEET_MANAGER_KEY_FE_SIGNALLOOM_SCOPES|stun' <<<"$scopes"
  grep -qx 'FLEET_MANAGER_KEY_DASHBOARD_SCOPES|stun,deploy,scan,reset,read' <<<"$scopes"  # read: the workload registry (GET /api/v1/fleet/workloads) feeds remote discovery
  [ "$(grep -c 'recover' <<<"$scopes")" -eq 1 ]
  grep -q '^FLEET_MANAGER_KEY_OPERATOR_SCOPES|.*recover' <<<"$scopes"
}

@test "caller-auth manifest: operator public keys come from the operator-keys ConfigMap, optional, with the local audience and trust root" {
  # OPERATOR_KEYS_JSON is PUBLIC material, so a ConfigMap rather than a
  # Secret, and optional so an estate that has not minted keys still starts
  # (every governed resume then fails closed). Audience and trust root are
  # plain values a pilot overlay overrides.
  run q 'select(.kind == "Deployment" and .metadata.name == "fleet-manager")
    | .spec.template.spec.containers[] | select(.name == "fleet-manager") | .env[]
    | select(.name == "OPERATOR_KEYS_JSON")
    | [(.value // ""), .valueFrom.configMapKeyRef.name, .valueFrom.configMapKeyRef.key, (.valueFrom.configMapKeyRef.optional | tostring)] | join("|")' "${FM}"
  [ "$status" -eq 0 ]
  [ "$output" = "|fleet-manager-operator-keys|keys.json|true" ]
  local rows; rows="$(fm_env | grep -E '^(FLEET_AUDIENCE|OPERATOR_TRUST_ROOT_ID)\|')"
  grep -qx 'FLEET_AUDIENCE|signalloom-fleet/local|' <<<"$rows"
  grep -qx 'OPERATOR_TRUST_ROOT_ID|signalloom-operators-v1|' <<<"$rows"
}

@test "caller-auth manifest: the node ipBlock admits fleet-manager's http port and nothing else" {
  run q 'select(.kind == "NetworkPolicy" and .metadata.name == "fleet-manager") | .spec.ingress[]
    | select(.from[].ipBlock) | [(.from | length), (.ports | length), .ports[0].port] | join(" ")' "${FM}"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 http" ]
}

@test "caller-auth manifest: the dashboard renders its fleet key from the Secret into a writable conf.d" {
  local dash="${BATS_TEST_TMPDIR}/dashboard.yaml"
  kubectl kustomize "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/base" >"${dash}"
  run q 'select(.kind == "Deployment" and .metadata.name == "dashboard-signalloom") | .spec.template.spec.containers[0].env[]
    | select(.name == "FLEET_DASHBOARD_KEY") | [(.value // ""), .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key] | join("|")' "${dash}"
  [ "$output" = "|fleet-manager-caller-keys|dashboard" ]
  run q 'select(.kind == "Deployment" and .metadata.name == "dashboard-signalloom") | .spec.template.spec.containers[0].volumeMounts[] | .mountPath' "${dash}"
  [[ "$output" == *"/etc/nginx/conf.d"* ]]
}

@test "caller-auth manifest: the sentinel reaches fleet-manager by FQDN with its key from a Secret" {
  run q 'select(.kind == "ConfigMap" and .metadata.name == "signalloom-warden-config") | .data.FLEET_MANAGER_URL' "${SENTINEL}"
  [ "$output" = "http://fleet-manager.fe-signalloom.svc.cluster.local:8082" ]
  run q 'select(.kind == "DaemonSet") | .spec.template.spec.containers[].env[] | select(.name == "FLEET_MANAGER_STUN_KEY")
    | [(.value // ""), .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key] | join("|")' "${SENTINEL}"
  [[ "$output" == *"fleet-key|token" ]]
}
