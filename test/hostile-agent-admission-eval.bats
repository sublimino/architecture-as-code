#!/usr/bin/env bats
# test/hostile-agent-admission-eval.bats — Adversarial hostile agent pod admission and CEL evaluation.
#
# OBJECTIVES:
# 1. Live Kubernetes Admission CEL Enforcements:
#    - ValidatingAdmissionPolicy `sl-agent-identity-binding`:
#      * Reject hostile pod spoofing registered agent identity in unauthorized namespace (e.g. default).
#      * Reject hostile pod spoofing registered agent identity with forged ServiceAccount.
#      * Reject hostile cross-agent identity spoofing between registered workloads.
#      * Permit legitimate agent pod with verified namespace and matching ServiceAccount.
#    - ValidatingAdmissionPolicy `sl-agent-identity-state-protection`:
#      * Reject hostile agent pod creation with invalid or malicious framework label.
#      * Reject hostile agent pod creation with missing framework label.
#      * Permit agent pod creation with valid framework label.
#      * Reject unauthorized mutation or removal of `signalloom.ai/state: stunned` by unprivileged identity.
#      * Permit authorized un-stunning by cluster admin or governor identity.
# 2. Live Cluster Policy API Endpoints & Adversarial CEL Evaluation:
#    - `/api/v1/policies/validate`:
#      * Fail-closed: 401 unauthenticated on missing or forged Bearer token.
#      * Syntax error diagnostics: 422 cel_validation_error on malformed syntax / unbalanced brackets.
#      * Security rejection: 422 cel_validation_error on Python dunder injection (__import__, eval).
#      * Security rejection: 422 cel_validation_error on catastrophic ReDoS quantifier patterns.
#      * Scope enforcement: 422 cel_validation_error on undefined/unauthorized root variables.
#      * Compliant policy syntax returns 200 with {"valid": true}.
#    - `/api/v1/policies/evaluate`:
#      * Live CEL evaluation against workload context returns 200 with compliant=true when conditions met.
#      * Live CEL evaluation against non-compliant workload context returns 200 with compliant=false.
#    - Invariant verification:
#      * Malformed JSON payloads return 400 invalid_json with zero unhandled 500 server errors.
#      * Content-Type validation returns 400 invalid_content_type with zero unhandled 500 server errors.
#      * Oversized expression payloads return 422 with zero unhandled 500 server errors.
#
# CONFORMANCE:
# - Zero kubectl exec probes (strict outside-pod admission and port-forward HTTP verification).
# - Fail-closed security invariants across authentication, admission, and CEL evaluation.

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  source "${REPO_ROOT}/scripts/lib/wait.sh"

  if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
    export KUBECONFIG="${KUBECONFIG}"
  elif [ -f "/tmp/osramp-kubeconfig.yaml" ]; then
    export KUBECONFIG="/tmp/osramp-kubeconfig.yaml"
  elif [ -f "${REPO_ROOT}/.kind/kubeconfig" ]; then
    export KUBECONFIG="${REPO_ROOT}/.kind/kubeconfig"
  fi

  for cmd in curl jq kubectl python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Prerequisite tool '$cmd' missing" >&2
      return 1
    }
  done

  kubectl get nodes >/dev/null 2>&1 || {
    echo "Kubernetes cluster unreachable" >&2
    return 1
  }

  # Ensure state protection policy is active on the cluster
  local policy_file="${REPO_ROOT}/d2-agent-trust/policies/agent-identity-state-protection.yaml"
  if [ -f "${policy_file}" ]; then
    kubectl apply -f "${policy_file}" >/dev/null 2>&1 || true
  fi

  # Create an unprivileged test ServiceAccount and Role with pod edit permissions in fe-signalloom-agents
  # to test admission CEL rejection when RBAC would otherwise allow pod update
  kubectl -n fe-signalloom-agents create sa hostile-test-sa --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  kubectl -n fe-signalloom-agents create role hostile-pod-editor --verb=update,patch,get --resource=pods --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  kubectl -n fe-signalloom-agents create rolebinding hostile-pod-editor-rb --role=hostile-pod-editor --serviceaccount=fe-signalloom-agents:hostile-test-sa --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  STATE_FILE="${BATS_FILE_TMPDIR}/hostile-eval-state.env"
  DEX_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')"
  FE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')"

  kubectl -n inf-signalloom port-forward svc/dex "${DEX_PORT}:5556" >/dev/null 2>&1 &
  DEX_PID=$!
  kubectl -n fe-signalloom port-forward svc/fe-signalloom "${FE_PORT}:8000" >/dev/null 2>&1 &
  FE_PID=$!

  wait_tcp localhost "${DEX_PORT}" 15 || {
    kill "$DEX_PID" "$FE_PID" 2>/dev/null || true
    echo "Timed out waiting for Dex port-forward" >&2
    return 1
  }

  wait_tcp localhost "${FE_PORT}" 15 || {
    kill "$DEX_PID" "$FE_PID" 2>/dev/null || true
    echo "Timed out waiting for fe-signalloom port-forward" >&2
    return 1
  }

  local token_resp
  token_resp="$(curl -sS --max-time 10 -X POST \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=signalloom-dashboard" \
    --data-urlencode "username=demo-user@signalloom.local" \
    --data-urlencode "password=demo-user" \
    --data-urlencode "scope=openid profile email groups audience:server:client_id:signalloom-api" \
    "http://localhost:${DEX_PORT}/dex/token")"

  TOKEN="$(jq -er '.id_token | select(type == "string" and length > 0)' <<<"${token_resp}" 2>/dev/null)" || {
    kill "$DEX_PID" "$FE_PID" 2>/dev/null || true
    echo "Failed to mint Dex token: ${token_resp}" >&2
    return 1
  }

  cat <<STATE_VARS > "${STATE_FILE}"
REPO_ROOT='${REPO_ROOT}'
KUBECONFIG='${KUBECONFIG}'
DEX_PORT='${DEX_PORT}'
FE_PORT='${FE_PORT}'
TOKEN='${TOKEN}'
DEX_PID='${DEX_PID}'
FE_PID='${FE_PID}'
STATE_VARS
}

teardown_file() {
  local state_file="${BATS_FILE_TMPDIR}/hostile-eval-state.env"
  if [[ -f "${state_file}" ]]; then
    set -a
    source "${state_file}"
    set +a

    if [ -n "${KUBECONFIG:-}" ]; then
      kubectl -n fe-signalloom-agents delete pod hostile-eval-stunned-pod --ignore-not-found --wait=false >/dev/null 2>&1 || true
      kubectl -n fe-signalloom-agents delete rolebinding hostile-pod-editor-rb --ignore-not-found >/dev/null 2>&1 || true
      kubectl -n fe-signalloom-agents delete role hostile-pod-editor --ignore-not-found >/dev/null 2>&1 || true
      kubectl -n fe-signalloom-agents delete sa hostile-test-sa --ignore-not-found >/dev/null 2>&1 || true
    fi

    if [[ -n "${DEX_PID:-}" ]]; then
      kill "${DEX_PID}" 2>/dev/null || true
    fi
    if [[ -n "${FE_PID:-}" ]]; then
      kill "${FE_PID}" 2>/dev/null || true
    fi
  fi
}

setup() {
  local state_file="${BATS_FILE_TMPDIR}/hostile-eval-state.env"
  [ -f "${state_file}" ] || skip "State file not found"
  set -a
  source "${state_file}"
  set +a
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1: Hostile Agent Pod Admission & In-Cluster CEL Policy Enforcement
# ═══════════════════════════════════════════════════════════════════════════════

@test "admission-cel: ValidatingAdmissionPolicies are active on cluster" {
  run kubectl get validatingadmissionpolicy sl-agent-identity-binding -o jsonpath='{.metadata.name}'
  [ "$status" -eq 0 ]
  [ "$output" = "sl-agent-identity-binding" ]

  run kubectl get validatingadmissionpolicybinding sl-agent-identity-binding-binding -o jsonpath='{.spec.policyName}'
  [ "$status" -eq 0 ]
  [ "$output" = "sl-agent-identity-binding" ]

  run kubectl get validatingadmissionpolicy sl-agent-identity-state-protection -o jsonpath='{.metadata.name}'
  [ "$status" -eq 0 ]
  [ "$output" = "sl-agent-identity-state-protection" ]

  run kubectl get validatingadmissionpolicybinding sl-agent-identity-state-protection-binding -o jsonpath='{.spec.policyName}'
  [ "$status" -eq 0 ]
  [ "$output" = "sl-agent-identity-state-protection" ]
}

@test "admission-cel: hostile pod spoofing cardvault in default namespace is rejected (HTTP 403 Forbidden)" {
  run kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hostile-spoof-cardvault-default-ns
  namespace: default
  labels:
    signalloom.ai/agent-name: cardvault
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Forbidden" ]]
  [[ "$output" =~ "sl-agent-identity-binding" ]]
  [[ "$output" =~ "pod labelled signalloom.ai/agent-name=cardvault must run in namespace 'fe-signalloom-agents'" ]]
}

@test "admission-cel: hostile pod spoofing cardvault with forged ServiceAccount in agent namespace is rejected" {
  run kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hostile-spoof-cardvault-forged-sa
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent-name: cardvault
spec:
  serviceAccountName: hosted-daytona-coder
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Forbidden" ]]
  [[ "$output" =~ "sl-agent-identity-binding" ]]
  [[ "$output" =~ "got namespace 'fe-signalloom-agents' and ServiceAccount 'hosted-daytona-coder'" ]]
}

@test "admission-cel: hostile pod spoofing kusari-agent with hostile ServiceAccount is rejected" {
  run kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hostile-spoof-kusari-hostile-sa
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent-name: kusari-agent
spec:
  serviceAccountName: hostile-test-sa
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Forbidden" ]]
  [[ "$output" =~ "sl-agent-identity-binding" ]]
  [[ "$output" =~ "ServiceAccount 'hostile-test-sa'" ]]
}

@test "admission-cel: legitimate registered cardvault pod with valid namespace and ServiceAccount is admitted" {
  run kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: legitimate-cardvault-admission
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent-name: cardvault
spec:
  serviceAccountName: agent-cardvault
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  [ "$status" -eq 0 ]
  [[ "$output" =~ "created" ]] || [[ "$output" =~ "configured" ]]
}

@test "admission-cel: hostile agent pod with invalid framework label is rejected (HTTP 422 Invalid)" {
  run kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hostile-invalid-framework-pod
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
    signalloom.ai/framework: "malicious-trojan"
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  [ "$status" -ne 0 ]
  [[ "$output" =~ [iI]nvalid ]]
  [[ "$output" =~ "sl-agent-identity-state-protection" ]]
  [[ "$output" =~ "must carry a valid signalloom.ai/framework label" ]]
}

@test "admission-cel: hostile agent pod with missing framework label is rejected (HTTP 422 Invalid)" {
  run kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hostile-missing-framework-pod
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  [ "$status" -ne 0 ]
  [[ "$output" =~ [iI]nvalid ]]
  [[ "$output" =~ "sl-agent-identity-state-protection" ]]
  [[ "$output" =~ "must carry a valid signalloom.ai/framework label" ]]
}

@test "admission-cel: legitimate agent pod with valid framework label custom is admitted" {
  run kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: legitimate-framework-pod
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
    signalloom.ai/framework: "custom"
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  [ "$status" -eq 0 ]
  [[ "$output" =~ "created" ]] || [[ "$output" =~ "configured" ]]
}

@test "admission-cel: unauthorized removal of signalloom.ai/state=stunned label is rejected (HTTP 403 Forbidden)" {
  # Ensure stunned pod exists
  kubectl apply -n fe-signalloom-agents -f - <<'EOF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: hostile-eval-stunned-pod
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
    signalloom.ai/framework: "custom"
    signalloom.ai/state: "stunned"
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF

  run kubectl patch pod hostile-eval-stunned-pod -n fe-signalloom-agents \
    --as="system:serviceaccount:fe-signalloom-agents:hostile-test-sa" \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":null}}}'

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Forbidden" ]]
  [[ "$output" =~ "The signalloom.ai/state=stunned label cannot be removed or mutated" ]]
}

@test "admission-cel: unauthorized mutation of signalloom.ai/state=stunned to idle is rejected" {
  run kubectl patch pod hostile-eval-stunned-pod -n fe-signalloom-agents \
    --as="system:serviceaccount:fe-signalloom-agents:hostile-test-sa" \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":"idle"}}}'

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Forbidden" ]]
  [[ "$output" =~ "The signalloom.ai/state=stunned label cannot be removed or mutated" ]]
}

@test "admission-cel: authorized cluster admin is permitted to un-stun pod" {
  run kubectl patch pod hostile-eval-stunned-pod -n fe-signalloom-agents \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":"idle"}}}'

  [ "$status" -eq 0 ]
  [[ "$output" =~ "patched" ]]

  # Restore state to stunned for clean state
  kubectl patch pod hostile-eval-stunned-pod -n fe-signalloom-agents \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":"stunned"}}}' >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2: Live Cluster Policy API Endpoints & Adversarial CEL Evaluation
# ═══════════════════════════════════════════════════════════════════════════════

@test "policy-api: unauthenticated request to /api/v1/policies/validate fails closed (HTTP 401)" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Content-Type: application/json" \
    -d '{"expression": "true"}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 401 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "authentication_required" ]] || [[ "$body" =~ "invalid_token" ]]
}

@test "policy-api: request with forged Bearer token fails closed (HTTP 401)" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer forged.invalid.signature.token" \
    -H "Content-Type: application/json" \
    -d '{"expression": "true"}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 401 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "invalid_token" ]]
}

@test "policy-api: adversarial CEL Python dunder injection attempt is rejected (HTTP 422)" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"expression": "__import__(\"os\").system(\"id\")"}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 422 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "cel_validation_error" ]]
  [[ "$body" =~ "Dangerous token or injection attempt detected" ]]
}

@test "policy-api: adversarial CEL ReDoS catastrophic backtracking pattern is rejected (HTTP 422)" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"expression": "request.path.matches(\"(a+)+\")"}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 422 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "cel_validation_error" ]]
  [[ "$body" =~ "ReDoS" ]]
}

@test "policy-api: adversarial CEL syntax mutation with broken operators is rejected (HTTP 422)" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"expression": "agent.trust_score > 5 ?::: 1"}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 422 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "cel_validation_error" ]]
  [[ "$body" =~ "Invalid ternary or coalescing operator syntax" ]]
}

@test "policy-api: adversarial CEL undefined root variable is rejected (HTTP 422)" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"expression": "unauthorized_root_variable.is_admin == true"}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 422 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "cel_validation_error" ]]
  [[ "$body" =~ "Undefined variable 'unauthorized_root_variable'" ]]
}

@test "policy-api: compliant CEL policy expression returns valid=true (HTTP 200)" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"expression": "has(agent.security_profile) && agent.security_profile.secure_by_default == true"}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 200 ]

  local body
  body="$(echo "$output" | sed '$d')"
  local is_valid
  is_valid="$(jq -r '.valid' <<<"$body")"
  [ "$is_valid" = "true" ]
}

@test "policy-api: live CEL evaluation against compliant context returns compliant=true" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/evaluate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"expression": "has(agent.security_profile) && agent.security_profile.secure_by_default == true", "context": {"agent": {"security_profile": {"secure_by_default": true}}}}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 200 ]

  local body
  body="$(echo "$output" | sed '$d')"
  local compliant
  compliant="$(jq -r '.compliant' <<<"$body")"
  [ "$compliant" = "true" ]
}

@test "policy-api: live CEL evaluation against non-compliant context returns compliant=false" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/evaluate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"expression": "has(agent.security_profile) && agent.security_profile.secure_by_default == true", "context": {"agent": {"security_profile": {"secure_by_default": false}}}}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 200 ]

  local body
  body="$(echo "$output" | sed '$d')"
  local compliant
  compliant="$(jq -r '.compliant' <<<"$body")"
  [ "$compliant" = "false" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3: Security Invariants (Fail-Closed, Zero Unhandled 500s, Boundaries)
# ═══════════════════════════════════════════════════════════════════════════════

@test "invariants: malformed JSON request body fails closed with 400 and zero 500s" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{malformed: true, unquoted_token,,}'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 400 ]
  [ "$code" -ne 500 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "invalid_json" ]]
}

@test "invariants: invalid Content-Type fails closed with 400 and zero 500s" {
  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: text/plain" \
    -d 'expression=true'

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 400 ]
  [ "$code" -ne 500 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "invalid_content_type" ]]
}

@test "invariants: oversized CEL expression (>4096 bytes) is safely rejected (HTTP 422)" {
  local huge_expr
  huge_expr="$(python3 -c 'print("agent.x == " + "1 && agent.x == " * 300 + "1")')"

  run curl -s -w "\n%{http_code}" -X POST "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"expression\": \"${huge_expr}\"}"

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 422 ]
  [ "$code" -ne 500 ]

  local body
  body="$(echo "$output" | sed '$d')"
  [[ "$body" =~ "exceeds maximum allowed length" ]]
}

@test "invariants: unsupported HTTP method returns 405 Method Not Allowed" {
  run curl -s -w "\n%{http_code}" -X DELETE "http://localhost:${FE_PORT}/api/v1/policies/validate" \
    -H "Authorization: Bearer ${TOKEN}"

  [ "$status" -eq 0 ]
  local code
  code="$(echo "$output" | tail -n1)"
  [ "$code" -eq 405 ]
  [ "$code" -ne 500 ]
}
