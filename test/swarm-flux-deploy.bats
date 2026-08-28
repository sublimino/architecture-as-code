#!/usr/bin/env bats
# test/swarm-flux-deploy.bats — Structural tests for the Flux ResourceSet
# that deploys the 10-agent Signal Loom swarm.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RS_FILE="$REPO_ROOT/d2-osramp-fleet/tenants/base/agent-swarm.yaml"
KUST_FILE="$REPO_ROOT/d2-osramp-fleet/tenants/base/kustomization.yaml"
SCRIPT="$REPO_ROOT/scripts/swarm-deploy.sh"

# ── ResourceSet existence and structure ───────────────────────────────

@test "agent-swarm.yaml exists" {
  [[ -f "$RS_FILE" ]]
}

@test "ResourceSet has correct apiVersion and kind" {
  grep -q 'apiVersion: fluxcd.controlplane.io/v1' "$RS_FILE"
  grep -q 'kind: ResourceSet' "$RS_FILE"
}

@test "ResourceSet name is agent-swarm in flux-system" {
  grep -q 'name: agent-swarm' "$RS_FILE"
  grep -q 'namespace: flux-system' "$RS_FILE"
}

@test "ResourceSet has reconcileEvery annotation" {
  grep -q 'reconcileEvery:' "$RS_FILE"
}

# ── dependsOn ─────────────────────────────────────────────────────────

@test "ResourceSet depends on signalloom-infra ResourceSet" {
  grep -q 'name: signalloom-infra' "$RS_FILE"
}

@test "ResourceSet depends on infra-configs Kustomization in inf-bao" {
  grep -q 'name: infra-configs' "$RS_FILE"
  grep -q 'namespace: inf-bao' "$RS_FILE"
}

# ── All 10 agents present ────────────────────────────────────────────

@test "ResourceSet contains prompt-commit-summarizer Kustomization" {
  grep -q 'name: agent-prompt-commit-summarizer' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/prompt-commit-summarizer' "$RS_FILE"
}

@test "ResourceSet contains triage-ci-worker Kustomization" {
  grep -q 'name: agent-triage-ci-worker' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/triage-ci-worker' "$RS_FILE"
}

@test "ResourceSet contains zulip-chat-agent Kustomization" {
  grep -q 'name: agent-zulip-chat-agent' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/zulip-chat-agent' "$RS_FILE"
}

@test "ResourceSet contains cpai-engineer Kustomization" {
  grep -q 'name: agent-cpai-engineer' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/cpai-engineer' "$RS_FILE"
}

@test "ResourceSet contains hosted-daytona-coder Kustomization" {
  grep -q 'name: agent-hosted-daytona-coder' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/hosted-daytona-coder' "$RS_FILE"
}

@test "ResourceSet contains swarm-governor Kustomization" {
  grep -q 'name: agent-swarm-governor' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/swarm-governor' "$RS_FILE"
}

@test "ResourceSet contains prod-deploy-gate Kustomization" {
  grep -q 'name: agent-prod-deploy-gate' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/prod-deploy-gate' "$RS_FILE"
}

@test "ResourceSet contains agent-cardvault Kustomization" {
  grep -q 'name: agent-cardvault' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/agent-cardvault' "$RS_FILE"
}

@test "ResourceSet contains nono-containment-probe Kustomization" {
  grep -q 'name: agent-nono-containment-probe' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/nono-containment-probe' "$RS_FILE"
}

@test "ResourceSet contains signalloom-stun-sentinel Kustomization" {
  grep -q 'name: agent-signalloom-stun-sentinel' "$RS_FILE"
  grep -q 'path: ./d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel' "$RS_FILE"
}

@test "ResourceSet has exactly 10 per-agent Kustomizations (plus base)" {
  local count
  # Count only spec.resources Kustomization objects (exclude dependsOn refs)
  # by matching lines with both kind: Kustomization AND a name: agent- prefix nearby.
  # Simpler: count metadata name lines for agent Kustomizations.
  count="$(grep -c 'name: agent-' "$RS_FILE")"
  # 11 base + 10 agents + agent-swarm-flux SA + agent-swarm-flux-namespaces (x2) + agent-swarm-flux-workloads + agent-swarm-flux RB + agent-swarm OCI
  # Better: count Kustomization resources by their path lines
  local path_count
  path_count="$(grep -c 'path: ./d2-signalloom/infra/agent-swarm' "$RS_FILE")"
  # 11 = 1 base (./d2-signalloom/infra/agent-swarm) + 10 agent subdirs
  [[ "$path_count" -eq 11 ]]
}

# ── RBAC resources ────────────────────────────────────────────────────

@test "ResourceSet creates agent-swarm-flux ServiceAccount" {
  grep -q 'name: agent-swarm-flux' "$RS_FILE"
  grep -q 'kind: ServiceAccount' "$RS_FILE"
}

@test "ResourceSet creates agent-swarm-flux-namespaces ClusterRole" {
  grep -q 'name: agent-swarm-flux-namespaces' "$RS_FILE"
  grep -q 'kind: ClusterRole' "$RS_FILE"
}

@test "ResourceSet creates agent-swarm-flux-namespaces ClusterRoleBinding" {
  grep -q 'name: agent-swarm-flux-namespaces' "$RS_FILE"
  grep -q 'kind: ClusterRoleBinding' "$RS_FILE"
}

@test "ResourceSet creates agent-swarm-flux-workloads ClusterRole" {
  grep -q 'name: agent-swarm-flux-workloads' "$RS_FILE"
}

@test "Workloads ClusterRole covers statefulsets and daemonsets" {
  grep -q 'statefulsets' "$RS_FILE"
  grep -q 'daemonsets' "$RS_FILE"
}

@test "Workloads ClusterRole covers persistentvolumeclaims" {
  grep -q 'persistentvolumeclaims' "$RS_FILE"
}

@test "Workloads ClusterRole covers Knative serving resources" {
  grep -q 'serving.knative.dev' "$RS_FILE"
}

# ── Namespace ─────────────────────────────────────────────────────────

@test "ResourceSet creates fe-signalloom-agents namespace" {
  grep -q 'name: fe-signalloom-agents' "$RS_FILE"
  grep -q 'kind: Namespace' "$RS_FILE"
}

@test "Namespace has signalloom.ai labels" {
  grep -q 'signalloom.ai/managed' "$RS_FILE"
  grep -q 'signalloom.ai/tier' "$RS_FILE"
}

# ── Inputs ────────────────────────────────────────────────────────────

@test "ResourceSet has envsubst inputs for tag and environment" {
  grep -q 'tag: "\${ARTIFACT_TAG}"' "$RS_FILE"
  grep -q 'environment: "\${ENVIRONMENT}"' "$RS_FILE"
}

# ── Kustomization integration ────────────────────────────────────────

@test "agent-swarm.yaml is listed in tenants kustomization" {
  grep -q 'agent-swarm.yaml' "$KUST_FILE"
}

# ── Deploy script ─────────────────────────────────────────────────────

@test "swarm-deploy.sh exists and is executable" {
  [[ -x "$SCRIPT" ]]
}

@test "swarm-deploy.sh is syntactically valid bash" {
  bash -n "$SCRIPT"
}

@test "swarm-deploy.sh has deploy command" {
  grep -q 'cmd_deploy' "$SCRIPT"
}

@test "swarm-deploy.sh has remove command" {
  grep -q 'cmd_remove' "$SCRIPT"
}

@test "swarm-deploy.sh has status command" {
  grep -q 'cmd_status' "$SCRIPT"
}

@test "swarm-deploy.sh has list command" {
  grep -q 'cmd_list' "$SCRIPT"
}

@test "swarm-deploy.sh lists all 10 agents" {
  local count
  count="$(grep -c 'agent-' "$SCRIPT" | head -1 || true)"
  # At least 10 agent references in the AGENTS array
  [[ "$(grep -c '^\s*agent-' "$SCRIPT")" -ge 10 ]]
}
