#!/usr/bin/env bash
# Launch Google ADK's `adk web` against the Olly Sentinel package so the agent
# appears in the dropdown with the Trace and Eval tabs — the ADK Studio view
# the demo GUI embeds. By default it serves the hermetic evidence stub so the
# seeded incidents are drivable offline; set MCP_URL to a port-forwarded
# elk-search-mcp to drive the real cluster instead:
#   kubectl -n olly-replica port-forward svc/elk-search-mcp 8099:8080
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
: "${MCP_URL:=http://127.0.0.1:8099}"
export MCP_URL
ADK_PORT="${ADK_PORT:-8000}"

STUB_PID=""
if [ "${MCP_URL}" = "http://127.0.0.1:8099" ]; then
  echo "starting hermetic evidence stub on 127.0.0.1:8099"
  ELK_STUB_PORT=8099 python tests/elk_stub.py &
  STUB_PID=$!
  trap '[ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null || true' EXIT
  sleep 1
fi

echo "adk web on http://127.0.0.1:${ADK_PORT}  (agent: olly_sentinel, evidence: ${MCP_URL})"
echo "paste a triage request in the chat, e.g.  {\"correlation_id\":\"corr-1\",\"app_id\":\"inventory-service\"}"
adk web --port "${ADK_PORT}"
