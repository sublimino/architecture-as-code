#!/usr/bin/env bats
# SuperCred demo validation — verifies the credential chain, compliance scan,
# and stun flow work end-to-end against the running cluster.
#
# Prerequisites: `make demo-signalloom-up && make demo-supercred-step1`
# must have completed. The bao slice and signalloom slice must be running.

NAMESPACE_INFRA="inf-signalloom"
NAMESPACE_BAO="inf-bao"
NAMESPACE_AGENTS="fe-signalloom-agents"
TIMEOUT="${DEMO_WAIT_TIMEOUT:-5m}"

# ─── Step 1 validation ───────────────────────────────────────────────────────

@test "SUPERCRED cardvault deployment is available" {
  run kubectl -n "$NAMESPACE_INFRA" wait deployment/cardvault \
    --for=condition=available --timeout=30s
  [ "$status" -eq 0 ]
}

@test "SUPERCRED policy-engine deployment is available" {
  run kubectl -n "$NAMESPACE_INFRA" wait deployment/policy-engine \
    --for=condition=available --timeout=30s
  [ "$status" -eq 0 ]
}

@test "SUPERCRED cardvault healthz returns 200" {
  run kubectl -n "$NAMESPACE_INFRA" exec deployment/cardvault -- \
    wget -qO- http://localhost:8080/healthz
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"ok"'* ]]
}

@test "SUPERCRED policy-engine healthz returns 200" {
  run kubectl -n "$NAMESPACE_INFRA" exec deployment/policy-engine -- \
    wget -qO- http://localhost:8081/healthz
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"ok"'* ]]
}

@test "SUPERCRED cardvault-agent pod exists in agents namespace" {
  run kubectl -n "$NAMESPACE_AGENTS" get pod agent-cardvault -o name
  [ "$status" -eq 0 ]
  [ "$output" = "pod/agent-cardvault" ]
}

@test "SUPERCRED cardvault-agent ServiceAccount exists" {
  run kubectl -n "$NAMESPACE_AGENTS" get sa cardvault-agent -o name
  [ "$status" -eq 0 ]
}

@test "SUPERCRED OpenBao supercred bootstrap completed" {
  run kubectl -n "$NAMESPACE_BAO" wait job/openbao-supercred-bootstrap \
    --for=condition=complete --timeout=30s
  [ "$status" -eq 0 ]
}

@test "SUPERCRED cardvault-agent has supercred label" {
  LABELS=$(kubectl -n "$NAMESPACE_AGENTS" get pod agent-cardvault \
    -o jsonpath='{.metadata.labels.signalloom\.ai/supercred}')
  [ "$LABELS" = "true" ]
}

@test "SUPERCRED agent pod INTENTIONALLY lacks pod-level securityContext" {
  SC=$(kubectl -n "$NAMESPACE_AGENTS" get pod agent-cardvault \
    -o jsonpath='{.spec.securityContext}')
  # Empty or just {} means no meaningful fields set
  [[ "$SC" == "" ]] || [[ "$SC" == "{}" ]]
}

# ─── Step 2 validation (credential chain) ────────────────────────────────────

@test "SUPERCRED cardvault rejects unauthenticated requests" {
  run kubectl -n "$NAMESPACE_INFRA" exec deployment/cardvault -- \
    wget -qO- http://localhost:8080/api/v1/cards 2>&1
  [ "$status" -ne 0 ]
}

# ─── Step 3 validation (compliance scan) ─────────────────────────────────────

@test "SUPERCRED policy-engine correctly evaluates non-compliant agent" {
  POD_SPEC='{"containers":[{"name":"agent","securityContext":null}],"securityContext":null}'
  RESULT=$(kubectl -n "$NAMESPACE_INFRA" exec deployment/policy-engine -- \
    wget -qO- --post-data="{\"agent_id\":\"cardvault\",\"namespace\":\"$NAMESPACE_AGENTS\",\"pod_spec\":$POD_SPEC,\"checks\":[\"security-context-present\",\"run-as-non-root\",\"drop-capabilities\"]}" \
    --header='Content-Type: application/json' \
    http://localhost:8081/api/v1/evaluate 2>/dev/null)
  echo "$RESULT"
  # Must report non-compliant
  [[ "$RESULT" == *'"compliant":false'* ]]
  # Must fail the security-context-present check
  [[ "$RESULT" == *'"security-context-present"'* ]]
}

@test "SUPERCRED policy-engine correctly evaluates compliant pod spec" {
  POD_SPEC='{"containers":[{"name":"c","securityContext":{"capabilities":{"drop":["ALL"]}}}],"securityContext":{"runAsNonRoot":true}}'
  RESULT=$(kubectl -n "$NAMESPACE_INFRA" exec deployment/policy-engine -- \
    wget -qO- --post-data="{\"agent_id\":\"test\",\"namespace\":\"default\",\"pod_spec\":$POD_SPEC,\"checks\":[\"security-context-present\",\"run-as-non-root\",\"drop-capabilities\"]}" \
    --header='Content-Type: application/json' \
    http://localhost:8081/api/v1/evaluate 2>/dev/null)
  echo "$RESULT"
  [[ "$RESULT" == *'"compliant":true'* ]]
}
