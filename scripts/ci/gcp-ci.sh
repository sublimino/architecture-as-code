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
readonly VM_NAME="${GCP_CI_VM_NAME:-signalloom-ci}"
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
# Outer fence on the whole remote pipeline. vm-pipeline.sh bounds each of its 8
# stages at CI_STAGE_TIMEOUT_SECONDS (default 900s), so the stages alone can
# legitimately reach 120m before setup, cluster build, and image pushes. A 90m
# fence would have killed healthy runs; the value is the ceiling for a WEDGED
# run, not a target. Enforced on the iap_ssh invocation below via timeout(1).
readonly TIMEOUT_MINUTES="${CI_TIMEOUT_MINUTES:-180}"
readonly REPORT_DIR="${GCP_CI_REPORT_DIR:-${REPO_ROOT}/ci-reports}"
readonly REMOTE_REPORT_DIR="${GCP_CI_REMOTE_REPORT_DIR:-/home/ci/reports}"
readonly REMOTE_WORK_DIR="${GCP_CI_REMOTE_WORK_DIR:-/home/ci/osramp-demo}"
readonly REPORT_FILENAME="${GCP_CI_REPORT_FILENAME:-signalloom-ci-report.yaml}"
readonly PIPELINE_LOG="${GCP_CI_PIPELINE_LOG:-/home/ci/ci-pipeline.log}"
readonly INSTANCE_LABELS="${GCP_CI_LABELS:-purpose=signalloom-ci,persistent=true}"

# CI opts out of monitoring + trivy-system by default: neither is a dependency
# of any demo slice, and together they add the kube-prometheus-stack install
# plus four 720s Kustomization waits to every run.
#
# This deliberately does NOT read ENABLE_OBSERVABILITY. The Makefile declares
# `ENABLE_OBSERVABILITY ?= true` and exports it, so by the time a recipe runs
# the variable is always set — which makes `${ENABLE_OBSERVABILITY:-false}`
# dead code in the make path (verified: it yields "true"), and leaves no way to
# tell the repo-wide default apart from an explicit user request for it.
# A separate CI-scoped variable keeps the two intentions distinguishable.
# To run CI *with* observability: CI_ENABLE_OBSERVABILITY=true make ci-gcp
readonly CI_ENABLE_OBSERVABILITY="${CI_ENABLE_OBSERVABILITY:-false}"

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

# Poll iap_ssh until the VM answers, or fail loudly. The previous inline loops
# `break`-ed on success but fell through silently on exhaustion, so a VM that
# never came back produced a confusing downstream SCP error instead of naming
# the real fault. Fixed 5s interval is deliberate: this is a gcloud API call,
# and tighter polling buys nothing but quota pressure.
wait_for_ssh() {
  local max_attempts="${1:-30}" interval="${2:-5}"
  local attempts=0
  while ((attempts < max_attempts)); do
    if iap_ssh "echo ready" &>/dev/null; then
      echo "==> SSH is available"
      return 0
    fi
    ((attempts += 1))
    sleep "$interval"
  done

  echo "ERROR: VM ${VM_NAME} did not accept SSH within $((max_attempts * interval))s" >&2
  return 2
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

# A local SSH failure is not a VM failure, and this used to report it as one.
#
# The loop below discards stderr, so "the VM has not finished provisioning yet"
# and "ssh on THIS machine cannot authenticate at all" were indistinguishable:
# both simply failed the test. Ten minutes later it printed "Timed out waiting
# for VM startup provisioning" and pointed the reader at a VM that had in fact
# finished in 124s, with `startup-script exit status 0` on the serial console
# and the marker file present the whole time. Observed 2026-08-03: an ssh-agent
# refusing to sign cost ~10 minutes of debugging in exactly the wrong place.
#
# The distinction is cheap to make. A missing marker file means ssh CONNECTED
# and the file was not there — that is the legitimate keep-waiting case. Any
# other failure means we never got far enough to look, and no amount of waiting
# will change it, so fail immediately with the real error rather than burning
# the full budget on a wrong diagnosis.
# Patterns must be specific enough to not catch gcloud's routine chatter.
# "was not found" alone looked reasonable and was actively dangerous: gcloud
# prints "External IP address was not found; defaulting to using IAP
# tunneling." on EVERY IAP connection, so a bare substring match classified
# every healthy run as terminal and aborted it on the first attempt. Caught by
# the classifier's own test table before it ever ran against a VM -- which is
# the argument for having one.
ssh_probe_error() { # returns 0 if the error is worth retrying, 1 if it is terminal
  local err="$1"
  case "$err" in
    *"agent refused operation"*|\
    *"Permission denied"*|\
    *"Too many authentication failures"*|\
    *"Could not resolve"*|\
    *"not have permission"*|\
    *"PERMISSION_DENIED"*|\
    *"Instance ["*"was not found"*) return 1 ;;
  esac
  return 0
}

wait_for_provision() {
  echo "==> Waiting for VM startup script to complete..."
  local attempts=0 err_file last_err=""
  err_file="$(mktemp)"
  while ((attempts < 60)); do
    if iap_ssh "sudo test -f /home/ci/.provisioned" 2>"$err_file"; then
      echo "==> VM provisioned successfully"
      rm -f "$err_file"
      return 0
    fi
    last_err="$(tr -d '\r' < "$err_file" | grep -v '^$' | tail -3)"

    if [[ -n "$last_err" ]] && ! ssh_probe_error "$last_err"; then
      echo "ERROR: SSH to ${VM_NAME} failed for a reason waiting cannot fix." >&2
      echo "       This is a LOCAL or IAM problem, not VM provisioning." >&2
      echo "       gcloud said:" >&2
      printf '         %s\n' "$last_err" >&2
      echo "       If it mentions 'agent refused operation', your ssh-agent is" >&2
      echo "       refusing to sign; retry with: SSH_AUTH_SOCK= make ci-gcp" >&2
      rm -f "$err_file"
      return 2
    fi

    ((attempts+=1))
    sleep 10
  done

  echo "ERROR: Timed out waiting for VM startup provisioning after 600s." >&2
  if [[ -n "$last_err" ]]; then
    echo "       Last SSH stderr (may explain it):" >&2
    printf '         %s\n' "$last_err" >&2
  fi
  echo "       Check the startup script on the serial console before assuming" >&2
  echo "       the VM is at fault:" >&2
  echo "         gcloud compute instances get-serial-port-output ${VM_NAME} \\" >&2
  echo "           --zone=${ZONE} --project=${PROJECT} | tail -40" >&2
  rm -f "$err_file"
  return 1
}

# ── Push code via SCP (for local runs without deploy key) ────────────
push_code() {
  echo "==> Pushing repo to VM via SCP..."

  local tarball
  tarball="$(mktemp "/tmp/osramp-demo-${VM_NAME}.XXXXXX.tar.gz")"
  tar -C "$REPO_ROOT" \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.cache' \
    --exclude='ci-reports*' \
    --exclude='test-results' \
    --exclude='playwright-report' \
    -czf "$tarball" .

  iap_scp "$tarball" "${VM_NAME}:/tmp/osramp-demo-ci.tar.gz"
  iap_ssh "sudo rm -rf ${REMOTE_WORK_DIR} && \
    sudo mkdir -p ${REMOTE_WORK_DIR} && \
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
       --labels="${INSTANCE_LABELS}"

    wait_for_provision

    # Suspend after initial provisioning
    echo "==> Suspending VM after initial provisioning"
    gcloud compute instances suspend "$VM_NAME" \
      --zone="$ZONE" --project="$PROJECT"
  else
    echo "==> VM ${VM_NAME} already exists (status: ${status})"
    if [[ "$status" == "RUNNING" ]] && ! iap_ssh "sudo test -f /home/ci/.provisioned" 2>/dev/null; then
      wait_for_provision
    fi
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
  echo "  Timeout:  ${TIMEOUT_MINUTES}m  |  Observability: ${CI_ENABLE_OBSERVABILITY}"
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
      wait_for_ssh 30 5 || exit 2
      ;;
    TERMINATED|STOPPED)
      echo "==> Starting stopped VM..."
      gcloud compute instances start "$VM_NAME" \
        --zone="$ZONE" --project="$PROJECT"
      wait_for_ssh 33 5 || exit 2
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

  # ── Synchronize the local checkout before every test run ───────────
  # The pipeline validates uncommitted local changes; reusing a previous
  # checkout would silently test stale files and preserve deleted paths.
  push_code

  # ── Run the pipeline via SSH ──
  echo "==> Running pipeline on VM..."
  local pipeline_exit=0

  # Capture the real source identity here — the VM only ever sees an untracked
  # tarball and git-inits a throwaway snapshot repo, whose SHA is meaningless.
  local source_commit source_branch
  source_commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  source_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "==> Source under test: ${source_branch}@${source_commit}"

  local pipeline_command
  printf -v pipeline_command 'cd %q && bash scripts/ci/vm-pipeline.sh' "$REMOTE_WORK_DIR"
  # TIMEOUT_MINUTES was previously defined and printed but never enforced, so a
  # wedged SSH session blocked the run forever and `CI_TIMEOUT_MINUTES=…` (as
  # documented in scripts/ci/README.md) silently did nothing. Fence it here.
  # SIGTERM first, SIGKILL 60s later, so the remote pipeline gets a chance to
  # flush its report files before the tunnel is torn down.
  timeout -k 60s "${TIMEOUT_MINUTES}m" \
    gcloud compute ssh "$VM_NAME" \
      --zone="$ZONE" --project="$PROJECT" \
      --tunnel-through-iap \
      --command="sudo -u ci env CI_WORK_DIR=$(printf '%q' "$REMOTE_WORK_DIR") CI_REPORT_DIR=$(printf '%q' "$REMOTE_REPORT_DIR") CI_REPORT_FILENAME=$(printf '%q' "$REPORT_FILENAME") CI_PIPELINE_LOG=$(printf '%q' "$PIPELINE_LOG") CI_SOURCE_COMMIT=$(printf '%q' "$source_commit") CI_SOURCE_BRANCH=$(printf '%q' "$source_branch") ENABLE_OBSERVABILITY=$(printf '%q' "$CI_ENABLE_OBSERVABILITY") bash -l -c $(printf '%q' "$pipeline_command")" \
    || pipeline_exit=$?

  if ((pipeline_exit == 124)); then
    echo "ERROR: pipeline exceeded the ${TIMEOUT_MINUTES}m fence and was terminated" >&2
    echo "       Raise it with: CI_TIMEOUT_MINUTES=<n> $0 run" >&2
  fi

  # ── Collect reports ──
  echo "==> Collecting reports..."
  # Rotate the previous run out of the way BEFORE collecting. `tar -xzf`
  # overwrites only the files present in the archive and leaves everything else
  # untouched, so a run that aborted before writing reports used to inherit the
  # previous run's summary.json wholesale — a run that executed zero tests
  # printed a complete, plausible "5 passed, 3 failed" from stale data, with
  # only the commit field and file mtimes betraying it. Keep one generation for
  # comparison rather than deleting, but never let two runs share a directory.
  if [[ -d "$REPORT_DIR" ]] && [[ -n "$(ls -A "$REPORT_DIR" 2>/dev/null)" ]]; then
    rm -rf "${REPORT_DIR}.prev"
    mv "$REPORT_DIR" "${REPORT_DIR}.prev"
    echo "    previous run rotated to $(basename "${REPORT_DIR}").prev"
  fi
  mkdir -p "$REPORT_DIR"
  # The report directory belongs to the restricted `ci` account, while IAP SCP
  # authenticates as the operator account. Package it via sudo first instead of
  # weakening /home/ci permissions just to collect CI artifacts.
  local report_archive="/tmp/${VM_NAME}-reports.tar.gz"
  if iap_ssh "sudo -u ci tar -C $(printf '%q' "$REMOTE_REPORT_DIR") -czf $(printf '%q' "$report_archive") ." \
    && iap_scp "${VM_NAME}:${report_archive}" "$REPORT_DIR/" 2>/dev/null \
    && tar -xzf "${REPORT_DIR}/$(basename "$report_archive")" -C "$REPORT_DIR"; then
    rm -f "${REPORT_DIR}/$(basename "$report_archive")"
    iap_ssh "rm -f $(printf '%q' "$report_archive")" >/dev/null 2>&1 || true
  else
    echo "WARNING: Failed to collect report files"
  fi

  if [[ -f "${REPORT_DIR}/summary.json" ]]; then
    echo ""
    echo "──── Summary ────"
    jq . "${REPORT_DIR}/summary.json"
    echo "──────────────────"
  else
    # Say so loudly. A missing summary means the pipeline died before the test
    # stages ran — a categorically worse outcome than failing tests, and one
    # that previously presented as silence next to a stale summary.
    echo "" >&2
    echo "ERROR: no summary.json was produced — the pipeline did not reach the" >&2
    echo "       test stages. This is an aborted run, NOT a test failure." >&2
    echo "       Pipeline log on the VM: ${PIPELINE_LOG}" >&2
    if [[ -d "${REPORT_DIR}.prev" ]]; then
      echo "       The previous run's reports are in $(basename "${REPORT_DIR}").prev" >&2
      echo "       — they describe a DIFFERENT run. Do not read them as this one." >&2
    fi
    if ((pipeline_exit == 0)); then
      echo "       Pipeline exited 0 without producing reports; treating as failure." >&2
      pipeline_exit=2
    fi
  fi

  if [[ -f "${REPORT_DIR}/${REPORT_FILENAME}" ]]; then
    echo "OpenReports: ${REPORT_DIR}/${REPORT_FILENAME}"
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
    wait_for_ssh 32 5 || exit 2
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
  if [[ "$VM_NAME" != "signalloom-ci" ]]; then
    echo "==> Destroying VM ${VM_NAME}; shared CI networking is retained."
    gcloud compute instances delete "$VM_NAME" \
      --zone="$ZONE" --project="$PROJECT" --quiet 2>/dev/null || true
    return
  fi

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
