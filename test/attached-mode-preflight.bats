#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      attached-mode-preflight
# @target  scripts/attached-mode-preflight.sh
# @doc     docs/attached-mode-central-issuance.md
# @spec    docs/EAP/remote-contract.md
#
# The contract of the APPLIANCE_MODE=attached preflight (OSD-8).
#
# `attached` mode renders the remote-tenant overlay, whose two key refs are
# `optional: false`. Both Secrets are minted on the VENDOR's central cluster and
# are documented as never issued locally, so a design partner who selects
# `attached` without them gets a DaemonSet stuck in ContainerCreating and no
# error that names the cause. These tests pin the early, named failure.
#
# No cluster is touched. `kubectl` is a stub whose answers are driven by files
# under ${STATE}, so every branch — both Secrets, one Secret, neither, an empty
# value, a malformed Secret — is reachable offline.

bats_require_minimum_version 1.5.0

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	SCRIPT="${REPO_ROOT}/scripts/attached-mode-preflight.sh"
	export KUBECONFIG=/dev/null
	STATE="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
	export FAKE_STATE="${STATE}"

	# A kubectl that answers `get secret <name> -o jsonpath={.data.<key>}` from
	# a file named after the Secret, and exits 1 (as kubectl does for NotFound)
	# when that file is absent. argv is recorded so the tests can assert the
	# script never mutates anything.
	cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
name=""
for a in "$@"; do
	case "$a" in
	signalloom-warden-ingest-token | signalloom-warden-fleet-key | signalloom-hub-ca)
		name="$a"
		;;
	esac
done
if [ -z "$name" ]; then exit 0; fi
if [ -f "${FAKE_STATE}/${name}" ]; then
	cat "${FAKE_STATE}/${name}"
	exit 0
fi
echo "Error from server (NotFound): secrets \"${name}\" not found" >&2
exit 1
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
	PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
	export PATH
}

# present NAME [VALUE] — the stub reports NAME with a base64-ish value.
#
# `${2-…}` and NOT `${2:-…}`: the colon form treats an explicitly-passed empty
# string as unset and substitutes the default, which silently turned the
# empty-token test into a duplicate of the happy path.
present() {
	printf '%s' "${2-dG9rZW4=}" >"${STATE}/$1"
}

# --- shape -------------------------------------------------------------------

@test "the script exists and is executable" {
	[ -f "${SCRIPT}" ]
	[ -x "${SCRIPT}" ]
}

@test "--help prints usage and exits 0" {
	run "${SCRIPT}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"attached-mode-preflight"* ]]
}

@test "an unknown flag exits 2" {
	run "${SCRIPT}" --not-a-flag
	[ "$status" -eq 2 ]
}

@test "no arguments is a valid invocation, not a usage error" {
	# The production call is `scripts/attached-mode-preflight.sh` with
	# APPLIANCE_MODE in the environment and no flags. A `main "${@:-}"` idiom
	# passes one empty argument there and an option loop rejects it, so the
	# bare call is its own test case.
	APPLIANCE_MODE=hub run "${SCRIPT}"
	[ "$status" -eq 0 ]
}

# --- mode gating -------------------------------------------------------------

@test "APPLIANCE_MODE=hub is a no-op that exits 0 and names the reason" {
	APPLIANCE_MODE=hub run "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"hub"* ]]
	[ ! -f "${STATE}/argv" ]
}

@test "an unset APPLIANCE_MODE defaults to hub and does not query a cluster" {
	run env -u APPLIANCE_MODE "${SCRIPT}"
	[ "$status" -eq 0 ]
	[ ! -f "${STATE}/argv" ]
}

@test "an unrecognised APPLIANCE_MODE exits 2 rather than guessing" {
	APPLIANCE_MODE=sidecar run "${SCRIPT}"
	[ "$status" -eq 2 ]
	[[ "$output" == *"sidecar"* ]]
}

# --- the finding: attached cannot self-provision -----------------------------

@test "attached with BOTH Secrets present passes" {
	present signalloom-warden-ingest-token
	present signalloom-warden-fleet-key
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"signalloom-warden-ingest-token"* ]]
	[[ "$output" == *"signalloom-warden-fleet-key"* ]]
}

@test "attached with NEITHER Secret fails, naming both and both issuing commands" {
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 1 ]
	[[ "$output" == *"signalloom-warden-ingest-token"* ]]
	[[ "$output" == *"signalloom-warden-fleet-key"* ]]
	# Who issues them, and where. A design partner cannot run either command.
	[[ "$output" == *"sldc-ingest-bearer.sh"* ]]
	[[ "$output" == *"fleet-manager-caller-keys.sh"* ]]
	[[ "$output" == *"--emit-remote-secrets"* ]]
	[[ "$output" == *"central"* ]]
}

@test "attached missing ONLY the ingest token names that one and not the other" {
	present signalloom-warden-fleet-key
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 1 ]
	[[ "$output" == *"signalloom-warden-ingest-token"* ]]
	[[ "$output" == *"sldc-ingest-bearer.sh"* ]]
	# The satisfied one must not be reported as missing.
	[[ "$output" != *"MISSING signalloom-warden-fleet-key"* ]]
}

@test "attached missing ONLY the fleet key names that one and not the other" {
	present signalloom-warden-ingest-token
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 1 ]
	[[ "$output" == *"signalloom-warden-fleet-key"* ]]
	[[ "$output" == *"fleet-manager-caller-keys.sh"* ]]
	[[ "$output" != *"MISSING signalloom-warden-ingest-token"* ]]
}

@test "a Secret that exists with an EMPTY token is a failure, not a pass" {
	# `kubectl get -o jsonpath={.data.token}` prints nothing and exits 0 for a
	# Secret that exists without the key. Presence is not sufficient.
	present signalloom-warden-ingest-token ""
	present signalloom-warden-fleet-key
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 1 ]
	[[ "$output" == *"signalloom-warden-ingest-token"* ]]
}

@test "the failure message states that the design partner cannot mint these" {
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 1 ]
	[[ "$output" == *"CANNOT mint them"* ]]
}

@test "the failure message points at the prerequisite document" {
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 1 ]
	[[ "$output" == *"docs/attached-mode-central-issuance.md"* ]]
}

# --- the optional third Secret -----------------------------------------------

@test "the optional hub CA is reported as a warning and does not fail the run" {
	present signalloom-warden-ingest-token
	present signalloom-warden-fleet-key
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"signalloom-hub-ca"* ]]
}

# --- it is read-only ---------------------------------------------------------

@test "the preflight never mutates the cluster" {
	present signalloom-warden-ingest-token
	present signalloom-warden-fleet-key
	APPLIANCE_MODE=attached run "${SCRIPT}"
	[ "$status" -eq 0 ]
	run grep -E -- '(^| )(apply|create|delete|patch|replace|edit)( |$)' "${STATE}/argv"
	[ "$status" -ne 0 ]
}

@test "the namespace and context are overridable for an appliance that renames them" {
	present signalloom-warden-ingest-token
	present signalloom-warden-fleet-key
	APPLIANCE_MODE=attached run "${SCRIPT}" --namespace other-ns --context some-ctx
	[ "$status" -eq 0 ]
	run grep -F -- '--context some-ctx' "${STATE}/argv"
	[ "$status" -eq 0 ]
	run grep -F -- '-n other-ns' "${STATE}/argv"
	[ "$status" -eq 0 ]
}

# --- the documentation it points at must exist and say the load-bearing thing -

@test "the prerequisite document exists and names both Secrets and both issuers" {
	DOC="${REPO_ROOT}/docs/attached-mode-central-issuance.md"
	[ -f "${DOC}" ]
	run grep -F -- 'signalloom-warden-ingest-token' "${DOC}"
	[ "$status" -eq 0 ]
	run grep -F -- 'signalloom-warden-fleet-key' "${DOC}"
	[ "$status" -eq 0 ]
	run grep -F -- 'scripts/sldc-ingest-bearer.sh' "${DOC}"
	[ "$status" -eq 0 ]
	run grep -F -- 'scripts/fleet-manager-caller-keys.sh' "${DOC}"
	[ "$status" -eq 0 ]
}

@test "the prerequisite document does NOT claim the escrow bundle carries these Secrets" {
	# OSD-8 investigation: the encrypted escrow bundle (Decision 3) covers
	# LOCALLY minted material only, and is unimplemented. Any sentence putting
	# the two central Secrets inside it would be false.
	DOC="${REPO_ROOT}/docs/attached-mode-central-issuance.md"
	# Positive control first: the doc must actually DISCUSS the escrow bundle and
	# name it. Without this, the negative assertion below would also pass for an
	# unreadable file, a renamed doc, or a doc that never mentions escrow at all.
	run grep -cF -- 'escrow' "${DOC}"
	[ "$status" -eq 0 ]
	[ "$output" -ge 3 ]
	run grep -F -- '<tenant-id>-escrow.tar.enc' "${DOC}"
	[ "$status" -eq 0 ]
	# Now the claim under test: no sentence puts either central Secret inside it.
	run grep -nE 'escrow[^.]*(ingest-token|fleet-key)|(ingest-token|fleet-key)[^.]*escrow' "${DOC}"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

# --- the lab wires the preflight in -----------------------------------------

@test "the remote-tenant lab invokes the preflight after applying the Secrets" {
	run grep -F -- 'attached-mode-preflight.sh' "${REPO_ROOT}/scripts/remote-tenant-lab.sh"
	[ "$status" -eq 0 ]
}
