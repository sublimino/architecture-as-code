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
	#
	# `[ "$status" -ne 0 ]` alone was vacuous, and test/vacuous-assertions.bats
	# (VAC003) caught it: grep exits 1 for "no match" — the pass condition — but
	# exits 2 for "file not found", so the assertion also passed if either script
	# had been renamed or never written. Both files are proven present first, and
	# the exit status is pinned to exactly 1 with empty output.
	[ -f "$script" ]
	[ -f "$reaper" ]
	run grep -nE '\b(pgrep|pkill)\b' "$script" "$reaper"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "GCPTFCI MUTATION the pgrep guard fires on a script that has one" {
	local stage
	stage="$(mktemp -d)"
	cp "$script" "$stage/mutant.sh"
	printf '\npkill -f "some pattern"\n' >>"$stage/mutant.sh"
	run grep -nE '\b(pgrep|pkill)\b' "$stage/mutant.sh"
	rm -rf "$stage"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
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
	grep -q 'instances resume sl-ci-1-vm' "$log"
	grep -q 'instances suspend sl-ci-1-vm' "$log"
}

@test "GCPTFCI default test command is the offline Terraform validation gate" {
	# The runner VM does not require a deployed demo. Setup supplies an override
	# for other lifecycle tests, so remove it to exercise the real default.
	run env -u GCP_TF_CI_TEST_CMD bash "$script" run
	[ "$status" -eq 0 ]

	grep -q 'make gcp-tf-validate' "$log"
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
	grep -q 'instances suspend sl-ci-1-vm' "$log"
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
#
# THE SELECTOR CHANGED ON 2026-08-20 AND THESE TESTS ARE THE PROOF IT IS SAFE.
#
# The reaper used to admit an instance whose NAME matched
# ^sl-ci-[1-9][0-9]*-runner$ — the shape terraform/modules/ci-runner produced.
# That module was absorbed into modules/compute, both lane kinds are now
# `sl-<key>-vm`, and the name gate would have matched nothing: the reaper would
# have suspended nothing, printed "0 suspended", and exited 0 while every lane
# billed forever. A silent no-op presents as success, which is why it is the
# worse of the two failures.
#
# The selector is now the `ci-lane` LABEL, emitted by modules/compute for
# `kind = "ci"` and for nothing else.
#
# ─── Why every test below carries BOTH halves ───────────────────────────────
#
# "no demo VM was suspended" is trivially satisfied by nothing being suspended
# at all, which is also exactly what a broken selector produces. So the negative
# is never asserted alone: every test that proves a demo VM was refused ALSO
# proves a genuine CI lane was reaped in the same run. One without the other is
# not evidence, it is the appearance of evidence.

seed_instances() {
	local old new
	old="$(date -u -d '@'"$(($(date +%s) - 6000))" +%Y-%m-%dT%H:%M:%S%z)"
	new="$(date -u -d '@'"$(($(date +%s) - 120))" +%Y-%m-%dT%H:%M:%S%z)"
	grep -v '^#' "$fixtures/instances.tsv.template" |
		sed -e "s|@OLD@|${old}|" -e "s|@NEW@|${new}|" \
			>"$BATS_TEST_TMPDIR/instances.tsv"
	export STUB_INSTANCE_LIST="$BATS_TEST_TMPDIR/instances.tsv"
}

# Runs the reaper over the seeded fixture at a threshold that makes every OLD
# row eligible on age, so the only thing deciding an outcome is a safety gate.
reap_all() {
	run bash "$reaper" --idle-minutes "${1:-60}" --project CHANGEME-project
	[ "$status" -eq 0 ]
}

# The positive control, factored into a helper so no test can forget it and so a
# reviewer can see at a glance which tests carry it.
#
# Named for what it defends: without a reaped lane in the same run, every
# "was not suspended" assertion in this file is satisfied by a reaper that does
# nothing whatsoever — which is exactly what the retired name selector would
# have degraded into.
assert_a_real_lane_was_reaped() {
	grep -q 'instances suspend sl-ci-1-vm' "$log" || {
		echo "POSITIVE CONTROL FAILED: no genuine CI lane was reaped, so every"
		echo "negative assertion in this test is vacuous. Suspend log:"
		cat "$log"
		return 1
	}
}

assert_not_suspended() {
	local name="$1" n
	n="$(grep -cE "instances suspend ${name}( |\$)" "$log" || true)"
	[ "$n" -eq 0 ] || {
		echo "REAPER SUSPENDED ${name} — it must never be able to."
		cat "$log"
		return 1
	}
}

@test "GCPTFREAP the adversarial instance list is loaded and non-trivial" {
	# Presence before behaviour: a reaper test against an empty list would prove
	# nothing at all and would pass.
	[ -f "$fixtures/instances.tsv.template" ]
	seed_instances
	run bash -c "wc -l < '$STUB_INSTANCE_LIST'"
	[ "$output" -ge 13 ]

	# Each adversarial row is present by name, so a fixture that silently lost
	# one cannot make the test it exists for pass by absence.
	grep -q 'sl-ci-1-vm' "$STUB_INSTANCE_LIST"
	grep -q 'sl-demo-1-vm' "$STUB_INSTANCE_LIST"
	grep -q 'sl-demo-2-vm' "$STUB_INSTANCE_LIST"
	grep -q 'sl-demo-3-vm' "$STUB_INSTANCE_LIST"
	grep -q 'signalloom-ci' "$STUB_INSTANCE_LIST"

	# And every row carries the full seven PIPE-separated columns. A short row
	# degrades to an empty kind label, which gate 3 refuses — so a truncated
	# fixture would make the demo-protection tests pass for the wrong reason.
	#
	# The separator is `|` rather than a tab because tab is IFS whitespace and
	# collapses the empty kind column this fixture deliberately contains; awk's
	# -F'\t' had the same defect as the reaper's `IFS=$'\t' read`. Asserted here
	# so a future "tidy up" back to tabs fails loudly.
	run awk -F'|' 'NF != 7 { bad++ } END { print bad + 0 }' "$STUB_INSTANCE_LIST"
	[ "$output" -eq 0 ]

	# The empty-kind row is genuinely empty, not merely short. This is the row
	# that found the tab bug; without it gate 3's absent-label test has no
	# subject.
	run awk -F'|' '$1 == "sl-ci-4-vm" { print "[" $6 "]" }' "$STUB_INSTANCE_LIST"
	[ "$output" = "[]" ]
}

# ─── The selector itself, at the source level ───────────────────────────────

@test "GCPTFREAP the selector is the ci-lane LABEL and refuses on its absence" {
	# The mechanism assertion, placed FIRST so a failure names the missing
	# mechanism rather than a missing message. CONTRACT §7b case 3.
	[ -f "$reaper" ]

	# It asks gcloud for the label, and for the two labels the deeper gates read.
	grep -q 'labels.ci-lane:\*' "$reaper"
	grep -q 'labels.kind' "$reaper"
	grep -q 'labels.environment' "$reaper"

	# The absence of the label is a REFUSAL. Matched as a complete line so a
	# comment describing the rule cannot satisfy the check — this repo has
	# shipped a guard satisfied by the prose that explained it.
	run grep -cE '^[[:space:]]*if \[ -z "\$\{lane:-\}" \]; then$' "$reaper"
	[ "$output" -eq 1 ]
}

@test "GCPTFREAP no gate ADMITS an instance because of its name" {
	# The rule that must survive every future edit: a name may only ever take
	# away. The old ^sl-ci-N-runner$ admission is gone and nothing may replace it.
	#
	# Scoped to the executing gate region — `main()` to end of file — rather than
	# the whole file, because the header comment quotes the retired pattern
	# verbatim in order to explain why it was retired, and a whole-file grep
	# would fire on the explanation. That is the exact shape that has bitten this
	# repo repeatedly: an assertion that is true, of the wrong thing.
	local body="$BATS_TEST_TMPDIR/reaper-main.sh"
	sed -n '/^main() {/,$p' "$reaper" >"$body"

	# The extraction is real. Without this, an empty body would pass everything
	# below it — a scoped grep whose scope resolved to nothing is a green test
	# measuring nothing.
	run grep -c 'Gate 1' "$body"
	[ "$output" -eq 1 ]

	# No name-shaped admission pattern anywhere in the executing body.
	run grep -nE 'sl-(ci|demo)-' "$body"
	[ "$status" -eq 1 ]
	[ -z "$output" ]

	# And there is no lane NAME pattern constant left anywhere to admit on.
	run grep -nE '^readonly LANE_NAME_PATTERN=' "$reaper"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

# ─── The safety property, positive and negative in the same test ────────────

@test "GCPTFREAP a demo VM is NEVER suspended, and a real CI lane IS" {
	# THE test. sl-demo-1-vm is serving a live demo right now.
	#
	# Both halves, deliberately in one test so neither can be deleted without the
	# other going with it. The negative alone is satisfied by a reaper that
	# suspends nothing.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	grep -q 'instances suspend sl-ci-2-vm' "$log"

	assert_not_suspended sl-demo-1-vm
	assert_not_suspended sl-demo-2-vm
	assert_not_suspended sl-demo-3-vm

	local names
	names="$(suspended_names)"
	[ -n "$names" ]
	[[ "$names" != *demo* ]]
}

@test "GCPTFREAP the LIVE demo sl-demo-1-vm is never suspended" {
	# Narrowed to ONE instance on purpose, and that instance is the one serving a
	# live demo right now.
	#
	# The broader test above asserts all three demo rows at once, which makes it
	# unusable as a mutation target for the individual gate-5 markers: a compound
	# mutation that isolates one marker necessarily lets a DIFFERENT demo row
	# through, so the broad test goes red for a reason that is not the one under
	# examination. test/ci-lane-reaper-mutation-proof.sh M8 targets this test
	# precisely because its subject is a single row.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-demo-1-vm
}

@test "GCPTFREAP GATE 3+4+5 a demo VM carrying a VALID ci-lane label is refused" {
	# sl-demo-2-vm carries ci-lane = ci-1, which passes gates 1 and 2 outright.
	# Before the selector moved, the instance-NAME gate caught this row. It no
	# longer can, so this is the test proving the replacement gates carry the
	# weight the name used to.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-demo-2-vm

	# It was seen and explicitly refused, not merely absent from the listing —
	# "never considered" and "considered and rejected" are different properties
	# and only one of them is evidence.
	[[ "$output" == *"sl-demo-2-vm"* ]]
	[[ "$output" == *"REFUSED"* ]]
}

@test "GCPTFREAP GATE 5 a demo VM with fully forged ci labels is still refused" {
	# sl-demo-3-vm forges kind = ci AND environment = ci-3 to match its ci-lane.
	# Gates 1, 2, 3 and 4 ALL pass on this row. Only gate 5's demo-marker check
	# stands between it and a suspend, which is what makes gate 5 load-bearing
	# rather than the redundant decoration it superficially looks like.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-demo-3-vm
	[[ "$output" == *"demo-lane markers"* ]]
}

@test "GCPTFREAP GATE 3 an ABSENT kind label is a refusal, not a default" {
	# sl-ci-4-vm has an empty kind column — the state a stale five-column listing
	# degrades to. Gate 3 compares for equality with "ci", so absent fails closed.
	# A gate written as "refuse if kind == demo" would admit this row.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-ci-4-vm
	[[ "$output" == *"kind label is <absent>"* ]]
}

@test "GCPTFREAP GATE 2 a ci-lane value that merely CONTAINS a lane key is refused" {
	# sl-ci-6-vm carries ci-lane = xci-6. Its environment label agrees, its kind
	# is ci, and its name carries no demo marker — so gates 3, 4, 5 and 6 all
	# pass. ONLY the ^...$ anchors on LANE_LABEL_PATTERN reject it.
	#
	# This repo has already shipped the unanchored version of this bug: DEMO_ENV
	# matching inside SL_DEMO_ENV, in a guard that read as correct.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-ci-6-vm
	[[ "$output" == *"xci-6 is not a CI lane key"* ]]
}

@test "GCPTFREAP GATE 4 an environment label disagreeing with ci-lane is refused" {
	# sl-ci-5-vm: ci-lane = ci-5, environment = ci-6. Both are CI keys, so gate 5
	# cannot fire and gate 4 is genuinely the only thing rejecting this row.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-ci-5-vm
	[[ "$output" == *"disagrees with ci-lane"* ]]
}

@test "GCPTFREAP GATE 6 the legacy signalloom-ci runners are NEVER suspended" {
	# They carry valid ci-1 / ci-2 labels AND kind = ci AND matching environment
	# labels in the fixture, so gates 1 through 5 all pass. Only the explicit
	# denylist stands between them and a suspend.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended signalloom-ci
	assert_not_suspended signalloom-ci-2
	[[ "$output" == *"protected instance"* ]]
}

# ─── Past the safety gates: whether to act, not whether it is allowed ───────

@test "GCPTFREAP a SUSPENDED lane is admitted and then left alone on state" {
	# Realistic: a demo lane is suspended right now for cost, and the gcloud
	# filter asks for RUNNING. The local status check exists for the case where
	# that filter silently stops working, so it must still hold.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-ci-7-vm
	[[ "$output" == *"state is SUSPENDED"* ]]
}

@test "GCPTFREAP an unreadable start timestamp leaves the lane running" {
	# The safe failure for a script that turns machines off is to leave them on.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-ci-8-vm
	[[ "$output" == *"unreadable start timestamp"* ]]
}

@test "GCPTFREAP the idle threshold actually gates: a young lane is left alone" {
	# sl-ci-9-vm is a genuine, correctly-labelled, correctly-named lane. The ONLY
	# thing protecting it is the threshold.
	seed_instances
	reap_all 60

	assert_a_real_lane_was_reaped
	assert_not_suspended sl-ci-9-vm
	[[ "$output" == *"sl-ci-9-vm"* ]]
	[[ "$output" == *"under the 60m threshold"* ]]
}

@test "GCPTFREAP lowering the threshold reaps the young lane too" {
	# The paired positive: without it, the previous test is indistinguishable
	# from a reaper that never suspends anything.
	seed_instances
	reap_all 1

	run grep -c 'instances suspend sl-ci-9-vm' "$log"
	[ "$output" -ge 1 ]

	# ...and every protected instance is STILL untouched at any threshold. This
	# is the structural claim: their protection does not depend on the number.
	run grep -c 'instances suspend sl-demo' "$log"
	[ "$output" -eq 0 ]
	run grep -cE 'instances suspend signalloom-ci' "$log"
	[ "$output" -eq 0 ]
}

# ─── Reporting a no-op loudly ───────────────────────────────────────────────

@test "GCPTFREAP the run reports how many rows it listed and how many it admitted" {
	# A broken selector and an idle estate both print "0 suspended". The counts
	# are what distinguishes them, and they are the operator-visible signal that
	# the selector still works at all.
	seed_instances
	reap_all 60

	[[ "$output" == *"13 listed"* ]]

	# Exactly the five genuine lanes got past the gates: ci-1, ci-2, and the
	# suspended, unreadable-timestamp and young ones. A COUNT rather than a
	# substring, because a substring assertion would hold for any number and the
	# whole point is that eight adversarial rows were stopped.
	[[ "$output" == *"5 admitted past the safety gates"* ]]
}

@test "GCPTFREAP an empty listing is reported as inconclusive, not as success" {
	# The silent-no-op failure mode in its purest form. The reaper cannot tell a
	# genuinely idle estate from a selector that stopped matching, so it must say
	# so rather than let a zero be read as health.
	: >"$BATS_TEST_TMPDIR/empty.tsv"
	export STUB_INSTANCE_LIST="$BATS_TEST_TMPDIR/empty.tsv"

	run bash "$reaper" --idle-minutes 60 --project CHANGEME-project
	[ "$status" -eq 0 ]
	[[ "$output" == *"no instance in CHANGEME-project carries a ci-lane label at all"* ]]
	[[ "$output" == *"This is not evidence of either"* ]]
	[ "$(suspend_calls)" -eq 0 ]
}

@test "GCPTFREAP a listing where every row is refused says so explicitly" {
	# Distinct from the empty case: rows arrived and every one was rejected. If a
	# real lane is running, that means the gates disagree with it — a condition
	# an operator must be told about rather than left to infer from a zero.
	seed_instances
	grep -v 'sl-ci-[1-9]-vm' "$STUB_INSTANCE_LIST" >"$BATS_TEST_TMPDIR/refused.tsv"
	export STUB_INSTANCE_LIST="$BATS_TEST_TMPDIR/refused.tsv"

	# The filtered list is non-empty, or this test measures the empty case above.
	run bash -c "wc -l < '$STUB_INSTANCE_LIST'"
	[ "$output" -ge 5 ]

	run bash "$reaper" --idle-minutes 60 --project CHANGEME-project
	[ "$status" -eq 0 ]
	[[ "$output" == *"every one was REFUSED by a"* ]]
	[ "$(suspend_calls)" -eq 0 ]
}

# ─── Flags ──────────────────────────────────────────────────────────────────

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
	[[ "$output" == *"DRY-RUN would suspend sl-ci-1-vm"* ]]
	[ "$(suspend_calls)" -eq 0 ]
}
