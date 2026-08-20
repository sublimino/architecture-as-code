#!/usr/bin/env bats
#
# The four-lane surfaces report — and proof it cannot report a green estate that
# is not there.
#
# The report answers "which lanes are good?" by reading each lane's per-surface
# receipt. That makes it a summariser, and summarisers are where this repository
# has repeatedly lost the truth: an absent summary.json was read as a pass twice
# in one day on 2026-08-13, and a receipt keeps asserting PASS long after the
# lane it describes was destroyed and rebuilt.
#
# So the two tests that matter here are not "does it print a table". They are:
# a MISSING receipt must fail, and a STALE one must fail. Both have a mutation
# partner proving the check can actually see the difference.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$repo/scripts/gcp-tf/surfaces-report.sh"
	export GCP_TF_SURFACES_DIR="$BATS_TEST_TMPDIR/surfaces"
	mkdir -p "$GCP_TF_SURFACES_DIR"
}

# Write a receipt for one lane/surface. Defaults to a passing, current one.
receipt() {
	local env="$1" surface="$2" outcome="${3:-PASS}" commit="${4:-deadbee}"
	cat >"$GCP_TF_SURFACES_DIR/${env}.${surface}.json" <<-JSON
		{
		  "schema": "signalloom.surface.receipt/v1",
		  "surface": "${surface}",
		  "env": "${env}",
		  "outcome": "${outcome}",
		  "commit": "${commit}",
		  "written_epoch": $(date +%s),
		  "checks_total": 7,
		  "checks_failed": 0
		}
	JSON
}

both() { receipt "$1" on-vm "${2:-PASS}" "${3:-deadbee}"; receipt "$1" tailnet "${2:-PASS}" "${3:-deadbee}"; }

@test "REPORT a fully green estate at the expected commit exits 0" {
	for l in demo-1 demo-2 ci-1 ci-2; do both "$l"; done
	run "$script" --commit deadbee
	[ "$status" -eq 0 ]
	[[ "$output" == *"ALL LANES PASS"* ]]
}

# ─── Failure mode 1: absence ────────────────────────────────────────────────

@test "REPORT a MISSING receipt fails the sweep" {
	for l in demo-1 demo-2 ci-1 ci-2; do both "$l"; done
	rm -f "$GCP_TF_SURFACES_DIR/ci-2.tailnet.json"
	run "$script" --commit deadbee
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" != *"ALL LANES PASS"* ]]
}

@test "REPORT MUTATION absence is not silently skipped — the lane is still named" {
	for l in demo-1 demo-2 ci-1 ci-2; do both "$l"; done
	rm -f "$GCP_TF_SURFACES_DIR/ci-2.tailnet.json"
	run "$script" --commit deadbee
	# A sweep that quietly omitted the lane would leave no trace of ci-2/tailnet.
	# Naming it is what turns "we did not look" into a reportable state.
	[[ "$output" == *"ci-2"* ]]
	[[ "$output" == *"tailnet"* ]]
}

# ─── Failure mode 2: staleness ──────────────────────────────────────────────

@test "REPORT a PASS from another commit is STALE, not a pass" {
	for l in demo-1 demo-2 ci-1 ci-2; do both "$l"; done
	# ci-1 passed — on a different tree.
	both ci-1 PASS 0ldc0de
	run "$script" --commit deadbee
	[ "$status" -eq 1 ]
	[[ "$output" == *"STALE"* ]]
	[[ "$output" != *"ALL LANES PASS"* ]]
}

@test "REPORT MUTATION staleness outranks a PASS outcome" {
	both demo-1 PASS 0ldc0de
	for l in demo-2 ci-1 ci-2; do both "$l"; done
	run "$script" --commit deadbee
	# The receipt says PASS. The report must not.
	grep -qE 'demo-1 +on-vm +STALE' <<<"$output"
	[ "$status" -eq 1 ]
}

@test "REPORT an explicitly FAILED receipt fails the sweep" {
	for l in demo-1 demo-2 ci-1 ci-2; do both "$l"; done
	both demo-2 FAIL
	run "$script" --commit deadbee
	[ "$status" -eq 1 ]
	[[ "$output" != *"ALL LANES PASS"* ]]
}

# The staleness check is only meaningful if an expected commit is resolved. An
# empty one would compare every receipt against nothing and pass them all, which
# is the vacuous-pass shape this whole file is about.
@test "REPORT MUTATION an empty expected commit cannot make everything pass" {
	both demo-1 PASS 0ldc0de
	for l in demo-2 ci-1 ci-2; do both "$l"; done
	# Explicitly empty: the script must fall back to the repo HEAD rather than
	# comparing against "" and calling every receipt current.
	run "$script" --commit "" --lanes "demo-1"
	[[ "$output" != *"ALL LANES PASS at "* ]] || {
		echo "an empty --commit made a stale receipt pass:"; echo "$output"; return 1
	}
}

@test "REPORT --lanes narrows the sweep" {
	both ci-1
	run "$script" --commit deadbee --lanes "ci-1"
	[ "$status" -eq 0 ]
	[[ "$output" != *"demo-2"* ]]
}

@test "REPORT --json emits parseable output carrying every lane" {
	for l in demo-1 demo-2 ci-1 ci-2; do both "$l"; done
	run "$script" --commit deadbee --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.lanes | length == 8' >/dev/null
	echo "$output" | jq -e '.schema == "signalloom.surfaces.report/v1"' >/dev/null
}
