#!/usr/bin/env bash
# doctor.sh — Cluster health check for the OSRAMP demo environment.
# Reports on: SignalLoom, Olly, OSRAMP apps, infrastructure, Flux state.
# Exit code: 0 = healthy, 1 = issues found.

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ISSUES=0

header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $1"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; ISSUES=$((ISSUES + 1)); }
fail()   { echo -e "  ${RED}✗${NC} $1"; ISSUES=$((ISSUES + 1)); }

check_namespace() {
  local ns="$1"
  local label="$2"
  if kubectl get namespace "${ns}" &>/dev/null; then
    ok "${label} namespace exists"
    return 0
  else
    fail "${label} namespace MISSING"
    return 1
  fi
}

check_pods() {
  local ns="$1"
  local label="$2"
  local total running problem

  if ! kubectl get namespace "${ns}" &>/dev/null; then
    return
  fi

  total=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l)
  running=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep -cE 'Running|Completed' || true)
  problem=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep -vcE 'Running|Completed' || true)

  if [ "${problem}" -eq 0 ]; then
    ok "${label}: ${running}/${total} pods healthy"
  else
    warn "${label}: ${problem}/${total} pods unhealthy"
    kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep -vE 'Running|Completed' | \
      awk '{printf "      %-45s %s\n", $1, $3}'
  fi
}

check_kustomizations() {
  local ns="$1"
  local label="$2"

  if ! kubectl get namespace "${ns}" &>/dev/null; then
    return
  fi

  local not_ready
  not_ready=$(kubectl get kustomizations -n "${ns}" --no-headers 2>/dev/null | grep -v "True" | wc -l || true)
  local total
  total=$(kubectl get kustomizations -n "${ns}" --no-headers 2>/dev/null | wc -l || true)

  if [ "${total}" -eq 0 ]; then
    return
  fi

  if [ "${not_ready}" -eq 0 ]; then
    ok "${label}: ${total} kustomization(s) Ready"
  else
    warn "${label}: ${not_ready}/${total} kustomization(s) not Ready"
    kubectl get kustomizations -n "${ns}" --no-headers 2>/dev/null | grep -v "True" | \
      awk '{printf "      %-20s %s\n", $1, $NF}'
  fi
}

check_resourcesets() {
  local not_ready
  not_ready=$(kubectl get resourcesets -A --no-headers 2>/dev/null | grep -v "True" | wc -l || true)
  local total
  total=$(kubectl get resourcesets -A --no-headers 2>/dev/null | wc -l || true)

  if [ "${not_ready}" -eq 0 ]; then
    ok "All ${total} ResourceSets reconciled"
  else
    warn "${not_ready}/${total} ResourceSets not Ready"
    kubectl get resourcesets -A --no-headers 2>/dev/null | grep -v "True" | \
      awk '{printf "      %-15s %-25s %s\n", $1, $2, $NF}'
  fi
}

# The expected set is derived from what the cluster actually references, not
# from a list kept here. This used to be a seven-element constant of OSRAMP and
# Olly images; the signalloom-only path never builds any of them, so it reported
# "7 image(s) missing" on every run that path made, pass or fail, and named
# none of them. See scripts/check-node-images.sh for the full account.
check_images_loaded() {
  local out rc=0
  out="$("$(dirname "$0")/check-node-images.sh" 2>&1)" || rc=$?
  # Line 1 is the headline; anything after it names an image and the workload
  # waiting on it.
  if [ "${rc}" -eq 0 ]; then
    ok "${out%%$'\n'*}"
  else
    warn "${out%%$'\n'*}"
    printf '%s\n' "${out}" | tail -n +2 | sed 's/^/      /'
  fi
}

# ═══════════════════════════════════════════════════════════════
echo -e "${BOLD}OSRAMP Demo — Cluster Doctor${NC}"
echo -e "Cluster: $(kubectl config current-context 2>/dev/null || echo 'UNKNOWN')"
echo -e "Time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ─── Cluster basics ───
header "CLUSTER"
if kubectl get nodes &>/dev/null; then
  ok "API server reachable"
else
  fail "Cannot reach API server"
  echo -e "\n${RED}FATAL: cluster unreachable. Exiting.${NC}"
  exit 1
fi

NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
if echo "${NODE_STATUS}" | grep -qv "Ready"; then
  fail "Node(s) not Ready"
else
  ok "All nodes Ready"
fi

# ─── Images ───
header "IMAGES"
check_images_loaded

# ─── Flux system ───
header "FLUX"
check_pods "flux-system" "Flux controllers"
check_resourcesets

# ─── Infrastructure ───
header "INFRASTRUCTURE"
for ns_label in "cert-manager:Cert Manager" "inf-bao:OpenBao/SPIRE" "ingress:Ingress (Envoy)" \
  "monitoring:Monitoring" "registry:Registry (Zot)" "trivy-system:Trivy"; do
  ns="${ns_label%%:*}"
  label="${ns_label##*:}"
  check_namespace "${ns}" "${label}" && check_pods "${ns}" "${label}"
done

# ─── SignalLoom ───
header "SIGNALLOOM"
check_namespace "inf-signalloom" "SignalLoom infra" && check_pods "inf-signalloom" "SignalLoom infra"
check_namespace "fe-signalloom" "SignalLoom frontend" && check_pods "fe-signalloom" "SignalLoom frontend"
check_kustomizations "fe-signalloom" "SignalLoom frontend"

# Check SignalLoom-specific components
if kubectl get namespace "fe-signalloom" &>/dev/null; then
  # Check the main deployment
  if kubectl get deploy fe-signalloom -n fe-signalloom &>/dev/null; then
    READY=$(kubectl get deploy fe-signalloom -n fe-signalloom -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ "${READY:-0}" -gt 0 ]; then
      ok "fe-signalloom deployment: ${READY} replica(s) ready"
    else
      warn "fe-signalloom deployment: 0 replicas ready"
    fi
  fi
  # Check bao-spire proof jobs
  POS=$(kubectl get job -n fe-signalloom -l role=bao-spire-positive-proof -o jsonpath='{.items[0].status.succeeded}' 2>/dev/null || true)
  NEG=$(kubectl get job -n fe-signalloom -l role=bao-spire-negative-proof -o jsonpath='{.items[0].status.succeeded}' 2>/dev/null || true)
  if [ "${POS:-0}" -gt 0 ] && [ "${NEG:-0}" -gt 0 ]; then
    ok "bao-spire proof jobs: both succeeded"
  else
    warn "bao-spire proof jobs: positive=${POS:-pending} negative=${NEG:-pending}"
  fi
fi

# ─── Olly Sentinel ───
header "OLLY SENTINEL"
check_namespace "olly-replica" "Olly" && check_pods "olly-replica" "Olly"
check_kustomizations "olly-replica" "Olly"

# Check key Olly services
if kubectl get namespace "olly-replica" &>/dev/null; then
  if kubectl get pods -n olly-replica -l app=olly-sentinel --no-headers 2>/dev/null | grep -q Running; then
    ok "olly-sentinel: running"
  else
    warn "olly-sentinel: not running"
  fi
  if kubectl get pods -n olly-replica -l app.kubernetes.io/name=redpanda --no-headers 2>/dev/null | grep -q Running; then
    ok "redpanda: running"
  else
    warn "redpanda: not running"
  fi
  if kubectl get pods -n olly-replica -l common.k8s.elastic.co/type=elasticsearch --no-headers 2>/dev/null | grep -q Running; then
    ok "elasticsearch: running"
  else
    warn "elasticsearch: not running"
  fi
fi

# ─── OSRAMP Apps ───
header "OSRAMP APPS"
check_namespace "frontend" "Frontend" && check_pods "frontend" "Frontend"
check_namespace "backend" "Backend" && check_pods "backend" "Backend"
check_kustomizations "frontend" "Frontend"
check_kustomizations "backend" "Backend"

# Check key OSRAMP services
if kubectl get namespace "backend" &>/dev/null; then
  for svc in postgres nats minio osramp-archivista; do
    if kubectl get pods -n backend -l app="${svc}" --no-headers 2>/dev/null | grep -q Running; then
      ok "backend/${svc}: running"
    elif kubectl get pods -n backend --no-headers 2>/dev/null | grep -q "${svc}.*Running"; then
      ok "backend/${svc}: running"
    else
      warn "backend/${svc}: not running"
    fi
  done
fi

if kubectl get namespace "frontend" &>/dev/null; then
  for deploy in osramp-purl osramp-archiver osramp-multipurpose; do
    READY=$(kubectl get deploy "${deploy}" -n frontend -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ "${READY:-0}" -gt 0 ]; then
      ok "frontend/${deploy}: ${READY} replica(s)"
    else
      warn "frontend/${deploy}: 0 replicas ready"
    fi
  done
fi

# ─── Summary ───
header "SUMMARY"
# ── Are the backends the dashboard proxies to actually deployed? ────────────
#
# Twice a complete slice sat in the repo undeployed (fleet-manager, afm-platform)
# and the failure reached a human as a JSON parse error or a raw errno rather
# than "not deployed". doctor is where an engineer looks FIRST, so it is where
# a missing backend belongs.
echo -e "\n${CYAN}━━━ DASHBOARD BACKENDS ━━━${NC}"
if ! "$(dirname "$0")/check-backends.sh" live 2>&1 | sed 's/^/  /'; then
  ISSUES=$(( ISSUES + 1 ))
fi

if [ "${ISSUES}" -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}All checks passed.${NC} Cluster is demo-ready."
else
  echo -e "  ${YELLOW}${BOLD}${ISSUES} issue(s) found.${NC} See above for details."
fi

exit $(( ISSUES > 0 ? 1 : 0 ))
