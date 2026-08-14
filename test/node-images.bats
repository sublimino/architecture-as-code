#!/usr/bin/env bats
#
# scripts/check-node-images.sh — is every image the cluster actually references
# present on the kind node?
#
# Cluster-free by construction: `docker` and `kubectl` are fakes on PATH driven
# by state files, so this runs in stage 1 alongside the other guard suites.
#
# The two defects this pins, both found on a run where all 13 CI stages passed:
#
#   1. The expected set was a seven-element hardcoded list of OSRAMP/Olly
#      images. scripts/ci/vm-pipeline.sh deliberately skips the OSRAMP-demo
#      ResourceSets, so on a signalloom-only run all seven are absent BY
#      DESIGN — "7 image(s) missing" printed on every green run, naming
#      nothing, and pointing at `make images`, which would not have fixed it.
#      A warning that is unconditionally true is indistinguishable from one
#      that just became true; a lane agent read the constant as a variable and
#      built arithmetic on it during a genuinely failing run.
#
#   2. The match was `grep -q "${img%%:*}.*${img##*:}"` — repo-prefix then tag,
#      loosely, anywhere on a line. `crictl images` is columnar, so a repo from
#      one column could satisfy the name while a TAG, IMAGE ID or SIZE from
#      another satisfied the tag. That is a false PASS, which is the worst
#      direction for a check to fail in.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/check-node-images.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	# `<repo> <tag> <digest>` per line — what the fake node reports via crictl.
	export CRICTL_STATE="$BATS_TEST_TMPDIR/crictl-images"
	# `<namespace> <pod> <phase> <image>` per line — what the fake cluster runs.
	export WORKLOAD_STATE="$BATS_TEST_TMPDIR/workloads"
	export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$CRICTL_STATE"
	: >"$WORKLOAD_STATE"
	: >"$CALL_LOG"

	cat >"$bin/docker" <<-'FAKE'
		#!/usr/bin/env bash
		echo "docker $*" >>"$CALL_LOG"
		[ "${DOCKER_EXEC_STATUS:-0}" = "0" ] || exit "$DOCKER_EXEC_STATUS"
		# Real crictl pads into columns; the width must not matter to the caller.
		# The IMAGE ID and SIZE values mirror the live osramp node, where
		# postgres 16-alpine is 116MB with ID de3a4eab8fdfa. Those two columns
		# are what let a loose whole-line regex satisfy a tag it never saw, so a
		# fake that emits inert values would let the old matcher pass this suite.
		printf '%-60s %-20s %-20s %-20s %s\n' IMAGE TAG DIGEST 'IMAGE ID' SIZE
		while read -r repo tag digest; do
		  [ -n "$repo" ] || continue
		  printf '%-60s %-20s %-20s %-20s %s\n' "$repo" "$tag" "$digest" abc123def4567 116MB
		done <"$CRICTL_STATE"
	FAKE

	cat >"$bin/kubectl" <<-'FAKE'
		#!/usr/bin/env bash
		echo "kubectl $*" >>"$CALL_LOG"
		[ "${KUBECTL_STATUS:-0}" = "0" ] || exit "$KUBECTL_STATUS"
		cat "$WORKLOAD_STATE"
	FAKE

	chmod +x "$bin/docker" "$bin/kubectl"
	export PATH="$bin:$PATH"
	export DOCKER_BIN="$bin/docker"
	export KUBECTL_BIN="$bin/kubectl"
	export KIND_NODE="osramp-control-plane"
}

# ── Defect 1: the expected set is the profile, not a constant ────────────────

@test "an image nothing deploys is not expected, however buildable it is" {
	# The signalloom profile: vm-pipeline.sh skips the OSRAMP-demo ResourceSets,
	# so listener/processor/olly-* are absent by design on every run of it.
	cat >"$WORKLOAD_STATE" <<-'EOF'
		fe-signalloom dashboard-abc Running netassert-controller:dev
		inf-signalloom dex-xyz Running ghcr.io/dexidp/dex:v2.41.1
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/netassert-controller dev sha256deadbeef
		ghcr.io/dexidp/dex v2.41.1 sha256cafebabe
	EOF

	run "$script"
	[ "$status" -eq 0 ]
	# The seven that used to be counted unconditionally
	refute_output_contains "listener"
	refute_output_contains "olly-sentinel"
	refute_output_contains "missing"
}

@test "the headline names the node and the derivation, never a bare count" {
	cat >"$WORKLOAD_STATE" <<-'EOF'
		fe-signalloom dashboard-abc Running netassert-controller:dev
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/netassert-controller dev sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 0 ]
	# "7 image(s) missing" with no statement of what was expected was the defect.
	echo "$output" | head -1 | grep -q 'referenced by'
	echo "$output" | head -1 | grep -q 'osramp-control-plane'
}

@test "an image the profile DOES expect is reported absent, by name" {
	cat >"$WORKLOAD_STATE" <<-'EOF'
		fe-signalloom dashboard-abc Running netassert-controller:dev
		fe-signalloom proxy-def Pending fake-integration-proxy:dev
	EOF
	# Only one of the two was ever loaded.
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/netassert-controller dev sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q 'fake-integration-proxy:dev'
	# and it says WHICH workload wants it, so the reader has somewhere to go
	echo "$output" | grep -q 'fe-signalloom/proxy-def'
	refute_output_contains "netassert-controller"
}

# ── Defect 2: columns, not a loose regex ────────────────────────────────────

@test "a tag that only prefix-matches another tag is absent, not present" {
	# `grep -q "postgres.*16"` matches the row `postgres 16-alpine`.
	# Verified against the live osramp node, where this exact pair exists.
	cat >"$WORKLOAD_STATE" <<-'EOF'
		backend db-1 Running postgres:16
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/postgres 16-alpine sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q 'postgres:16'
}

@test "a tag satisfied only by the SIZE column is absent, not present" {
	# `grep -q "postgres.*116"` matches the row's SIZE of 116MB. The name comes
	# from column 1 and the tag from column 5 — an image that is not on the node
	# reported as present, purely by reading across columns.
	cat >"$WORKLOAD_STATE" <<-'EOF'
		backend db-1 Running postgres:116
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/postgres 16-alpine sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q 'postgres:116'
}

@test "a tag satisfied only by the IMAGE ID column is absent, not present" {
	# The fake reports IMAGE ID abc123def4567 for every row, mirroring the real
	# node's hex IDs. `grep -q "redis.*abc"` would match; columns cannot.
	cat >"$WORKLOAD_STATE" <<-'EOF'
		backend cache-1 Running redis:abc
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/redis 7-alpine sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q 'redis:abc'
}

@test "a bare reference is matched as docker.io/library, as crictl reports it" {
	cat >"$WORKLOAD_STATE" <<-'EOF'
		fe-signalloom runner-1 Running supercred-demo-runner:local
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/supercred-demo-runner local sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 0 ]
}

@test "a docker.io user image is matched without the library/ infix" {
	cat >"$WORKLOAD_STATE" <<-'EOF'
		inf-signalloom minio-1 Running minio/minio:latest
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/minio/minio latest sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 0 ]
}

@test "a digest-pinned reference matches on the digest, which crictl untags" {
	# Flux pins by digest. crictl reports TAG as <none> for those, so a tag
	# comparison alone reports four healthy controllers as missing.
	cat >"$WORKLOAD_STATE" <<-'EOF'
		flux-system source-controller-1 Running ghcr.io/fluxcd/source-controller:v1.9.4@sha256:8a8ed0a57b8b86f561d5a4309a69f65e62f0cebe4de8801593c5ff35a3bc3c23
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		ghcr.io/fluxcd/source-controller <none> 8a8ed0a57b8b8
	EOF

	run "$script"
	[ "$status" -eq 0 ]
}

@test "a digest-pinned reference whose digest is NOT on the node is absent" {
	cat >"$WORKLOAD_STATE" <<-'EOF'
		flux-system source-controller-1 Running ghcr.io/fluxcd/source-controller:v1.9.4@sha256:8a8ed0a57b8b86f561d5a4309a69f65e62f0cebe4de8801593c5ff35a3bc3c23
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		ghcr.io/fluxcd/source-controller <none> 0000000000000
	EOF

	run "$script"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q 'source-controller'
}

# ── Cannot pass, or fail, vacuously ─────────────────────────────────────────

@test "an unreadable node listing is indeterminate, not everything-missing" {
	# The old check swallowed the docker failure with `|| true` and then compared
	# every image against an empty string, reporting all seven missing on any
	# cluster that is not a local kind node.
	cat >"$WORKLOAD_STATE" <<-'EOF'
		fe-signalloom dashboard-abc Running netassert-controller:dev
	EOF
	export DOCKER_EXEC_STATUS=1

	run "$script"
	[ "$status" -eq 3 ]
	echo "$output" | grep -qi 'cannot read'
	refute_output_contains "absent"
}

@test "no workloads at all is indeterminate, not a confident pass" {
	# A renamed field or a broken template would otherwise produce an empty
	# expected set and a green light for a cluster nobody looked at.
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/netassert-controller dev sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 3 ]
	echo "$output" | grep -qi 'no workload'
}

# ── The diagnostic stays read-only ──────────────────────────────────────────

@test "reads the cluster and never writes to it" {
	cat >"$WORKLOAD_STATE" <<-'EOF'
		fe-signalloom dashboard-abc Running netassert-controller:dev
	EOF
	cat >"$CRICTL_STATE" <<-'EOF'
		docker.io/library/netassert-controller dev sha256deadbeef
	EOF

	run "$script"
	[ "$status" -eq 0 ]
	# `make doctor` is a read-only diagnostic; a repair here would surprise
	# someone mid-debug.
	run grep -cE 'kubectl (apply|patch|delete|create|edit|replace|scale|label|annotate)' "$CALL_LOG"
	[ "$output" = "0" ]
}

@test "doctor.sh delegates to this script rather than carrying its own list" {
	doctor="$BATS_TEST_DIRNAME/../scripts/doctor.sh"
	grep -Fq 'check-node-images.sh' "$doctor"
	# The seven-element constant must be gone, not merely bypassed.
	run grep -Fc 'olly-tenant-app:dev' "$doctor"
	[ "$output" = "0" ]
}

refute_output_contains() {
	if echo "$output" | grep -Fq "$1"; then
		echo "expected output NOT to contain '$1', but it did:" >&2
		echo "$output" >&2
		return 1
	fi
}
