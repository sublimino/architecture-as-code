#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      remote-tenant-lab
# @target  scripts/remote-tenant-lab.sh
# @doc     docs/EAP/secondary-cluster.md
# @spec    docs/EAP/remote-contract.md
#
# The lab script's own contract, with no cluster: argument handling, the step
# list, the addressing it derives, and the pass/fail table. The lead runs the
# live chain.
#
# Two things are deliberately NOT asserted here, because only live clusters can
# answer them: that the warden actually reports, and that a stun is actually
# acknowledged. Those are rows 6 to 10 of the table the script prints.

bats_require_minimum_version 1.5.0

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	SCRIPT="${REPO_ROOT}/scripts/remote-tenant-lab.sh"
	export KUBECONFIG=/dev/null
	STATE="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
	# A kubectl that records argv and succeeds. Only the dry-run paths are
	# exercised, so it is never asked for data, but a real binary on PATH would
	# be: --dry-run must not reach a cluster even by accident.
	cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
	export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}"
}

dry() { run bash "${SCRIPT}" --dry-run "$@"; }

@test "lab: the script is executable and parses" {
	[ -x "${SCRIPT}" ]
	run bash -n "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "lab: --help exits 0, prints the usage block, and touches no cluster" {
	run bash "${SCRIPT}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--hub-context"* ]]
	[[ "$output" == *"--remote-context"* ]]
	[[ "$output" == *"--dry-run"* ]]
	[ ! -s "${STATE}/argv" ]
}

@test "lab: an unknown argument is exit 2 and names itself" {
	run bash "${SCRIPT}" --not-a-flag
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument: --not-a-flag"* ]]
}

@test "lab: every option that takes a value rejects an empty one (exit 2)" {
	local f
	for f in --hub-context --remote-context --cluster-id --timeout; do
		run bash "${SCRIPT}" --dry-run "$f" ""
		[ "$status" -eq 2 ]
	done
}

@test "lab: a non-numeric timeout is exit 2, not a wait that never ends" {
	run bash "${SCRIPT}" --dry-run --timeout 3m
	[ "$status" -eq 2 ]
	[[ "$output" == *"whole number of seconds"* ]]
}

@test "lab: the same context for hub and remote is exit 2" {
	# One cluster cannot be both ends of a cross-cluster proof, and the symptom
	# of trying is a confusing pass.
	run bash "${SCRIPT}" --dry-run --hub-context kind-osramp --remote-context kind-osramp
	[ "$status" -eq 2 ]
	[[ "$output" == *"must differ"* ]]
}

@test "lab: a dry run passes all ten steps and mutates nothing" {
	dry
	[ "$status" -eq 0 ]
	[[ "$output" == *"VERDICT: PASS (10/10 passed)"* ]]
	# No kubectl at all under --dry-run: every call is printed instead.
	[ ! -s "${STATE}/argv" ]
}

@test "lab: the table names every step of the remote contract, in order" {
	dry
	[ "$status" -eq 0 ]
	# Order is asserted by first-occurrence line number rather than by joining
	# the STEP column: print_table pads that column to the widest name, so its
	# width moves whenever a step is renamed and an exact compare of the joined
	# column would fail on formatting instead of on order.
	local s prev=0 line
	for s in "1 preflight" "2 keys" "3 secrets" "4 dns" "5 overlay" \
		"6 report" "7 stun" "8 stun ack" "9 resume" "10 resume ack"; do
		line="$(grep -n "^PASS  *${s} " <<<"$output" | head -1 | cut -d: -f1)"
		[ -n "${line}" ]
		[ "${line}" -gt "${prev}" ]
		prev="${line}"
	done
}

@test "lab: the dry run names the two clusters and the hub URL it derived" {
	dry
	[ "$status" -eq 0 ]
	[[ "$output" == *"hub kind-osramp"* ]]
	[[ "$output" == *"remote kind-signalloom-hub"* ]]
	# The NodePort is in the default URL because the warden's own URL carries
	# no port and the lab gateway is not on 443.
	[[ "$output" == *"https://dashboard.osramp.acme.local:30476"* ]]
}

@test "lab: --hub-url overrides the derived URL for both prefixes" {
	dry --hub-url https://hub.example.test
	[ "$status" -eq 0 ]
	[[ "$output" == *"https://hub.example.test/warden-ingest"* ]]
	[[ "$output" == *"https://hub.example.test/warden-fleet"* ]]
	[[ "$output" != *"30476/warden-ingest"* ]]
}

@test "lab: --cluster-id reaches both the DaemonSet env and the registry query" {
	dry --cluster-id pilot-七 --cluster-id pilot-x
	[ "$status" -eq 0 ]
	[[ "$output" == *"SIGNAL_CLUSTER_ID=pilot-x"* ]]
	[[ "$output" == *"cluster id pilot-x"* ]]
}

@test "lab: it applies the dev overlay, never the pilot one" {
	# remote-tenant-dev skips certificate verification. Applying it to a pilot
	# cluster is the mistake this assertion exists to catch early.
	dry
	[ "$status" -eq 0 ]
	[[ "$output" == *"signalloom-warden-overlays/remote-tenant-dev"* ]]
	[[ "$output" != *"apply -k"*"/remote-tenant "* ]]
}

@test "lab: the Secrets are applied BEFORE the overlay" {
	# The remote-tenant key refs are not optional, so a DaemonSet created first
	# waits in ContainerCreating. Order is the fix, not a longer timeout.
	dry
	[ "$status" -eq 0 ]
	local secret_line overlay_line
	secret_line="$(grep -n 'remote secret signalloom-warden-fleet-key' <<<"$output" | head -1 | cut -d: -f1)"
	overlay_line="$(grep -n 'DRY-RUN apply overlay' <<<"$output" | head -1 | cut -d: -f1)"
	[ -n "${secret_line}" ]
	[ -n "${overlay_line}" ]
	[ "${secret_line}" -lt "${overlay_line}" ]
}

@test "lab: the transfer directory is created 0700 and removed unless --keep" {
	local dir="${BATS_TEST_TMPDIR}/transfer"
	dry --transfer-dir "${dir}"
	[ "$status" -eq 0 ]
	# Removed on exit: the files hold key material in clear base64.
	[ ! -d "${dir}" ]
	dry --transfer-dir "${dir}" --keep
	[ "$status" -eq 0 ]
	[ -d "${dir}" ]
	[ "$(stat -c '%a' "${dir}")" = "700" ]
}

@test "lab: no bearer token ever appears in a rendered command" {
	# Every fleet call reads its Authorization header from stdin (-H @-). A
	# bearer in argv is readable from /proc for the life of the call.
	run grep -n 'Authorization: Bearer' "${SCRIPT}"
	[ "$status" -eq 0 ]
	# Each occurrence must be a printf piped into curl, never a -H "..." literal.
	run ! grep -E -- '-H *"Authorization: Bearer' "${SCRIPT}"
	run grep -c -- '-H @-' "${SCRIPT}"
	[ "$output" -ge 2 ]
}

@test "lab: the port-forward child is detached and torn down by pid, not by pattern" {
	# setsid plus all three fds, or the child keeps writing into the caller's
	# output stream and dies with the session. And never pkill a pattern that
	# appears in this script's own command line.
	run grep -q 'setsid .*port-forward' "${SCRIPT}"
	[ "$status" -eq 0 ]
	run grep -q '</dev/null >/dev/null 2>&1 &' "${SCRIPT}"
	[ "$status" -eq 0 ]
	# Comment lines are stripped first: the script names pkill in the comment
	# that explains why it does not call it, and a bare grep cannot tell a
	# warning from the thing it warns about.
	run ! grep -E '^[^#]*(pkill|pgrep)' "${SCRIPT}"
}

@test "lab: it never creates or deletes a cluster" {
	# This script attaches to the topology dual-cluster-up.sh built. A lab that
	# can delete a cluster is a lab somebody runs by accident.
	run ! grep -E 'kind (create|delete) cluster' "${SCRIPT}"
	run ! grep -E 'kubectl.*delete (ns|namespace)' "${SCRIPT}"
}
