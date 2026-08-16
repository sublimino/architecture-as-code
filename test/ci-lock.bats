#!/usr/bin/env bats
#
# The lock exists because announcing intent is not a control: on 2026-08-04 a
# destructive pipeline started 25 seconds after the other party said "taking the
# VM", and twice more the same night. The race is shorter than the time it takes
# to read a message.
#
# These tests drive the real lock protocol against a local temp directory by
# wiring CI_LOCK_REMOTE_EXEC to `bash -c` instead of an IAP SSH invocation — no
# VM, no gcloud, no network. That injectable boundary is the reason the lock can
# be tested at all.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/ci/ci-lock.sh"
	export CI_LOCK_PATH="$BATS_TEST_TMPDIR/lock"
	export CI_LOCK_REMOTE_EXEC="bash -c"
	export CI_LOCK_HOLDER="agent-a@host"
	export CI_LOCK_TOKEN="agent-a@host:111"
	# Zero-delay retries for test speed; production defaults to 1s base.
	export CI_LOCK_RETRY_DELAY=0
	export CI_LOCK_RETRY_MAX=3
}

# Take the lock as somebody else, optionally aged into the past.
hold_as() {
	local holder="$1" token="$2" age_secs="${3:-0}"
	mkdir -p "$CI_LOCK_PATH"
	printf '%s|%s|%s|%s\n' "$holder" "$token" "$(( $(date +%s) - age_secs ))" "their run" \
		>"$CI_LOCK_PATH/holder"
}

# ─── Acquire ────────────────────────────────────────────────────────────────

@test "CILOCK a free lock is acquired" {
	run bash "$script" acquire
	[ "$status" -eq 0 ]
	[[ "$output" == *"acquired by agent-a@host"* ]]
	[ -f "$CI_LOCK_PATH/holder" ]
}

@test "CILOCK a held lock is REFUSED, not silently taken" {
	hold_as "agent-b@host" "agent-b@host:222" 300
	run bash "$script" acquire
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]]
	[[ "$output" == *"agent-b@host"* ]]
	# The holder record must be untouched — a refused acquire that overwrote
	# the holder would be worse than no lock at all.
	run cat "$CI_LOCK_PATH/holder"
	[[ "$output" == *"agent-b@host:222"* ]]
}

@test "CILOCK the refusal names the blast radius, not just the lock" {
	# "Lock held" invites --force as a reflex. Naming what would be destroyed
	# is the difference between a warning and a decision.
	hold_as "agent-b@host" "agent-b@host:222" 300
	run bash "$script" acquire
	[[ "$output" == *"rm -rf"* ]]
	[[ "$output" == *"make teardown"* ]]
}

@test "CILOCK the refusal reports how long the lock has been held" {
	# Age is what tells a blocked caller whether to wait or investigate, so both
	# sides of the minutes/hours boundary are covered. The switch is at 90m, not
	# 60m, so an hour-old lock reads "60m" — deliberate: one unit change rather
	# than two, and "60m" is never ambiguous.
	hold_as "agent-b@host" "agent-b@host:222" 3600
	run bash "$script" acquire
	[[ "$output" == *"60m"* ]]

	rm -rf "$CI_LOCK_PATH"
	hold_as "agent-b@host" "agent-b@host:222" 7200
	run bash "$script" acquire
	[[ "$output" == *"2h0m"* ]]

	rm -rf "$CI_LOCK_PATH"
	hold_as "agent-b@host" "agent-b@host:222" 30
	run bash "$script" acquire
	[[ "$output" == *"30s"* ]]
}

@test "CILOCK --force takes a held lock and says so loudly" {
	hold_as "agent-b@host" "agent-b@host:222" 60
	run bash "$script" acquire --force
	[ "$status" -eq 0 ]
	[[ "$output" == *"FORCING"* ]]
	[[ "$output" == *"agent-b@host"* ]]
	run cat "$CI_LOCK_PATH/holder"
	[[ "$output" == *"agent-a@host:111"* ]]
}

@test "CILOCK a lock past its TTL is reclaimed automatically" {
	# A crashed holder must not wedge the VM until a human notices.
	CI_LOCK_TTL_MINUTES=60 hold_as "agent-b@host" "agent-b@host:222" 7200
	CI_LOCK_TTL_MINUTES=60 run bash "$script" acquire
	[ "$status" -eq 0 ]
	[[ "$output" == *"stale lock reclaimed"* ]]
}

@test "CILOCK a lock INSIDE its TTL is not reclaimed" {
	# The boundary in the direction that matters: stealing a live lock is the
	# exact failure this file exists to prevent, so an off-by-one here would
	# reintroduce it.
	CI_LOCK_TTL_MINUTES=60 hold_as "agent-b@host" "agent-b@host:222" 3540
	CI_LOCK_TTL_MINUTES=60 run bash "$script" acquire
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]]
}

@test "CILOCK two sequential acquires cannot both succeed" {
	# The property the whole thing rests on, asserted end to end rather than
	# inferred from mkdir's documented behaviour.
	run bash "$script" acquire
	[ "$status" -eq 0 ]
	CI_LOCK_HOLDER="agent-b@host" CI_LOCK_TOKEN="agent-b@host:222" run bash "$script" acquire
	[ "$status" -ne 0 ]
}

@test "CILOCK a lock directory with unreadable metadata is still a lock" {
	# Reporting "free" because the holder file is missing would be the worst
	# possible failure for a safety check — it fails OPEN on exactly the
	# half-written state that a crash during acquire produces.
	mkdir -p "$CI_LOCK_PATH"
	run bash "$script" acquire
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]]
}

@test "CILOCK a reason is recorded and shown to whoever is blocked" {
	bash "$script" acquire --reason "ISC-73 e2e run"
	CI_LOCK_HOLDER="agent-b@host" CI_LOCK_TOKEN="agent-b@host:222" run bash "$script" acquire
	[[ "$output" == *"ISC-73 e2e run"* ]]
}

# ─── Release ────────────────────────────────────────────────────────────────

@test "CILOCK release frees a lock we hold" {
	bash "$script" acquire
	run bash "$script" release
	[ "$status" -eq 0 ]
	[ ! -d "$CI_LOCK_PATH" ]
}

@test "CILOCK release does NOT free a lock someone else now holds" {
	# The subtle second race: our run overruns its TTL, someone legitimately
	# reclaims the lock, and then our exit trap fires. Without the token check
	# the trap deletes the new holder's lock and the safety mechanism becomes
	# the hazard.
	hold_as "agent-b@host" "agent-b@host:222" 10
	run bash "$script" release
	[ "$status" -ne 0 ]
	[[ "$output" == *"NOT releasing"* ]]
	[ -d "$CI_LOCK_PATH" ]
}

@test "CILOCK releasing an already-free lock is a no-op, not an error" {
	# Release runs from an exit trap, including on paths where acquire never
	# ran. It must not turn a successful run into a failed one.
	run bash "$script" release
	[ "$status" -eq 0 ]
	[[ "$output" == *"already free"* ]]
}

# ─── Status ─────────────────────────────────────────────────────────────────

@test "CILOCK status reports free when free" {
	run bash "$script" status
	[ "$status" -eq 0 ]
	[ "$output" = "free" ]
}

@test "CILOCK status names the holder and the age" {
	hold_as "agent-b@host" "agent-b@host:222" 120
	run bash "$script" status
	[[ "$output" == *"agent-b@host"* ]]
	[[ "$output" == *"2m"* ]]
	[[ "$output" == *"their run"* ]]
}

# ─── Wiring ─────────────────────────────────────────────────────────────────

@test "CILOCK refuses to run at all without a remote-exec boundary" {
	# Fail closed rather than silently locking the local machine, which would
	# report success while protecting nothing.
	CI_LOCK_REMOTE_EXEC="" run bash "$script" status
	[ "$status" -ne 0 ]
	[[ "$output" == *"CI_LOCK_REMOTE_EXEC"* ]]
}

@test "CILOCK gcp-ci.sh acquires the lock before anything destructive" {
	# Guards the integration, not the unit. push_code does `rm -rf` and the
	# pipeline does `make teardown`; if the lock is ever acquired after either,
	# it protects nothing.
	local gcp="$BATS_TEST_DIRNAME/../scripts/ci/gcp-ci.sh"
	run grep -n "lock_acquire\|push_code\|make teardown" "$gcp"
	[ "$status" -eq 0 ]
	local acquire_line push_line
	acquire_line="$(grep -n 'lock_acquire' "$gcp" | grep -v '^\s*#' | head -1 | cut -d: -f1)"
	push_line="$(grep -n '^\s*push_code$' "$gcp" | head -1 | cut -d: -f1)"
	[ -n "$acquire_line" ]
	[ -n "$push_line" ]
	[ "$acquire_line" -lt "$push_line" ]
}

# ─── Unreachable is not free ────────────────────────────────────────────────
#
# All four of these regress one 2026-08-12 warm CI run: 8/8 stages green, and
# the run still printed "ci-lock: already free" and exited 1. The lock was on a
# VM that had just been suspended, so every remote read failed and was reported
# as "free" — leaving the lock held for its full TTL.

# A remote boundary that cannot reach the far side, as a suspended VM or a
# dropped IAP tunnel presents.
unreachable_exec() {
	printf '#!/usr/bin/env bash\necho "ERROR: could not reach the instance" >&2\nexit 255\n' \
		>"$BATS_TEST_TMPDIR/unreachable"
	chmod +x "$BATS_TEST_TMPDIR/unreachable"
	export CI_LOCK_REMOTE_EXEC="$BATS_TEST_TMPDIR/unreachable"
}

@test "CILOCK status does NOT report free when the VM is unreachable" {
	unreachable_exec
	run bash "$script" status
	[ "$status" -ne 0 ]
	[ "$output" != "free" ]
	[[ "$output" == *"could not reach"* ]]
}

@test "CILOCK release does NOT claim already-free when the VM is unreachable" {
	# The lock lives on the VM. If we cannot reach it we have not released it,
	# and saying otherwise is how a lock survives its own run.
	unreachable_exec
	run bash "$script" release
	[ "$status" -ne 0 ]
	[[ "$output" != *"already free"* ]]
	[[ "$output" == *"NOT released"* ]]
}

@test "CILOCK acquire refuses rather than reclaiming an unreachable VM as stale" {
	unreachable_exec
	run bash "$script" acquire
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot reach"* ]]
}

@test "CILOCK acquire does not let --force past an unreachable VM" {
	# --force past a VM we cannot talk to writes no holder record: it would
	# report an acquisition that never happened.
	unreachable_exec
	run bash "$script" acquire --force
	[ "$status" -ne 0 ]
	[[ "$output" != *"acquired"* ]]
}

@test "CILOCK a held lock is still read correctly through the sentinel path" {
	# The free/unreachable split works by having the far side echo a sentinel.
	# Guard that it did not start leaking into the holder record.
	hold_as "agent-b@host" "agent-b@host:222" 60
	run bash "$script" status
	[ "$status" -eq 0 ]
	[[ "$output" == *"agent-b@host"* ]]
	[[ "$output" != *"__CI_LOCK_FREE__"* ]]
}

# ─── Transport-failure retry (the mkdir/free race) ─────────────────────────
#
# On 2026-08-16, a freshly provisioned VM was still booting when the mkdir SSH
# failed (return 255). read_lock then succeeded and found the lock free, but
# the code fell through to REFUSING with "an unknown process" for "0s" — a
# free lock reported as held. The fix retries the mkdir with bounded backoff
# when read_lock confirms the lock is free.

# A remote boundary that fails the first N calls, then succeeds.
# Usage: flaky_exec <fail_count>
flaky_exec() {
	local fail_count="${1:-1}"
	cat >"$BATS_TEST_TMPDIR/flaky" <<SHIM
#!/usr/bin/env bash
COUNTER_FILE="$BATS_TEST_TMPDIR/flaky-counter"
count=0
[ -f "\$COUNTER_FILE" ] && count=\$(cat "\$COUNTER_FILE")
count=\$((count + 1))
printf '%s' "\$count" >"\$COUNTER_FILE"
if [ "\$count" -le "$fail_count" ]; then
  echo "ERROR: could not reach the instance" >&2
  exit 255
fi
bash -c "\$1"
SHIM
	chmod +x "$BATS_TEST_TMPDIR/flaky"
	printf '0' >"$BATS_TEST_TMPDIR/flaky-counter"
	export CI_LOCK_REMOTE_EXEC="$BATS_TEST_TMPDIR/flaky"
}

@test "CILOCK transport fails on mkdir, SSH recovers, lock free → acquired on retry" {
	# The exact defect: mkdir fails (transport), read_lock succeeds (free),
	# retry mkdir succeeds → acquired. Must NOT say REFUSING.
	flaky_exec 1  # first call (mkdir) fails, all subsequent succeed
	run bash "$script" acquire
	[ "$status" -eq 0 ]
	[[ "$output" == *"acquired by agent-a@host"* ]]
	[[ "$output" == *"retry"* ]]
	[ -f "$CI_LOCK_PATH/holder" ]
}

@test "CILOCK transport fails on mkdir, SSH recovers, lock NOW held → refused with real holder" {
	# mkdir fails (transport), read_lock succeeds and finds it free, but by
	# the time we retry someone else has taken it. Must REFUSE naming the
	# real holder, not "an unknown process".
	flaky_exec 1
	# After the first call fails, hold_as creates the lock before the retry
	# mkdir runs. We simulate this by pre-creating the lock — the flaky shim
	# fails call 1 (the original mkdir), then call 2 (read_lock) succeeds
	# and finds the lock free, then call 3 (retry mkdir) will fail because
	# the directory exists, and call 4 (re-read) will find the holder.
	# Actually: we need the lock to appear between the read_lock and retry.
	# Simpler: fail only the first call, then let the lock be pre-held.
	# The first mkdir fails (transport). read_lock succeeds → free.
	# Then before retry, someone acquires. We can simulate by having the
	# lock directory exist with a holder file — the retry mkdir will fail
	# (dir exists), and the re-read will find the holder.
	#
	# Reset: the flaky shim fails call 1. After that, bash -c works.
	# We hold the lock BEFORE running the script — the sequence:
	# 1. mkdir → flaky fails (call 1)
	# 2. read_lock → succeeds (call 2), but finds holder → held
	# This means it goes straight to the existing held-lock path.
	# That's actually the pre-existing "held lock" case.
	#
	# For the retry path: we need read_lock to return free (no lock dir),
	# then someone creates the lock dir between read_lock and retry mkdir.
	# Use a shim that creates the lock on call 3 (the first retry mkdir).
	cat >"$BATS_TEST_TMPDIR/flaky-then-held" <<SHIM
#!/usr/bin/env bash
COUNTER_FILE="$BATS_TEST_TMPDIR/flaky-counter2"
count=0
[ -f "\$COUNTER_FILE" ] && count=\$(cat "\$COUNTER_FILE")
count=\$((count + 1))
printf '%s' "\$count" >"\$COUNTER_FILE"
if [ "\$count" -eq 1 ]; then
  # First call: original mkdir — transport failure
  echo "ERROR: could not reach the instance" >&2
  exit 255
fi
if [ "\$count" -eq 3 ]; then
  # Third call: first retry mkdir — someone else acquires just before us
  mkdir -p "$CI_LOCK_PATH"
  printf 'rival@box|rival@box:999|%s|their job\n' "\$(date +%s)" >"$CI_LOCK_PATH/holder"
fi
bash -c "\$1"
SHIM
	chmod +x "$BATS_TEST_TMPDIR/flaky-then-held"
	printf '0' >"$BATS_TEST_TMPDIR/flaky-counter2"
	export CI_LOCK_REMOTE_EXEC="$BATS_TEST_TMPDIR/flaky-then-held"

	run bash "$script" acquire
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]]
	[[ "$output" == *"rival@box"* ]]
	# Must NOT say "an unknown process" — the real holder is known.
	[[ "$output" != *"an unknown process"* ]]
}

@test "CILOCK transport fails on mkdir AND read_lock → dies with transport error" {
	# Both mkdir and read_lock fail: fully unreachable. Must die, not retry.
	unreachable_exec
	run bash "$script" acquire
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot reach"* ]]
	[[ "$output" != *"REFUSING"* ]]
	[[ "$output" != *"TRANSPORT ERROR"* ]]
}

@test "CILOCK transport error message for exhausted retries names the real cause" {
	# mkdir fails every time, but read_lock succeeds every time (free).
	# After max retries, must say TRANSPORT ERROR, not REFUSING.
	cat >"$BATS_TEST_TMPDIR/mkdir-always-fails" <<SHIM
#!/usr/bin/env bash
# mkdir calls fail (transport), everything else succeeds via bash -c.
# Detect mkdir by the command containing 'mkdir'.
if printf '%s' "\$1" | grep -q 'mkdir'; then
  echo "ERROR: could not reach the instance" >&2
  exit 255
fi
bash -c "\$1"
SHIM
	chmod +x "$BATS_TEST_TMPDIR/mkdir-always-fails"
	export CI_LOCK_REMOTE_EXEC="$BATS_TEST_TMPDIR/mkdir-always-fails"

	run bash "$script" acquire
	[ "$status" -eq 2 ]
	[[ "$output" == *"TRANSPORT ERROR"* ]]
	[[ "$output" == *"free but we cannot acquire"* ]]
	[[ "$output" != *"REFUSING"* ]]
	[[ "$output" == *"Nobody holds the lock"* ]]
}

@test "CILOCK refusal for a REAL lock still names the holder and age" {
	# Regression guard: the retry logic must not interfere with the normal
	# held-lock refusal path. Holder name and age must appear.
	hold_as "agent-b@host" "agent-b@host:222" 600
	run bash "$script" acquire
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]]
	[[ "$output" == *"agent-b@host"* ]]
	[[ "$output" == *"10m"* ]]
}

# ─── The exit trap must not rewrite the run's verdict ───────────────────────

@test "CILOCK gcp-ci.sh releases the lock BEFORE suspending the VM" {
	# Releasing from the EXIT trap alone put every release after the suspend,
	# where it could never succeed.
	# Scoped to cmd_run: cmd_provision legitimately suspends too, and it has no
	# lock to release.
	local gcp="$BATS_TEST_DIRNAME/../scripts/ci/gcp-ci.sh"
	local body release_line suspend_line
	body="$(awk '/^cmd_run\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp")"
	release_line="$(printf '%s\n' "$body" | grep -n '^[[:space:]]*lock_release$' | head -1 | cut -d: -f1)"
	suspend_line="$(printf '%s\n' "$body" | grep -n 'instances suspend' | head -1 | cut -d: -f1)"
	[ -n "$release_line" ]
	[ -n "$suspend_line" ]
	[ "$release_line" -lt "$suspend_line" ]
}

@test "CILOCK gcp-ci.sh lock_release ends in an unconditional return 0" {
	# `set -e` makes a failing last command in an EXIT trap override the exit
	# status the script asked for. lock_release ended in
	# `[ -n "$LOCK_SHIM" ] && rm -f "$LOCK_SHIM"`, which returned 1 whenever
	# LOCK_SHIM was empty — which was always, because lock_shim assigned it in
	# a `$( )` subshell. 8/8 stages green, exit 1.
	local gcp="$BATS_TEST_DIRNAME/../scripts/ci/gcp-ci.sh"
	run awk '/^lock_release\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"return 0"* ]]
	# The last statement before the closing brace must be `return 0`.
	local last
	last="$(printf '%s\n' "$output" | grep -v '^\s*$' | tail -2 | head -1 | tr -d '[:space:]')"
	[ "$last" = "return0" ]
}

@test "CILOCK gcp-ci.sh never calls lock_shim in a command substitution" {
	# `LOCK_SHIM="$(mktemp ...)"` inside `$(lock_shim)` is discarded with the
	# subshell: the memo never hits, each call leaks a temp file, and the
	# parent's LOCK_SHIM stays empty forever.
	local gcp="$BATS_TEST_DIRNAME/../scripts/ci/gcp-ci.sh"
	# A missing gcp-ci.sh makes the first grep exit 2 and emit nothing, so the
	# second grep exits 1 and the old `-ne 0` passed — on an empty scan. The
	# pipeline hides the error status of its first stage, which is exactly why
	# the subject has to be asserted separately.
	[ -f "$gcp" ]

	# Code only — the comment on lock_shim quotes the broken form on purpose.
	run bash -c "grep -v '^[[:space:]]*#' '$gcp' | grep -n '\$(lock_shim)'"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "CILOCK an exit trap wired to lock_release preserves a zero exit status" {
	# End to end on the real function, with the remote boundary stubbed out:
	# a script that succeeds must still exit 0 after the trap has run.
	local gcp="$BATS_TEST_DIRNAME/../scripts/ci/gcp-ci.sh"
	cat >"$BATS_TEST_TMPDIR/trap-probe.sh" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
VM_NAME=vm; ZONE=z; PROJECT=p
LOCK_SCRIPT="$BATS_TEST_TMPDIR/noop-lock.sh"
LOCK_HOLDER_NAME=probe
LOCK_TOKEN_VALUE=probe:1
GCP_CI_HOLDS_LOCK=1
LOCK_SHIM=""
$(awk '/^lock_shim\(\)/{f=1} f{print} f&&/^}/{if(++n==1)exit}' "$gcp")
$(awk '/^lock_release\(\)/{f=1} f{print} f&&/^}/{exit}' "$gcp")
trap lock_release EXIT
exit 0
PROBE
	printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/noop-lock.sh"
	run bash "$BATS_TEST_TMPDIR/trap-probe.sh"
	[ "$status" -eq 0 ]
}
