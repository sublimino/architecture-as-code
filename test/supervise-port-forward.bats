#!/usr/bin/env bats
#
# The defect: `make signalloom-images` started one bare `kubectl port-forward`,
# proved `/v2/` answered once, then spent minutes inside parallel Docker builds
# before pushing to the registry through that same forward. The first probe only
# proved the forward was alive BEFORE the expensive work. On 2026-08-13 both GCP
# CI lanes reached the push window with a dead forward and failed on curl exit 7
# (connection refused); the pipeline's retry masked it and burned a cycle.
#
# These tests run entirely against fake kubectl/curl binaries — no cluster, no
# apiserver — because the whole point is to exercise the FAILURE path. A real
# port-forward that happens to survive today would exercise nothing; the bug is
# precisely that it survives most of the time.
#
# The fakes are coupled the way the real system is: the fake kubectl owns a
# "serving" marker and removes it when it dies, and the fake curl reports exit 7
# when that marker is absent. Killing the child therefore genuinely takes the
# endpoint down, which is what makes the respawn assertions mean something.
#
# The fakes are deliberately the same shape as test/kind-load-verified.bats, so
# the two files can be read together.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/supervise-port-forward.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	STATE="$BATS_TEST_TMPDIR/state"

	# The fakes read all of these from the environment, so they must be exported:
	# the supervisor is a grandchild of this shell and inherits them.
	export SERVING_MARKER="$BATS_TEST_TMPDIR/serving"
	export KUBECTL_PIDS="$BATS_TEST_TMPDIR/kubectl-pids"
	export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
	# Pids the test snapshots by hand, for teardown to clean up when a state file
	# has already been removed by the code under test.
	EXTRA_PIDS="$BATS_TEST_TMPDIR/extra-pids"
	: >"$KUBECTL_PIDS"
	: >"$CALL_LOG"
	: >"$EXTRA_PIDS"
	rm -f "$SERVING_MARKER"

	cat >"$bin/kubectl" <<-'FAKE'
		#!/usr/bin/env bash
		echo "kubectl $*" >>"$CALL_LOG"
		# One pid per line: the supervisor respawns, and the tests need to tell the
		# replacement from the process it replaced.
		echo "$$" >>"$KUBECTL_PIDS"

		# Removing the marker on death is the load-bearing part of this fake. A
		# port-forward that dies stops serving; if the fake kept serving after being
		# killed, every respawn assertion below would pass vacuously.
		drop_marker() { rm -f "$SERVING_MARKER"; }
		trap 'drop_marker; exit 0' TERM INT
		trap drop_marker EXIT

		if [ "${FAKE_KUBECTL_NEVER_SERVES:-0}" = 0 ]; then
		  : >"$SERVING_MARKER"
		fi

		# Block until killed, but bounded: a fake that leaked out of a failed test
		# must not outlive the suite.
		for _ in $(seq 1 600); do sleep 0.2; done
	FAKE

	cat >"$bin/curl" <<-'FAKE'
		#!/usr/bin/env bash
		echo "curl $*" >>"$CALL_LOG"
		# 7 is what real curl returns for connection refused, and exactly the code
		# CI reported as `make: *** [Makefile:252: signalloom-images] Error 7`.
		[ -e "$SERVING_MARKER" ] || exit 7
		exit 0
	FAKE

	chmod +x "$bin/kubectl" "$bin/curl"
	export PATH="$bin:$PATH"
	export KUBECTL_BIN="$bin/kubectl"
	export CURL_BIN="$bin/curl"

	# Keep the suite fast without making it racy.
	export PF_POLL_INTERVAL=1
	export PF_PROBE_TIMEOUT=1
	export PF_KILL_TIMEOUT=2
}

teardown() {
	local pid
	for pid_file in "$STATE/supervisor.pid" "$STATE/forward.pid"; do
		[ -f "$pid_file" ] || continue
		pid="$(cat "$pid_file" 2>/dev/null || true)"
		[ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
	done
	for pid_file in "$EXTRA_PIDS" "$KUBECTL_PIDS"; do
		[ -f "$pid_file" ] || continue
		while IFS= read -r pid; do
			[ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
		done <"$pid_file"
	done
	# Teardown must never be the thing that fails the run.
	return 0
}

# ─── Helpers ────────────────────────────────────────────────────────────────
#
# Every wait in this file goes through poll_until. A bare `sleep` long enough to
# "probably" be fine is how a suite becomes flaky, and an unbounded loop turns a
# failing test into a hung one.

poll_until() {
	local description="$1" timeout="$2"
	shift 2
	local deadline=$((SECONDS + timeout))

	while [ "$SECONDS" -lt "$deadline" ]; do
		if "$@"; then
			return 0
		fi
		sleep 0.2
	done

	echo "timed out after ${timeout}s waiting for: ${description}" >&2
	return 1
}

pid_alive() {
	kill -0 "$1" 2>/dev/null
}

pid_gone() {
	kill -0 "$1" 2>/dev/null || return 0
	# A zombie answers kill -0 but is not running — it is merely unreaped. Reading
	# it as "still alive" would make these assertions depend on when the parent
	# happens to reap, which is exactly the flakiness this file exists to avoid.
	local state
	state="$(ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]' || true)"
	case "$state" in
	Z*) return 0 ;;
	esac
	return 1
}

endpoint_up() {
	[ -e "$SERVING_MARKER" ]
}

endpoint_down() {
	[ ! -e "$SERVING_MARKER" ]
}

forward_pid() {
	cat "$STATE/forward.pid" 2>/dev/null || true
}

forward_pid_differs_from() {
	local previous="$1" current
	current="$(forward_pid)"
	# The pid file is briefly absent between the kill and the respawn.
	[ -n "$current" ] && [ "$current" != "$previous" ]
}

kubectl_spawn_count_at_least() {
	local want="$1" seen
	seen="$(wc -l <"$KUBECTL_PIDS")"
	[ "$seen" -ge "$want" ]
}

start_supervised() {
	PF_UP_TIMEOUT=10 "$script" up "$STATE" registry zot 5001 5000 /v2/ "${1:-$$}"
}

# ─── The happy path stays the happy path ────────────────────────────────────

@test "up brings the forward online and records a live supervisor and child" {
	run start_supervised
	[ "$status" -eq 0 ]

	[ -f "$STATE/forward.pid" ]
	[ -f "$STATE/supervisor.pid" ]
	pid_alive "$(cat "$STATE/forward.pid")"
	pid_alive "$(cat "$STATE/supervisor.pid")"
	endpoint_up
}

# ─── The regression this whole change exists for ────────────────────────────

@test "the supervisor respawns the forward after the child dies mid-window" {
	start_supervised

	local old_pid
	old_pid="$(forward_pid)"
	kill "$old_pid"

	poll_until "the endpoint to stop answering after the child was killed" 10 endpoint_down
	poll_until "a replacement child pid to be recorded" 20 forward_pid_differs_from "$old_pid"
	poll_until "the endpoint to answer again" 20 endpoint_up

	local new_pid
	new_pid="$(forward_pid)"
	[ "$new_pid" != "$old_pid" ]
	pid_alive "$new_pid"

	grep -q "restart #1: probe failed at .*, respawning kubectl port-forward" "$STATE/forward.log"
}

@test "ensure bridges a forward that died during the build window" {
	start_supervised

	kill "$(forward_pid)"
	poll_until "the endpoint to stop answering" 10 endpoint_down

	# This is the call the Makefile makes immediately before each push.
	run env PF_ENSURE_TIMEOUT=20 "$script" ensure "$STATE"
	[ "$status" -eq 0 ]
	endpoint_up
}

# ─── The repair has to be visible, or a green lane proves nothing ───────────
#
# On a warm CI lane the Docker layers are cached, the build window collapses,
# and the forward is never stressed. A run with no `Error 7` is then equally
# consistent with "supervision worked" and "supervision never ran". These two
# lines are what tell those apart in a 1000-line CI log — and they are emitted
# from the foreground commands because the supervisor's own streams are
# detached to keep kubectl's noise out of the build output.

@test "ensure announces a repair on stdout, naming the endpoint and how long it took" {
	start_supervised

	kill "$(forward_pid)"
	poll_until "the endpoint to stop answering" 10 endpoint_down

	run env PF_ENSURE_TIMEOUT=20 "$script" ensure "$STATE"
	[ "$status" -eq 0 ]
	[[ "$output" == *"supervise-port-forward: forward was down at http://localhost:5001/v2/, restored after "*"s" ]]
}

@test "ensure stays silent when the forward was healthy all along" {
	start_supervised

	# The hot path runs before every push; narrating a non-event would bury the
	# line that matters when there IS one.
	run env PF_ENSURE_TIMEOUT=5 "$script" ensure "$STATE"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "down reports the restart count before the state dir is deleted" {
	start_supervised

	kill "$(forward_pid)"
	poll_until "the supervisor to spawn a replacement" 20 kubectl_spawn_count_at_least 2
	poll_until "the endpoint to answer again" 20 endpoint_up

	run "$script" down "$STATE"
	[ "$status" -eq 0 ]
	[[ "$output" == *"supervise-port-forward: 1 restart(s) during this run"* ]]

	# The Makefile removes the state dir immediately after this call, so the
	# printed line is the only surviving record.
	rm -rf "$STATE"
	run "$script" down "$STATE"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "down reports an explicit zero when the forward never needed repairing" {
	start_supervised

	run "$script" down "$STATE"
	[ "$status" -eq 0 ]
	# Explicit rather than silent: a missing line cannot be distinguished from a
	# teardown that never ran, which is the ambiguity this reporting removes.
	[[ "$output" == *"supervise-port-forward: 0 restart(s) during this run"* ]]
}

# ─── Unreachable registries fail loudly, and bounded ────────────────────────

@test "ensure fails with a clear message inside a bounded time when nothing can repair the forward" {
	start_supervised

	# Take supervision away first, so there is genuinely nothing left to repair it.
	"$script" down "$STATE"
	poll_until "the endpoint to stop answering once supervision is gone" 10 endpoint_down

	local started=$SECONDS
	run env PF_ENSURE_TIMEOUT=2 "$script" ensure "$STATE"
	local elapsed=$((SECONDS - started))

	[ "$status" -ne 0 ]
	[[ "$output" == *"localhost:5001/v2/"* ]]
	# Waited for the full window rather than giving up early...
	[ "$elapsed" -ge 2 ]
	# ...and did not hang, which is the failure mode that costs a whole CI slot.
	[ "$elapsed" -lt 15 ]
}

@test "up fails with a clear message and leaves nothing running when the registry never answers" {
	export FAKE_KUBECTL_NEVER_SERVES=1

	local output_file="$BATS_TEST_TMPDIR/up.out"
	local started=$SECONDS

	# Run in the background: cmd_up tears down its own pid files on the failure
	# path, so the pids have to be snapshotted while it is still running.
	PF_UP_TIMEOUT=3 "$script" up "$STATE" registry zot 5001 5000 /v2/ $$ >"$output_file" 2>&1 &
	local up_pid=$!

	poll_until "up to record its supervisor pid" 15 test -s "$STATE/supervisor.pid"
	local supervisor_pid forward_child_pid
	supervisor_pid="$(cat "$STATE/supervisor.pid")"
	forward_child_pid="$(forward_pid)"
	printf '%s\n%s\n' "$supervisor_pid" "$forward_child_pid" >>"$EXTRA_PIDS"

	local up_status=0
	wait "$up_pid" || up_status=$?
	local elapsed=$((SECONDS - started))

	[ "$up_status" -ne 0 ]
	grep -q "registry registry/svc/zot on localhost:5001->5000/v2/" "$output_file"
	grep -q "stayed unreachable for 3s" "$output_file"
	[ "$elapsed" -ge 3 ]
	[ "$elapsed" -lt 25 ]

	# A failed up must not leave the supervisor behind to rebind the port for the
	# next run — that turns one bad run into every subsequent run being bad.
	poll_until "the supervisor to be gone after a failed up" 10 pid_gone "$supervisor_pid"
	poll_until "the forward child to be gone after a failed up" 10 pid_gone "$forward_child_pid"
}

# ─── Teardown leaves nothing behind ─────────────────────────────────────────

@test "down kills both processes by pid, removes the pid files, and is idempotent" {
	start_supervised

	local supervisor_pid forward_child_pid
	supervisor_pid="$(cat "$STATE/supervisor.pid")"
	forward_child_pid="$(forward_pid)"

	run "$script" down "$STATE"
	[ "$status" -eq 0 ]

	poll_until "the supervisor to exit" 10 pid_gone "$supervisor_pid"
	poll_until "the forward child to exit" 10 pid_gone "$forward_child_pid"
	[ ! -f "$STATE/supervisor.pid" ]
	[ ! -f "$STATE/forward.pid" ]

	# The Makefile calls down from an EXIT trap, which fires on success, on
	# failure, and after a previous down. All three must be quiet no-ops.
	run "$script" down "$STATE"
	[ "$status" -eq 0 ]
	run "$script" down "$BATS_TEST_TMPDIR/never-existed"
	[ "$status" -eq 0 ]
}

@test "no kubectl process survives a supervised session, including respawned ones" {
	start_supervised

	# Force at least one respawn, so the assertion covers a child the supervisor
	# started rather than only the one up started.
	kill "$(forward_pid)"
	poll_until "the supervisor to spawn a replacement" 20 kubectl_spawn_count_at_least 2

	"$script" down "$STATE"

	local pid
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		poll_until "kubectl pid ${pid} to exit" 10 pid_gone "$pid"
	done <"$KUBECTL_PIDS"
}

@test "the supervisor exits on its own when its owner dies, taking the child with it" {
	# A hard-killed make never runs its EXIT trap. The owner-liveness check is the
	# only thing standing between that and an orphaned kubectl holding port 5001
	# hostage for the next run.
	sleep 120 &
	local owner_pid=$!
	echo "$owner_pid" >>"$EXTRA_PIDS"

	start_supervised "$owner_pid"

	local supervisor_pid forward_child_pid
	supervisor_pid="$(cat "$STATE/supervisor.pid")"
	forward_child_pid="$(forward_pid)"

	kill "$owner_pid"

	poll_until "the supervisor to notice its owner died" 20 pid_gone "$supervisor_pid"
	poll_until "the forward child to go with it" 20 pid_gone "$forward_child_pid"
	grep -q "owner pid ${owner_pid} exited" "$STATE/forward.log"
}

# ─── The make-escaping bug this guard exists to catch ───────────────────────

@test "up rejects an owner pid that is not a live process" {
	# `$$` in a make recipe is make's escape for a literal '$' — the shell gets one
	# dollar character, not a pid. Passing that silently would make the supervisor
	# conclude its owner was already dead and tear the forward down seconds after
	# starting it, which is worse than the bug this change replaces.
	run env PF_UP_TIMEOUT=2 "$script" up "$STATE" registry zot 5001 5000 /v2/ '$'
	[ "$status" -ne 0 ]
	[[ "$output" == *'received [$]'* ]]

	local dead_pid
	sleep 0.1 &
	dead_pid=$!
	wait "$dead_pid" || true

	run env PF_UP_TIMEOUT=2 "$script" up "$STATE" registry zot 5001 5000 /v2/ "$dead_pid"
	[ "$status" -ne 0 ]
	[[ "$output" == *"received [${dead_pid}]"* ]]
}

# ─── Probe noise: the regression that made a healthy run look broken ────────

@test "polling a slow registry does not print curl connection errors" {
	# `up` probes once a second for up to 30s and `ensure` for up to 60s. With -S,
	# every one of those seconds printed
	#
	#   curl: (7) Failed to connect to localhost port 5001 after 0 ms
	#
	# which is the exact string CI emitted the day the forward genuinely died. A
	# reader cannot tell a slow zot from a dead one, and on a fresh cluster it
	# appears on every run — so a working build reads as a broken one. The inline
	# loop this script replaced suppressed it; losing that was a regression.
	#
	# This fake mirrors real curl's contract precisely: silent under -f -s, and
	# speaking only when -S is added. That is what makes the assertion honest — it
	# goes red the moment -S comes back or the stderr redirect is dropped, rather
	# than passing because the fake happens to be quiet.
	cat >"$CURL_BIN" <<-'FAKE'
		#!/usr/bin/env bash
		echo "curl $*" >>"$CALL_LOG"
		[ -e "$SERVING_MARKER" ] && exit 0
		case " $* " in
			*" -S "*|*-fsS*) echo "curl: (7) Failed to connect to localhost port 5001 after 0 ms" >&2 ;;
		esac
		exit 7
	FAKE
	chmod +x "$CURL_BIN"

	run env FAKE_KUBECTL_NEVER_SERVES=1 PF_UP_TIMEOUT=3 \
		"$script" up "$STATE" registry zot 5001 5000 /v2/ $$
	[ "$status" -ne 0 ]

	# What a reader SHOULD see: one message naming what to go and look at.
	[[ "$output" == *"registry/svc/zot"* ]]
	# What they should NOT see: the poll's own transport errors.
	[[ "$output" != *"curl: (7)"* ]]
}
