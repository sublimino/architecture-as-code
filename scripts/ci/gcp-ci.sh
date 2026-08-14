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
#   lock         — Inspect or manage the exclusive VM lock:
#                    lock status | lock acquire [--force] | lock release
#                  `run` and `push-code` take it automatically. Nothing but
#                  the lock stops two callers destroying each other's cluster.
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
# Deliberately NOT derived from VM_NAME. The VPC, subnet, router and NAT are
# SHARED by both CI VMs, so signalloom-ci-2 lives on signalloom-ci's network.
# What stops `GCP_CI_VM_NAME=signalloom-ci-2 gcp-ci.sh destroy` from taking the
# shared network down with the instance is cmd_destroy's early return: for any
# VM_NAME other than exactly `signalloom-ci` it deletes the instance and
# returns, and the network teardown below that is unreachable. This note exists
# because the hardcoded name here reads as a bug until you find that guard.
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
# A relative GCP_CI_REPORT_DIR — the Makefile's CI_2_ENV passes `ci-reports-2` —
# used to resolve against the CALLER's cwd, so the identical command wrote its
# reports to a different directory depending on where you were standing when you
# typed it. Reports belong to the checkout whose scripts ran, not to whatever
# happened to be $PWD, so a relative value is anchored at REPO_ROOT. Everything
# downstream (including `state`) then prints an absolute path, which is the
# whole point: the data was never wrong, knowing which file it was in was.
_gcp_ci_report_dir="${GCP_CI_REPORT_DIR:-ci-reports}"
case "$_gcp_ci_report_dir" in
  /*) readonly REPORT_DIR="$_gcp_ci_report_dir" ;;
  *)  readonly REPORT_DIR="${REPO_ROOT}/${_gcp_ci_report_dir}" ;;
esac
unset _gcp_ci_report_dir
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

# ── Exclusive lock on the shared VM ──────────────────────────────────
# `run` destroys shared state before it tests anything: push_code does
# `rm -rf ${REMOTE_WORK_DIR}` and the pipeline does `make teardown`. On
# 2026-08-04 that landed on another agent's live cluster three times in one
# night, once 25 seconds after they announced they were taking the VM — which
# is the point: announcing is not a control, because the race is shorter than
# the time it takes to read a message. See scripts/ci/ci-lock.sh.
readonly LOCK_SCRIPT="${SCRIPT_DIR}/ci-lock.sh"
readonly LOCK_HOLDER_NAME="${GCP_CI_LOCK_HOLDER:-$(id -un)@$(hostname -s)}"
readonly LOCK_TOKEN_VALUE="${LOCK_HOLDER_NAME}:$$"
GCP_CI_HOLDS_LOCK=0
LOCK_SHIM=""

# ci-lock.sh calls its remote boundary as `$CI_LOCK_REMOTE_EXEC "<snippet>"`,
# so the boundary has to be an executable that takes the snippet as $1. A
# throwaway shim is simpler and far more legible than exporting shell functions
# through nested `bash -c`, and it keeps gcloud confined to one line.
#
# Call it as a plain command and then read $LOCK_SHIM. It must NOT be called as
# `$(lock_shim)`: command substitution runs in a subshell, so the assignment to
# LOCK_SHIM was discarded, the memo never hit, every call mktemp'd a fresh file
# that nothing ever deleted, and — because the parent's LOCK_SHIM stayed empty
# — the `[ -n "$LOCK_SHIM" ]` cleanup below always evaluated false and returned
# 1 as the last command of the EXIT trap. Under `set -e` that replaced the
# script's own exit status, so a run with 8/8 stages green exited 1.
lock_shim() {
  [ -n "$LOCK_SHIM" ] && return 0
  LOCK_SHIM="$(mktemp -t gcp-ci-lock-shim-XXXXXX)"
  cat >"$LOCK_SHIM" <<SHIM
#!/usr/bin/env bash
exec gcloud compute ssh $(printf '%q' "$VM_NAME") \\
  --zone=$(printf '%q' "$ZONE") --project=$(printf '%q' "$PROJECT") \\
  --tunnel-through-iap --command="sudo -u ci bash -c \\"\$1\\""
SHIM
  chmod +x "$LOCK_SHIM"
}

lock_acquire() {
  if [ "${GCP_CI_SKIP_LOCK:-0}" = "1" ]; then
    echo "==> Lock skipped (GCP_CI_SKIP_LOCK=1) — you are responsible for the collision"
    return 0
  fi
  local args=(acquire --reason "${GCP_CI_LOCK_REASON:-gcp-ci.sh run}")
  [ "${GCP_CI_FORCE_LOCK:-0}" = "1" ] && args+=(--force)

  lock_shim
  if CI_LOCK_REMOTE_EXEC="$LOCK_SHIM" \
     CI_LOCK_HOLDER="$LOCK_HOLDER_NAME" \
     CI_LOCK_TOKEN="$LOCK_TOKEN_VALUE" \
     GCP_CI_REMOTE_WORK_DIR="$REMOTE_WORK_DIR" \
     bash "$LOCK_SCRIPT" "${args[@]}"; then
    GCP_CI_HOLDS_LOCK=1
    return 0
  fi
  echo "    Override with: GCP_CI_FORCE_LOCK=1 $0 run" >&2
  exit 2
}

# Released from a trap, so it must never turn a passing run into a failing one
# — and never release a lock that was legitimately reclaimed while we ran.
#
# Every path out of this function returns 0, explicitly. `set -e` makes a
# failing final command inside an EXIT trap override the status the script
# asked for, which is how a green run reported failure. The invariant in the
# comment above is only as good as that trailing `return 0`.
lock_release() {
  if [ "$GCP_CI_HOLDS_LOCK" != "1" ]; then
    return 0
  fi
  lock_shim
  CI_LOCK_REMOTE_EXEC="$LOCK_SHIM" \
  CI_LOCK_HOLDER="$LOCK_HOLDER_NAME" \
  CI_LOCK_TOKEN="$LOCK_TOKEN_VALUE" \
    bash "$LOCK_SCRIPT" release || true
  GCP_CI_HOLDS_LOCK=0
  if [ -n "$LOCK_SHIM" ]; then
    rm -f "$LOCK_SHIM"
    LOCK_SHIM=""
  fi
  return 0
}

# ── Helpers ──────────────────────────────────────────────────────────
# NOT_FOUND means the API answered and the VM is absent. It must NOT mean "we
# could not ask".
#
# `2>/dev/null || echo NOT_FOUND` swallowed every failure alike, so an expired
# credential printed
#
#   ERROR: VM not found. Run './scripts/ci/gcp-ci.sh provision' first.
#
# against a VM that was present and healthy. Following that advice would spend
# ~11 minutes provisioning a duplicate, and for signalloom-ci the destroy path
# deletes the shared VPC both CI VMs depend on — so a misdiagnosis here is
# expensive in a way it is not elsewhere. Observed 2026-08-13.
#
# Distinguish the three outcomes: absent, unauthenticated, and everything else.
vm_status() {
  local out rc
  out="$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --format='get(status)' 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out"
    return 0
  fi
  case "$out" in
    *"was not found"*|*"notFound"*|*"does not exist"*)
      printf 'NOT_FOUND' ;;
    *"Reauthentication failed"*|*"gcloud auth login"*|*"credentials"*|*"invalid_grant"*|*"Request had invalid authentication"*)
      printf 'AUTH_REQUIRED' ;;
    *)
      printf 'QUERY_FAILED' ;;
  esac
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
    # `grep -v` exits 1 when it selects no lines, and under this script's
    # `set -euo pipefail` a failing command substitution in an assignment kills
    # the run outright: exit 1, mid-poll, without printing a single word. Empty
    # stderr is not an edge case here, it is the ordinary cold-start case — SSH
    # connects fine and `test -f` simply reports the marker is not written yet.
    # A warm VM never reaches this line, because the first probe returns 0, so
    # only a freshly created VM ever saw it. Observed 2026-08-12 on a new
    # signalloom-ci-2: provisioning "failed" ~4 minutes in with no diagnosis,
    # while the VM was healthy and finished writing the marker shortly after.
    last_err="$(tr -d '\r' < "$err_file" | grep -v '^$' | tail -3 || true)"

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

# ── Terminal state that outlives the terminal ────────────────────────
#
# Three incidents in one session on 2026-08-13, all the same shape: the state
# left on disk after a run could not distinguish success from never-having-run.
#
#   1. Two lanes aborted before stage 1. Both VMs were suspended by hand to stop
#      the cost, which is also the SUCCESS state — the script suspends on pass.
#      "SUSPENDED, ci-reports/ holding only wait-stats.txt" is what you see
#      after a clean pass whose collection failed, after an abort, and after a
#      run that never started.
#   2. A poll read ci-reports/summary.json mid-run and got `5444d45 FAIL 8/12` —
#      the PREVIOUS round's file, because the new run had not collected yet.
#   3. A VM status read 14 seconds before the VM was resumed was reported as
#      "not started". Accurate when taken, wrong on arrival.
#
# The fix is that the run writes its own state at every transition, starting
# before it touches the VM: a RUNNING marker with the commit under test, then a
# terminal PASS / FAIL / ABORTED / STALE. There is never a window in which
# summary.json describes a different run than the one you are asking about.
RUN_COMMIT="unknown"
RUN_BRANCH="unknown"
RUN_STARTED_AT=""
RUN_PHASE="not-started"

# One generation back, out of the way, BEFORE anything can be collected into it.
# Rotating at collection time (where this used to live) leaves the previous
# round's summary.json readable for the entire duration of the new run — which
# is incident 2 exactly.
rotate_reports() {
  if [[ -d "$REPORT_DIR" ]] && [[ -n "$(ls -A "$REPORT_DIR" 2>/dev/null)" ]]; then
    rm -rf "${REPORT_DIR}.prev"
    mv "$REPORT_DIR" "${REPORT_DIR}.prev"
    echo "    previous run rotated to $(basename "${REPORT_DIR}").prev"
  fi
  mkdir -p "$REPORT_DIR"
  return 0
}

# write_run_status <outcome> <phase> [note] [exit_code]
# Shaped to match the pipeline's own summary.json so one reader handles both.
#
# pid, host and origin are structured fields, not prose. The note has carried
# "run in flight (pid N on host)" since the marker was introduced, and on
# 2026-08-14 a reader looked at a RUNNING marker two minutes old, could not
# check whether pid N was still alive, and reasonably concluded the run was
# stranded — while it was in fact mid-pipeline. A fact buried in a sentence is a
# fact no tool can act on. `state` reads these three and answers the question.
write_run_status() {
  local outcome="$1" phase="$2" note="${3:-}" exit_code="${4:-}"
  mkdir -p "$REPORT_DIR" 2>/dev/null || return 0
  local tmp="${REPORT_DIR}/.summary.json.tmp"
  if jq -n \
      --arg outcome "$outcome" \
      --arg phase "$phase" \
      --arg note "$note" \
      --arg commit "$RUN_COMMIT" \
      --arg branch "$RUN_BRANCH" \
      --arg vm "$VM_NAME" \
      --arg started_at "$RUN_STARTED_AT" \
      --arg written_at "$(date -Iseconds)" \
      --arg exit_code "$exit_code" \
      --arg pid "$$" \
      --arg host "$(hostname -s 2>/dev/null || echo unknown)" \
      --arg origin "${REPO_ROOT:-unknown}" \
      '{outcome: $outcome, overall: $outcome, phase: $phase, commit: $commit,
        branch: $branch, vm: $vm, started_at: $started_at, written_at: $written_at,
        pid: ($pid | tonumber), host: $host, origin: $origin,
        note: $note}
       + (if $exit_code == "" then {} else {exit_code: ($exit_code | tonumber)} end)' \
      >"$tmp" 2>/dev/null; then
    mv "$tmp" "${REPORT_DIR}/summary.json"
  else
    rm -f "$tmp"
  fi
  return 0
}

# The EXIT trap for `run`. Releases the lock as before, and converts a leftover
# RUNNING marker into a terminal ABORTED — a run killed between the start marker
# and the verdict (Ctrl-C, a `exit 2` from the resume path, an OOM) would
# otherwise leave "RUNNING" on disk forever, which reads as "still going".
#
# The explicit `exit "$rc"` is not decoration: under `set -e` an EXIT trap hands
# its own last exit status to the shell, which is how a run with 8/8 stages
# green once exited 1. See lock_release's comment and test/ci-lock.bats.
run_exit_trap() {
  local rc=$?
  lock_release || true
  local outcome=""
  if [[ -f "${REPORT_DIR}/summary.json" ]]; then
    outcome="$(jq -r '.outcome // ""' "${REPORT_DIR}/summary.json" 2>/dev/null || echo "")"
  fi
  if [[ "$outcome" == "RUNNING" ]]; then
    write_run_status ABORTED "$RUN_PHASE" \
      "run exited during phase '${RUN_PHASE}' without reaching a verdict; this is an ABORTED run, NOT a test failure" \
      "$rc"
  fi
  exit "$rc"
}

set_run_phase() {
  RUN_PHASE="$1"
  write_run_status RUNNING "$1" "run in flight (pid $$ on $(hostname -s)); this is not a verdict"
  return 0
}

# classify_run_outcome <summary-file> <expected-commit> <pipeline-exit>
# Echoes exactly one of: PASS | FAIL | ABORTED | STALE.
#
# The two dishonest readings this exists to stop:
#   RUNNING  — our own start marker survived collection, i.e. NOTHING came back
#              from the VM. Absence of a report is an abort, never a pass.
#   STALE    — the summary on disk names a different commit than the one under
#              test, so it describes some other run. A green run cannot reach
#              this branch: the pipeline stamps the commit gcp-ci.sh hands it.
classify_run_outcome() {
  local summary="$1" expected_commit="$2" pipeline_exit="$3"
  [[ -f "$summary" ]] || { echo ABORTED; return 0; }

  local outcome commit
  outcome="$(jq -r '.outcome // .overall // "UNKNOWN"' "$summary" 2>/dev/null || echo UNKNOWN)"
  commit="$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)"

  case "$outcome" in
    RUNNING|ABORTED|UNKNOWN|"") echo ABORTED; return 0 ;;
  esac

  if [[ "$expected_commit" != "unknown" && "$commit" != "unknown" \
        && "$commit" != "$expected_commit" ]]; then
    echo STALE
    return 0
  fi

  # A summary saying PASS does not outrank a non-zero pipeline exit; that pair
  # means the run died after writing its report, and exiting 0 on it would be
  # the same lie in a different file. This is the status the script already
  # exited with, so nothing green changes colour.
  if [[ "$outcome" == "PASS" ]] && ((pipeline_exit == 0)); then
    echo PASS
  else
    echo FAIL
  fi
  return 0
}

# final_exit_code <verdict> <pipeline-exit>
# The one place the run's exit status is decided, so the status, the message and
# the file on disk cannot disagree with each other.
#
#   PASS            — 0. Unchanged, and the only path that suspends the VM.
#   FAIL            — the pipeline's own status, or 1 if it somehow exited 0
#                     while reporting failures. A report saying FAIL next to a
#                     green exit is the same lie in a different file.
#   ABORTED / STALE — the pipeline's own status, or 2 if it exited 0 without
#                     producing a verdict. Preserves today's behaviour, which
#                     already promoted a reportless exit 0 to 2.
final_exit_code() {
  local verdict="$1" pipeline_exit="$2"
  case "$verdict" in
    PASS) echo 0 ;;
    FAIL) if ((pipeline_exit == 0)); then echo 1; else echo "$pipeline_exit"; fi ;;
    *)    if ((pipeline_exit == 0)); then echo 2; else echo "$pipeline_exit"; fi ;;
  esac
  return 0
}

# Marks a collected report as belonging to a COMPLETED collection. Without it,
# a summary.json on disk is indistinguishable from one a previous run left there.
#
# `origin` is stamped here as well as in write_run_status because collection
# OVERWRITES summary.json with the VM's copy, which knows nothing about the
# checkout that asked for the run. This repo now has a dozen checkouts and the
# reports live at <checkout>/ci-reports; without the origin field, a report
# directory rsynced, copied or simply left behind by an older run in a DIFFERENT
# checkout reads exactly like one this checkout produced.
stamp_collected_summary() {
  local f="${REPORT_DIR}/summary.json"
  [[ -f "$f" ]] || return 0
  local tmp="${REPORT_DIR}/.summary.json.tmp"
  if jq --arg c "$(date -Iseconds)" --arg vm "$VM_NAME" \
       --arg origin "${REPO_ROOT:-unknown}" \
       --arg host "$(hostname -s 2>/dev/null || echo unknown)" \
       '. + {outcome: (.outcome // .overall), collected_at: $c, vm: $vm,
             origin: $origin, host: $host}' \
       "$f" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
  return 0
}

# print_local_run_status [summary-file] [now-epoch]
# What the report directory says, with the time it says it about — so a reader
# never has to reach for `gcloud ... lastStartTimestamp` to date a claim.
print_local_run_status() {
  local f="${1:-${REPORT_DIR}/summary.json}"
  local now_epoch="${2:-$(date +%s)}"
  if [[ ! -f "$f" ]]; then
    echo "Report:  none collected in $(basename "$(dirname "$f")")/ — no run has finished here."
    return 0
  fi

  local outcome commit branch when phase
  outcome="$(jq -r '.outcome // .overall // "UNKNOWN"' "$f" 2>/dev/null || echo UNKNOWN)"
  commit="$(jq -r '.commit // "unknown"' "$f" 2>/dev/null || echo unknown)"
  branch="$(jq -r '.branch // "unknown"' "$f" 2>/dev/null || echo unknown)"
  phase="$(jq -r '.phase // "unknown"' "$f" 2>/dev/null || echo unknown)"
  when="$(jq -r '.collected_at // .written_at // .timestamp // "unknown"' "$f" 2>/dev/null || echo unknown)"
  # The phase only carries information for a run that did not finish; on a PASS
  # it is noise, and "phase: unknown" next to a verdict reads as doubt about it.
  local phase_note=""
  [[ "$phase" != "unknown" && "$outcome" != "PASS" && "$outcome" != "FAIL" ]] && phase_note="phase: ${phase}, "
  echo "Report:  ${outcome} for ${branch}@${commit} (${phase_note}as of ${when})"

  if [[ "$outcome" == "RUNNING" ]]; then
    local started="" age=-1 started_epoch
    started="$(jq -r '.started_at // empty' "$f" 2>/dev/null || echo "")"
    if [[ -n "$started" ]]; then
      started_epoch="$(date -d "$started" +%s 2>/dev/null || echo "")"
      [[ -n "$started_epoch" ]] && age=$(( now_epoch - started_epoch ))
    fi
    local fence=$(( 60 * ${TIMEOUT_MINUTES:-180} ))
    if ((age > fence)); then
      echo "         that RUNNING marker is ${age}s old, past the ${TIMEOUT_MINUTES:-180}m fence —"
      echo "         the run that wrote it did not finish. It is NOT a result."
    else
      echo "         a run is in flight. RUNNING is not a verdict; wait for it."
    fi
  fi
  return 0
}

# ── Is the run that wrote this marker still alive? ───────────────────
#
# The RUNNING marker has always carried its pid and host — in the note, as
# prose. On 2026-08-14 a reader found a RUNNING marker in the main checkout,
# saw no run they had started, and concluded it was stranded. It was not: two
# `gcp-ci.sh run` processes were mid-pipeline from that very directory. The
# marker was honest and the reader had no way to check it, which is the same
# class of defect as the ambiguity it replaced — just moved into the reader.
#
# Nothing here is a heartbeat. A timestamp cannot separate a slow run from a
# dead one; a pid can, and it costs one stat.

# proc_start_epoch <pid> — when that pid started, epoch seconds. Empty if no
# such process exists.
proc_start_epoch() {
  local pid="$1" lstart
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  lstart="$(ps -o lstart= -p "$pid" 2>/dev/null || true)"
  [[ -n "$lstart" ]] || return 0
  date -d "$lstart" +%s 2>/dev/null || true
}

# marker_process_state <pid> <host> <started_at>
# Echoes exactly one of: LIVE | GONE | RECYCLED | ELSEWHERE | UNKNOWN.
marker_process_state() {
  local pid="$1" host="$2" started_at="$3"
  local me; me="$(hostname -s 2>/dev/null || echo unknown)"

  [[ "$pid" =~ ^[0-9]+$ ]] || { echo UNKNOWN; return 0; }
  if [[ -n "$host" && "$host" != "null" && "$host" != "unknown" && "$host" != "$me" ]]; then
    echo ELSEWHERE
    return 0
  fi

  local proc_epoch
  proc_epoch="$(proc_start_epoch "$pid")"
  [[ -n "$proc_epoch" ]] || { echo GONE; return 0; }

  # A live pid alone proves nothing. Pids are recycled, and an old marker naming
  # a number some unrelated process now holds would read as "still running"
  # forever — the failure mode this whole file exists to prevent, reintroduced
  # by the fix for it. A run's own process cannot have started AFTER the marker
  # it wrote, so a later start time means a different process wearing the same
  # number. The 60s of slack is for clock granularity, not for a fresh run.
  local started_epoch=""
  if [[ -n "$started_at" && "$started_at" != "null" ]]; then
    started_epoch="$(date -d "$started_at" +%s 2>/dev/null || true)"
  fi
  if [[ -n "$started_epoch" ]] && ((proc_epoch > started_epoch + 60)); then
    echo RECYCLED
    return 0
  fi
  echo LIVE
  return 0
}

# ── Reports are per-checkout, so a checkout can hold a foreign answer ─
#
# REPORT_DIR is <checkout>/ci-reports, and this repo now has a dozen checkouts.
# That locality is correct — two lanes running concurrently in two worktrees
# must not share a directory — but it means the OBVIOUS place to look is not
# necessarily the place that ran. On 2026-08-14 the main checkout's
# ci-reports-2/summary.json said `d574d7d PASS 11/11` from the previous day
# while the run everyone cared about had finished in a lane worktree an hour
# earlier. Two agents saw that artefact independently and each assumed their own
# tooling was misreading.

# summary_epoch <summary-file> — the time the report itself claims, epoch
# seconds. Deliberately not mtime: mtime records whatever last touched the file,
# so a copy, an rsync or a tar extraction re-dates a report it did not produce.
summary_epoch() {
  local f="$1" ts
  [[ -f "$f" ]] || return 0
  ts="$(jq -r '.collected_at // .written_at // .timestamp // empty' "$f" 2>/dev/null || true)"
  [[ -n "$ts" ]] || return 0
  date -d "$ts" +%s 2>/dev/null || true
}

# newer_sibling_reports <report-dir> [our-epoch]
# Prints "<epoch>\t<summary-path>" for every OTHER checkout of this repo holding
# a same-named report directory whose report is newer than ours.
#
# This is the half that provenance alone cannot cover. The stale artefact in the
# main checkout was honest about its origin — main really did produce it — and
# was still the wrong answer. Only comparing across checkouts says so.
#
# `git worktree list` is the enumerator rather than a filesystem walk because it
# is exactly the set of checkouts of THIS repo, it includes the main checkout,
# and it cannot wander into an unrelated tree.
newer_sibling_reports() {
  local dir="$1" ours="${2:-}"
  local base line path candidate epoch
  base="$(basename "$dir")"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      *) continue ;;
    esac
    [[ -d "$path" ]] || continue
    # -ef compares device+inode, so a symlinked path to our own checkout is not
    # mistaken for a sibling.
    [[ "$path" -ef "$REPO_ROOT" ]] && continue
    candidate="${path}/${base}/summary.json"
    [[ -f "$candidate" ]] || continue
    epoch="$(summary_epoch "$candidate")"
    [[ -n "$epoch" ]] || continue
    if [[ -z "$ours" ]] || ((epoch > ours)); then
      printf '%s\t%s\n' "$epoch" "$candidate"
    fi
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)
  return 0
}

# ── What happened to the last run? ───────────────────────────────────
#
# The last mile: one local, network-free command a cold reader can run to find
# out what the last run did, WITHOUT having to know which of a dozen checkouts
# is authoritative. It answers with an absolute path first, because that is the
# question that was actually unanswered.
cmd_state() {
  local summary="${REPORT_DIR}/summary.json"
  local head_commit head_branch me
  head_commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  head_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  me="$(hostname -s 2>/dev/null || echo unknown)"

  echo "Report:   ${summary}"
  echo "Checkout: ${REPO_ROOT}  (HEAD ${head_branch}@${head_commit})"

  local ours_epoch
  ours_epoch="$(summary_epoch "$summary")"

  if [[ ! -f "$summary" ]]; then
    echo "Verdict:  NONE — that file does not exist, so no run has finished in this checkout."
    print_sibling_reports "$ours_epoch"
    echo "Exit:     2 (no verdict here)"
    return 2
  fi

  local raw commit branch vm phase started_at when pid host origin
  local passed failed total exit_code
  raw="$(jq -r '.outcome // .overall // "UNKNOWN"' "$summary" 2>/dev/null || echo UNKNOWN)"
  commit="$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)"
  branch="$(jq -r '.branch // "unknown"' "$summary" 2>/dev/null || echo unknown)"
  vm="$(jq -r '.vm // "unknown"' "$summary" 2>/dev/null || echo unknown)"
  phase="$(jq -r '.phase // "unknown"' "$summary" 2>/dev/null || echo unknown)"
  started_at="$(jq -r '.started_at // empty' "$summary" 2>/dev/null || true)"
  when="$(jq -r '.collected_at // .written_at // .timestamp // "unknown"' "$summary" 2>/dev/null || echo unknown)"
  pid="$(jq -r '.pid // empty' "$summary" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$summary" 2>/dev/null || true)"
  origin="$(jq -r '.origin // empty' "$summary" 2>/dev/null || true)"
  passed="$(jq -r '.passed // empty' "$summary" 2>/dev/null || true)"
  failed="$(jq -r '.failed // empty' "$summary" 2>/dev/null || true)"
  total="$(jq -r '.total_stages // empty' "$summary" 2>/dev/null || true)"
  exit_code="$(jq -r '.exit_code // 0' "$summary" 2>/dev/null || echo 0)"
  [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=0

  # The verdict comes from the same classifier the run itself uses. Re-deriving
  # it here would be a second opinion, and two opinions is the disease.
  local verdict final
  verdict="$(classify_run_outcome "$summary" "$head_commit" "$exit_code")"
  final="$(final_exit_code "$verdict" "$exit_code")"

  case "$raw" in
    RUNNING)
      # classify_run_outcome calls this ABORTED and it is right to: a marker
      # with no verdict is not a result, whichever way it got there. But
      # "ABORTED" and "still going" are different things to a human standing in
      # front of it, and the pid is what tells them apart.
      local pstate
      pstate="$(marker_process_state "$pid" "$host" "$started_at")"
      case "$pstate" in
        LIVE)
          echo "Verdict:  RUNNING — a run is IN FLIGHT. Not a verdict; wait for it."
          echo "          pid ${pid} on ${host} is alive and was started with this marker."
          ;;
        GONE)
          echo "Verdict:  ABORTED — the marker says RUNNING, but pid ${pid} on ${host} is gone."
          echo "          The run that wrote it died without reaching a verdict. That is neither"
          echo "          a pass nor a test failure, and this file is not a result."
          ;;
        RECYCLED)
          echo "Verdict:  ABORTED — the marker says RUNNING and pid ${pid} exists, but that"
          echo "          process started after the marker was written, so it is a different"
          echo "          process reusing the number. The run itself is gone."
          ;;
        ELSEWHERE)
          echo "Verdict:  RUNNING — written on '${host}', and this is '${me}'. Whether pid"
          echo "          ${pid} is still running cannot be checked from here; check on ${host}."
          ;;
        *)
          echo "Verdict:  RUNNING — no usable pid recorded, so liveness cannot be checked."
          echo "          A marker written before pid stamping, or by an older gcp-ci.sh."
          ;;
      esac
      echo "          Phase reached: ${phase}"
      ;;
    *)
      echo "Verdict:  ${verdict}"
      if [[ "$verdict" == "STALE" ]]; then
        echo "          The report is stamped ${commit}, but HEAD here is ${head_commit}."
        echo "          It describes a DIFFERENT commit and is not a verdict on this tree."
      fi
      ;;
  esac

  echo "Run:      ${branch}@${commit} on ${vm}"
  if [[ -n "$total" && "$total" != "null" ]]; then
    echo "Stages:   ${passed:-0} passed, ${failed:-0} failed, of ${total}"
  else
    echo "Stages:   none recorded"
  fi
  echo "When:     ${when}"

  # Provenance: a report that names a different checkout was not produced here,
  # whatever directory you found it in.
  if [[ -z "$origin" || "$origin" == "null" || "$origin" == "unknown" ]]; then
    echo "Origin:   not recorded (written before origin stamping) — provenance unknown"
  elif [[ -d "$origin" && "$origin" -ef "$REPO_ROOT" ]]; then
    echo "Origin:   this checkout"
  else
    echo "Origin:   ${origin} — a DIFFERENT checkout produced this report"
  fi

  print_sibling_reports "$ours_epoch"

  if [[ -f "${REPORT_DIR}/${REPORT_FILENAME}" ]]; then
    echo "Full:     ${REPORT_DIR}/${REPORT_FILENAME}"
  fi
  echo "Exit:     ${final}"
  return "$final"
}

# print_sibling_reports [our-epoch] — the "somewhere else knows more" line.
# Newest first, so "read that one" points at exactly one thing.
print_sibling_reports() {
  local ours="${1:-}" found=0 epoch path
  while IFS=$'\t' read -r epoch path; do
    [[ -n "$path" ]] || continue
    if ((found == 0)); then
      echo "NEWER ELSEWHERE — another checkout of this repo holds a more recent report:"
      found=1
    fi
    printf '          %s  (%s)\n' "$path" "$(date -d "@${epoch}" -Iseconds 2>/dev/null || echo "$epoch")"
  done < <(newer_sibling_reports "$REPORT_DIR" "$ours" | sort -rn)
  ((found == 1)) && echo "          Read the top one, or re-run here. This directory is not the whole story."
  return 0
}

# ── Run (resume → test → collect → suspend) ─────────────────────────
cmd_run() {
  echo "════════════════════════════════════════════════════════════"
  echo "  Signalloom D2 E2E CI — Run"
  echo "  Project:  ${PROJECT}  |  VM: ${VM_NAME}"
  echo "  Timeout:  ${TIMEOUT_MINUTES}m  |  Observability: ${CI_ENABLE_OBSERVABILITY}"
  echo "════════════════════════════════════════════════════════════"

  # ── Declare the run before touching anything ────────────────────────
  # Capture the real source identity up front: the VM only ever sees an
  # untracked tarball and git-inits a throwaway snapshot repo, whose SHA is
  # meaningless. Everything written into REPORT_DIR from here on is stamped with
  # it, so no artifact in there can be read as belonging to another run.
  RUN_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  RUN_STARTED_AT="$(date -Iseconds)"
  echo "==> Source under test: ${RUN_BRANCH}@${RUN_COMMIT}  (started ${RUN_STARTED_AT})"
  rotate_reports

  # Armed before the first thing that can fail, for two reasons: a failure
  # between lock_acquire and push_code would otherwise leave the lock held with
  # nobody to release it, and a run that dies here would otherwise leave a
  # RUNNING marker that reads as "still going" forever.
  trap run_exit_trap EXIT
  set_run_phase "resuming-vm"

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
    AUTH_REQUIRED)
      # Not a VM problem. Saying "not found" here sent an operator to provision a
      # duplicate of a healthy VM.
      echo "ERROR: gcloud is not authenticated, so the VM's state is UNKNOWN — this is not" >&2
      echo "       evidence that ${VM_NAME} is missing. Run:  gcloud auth login" >&2
      exit 2
      ;;
    QUERY_FAILED)
      echo "ERROR: could not query ${VM_NAME} (the API call failed for a reason other than" >&2
      echo "       absence or auth). Its state is UNKNOWN — do NOT provision on this basis." >&2
      exit 2
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

  # ── Claim the VM before touching anything ──────────────────────────
  # Must come BEFORE push_code, which does `rm -rf ${REMOTE_WORK_DIR}`, and
  # before the pipeline's `make teardown`. Acquiring afterwards would protect
  # nothing — the damage is already done by then. test/ci-lock.bats asserts
  # this ordering, because it is the kind of thing a later refactor moves.
  echo "==> Claiming the VM..."
  set_run_phase "claiming-lock"
  lock_acquire

  # ── Synchronize the local checkout before every test run ───────────
  # The pipeline validates uncommitted local changes; reusing a previous
  # checkout would silently test stale files and preserve deleted paths.
  set_run_phase "pushing-code"
  push_code

  # ── Run the pipeline via SSH ──
  echo "==> Running pipeline on VM..."
  set_run_phase "pipeline"
  local pipeline_exit=0
  local source_commit="$RUN_COMMIT" source_branch="$RUN_BRANCH"

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
  set_run_phase "collecting-reports"
  # The previous run was rotated to ${REPORT_DIR}.prev at run START, not here.
  # `tar -xzf` overwrites only the files present in the archive and leaves
  # everything else untouched, so a run that aborted before writing reports used
  # to inherit the previous run's summary.json wholesale — a run that executed
  # zero tests printed a complete, plausible "5 passed, 3 failed" from stale
  # data, with only the commit field and file mtimes betraying it. Rotating here
  # closed that, but left the previous verdict readable for the whole duration
  # of the new run, which is how a mid-run poll read `5444d45 FAIL 8/12` off a
  # round that had already been superseded.
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

  # ── Decide once, then say the same thing everywhere ─────────────────
  local verdict final_exit
  verdict="$(classify_run_outcome "${REPORT_DIR}/summary.json" "$RUN_COMMIT" "$pipeline_exit")"
  final_exit="$(final_exit_code "$verdict" "$pipeline_exit")"

  case "$verdict" in
    PASS|FAIL)
      stamp_collected_summary
      echo ""
      echo "──── Summary ────"
      jq . "${REPORT_DIR}/summary.json"
      echo "──────────────────"
      ;;
    STALE)
      # The collected summary names a commit other than the one under test, so
      # it describes some other run. Reporting its verdict as this run's is the
      # exact failure this whole change exists to stop.
      local stale_commit
      stale_commit="$(jq -r '.commit // "unknown"' "${REPORT_DIR}/summary.json" 2>/dev/null || echo unknown)"
      echo "" >&2
      echo "ERROR: the collected summary.json is stamped ${stale_commit}, but this run" >&2
      echo "       tested ${RUN_COMMIT}. It describes a DIFFERENT run and is not a" >&2
      echo "       verdict on this one. Treating as ABORTED." >&2
      # STALE is the diagnosis; ABORTED is what gets recorded, because from the
      # outside that is what happened — this run produced no verdict of its own.
      write_run_status ABORTED "$RUN_PHASE" \
        "collected summary.json was stamped ${stale_commit}, not the ${RUN_COMMIT} under test" \
        "$final_exit"
      verdict="ABORTED"
      ;;
    ABORTED)
      # Say so loudly, and leave it in writing. A missing (or RUNNING-only)
      # summary means the pipeline died before it could report — a categorically
      # worse outcome than failing tests, and one that used to present as an
      # empty directory somebody had to interpret.
      echo "" >&2
      echo "ERROR: no verdict was produced — the pipeline did not reach the test" >&2
      echo "       stages. This is an aborted run, NOT a test failure." >&2
      echo "       Pipeline log on the VM: ${PIPELINE_LOG}" >&2
      if [[ -d "${REPORT_DIR}.prev" ]]; then
        echo "       The previous run's reports are in $(basename "${REPORT_DIR}").prev" >&2
        echo "       — they describe a DIFFERENT run. Do not read them as this one." >&2
      fi
      if ((pipeline_exit == 0)); then
        echo "       Pipeline exited 0 without producing reports; treating as failure." >&2
      fi
      # If the pipeline managed to write its own abort record it knows more than
      # we do — it names the phase it died in and any stages that had already
      # run. Keep it; only fall back to the local view when nothing came back.
      local collected_outcome=""
      if [[ -f "${REPORT_DIR}/summary.json" ]]; then
        collected_outcome="$(jq -r '.outcome // ""' "${REPORT_DIR}/summary.json" 2>/dev/null || echo "")"
      fi
      if [[ "$collected_outcome" == "ABORTED" ]]; then
        stamp_collected_summary
        echo "       The pipeline recorded the abort itself:" >&2
        jq -r '"       phase=\(.phase // "unknown") stages_run=\(.total_stages // 0) exit=\(.exit_code // "?")"' \
          "${REPORT_DIR}/summary.json" >&2 2>/dev/null || true
      else
        write_run_status ABORTED "$RUN_PHASE" \
          "run reached phase '${RUN_PHASE}' and produced no verdict; this is an ABORTED run, NOT a test failure" \
          "$final_exit"
      fi
      echo "       Recorded at ${REPORT_DIR}/summary.json (outcome: ABORTED)." >&2
      ;;
  esac

  if [[ -f "${REPORT_DIR}/${REPORT_FILENAME}" ]]; then
    echo "OpenReports: ${REPORT_DIR}/${REPORT_FILENAME}"
  fi

  # ── Release the lock while the VM can still be reached ─────────────
  # The lock lives on the VM, so it can only be released over SSH. Leaving this
  # to the EXIT trap put it AFTER the suspend below, where every release call
  # hit an unreachable host — and ci-lock.sh's read then reported "already
  # free", so each successful run left its own lock behind for the full 4h TTL.
  # The next caller met "REFUSING — the CI VM is in use" naming a run that had
  # finished, which trains exactly the --force reflex the lock exists to stop.
  lock_release

  # ── Suspend on success, leave running on failure for debugging ──
  if ((final_exit == 0)); then
    echo "==> PASS — suspending VM to save cost"
    gcloud compute instances suspend "$VM_NAME" \
      --zone="$ZONE" --project="$PROJECT"
    echo "==> VM suspended. Resume with: ./scripts/ci/gcp-ci.sh run"
  else
    echo "==> ${verdict} — VM left running for debugging"
    echo "    SSH in:  ./scripts/ci/gcp-ci.sh ssh"
    echo "    Logs:    tail -f /var/log/ci-pipeline.log"
    echo "    Reports: ls ${REMOTE_REPORT_DIR}/"
    echo ""
    echo "    When done, suspend manually:"
    echo "    gcloud compute instances suspend ${VM_NAME} --zone=${ZONE} --project=${PROJECT}"
    # Suspending is also what a PASS looks like, so the VM's state cannot carry
    # this verdict. The file can, and it survives the terminal that printed it.
    echo "    Suspending does not erase this: ${REPORT_DIR}/summary.json records"
    echo "    outcome=${verdict} for ${RUN_BRANCH}@${RUN_COMMIT}. Read that, not the VM state."
  fi

  exit "$final_exit"
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
  local status observed_at
  status="$(vm_status)"
  observed_at="$(date -Iseconds)"
  echo "VM: ${VM_NAME} | Project: ${PROJECT} | Zone: ${ZONE} | Status: ${status}"

  # A status with no time beside it is a claim about the past presented as the
  # present. One was read 14 seconds before the VM was resumed and relayed as
  # "it has not started". Both lines below are cheap and remove the guesswork:
  # `observed` dates the claim, `last started` dates the VM's own transition —
  # which is what an operator was otherwise reaching for gcloud --format to get.
  echo "Observed: ${observed_at}"
  local last_start
  last_start="$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --format='value(lastStartTimestamp)' 2>/dev/null || true)"
  [[ -n "$last_start" ]] && echo "Started:  ${last_start}"

  # SUSPENDED is both the success state and what an operator leaves behind after
  # killing an aborted run, so it says nothing on its own. The report does.
  print_local_run_status

  # "Is anyone using it?" should be one command, not a ps heuristic — reading
  # the process table was how three collisions were diagnosed AFTER the fact.
  if [[ "$status" == "RUNNING" ]]; then
    local lock
    lock_shim
    lock="$(CI_LOCK_REMOTE_EXEC="$LOCK_SHIM" bash "$LOCK_SCRIPT" status 2>/dev/null || echo "unknown")"
    echo "Lock: ${lock}"
    rm -f "$LOCK_SHIM"
    LOCK_SHIM=""
  fi

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
  # push-code is destructive on its own (`rm -rf ${REMOTE_WORK_DIR}`), so it
  # takes the lock too rather than being a quiet back door around it.
  push-code)   trap lock_release EXIT; lock_acquire; push_code ;;
  lock)        shift; lock_shim
               CI_LOCK_REMOTE_EXEC="$LOCK_SHIM" CI_LOCK_HOLDER="$LOCK_HOLDER_NAME" \
                 CI_LOCK_TOKEN="$LOCK_TOKEN_VALUE" GCP_CI_REMOTE_WORK_DIR="$REMOTE_WORK_DIR" \
                 bash "$LOCK_SCRIPT" "${@:-status}"
               rm -f "$LOCK_SHIM" ;;
  ssh)         cmd_ssh ;;
  status)      cmd_status ;;
  # Local, network-free, and safe to run while a lane is in flight: it reads
  # files and one process table entry, and touches neither gcloud nor the lock.
  state)       cmd_state ;;
  destroy)     cmd_destroy ;;
  *)
    echo "Usage: $0 {lock|provision|run|push-code|ssh|status|state|destroy}" >&2
    exit 1
    ;;
esac
