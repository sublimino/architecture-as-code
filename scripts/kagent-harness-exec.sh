#!/usr/bin/env bash
# scripts/kagent-harness-exec.sh — Deterministic Harness Execution & Proof Dropper
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Was hardcoded to /home/andy/src/cp/osramp-demo/scripts/bin, which made any run
# from a git worktree silently use another checkout's helper binaries.
export PATH="${REPO_ROOT}/scripts/bin:${PATH}"
KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
if [ -f "${KUBECONFIG_PATH}" ]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

TASK_ID="${1:-P0}"
PROOF_FILE="${REPO_ROOT}/.kagent-preflight-proof.json"

echo "==> [Harness] Executing task '${TASK_ID}'..."

# Step 1: Immediately drop heartbeat / evidence file on disk
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(/usr/bin/git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
CLUSTER_INFO="$(/usr/local/bin/kubectl cluster-info 2>&1 | head -n 1 || echo "Cluster unreachable")"
KAGENT_PODS="$(/usr/local/bin/kubectl get pods -n kagent --no-headers 2>/dev/null | awk '{print $1":"$3}' | paste -sd, - || echo "none")"
AGENT_CRS="$(/usr/local/bin/kubectl get agents -n fe-signalloom-agents --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, - || echo "none")"

# Step 2: Write structured proof JSON immediately
python3 -c "
import json
proof = {
    'task_id': '${TASK_ID}',
    'timestamp': '${TIMESTAMP}',
    'git_commit': '${GIT_SHA}',
    'cluster_info': '''${CLUSTER_INFO}'''.strip(),
    'kagent_pods': '${KAGENT_PODS}'.split(',') if '${KAGENT_PODS}' != 'none' else [],
    'agent_crs': '${AGENT_CRS}'.split(',') if '${AGENT_CRS}' != 'none' else [],
    'status': 'STARTED',
    'proof_path': '${PROOF_FILE}'
}
with open('${PROOF_FILE}', 'w') as f:
    json.dump(proof, f, indent=2)
"

# Step 3: Run verification test suite, capturing its output so the tally in the
# proof artefact is a measurement rather than an assertion of faith.
TEST_LOG="$(mktemp)"
TEST_STATUS=0
# errexit + pipefail would abort the harness the moment a suite fails, skipping
# step 4 and leaving the proof artefact frozen at 'STARTED' — i.e. a failing run
# would leave behind the *previous* run's verdict. Disable both across the call.
set +e +o pipefail
"${REPO_ROOT}/scripts/kagent-test.sh" 2>&1 | tee "${TEST_LOG}"
TEST_STATUS="${PIPESTATUS[0]}"
set -e -o pipefail

# kagent-test.sh emits: KAGENT_TALLY passed=N failed=M
TALLY_LINE="$(grep '^KAGENT_TALLY ' "${TEST_LOG}" | tail -1 || true)"
PASSED_COUNT="$(printf '%s' "${TALLY_LINE}" | sed -n 's/.*passed=\([0-9][0-9]*\).*/\1/p')"
FAILED_COUNT="$(printf '%s' "${TALLY_LINE}" | sed -n 's/.*failed=\([0-9][0-9]*\).*/\1/p')"
rm -f "${TEST_LOG}"

# An absent tally means the runner did not get far enough to count anything.
# Recording 0 is honest; inventing a number is what this replaced.
PASSED_COUNT="${PASSED_COUNT:-0}"
FAILED_COUNT="${FAILED_COUNT:-0}"

# Step 4: Finalize proof file with execution results
#
# `test_assertions_passed` was previously the literal 23 — a number written by
# hand, unconnected to any run, and never equal to the number of tests in the
# repo. It was then read back by test/kagent-demo-harness.bats and quoted as
# evidence. It is now whatever the runner actually counted.
python3 -c "
import json
with open('${PROOF_FILE}') as f:
    proof = json.load(f)
proof['status'] = 'COMPLETED' if ${TEST_STATUS} == 0 else 'FAILED'
proof['test_status'] = 'PASS' if ${TEST_STATUS} == 0 else 'FAIL'
proof['test_assertions_passed'] = ${PASSED_COUNT}
proof['test_assertions_failed'] = ${FAILED_COUNT}
with open('${PROOF_FILE}', 'w') as f:
    json.dump(proof, f, indent=2)
print('✓ Proof file written at: ' + '${PROOF_FILE}')
"

echo "==> [Harness] Task '${TASK_ID}' completed with status: $([ $TEST_STATUS -eq 0 ] && echo 'SUCCESS' || echo 'FAILURE')"
cat "${PROOF_FILE}"
