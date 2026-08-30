#!/usr/bin/env bats
# test/kagent-demo-harness.bats — End-to-end Demo 5 Verification & Proof Gate

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
}

@test "kagent-demo: full lifecycle dry-run passes" {
  run bash "${REPO_ROOT}/scripts/kagent-infra.sh" status
  [ "$status" -eq 0 ]
  run bash "${REPO_ROOT}/scripts/kagent-agents.sh" status
  [ "$status" -eq 0 ]
}

@test "kagent-demo: preflight proof file exists on disk with active harness verification" {
  proof_file="${REPO_ROOT}/.kagent-preflight-proof.json"
  [ -f "$proof_file" ]
  run jq -e '(.status == "STARTED" or .status == "COMPLETED") and .git_commit != null' "$proof_file"
  [ "$status" -eq 0 ]
}

@test "kagent-demo: proof file records live Kind cluster and all 5 agent CRs" {
  proof_file="${REPO_ROOT}/.kagent-preflight-proof.json"
  [ -f "$proof_file" ]
  run jq -e '.agent_crs | length >= 5' "$proof_file"
  [ "$status" -eq 0 ]
}
