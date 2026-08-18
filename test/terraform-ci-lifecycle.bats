#!/usr/bin/env bats
#
# Fake-client tests for the CI lane lifecycle and the reaper.
#
# A stub `gcloud` and stub test runners go on PATH, so both scripts execute
# their REAL control flow — resume, lock, ssh, suspend, trap, gate — with no
# cloud access, no credentials and no network. Every stub invocation is logged
# with the SSH_AUTH_SOCK the caller actually exported, which is what turns the
# ssh-agent guard from a grep into a behavioural assertion.
#
# The regression these tests exist for is the trap. Under `set -e` a failing
# final command in an EXIT trap replaces the status the script asked for; this
# repo has already lost a run with 8/8 green stages to exactly that. So it is
# not enough to assert pass exits 0 and fail exits non-zero. The test that
# matters is: make the trap's own cleanup FAIL, and assert a passing run still
# exits 0.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$repo/scripts/ci/gcp-tf-ci.sh"
	reaper="$repo/scripts/ci/gcp-tf-reaper.sh"
	fixtures="$repo/test/fixtures/gcp-tf-ci"

	# Presence before behaviour: a test that drives a script that was never
	# written reports whatever the shell does with a missing file.
	[ -f "$script" ]
	[ -f "$reaper" ]
	[ -d "$fixtures" ]

	stubdir="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$stubdir" "$BATS_TEST_TMPDIR/locks"
	cp "$fixtures/stub-gcloud" "$stubdir/gcloud"
	cp "$fixtures/stub-tests-pass" "$fixtures/stub-tests-fail" "$fixtures/stub-tests-hang" "$stubdir/"
	chmod +x "$stubdir"/*
	PATH="$stubdir:$PATH"
	export PATH

	log="$BATS_TEST_TMPDIR/gcloud.log"
	: >"$log"

	export STUB_GCLOUD_LOG="$log"
	export STUB_VM_STATE=SUSPENDED
	export STUB_TEST_CMD="$stubdir/stub-tests-pass"

	export GCP_TF_CI_KEY=ci-1
	export GCP_TF_CI_PROJECT=CHANGEME-project
	export GCP_TF_CI_ZONE=europe-west2-a
	export GCP_TF_CI_LOCK_HOME="$BATS_TEST_TMPDIR/locks"
	export GCP_TF_CI_SSH_WAIT_ATTEMPTS=2
	export GCP_TF_CI_SSH_WAIT_INTERVAL=0
	export GCP_TF_CI_LOCK_HOLDER="agent-a@host"
	export GCP_TF_CI_LOCK_TOKEN="agent-a@host:111"
}

suspend_calls() {
	grep -c 'instances suspend' "$log" || true
}

suspended_names() {
	grep -o 'instances suspend [^ ]*' "$log" | awk '{print $3}' || true
}

# ─── Static properties ──────────────────────────────────────────────────────

@test "GCPTFCI both scripts are executable and shellcheck clean" {
	[ -x "$script" ]
	[ -x "$reaper" ]
	command -v shellcheck >/dev/null || skip "shellcheck not installed"
	run shellcheck "$script" "$reaper"
	[ "$status" -eq 0 ]
}

@test "GCPTFCI the SSH_AUTH_SOCK guard is present in the source" {
	# ISC-198, ISC-199. Half the assertion; the effectiveness half is below.
	grep -q 'SSH_AUTH_SOCK' "$script"
	run grep -cE '^[[:space:]]*export SSH_AUTH_SOCK=' "$script"
	[ "$output" -ge 1 ]
}

@test "GCPTFCI the script never pgreps or pkills a pattern matching itself" {
	# The Bash tool wraps every command in `bash -c`, so the whole script text is
	# that shell's cmdline; a pattern matching it kills the caller.
	run grep -nE '\b(pgrep|pkill)\b' "$script" "$reaper"
	[ "$status" -ne 0 ]
}

@test "GCPTFCI the trap's last statement is an explicit exit of the captured status" {
	# ISC-190. The structural half of the errexit-trap regression; the
	# behavioural half is the cleanup-failure test below.
	grep -q 'local rc=\$?' "$script"
	run bash -c "sed -n '/^on_exit()/,/^}/p' '$script' | grep -c 'exit \"\$rc\"'"
	[ "$output" -eq 1 ]

	# Every cleanup call inside the trap tolerates its own failure.
	run bash -c "sed -n '/^on_exit()/,/^}/p' '$script' | grep -c 'lock_release || true'"
	[ "$output" -eq 1 ]
}

@test "GCPTFCI the reaper's idle threshold is a variable, not a literal" {
	# ISC-195. The comparison site must reference the variable.
	grep -qE '^IDLE_MINUTES=' "$reaper"
	grep -qE '\[ "\$age" -lt "\$IDLE_MINUTES" \]' "$reaper"

	# And no bare numeric threshold comparison anywhere.
	run grep -nE '\-lt[[:space:]]+[0-9]+[[:space:]]*\]' "$reaper"
	[ "$status" -ne 0 ]
}

# ─── The lane lock ──────────────────────────────────────────────────────────

@test "GCPTFCI two lanes derive different lock names" {
	# ISC-192, ISC-193. The whole point of lanes is that ci-1 and ci-2 do not
	# contend.
	GCP_TF_CI_KEY=ci-1 run bash "$script" lock-path
	[ "$status" -eq 0 ]
	local one="$output"

	GCP_TF_CI_KEY=ci-2 run bash "$script" lock-path
	[ "$status" -eq 0 ]
	local two="$output"

	[ -n "$one" ]
	[ -n "$two" ]
	[ "$one" != "$two" ]
	[[ "$one" == *ci-1* ]]
	[[ "$two" == *ci-2* ]]
}

@test "GCPTFCI a second run on the SAME lane is refused" {
	local path
	path="$(GCP_TF_CI_KEY=ci-1 bash "$script" lock-path)"
	mkdir -p "$path"
	printf 'agent-b@host|agent-b@host:222|%s\n' "$(date +%s)" >"$path/holder"

	run bash "$script" run
	[ "$status" -ne 0 ]
	[[ "$output" == *REFUSING* ]]
	[[ "$output" == *agent-b@host* ]]

	# It refused before doing anything to the VM.
	[ "$(suspend_calls)" -eq 0 ]
}

@test "GCPTFCI a run on a DIFFERENT lane is not blocked by the first lane's lock" {
	local path
	path="$(GCP_TF_CI_KEY=ci-1 bash "$script" lock-path)"
	mkdir -p "$path"
	printf 'agent-b@host|agent-b@host:222|%s\n' "$(date +%s)" >"$path/holder"

	GCP_TF_CI_KEY=ci-2 run bash "$script" run
	[ "$status" -eq 0 ]
	[ "$(suspend_calls)" -ge 1 ]
}

@test "GCPTFCI a refused lane key outside ^ci-N is rejected before any gcloud call" {
	GCP_TF_CI_KEY=demo-1 run bash "$script" run
	[ "$status" -ne 0 ]
	[[ "$output" == *"refusing to act"* ]]
	[ ! -s "$log" ]
}

# ─── The three lifecycle paths ──────────────────────────────────────────────

@test "GCPTFCI PASS path exits 0 and suspends the lane" {
	# ISC-186, ISC-188.
	export STUB_TEST_CMD="$stubdir/stub-tests-pass"
	run bash "$script" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"tests PASSED"* ]]
	[ "$(suspend_calls)" -ge 1 ]

	# It resumed first, and it suspended the lane it was asked about.
	grep -q 'instances resume sl-ci-1-runner' "$log"
	grep -q 'instances suspend sl-ci-1-runner' "$log"
}

@test "GCPTFCI FAIL path exits non-zero and STILL suspends the lane" {
	# ISC-187, ISC-188. "Leave it up so I can debug" is the intention that never
	# survives contact with a Friday evening.
	export STUB_TEST_CMD="$stubdir/stub-tests-fail"
	run bash "$script" run
	[ "$status" -eq 3 ]
	[[ "$output" == *"tests FAILED"* ]]
	[ "$(suspend_calls)" -ge 1 ]
}

@test "GCPTFCI INTERRUPT path suspends the lane (SIGTERM to the script)" {
	# ISC-189, ISC-202. The signal arrives while the remote test command is the
	# foreground child. bash defers the trap until that child returns, so the
	# hang is short by design.
	export STUB_TEST_CMD="$stubdir/stub-tests-hang"
	export STUB_HANG_SECONDS=2

	bash "$script" run >"$BATS_TEST_TMPDIR/int.out" 2>&1 &
	local pid=$!

	local waited=0
	while ! grep -q 'compute ssh' "$log" 2>/dev/null; do
		sleep 0.2
		waited=$((waited + 1))
		[ "$waited" -lt 40 ] || break
	done
	grep -q 'compute ssh' "$log"

	kill -TERM "$pid"
	local rc=0
	wait "$pid" || rc=$?

	[ "$rc" -ne 0 ]
	[ "$(suspend_calls)" -ge 1 ]
}

@test "GCPTFCI INTERRUPT path suspends the lane (SIGINT to the process group)" {
	# The realistic Ctrl-C: the terminal signals the whole foreground process
	# group, so the remote command dies at once and the trap runs immediately.
	#
	# The run MUST be in the foreground here. bash sets SIGINT to SIG_IGN in
	# asynchronous children, and that disposition is inherited and cannot be
	# reset by a non-interactive shell — so `setsid ... &` produces a tree that
	# ignores SIGINT entirely. An earlier draft of this test did exactly that,
	# went green, and was measuring a run that completed normally after its
	# sleep expired. `setsid --wait` in the foreground with the killer in the
	# background is what actually delivers the signal, and it keeps bats itself
	# out of the blast radius by giving the run its own process group.
	command -v setsid >/dev/null || skip "setsid not available"
	setsid --help 2>&1 | grep -q -- '--wait' || skip "setsid lacks --wait"

	export STUB_TEST_CMD="$stubdir/stub-tests-hang"
	export STUB_HANG_SECONDS=25

	local pidfile="$BATS_TEST_TMPDIR/pgid"
	(
		local i
		for i in $(seq 1 60); do
			[ -s "$pidfile" ] && grep -q 'compute ssh' "$log" 2>/dev/null && break
			sleep 0.2
		done
		sleep 0.3
		[ -s "$pidfile" ] && kill -INT -- "-$(cat "$pidfile")"
	) &
	local killer=$!

	run setsid --wait bash -c 'echo $$ >"$1"; exec bash "$2" run' _ "$pidfile" "$script"
	wait "$killer" 2>/dev/null || true

	# 130 is SIGINT. If this is 0 the run was never interrupted and the test is
	# measuring a normal completion — the exact failure the comment above
	# describes.
	[ "$status" -eq 130 ]
	[ "$(suspend_calls)" -ge 1 ]
	grep -q 'instances suspend sl-ci-1-runner' "$log"
}

# ─── The regression that matters ────────────────────────────────────────────

@test "GCPTFCI REGRESSION a failing cleanup inside the trap cannot fail a passing run" {
	# ISC-190, ISC-191. Under `set -e` a failing final command in an EXIT trap
	# replaces the script's own exit code. On 2026-08-14 that reported failure
	# for a run with 8/8 green stages. Here the suspend itself is made to fail —
	# a real cleanup failure, not a synthetic hook — and the run must still be
	# reported as the pass it was.
	export STUB_TEST_CMD="$stubdir/stub-tests-pass"
	export STUB_SUSPEND_RC=7

	run bash "$script" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"tests PASSED"* ]]

	# The suspend was genuinely attempted and genuinely failed.
	[ "$(suspend_calls)" -ge 1 ]
	[[ "$output" == *"suspend failed"* ]]
}

@test "GCPTFCI REGRESSION a failing cleanup does not mask a failing run either" {
	# The other direction. A trap that swallowed everything would turn the fail
	# path green, which is the same bug wearing a different hat.
	export STUB_TEST_CMD="$stubdir/stub-tests-fail"
	export STUB_SUSPEND_RC=7

	run bash "$script" run
	[ "$status" -eq 3 ]
	[ "$(suspend_calls)" -ge 1 ]
}

@test "GCPTFCI REGRESSION MUTATION a trap without the explicit exit does corrupt the status" {
	# Proves the assertion above measures the mechanism rather than an accident of
	# this script's structure. On a COPY, the trap's closing `exit "$rc"` is
	# replaced by a conditional that evaluates false — the exact shape of the
	# 2026-08-14 bug, where `[ -n "$LOCK_SHIM" ]` was the last command of an EXIT
	# trap and `set -e` turned its false into the script's exit status.
	#
	# Only the FIRST occurrence is replaced: on_exit's. cmd_run's own
	# `exit "$rc"` is left alone, so the mutation isolates the trap.
	local copy="$BATS_TEST_TMPDIR/mutated.sh"
	sed '0,/^  exit "\$rc"$/s//  [ "$HOLDS_LOCK" = "1" ]/' "$script" >"$copy"
	chmod +x "$copy"

	# The mutation landed where it was aimed. Counted at the statement site only:
	# the header comment also contains the string, and matching that would let a
	# no-op sed report success.
	run grep -c '^  exit "\$rc"$' "$script"
	[ "$output" -eq 2 ]
	run grep -c '^  exit "\$rc"$' "$copy"
	[ "$output" -eq 1 ]
	run grep -c 'HOLDS_LOCK" = "1" \]$' "$copy"
	[ "$output" -ge 1 ]

	export STUB_TEST_CMD="$stubdir/stub-tests-pass"

	# Mutant: a passing run reports failure.
	run bash "$copy" run
	[ "$status" -ne 0 ]
	[[ "$output" == *"tests PASSED"* ]]

	# Paired positive on the real script, same scenario: still 0.
	: >"$log"
	run bash "$script" run
	[ "$status" -eq 0 ]
	[[ "$output" == *"tests PASSED"* ]]
}

# ─── The ssh-agent guard, as behaviour ──────────────────────────────────────

@test "GCPTFCI the ssh-agent guard is effective, not merely present" {
	# ISC-198. A populated agent makes IAP SSH fail with "agent refused
	# operation", which reads as a VM provisioning fault and is a local one.
	export SSH_AUTH_SOCK="/tmp/definitely-not-a-real-agent.sock"
	export STUB_TEST_CMD="$stubdir/stub-tests-pass"

	run bash "$script" run
	[ "$status" -eq 0 ]

	# The stub records what it actually observed on every call.
	run grep -c 'SSH_AUTH_SOCK=\[\]' "$log"
	[ "$output" -ge 1 ]

	run grep -c 'definitely-not-a-real-agent' "$log"
	[ "$output" -eq 0 ]
}

# ─── The reaper ─────────────────────────────────────────────────────────────

seed_instances() {
	local old new
	old="$(date -u -d '@'"$(($(date +%s) - 6000))" +%Y-%m-%dT%H:%M:%S%z)"
	new="$(date -u -d '@'"$(($(date +%s) - 120))" +%Y-%m-%dT%H:%M:%S%z)"
	grep -v '^#' "$fixtures/instances.tsv.template" |
		sed -e "s|@OLD@|${old}|" -e "s|@NEW@|${new}|" \
			>"$BATS_TEST_TMPDIR/instances.tsv"
	export STUB_INSTANCE_LIST="$BATS_TEST_TMPDIR/instances.tsv"
}

@test "GCPTFREAP the adversarial instance list is loaded and non-trivial" {
	# Presence before behaviour: a reaper test against an empty list would prove
	# nothing at all and would pass.
	[ -f "$fixtures/instances.tsv.template" ]
	seed_instances
	run bash -c "wc -l < '$STUB_INSTANCE_LIST'"
	[ "$output" -ge 7 ]
	grep -q 'sl-demo-1-vm' "$STUB_INSTANCE_LIST"
	grep -q 'signalloom-ci' "$STUB_INSTANCE_LIST"
	grep -q 'sl-ci-1-runner' "$STUB_INSTANCE_LIST"
}

@test "GCPTFREAP only ci-lane instances are suspended" {
	# ISC-196.
	seed_instances
	run bash "$reaper" --idle-minutes 60 --project CHANGEME-project
	[ "$status" -eq 0 ]

	local names
	names="$(suspended_names)"
	[ -n "$names" ]
	[[ "$names" == *sl-ci-1-runner* ]]
	[[ "$names" == *sl-ci-2-runner* ]]
}

@test "GCPTFREAP a demo VM is NEVER suspended, even when it carries a ci-lane label" {
	# ISC-197. The fixture's demo rows carry ci-lane labels on purpose: the
	# gcloud filter alone must not be what protects them.
	seed_instances
	run bash "$reaper" --idle-minutes 60 --project CHANGEME-project
	[ "$status" -eq 0 ]

	local names
	names="$(suspended_names)"
	[[ "$names" != *demo* ]]
	run grep -c 'instances suspend sl-demo-1-vm' "$log"
	[ "$output" -eq 0 ]
	run grep -c 'instances suspend sl-demo-2-runner' "$log"
	[ "$output" -eq 0 ]
}

@test "GCPTFREAP the legacy signalloom-ci runners are NEVER suspended" {
	# They carry valid ci-1 / ci-2 labels in the fixture, so only the name
	# allowlist and the explicit denylist stand between them and a suspend.
	seed_instances
	run bash "$reaper" --idle-minutes 60 --project CHANGEME-project
	[ "$status" -eq 0 ]

	run grep -cE 'instances suspend signalloom-ci( |$)' "$log"
	[ "$output" -eq 0 ]
	run grep -c 'instances suspend signalloom-ci-2' "$log"
	[ "$output" -eq 0 ]
}

@test "GCPTFREAP the idle threshold actually gates: a young lane is left alone" {
	# ISC-195 as behaviour. sl-ci-9-runner is a genuine, correctly-labelled,
	# correctly-named lane. The ONLY thing protecting it is the threshold.
	seed_instances
	run bash "$reaper" --idle-minutes 60 --project CHANGEME-project
	[ "$status" -eq 0 ]
	[[ "$output" == *"sl-ci-9-runner"* ]]
	[[ "$output" == *"under the 60m threshold"* ]]

	run grep -c 'instances suspend sl-ci-9-runner' "$log"
	[ "$output" -eq 0 ]
}

@test "GCPTFREAP lowering the threshold reaps the young lane too" {
	# The paired positive: without it, the previous test is indistinguishable
	# from a reaper that never suspends anything.
	seed_instances
	run bash "$reaper" --idle-minutes 1 --project CHANGEME-project
	[ "$status" -eq 0 ]

	run grep -c 'instances suspend sl-ci-9-runner' "$log"
	[ "$output" -ge 1 ]

	# ...and the demo and legacy VMs are STILL untouched at any threshold. This
	# is the structural claim: their protection does not depend on the number.
	run grep -c 'instances suspend sl-demo' "$log"
	[ "$output" -eq 0 ]
	run grep -cE 'instances suspend signalloom-ci' "$log"
	[ "$output" -eq 0 ]
}

@test "GCPTFREAP a non-numeric idle threshold is refused" {
	seed_instances
	run bash "$reaper" --idle-minutes not-a-number
	[ "$status" -ne 0 ]
	[[ "$output" == *"positive integer"* ]]
	[ "$(suspend_calls)" -eq 0 ]
}

@test "GCPTFREAP dry-run suspends nothing" {
	seed_instances
	run bash "$reaper" --idle-minutes 1 --dry-run --project CHANGEME-project
	[ "$status" -eq 0 ]
	[[ "$output" == *"DRY-RUN would suspend sl-ci-1-runner"* ]]
	[ "$(suspend_calls)" -eq 0 ]
}
