#!/usr/bin/env bash
# SuperCred demo lifecycle: identity chain → compliance scan → agent stun.
#
# Five numbered steps, each with a preflight check:
#   supercred-demo.sh 1   # Deploy services, agent, OpenBao secrets, SPIRE entry
#   supercred-demo.sh 2   # Run the agent's credential chain
#   supercred-demo.sh 3   # Compliance scan — discovers missing securityContext
#   supercred-demo.sh 4   # Stun: revoke credentials, verify denial
#   supercred-demo.sh 5   # Teardown + verify clean
#   supercred-demo.sh all # Run 1→5 sequentially
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"

NAMESPACE_INFRA="inf-signalloom"
NAMESPACE_BAO="inf-bao"
NAMESPACE_AGENTS="fe-signalloom-agents"
SPIFFE_ID="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"
PARENT_ID="spiffe://signalloom.demo/agent/kind"

# agents-cardvault.yaml declares `namespace: fe-signalloom-agents`, but the Flux
# Kustomization's targetNamespace can override that and land the pod in
# fe-signalloom instead. NAMESPACE_AGENTS stays the default (and the namespace
# this script creates and deletes Jobs in); AGENT_POD_NAMESPACE is resolved at
# runtime so label/annotate/get calls follow the pod wherever Flux placed it.
IFS=' ' read -r -a AGENT_NAMESPACE_CANDIDATES \
  <<< "${AGENT_NAMESPACE_CANDIDATES:-fe-signalloom-agents fe-signalloom}"
AGENT_POD_NAMESPACE="$NAMESPACE_AGENTS"

log() { printf '\033[1;36m[supercred]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[supercred] ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[supercred] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

# Sets AGENT_POD_NAMESPACE to the namespace that actually holds agent-cardvault.
# Falls back to NAMESPACE_AGENTS and returns non-zero when the pod is nowhere.
resolve_agent_pod_namespace() {
  local ns
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    if kubectl -n "$ns" get pod agent-cardvault >/dev/null 2>&1; then
      AGENT_POD_NAMESPACE="$ns"
      if [ "$ns" != "$NAMESPACE_AGENTS" ]; then
        log "agent-cardvault resolved to namespace $ns (Flux relocated it from $NAMESPACE_AGENTS)"
      fi
      return 0
    fi
  done
  AGENT_POD_NAMESPACE="$NAMESPACE_AGENTS"
  return 1
}

spire_pod() {
  kubectl -n "$NAMESPACE_BAO" get pod -l app.kubernetes.io/name=spire-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ─── Preflight checks ───────────────────────────────────────────────────────

preflight_cluster() {
  log "preflight: checking cluster health"
  kubectl cluster-info >/dev/null 2>&1 || fail "cluster not reachable"
  kubectl get ns "$NAMESPACE_BAO" >/dev/null 2>&1 || fail "namespace $NAMESPACE_BAO not found — run make demo-signalloom-up first"
  kubectl get ns "$NAMESPACE_INFRA" >/dev/null 2>&1 || fail "namespace $NAMESPACE_INFRA not found — run make demo-signalloom-up first"
  wait_k8s_ready deployment openbao -n "$NAMESPACE_BAO" 30 \
    || fail "OpenBao not running — run make demo-signalloom-up first"
  wait_k8s_ready deployment spire-server -n "$NAMESPACE_BAO" 30 \
    || fail "SPIRE server not running — run make demo-signalloom-up first"
  wait_pods_ready "app.kubernetes.io/name=spire-agent" -n "$NAMESPACE_BAO" 60 \
    || fail "SPIRE agent not ready — the agent needs a valid join token. Check: kubectl -n inf-bao logs daemonset/spire-agent"
  ok "cluster healthy, OpenBao + SPIRE + agent running"
}

preflight_images() {
  # kind-loaded :local images do NOT survive a `kind delete/create`, but the
  # namespaces/Jobs referencing them can be re-applied — leaving a manifest
  # pointing at an image that is no longer on the node. containerd then falls
  # back to the pull-through mirror and fails with "unexpected media type
  # text/html" (ImagePullBackOff). Verify the images are present before any step
  # applies a workload that needs them.
  log "preflight: verifying supercred images are loaded on the node"
  local node="${CLUSTER_NAME:-osramp}-control-plane"
  local img missing=()
  for img in cardvault:local policy-engine:local cardvault-agent:local; do
    docker exec "$node" ctr -n k8s.io images ls -q 2>/dev/null \
      | grep -Fq "docker.io/library/${img}" || missing+=("$img")
  done
  if ((${#missing[@]} > 0)); then
    fail "supercred images missing from the kind node: ${missing[*]}
       (kind-loaded :local images do not survive a cluster recreate)
       rebuild + reload them:  make demo-signalloom-supercred-images"
  fi
  ok "supercred images present on the node"
}

preflight_step1_deployed() {
  log "preflight: verifying step 1 resources"
  wait_k8s_exists deployment cardvault -n "$NAMESPACE_INFRA" 10 \
    || fail "cardvault not deployed — run step 1 first"
  wait_k8s_exists deployment policy-engine -n "$NAMESPACE_INFRA" 10 \
    || fail "policy-engine not deployed — run step 1 first"
  resolve_agent_pod_namespace \
    || fail "agent-cardvault pod not found in ${AGENT_NAMESPACE_CANDIDATES[*]} — run step 1 first"
  wait_k8s_exists pod agent-cardvault -n "$AGENT_POD_NAMESPACE" 10 \
    || fail "agent-cardvault pod not found — run step 1 first"
  ok "step 1 resources present (agent pod in $AGENT_POD_NAMESPACE)"
}

preflight_step2_completed() {
  log "preflight: verifying credential chain ran"
  resolve_agent_pod_namespace || fail "agent-cardvault pod not found — run step 1 first"
  local state
  state=$(kubectl -n "$AGENT_POD_NAMESPACE" get pod agent-cardvault \
    -o jsonpath='{.metadata.labels.signalloom\.ai/state}' 2>/dev/null)
  [ "$state" = "active" ] || [ "$state" = "non-compliant" ] \
    || fail "agent state is '$state' — run step 2 first (expected active or non-compliant)"
  ok "agent state = $state (credential chain completed)"
}

preflight_step3_completed() {
  log "preflight: verifying compliance scan ran"
  resolve_agent_pod_namespace || fail "agent-cardvault pod not found — run step 1 first"
  local state
  state=$(kubectl -n "$AGENT_POD_NAMESPACE" get pod agent-cardvault \
    -o jsonpath='{.metadata.labels.signalloom\.ai/state}' 2>/dev/null)
  [ "$state" = "non-compliant" ] \
    || fail "agent state is '$state' — run step 3 first (expected non-compliant)"
  ok "agent state = non-compliant (compliance scan completed)"
}

# ─── STEP 1: Deploy ─────────────────────────────────────────────────────────

demo_1() {
  preflight_cluster
  preflight_images
  log "step 1: clean + deploy supercred services"

  # Ensure agents namespace exists (annotated to prevent Flux pruning)
  kubectl create namespace "$NAMESPACE_AGENTS" --dry-run=client -o yaml | \
    kubectl apply -f - 2>/dev/null || true
  kubectl annotate namespace "$NAMESPACE_AGENTS" \
    kustomize.toolkit.fluxcd.io/prune=disabled --overwrite 2>/dev/null || true

  # Clean previous runs (idempotent)
  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl delete job openbao-supercred-bootstrap -n "$NAMESPACE_BAO" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  resolve_agent_pod_namespace || true
  kubectl delete pod agent-cardvault -n "$AGENT_POD_NAMESPACE" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  # Clean SPIRE entry from previous run
  local spire_pod
  spire_pod=$(spire_pod)
  if [ -n "$spire_pod" ]; then
    local entry_id
    entry_id=$(kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
      /opt/spire/bin/spire-server entry show -spiffeID "$SPIFFE_ID" 2>/dev/null \
      | grep "Entry ID" | awk '{print $NF}') || true
    if [ -n "$entry_id" ]; then
      kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
        /opt/spire/bin/spire-server entry delete -entryID "$entry_id" >/dev/null 2>&1 || true
    fi
  fi

  # Apply NetworkPolicy updates for cross-namespace access
  log "applying NetworkPolicy updates"
  kubectl apply -f d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml -n "$NAMESPACE_BAO" 2>/dev/null || true

  # Deploy cardvault service
  log "deploying cardvault service"
  kubectl apply -k d2-signalloom/apps/cardvault/base/ -n "$NAMESPACE_INFRA"
  wait_rollout cardvault -n "$NAMESPACE_INFRA" 120 || fail "cardvault deployment failed"

  # Deploy policy engine
  log "deploying policy-engine"
  kubectl apply -k d2-signalloom/apps/policy-engine/base/ -n "$NAMESPACE_INFRA"
  wait_rollout policy-engine -n "$NAMESPACE_INFRA" 120 || fail "policy-engine deployment failed"

  # Deploy agent (inert pod + service account)
  log "deploying cardvault agent"
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault-sa.yaml
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml
  resolve_agent_pod_namespace || true
  wait_pods_ready "app.kubernetes.io/instance=cardvault" -n "$AGENT_POD_NAMESPACE" 60 \
    || fail "agent pod failed to become ready in $AGENT_POD_NAMESPACE"

  # Re-seed OpenBao secrets (handles stun revocation from previous run)
  log "seeding OpenBao supercred secrets"
  spire_pod=$(spire_pod)
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token sh -ec '
    cat >/tmp/policy.hcl <<POLICY
path "kv/data/signalloom/cardvault-agent" { capabilities = ["read"] }
POLICY
    bao policy write signalloom-cardvault-agent /tmp/policy.hcl
    bao write auth/jwt/role/signalloom-cardvault-agent \
      role_type=jwt bound_audiences=openbao \
      bound_subject='"$SPIFFE_ID"' \
      user_claim=sub policies=signalloom-cardvault-agent
    bao kv put kv/signalloom/cardvault-agent \
      username=cardvault-svc-account password=supercred-demo-password-2026
  '

  # Register SPIRE entry
  log "registering SPIRE entry"
  kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
    /opt/spire/bin/spire-server entry create \
      -spiffeID "$SPIFFE_ID" \
      -parentID "$PARENT_ID" \
      -selector "k8s:ns:fe-signalloom-agents" \
      -selector "k8s:sa:cardvault-agent" \
      -dns cardvault-agent 2>/dev/null || true

  ok "step 1 complete — services deployed, secrets seeded, SPIRE registered"
}

# ─── STEP 2: Credential Chain ───────────────────────────────────────────────

demo_2() {
  preflight_step1_deployed
  preflight_images
  log "step 2: running the agent's credential chain (SPIFFE → OpenBao → cardvault)"

  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml

  log "waiting for agent job to complete..."
  wait_k8s_ready job supercred-agent-run -n "$NAMESPACE_AGENTS" --for condition=complete 300 || {
    log "agent job output:"
    kubectl -n "$NAMESPACE_AGENTS" logs job/supercred-agent-run --tail=50 2>/dev/null || true
    fail "agent credential chain failed"
  }

  log "agent job output:"
  kubectl -n "$NAMESPACE_AGENTS" logs job/supercred-agent-run

  kubectl -n "$AGENT_POD_NAMESPACE" label pod agent-cardvault signalloom.ai/state=active --overwrite
  ok "step 2 complete — credential chain verified, agent marked active"
}

# ─── STEP 3: Compliance Scan ────────────────────────────────────────────────

demo_3() {
  preflight_step2_completed
  log "step 3: compliance scan against cardvault agent"

  local pod_spec
  pod_spec=$(kubectl -n "$AGENT_POD_NAMESPACE" get pod agent-cardvault -o json | \
    python3 -c 'import sys,json; d=json.load(sys.stdin)["spec"]; print(json.dumps({"containers":[{"name":c["name"],"securityContext":c.get("securityContext")} for c in d.get("containers",[])], "securityContext":d.get("securityContext")}))')

  kubectl -n "$NAMESPACE_INFRA" port-forward svc/policy-engine 18081:8081 >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill $pf_pid 2>/dev/null || true' RETURN

  wait_reachable http://localhost:18081/healthz 30 || fail "policy-engine port-forward not reachable"

  local result
  result=$(curl -sS --fail -X POST http://localhost:18081/api/v1/evaluate \
    -H 'Content-Type: application/json' \
    -d "{\"agent_id\":\"cardvault\",\"namespace\":\"$AGENT_POD_NAMESPACE\",\"pod_spec\":$pod_spec,\"checks\":[\"security-context-present\",\"run-as-non-root\",\"drop-capabilities\"]}") \
    || fail "policy-engine evaluate call failed"
  kill $pf_pid 2>/dev/null || true

  python3 -c "
import json
r = json.loads('''$result''')
print(f\"\\n  Agent: {r['agent_id']}\")
print(f\"  Compliant: {r['compliant']}\")
for c in r.get('results', []):
    icon = '✅' if c['pass'] else '❌'
    print(f\"  {icon} {c['check']}: {c['reason']}\")
print()
"

  local compliant
  compliant=$(python3 -c "import json; print(json.loads('''$result''')['compliant'])")
  if [ "$compliant" = "False" ] || [ "$compliant" = "false" ]; then
    kubectl -n "$AGENT_POD_NAMESPACE" label pod agent-cardvault signalloom.ai/state=non-compliant --overwrite
    ok "step 3 complete — agent is OUT OF COMPLIANCE"
  else
    ok "step 3 complete — agent is compliant"
  fi
}

# ─── STEP 4: Stun ───────────────────────────────────────────────────────────

demo_4() {
  preflight_step3_completed
  preflight_images
  log "step 4: revoking credentials and restricting agent"

  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token \
    bao kv delete kv/signalloom/cardvault-agent 2>/dev/null || true

  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token \
    bao delete auth/jwt/role/signalloom-cardvault-agent 2>/dev/null || true

  kubectl -n "$AGENT_POD_NAMESPACE" label pod agent-cardvault signalloom.ai/state=stunned --overwrite
  kubectl -n "$AGENT_POD_NAMESPACE" annotate pod agent-cardvault \
    "signalloom.ai/stunned-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "signalloom.ai/stun-reason=compliance-failure: securityContext not set" \
    --overwrite

  log "verifying agent credential revocation..."
  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml
  if wait_k8s_ready job supercred-agent-run -n "$NAMESPACE_AGENTS" --for condition=complete 60 2>/dev/null; then
    fail "agent should not complete after stun — credentials were not revoked"
  else
    log "confirmed: agent cannot acquire credentials (expected failure)"
    kubectl -n "$NAMESPACE_AGENTS" logs job/supercred-agent-run --tail=5 2>/dev/null || true
  fi

  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  ok "step 4 complete — agent stunned, credentials revoked"
}

# ─── STEP 5: Teardown ───────────────────────────────────────────────────────

demo_5() {
  log "step 5: tearing down supercred demo resources"
  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true 2>/dev/null || true
  kubectl delete job openbao-supercred-bootstrap -n "$NAMESPACE_BAO" --ignore-not-found --wait=true 2>/dev/null || true
  resolve_agent_pod_namespace || true
  kubectl delete pod agent-cardvault -n "$AGENT_POD_NAMESPACE" --ignore-not-found --wait=true 2>/dev/null || true
  kubectl delete sa cardvault-agent -n "$NAMESPACE_AGENTS" --ignore-not-found 2>/dev/null || true
  kubectl delete -k d2-signalloom/apps/cardvault/base/ --ignore-not-found 2>/dev/null || true
  kubectl delete -k d2-signalloom/apps/policy-engine/base/ --ignore-not-found 2>/dev/null || true

  local spire_pod
  spire_pod=$(spire_pod)
  if [ -n "$spire_pod" ]; then
    local entry_id
    entry_id=$(kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
      /opt/spire/bin/spire-server entry show -spiffeID "$SPIFFE_ID" 2>/dev/null \
      | grep "Entry ID" | awk '{print $NF}') || true
    if [ -n "$entry_id" ]; then
      kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
        /opt/spire/bin/spire-server entry delete -entryID "$entry_id" >/dev/null 2>&1 || true
    fi
  fi

  # Verify clean
  log "verifying teardown..."
  kubectl -n "$NAMESPACE_INFRA" get deployment cardvault 2>/dev/null && fail "cardvault still exists after teardown"
  kubectl -n "$NAMESPACE_INFRA" get deployment policy-engine 2>/dev/null && fail "policy-engine still exists after teardown"
  resolve_agent_pod_namespace \
    && fail "agent pod still exists in $AGENT_POD_NAMESPACE after teardown"

  ok "step 5 complete — teardown verified"
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

run_all() {
  log "running full demo cycle (steps 1→5)"
  demo_1
  demo_2
  demo_3
  demo_4
  demo_5
  ok "full demo cycle complete"
}

case "${1:-}" in
  1) demo_1 ;;
  2) demo_2 ;;
  3) demo_3 ;;
  4) demo_4 ;;
  5) demo_5 ;;
  all) run_all ;;
  *)
    echo "Usage: $0 {1|2|3|4|5|all}" >&2
    echo ""
    echo "  1    Deploy services, agent, OpenBao secrets, SPIRE entry"
    echo "  2    Run SPIFFE → OpenBao → cardvault credential chain"
    echo "  3    Compliance scan — discovers missing securityContext"
    echo "  4    Stun: revoke credentials, verify denial"
    echo "  5    Teardown + verify clean"
    echo "  all  Run 1→5 sequentially"
    exit 1
    ;;
esac
