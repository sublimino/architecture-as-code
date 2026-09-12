#!/usr/bin/env bats
# test/signalloom/dual-agents-deployed.bats — Verification of dual demo agent deployment in fe-signalloom-agents.
#
# Covers Mission SLON (Signal Loom First User and Agent Onboarding — Phase 2-1):
# 1. Verification of concurrent pod rollout for agent-nono-evidenced and agent-standard-baseline.
# 2. ServiceAccount and SPIFFE identity registration verification under trust domain spiffe://signalloom.demo/.
# 3. Discoverable metadata labels (signalloom.io/agent=demo, signalloom.io/workload-profile).
# 4. SPIFFE Workload API socket volume mount (/run/spire/sockets/agent.sock).
# 5. SP-5 dynamic capability probe and graceful fallback execution without pod crashes.
# 6. Structured heartbeat telemetry emission from both workloads.
# 7. Dynamic inventory discovery via Signal Loom backend proxy.

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  for cmd in kubectl jq curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Prerequisite tool '$cmd' missing" >&2
      return 1
    }
  done

  kubectl get nodes >/dev/null 2>&1 || {
    echo "Kubernetes cluster unreachable" >&2
    return 1
  }
}

@test "1. Both demo agent deployments are rolled out and healthy in fe-signalloom-agents" {
  run kubectl -n fe-signalloom-agents rollout status deployment/agent-nono-evidenced --timeout=30s
  [ "$status" -eq 0 ]
  [[ "$output" =~ "successfully rolled out" ]]

  run kubectl -n fe-signalloom-agents rollout status deployment/agent-standard-baseline --timeout=30s
  [ "$status" -eq 0 ]
  [[ "$output" =~ "successfully rolled out" ]]
}

@test "2. ServiceAccounts and unique SPIFFE workload identities exist for both demo agents" {
  run kubectl -n fe-signalloom-agents get sa agent-nono-evidenced
  [ "$status" -eq 0 ]

  run kubectl -n fe-signalloom-agents get sa agent-standard-baseline
  [ "$status" -eq 0 ]

  run kubectl -n inf-bao exec deployment/spire-server -- \
    /opt/spire/bin/spire-server entry show -spiffeID "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced" ]]
  [[ "$output" =~ "k8s:sa:agent-nono-evidenced" ]]

  run kubectl -n inf-bao exec deployment/spire-server -- \
    /opt/spire/bin/spire-server entry show -spiffeID "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline" ]]
  [[ "$output" =~ "k8s:sa:agent-standard-baseline" ]]
}

@test "3. Both workloads declare discoverable metadata labels and annotations" {
  run kubectl -n fe-signalloom-agents get deployment agent-nono-evidenced -o json
  [ "$status" -eq 0 ]
  nono_agent_label=$(echo "$output" | jq -r '.metadata.labels["signalloom.io/agent"]')
  nono_profile_label=$(echo "$output" | jq -r '.metadata.labels["signalloom.io/workload-profile"]')
  nono_ai_agent=$(echo "$output" | jq -r '.metadata.labels["signalloom.ai/agent"]')
  [ "$nono_agent_label" = "demo" ]
  [ "$nono_profile_label" = "nono-evidenced" ]
  [ "$nono_ai_agent" = "true" ]

  run kubectl -n fe-signalloom-agents get deployment agent-standard-baseline -o json
  [ "$status" -eq 0 ]
  base_agent_label=$(echo "$output" | jq -r '.metadata.labels["signalloom.io/agent"]')
  base_profile_label=$(echo "$output" | jq -r '.metadata.labels["signalloom.io/workload-profile"]')
  base_ai_agent=$(echo "$output" | jq -r '.metadata.labels["signalloom.ai/agent"]')
  [ "$base_agent_label" = "demo" ]
  [ "$base_profile_label" = "standard-baseline" ]
  [ "$base_ai_agent" = "true" ]
}

@test "4. SPIFFE Workload API socket is mounted at /run/spire/sockets in both agent pods" {
  run kubectl -n fe-signalloom-agents logs deploy/agent-nono-evidenced -c agent
  [ "$status" -eq 0 ]
  [[ "$output" =~ "[SPIFFE] Workload API socket verified available at /run/spire/sockets/agent.sock" ]]

  run kubectl -n fe-signalloom-agents logs deploy/agent-standard-baseline -c agent
  [ "$status" -eq 0 ]
  [[ "$output" =~ "[SPIFFE] Workload API socket verified available at /run/spire/sockets/agent.sock" ]]
}

@test "5. SP-5 dynamic Nono capability probe runs and emits structured fallback/detection telemetry" {
  run kubectl -n fe-signalloom-agents logs deploy/agent-nono-evidenced -c agent
  [ "$status" -eq 0 ]
  [[ "$output" =~ "[NONO-PROBE]" ]]
  [[ "$output" =~ "nono_capability_available" || "$output" =~ "nono_available" ]]
}

@test "6. Both demo agent pods emit periodic structured heartbeat telemetry" {
  run kubectl -n fe-signalloom-agents logs deploy/agent-nono-evidenced -c agent --tail=5
  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"agent_id\":\"agent-nono-evidenced\"" ]]
  [[ "$output" =~ "\"profile\":\"nono-evidenced\"" ]]
  [[ "$output" =~ "\"status\":\"healthy\"" ]]

  run kubectl -n fe-signalloom-agents logs deploy/agent-standard-baseline -c agent --tail=5
  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"agent_id\":\"agent-standard-baseline\"" ]]
  [[ "$output" =~ "\"profile\":\"standard-baseline\"" ]]
  [[ "$output" =~ "\"status\":\"healthy\"" ]]
}

@test "7. Signal Loom agent inventory service dynamically discovers both demo workloads" {
  run kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
    curl -sS http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/agents
  [ "$status" -eq 0 ]
  
  nono_found=$(echo "$output" | jq -r '.agents[] | select(.id | startswith("agent-nono-evidenced")) | .name')
  base_found=$(echo "$output" | jq -r '.agents[] | select(.id | startswith("agent-standard-baseline")) | .name')
  
  [ "$nono_found" = "Demo Agent (Nono Evidenced)" ]
  [ "$base_found" = "Demo Agent (Standard Baseline)" ]
}
