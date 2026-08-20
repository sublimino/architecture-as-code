#!/usr/bin/env bats
#
# The demo VM keeps the SAME tailnet name across a destroy/rebuild.
#
# ─── The defect this suite exists for ───────────────────────────────────────
#
# sl-demo-1 was destroyed and rebuilt on 2026-08-18. The rebuilt VM joined as a
# SUFFIXED name. Both device records carried HostName=sl-demo-1 — the requested
# --hostname was honoured — but the MagicDNS name drifted, because
# `terraform destroy` removes the GCP instance and NOTHING removes the tailnet
# device record. The offline corpse still owned the name, so the new node was
# given the next free suffix. The suffix is a function of how many corpses
# exist, so the demo URL moves further on every rebuild.
#
# That URL is the deliverable: the whole point of this access plane is an
# address that can be sent to someone before the VM has finished booting.
#
# Aggravating factor, and the reason it went unseen: the comment above
# bring_tailscale_up ASSERTED that the rebuilt VM "reclaims sl-demo-1 rather
# than accumulating" suffixes. Nothing implemented that. A comment stating an
# invariant the code does not hold reads as a guarantee to everyone downstream.
#
# ─── What is asserted here ──────────────────────────────────────────────────
#
#   Removal   the logout runs BEFORE the destroy, and can never block it.
#   Assertion the node checks the name it was GRANTED against the one it asked
#             for, logs at ERROR, and leaves a durable marker.
#   Surfacing the driver's status commands FAIL on that marker.
#   Hygiene   the auth key appears in exactly one place and reaches no log,
#             no marker and no argument list.
#
# ─── Named terraform-*.bats deliberately ────────────────────────────────────
#
# `make gcp-tf-validate` runs `$(wildcard test/terraform-*.bats)`, so this suite
# is registered the moment it lands and cannot be forgotten by a hand-maintained
# list — the failure mode that left 33 suites in this repo passing and unasked.
#
# ─── Everything runs offline ────────────────────────────────────────────────
#
# No tailnet, no cloud, no credentials, no network. The states this suite is
# really about — a node given the wrong name, a VM that is unreachable at
# teardown, a logout that fails — are all states you cannot reliably produce on
# a healthy estate.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export MAKEFILE="${REPO_ROOT}/Makefile"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
	export STARTUP="${REPO_ROOT}/terraform/modules/compute/startup/demo-vm.sh"
	export TFVARS="${REPO_ROOT}/deploy/gcp/sl-port-over-sandbox.example.tfvars"
	export STUB_SRC="${REPO_ROOT}/test/fixtures/gcp-tf-tailscale/stub-gcloud"
	export HELPER="${REPO_ROOT}/test/helpers/ts-node-name.bash"
}

setup() {
	# ─── Presence before behaviour, always ──────────────────────────────────
	#
	# A suite driving a file that was never written reports whatever the shell
	# does with a missing path, and this repo has shipped that shape before.
	[ -f "${MAKEFILE}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -x "${DRIVER_SRC}" ]
	[ -f "${STARTUP}" ]
	[ -f "${STUB_SRC}" ]
	[ -f "${HELPER}" ]

	# ─── The MECHANISM must be present before its behaviour is asserted ─────
	#
	# Without these four, a tree that had never received this work at all would
	# sail through most of the suite: the extraction would produce nothing, the
	# driver would hit its usage error, `[ "$status" -ne 0 ]` would hold, and
	# the run would report that a set of guards works correctly against a
	# codebase containing none of them.
	grep -q '^assert_tailscale_node_name()' "${STARTUP}" || {
		echo "the startup script has no assert_tailscale_node_name — this suite would test nothing"
		return 1
	}
	grep -q '^install_tailscale_logout_unit()' "${STARTUP}" || {
		echo "the startup script installs no shutdown logout unit — the backstop assertions would be vacuous"
		return 1
	}
	grep -q '^cmd_ts_logout()' "${DRIVER_SRC}" || {
		echo "the driver has no cmd_ts_logout — every logout test would hit the usage error"
		return 1
	}
	grep -q '^  ts-logout) cmd_ts_logout ;;' "${DRIVER_SRC}" || {
		echo "ts-logout is not dispatched — every subcommand test would hit the usage error"
		return 1
	}

	# shellcheck source=test/helpers/ts-node-name.bash
	source "${HELPER}"

	ENV_KEY="demo-9"
	TS_HOST="sl-${ENV_KEY}"
	# The DRIFTED name, built rather than written, so this file contains no
	# hardcoded suffixed literal for the anti-test at the bottom to find. It is
	# fixture INPUT — the thing the guard must reject — never an expectation.
	TS_DRIFTED="$(printf '%s-%d' "${TS_HOST}" 1)"
	TS_SUFFIX="example-tailnet.ts.net"

	stubdir="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${stubdir}"

	export TS_NAME_MARKER="${BATS_TEST_TMPDIR}/tailscale-name-mismatch"
	HARNESS="${BATS_TEST_TMPDIR}/harness.sh"
	ts_name_harness "${HARNESS}" "${STARTUP}"
	ts_name_stub_tailscale "${stubdir}"
	export PATH="${stubdir}:${PATH}"
}

# Run assert_tailscale_node_name against a tailnet that reports $1 as this
# node's DNSName, asking for $2. Sets $status and $output like `run` does.
assert_name() {
	local dnsname="$1" want="$2"
	ts_name_status_json "${dnsname}" "${TS_HOST}" >"${BATS_TEST_TMPDIR}/status.json"
	export STUB_TS_JSON="${BATS_TEST_TMPDIR}/status.json"
	run bash -c "source '${HARNESS}'; assert_tailscale_node_name '${want}'"
}

# ---------------------------------------------------------------------------
# The name assertion — success path
# ---------------------------------------------------------------------------

@test "a node granted the name it asked for passes and writes no marker" {
	assert_name "${TS_HOST}.${TS_SUFFIX}." "${TS_HOST}"
	[ "$status" -eq 0 ]
	[[ "${output}" == *"verified"* ]]
	[ ! -f "${TS_NAME_MARKER}" ]
}

@test "the comparison is trailing-dot safe" {
	# The tailnet returns a correct FQDN with a trailing dot. Comparing that raw
	# string against a short hostname fails on every HEALTHY node, so getting
	# this wrong produces a permanent false alarm rather than a guard.
	assert_name "${TS_HOST}.${TS_SUFFIX}." "${TS_HOST}"
	[ "$status" -eq 0 ]

	# And it must not DEPEND on the dot being there either.
	assert_name "${TS_HOST}.${TS_SUFFIX}" "${TS_HOST}"
	[ "$status" -eq 0 ]
}

@test "the FQDN this node reports is normalised, with no trailing dot" {
	# Separate from the comparison test above, and the mutation proof is why.
	#
	# Deleting the `${got%.}` strip does NOT break the comparison — `${got%%.*}`
	# takes the first label and is dot-safe on its own — so the test above stayed
	# green against a tree with the strip removed. What the strip actually
	# governs is the name REPORTED to humans, in the log and in the marker. A
	# trailing dot there is the difference between a name an operator can paste
	# into a browser and one they have to know to edit.
	assert_name "${TS_HOST}.${TS_SUFFIX}." "${TS_HOST}"
	[ "$status" -eq 0 ]
	[[ "${output}" != *"${TS_SUFFIX}."* ]]

	# Same property on the failure path, where the name is written to disk and
	# outlives the boot.
	assert_name "${TS_DRIFTED}.${TS_SUFFIX}." "${TS_HOST}"
	observed="$(sed -n 's/^observed:  *//p' "${TS_NAME_MARKER}")"
	[ -n "${observed}" ]
	[[ "${observed}" != *"." ]]
}

@test "only the first label is compared, so the tailnet suffix is never hardcoded" {
	# Same node, a tailnet that has been renamed. The suffix belongs to the
	# tailnet, not to this node; pinning it here would be the "no literal FQDN"
	# rule broken in the easiest place to break it.
	assert_name "${TS_HOST}.some-other-tailnet.ts.net." "${TS_HOST}"
	[ "$status" -eq 0 ]
}

@test "a marker from an earlier boot is cleared when the name is correct" {
	# A guard that cannot go back to green is a guard people learn to ignore.
	printf 'stale mismatch from a previous boot\n' >"${TS_NAME_MARKER}"
	[ -f "${TS_NAME_MARKER}" ]

	assert_name "${TS_HOST}.${TS_SUFFIX}." "${TS_HOST}"
	[ "$status" -eq 0 ]
	[ ! -f "${TS_NAME_MARKER}" ]
}

# ---------------------------------------------------------------------------
# The name assertion — failure path. Three things must ALL happen.
# ---------------------------------------------------------------------------

@test "a drifted name FAILS, logs at ERROR, and writes the marker" {
	assert_name "${TS_DRIFTED}.${TS_SUFFIX}." "${TS_HOST}"

	# 1. non-success return
	[ "$status" -ne 0 ]

	# 2. logged at ERROR
	[[ "${output}" == *"ERROR:"* ]]

	# 3. durable marker
	[ -f "${TS_NAME_MARKER}" ]
}

@test "the drift is logged at ERROR and never as a WARNING" {
	# This file's convention is that WARNING means degradation: an optional
	# feature that did not come up on a VM that is otherwise fine. This is not
	# degradation — Tailscale is fully working, under a name nobody can predict.
	# The estate is up and the deliverable is broken, and those two need
	# different words or the second one is never read.
	assert_name "${TS_DRIFTED}.${TS_SUFFIX}." "${TS_HOST}"
	[ "$status" -ne 0 ]
	[[ "${output}" == *"ERROR:"* ]]

	# No line about this failure may be a WARNING.
	run bash -c "source '${HARNESS}'; assert_tailscale_node_name '${TS_HOST}' 2>&1 | grep -c 'WARNING'"
	[ "${output}" = "0" ]
}

@test "the failure names BOTH the requested and the granted name" {
	# A diagnosis that says only "wrong name" sends the reader to the console to
	# work out which node it is talking about.
	assert_name "${TS_DRIFTED}.${TS_SUFFIX}." "${TS_HOST}"
	[[ "${output}" == *"${TS_HOST}"* ]]
	[[ "${output}" == *"${TS_DRIFTED}"* ]]
}

@test "the suffixed name is NEVER silently accepted" {
	assert_name "${TS_DRIFTED}.${TS_SUFFIX}." "${TS_HOST}"
	[ "$status" -ne 0 ]

	# The tell for a silent fallback: a success verdict, or language that treats
	# the drift as something to carry on through. Accepting the suffixed name is
	# what makes the drift permanent, and it is how the live estate got here.
	[[ "${output}" != *"verified"* ]]
	[[ "${output}" != *"continuing without"* ]]
}

@test "a status document that cannot be read FAILS rather than assuming success" {
	# An unreadable name is not a verified name. Treating "could not check" as
	# a pass is the single most tempting shortcut in a guard like this.
	export STUB_TS_DOWN=1
	ts_name_status_json "${TS_HOST}.${TS_SUFFIX}." "${TS_HOST}" >"${BATS_TEST_TMPDIR}/status.json"
	export STUB_TS_JSON="${BATS_TEST_TMPDIR}/status.json"

	run bash -c "source '${HARNESS}'; assert_tailscale_node_name '${TS_HOST}'"
	[ "$status" -ne 0 ]
	[[ "${output}" == *"ERROR:"* ]]
	[ -f "${TS_NAME_MARKER}" ]
}

@test "the marker records both names and a timestamp" {
	assert_name "${TS_DRIFTED}.${TS_SUFFIX}." "${TS_HOST}"
	[ -f "${TS_NAME_MARKER}" ]

	run cat "${TS_NAME_MARKER}"
	[[ "${output}" == *"requested:"* ]]
	[[ "${output}" == *"observed:"* ]]
	[[ "${output}" == *"${TS_HOST}"* ]]
	[[ "${output}" == *"${TS_DRIFTED}"* ]]
}

@test "the status query suppresses peers, so a peer's name cannot be read as ours" {
	# EVERY peer object carries its own DNSName. Against a full status document
	# a first-match extraction returns whichever node the daemon serialised
	# first — on a healthy tailnet, somebody else's laptop. The resulting
	# "mismatch" would name a machine with nothing to do with this one, and the
	# resulting MATCH would be pure luck.
	#
	# Scoped to the FUNCTION BODY, not the file. The mutation proof caught this:
	# a whole-file grep stayed green after --peers=false was stripped from the
	# actual command, because the COMMENT above the function explaining why the
	# flag matters still contained the string. A guard satisfied by the prose
	# that documents it is not a guard.
	body="$(sed -n '/^tailscale_self_dnsname() {/,/^}/p' "${STARTUP}")"
	[ -n "${body}" ]
	[[ "${body}" == *"--peers=false"* ]]
}

# ---------------------------------------------------------------------------
# Secret hygiene. Non-negotiable: a key substring was genuinely printed once.
# ---------------------------------------------------------------------------

@test "the auth key's value is referenced in exactly two places, and both are named" {
	# Enumerated by IDENTITY, not by count. A count alone goes green when one
	# permitted line is deleted and one illegitimate line is added, which is
	# precisely the change this guard exists to catch.
	#
	# Two, not one, and the second is structural rather than an oversight:
	# fetch_tailscale_authkey returns the key to install_tailscale, which must
	# hand it to bring_tailscale_up. There is no arrangement with fewer, short
	# of merging the two functions.
	run bash -c "grep -c '\\\$authkey\\|\\\${authkey}' '${STARTUP}'"
	[ "${output}" = "2" ]

	# 1. the hand-off from the fetcher's caller to the joiner
	run bash -c "grep -c '^  bring_tailscale_up \"\\\$authkey\"' '${STARTUP}'"
	[ "${output}" = "1" ]

	# 2. the only place the value is actually consumed
	run bash -c "grep -c '^  tailscale up --auth-key=\"\\\$authkey\"' '${STARTUP}'"
	[ "${output}" = "1" ]
}

@test "the key is never echoed, and set -x is never enabled" {
	# `set -x` would print the tailscale up line with the key expanded, which is
	# a leak that no amount of care at the call sites can prevent.
	run bash -c "grep -cE '^[[:space:]]*set -x' '${STARTUP}'"
	[ "${output}" = "0" ]
}

@test "no log, marker or error line can interpolate the auth key" {
	# The mechanism, stated as a property rather than as a list of current
	# offenders: no line that EMITS anything may also reference the key.
	run bash -c "
		grep -nE '^[[:space:]]*(log|echo|printf|logger|die|cat)' '${STARTUP}' \
		  | grep 'authkey' || true
	"
	[ -z "${output}" ]
}

@test "the marker writer is not even passed the key" {
	# Structural, not behavioural. write_ts_name_marker takes two arguments and
	# neither is the key, so it is not in a position to leak one however it is
	# later edited.
	run bash -c "sed -n '/^write_ts_name_marker() {/,/^}/p' '${STARTUP}' | grep -c 'authkey'"
	[ "${output}" = "0" ]
}

@test "the marker written on a real mismatch contains no key-shaped string" {
	assert_name "${TS_DRIFTED}.${TS_SUFFIX}." "${TS_HOST}"
	run grep -c 'tskey-' "${TS_NAME_MARKER}"
	[ "${output}" = "0" ]
}

# ---------------------------------------------------------------------------
# The shutdown logout unit — the backstop for teardowns that skip the driver
# ---------------------------------------------------------------------------

@test "the startup script installs a shutdown logout unit" {
	run grep -qF 'install_tailscale_logout_unit' "${STARTUP}"
	[ "$status" -eq 0 ]
	run bash -c "sed -n '/^bring_tailscale_up() {/,/^}/p' '${STARTUP}' | grep -c 'install_tailscale_logout_unit'"
	[ "${output}" = "1" ]
}

@test "the unit logs out on stop, and tolerates every way that can fail" {
	unit="$(sed -n '/^install_tailscale_logout_unit() {/,/^}/p' "${STARTUP}")"

	# The `-` prefix is what makes a failed logout a non-event. Without it a
	# tailnet that is already unreachable marks the shutdown failed.
	[[ "${unit}" == *"ExecStop=-/usr/bin/tailscale logout"* ]]
	[[ "${unit}" == *"TimeoutStopSec="* ]]
}

@test "the unit is ordered so its stop runs BEFORE the network goes" {
	unit="$(sed -n '/^install_tailscale_logout_unit() {/,/^}/p' "${STARTUP}")"

	# Shutdown ordering is the INVERSE of start ordering. `After=` these two at
	# start means the unit is STOPPED before them — which is the only window in
	# which a logout can still reach the coordination server.
	[[ "${unit}" == *"After=network-online.target tailscaled.service"* ]]
}

@test "the unit does NOT disable DefaultDependencies" {
	# The subtle way to get this wrong, and the version most hand-written
	# examples use. DefaultDependencies=no strips the implicit
	# Before/Conflicts=shutdown.target, and without those systemd never stops
	# the unit at all — so its ExecStop never runs. It would look installed,
	# enabled and correct, and do nothing.
	unit="$(sed -n '/^install_tailscale_logout_unit() {/,/^}/p' "${STARTUP}")"
	[[ "${unit}" != *"DefaultDependencies=no"* ]]
}

@test "the unit is STARTED, not merely enabled" {
	# A oneshot with RemainAfterExit must be started for its ExecStop to run at
	# all. `enable` alone arms it for the NEXT boot and never fires on this one
	# — the exact shape of a guard that looks installed and has never once run.
	unit="$(sed -n '/^install_tailscale_logout_unit() {/,/^}/p' "${STARTUP}")"
	[[ "${unit}" == *"systemctl enable"* ]]
	[[ "${unit}" == *"systemctl start"* ]]
}

@test "no failure in the logout unit install can take the bootstrap down" {
	# The whole tailscale stage is optional. A VM that will not boot because an
	# optional feature's systemd unit failed to install is strictly worse than a
	# VM without the feature.
	run bash -c "sed -n '/^install_tailscale_logout_unit() {/,/^}/p' '${STARTUP}' | grep -c 'die '"
	[ "${output}" = "0" ]
}

# ---------------------------------------------------------------------------
# Logout BEFORE destroy. The primary mechanism.
# ---------------------------------------------------------------------------

# The destroy recipe as make would run it. `make -n` rather than a grep of the
# file: this proves the line is in THAT TARGET'S recipe, in that position, which
# a grep of the Makefile cannot distinguish from the line existing anywhere at
# all. There is no recursive make in the recipe, so -n prints everything and
# executes nothing.
destroy_recipe() {
	make -C "${REPO_ROOT}" -n gcp-tf-destroy \
		ENV="${ENV_KEY}" CONFIRM="${ENV_KEY}" TF_STATE_BUCKET=stub-bucket 2>&1
}

@test "gcp-tf-destroy releases the tailnet name BEFORE terraform destroy" {
	run destroy_recipe
	[ "$status" -eq 0 ]

	logout_line="$(printf '%s\n' "${output}" | grep -n "demo-up.sh' ts-logout" | head -1 | cut -d: -f1)"
	destroy_line="$(printf '%s\n' "${output}" | grep -n 'chdir=.*destroy' | head -1 | cut -d: -f1)"

	# Both must be FOUND. Without this the comparison below is between two empty
	# strings, which is the vacuous pass this whole repo keeps rediscovering.
	[ -n "${logout_line}" ]
	[ -n "${destroy_line}" ]
	[ "${logout_line}" -lt "${destroy_line}" ]
}

@test "the logout step cannot fail the destroy" {
	run destroy_recipe
	[ "$status" -eq 0 ]

	# `make -n` prints the recipe with the `@` stripped but the `-` is a make
	# directive, so it does not appear in the printed line. Assert it on the
	# source instead — this is the one property that has to be read from the
	# Makefile text, because it is make's own error-tolerance flag.
	run grep -F -- "-@\$(GCP_TF_DEMO_ENVIRONMENT) '\$(GCP_TF_DEMO_SCRIPT)' ts-logout" "${MAKEFILE}"
	[ "$status" -eq 0 ]
}

@test "gcp-tf-ts-logout forwards to the driver and survives a driver that fails" {
	# EXECUTED, not grepped. A stub driver that exits non-zero models every
	# runtime failure at once; the target must still report success.
	stub="${BATS_TEST_TMPDIR}/failing-driver.sh"
	printf '#!/usr/bin/env bash\necho "DRIVER CALLED: $*"\nexit 7\n' >"${stub}"
	chmod +x "${stub}"

	run make -C "${REPO_ROOT}" gcp-tf-ts-logout \
		ENV="${ENV_KEY}" GCP_TF_DEMO_SCRIPT="${stub}"
	[ "$status" -eq 0 ]
	[[ "${output}" == *"DRIVER CALLED: ts-logout"* ]]
}

@test "gcp-tf-ts-logout survives the driver being missing entirely" {
	run make -C "${REPO_ROOT}" gcp-tf-ts-logout \
		ENV="${ENV_KEY}" GCP_TF_DEMO_SCRIPT="${BATS_TEST_TMPDIR}/does-not-exist.sh"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The driver's ts-logout. Its one guarantee is that it always exits 0.
# ---------------------------------------------------------------------------

# A fixture checkout with a hand-off, plus the gcloud stub, so the driver runs
# end to end with no cloud and no credentials.
setup_driver() {
	root="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${root}/deploy/gcp"
	gcloudlog="${BATS_TEST_TMPDIR}/gcloud.log"
	: >"${gcloudlog}"

	cp "${STUB_SRC}" "${stubdir}/gcloud"
	chmod +x "${stubdir}/gcloud"

	jq -n --arg env "${ENV_KEY}" \
		'{schema: "signalloom.gcp.handoff/v1", schema_version: 1,
		  project_id: "acme-real-project-42", environment_key: $env, env: $env,
		  region: "europe-west2", zone: "europe-west2-a",
		  instance_name: ("sl-" + $env + "-demo"), internal_ip: "10.4.0.7",
		  app_port: 8080, state_bucket: "acme-tfstate",
		  state_prefix: ("osramp/environments/" + $env),
		  deploy_sa: "deployer@acme-real-project-42.iam.gserviceaccount.com",
		  operator_sa: "sl-operator@acme-real-project-42.iam.gserviceaccount.com",
		  access_mode: "iap", tailscale_hostname: ("sl-" + $env)}' \
		>"${root}/deploy/gcp/${ENV_KEY}.handoff.json"

	export STUB_GCLOUD_LOG="${gcloudlog}"
	export GCP_TF_DEMO_REPO_ROOT="${root}"
	export GCP_TF_DEMO_ENV="${ENV_KEY}"
	export GCP_TF_HANDOFF_DIR="${root}/deploy/gcp"
	export GCP_TF_DEMO_REPORT_DIR="${root}/demo-reports"
}

@test "ts-logout logs the node out when the VM is running" {
	setup_driver
	run "${DRIVER_SRC}" ts-logout
	[ "$status" -eq 0 ]
	run grep -c 'tailscale logout' "${gcloudlog}"
	[ "${output}" -ge 1 ]
}

@test "ts-logout exits 0 when the logout itself fails" {
	setup_driver
	export STUB_TS_LOGOUT_RC=1
	run "${DRIVER_SRC}" ts-logout

	# The guarantee. A destroy is the operator's escape hatch and must never be
	# blocked by a best-effort cleanup.
	[ "$status" -eq 0 ]

	# Silence would be worse than the failure. The operator has to learn that
	# the name may still be held.
	[[ "${output}" == *"admin/machines"* ]]
}

@test "ts-logout exits 0 when the VM is not running" {
	setup_driver
	export STUB_VM_STATE=TERMINATED
	run "${DRIVER_SRC}" ts-logout
	[ "$status" -eq 0 ]

	# And it must not have tried, because there is nothing there to try against.
	run grep -c 'tailscale logout' "${gcloudlog}"
	[ "${output}" = "0" ]
}

@test "ts-logout exits 0 when the VM has no tailscale client" {
	setup_driver
	export STUB_TS_ABSENT=1
	run "${DRIVER_SRC}" ts-logout
	[ "$status" -eq 0 ]
	run grep -c 'tailscale logout' "${gcloudlog}"
	[ "${output}" = "0" ]
}

@test "ts-logout exits 0 when the hand-off file is missing" {
	# `prepare` calls `die` on a missing hand-off, and `die` EXITS. In-process
	# that would take the destroy down with it — the precise outcome this
	# subcommand promises never to cause.
	setup_driver
	rm -f "${root}/deploy/gcp/${ENV_KEY}.handoff.json"
	run "${DRIVER_SRC}" ts-logout
	[ "$status" -eq 0 ]
}

@test "ts-logout exits 0 when gcloud is not on PATH at all" {
	setup_driver
	rm -f "${stubdir}/gcloud"
	run env PATH="${stubdir}:/usr/bin:/bin" "${DRIVER_SRC}" ts-logout
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Surfacing. A recorded mismatch must FAIL the status commands.
# ---------------------------------------------------------------------------

@test "status FAILS when the VM recorded a name mismatch" {
	setup_driver
	export STUB_TS_NAME_MARKER="requested: ${TS_HOST}
observed:  ${TS_DRIFTED}.${TS_SUFFIX}"

	run "${DRIVER_SRC}" status
	[ "$status" -ne 0 ]
	[[ "${output}" == *"MISMATCH"* ]]
}

@test "status passes when the VM recorded no mismatch" {
	# The other half. Without this, a `status` that failed unconditionally would
	# satisfy the test above and nobody would notice.
	setup_driver
	run "${DRIVER_SRC}" status
	[ "$status" -eq 0 ]
	[[ "${output}" != *"MISMATCH"* ]]
}

@test "the mismatch block reports what the VM recorded, verbatim" {
	setup_driver
	export STUB_TS_NAME_MARKER="requested: ${TS_HOST}
observed:  ${TS_DRIFTED}.${TS_SUFFIX}"

	run "${DRIVER_SRC}" status
	[[ "${output}" == *"${TS_HOST}"* ]]
	[[ "${output}" == *"${TS_DRIFTED}"* ]]
}

@test "the driver never hardcodes a tailnet FQDN" {
	# The name must stay DERIVED from `tailscale status --json`. A literal here
	# is a second place for the name to be wrong, and it would promise a URL
	# under a tailnet the operator may not be on.
	run bash -c "grep -oE '[a-z0-9-]+\\.ts\\.net' '${DRIVER_SRC}' | grep -v 'login.tailscale' || true"
	[ -z "${output}" ]
}

@test "the marker path is the same string in the writer and the reader" {
	# A contract between two files with no shared header. If these drift, the
	# writer writes a marker nothing reads, and the estate reports healthy
	# forever — silently, which is the failure mode this whole suite exists for.
	writer="$(grep -oE '/var/lib/signalloom/[a-z-]+' "${STARTUP}" | grep mismatch | head -1)"
	reader="$(grep -oE '/var/lib/signalloom/[a-z-]+' "${DRIVER_SRC}" | grep mismatch | head -1)"
	[ -n "${writer}" ]
	[ -n "${reader}" ]
	[ "${writer}" = "${reader}" ]
}

# ---------------------------------------------------------------------------
# Documentation, and the anti-test
# ---------------------------------------------------------------------------

@test "the false reclaim claim is gone from the startup script" {
	# The comment that asserted the rebuilt VM "reclaims" its name is why this
	# went unseen for three rebuilds. A comment stating an invariant the code
	# does not hold is a guarantee to everyone downstream of it.
	run bash -c "grep -c 'reclaims sl-demo-1 rather than accumulating' '${STARTUP}' || true"
	[ "${output}" = "0" ]
}

@test "the tfvars comment records that the auth key MUST be ephemeral" {
	run grep -qi 'EPHEMERAL IS MANDATORY' "${TFVARS}"
	[ "$status" -eq 0 ]

	# And says WHY, in terms of the mechanism rather than as an assertion.
	run grep -qi 'NOTHING IN TERRAFORM REMOVES THE' "${TFVARS}"
	[ "$status" -eq 0 ]
}

@test "ANTI-TEST: no suite pins the drifted name as an expectation" {
	# The tempting "fix" for this defect is to accept the observed suffixed name
	# — in a test, that means asserting equality against it. Any such assertion
	# encodes the bug as the contract.
	#
	# The needle is BUILT, never written, so this guard cannot match its own
	# source. A forbidden-literal grep that fires on the file holding the
	# pattern reads exactly like a real finding, and this repo has shipped that
	# shape before.
	needle="$(printf 'sl-demo-%d-%d' 1 1)"

	run bash -c "grep -rlF -- '${needle}' '${REPO_ROOT}/test' 2>/dev/null || true"
	[ -z "${output}" ]
}

@test "ANTI-TEST: the anti-test above can actually fail" {
	# A guard whose needle no longer matches anything anywhere is indistinguishable
	# from a guard that is working. Prove the search itself finds a planted
	# instance, in a scratch tree, so the green above means something.
	needle="$(printf 'sl-demo-%d-%d' 1 1)"
	scratch="${BATS_TEST_TMPDIR}/scratch"
	mkdir -p "${scratch}"
	printf '[ "$x" = "%s" ]\n' "${needle}" >"${scratch}/planted.bats"

	run bash -c "grep -rlF -- '${needle}' '${scratch}' 2>/dev/null || true"
	[ -n "${output}" ]
}
