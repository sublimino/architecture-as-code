#!/usr/bin/env bats
#
# Offline tests for scripts/portal-egress-probe.sh, the live end-to-end check
# of security exemption SA-TODO-001 (public HTTPS egress for the portal pod).
#
# The probe runs against a cluster, so these tests replace the cluster client
# with a stub (PORTAL_EGRESS_KUBECTL). They pin argument handling, the verdict
# for each kind of probe result, and the exit codes. The important property is
# that a probe which could not run never reads as "blocked": a missing python,
# a failed exec, or a short result set must exit 3, not 0.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	probe="$repo_root/scripts/portal-egress-probe.sh"
	stub_dir="$BATS_TEST_TMPDIR/stub"
	mkdir -p "$stub_dir"
	export STUB_LOG="$stub_dir/calls.log"
	export STUB_RESULTS="$stub_dir/results.txt"
	export STUB_EXEC_RC=0
	export STUB_PORTAL_POD="fe-signalloom-abc-123"
	export STUB_BLOCKED_IP="10.244.0.99"
	: >"$STUB_LOG"

	cat >"$stub_dir/kube" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
	*" get pods "*"app.kubernetes.io/name=fe-signalloom"*)
		printf '%s' "$STUB_PORTAL_POD" ;;
	*" get pods "*"app.kubernetes.io/name=dashboard-signalloom"*)
		printf '%s' "$STUB_BLOCKED_IP" ;;
	*" exec "*)
		cat >/dev/null
		[ -f "$STUB_RESULTS" ] && cat "$STUB_RESULTS"
		exit "$STUB_EXEC_RC" ;;
	*)
		echo "stub: unexpected call: $*" >&2
		exit 99 ;;
esac
STUB
	chmod +x "$stub_dir/kube"
	export PORTAL_EGRESS_KUBECTL="$stub_dir/kube"
}

# All results as the in-pod helper prints them when the exemption works.
all_good() {
	cat >"$STUB_RESULTS" <<'EOF'
public api.anthropic.com:443 HTTP 404 160.79.104.10
public api.openai.com:443 HTTP 421 162.159.140.245
public claude.ai:443 HTTP 403 160.79.104.10
public anthropic.com:443 HTTP 301 160.79.104.10
blocked 10.244.0.99:443 TIMEOUT -
blocked 10.244.0.99:8080 TIMEOUT -
control signal-ingest:8082 CONNECTED 10.96.12.34
EOF
}

# Replace the result line for one target.
set_result() {
	local target="$1" line="$2"
	grep -v " $target " "$STUB_RESULTS" >"$STUB_RESULTS.tmp" || true
	printf '%s\n' "$line" >>"$STUB_RESULTS.tmp"
	mv "$STUB_RESULTS.tmp" "$STUB_RESULTS"
}

@test "--help prints usage and exits 0" {
	run "$probe" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage:"* ]]
	[[ "$output" == *"--context"* ]]
}

@test "no arguments is a usage error: --context is required" {
	run "$probe"
	[ "$status" -eq 2 ]
	[[ "$output" == *"--context is required"* ]]
}

@test "an unknown option is a usage error" {
	run "$probe" --context kind-osramp --bogus
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown option"* ]]
}

@test "--context without a value is a usage error" {
	run "$probe" --context
	[ "$status" -eq 2 ]
}

@test "--timeout must be a positive integer" {
	run "$probe" --context kind-osramp --timeout abc
	[ "$status" -eq 2 ]
	run "$probe" --context kind-osramp --timeout 0
	[ "$status" -eq 2 ]
}

@test "all reachable, blocked, and control results pass with exit 0" {
	all_good
	run "$probe" --context kind-osramp
	echo "$output" >&2
	[ "$status" -eq 0 ]
	[ "$(grep -cE '^(public|blocked|control) +[^ ]+ +PASS ' <<<"$output")" -eq 7 ]
	[[ "$output" != *" FAIL "* ]]
	[[ "$output" == *"api.anthropic.com:443"*"HTTP 404"* ]]
	[[ "$output" == *"api.openai.com:443"*"HTTP 421"* ]]
}

@test "the probe targets the named context, namespace, pod, and container" {
	all_good
	run "$probe" --context kind-osramp
	[ "$status" -eq 0 ]
	grep -q -- '--context kind-osramp' "$STUB_LOG"
	grep -q -- '-n fe-signalloom' "$STUB_LOG"
	grep -q -- "exec -i $STUB_PORTAL_POD -c discovery-portal" "$STUB_LOG"
	# Every call carries the context. A call without it would probe whatever
	# cluster the kubeconfig points at.
	[ "$(grep -vc -- '--context kind-osramp' "$STUB_LOG")" -eq 0 ]
}

@test "--namespace changes the namespace of every call" {
	all_good
	run "$probe" --context kind-osramp --namespace other-ns
	[ "$status" -eq 0 ]
	[ "$(grep -vc -- '-n other-ns' "$STUB_LOG")" -eq 0 ]
}

@test "a public provider that times out fails with exit 1" {
	all_good
	set_result "api.anthropic.com:443" "public api.anthropic.com:443 TIMEOUT -"
	run "$probe" --context kind-osramp
	[ "$status" -eq 1 ]
	[[ "$output" == *"api.anthropic.com:443"*"FAIL"* ]]
}

@test "a public provider that connects but returns no HTTP status fails" {
	all_good
	set_result "api.openai.com:443" "public api.openai.com:443 TLS_ERROR certificate-verify-failed"
	run "$probe" --context kind-osramp
	[ "$status" -eq 1 ]
}

@test "a REFUSED private target fails: the packet passed the policy" {
	# A NetworkPolicy drop is a timeout. A refusal means the SYN reached the
	# pod, so the private range is open.
	all_good
	set_result "10.244.0.99:443" "blocked 10.244.0.99:443 REFUSED -"
	run "$probe" --context kind-osramp
	[ "$status" -eq 1 ]
	[[ "$output" == *"10.244.0.99:443"*"FAIL"* ]]
}

@test "a CONNECTED private target fails" {
	all_good
	set_result "10.244.0.99:8080" "blocked 10.244.0.99:8080 CONNECTED 10.244.0.99"
	run "$probe" --context kind-osramp
	[ "$status" -eq 1 ]
}

@test "a control target that times out fails: pod networking is not proven" {
	all_good
	set_result "signal-ingest:8082" "control signal-ingest:8082 TIMEOUT -"
	run "$probe" --context kind-osramp
	[ "$status" -eq 1 ]
}

@test "a short result set exits 3, not 0" {
	all_good
	head -n 3 "$STUB_RESULTS" >"$STUB_RESULTS.tmp" && mv "$STUB_RESULTS.tmp" "$STUB_RESULTS"
	run "$probe" --context kind-osramp
	[ "$status" -eq 3 ]
	[[ "$output" == *"expected 7 results"* ]]
}

@test "a failed exec with no output exits 3, not 0" {
	rm -f "$STUB_RESULTS"
	export STUB_EXEC_RC=126
	run "$probe" --context kind-osramp
	[ "$status" -eq 3 ]
}

@test "a missing portal pod exits 3" {
	all_good
	export STUB_PORTAL_POD=""
	run "$probe" --context kind-osramp
	[ "$status" -eq 3 ]
	[[ "$output" == *"no running portal pod"* ]]
}

@test "a missing dashboard pod for the blocked target exits 3" {
	all_good
	export STUB_BLOCKED_IP=""
	run "$probe" --context kind-osramp
	[ "$status" -eq 3 ]
}

@test "--blocked-ip skips the dashboard lookup" {
	all_good
	sed 's/10\.244\.0\.99/10.244.7.7/' "$STUB_RESULTS" >"$STUB_RESULTS.tmp" && mv "$STUB_RESULTS.tmp" "$STUB_RESULTS"
	export STUB_BLOCKED_IP=""
	run "$probe" --context kind-osramp --blocked-ip 10.244.7.7
	echo "$output" >&2
	[ "$status" -eq 0 ]
	! grep -q 'dashboard-signalloom' "$STUB_LOG"
}

@test "--blocked-ip rejects a public address" {
	run "$probe" --context kind-osramp --blocked-ip 8.8.8.8
	[ "$status" -eq 2 ]
}
