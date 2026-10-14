#!/usr/bin/env bats
#
# Acceptance suite for the three AJM decisions OSD-1, OSD-2 and OSD-3.
#
# @id     slsi-bundle-osd-bats
# @target scripts/package-tenant-bundle.sh, scripts/init-tenant.sh
# @schema schemas/slsi-appliance-manifest-schema.json
# @lib    test/helpers/slsi-bundle-build-driver.bash, test/helpers/slsi-bundle-fake-crane.bash
# @task   SLSI-OSD-1, SLSI-OSD-2, SLSI-OSD-3
#
# Hermetic: it copies the repository's bundle tree to a temporary directory and
# builds there, so it never writes to bundle/ or dist/ and leaves no tracked
# file dirty. The copy is `cp -a` and never `cp -al`: hardlinked trees share
# inodes, and a build writing in place through a hardlink corrupts the source it
# was copied from (it has already dirtied 16 tracked files in this repository
# once).
#
# Everything it needs is on disk already: stage_osd_1_first_party_images reaches
# the registry only through the SLSI_CRANE_BIN seam, which is pointed at
# test/helpers/slsi-bundle-fake-crane.bash, and stage_p1_3_manifest reads
# bundle/.manifest.d/images.json and the repository's own fleet and infra trees.
# No network, no Docker, no OpenBao, and therefore no reason to skip: a skip in
# setup() turns a build failure into a silent pass, which once read green for
# two commits across 81 tests in this repository.

setup_file() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	export REPO_ROOT

	OSD_WORK="$BATS_FILE_TMPDIR/happy"
	export OSD_WORK
	mkdir -p "$OSD_WORK"
	cp -a "$REPO_ROOT/bundle" "$OSD_WORK/bundle"

	set +e
	SLSI_CRANE_BIN="$REPO_ROOT/test/helpers/slsi-bundle-fake-crane.bash" \
		SLSI_BUNDLE_OUT="$OSD_WORK/dist" \
		bash "$REPO_ROOT/test/helpers/slsi-bundle-build-driver.bash" \
		"$REPO_ROOT" "$OSD_WORK/bundle" \
		stage_osd_1_first_party_images stage_p1_3_manifest \
		>"$OSD_WORK/build.log" 2>&1
	echo "$?" >"$OSD_WORK/build.rc"
	set -e
}

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	MANIFEST="$OSD_WORK/dist/MANIFEST.json"
	IMAGES_JSON="$OSD_WORK/bundle/.manifest.d/images.json"
	BUILD_LOG="$OSD_WORK/build.log"
	SCHEMA_FILE="$REPO_ROOT/schemas/slsi-appliance-manifest-schema.json"
	SCHEMA_VALIDATOR="$REPO_ROOT/scripts/lib/json-schema-lite.jq"
	OSD1_WORKLOADS="dashboard-signalloom docs-signalloom fe-signalloom"
}

# ── OSD-1: first-party application images are exported and recorded ──────────

@test "OSD-1: the stage is dispatched by run_stage and the build succeeds" {
	# run_stage silently returns 0 for a name it cannot resolve, so the only
	# proof the stage ran is its own dispatcher line plus its effect.
	[ "$(cat "$OSD_WORK/build.rc")" -eq 0 ]
	grep -qF 'stage stage_osd_1_first_party_images: running' "$BUILD_LOG"
	run grep -cF 'stage stage_osd_1_first_party_images: pending' "$BUILD_LOG"
	[ "$output" = "0" ]
}

@test "OSD-1: exactly the three first-party applications are recorded, with party first-party" {
	run jq -r '[.images[] | select(.party == "first-party" and .role == "application") | .logicalName] | sort | join(" ")' "$MANIFEST"
	[ "$status" -eq 0 ]
	[ "$output" = "$OSD1_WORKLOADS" ]
}

@test "OSD-1: each first-party record carries the acme/images namespace and its source-id identity" {
	source "$REPO_ROOT/scripts/lib/source-id.sh"
	local w id
	for w in $OSD1_WORKLOADS; do
		id="$(source_id_for "$w")"
		[ -n "$id" ]
		run jq -e --arg w "$w" --arg id "$id" --arg tag "src-${id:0:12}" '
			[.images[] | select(.logicalName == $w and .party == "first-party")] as $r
			| ($r | length) == 1
			and ($r[0].sourceId == $id)
			and ($r[0].sourceIdTag == $tag)
			and ($r[0].digest | test("^sha256:[0-9a-f]{64}$"))
			and ($r[0].ref | test("/acme/images/signalloom/apps/" + $w + "@sha256:[0-9a-f]{64}$"))
			and ($r[0].resolvedRef == $r[0].ref)
			and ($r[0].sourceRef | test(":latest$"))
		' "$MANIFEST"
		[ "$status" -eq 0 ]
	done
}

@test "OSD-1: images.json count stays in arity with its array after the merge" {
	# Gate 3 of P1-3 compares these two. A dropped array element passes every
	# per-element check, so arity is the only assertion that catches it.
	run jq -e '.count == (.images | length) and .count == 33' "$IMAGES_JSON"
	[ "$status" -eq 0 ]
}

@test "OSD-1: the manifest digest set and the OCI index descriptor set are equal" {
	diff <(jq -r '.images[].digest' "$MANIFEST" | LC_ALL=C sort -u) \
		<(jq -r '.manifests[].digest' "$OSD_WORK/bundle/images/index.json" | LC_ALL=C sort -u)
}

@test "OSD-1: a digest the exporter cannot resolve is attributed, never absorbed" {
	local w="$BATS_TEST_TMPDIR/unresolvable"
	mkdir -p "$w"
	cp -a "$REPO_ROOT/bundle" "$w/bundle"

	run env FAKE_CRANE_UNRESOLVABLE=1 \
		SLSI_CRANE_BIN="$REPO_ROOT/test/helpers/slsi-bundle-fake-crane.bash" \
		SLSI_BUNDLE_OUT="$w/dist" \
		bash "$REPO_ROOT/test/helpers/slsi-bundle-build-driver.bash" \
		"$REPO_ROOT" "$w/bundle" \
		stage_osd_1_first_party_images stage_p1_3_manifest

	[ "$status" -ne 0 ]
	echo "$output" | grep -qF 'DIGEST-UNRESOLVED'
	[ ! -f "$w/dist/MANIFEST.json" ]
}

@test "OSD-1: re-running the export does not duplicate the first-party records" {
	run env SLSI_CRANE_BIN="$REPO_ROOT/test/helpers/slsi-bundle-fake-crane.bash" \
		SLSI_BUNDLE_OUT="$OSD_WORK/dist" \
		bash "$REPO_ROOT/test/helpers/slsi-bundle-build-driver.bash" \
		"$REPO_ROOT" "$OSD_WORK/bundle" \
		stage_osd_1_first_party_images
	[ "$status" -eq 0 ]
	run jq -e '.count == (.images | length) and .count == 33' "$IMAGES_JSON"
	[ "$status" -eq 0 ]
}

# ── OSD-2: the four tag-only references are declared, not pinned ─────────────

@test "OSD-2: exactly the four deferred references carry reason dev-deferred-pin" {
	diff <(jq -r '.coverageExclusions[] | select(.reason == "dev-deferred-pin") | .ref' "$MANIFEST" | LC_ALL=C sort) \
		<(printf '%s\n' \
			'ghcr.io/controlplaneio-in-toto/signalloom-warden:src-50c79ef7e84f' \
			'ghcr.io/stefanprodan/podinfo:6.7.1' \
			'python:3.12-slim' \
			'registry.k8s.io/coredns/coredns:v1.14.2' | LC_ALL=C sort)
}

@test "OSD-2: every exclusion entry self-documents with a justification" {
	run jq -e '
		(.coverageExclusions | length) == 8
		and ([.coverageExclusions[] | select((.justification // "") | length >= 40)] | length)
		    == (.coverageExclusions | length)
	' "$MANIFEST"
	[ "$status" -eq 0 ]
}

@test "OSD-2: a deferral preserves the version-or-source-tag distinction, never :latest" {
	run jq -e '
		[.coverageExclusions[] | select(.reason == "dev-deferred-pin")] as $d
		| ($d | length) == 4
		and ([$d[] | select(.mutableTag == false)] | length) == 4
		and ([$d[] | select((.tag // "") | length > 0)] | length) == 4
		and ([$d[] | select(.tag == "latest" or .tag == "*")] | length) == 0
		and ([$d[] | . as $e | select($e.ref | endswith(":" + $e.tag))] | length) == 4
	' "$MANIFEST"
	[ "$status" -eq 0 ]
}

@test "OSD-2: G-COVERAGE finds no unpinned domain image once the four are declared" {
	# Measured before the gate was written: the domain is 8 digest-less refs, of
	# which 4 were already declared and 4 are these. Both consumers -- the
	# bundler's own grep over the staged fleet and infra trees, and
	# airgap_digestless_refs over the extracted archive -- compute the same 8.
	grep -qF 'Gate G-COVERAGE passed' "$BUILD_LOG"
	run grep -cF 'REPORTED FAIL' "$BUILD_LOG"
	[ "$output" = "0" ]
}

@test "OSD-2: the schema rejects an undeclared reason and an entry with no justification" {
	local doc="$BATS_TEST_TMPDIR/mutated.json"

	jq '.coverageExclusions[0].reason = "because-i-said-so"' "$MANIFEST" >"$doc"
	run jq -n -r --slurpfile schema "$SCHEMA_FILE" --slurpfile doc "$doc" --arg ptr '#' -f "$SCHEMA_VALIDATOR"
	[ -n "$output" ]

	jq 'del(.coverageExclusions[0].justification)' "$MANIFEST" >"$doc"
	run jq -n -r --slurpfile schema "$SCHEMA_FILE" --slurpfile doc "$doc" --arg ptr '#' -f "$SCHEMA_VALIDATOR"
	[ -n "$output" ]
}

# ── OSD-3: the installer slot and its honest stub ────────────────────────────

@test "OSD-3: init-tenant.sh exists, is executable, and refuses every operational path" {
	local s="$REPO_ROOT/scripts/init-tenant.sh"
	[ -x "$s" ]

	run bash "$s" --help
	[ "$status" -eq 0 ]

	# The production invocation is a test case: the bare call is the one a
	# caller makes by accident and the one `main "${@:-}"` breaks.
	local arg
	for arg in "" plan apply verify provision; do
		if [ -z "$arg" ]; then
			run bash "$s"
		else
			run bash "$s" "$arg"
		fi
		[ "$status" -eq 69 ]
		echo "$output" | grep -qF 'not yet implemented'
		echo "$output" | grep -qF 'SLSI-P2-1'
	done
}

@test "OSD-3: the stub's own slot report agrees with MANIFEST.json" {
	run bash "$REPO_ROOT/scripts/init-tenant.sh" slot
	[ "$status" -eq 0 ]
	local reported="$BATS_TEST_TMPDIR/slot.json"
	printf '%s\n' "$output" >"$reported"

	run jq -e --slurpfile m "$MANIFEST" '
		.path == $m[0].installer.path
		and .ownedBy == $m[0].installer.ownedBy
		and .governedBy == $m[0].installer.governedBy
		and .status == $m[0].installer.status
	' "$reported"
	[ "$status" -eq 0 ]
}

@test "OSD-3: the installer block states the real state of both payload and source tree" {
	run jq -e '
		.installer.path == "scripts/init-tenant.sh"
		and .installer.present == false
		and .installer.status == "pending-p2-1"
		and .installer.ownedBy == "SLSI-P2-1"
		and (.installer.governedBy | length > 0)
		and .installer.sourcePath == "scripts/init-tenant.sh"
		and .installer.sourcePresent == true
		and (.installer.sourceStatus | length >= 20)
	' "$MANIFEST"
	[ "$status" -eq 0 ]
}

@test "OSD-3: installer.present is measured against the payload, not asserted" {
	local root="$BATS_TEST_TMPDIR/extract"
	mkdir -p "$root"
	tar -xzf "$OSD_WORK/dist/slsi-appliance-0.1.0.tar.gz" -C "$root"

	local path on_disk declared
	path="$(jq -r '.installer.path' "$root/MANIFEST.json")"
	if [ -e "$root/$path" ]; then on_disk=true; else on_disk=false; fi
	declared="$(jq -r '.installer.present' "$root/MANIFEST.json")"
	[ "$declared" = "$on_disk" ]
}
