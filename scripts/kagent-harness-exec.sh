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
# The heartbeat is written here, NOT to PROOF_FILE, and PROOF_FILE is replaced
# atomically only once the counts are known.
#
# Previously the artefact was truncated to a countless heartbeat at step 2 and
# only completed at step 4, so for the whole duration of a run the published
# artefact had no test_assertions_passed. The suite that validates it runs
# INSIDE that window, read the absent count as the -1 default, and failed every
# single time with "claims -1 passes" — a test that could never pass during the
# only process that generates its input. Publishing atomically means the
# published artefact is always complete: during a run it is the previous one,
# which is a true statement about a real earlier run rather than a half-written
# one about this run.
PROOF_INPROGRESS="${PROOF_FILE}.inprogress"

echo "==> [Harness] Executing task '${TASK_ID}'..."

# Step 1: Immediately drop heartbeat / evidence file on disk
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(/usr/bin/git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
CLUSTER_INFO="$(/usr/local/bin/kubectl cluster-info 2>&1 | head -n 1 || echo "Cluster unreachable")"
KAGENT_PODS="$(/usr/local/bin/kubectl get pods -n kagent --no-headers 2>/dev/null | awk '{print $1":"$3}' | paste -sd, - || echo "none")"
AGENT_CRS="$(/usr/local/bin/kubectl get agents -n fe-signalloom-agents --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, - || echo "none")"

# Step 2: Write structured proof JSON immediately
python3 - "$TASK_ID" "$TIMESTAMP" "$GIT_SHA" "$CLUSTER_INFO" "$KAGENT_PODS" "$AGENT_CRS" "$PROOF_FILE" "$PROOF_INPROGRESS" <<'PY'
import json
import sys

task_id, timestamp, git_sha, cluster_info, kagent_pods, agent_crs, proof_file, inprogress = sys.argv[1:]
proof = {
    "task_id": task_id,
    "timestamp": timestamp,
    "git_commit": git_sha,
    "cluster_info": cluster_info.strip(),
    "kagent_pods": kagent_pods.split(",") if kagent_pods != "none" else [],
    "agent_crs": agent_crs.split(",") if agent_crs != "none" else [],
    "status": "STARTED",
    "proof_path": proof_file,
}
with open(inprogress, "w") as handle:
    json.dump(proof, handle, indent=2)
PY

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
SKIPPED_COUNT="$(printf '%s' "${TALLY_LINE}" | sed -n 's/.*skipped=\([0-9][0-9]*\).*/\1/p')"
rm -f "${TEST_LOG}"

# An absent tally means the runner did not get far enough to count anything.
# Recording 0 is honest; inventing a number is what this replaced.
PASSED_COUNT="${PASSED_COUNT:-0}"
FAILED_COUNT="${FAILED_COUNT:-0}"
SKIPPED_COUNT="${SKIPPED_COUNT:-0}"

# Step 4: Finalize proof file with execution results
#
# `test_assertions_passed` was previously the literal 23 — a number written by
# hand, unconnected to any run, and never equal to the number of tests in the
# repo. It was then read back by test/kagent-demo-harness.bats and quoted as
# evidence. It is now whatever the runner actually counted.
python3 - "$PROOF_INPROGRESS" "$TEST_STATUS" "$PASSED_COUNT" "$FAILED_COUNT" "$SKIPPED_COUNT" "$PROOF_FILE" <<'PY'
import json
import os
import sys

inprogress, test_status, passed, failed, skipped, proof_file = sys.argv[1:]
with open(inprogress) as handle:
    proof = json.load(handle)
proof["status"] = "COMPLETED" if test_status == "0" else "FAILED"
proof["test_status"] = "PASS" if test_status == "0" else "FAIL"
proof["test_assertions_passed"] = int(passed)
proof["test_assertions_failed"] = int(failed)
proof["test_assertions_skipped"] = int(skipped)
with open(inprogress, "w") as handle:
    json.dump(proof, handle, indent=2)
# os.replace is atomic within a filesystem: no reader ever sees a partial file.
os.replace(inprogress, proof_file)
print("✓ Proof file published at: " + proof_file)
PY

echo "==> [Harness] Task '${TASK_ID}' completed with status: $([ "$TEST_STATUS" -eq 0 ] && echo 'SUCCESS' || echo 'FAILURE')"
cat "${PROOF_FILE}"
