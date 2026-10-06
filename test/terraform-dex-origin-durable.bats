#!/usr/bin/env bats
#
# The tailnet Dex origin must not be left RELEASED by a run that aborts.
#
# ═══ The gap ════════════════════════════════════════════════════════════════
#
# scripts/gcp-tf/demo-up.sh releases this lane's own tailnet origin BEFORE
# run_pipeline, on purpose, so the 29-stage browser suite runs at the resting
# origin. It re-claims AFTER the verdict is filed. Between those two points sit
# the whole pipeline and the whole of report collection — tens of minutes during
# which the lane's tailnet login is deliberately broken.
#
# Nothing closed that window on an abnormal exit. `ensure_vm_ready || exit 2`, a
# set -e death in the pipeline, Ctrl-C (on_int -> 130) or a SIGTERM from a
# lane's idle-suspend timer (on_term -> 143) all jump straight to run_exit_trap,
# which files ABORTED and exits with the origin still released. The first
# symptom is a human hitting `Unregistered redirect_uri`. That is how this was
# found, twice, by the principal.
#
# ═══ What must stay true ════════════════════════════════════════════════════
#
# The fix must NOT re-claim on the normal path — the release is deliberate and
# the browser stage depends on it — and must NOT apply twice, because
# dex_origin_apply restarts Dex unconditionally and Dex runs `storage: type:
# memory`, so a second apply logs every user out. § NO-LOOP is that property.
#
# Offline: no cluster, no gcloud, no SSH. dex_origin() is stubbed at the REMOTE
# boundary so release_own_tailnet_origin, ensure_tailnet_origin_claimed and
# reclaim_tailnet_origin_on_abort all run their REAL bodies. Only the wire is
# fake.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export DRIVER="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
}

setup() {
	# Presence AND shape. A suite whose subject moved must fail loudly rather
	# than silently testing an empty file.
	[ -f "${DRIVER}" ]
	grep -q '^reclaim_tailnet_origin_on_abort()' "${DRIVER}" || {
		echo "the function under test is not in this tree — every test below would be vacuous"
		return 1
	}

	WORK="${BATS_TEST_TMPDIR}/w"
	mkdir -p "${WORK}/scripts/gcp-tf" "${WORK}/scripts/lib"

	# The driver copy under test. Mutations apply to THIS, never to the repo —
	# a mutation harness that rewrites the tree in place leaves it mutated when
	# the run is killed, because EXIT traps survive SIGTERM but not SIGKILL.
	#
	# The PATH SHAPE matters and is not arbitrary: the driver resolves its
	# library as `<its own dir>/../lib/wait.sh`. Copying it to a flat temp dir
	# makes that source fail, the harness dies at line 118 before it reaches
	# anything under test, and every assertion below then reports an empty call
	# log — which reads as "the feature is missing" rather than "the fixture is
	# wrong". That is exactly how this suite first failed.
	driver="${WORK}/scripts/gcp-tf/demo-up.sh"
	cp "${DRIVER}" "${driver}"

	cp -a "${REPO_ROOT}/scripts/lib/." "${WORK}/scripts/lib/"
	[ -f "${WORK}/scripts/lib/wait.sh" ] || {
		echo "fixture is missing scripts/lib/wait.sh — the driver cannot source its library"
		return 1
	}

	CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
	export CALL_LOG
	: >"${CALL_LOG}"
}

# Apply a sed expression to the driver COPY, and PROVE it applied. A sed that
# matches nothing exits 0 and changes nothing, so the mutation test that follows
# would run against correct code and pass.
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

# Build a harness that sources the driver as a library and runs run_lane with
# every collaborator stubbed — EXCEPT run_exit_trap, release_own_tailnet_origin,
# ensure_tailnet_origin_claimed and reclaim_tailnet_origin_on_abort, which are
# the subject and run for real.
#
# `$1` is the body of run_pipeline, which is how each test chooses how the run
# ends: return cleanly, exit non-zero, or take a signal.
write_harness() {
	local pipeline_body="$1"
	cat >"${WORK}/harness.sh" <<-HARNESS
		#!/usr/bin/env bash
		set -uo pipefail

		sed '/^case "\${1:-up}" in/,\$d' "${driver}" >"${WORK}/scripts/gcp-tf/lib.sh"
		# shellcheck disable=SC1090
		source "${WORK}/scripts/gcp-tf/lib.sh"

		log_call() { printf '%s\n' "\$1" >>"${CALL_LOG}"; }

		capture_source_identity() { RUN_BRANCH=test; RUN_COMMIT=abc1234; RUN_STARTED_AT=now; }
		rotate_reports()        { :; }
		set_run_phase()         { RUN_PHASE="\$1"; }
		ensure_vm_ready()       { return 0; }
		deliver_code()          { :; }
		deliver_afm_image()     { :; }
		collect_reports()       { :; }
		classify_run_outcome()  { printf 'PASS'; }
		final_exit_code()       { printf '0'; }
		report_verdict()        { :; }
		write_surface_receipt() { return 0; }
		write_run_status()      { log_call "write_run_status:\$1"; return 0; }
		ensure_published()      { return 0; }
		ensure_ts_serve_unit()  { return 0; }
		assert_tailnet_cert_state() { return 0; }

		# The login gate is stubbed: whether it VERIFIES is this suite's
		# subject, not whether it is correct — that is
		# test/terraform-login-surface-gate.bats.
		assert_tailnet_login_works() { log_call "login_gate:\$1"; return 0; }

		# ─── The origin mechanism, stubbed at the REMOTE boundary ──────────
		dex_origin()           { log_call "dex_origin:\$*"; return \${STUB_DEX_RC:-0}; }
		dex_origin_available() { return \${STUB_DEX_AVAIL_RC:-0}; }
		dex_origin_field()     { printf '%s' "\${STUB_HOLDER-tailscale}"; }
		ts_fqdn_from_vm() {
			[ -n "\${STUB_FQDN:-}" ] || return 1
			printf '%s' "\${STUB_FQDN}"
		}

		warn() { printf 'WARN: %s\n' "\$*" >&2; }
		log()  { printf '==> %s\n' "\$*"; }

		run_pipeline() { log_call run_pipeline; ${pipeline_body} }

		ENV_KEY=ci-2
		PROJECT_ID=proj
		INSTANCE_NAME=vm
		ZONE=zone
		OPERATOR_SA=sa
		APP_PORT=30754
		DEX_ORIGIN_REL=scripts/lib/dex-origin.sh

		# \${VAR=default}, NOT \${VAR:=default}. The colon form treats EMPTY as
		# absent, so a test setting STUB_FQDN='' to model a VM that cannot
		# report its name would silently get the default and test the happy
		# path instead.
		: "\${STUB_FQDN=sl-ci-2.tailnet-example.ts.net}"
		PIPELINE_EXIT=0
		REPORT_DIR="${WORK}"
		SUMMARY_NAME=summary.json
		SURFACE_DIR="${WORK}"

		run_lane full
	HARNESS
	chmod +x "${WORK}/harness.sh"
}

run_harness() { run bash "${WORK}/harness.sh"; }

# `grep -c` exits 1 on zero matches, so a naive `grep -c ... || printf 0` prints
# the count AND the fallback — "0\n0", which `[ ... -eq 0 ]` then rejects as
# "integer expression expected". Assign first, default on failure, print once.
count_calls() {
	local n
	n="$(grep -c "$1" "${CALL_LOG}" 2>/dev/null)" || n=0
	printf '%s' "${n:-0}"
}
applies()  { count_calls '^dex_origin:apply'; }
restores() { count_calls '^dex_origin:restore'; }

# ─── § THE GAP — an aborted run must not leave the login broken ─────────────

@test "ABORT a run that dies after releasing the origin re-claims it on the way out" {
	# THE test. run_pipeline exits 2, exactly as `ensure_vm_ready || exit 2` or
	# a set -e death inside the pipeline would.
	write_harness 'exit 2;'
	run_harness

	[ "$(restores)" -ge 1 ] || {
		echo "the run never released the origin, so this test proves nothing about re-claiming it"
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
	grep -q '^dex_origin:apply tailscale https://sl-ci-2.tailnet-example.ts.net$' "${CALL_LOG}" || {
		echo "the run RELEASED the tailnet origin and then aborted WITHOUT re-claiming it."
		echo "the lane's tailnet login is left broken with nothing to repair it, which"
		echo "is the outage the principal found by hand. Twice."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "ABORT the re-claim SAYS the login was left broken rather than repairing silently" {
	# A repair that says nothing trains its operator to believe nothing ever
	# went wrong, and the next time it cannot repair, the silence reads the same.
	write_harness 'exit 2;'
	run_harness

	[[ "$output" == *"aborted before re-claiming"* ]] || {
		echo "the origin was re-claimed silently"; echo "$output"; return 1;
	}
}

@test "ABORT a SIGTERM mid-pipeline re-claims the origin" {
	# on_term -> exit 143 -> the EXIT trap. This is the lane-suspends-itself
	# case: a ci-* lane's 30-minute idle timer terminates the run, and until now
	# it left the login broken.
	write_harness 'kill -TERM $$; sleep 5;'
	run_harness

	grep -q '^dex_origin:apply tailscale ' "${CALL_LOG}" || {
		echo "a TERM-killed run left the tailnet origin released"
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "ABORT a re-claim that cannot resolve the VM name WARNS that the login is broken" {
	# The VM being unreachable is a very likely REASON the run aborted, so this
	# is not an exotic path. It cannot repair, and must say so in terms that
	# name the consequence rather than the mechanism.
	write_harness 'exit 2;'
	STUB_FQDN='' run_harness

	[[ "$output" == *"TAILNET LOGIN IS BROKEN"* ]] || {
		echo "could not re-claim and did not say the login is broken"
		echo "$output"; return 1;
	}
}

@test "ABORT the re-claim does not change the run's exit status" {
	# The trap captures rc first and every cleanup is non-fatal. This repo has
	# already lost a run with 8/8 green stages to a failing last command in an
	# EXIT trap replacing the status the script asked for.
	write_harness 'exit 2;'
	STUB_DEX_RC=9 run_harness

	[ "$status" -eq 2 ] || {
		echo "a failing re-claim rewrote the run's exit status to ${status}, expected 2"
		echo "$output"; return 1;
	}
}

# ─── § NO-LOOP — the restart hazard the mechanism must not have ────────────

@test "NO-LOOP a normal run applies the origin EXACTLY once" {
	# dex_origin_apply restarts Dex unconditionally on any call that reaches its
	# tail, and Dex's storage is `type: memory`, so a second apply logs every
	# in-flight user out. One apply per run, never two.
	write_harness 'PIPELINE_EXIT=0;'
	run_harness

	[ "$(applies)" -eq 1 ] || {
		echo "expected exactly 1 apply on the normal path, got $(applies)."
		echo "more than one means the EXIT trap re-claimed on top of the normal"
		echo "claim — a needless Dex restart that logs every user out."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "NO-LOOP an aborted run applies the origin EXACTLY once" {
	write_harness 'exit 2;'
	run_harness

	[ "$(applies)" -eq 1 ] || {
		echo "expected exactly 1 apply on the abort path, got $(applies)"
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "NO-LOOP the re-claim disarms itself, so it cannot fire twice" {
	# Directly: arm the flag, call the trap's re-claim twice, and count. The
	# integration tests above cannot distinguish "runs once" from "runs once
	# because nothing invoked it again".
	write_harness 'PIPELINE_EXIT=0;'
	cat >"${WORK}/twice.sh" <<-TWICE
		#!/usr/bin/env bash
		set -uo pipefail
		source "${WORK}/scripts/gcp-tf/lib.sh"
		log_call() { printf '%s\n' "\$1" >>"${CALL_LOG}"; }
		dex_origin()           { log_call "dex_origin:\$*"; return 0; }
		dex_origin_available() { return 0; }
		ts_fqdn_from_vm()      { printf '%s' 'sl-ci-2.tailnet-example.ts.net'; }
		warn() { :; }
		log()  { :; }
		ENV_KEY=ci-2; INSTANCE_NAME=vm; DEX_ORIGIN_REL=x
		TAILNET_ORIGIN_RELEASED=1
		reclaim_tailnet_origin_on_abort
		reclaim_tailnet_origin_on_abort
		reclaim_tailnet_origin_on_abort
	TWICE
	# lib.sh is produced by the harness run above.
	run_harness
	: >"${CALL_LOG}"
	run bash "${WORK}/twice.sh"

	# The status IS examined, and not as ceremony: if the script died on its
	# first invocation the call log would hold exactly one apply and this test
	# would pass for entirely the wrong reason — "runs once" is indistinguishable
	# from "crashed after one" unless the exit is checked.
	[ "$status" -eq 0 ] || {
		echo "the triple-invocation script exited ${status}; a single apply below"
		echo "would then prove nothing about disarming."
		echo "$output"; return 1;
	}

	[ "$(applies)" -eq 1 ] || {
		echo "three invocations produced $(applies) applies — the flag does not disarm,"
		echo "so any caller that retried would restart Dex on every attempt."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

# ─── § THE LEASE — a re-claim must never steal another method's origin ─────

@test "LEASE a run that never released the origin does not claim one on abort" {
	# The holder is ngrok or funnel, so release_own_tailnet_origin correctly
	# declines to release. Nothing was taken out, so nothing may be put back —
	# re-claiming here would take the issuer from a live public demo.
	write_harness 'exit 2;'
	STUB_HOLDER=ngrok run_harness

	[ "$(restores)" -eq 0 ] || {
		echo "the run released an origin held by ngrok"; return 1;
	}
	[ "$(applies)" -eq 0 ] || {
		echo "an aborted run CLAIMED the tailnet origin having never released one."
		echo "that steals the issuer from whichever access method holds it — the"
		echo "exact collision the lease mechanism exists to prevent."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "LEASE the re-claim is skipped when the origin mechanism is not in the checkout" {
	write_harness 'exit 2;'
	STUB_DEX_AVAIL_RC=1 run_harness

	[ "$(applies)" -eq 0 ] || {
		echo "re-claimed via a mechanism this checkout does not have"; return 1;
	}
}

@test "LEASE GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 suppresses the re-claim" {
	# The documented escape hatch. An operator who has said "do not touch my
	# issuer" must not have it touched from an EXIT trap, which is the least
	# expected place for it to happen.
	write_harness 'exit 2;'
	GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 run_harness

	[ "$(applies)" -eq 0 ] || {
		echo "the skip flag was ignored by the abort path"; return 1;
	}
}

# ─── § VERIFY — the claim is proven, not assumed ───────────────────────────

@test "VERIFY a normal run drives the login gate against the claimed origin" {
	# `dex_origin apply` returning 0 means a ConfigMap was patched. It does not
	# mean a browser can sign in — which is precisely the difference that let
	# two outages through every green check this lane owned.
	write_harness 'PIPELINE_EXIT=0;'
	run_harness

	grep -q '^login_gate:https://sl-ci-2.tailnet-example.ts.net$' "${CALL_LOG}" || {
		echo "the lane claimed the origin and never verified a human could sign in."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "VERIFY the login gate runs AFTER the claim, not before it" {
	# Verifying before claiming would assert against the resting origin and
	# report a failure that the very next line fixes.
	write_harness 'PIPELINE_EXIT=0;'
	run_harness

	local apply_line gate_line
	apply_line="$(grep -n '^dex_origin:apply' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	gate_line="$(grep -n '^login_gate:' "${CALL_LOG}" | head -1 | cut -d: -f1)"
	[ -n "$apply_line" ] && [ -n "$gate_line" ] || {
		echo "expected both an apply and a gate call"; echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
	[ "$gate_line" -gt "$apply_line" ] || {
		echo "the login gate ran at line ${gate_line}, before the claim at ${apply_line}"
		return 1;
	}
}

# ─── § STRICTNESS — the same check, two different consequences ────────────
#
# Post-deploy the verdict is already filed, so a failed login check must WARN.
# On ts-up and funnel-up nothing has been reported yet and the only output is a
# URL for a human to click, so a failed check must REFUSE TO PRINT IT.

# Run assert_tailnet_login_works directly against a stub gate.
# $1 = the gate's exit status, $2 = the fatal flag, or 'missing' for no gate.
run_login_assert() {
	local gate_rc="$1" fatal="$2"
	mkdir -p "${WORK}/repo/scripts/ci"
	if [ "$gate_rc" != "missing" ]; then
		cat >"${WORK}/repo/scripts/ci/login-surface-gate.sh" <<-GATE
			#!/usr/bin/env bash
			echo "STUB GATE RAN: \$*"
			exit ${gate_rc}
		GATE
		chmod +x "${WORK}/repo/scripts/ci/login-surface-gate.sh"
	fi

	cat >"${WORK}/strict.sh" <<-STRICT
		#!/usr/bin/env bash
		set -uo pipefail
		sed '/^case "\${1:-up}" in/,\$d' "${driver}" >"${WORK}/scripts/gcp-tf/lib.sh"
		# shellcheck disable=SC1090
		source "${WORK}/scripts/gcp-tf/lib.sh"
		warn() { printf 'WARN: %s\n' "\$*" >&2; }
		log()  { :; }
		REPO_ROOT="${WORK}/repo"
		ENV_KEY=ci-2
		assert_tailnet_login_works "https://sl-ci-2.example.ts.net" "${fatal}"
		echo "RETURNED-NORMALLY"
	STRICT
	run bash "${WORK}/strict.sh"
}

@test "STRICT a passing gate returns cleanly in both modes" {
	run_login_assert 0 0
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"RETURNED-NORMALLY"* ]] || { echo "$output"; return 1; }

	run_login_assert 0 1
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "STRICT a failing gate WARNS and continues when non-fatal" {
	run_login_assert 1 0
	[[ "$output" == *"RETURNED-NORMALLY"* ]] || {
		echo "a non-fatal login failure stopped the caller — this runs after the"
		echo "verdict is filed and must not turn a green lane red"
		echo "$output"; return 1;
	}
	[[ "$output" == *"WARN:"* ]] || {
		echo "the login check failed and said NOTHING"; echo "$output"; return 1;
	}
}

@test "STRICT a failing gate STOPS the caller when fatal" {
	run_login_assert 1 1
	[[ "$output" != *"RETURNED-NORMALLY"* ]] || {
		echo "a fatal login failure did not stop the caller, so ts-up would go on"
		echo "to print a URL whose login bounces — the exact thing it promises not"
		echo "to do."
		echo "$output"; return 1;
	}
	[ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "STRICT an ABSENT gate warns rather than blocking the publish, even when fatal" {
	# The gate missing is this checkout's problem, not the lane's. Refusing to
	# publish a working demo because a verification script is absent would make
	# an older checkout unable to run at all.
	run_login_assert missing 1
	[[ "$output" == *"RETURNED-NORMALLY"* ]] || {
		echo "an absent gate blocked the publish"; echo "$output"; return 1;
	}
	[[ "$output" == *"NOTHING verified"* ]] || {
		echo "an absent gate was passed over silently, which reads as a successful"
		echo "verification that never happened"
		echo "$output"; return 1;
	}
}

@test "STRICT the gate is actually invoked with the origin under test" {
	run_login_assert 0 1
	[[ "$output" == *"STUB GATE RAN: --base-url https://sl-ci-2.example.ts.net"* ]] || {
		echo "the gate was not invoked, or not against the origin being published"
		echo "$output"; return 1;
	}
}

# ─── § WIRING — the publish paths must ask, and ask fatally ────────────────

@test "WIRING ts-up verifies the login before printing a URL" {
	local ts_body
	ts_body="$(sed -n '/^cmd_ts_up()/,/^}/p' "${driver}")"
	[[ "$ts_body" == *"assert_tailnet_login_works \"\$base\" 1"* ]] || {
		echo "cmd_ts_up does not verify the login fatally. It prints 'verified"
		echo "before you clicked' over a health probe that was 200 throughout both"
		echo "outages."
		return 1;
	}
}

@test "WIRING funnel-up verifies the login, and not behind the skip flag" {
	# A bouncing login on a tailnet URL is an inconvenience; on a URL the whole
	# internet can reach it is a broken thing published under this estate's
	# name. funnel-up already refuses to honour the skip flag for
	# require_dex_origin_mechanism; this must match.
	local fn_body
	fn_body="$(sed -n '/^cmd_funnel_up()/,/^}/p' "${driver}")"
	[[ "$fn_body" == *"assert_tailnet_login_works \"\$base\" 1"* ]] || {
		echo "cmd_funnel_up publishes to the public internet without verifying"
		echo "that anyone can sign in."
		return 1;
	}
	[[ "$fn_body" != *"GCP_TF_DEMO_SKIP_DEX_ORIGIN"* ]] || {
		echo "funnel-up gained a skip flag around the origin mechanism, which it"
		echo "deliberately does not honour."
		return 1;
	}
}

# ─── § MUTATION — every RED below was WATCHED ──────────────────────────────

@test "MUTATION removing the trap re-claim reopens the gap" {
	# WATCHED: with the call deleted from run_exit_trap, the aborted run leaves
	# the origin released — which is the pre-fix behaviour, restored exactly.
	# `%` as the delimiter, not `|`: the line being matched CONTAINS `||`, which
	# ends a `s|...|` expression early and makes sed report "unknown option".
	mutate 's%^  reclaim_tailnet_origin_on_abort || true$%  : # re-claim removed%'
	write_harness 'exit 2;'
	run_harness

	[ "$(applies)" -eq 0 ] || {
		echo "the origin was re-claimed with the trap call deleted, so something"
		echo "other than the trap is doing it and the test above proves less than"
		echo "it claims."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "MUTATION never arming the flag makes the re-claim dead code" {
	# WATCHED: the guard is `[ "${TAILNET_ORIGIN_RELEASED:-0}" = "1" ]`. Never
	# setting it to 1 means the re-claim returns immediately, every time.
	mutate 's|^    TAILNET_ORIGIN_RELEASED=1$|    TAILNET_ORIGIN_RELEASED=0|'
	write_harness 'exit 2;'
	run_harness

	[ "$(applies)" -eq 0 ] || {
		echo "the re-claim fired without the release ever arming it — the flag is"
		echo "not what gates it, so the LEASE tests above are not proving what"
		echo "they say."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "MUTATION not disarming on the normal path causes a SECOND apply" {
	# WATCHED, and this is the restart-loop hazard made concrete. Delete the
	# disarm from ensure_tailnet_origin_claimed and the normal path applies
	# twice — one needless Dex restart, and because storage is `type: memory`,
	# every in-flight login dropped.
	mutate 's|^  TAILNET_ORIGIN_RELEASED=0$|  : # disarm removed|'
	write_harness 'PIPELINE_EXIT=0;'
	run_harness

	[ "$(applies)" -ge 2 ] || {
		echo "expected a double apply with the disarm removed, got $(applies)."
		echo "if one apply survives this mutation then the disarm is not what"
		echo "prevents the second one, and the NO-LOOP test proves nothing."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "MUTATION removing the holder check lets an aborted run steal ngrok's origin" {
	# WATCHED: release_own_tailnet_origin's anchored holder test is the only
	# thing keeping a deploy from taking a public demo's issuer.
	# `true ||` rather than a self-comparison: same effect (the early return can
	# never fire) without writing a literal tautology, which VAC004 flags and
	# cannot distinguish from a real assertion.
	mutate 's%^  \[ "\$method" = "tailscale" \] || return 0$%  true || return 0%'
	write_harness 'exit 2;'
	STUB_HOLDER=ngrok run_harness

	[ "$(applies)" -ge 1 ] || {
		echo "expected the mutated driver to steal the origin, got $(applies) applies."
		echo "if it still declines, the holder check is not what protects ngrok and"
		echo "the LEASE test above is vacuous."
		echo "calls: $(tr '\n' ' ' <"${CALL_LOG}")"; return 1;
	}
}

@test "MUTATION dropping ts-up's fatal flag lets it print a URL with a broken login" {
	# WATCHED. The `1` is the entire difference between refusing to publish and
	# publishing something that does not work.
	mutate 's%^    assert_tailnet_login_works "\$base" 1$%    assert_tailnet_login_works "$base" 0%'
	run_login_assert 1 0

	[[ "$output" == *"RETURNED-NORMALLY"* ]] || {
		echo "with the fatal flag dropped the caller must CONTINUE past a broken"
		echo "login — if it still stops, the flag is not what makes ts-up refuse"
		echo "and the WIRING test proves nothing."
		echo "$output"; return 1;
	}
}
