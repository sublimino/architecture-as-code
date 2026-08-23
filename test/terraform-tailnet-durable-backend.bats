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

		# ─── The origin mechanism, stubbed at the REMOTE boundary ──────────
		#
		# dex_origin() shells out to the delivered copy over SSH. Left real,
		# every test in this file would attempt a gcloud IAP connection to a VM
		# that does not exist, and the suite would be measuring the timeout.
		#
		# Stubbed HERE rather than by exporting GCP_TF_DEMO_DEX_ORIGIN_CMD so
		# that dex_origin_available(), release_own_tailnet_origin() and
		# ensure_tailnet_origin_claimed() all run their REAL bodies — those are
		# the subject. Only the wire is fake.
		dex_origin()       { log_call "dex_origin:\$*"; return \${STUB_DEX_ORIGIN_RC:-0}; }
		dex_origin_field() { printf '%s' "\${STUB_HOLDER:-}"; }
		ts_fqdn_from_vm() {
			[ -n "\${STUB_FQDN:-}" ] || return 1
			printf '%s' "\${STUB_FQDN}"
		}

		warn() { printf 'WARN: %s\n' "\$*" >&2; }
		log()  { printf '==> %s\n' "\$*"; }

		ENV_KEY=ci-2
		PROJECT_ID=proj
		INSTANCE_NAME=vm
		ZONE=zone
		OPERATOR_SA=sa
		APP_PORT=30754

		# Defaults, so the happy path is the happy path. Each is overridable
		# from the test via the environment, which is how the RED cases below
		# steer the branch under test.
		#
		# `\${VAR=default}` and NOT `\${VAR:=default}`. The colon form treats
		# EMPTY as absent, so \`STUB_FQDN='' run_lane_harness\` — the case that
		# tests a VM which cannot report its name — would silently be handed the
		# default and test the happy path instead. Caught by that test failing.
		: "\${STUB_FQDN=sl-ci-2.tailnet-example.ts.net}"
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

# ─── The other half of a working tailnet URL: the ORIGIN ────────────────────
#
# A durable backend makes the URL answer. It does not make it usable.
#
# Reproduced on sl-demo-1 on 2026-08-23, with the backend healthy and `/`
# answering 200:
#
#     /dex/auth?...redirect_uri=https://sl-demo-1.<tailnet>.ts.net/callback
#       -> 302 -> /dex/auth/local -> 400
#          Unregistered redirect_uri ("https://sl-demo-1.<tailnet>.ts.net/callback")
#
# So the assertions below deliberately do NOT test that anything returns 200.
# A 200 on `/` is exactly what the broken state produced, and a suite that
# accepted it would have certified this bug.

@test "ORIGIN the deploy lane claims the tailnet origin, not just the backend" {
	write_lane_harness 0
	run_lane_harness

	grep -q '^dex_origin:apply tailscale https://' "${CALL_LOG}" || {
		echo "run_lane installed the backend and never told Dex the tailnet origin is"
		echo "legitimate. The URL would answer 200 and the login would bounce with"
		echo "'Unregistered redirect_uri' — which is what a 200 does not prove."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "ORIGIN the claimed origin is the name the VM reports, as https, with no trailing dot" {
	# `.Self.DNSName` is fully qualified and ends in a dot. An origin carrying
	# that dot is refused by dex_origin_validate, so the whole claim would fail
	# at the door — and the lane would warn about the wrong thing.
	STUB_FQDN='sl-ci-2.tailnet-example.ts.net' write_lane_harness 0
	STUB_FQDN='sl-ci-2.tailnet-example.ts.net' run_lane_harness

	grep -qx 'dex_origin:apply tailscale https://sl-ci-2.tailnet-example.ts.net' "${CALL_LOG}" || {
		echo "the claimed origin is not exactly https://<the name the VM reported>."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "ORIGIN the method is 'tailscale', the same name ts-up takes" {
	# Not cosmetic. The method is what a refusal quotes back at the next access
	# path, so a lane claiming under any other name would make
	# 'make gcp-tf-ts-up' refuse itself and name a holder no teardown documents.
	write_lane_harness 0
	run_lane_harness

	grep -q '^dex_origin:apply tailscale ' "${CALL_LOG}" || {
		echo "the deploy lane claims under a method name that is not 'tailscale'."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
	grep -q 'dex_origin apply tailscale' "${DRIVER_SRC}" || {
		echo "the driver no longer applies under 'tailscale' anywhere"
		return 1
	}
}

@test "ORIGIN a backend that could not be installed does NOT get an origin claimed" {
	# Publishing an origin for a URL with nothing behind it converts a 502 into
	# a 502 that has also taken the lease, so the next access method is refused
	# and named a holder that serves nothing.
	write_lane_harness 8
	run_lane_harness

	! grep -q '^dex_origin:apply' "${CALL_LOG}" || {
		echo "the backend failed to install and the lane claimed the origin anyway,"
		echo "taking the lease on behalf of a URL that answers 502."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "ORIGIN claiming the origin cannot turn a passing lane red" {
	# Same reasoning as the backend: the verdict is already decided and filed.
	STUB_DEX_ORIGIN_RC=1 write_lane_harness 0
	STUB_DEX_ORIGIN_RC=1 run_lane_harness

	[ "$status" -eq 0 ] || {
		echo "a failed origin claim changed the run's exit status to ${status}"
		echo "output: ${output}"
		return 1
	}
}

@test "ORIGIN an origin that could not be claimed WARNS, naming the bouncing login" {
	# The half that matters. A silent failure here is a lane reporting PASS over
	# a URL that loads and cannot be logged into.
	STUB_DEX_ORIGIN_RC=1 write_lane_harness 0
	STUB_DEX_ORIGIN_RC=1 run_lane_harness

	[[ "$output" == *"WARN:"* ]] || {
		echo "the origin claim failed and the lane said NOTHING. output: ${output}"
		return 1
	}
	[[ "$output" == *"BOUNCE"* || "$output" == *"bounce"* ]] || {
		echo "the warning does not say the login will bounce, so a reader cannot tell"
		echo "this from a cosmetic failure. output: ${output}"
		return 1
	}
}

@test "ORIGIN a VM that cannot report its tailnet name WARNS and publishes nothing" {
	# ts_fqdn_from_vm returning empty must not become the origin 'https://'.
	STUB_FQDN='' write_lane_harness 0
	STUB_FQDN='' run_lane_harness

	! grep -q '^dex_origin:apply' "${CALL_LOG}" || {
		echo "the name could not be read and an origin was published anyway."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
	[[ "$output" == *"WARN:"* ]] || {
		echo "the name could not be read and the lane said nothing. output: ${output}"
		return 1
	}
}

@test "ORIGIN GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 skips the claim and says the login will bounce" {
	GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 write_lane_harness 0
	GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 run_lane_harness

	! grep -q '^dex_origin:apply' "${CALL_LOG}" || {
		echo "the skip knob was set and the origin was claimed anyway."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
	[[ "$output" == *"BOUNCE"* ]] || {
		echo "the skip path does not warn that the login will bounce, which is the"
		echo "one thing that makes the knob safe to use. output: ${output}"
		return 1
	}
}

# ─── Not breaking the path every test uses ──────────────────────────────────
#
# Claiming REPLACES: PUBLIC_ORIGIN is one value, because the SPA validates the
# ID token's `iss` against the origin it was served from (oidc.tsx). The
# estate's browser journey drives the RESTING origin, so a lane still holding
# the tailnet origin would fail that stage on an issuer mismatch and blame the
# dashboard. These assert the two things that keep them apart.

@test "ORDER the pipeline runs BEFORE the origin moves" {
	write_lane_harness 0
	run_lane_harness

	local pipeline_line claim_line
	pipeline_line="$(grep -n '^run_pipeline$' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	claim_line="$(grep -n '^dex_origin:apply' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	[ -n "$pipeline_line" ] && [ -n "$claim_line" ] || {
		echo "expected both a pipeline run and an origin claim in the log."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
	[ "$pipeline_line" -lt "$claim_line" ] || {
		echo "the origin moved BEFORE the pipeline ran. The browser stage drives the"
		echo "resting origin, so it would fail on an issuer mismatch and name the"
		echo "dashboard rather than the origin."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "RELEASE a lane holding its OWN tailnet origin releases it before the pipeline" {
	STUB_HOLDER=tailscale write_lane_harness 0
	STUB_HOLDER=tailscale run_lane_harness

	local restore_line pipeline_line
	restore_line="$(grep -n '^dex_origin:restore$' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	pipeline_line="$(grep -n '^run_pipeline$' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	[ -n "$restore_line" ] || {
		echo "a lane already holding the tailnet origin did not release it, so the"
		echo "browser stage would run against a Dex issuing for a different origin."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
	[ "$restore_line" -lt "$pipeline_line" ] || {
		echo "the release happened AFTER the pipeline, which is too late to help it."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "RELEASE a FUNNEL lease is never released by a deploy" {
	# funnel publishes the IDENTICAL URL, so a substring or prefix match on the
	# holder would release it. It is a deliberate PUBLIC listener with its own
	# teardown, and a deploy is not consent to end it.
	STUB_HOLDER=funnel write_lane_harness 0
	STUB_HOLDER=funnel run_lane_harness

	! grep -q '^dex_origin:restore$' "${CALL_LOG}" || {
		echo "a deploy released a FUNNEL lease. That is a public URL whose login this"
		echo "just broke, with nothing in the output saying so."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "RELEASE another method's lease is never released by a deploy" {
	for holder in ngrok iap tailscale-funnel xtailscale; do
		STUB_HOLDER="$holder" write_lane_harness 0
		: >"${CALL_LOG}"
		STUB_HOLDER="$holder" run_lane_harness

		! grep -q '^dex_origin:restore$' "${CALL_LOG}" || {
			echo "a deploy released a lease held by '${holder}'. Only this lane's own"
			echo "'tailscale' lease may be released; the holder match must be exact."
			echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
			return 1
		}
	done
}

@test "RELEASE an unheld origin is not restored, so an idle cluster is left alone" {
	# dex_origin_current falls back to the resting origin, so "non-empty means
	# somebody holds it" is wrong — that exact mistake made every ts-up on an
	# idle cluster refuse itself. The holder KEY is the only question.
	STUB_HOLDER='' write_lane_harness 0
	STUB_HOLDER='' run_lane_harness

	! grep -q '^dex_origin:restore$' "${CALL_LOG}" || {
		echo "a deploy restored an origin nobody was holding, restarting Dex — which"
		echo "runs storage: type: memory — and logging out every in-flight session."
		echo "calls made: $(tr '\n' ' ' <"${CALL_LOG}")"
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

@test "MUTATION removing the origin claim from the deploy lane goes RED" {
	mutate 's/^    ensure_tailnet_origin_claimed$/    : # claim removed/'
	write_lane_harness 0
	run_lane_harness

	! grep -q '^dex_origin:apply' "${CALL_LOG}" || {
		echo "the claim call was removed and the lane still claimed an origin — the"
		echo "ORIGIN tests are not connected to the code they claim to test"
		return 1
	}
}

@test "MUTATION removing the release from the deploy lane goes RED" {
	mutate 's/^  release_own_tailnet_origin$/  : # release removed/'
	STUB_HOLDER=tailscale write_lane_harness 0
	STUB_HOLDER=tailscale run_lane_harness

	! grep -q '^dex_origin:restore$' "${CALL_LOG}" || {
		echo "the release call was removed and the lane still restored — the RELEASE"
		echo "tests are not connected to the code they claim to test"
		return 1
	}
}

@test "MUTATION RENAMING the claimed method away from 'tailscale' is caught" {
	# The rename case specifically. A guard that matched the method name as a
	# SUBSTRING of some longer string would stay green through this, and the
	# lane would take its lease under a name no teardown documents.
	mutate 's/dex_origin apply tailscale "\$base"/dex_origin apply tailnet "$base"/'
	write_lane_harness 0
	run_lane_harness

	! grep -q '^dex_origin:apply tailscale ' "${CALL_LOG}" || {
		echo "the method was renamed and the assertion did not notice; it is matching"
		echo "something other than the method actually applied"
		return 1
	}
}

@test "MUTATION relaxing the holder match to a substring is caught" {
	# The specific way this goes wrong: `case`/`==` with a glob, or a grep,
	# instead of an exact compare. Any of them release a FUNNEL lease.
	mutate 's/\[ "\$method" = "tailscale" \] || return 0/[[ "$method" == *tailscale* ]] || return 0/'
	STUB_HOLDER=funnel write_lane_harness 0
	STUB_HOLDER=funnel run_lane_harness

	# funnel does not contain "tailscale", so prove the mutation with a holder
	# that DOES — otherwise this control would pass without the guard moving.
	: >"${CALL_LOG}"
	STUB_HOLDER=tailscale-funnel run_lane_harness
	grep -q '^dex_origin:restore$' "${CALL_LOG}" || {
		echo "the mutation did not loosen the match, so the exactness assertion above"
		echo "is not proving anything"
		return 1
	}
}

@test "MUTATION moving the origin claim ahead of the pipeline is caught" {
	# Proves the ORDER assertion is load-bearing rather than true by accident.
	mutate 's/^  release_own_tailnet_origin$/  ensure_tailnet_origin_claimed/'
	write_lane_harness 0
	run_lane_harness

	local pipeline_line claim_line
	pipeline_line="$(grep -n '^run_pipeline$' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	claim_line="$(grep -n '^dex_origin:apply' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	[ -n "$claim_line" ] && [ "$claim_line" -lt "$pipeline_line" ] || {
		echo "the mutation did not move a claim ahead of the pipeline, so the ORDER"
		echo "assertion is untested. calls: $(tr '\n' ' ' <"${CALL_LOG}")"
		return 1
	}
}

@test "MUTATION dropping the trailing-dot strip from the VM name is caught" {
	# The dot is what dex_origin_validate refuses. Proves the strip is real code
	# and not an accident of the stub.
	grep -q 'out="\${out%\.}"' "${DRIVER_SRC}" || {
		echo "ts_fqdn_from_vm no longer strips the trailing dot from .Self.DNSName;"
		echo "the origin would be refused as malformed at the door"
		return 1
	}
	mutate 's/  out="\${out%\.}"/  : # strip removed/'
	! grep -q 'out="\${out%\.}"' "${driver}" || {
		echo "the mutation did not remove the strip; the guard is untested"
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
