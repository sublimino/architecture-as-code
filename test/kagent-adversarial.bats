#!/usr/bin/env bats
# test/kagent-adversarial.bats — CEL ValidatingAdmissionPolicy & adversarial security boundary probes.
#
# OBJECTIVE:
# 1. Protect agent identity and containment state in fe-signalloom-agents.
# 2. Enforce that signalloom.ai/state=stunned cannot be removed or mutated by
#    unauthorized identities (only swarm-governor or cluster admin).
# 3. Enforce that any agent pod (signalloom.ai/agent=true) must carry a valid
#    signalloom.ai/framework label (e.g. kagent, langroid, autogen, custom).
# 4. Validate adversarial RBAC and isolation boundaries.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
    export KUBECONFIG="${KUBECONFIG}"
  elif [ -f "${REPO_ROOT}/.kind/kubeconfig" ] && kubectl --kubeconfig="${REPO_ROOT}/.kind/kubeconfig" cluster-info >/dev/null 2>&1; then
    export KUBECONFIG="${REPO_ROOT}/.kind/kubeconfig"
  elif [ -f "${HOME}/.kube/config" ] && kubectl --kubeconfig="${HOME}/.kube/config" cluster-info >/dev/null 2>&1; then
    export KUBECONFIG="${HOME}/.kube/config"
  fi
  NS="fe-signalloom-agents"
  POLICY_FILE="${REPO_ROOT}/d2-agent-trust/policies/agent-identity-state-protection.yaml"

  # Ensure policy is applied to cluster
  if [ -f "${POLICY_FILE}" ]; then
    kubectl apply -f "${POLICY_FILE}" >/dev/null 2>&1 || true
  fi
}

teardown() {
  # Clean up any test pods created in tests
  kubectl -n "${NS}" delete pod test-agent-valid test-agent-stunned test-agent-ephemeral --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "${NS}" delete rolebinding test-swarm-gov-rb --ignore-not-found >/dev/null 2>&1 || true
}

# Helper to assert a subject exists and is refused via auth can-i
assert_denied() {
  local sa="$1" verb="$2" resource="$3"
  shift 3
  local sa_ns="${SA_NS:-$NS}"

  kubectl get sa "$sa" -n "$sa_ns" >/dev/null 2>&1 || {
    echo "ServiceAccount ${sa_ns}/${sa} does not exist"
    return 1
  }

  local verdict
  verdict="$(kubectl auth can-i "$verb" "$resource" \
    --as="system:serviceaccount:${sa_ns}:${sa}" "$@" 2>/dev/null || true)"
  verdict="$(printf '%s' "$verdict" | tr -d '\r' | tail -1)"

  [ "$verdict" = "no" ] || {
    echo "${sa_ns}/${sa} is permitted to '${verb} ${resource}' ($*): '${verdict}'"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. CEL ValidatingAdmissionPolicy: Policy & Binding Readiness
# ─────────────────────────────────────────────────────────────────────────────

@test "cel-policy: admission policy and binding exist on cluster" {
  run kubectl get validatingadmissionpolicy sl-agent-identity-state-protection -o jsonpath='{.metadata.name}'
  [ "$status" -eq 0 ]
  [ "$output" = "sl-agent-identity-state-protection" ]

  run kubectl get validatingadmissionpolicybinding sl-agent-identity-state-protection-binding -o jsonpath='{.spec.policyName}'
  [ "$status" -eq 0 ]
  [ "$output" = "sl-agent-identity-state-protection" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Framework Label Validation on Agent Pod Creation
# ─────────────────────────────────────────────────────────────────────────────

@test "cel-policy: valid agent pod creation succeeds with standard framework labels" {
  for fw in kagent langroid autogen custom langgraph; do
    run kubectl apply --dry-run=server -n "${NS}" -f - <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-agent-valid-${fw}
  namespace: ${NS}
  labels:
    signalloom.ai/agent: "true"
    signalloom.ai/framework: "${fw}"
spec:
  containers:
    - name: agent
      image: ghcr.io/stefanprodan/podinfo:6.7.1
POD_EOF
    [ "$status" -eq 0 ]
    [[ "$output" =~ "created (server dry run)" ]] || {
      echo "Failed to create agent pod with framework ${fw}: ${output}"
      return 1
    }
  done
}

@test "cel-policy: non-agent pod creation succeeds without framework label" {
  run kubectl apply --dry-run=server -n "${NS}" -f - <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-non-agent-pod
  namespace: fe-signalloom-agents
  labels:
    app.kubernetes.io/name: helper
spec:
  containers:
    - name: app
      image: ghcr.io/stefanprodan/podinfo:6.7.1
POD_EOF
  [ "$status" -eq 0 ]
  [[ "$output" =~ "created (server dry run)" ]]
}

@test "cel-policy: agent pod creation is rejected when signalloom.ai/framework label is missing" {
  run kubectl apply --dry-run=server -n "${NS}" -f - <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-agent-missing-fw
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
spec:
  containers:
    - name: agent
      image: ghcr.io/stefanprodan/podinfo:6.7.1
POD_EOF
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Agent pods (signalloom.ai/agent=true) must carry a valid signalloom.ai/framework label" ]] || {
    echo "Expected rejection message for missing framework, got: ${output}"
    return 1
  }
}

@test "cel-policy: agent pod creation is rejected when signalloom.ai/framework label is invalid" {
  run kubectl apply --dry-run=server -n "${NS}" -f - <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-agent-invalid-fw
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
    signalloom.ai/framework: "unapproved-rogue-framework"
spec:
  containers:
    - name: agent
      image: ghcr.io/stefanprodan/podinfo:6.7.1
POD_EOF
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Agent pods (signalloom.ai/agent=true) must carry a valid signalloom.ai/framework label" ]] || {
    echo "Expected rejection message for invalid framework, got: ${output}"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Containment State Protection: signalloom.ai/state=stunned
# ─────────────────────────────────────────────────────────────────────────────

@test "cel-policy: creation of stunned agent pod succeeds" {
  run kubectl apply -n "${NS}" -f - <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-agent-stunned
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
    signalloom.ai/framework: "custom"
    signalloom.ai/state: "stunned"
spec:
  containers:
    - name: agent
      image: ghcr.io/stefanprodan/podinfo:6.7.1
POD_EOF
  [ "$status" -eq 0 ]
}

@test "cel-policy: unauthorized removal of signalloom.ai/state=stunned is rejected (HTTP 403 / Forbidden)" {
  # Ensure test stunned pod exists
  kubectl get pod test-agent-stunned -n "${NS}" >/dev/null 2>&1 || {
    kubectl apply -n "${NS}" -f - <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-agent-stunned
  namespace: fe-signalloom-agents
  labels:
    signalloom.ai/agent: "true"
    signalloom.ai/framework: "custom"
    signalloom.ai/state: "stunned"
spec:
  containers:
    - name: agent
      image: ghcr.io/stefanprodan/podinfo:6.7.1
POD_EOF
  }

  # Attempt removal of stunned label as unauthorized service account
  run kubectl patch pod test-agent-stunned -n "${NS}" \
    --as="system:serviceaccount:fe-signalloom:supercred-demo-runner" \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":null}}}'

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Forbidden" ]] || [[ "$output" =~ "denied request" ]]
  [[ "$output" =~ "The signalloom.ai/state=stunned label cannot be removed or mutated" ]] || {
    echo "Expected CEL denial message, got: ${output}"
    return 1
  }
}

@test "cel-policy: unauthorized mutation of signalloom.ai/state=stunned to idle is rejected" {
  run kubectl patch pod test-agent-stunned -n "${NS}" \
    --as="system:serviceaccount:fe-signalloom:supercred-demo-runner" \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":"idle"}}}'

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Forbidden" ]] || [[ "$output" =~ "denied request" ]]
  [[ "$output" =~ "The signalloom.ai/state=stunned label cannot be removed or mutated" ]]
}

@test "cel-policy: unprivileged metadata updates preserving signalloom.ai/state=stunned succeed" {
  run kubectl patch pod test-agent-stunned -n "${NS}" \
    --as="system:serviceaccount:fe-signalloom:supercred-demo-runner" \
    --type=merge \
    -p '{"metadata":{"annotations":{"test.signalloom.io/audited":"true"}}}'

  [ "$status" -eq 0 ]
  [[ "$output" =~ "patched" ]]
}

@test "cel-policy: authorized un-stunning by Swarm Governor succeeds" {
  # Bind supercred-demo-runner role to swarm-governor temporarily for test
  kubectl create rolebinding test-swarm-gov-rb \
    --role=supercred-demo-runner \
    --serviceaccount=fe-signalloom:swarm-governor \
    --serviceaccount=fe-signalloom-agents:swarm-governor \
    -n "${NS}" >/dev/null 2>&1 || true

  run kubectl patch pod test-agent-stunned -n "${NS}" \
    --as="system:serviceaccount:fe-signalloom:swarm-governor" \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":"idle"}}}'

  [ "$status" -eq 0 ]
  [[ "$output" =~ "patched" ]]

  # Re-stun for subsequent tests
  kubectl patch pod test-agent-stunned -n "${NS}" \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":"stunned"}}}' >/dev/null
}

@test "cel-policy: authorized un-stunning by cluster admin succeeds" {
  run kubectl patch pod test-agent-stunned -n "${NS}" \
    --type=merge \
    -p '{"metadata":{"labels":{"signalloom.ai/state":"idle"}}}'

  [ "$status" -eq 0 ]
  [[ "$output" =~ "patched" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. RBAC Adversarial Boundaries (Kagent / Agent Swarm)
# ─────────────────────────────────────────────────────────────────────────────

@test "kagent-adversarial: RBAC evaluation is live (positive control)" {
  if ! kubectl get sa kagent-k8s-reader -n "${NS}" >/dev/null 2>&1; then
    skip "kagent-k8s-reader ServiceAccount not yet deployed in ${NS}"
  fi

  verdict="$(kubectl auth can-i get pods \
    --as="system:serviceaccount:${NS}:kagent-k8s-reader" -n default 2>/dev/null || true)"
  verdict="$(printf '%s' "$verdict" | tr -d '\r' | tail -1)"
  [ "$verdict" = "yes" ] || {
    echo "kagent-k8s-reader cannot 'get pods', which its ClusterRole grants."
    echo "verdict: ${verdict}"
    return 1
  }
}

@test "kagent-adversarial: every agent ServiceAccount exists" {
  if ! kubectl get sa kagent-k8s-reader -n "${NS}" >/dev/null 2>&1; then
    skip "kagent agent ServiceAccounts not yet deployed in ${NS}"
  fi

  missing=""
  for sa in kagent-k8s-reader kagent-commit-summariser kagent-security-analyst \
    kagent-network-auditor kagent-incident-responder kagent-compliance-checker \
    kagent-finops-optimizer kagent-chaos-prober; do
    kubectl get sa "$sa" -n "${NS}" >/dev/null 2>&1 || missing+="$sa "
  done
  [ -z "$missing" ]
}

@test "kagent-adversarial: read-only reader SA is denied creating pods in any namespace" {
  if ! kubectl get sa kagent-k8s-reader -n "${NS}" >/dev/null 2>&1; then
    skip "kagent-k8s-reader not deployed"
  fi
  assert_denied kagent-k8s-reader create pods -n default
  assert_denied kagent-k8s-reader create pods -n kube-system
  assert_denied kagent-k8s-reader create pods -n "${NS}"
}

@test "kagent-adversarial: read-only reader SA is denied deleting namespaces" {
  if ! kubectl get sa kagent-k8s-reader -n "${NS}" >/dev/null 2>&1; then
    skip "kagent-k8s-reader not deployed"
  fi
  assert_denied kagent-k8s-reader delete namespaces
}

@test "kagent-adversarial: read-only reader SA is denied reading secrets" {
  if ! kubectl get sa kagent-k8s-reader -n "${NS}" >/dev/null 2>&1; then
    skip "kagent-k8s-reader not deployed"
  fi
  assert_denied kagent-k8s-reader get secrets -n kube-system
  assert_denied kagent-k8s-reader get secrets -n "${NS}"
}

@test "kagent-adversarial: commit-summariser SA is denied reading secrets outside its scope" {
  if ! kubectl get sa kagent-commit-summariser -n "${NS}" >/dev/null 2>&1; then
    skip "kagent-commit-summariser not deployed"
  fi
  assert_denied kagent-commit-summariser get secrets -n kube-system
}

@test "kagent-adversarial: security-analyst SA is denied modifying cluster RBAC bindings" {
  if ! kubectl get sa kagent-security-analyst -n "${NS}" >/dev/null 2>&1; then
    skip "kagent-security-analyst not deployed"
  fi
  assert_denied kagent-security-analyst create clusterrolebindings
}

@test "kagent-adversarial: the controller can write Agent status but cannot escalate RBAC" {
  if ! kubectl get sa kagent-controller -n kagent >/dev/null 2>&1; then
    skip "kagent-controller not deployed in kagent namespace"
  fi

  SA_NS=kagent
  verdict="$(kubectl auth can-i update agents/status \
    --as="system:serviceaccount:kagent:kagent-controller" -n "${NS}" 2>/dev/null || true)"
  verdict="$(printf '%s' "$verdict" | tr -d '\r' | tail -1)"
  if [ "$verdict" != "yes" ]; then
    skip "kagent-controller does not currently have update agents/status grant (control plane not reconciled)"
  fi

  assert_denied kagent-controller create clusterrolebindings
  assert_denied kagent-controller escalate clusterroles
}

@test "kagent-adversarial: postgres NetworkPolicy actually declares Ingress" {
  if ! kubectl get netpol kagent-postgres-isolation -n kagent >/dev/null 2>&1; then
    skip "kagent-postgres-isolation networkpolicy not deployed"
  fi

  run kubectl get netpol kagent-postgres-isolation -n kagent -o json
  [ "$status" -eq 0 ]
  types="$(printf '%s' "$output" | jq -r '(.spec.policyTypes // []) | join(",")')"
  [[ "$types" == *"Ingress"* ]]
}
