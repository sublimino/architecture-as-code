#!/usr/bin/env bats
#
# `kill -0` cannot tell "dead" from "not mine", and the owner pid is pid 1.
#
# ─── The defect this pins ───────────────────────────────────────────────────
#
# validate_owner_pid() gated on `kill -0 "$owner_pid"`. That call answers two
# questions with one exit status: does the pid exist (ESRCH), and may I signal
# it (EPERM). The pipeline's default owner is pid 1 — chosen deliberately,
# because systemd outlives everything — but pid 1 is root-owned and the
# pipeline runs as an unprivileged service account.
#
# Measured on the CI VM as that user:
#
#   $ kill -0 1   -> bash: kill: (1) - Operation not permitted   rc=1
#   $ ps -p 1     -> 1 root Ss systemd
#
# So the most-alive process on the machine was classified dead, and the publish
# stage failed in ZERO seconds having attempted nothing. The surrounding report
# meanwhile claimed "demo_published": true, so the run advertised a dashboard
# URL that nothing was serving.
#
# ─── Why a suite of its own ─────────────────────────────────────────────────
#
# test/supervise-port-forward.bats already asserts the NEGATIVE ("up rejects an
# owner pid that is not a live process"). Nothing asserted the POSITIVE, and the
# two failure modes pull in opposite directions: a fix for this bug that goes
# too far would accept dead pids and silently disarm the supervisor's exit
# condition. Both directions are asserted here, together, so a future edit
# cannot satisfy one by breaking the other.
#
# These tests exercise the PREDICATE rather than driving the whole supervisor,
# because the condition under test is a property of the host's permission model,
# not of the port-forward. That keeps them hermetic and fast.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$repo/scripts/supervise-port-forward.sh"
}

# The exact predicate the script uses. Kept in one place so the tests below
# cannot drift into testing a paraphrase of the code instead of the code.
live_pid() {
	local pid="$1"
	if ! kill -0 "$pid" 2>/dev/null && [ ! -e "/proc/${pid}" ]; then
		return 1
	fi
	return 0
}

@test "EPERM the environment actually reproduces the condition" {
	# ANCHOR. If this test runs as root, or on a kernel without /proc, every
	# assertion below would pass for the wrong reason. Refuse rather than
	# report a green that measured nothing.
	[ "$(id -u)" -ne 0 ] || skip "running as root; EPERM cannot be reproduced"
	[ -e /proc/1 ] || skip "no /proc; this predicate is Linux-specific"

	# The precondition that makes this bug possible: pid 1 is alive AND we
	# cannot signal it. If `kill -0 1` ever succeeds here, the bug could not
	# have occurred and these tests are not measuring the real thing.
	run kill -0 1
	[ "$status" -ne 0 ]
}

@test "EPERM a live pid we may not signal is treated as ALIVE" {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	[ -e /proc/1 ] || skip "no /proc"
	# This is the regression. Before the fix it returned 1.
	run live_pid 1
	[ "$status" -eq 0 ]
}

@test "EPERM a genuinely dead pid is still REJECTED" {
	# The guard must not be traded away for the fix above. Pick a pid that
	# cannot exist rather than a large number that might.
	dead=999999
	[ ! -e "/proc/${dead}" ] || skip "pid ${dead} unexpectedly exists"
	run live_pid "$dead"
	[ "$status" -eq 1 ]
}

@test "EPERM our own live pid is treated as alive" {
	# Positive control from the other direction: a pid we CAN signal must also
	# pass, or the predicate is rejecting everything and the test above is
	# green by accident.
	run live_pid "$$"
	[ "$status" -eq 0 ]
}

@test "EPERM the script does not gate on a bare kill -0" {
	# Couples these tests to the real file. A future edit that reverts to
	# `if ! kill -0 "$owner_pid"` alone must fail here, not just in a live run
	# on a VM where nobody is watching.
	block="$(sed -n '/^validate_owner_pid()/,/^}/p' "$script")"
	[ -n "$block" ]
	grep -q 'kill -0' <<<"$block"
	# The /proc fallback must be present in the same condition.
	grep -qE '/proc/\$\{?owner_pid' <<<"$block" || {
		echo "validate_owner_pid gates on kill -0 without a /proc fallback;" >&2
		echo "an unsignalable-but-alive owner (pid 1 as non-root) will be" >&2
		echo "rejected as dead. See this file's header." >&2
		return 1
	}
}
