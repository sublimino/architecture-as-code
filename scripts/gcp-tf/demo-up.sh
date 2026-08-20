#!/usr/bin/env bash
#
# demo-up.sh — the LOCAL side of the GCP demo lane.
#
#   demo-up.sh up          # deliver this checkout, build the estate, test it
#   demo-up.sh test        # re-run the tests only, against a standing cluster
#   demo-up.sh status      # VM state and the verdict on disk, read-only
#   demo-up.sh payload F   # build the delivery tarball at F and stop
#
#   --- Tailscale, the PRIMARY access path ---
#   demo-up.sh ts-up       # serve the dashboard on the tailnet, print the URL
#   demo-up.sh ts-status   # node, MagicDNS name, tailnet IP, dashboard health
#   demo-up.sh funnel-up   # additionally expose it to the PUBLIC internet
#   demo-up.sh funnel-down # remove the public listener, keep the tailnet one
#
#   --- IAP, the fallback ---
#   demo-up.sh connect     # open the IAP tunnel and print what a human needs
#   demo-up.sh public      # publish, prove a 200, then hand over the URL
#   demo-up.sh public-down # stop the VM-side forward
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
GIT_CMD="${GCP_TF_DEMO_GIT:-git}"

# Where the delivered checkout and its reports live ON THE VM. Both are part of
# the contract with demo-pipeline.sh (chunk C) and are stated in
# docs/gcp-demo/RUNBOOK.md § "The pipeline contract".
#
# /opt/signalloom is the path an unpack was actually measured working at, not a
# path this file invented.
REMOTE_WORK_DIR="${GCP_TF_DEMO_REMOTE_DIR:-/opt/signalloom/repo}"
REMOTE_REPORT_DIR="${GCP_TF_DEMO_REMOTE_REPORT_DIR:-/opt/signalloom/reports}"
REMOTE_LOG="${GCP_TF_DEMO_REMOTE_LOG:-/opt/signalloom/demo-pipeline.log}"

# EMPTY by default, meaning "run as whoever OS Login logged us in as".
#
# v1 hardcodes `sudo -u ci` because that VM provisions a `ci` account. This lane
# has no such guarantee: the only account proven to exist on the demo VM is the
# one OS Login creates for the impersonated operator SA, and `sudo -u <someone
# who does not exist>` fails with a message about the user, which reads as a
# permissions problem rather than as a wrong assumption in this file. Set it
# when chunk B's VM profile guarantees a service account to drop to.
REMOTE_USER="${GCP_TF_DEMO_REMOTE_USER:-}"

# The pipeline, relative to the repo root. Overridable so the tests can drive a
# fixture tree, and so a rename on chunk C's side is a one-variable change here
# rather than a silent 127 on the VM.
PIPELINE_REL="${GCP_TF_DEMO_PIPELINE:-scripts/gcp-tf/demo-pipeline.sh}"

REPORT_DIR="${GCP_TF_DEMO_REPORT_DIR:-${REPO_ROOT}/demo-reports}"
SUMMARY_NAME="${GCP_TF_DEMO_SUMMARY_NAME:-summary.json}"

# How long cmd_connect waits for the tunnel to bind before it stops waiting and
# starts diagnosing. PORT_PROBE is injectable so the whole connect path is
# exercisable without a real listener; the default needs no external binary.
TUNNEL_WAIT_SECONDS="${GCP_TF_DEMO_TUNNEL_WAIT_SECONDS:-20}"
PORT_PROBE="${GCP_TF_DEMO_PORT_PROBE:-default_port_probe}"

default_port_probe() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

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

# `--impersonate-service-account` makes gcloud print a WARNING to stderr on
# EVERY underlying API call — four per invocation, observed live. Two things go
# wrong if that is left alone, and they are different problems:
#
#   1. It pollutes the streamed pipeline output the operator is watching, at a
#      rate of four lines per gcloud call.
#   2. Anything that PARSES stderr gets the warning as data. vm_status merges
#      stderr into stdout deliberately (so it can classify auth failures) and
#      then compares the result against RUNNING/SUSPENDED/… — with the warning
#      glued on, that comparison never matches, every state reads as unknown,
#      and the run aborts against a perfectly healthy VM.
#
# Narrow on purpose. It matches gcloud's own impersonation warning and nothing
# else; a filter broad enough to swallow a real error would be worse than the
# noise it removes.
strip_impersonation_warning() {
  grep -v -E '^WARNING: This command is using service account impersonation|^WARNING: .*impersonat' || true
}

# The two IAP tunnel errors that do not say what they mean, both hit live.
#
#   4033 'not authorized'          — the SA lacks roles/iap.tunnelResourceAccessor.
#                                    Says nothing about IAM; reads as a network fault.
#   4003 'failed to connect to backend' — nothing is listening on the target port,
#                                    OR a firewall rule does not permit it. Those
#                                    two are indistinguishable from the client, so
#                                    the message must name both rather than pick.
explain_iap_error() {
  local err="$1" port="${2:-the target port}"
  case "$err" in
    *4033*|*"not authorized"*)
      cat >&2 <<EOF

  This is an IAM failure, not a network one, despite what it says.

  The operator service account needs roles/iap.tunnelResourceAccessor on the
  project (or on the instance). Without it every tunnel attempt returns
  4033 'not authorized', which mentions no permission and no principal.

      gcloud projects add-iam-policy-binding ${PROJECT_ID} \\
        --member=serviceAccount:${OPERATOR_SA} \\
        --role=roles/iap.tunnelResourceAccessor

  IAM takes roughly a minute to propagate. An immediate retry after granting
  still fails, which reads exactly like the grant not having worked.
EOF
      ;;
    *4003*|*"failed to connect to backend"*)
      cat >&2 <<EOF

  The tunnel reached IAP and IAP could not reach the port. That is TWO causes
  wearing one error, and they are indistinguishable from here:

    1. Nothing is listening on ${INSTANCE_NAME}:${port}.
       Check the estate is actually up:  make gcp-tf-demo-status ENV=${ENV_KEY}
    2. A firewall rule does not permit it. The IAP range is 35.235.240.0/20,
       and a rule that only opens tcp:22 from it — with the app port opened to
       Google's load-balancer health-check ranges instead — produces exactly
       this, because this environment has no load balancer in front of it.

       gcloud compute firewall-rules list --project=${PROJECT_ID} \\
         --filter="network~${INSTANCE_NAME}" --format='table(name,allowed[],sourceRanges[])'
EOF
      ;;
  esac
}

# Run a command with its stderr passed through the impersonation filter, and
# its exit status and its stdout untouched.
#
# stderr is buffered to a file rather than piped, deliberately. A pipe or a
# process substitution here would either lose the exit status or race the
# script's own exit; every caller below is a short control-plane call, so
# buffering costs nothing. Anything that STREAMS (the pipeline) filters inline
# instead and never comes through here.
run_filtered() {
  local err rc=0
  err="$(mktemp "${TMPDIR:-/tmp}/demo-stderr.XXXXXX")"
  "$@" 2>"$err" || rc=$?
  strip_impersonation_warning <"$err" >&2
  rm -f "$err"
  return "$rc"
}

vm_ssh() {
  local args=()
  mapfile -t args < <(gcloud_common)
  run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute ssh "$INSTANCE_NAME" \
    --zone="$ZONE" "${args[@]}" --tunnel-through-iap \
    --command="$1"
}

# Run a command on the VM, optionally dropping to a service account.
#
# `--command` and NOTHING on stdin. `gcloud compute ssh --command '…' < file`
# DOES NOT FORWARD STDIN: the redirect is accepted, the command runs, the exit
# status is 0, and the file arrives EMPTY. Every surrounding step then reports
# success — chmod works, a launch reports launched, and the log is empty. It is
# the worst possible failure shape, because nothing anywhere goes red. Anything
# that needs bytes on the VM goes through vm_scp and is verified after transfer.
remote_run() {
  local cmd="$1"
  if [ -n "$REMOTE_USER" ]; then
    printf -v cmd 'sudo -u %q bash -lc %q' "$REMOTE_USER" "$cmd"
  fi
  vm_ssh "$cmd"
}

vm_scp() {
  local args=()
  mapfile -t args < <(gcloud_common)
  run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute scp --tunnel-through-iap \
    --zone="$ZONE" "${args[@]}" "$@"
}

# An unreadable state is not an absent VM. Distinguishing them matters: acting
# on "absent" here would mean telling the operator to re-apply Terraform against
# an estate that is standing and healthy.
vm_status() {
  local out rc=0 args=()
  mapfile -t args < <(gcloud_common)
  # stderr is merged in ON PURPOSE — the classification below reads gcloud's
  # error text — and then the impersonation warning is stripped, because
  # otherwise it is glued onto the status and `RUNNING` never compares equal to
  # anything. Stripping BEFORE the success branch is what matters; doing it only
  # on the error path would leave the healthy case broken.
  out="$(SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" "${args[@]}" --format='get(status)' 2>&1 |
    strip_impersonation_warning)" || rc=$?
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
      run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances resume "$INSTANCE_NAME" \
        --zone="$ZONE" "${args[@]}" --quiet
      wait_for_ssh || return 2
      ;;
    TERMINATED | STOPPED)
      log "starting stopped ${INSTANCE_NAME}"
      run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances start "$INSTANCE_NAME" \
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

# Build the payload with `git archive`, not with a tar of the working tree.
#
# This is the security boundary of the whole lane, and the mechanism is the
# point. `git archive HEAD` ships TRACKED FILES ONLY. Every piece of secret
# material in this repo is gitignored — the tfvars, the hand-offs,
# deploy/gcp/deploy-sa, .keys — so none of it CAN ride along. That is a
# guarantee by construction. An `--exclude` list is a guarantee by somebody
# maintaining it correctly forever, which is a different and much weaker thing:
# a pattern that silently matches nothing looks exactly like one that works.
#
# It is also just better. A tar of this working tree measured 249MB, because
# `.terraform*` provider binaries and several node_modules trees survived the
# excludes. `git archive` is 35MB and ~2576 files.
#
# THE COST, stated plainly because it is real: uncommitted work is not
# delivered. HEAD is what ships, so a run against a dirty tree would test
# something other than what the operator is looking at while stamping the report
# with HEAD's SHA — the exact "green tests tested the wrong artefact" shape. So
# a dirty tree is refused rather than silently tolerated.
#
# `git archive` also ships no `.git`, which Kustomize needs as a security
# boundary for relative path traversal (`../base/` is rejected without one).
# deliver_code snapshots a throwaway repo on the VM for that. It is a marker,
# not history.
require_clean_tree() {
  [ "${GCP_TF_DEMO_ALLOW_DIRTY:-0}" != "1" ] || {
    warn "GCP_TF_DEMO_ALLOW_DIRTY=1 — delivering HEAD. Your uncommitted changes are NOT in this run, and the report will be stamped with HEAD's commit regardless."
    return 0
  }

  local dirty
  dirty="$("$GIT_CMD" -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
  [ -n "$dirty" ] || return 0

  {
    printf 'demo-up: REFUSING to deliver — the working tree has uncommitted changes.\n\n'
    printf '%s\n' "$dirty" | head -20 | while IFS= read -r entry; do printf '  %s\n' "$entry"; done
    cat <<EOF

  The payload is built with 'git archive HEAD', so only COMMITTED files travel.
  Running now would test HEAD while you are looking at something else on disk,
  and stamp the report with HEAD's commit — a verdict that is accurate about a
  tree nobody is reading.

  Commit first, or accept it explicitly:

      GCP_TF_DEMO_ALLOW_DIRTY=1 make gcp-tf-demo-up ENV=${ENV_KEY}
EOF
  } >&2
  exit 2
}

build_payload() {
  local out="$1"
  [ -n "$out" ] || die "build_payload needs an output path"

  require_clean_tree

  "$GIT_CMD" -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    die "${REPO_ROOT} is not a git repository, and the payload is built with 'git archive'. There is no working-tree fallback on purpose: it is the tracked-files-only property that keeps secrets out of the payload."

  # Presence before packaging. A payload that omits the pipeline produces a 127
  # on the VM twenty minutes later, by which point the obvious suspect is the VM.
  #
  # Checked against `git ls-files`, not against the filesystem: an UNTRACKED
  # pipeline exists on disk and will not be in the archive, and "it is right
  # there" is the most convincing possible wrong answer.
  "$GIT_CMD" -C "$REPO_ROOT" ls-files --error-unmatch "$PIPELINE_REL" >/dev/null 2>&1 ||
    die "no TRACKED pipeline at ${PIPELINE_REL}. If the file exists on disk it is untracked, and 'git archive' will not carry it. Commit it, or override with GCP_TF_DEMO_PIPELINE=<relative-path>."

  "$GIT_CMD" -C "$REPO_ROOT" archive --format=tar.gz -o "$out" HEAD

  # Verify the artefact, not the mechanism. Cheap, and it is the assertion that
  # survives someone swapping git archive back out for a tar with excludes.
  local leaked
  leaked="$("$TAR_CMD" -tzf "$out" |
    grep -E '(^|/)(\.git/|\.keys/|node_modules/|\.terraform)|\.tfvars($|\.json$)|\.handoff\.json$|deploy/gcp/deploy-sa$' |
    head -5 || true)"
  if [ -n "$leaked" ]; then
    printf 'demo-up: REFUSING to deliver — excluded material is present in the payload:\n' >&2
    printf '%s\n' "$leaked" | while IFS= read -r entry; do printf '  %s\n' "$entry" >&2; done
    printf 'demo-up: something is TRACKED that must not be. Fix .gitignore and untrack it;\n' >&2
    printf 'demo-up: do not paper over it with an archive exclusion.\n' >&2
    rm -f "$out"
    exit 2
  fi
  return 0
}

REMOTE_DELIVERY_PATH="${GCP_TF_DEMO_REMOTE_DELIVERY:-/tmp/osramp-demo-delivery.tar.gz}"

# Confirm the bytes ARRIVED, rather than confirming the transfer command exited 0.
#
# This is not defensive padding. `gcloud compute ssh --command '…' < file` does
# not forward stdin: it exits 0 and the file lands at ZERO BYTES, and everything
# downstream — chmod, a launch, a "delivered" log line — reports success against
# an empty file. Observed live. scp is a different mechanism and does not have
# that specific defect, but the lesson generalises to every transfer here: an
# exit status describes the command, and the only thing that describes the
# artefact is the artefact.
#
# Byte count rather than a checksum: it catches the empty and truncated cases
# (which are the ones that actually happen and the ones that read as success),
# needs no sha256sum on the VM, and one round trip rather than two.
verify_delivered_size() {
  local expected="$1" remote_size
  remote_size="$(vm_ssh "stat -c %s $(printf '%q' "$REMOTE_DELIVERY_PATH") 2>/dev/null || echo MISSING" |
    strip_impersonation_warning | tr -d '[:space:]')"

  if [ "$remote_size" = "MISSING" ] || [ -z "$remote_size" ]; then
    die "the payload is not on ${INSTANCE_NAME} at ${REMOTE_DELIVERY_PATH} after a transfer that reported success. Nothing was delivered; do NOT read the run that would have followed as a result about this code."
  fi
  if [ "$remote_size" != "$expected" ]; then
    die "the delivered payload is ${remote_size} bytes and ${expected} were sent. A truncated or empty payload extracts partially and the pipeline then fails somewhere unrelated, blaming the estate."
  fi
  log "delivery verified: ${remote_size} bytes on the VM"
}

deliver_code() {
  log "delivering HEAD to ${INSTANCE_NAME}:${REMOTE_WORK_DIR}"
  local tarball
  tarball="$(mktemp "${TMPDIR:-/tmp}/osramp-demo-${ENV_KEY}.XXXXXX.tar.gz")"
  build_payload "$tarball"

  local size
  size="$(wc -c <"$tarball" | tr -d '[:space:]')"
  log "payload: ${size} bytes (git archive HEAD — tracked files only)"

  vm_scp "$tarball" "${INSTANCE_NAME}:${REMOTE_DELIVERY_PATH}"
  verify_delivered_size "$size"

  # rm -rf then re-extract, rather than extracting over the top. `tar -xzf`
  # overwrites the files in the archive and leaves everything else alone, so a
  # file deleted in this checkout would survive on the VM and the pipeline would
  # test a tree that exists nowhere in git.
  # The chown is unconditional, and when no service account is configured it
  # targets the CONNECTING user — resolved on the VM with `id -un`, not here.
  # The directory is created with sudo, so without this it belongs to root and
  # the very next step (git init, as an unprivileged user) fails with a
  # permission error that reads like an IAM problem and is a chown.
  local owner
  if [ -n "$REMOTE_USER" ]; then
    owner="$(printf '%q' "$REMOTE_USER")"
  else
    # shellcheck disable=SC2016  # deliberately unexpanded: evaluated on the VM
    owner='$(id -un)'
  fi

  vm_ssh "sudo rm -rf $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo mkdir -p $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo tar -xzf $(printf '%q' "$REMOTE_DELIVERY_PATH") -C $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo chown -R ${owner} $(printf '%q' "$REMOTE_WORK_DIR") \
    && rm -f $(printf '%q' "$REMOTE_DELIVERY_PATH")"

  rm -f "$tarball"
  snapshot_remote_git
  log "delivered to ${REMOTE_WORK_DIR}"
}

# Kustomize uses .git/ as a security boundary for relative path traversal:
# without one, a kustomization referencing `../base/` is rejected. `git archive`
# ships no .git, so one is created here.
#
# It is a MARKER, not history. Its SHA is meaningless — two runs of
# byte-identical code produce two different SHAs, which is why every report is
# stamped with the commit from the local checkout instead and why a report
# carrying the VM's own SHA is classified STALE.
snapshot_remote_git() {
  log "snapshotting a throwaway git repo on the VM (Kustomize path-traversal boundary)"
  remote_run "cd $(printf '%q' "$REMOTE_WORK_DIR") \
    && if [ ! -d .git ]; then \
      git init -q \
      && git add -A \
      && git -c user.name='Signal Loom demo' -c user.email='demo@signalloom.local' \
           commit -q -m 'demo snapshot' --no-gpg-sign --allow-empty; \
    fi \
    && test -d .git"
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

  # `env VAR=… cmd` with no sudo when no service account is configured. v1 always
  # drops to `ci`; here that account is not guaranteed to exist, and `sudo -u`
  # naming a missing user fails with a message about sudo, which reads as a
  # privilege problem rather than as a wrong assumption in this file.
  local invocation
  if [ -n "$REMOTE_USER" ]; then
    printf -v invocation 'sudo -u %q env %s bash -l -c %q' \
      "$REMOTE_USER" "$envs" "$remote_cmd"
  else
    printf -v invocation 'env %s bash -l -c %q' "$envs" "$remote_cmd"
  fi

  log "running the pipeline on ${INSTANCE_NAME} (stage=${stage}, fence=${TIMEOUT_MINUTES}m)"
  log "output streams below; it is also being written to ${REPORT_DIR}/pipeline.log"

  # The fence is enforced, not merely printed. A wedged SSH session otherwise
  # blocks the run forever. SIGTERM first and SIGKILL 60s later, so the remote
  # pipeline gets a chance to flush its report files before the tunnel is torn
  # down — a killed pipeline that wrote nothing is an ABORTED with no diagnosis.
  #
  # The impersonation warning is stripped before the tee. gcloud emits it on
  # every underlying API call — four per invocation — and left alone it
  # interleaves with the pipeline's real output at exactly the moment a human is
  # reading it for a problem.
  #
  # PIPESTATUS[0], not $?, because tee is what the shell sees last.
  set +e
  "$TIMEOUT_CMD" -k 60s "${TIMEOUT_MINUTES}m" \
    env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute ssh "$INSTANCE_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA" \
    --tunnel-through-iap \
    --command="$invocation" \
    2>&1 | strip_impersonation_warning | tee -a "${REPORT_DIR}/pipeline.log"
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

  # Printed BEFORE the tunnel, because the tunnel occupies the foreground and
  # anything printed after it would only appear once the operator had already
  # given up and pressed Ctrl-C.
  print_connect_instructions "$port"

  log "opening IAP tunnel: localhost:${port} -> ${INSTANCE_NAME}:${port}"

  # Backgrounded and PROBED, rather than exec'd.
  #
  # `exec` was the obvious shape and it is the wrong one, because the two ways
  # this fails both look like a tunnel that is simply taking its time:
  #
  #   4033 'not authorized'              — the SA lacks iap.tunnelResourceAccessor
  #   4003 'failed to connect to backend' — the port is closed, or firewalled
  #
  # Neither mentions IAM or a firewall. Under `exec` the operator sits watching
  # a terminal that has printed a URL, waiting for something that will never
  # bind. So the tunnel is started, the local port is polled to a deadline, and
  # a failure is diagnosed with its own stderr in hand.
  local tunnel_err
  tunnel_err="$(mktemp "${TMPDIR:-/tmp}/demo-tunnel.XXXXXX.log")"

  env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute start-iap-tunnel "$INSTANCE_NAME" "$port" \
    --local-host-port="localhost:${port}" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA" 2>"$tunnel_err" &
  local tunnel_pid=$!

  # Killed by PID, never by pattern. `pkill -f start-iap-tunnel` would match the
  # shell running this script, because the tool that invokes it puts the whole
  # script text on that shell's command line — a self-kill that presents as a
  # silent exit with no output at all.
  local bound=0 waited=0
  while [ "$waited" -lt "$TUNNEL_WAIT_SECONDS" ]; do
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      break # the tunnel died; fall through to the diagnosis
    fi
    if "$PORT_PROBE" "$port"; then
      bound=1
      break
    fi
    waited=$((waited + 1))
    sleep 1
  done

  if [ "$bound" -ne 1 ]; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    local err
    err="$(strip_impersonation_warning <"$tunnel_err" | tail -5)"
    {
      printf '\ndemo-up: the tunnel did not bind localhost:%s within %ds.\n' "$port" "$TUNNEL_WAIT_SECONDS"
      printf '\n  gcloud said:\n'
      printf '%s\n' "${err:-(nothing on stderr)}" | while IFS= read -r line; do printf '    %s\n' "$line"; done
    } >&2
    explain_iap_error "${err}" "$port"
    rm -f "$tunnel_err"
    exit 2
  fi

  rm -f "$tunnel_err"
  log "tunnel is UP on localhost:${port} — the URL above is live. Ctrl-C to close."
  wait "$tunnel_pid"
}

# ── Publishing, and proving it before a human clicks ────────────────────────
#
# `connect` opens the tunnel and proves the LOCAL port binds. That is necessary
# and it is not sufficient, and the gap between the two is where this whole
# family earns its keep:
#
#   * A bound local port says the IAP tunnel accepted a connection. It says
#     nothing about whether anything on the VM is listening on the far side,
#     because gcloud binds locally before it ever proves the backend.
#   * The VM-side forward is the piece that actually dies. `kubectl
#     port-forward` drops on apiserver SPDY resets and pod restarts, so a demo
#     that worked an hour ago frequently has no listener now.
#   * Even with both ends up, the Gateway selects its route by SNI. A probe
#     that omits the SNI name gets its connection closed during the TLS
#     handshake — measured, and it presents as `UNEXPECTED_EOF_WHILE_READING`,
#     which reads like a broken tunnel rather than a wrong hostname.
#
# So `public` does the whole chain and refuses to hand over a URL it has not
# fetched a 200 from: ensure the VM is publishing, open the tunnel, wait for
# the local bind, then HTTP-probe /readyz through the tunnel WITH the SNI name.
# Only then is anything printed that invites a click.

# Everything below is injectable so the control flow is exercisable against
# stubs with no cluster, no tunnel and no cloud account.
HEALTH_PATH="${GCP_TF_DEMO_HEALTH_PATH:-/readyz}"
HEALTH_WAIT_SECONDS="${GCP_TF_DEMO_HEALTH_WAIT_SECONDS:-120}"
HEALTH_INTERVAL_SECONDS="${GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS:-3}"
CURL_BIN="${GCP_TF_DEMO_CURL:-curl}"
GATEWAY_LABEL="${GCP_TF_DEMO_GATEWAY_LABEL:-gateway.envoyproxy.io/owning-gateway-name=cluster}"

# The wildcard bind address, not loopback.
#
# Loopback is the wrong value here and the failure is misleading: the operator
# arrives over an IAP tunnel that connects to the instance's INTERNAL IP, so a
# forward bound to localhost is reachable only from the VM itself and presents
# to the tunnel as 4003 'failed to connect to backend' — indistinguishable from
# a firewall block, and it sends the reader to the firewall.
#
# It is an IP literal, which the estate-identity scan in
# test/terraform-demo-driver.bats forbids. It is exempted there alongside
# 127.0.0.1 and 35.235.240.0/20 on the same stated grounds: those are constants
# of the PROTOCOL, not of the estate, and cannot go stale when the estate is
# rebuilt — which is the property that guard exists to protect.
#
# Defined here with the other constants rather than beside its consumer, because
# it is read inside a heredoc built by ensure_published and a later definition
# would expand empty.
GATEWAY_BIND_ADDRESS="${GCP_TF_DEMO_GATEWAY_BIND_ADDRESS:-0.0.0.0}"

# Where the VM records the forward's PID and log, so `public-down` can stop it
# by PID rather than by a self-matching pattern.
PF_PID_FILE="${GCP_TF_DEMO_PF_PID_FILE:-/tmp/demo-gateway-pf.pid}"
PF_LOG="${GCP_TF_DEMO_PF_LOG:-/tmp/demo-gateway-pf.log}"

# One HTTP probe through the tunnel. Returns the status code on stdout, or the
# empty string when the request could not be made at all.
#
# --resolve rather than /etc/hosts: it sets BOTH the connection target and the
# TLS SNI name from the URL's hostname, which is exactly the pair the Gateway
# needs, and it does it without asking the operator to mutate a system file
# before we have proven there is anything worth pointing at.
#
# -k because the Gateway serves a self-signed certificate. This probe is
# checking liveness through a tunnel that Google has already authenticated; it
# is not the thing establishing trust.
probe_dashboard_status() {
  local port="$1"
  "$CURL_BIN" -k -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${DASHBOARD_HOST}:${port}:127.0.0.1" \
    "https://${DASHBOARD_HOST}:${port}${HEALTH_PATH}" 2>/dev/null || printf ''
}

# Poll until the dashboard answers 200, or the deadline expires.
wait_for_dashboard() {
  local port="$1" waited=0 code=''
  while [ "$waited" -lt "$HEALTH_WAIT_SECONDS" ]; do
    code="$(probe_dashboard_status "$port")"
    if [ "$code" = "200" ]; then
      printf '%s' "$code"
      return 0
    fi
    sleep "$HEALTH_INTERVAL_SECONDS"
    waited=$((waited + HEALTH_INTERVAL_SECONDS))
  done
  printf '%s' "$code"
  return 1
}

# Does THIS machine resolve the dashboard's SNI name to loopback?
#
# This is not covered by the health probe, and the gap is the dangerous kind.
# probe_dashboard_status uses `curl --resolve`, which sets the connection target
# and the SNI name directly and NEVER CONSULTS /etc/hosts. That is correct for a
# liveness probe — it tests the tunnel and the estate without requiring the
# operator to mutate a system file first — but it means a 200 says nothing about
# whether a BROWSER on this machine can reach the same URL.
#
# So without this check the target could print "verified before you clicked" and
# then hand over a URL that fails to resolve the moment it is clicked, which is
# precisely the promise it exists to keep. It passed unnoticed on the machine
# this was written on only because /etc/hosts already carried the entry.
#
# getent, not ping or curl: it asks the name-service switch the same question
# the browser will, so /etc/hosts, nsswitch and any resolver all count.
hosts_entry_present() {
  getent hosts "$DASHBOARD_HOST" 2>/dev/null | grep -q '^127\.0\.0\.1'
}

require_hosts_entry() {
  if hosts_entry_present; then
    log "${DASHBOARD_HOST} resolves to loopback — a browser here can reach it"
    return 0
  fi

  if [ "${GCP_TF_DEMO_SKIP_HOSTS_CHECK:-0}" = "1" ]; then
    warn "${DASHBOARD_HOST} does not resolve to loopback. Continuing because GCP_TF_DEMO_SKIP_HOSTS_CHECK=1 — curl --resolve will still work, a browser will not."
    return 0
  fi

  cat >&2 <<EOF
demo-up: ${DASHBOARD_HOST} does not resolve on this machine.

  The tunnel and the estate may both be perfectly healthy — this check is about
  THIS machine's name resolution, and it runs first precisely so you do not wait
  for a working tunnel and then discover the browser cannot use it.

  The dashboard is served by the Envoy Gateway behind an SNI hostname, so
  https://localhost:${APP_PORT} reaches the Gateway and is then rejected at TLS.
  The name is not optional and it is not a DNS name — it resolves nowhere in the
  world except a hosts file you control.

  Add it once per machine:

      echo '127.0.0.1 ${DASHBOARD_HOST}' | sudo tee -a /etc/hosts

  Then re-run this target. If you only want a scripted curl and no browser:

      GCP_TF_DEMO_SKIP_HOSTS_CHECK=1 make gcp-tf-public ENV=${ENV_KEY}
EOF
  exit 4
}

# Is the VM publishing the dashboard on its own interface?
#
# `ss -ltn` on the VM, not a probe from here: from here a closed port and a
# firewalled port are the same timeout, and this has to tell them apart to give
# a useful message.
remote_is_publishing() {
  local port="$1"
  remote_run "ss -ltn 2>/dev/null | grep -q ':${port} ' && echo PUBLISHING || echo ABSENT" 2>/dev/null \
    | grep -q PUBLISHING
}

# Start the VM-side supervised forward if it is not already up. Idempotent.
#
# Resolves the Gateway by LABEL rather than by name: Envoy appends a hash to the
# service name (envoy-ingress-cluster-6b24dc08), so a hardcoded name works until
# the Gateway is recreated and then fails with "service not found" on a cluster
# that is perfectly healthy.
ensure_published() {
  local port="$1"

  if remote_is_publishing "$port"; then
    log "the VM is already publishing on :${port}"
    return 0
  fi

  log "the VM is not publishing on :${port} — starting the supervised forward"

  # 0.0.0.0, not loopback: the operator arrives over an IAP tunnel that connects
  # to the instance's INTERNAL IP, so a forward bound to localhost is reachable
  # only from the VM itself and presents to the tunnel as 4003 'failed to
  # connect to backend' — indistinguishable from a firewall problem.
  #
  # Owned by pid 1 so it outlives this SSH session. A forward owned by the
  # session dies the moment we disconnect, which is the same defect as not
  # starting one, deferred by a few seconds.
  # No `cd` into the checkout: this needs kubectl and a kubeconfig, not the
  # repository. Anchoring it to the delivery directory would make publishing an
  # already-running estate fail on a VM where the payload had been cleaned up.
  local script
  script=$(cat <<REMOTE
set -uo pipefail
# NOT set -e, and NOT a bare \`read\`.
#
# kubectl -o jsonpath emits NO trailing newline, so \`read\` consumes the fields
# and still returns non-zero for want of a line terminator. Under \`set -e\` that
# aborts the script at this line — before the gateway check, before the
# forward, before any echo — so the caller sees a completely empty stdout and a
# generic failure. That cost a diagnosis cycle here; the \`|| true\` and the
# explicit checks below are what make the failure say which thing was missing.
read -r ns svc < <(kubectl get service -A -l '${GATEWAY_LABEL}' \
  -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}' 2>/dev/null) || true
if [ -z "\${ns:-}" ] || [ -z "\${svc:-}" ]; then
  echo "NO_GATEWAY" >&2
  exit 3
fi
echo "gateway=\${ns}/\${svc}"
nohup setsid kubectl port-forward -n "\${ns}" "svc/\${svc}" \
  --address ${GATEWAY_BIND_ADDRESS} ${port}:443 >${PF_LOG} 2>&1 < /dev/null &
# The PID is RECORDED, because it is the only thing that can stop this forward
# without a pattern match. A \`pkill -f 'kubectl port-forward…'\` issued over
# remote_run matches the remote \`bash -lc\` that carries the command text and
# kills its own shell — the same self-kill the local tunnel is killed by PID to
# avoid.
echo \$! >${PF_PID_FILE}
sleep 6
ss -ltn 2>/dev/null | grep -q ':${port} ' && echo PUBLISHED || { echo NOT_PUBLISHED >&2; exit 4; }
REMOTE
)
  if ! remote_run "$script"; then
    die "could not publish the dashboard on the VM. Is the estate up? Try: make gcp-tf-demo-status ENV=${ENV_KEY}"
  fi
}

# `public` — the whole chain, proven, then handed over.
cmd_public() {
  prepare public

  local port="$APP_PORT"
  if [ "$port" != "$DEX_PINNED_PORT" ] && [ "${GCP_TF_DEMO_ALLOW_PORT_MISMATCH:-0}" != "1" ]; then
    die "refusing to publish on ${port}: Dex pins its OIDC callback to ${DEX_PINNED_PORT}, so login would fail. Fix app_port, or set GCP_TF_DEMO_ALLOW_PORT_MISMATCH=1."
  fi

  # FIRST, and deliberately before any cloud call. It is a local check costing
  # milliseconds, and failing it after publishing and tunnelling would mean
  # waiting a minute to be told about a line in a file.
  require_hosts_entry

  ensure_published "$port"

  log "opening IAP tunnel: localhost:${port} -> ${INSTANCE_NAME}:${port}"
  local tunnel_err
  tunnel_err="$(mktemp "${TMPDIR:-/tmp}/demo-tunnel.XXXXXX.log")"

  env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute start-iap-tunnel "$INSTANCE_NAME" "$port" \
    --local-host-port="localhost:${port}" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA" 2>"$tunnel_err" &
  local tunnel_pid=$!

  # Killed by PID, never by pattern — `pkill -f start-iap-tunnel` matches the
  # shell running this script and self-terminates it silently.
  # shellcheck disable=SC2064
  trap "kill ${tunnel_pid} 2>/dev/null || true" EXIT

  local bound=0 waited=0
  while [ "$waited" -lt "$TUNNEL_WAIT_SECONDS" ]; do
    kill -0 "$tunnel_pid" 2>/dev/null || break
    if "$PORT_PROBE" "$port"; then bound=1; break; fi
    waited=$((waited + 1))
    sleep 1
  done

  if [ "$bound" -ne 1 ]; then
    local err
    err="$(strip_impersonation_warning <"$tunnel_err" | tail -5)"
    printf '\ndemo-up: the tunnel did not bind localhost:%s within %ds.\n\n  gcloud said:\n%s\n' \
      "$port" "$TUNNEL_WAIT_SECONDS" "${err:-    (nothing on stderr)}" >&2
    explain_iap_error "${err}" "$port"
    rm -f "$tunnel_err"
    exit 2
  fi

  # The bit `connect` does not do. A bound port is not a working demo.
  log "tunnel bound — probing https://${DASHBOARD_HOST}:${port}${HEALTH_PATH} (up to ${HEALTH_WAIT_SECONDS}s)"
  local code
  if ! code="$(wait_for_dashboard "$port")"; then
    {
      printf '\ndemo-up: the tunnel is up but the dashboard did not answer %s.\n' "$HEALTH_PATH"
      printf '  last status: %s\n\n' "${code:-(no response)}"
      printf '  The tunnel and the firewall are FINE — this got far enough to ask.\n'
      printf '  What has not: something behind the Gateway. Check the estate:\n\n'
      printf '    make gcp-tf-demo-status ENV=%s\n' "$ENV_KEY"
      printf '    make gcp-tf-demo-up ENV=%s      # rebuild and re-test\n\n' "$ENV_KEY"
      printf '  An empty status usually means curl could not resolve or connect;\n'
      printf '  a 404 means the Gateway answered but no route matched the SNI name\n'
      printf '  %s.\n' "$DASHBOARD_HOST"
    } >&2
    rm -f "$tunnel_err"
    exit 3
  fi

  rm -f "$tunnel_err"
  print_connect_instructions "$port"
  printf '\n  HEALTH: %s%s returned %s — verified before you clicked.\n\n' \
    "$DASHBOARD_HOST" "$HEALTH_PATH" "$code"
  log "the demo is live on localhost:${port}. Ctrl-C to close the tunnel."
  wait "$tunnel_pid"
}

# Stop the VM-side forward. The local tunnel dies with its own process.
cmd_public_down() {
  prepare public-down
  local port="$APP_PORT"
  log "stopping the VM-side forward on :${port}"

  # BY PID, never by pattern — the same rule the local tunnel follows, and for
  # the same reason. `remote_run` hands this text to a remote `bash -lc`, so the
  # whole command string becomes that shell's /proc/<pid>/cmdline; a
  # `pkill -f 'kubectl port-forward…'` matches its own parent, kills it, and
  # everything after the pkill silently never runs. Measured in this repo as a
  # bare exit 144 with no output at all, which reads as a hung command rather
  # than a self-kill.
  #
  # ensure_published records the PID for exactly this. A missing PID file is
  # reported rather than papered over with a pattern sweep: "I do not know what
  # to stop" is a different answer from "there was nothing to stop", and
  # conflating them is how a forward survives a teardown that claimed success.
  remote_run "
if [ ! -f '${PF_PID_FILE}' ]; then
  if ss -ltn 2>/dev/null | grep -q ':${port} '; then
    echo 'UNKNOWN_OWNER'
  else
    echo 'STOPPED'
  fi
  exit 0
fi
kill \"\$(cat '${PF_PID_FILE}')\" 2>/dev/null || true
rm -f '${PF_PID_FILE}'
sleep 2
ss -ltn 2>/dev/null | grep -q ':${port} ' && echo STILL_PUBLISHING || echo STOPPED"
}

cmd_public_status() {
  prepare public-status
  local port="$APP_PORT"
  printf 'env:       %s\n' "$ENV_KEY"
  printf 'instance:  %s (%s)\n' "$INSTANCE_NAME" "$(vm_status)"
  if hosts_entry_present; then
    printf 'hosts:     %s -> 127.0.0.1 (a browser here can reach it)\n' "$DASHBOARD_HOST"
  else
    printf "hosts:     %s does NOT resolve — add: echo '127.0.0.1 %s' | sudo tee -a /etc/hosts\n" \
      "$DASHBOARD_HOST" "$DASHBOARD_HOST"
  fi
  if remote_is_publishing "$port"; then
    printf 'vm:        PUBLISHING on %s:%s\n' "$GATEWAY_BIND_ADDRESS" "$port"
  else
    printf 'vm:        NOT publishing on :%s — run: make gcp-tf-public ENV=%s\n' "$port" "$ENV_KEY"
  fi
  local code
  code="$(probe_dashboard_status "$port")"
  if [ "$code" = "200" ]; then
    printf 'local:     tunnel OPEN and healthy (%s%s -> %s)\n' "$DASHBOARD_HOST" "$HEALTH_PATH" "$code"
  else
    printf 'local:     no healthy tunnel here (%s%s -> %s)\n' \
      "$DASHBOARD_HOST" "$HEALTH_PATH" "${code:-no response}"
  fi
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

# ── Tailscale: the PRIMARY access path ──────────────────────────────────────
#
# IAP (everything above) stays, tested, as the documented fallback. Tailscale
# leads because it removes the two things that make the IAP path awkward for a
# human, and it removes them for a stated reason rather than by preference:
#
#   1. NO /etc/hosts LINE. The IAP path hands over an SNI hostname that resolves
#      nowhere in the world, so every operator must edit a system file before a
#      browser can reach the demo — see require_hosts_entry, which exists purely
#      to stop that being discovered on the click. MagicDNS resolves the node's
#      name on every device already on the tailnet, so there is nothing to edit.
#   2. NO FOREGROUND TUNNEL. `public` and `connect` hold a gcloud process for as
#      long as the demo is wanted; close the terminal and the demo goes away.
#      A Tailscale node serves for as long as it is up.
#   3. NOTHING TO DO ON THE VM. Every step below is performed by the driver.
#      `make gcp-tf-ts-up ENV=<key>` against a freshly applied VM is the whole
#      procedure — no shell on the box, no hand-started port-forward, no
#      hand-run `tailscale serve`, no hand-applied Dex origin. That is the
#      property this path is FOR, and each of those four was a manual step
#      before; none of them survived a destroy, which is how the demo was
#      rebuilt from a runbook rather than from code.
#
# ── The SNI problem, and why it is now absent rather than solved ────────────
#
#   The obvious backend is the in-cluster Envoy Gateway, and it is the wrong
#   one. Envoy selects its route by SNI *and* by the request's `:authority`; its
#   listener hostname is `*.osramp.acme.local`. Measured, holding SNI constant:
#
#       Host: dashboard.osramp.acme.local  ->  200 OK
#       Host: <node>.<tailnet>.ts.net      ->  404 Not Found
#
#   A MagicDNS name therefore cannot reach the Gateway's route at all without
#   the Host header being rewritten, and the 404 it produces reads as a broken
#   application rather than as a name mismatch. The workaround — dial the
#   Gateway over TLS at the name it wants, having given that name a loopback
#   alias on the VM — worked, and cost a /etc/hosts edit on the box, a
#   self-signed hop, and an SNI discipline every future edit had to preserve.
#
#   Serving the DASHBOARD NGINX instead removes the problem rather than solving
#   it. nginx has `server_name _`, so it answers to any name; it proxies /dex/,
#   /api/, /afm/, /demo-api/, /fleet-api/ and /supercred-api/ to their
#   in-cluster backends, so it is a same-origin front door for the whole
#   application including OIDC; and it sets `absolute_redirect off`, so it
#   generates no redirect carrying an origin the browser did not use. TLS is
#   terminated once, by the Tailscale node, with a real publicly-trusted
#   certificate for the MagicDNS name. scripts/public-tunnel.sh reached the same
#   conclusion for ngrok and states it in its header.
#
# ── The origin changes, and Dex has exactly one issuer ──────────────────────
#
# A browser reaching the demo at https://<node>.<tailnet>.ts.net is at a
# DIFFERENT ORIGIN from https://DASHBOARD_HOST:30754, and Dex pins its OIDC
# issuer and its callback client to one origin at a time. Left alone, the
# dashboard loads over Tailscale and the login bounces — which presents as a
# broken application, not as an origin mismatch, and is the single most
# expensive failure shape this lane has. Every path below that changes the
# browser-visible origin therefore claims it through dex_origin() and refuses
# when something else holds it.
#
# ── Funnel is the same URL, made PUBLIC ─────────────────────────────────────
#
# `tailscale serve` and `tailscale funnel` publish the same MagicDNS name with
# the same certificate; funnel additionally routes it from the public internet
# over Tailscale's edge. That is why funnel-up does not re-patch Dex — the
# origin is identical — and why funnel-down leaves serve standing: the demo is
# still live on the tailnet after the public listener is switched off.

# Injectable like everything else in this file, so the whole Tailscale control
# flow is exercisable against a stub binary with no tailnet and no cloud.
TAILSCALE_CMD="${GCP_TF_DEMO_TAILSCALE:-tailscale}"

# The node's SHORT hostname. Deterministic from the environment key, because
# chunk T1 derives it the same way in Terraform and a name typed in two places
# is a name that disagrees in one of them.
#
# Resolution order mirrors OPERATOR_SA's: explicit override, then the hand-off
# field T1 publishes, then the derivation. The derivation is last rather than
# absent so this file is usable before T1's output block lands.
ts_node_hostname() {
  local from_handoff=""
  if [ -n "$HANDOFF_FILE" ] && [ -f "$HANDOFF_FILE" ]; then
    from_handoff="$(jq -r '.tailscale_hostname // ""' "$HANDOFF_FILE" 2>/dev/null || true)"
  fi
  printf '%s' "${GCP_TF_DEMO_TS_HOSTNAME:-${from_handoff:-sl-${ENV_KEY}}}"
}

# The tailnet's MagicDNS suffix is deliberately NOT a constant in this file.
#
# It could be one — it is stable per tailnet — but `tailscale status --json`
# already carries the node's fully-qualified DNSName, which is the name a
# browser and `getent` will both use. Deriving it from the live tailnet means
# there is no second place for it to be wrong, and no way for this file to
# promise a URL under a tailnet the operator is not actually on.
ts_status_json() {
  "$TAILSCALE_CMD" status --json 2>/dev/null || printf ''
}

# Resolved by ts_resolve_node. FQDN carries no trailing dot.
TS_FQDN=""
TS_IP=""
TS_ONLINE=""

# Find this environment's node in the tailnet and fill TS_FQDN / TS_IP /
# TS_ONLINE. Returns non-zero with a diagnosis on stderr, having named which of
# the five distinguishable causes applies — no client, no daemon, no such node,
# no MagicDNS name, or offline. They are separated because each invites a
# completely different next move, and a single "tailscale is not working"
# message sends the reader to the admin console for a missing package.
#
# Local only: it asks the tailscaled on THIS machine, so it costs milliseconds,
# needs no credentials, and — the point — runs before any cloud call, so an
# operator whose node is not up is told so immediately rather than after a
# minute of gcloud.
ts_resolve_node() {
  local host json node
  host="$(ts_node_hostname)"

  if ! command -v "$TAILSCALE_CMD" >/dev/null 2>&1; then
    cat >&2 <<EOF
demo-up: no '${TAILSCALE_CMD}' on PATH.

  The Tailscale access path needs a tailscale client on THIS machine, because
  MagicDNS is what makes the demo URL resolve here without a hosts file.

      https://tailscale.com/download

  Then join the tailnet and re-run. If you cannot install it, the IAP path is
  still fully supported:

      make gcp-tf-public ENV=${ENV_KEY}
EOF
    return 2
  fi

  json="$(ts_status_json)"
  if [ -z "$json" ]; then
    cat >&2 <<EOF
demo-up: '${TAILSCALE_CMD} status --json' returned nothing.

  tailscaled is not running here, or this machine is logged out of the tailnet.
  This says nothing about the demo VM — it is a statement about THIS machine.

      sudo tailscale up
      tailscale status
EOF
    return 2
  fi

  # .Self is included so the lookup still works when this driver is run FROM
  # the demo node itself, which is a legitimate way to debug it.
  node="$(printf '%s' "$json" |
    jq -c --arg h "$host" \
      '[.Self // empty] + [(.Peer // {}) | .[]] | map(select((.HostName // "") == $h)) | first // empty' \
      2>/dev/null || printf '')"

  if [ -z "$node" ]; then
    local seen
    seen="$(printf '%s' "$json" |
      jq -r '[.Self // empty] + [(.Peer // {}) | .[]] | map(.HostName // empty) | join(", ")' \
        2>/dev/null || printf '')"
    cat >&2 <<EOF
demo-up: no node named '${host}' in this tailnet.

  Three causes, and they are distinguishable only from the admin console:

    1. The VM has not joined. Its tailscaled is ephemeral, so a node that has
       been down long enough is REMOVED from the tailnet rather than shown
       offline — an absent node is the expected look of a suspended demo VM.
       Bring the estate up:   make gcp-tf-demo-up ENV=${ENV_KEY}
    2. The auth key expired, or 'tag:sl-demo' has no tagOwners entry, so the
       node was never approved. See docs/gcp-demo/RUNBOOK.md § "One-time
       Tailscale admin console setup".
    3. An ACL rule hides it from your user. A node you cannot see and a node
       that does not exist look identical from here.

  Nodes visible to you right now: ${seen:-(none)}
EOF
    return 2
  fi

  TS_FQDN="$(printf '%s' "$node" | jq -r '.DNSName // ""' | sed 's/\.$//')"
  TS_IP="$(printf '%s' "$node" | jq -r '.TailscaleIPs[0] // ""')"
  TS_ONLINE="$(printf '%s' "$node" | jq -r 'if .Online == true then "true" else "false" end')"

  if [ -z "$TS_FQDN" ]; then
    cat >&2 <<EOF
demo-up: node '${host}' is in the tailnet but has no MagicDNS name.

  MagicDNS is disabled for this tailnet. Without it the node has an IP and no
  name, and a certificate cannot be issued for it — so 'tailscale serve' has
  nothing to terminate TLS with and there is no URL to hand over.

  Enable it once, in the admin console:
      https://login.tailscale.com/admin/dns  ->  MagicDNS: on
EOF
    return 2
  fi

  # Checked AFTER the name, because an offline node still reports its DNSName
  # and reporting "no name" for an offline node would be a wrong diagnosis.
  if [ "$TS_ONLINE" != "true" ]; then
    cat >&2 <<EOF
demo-up: node '${TS_FQDN}' is in the tailnet but OFFLINE.

  The VM is suspended, or its tailscaled is not running.
  This is not a name resolution problem and not an ACL problem — the node is
  known to the tailnet by name, and it is not answering.

      make gcp-tf-demo-status ENV=${ENV_KEY}    # is the VM even running?
      make gcp-tf-demo-up ENV=${ENV_KEY}        # bring the estate back up
EOF
    return 2
  fi

  return 0
}

# Does THIS machine actually RESOLVE the node's name?
#
# The direct analogue of require_hosts_entry on the IAP path, and it exists for
# the same reason: a health probe that reaches the dashboard proves nothing
# about whether a browser here can reach the same URL. The difference is only
# that the fix is a tailnet setting rather than a line in a file — the failure
# it prevents, promising a URL that does not resolve on the click, is identical.
#
# ts_resolve_node has already established that the node HAS a MagicDNS name.
# This is the separate question of whether this machine's resolver returns it,
# which is what a browser will do.
#
# getent, not ping or curl: it asks the name-service switch the same question
# the browser will, so the tailscale resolver, /etc/hosts and nsswitch all
# count.
magicdns_resolves() {
  getent hosts "$TS_FQDN" >/dev/null 2>&1
}

require_magicdns() {
  if magicdns_resolves; then
    log "${TS_FQDN} resolves here — a browser on this machine can reach it"
    return 0
  fi

  if [ "${GCP_TF_DEMO_SKIP_MAGICDNS_CHECK:-0}" = "1" ]; then
    warn "${TS_FQDN} does not resolve here. Continuing because GCP_TF_DEMO_SKIP_MAGICDNS_CHECK=1 — a scripted curl against the tailnet IP will still work, a browser will not."
    return 0
  fi

  cat >&2 <<EOF
demo-up: ${TS_FQDN} does not resolve on this machine.

  The node is up and the tailnet knows its name — this check is about THIS
  machine's resolver, and it runs first precisely so you do not wait for a
  healthy estate and then discover the browser cannot use it.

  In order of likelihood:

    1. MagicDNS is off for your device. 'tailscale up --accept-dns' turns the
       tailnet's resolver back on; a device brought up with --accept-dns=false
       stays on its old DNS and resolves nothing in the tailnet.
    2. MagicDNS is off for the whole TAILNET:
       https://login.tailscale.com/admin/dns  ->  MagicDNS: on
    3. Something local overrode /etc/resolv.conf after tailscaled wrote it.
       'tailscale status' will still look perfectly healthy.

  Its tailnet IP is ${TS_IP:-unknown}, so a scripted probe can proceed without
  a resolver:

      GCP_TF_DEMO_SKIP_MAGICDNS_CHECK=1 make gcp-tf-ts-up ENV=${ENV_KEY}
EOF
  exit 4
}

# One HTTP probe at the MagicDNS URL. Status code on stdout, empty string when
# the request could not be made at all.
#
# NO -k, unlike probe_dashboard_status. That is a deliberate difference rather
# than an inconsistency: the IAP path probes a self-signed in-cluster
# certificate through a tunnel Google has already authenticated, whereas here
# the certificate is a real one issued to the MagicDNS name. If it does not
# verify, HTTPS certs are not enabled for the tailnet — which is a cause worth
# surfacing, and -k would hide it behind a healthy-looking 200.
TS_HEALTH_PATH="${GCP_TF_DEMO_TS_HEALTH_PATH:-${HEALTH_PATH}}"

probe_ts_status() {
  local base="$1"
  "$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "${base}${TS_HEALTH_PATH}" 2>/dev/null || printf ''
}

wait_for_ts_dashboard() {
  local base="$1" waited=0 code=''
  while [ "$waited" -lt "$HEALTH_WAIT_SECONDS" ]; do
    code="$(probe_ts_status "$base")"
    if [ "$code" = "200" ]; then
      printf '%s' "$code"
      return 0
    fi
    sleep "$HEALTH_INTERVAL_SECONDS"
    waited=$((waited + HEALTH_INTERVAL_SECONDS))
  done
  printf '%s' "$code"
  return 1
}

# ── The single coupling to chunk T2's origin mechanism ──────────────────────
#
# Everything this file knows about Dex's issuer goes through here, so the
# orchestrator reconciling T2's real interface at merge has ONE function to
# read rather than four call sites to find.
#
# ASSUMED INTERFACE (scripts/lib/dex-origin.sh, chunk T2 — NOT present in this
# worktree, so this is a contract stated, not a contract observed):
#
#   apply <origin>   claim the origin. Exit 0 on success. Non-zero when another
#                    origin already holds Dex.
#   current          print the origin currently in force, or nothing when Dex
#                    is at its pinned default. Exit 0 either way.
#   restore          put the pinned default back. Exit 0.
#   status           human-readable. Exit 0.
#
# WHERE IT RUNS is the part most likely to need reconciling. T2 is building it
# for `make public`, where kubectl is local. On this lane the cluster lives on
# the demo VM, so the default is to invoke the DELIVERED copy over SSH.
# GCP_TF_DEMO_DEX_ORIGIN_CMD overrides that with a local command, which is both
# the escape hatch for a different topology and what makes every branch below
# testable with no cluster.
DEX_ORIGIN_REL="${GCP_TF_DEMO_DEX_ORIGIN_REL:-scripts/lib/dex-origin.sh}"
DEX_ORIGIN_CMD="${GCP_TF_DEMO_DEX_ORIGIN_CMD:-}"

# Checked against the LOCAL checkout even when the call is remote. The payload
# is `git archive HEAD` of this tree, so a file absent here is absent on the VM
# — and "T2 has not landed yet" is a far more useful message than a 127 from a
# remote shell twenty seconds later.
dex_origin_available() {
  [ -n "$DEX_ORIGIN_CMD" ] && return 0
  [ -f "${REPO_ROOT}/${DEX_ORIGIN_REL}" ]
}

dex_origin() {
  if [ -n "$DEX_ORIGIN_CMD" ]; then
    # Word-split deliberately: an operator-supplied command plus its flags.
    local parts=()
    read -r -a parts <<<"$DEX_ORIGIN_CMD"
    "${parts[@]}" "$@"
    return $?
  fi
  local remote
  printf -v remote 'cd %q && %q %s' "$REMOTE_WORK_DIR" \
    "${REMOTE_WORK_DIR}/${DEX_ORIGIN_REL}" "$(printf '%q ' "$@")"
  remote_run "$remote"
}

# Refuse when T2's mechanism is not here.
#
# `who` names the caller so the message can say what will break, because the
# consequence differs: over Tailscale a missing patch means a login that
# bounces, and behind Funnel it means the same login bouncing on a URL the
# whole internet can reach.
require_dex_origin_mechanism() {
  local who="$1"
  dex_origin_available && return 0
  cat >&2 <<EOF
demo-up: ${who} needs the Dex origin mechanism, and it is not in this checkout.

  Expected: ${REPO_ROOT}/${DEX_ORIGIN_REL}   (chunk T2)

  Serving the dashboard at a new origin without repointing Dex's issuer gives
  you a dashboard that LOADS and a login that BOUNCES. That presents as a
  broken application rather than as an origin mismatch, which is the most
  expensive wrong diagnosis available on this lane.

  Until T2 lands, either use the IAP path — which serves at the origin Dex is
  already pinned to:

      make gcp-tf-public ENV=${ENV_KEY}

  or point this at an equivalent implementation:

      GCP_TF_DEMO_DEX_ORIGIN_CMD='<cmd>' make gcp-tf-ts-up ENV=${ENV_KEY}
EOF
  exit 5
}

# Read-only conflict check, run BEFORE anything is stood up.
#
# Separated from the apply deliberately. `current` mutates nothing, so a demo
# that is going to be refused is refused before the VM is touched; the write
# happens later, once the serving path is real. Doing both at the point of
# apply would mean publishing, serving, and only then discovering that ngrok
# holds the issuer.
require_no_conflicting_origin() {
  local want="$1" holder=""
  holder="$(dex_origin current 2>/dev/null | tr -d '\r' | tail -1 | tr -d '[:space:]' || true)"
  [ -n "$holder" ] || return 0
  [ "$holder" != "$want" ] || return 0

  cat >&2 <<EOF
demo-up: REFUSING — another origin already holds Dex.

  currently held by: ${holder}
  this run wants:    ${want}

  Dex has exactly ONE issuer, so these cannot both be live. The other origin is
  almost certainly an ngrok tunnel from 'make public'; whatever it is, taking
  the issuer from underneath it breaks that demo's login without warning it.

  Release it first, then re-run:

      ./scripts/public-tunnel.sh down          # if ngrok holds it
      ${DEX_ORIGIN_REL} restore                # otherwise
EOF
  exit 6
}

# ── The backend is the dashboard nginx, NOT the Envoy Gateway ───────────────
#
# This is the single most consequential decision on this path, it was measured
# rather than reasoned, and getting it wrong is expensive in a way that does not
# look like a routing problem.
#
# The Gateway selects its route by SNI *and* by the request's `:authority`. Its
# listener hostname is `*.osramp.acme.local`. Holding SNI constant and varying
# only the Host header:
#
#     Host: dashboard.osramp.acme.local  ->  200 OK
#     Host: <node>.<tailnet>.ts.net      ->  404 Not Found
#
# So a MagicDNS name can never be served through the Gateway without also
# rewriting the Host header, and a 404 from a healthy Gateway reads as a broken
# application. `tailscale serve` sets the Host header from the *backend* URL it
# was given, so pointing it at an `https+insecure://dashboard.osramp.acme.local`
# backend does work — at the cost of a VM-side /etc/hosts alias to make that name
# resolve, plus a self-signed certificate on the hop, plus an SNI discipline that
# must be preserved by every future edit.
#
# The dashboard nginx removes all three at once. It is
# `nginxinc/nginx-unprivileged` serving the SPA and proxy_pass-ing /dex/, /api/,
# /afm/, /demo-api/, /fleet-api/ and /supercred-api/ to their in-cluster
# backends: a SAME-ORIGIN front door for the whole application, OIDC included.
# It has `server_name _` and `absolute_redirect off`, so it does not care what
# name it is reached by and generates no redirect that would leak one.
# scripts/public-tunnel.sh has always used it for exactly these reasons and says
# so in its header; this path now agrees with it rather than solving the problem
# a second, harder way.
#
# What that buys, concretely: no Host-header 404, no /etc/hosts line on the VM,
# no SNI to keep, and TLS terminated once — by Tailscale, with a real
# publicly-trusted certificate for the MagicDNS name.
DASHBOARD_NAMESPACE="${GCP_TF_DEMO_DASHBOARD_NS:-fe-signalloom}"
DASHBOARD_SERVICE="${GCP_TF_DEMO_DASHBOARD_SVC:-dashboard-signalloom}"
DASHBOARD_SVC_PORT="${GCP_TF_DEMO_DASHBOARD_SVC_PORT:-8080}"

# The VM-local port the forward binds. Same number as the service port by
# convention only — they are independent, and naming them separately is what
# stops a service-port change silently becoming a bind-port change.
TS_BACKEND_PORT="${GCP_TF_DEMO_TS_BACKEND_PORT:-8080}"

# LOOPBACK, and this is the one place in this file where that is right.
#
# ensure_published binds 0.0.0.0 because the operator arrives over an IAP tunnel
# to the instance's INTERNAL ip, so a loopback bind is unreachable and presents
# as a firewall problem. Nothing about that applies here: `tailscale serve` runs
# ON the VM and dials this port from the VM. Binding it wider would publish an
# unauthenticated dashboard on the instance's internal interface — defended only
# by a firewall rule, for no benefit at all.
TS_BACKEND_BIND="${GCP_TF_DEMO_TS_BACKEND_BIND:-127.0.0.1}"

# The supervised forward, as a systemd unit rather than a nohup'd process.
#
# `kubectl port-forward` is not a durable tunnel. It dies on apiserver resets and
# on pod restarts, and it does so silently — which is how a demo that worked at
# 21:00 is dead at 09:00 with nothing in any log that says why. ensure_published
# has the same exposure and mitigates it with `nohup setsid` plus a recorded PID,
# which survives the SSH session but not the process. A unit with Restart=always
# survives both, and survives a VM reboot.
#
# The unit name is a constant so `ts-status` can ask about it by name, and so a
# second run adopts the existing unit rather than racing it.
PF_UNIT="${GCP_TF_DEMO_PF_UNIT:-signalloom-dashboard-pf}"
PF_UNIT_PATH="/etc/systemd/system/${PF_UNIT}.service"

# Poll for the forward's local port, in seconds. Generous because a cold start
# also waits for kubectl to reach the apiserver.
PF_WAIT_SECONDS="${GCP_TF_DEMO_PF_WAIT_SECONDS:-60}"

# Install and start the dashboard forward on the VM. Idempotent.
#
# Idempotence here is not tidiness. Restarting the unit drops every in-flight
# connection, and Dex runs `storage: type: memory`, so a needless restart during
# a demo logs people out. The unit is therefore rewritten and reloaded ONLY when
# its content actually changes; an already-correct, already-active unit is left
# strictly alone.
ensure_dashboard_forward() {
  log "ensuring the dashboard forward on ${INSTANCE_NAME}: ${TS_BACKEND_BIND}:${TS_BACKEND_PORT} -> ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE}:${DASHBOARD_SVC_PORT}"

  local script
  script=$(cat <<REMOTE
set -uo pipefail
# NOT set -e. The kubectl probes below are expected to fail on a cluster that is
# not up yet, and each failure needs to produce its OWN message: under errexit
# the script would abort at the first one and the caller would see empty stdout
# and a generic non-zero, which is the exact shape that cost a diagnosis cycle
# in ensure_published.

KUBECTL="\$(command -v kubectl 2>/dev/null || true)"
if [ -z "\$KUBECTL" ]; then
  echo "NO_KUBECTL" >&2
  exit 3
fi

# The kubeconfig is discovered, never assumed. The cluster is Kind, created by
# whichever account the pipeline ran as, so its config lives in that user's HOME
# — and this command arrives over a login shell that already has that HOME.
# systemd does not: a unit with no KUBECONFIG runs with HOME=/root and finds
# nothing, which surfaces as an authentication error against localhost:6443 and
# reads like a broken cluster.
KUBECONFIG_PATH="\${KUBECONFIG:-\${HOME}/.kube/config}"
if [ ! -r "\$KUBECONFIG_PATH" ]; then
  echo "NO_KUBECONFIG:\${KUBECONFIG_PATH}" >&2
  exit 4
fi
RUN_USER="\$(id -un)"

# PROVE THE SERVICE EXISTS BEFORE WRITING A UNIT THAT CHASES IT.
#
# Restart=always turns a wrong namespace or a renamed service into an infinite
# restart loop: the unit reports active, nothing ever listens, and the health
# gate below times out after two minutes with an empty status. That is a
# genuinely hard failure to read. One cheap read here converts it into a named
# one. \`|| true\` because errexit is off and a missing service must reach the
# explicit test rather than the exit status of a pipeline.
SVC="\$("\$KUBECTL" get service -n ${DASHBOARD_NAMESPACE} ${DASHBOARD_SERVICE} \
  -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [ "\$SVC" != "${DASHBOARD_SERVICE}" ]; then
  echo "NO_SERVICE:${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE}" >&2
  exit 5
fi

# ExecStart takes an absolute path and no shell metacharacters — systemd does
# not run a shell, so a \$VAR or a pipe here would be passed to kubectl as a
# literal argument.
UNIT_BODY="[Unit]
Description=Signal Loom dashboard port-forward (Tailscale access path)
Documentation=https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/docs/gcp-demo/RUNBOOK.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=\${RUN_USER}
Environment=KUBECONFIG=\${KUBECONFIG_PATH}
ExecStart=\${KUBECTL} port-forward --namespace ${DASHBOARD_NAMESPACE} svc/${DASHBOARD_SERVICE} --address ${TS_BACKEND_BIND} ${TS_BACKEND_PORT}:${DASHBOARD_SVC_PORT}
# Always, not on-failure: a port-forward that loses its pod exits ZERO, so
# on-failure would leave the demo dead with the unit reported as cleanly
# finished.
Restart=always
RestartSec=5
# The forward is expected to die often — a pod roll restarts it several times in
# a minute. systemd's default rate limit would give up after 5 restarts in 10s
# and leave the unit failed, which is worse than the problem it guards against.
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
"

# Rewrite ONLY on change. Restarting drops in-flight connections, and Dex keeps
# its sessions in memory, so a gratuitous restart logs out everyone using the
# demo right now.
CHANGED=0
if [ ! -f ${PF_UNIT_PATH} ] || ! printf '%s' "\$UNIT_BODY" | sudo cmp -s - ${PF_UNIT_PATH}; then
  printf '%s' "\$UNIT_BODY" | sudo tee ${PF_UNIT_PATH} >/dev/null || { echo "UNIT_WRITE_FAILED" >&2; exit 6; }
  sudo systemctl daemon-reload || { echo "DAEMON_RELOAD_FAILED" >&2; exit 7; }
  CHANGED=1
fi
echo "unit_changed=\${CHANGED}"

if [ "\$CHANGED" = "1" ]; then
  sudo systemctl enable --now ${PF_UNIT}.service >/dev/null 2>&1 || { echo "UNIT_START_FAILED" >&2; exit 8; }
  sudo systemctl restart ${PF_UNIT}.service || { echo "UNIT_RESTART_FAILED" >&2; exit 8; }
else
  # enable is idempotent and cheap; it is what makes the forward survive a
  # reboot even when the unit body was already correct from a previous run.
  sudo systemctl enable ${PF_UNIT}.service >/dev/null 2>&1 || true
  sudo systemctl is-active --quiet ${PF_UNIT}.service || sudo systemctl start ${PF_UNIT}.service || { echo "UNIT_START_FAILED" >&2; exit 8; }
fi

# Wait for the LISTENER, not for the unit. systemd reports active the moment the
# process is forked, which is several seconds before kubectl has a connection to
# the apiserver — so "active" is not the property anything downstream needs.
WAITED=0
while [ "\$WAITED" -lt ${PF_WAIT_SECONDS} ]; do
  if ss -ltn 2>/dev/null | grep -q '${TS_BACKEND_BIND}:${TS_BACKEND_PORT} '; then
    echo "FORWARD_LISTENING"
    exit 0
  fi
  sleep 2
  WAITED=\$((WAITED + 2))
done

echo "FORWARD_NOT_LISTENING" >&2
sudo systemctl status ${PF_UNIT}.service --no-pager --lines=15 >&2 2>/dev/null || true
exit 9
REMOTE
)

  # stdout captured, stderr NOT: the remote script's diagnoses (NO_SERVICE,
  # FORWARD_NOT_LISTENING, the systemctl status dump) are written to stderr
  # precisely so they reach the operator's terminal as they happen rather than
  # being swallowed into a variable and reprinted out of order.
  local out rc=0
  out="$(remote_run "$script")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat >&2 <<EOF

demo-up: could not stand up the dashboard forward on ${INSTANCE_NAME}.

  The unit is ${PF_UNIT}.service, at ${PF_UNIT_PATH}.
  The remote step exited ${rc}, which names the cause:

    3  no kubectl on the VM        — the estate was never deployed here
    4  no readable kubeconfig      — the Kind cluster belongs to another user
    5  no ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} service
                                   — the cluster is up and the app is not.
                                     Run: make gcp-tf-demo-up ENV=${ENV_KEY}
    6/7 could not write or reload the unit — sudo is refusing on the VM
    8  systemd would not start the unit
    9  the unit started and nothing ever listened on ${TS_BACKEND_BIND}:${TS_BACKEND_PORT}
                                     systemctl status is above.

EOF
    exit 7
  fi
  printf '%s\n' "$out" | grep -q FORWARD_LISTENING ||
    die "the dashboard forward reported success without a listener on ${TS_BACKEND_BIND}:${TS_BACKEND_PORT}. Refusing to serve a URL in front of nothing."
}

# `tailscale serve` (tailnet-only) or `tailscale funnel` (public), on the VM.
#
# One function for both because they differ in exactly one word and in exactly
# one property, and writing them twice is how the two drift.
TS_SERVE_PORT="${GCP_TF_DEMO_TS_SERVE_PORT:-443}"

ensure_ts_serve() {
  local verb="$1" port="$2" # verb: serve | funnel
  log "configuring 'tailscale ${verb}' on ${INSTANCE_NAME}: :${TS_SERVE_PORT} -> http://${TS_BACKEND_BIND}:${port}"
  # PLAIN http, and no `https+insecure://`. The backend is nginx on loopback on
  # this same VM, which speaks http and holds no certificate; TLS is terminated
  # once, by Tailscale, with a real certificate for the MagicDNS name. The
  # previous form dialled the Envoy Gateway over TLS purely to satisfy its SNI
  # route, and that whole hop is gone.
  remote_run "sudo tailscale ${verb} --bg --https=${TS_SERVE_PORT} \
    'http://${TS_BACKEND_BIND}:${port}' && echo ${verb^^}_CONFIGURED" ||
    die "'tailscale ${verb}' failed on ${INSTANCE_NAME}. If it named a certificate, HTTPS certs are not enabled for this tailnet (admin console -> DNS -> HTTPS Certificates). If it named funnel, the tailnet policy has no nodeAttrs entry granting 'funnel' to tag:sl-demo. Neither is fixable from here."
}

print_ts_instructions() {
  local url="$1"
  cat <<EOF

════════════════════════════════════════════════════════════════════
  Signal Loom demo — ${ENV_KEY}  (Tailscale)
════════════════════════════════════════════════════════════════════

  URL:      ${url}

  1. There is NOTHING to add to /etc/hosts. MagicDNS resolves this name on
     every device already on the tailnet, which is the whole reason this is
     the primary path.

  2. The certificate is a REAL one, issued to the MagicDNS name. No browser
     warning to click through, unlike the IAP path's self-signed Gateway cert.

  3. Log in through Dex:

         username: ${DEMO_LOGIN_USER}
         password: ${DEMO_LOGIN_PASS}

  4. Reachable from any device on the tailnet — including a phone — with no
     tunnel held open in a terminal. Nothing here has to stay running.

  Confirm it from anywhere on the tailnet:

      curl ${url}${TS_HEALTH_PATH}

════════════════════════════════════════════════════════════════════
EOF
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_ts_status() {
  prepare ts-status
  local host
  host="$(ts_node_hostname)"

  printf 'env:       %s\n' "$ENV_KEY"
  printf 'instance:  %s (%s)\n' "$INSTANCE_NAME" "$(vm_status)"
  printf 'ts node:   %s\n' "$host"

  if ! ts_resolve_node; then
    printf 'ts state:  NOT USABLE — see the diagnosis above\n'
    return 1
  fi

  printf 'magicdns:  %s\n' "$TS_FQDN"
  printf 'tailnet ip: %s\n' "${TS_IP:-unknown}"
  printf 'online:    %s\n' "$TS_ONLINE"

  if magicdns_resolves; then
    printf 'resolves:  yes — a browser here can reach it\n'
  else
    printf 'resolves:  NO — this machine does not resolve %s (MagicDNS off for this device or tailnet)\n' "$TS_FQDN"
  fi

  # The FORWARD's port, not the Gateway's. Reporting APP_PORT here would say
  # "PUBLISHING" on a VM where the IAP path happens to be up and the Tailscale
  # backend is not — a green line for the wrong listener.
  #
  # Two facts, deliberately separate: whether systemd thinks the unit is alive,
  # and whether anything is actually listening. They disagree exactly when it
  # matters — a unit in a Restart=always loop reports `activating` or even
  # `active` forever while no port ever opens.
  local unit_state
  unit_state="$(remote_run "systemctl is-active ${PF_UNIT}.service 2>/dev/null || true" 2>/dev/null |
    tr -d '\r' | tr -d '[:space:]')"
  printf 'forward:   %s.service is %s\n' "$PF_UNIT" "${unit_state:-unknown}"

  if remote_is_publishing "$TS_BACKEND_PORT"; then
    printf 'backend:   LISTENING on %s:%s (%s/%s)\n' \
      "$TS_BACKEND_BIND" "$TS_BACKEND_PORT" "$DASHBOARD_NAMESPACE" "$DASHBOARD_SERVICE"
  else
    printf 'backend:   NOTHING on :%s — run: make gcp-tf-ts-up ENV=%s\n' "$TS_BACKEND_PORT" "$ENV_KEY"
  fi

  if dex_origin_available; then
    local holder
    holder="$(dex_origin current 2>/dev/null | tr -d '\r' | tail -1 | tr -d '[:space:]' || true)"
    printf 'dex origin: %s\n' "${holder:-(pinned default — the IAP origin)}"
  else
    printf 'dex origin: UNKNOWN — %s is not in this checkout (chunk T2)\n' "$DEX_ORIGIN_REL"
  fi

  local base code
  base="https://${TS_FQDN}"
  code="$(probe_ts_status "$base")"
  if [ "$code" = "200" ]; then
    printf 'dashboard: HEALTHY (%s%s -> 200)\n' "$base" "$TS_HEALTH_PATH"
  else
    printf 'dashboard: not answering (%s%s -> %s)\n' "$base" "$TS_HEALTH_PATH" "${code:-no response}"
  fi
  return 0
}

cmd_ts_up() {
  prepare ts-up

  # TS_BACKEND_PORT, not APP_PORT. APP_PORT is the Gateway's node port and is
  # what the IAP path publishes; this path does not go near the Gateway. The two
  # were the same variable while `tailscale serve` dialled the Gateway, and
  # keeping them merged after the backend moved would have made a Gateway port
  # change silently repoint the dashboard forward.
  local port="$TS_BACKEND_PORT"

  # LOCAL FIRST, before any cloud call, in this order and for the same reason
  # cmd_public checks /etc/hosts first: these cost milliseconds, and failing
  # them after publishing would mean waiting a minute to be told about a
  # setting on this machine.
  ts_resolve_node || exit 2
  require_magicdns

  local base="https://${TS_FQDN}"

  # Read-only, and before the estate is touched. Skippable for a scripted probe
  # that does not care about login, but NOT skippable by default: a dashboard
  # that loads with a bouncing login is the failure this whole block is built
  # around.
  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" = "1" ]; then
    warn "GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 — Dex will keep its current issuer. The dashboard will load at ${base} and the LOGIN WILL BOUNCE."
  else
    require_dex_origin_mechanism "gcp-tf-ts-up"
    require_no_conflicting_origin "$base"
  fi

  # Forward FIRST, then serve. The reverse order publishes a listener in front of
  # nothing, and `tailscale serve` accepts a backend that is not answering
  # without complaint — so the failure would surface two minutes later at the
  # health gate as a 502, having named nothing.
  ensure_dashboard_forward
  ensure_ts_serve serve "$port"

  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" != "1" ]; then
    log "claiming the Dex origin: ${base}"
    # `apply <method> <origin>` — the METHOD is not optional. The mechanism
    # records which access method holds the lease so the refusal it gives the
    # next caller can name whose teardown to run; an origin alone cannot answer
    # that. Chunk T3 was written against an assumed one-argument signature and
    # this seam was invisible to both suites, because each tested its own side
    # of it: T3 against a stub, T2 against its own CLI.
    dex_origin apply tailscale "$base" ||
      die "could not repoint Dex at ${base}. The dashboard would load and the login would bounce, so this is a failure rather than a warning."
  fi

  log "probing ${base}${TS_HEALTH_PATH} (up to ${HEALTH_WAIT_SECONDS}s)"
  local code
  if ! code="$(wait_for_ts_dashboard "$base")"; then
    {
      printf '\ndemo-up: the node is up but the dashboard did not answer %s.\n' "$TS_HEALTH_PATH"
      printf '  last status: %s\n\n' "${code:-(no response)}"
      printf '  MagicDNS and the tailnet are FINE — this got far enough to ask.\n'
      printf '  Three things are behind that name and any of them can be the one:\n\n'
      printf '    1. An EMPTY status usually means the TLS certificate did not verify.\n'
      printf '       HTTPS certs are not enabled for this tailnet (admin console ->\n'
      printf '       DNS -> HTTPS Certificates). Nothing in this repo can turn that on.\n'
      printf '    2. A 502 means tailscale serve dialled %s:%s and got\n' "$TS_BACKEND_BIND" "$TS_BACKEND_PORT"
      printf '       nothing. The forward opened its port and then lost it — a pod\n'
      printf '       roll, or the apiserver going away. systemd will be restarting it:\n'
      printf '         make gcp-tf-ts-status ENV=%s\n' "$ENV_KEY"
      printf '    3. A 404 means something answered that is NOT the dashboard nginx.\n'
      printf '       nginx serves this path unconditionally, so a 404 here means the\n'
      printf '       forward is pointed at another service — check that\n'
      printf '       %s/%s is what %s.service names.\n' \
        "$DASHBOARD_NAMESPACE" "$DASHBOARD_SERVICE" "$PF_UNIT"
    } >&2
    exit 3
  fi

  print_ts_instructions "$base"
  printf '\n  HEALTH: %s%s returned %s — verified before you clicked.\n' \
    "$TS_FQDN" "$TS_HEALTH_PATH" "$code"
  printf '  SCOPE:  reachable from this TAILNET only. Not from the public internet.\n'
  printf '          Making it public is a separate, deliberate act:\n'
  printf '            make gcp-tf-funnel-up ENV=%s\n\n' "$ENV_KEY"
  log "the demo is live at ${base}. Nothing is being held open — it stays up."
}

cmd_funnel_up() {
  prepare funnel-up
  local port="$TS_BACKEND_PORT"

  ts_resolve_node || exit 2
  require_magicdns

  local base="https://${TS_FQDN}"

  # NOT skippable here, unlike ts-up. A bouncing login on a tailnet-only URL is
  # an inconvenience; a bouncing login on a URL the whole internet can reach is
  # a broken thing published under this estate's name.
  require_dex_origin_mechanism "gcp-tf-funnel-up"
  require_no_conflicting_origin "$base"

  cat <<EOF

  ⚠  FUNNEL EXPOSES THIS DEMO TO THE PUBLIC INTERNET.

  Every other access path in this estate is closed by construction: the VM has
  no external IP, IAP requires a Google identity holding
  roles/iap.tunnelResourceAccessor, and Tailscale requires membership of this
  tailnet. Funnel is the ONLY thing here that creates a listener anyone can
  reach, and it does so under a name with a valid public certificate.

  What is behind it is a demo estate with published credentials
  (${DEMO_LOGIN_USER} / ${DEMO_LOGIN_PASS}). Treat everything in it as
  disclosed for as long as this is on.

  Switch it off the moment the demo ends — it does not expire on its own:

      make gcp-tf-funnel-down ENV=${ENV_KEY}

EOF

  ensure_dashboard_forward
  ensure_ts_serve funnel "$port"

  log "claiming the Dex origin: ${base}"
  # `funnel`, not `tailscale` — same URL, different method. serve and funnel
  # publish the identical origin, so the lease would be satisfied either way,
  # but the recorded holder is what a later refusal quotes back. Naming it
  # `tailscale` here would tell the next operator to run the wrong teardown and
  # leave the PUBLIC listener up.
  dex_origin apply funnel "$base" ||
    die "could not repoint Dex at ${base}. Refusing to leave a PUBLIC URL whose login bounces — run 'make gcp-tf-funnel-down ENV=${ENV_KEY}' now."

  log "probing ${base}${TS_HEALTH_PATH} (up to ${HEALTH_WAIT_SECONDS}s)"
  local code
  if ! code="$(wait_for_ts_dashboard "$base")"; then
    {
      printf '\ndemo-up: funnel is configured and the dashboard did not answer %s.\n' "$TS_HEALTH_PATH"
      printf '  last status: %s\n\n' "${code:-(no response)}"
      printf '  A PUBLIC listener may now exist in front of something that does not\n'
      printf '  work. Take it down before debugging:\n\n'
      printf '    make gcp-tf-funnel-down ENV=%s\n\n' "$ENV_KEY"
      printf '  An empty status here most often means the tailnet policy grants no\n'
      printf "  'funnel' nodeAttr to tag:sl-demo, so the edge is refusing to route.\n"
    } >&2
    exit 3
  fi

  print_ts_instructions "$base"
  printf '\n  HEALTH: %s%s returned %s — verified before you clicked.\n' \
    "$TS_FQDN" "$TS_HEALTH_PATH" "$code"
  printf '  SCOPE:  PUBLIC. This URL is reachable from the entire internet.\n'
  printf '          make gcp-tf-funnel-down ENV=%s\n\n' "$ENV_KEY"
}

cmd_funnel_down() {
  prepare funnel-down
  ts_resolve_node || exit 2

  log "switching off the public funnel listener on ${INSTANCE_NAME}"
  remote_run "sudo tailscale funnel --https=${TS_SERVE_PORT} off && echo FUNNEL_OFF" ||
    die "could not switch off funnel on ${INSTANCE_NAME}. The public listener may STILL BE UP. Check by hand: gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} --impersonate-service-account=${OPERATOR_SA} --tunnel-through-iap --command='sudo tailscale funnel status'"

  # Deliberately leaves `tailscale serve` and the Dex origin alone. The demo is
  # still live on the tailnet at the same URL after this, so restoring the
  # issuer here would break the thing the operator is still using.
  printf '\n  Funnel is OFF. The demo is still live for this tailnet at https://%s\n' "$TS_FQDN"
  printf '  Dex still points there, which is correct — only the PUBLIC listener\n'
  printf '  was removed. To stop serving entirely: make gcp-tf-public-down ENV=%s\n\n' "$ENV_KEY"
}

case "${1:-up}" in
  up) cmd_up ;;
  test) cmd_test ;;
  connect) cmd_connect ;;
  public) cmd_public ;;
  public-down) cmd_public_down ;;
  public-status) cmd_public_status ;;
  ts-status) cmd_ts_status ;;
  ts-up) cmd_ts_up ;;
  funnel-up) cmd_funnel_up ;;
  funnel-down) cmd_funnel_down ;;
  status) cmd_status ;;
  payload)
    shift
    cmd_payload "${1:-}"
    ;;
  -h | --help | help) sed -n '2,24p' "$0" ;;
  *) die "usage: $(basename "$0") {up|test|connect|ts-up|ts-status|funnel-up|funnel-down|public|public-down|public-status|status|payload <file>}" ;;
esac
