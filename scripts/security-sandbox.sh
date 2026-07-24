#!/bin/sh
# Apply the Security Sandbox toggle from .env (SECURITY_SANDBOX_ENABLED).
#
# One knob for both layers:
#   LLM Guard  - the in-cluster scanner pod + the sentinel's Olly -> Orbit hop.
#   promptfoo  - the red-team UI (docker compose on :3000).
#
# Best-effort and idempotent: with no .env, or the flag false, it makes sure the
# sandbox is OFF (guard scaled to 0, hop disabled, promptfoo stopped). `make up`
# runs this at the end, so a filled-in .env is all it takes. Nothing here is a
# hard dependency of the demo; the sandbox is additive.
NS=olly-replica
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="${ROOT}/olly-replica/apps/security-sandbox"

enabled=false
if [ -f "${ROOT}/.env" ]; then
  # shellcheck disable=SC1091
  . "${ROOT}/.env"
fi
case "$(printf '%s' "${SECURITY_SANDBOX_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
  1 | true | yes | on) enabled=true ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

if [ "${enabled}" = "true" ]; then
  echo "security sandbox: ENABLING (SECURITY_SANDBOX_ENABLED=${SECURITY_SANDBOX_ENABLED})"
  echo "  note: the LLM Guard pod loads ~2-3GB of models; give the node RAM headroom."
  if have kubectl; then
    if kubectl -n "${NS}" get deploy llm-guard >/dev/null 2>&1; then
      kubectl -n "${NS}" scale deploy llm-guard --replicas=1 >/dev/null 2>&1 \
        && echo "  llm-guard pod: scaled to 1 (models load on first scan)" \
        || echo "  llm-guard pod: scale failed"
    else
      echo "  llm-guard deploy not found; apply components/configs/base/llm-guard.yaml or 'make push-local' first."
    fi
    if kubectl -n "${NS}" get deploy olly-sentinel >/dev/null 2>&1; then
      kubectl -n "${NS}" set env deploy/olly-sentinel LLM_GUARD_ENABLED=true >/dev/null 2>&1 \
        && echo "  sentinel hop: LLM_GUARD_ENABLED=true (sentinel restarts)" \
        || echo "  sentinel hop: set env failed"
    fi
  else
    echo "  kubectl not found; skipping the in-cluster guard toggle."
  fi
  if have docker; then
    ( cd "${SANDBOX}" && docker compose up -d >/dev/null 2>&1 ) \
      && echo "  promptfoo: up at http://localhost:3000 (run ./redteam.sh baseline|guarded)" \
      || echo "  promptfoo: docker compose up failed (is Docker running?)"
  else
    echo "  docker not found; start promptfoo later with 'make -C olly-replica security-sandbox-up'."
  fi
  echo "security sandbox: enabled."
else
  echo "security sandbox: OFF (SECURITY_SANDBOX_ENABLED=${SECURITY_SANDBOX_ENABLED:-unset}); keeping it dormant."
  # Scaling to 0 is a no-op when already 0, so it never disturbs a running pod.
  if have kubectl && kubectl -n "${NS}" get deploy llm-guard >/dev/null 2>&1; then
    kubectl -n "${NS}" scale deploy llm-guard --replicas=0 >/dev/null 2>&1 && echo "  llm-guard pod: scaled to 0"
  fi
  # Only touch the sentinel if the hop is actually on, so a routine off-run does
  # not restart a healthy sentinel (it already defaults to off).
  if have kubectl && kubectl -n "${NS}" get deploy olly-sentinel >/dev/null 2>&1; then
    cur=$(kubectl -n "${NS}" get deploy olly-sentinel \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LLM_GUARD_ENABLED")].value}' 2>/dev/null)
    if [ "${cur}" = "true" ]; then
      kubectl -n "${NS}" set env deploy/olly-sentinel LLM_GUARD_ENABLED=false >/dev/null 2>&1 \
        && echo "  sentinel hop: turned off (was on)"
    else
      echo "  sentinel hop: already off (no restart)"
    fi
  fi
  if have docker; then
    ( cd "${SANDBOX}" && docker compose down >/dev/null 2>&1 ) && echo "  promptfoo: stopped"
  fi
fi
