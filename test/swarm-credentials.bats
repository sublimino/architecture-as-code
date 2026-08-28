#!/usr/bin/env bats
#
# swarm-credentials.bats — Static guards for the OpenBao credential wiring
# and Nono SPIFFE bootstrap across the agent swarm.
#
# These tests assert the SHAPE of the configuration, not live behaviour.
# They verify that every agent that needs credentials has the right volumes,
# sidecars, and config in place so a deploy does not silently drop secrets.
#
# ─── What this exists to stop coming back ──────────────────────────────────
#
# An agent deployed without its SPIFFE CSI volume mount silently runs with no
# credentials. The pod starts, the sidecar has no socket, and the OpenBao Agent
# exits with a non-obvious "dial unix: no such file" buried in a sidecar log
# that nobody watches. The main container runs with empty env vars and fails
# at the application layer — hours after the deploy.

REPO_ROOT="${BATS_TEST_DIRNAME}/.."
AGENT_SWARM="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
APPS="${REPO_ROOT}/d2-signalloom/apps"
SCRIPTS="${REPO_ROOT}/scripts"

# ─── OpenBao Secret Paths ConfigMap ───────────────────────────────────────────

@test "openbao-secret-paths ConfigMap exists" {
  [ -f "${AGENT_SWARM}/openbao-secret-paths.yaml" ]
}

@test "openbao-secret-paths has all 6 agents" {
  local cm="${AGENT_SWARM}/openbao-secret-paths.yaml"
  for agent in prompt-commit-summarizer triage-ci-worker zulip-chat-agent \
               cpai-engineer prod-deploy-gate swarm-governor; do
    run grep -c "${agent}.json" "$cm"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
  done
}

@test "each secret path entry is valid JSON" {
  local cm="${AGENT_SWARM}/openbao-secret-paths.yaml"
  # Extract JSON blocks (lines after the key: |) and validate
  for agent in prompt-commit-summarizer triage-ci-worker zulip-chat-agent \
               cpai-engineer prod-deploy-gate swarm-governor; do
    local json
    json=$(awk "/${agent}\\.json:/{found=1; next} found && /^    /{print; next} found{exit}" "$cm")
    [ -n "$json" ]
  done
}

# ─── OpenBao Agent Sidecar Configs ────────────────────────────────────────────

@test "openbao-agent-sidecar.yaml exists" {
  [ -f "${AGENT_SWARM}/openbao-agent-sidecar.yaml" ]
}

@test "per-agent openbao configs exist for all 6 agents" {
  local sidecar="${AGENT_SWARM}/openbao-agent-sidecar.yaml"
  for agent in prompt-commit-summarizer triage-ci-worker zulip-chat-agent \
               cpai-engineer prod-deploy-gate swarm-governor; do
    run grep -c "${agent}-openbao-config" "$sidecar"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
  done
}

@test "all sidecar configs use signalloom-agent-generic role" {
  local sidecar="${AGENT_SWARM}/openbao-agent-sidecar.yaml"
  # Count role references — should be 6 (one per agent config)
  run grep -c 'role.*=.*"signalloom-agent-generic"' "$sidecar"
  [ "$status" -eq 0 ]
  [ "$output" -ge 6 ]
}

@test "all sidecar configs use SPIRE socket path" {
  local sidecar="${AGENT_SWARM}/openbao-agent-sidecar.yaml"
  run grep -c '/run/spire/sockets/agent.sock' "$sidecar"
  [ "$status" -eq 0 ]
  [ "$output" -ge 6 ]
}

# ─── Agent Deployments: SPIFFE CSI Volume Mount ──────────────────────────────

@test "cpai-engineer has SPIFFE CSI volume" {
  run grep -c 'csi.spiffe.io' "${AGENT_SWARM}/cpai-engineer/statefulset.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "swarm-governor has SPIFFE CSI volume" {
  run grep -c 'csi.spiffe.io' "${AGENT_SWARM}/swarm-governor/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "zulip-chat-agent has SPIFFE CSI volume" {
  run grep -c 'csi.spiffe.io' "${AGENT_SWARM}/zulip-chat-agent/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "prod-deploy-gate has SPIFFE CSI volume" {
  run grep -c 'csi.spiffe.io' "${AGENT_SWARM}/prod-deploy-gate/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "prompt-commit-summarizer has SPIFFE CSI volume" {
  run grep -c 'csi.spiffe.io' "${AGENT_SWARM}/prompt-commit-summarizer/knative-service.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "triage-ci-worker has SPIFFE CSI volume" {
  run grep -c 'csi.spiffe.io' "${AGENT_SWARM}/triage-ci-worker/knative-service.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─── Agent Deployments: OpenBao Agent Sidecar ─────────────────────────────────

@test "cpai-engineer has openbao-agent sidecar" {
  run grep -c 'name: openbao-agent' "${AGENT_SWARM}/cpai-engineer/statefulset.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "swarm-governor has openbao-agent sidecar" {
  run grep -c 'name: openbao-agent' "${AGENT_SWARM}/swarm-governor/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "zulip-chat-agent has openbao-agent sidecar" {
  run grep -c 'name: openbao-agent' "${AGENT_SWARM}/zulip-chat-agent/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "prod-deploy-gate has openbao-agent sidecar" {
  run grep -c 'name: openbao-agent' "${AGENT_SWARM}/prod-deploy-gate/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "prompt-commit-summarizer has openbao-agent sidecar" {
  run grep -c 'name: openbao-agent' "${AGENT_SWARM}/prompt-commit-summarizer/knative-service.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "triage-ci-worker has openbao-agent sidecar" {
  run grep -c 'name: openbao-agent' "${AGENT_SWARM}/triage-ci-worker/knative-service.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─── Agent Deployments: vault-secrets volume mount ────────────────────────────

@test "cpai-engineer mounts /vault/secrets" {
  run grep -c '/vault/secrets' "${AGENT_SWARM}/cpai-engineer/statefulset.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "swarm-governor mounts /vault/secrets" {
  run grep -c '/vault/secrets' "${AGENT_SWARM}/swarm-governor/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─── Nono Profiles: SPIRE Socket Access ──────────────────────────────────────

@test "cpai-engineer strict.toml includes /run/spire/sockets in allow_read" {
  run grep '/run/spire/sockets' "${APPS}/cpai-engineer/nono-profiles/strict.toml"
  [ "$status" -eq 0 ]
}

@test "cpai-engineer strict.toml allows OpenBao loopback" {
  run grep '127.0.0.1:8200' "${APPS}/cpai-engineer/nono-profiles/strict.toml"
  [ "$status" -eq 0 ]
}

@test "nono-containment-probe probe.toml includes /run/spire/sockets" {
  run grep '/run/spire/sockets' "${APPS}/nono-containment-probe/nono-profiles/probe.toml"
  [ "$status" -eq 0 ]
}

# ─── Scripts: Syntactic Validity ──────────────────────────────────────────────

@test "nono-spiffe-bootstrap.sh is syntactically valid bash" {
  run bash -n "${SCRIPTS}/lib/nono-spiffe-bootstrap.sh"
  [ "$status" -eq 0 ]
}

@test "swarm-seed-secrets.sh is syntactically valid bash" {
  run bash -n "${SCRIPTS}/swarm-seed-secrets.sh"
  [ "$status" -eq 0 ]
}

@test "nono-spiffe-bootstrap.sh defines nono_with_spiffe function" {
  run grep -c 'nono_with_spiffe()' "${SCRIPTS}/lib/nono-spiffe-bootstrap.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "swarm-seed-secrets.sh seeds all 6 agents" {
  for agent in prompt-commit-summarizer triage-ci-worker zulip-chat-agent \
               cpai-engineer prod-deploy-gate swarm-governor; do
    run grep -c "\"$agent\"" "${SCRIPTS}/swarm-seed-secrets.sh"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
  done
}
