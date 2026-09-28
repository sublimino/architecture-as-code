#!/usr/bin/env bash
# ==============================================================================
# Signal Loom - 10-Run Onboarding Verification & Stability Harness
# ==============================================================================
# Executes N iterations of the full onboarding lifecycle against live sovereign
# infrastructure, tracking latency, database consistency, and audit integrity.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONBOARD_SCRIPT="${SCRIPT_DIR}/onboard-test-agent.sh"

TOTAL_ITERATIONS="${1:-10}"
LOG_FILE="/tmp/signalloom-onboarding-10x.log"
RESULTS_FILE="/tmp/signalloom-onboarding-10x.json"

echo "======================================================================"
echo " Starting Signal Loom Onboarding 10-Iteration Verification Harness"
echo " Iterations: ${TOTAL_ITERATIONS}"
echo " Timestamp:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " Log file:   ${LOG_FILE}"
echo "======================================================================"

> "${LOG_FILE}"

SUCCESS_COUNT=0
FAILURE_COUNT=0
TOTAL_DURATION=0
RESULTS=()

for i in $(seq 1 "${TOTAL_ITERATIONS}"); do
  ITER_START="$(date +%s%N)"
  ITER_AGENT="agent-iter-${i}-$(date +%s | tail -c 5)"
  ITER_HOST="host-iter-${i}-$(date +%s | tail -c 5)"

  echo -n "[Iteration ${i}/${TOTAL_ITERATIONS}] Testing '${ITER_AGENT}'... "

  set +e
  OUTPUT="$("${ONBOARD_SCRIPT}" "${ITER_AGENT}" "${ITER_HOST}" 2>&1)"
  EXIT_CODE=$?
  set -e

  ITER_END="$(date +%s%N)"
  DURATION_MS=$(( (ITER_END - ITER_START) / 1000000 ))
  TOTAL_DURATION=$(( TOTAL_DURATION + DURATION_MS ))

  echo "${OUTPUT}" >> "${LOG_FILE}"
  echo "--------------------------------------------------" >> "${LOG_FILE}"

  if [[ ${EXIT_CODE} -eq 0 ]]; then
    SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
    echo "PASS (${DURATION_MS}ms)"
    RESULTS+=("{\"iteration\": ${i}, \"agent_id\": \"${ITER_AGENT}\", \"status\": \"PASS\", \"latency_ms\": ${DURATION_MS}}")
  else
    FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
    echo "FAIL (${DURATION_MS}ms) - Exit ${EXIT_CODE}"
    RESULTS+=("{\"iteration\": ${i}, \"agent_id\": \"${ITER_AGENT}\", \"status\": \"FAIL\", \"latency_ms\": ${DURATION_MS}}")
  fi

  # Gentle breathing room between iterations
  sleep 1
done

AVG_LATENCY=0
if [[ ${TOTAL_ITERATIONS} -gt 0 ]]; then
  AVG_LATENCY=$(( TOTAL_DURATION / TOTAL_ITERATIONS ))
fi

echo "======================================================================"
echo " 10-Iteration Verification Summary"
echo " Total:        ${TOTAL_ITERATIONS}"
echo " Succeeded:    ${SUCCESS_COUNT}"
echo " Failed:       ${FAILURE_COUNT}"
echo " Avg Latency:  ${AVG_LATENCY} ms"
echo " Success Rate: $(( (SUCCESS_COUNT * 100) / TOTAL_ITERATIONS ))%"
echo "======================================================================"

# Write JSON output
printf '[\n  %s\n]\n' "$(IFS=,; echo "${RESULTS[*]}")" > "${RESULTS_FILE}"

if [[ ${FAILURE_COUNT} -gt 0 ]]; then
  echo "❌ Verification loop encountered failures. Inspect ${LOG_FILE}"
  exit 1
else
  echo "✅ All ${TOTAL_ITERATIONS} onboarding iterations passed with 100% reliability!"
  exit 0
fi
