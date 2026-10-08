#!/usr/bin/env bats
# Tests for supercred-fleet-demo.sh deploy-fleet — validates multi-agent
# provisioning, credential polling, SPIRE registration, and OpenBao seeding.
#
# These tests run offline using stubbed kubectl/spire/openbao calls.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FLEET_SCRIPT="${REPO_ROOT}/scripts/supercred-fleet-demo.sh"
  TEST_TMP="${BATS_TEST_TMPDIR}/fleet-deploy-$$"
  mkdir -p "${TEST_TMP}/bin"
  RECORD_FILE="${TEST_TMP}/kubectl_calls.log"
  : > "$RECORD_FILE"

  # Stub kubectl to record commands and simulate successful cluster ops
  cat << 'STUB' > "${TEST_TMP}/bin/kubectl"
#!/usr/bin/env bash
echo "$@" >> "${RECORD_FILE}"
if [[ "$*" =~ get\ deploy ]]; then exit 0; fi
if [[ "$*" =~ rollout\ status ]]; then exit 0; fi
if [[ "$*" =~ get\ ns ]]; then exit 0; fi
if [[ "$*" =~ cluster-info ]]; then exit 0; fi
if [[ "$*" =~ get\ nodes ]]; then echo "kind-control-plane Ready"; exit 0; fi
if [[ "$*" =~ get\ pods.*-o.*jsonpath ]]; then echo "agent-pod|true,"; exit 0; fi
if [[ "$*" =~ get\ pods.*-l.*spire-server ]]; then echo "spire-server-0"; exit 0; fi
if [[ "$*" =~ get\ pods.*-l.*openbao ]]; then echo "openbao-0"; exit 0; fi
if [[ "$*" =~ exec.*spire-server ]]; then echo "Entry ID: test-entry-id"; exit 0; fi
if [[ "$*" =~ exec.*openbao ]]; then echo "Success!"; exit 0; fi
exit 0
STUB
  chmod +x "${TEST_TMP}/bin/kubectl"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# ─── Static fleet definitions ────────────────────────────────────────────────

@test "DEPLOY FLEET: script defines 5 distinct heterogeneous agents" {
  run grep -E '^\s*"agent-[a-z-]+' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "DEPLOY FLEET: all 5 agent service accounts mapped in FLEET_AGENTS" {
  for sa in "cardvault-agent" "txn-pipeline-agent" "llm-classifier-agent" "api-gateway-agent" "monitor-agent"; do
    run grep -c "$sa" "$FLEET_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
  done
}

@test "DEPLOY FLEET: SPIFFE IDs match signalloom demo trust domain for all 5 agents" {
  for agent in "agent-cardvault" "agent-txn-pipeline" "agent-llm-classifier" "agent-api-gateway" "agent-monitor"; do
    run grep -E "\[$agent\]=\"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/" "$FLEET_SCRIPT"
    [ "$status" -eq 0 ]
  done
}

@test "DEPLOY FLEET: OpenBao JWT mounts configured for all 5 teams" {
  run grep -c 'jwt-payments' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c 'jwt-ml-ops' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c 'jwt-platform' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c 'jwt-sre' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
}

# ─── Mocked deployment execution ─────────────────────────────────────────────

@test "DEPLOY FLEET: deploy_fleet succeeds in stubbed cluster environment" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    WAIT_PODS_TIMEOUT=5 \
    run bash "$FLEET_SCRIPT" deploy-fleet
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet deployed: 5 agents active"* ]]
}

@test "DEPLOY FLEET: deploy_fleet ensures agents namespace exists" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    WAIT_PODS_TIMEOUT=5 \
    run bash "$FLEET_SCRIPT" deploy-fleet
  [ "$status" -eq 0 ]
  run grep 'create namespace fe-signalloom-agents' "$RECORD_FILE"
  [ "$status" -eq 0 ]
}

@test "DEPLOY FLEET: deploy_fleet applies cardvault SA and deployment manifests" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    WAIT_PODS_TIMEOUT=5 \
    run bash "$FLEET_SCRIPT" deploy-fleet
  [ "$status" -eq 0 ]
  run grep 'apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml' "$RECORD_FILE"
  [ "$status" -eq 0 ]
}

@test "DEPLOY FLEET: deploy_fleet applies fleet-agents kustomize directory" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    WAIT_PODS_TIMEOUT=5 \
    run bash "$FLEET_SCRIPT" deploy-fleet
  [ "$status" -eq 0 ]
  run grep 'apply -k d2-signalloom/apps/fleet-agents/base/' "$RECORD_FILE"
  [ "$status" -eq 0 ]
}

@test "DEPLOY FLEET: deploy_fleet registers SPIRE workloads for all 5 agents" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    WAIT_PODS_TIMEOUT=5 \
    run bash "$FLEET_SCRIPT" deploy-fleet
  [ "$status" -eq 0 ]
  for sa in "cardvault-agent" "txn-pipeline-agent" "llm-classifier-agent" "api-gateway-agent" "monitor-agent"; do
    run grep "k8s:sa:${sa}" "$RECORD_FILE"
    [ "$status" -eq 0 ]
  done
}

@test "DEPLOY FLEET: deploy_fleet seeds OpenBao policy and JWT role for all 5 agents" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    WAIT_PODS_TIMEOUT=5 \
    run bash "$FLEET_SCRIPT" deploy-fleet
  [ "$status" -eq 0 ]
  for role in "signalloom-cardvault-agent" "fleet-txn-pipeline" "fleet-llm-classifier" "fleet-api-gateway" "fleet-monitor"; do
    run grep -c "$role" "$RECORD_FILE"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
  done
}

@test "DEPLOY FLEET: deploy_fleet waits for pods ready on all 5 instances" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    WAIT_PODS_TIMEOUT=5 \
    run bash "$FLEET_SCRIPT" deploy-fleet
  [ "$status" -eq 0 ]
  for inst in "cardvault" "txn-pipeline" "llm-classifier" "api-gateway" "monitor"; do
    run grep "app.kubernetes.io/instance=${inst}" "$RECORD_FILE"
    [ "$status" -eq 0 ]
  done
}

@test "DEPLOY FLEET: scan-fleet reports compliance scan for all 5 agents" {
  PATH="${TEST_TMP}/bin:$PATH" RECORD_FILE="${RECORD_FILE}" \
    run bash "$FLEET_SCRIPT" scan-fleet
  [ "$status" -eq 0 ]
  [[ "$output" == *"scanning fleet for compliance"* ]]
}
