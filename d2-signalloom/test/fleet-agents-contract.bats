#!/usr/bin/env bats
# Fleet agents contract tests — validates agent profiles, dependency DAG,
# SPIFFE naming conventions, fleet ConfigMap consistency, and bootstrap
# non-overlap with the single-agent bootstrap.
#
# These tests run offline (no cluster required) against the YAML files.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AGENTS_DIR="${REPO_ROOT}/d2-signalloom/agents"
  FLEET_AGENTS_DIR="${REPO_ROOT}/d2-signalloom/apps/fleet-agents/base"
  FLEET_CONFIG="${REPO_ROOT}/d2-signalloom/apps/fleet-manager/base/fleet-config.yaml"
  FLEET_BOOTSTRAP="${REPO_ROOT}/d2-signalloom/infra/inf-bao/configs/base/openbao-fleet-bootstrap.yaml"
  SINGLE_BOOTSTRAP="${REPO_ROOT}/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
  FLEET_SCRIPT="${REPO_ROOT}/scripts/supercred-fleet-demo.sh"

  AGENT_NAMES=(
    agent-cardvault
    agent-txn-pipeline
    agent-llm-classifier
    agent-api-gateway
    agent-monitor
  )
}

# ─── Agent profile YAML validity ─────────────────────────────────────────────

@test "FLEET every agent profile YAML is parseable" {
  for name in "${AGENT_NAMES[@]}"; do
    run yq '.' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "FLEET every agent profile has required fields" {
  for name in "${AGENT_NAMES[@]}"; do
    # apiVersion
    run yq '.apiVersion' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "signalloom.controlplane.io/v1alpha1" ]

    # kind
    run yq '.kind' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "AgentProfile" ]

    # metadata.name
    run yq '.metadata.name' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "$name" ]

    # spec.type
    run yq '.spec.type' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]

    # spec.team
    run yq '.spec.team' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]

    # spec.trustProfile
    run yq '.spec.trustProfile' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]

    # spec.riskClass
    run yq '.spec.riskClass' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]

    # spec.spiffe.path
    run yq '.spec.spiffe.path' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]

    # spec.openbao.authMount
    run yq '.spec.openbao.authMount' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != "null" ]]
  done
}

# ─── SPIFFE naming convention ────────────────────────────────────────────────

@test "FLEET every agent SPIFFE path matches /ns/<team>/sa/<name> convention" {
  for name in "${AGENT_NAMES[@]}"; do
    local spiffe_path
    spiffe_path=$(yq '.spec.spiffe.path' "${AGENTS_DIR}/${name}.yaml")
    # Must start with /ns/ and contain /sa/
    [[ "$spiffe_path" =~ ^/ns/[a-z-]+/sa/[a-z-]+$ ]]
  done
}

@test "FLEET every agent SPIFFE trustDomain is signalloom.local" {
  for name in "${AGENT_NAMES[@]}"; do
    run yq '.spec.spiffe.trustDomain' "${AGENTS_DIR}/${name}.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "signalloom.local" ]
  done
}

# ─── Dependency graph validation ─────────────────────────────────────────────

@test "FLEET every dependency references an agent that exists in the set" {
  for name in "${AGENT_NAMES[@]}"; do
    local deps
    deps=$(yq '.spec.dependencies[]' "${AGENTS_DIR}/${name}.yaml" 2>/dev/null) || continue
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      # Check the dependency exists as a profile file
      [ -f "${AGENTS_DIR}/${dep}.yaml" ] || {
        echo "FAIL: ${name} depends on ${dep} which does not exist"
        return 1
      }
    done <<< "$deps"
  done
}

@test "FLEET dependency graph is acyclic (topological sort succeeds)" {
  # Build adjacency list and run a simple cycle detection
  # Using a DFS-based cycle check via shell
  local -A visited=()
  local -A in_stack=()

  dfs() {
    local node="$1"
    if [[ "${in_stack[$node]:-}" == "1" ]]; then
      echo "CYCLE detected at: $node"
      return 1
    fi
    if [[ "${visited[$node]:-}" == "1" ]]; then
      return 0
    fi
    in_stack[$node]=1
    visited[$node]=1

    local deps
    deps=$(yq '.spec.dependencies[]' "${AGENTS_DIR}/${node}.yaml" 2>/dev/null) || true
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      dfs "$dep" || return 1
    done <<< "$deps"

    in_stack[$node]=0
    return 0
  }

  for name in "${AGENT_NAMES[@]}"; do
    dfs "$name" || {
      echo "Dependency graph has a cycle involving $name"
      return 1
    }
  done
}

@test "FLEET dependency graph renders correctly" {
  # Print the DAG for visual inspection
  echo "# Fleet Dependency Graph (The Cascade)"
  echo "#"
  echo "#   agent-cardvault (root, no deps)"
  echo "#     |--- agent-txn-pipeline"
  echo "#     |     |--- agent-llm-classifier"
  echo "#     |--- agent-api-gateway"
  echo "#     |--- agent-monitor (depends on ALL)"
  echo "#"

  for name in "${AGENT_NAMES[@]}"; do
    local deps
    deps=$(yq '.spec.dependencies | join(", ")' "${AGENTS_DIR}/${name}.yaml" 2>/dev/null) || deps=""
    if [ -z "$deps" ] || [ "$deps" = "" ]; then
      echo "  $name -> (root)"
    else
      echo "  $name -> $deps"
    fi
  done
}

# ─── Fleet ConfigMap consistency ─────────────────────────────────────────────

@test "FLEET ConfigMap is parseable YAML" {
  run yq '.' "$FLEET_CONFIG"
  [ "$status" -eq 0 ]
}

@test "FLEET ConfigMap agent count matches profile count" {
  local configmap_count
  configmap_count=$(yq '.data["fleet.yaml"]' "$FLEET_CONFIG" | yq '.spec.agents | length')
  [ "$configmap_count" -eq 5 ]
}

@test "FLEET ConfigMap agent names match profile names" {
  for name in "${AGENT_NAMES[@]}"; do
    local found
    found=$(yq '.data["fleet.yaml"]' "$FLEET_CONFIG" \
      | yq ".spec.agents[] | select(.name == \"$name\") | .name")
    [ "$found" = "$name" ]
  done
}

@test "FLEET ConfigMap agent types match profiles" {
  for name in "${AGENT_NAMES[@]}"; do
    local profile_type configmap_type
    profile_type=$(yq '.spec.type' "${AGENTS_DIR}/${name}.yaml")
    configmap_type=$(yq '.data["fleet.yaml"]' "$FLEET_CONFIG" \
      | yq ".spec.agents[] | select(.name == \"$name\") | .type")
    [ "$profile_type" = "$configmap_type" ]
  done
}

@test "FLEET ConfigMap agent teams match profiles" {
  for name in "${AGENT_NAMES[@]}"; do
    local profile_team configmap_team
    profile_team=$(yq '.spec.team' "${AGENTS_DIR}/${name}.yaml")
    configmap_team=$(yq '.data["fleet.yaml"]' "$FLEET_CONFIG" \
      | yq ".spec.agents[] | select(.name == \"$name\") | .team")
    [ "$profile_team" = "$configmap_team" ]
  done
}

# ─── Bootstrap non-overlap ───────────────────────────────────────────────────

@test "FLEET bootstrap job name differs from single-agent bootstrap" {
  local fleet_name single_name
  fleet_name=$(yq '.metadata.name' "$FLEET_BOOTSTRAP")
  single_name=$(yq '.metadata.name' "$SINGLE_BOOTSTRAP")
  [ "$fleet_name" != "$single_name" ]
  [ "$fleet_name" = "openbao-fleet-bootstrap" ]
  [ "$single_name" = "openbao-supercred-bootstrap" ]
}

@test "FLEET bootstrap does not reference cardvault-agent KV path" {
  # The fleet bootstrap should NOT seed kv/signalloom/cardvault-agent —
  # that belongs to the single-agent bootstrap.
  run grep -c 'kv/signalloom/cardvault-agent' "$FLEET_BOOTSTRAP"
  [ "$output" = "0" ] || [ "$status" -ne 0 ]
}

@test "FLEET bootstrap uses distinct policy names from single-agent" {
  local fleet_policies single_policy
  single_policy=$(grep 'bao policy write' "$SINGLE_BOOTSTRAP" | awk '{print $4}' | head -1)
  fleet_policies=$(grep 'bao policy write' "$FLEET_BOOTSTRAP" | awk '{print $4}')

  while IFS= read -r fp; do
    [ -z "$fp" ] && continue
    [ "$fp" != "$single_policy" ]
  done <<< "$fleet_policies"
}

# ─── Script syntax ───────────────────────────────────────────────────────────

@test "FLEET demo script passes bash -n syntax check" {
  run bash -n "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "FLEET demo script does not use set -u" {
  run grep -c 'set -u' "$FLEET_SCRIPT"
  # grep returns 1 when no match (which is what we want)
  [ "$status" -eq 1 ] || [ "$output" = "0" ]
}

# ─── Pod manifests ───────────────────────────────────────────────────────────

@test "FLEET kustomization.yaml is valid" {
  run yq '.' "${FLEET_AGENTS_DIR}/kustomization.yaml"
  [ "$status" -eq 0 ]
}

@test "FLEET pod manifests exist for all non-cardvault agents" {
  for name in agent-txn-pipeline agent-llm-classifier agent-api-gateway agent-monitor; do
    [ -f "${FLEET_AGENTS_DIR}/${name}.yaml" ]
  done
}

@test "FLEET pod manifests have correct fleet labels" {
  for name in agent-txn-pipeline agent-llm-classifier agent-api-gateway agent-monitor; do
    # Select the Pod document (second doc in multi-doc YAML)
    local agent_label fleet_label
    agent_label=$(yq 'select(.kind == "Pod") | .metadata.labels["signalloom.ai/agent"]' \
      "${FLEET_AGENTS_DIR}/${name}.yaml")
    fleet_label=$(yq 'select(.kind == "Pod") | .metadata.labels["signalloom.ai/fleet"]' \
      "${FLEET_AGENTS_DIR}/${name}.yaml")
    [ "$agent_label" = "true" ]
    [ "$fleet_label" = "supercred" ]
  done
}

@test "FLEET pod manifests have securityContext (unlike cardvault)" {
  for name in agent-txn-pipeline agent-llm-classifier agent-api-gateway agent-monitor; do
    local run_as
    run_as=$(yq 'select(.kind == "Pod") | .spec.securityContext.runAsNonRoot' \
      "${FLEET_AGENTS_DIR}/${name}.yaml")
    [ "$run_as" = "true" ]
  done
}
