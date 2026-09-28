#!/usr/bin/env bash
# swarm-fleet-demo.sh — Deploy and verify the 10-agent demo fleet
#
# Usage:
#   scripts/swarm-fleet-demo.sh deploy    # Deploy all agents
#   scripts/swarm-fleet-demo.sh verify    # Run verification matrix
#   scripts/swarm-fleet-demo.sh teardown  # Remove all agents
#   scripts/swarm-fleet-demo.sh all       # Deploy + verify
#
# Prerequisites:
#   - Kind cluster 'osramp' running
#   - Flux bootstrapped
#   - SPIRE + OpenBao deployed in inf-bao
#   - Knative Serving + Eventing installed
#
# The fleet exercises every workload archetype:
#   Tier 1: prompt-commit-summarizer (stateless prompt function)
#   Tier 2: triage-ci-worker (deterministic structured worker)
#   Tier 3: zulip-chat-agent (interactive ChatOps)
#   Tier 4A: cpai-engineer (in-cluster sandboxed coding)
#   Tier 4B: hosted-daytona-coder (hosted remote coding)
#   Tier 5: swarm-governor (A2A dispatcher)
#   Tier 6: prod-deploy-gate (HITL policy proxy)
#   Security: agent-cardvault, nono-containment-probe, stun-sentinel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${SWARM_NAMESPACE:-fe-signalloom-agents}"

# ── Colours ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { printf "${BLUE}[swarm]${NC} %s\n" "$*"; }
pass() { printf "${GREEN}[PASS]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

# ── Deploy ───────────────────────────────────────────────────────────────────

deploy_infra() {
  log "Deploying swarm infrastructure..."

  # Ensure namespace exists with correct labels
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || \
    kubectl create ns "$NAMESPACE"
  kubectl label ns "$NAMESPACE" signalloom.ai/managed=true --overwrite

  # Apply OpenBao glob JWT role
  if [[ -d "$ROOT/d2-signalloom/infra/inf-bao/controllers/base" ]]; then
    log "Applying OpenBao agent generic role..."
    kubectl apply -k "$ROOT/d2-signalloom/infra/inf-bao/controllers/base/" 2>/dev/null || true
  fi

  # Apply Knative (if manifests exist)
  if [[ -d "$ROOT/d2-signalloom/infra/knative" ]]; then
    log "Applying Knative Eventing..."
    kubectl apply -k "$ROOT/d2-signalloom/infra/knative/" 2>/dev/null || true
  fi

  # Apply agent swarm RBAC
  if [[ -d "$ROOT/d2-signalloom/infra/agent-swarm" ]]; then
    log "Applying agent swarm RBAC and service accounts..."
    kubectl apply -k "$ROOT/d2-signalloom/infra/agent-swarm/" 2>/dev/null || true
  fi

  log "Infrastructure deployed."
}

deploy_fleet() {
  log "Deploying 10-agent demo fleet..."

  local agents=(
    prompt-commit-summarizer
    triage-ci-worker
    zulip-chat-agent
    cpai-engineer
    hosted-daytona-coder
    swarm-governor
    prod-deploy-gate
    agent-cardvault
    nono-containment-probe
    signalloom-stun-sentinel
    kusari-agent
  )

  for agent in "${agents[@]}"; do
    local manifest_dir="$ROOT/d2-signalloom/infra/agent-swarm/$agent"
    if [[ -d "$manifest_dir" ]]; then
      log "  Deploying $agent..."
      kubectl apply -k "$manifest_dir/" 2>/dev/null || warn "  $agent: apply failed (may need prerequisites)"
    else
      warn "  $agent: no manifests at $manifest_dir"
    fi
  done

  log "Fleet deployment complete. Waiting for pods..."
  kubectl wait --for=condition=Ready pod -l signalloom.ai/agent=true \
    -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
    warn "Some pods not ready within 120s — check with: kubectl get pods -n $NAMESPACE"
}

# ── Verify ───────────────────────────────────────────────────────────────────

verify_discovery() {
  log "Gate 0: Label-driven discovery..."
  local count
  count=$(kubectl get pods -n "$NAMESPACE" -l signalloom.ai/agent=true \
    --no-headers 2>/dev/null | wc -l)
  if [[ "$count" -ge 1 ]]; then
    pass "Discovered $count governed agents via label selector"
  else
    fail "No agents discovered with signalloom.ai/agent=true label"
    return 1
  fi
}

verify_prompt_summarizer() {
  log "Gate 1: Prompt Function (prompt-commit-summarizer)..."
  # Check the Knative service exists
  if kubectl get ksvc prompt-commit-summarizer -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "Knative service exists"
  elif kubectl get deployment prompt-commit-summarizer -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "Deployment exists (Knative optional)"
  else
    warn "prompt-commit-summarizer not deployed — skipping"
  fi
}

verify_triage_worker() {
  log "Gate 2: Tool Worker (triage-ci-worker)..."
  if kubectl get ksvc triage-ci-worker -n "$NAMESPACE" >/dev/null 2>&1 || \
     kubectl get deployment triage-ci-worker -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "triage-ci-worker exists"
  else
    warn "triage-ci-worker not deployed — skipping"
  fi
}

verify_chatops() {
  log "Gate 3: ChatOps Ingress (zulip-chat-agent)..."
  if kubectl get deployment zulip-chat-agent -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "zulip-chat-agent deployment exists"
  else
    warn "zulip-chat-agent not deployed — skipping"
  fi
}

verify_cpai() {
  log "Gate 4: In-Cluster Sandbox (cpai-engineer)..."
  if kubectl get statefulset cpai-engineer -n "$NAMESPACE" >/dev/null 2>&1 || \
     kubectl get deployment cpai-engineer -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "cpai-engineer exists"
  else
    warn "cpai-engineer not deployed — skipping"
  fi
}

verify_daytona() {
  log "Gate 5: Hosted Devbox (hosted-daytona-coder)..."
  if kubectl get deployment hosted-daytona-coder -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "hosted-daytona-coder workspace manager exists"
  else
    warn "hosted-daytona-coder not deployed — skipping"
  fi
}

verify_governor() {
  log "Gate 6: Swarm Governor (swarm-governor)..."
  if kubectl get deployment swarm-governor -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "swarm-governor deployment exists"
    # Check A2A card is served
    local pod
    pod=$(kubectl get pod -n "$NAMESPACE" -l app=swarm-governor \
      --no-headers -o name 2>/dev/null | head -1)
    if [[ -n "$pod" ]]; then
      if kubectl exec -n "$NAMESPACE" "$pod" -- \
        wget -qO- http://localhost:8080/.well-known/agent-card.json 2>/dev/null | \
        grep -q '"name"'; then
        pass "A2A agent card served at /.well-known/agent-card.json"
      else
        warn "A2A agent card not reachable"
      fi
    fi
  else
    warn "swarm-governor not deployed — skipping"
  fi
}

verify_deploy_gate() {
  log "Gate 7: HITL Gate (prod-deploy-gate)..."
  if kubectl get deployment prod-deploy-gate -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "prod-deploy-gate deployment exists"
  else
    warn "prod-deploy-gate not deployed — skipping"
  fi
}

verify_cardvault() {
  log "Gate 8: SPIRE / OpenBao (agent-cardvault)..."
  if kubectl get deployment agent-cardvault -n "$NAMESPACE" >/dev/null 2>&1 || \
     kubectl get deployment cardvault-agent -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "agent-cardvault exists"
  else
    warn "agent-cardvault not deployed — skipping"
  fi
}

verify_nono() {
  log "Gate 9: Nono Landlock (nono-containment-probe)..."
  if kubectl get job nono-containment-probe -n "$NAMESPACE" >/dev/null 2>&1; then
    # Check job completion
    local status
    status=$(kubectl get job nono-containment-probe -n "$NAMESPACE" \
      -o jsonpath='{.status.succeeded}' 2>/dev/null)
    if [[ "$status" == "1" ]]; then
      pass "nono-containment-probe completed successfully"
      # Show probe results
      local pod
      pod=$(kubectl get pod -n "$NAMESPACE" -l job-name=nono-containment-probe \
        --no-headers -o name 2>/dev/null | head -1)
      if [[ -n "$pod" ]]; then
        log "  Probe results:"
        kubectl logs -n "$NAMESPACE" "$pod" 2>/dev/null | head -10
      fi
    else
      warn "nono-containment-probe has not completed yet"
    fi
  else
    warn "nono-containment-probe not deployed — skipping"
  fi
}

verify_stun_sentinel() {
  log "Gate 10: eBPF Stun (signalloom-stun-sentinel)..."
  if kubectl get daemonset signalloom-stun-sentinel -n "$NAMESPACE" >/dev/null 2>&1; then
    local desired ready
    desired=$(kubectl get daemonset signalloom-stun-sentinel -n "$NAMESPACE" \
      -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
    ready=$(kubectl get daemonset signalloom-stun-sentinel -n "$NAMESPACE" \
      -o jsonpath='{.status.numberReady}' 2>/dev/null)
    if [[ "$ready" == "$desired" ]] && [[ "$desired" -ge 1 ]]; then
      pass "Stun sentinel DaemonSet ready ($ready/$desired)"
    else
      warn "Stun sentinel not fully ready ($ready/$desired)"
    fi
  else
    warn "signalloom-stun-sentinel not deployed — skipping"
  fi
}

verify_stun_action() {
  log "Gate 10b: Stun action test..."
  # Find any governed agent pod
  local target
  target=$(kubectl get pod -n "$NAMESPACE" \
    -l signalloom.ai/agent=true,signalloom.ai/role!=sentinel \
    --no-headers -o name 2>/dev/null | head -1)

  if [[ -z "$target" ]]; then
    warn "No agent pod available for stun test"
    return
  fi

  local pod_name="${target#pod/}"
  log "  Stunning $pod_name..."
  kubectl label pod -n "$NAMESPACE" "$pod_name" signalloom.ai/state=stunned signalloom.io/stunned=true signalloom.io/containment-mode=frozen --field-manager=flux-client-side-apply --overwrite
  kubectl annotate pod -n "$NAMESPACE" "$pod_name" signalloom.ai/stun-reason="demo-containment" signalloom.io/stun-reason="demo-containment" --field-manager=flux-client-side-apply --overwrite

  sleep 2

  local state
  state=$(kubectl get pod -n "$NAMESPACE" "$pod_name" \
    -o jsonpath='{.metadata.labels.signalloom\.ai/state}' 2>/dev/null)
  if [[ "$state" == "stunned" ]]; then
    pass "Pod labelled as stunned"
  else
    fail "Pod label not set"
  fi

  # Unstun
  log "  Unstuning $pod_name..."
  kubectl label pod -n "$NAMESPACE" "$pod_name" signalloom.ai/state=active signalloom.io/stunned=false signalloom.io/containment-mode=none --field-manager=flux-client-side-apply --overwrite
}

run_verification() {
  log "Running verification matrix..."
  echo ""

  verify_discovery
  echo ""
  verify_prompt_summarizer
  verify_triage_worker
  verify_chatops
  verify_cpai
  verify_daytona
  verify_governor
  verify_deploy_gate
  verify_cardvault
  verify_nono
  verify_stun_sentinel
  echo ""
  verify_stun_action
  echo ""

  log "Verification complete."
}

# ── Teardown ─────────────────────────────────────────────────────────────────

teardown() {
  log "Tearing down demo fleet..."

  # Delete all governed agent workloads
  kubectl delete deployment,statefulset,daemonset,job,ksvc \
    -n "$NAMESPACE" -l signalloom.ai/agent=true \
    --ignore-not-found 2>/dev/null || true

  # Clean up PVCs
  kubectl delete pvc -n "$NAMESPACE" -l signalloom.ai/agent=true \
    --ignore-not-found 2>/dev/null || true

  log "Fleet teardown complete."
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-help}" in
  deploy)
    deploy_infra
    deploy_fleet
    ;;
  verify)
    run_verification
    ;;
  teardown)
    teardown
    ;;
  all)
    deploy_infra
    deploy_fleet
    echo ""
    log "Waiting 30s for pods to settle..."
    sleep 30
    run_verification
    ;;
  *)
    echo "Usage: $0 {deploy|verify|teardown|all}"
    exit 1
    ;;
esac
