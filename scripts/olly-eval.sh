#!/usr/bin/env bash
# Run the Olly Sentinel eval suite: the deterministic RCA signal-check gate
# (the real CI gate) plus the ADK AgentEvaluator rca_readiness eval (the
# surface that also populates the `adk web` Eval tab and the run history).
# Offline and reproducible — the eval starts a hermetic evidence stub, so no
# cluster or model credentials are needed for the baseline.
#
# Uses a local venv under apps/sentinel/.venv (the demo's pattern). First run
# installs google-adk[a2a,eval]; later runs are fast.
set -euo pipefail

cd "$(dirname "$0")/../olly-replica/apps/sentinel"

VENV=.venv
if [ ! -d "${VENV}" ]; then
  echo "creating ${VENV} (first run installs google-adk[a2a,eval] — this is slow once)"
  python3 -m venv "${VENV}"
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
pip install -q --upgrade pip
pip install -q -r requirements.txt

export CONTRACTS_DIR="$(cd ../../contracts && pwd)"
export EVAL_RUN_ID="${EVAL_RUN_ID:-local-$(date +%s)}"
echo "CONTRACTS_DIR=${CONTRACTS_DIR}  EVAL_RUN_ID=${EVAL_RUN_ID}"

echo
echo "== 1/2 deterministic RCA signal-check gate (the real gate) =="
python -m pytest tests/test_rca_signals.py -v

echo
echo "== 2/2 ADK AgentEvaluator: rca_readiness (adk web Eval-tab surface) =="
python -m pytest olly_sentinel/eval_test.py -v

echo
echo "eval complete: EVAL_RUN_ID=${EVAL_RUN_ID}"
echo "run history: olly-replica/apps/sentinel/olly_sentinel/.adk/eval_history/"
