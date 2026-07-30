#!/usr/bin/env bash
# gcp-ci.sh — Persistent GCP VM CI for Signalloom D2 e2e tests.
#
# Manages a persistent n2-standard-16 in europe-west2 that suspends after
# each successful run. The VM, VPC, and networking are created once and
# reused across runs. GitHub Actions (or local CLI) resumes the VM, SSHes
# in via IAP, runs the pipeline, collects the OpenReports report, and
# suspends the VM on success (leaves it running on failure for debugging).
#
# Subcommands:
#   provision    — One-time: create VPC, NAT, firewall, SA, VM (idempotent)
#   run          — Resume VM, SSH in, run pipeline, collect report, suspend on pass
#   ssh          — Open an interactive IAP SSH session for debugging
#   destroy      — Tear down VM + networking (use only when decommissioning)
#   status       — Show VM state (RUNNING / SUSPENDED / TERMINATED / not found)
#
# Exit codes:
#   0 — all tests passed (VM suspended)
#   1 — one or more tests failed (VM left running for debugging)
#   2 — infrastructure error or timeout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Configuration ────────────────────────────────────────────────────
readonly PROJECT="${GCP_CI_PROJECT:-cp-dev-ajm}"
readonly REGION="europe-west2"
readonly ZONE="europe-west2-a"
readonly VM_NAME="signalloom-ci"
readonly VPC_NAME="signalloom-ci"
readonly SUBNET_NAME="signalloom-ci-subnet"
readonly ROUTER_NAME="${VPC_NAME}-router"
readonly NAT_NAME="${VPC_NAME}-nat"
readonly SA_NAME="signalloom-ci-vm"
readonly SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
readonly MACHINE_TYPE="${GCP_CI_MACHINE_TYPE:-n2-standard-16}"
readonly BOOT_DISK_SIZE="200GB"
readonly IMAGE_FAMILY="ubuntu-2404-lts-amd64"
readonly IMAGE_PROJECT="ubuntu-os-cloud"
readonly SECRET_NAME="signalloom-deploy-key"
readonly TIMEOUT_MINUTES="${CI_TIMEOUT_MINUTES:-90}"
readonly REPORT_DIR="${CI_REPORT_DIR:-${REPO_ROOT}/ci-reports}"
readonly REMOTE_REPORT_DIR="/home/ci/reports"
readonly REMOTE_WORK_DIR="/home/ci/osramp-demo"

# ── Helpers ──────────────────────────────────────────────────────────
vm_status() {
  gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --format='get(status)' 2>/dev/null || echo "NOT_FOUND"
}

iap_ssh() {
  gcloud compute ssh "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --tunnel-through-iap \
    --command="$1"
}

iap_ssh_interactive() {
  gcloud compute ssh "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --tunnel-through-iap
}

iap_scp() {
  gcloud compute scp --tunnel-through-iap \
    --zone="$ZONE" --project="$PROJECT" --recurse \
    "$@"
}

# ── Push code via SCP (for local runs without deploy key) ────────────
push_code() {
  echo "==> Pushing repo to VM via SCP..."

  local tarball="/tmp/osramp-demo-ci.tar.gz"
  tar -C "$REPO_ROOT" \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.cache' \
    --exclude='ci-reports' \
    -czf "$tarball" .

  iap_scp "$tarball" "${VM_NAME}:/tmp/osramp-demo-ci.tar.gz"
  iap_ssh "sudo mkdir -p ${REMOTE_WORK_DIR} && \
    sudo tar -xzf /tmp/osramp-demo-ci.tar.gz -C ${REMOTE_WORK_DIR} && \
    sudo chown -R ci:ci ${REMOTE_WORK_DIR} && \
    rm /tmp/osramp-demo-ci.tar.gz"

  rm -f "$tarball"
  echo "==> Code pushed to ${REMOTE_WORK_DIR}"
}

# ── Provision (idempotent — safe to run multiple times) ──────────────
cmd_provision() {
  echo "════════════════════════════════════════════════════════════"
  echo "  Signalloom D2 CI — Provisioning persistent VM"
  echo "  Project:  ${PROJECT}"
  echo "  Region:   ${REGION}"
  echo "  Machine:  ${MACHINE_TYPE}"
  echo "════════════════════════════════════════════════════════════"

  # ── Service account ──
  echo "==> Ensuring service account: ${SA_NAME}"
  if ! gcloud iam service-accounts describe "$SA_EMAIL" \
    --project="$PROJECT" &>/dev/null; then
    gcloud iam service-accounts create "$SA_NAME" \
      --project="$PROJECT" \
      --display-name="SignalLoom CI VM (persistent, minimal API access)"
  fi

  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --condition="expression=resource.name.startsWith('projects/${PROJECT}/secrets/${SECRET_NAME}'),title=signalloom-deploy-key-only" \
    --quiet >/dev/null 2>&1 || true

  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/logging.logWriter" \
    --quiet >/dev/null 2>&1 || true

  # ── VPC + subnet ──
  if ! gcloud compute networks describe "$VPC_NAME" --project="$PROJECT" &>/dev/null; then
    echo "==> Creating VPC: ${VPC_NAME}"
    gcloud compute networks create "$VPC_NAME" \
      --project="$PROJECT" \
      --subnet-mode=custom \
      --bgp-routing-mode=regional

    gcloud compute networks subnets create "$SUBNET_NAME" \
      --project="$PROJECT" \
      --network="$VPC_NAME" \
      --region="$REGION" \
      --range="10.0.0.0/24"
  else
    echo "==> VPC ${VPC_NAME} already exists"
  fi

  # ── Firewall rules (idempotent) ──
  for rule_args in \
    "${VPC_NAME}-deny-ingress --direction=INGRESS --action=DENY --rules=all --source-ranges=0.0.0.0/0 --priority=65534" \
    "${VPC_NAME}-allow-iap-ssh --direction=INGRESS --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20 --priority=1000" \
    "${VPC_NAME}-allow-egress --direction=EGRESS --action=ALLOW --rules=all --destination-ranges=0.0.0.0/0 --priority=1000"; do
    local rule_name="${rule_args%% *}"
    if ! gcloud compute firewall-rules describe "$rule_name" --project="$PROJECT" &>/dev/null; then
      echo "==> Firewall: ${rule_name}"
      # shellcheck disable=SC2086
      gcloud compute firewall-rules create $rule_args \
        --project="$PROJECT" \
        --network="$VPC_NAME"
    fi
  done

  # ── Cloud NAT ──
  if ! gcloud compute routers describe "$ROUTER_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
    echo "==> Cloud NAT: ${ROUTER_NAME}"
    gcloud compute routers create "$ROUTER_NAME" \
      --project="$PROJECT" \
      --network="$VPC_NAME" \
      --region="$REGION"

    gcloud compute routers nats create "$NAT_NAME" \
      --project="$PROJECT" \
      --router="$ROUTER_NAME" \
      --region="$REGION" \
      --nat-all-subnet-ip-ranges \
      --auto-allocate-nat-external-ips
  fi

  # ── VM ──
  local status
  status="$(vm_status)"

  if [[ "$status" == "NOT_FOUND" ]]; then
    echo "==> Creating VM: ${VM_NAME}"

    gcloud compute instances create "$VM_NAME" \
      --project="$PROJECT" \
      --zone="$ZONE" \
      --machine-type="$MACHINE_TYPE" \
      --network-interface="network=${VPC_NAME},subnet=${SUBNET_NAME},no-address" \
      --image-family="$IMAGE_FAMILY" \
      --image-project="$IMAGE_PROJECT" \
      --boot-disk-size="$BOOT_DISK_SIZE" \
      --boot-disk-type=pd-ssd \
      --service-account="$SA_EMAIL" \
      --scopes="cloud-platform" \
      --metadata-from-file="startup-script=${SCRIPT_DIR}/vm-startup.sh" \
      --metadata="secret-name=${SECRET_NAME},ci-project=${PROJECT}" \
      --shielded-secure-boot \
      --shielded-vtpm \
      --shielded-integrity-monitoring \
      --no-address \
      --labels="purpose=signalloom-ci,persistent=true"

    echo "==> Waiting for VM startup script to complete..."
    sleep 30
    local attempts=0
    while ((attempts < 60)); do
      if iap_ssh "test -f /home/ci/.provisioned" 2>/dev/null; then
        echo "==> VM provisioned successfully"
        break
      fi
      ((attempts++))
      sleep 10
    done

    # Suspend after initial provisioning
    echo "==> Suspending VM after initial provisioning"
    gcloud compute instances suspend "$VM_NAME" \
      --zone="$ZONE" --project="$PROJECT"
  else
    echo "==> VM ${VM_NAME} already exists (status: ${status})"
  fi

  echo "==> Provisioning complete."
  echo "    Run tests:  ./scripts/ci/gcp-ci.sh run"
  echo "    Debug SSH:   ./scripts/ci/gcp-ci.sh ssh"
}

# ── Run (resume → test → collect → suspend) ─────────────────────────
cmd_run() {
  echo "════════════════════════════════════════════════════════════"
  echo "  Signalloom D2 E2E CI — Run"
  echo "  Project:  ${PROJECT}  |  VM: ${VM_NAME}"
  echo "  Timeout:  ${TIMEOUT_MINUTES}m"
  echo "════════════════════════════════════════════════════════════"

  # ── Resume VM if suspended ──
  local status
  status="$(vm_status)"

  case "$status" in
    RUNNING)
      echo "==> VM is already running"
      ;;
    SUSPENDED)
      echo "==> Resuming suspended VM..."
      gcloud compute instances resume "$VM_NAME" \
        --zone="$ZONE" --project="$PROJECT"
      echo "==> Waiting for SSH to become available..."
      local attempts=0
      while ((attempts < 30)); do
        if iap_ssh "echo ready" &>/dev/null; then break; fi
        ((attempts++))
        sleep 5
      done
      ;;
    TERMINATED|STOPPED)
      echo "==> Starting stopped VM..."
      gcloud compute instances start "$VM_NAME" \
        --zone="$ZONE" --project="$PROJECT"
      sleep 15
      local attempts=0
      while ((attempts < 30)); do
        if iap_ssh "echo ready" &>/dev/null; then break; fi
        ((attempts++))
        sleep 5
      done
      ;;
    NOT_FOUND)
      echo "ERROR: VM not found. Run './scripts/ci/gcp-ci.sh provision' first." >&2
      exit 2
      ;;
    *)
      echo "ERROR: VM in unexpected state: ${status}" >&2
      exit 2
      ;;
  esac

  # ── Push code if repo doesn't exist on VM yet ──
  if ! iap_ssh "test -d ${REMOTE_WORK_DIR}/scripts" 2>/dev/null; then
    echo "==> No code on VM — pushing via SCP..."
    push_code
  fi

  # ── Run the pipeline via SSH ──
  echo "==> Running pipeline on VM..."
  local pipeline_exit=0

  iap_ssh "sudo -u ci bash -l -c 'cd ${REMOTE_WORK_DIR} && bash scripts/ci/vm-pipeline.sh'" \
    || pipeline_exit=$?

  # ── Collect reports ──
  echo "==> Collecting reports..."
  mkdir -p "$REPORT_DIR"
  iap_scp "${VM_NAME}:${REMOTE_REPORT_DIR}/*" "$REPORT_DIR/" 2>/dev/null || {
    echo "WARNING: Failed to collect report files"
  }

  if [[ -f "${REPORT_DIR}/summary.json" ]]; then
    echo ""
    echo "──── Summary ────"
    jq . "${REPORT_DIR}/summary.json"
    echo "──────────────────"
  fi

  if [[ -f "${REPORT_DIR}/signalloom-ci-report.yaml" ]]; then
    echo "OpenReports: ${REPORT_DIR}/signalloom-ci-report.yaml"
  fi

  # ── Suspend on success, leave running on failure for debugging ──
  if ((pipeline_exit == 0)); then
    echo "==> PASS — suspending VM to save cost"
    gcloud compute instances suspend "$VM_NAME" \
      --zone="$ZONE" --project="$PROJECT"
    echo "==> VM suspended. Resume with: ./scripts/ci/gcp-ci.sh run"
  else
    echo "==> FAIL — VM left running for debugging"
    echo "    SSH in:  ./scripts/ci/gcp-ci.sh ssh"
    echo "    Logs:    tail -f /var/log/ci-pipeline.log"
    echo "    Reports: ls ${REMOTE_REPORT_DIR}/"
    echo ""
    echo "    When done, suspend manually:"
    echo "    gcloud compute instances suspend ${VM_NAME} --zone=${ZONE} --project=${PROJECT}"
  fi

  exit "$pipeline_exit"
}

# ── SSH (interactive debugging) ──────────────────────────────────────
cmd_ssh() {
  local status
  status="$(vm_status)"

  if [[ "$status" == "SUSPENDED" ]]; then
    echo "==> Resuming suspended VM for debugging..."
    gcloud compute instances resume "$VM_NAME" \
      --zone="$ZONE" --project="$PROJECT"
    sleep 10
    local attempts=0
    while ((attempts < 30)); do
      if iap_ssh "echo ready" &>/dev/null; then break; fi
      ((attempts++))
      sleep 5
    done
  elif [[ "$status" != "RUNNING" ]]; then
    echo "ERROR: VM is ${status}. Run './scripts/ci/gcp-ci.sh provision' first." >&2
    exit 2
  fi

  iap_ssh_interactive
}

# ── Status ───────────────────────────────────────────────────────────
cmd_status() {
  local status
  status="$(vm_status)"
  echo "VM: ${VM_NAME} | Project: ${PROJECT} | Zone: ${ZONE} | Status: ${status}"

  if [[ "$status" == "RUNNING" ]]; then
    echo ""
    echo "SSH:     ./scripts/ci/gcp-ci.sh ssh"
    echo "Run:     ./scripts/ci/gcp-ci.sh run"
    echo "Suspend: gcloud compute instances suspend ${VM_NAME} --zone=${ZONE} --project=${PROJECT}"
  elif [[ "$status" == "SUSPENDED" ]]; then
    echo ""
    echo "Run (resumes automatically): ./scripts/ci/gcp-ci.sh run"
  fi
}

# ── Destroy (decommission everything) ────────────────────────────────
cmd_destroy() {
  echo "==> Destroying all signalloom-ci resources..."

  gcloud compute instances delete "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" --quiet 2>/dev/null || true

  for rule in "${VPC_NAME}-deny-ingress" "${VPC_NAME}-allow-iap-ssh" "${VPC_NAME}-allow-egress"; do
    gcloud compute firewall-rules delete "$rule" \
      --project="$PROJECT" --quiet 2>/dev/null || true
  done

  gcloud compute routers nats delete "$NAT_NAME" \
    --router="$ROUTER_NAME" --region="$REGION" \
    --project="$PROJECT" --quiet 2>/dev/null || true

  gcloud compute routers delete "$ROUTER_NAME" \
    --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

  gcloud compute networks subnets delete "$SUBNET_NAME" \
    --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

  gcloud compute networks delete "$VPC_NAME" \
    --project="$PROJECT" --quiet 2>/dev/null || true

  echo "==> All resources destroyed."
}

# ── Main ─────────────────────────────────────────────────────────────
case "${1:-run}" in
  provision)   cmd_provision ;;
  run)         cmd_run ;;
  push-code)   push_code ;;
  ssh)         cmd_ssh ;;
  status)      cmd_status ;;
  destroy)     cmd_destroy ;;
  *)
    echo "Usage: $0 {provision|run|push-code|ssh|status|destroy}" >&2
    exit 1
    ;;
esac
