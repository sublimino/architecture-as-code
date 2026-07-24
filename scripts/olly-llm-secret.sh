#!/usr/bin/env bash
# Create the `olly-llm` secret in the olly-replica namespace from a local .env
# file, so the Olly Sentinel narrator calls a real LLM (OpenRouter, Anthropic,
# OpenAI, or a local Ollama gateway) instead of the deterministic fallback.
# Best-effort and idempotent: with no .env (or LLM_PROVIDER unset) it prints a
# note and exits 0, so `make up` stays green whether or not an LLM is wired.
#
# The pipeline stays deterministic (invariant 8: the model narrates, it never
# decides); this only swaps the RCA narrative for a model-generated one. The
# .env file is gitignored; keys never get committed.
set -uo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ -z "${LLM_PROVIDER:-}" ]; then
  echo "no LLM_PROVIDER in .env; the sentinel uses its deterministic RCA."
  echo "  to wire an LLM: set LLM_PROVIDER (openrouter|anthropic|openai|ollama),"
  echo "  LLM_MODEL, and LLM_API_KEY in .env, then rerun 'make olly-llm-secret'."
  exit 0
fi

# Cloud providers need a key; a local Ollama gateway does not.
case "${LLM_PROVIDER}" in
  openrouter|anthropic|openai)
    if [ -z "${LLM_API_KEY:-}" ]; then
      echo "LLM_PROVIDER=${LLM_PROVIDER} needs LLM_API_KEY in .env; staying deterministic."
      exit 0
    fi
    ;;
esac

echo "waiting for the olly-replica namespace..."
for _ in $(seq 1 60); do
  kubectl get ns olly-replica >/dev/null 2>&1 && break
  sleep 5
done
if ! kubectl get ns olly-replica >/dev/null 2>&1; then
  echo "olly-replica namespace never appeared; is the cluster up and reconciled?" >&2
  exit 1
fi

echo "creating the olly-llm secret (provider=${LLM_PROVIDER} model=${LLM_MODEL:-<default>})"
kubectl -n olly-replica create secret generic olly-llm \
  --from-literal=LLM_PROVIDER="${LLM_PROVIDER}" \
  --from-literal=LLM_MODEL="${LLM_MODEL:-}" \
  --from-literal=LLM_API_KEY="${LLM_API_KEY:-}" \
  --from-literal=LLM_URL="${LLM_URL:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n olly-replica get deploy olly-sentinel >/dev/null 2>&1; then
  echo "restarting olly-sentinel to pick up the LLM configuration"
  kubectl -n olly-replica rollout restart deploy/olly-sentinel
fi

echo "done: the sentinel's RCA narrative now comes from ${LLM_PROVIDER}."
