#!/usr/bin/env bats
#
# The three optional knobs scripts/supervise-port-forward.sh grew for the GCP
# demo Gateway forward: PF_ADDRESS, PF_PROBE_URL and PF_PROBE_CURL_OPTS.
#
# Separate from test/supervise-port-forward.bats, which owns the supervisor
# lifecycle — respawn, owner death, teardown, restart accounting — and is run by
# scripts/ci/vm-pipeline.sh's stage 1g. This file owns only the knobs, so the
# two can be read and changed independently.
#
# WHY THESE NEED A TEST AT ALL. test/gcp-demo-pipeline.bats asserts that
# demo-pipeline.sh EXPORTS PF_ADDRESS=0.0.0.0 and the right probe URL, but it
# does so against a stub supervisor — it cannot say whether the real script
# does anything with them. Asserting the caller and never the callee is how a
# correctly-configured integration reaches production doing nothing, and it is
# indistinguishable from a working one until an operator cannot reach the demo.
#
# The DEFAULT case is tested first and hardest. Every existing caller — the
# Makefile recipes that publish images to Zot — passes none of these, and a
# change advertised as backwards compatible that quietly starts passing
# `--address ''` to kubectl would break all of them.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/supervise-port-forward.sh"
	[ -f "$script" ]

	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"
	STATE="$BATS_TEST_TMPDIR/state"

	export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$CALL_LOG"

	# The forward fake records its full argument vector and then blocks, because
	# a `kubectl port-forward` that returns immediately is not a port-forward and
	# the supervisor would respawn it in a tight loop.
	cat >"$bin/kubectl" <<-'FAKE'
		#!/usr/bin/env bash
		echo "kubectl $*" >>"$CALL_LOG"
		for _ in $(seq 1 300); do sleep 0.2; done
	FAKE

	# The probe fake records the full curl argument vector — which is the only
	# place PF_PROBE_URL and PF_PROBE_CURL_OPTS become observable — and always
	# succeeds, so `up` returns without waiting out its 30s budget.
	cat >"$bin/curl" <<-'FAKE'
		#!/usr/bin/env bash
		echo "curl $*" >>"$CALL_LOG"
		exit 0
	FAKE

	chmod +x "$bin/kubectl" "$bin/curl"
	export PATH="$bin:$PATH"
	export KUBECTL_BIN="$bin/kubectl"
	export CURL_BIN="$bin/curl"
	export PF_POLL_INTERVAL=1
	export PF_PROBE_TIMEOUT=1
	export PF_KILL_TIMEOUT=2
}

teardown() {
	# PID-file only. Pattern-matching processes from inside a wrapped shell is
	# how this repo has self-killed the calling shell before.
	local pid_file pid
	for pid_file in "$STATE/supervisor.pid" "$STATE/forward.pid"; do
		[ -f "$pid_file" ] || continue
		pid="$(cat "$pid_file" 2>/dev/null || true)"
		[ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
	done
	return 0
}

bring_up() {
	# Owner is this bats process, which is alive for the duration of the test.
	run bash "$script" up "$STATE" "$@" "$$"
	[ "$status" -eq 0 ]
}

kubectl_line() {
	grep -m1 '^kubectl ' "$CALL_LOG"
}

curl_line() {
	grep -m1 '^curl ' "$CALL_LOG"
}

# ═══ The default: byte-for-byte the previous behaviour ═══════════════════════

@test "PFKNOBS with no knobs set the kubectl argv is unchanged" {
	bring_up zot-system zot 5001 5000 /v2/

	# Exactly the original vector. Notably NO --address: an empty PF_ADDRESS must
	# not become `--address ''`, which kubectl rejects.
	[ "$(kubectl_line)" = "kubectl -n zot-system port-forward svc/zot 5001:5000" ]
	run grep -c -- '--address' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

@test "PFKNOBS with no knobs set the probe URL is the localhost default" {
	bring_up zot-system zot 5001 5000 /v2/
	[[ "$(curl_line)" == *"http://localhost:5001/v2/"* ]]
	# And no stray options were injected.
	run grep -c -- '--resolve' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

# ═══ PF_ADDRESS ══════════════════════════════════════════════════════════════

@test "PFKNOBS PF_ADDRESS puts --address on the kubectl argv" {
	# The operator reaches the demo over a Google IAP tunnel, which connects to
	# the instance's INTERNAL IP. kubectl binds loopback by default, so without
	# this the published demo is reachable only from a shell already on the VM.
	PF_ADDRESS=0.0.0.0 bring_up ingress cluster-envoy 30754 443 /livez
	[ "$(kubectl_line)" = "kubectl -n ingress port-forward --address 0.0.0.0 svc/cluster-envoy 30754:443" ]
}

@test "PFKNOBS PF_ADDRESS survives into the persisted config, not just the first spawn" {
	# The supervisor is a background grandchild and respawns the forward on every
	# probe failure. A knob that lived only in the calling shell's environment
	# would apply to the first spawn and silently revert to loopback on every
	# repair — a demo that works until the first network blip.
	PF_ADDRESS=0.0.0.0 bring_up ingress cluster-envoy 30754 443 /livez
	[ -f "$STATE/config.env" ]
	grep -q "^PF_ADDRESS=0.0.0.0$" "$STATE/config.env"
}

# ═══ PF_PROBE_URL and PF_PROBE_CURL_OPTS ═════════════════════════════════════

@test "PFKNOBS PF_PROBE_URL and PF_PROBE_CURL_OPTS reach curl" {
	# The Gateway speaks TLS on 443 and selects its route by SNI, so its health
	# cannot be expressed as a path on a plaintext localhost URL. -k because the
	# demo certificate is self-signed; --resolve because the SNI name has no DNS
	# record by design.
	PF_ADDRESS=0.0.0.0 \
	PF_PROBE_URL="https://dashboard.osramp.acme.local:30754/livez" \
	PF_PROBE_CURL_OPTS="-k --resolve dashboard.osramp.acme.local:30754:127.0.0.1" \
		bring_up ingress cluster-envoy 30754 443 /livez

	local line
	line="$(curl_line)"
	[[ "$line" == *"-k"* ]]
	[[ "$line" == *"--resolve dashboard.osramp.acme.local:30754:127.0.0.1"* ]]
	[[ "$line" == *"https://dashboard.osramp.acme.local:30754/livez"* ]]
	# The default endpoint must NOT also have been probed — an override that
	# appends rather than replaces would leave the supervisor healthy on a URL
	# nothing serves.
	run grep -c 'http://localhost:30754' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

@test "PFKNOBS the overridden endpoint is what the success message names" {
	# Every report on this forward routes through state_endpoint. A caller that
	# overrides the probe and is then told about a localhost URL nothing ever
	# contacted has been handed a diagnostic that points at the wrong thing.
	PF_PROBE_URL="https://dashboard.osramp.acme.local:30754/livez" \
	PF_PROBE_CURL_OPTS="-k" \
		run bash "$script" up "$STATE" ingress cluster-envoy 30754 443 /livez "$$"
	[ "$status" -eq 0 ]
	[[ "$output" == *"https://dashboard.osramp.acme.local:30754/livez"* ]]
}

@test "PFKNOBS MUTATION dropping the PF_ADDRESS expansion loses the bind address" {
	# The paired positive. Without it, the PF_ADDRESS tests above cannot tell a
	# working expansion from a fake kubectl that would have logged anything.
	local mutant="$BATS_TEST_TMPDIR/mutant.sh"
	sed 's|^    ${address_args\[@\]+"${address_args\[@\]}"} \\$|    \\|' "$script" >"$mutant"
	chmod +x "$mutant"
	# The mutation landed where it was aimed: the expansion is gone from the
	# mutant and was present in the original. Both directions are asserted,
	# because a sed that matched nothing would leave the mutant identical to the
	# real script and the test below would then be measuring the real script.
	run grep -c 'address_args\[@\]+' "$script"
	[ "$output" -eq 1 ]
	run grep -c 'address_args\[@\]+' "$mutant"
	[ "$output" -eq 0 ]

	PF_ADDRESS=0.0.0.0 run bash "$mutant" up "$STATE" ingress cluster-envoy 30754 443 /livez "$$"
	[ "$status" -eq 0 ]
	run grep -c -- '--address' "$CALL_LOG"
	[ "$output" -eq 0 ]
}
