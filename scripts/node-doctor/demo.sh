#!/usr/bin/env bash
# demo.sh — the demo-lane node doctor.
#
# Called by scripts/node-doctor.sh once the lane kind has been resolved. It runs
# the shared block and then the checks that are genuinely DEMO-only.
#
# ─── What is actually different about a demo lane ───────────────────────────
#
# Very little, and that is deliberate. Andy's decision (terraform/environments/
# main.tf, 2026-08-20) is that a CI environment IS a demo environment, differing
# only in that it suspends itself when idle and carries a reaper label. Before
# that, CI ran modules/ci-runner with no metadata_startup_script — a bare Debian
# box — and every fix to the demo bring-up landed on a machine CI never ran.
#
# So this file does NOT invent differences. Measured on the live estate,
# 2026-08-21:
#
#   sl-demo-1-vm  kind=demo  tier=demo  <no ci-lane label>  <no idle metadata>
#   sl-ci-1-vm    kind=ci    tier=ci    ci-lane=ci-1        idle-suspend-minutes=30
#
# Two properties, both inverted into real incidents:
#
#   a demo VM carrying `ci-lane`         the reaper is entitled to switch it
#                                        off, mid-presentation, and will
#   a demo VM carrying idle-suspend-*    it suspends itself while somebody is
#                                        demoing on it
#
# Both are enforced at plan time by terraform/modules/compute (COMPUTE-RULE-09,
# COMPUTE-RULE-12). They are re-checked here against the LIVE instance because a
# plan-time rule says what Terraform intended, and a label can be changed by
# hand, by another tool, or by an apply nobody remembers running.
#
# ─── What is deliberately NOT checked, and why ──────────────────────────────
#
# deletionProtection. It reads False on all four lanes including both demo lanes
# (measured 2026-08-21), so asserting it here would be inventing a contract the
# estate does not have and failing every demo lane on the strength of it.
#
# The HTTPS load balancer / Cloud Armor edge. modules/edge is demo-lanes-only by
# design, but `local.edge_environments` is `{}` and the module block is
# commented out, so there is nothing standing to check.

set -eo pipefail

# shellcheck source=scripts/node-doctor/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

nd_doctor_demo() {
  local report="$1" env_key="$2" app_port="$3" expect_host="$4"
  local vm_status="$5" ci_lane_label="$6" idle_minutes="$7"
  local v

  nd_header "LANE (demo)"
  v="$(nd_verdict_vm_status demo "$vm_status")"
  if [ "$v" = "FAIL" ] && [ "$vm_status" = "SUSPENDED" ]; then
    nd_report FAIL "instance is SUSPENDED. On a CI lane that is the idle reaper working as designed; on a DEMO lane nothing on this estate should ever suspend it, so something switched it off. Resume: gcloud compute instances resume ${env_key}"
  else
    nd_report "$v" "instance status: ${vm_status}"
  fi

  v="$(nd_verdict_demo_no_ci_label "$ci_lane_label")"
  if [ "$v" = "FAIL" ]; then
    nd_report FAIL "this DEMO lane carries the label ci-lane=${ci_lane_label}. scripts/ci/gcp-tf-reaper.sh selects instances to SUSPEND on exactly that label, so this VM is one the reaper is entitled to turn off — mid-demo, with no warning. COMPUTE-RULE-09 forbids it at plan time; finding it on the live instance means something set it outside Terraform."
  else
    nd_report "$v" "reaper label: ci-lane is absent, as a demo lane requires"
  fi

  v="$(nd_verdict_demo_no_idle_budget "$idle_minutes")"
  if [ "$v" = "FAIL" ]; then
    nd_report FAIL "this DEMO lane publishes idle-suspend-minutes=${idle_minutes}. That is the CI self-suspend budget; on a demo lane it means the VM can switch itself off while somebody is presenting on it. modules/compute emits no such key for kind=demo."
  else
    nd_report "$v" "idle-suspend budget: absent, as a demo lane requires (a demo VM must not switch itself off)"
  fi

  # SUSPENDED on a demo lane is a fault, but it is also a lane there is nothing
  # further to measure on. Report the fault, then stop rather than emit a screen
  # of UNKNOWNs that all have the same single cause.
  case "$vm_status" in
    SUSPENDED|SUSPENDING|TERMINATED|STOPPED)
      nd_unknown "the VM is not running, so no VM-side check below could be attempted."
      return 0 ;;
  esac

  nd_checks_shared "$report" "$env_key" "$app_port" "$expect_host"
}
