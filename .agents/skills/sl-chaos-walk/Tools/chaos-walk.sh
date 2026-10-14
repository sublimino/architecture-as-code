#!/usr/bin/env bash
#
# chaos-walk.sh — Unified CLI runner for sl-chaos-walk (Signal Loom exploratory QA & chaos walk)
# Constructed under Matt Pocock skill discipline with tight feedback loops and bounded execution.
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
JEV_DIR="${REPO_ROOT}/scripts/jev-test-bot"

# Default configuration
PROFILE="quick-walk"
TARGET_URL="${CHAOS_WALK_URL:-https://ftna-signalloom.taild4da3.ts.net/}"
AREA=""
TURNS=""
REQUESTS="300"
CONCURRENCY="6"
MOCK_MODE=0
STOP_ON_ERROR=0
OUT_DIR="${REPO_ROOT}/reports/chaos-walk"

USE_LOCAL=0
MOCK_EXPLICIT=0

usage() {
  cat <<USAGE
Usage: chaos-walk.sh [options]

Operational Profiles:
  --profile quick-walk     Fast route sanity check (5-10 turns, <= 30s) [default]
  --profile deep-chaos     Multi-turn exploratory chaos with click storm & jitter
  --profile api-storm      High-concurrency stochastic REST API payload fuzzing

Options:
  --url URL                Target base URL (default: https://ftna-signalloom.taild4da3.ts.net/)
  --local                  Target local cluster endpoint (checks 5173 then 19080)
  --area PATH              Route/area prefix to scope the walk (e.g. /policies, /agents)
  --turns N                Max interaction turns (defaults: quick-walk=5, deep-chaos=25)
  --requests N             Number of requests for api-storm (default: 300)
  --concurrency N          Concurrency level for api-storm (default: 6)
  --mock                   Force offline calibrated simulation mode (default when offline)
  --stop-on-error          Halt walk immediately on first detected oracle failure
  --out-dir PATH           Report output directory (default: reports/chaos-walk)
  -h, --help               Show this help message
USAGE
  exit 0
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --url)
      TARGET_URL="$2"
      shift 2
      ;;
    --local)
      USE_LOCAL=1
      shift
      ;;
    --area)
      AREA="$2"
      shift 2
      ;;
    --turns)
      TURNS="$2"
      shift 2
      ;;
    --requests)
      REQUESTS="$2"
      shift 2
      ;;
    --concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    --mock)
      MOCK_MODE=1
      MOCK_EXPLICIT=1
      shift
      ;;
    --stop-on-error)
      STOP_ON_ERROR=1
      shift
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# If --local requested, auto-detect active local port
if [[ "${USE_LOCAL}" -eq 1 ]]; then
  if curl -sf --max-time 1 "http://127.0.0.1:5173/" >/dev/null 2>&1; then
    TARGET_URL="http://127.0.0.1:5173/"
  elif curl -sf --max-time 1 "http://127.0.0.1:19080/" >/dev/null 2>&1; then
    TARGET_URL="http://127.0.0.1:19080/"
  else
    echo "Warning: Local endpoints (5173/19080) not responding, using http://127.0.0.1:5173/" >&2
    TARGET_URL="http://127.0.0.1:5173/"
  fi
fi

# Resolve TypeSafe / Jev API key if not already set in environment
if [[ -z "${TYPESAFE_API_KEY:-}" && -z "${JEV_API_KEY:-}" ]]; then
  RESOLVED_KEY="$(python3 -c 'import sys; sys.path.insert(0, "'"${JEV_DIR}"'"); from bot import get_jev_api_key; k = get_jev_api_key(); print(k or "")' 2>/dev/null || true)"
  if [[ -n "${RESOLVED_KEY}" ]]; then
    export JEV_API_KEY="${RESOLVED_KEY}"
    export TYPESAFE_API_KEY="${RESOLVED_KEY}"
  fi
fi

# Check for TypeSafe API key or auto-activate mock if unavailable
if [[ -z "${TYPESAFE_API_KEY:-}" && -z "${JEV_API_KEY:-}" ]]; then
  MOCK_MODE=1
fi

if [[ "${MOCK_MODE}" -eq 1 ]]; then
  DECISION_ENGINE="Calibrated System One Simulator (mock/offline)"
else
  DECISION_ENGINE="Live TypeSafe Jev API (${TYPESAFE_MODEL:-jev-latest})"
fi

mkdir -p "${OUT_DIR}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_REPORT="${OUT_DIR}/${TIMESTAMP}_${PROFILE}.md"

echo "=================================================================="
echo "sl-chaos-walk: Matt Pocock Exploratory Chaos Fuzzer"
echo "  Profile:         ${PROFILE}"
echo "  Target URL:      ${TARGET_URL}"
echo "  Scope Area:      ${AREA:-<all routes>}"
echo "  Decision Engine: ${DECISION_ENGINE}"
echo "  Report:          ${RUN_REPORT}"
echo "=================================================================="

case "${PROFILE}" in
  quick-walk)
    EFFECTIVE_TURNS="${TURNS:-5}"
    echo "==> Running quick-walk (${EFFECTIVE_TURNS} turns)..."
    CMD=(python3 "${JEV_DIR}/bot.py" --url "${TARGET_URL}" --max-turns "${EFFECTIVE_TURNS}")
    if [[ -n "${AREA}" ]]; then
      CMD+=(--area "${AREA}")
    fi
    if [[ "${MOCK_MODE}" -eq 1 ]]; then
      CMD+=(--mock)
    fi
    if [[ "${STOP_ON_ERROR}" -eq 1 ]]; then
      CMD+=(--stop-on-error)
    fi
    "${CMD[@]}" | tee "${RUN_REPORT}"
    ;;

  deep-chaos)
    EFFECTIVE_TURNS="${TURNS:-25}"
    echo "==> Running deep-chaos exploratory walk (${EFFECTIVE_TURNS} turns)..."
    export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${REPO_ROOT}/.cache/ms-playwright}"

    ROUTES_TMP="$(mktemp "${TMPDIR:-/tmp}/chaos_routes_XXXXXX.txt")"
    trap 'rm -f "${ROUTES_TMP}"' EXIT
    if [[ -n "${AREA}" ]]; then
      python3 "${JEV_DIR}/routes.py" 2>/dev/null | grep -E "^${AREA}" > "${ROUTES_TMP}" || true
      if [[ ! -s "${ROUTES_TMP}" ]]; then
        echo "${AREA}" > "${ROUTES_TMP}"
      fi
    else
      python3 "${JEV_DIR}/routes.py" 2>/dev/null > "${ROUTES_TMP}" || true
      if [[ ! -s "${ROUTES_TMP}" ]]; then
        echo "/" > "${ROUTES_TMP}"
      fi
    fi

    CMD=(node "${JEV_DIR}/browser_driver.mjs" --base "${TARGET_URL}" --routes "${ROUTES_TMP}" --turns "${EFFECTIVE_TURNS}" --out-dir "${OUT_DIR}")
    if [[ "${MOCK_MODE}" -eq 1 ]]; then
      CMD+=(--mock)
    else
      CMD+=(--decider python)
    fi
    if [[ "${STOP_ON_ERROR}" -eq 1 ]]; then
      CMD+=(--stop-on-error)
    fi
    "${CMD[@]}" | tee "${RUN_REPORT}"
    ;;

  api-storm)
    echo "==> Running api-storm REST endpoint fuzzing (${REQUESTS} requests, concurrency ${CONCURRENCY})..."
    CMD=(python3 "${JEV_DIR}/fuzz_api.py" --url "${TARGET_URL}" --requests "${REQUESTS}" --concurrency "${CONCURRENCY}" --seed 4242)
    "${CMD[@]}" | tee "${RUN_REPORT}"
    ;;

  *)
    echo "ERROR: Unsupported profile '${PROFILE}'. Use quick-walk, deep-chaos, or api-storm." >&2
    exit 1
    ;;
esac

echo ""
echo "✓ Chaos walk completed. Report saved to: ${RUN_REPORT}"
