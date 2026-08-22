#!/usr/bin/env bats
#
# `ensure_vm_ready` must not return until the VM actually accepts SSH.
#
# ─── The run this was written for ───────────────────────────────────────────
#
# ci-1, 2026-08-22, third consecutive from-scratch cycle, running exactly the
# documented loop:
#
#   make gcp-tf-up ENV=ci-1        # terraform apply, exits 0
#   make gcp-tf-demo-up ENV=ci-1   # immediately after
#
# demo-up said `==> sl-ci-1-vm is already running`, went straight to delivery,
# and died 36 seconds later on a raw gcloud traceback:
#
#   ERROR: [0] Error during local connection to [stdin]: Error while connecting
#   [4003: 'failed to connect to backend']. (Failed to connect to port 22)
#   ERROR: (gcloud.compute.scp) [/usr/bin/scp] exited with return code [255].
#
# Measured on that VM: created 18:28:32, guest booted 18:28:49 (`uptime -s`),
# scp attempted ~18:29:46 — about 74 seconds after creation. The same SSH
# command succeeded by hand at 18:35:57. Nothing was wrong with the VM; it was
# asked too early.
#
# ─── Why the RUNNING branch specifically ────────────────────────────────────
#
# `ensure_vm_ready` already waits on the two branches where it is obvious that
# it must: SUSPENDED (after `instances resume`) and TERMINATED/STOPPED (after
# `instances start`). The RUNNING branch logged "is already running" and
# returned 0.
#
# The assumption underneath is that RUNNING means reachable. GCE reports RUNNING
# as soon as the instance object is created, which is well before the guest's
# sshd is listening and before IAP can reach port 22 — so the assumption is true
# of a VM that has been up for a while and false of one `terraform apply`
# created a minute ago. That is precisely the VM the documented loop hands to
# demo-up, so the one branch with no wait is the one the loop always takes.
#
# It is invisible in proportion to how slowly you work. Cycle 1 of the same loop
# survived because minutes of human thinking sat between the two commands;
# cycle 2 survived on the margin; cycle 3 lost the race. A defect that only
# appears when the operator is fast is one that appears first in automation.
#
# ─── What is asserted ───────────────────────────────────────────────────────
#
# Behaviour, not the presence of a line. A grep for `wait_for_ssh` inside the
# RUNNING branch would be satisfied by a comment mentioning it, and would go
# green against a `wait_for_ssh` whose result is discarded. So the driver is
# sourced as a library and `ensure_vm_ready` is run for real against a stubbed
# `vm_ssh` whose success is the variable under test.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"

	[ -f "${DRIVER_SRC}" ] || {
		echo "driver not found at ${DRIVER_SRC} — nothing was tested"
		return 1
	}
	# The subject must exist before anything claims to have exercised it. A
	# renamed function would otherwise leave every test below calling a stub of
	# its own making and passing.
	grep -q '^ensure_vm_ready()' "${DRIVER_SRC}" || {
		echo "the driver defines no ensure_vm_ready — these tests would be vacuous"
		return 1
	}
	grep -q '^wait_for_ssh()' "${DRIVER_SRC}" || {
		echo "the driver defines no wait_for_ssh — there is no readiness wait to assert on"
		return 1
	}

	WORK="${BATS_TEST_TMPDIR}/work"
	mkdir -p "${WORK}/scripts/gcp-tf" "${WORK}/scripts/lib"
	driver="${WORK}/scripts/gcp-tf/demo-up.sh"
	cp "${DRIVER_SRC}" "${driver}"
	cp -a "${REPO_ROOT}/scripts/lib/." "${WORK}/scripts/lib/"

	CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
	export CALL_LOG
	: >"${CALL_LOG}"
}

# Source the driver as a library and run the real ensure_vm_ready against
# stubbed collaborators. `vm_status` decides which branch is taken and `vm_ssh`
# decides whether the VM is reachable — the two inputs the subject exists to
# combine.
#
# The wait budget is squeezed to 3 x 0s so an unreachable VM costs no wall
# clock. The real defaults are 30 x 5s = 150s, comfortably more than the ~74s
# gap measured on ci-1.
write_harness() { # write_harness <vm_status> <vm_ssh-exit-status>
	cat >"${WORK}/harness.sh" <<-HARNESS
		#!/usr/bin/env bash
		set -uo pipefail

		sed '/^case "\${1:-up}" in/,\$d' "${driver}" >"${WORK}/scripts/gcp-tf/lib.sh"
		# shellcheck disable=SC1090
		source "${WORK}/scripts/gcp-tf/lib.sh"

		log_call() { printf '%s\n' "\$1" >>"${CALL_LOG}"; }

		vm_status()   { printf '%s' "$1"; }
		vm_ssh()      { log_call vm_ssh; return $2; }
		gcloud_common() { :; }
		run_filtered()  { log_call "run_filtered:\$*"; }
		die()  { printf 'DIE: %s\n' "\$*" >&2; exit 9; }
		warn() { printf 'WARN: %s\n' "\$*" >&2; }
		log()  { printf '==> %s\n' "\$*"; }

		SSH_WAIT_ATTEMPTS=3
		SSH_WAIT_INTERVAL=0
		INSTANCE_NAME=sl-ci-1-vm
		PROJECT_ID=proj
		ZONE=zone
		ENV_KEY=ci-1
		GCLOUD=(gcloud)

		ensure_vm_ready
	HARNESS
	chmod +x "${WORK}/harness.sh"
}

@test "VMREADY a RUNNING VM that never accepts SSH is not called ready" {
	# The regression lock. Before the fix this returned 0 and the caller went
	# on to scp into a VM that could not be reached, surfacing as a gcloud
	# traceback from inside the delivery step rather than as a refusal here.
	write_harness RUNNING 1
	run bash "${WORK}/harness.sh"
	[ "$status" -ne 0 ]
}

@test "VMREADY a RUNNING VM is actually probed, not assumed reachable" {
	# The other half, and the one a status-code assertion alone would miss:
	# returning non-zero for the right reason. If the RUNNING branch never
	# calls vm_ssh at all then it is not waiting, whatever it returns.
	write_harness RUNNING 1
	run bash "${WORK}/harness.sh"
	[ "$status" -ne 0 ]
	# wait_for_ssh's own timeout message. Its presence proves the branch reached
	# the wait and exhausted it, which the call log alone cannot distinguish
	# from a single opportunistic probe made for some other reason.
	[[ "$output" == *"did not accept SSH within"* ]]
	grep -q '^vm_ssh$' "${CALL_LOG}"
}

@test "VMREADY a RUNNING VM that does accept SSH is ready, and says so" {
	# Positive control. The fix must not turn a healthy lane into a refusal —
	# a guard that fails closed on everything is as useless as one that passes
	# on everything, and costs a 30-minute lane to discover.
	write_harness RUNNING 0
	run bash "${WORK}/harness.sh"
	[ "$status" -eq 0 ]
	grep -q '^vm_ssh$' "${CALL_LOG}"
}

@test "VMREADY the branches that already waited still wait" {
	# SUSPENDED and TERMINATED had the wait before this change and must keep it.
	# They are the control proving the harness can see a missing wait at all:
	# if these ever pass with an unreachable VM, the harness is not measuring
	# what the RUNNING tests above claim it measures.
	for state in SUSPENDED TERMINATED; do
		: >"${CALL_LOG}"
		write_harness "$state" 1
		run bash "${WORK}/harness.sh"
		[ "$status" -ne 0 ] || {
			echo "${state} returned 0 with an unreachable VM"
			return 1
		}
	done
}

@test "VMREADY an unreadable state is still refused outright" {
	# NOT_FOUND and the catch-all must keep dying rather than waiting 150s to
	# discover that a VM which does not exist does not answer SSH.
	write_harness NOT_FOUND 1
	run bash "${WORK}/harness.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not exist"* ]]
	# Nothing should have been probed: there is no VM to probe.
	run grep -c '^vm_ssh$' "${CALL_LOG}"
	[ "$output" = "0" ]
}
