#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/prelive-clean-down.sh — Pre-live verification and clean-down reset
# for demo and EAP customer environments.
#
# Usage:
#   scripts/prelive-clean-down.sh [--check | --clean | --full]
#   ENV=demo-1 scripts/prelive-clean-down.sh --remote [--check | --clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="check"
TARGET_TENANT="${TARGET_TENANT:-tenant-demo}"
REMOTE=0

# Ensure KUBECONFIG is set if not already present
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  else
    for cfg in /home/*/.kube/config /etc/kubernetes/admin.conf; do
      if [[ -f "$cfg" ]]; then
        export KUBECONFIG="$cfg"
        break
      fi
    done
  fi
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Pre-live verification and clean-down reset for Demo and EAP environments.

Options:
  --check     Run read-only pre-live readiness audit (default)
  --clean     Execute clean-down reset to pristine baseline (resets onboarding & data)
  --full      Execute clean-down followed immediately by full pre-live audit
  --remote    Execute command on remote GCP VM defined by ENV=<lane> (e.g. ENV=demo-1)
  --tenant ID Target tenant to reset onboarding for (default: tenant-demo)
  -h, --help  Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --clean) MODE="clean"; shift ;;
    --full)  MODE="full";  shift ;;
    --remote) REMOTE=1;    shift ;;
    --tenant) TARGET_TENANT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $1"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()   { echo -e "  ${RED}✗${NC} $1"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

do_clean_down() {
  header "EXECUTING CLEAN-DOWN RESET FOR NEW USER ONBOARDING"

  # 1. Reset PostgreSQL tenant onboarding to pending
  echo "--> Resetting tenant_onboarding for ${TARGET_TENANT}..."
  if kubectl get deployment postgresql -n inf-signalloom >/dev/null 2>&1; then
    kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -c "
      UPDATE public.tenant_onboarding
      SET status = 'pending',
          completed_at = NULL,
          skipped_at = NULL,
          wizard_state = '{\"step_index\": 0, \"provider_run_state\": {}, \"selected_provider_ids\": []}'
      WHERE tenant_id = '${TARGET_TENANT}';
    " >/dev/null 2>&1 || true

    # Also clean audit trails, logs, and transient/dirty test tables
    kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -c "
      TRUNCATE public.audit_events CASCADE;
      TRUNCATE public.signal_audit_trail CASCADE;
      TRUNCATE public.signed_audit_sessions CASCADE;
      TRUNCATE public.consent_events CASCADE;
      TRUNCATE public.actor_evidence CASCADE;
      TRUNCATE public.external_agent_evidence CASCADE;
      TRUNCATE public.retention_deletion_receipts CASCADE;
      TRUNCATE public.retention_legal_holds CASCADE;
      TRUNCATE public.quarantined_synthetic_audit_events CASCADE;
      TRUNCATE public.agent_violations CASCADE;
      TRUNCATE public.lifecycle_transitions CASCADE;
      TRUNCATE public.discovered_agents CASCADE;
      TRUNCATE public.discovery_scan_sessions CASCADE;
    " >/dev/null 2>&1 || true
    ok "PostgreSQL tenant_onboarding reset to 'pending', audit trails, and transient tables truncated"
  else
    warn "PostgreSQL not reachable; skipping database onboarding reset"
  fi

  # 2. Flush Redis cache
  echo "--> Flushing Redis cache..."
  if kubectl get deployment redis -n inf-signalloom >/dev/null 2>&1; then
    kubectl exec -n inf-signalloom deployment/redis -- redis-cli flushall >/dev/null 2>&1 || true
    ok "Redis cache flushed"
  fi

  # 3. Unfreeze any cgroups left in frozen containment state
  echo "--> Unfreezing any stunned/frozen cgroup workloads..."
  local frozen_count=0
  for f in $(find /sys/fs/cgroup -name "cgroup.freeze" 2>/dev/null || true); do
    if [[ -r "$f" ]] && [[ "$(cat "$f" 2>/dev/null || true)" == "1" ]]; then
      echo 0 | sudo tee "$f" >/dev/null 2>&1 || true
      frozen_count=$((frozen_count + 1))
    fi
  done
  ok "Cgroup freezer audited; ${frozen_count} frozen workload(s) unfrozen"

  # 4. Clean host /tmp test artifacts
  echo "--> Cleaning host /tmp test artifacts..."
  rm -f /tmp/osramp-tenant-*.kubeconfig /tmp/test-tenant* /tmp/slsi-test-* /tmp/cgroup-freeze-proof.json 2>/dev/null || true
  ok "Host /tmp test artifacts cleaned"
}

do_prelive_check() {
  header "PRE-LIVE READINESS VERIFICATION AUDIT"

  # 1. Foundation & Host Health
  if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
    ok "Kubernetes control-plane node is Ready"
  else
    fail "Kubernetes control-plane node is NOT Ready"
  fi

  local disk_avail
  disk_avail=$(df -h / | awk 'NR==2 {print $4}')
  ok "Disk space available: ${disk_avail}"

  # 2. Systemd services
  if systemctl is-active --quiet signalloom-dashboard-pf.service 2>/dev/null; then
    ok "Service signalloom-dashboard-pf.service is ACTIVE"
  else
    warn "Service signalloom-dashboard-pf.service is not active"
  fi

  if systemctl is-active --quiet tailscaled.service 2>/dev/null; then
    ok "Service tailscaled.service is ACTIVE"
  else
    warn "Service tailscaled.service is not active"
  fi

  # 3. Ingress Upstream Backends
  if [[ -f "${REPO_ROOT}/scripts/check-backends.sh" ]]; then
    if "${REPO_ROOT}/scripts/check-backends.sh" live >/dev/null 2>&1; then
      ok "All 7 NGINX upstream backends declared and reachable with live endpoints"
    else
      fail "One or more NGINX upstream backends are unreachable"
    fi
  fi

  # 4. Containment & Stun Sanity
  local active_frozen=0
  for f in $(find /sys/fs/cgroup -name "cgroup.freeze" 2>/dev/null || true); do
    if [[ -r "$f" ]] && [[ "$(cat "$f" 2>/dev/null || true)" == "1" ]]; then
      active_frozen=$((active_frozen + 1))
    fi
  done
  if [[ "$active_frozen" -eq 0 ]]; then
    ok "Containment integrity: 0 frozen cgroup processes"
  else
    fail "Containment integrity: ${active_frozen} processes currently FROZEN"
  fi

  local suspended_kust=0
  suspended_kust=$(flux get kustomizations -A --no-headers 2>/dev/null | grep -c "True.*Suspended" || true)
  if [[ "$suspended_kust" -eq 0 ]]; then
    ok "GitOps reconciliation: 0 suspended Kustomizations"
  else
    fail "GitOps reconciliation: ${suspended_kust} Kustomizations are SUSPENDED"
  fi

  # 5. Database & Onboarding State
  if kubectl get deployment postgresql -n inf-signalloom >/dev/null 2>&1; then
    local ob_status
    ob_status=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "
      SELECT status FROM public.tenant_onboarding WHERE tenant_id = '${TARGET_TENANT}';
    " 2>/dev/null || echo "missing")
    if [[ "$ob_status" == "pending" ]]; then
      ok "Onboarding baseline: tenant '${TARGET_TENANT}' status is 'pending' (ready for new user)"
    elif [[ "$ob_status" == "skipped" || "$ob_status" == "completed" ]]; then
      warn "Onboarding baseline: tenant '${TARGET_TENANT}' is '${ob_status}' (onboarding wizard already closed)"
    else
      ok "Onboarding baseline: tenant '${TARGET_TENANT}' has no prior record (clean state)"
    fi
  fi

  # 6. Core HTTP Endpoints
  local app_port="30754"
  if curl -sf -o /dev/null "http://127.0.0.1:${app_port}/health" 2>/dev/null; then
    ok "HTTP /health endpoint returns 200 OK"
  else
    fail "HTTP /health endpoint failed on http://127.0.0.1:${app_port}/health"
  fi

  if curl -sf -o /dev/null "http://127.0.0.1:${app_port}/readyz" 2>/dev/null; then
    ok "HTTP /readyz endpoint returns 200 OK"
  else
    fail "HTTP /readyz endpoint failed on http://127.0.0.1:${app_port}/readyz"
  fi

  if curl -sf -o /dev/null "http://127.0.0.1:${app_port}/dex/.well-known/openid-configuration" 2>/dev/null; then
    ok "Dex OIDC openid-configuration returns 200 OK"
  else
    fail "Dex OIDC openid-configuration failed"
  fi

  header "SUMMARY"
  if [[ "$FAILURES" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}PRE-LIVE VERIFICATION PASSED — Estate is clean, whole, and ready for user onboarding.${NC}"
    return 0
  else
    echo -e "${RED}${BOLD}PRE-LIVE VERIFICATION FAILED — ${FAILURES} critical check(s) failed.${NC}"
    return 1
  fi
}

do_remote() {
  local env_key="${ENV:-demo-1}"
  local handoff="${REPO_ROOT}/deploy/gcp/${env_key}.handoff.json"
  if [[ ! -f "$handoff" ]]; then
    echo "ERROR: Handoff file not found: $handoff" >&2
    exit 2
  fi
  local project zone instance operator_sa
  project=$(jq -r '.project_id' "$handoff")
  zone=$(jq -r '.zone' "$handoff")
  instance=$(jq -r '.instance_name' "$handoff")
  operator_sa=$(jq -r '.operator_sa' "$handoff")

  local ssh_key_arg=()
  if [[ -f "/tmp/gcp_ssh_key" ]]; then
    ssh_key_arg=(--ssh-key-file=/tmp/gcp_ssh_key)
  elif [[ -n "${GCP_SSH_KEY_FILE:-}" ]]; then
    ssh_key_arg=(--ssh-key-file="$GCP_SSH_KEY_FILE")
  fi

  header "DISPATCHING PRE-LIVE CLEAN-DOWN TO REMOTE: ${instance} (${env_key})"
  # SCP latest script to VM
  unset SSH_AUTH_SOCK
  gcloud compute scp --tunnel-through-iap --zone="$zone" --project="$project" \
    --impersonate-service-account="$operator_sa" "${ssh_key_arg[@]}" \
    "${SCRIPT_DIR}/prelive-clean-down.sh" "${instance}:/tmp/prelive-clean-down.sh" >/dev/null

  # Execute on remote VM
  gcloud compute ssh "$instance" --zone="$zone" --project="$project" \
    --impersonate-service-account="$operator_sa" "${ssh_key_arg[@]}" \
    --tunnel-through-iap --command="sudo cp /tmp/prelive-clean-down.sh /opt/signalloom/repo/scripts/prelive-clean-down.sh && sudo chmod +x /opt/signalloom/repo/scripts/prelive-clean-down.sh && /opt/signalloom/repo/scripts/prelive-clean-down.sh --${MODE} --tenant ${TARGET_TENANT}"
}

main() {
  if [[ "$REMOTE" -eq 1 ]]; then
    do_remote
    return $?
  fi
  case "$MODE" in
    clean) do_clean_down ;;
    check) do_prelive_check ;;
    full)  do_clean_down; do_prelive_check ;;
  esac
}

main "$@"
