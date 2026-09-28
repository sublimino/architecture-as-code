#!/usr/bin/env bash
# scripts/swarm-deploy.sh — Deploy, remove, and inspect the 10-agent Signal
# Loom swarm via Flux ResourceSet reconciliation.
#
# Usage:
#   scripts/swarm-deploy.sh deploy [agent-name]   Deploy one or all agents via Flux
#   scripts/swarm-deploy.sh remove [agent-name]   Suspend + delete workloads for one or all
#   scripts/swarm-deploy.sh status                Show Flux reconciliation status
#   scripts/swarm-deploy.sh list                  List all swarm agent pods and states
#
# The ResourceSet is at d2-osramp-fleet/tenants/base/agent-swarm.yaml and
# creates per-agent Kustomization objects in fe-signalloom-agents.
set -euo pipefail

NAMESPACE="fe-signalloom-agents"
RESOURCESET_NAME="agent-swarm"
RESOURCESET_NS="flux-system"

# All 11 agent Kustomization names (as declared in the ResourceSet).
AGENTS=(
  agent-prompt-commit-summarizer
  agent-triage-ci-worker
  agent-zulip-chat-agent
  agent-cpai-engineer
  agent-hosted-daytona-coder
  agent-swarm-governor
  agent-prod-deploy-gate
  agent-cardvault
  agent-nono-containment-probe
  agent-signalloom-stun-sentinel
  agent-kusari-agent
)

# ── helpers ───────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "--- $* ---"; }

resolve_agent_name() {
  local name="$1"
  # Accept bare name or agent- prefixed
  local prefixed="agent-${name}"
  for a in "${AGENTS[@]}"; do
    [[ "$a" == "$name" || "$a" == "$prefixed" ]] && echo "$a" && return 0
  done
  die "Unknown agent: $name. Valid agents: ${AGENTS[*]}"
}

# ── deploy ────────────────────────────────────────────────────────────

cmd_deploy() {
  if [[ $# -eq 0 ]]; then
    info "Reconciling full agent-swarm ResourceSet"
    kubectl annotate resourceset/"$RESOURCESET_NAME" \
      -n "$RESOURCESET_NS" \
      reconcile.fluxcd.io/requestedAt="$(date +%s)" \
      --overwrite
    echo "ResourceSet annotated for immediate reconciliation."
  else
    local agent
    agent="$(resolve_agent_name "$1")"
    info "Reconciling agent: $agent"
    kubectl annotate kustomization/"$agent" \
      -n "$NAMESPACE" \
      reconcile.fluxcd.io/requestedAt="$(date +%s)" \
      --overwrite
    echo "Kustomization $agent annotated for immediate reconciliation."
  fi
}

# ── remove ────────────────────────────────────────────────────────────

remove_agent() {
  local agent="$1"
  info "Suspending Flux reconciliation for $agent"
  kubectl patch kustomization/"$agent" \
    -n "$NAMESPACE" \
    --type=merge \
    -p '{"spec":{"suspend":true}}' 2>/dev/null || true

  info "Deleting workloads for $agent"
  # The agent-name label on the Kustomization tells us which subdirectory
  # it manages; delete all resources in the target namespace with that label.
  local agent_label
  agent_label="$(kubectl get kustomization/"$agent" \
    -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.signalloom\.ai/agent-name}' 2>/dev/null || true)"
  if [[ -n "$agent_label" ]]; then
    kubectl delete deploy,sts,job,ds,svc,sa \
      -n "$NAMESPACE" \
      -l "app.kubernetes.io/name=$agent_label" \
      --ignore-not-found 2>/dev/null || true
  fi
  echo "Agent $agent suspended and workloads deleted."
}

cmd_remove() {
  if [[ $# -eq 0 ]]; then
    info "Removing all swarm agents"
    for agent in "${AGENTS[@]}"; do
      remove_agent "$agent"
    done
  else
    local agent
    agent="$(resolve_agent_name "$1")"
    remove_agent "$agent"
  fi
}

# ── status ────────────────────────────────────────────────────────────

cmd_status() {
  info "Flux ResourceSet status"
  kubectl get resourceset/"$RESOURCESET_NAME" \
    -n "$RESOURCESET_NS" \
    -o wide 2>/dev/null || echo "ResourceSet not found"
  echo

  info "Per-agent Kustomization status"
  kubectl get kustomization \
    -n "$NAMESPACE" \
    -l "signalloom.ai/agent=true" \
    -o wide 2>/dev/null || echo "No agent Kustomizations found"
}

# ── list ──────────────────────────────────────────────────────────────

cmd_list() {
  info "Agent swarm pods in $NAMESPACE"
  kubectl get pods \
    -n "$NAMESPACE" \
    -o wide 2>/dev/null || echo "No pods found in $NAMESPACE"
  echo

  info "Knative services (if any)"
  kubectl get ksvc \
    -n "$NAMESPACE" \
    -o wide 2>/dev/null || true
}

# ── main ──────────────────────────────────────────────────────────────

case "${1:-help}" in
  deploy) shift; cmd_deploy "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  status) cmd_status ;;
  list)   cmd_list ;;
  help|--help|-h)
    sed -n '2,/^$/s/^# //p' "$0"
    exit 0
    ;;
  *)
    die "Unknown command: $1. Use deploy|remove|status|list|help."
    ;;
esac
