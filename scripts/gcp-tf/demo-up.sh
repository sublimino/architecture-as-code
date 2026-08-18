#!/usr/bin/env bash
#
# demo-up.sh — the LOCAL side of the GCP demo lane.
#
#   demo-up.sh up        # deliver this checkout, build the estate, test it
#   demo-up.sh test      # re-run the tests only, against a standing cluster
#   demo-up.sh connect   # open the IAP tunnel and print what a human needs
#   demo-up.sh status    # VM state and the verdict on disk, read-only
#   demo-up.sh payload F # build the delivery tarball at F and stop
#
# Terraform builds a hardened, IAP-only VM with no external IP.
# scripts/gcp-tf/demo-pipeline.sh runs ON that VM and stands the estate up.
# This file is what carries the code across, starts that pipeline, streams it
# back, collects the report, and decides whether the run passed.
#
# It is a SIBLING of scripts/ci/gcp-ci.sh and scripts/ci/gcp-tf-ci.sh. That
# first one owns the shared signalloom-ci VMs and their kind pipeline; the
# second owns the per-lane Terraform CI runners. This one owns the human-facing
# demo VM. None of the three reads or writes another's state, and gcp-ci.sh is
# frozen (test/fixtures/gcp-tf-ci/untouched-scripts.sha256 pins its digest).
#
# ─── Nothing is hardcoded; everything comes from the hand-off ───────────────
#
# deploy/gcp/<env>.handoff.json (schema signalloom.gcp.handoff/v1, written by
# `make gcp-tf-handoff`) carries project_id, zone, instance_name, app_port and
# the service accounts. Every value this script needs is read from there. A
# project id or a zone typed into a script is a value that goes stale silently
# and names the wrong estate at the worst possible moment.
#
# ─── ssh-agent ──────────────────────────────────────────────────────────────
#
# SSH_AUTH_SOCK is emptied before anything can call `gcloud compute ssh`. A
# populated agent makes IAP SSH fail with "agent refused operation", which reads
# as a VM provisioning fault and is a purely local one. That misdiagnosis has
# cost real debugging time on this project twice — on 2026-08-03 it burned ten
# minutes pointed at a VM that had finished provisioning in 124s.
#
# ─── Impersonation is not optional here, and not for the usual reason ───────
#
# Everywhere else in this estate impersonation exists because the human's own
# principal is roles/editor and cannot create IAM-shaped resources. Here it
# exists because the operator is EXTERNAL to the owning organisation, so
# `gcloud compute ssh` demands roles/compute.osLoginExternalUser — a role the
# operator cannot grant themselves. An org-INTERNAL service account is not
# subject to that rule, so every gcloud call below runs as one. This is
# measured, not theoretical: without it the SSH fails at the OS Login step with
# a permission error that names the external-user role, and the obvious next
# move (grant it) is one the operator has no authority to make.
#
# ─── A missing verdict is never a pass ──────────────────────────────────────
#
# On 2026-08-13 an absent summary.json was read as a pass twice in one day. The
# classifier below has exactly four answers — PASS, FAIL, ABORTED, STALE — and
# only the first of them exits 0. Absence of a report is ABORTED. A report
# stamped with a different commit than the one delivered is STALE, which is also
# an abort: it describes some other run.

set -euo pipefail

# ── Injectable boundaries ───────────────────────────────────────────────────
#
# Every external dependency is overridable, which is what makes the whole
# control flow exercisable by test/terraform-demo-driver.bats against stubs on
# PATH, with no cloud access and no credentials. A component that can only be
# tested against the real system is a component nobody tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GCP_TF_DEMO_REPO_ROOT:-}"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENV_KEY="${GCP_TF_DEMO_ENV:-${ENV:-}}"
HANDOFF_DIR="${GCP_TF_HANDOFF_DIR:-${REPO_ROOT}/deploy/gcp}"
GCLOUD_CMD="${GCP_TF_DEMO_GCLOUD:-gcloud}"
TAR_CMD="${GCP_TF_DEMO_TAR:-tar}"

# Where the delivered checkout and its reports live ON THE VM. Both are part of
# the contract with demo-pipeline.sh (chunk C) and are stated in
# docs/gcp-demo/RUNBOOK.md § "The pipeline contract".
REMOTE_WORK_DIR="${GCP_TF_DEMO_REMOTE_DIR:-/home/demo/osramp-demo}"
REMOTE_REPORT_DIR="${GCP_TF_DEMO_REMOTE_REPORT_DIR:-/home/demo/demo-reports}"
REMOTE_USER="${GCP_TF_DEMO_REMOTE_USER:-demo}"
REMOTE_LOG="${GCP_TF_DEMO_REMOTE_LOG:-/home/demo/demo-pipeline.log}"

# The pipeline, relative to the repo root. Overridable so the tests can drive a
# fixture tree, and so a rename on chunk C's side is a one-variable change here
# rather than a silent 127 on the VM.
PIPELINE_REL="${GCP_TF_DEMO_PIPELINE:-scripts/gcp-tf/demo-pipeline.sh}"

REPORT_DIR="${GCP_TF_DEMO_REPORT_DIR:-${REPO_ROOT}/demo-reports}"
SUMMARY_NAME="${GCP_TF_DEMO_SUMMARY_NAME:-summary.json}"

SSH_WAIT_ATTEMPTS="${GCP_TF_DEMO_SSH_WAIT_ATTEMPTS:-30}"
SSH_WAIT_INTERVAL="${GCP_TF_DEMO_SSH_WAIT_INTERVAL:-5}"
TIMEOUT_MINUTES="${GCP_TF_DEMO_TIMEOUT_MINUTES:-90}"
TIMEOUT_CMD="${GCP_TF_DEMO_TIMEOUT:-timeout}"

# The dashboard's SNI name is a property of the in-cluster Envoy Gateway and of
# Dex's pinned redirect URI. It is NOT the estate's DNS name, so it is
# deliberately not read from the hand-off's `hostname` field — those two are
# different names for different things, and conflating them produces a URL that
# resolves and then fails TLS on SNI.
DASHBOARD_HOST="${GCP_TF_DEMO_DASHBOARD_HOST:-dashboard.osramp.acme.local}"

# Dex pins its OIDC issuer AND its callback client to this port. See
# scripts/acceptance-test.sh:setup_gateway_forward — the comment there is the
# source of truth and says it in one line: "Dex pins its local issuer and
# callback client to this stable port". Any other local port reaches the
# Gateway and then fails the login redirect, which presents as a broken
# application rather than as a port mismatch. That is the whole reason this
# constant exists rather than being "whatever port is free".
DEX_PINNED_PORT="${GCP_TF_DEMO_DEX_PORT:-30754}"

DEMO_LOGIN_USER="${GCP_TF_DEMO_LOGIN_USER:-demo-user@signalloom.local}"
DEMO_LOGIN_PASS="${GCP_TF_DEMO_LOGIN_PASS:-demo-user}"

# An ssh-agent socket in the environment breaks IAP SSH. Emptied here, before
# any code path can reach `gcloud compute ssh`. Exported so a stub gcloud in the
# tests observes the same value the real one would — which is what makes this a
# behavioural assertion rather than a grep.
export SSH_AUTH_SOCK=

# Word-split deliberately: this is a command plus its flags supplied by the
# operator (e.g. "gcloud --verbosity=error"), not user input.
read -r -a GCLOUD <<<"$GCLOUD_CMD"

# Resolved from the hand-off in load_handoff.
PROJECT_ID=""
ZONE=""
INSTANCE_NAME=""
APP_PORT=""
OPERATOR_SA=""
HANDOFF_FILE=""

RUN_COMMIT="unknown"
RUN_BRANCH="unknown"
RUN_STARTED_AT=""
RUN_PHASE="not-started"

die() {
  printf 'demo-up: %s\n' "$*" >&2
  exit 2
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'demo-up: WARNING — %s\n' "$*" >&2; }

# ── Configuration, entirely from the hand-off ───────────────────────────────

require_env() {
  [ -n "$ENV_KEY" ] || die "ENV is required. Usage: ENV=demo-1 $(basename "$0") ${1:-up}"
  case "$ENV_KEY" in
    demo-[1-9] | demo-[1-9][0-9]* | ci-[1-9] | ci-[1-9][0-9]*) ;;
    *) die "ENV='${ENV_KEY}' is not a valid environment key (^(demo|ci)-[1-9][0-9]*\$)" ;;
  esac
}

# Read every value this script needs out of deploy/gcp/<env>.handoff.json.
#
# The absent-file message names the target that produces it. The alternative —
# "no such file" — sends a reader hunting for a file that was never meant to be
# written by hand, and the fields in it are derived from `terraform output`, so
# hand-writing one produces a driver pointed at an estate that does not exist.
load_handoff() {
  HANDOFF_FILE="${HANDOFF_DIR}/${ENV_KEY}.handoff.json"

  if [ ! -f "$HANDOFF_FILE" ]; then
    cat >&2 <<EOF
demo-up: no hand-off for ENV=${ENV_KEY}.

  Expected: ${HANDOFF_FILE}

  That file carries the project, the zone, the instance name and the service
  accounts. Nothing here is hardcoded, so without it this script does not know
  which estate to talk to and will not guess.

  Produce it with:

      make gcp-tf-handoff ENV=${ENV_KEY} TF_STATE_BUCKET=<bucket>

  It is derived from 'terraform output -json' and is untracked, because every
  field in it names a real project. Do not hand-write one.
EOF
    exit 2
  fi

  command -v jq >/dev/null 2>&1 || die "jq is required to read ${HANDOFF_FILE}"
  jq -e . "$HANDOFF_FILE" >/dev/null 2>&1 ||
    die "${HANDOFF_FILE} is not valid JSON — regenerate it with 'make gcp-tf-handoff ENV=${ENV_KEY}'"

  local schema
  schema="$(jq -r '.schema // ""' "$HANDOFF_FILE")"
  case "$schema" in
    signalloom.gcp.handoff/v1) ;;
    "") die "${HANDOFF_FILE} declares no schema — it was not written by 'make gcp-tf-handoff'" ;;
    *) die "${HANDOFF_FILE} declares schema '${schema}', which this driver does not understand (expected signalloom.gcp.handoff/v1)" ;;
  esac

  PROJECT_ID="$(jq -r '.project_id // ""' "$HANDOFF_FILE")"
  ZONE="$(jq -r '.zone // ""' "$HANDOFF_FILE")"
  INSTANCE_NAME="$(jq -r '.instance_name // ""' "$HANDOFF_FILE")"
  APP_PORT="$(jq -r '.app_port // ""' "$HANDOFF_FILE")"

  # The SSH identity is a DIFFERENT service account from the Terraform deploy SA
  # and must not silently fall back to it. The deploy SA holds resource-creation
  # rights the demo lane has no business exercising, and an operator who typed
  # nothing would get those rights by accident. So: explicit override first,
  # then the hand-off's own field, then a refusal that names both.
  OPERATOR_SA="${GCP_TF_DEMO_OPERATOR_SA:-$(jq -r '.operator_sa // .operator_service_account // ""' "$HANDOFF_FILE")}"

  local missing=""
  [ -n "$PROJECT_ID" ] || missing="${missing} project_id"
  [ -n "$ZONE" ] || missing="${missing} zone"
  [ -n "$INSTANCE_NAME" ] || missing="${missing} instance_name"
  [ -n "$APP_PORT" ] || missing="${missing} app_port"
  if [ -n "$missing" ]; then
    die "${HANDOFF_FILE} is missing required field(s):${missing} — regenerate it with 'make gcp-tf-handoff ENV=${ENV_KEY}'"
  fi

  local env_in_file
  env_in_file="$(jq -r '.environment_key // .env // ""' "$HANDOFF_FILE")"
  if [ -n "$env_in_file" ] && [ "$env_in_file" != "$ENV_KEY" ]; then
    die "${HANDOFF_FILE} describes environment '${env_in_file}', not '${ENV_KEY}'. Reading it would point this run at the wrong estate."
  fi
}

# Refuse to reach the cloud as the human. See the header for why this is about
# osLoginExternalUser here and about IAM-shaped resources everywhere else.
require_operator_sa() {
  [ -n "$OPERATOR_SA" ] && return 0
  cat >&2 <<EOF
demo-up: refusing to run without an operator service account.

  ${HANDOFF_FILE} carries no 'operator_sa', and GCP_TF_DEMO_OPERATOR_SA is not
  set, so every gcloud call below would run as your own principal.

  That does not fail cleanly. The operator on this estate is EXTERNAL to the
  owning organisation, so 'gcloud compute ssh' requires
  roles/compute.osLoginExternalUser — which an external principal cannot grant
  itself. The error names an OS Login permission, so the diagnosis it invites is
  "grant that role", which is not an action you have the authority to take.
  An org-internal service account is not subject to the rule at all.

  Fix either of:
      make gcp-tf-handoff ENV=${ENV_KEY} TF_STATE_BUCKET=<bucket>   # republish it
      GCP_TF_DEMO_OPERATOR_SA=<sa>@<project>.iam.gserviceaccount.com make ...
EOF
  exit 2
}

# ── gcloud boundary ─────────────────────────────────────────────────────────
#
# Every call goes through these three so the impersonation flag, the project,
# the zone and the emptied agent socket cannot be forgotten on one path and
# present on the others. SSH_AUTH_SOCK is already empty process-wide; it is
# re-stated on the call itself so the guard survives anyone later sourcing this
# file or reordering the header.

gcloud_common() {
  printf '%s\n' "--project=${PROJECT_ID}" "--impersonate-service-account=${OPERATOR_SA}"
}

vm_ssh() {
  local args=()
  mapfile -t args < <(gcloud_common)
  SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute ssh "$INSTANCE_NAME" \
    --zone="$ZONE" "${args[@]}" --tunnel-through-iap \
    --command="$1"
}

vm_scp() {
  local args=()
  mapfile -t args < <(gcloud_common)
  SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute scp --tunnel-through-iap \
    --zone="$ZONE" "${args[@]}" "$@"
}

# An unreadable state is not an absent VM. Distinguishing them matters: acting
# on "absent" here would mean telling the operator to re-apply Terraform against
# an estate that is standing and healthy.
vm_status() {
  local out rc=0 args=()
  mapfile -t args < <(gcloud_common)
  out="$(SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" "${args[@]}" --format='get(status)' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | tr -d '[:space:]'
    return 0
  fi
  case "$out" in
    *"was not found"* | *"notFound"* | *"does not exist"*) printf 'NOT_FOUND' ;;
    *"gcloud auth login"* | *"Reauthentication"* | *"credentials"* | *"invalid_grant"*) printf 'AUTH_REQUIRED' ;;
    *) printf 'QUERY_FAILED' ;;
  esac
}

wait_for_ssh() {
  local attempts=0
  while [ "$attempts" -lt "$SSH_WAIT_ATTEMPTS" ]; do
    if vm_ssh "echo ready" >/dev/null 2>&1; then
      log "SSH is available on ${INSTANCE_NAME}"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep "$SSH_WAIT_INTERVAL"
  done
  printf 'demo-up: %s did not accept SSH within %ds.\n' \
    "$INSTANCE_NAME" "$((SSH_WAIT_ATTEMPTS * SSH_WAIT_INTERVAL))" >&2
  printf '         If gcloud mentioned "agent refused operation" this is a LOCAL\n' >&2
  printf '         ssh-agent fault, not the VM. This script already empties\n' >&2
  printf '         SSH_AUTH_SOCK, so an ad-hoc gcloud call is the likelier culprit.\n' >&2
  return 2
}

ensure_vm_ready() {
  local status args=()
  mapfile -t args < <(gcloud_common)
  status="$(vm_status)"
  case "$status" in
    RUNNING)
      log "${INSTANCE_NAME} is already running"
      ;;
    SUSPENDED)
      log "resuming suspended ${INSTANCE_NAME}"
      SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances resume "$INSTANCE_NAME" \
        --zone="$ZONE" "${args[@]}" --quiet
      wait_for_ssh || return 2
      ;;
    TERMINATED | STOPPED)
      log "starting stopped ${INSTANCE_NAME}"
      SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances start "$INSTANCE_NAME" \
        --zone="$ZONE" "${args[@]}" --quiet
      wait_for_ssh || return 2
      ;;
    NOT_FOUND)
      die "${INSTANCE_NAME} does not exist in ${PROJECT_ID}/${ZONE} — run: make gcp-tf-up ENV=${ENV_KEY}"
      ;;
    AUTH_REQUIRED)
      die "gcloud is not authenticated, so ${INSTANCE_NAME}'s state is UNKNOWN. This is NOT evidence the VM is missing — do not re-apply on this basis. Run: gcloud auth login"
      ;;
    *)
      die "could not read ${INSTANCE_NAME}'s state (got '${status}') — refusing to act on an unknown state"
      ;;
  esac
  return 0
}

# ── Delivery ────────────────────────────────────────────────────────────────

# Build the tarball that gets carried to the VM.
#
# The exclusion list is the security boundary of this whole lane, so it is a
# list of reasons rather than a list of paths:
#
#   .git          the VM does not need history, and shipping it would carry
#                 every branch and every credential ever committed in error.
#                 Kustomize DOES need a .git as a security boundary for relative
#                 path traversal (`../base/` is rejected without one) — the
#                 pipeline git-inits a throwaway snapshot repo on the VM for
#                 that, exactly as scripts/ci/vm-pipeline.sh does. It is a
#                 marker, not history.
#   .keys         signing keys. Never leave this machine. The pipeline mints its
#                 own on the VM; a key that rides along is a key that exists in
#                 two places and gets revoked in one.
#   *.tfvars      real inputs. They name the project, the billing account and
#                 the operator's own domains.
#   *.handoff.json and deploy/gcp/deploy-sa — the same, plus service account
#                 identities the demo pipeline has no use for.
#   node_modules, .terraform* — reinstallable, and together they are most of the
#                 bytes. Excluding them is what makes this transfer seconds.
#
# Anything added here needs a reason on the same footing. An exclusion with no
# reason is how a file the pipeline needs disappears and nobody can say when.
build_payload() {
  local out="$1"
  [ -n "$out" ] || die "build_payload needs an output path"

  # Presence before packaging. A payload that omits the pipeline produces a 127
  # on the VM twenty minutes later, by which point the obvious suspect is the
  # VM.
  if [ ! -f "${REPO_ROOT}/${PIPELINE_REL}" ]; then
    die "no pipeline at ${REPO_ROOT}/${PIPELINE_REL}. It is supplied by scripts/gcp-tf/demo-pipeline.sh; override the path with GCP_TF_DEMO_PIPELINE=<relative-path>."
  fi

  "$TAR_CMD" -C "$REPO_ROOT" \
    --exclude='.git' \
    --exclude='.keys' \
    --exclude='.claude' \
    --exclude='.worktrees' \
    --exclude='node_modules' \
    --exclude='.terraform' \
    --exclude='.terraform*' \
    --exclude='*.tfvars' \
    --exclude='*.tfvars.json' \
    --exclude='*.tfplan' \
    --exclude='*.handoff.json' \
    --exclude='deploy/gcp/deploy-sa' \
    --exclude='ci-reports*' \
    --exclude='demo-reports*' \
    --exclude='test-results' \
    --exclude='playwright-report' \
    -czf "$out" .

  # Verify what was built rather than trusting the flag list. A tar --exclude
  # that silently matches nothing (a renamed directory, a pattern that needed a
  # leading ./) is indistinguishable from a correct one at this point, and the
  # cost of being wrong is a signing key in a bucket. Checking the artefact is
  # the only assertion that survives a refactor of the list above.
  local leaked
  leaked="$("$TAR_CMD" -tzf "$out" |
    grep -E '(^|/)(\.git/|\.keys/|node_modules/|\.terraform)|\.tfvars($|\.json$)|\.handoff\.json$|deploy/gcp/deploy-sa$' |
    head -5 || true)"
  if [ -n "$leaked" ]; then
    printf 'demo-up: REFUSING to deliver — excluded material is present in the payload:\n' >&2
    printf '%s\n' "$leaked" | while IFS= read -r entry; do printf '  %s\n' "$entry" >&2; done
    printf 'demo-up: this is the exclusion list failing, not a transfer problem.\n' >&2
    rm -f "$out"
    exit 2
  fi
  return 0
}

deliver_code() {
  log "delivering this checkout to ${INSTANCE_NAME}:${REMOTE_WORK_DIR}"
  local tarball
  tarball="$(mktemp "${TMPDIR:-/tmp}/osramp-demo-${ENV_KEY}.XXXXXX.tar.gz")"
  build_payload "$tarball"

  local size
  size="$(wc -c <"$tarball" | tr -d ' ')"
  log "payload: ${size} bytes"

  vm_scp "$tarball" "${INSTANCE_NAME}:/tmp/osramp-demo-delivery.tar.gz"

  # rm -rf then re-extract, rather than extracting over the top. `tar -xzf`
  # overwrites the files in the archive and leaves everything else alone, so a
  # file deleted in this checkout would survive on the VM and the pipeline would
  # test a tree that exists nowhere in git.
  vm_ssh "sudo rm -rf $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo mkdir -p $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo tar -xzf /tmp/osramp-demo-delivery.tar.gz -C $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo chown -R $(printf '%q' "$REMOTE_USER"):$(printf '%q' "$REMOTE_USER") $(printf '%q' "$REMOTE_WORK_DIR") \
    && rm -f /tmp/osramp-demo-delivery.tar.gz"

  rm -f "$tarball"
  log "delivered to ${REMOTE_WORK_DIR}"
}

# ── Run state: written at every transition, starting before the VM is touched ─
#
# Lifted from scripts/ci/gcp-ci.sh, which arrived at it the hard way. The
# failure it removes is a report directory whose newest file describes a
# PREVIOUS run: a mid-run poll then reads a verdict that has already been
# superseded, and an aborted run inherits its predecessor's "all green".

rotate_reports() {
  if [ -d "$REPORT_DIR" ] && [ -n "$(ls -A "$REPORT_DIR" 2>/dev/null)" ]; then
    rm -rf "${REPORT_DIR}.prev"
    mv "$REPORT_DIR" "${REPORT_DIR}.prev"
    log "previous run rotated to $(basename "${REPORT_DIR}").prev"
  fi
  mkdir -p "$REPORT_DIR"
  return 0
}

write_run_status() {
  local outcome="$1" phase="$2" note="${3:-}" exit_code="${4:-}"
  mkdir -p "$REPORT_DIR" 2>/dev/null || return 0
  local tmp="${REPORT_DIR}/.${SUMMARY_NAME}.tmp"
  if jq -n \
    --arg outcome "$outcome" \
    --arg phase "$phase" \
    --arg note "$note" \
    --arg commit "$RUN_COMMIT" \
    --arg branch "$RUN_BRANCH" \
    --arg env "$ENV_KEY" \
    --arg instance "$INSTANCE_NAME" \
    --arg started_at "$RUN_STARTED_AT" \
    --arg written_at "$(date -Iseconds)" \
    --arg exit_code "$exit_code" \
    --arg pid "$$" \
    --arg host "$(hostname -s 2>/dev/null || echo unknown)" \
    --arg origin "$REPO_ROOT" \
    '{outcome: $outcome, overall: $outcome, phase: $phase, commit: $commit,
      branch: $branch, env: $env, instance: $instance, started_at: $started_at,
      written_at: $written_at, pid: ($pid | tonumber), host: $host,
      origin: $origin, note: $note}
     + (if $exit_code == "" then {} else {exit_code: ($exit_code | tonumber)} end)' \
    >"$tmp" 2>/dev/null; then
    mv "$tmp" "${REPORT_DIR}/${SUMMARY_NAME}"
  else
    rm -f "$tmp"
  fi
  return 0
}

set_run_phase() {
  RUN_PHASE="$1"
  write_run_status RUNNING "$1" "run in flight (pid $$ on $(hostname -s 2>/dev/null || echo unknown)); this is not a verdict"
  return 0
}

# classify_run_outcome <summary-file> <expected-commit> <pipeline-exit>
# Echoes exactly one of: PASS | FAIL | ABORTED | STALE.
#
# The two dishonest readings this exists to stop:
#   RUNNING — our own start marker survived collection, i.e. NOTHING came back
#             from the VM. Absence of a report is an abort, never a pass.
#   STALE   — the summary names a commit other than the one delivered, so it
#             describes some other run. A green run cannot reach this branch:
#             the pipeline stamps the commit this script hands it.
classify_run_outcome() {
  local summary="$1" expected_commit="$2" pipeline_exit="$3"
  [ -f "$summary" ] || {
    echo ABORTED
    return 0
  }

  local outcome commit
  outcome="$(jq -r '.outcome // .overall // "UNKNOWN"' "$summary" 2>/dev/null || echo UNKNOWN)"
  commit="$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)"

  case "$outcome" in
    RUNNING | ABORTED | UNKNOWN | "")
      echo ABORTED
      return 0
      ;;
  esac

  if [ "$expected_commit" != "unknown" ] && [ "$commit" != "unknown" ] &&
    [ "$commit" != "$expected_commit" ]; then
    echo STALE
    return 0
  fi

  # A summary saying PASS does not outrank a non-zero pipeline exit; that pair
  # means the run died after writing its report, and exiting 0 on it would be
  # the same lie in a different file.
  if [ "$outcome" = "PASS" ] && [ "$pipeline_exit" -eq 0 ]; then
    echo PASS
  else
    echo FAIL
  fi
  return 0
}

# The one place the run's exit status is decided, so the status, the message and
# the file on disk cannot disagree with each other.
final_exit_code() {
  local verdict="$1" pipeline_exit="$2"
  case "$verdict" in
    PASS) echo 0 ;;
    FAIL) if [ "$pipeline_exit" -eq 0 ]; then echo 1; else echo "$pipeline_exit"; fi ;;
    *) if [ "$pipeline_exit" -eq 0 ]; then echo 2; else echo "$pipeline_exit"; fi ;;
  esac
  return 0
}

# Under `set -e` a failing final command in an EXIT trap replaces the status the
# script asked for; this repo has already lost a run with 8/8 green stages to
# exactly that. So rc is captured FIRST, every cleanup is `|| true`, and the last
# statement is an explicit `exit "$rc"`.
#
# `$?` alone is not enough to exit on either. bash runs this trap on SIGINT as
# well as on a normal exit, and on a signal `$?` is 0 — so a Ctrl-C'd run wrote
# ABORTED into the summary and then reported success. The status therefore comes
# from final_exit_code, the same function cmd_up uses.
run_exit_trap() {
  local rc=$?
  trap - EXIT INT TERM
  local outcome=""
  if [ -f "${REPORT_DIR}/${SUMMARY_NAME}" ]; then
    outcome="$(jq -r '.outcome // ""' "${REPORT_DIR}/${SUMMARY_NAME}" 2>/dev/null || echo "")"
  fi
  case "$outcome" in
    RUNNING)
      rc="$(final_exit_code ABORTED "$rc" 2>/dev/null || echo 2)"
      write_run_status ABORTED "$RUN_PHASE" \
        "run exited during phase '${RUN_PHASE}' without reaching a verdict; this is an ABORTED run, NOT a test failure" \
        "$rc" || true
      ;;
    ABORTED)
      rc="$(final_exit_code ABORTED "$rc" 2>/dev/null || echo 2)"
      ;;
  esac
  exit "$rc"
}

on_int() { exit 130; }
on_term() { exit 143; }

# ── The pipeline invocation ─────────────────────────────────────────────────
#
# The contract with scripts/gcp-tf/demo-pipeline.sh (chunk C), stated here
# because the two halves land on different branches and a contract that lives in
# only one of them is a contract nobody can check:
#
#   invoked as   : bash <PIPELINE_REL>, with cwd = SL_DEMO_WORK_DIR
#   configured by: the SL_DEMO_* environment below, nothing else
#   must write   : SL_DEMO_REPORT_DIR/summary.json, a JSON object carrying at
#                  least {outcome: "PASS"|"FAIL"|"ABORTED", commit: "<sha>"}.
#                  The commit MUST be the SL_DEMO_SOURCE_COMMIT it was handed —
#                  the VM's own git SHA is a throwaway snapshot and means
#                  nothing, so stamping that instead makes every run look STALE.
#   exit status  : 0 pass, non-zero otherwise. A zero exit with no summary is
#                  treated as ABORTED here, never as a pass.
#
# Sets the global PIPELINE_EXIT rather than echoing it. That is not a style
# choice: `pipeline_exit="$(run_pipeline …)"` captures this function's stdout,
# which IS the pipeline's live output, so the operator would watch a blank
# terminal for ninety minutes and then receive the whole log at once. Streaming
# and returning a value through the same channel cannot both work.
PIPELINE_EXIT=0
run_pipeline() {
  local stage="$1"
  PIPELINE_EXIT=0

  local remote_cmd
  printf -v remote_cmd 'cd %q && bash %q' "$REMOTE_WORK_DIR" "$PIPELINE_REL"

  local envs
  printf -v envs 'SL_DEMO_ENV=%q SL_DEMO_STAGE=%q SL_DEMO_WORK_DIR=%q SL_DEMO_REPORT_DIR=%q SL_DEMO_SUMMARY_FILE=%q SL_DEMO_APP_PORT=%q SL_DEMO_HOSTNAME=%q SL_DEMO_LOG=%q SL_DEMO_SOURCE_COMMIT=%q SL_DEMO_SOURCE_BRANCH=%q' \
    "$ENV_KEY" "$stage" "$REMOTE_WORK_DIR" "$REMOTE_REPORT_DIR" \
    "${REMOTE_REPORT_DIR}/${SUMMARY_NAME}" "$APP_PORT" "$DASHBOARD_HOST" \
    "$REMOTE_LOG" "$RUN_COMMIT" "$RUN_BRANCH"

  log "running the pipeline on ${INSTANCE_NAME} (stage=${stage}, fence=${TIMEOUT_MINUTES}m)"
  log "output streams below; it is also being written to ${REPORT_DIR}/pipeline.log"

  # The fence is enforced, not merely printed. A wedged SSH session otherwise
  # blocks the run forever. SIGTERM first and SIGKILL 60s later, so the remote
  # pipeline gets a chance to flush its report files before the tunnel is torn
  # down — a killed pipeline that wrote nothing is an ABORTED with no diagnosis.
  #
  # PIPESTATUS, not $?, because the tee is what the shell sees last.
  set +e
  "$TIMEOUT_CMD" -k 60s "${TIMEOUT_MINUTES}m" \
    env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute ssh "$INSTANCE_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA" \
    --tunnel-through-iap \
    --command="sudo -u $(printf '%q' "$REMOTE_USER") env ${envs} bash -l -c $(printf '%q' "$remote_cmd")" \
    2>&1 | tee -a "${REPORT_DIR}/pipeline.log"
  PIPELINE_EXIT="${PIPESTATUS[0]}"
  set -e

  if [ "$PIPELINE_EXIT" -eq 124 ]; then
    warn "the pipeline exceeded the ${TIMEOUT_MINUTES}m fence and was terminated. Raise it with GCP_TF_DEMO_TIMEOUT_MINUTES=<n>."
  fi
  return 0
}

collect_reports() {
  log "collecting reports from ${REMOTE_REPORT_DIR}"
  local archive="/tmp/osramp-demo-${ENV_KEY}-reports.tar.gz"
  # The report directory belongs to the restricted demo account while IAP SCP
  # authenticates as the operator SA, so it is packaged via sudo rather than
  # weakening the directory's permissions just to collect artefacts.
  if vm_ssh "sudo -u $(printf '%q' "$REMOTE_USER") tar -C $(printf '%q' "$REMOTE_REPORT_DIR") -czf $(printf '%q' "$archive") ." &&
    vm_scp "${INSTANCE_NAME}:${archive}" "${REPORT_DIR}/" &&
    "$TAR_CMD" -xzf "${REPORT_DIR}/$(basename "$archive")" -C "$REPORT_DIR"; then
    rm -f "${REPORT_DIR}/$(basename "$archive")"
    vm_ssh "rm -f $(printf '%q' "$archive")" >/dev/null 2>&1 || true
    log "reports collected into ${REPORT_DIR}"
    return 0
  fi
  # Deliberately not fatal on its own: a failed collection is diagnosed by the
  # classifier below, which will read the absent summary as ABORTED. Turning it
  # into an immediate exit here would lose the pipeline's own exit status.
  warn "failed to collect report files — the verdict below is derived without them"
  return 0
}

report_verdict() {
  local verdict="$1" final_exit="$2" pipeline_exit="$3"
  local summary="${REPORT_DIR}/${SUMMARY_NAME}"

  case "$verdict" in
    PASS | FAIL)
      echo ""
      echo "──── Summary (${ENV_KEY}) ────"
      jq . "$summary" 2>/dev/null || cat "$summary"
      echo "──────────────────────────────"
      ;;
    STALE)
      local stale_commit
      stale_commit="$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)"
      {
        echo ""
        echo "ERROR: the collected summary is stamped ${stale_commit}, but this run"
        echo "       delivered ${RUN_COMMIT}. It describes a DIFFERENT run and is not a"
        echo "       verdict on this one. Treating as ABORTED."
      } >&2
      write_run_status ABORTED "$RUN_PHASE" \
        "collected summary was stamped ${stale_commit}, not the ${RUN_COMMIT} delivered" \
        "$final_exit"
      ;;
    ABORTED)
      {
        echo ""
        echo "ERROR: no verdict was produced — the pipeline did not reach the test"
        echo "       stages. This is an ABORTED run, NOT a test failure."
        echo "       Pipeline log on the VM: ${REMOTE_LOG}"
        echo "       Streamed copy locally:  ${REPORT_DIR}/pipeline.log"
        if [ -d "${REPORT_DIR}.prev" ]; then
          echo "       The previous run's reports are in $(basename "${REPORT_DIR}").prev —"
          echo "       they describe a DIFFERENT run. Do not read them as this one."
        fi
        if [ "$pipeline_exit" -eq 0 ]; then
          echo "       The pipeline exited 0 without producing a report. A missing verdict"
          echo "       is never a pass, so this is being treated as a failure."
        fi
      } >&2
      local collected=""
      if [ -f "$summary" ]; then
        collected="$(jq -r '.outcome // ""' "$summary" 2>/dev/null || echo "")"
      fi
      if [ "$collected" != "ABORTED" ]; then
        write_run_status ABORTED "$RUN_PHASE" \
          "run reached phase '${RUN_PHASE}' and produced no verdict; this is an ABORTED run, NOT a test failure" \
          "$final_exit"
      fi
      echo "       Recorded at ${summary} (outcome: ABORTED)." >&2
      ;;
  esac
  return 0
}

# ── The connect instructions ────────────────────────────────────────────────
#
# This is the deliverable the human actually sees, so it is a function of its
# own and is asserted line by line in test/terraform-demo-driver.bats.
print_connect_instructions() {
  local port="$1"
  cat <<EOF

════════════════════════════════════════════════════════════════════
  Signal Loom demo — ${ENV_KEY}
════════════════════════════════════════════════════════════════════

  URL:      https://${DASHBOARD_HOST}:${port}

  1. Add this line to /etc/hosts (once per machine):

         127.0.0.1 ${DASHBOARD_HOST}

     The dashboard is served by the Envoy Gateway behind an SNI hostname.
     Browsing to https://localhost:${port} reaches the Gateway and is then
     rejected at TLS, because the name in the request is not the name the
     certificate and the route are keyed on.

  2. The certificate is SELF-SIGNED. Your browser will interrupt with a
     warning. Accept it — there is no public CA in this estate and there is
     not meant to be.

  3. Log in through Dex:

         username: ${DEMO_LOGIN_USER}
         password: ${DEMO_LOGIN_PASS}

  4. Port ${port} is NOT negotiable. Dex pins its OIDC issuer and its
     callback client to it. Any other local port reaches the Gateway and then
     fails the login redirect — which presents as a broken application, not as
     a port mismatch, and costs an hour before anyone suspects the tunnel.

  Confirm the tunnel BEFORE opening a browser:

      curl -k --resolve ${DASHBOARD_HOST}:${port}:127.0.0.1 https://${DASHBOARD_HOST}:${port}/readyz

  That prints 'ready' when the estate is up. If it hangs, the tunnel is not
  bound. If it connects and 404s, the tunnel is fine and the estate is not.

  The tunnel runs in the FOREGROUND below. Ctrl-C closes it.

════════════════════════════════════════════════════════════════════
EOF
}

# ── Commands ────────────────────────────────────────────────────────────────

# Shared preamble for every command that reaches the cloud.
prepare() {
  require_env "$1"
  load_handoff
  require_operator_sa
}

capture_source_identity() {
  RUN_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  RUN_STARTED_AT="$(date -Iseconds)"
}

# stage is "full" (build the estate, then test it) or "test" (tests only).
run_lane() {
  local stage="$1"

  capture_source_identity
  echo "════════════════════════════════════════════════════════════"
  echo "  Signal Loom GCP demo — ${stage}"
  echo "  ENV: ${ENV_KEY}  |  project: ${PROJECT_ID}  |  VM: ${INSTANCE_NAME}"
  echo "  Source: ${RUN_BRANCH}@${RUN_COMMIT}  (started ${RUN_STARTED_AT})"
  echo "════════════════════════════════════════════════════════════"

  rotate_reports

  # Armed before the first thing that can fail: a run that dies from here on
  # would otherwise leave a RUNNING marker that reads as "still going" forever.
  trap run_exit_trap EXIT
  trap on_int INT
  trap on_term TERM

  set_run_phase "resuming-vm"
  ensure_vm_ready || exit 2

  set_run_phase "delivering-code"
  deliver_code

  set_run_phase "pipeline"
  run_pipeline "$stage"

  set_run_phase "collecting-reports"
  collect_reports

  local verdict final_exit
  verdict="$(classify_run_outcome "${REPORT_DIR}/${SUMMARY_NAME}" "$RUN_COMMIT" "$PIPELINE_EXIT")"
  final_exit="$(final_exit_code "$verdict" "$PIPELINE_EXIT")"
  report_verdict "$verdict" "$final_exit" "$PIPELINE_EXIT"

  echo ""
  if [ "$final_exit" -eq 0 ]; then
    echo "==> PASS — the estate is standing and tested."
    echo "    Open it with:  make gcp-tf-connect ENV=${ENV_KEY}"
  else
    echo "==> ${verdict} — the VM is left RUNNING so it can be inspected." >&2
    echo "    SSH in:   gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} \\" >&2
    echo "                --impersonate-service-account=${OPERATOR_SA} --tunnel-through-iap" >&2
    echo "    VM log:   ${REMOTE_LOG}" >&2
    echo "    Verdict:  ${REPORT_DIR}/${SUMMARY_NAME} records outcome=${verdict}" >&2
    echo "              for ${RUN_BRANCH}@${RUN_COMMIT}. Read that file, not the VM state." >&2
    echo "    Suspend it when you are done — it bills until you do:" >&2
    echo "      gcloud compute instances suspend ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} \\" >&2
    echo "        --impersonate-service-account=${OPERATOR_SA}" >&2
  fi

  exit "$final_exit"
}

cmd_up() {
  prepare up
  run_lane full
}

cmd_test() {
  prepare test
  run_lane test
}

cmd_connect() {
  prepare connect

  local port="$APP_PORT"
  if [ "$port" != "$DEX_PINNED_PORT" ]; then
    if [ "${GCP_TF_DEMO_ALLOW_PORT_MISMATCH:-0}" != "1" ]; then
      cat >&2 <<EOF
demo-up: REFUSING to open the tunnel on port ${port}.

  The hand-off says app_port=${port}, but Dex pins its OIDC issuer and its
  callback client to ${DEX_PINNED_PORT}. On any other port the dashboard loads,
  the login redirect fails, and the result presents as a broken application
  rather than as a port mismatch — which is an hour of debugging aimed at the
  wrong layer.

  Fix the estate (terraform/environments app_port) rather than the tunnel. If
  you genuinely mean to open a non-Dex port:

      GCP_TF_DEMO_ALLOW_PORT_MISMATCH=1 make gcp-tf-connect ENV=${ENV_KEY}
EOF
      exit 2
    fi
    warn "opening ${port}, not the Dex-pinned ${DEX_PINNED_PORT}. The dashboard login WILL fail."
  fi

  # Printed BEFORE the tunnel, because the tunnel blocks in the foreground and
  # anything printed after it would only appear once the operator had already
  # given up and pressed Ctrl-C.
  print_connect_instructions "$port"

  log "opening IAP tunnel: localhost:${port} -> ${INSTANCE_NAME}:${port}"
  exec env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute start-iap-tunnel "$INSTANCE_NAME" "$port" \
    --local-host-port="localhost:${port}" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA"
}

cmd_status() {
  prepare status
  printf 'env:      %s\n' "$ENV_KEY"
  printf 'project:  %s\n' "$PROJECT_ID"
  printf 'instance: %s (%s)\n' "$INSTANCE_NAME" "$(vm_status)"
  printf 'handoff:  %s\n' "$HANDOFF_FILE"
  local summary="${REPORT_DIR}/${SUMMARY_NAME}"
  if [ -f "$summary" ]; then
    printf 'verdict:  %s for %s@%s (as of %s)\n' \
      "$(jq -r '.outcome // .overall // "UNKNOWN"' "$summary" 2>/dev/null || echo UNKNOWN)" \
      "$(jq -r '.branch // "unknown"' "$summary" 2>/dev/null || echo unknown)" \
      "$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)" \
      "$(jq -r '.collected_at // .written_at // "unknown"' "$summary" 2>/dev/null || echo unknown)"
  else
    printf 'verdict:  none — no run has finished in %s\n' "$REPORT_DIR"
  fi
}

# Build the payload and stop. Exists so the exclusion list is directly
# inspectable and directly testable without a cloud account: the assertion that
# no secret material rides along must not depend on reaching GCP.
cmd_payload() {
  local out="${1:-}"
  [ -n "$out" ] || die "usage: $(basename "$0") payload <output.tar.gz>"
  build_payload "$out"
  printf '%s\n' "$out"
}

case "${1:-up}" in
  up) cmd_up ;;
  test) cmd_test ;;
  connect) cmd_connect ;;
  status) cmd_status ;;
  payload)
    shift
    cmd_payload "${1:-}"
    ;;
  -h | --help | help) sed -n '2,20p' "$0" ;;
  *) die "usage: $(basename "$0") {up|test|connect|status|payload <file>}" ;;
esac
