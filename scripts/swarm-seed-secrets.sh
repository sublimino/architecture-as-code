#!/usr/bin/env bash
# shellcheck shell=bash
#
# swarm-seed-secrets.sh — Seed demo secrets into OpenBao for the agent swarm.
#
# Each agent's secrets are stored at a path scoped by its SPIFFE ID so the
# templated policy (signalloom-agent-templated) grants access only to the
# agent's own secrets:
#
#   secret/data/agents/spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/<sa>/<key>
#
# Usage:
#   scripts/swarm-seed-secrets.sh                     # from repo root
#   BAO_ADDR=http://localhost:8200 scripts/swarm-seed-secrets.sh  # custom addr
#
# Idempotent — safe to re-run. Seeds DEMO values only, not real API keys.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh" 2>/dev/null || true

BAO_ADDR="${BAO_ADDR:-http://openbao.inf-bao.svc.cluster.local:8200}"
BAO_TOKEN="${BAO_TOKEN:-signalloom-demo-root-token}"
export BAO_ADDR BAO_TOKEN

TRUST_DOMAIN="signalloom.demo"
NAMESPACE="fe-signalloom-agents"
SPIFFE_PREFIX="spiffe://${TRUST_DOMAIN}/ns/${NAMESPACE}/sa"

log() { printf '  [swarm-seed] %s\n' "$*"; }
ok()  { printf '  [swarm-seed] \033[32m✓\033[0m %s\n' "$*"; }
err() { printf '  [swarm-seed] \033[31m✗\033[0m %s\n' "$*" >&2; }

# ─── Enable KV v2 if not already ─────────────────────────────────────────────

enable_kv_v2() {
  if bao secrets list -format=json 2>/dev/null | grep -q '"secret/"'; then
    log "KV v2 already enabled at secret/"
  else
    log "enabling KV v2 at secret/"
    bao secrets enable -path=secret kv-v2 || true
  fi
}

# ─── Seed one secret ─────────────────────────────────────────────────────────

seed_secret() {
  local sa="$1" path="$2" value="$3"
  local full_path="secret/data/agents/${SPIFFE_PREFIX}/${sa}/${path}"

  log "seeding ${sa}/${path}"
  bao kv put "secret/agents/${SPIFFE_PREFIX}/${sa}/${path}" value="$value" >/dev/null 2>&1 \
    && ok "${sa}/${path}" \
    || err "${sa}/${path} — write failed"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  log "seeding demo secrets for the agent swarm"
  log "BAO_ADDR=$BAO_ADDR"
  log "trust domain: $TRUST_DOMAIN"
  log "namespace: $NAMESPACE"
  echo

  enable_kv_v2

  # prompt-commit-summarizer — LLM API key (Gemini/LiteLLM)
  seed_secret "prompt-commit-summarizer" "llm/api-key" \
    "demo-llm-api-key-$(date +%s)-not-real"

  # triage-ci-worker — GitHub token
  seed_secret "triage-ci-worker" "github/token" \
    "ghp_demo000000000000000000000000000000000"

  # zulip-chat-agent — Zulip API key
  seed_secret "zulip-chat-agent" "zulip/api-key" \
    "demo-zulip-api-key-not-real-000000000000"

  # cpai-engineer — Anthropic API key
  seed_secret "cpai-engineer" "anthropic/api-key" \
    "sk-ant-demo-000000000000000000000000000000"

  # prod-deploy-gate — HMAC secret
  seed_secret "prod-deploy-gate" "gate/hmac-secret" \
    "demo-hmac-secret-$(date +%s)-not-real"

  # swarm-governor — Anthropic API key (same provider, different identity)
  seed_secret "swarm-governor" "anthropic/api-key" \
    "sk-ant-demo-governor-0000000000000000000"

  echo
  ok "all demo secrets seeded"
}

main "$@"
