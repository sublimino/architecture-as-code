#!/usr/bin/env bats
#
# Local paths that four concurrent lanes compute IDENTICALLY are shared mutable
# state, and this repo has now been bitten by that twice.
#
# ─── The class ──────────────────────────────────────────────────────────────
#
# `make gcp-tf-demo-up ENV=<lane>` is run for four lanes in parallel from ONE
# checkout. Anything defaulting to a bare path under REPO_ROOT is therefore the
# same file for all four, and whichever lane writes last wins.
#
#   1. REPORT_DIR — surfaced as `mv: cannot stat '.../demo-reports'`, because
#      one lane moved the directory another was writing. Fixed by keying on
#      ENV_KEY (demo-up.sh:279).
#
#   2. LOCAL_AFM_ARCHIVE — the same defect, with a much better disguise. Each
#      lane rebuilds a 244MB archive before delivering it, so lane B's
#      `k8s-afm.sh save` truncates and rewrites the file lane A is scp-ing.
#      Measured at 75868d19: ci-1 hashed f91275f4fd69 before sending and the
#      far side received 3a64f0694fa3, the bytes the other three had just
#      written. The far-side digest check refused with
#
#         The archive is corrupt in transit
#
#      which sends you to look at scp and the network. Nothing was wrong with
#      either. The file changed under the sender.
#
# The remote paths are NOT affected and deliberately so: they derive from
# REMOTE_WORK_DIR, which is per-VM, so two lanes cannot collide there. The
# hazard is specific to the LOCAL side, where one filesystem serves every lane.
#
# ─── Why a guard rather than a fix and a note ───────────────────────────────
#
# Both instances were found in production, hours apart, by two different
# symptoms neither of which named the cause. The defect is invisible in review
# because a bare path under REPO_ROOT is exactly what a single-lane script
# should use — it only becomes wrong when the caller runs four at once, which
# is a fact about the Makefile, not about the line you are reading.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	driver="$repo/scripts/gcp-tf/demo-up.sh"
}

# The default half of a `VAR="${OVERRIDE:-<default>}"` assignment.
default_of() {
	grep -m1 -E "^${1}=" "$driver" | sed -E 's/^[A-Z_]+="\$\{[A-Z_]+:-(.*)\}"$/\1/'
}

@test "LANEPATH the driver is readable and the assignments are found" {
	# ANCHOR. If default_of() returns nothing, every assertion below passes
	# vacuously — which is the failure mode this repo keeps rediscovering.
	[ -r "$driver" ]
	run default_of LOCAL_AFM_ARCHIVE
	[ -n "$output" ]
	run default_of REPORT_DIR
	[ -n "$output" ]
}

@test "LANEPATH the local AFM archive default is lane-private" {
	run default_of LOCAL_AFM_ARCHIVE
	[[ "$output" == *'${ENV_KEY}'* ]] || {
		echo "LOCAL_AFM_ARCHIVE defaults to a path every lane computes identically:" >&2
		echo "  $output" >&2
		echo "" >&2
		echo "Four lanes run concurrently from one checkout and each REBUILDS this" >&2
		echo "archive before delivering it, so one lane truncates the file another" >&2
		echo "is scp-ing. It surfaces as 'corrupt in transit', which is not what it" >&2
		echo "is. Key the default on \${ENV_KEY}. See this file's header." >&2
		return 1
	}
}

@test "LANEPATH the report directory default is lane-private" {
	# The first instance of the class. Asserted so a revert cannot quietly
	# reopen it, and so this suite covers the pattern rather than one line.
	run default_of REPORT_DIR
	[[ "$output" == *'${ENV_KEY}'* ]]
}

# ─── POSITIVE CONTROLS ──────────────────────────────────────────────────────

@test "LANEPATH MUTATION the check can SEE a shared path" {
	# The exact historical value. If the matcher cannot reject this, the tests
	# above prove nothing.
	bad='${REPO_ROOT}/.afm-image/kubesec-afm.tar.gz'
	[[ "$bad" != *'${ENV_KEY}'* ]]
}

@test "LANEPATH MUTATION the check ACCEPTS a correctly keyed path" {
	# The other direction: a matcher that rejects everything would make the
	# mutation control above pass while the real tests fail for the wrong
	# reason.
	good='${REPO_ROOT}/.afm-image/${ENV_KEY}/kubesec-afm.tar.gz'
	[[ "$good" == *'${ENV_KEY}'* ]]
}

@test "LANEPATH MUTATION the parser really reads THIS driver" {
	# Couples the suite to the real file rather than to a paraphrase.
	run default_of LOCAL_AFM_ARCHIVE
	[[ "$output" == *'.afm-image'* ]]
}

# The remote side is per-VM and must NOT be keyed on ENV_KEY — asserting this
# stops someone "fixing" it for symmetry and breaking the deliberate rule that
# both sides of the ssh boundary derive the same remote path independently.
@test "LANEPATH the REMOTE archive path is derived, not lane-keyed" {
	# One LINE, not a range. remote_afm_archive is a single-line function, and a
	# `/^name()/,/^}/` range therefore runs past it to the next line starting
	# with `}` — swallowing unrelated code. That extraction failed this test
	# against correct source, which is the more dangerous direction: it reports
	# a defect in the thing under test when the fault is in the reader.
	block="$(grep -m1 -E '^remote_afm_archive\(\)' "$driver")"
	[ -n "$block" ]
	[[ "$block" == *'REMOTE_WORK_DIR'* ]]
	[[ "$block" != *'ENV_KEY'* ]]
}
