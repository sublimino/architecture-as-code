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
	# A `go` that records itself and fails: the dry run must never build or
	# run cmd/resume-token, and a real toolchain on PATH would hide that.
	cat >"${BATS_TEST_TMPDIR}/bin/go" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/go-argv"
exit 1
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/go"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
	export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}"
	# A pinned keys dir so the operator-key paths the dry run renders are
	# deterministic and never the shared checkout's.
	export KEYS_DIR="${BATS_TEST_TMPDIR}/keys"
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

@test "lab: a dry run passes all thirteen steps and mutates nothing" {
	# Thirteen since OSD-8 added step 3b, the APPLIANCE_MODE=attached gate,
	# between the Secret apply and the DNS splice.
	dry
	[ "$status" -eq 0 ]
	[[ "$output" == *"VERDICT: PASS (13/13 passed)"* ]]
	# No kubectl and no go at all under --dry-run: every call is printed.
	[ ! -s "${STATE}/argv" ]
	[ ! -e "${STATE}/go-argv" ]
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
		"6 report" "7 stun" "8 stun ack" "9 resume" "9b replay" "10 resume ack"; do
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
	#
	# Written as plain `run` + an explicit exact-status check, rather than the
	# equivalent `run !` negation flag: grep's exit codes are 0 found / 1
	# not-found / 2 error, and -eq 1 is what "never creates or deletes" means --
	# a script-read error (2) proves nothing about the script's content.
	run grep -E 'kind (create|delete) cluster' "${SCRIPT}"
	[ "$status" -eq 1 ]
	run grep -E 'kubectl.*delete (ns|namespace)' "${SCRIPT}"
	[ "$status" -eq 1 ]
}

# --- the governed resume (steps 2, 9 and 9b) --------------------------------

@test "lab: step 2 ensures the operator keys on the hub, before the overlay is applied" {
	dry
	[ "$status" -eq 0 ]
	local keys_line overlay_line
	keys_line="$(grep -n 'fleet-operator-keys.sh --context kind-osramp' <<<"$output" | head -1 | cut -d: -f1)"
	overlay_line="$(grep -n 'DRY-RUN apply overlay' <<<"$output" | head -1 | cut -d: -f1)"
	[ -n "${keys_line}" ]
	[ -n "${overlay_line}" ]
	[ "${keys_line}" -lt "${overlay_line}" ]
	[[ "$output" == *"operator keys alice bob in place"* ]]
}

@test "lab: step 9 mints for the registry target in the remote namespace, for the hub's audience and trust root" {
	dry
	[ "$status" -eq 0 ]
	local mint
	mint="$(grep 'DRY-RUN resume-token mint:' <<<"$output" | head -1)"
	[ -n "${mint}" ]
	# The agent is the registry pod name exactly as the hub lists it.
	[[ "${mint}" == *"--agent <first registry pod>"* ]]
	[[ "${mint}" == *"--namespace fe-signalloom-agents"* ]]
	[[ "${mint}" == *"--audience signalloom-fleet/local"* ]]
	[[ "${mint}" == *"--trust-root signalloom-operators-v1"* ]]
	[[ "${mint}" == *"--approval remote-tenant-lab"* ]]
	[[ "${mint}" == *"--lifetime 10m"* ]]
	[[ "${mint}" == *"--required-signatures 2"* ]]
	# The live run READS both from the Deployment; the dry run says what it assumed.
	[[ "$output" == *"read FLEET_AUDIENCE and OPERATOR_TRUST_ROOT_ID from deploy/fleet-manager on kind-osramp"* ]]
}

@test "lab: step 9 signs with both operator keys from keys_dir, by file path, then builds the request body" {
	dry
	[ "$status" -eq 0 ]
	local opdir="${KEYS_DIR}/fleet-operators"
	[[ "$output" == *"resume-token sign alice: "*"--operator spiffe://signalloom.demo/operator/alice --key ${opdir}/alice.key"* ]]
	[[ "$output" == *"resume-token sign bob: "*"--operator spiffe://signalloom.demo/operator/bob --key ${opdir}/bob.key"* ]]
	[[ "$output" == *"resume-token request: "*"--token "*"/resume-token.json --out "*"/resume-request.json"* ]]
	# mint, then both signatures, then request, then the POST: in that order.
	local m s1 s2 r p
	m="$(grep -n 'resume-token mint:' <<<"$output" | head -1 | cut -d: -f1)"
	s1="$(grep -n 'resume-token sign alice:' <<<"$output" | head -1 | cut -d: -f1)"
	s2="$(grep -n 'resume-token sign bob:' <<<"$output" | head -1 | cut -d: -f1)"
	r="$(grep -n 'resume-token request:' <<<"$output" | head -1 | cut -d: -f1)"
	p="$(grep -n 'POST /api/v1/fleet/resume/<first registry pod> with the signed request body' <<<"$output" | head -1 | cut -d: -f1)"
	[ -n "$m" ] && [ -n "$s1" ] && [ -n "$s2" ] && [ -n "$r" ] && [ -n "$p" ]
	[ "$m" -lt "$s1" ] && [ "$s1" -lt "$s2" ] && [ "$s2" -lt "$r" ] && [ "$r" -lt "$p" ]
}

@test "lab: step 9b replays the consumed token under a new idempotency key and expects 409" {
	dry
	[ "$status" -eq 0 ]
	[[ "$output" == *"same token and a new idempotency_key, expect 409"* ]]
	local nine nineb ten
	nine="$(grep -n '^PASS  *9 resume ' <<<"$output" | head -1 | cut -d: -f1)"
	nineb="$(grep -n '^PASS  *9b replay ' <<<"$output" | head -1 | cut -d: -f1)"
	ten="$(grep -n '^PASS  *10 resume ack ' <<<"$output" | head -1 | cut -d: -f1)"
	[ "$nine" -lt "$nineb" ] && [ "$nineb" -lt "$ten" ]
	# The live path asserts the status code, and 409 only: a 4xx of any other
	# kind is a broken request, not a working replay ledger.
	grep -q '\[ "\$code" = "409" \]' "${SCRIPT}"
}

@test "lab: the token and the request body are posted from files, never from argv" {
	# `--data "@file"`: a signed token in argv would sit in /proc for the life
	# of the call, same as a bearer.
	grep -q -- '--data "@\$datafile"' "${SCRIPT}"
	# Both resume POSTs, step 9 and the 9b replay, go through fm_file.
	[ "$(grep -c 'fm_file POST "/api/v1/fleet/resume/\$TARGET"' "${SCRIPT}")" -eq 2 ]
}
