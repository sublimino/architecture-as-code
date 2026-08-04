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
