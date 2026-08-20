#!/usr/bin/env bash
#
# gcp-tf-ci.sh — resume → test → suspend, for one named Terraform CI lane.
#
#   gcp-tf-ci.sh run          # resume the lane, run the tests, suspend it
#   gcp-tf-ci.sh suspend      # suspend the lane and nothing else
#   gcp-tf-ci.sh status       # print the lane's instance state
#   gcp-tf-ci.sh lock-path    # print this lane's lock path and exit
#
# This is a SIBLING of scripts/ci/gcp-ci.sh, not a replacement. That script owns
# the shared signalloom-ci VMs and the kind-cluster pipeline; this one owns the
# per-lane Terraform runners built by terraform/modules/ci-runner. Neither file
# reads or writes the other's state.
#
# ─── The KPI ────────────────────────────────────────────────────────────────
#
# The lane suspends after EVERY completed run, pass or fail. A lane left running
# on a failure bills for the rest of the night, and "leave it up so I can debug"
# is exactly the intention that never survives contact with a Friday evening.
# Debugging is `gcp-tf-ci.sh run` again, or an explicit resume.
#
# So the suspend runs from an EXIT trap, which bash also runs on SIGINT and
# SIGTERM once those are trapped to an exit.
#
# ─── The trap must not rewrite the verdict ──────────────────────────────────
#
# Under `set -e` a failing final command in an EXIT trap replaces the status the
# script asked for. This repo has already lost a run to that: 8/8 stages green,
# reported as failure, because a cleanup conditional evaluated false as the last
# statement of the trap. See scripts/ci/gcp-ci.sh's lock_release comment.
#
# Three things prevent a repeat here, and all three are tested:
#   1. the real status is captured into `rc` as the trap's FIRST action;
#   2. every cleanup call is `|| true`, so none of them can propagate;
#   3. the trap's last statement is an explicit `exit "$rc"`.
#
# ─── ssh-agent ──────────────────────────────────────────────────────────────
#
# SSH_AUTH_SOCK is emptied before anything can call `gcloud compute ssh`. A
# populated agent makes IAP SSH fail with "agent refused operation", which reads
# as a VM provisioning fault and is a purely local one. That misdiagnosis has
# cost real debugging time on this project.

set -euo pipefail

# ── Injectable boundaries ───────────────────────────────────────────────────
#
# Every external dependency is overridable, which is what makes the whole
# control flow exercisable by test/terraform-ci-lifecycle.bats against stubs on
# PATH, with no cloud access and no credentials.

CI_KEY="${GCP_TF_CI_KEY:-}"
PROJECT="${GCP_TF_CI_PROJECT:-CHANGEME-project}"
ZONE="${GCP_TF_CI_ZONE:-europe-west2-a}"
GCLOUD_CMD="${GCP_TF_CI_GCLOUD:-gcloud}"
TEST_CMD="${GCP_TF_CI_TEST_CMD:-make gcp-tf-validate}"
REMOTE_DIR="${GCP_TF_CI_REMOTE_DIR:-/home/ci/osramp-demo}"
SSH_WAIT_ATTEMPTS="${GCP_TF_CI_SSH_WAIT_ATTEMPTS:-30}"
SSH_WAIT_INTERVAL="${GCP_TF_CI_SSH_WAIT_INTERVAL:-5}"
LOCK_HOME="${GCP_TF_CI_LOCK_HOME:-${TMPDIR:-/tmp}}"
LOCK_TTL_MINUTES="${GCP_TF_CI_LOCK_TTL_MINUTES:-240}"
LOCK_HOLDER="${GCP_TF_CI_LOCK_HOLDER:-$(id -un 2>/dev/null || echo unknown)@$(hostname -s 2>/dev/null || echo host)}"
LOCK_TOKEN="${GCP_TF_CI_LOCK_TOKEN:-${LOCK_HOLDER}:$$}"

# An ssh-agent socket in the environment breaks IAP SSH. Emptied here, before
# any code path can reach `gcloud compute ssh`. Exported so the stub gcloud in
# the tests observes the same value the real one would.
export SSH_AUTH_SOCK=

# Word-split deliberately: this is a command plus its flags supplied by the
# operator (e.g. "gcloud --verbosity=error"), not user input.
read -r -a GCLOUD <<<"$GCLOUD_CMD"

HOLDS_LOCK=0

die() {
  printf 'gcp-tf-ci: %s\n' "$*" >&2
  exit 2
}

log() { printf '==> %s\n' "$*"; }

# ── Lane identity ───────────────────────────────────────────────────────────
#
# Restricted to CI keys by the same regex terraform/modules/ci-runner enforces.
# A lane key is the only thing that decides which VM this script touches, so a
# typo that resolved to a demo VM would be a resume/suspend against production.

require_lane() {
  [ -n "$CI_KEY" ] || die "GCP_TF_CI_KEY is not set (expected a CI lane key such as ci-1)"
  case "$CI_KEY" in
    ci-[1-9] | ci-[1-9][0-9]*) ;;
    *) die "GCP_TF_CI_KEY must match ^ci-[1-9][0-9]*\$ — refusing to act on '${CI_KEY}'" ;;
  esac
}

vm_name() {
  printf '%s' "${GCP_TF_CI_VM:-sl-${CI_KEY}-runner}"
}

# ── Per-lane lock ───────────────────────────────────────────────────────────
#
# Keyed on the lane, so ci-1 and ci-2 never contend — the whole point of having
# lanes. Same idiom as scripts/ci/ci-lock.sh: mkdir is atomic and fails
# unambiguously when the directory exists, where `[ -e ] && mkdir` is the
# check-then-act race the lock exists to remove. That file locks a path on a
# shared VM; this one locks locally, because each lane is its own VM and the
# collision being prevented is two local runs driving the same lane.

lock_path() {
  printf '%s/gcp-tf-ci-%s.lock' "$LOCK_HOME" "$CI_KEY"
}

lock_acquire() {
  local path age holder held_since
  path="$(lock_path)"

  if mkdir "$path" 2>/dev/null; then
    printf '%s|%s|%s\n' "$LOCK_HOLDER" "$LOCK_TOKEN" "$(date +%s)" >"${path}/holder"
    HOLDS_LOCK=1
    log "lane ${CI_KEY} locked by ${LOCK_HOLDER}"
    return 0
  fi

  holder="$(cut -d'|' -f1 <"${path}/holder" 2>/dev/null || true)"
  held_since="$(cut -d'|' -f3 <"${path}/holder" 2>/dev/null || true)"
  age=0
  [ -n "$held_since" ] && age=$(( $(date +%s) - held_since ))

  if [ -n "$held_since" ] && [ "$age" -gt $((LOCK_TTL_MINUTES * 60)) ]; then
    printf 'gcp-tf-ci: reclaiming a STALE lane lock held by %s for %dm (TTL %dm)\n' \
      "${holder:-an unknown process}" "$((age / 60))" "$LOCK_TTL_MINUTES" >&2
    printf '%s|%s|%s\n' "$LOCK_HOLDER" "$LOCK_TOKEN" "$(date +%s)" >"${path}/holder"
    HOLDS_LOCK=1
    return 0
  fi

  cat >&2 <<EOF
gcp-tf-ci: REFUSING — lane ${CI_KEY} is in use.

  Held by : ${holder:-an unknown process}
  For     : $((age / 60))m
  Lock    : ${path}

  Proceeding would resume and then suspend a VM someone else is mid-run on.
  Other lanes are unaffected — try a different GCP_TF_CI_KEY.
EOF
  return 1
}

# Never turns a passing run into a failing one, and never releases a lock that
# was legitimately reclaimed while we ran. Every path returns 0 explicitly.
lock_release() {
  local path token
  [ "$HOLDS_LOCK" = "1" ] || return 0
  path="$(lock_path)"
  token="$(cut -d'|' -f2 <"${path}/holder" 2>/dev/null || true)"
  if [ -n "$token" ] && [ "$token" != "$LOCK_TOKEN" ]; then
    printf 'gcp-tf-ci: NOT releasing — lane %s is now held by someone else\n' "$CI_KEY" >&2
    HOLDS_LOCK=0
    return 0
  fi
  rm -rf "$path"
  HOLDS_LOCK=0
  return 0
}

# ── gcloud boundary ─────────────────────────────────────────────────────────

vm_status() {
  local out rc=0
  out="$("${GCLOUD[@]}" compute instances describe "$(vm_name)" \
    --zone="$ZONE" --project="$PROJECT" --format='get(status)' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | tr -d '[:space:]'
    return 0
  fi
  # An unreadable state is not an absent VM. Distinguishing them matters: acting
  # on "absent" would mean provisioning a duplicate lane.
  case "$out" in
    *"was not found"* | *"notFound"* | *"does not exist"*) printf 'NOT_FOUND' ;;
    *"gcloud auth login"* | *"Reauthentication"* | *"credentials"*) printf 'AUTH_REQUIRED' ;;
    *) printf 'QUERY_FAILED' ;;
  esac
}

# SSH_AUTH_SOCK is already empty process-wide; re-stated on the call itself so
# the guard survives anyone later sourcing this file or reordering the header.
lane_ssh() {
  SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute ssh "$(vm_name)" \
    --zone="$ZONE" --project="$PROJECT" --tunnel-through-iap \
    --command="$1"
}

wait_for_ssh() {
  local attempts=0
  while [ "$attempts" -lt "$SSH_WAIT_ATTEMPTS" ]; do
    if lane_ssh "echo ready" >/dev/null 2>&1; then
      log "SSH is available on lane ${CI_KEY}"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep "$SSH_WAIT_INTERVAL"
  done
  printf 'gcp-tf-ci: lane %s did not accept SSH within %ds\n' \
    "$CI_KEY" "$((SSH_WAIT_ATTEMPTS * SSH_WAIT_INTERVAL))" >&2
  return 2
}

resume_lane() {
  local status
  status="$(vm_status)"
  case "$status" in
    RUNNING)
      log "lane ${CI_KEY} is already running"
      ;;
    SUSPENDED)
      log "resuming suspended lane ${CI_KEY}"
      "${GCLOUD[@]}" compute instances resume "$(vm_name)" \
        --zone="$ZONE" --project="$PROJECT" --quiet
      wait_for_ssh || return 2
      ;;
    TERMINATED | STOPPED)
      log "starting stopped lane ${CI_KEY}"
      "${GCLOUD[@]}" compute instances start "$(vm_name)" \
        --zone="$ZONE" --project="$PROJECT" --quiet
      wait_for_ssh || return 2
      ;;
    NOT_FOUND)
      die "lane ${CI_KEY} does not exist — apply terraform/modules/ci-runner for this lane first"
      ;;
    AUTH_REQUIRED)
      die "gcloud is not authenticated, so lane ${CI_KEY}'s state is UNKNOWN. This is not evidence the lane is missing."
      ;;
    *)
      die "could not read lane ${CI_KEY}'s state (got '${status}') — refusing to act on an unknown state"
      ;;
  esac
  return 0
}

suspend_lane() {
  if [ "${GCP_TF_CI_SKIP_SUSPEND:-0}" = "1" ]; then
    log "suspend skipped (GCP_TF_CI_SKIP_SUSPEND=1) — this lane will bill until you suspend it"
    return 0
  fi
  log "suspending lane ${CI_KEY}"
  "${GCLOUD[@]}" compute instances suspend "$(vm_name)" \
    --zone="$ZONE" --project="$PROJECT" --quiet
}

# ── Exit handling ───────────────────────────────────────────────────────────
#
# See the header. rc is captured first, every cleanup is `|| true`, and the last
# statement is an explicit `exit "$rc"`.

on_exit() {
  local rc=$?
  trap - EXIT INT TERM

  # The suspend is the KPI: it runs on the pass path, the fail path, and the
  # interrupt path. Its own failure is reported and then discarded — a lane that
  # would not suspend must not also turn a green run red.
  suspend_lane || printf 'gcp-tf-ci: WARNING — suspend failed for lane %s; it is still billing\n' "$CI_KEY" >&2
  lock_release || true

  exit "$rc"
}

# Trapping the signals to an explicit exit is what makes bash run the EXIT trap
# on an interrupt. Without these, Ctrl-C leaves the lane running.
on_int() { exit 130; }
on_term() { exit 143; }

# ── Commands ────────────────────────────────────────────────────────────────

cmd_run() {
  require_lane
  lock_acquire || exit 1

  trap on_exit EXIT
  trap on_int INT
  trap on_term TERM

  resume_lane

  local rc=0
  log "running tests on lane ${CI_KEY}: ${TEST_CMD}"
  lane_ssh "cd $(printf '%q' "$REMOTE_DIR") && ${TEST_CMD}" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log "lane ${CI_KEY}: tests PASSED"
  else
    printf 'gcp-tf-ci: lane %s: tests FAILED (rc=%d)\n' "$CI_KEY" "$rc" >&2
  fi

  # The EXIT trap suspends and unlocks; it preserves this status.
  exit "$rc"
}

cmd_suspend() {
  require_lane
  suspend_lane
}

cmd_status() {
  require_lane
  printf '%s %s\n' "$(vm_name)" "$(vm_status)"
}

cmd_lock_path() {
  require_lane
  lock_path
  printf '\n'
}

case "${1:-run}" in
  run) cmd_run ;;
  suspend) cmd_suspend ;;
  status) cmd_status ;;
  lock-path) cmd_lock_path ;;
  -h | --help | help)
    sed -n '2,10p' "$0"
    ;;
  *) die "usage: $(basename "$0") {run|suspend|status|lock-path}" ;;
esac
