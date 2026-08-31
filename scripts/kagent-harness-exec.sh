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
KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
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
PROOF_INPROGRESS="$(mktemp "${PROOF_FILE}.inprogress.XXXXXX")"
TEST_LOG=""

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  rm -f "${TEST_LOG}" "${PROOF_INPROGRESS}"
}
trap cleanup EXIT

echo "==> [Harness] Executing task '${TASK_ID}'..."

# Step 1: Collect cluster evidence. A failed query must not be silently
# represented as an empty result: an empty list and an unavailable API server
# make opposite claims about the cluster.
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(/usr/bin/git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
PROOF_ERRORS=()

if cluster_output="$("${KUBECTL}" cluster-info 2>&1)"; then
  CLUSTER_INFO="$(printf '%s\n' "${cluster_output}" | head -n 1)"
else
  CLUSTER_INFO="ERROR: kubectl cluster-info failed"
  PROOF_ERRORS+=("cluster-info")
  printf 'ERROR: kubectl cluster-info failed: %s\n' "${cluster_output}" >&2
fi

if pods_output="$("${KUBECTL}" get pods -n kagent --no-headers 2>&1)"; then
  if [ -n "${pods_output}" ]; then
    KAGENT_PODS="$(printf '%s\n' "${pods_output}" | awk '{print $1":"$3}' | paste -sd, -)"
  else
    KAGENT_PODS=""
  fi
else
  KAGENT_PODS="none"
  PROOF_ERRORS+=("kagent-pods")
  printf 'ERROR: kubectl get pods -n kagent failed: %s\n' "${pods_output}" >&2
fi

if agents_output="$("${KUBECTL}" get agents -n fe-signalloom-agents --no-headers 2>&1)"; then
  if [ -n "${agents_output}" ]; then
    AGENT_CRS="$(printf '%s\n' "${agents_output}" | awk '{print $1}' | paste -sd, -)"
  else
    AGENT_CRS=""
  fi
else
  AGENT_CRS="none"
  PROOF_ERRORS+=("agent-crs")
  printf 'ERROR: kubectl get agents -n fe-signalloom-agents failed: %s\n' "${agents_output}" >&2
fi

# Step 2: Write structured proof JSON immediately
proof_errors="$(IFS=,; printf '%s' "${PROOF_ERRORS[*]}")"
python3 - "$TASK_ID" "$TIMESTAMP" "$GIT_SHA" "$CLUSTER_INFO" "$KAGENT_PODS" "$AGENT_CRS" "$proof_errors" "$PROOF_FILE" "$PROOF_INPROGRESS" <<'PY'
import json
import sys

task_id, timestamp, git_sha, cluster_info, kagent_pods, agent_crs, proof_errors, proof_file, inprogress = sys.argv[1:]
proof = {
    "task_id": task_id,
    "timestamp": timestamp,
    "git_commit": git_sha,
    "cluster_info": cluster_info.strip(),
    "kagent_pods": kagent_pods.split(",") if kagent_pods else [],
    "agent_crs": agent_crs.split(",") if agent_crs else [],
    "proof_errors": proof_errors.split(",") if proof_errors else [],
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

# kagent-test.sh emits exactly one complete, machine-readable tally. A
# successful runner without that measurement is not a successful proof run.
mapfile -t TALLY_LINES < <(grep -xE 'KAGENT_TALLY passed=[0-9]+ failed=[0-9]+ skipped=[0-9]+' "${TEST_LOG}" || true)
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
if [ "${#TALLY_LINES[@]}" -eq 1 ] &&
   [[ "${TALLY_LINES[0]}" =~ ^KAGENT_TALLY\ passed=([0-9]+)\ failed=([0-9]+)\ skipped=([0-9]+)$ ]]; then
  PASSED_COUNT="${BASH_REMATCH[1]}"
  FAILED_COUNT="${BASH_REMATCH[2]}"
  SKIPPED_COUNT="${BASH_REMATCH[3]}"
else
  PROOF_ERRORS+=("invalid-tally")
  printf 'ERROR: expected exactly one complete KAGENT_TALLY line\n' >&2
  TEST_STATUS=1
fi

if [ "${#PROOF_ERRORS[@]}" -gt 0 ]; then
  TEST_STATUS=1
fi
if [ "${TEST_STATUS}" -eq 0 ] && [ "${FAILED_COUNT}" -gt 0 ]; then
  TEST_STATUS=1
fi
proof_errors="$(IFS=,; printf '%s' "${PROOF_ERRORS[*]}")"

# Step 4: Finalize proof file with execution results
#
# `test_assertions_passed` was previously the literal 23 — a number written by
# hand, unconnected to any run, and never equal to the number of tests in the
# repo. It was then read back by test/kagent-demo-harness.bats and quoted as
# evidence. It is now whatever the runner actually counted.
python3 - "$PROOF_INPROGRESS" "$TEST_STATUS" "$PASSED_COUNT" "$FAILED_COUNT" "$SKIPPED_COUNT" "$proof_errors" "$PROOF_FILE" <<'PY'
import json
import os
import sys

inprogress, test_status, passed, failed, skipped, proof_errors, proof_file = sys.argv[1:]
with open(inprogress) as handle:
    proof = json.load(handle)
proof["status"] = "COMPLETED" if test_status == "0" else "FAILED"
proof["test_status"] = "PASS" if test_status == "0" else "FAIL"
proof["test_assertions_passed"] = int(passed)
proof["test_assertions_failed"] = int(failed)
proof["test_assertions_skipped"] = int(skipped)
proof["proof_errors"] = proof_errors.split(",") if proof_errors else []
with open(inprogress, "w") as handle:
    json.dump(proof, handle, indent=2)
# os.replace is atomic within a filesystem: no reader ever sees a partial file.
os.replace(inprogress, proof_file)
print("✓ Proof file published at: " + proof_file)
PY

echo "==> [Harness] Task '${TASK_ID}' completed with status: $([ "$TEST_STATUS" -eq 0 ] && echo 'SUCCESS' || echo 'FAILURE')"
cat "${PROOF_FILE}"
exit "${TEST_STATUS}"
