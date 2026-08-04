#!/usr/bin/env bash
# SuperCred FLEET demo lifecycle: deploy, scan, stun, recover, reset for
# the five-agent heterogeneous fleet ("The Cascade").
#
# Subcommands:
#   supercred-fleet-demo.sh deploy-fleet   — deploy all five agents
#   supercred-fleet-demo.sh scan-fleet     — compliance scan each agent
#   supercred-fleet-demo.sh stun-agent <id>   — stun a single agent
#   supercred-fleet-demo.sh recover-agent <id> — re-credential a single agent
#   supercred-fleet-demo.sh reset-fleet    — tear down all five agents
#
# This script does NOT modify the single-agent demo (supercred-demo.sh).
# It reuses the same shared libs and follows the same patterns.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"

# ─── Constants ────────────────────────────────────────────────────────────────

NAMESPACE_INFRA="inf-signalloom"
NAMESPACE_BAO="inf-bao"
NAMESPACE_AGENTS="fe-signalloom-agents"
PARENT_ID="spiffe://signalloom.demo/agent/kind"
BAO_ROOT_TOKEN="signalloom-demo-root-token"

# The fleet: name|type|team|sa_name
# cardvault is the existing single-agent demo agent and uses its own SA name.
FLEET_AGENTS=(
  "agent-cardvault|data-vault|payments|cardvault-agent"
  "agent-txn-pipeline|data-pipeline|payments|txn-pipeline-agent"
  "agent-llm-classifier|llm-inference|ml-ops|llm-classifier-agent"
  "agent-api-gateway|api-gateway|platform|api-gateway-agent"
  "agent-monitor|observability|sre|monitor-agent"
)

# Per-agent SPIFFE IDs
declare -A SPIFFE_IDS=(
  [agent-cardvault]="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"
  [agent-txn-pipeline]="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/txn-pipeline-agent"
  [agent-llm-classifier]="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/llm-classifier-agent"
  [agent-api-gateway]="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/api-gateway-agent"
  [agent-monitor]="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/monitor-agent"
)

# Per-agent OpenBao JWT auth mount names (the fleet uses jwt-<team> mounts)
declare -A BAO_AUTH_MOUNTS=(
  [agent-cardvault]="jwt"
  [agent-txn-pipeline]="jwt-payments"
  [agent-llm-classifier]="jwt-ml-ops"
  [agent-api-gateway]="jwt-platform"
  [agent-monitor]="jwt-sre"
)

# Per-agent OpenBao role names
declare -A BAO_ROLES=(
  [agent-cardvault]="signalloom-cardvault-agent"
  [agent-txn-pipeline]="fleet-txn-pipeline"
  [agent-llm-classifier]="fleet-llm-classifier"
  [agent-api-gateway]="fleet-api-gateway"
  [agent-monitor]="fleet-monitor"
)

# Per-agent OpenBao KV paths
declare -A BAO_KV_PATHS=(
  [agent-cardvault]="kv/signalloom/cardvault-agent"
  [agent-txn-pipeline]="kv/payments/txn-pipeline"
  [agent-llm-classifier]="kv/ml-ops/llm-classifier"
  [agent-api-gateway]="kv/platform/api-gateway"
  [agent-monitor]="kv/sre/monitor"
)

# Per-agent OpenBao policy names
declare -A BAO_POLICIES=(
  [agent-cardvault]="signalloom-cardvault-agent"
  [agent-txn-pipeline]="fleet-txn-pipeline"
  [agent-llm-classifier]="fleet-llm-classifier"
  [agent-api-gateway]="fleet-api-gateway"
  [agent-monitor]="fleet-monitor"
)

IFS=' ' read -r -a AGENT_NAMESPACE_CANDIDATES \
  <<< "${AGENT_NAMESPACE_CANDIDATES:-fe-signalloom-agents fe-signalloom}"

log()  { printf '\033[1;36m[fleet]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[fleet] ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fleet] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Helpers ──────────────────────────────────────────────────────────────────

spire_pod() {
  kubectl -n "$NAMESPACE_BAO" get pod -l app.kubernetes.io/name=spire-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# resolve_fleet_agent_namespace <agent-name>
# Sets RESOLVED_NS to the namespace where the named agent pod lives.
resolve_fleet_agent_namespace() {
  local agent_name="$1"
  local ns
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    if kubectl -n "$ns" get pod "$agent_name" >/dev/null 2>&1; then
      RESOLVED_NS="$ns"
      return 0
    fi
  done
  RESOLVED_NS="$NAMESPACE_AGENTS"
  return 1
}

# parse_agent_entry <entry> — splits pipe-delimited agent entry
parse_agent_entry() {
  IFS='|' read -r AGENT_NAME AGENT_TYPE AGENT_TEAM AGENT_SA <<< "$1"
}

# validate_agent_id <id> — confirms the agent exists in FLEET_AGENTS
validate_agent_id() {
  local target="$1"
  local entry
  for entry in "${FLEET_AGENTS[@]}"; do
    parse_agent_entry "$entry"
    if [ "$AGENT_NAME" = "$target" ]; then
      return 0
    fi
  done
  fail "unknown agent: $target (valid: agent-cardvault, agent-txn-pipeline, agent-llm-classifier, agent-api-gateway, agent-monitor)"
}

# ─── Preflight ────────────────────────────────────────────────────────────────

preflight_cluster() {
  log "preflight: checking cluster health"
  kubectl cluster-info >/dev/null 2>&1 || fail "cluster not reachable"
  kubectl get ns "$NAMESPACE_BAO" >/dev/null 2>&1 \
    || fail "namespace $NAMESPACE_BAO not found — run make demo-signalloom-up first"
  wait_rollout openbao -n "$NAMESPACE_BAO" 30 \
    || fail "OpenBao not running — run make demo-signalloom-up first"
  wait_rollout spire-server -n "$NAMESPACE_BAO" 30 \
    || fail "SPIRE server not running — run make demo-signalloom-up first"
  wait_pods_ready "app.kubernetes.io/name=spire-agent" -n "$NAMESPACE_BAO" 60 \
    || fail "SPIRE agent not ready"
  ok "cluster healthy, OpenBao + SPIRE running"
}

# ─── deploy-fleet ─────────────────────────────────────────────────────────────

deploy_fleet() {
  preflight_cluster
  log "deploying fleet: 5 agents to $NAMESPACE_AGENTS"

  # Ensure namespace exists
  kubectl create namespace "$NAMESPACE_AGENTS" --dry-run=client -o yaml | \
    kubectl apply -f - 2>/dev/null || true
  kubectl annotate namespace "$NAMESPACE_AGENTS" \
    kustomize.toolkit.fluxcd.io/prune=disabled --overwrite 2>/dev/null || true

  # Deploy cardvault agent (existing manifests — the non-compliant one)
  log "deploying agent-cardvault (existing single-agent manifest)"
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault-sa.yaml
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml

  # Deploy the four new fleet agents
  log "deploying fleet agents (txn-pipeline, llm-classifier, api-gateway, monitor)"
  kubectl apply -k d2-signalloom/apps/fleet-agents/base/

  # Wait for all agent pods
  local entry
  for entry in "${FLEET_AGENTS[@]}"; do
    parse_agent_entry "$entry"
    log "waiting for $AGENT_NAME..."
    wait_pods_ready "app.kubernetes.io/instance=${AGENT_NAME#agent-}" \
      -n "$NAMESPACE_AGENTS" 60 \
      || fail "$AGENT_NAME pod failed to become ready"
  done

  # Seed OpenBao credentials for all agents
  log "seeding OpenBao credentials for fleet"
  local sp
  sp=$(spire_pod)

  # cardvault uses the existing single-agent pattern (jwt/ mount)
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_ROOT_TOKEN" sh -ec '
    cat >/tmp/policy.hcl <<POLICY
path "kv/data/signalloom/cardvault-agent" { capabilities = ["read"] }
POLICY
    bao policy write signalloom-cardvault-agent /tmp/policy.hcl
    bao write auth/jwt/role/signalloom-cardvault-agent \
      role_type=jwt bound_audiences=openbao \
      bound_subject=spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent \
      user_claim=sub policies=signalloom-cardvault-agent
    bao kv put kv/signalloom/cardvault-agent \
      username=cardvault-svc-account password=supercred-demo-password-2026
  '

  # Fleet agents use per-team JWT mounts
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_ROOT_TOKEN" sh -ec '
    # Enable per-team JWT auth mounts (idempotent)
    for mount in jwt-payments jwt-ml-ops jwt-platform jwt-sre; do
      if ! bao auth list 2>/dev/null | grep -q "${mount}/"; then
        bao auth enable -path="${mount}" jwt 2>/dev/null || true
      fi
    done

    # txn-pipeline
    cat >/tmp/p.hcl <<POLICY
path "kv/data/payments/txn-pipeline" { capabilities = ["read"] }
POLICY
    bao policy write fleet-txn-pipeline /tmp/p.hcl
    bao write auth/jwt-payments/role/fleet-txn-pipeline \
      role_type=jwt bound_audiences=openbao \
      bound_subject=spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/txn-pipeline-agent \
      user_claim=sub policies=fleet-txn-pipeline
    bao kv put kv/payments/txn-pipeline \
      api-key=txn-pipeline-key-2026 endpoint=cardvault.inf-signalloom.svc.cluster.local:8080

    # llm-classifier
    cat >/tmp/p.hcl <<POLICY
path "kv/data/ml-ops/llm-classifier" { capabilities = ["read"] }
POLICY
    bao policy write fleet-llm-classifier /tmp/p.hcl
    bao write auth/jwt-ml-ops/role/fleet-llm-classifier \
      role_type=jwt bound_audiences=openbao \
      bound_subject=spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/llm-classifier-agent \
      user_claim=sub policies=fleet-llm-classifier
    bao kv put kv/ml-ops/llm-classifier \
      model-endpoint=https://api.internal/v1/classify api-key=llm-classifier-key-2026

    # api-gateway
    cat >/tmp/p.hcl <<POLICY
path "kv/data/platform/api-gateway" { capabilities = ["read"] }
POLICY
    bao policy write fleet-api-gateway /tmp/p.hcl
    bao write auth/jwt-platform/role/fleet-api-gateway \
      role_type=jwt bound_audiences=openbao \
      bound_subject=spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/api-gateway-agent \
      user_claim=sub policies=fleet-api-gateway
    bao kv put kv/platform/api-gateway \
      upstream-url=cardvault.inf-signalloom.svc.cluster.local:8080 rate-limit=1000

    # monitor
    cat >/tmp/p.hcl <<POLICY
path "kv/data/sre/monitor" { capabilities = ["read"] }
POLICY
    bao policy write fleet-monitor /tmp/p.hcl
    bao write auth/jwt-sre/role/fleet-monitor \
      role_type=jwt bound_audiences=openbao \
      bound_subject=spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/monitor-agent \
      user_claim=sub policies=fleet-monitor
    bao kv put kv/sre/monitor \
      prometheus-endpoint=http://prometheus.monitoring.svc:9090 alert-webhook=https://alerts.internal/fleet
  '

  # Register SPIRE entries for all agents
  log "registering SPIRE entries for fleet"
  for entry in "${FLEET_AGENTS[@]}"; do
    parse_agent_entry "$entry"
    local spiffe_id="${SPIFFE_IDS[$AGENT_NAME]}"
    log "  SPIRE entry: $AGENT_NAME -> $spiffe_id"
    kubectl -n "$NAMESPACE_BAO" exec "$sp" -- \
      /opt/spire/bin/spire-server entry create \
        -spiffeID "$spiffe_id" \
        -parentID "$PARENT_ID" \
        -selector "k8s:ns:$NAMESPACE_AGENTS" \
        -selector "k8s:sa:$AGENT_SA" \
        -dns "$AGENT_NAME" 2>/dev/null || true
  done

  # Label all agents as active
  for entry in "${FLEET_AGENTS[@]}"; do
    parse_agent_entry "$entry"
    kubectl -n "$NAMESPACE_AGENTS" label pod "$AGENT_NAME" \
      signalloom.ai/state=active --overwrite 2>/dev/null || true
  done

  ok "fleet deployed: 5 agents active in $NAMESPACE_AGENTS"
}

# ─── scan-fleet ───────────────────────────────────────────────────────────────

scan_fleet() {
  log "scanning fleet for compliance"
  local entry non_compliant=0

  for entry in "${FLEET_AGENTS[@]}"; do
    parse_agent_entry "$entry"
    log "  scanning $AGENT_NAME..."

    # Check for pod-level securityContext
    local sc
    sc=$(kubectl -n "$NAMESPACE_AGENTS" get pod "$AGENT_NAME" \
      -o jsonpath='{.spec.securityContext}' 2>/dev/null) || continue

    if [[ "$sc" == "" ]] || [[ "$sc" == "{}" ]]; then
      log "  $AGENT_NAME: MISSING pod-level securityContext -> non-compliant"
      kubectl -n "$NAMESPACE_AGENTS" label pod "$AGENT_NAME" \
        signalloom.ai/state=non-compliant --overwrite
      non_compliant=$((non_compliant + 1))
    else
      log "  $AGENT_NAME: securityContext present -> compliant"
    fi
  done

  if [ "$non_compliant" -gt 0 ]; then
    ok "scan complete: $non_compliant agent(s) non-compliant"
  else
    ok "scan complete: all agents compliant"
  fi
}

# ─── stun-agent ───────────────────────────────────────────────────────────────

stun_agent() {
  local agent_id="$1"
  [ -n "$agent_id" ] || fail "usage: supercred-fleet-demo.sh stun-agent <agent-id>"
  validate_agent_id "$agent_id"

  log "stunning agent: $agent_id"

  # Revoke OpenBao credentials
  local auth_mount="${BAO_AUTH_MOUNTS[$agent_id]}"
  local role="${BAO_ROLES[$agent_id]}"
  log "  revoking OpenBao role: $role on mount $auth_mount"
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_ROOT_TOKEN" \
    bao delete "auth/${auth_mount}/role/${role}" 2>/dev/null || true

  # Label as stunned
  kubectl -n "$NAMESPACE_AGENTS" label pod "$agent_id" \
    signalloom.ai/state=stunned --overwrite
  kubectl -n "$NAMESPACE_AGENTS" annotate pod "$agent_id" \
    "signalloom.ai/stunned-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "signalloom.ai/stun-reason=credential-revocation" --overwrite

  ok "agent $agent_id stunned — credentials revoked, labelled stunned"
}

# ─── recover-agent ────────────────────────────────────────────────────────────

recover_agent() {
  local agent_id="$1"
  [ -n "$agent_id" ] || fail "usage: supercred-fleet-demo.sh recover-agent <agent-id>"
  validate_agent_id "$agent_id"

  log "recovering agent: $agent_id"

  local spiffe_id="${SPIFFE_IDS[$agent_id]}"
  local auth_mount="${BAO_AUTH_MOUNTS[$agent_id]}"
  local role="${BAO_ROLES[$agent_id]}"
  local policy="${BAO_POLICIES[$agent_id]}"
  local kv_path="${BAO_KV_PATHS[$agent_id]}"

  # Re-register SPIRE entry
  local sp
  sp=$(spire_pod)
  log "  re-registering SPIRE entry: $spiffe_id"

  # Find the SA name for this agent
  local entry sa_name=""
  for entry in "${FLEET_AGENTS[@]}"; do
    parse_agent_entry "$entry"
    if [ "$AGENT_NAME" = "$agent_id" ]; then
      sa_name="$AGENT_SA"
      break
    fi
  done

  kubectl -n "$NAMESPACE_BAO" exec "$sp" -- \
    /opt/spire/bin/spire-server entry create \
      -spiffeID "$spiffe_id" \
      -parentID "$PARENT_ID" \
      -selector "k8s:ns:$NAMESPACE_AGENTS" \
      -selector "k8s:sa:$sa_name" \
      -dns "$agent_id" 2>/dev/null || true

  # Re-create OpenBao role
  log "  re-creating OpenBao role: $role"
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_ROOT_TOKEN" sh -ec "
    bao write auth/${auth_mount}/role/${role} \
      role_type=jwt bound_audiences=openbao \
      bound_subject='${spiffe_id}' \
      user_claim=sub policies=${policy}
  "

  # Label as active
  kubectl -n "$NAMESPACE_AGENTS" label pod "$agent_id" \
    signalloom.ai/state=active --overwrite
  kubectl -n "$NAMESPACE_AGENTS" annotate pod "$agent_id" \
    signalloom.ai/stunned-at- \
    signalloom.ai/stun-reason- 2>/dev/null || true

  ok "agent $agent_id recovered — new credentials issued, labelled active"
}

# ─── reset-fleet ──────────────────────────────────────────────────────────────

reset_fleet() {
  log "resetting fleet: tearing down all agents"

  # Delete fleet agent pods and SAs
  kubectl delete -k d2-signalloom/apps/fleet-agents/base/ --ignore-not-found 2>/dev/null || true

  # Delete cardvault agent (original single-agent manifests)
  kubectl delete pod agent-cardvault -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true 2>/dev/null || true
  kubectl delete sa cardvault-agent -n "$NAMESPACE_AGENTS" --ignore-not-found 2>/dev/null || true

  # Also sweep the alternate namespace
  local ns
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    local entry
    for entry in "${FLEET_AGENTS[@]}"; do
      parse_agent_entry "$entry"
      kubectl delete pod "$AGENT_NAME" -n "$ns" --ignore-not-found --wait=true 2>/dev/null || true
      kubectl delete sa "$AGENT_SA" -n "$ns" --ignore-not-found 2>/dev/null || true
    done
  done

  # Delete OpenBao fleet resources
  log "cleaning OpenBao fleet roles and policies"
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_ROOT_TOKEN" sh -ec '
    # Fleet roles
    bao delete auth/jwt-payments/role/fleet-txn-pipeline 2>/dev/null || true
    bao delete auth/jwt-ml-ops/role/fleet-llm-classifier 2>/dev/null || true
    bao delete auth/jwt-platform/role/fleet-api-gateway 2>/dev/null || true
    bao delete auth/jwt-sre/role/fleet-monitor 2>/dev/null || true
    # Cardvault role
    bao delete auth/jwt/role/signalloom-cardvault-agent 2>/dev/null || true
    # Fleet policies
    bao policy delete fleet-txn-pipeline 2>/dev/null || true
    bao policy delete fleet-llm-classifier 2>/dev/null || true
    bao policy delete fleet-api-gateway 2>/dev/null || true
    bao policy delete fleet-monitor 2>/dev/null || true
    bao policy delete signalloom-cardvault-agent 2>/dev/null || true
  ' 2>/dev/null || true

  # Delete SPIRE entries for fleet agents
  log "cleaning SPIRE entries"
  local sp
  sp=$(spire_pod) || true
  if [ -n "$sp" ]; then
    local entry
    for entry in "${FLEET_AGENTS[@]}"; do
      parse_agent_entry "$entry"
      local spiffe_id="${SPIFFE_IDS[$AGENT_NAME]}"
      local eid
      eid=$(kubectl -n "$NAMESPACE_BAO" exec "$sp" -- \
        /opt/spire/bin/spire-server entry show -spiffeID "$spiffe_id" 2>/dev/null \
        | grep "Entry ID" | awk '{print $NF}') || true
      if [ -n "$eid" ]; then
        kubectl -n "$NAMESPACE_BAO" exec "$sp" -- \
          /opt/spire/bin/spire-server entry delete -entryID "$eid" >/dev/null 2>&1 || true
      fi
    done
  fi

  # Delete fleet bootstrap job
  kubectl delete job openbao-fleet-bootstrap -n "$NAMESPACE_BAO" --ignore-not-found --wait=true 2>/dev/null || true

  # Verify clean state
  log "verifying clean state"
  local remaining=0
  local entry
  for entry in "${FLEET_AGENTS[@]}"; do
    parse_agent_entry "$entry"
    if kubectl -n "$NAMESPACE_AGENTS" get pod "$AGENT_NAME" >/dev/null 2>&1; then
      log "  WARNING: $AGENT_NAME still exists"
      remaining=$((remaining + 1))
    fi
  done

  if [ "$remaining" -gt 0 ]; then
    fail "$remaining agent pod(s) still exist after teardown"
  fi

  ok "fleet reset complete — all agents removed"
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  deploy-fleet)   deploy_fleet ;;
  scan-fleet)     scan_fleet ;;
  stun-agent)     stun_agent "${2:-}" ;;
  recover-agent)  recover_agent "${2:-}" ;;
  reset-fleet)    reset_fleet ;;
  *)
    echo "Usage: $0 {deploy-fleet|scan-fleet|stun-agent <id>|recover-agent <id>|reset-fleet}"
    echo ""
    echo "Fleet agents: agent-cardvault, agent-txn-pipeline, agent-llm-classifier,"
    echo "              agent-api-gateway, agent-monitor"
    exit 1
    ;;
esac
