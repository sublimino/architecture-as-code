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
# be unreachable from it by construction, not by careful reading.
#
# ─── THE SELECTOR MOVED, AND THE OLD ONE WAS A FILENAME ─────────────────────
#
# Read this before changing anything below it.
#
# Until 2026-08-20 gate 3 of this script was:
#
#     the instance NAME must match ^sl-ci-[1-9][0-9]*-runner$, the name shape
#     terraform/modules/ci-runner produces, and nothing else
#
# and that string convention was, in practice, THE property keeping this script
# away from a demo VM. modules/ci-runner has since been absorbed into
# modules/compute so that a CI lane is the demo environment plus idle-suspend,
# and both kinds are now named `sl-<key>-vm`. Two things follow, and both are
# serious:
#
#   * left alone, `-runner` would have matched NOTHING. The reaper would have
#     suspended nothing, printed "0 suspended", exited 0, and every lane would
#     have billed forever. A silent no-op is the worse of the two failures
#     precisely because it presents as success.
#   * "fixed" by widening the pattern to `^sl-.*-vm$`, it would have been able
#     to suspend sl-demo-1-vm.
#
# So the selector is now the `ci-lane` LABEL, which terraform/modules/compute
# emits for `kind = "ci"` and for nothing else. That is stronger than a name
# convention because it is derived from the environment definition: the module's
# preconditions require var.kind, the env-contract `kind` label and the
# environment key's own prefix to agree before the plan is allowed to proceed.
#
# ─── The rule that must survive every future edit ───────────────────────────
#
# A NAME MAY ONLY EVER TAKE AWAY. No gate below admits an instance because of
# what it is called, and none may be added. Absence of the label is a REFUSAL,
# never a reason to fall back to matching a name — a fallback would reintroduce
# exactly the coupling this change removes, and it would do it in the code path
# that runs when the label mechanism is broken, which is the worst possible
# moment to start trusting a string.
#
# ─── Six independent gates, each sufficient on its own ──────────────────────
#
#   1. the gcloud filter selects only instances carrying a `ci-lane` label, and
#      the filter is re-asserted locally so a filter that silently stopped
#      working cannot widen the blast radius. NO LABEL, NO REAP — full stop.
#   2. the `ci-lane` value must match ^ci-[1-9][0-9]*$, so an adversarial or
#      mistaken `ci-lane = demo-1` is rejected.
#   3. the `kind` label must be exactly "ci". This is the env-contract's own
#      mandatory label (CONTRACT §3), applied to every instance in the estate,
#      so a demo VM carries `kind = demo` and cannot pass — no matter what
#      anyone pasted into its `ci-lane` label.
#   4. the `environment` label must equal the `ci-lane` label. Both are written
#      by Terraform from one tfvars entry, so they agree for free on a real lane
#      and disagree the moment one of them was set by hand.
#   5. an explicit DEMO-MARKER refusal: `kind = demo`, an `environment` starting
#      `demo-`, or a name containing `demo`. Redundant against gates 3 and 4 by
#      construction, and that is the point — it is the gate that still fires if
#      someone later "simplifies" the label checks.
#   6. an explicit denylist naming signalloom-ci and signalloom-ci-2, the shared
#      runners owned by scripts/ci/gcp-ci.sh.
#
# The cost of the redundancy is a dozen lines. The cost of being wrong once is
# somebody else's running demo.
#
# ─── Reporting a no-op loudly ───────────────────────────────────────────────
#
# Because a broken selector and a genuinely idle estate produce the same
# "0 suspended", the summary distinguishes them: if the listing returned no rows
# at all, or returned rows and admitted none of them, that is stated explicitly
# rather than left to be inferred from a zero.

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

# The `ci-lane` label value terraform/modules/compute emits for kind = "ci".
# Anchored at BOTH ends: an unanchored form would admit `xci-1x`, and this repo
# has already shipped a token matching inside a longer token (DEMO_ENV inside
# SL_DEMO_ENV) in a guard that read as correct.
readonly LANE_LABEL_PATTERN='^ci-[1-9][0-9]*$'

# The env-contract's mandatory `kind` label (CONTRACT §3). Compared with string
# equality rather than a regex, because "is exactly ci" is the property and a
# regex is a second place for an anchor to go missing.
readonly LANE_KIND='ci'
readonly DEMO_KIND='demo'

# Demo markers. Gate 5 refuses on any of these regardless of what the other
# gates decided. Deliberately broad: over-refusing costs a lane that stays up
# for another 45 minutes, and the summary says loudly when nothing was admitted.
# Under-refusing costs a running demo.
readonly DEMO_ENV_PATTERN='^demo-'
readonly DEMO_NAME_SUBSTRING='demo'

# NOTE: there is deliberately NO lane NAME pattern here, and adding one back
# would be a regression even if it were only used to refuse. See the header:
# a name may only ever take away, and the two negative name checks that remain
# (gate 5's `demo` substring and gate 6's denylist) are the whole of it.

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

# Gate 5. Returns 0 (true, REFUSE) when the row carries any demo-lane marker.
#
# Three independent markers, OR-ed. A demo VM built by this estate trips all
# three; tripping any one is enough. Extracted into a function so each marker is
# testable in isolation and so a mutation harness can remove exactly one of them
# — a compound condition inlined at the call site is a single thing to delete,
# which makes "each marker is load-bearing" unprovable.
has_demo_markers() {
  local name="$1" kind="$2" env="$3"

  [ "$kind" = "$DEMO_KIND" ] && return 0
  printf '%s' "$env" | grep -Eq "$DEMO_ENV_PATTERN" && return 0
  case "$name" in
    *"$DEMO_NAME_SUBSTRING"*) return 0 ;;
  esac

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

# The two label columns are APPENDED, never inserted. Every existing field keeps
# its position, so a reader that only knows the old five still parses correctly
# and a stale fixture degrades to empty kind/environment — which every gate
# below treats as a refusal. Fail-closed on a short row is the whole reason for
# putting them at the end.
list_lanes() {
  local args=(
    compute instances list
    --project="$PROJECT"
    --filter="labels.ci-lane:* AND status=RUNNING"
    "--format=value(name,zone,labels.ci-lane,lastStartTimestamp,status,labels.kind,labels.environment)"
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
  local name zone lane ts status kind env age
  local reaped=0 skipped=0 seen=0 admitted=0

  printf '==> reaping CI lanes idle beyond %s minutes in %s\n' "$IDLE_MINUTES" "$PROJECT"

  while IFS=$'\t' read -r name zone lane ts status kind env; do
    [ -n "${name:-}" ] || continue
    seen=$((seen + 1))

    # ── Gate 1 — the ci-lane label. REFUSE on absence; never fall back. ─────
    #
    # The gcloud filter already asked for this; re-asserted locally so a filter
    # that silently stopped working cannot widen the blast radius. There is no
    # `else` branch here that inspects the name, and adding one would defeat the
    # entire design — see the header.
    if [ -z "${lane:-}" ]; then
      printf '    skip %-24s REFUSED: no ci-lane label (never inferred from the name)\n' "$name"
      skipped=$((skipped + 1))
      continue
    fi

    # ── Gate 2 — an adversarial or mistaken `ci-lane = demo-1` is not a lane ─
    if ! printf '%s' "$lane" | grep -Eq "$LANE_LABEL_PATTERN"; then
      printf '    skip %-24s REFUSED: ci-lane label %s is not a CI lane key\n' "$name" "$lane"
      skipped=$((skipped + 1))
      continue
    fi

    # ── Gate 3 — the env-contract kind label must be exactly "ci" ───────────
    #
    # This is what replaced the name-shape gate. modules/env-contract applies
    # `kind` to every instance in the estate and modules/compute refuses to plan
    # unless it agrees with var.kind and with the environment key's prefix, so a
    # demo VM carries `kind = demo` whatever else was done to it. An ABSENT
    # label fails this too, which is the fail-closed behaviour a short or stale
    # listing row must have.
    if [ "${kind:-}" != "$LANE_KIND" ]; then
      printf '    skip %-24s REFUSED: kind label is %s, not %s\n' \
        "$name" "${kind:-<absent>}" "$LANE_KIND"
      skipped=$((skipped + 1))
      continue
    fi

    # ── Gate 4 — the environment label must agree with the ci-lane label ────
    #
    # Terraform writes both from one tfvars entry. They agree for free on a real
    # lane; a disagreement means at least one was set by hand, and a hand-set
    # label on an instance this script is about to switch off is not something
    # to resolve in favour of proceeding.
    if [ "${env:-}" != "$lane" ]; then
      printf '    skip %-24s REFUSED: environment label %s disagrees with ci-lane %s\n' \
        "$name" "${env:-<absent>}" "$lane"
      skipped=$((skipped + 1))
      continue
    fi

    # ── Gate 5 — demo markers, refused regardless of anything above ─────────
    #
    # Redundant against gates 3 and 4 by construction. Kept because redundancy
    # is the only thing that survives a future edit which "simplifies" the label
    # checks, and because this is the gate whose failure is a running demo.
    if has_demo_markers "$name" "${kind:-}" "${env:-}"; then
      printf '    skip %-24s REFUSED: carries demo-lane markers (kind=%s environment=%s)\n' \
        "$name" "${kind:-<absent>}" "${env:-<absent>}"
      skipped=$((skipped + 1))
      continue
    fi

    # ── Gate 6 — the shared runners owned by scripts/ci/gcp-ci.sh ───────────
    if is_protected "$name"; then
      printf '    skip %-24s REFUSED: protected instance\n' "$name"
      skipped=$((skipped + 1))
      continue
    fi

    # Past every refusal. Everything below is about WHETHER to act, not about
    # whether this script is entitled to.
    admitted=$((admitted + 1))

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

  # ── Say which kind of zero this is ──────────────────────────────────────
  #
  # A broken selector and a genuinely idle estate both print "0 suspended". The
  # first is a silent forever-bill and the second is the system working. They
  # are distinguished here rather than left to be inferred, because the whole
  # reason the selector changed is that the previous one would have degraded
  # into the first while looking like the second.
  if [ "$seen" -eq 0 ]; then
    printf '==> NOTE: no instance in %s carries a ci-lane label at all. Either no CI\n' "$PROJECT"
    printf '    lane is running, or the selector is broken. This is not evidence of either.\n'
  elif [ "$admitted" -eq 0 ]; then
    printf '==> NOTE: %d labelled instance(s) were listed and every one was REFUSED by a\n' "$seen"
    printf '    safety gate. If a real CI lane is running, the gates disagree with it.\n'
  fi

  printf '==> %d suspended, %d left alone (%d listed, %d admitted past the safety gates)\n' \
    "$reaped" "$skipped" "$seen" "$admitted"
}

main
