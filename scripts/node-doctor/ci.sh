#!/usr/bin/env bash
# ci.sh — the ci-lane node doctor.
#
# Called by scripts/node-doctor.sh once the lane kind has been resolved. Runs
# the shared block plus the two properties that make a lane a CI lane, and
# handles the one state that means the opposite of what it looks like.
#
# ═══ SUSPENDED IS THE SUCCESS STATE ═════════════════════════════════════════
#
# The single most expensive thing this file can get wrong. A ci-* lane carries
# `idle-suspend-minutes` metadata and scripts/ci/gcp-tf-reaper.sh suspends it
# once that budget is exhausted. So a CI lane found SUSPENDED is a CI lane whose
# cost control is WORKING.
#
# Reporting that as a fault is not a cosmetic error. The obvious response to
# "the CI VM is down" is to resume it, and resuming a lane nobody is using
# restarts the billing the reaper just stopped — while the doctor that caused it
# reports a fix. Worse, the same lane self-suspends MID-SESSION on a 30-minute
# timer: a URL that worked ten minutes ago answering 000 now reads exactly like
# a regression somebody just introduced.
#
# So: SUSPENDED passes, is labelled as expected, and the run STOPS there rather
# than emitting a screen of UNKNOWNs that all share one benign cause.
#
# ─── What is actually different about a CI lane ─────────────────────────────
#
# Two properties, and no more. Andy's decision (terraform/environments/main.tf,
# 2026-08-20) collapsed modules/ci-runner into modules/compute precisely so that
# a CI lane and a demo lane are the same machine. Measured 2026-08-21:
#
#   sl-ci-1-vm    ci-lane=ci-1   kind=ci    idle-suspend-minutes=30
#   sl-ci-2-vm    ci-lane=ci-2   kind=ci    idle-suspend-minutes=30
#
# Inverted, both are real incidents: a CI lane WITHOUT `ci-lane` is a lane the
# reaper's selector cannot match, so it is never suspended and bills until
# somebody notices — and the reaper reports success the whole time, because
# suspending nothing is not an error. A budget below 5 suspends lanes mid-run.
# COMPUTE-RULE-10 and COMPUTE-RULE-12 enforce both at plan time; they are
# re-checked here against the LIVE instance because a plan-time rule describes
# what Terraform intended, not what the instance currently wears.
#
# ─── What is deliberately NOT checked, and why ──────────────────────────────
#
# The CI advisory lock. scripts/ci/ci-lock.sh keeps it at /home/ci/.ci-lock,
# which belongs to the legacy scripts/ci/gcp-ci.sh estate. Measured on
# sl-ci-1-vm 2026-08-21: /opt/signalloom holds no lock file and there is no
# /home/ci. Checking a path that does not exist on these lanes would report a
# free lock on every run — a check that cannot fail, which is worse than no
# check because it also stops anyone writing one that can.
#
# A local systemd idle timer. There is none: `systemctl list-units --type=timer`
# on sl-ci-1-vm returns nothing idle-related. The suspension is driven from
# OUTSIDE by the reaper reading the instance metadata, which is why the budget
# check below is an API-side fact and not a VM-side one.

set -eo pipefail

# shellcheck source=scripts/node-doctor/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

nd_doctor_ci() {
  local report="$1" env_key="$2" app_port="$3" expect_host="$4"
  local vm_status="$5" ci_lane_label="$6" idle_minutes="$7"
  local v

  nd_header "LANE (ci)"
  v="$(nd_verdict_vm_status ci "$vm_status")"
  case "$vm_status" in
    SUSPENDED|SUSPENDING)
      nd_report "$v" "instance status: ${vm_status} — EXPECTED for an idle ci lane. The reaper suspended it after its ${idle_minutes:-?}-minute budget; that is the cost control working, not a fault. Do NOT resume it to 'fix' this." ;;
    *)
      nd_report "$v" "instance status: ${vm_status}" ;;
  esac

  v="$(nd_verdict_ci_lane_label "$env_key" "$ci_lane_label")"
  if [ "$v" = "FAIL" ]; then
    nd_report FAIL "reaper label wrong: ci-lane='${ci_lane_label}', expected '${env_key}'. scripts/ci/gcp-tf-reaper.sh selects on this label and cross-checks its value against the environment label; a mismatch or an absence makes this lane UNREAPABLE — it bills until somebody notices, and the reaper reports success throughout because suspending nothing is not an error."
  else
    nd_report "$v" "reaper label: ci-lane=${ci_lane_label} — the reaper can select this lane"
  fi

  v="$(nd_verdict_ci_idle_budget "$idle_minutes")"
  if [ "$v" = "FAIL" ]; then
    nd_report FAIL "idle-suspend budget is '${idle_minutes}'. COMPUTE-RULE-12 requires >= 5: below that the reaper suspends lanes mid-run, and at 0 or absent it never suspends them at all."
  else
    nd_report "$v" "idle-suspend budget: ${idle_minutes} minutes — the reaper reads its budget off the lane"
  fi

  # The stop, and the reason it is a stop rather than a cascade of UNKNOWNs.
  # Every VM-side check would report "could not measure" with the same single
  # benign cause, and a screen of them reads like a broken lane.
  case "$vm_status" in
    SUSPENDED|SUSPENDING)
      printf '\n  %sThis lane is idle and suspended. Nothing below could be measured, and\n' "$ND_CYA"
      printf '  nothing needs to be: the next run that wants it will resume it.%s\n' "$ND_RST"
      return 0 ;;
    TERMINATED|STOPPED)
      nd_unknown "the VM is ${vm_status}, so no VM-side check below could be attempted. That is NOT the reaper — it suspends, it does not stop."
      return 0 ;;
  esac

  nd_checks_shared "$report" "$env_key" "$app_port" "$expect_host"
}
