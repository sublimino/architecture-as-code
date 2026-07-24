#!/usr/bin/env bash
# Run a promptfoo red-team pass against the live Olly agent through the console
# broker's Security Sandbox probe, then leave the results in the web UI (:3000).
#
#   ./redteam.sh baseline   # LLM Guard OFF  (attack-success baseline)
#   ./redteam.sh guarded    # LLM Guard ON   (defended)
#
# Prereqs: the console broker is up (make console), the LLM Guard pod is running
# for the guarded pass, and .env has an LLM provider key (OpenRouter/OpenAI/
# Anthropic) for attack generation and grading.
set -euo pipefail

MODE="${1:-baseline}"
case "${MODE}" in
  baseline) CONFIG="olly-redteam.baseline.yaml" ;;
  guarded)  CONFIG="olly-redteam.guarded.yaml" ;;
  *) echo "usage: $0 [baseline|guarded]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")"
[ -f .env ] && export $(grep -v '^#' .env | xargs) || true

echo "starting promptfoo (web UI on http://localhost:3000)"
docker compose up -d

echo "running red-team: ${CONFIG} (guard ${MODE})"
docker compose exec -T promptfoo \
  promptfoo redteam run --config "/app/config/${CONFIG}" --no-cache

echo
echo "done. Open the report at http://localhost:3000 and compare baseline vs guarded."
