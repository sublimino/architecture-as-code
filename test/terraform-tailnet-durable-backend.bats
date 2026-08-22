#!/usr/bin/env bats
#
# The tailnet target has to outlive the run that created it.
#
# Named `terraform-*.bats` so `make gcp-tf-validate`'s glob registers it on the
# commit that lands it, for the same reason terraform-tailnet-remote.bats is:
# a suite that matches neither that glob nor a stage-1g list runs NOWHERE, and
# this repo has shipped 33 such suites at once.
#
# ─── The fault this suite exists to prevent ────────────────────────────────
#
# Measured on all four lanes on 2026-08-22, before the fix:
#
#     sl-demo-1  000        sl-demo-2  502
#     sl-ci-1    502        sl-ci-2    502
#
# Three lanes were ON the tailnet, holding a valid `tailscale serve` config
# that proxied `/` to `http://127.0.0.1:30754`, with NOTHING listening on
# 30754. `sudo ss -ltnp` on sl-ci-2-vm showed no such listener at all.
#
# The two halves of the access path are installed by DIFFERENT things:
#
#   serve half     signalloom-tailscale-serve.service, written by the VM's
#                  startup script — so it is present on every VM from birth,
#                  unconditionally, whether or not anything is behind it.
#   backend half   signalloom-dashboard-pf.service, written by ensure_published
#                  — which only ever ran from `ts-up`, `public` and
#                  `funnel-up`, and never from the deploy lane.
#
# So every VM booted advertising a URL and serving nothing, and the only way to
# make the URL work was a separate manual command. `cmd_up` completing was not
# enough. That is the gap: not a flake, not a dead pod — a lane that is healthy
# by every on-VM measure and unreachable by the one path a human uses.
#
# The estate's own suites could not see it. They assert against 127.0.0.1 ON
# the VM, where the dashboard is genuinely up; the tailnet is a separate access
# path nothing in the on-VM suite depends on. demo-1 scored 29/29 while
# answering 000.
#
# ─── What is asserted here, and what is asserted elsewhere ─────────────────
#
# terraform-tailnet-remote.bats owns the THREE-STATE distinction on the wire —
# absent node vs. up-but-not-serving vs. TLS failure vs. a 502 at the health
# path — and it already fails distinctly for each. This suite does not repeat
# it. This suite owns the one property that suite cannot see from outside: that
# the DEPLOY LANE ITSELF leaves a durable backend behind, so the URL still
# answers once the deploying process has exited.
#
# ─── Everything runs against the real control flow ─────────────────────────
#
# The driver is sourced as a library (its dispatch `case` stripped) so the
# genuine `run_lane` body executes and only its collaborators are stubbed. A
# grep for `ensure_published` in run_lane would pass against a call sitting in
# a comment — this repo has shipped a guard satisfied by exactly that.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
}

setup() {
	[ -f "${DRIVER_SRC}" ]
	[ -x "${DRIVER_SRC}" ]

	# ─── The mechanism must be PRESENT before its behaviour is asserted ────
	#
	# A correct test can run happily against a tree that no longer contains the
	# thing under test, and then report the wrong subject. Name the absence
	# here rather than as six assertion failures about stub logs.
	grep -q 'ensure_published()' "${DRIVER_SRC}" || {
		echo "the driver has no ensure_published — every assertion in this suite would be about nothing"
		return 1
	}
	grep -q 'run_lane()' "${DRIVER_SRC}" || {
		echo "the driver has no run_lane — the deploy-lane tests would be vacuous"
		return 1
	}
	grep -q 'PF_UNIT=' "${DRIVER_SRC}" || {
		echo "the driver names no port-forward unit — the durability tests would be vacuous"
		return 1
	}

	WORK="${BATS_TEST_TMPDIR}/work"
	mkdir -p "${WORK}/scripts/gcp-tf" "${WORK}/scripts/lib"

	# The driver copy under test. Mutations apply to THIS, never to the repo.
	driver="${WORK}/scripts/gcp-tf/demo-up.sh"
	cp "${DRIVER_SRC}" "${driver}"

	# The REAL library, copied as a DIRECTORY so a library gaining a second
	# file does not silently break the load. The driver resolves it as
	# `<its own dir>/../lib/wait.sh`, which is why the path shape matters.
	cp -a "${REPO_ROOT}/scripts/lib/." "${WORK}/scripts/lib/"
	[ -f "${WORK}/scripts/lib/wait.sh" ] || {
		echo "fixture is missing scripts/lib/wait.sh — the driver cannot source its library"
		return 1
	}

	CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
	export CALL_LOG
	: >"${CALL_LOG}"
}

# Apply a sed expression to the driver copy, and PROVE it applied.
#
# A sed expression that matches nothing exits 0 and changes nothing, so the
# mutation test that follows would run against CORRECT code and pass — a
# mutation proof proving the opposite of what it claims. This repo has shipped
# exactly that shape, more than once.
mutate() {
	local before after
	before="$(md5sum <"${driver}")"
	sed -i "$1" "${driver}"
	after="$(md5sum <"${driver}")"
	[ "$before" != "$after" ] || {
		echo "the mutation '$1' matched nothing — the test that follows would be vacuous"
		return 1
	}
}

# Build the harness that sources the driver-under-test as a library and runs
# `run_lane` with every collaborator stubbed to a logging no-op.
#
# The stubs are defined AFTER the source, so they replace the real definitions
# while the real run_lane body — the subject — is the one that executes.
#
# ensure_published's exit status is the test's to choose, because the property
# under test is what run_lane does with it.
write_lane_harness() { # write_lane_harness <ensure_published-exit-status>
	local pub_rc="$1"
	cat >"${WORK}/harness.sh" <<-HARNESS
		#!/usr/bin/env bash
		set -uo pipefail

		# Strip the dispatch so this file is a library, not a command.
		sed '/^case "\${1:-up}" in/,\$d' "${driver}" >"${WORK}/scripts/gcp-tf/lib.sh"
		# shellcheck disable=SC1090
		source "${WORK}/scripts/gcp-tf/lib.sh"

		log_call() { printf '%s\n' "\$1" >>"${CALL_LOG}"; }

		# ─── Collaborators, stubbed ────────────────────────────────────────
		capture_source_identity() { RUN_BRANCH=test; RUN_COMMIT=abc1234; RUN_STARTED_AT=now; }
		rotate_reports()          { :; }
		set_run_phase()           { :; }
		run_exit_trap()           { :; }
		ensure_vm_ready()         { log_call ensure_vm_ready; return 0; }
		deliver_code()            { log_call deliver_code; }
		deliver_afm_image()       { log_call deliver_afm_image; }
		run_pipeline()            { log_call run_pipeline; PIPELINE_EXIT=0; }
		collect_reports()         { log_call collect_reports; }
		classify_run_outcome()    { printf 'PASS'; }
		final_exit_code()         { printf '0'; }
		report_verdict()          { :; }
		write_surface_receipt()   { log_call write_surface_receipt; return 0; }

		# ─── The subject's collaborator, whose failure is the variable ─────
		ensure_published() { log_call "ensure_published:\$1"; return ${pub_rc}; }
		ensure_ts_serve_unit() { log_call "ensure_ts_serve_unit:\$1"; return 0; }

		warn() { printf 'WARN: %s\n' "\$*" >&2; }
		log()  { printf '==> %s\n' "\$*"; }

		ENV_KEY=ci-2
		PROJECT_ID=proj
		INSTANCE_NAME=vm
		ZONE=zone
		OPERATOR_SA=sa
		APP_PORT=30754
		PIPELINE_EXIT=0
		REPORT_DIR="${WORK}"
		SUMMARY_NAME=summary.json
		SURFACE_DIR="${WORK}"

		run_lane full
	HARNESS
	chmod +x "${WORK}/harness.sh"
}

run_lane_harness() { run bash "${WORK}/harness.sh"; }

# ─── The gap itself ─────────────────────────────────────────────────────────

@test "DURABLE the deploy lane installs the durable backend before it finishes" {
	write_lane_harness 0
	run_lane_harness

	grep -q '^ensure_published:' "${CALL_LOG}" || {
		echo "run_lane completed WITHOUT installing the dashboard port-forward unit."
		echo "This is the 502: the VM's startup script installs the tailscale serve"
		echo "half unconditionally at boot, so the lane advertises a URL whose"
		echo "backend only ever existed if somebody separately ran 'ts-up'."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "DURABLE the backend is published on the SAME port tailscale serve proxies to" {
	write_lane_harness 0
	run_lane_harness

	# A forward on one port and a serve config on another is a PERMANENT 502
	# that looks healthy from both ends: the unit is active, serve is
	# configured, and nothing connects them. APP_PORT is the single value.
	grep -q '^ensure_published:30754$' "${CALL_LOG}" || {
		echo "the forward was published on a port that is not APP_PORT."
		echo "serve proxies to 127.0.0.1:APP_PORT; a divergence here is a 502"
		echo "with every component reporting itself healthy."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "DURABLE installing the backend cannot turn a passing lane red" {
	# The verdict has already been decided and printed by this point. A lane
	# that tested green must not be reported as a failure because a
	# port-forward could not be installed — that would be bookkeeping
	# overriding the run's own result.
	write_lane_harness 8
	run_lane_harness

	[ "$status" -eq 0 ] || {
		echo "a failed publish changed the run's exit status to ${status}."
		echo "output: ${output}"
		return 1
	}
}

@test "DURABLE a backend that could not be installed WARNS rather than passing silently" {
	# The counterpart to the test above, and it is the half that matters. A
	# non-fatal step that says nothing when it fails is how a lane reports PASS
	# while its URL answers 502 — which is the exact history here.
	write_lane_harness 8
	run_lane_harness

	[[ "$output" == *"WARN:"* ]] || {
		echo "the publish failed and the lane said NOTHING about it."
		echo "output: ${output}"
		return 1
	}
	[[ "$output" == *"30754"* || "$output" == *"tailnet"* || "$output" == *"ts-up"* ]] || {
		echo "the warning does not name the port, the tailnet, or the recovery command,"
		echo "so a reader cannot act on it. output: ${output}"
		return 1
	}
}

# ─── The unit's own durability ──────────────────────────────────────────────

@test "DURABLE the forward is a systemd unit, not a process tied to the run" {
	# nohup/setsid survives the SSH session and nothing else. The whole point
	# is surviving the process that created it AND a reboot.
	grep -q 'ExecStart=.*port-forward' "${DRIVER_SRC}" || {
		echo "the forward is no longer an ExecStart — it cannot outlive the run"
		return 1
	}
	! grep -qE 'nohup .*port-forward|setsid .*port-forward' "${DRIVER_SRC}" || {
		echo "a nohup'd port-forward has come back; it does not survive a reboot"
		return 1
	}
}

@test "DURABLE the unit restarts always, because a dead forward exits ZERO" {
	# kubectl port-forward exits 0 when its pod goes away. Restart=on-failure
	# would leave the demo dead with the unit reported cleanly finished.
	#
	# `grep -qx`, matching the WHOLE LINE, is the load-bearing detail. The
	# driver mentions "Restart=always" in three separate COMMENTS explaining
	# why it is set, so a substring grep stays green with the directive itself
	# deleted — satisfied entirely by the prose that explains it. That is not
	# hypothetical: the mutation control below caught this suite doing it.
	grep -qx 'Restart=always' "${DRIVER_SRC}" || {
		echo "the unit no longer restarts always; a lost pod would silently end the demo"
		return 1
	}
}

@test "DURABLE the unit is wanted by multi-user.target, so it returns after a reboot" {
	grep -qx 'WantedBy=multi-user.target' "${DRIVER_SRC}" || {
		echo "the unit is not linked into a target — it would not come back from a reboot,"
		echo "which is the manual SSH step this mechanism exists to delete"
		return 1
	}
}

@test "DURABLE the unit is enabled on BOTH the changed and unchanged branches" {
	# Enabling only when the body changed leaves an already-correct unit
	# installed and disabled — healthy today, gone after the next reboot.
	#
	# Both assertions name ${PF_UNIT} explicitly. A bare count of `systemctl
	# enable` across the driver would be an assertion about the wrong thing:
	# there are four such calls and two of them belong to the SERVE unit, so
	# the count stays green with both of the port-forward's enables deleted.
	grep -q 'systemctl enable --now ${PF_UNIT}' "${DRIVER_SRC}" || {
		echo "the changed branch no longer enables ${PF_UNIT} — a freshly written"
		echo "unit would run now and be gone after the next reboot"
		return 1
	}
	grep -q 'systemctl enable ${PF_UNIT}' "${DRIVER_SRC}" || {
		echo "the unchanged branch no longer enables ${PF_UNIT} — a unit whose body"
		echo "is already correct would be left installed and not linked into a target"
		return 1
	}
}

@test "DURABLE the unit carries a KUBECONFIG, because systemd has no login shell" {
	# A unit with no KUBECONFIG runs with HOME=/root, finds nothing, and fails
	# authenticating to localhost:6443 — which reads as a broken cluster.
	grep -q 'Environment=KUBECONFIG=' "${DRIVER_SRC}" || {
		echo "the unit has no KUBECONFIG; under systemd it would fail to reach the"
		echo "apiserver and the symptom would name the cluster, not the variable"
		return 1
	}
}

# ─── Positive controls ──────────────────────────────────────────────────────
#
# Every assertion above is proved able to go RED by mutating the driver copy.
# A guard nobody has watched fail is a guard nobody knows is connected.

@test "MUTATION removing the publish call from the deploy lane goes RED" {
	mutate 's/^  ensure_tailnet_target_durable$/  : # publish removed/'
	write_lane_harness 0
	run_lane_harness

	! grep -q '^ensure_published:' "${CALL_LOG}" || {
		echo "the publish call was removed and run_lane still published — the"
		echo "deploy-lane test is not connected to the code it claims to test"
		return 1
	}
}

@test "MUTATION making the publish fatal turns a passing lane red, and is caught" {
	# Proves the non-fatal test is load-bearing rather than passing by default.
	mutate 's/^  ensure_tailnet_target_durable$/  ensure_published "$APP_PORT" || exit 9/'
	write_lane_harness 8
	run_lane_harness

	[ "$status" -eq 9 ] || {
		echo "a deliberately fatal publish did NOT change the exit status, so the"
		echo "non-fatal assertion above would pass no matter what. status=${status}"
		return 1
	}
}

@test "MUTATION dropping Restart=always is caught" {
	mutate 's/^Restart=always$/Restart=on-failure/'
	! grep -qx 'Restart=always' "${driver}" || {
		echo "the mutation did not remove Restart=always; the guard is untested"
		return 1
	}
	# And the substring form would NOT have caught it — this is the record of
	# why the guard above matches whole lines. Three comments still say the
	# words with the directive gone.
	grep -q 'Restart=always' "${driver}" || {
		echo "expected the explanatory comments to survive the mutation; if they did"
		echo "not, the whole-line guard above is no longer proving anything extra"
		return 1
	}
}

@test "MUTATION dropping WantedBy=multi-user.target is caught" {
	mutate 's/^WantedBy=multi-user.target$/WantedBy=/'
	! grep -qx 'WantedBy=multi-user.target' "${driver}" || {
		echo "the mutation did not remove the install target; the guard is untested"
		return 1
	}
}

@test "MUTATION dropping the unit's KUBECONFIG is caught" {
	mutate 's/^Environment=KUBECONFIG=/Environment=NOKUBECONFIG=/'
	! grep -q 'Environment=KUBECONFIG=' "${driver}" || {
		echo "the mutation did not remove the KUBECONFIG; the guard is untested"
		return 1
	}
}

@test "MUTATION turning the forward into something else is caught" {
	mutate 's/ port-forward --namespace/ proxy --namespace/'
	! grep -q 'ExecStart=.*port-forward' "${driver}" || {
		echo "the mutation did not change the ExecStart; the guard is untested"
		return 1
	}
}

@test "MUTATION dropping either enable of the port-forward unit is caught" {
	# Each branch is proved separately. Deleting only one is the realistic
	# regression — and the one a global count of `systemctl enable` misses.
	mutate 's/sudo systemctl enable --now ${PF_UNIT}/sudo true --now ${PF_UNIT}/'
	! grep -q 'systemctl enable --now ${PF_UNIT}' "${driver}" || {
		echo "the mutation did not remove the changed-branch enable; the guard is untested"
		return 1
	}
	# The unchanged branch's enable is still there, so a guard that only
	# counted occurrences would still be green at this point.
	grep -q 'systemctl enable ${PF_UNIT}' "${driver}" || {
		echo "expected the unchanged-branch enable to survive; if it did not, the"
		echo "two assertions in the guard above are not independent"
		return 1
	}
}
