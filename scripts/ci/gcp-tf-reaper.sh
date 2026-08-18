#!/usr/bin/env bash
#
# gcp-tf-reaper.sh — suspend Terraform CI lanes that have been up too long.
#
#   gcp-tf-reaper.sh [--idle-minutes N] [--dry-run] [--project P] [--zone Z]
#
# scripts/ci/gcp-tf-ci.sh suspends its lane after every COMPLETED run. This
# script exists for the runs that never complete: a killed CI job, a lost SSH
# session, a laptop that closed mid-run. Those leave a lane running until
# somebody notices the bill.
#
# ─── What "idle" means here ─────────────────────────────────────────────────
#
# Uptime since the lane last started, not keystroke idleness. That is the honest
# description and it is also the right measure: gcp-tf-ci.sh suspends on pass,
# on fail, and on interrupt, so a lane still RUNNING well past the threshold is
# by construction a lane whose owner is gone. The threshold must therefore sit
# comfortably above the longest legitimate run.
#
# ─── Why this cannot touch anything but a CI lane ───────────────────────────
#
# A reaper is a script whose entire job is turning other people's machines off.
# The demo VMs and the pre-existing signalloom-ci / signalloom-ci-2 runners must
# be unreachable from it by construction, not by careful reading. Four
# independent gates, each sufficient on its own:
#
#   1. the gcloud filter selects only instances carrying a ci-lane label;
#   2. the ci-lane label value must match ^ci-[1-9][0-9]*$, so an adversarial
#      `ci-lane = demo-1` label is rejected;
#   3. the instance NAME must match ^sl-ci-[1-9][0-9]*-runner$, the name
#      terraform/modules/ci-runner produces — no demo VM and neither legacy
#      runner can ever match it;
#   4. an explicit denylist names signalloom-ci and signalloom-ci-2, so a future
#      rename that accidentally satisfied gate 3 still would not reach suspend.
#
# Gates 2 and 4 are redundant against gate 3 today. That is the point: the cost
# of the redundancy is four lines, and the cost of being wrong once is somebody
# else's cluster.

set -euo pipefail

# The threshold is a variable, overridable by flag and by environment. It is
# never written as a literal at the comparison site.
IDLE_MINUTES="${GCP_TF_REAPER_IDLE_MINUTES:-45}"
PROJECT="${GCP_TF_REAPER_PROJECT:-CHANGEME-project}"
ZONE="${GCP_TF_REAPER_ZONE:-}"
GCLOUD_CMD="${GCP_TF_REAPER_GCLOUD:-gcloud}"
DRY_RUN=0

# The reaper never opens an SSH session, but it shares a machine with scripts
# that do, and an inherited agent socket has cost debugging time on this project.
export SSH_AUTH_SOCK=

# Instances that must never be suspended by this script regardless of labels.
# These are the shared runners owned by scripts/ci/gcp-ci.sh.
readonly PROTECTED_INSTANCES=(
  signalloom-ci
  signalloom-ci-2
)

# The name shape terraform/modules/ci-runner emits: sl-<lane key>-runner.
readonly LANE_NAME_PATTERN='^sl-ci-[1-9][0-9]*-runner$'
readonly LANE_LABEL_PATTERN='^ci-[1-9][0-9]*$'

die() {
  printf 'gcp-tf-reaper: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --idle-minutes)
      shift
      IDLE_MINUTES="${1:-}"
      ;;
    --project)
      shift
      PROJECT="${1:-}"
      ;;
    --zone)
      shift
      ZONE="${1:-}"
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

case "$IDLE_MINUTES" in
  '' | *[!0-9]*) die "--idle-minutes must be a positive integer, got '${IDLE_MINUTES}'" ;;
esac
[ "$IDLE_MINUTES" -ge 1 ] || die "--idle-minutes must be at least 1"

read -r -a GCLOUD <<<"$GCLOUD_CMD"

is_protected() {
  local name="$1" p
  for p in "${PROTECTED_INSTANCES[@]}"; do
    [ "$name" = "$p" ] && return 0
  done
  return 1
}

# Returns the instance's age in minutes since it last started, or empty if the
# timestamp is unparseable. Unparseable means "do not touch it" — the safe
# failure for a script that turns machines off is to leave them on.
age_minutes() {
  local ts="$1" epoch now
  [ -n "$ts" ] || return 1
  epoch="$(date -d "$ts" +%s 2>/dev/null)" || return 1
  [ -n "$epoch" ] || return 1
  now="$(date +%s)"
  printf '%d' $(((now - epoch) / 60))
}

list_lanes() {
  local args=(
    compute instances list
    --project="$PROJECT"
    --filter="labels.ci-lane:* AND status=RUNNING"
    "--format=value(name,zone,labels.ci-lane,lastStartTimestamp,status)"
  )
  [ -n "$ZONE" ] && args+=(--zones="$ZONE")
  "${GCLOUD[@]}" "${args[@]}"
}

suspend_lane() {
  local name="$1" zone="$2"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN would suspend %s (zone %s)\n' "$name" "$zone"
    return 0
  fi
  "${GCLOUD[@]}" compute instances suspend "$name" \
    --zone="$zone" --project="$PROJECT" --quiet
}

main() {
  local name zone lane ts status age reaped=0 skipped=0

  printf '==> reaping CI lanes idle beyond %s minutes in %s\n' "$IDLE_MINUTES" "$PROJECT"

  while IFS=$'\t' read -r name zone lane ts status; do
    [ -n "${name:-}" ] || continue

    # Gate 1 is the gcloud filter; re-assert it locally so a filter that silently
    # stopped working cannot widen the blast radius.
    if [ -z "${lane:-}" ]; then
      printf '    skip %-24s no ci-lane label\n' "$name"
      skipped=$((skipped + 1))
      continue
    fi

    # Gate 2 — an adversarial or mistaken `ci-lane = demo-1` is not a CI lane.
    if ! printf '%s' "$lane" | grep -Eq "$LANE_LABEL_PATTERN"; then
      printf '    skip %-24s ci-lane label %s is not a CI lane key\n' "$name" "$lane"
      skipped=$((skipped + 1))
      continue
    fi

    # Gate 3 — the name shape modules/ci-runner produces, and nothing else.
    if ! printf '%s' "$name" | grep -Eq "$LANE_NAME_PATTERN"; then
      printf '    skip %-24s name is not a managed CI lane\n' "$name"
      skipped=$((skipped + 1))
      continue
    fi

    # Gate 4 — the shared runners owned by scripts/ci/gcp-ci.sh.
    if is_protected "$name"; then
      printf '    skip %-24s protected instance\n' "$name"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "${status:-}" != "RUNNING" ]; then
      printf '    skip %-24s state is %s\n' "$name" "${status:-unknown}"
      skipped=$((skipped + 1))
      continue
    fi

    if ! age="$(age_minutes "${ts:-}")"; then
      printf '    skip %-24s unreadable start timestamp\n' "$name"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$age" -lt "$IDLE_MINUTES" ]; then
      printf '    keep %-24s up %sm, under the %sm threshold\n' "$name" "$age" "$IDLE_MINUTES"
      skipped=$((skipped + 1))
      continue
    fi

    printf '    reap %-24s up %sm, past the %sm threshold\n' "$name" "$age" "$IDLE_MINUTES"
    if suspend_lane "$name" "$zone"; then
      reaped=$((reaped + 1))
    else
      printf 'gcp-tf-reaper: WARNING — suspend failed for %s\n' "$name" >&2
    fi
  done < <(list_lanes)

  printf '==> %d suspended, %d left alone\n' "$reaped" "$skipped"
}

main
