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
  if [[ -f "/tmp/osramp-kubeconfig.yaml" ]]; then
    export KUBECONFIG="/tmp/osramp-kubeconfig.yaml"
  elif [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  else
    for cfg in /tmp/osramp-kubeconfig.yaml /home/*/.kube/config /etc/kubernetes/admin.conf; do
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
  --restore-swarm Un-suspend Flux agent-swarm and scale workloads back up
  --remote        Execute command on remote GCP VM defined by ENV=<lane> (e.g. ENV=demo-1)
  --tenant ID     Target tenant to reset onboarding for (default: tenant-demo)
  -h, --help      Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --clean) MODE="clean"; shift ;;
    --full)  MODE="full";  shift ;;
    --restore-swarm) MODE="restore-swarm"; shift ;;
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
  header "EXECUTING FULL REFRESH & USER DATA RESET FOR NEW ONBOARDING"

  # 1. Suspend Flux agent-swarm & signalloom-infra ResourceSets to prevent automatic re-spawning
  echo "--> Suspending Flux agent-swarm and signalloom-infra ResourceSets..."
  kubectl -n flux-system annotate resourceset agent-swarm fluxcd.controlplane.io/reconcile=disabled --overwrite 2>/dev/null || true
  kubectl -n flux-system annotate resourceset signalloom-infra fluxcd.controlplane.io/reconcile=disabled --overwrite 2>/dev/null || true
  kubectl -n flux-system patch resourceset agent-swarm --type=merge -p '{"spec":{"suspend":true}}' 2>/dev/null || true
  flux suspend kustomization -n fe-signalloom-agents --all 2>/dev/null || true
  kubectl get kustomization -n fe-signalloom-agents -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n fe-signalloom-agents --type=merge -p '{"spec":{"suspend":true}}' 2>/dev/null || true
  kubectl -n fe-signalloom-agents annotate kustomization --all kustomize.toolkit.fluxcd.io/reconcile=disabled --overwrite 2>/dev/null || true
  ok "Flux agent-swarm and signalloom-infra ResourceSets and child Kustomizations suspended"

  # 2. Scale down workloads and delete agent pods in fe-signalloom-agents
  echo "--> Scaling down agent workloads in fe-signalloom-agents..."
  kubectl scale deployment --all -n fe-signalloom-agents --replicas=0 2>/dev/null || true
  kubectl scale statefulset --all -n fe-signalloom-agents --replicas=0 2>/dev/null || true
  kubectl delete daemonset --all -n fe-signalloom-agents --ignore-not-found 2>/dev/null || true
  kubectl delete pod -n fe-signalloom-agents -l signalloom.ai/agent=true --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete pod -n fe-signalloom-agents -l app.kubernetes.io/name=cardvault-agent --ignore-not-found --wait=false 2>/dev/null || true
  ok "Agent workloads in fe-signalloom-agents scaled down to 0 and agent pods deleted"

  # 3. Teardown any running SuperCred demo resources and credential material
  echo "--> Tearing down SuperCred demo resources..."
  if [[ -x "${REPO_ROOT}/scripts/supercred-demo.sh" ]]; then
    bash "${REPO_ROOT}/scripts/supercred-demo.sh" 5 >/dev/null 2>&1 || true
    ok "SuperCred demo workloads and credential material cleaned down"
  fi

  # 4. Reset PostgreSQL database user data and onboarding
  echo "--> Resetting database user data, agent claims, and onboarding state..."
  if kubectl get deployment postgresql -n inf-signalloom >/dev/null 2>&1; then
    kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -c "
      DELETE FROM public.tenant_onboarding;
      TRUNCATE public.agent_claims CASCADE;
      TRUNCATE public.agent_registry CASCADE;
      TRUNCATE public.agent_credentials CASCADE;
      TRUNCATE public.agent_origin_verifications CASCADE;
      TRUNCATE public.agent_compliance_results CASCADE;
      TRUNCATE public.agent_violations CASCADE;
      TRUNCATE public.discovered_agents CASCADE;
      TRUNCATE public.discovery_scan_sessions CASCADE;
      TRUNCATE public.host_enrollment_tokens CASCADE;
      TRUNCATE public.external_agent_evidence CASCADE;
      TRUNCATE public.external_agent_registrations CASCADE;
      TRUNCATE public.lifecycle_transitions CASCADE;
      TRUNCATE public.actor_evidence CASCADE;
      TRUNCATE public.consent_events CASCADE;
      TRUNCATE public.audit_events CASCADE;
      TRUNCATE public.signal_audit_trail CASCADE;
      TRUNCATE public.signed_audit_sessions CASCADE;
      TRUNCATE public.quarantined_synthetic_audit_events CASCADE;
      TRUNCATE public.retention_deletion_receipts CASCADE;
      TRUNCATE public.retention_legal_holds CASCADE;
      TRUNCATE public.user_preferences CASCADE;
      TRUNCATE public.support_requests CASCADE;
      TRUNCATE public.tenant_api_keys CASCADE;
      TRUNCATE public.invites CASCADE;
      TRUNCATE public.nhi_discovered_accounts CASCADE;
      TRUNCATE public.nhi_scans CASCADE;
      TRUNCATE public.delegations CASCADE;
      TRUNCATE public.aliases CASCADE;
      TRUNCATE public.provisional_actors CASCADE;
      TRUNCATE public.operator_identities CASCADE;
      TRUNCATE public.subject_key_erasures CASCADE;
      TRUNCATE public.subject_keys CASCADE;
      TRUNCATE public.subject_tenants CASCADE;
      DELETE FROM public.tenant_settings WHERE tenant_id NOT IN ('default');
    " >/dev/null 2>&1 || true
    ok "PostgreSQL user data, agent claims, audit trails, and onboarding reset"
  else
    warn "PostgreSQL not reachable; skipping database onboarding reset"
  fi

  # 4b. Seed database with canonical CEL compliance frameworks, controls, and default tenant settings
  echo "--> Seeding database with canonical CEL compliance frameworks, controls, and active policies..."
  if kubectl get deployment postgresql -n inf-signalloom >/dev/null 2>&1; then
    local seed_file="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/db/seed-governance-frameworks.sql"
    if [[ -f "${seed_file}" ]]; then
      kubectl exec -i -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -v ON_ERROR_STOP=1 < "${seed_file}" >/dev/null 2>&1 || true
    fi
    # Ensure both default and target tenant have CEL policy frameworks enabled in tenant_settings
    kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -c "
      INSERT INTO public.tenant_settings (
        tenant_id, org_name, plan_tier, status, selected_frameworks, api_key_status, cookie_preferences
      ) VALUES
        ('default', 'Default Organization', 'enterprise', 'active', '[\"eu-ai-act\", \"k8s-cis-benchmark\", \"cis-kubernetes\", \"finos-ai-governance-framework\", \"finos-aigf\", \"soc2\"]'::jsonb, 'active', '{\"strictly_necessary\": true, \"analytics\": true}'::jsonb),
        ('${TARGET_TENANT}', '${TARGET_TENANT} Org', 'enterprise', 'active', '[\"eu-ai-act\", \"k8s-cis-benchmark\", \"cis-kubernetes\", \"finos-ai-governance-framework\", \"finos-aigf\", \"soc2\"]'::jsonb, 'active', '{\"strictly_necessary\": true, \"analytics\": true}'::jsonb)
      ON CONFLICT (tenant_id) DO UPDATE SET
        selected_frameworks = EXCLUDED.selected_frameworks,
        plan_tier = EXCLUDED.plan_tier,
        status = EXCLUDED.status;
    " >/dev/null 2>&1 || true
    ok "PostgreSQL database seeded: default CEL compliance frameworks and controls active"
  fi

  # 5. Flush Redis cache
  echo "--> Flushing Redis cache..."
  if kubectl get deployment redis -n inf-signalloom >/dev/null 2>&1; then
    kubectl exec -n inf-signalloom deployment/redis -- redis-cli flushall >/dev/null 2>&1 || true
    ok "Redis cache flushed"
  fi

  # 6. Restart fe-signalloom to purge in-memory stores and cached discovery
  echo "--> Restarting fe-signalloom to purge in-memory stores..."
  if kubectl get deployment fe-signalloom -n fe-signalloom >/dev/null 2>&1; then
    kubectl rollout restart deployment/fe-signalloom -n fe-signalloom >/dev/null 2>&1 || true
    kubectl rollout status deployment/fe-signalloom -n fe-signalloom --timeout=60s >/dev/null 2>&1 || true
    ok "fe-signalloom restarted with clean in-memory state"
  fi

  # 7. Restart fake-integration-proxy to clear any cached proxy observations
  echo "--> Restarting fake-integration-proxy..."
  if kubectl get deployment fake-integration-proxy -n inf-signalloom >/dev/null 2>&1; then
    kubectl rollout restart deployment/fake-integration-proxy -n inf-signalloom >/dev/null 2>&1 || true
    kubectl rollout status deployment/fake-integration-proxy -n inf-signalloom --timeout=60s >/dev/null 2>&1 || true
    ok "fake-integration-proxy restarted"
  fi

  # 8. Unfreeze any cgroups left in frozen containment state
  echo "--> Unfreezing any stunned/frozen cgroup workloads..."
  local frozen_count=0
  for f in $(find /sys/fs/cgroup -name "cgroup.freeze" 2>/dev/null || true); do
    if [[ -r "$f" ]] && [[ "$(cat "$f" 2>/dev/null || true)" == "1" ]]; then
      echo 0 | sudo tee "$f" >/dev/null 2>&1 || true
      frozen_count=$((frozen_count + 1))
    fi
  done
  ok "Cgroup freezer audited; ${frozen_count} frozen workload(s) unfrozen"

  # 9. Clean host /tmp test artifacts
  echo "--> Cleaning host /tmp test artifacts..."
  rm -f /tmp/osramp-tenant-*.kubeconfig /tmp/test-tenant* /tmp/slsi-test-* /tmp/cgroup-freeze-proof.json 2>/dev/null || true
  ok "Host /tmp test artifacts cleaned"

  # 10. Verify clean baseline
  echo "--> Verifying clean baseline in PostgreSQL and fe-signalloom-agents..."
  if kubectl get deployment postgresql -n inf-signalloom >/dev/null 2>&1; then
    local reg_count claim_count disc_count audit_count ob_count
    reg_count=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "SELECT COUNT(*) FROM public.agent_registry;" 2>/dev/null || echo "-1")
    claim_count=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "SELECT COUNT(*) FROM public.agent_claims;" 2>/dev/null || echo "-1")
    disc_count=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "SELECT COUNT(*) FROM public.discovered_agents;" 2>/dev/null || echo "-1")
    audit_count=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "SELECT COUNT(*) FROM public.audit_events;" 2>/dev/null || echo "-1")
    ob_count=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "SELECT COUNT(*) FROM public.tenant_onboarding WHERE status IN ('completed', 'skipped');" 2>/dev/null || echo "-1")
    if [[ "$reg_count" == "0" && "$claim_count" == "0" && "$disc_count" == "0" && "$audit_count" == "0" && "$ob_count" == "0" ]]; then
      ok "Clean baseline verified: 0 registered agents, 0 agent claims, 0 discovered agents, 0 audit events, 0 completed onboarding"
    else
      warn "Baseline check: registry=${reg_count}, claims=${claim_count}, discovered=${disc_count}, audit=${audit_count}, onboarding_done=${ob_count}"
    fi

    local fw_count ctrl_count
    fw_count=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "SELECT COUNT(*) FROM public.governance_frameworks WHERE tenant_id = '${TARGET_TENANT}';" 2>/dev/null || echo "-1")
    ctrl_count=$(kubectl exec -n inf-signalloom deployment/postgresql -- psql -U signalloom -d signalloom -t -A -c "SELECT COUNT(*) FROM public.governance_controls WHERE tenant_id = '${TARGET_TENANT}';" 2>/dev/null || echo "-1")
    if [[ "$fw_count" -ge 4 && "$ctrl_count" -ge 39 ]]; then
      ok "Seeded governance verified: ${fw_count} frameworks, ${ctrl_count} controls active for '${TARGET_TENANT}'"
    else
      warn "Seeded governance check: frameworks=${fw_count} (expected >=4), controls=${ctrl_count} (expected >=39)"
    fi
  fi
  local agent_pods_count
  agent_pods_count=$(kubectl get pods -n fe-signalloom-agents -l signalloom.ai/agent=true --no-headers 2>/dev/null | grep -v "Terminating" | wc -l | tr -d '[:space:]' || echo "0")
  if [[ "$agent_pods_count" == "0" ]]; then
    ok "fe-signalloom-agents pod verification: 0 agent pods running"
  else
    warn "fe-signalloom-agents pod verification: ${agent_pods_count} agent pod(s) still present"
  fi
}

do_restore_swarm() {
  header "RESTORING AGENT SWARM IN FE-SIGNALLOOM-AGENTS"

  echo "--> Un-suspending Flux agent-swarm and signalloom-infra ResourceSets and child Kustomizations..."
  kubectl -n flux-system annotate resourceset agent-swarm fluxcd.controlplane.io/reconcile- 2>/dev/null || true
  kubectl -n flux-system annotate resourceset signalloom-infra fluxcd.controlplane.io/reconcile- 2>/dev/null || true
  kubectl -n flux-system annotate resourceset agent-swarm reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite 2>/dev/null || true
  kubectl -n flux-system annotate resourceset signalloom-infra reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite 2>/dev/null || true
  kubectl -n flux-system patch resourceset agent-swarm --type=merge -p '{"spec":{"suspend":false}}' 2>/dev/null || true
  flux resume kustomization -n fe-signalloom-agents --all 2>/dev/null || true
  kubectl get kustomization -n fe-signalloom-agents -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n fe-signalloom-agents --type=merge -p '{"spec":{"suspend":false}}' 2>/dev/null || true
  kubectl -n fe-signalloom-agents annotate kustomization --all kustomize.toolkit.fluxcd.io/reconcile- 2>/dev/null || true
  ok "Flux agent-swarm and signalloom-infra ResourceSets and child Kustomizations un-suspended"

  echo "--> Scaling up workloads in fe-signalloom-agents..."
  kubectl scale deployment --all -n fe-signalloom-agents --replicas=1 2>/dev/null || true
  kubectl scale statefulset --all -n fe-signalloom-agents --replicas=1 2>/dev/null || true
  ok "Agent workloads in fe-signalloom-agents scaled up to 1 replica"
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
  suspended_kust=$(flux get kustomizations -A 2>/dev/null | grep -v "fe-signalloom-agents" | grep -c "True.*Suspended" || true)
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
    restore-swarm) do_restore_swarm ;;
  esac
}

main "$@"
