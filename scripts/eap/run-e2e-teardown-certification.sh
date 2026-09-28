#!/usr/bin/env bash
# ==============================================================================
# SLRC-P4-1: Attributed end-to-end teardown and mid-stage failure recovery driver.
#
# Proves all destructive postconditions and failure recovery mechanics against
# an isolated disposable fixture in Kind cluster:
#   1. Ingress route removal before workload deletion.
#   2. Attributed disposable mesh node eviction.
#   3. OpenBao key shredding with 404 verification and decrypt failure.
#   4. SPIRE workload deregistration and entry count decrease.
#   5. Namespace and storage deletion after prior checkpoints succeed.
#   6. Zero persistent storage leaks.
#   7. Mid-stage failure injection and resumption from incomplete checkpoint.
#   8. Evidence validator acceptance of clean proof and rejection of tampered proof.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_SRC="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src"
EVIDENCE_FILE="${REPO_ROOT}/docs/signalloom/evidence/slrc-p4-e2e-evidence.json"
PORT_FORWARD_PID=""

log() { printf '[slrc-p4-1] %s\n' "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

cleanup() {
  local status=$?
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  # Clean up any orphaned background port-forwards
  pgrep -f "port-forward.*openbao 18200:8200" | grep -v 'claude\|snapshot-bash\|grep' | xargs -r kill -9 >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT INT TERM

# 1. Pre-flight checks
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"

# 2. Check Kind Cluster
kubectl cluster-info >/dev/null 2>&1 || die "Kubernetes cluster not reachable"
kubectl get ns inf-bao >/dev/null 2>&1 || die "Namespace inf-bao not found in cluster"

# 3. Setup OpenBao Port-Forward on loopback port 18200
log "setting up OpenBao port-forward on 127.0.0.1:18200"
setsid kubectl port-forward -n inf-bao svc/openbao 18200:8200 </dev/null >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait for OpenBao port-forward to become ready
READY=0
for i in {1..20}; do
  if curl -s --max-time 1 http://127.0.0.1:18200/v1/sys/health >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.5
done
[[ "${READY}" -eq 1 ]] || die "OpenBao port-forward failed to become ready on 127.0.0.1:18200"

# 4. Execute End-to-End Teardown Certification Scenario
log "executing Python end-to-end certification orchestrator"
export PYTHONPATH="${APP_SRC}:${SCRIPT_DIR}:${PYTHONPATH:-}"
export SIGNALLOOM_TEARDOWN_OPENBAO_PORT="18200"

python3 "${SCRIPT_DIR}/e2e_teardown_certifier.py" || die "End-to-end certification execution failed"

# 5. Execute Evidence Validator Verification
log "verifying generated evidence bundle with verify_teardown_evidence.py"
python3 "${SCRIPT_DIR}/verify_teardown_evidence.py" --evidence-file "${EVIDENCE_FILE}" || die "Evidence verification failed"

log "ALL CERTIFICATION GATES PASSED (100% SUCCESS)"
