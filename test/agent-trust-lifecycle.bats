#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  real_kubectl="$(command -v kubectl)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/commands.log"
  mkdir -p "$bin"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == *'get daemonset -o json'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_CNI:-none}" == kindnet ]]; then
    printf '%s\n' '{"items":[{"metadata":{"name":"kindnet"}}]}'
  else
    printf '%s\n' '{"items":[]}'
  fi
fi
if [[ "$*" == *'api-resources --api-group=networking.k8s.io -o name'* ]]; then printf 'networkpolicies\n'; fi
if [[ "$*" == *'get pods -l app.kubernetes.io/name=agent-trust-triage'* ]]; then printf 'true\n'; fi
if [[ "$*" == *'get deployment openbao -o json'* ]]; then printf '%s\n' '{"spec":{"template":{"spec":{"containers":[{"name":"openbao","env":[{"name":"BAO_DEV_ROOT_TOKEN_ID","value":"fixture-admin-token"}]}]}}}}'; fi
if [[ "$*" == *'bao read -format=json auth/jwt/role/agent-trust-'* ]]; then printf '%s\n' '{"data":{"token_type":"batch","token_ttl":300,"token_max_ttl":300,"token_period":0}}'; fi
if [[ "$*" == *'get pod -l app.kubernetes.io/name=spire-server -o jsonpath='* ]]; then printf 'spire-server-0'; fi
if [[ "$*" == *'spire-server entry show -spiffeID'* ]]; then printf 'Entry ID : fixture-entry\n'; fi
if [[ "$*" == *'exec deployment/'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_UNEXPECTED_ALLOW:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then exit 0; fi
  if [[ "$*" == *'deployment/agent-trust-risk-reader'* || "$*" == *'deployment/agent-trust-investigator'* || "$*" == *' 1.1.1.1 443'* ]]; then exit 1; fi
fi
if [[ "$*" == *'get resourceset -o json'* ]]; then
  printf '%s\n' '{"items":[{"metadata":{"name":"signalloom-infra"},"spec":{"inputs":[{"tenant":"inf-bao","tag":"latest"}]}},{"metadata":{"name":"signalloom-apps"},"spec":{"inputs":[{"tenant":"fe-signalloom","tag":"latest"}]}},{"metadata":{"name":"olly"},"spec":{"inputs":[]}}]}'
fi
if [[ "${AGENT_TRUST_FAKE_ABSENT:-0}" == 1 && "$*" == *'get namespace agent-trust-'* ]]; then exit 1; fi
if [[ "${AGENT_TRUST_FAKE_DOWN_FAILURE:-0}" == 1 && "$*" == *'metadata.annotations.agent-trust'* ]]; then printf 'true'; fi
if [[ "$*" == *'get resourceset/agent-trust -o jsonpath='* && "$*" != *'metadata.annotations.agent-trust'* ]]; then printf '[]'; fi
if [[ "${AGENT_TRUST_FAKE_DOWN_FAILURE:-0}" == 1 && "$*" == *'delete namespace agent-trust-platform'* ]]; then exit 1; fi
SCRIPT
cat >"$bin/flux" <<'SCRIPT'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >>"$COMMAND_LOG"
if [[ "${AGENT_TRUST_FAKE_RECONCILE_FAILURE:-0}" == 1 && "$*" == *'reconcile kustomization agent-trust'* ]]; then exit 1; fi
SCRIPT
  chmod +x "$bin/kubectl" "$bin/flux"
}

line_number() {
  local first line=""
  first="$(grep -n -F "$1" "$log" | cut -d: -f1 | { IFS= read -r line || true; printf '%s' "$line"; })"
  printf '%s\n' "$first"
}

@test "lifecycle preflights Bao before patching the opt-in ResourceSet" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent Trust local reconciliation converged"* ]]
  grep -Fq 'reconcile kustomization flux-system -n flux-system --with-source' "$log"
  grep -Fq 'suspend kustomization tenants -n flux-system' "$log"
  grep -Fq 'get resourceset agent-trust' "$log"
  grep -Fq 'get resourceset -o json' "$log"
  grep -Fq 'patch resourceset/signalloom-infra --type merge -p {"spec":{"inputs":[{"tenant":"inf-bao","tag":"latest"}]}}' "$log"
  grep -Fq 'patch resourceset/signalloom-apps --type merge -p {"spec":{"inputs":[{"tenant":"fe-signalloom","tag":"latest"}]}}' "$log"
  ! grep -Fq 'patch resourceset/olly --type merge' "$log"
  grep -Fq 'wait resourceset/signalloom-infra --for=condition=ready' "$log"
  grep -Fq 'wait kustomization/infra-configs --for=condition=ready' "$log"
  grep -Fq 'patch resourceset/agent-trust --type merge' "$log"
  grep -Fq 'reconcile kustomization agent-trust -n agent-trust-platform --with-source' "$log"
  grep -Fq 'bao write "auth/jwt/role/agent-trust-${agent}"' "$log"
  grep -Fq 'bao read -format=json auth/jwt/role/agent-trust-planner' "$log"
  grep -Fq 'spire-server entry show -spiffeID spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner' "$log"
  grep -Fq 'rollout status deploy/agent-trust-triage' "$log"
  grep -Fq 'get service agent-trust-triage' "$log"
  restore=$(line_number 'patch resourceset/signalloom-infra --type merge')
  suspend=$(line_number 'suspend kustomization tenants -n flux-system')
  bao_preflight=$(line_number 'wait resourceset/signalloom-infra --for=condition=ready')
  [ "$suspend" -lt "$restore" ]
  [ "$restore" -lt "$bao_preflight" ]
}

@test "repeat activation changes nonce without changing logical Agent Trust inputs" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_ACTIVATION_NONCE=first \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_ACTIVATION_NONCE=second \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  mapfile -t patches < <(grep 'patch resourceset/agent-trust --type merge' "$log")
  [ "${#patches[@]}" -eq 2 ]
  [[ "${patches[0]}" == *'"activationNonce":"first"'* ]]
  [[ "${patches[1]}" == *'"activationNonce":"second"'* ]]
  [[ "${patches[0]}" == *'"tenant":"agent-trust-platform"'* ]]
  [[ "${patches[1]}" == *'"tenant":"agent-trust-platform"'* ]]
}

@test "failed reconciliation rolls activation back to inactive inputs" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_RECONCILE_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -ne 0 ]
  [[ "$output" == *"restoring ResourceSet inputs to []"* ]]
  grep -Fq 'patch resourceset/agent-trust --type merge -p {"spec":{"inputs":[]}}' "$log"
  grep -Fq 'flux resume kustomization flux-system -n flux-system' "$log"
  grep -Fq 'flux resume kustomization tenants -n flux-system' "$log"
}

@test "network test fails closed when no CNI daemonset is present" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  ! grep -Fq 'exec deployment/' "$log"
}

@test "kindnet is admitted to dataplane probes without name-based enforcement inference" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"NetworkPolicy evidence passed"* ]]
  grep -Fq 'api-resources --api-group=networking.k8s.io -o name' "$log"
  grep -Fq 'exec deployment/agent-trust-planner -- nc -z -w 5 agent-trust-triage 8080' "$log"
  grep -Fq 'exec deployment/agent-trust-planner -- /usr/local/bin/signalloom-spire-proof call-a2a -audience openbao-supercredential' "$log"
  grep -Fq 'exec deployment/agent-trust-risk-reader -- nc -z -w 5 agent-trust-triage.agent-trust-acme-payments.svc 8080' "$log"
}

@test "unexpectedly allowed denied dataplane path fails network evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_UNEXPECTED_ALLOW=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpectedly allowed"* ]]
}

@test "lifecycle contains no fixed readiness sleeps and teardown is owned-only" {
  script="$root/scripts/agent-trust-local.sh"
  ! grep -E '(^|[;[:space:]])sleep[[:space:]]+[0-9]' "$script"
  grep -Fq 'patch "resourceset/${resource_set}" --type merge -p '\''{"spec":{"inputs":[]}}'\''' "$script"
  grep -Fq 'kubectl delete namespace "$namespace"' "$script"
  ! grep -Fq 'delete namespace "$bao_namespace"' "$script"
}

@test "down deactivates the ResourceSet then removes only owned namespaces" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_ABSENT=1 \
    "$root/scripts/agent-trust-local.sh" down
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-existing inf-bao deployment remains intact"* ]]
  grep -Fq 'patch resourceset/agent-trust --type merge -p {"spec":{"inputs":[]}}' "$log"
  grep -Fq 'get resourceset/agent-trust -o jsonpath={.spec.inputs}' "$log"
  grep -Fq 'delete namespace agent-trust-platform --ignore-not-found --wait=true' "$log"
  grep -Fq 'delete namespace agent-trust-northstar-investigations --ignore-not-found --wait=true' "$log"
  ! grep -Fq 'delete namespace inf-bao' "$log"
  grep -Fq 'bao delete auth/jwt/role/agent-trust-planner' "$log"
}

@test "failed teardown still resumes root Fleet reconciliation" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_DOWN_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" down
  [ "$status" -ne 0 ]
  grep -Fq 'flux resume kustomization flux-system -n flux-system' "$log"
  grep -Fq 'flux resume kustomization tenants -n flux-system' "$log"
}

@test "ResourceSet uses limited Agent Trust RBAC and signed OCI wiring" {
  resource="$root/d2-osramp-fleet/tenants/base/agent-trust.yaml"
  grep -Fq 'inputs: []' "$resource"
  grep -Fq 'name: signalloom-infra' "$resource"
  grep -Fq 'namespace: inf-bao' "$resource"
  grep -Fq 'name: agent-trust-flux' "$resource"
  grep -Fq 'resources: [namespaces]' "$resource"
  [ "$(grep -c 'kind: Namespace' "$resource")" -eq 6 ]
  [ "$(grep -c 'kind: RoleBinding' "$resource")" -eq 6 ]
  grep -Fq 'verbs: [get, list, watch, create]' "$resource"
  grep -Fq 'verbs: [get, update, patch, delete]' "$resource"
  grep -Fq 'resourceNames:' "$resource"
  grep -Fq 'resources: [deployments, replicasets]' "$resource"
  ! grep -Fq 'cluster-admin' "$resource"
  grep -Fq 'provider: cosign' "$resource"
  grep -Fq 'artifactSubjectWorkflow' "$resource"
  grep -Fq 'push_and_sign "signalloom/agent-trust" "d2-agent-trust/manifests"' "$root/scripts/push-local.sh"
  grep -Fq 'repository: signalloom/agent-trust' "$root/.github/workflows/push-artifacts.yaml"
  grep -Fq 'name: allow-agent-trust-openbao' "$resource"
  grep -Fq 'agent-trust.signalloom.io/project: payments' "$resource"
  grep -Fq 'app.kubernetes.io/name: agent-trust-planner' "$resource"
  grep -Fq 'app.kubernetes.io/name: agent-trust-triage' "$resource"
  grep -Fq 'port: 8200' "$resource"
  grep -Fq '"serve-a2a"' "$root/d2-agent-trust/manifests/boundaries.yaml"
  grep -Fq 'readinessProbe: {httpGet: {path: /readyz, port: a2a}' "$root/d2-agent-trust/manifests/boundaries.yaml"
  ! grep -R -Fq 'activationNonce' "$root/d2-agent-trust/manifests"
}

@test "local fleet renders inactive Agent Trust with local signature verification" {
  rendered="$BATS_TEST_TMPDIR/tenants-local.yaml"
  run "$real_kubectl" kustomize --load-restrictor LoadRestrictionsNone "$root/d2-osramp-fleet/tenants/local"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$rendered"
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | (.spec.inputs | length) == 0' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | .spec.resources[16].spec.verify.secretRef.name == "cosign-pub"' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | .spec.dependsOn[] | select(.name == "signalloom-infra" or (.name == "infra-configs" and .namespace == "inf-bao")) | .readyExpr | contains("conditions")' "$rendered"
  [ "$status" -eq 0 ]
  [[ "$output" == *"true"* ]]
}

@test "Agent Trust Make target publishes bounded artifacts only" {
  run make -n demo-agent-trust-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"push-local-fleet"* ]]
  [[ "$output" == *"push-local-agent-trust"* ]]
  [[ "$output" == *"signalloom-spire-helper"* ]]
  [[ "$output" != *"push-local-signalloom"* ]]
}
