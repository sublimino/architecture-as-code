#!/usr/bin/env bats
#
# Enforces d2-signalloom/apps/docs-signalloom/DIAGRAMS.md on every published
# architecture diagram: the .drawio source is the truth (regenerated outputs
# are not re-checked here, the source is), excluded components must not
# appear in any label, and the required components must appear in every one.
#
# No cluster and no network: grep only, against the tracked .drawio files.

setup() {
	repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	cd "$repo_root"
	diagram_dir="d2-signalloom/apps/docs-signalloom/public/diagrams"
}

# excluded_terms_found FILE — print any excluded term that appears in FILE,
# one per line. Empty output means the file is clean.
excluded_terms_found() {
	local file="$1"
	local term
	for term in \
		"kagent" \
		"purl listener" \
		"witness processor" \
		"osramp archiver" \
		"osramp apps" \
		"olly sentinel sre" \
		"o11y sentinel sre"
	do
		grep -qi -- "$term" "$file" && echo "$term"
	done
	# This function communicates via stdout, not its exit status: the last
	# `grep && echo` in the loop evaluates false (and so would make this
	# function return non-zero) on every file that is clean of every term
	# but the last one checked -- i.e. on almost every real file. Under
	# bats' errexit, a bare `return 1` here would abort the whole test on
	# the first clean file instead of just reporting "nothing found".
	return 0
}

# required_terms_missing FILE — print any required component not found in
# FILE, one per line. Empty output means the file shows everything it must.
required_terms_missing() {
	local file="$1"
	grep -qi 'openbao' "$file" || echo "OpenBao"
	grep -qi 'spire' "$file" || echo "SPIRE"
	grep -Eqi 'kubesec.afm' "$file" || echo "KubeSec AFM"
	grep -qi 'warden' "$file" || echo "the warden"

	local collector_term found=0
	for collector_term in \
		"cloudtrail" "guardduty" "event hub" "activity log" \
		"pub/sub" "sqs" "audit log" "offline replay" "replay fixture"
	do
		if grep -qi -- "$collector_term" "$file"; then
			found=1
			break
		fi
	done
	[ "$found" -eq 1 ] || echo "an external-system collector reference"
}

@test "every published diagram source excludes Kagent, the OSRAMP apps, and Olly Sentinel SRE" {
	local f hits failed=0
	for f in "$diagram_dir"/*.drawio; do
		hits="$(excluded_terms_found "$f")"
		if [ -n "$hits" ]; then
			echo "excluded terms found in $f:" >&2
			echo "$hits" >&2
			failed=1
		fi
	done
	[ "$failed" -eq 0 ]
}

@test "every published diagram source shows OpenBao, SPIRE, KubeSec AFM, the warden, and a collector" {
	local f missing failed=0
	for f in "$diagram_dir"/*.drawio; do
		missing="$(required_terms_missing "$f")"
		if [ -n "$missing" ]; then
			echo "missing from $f:" >&2
			echo "$missing" >&2
			failed=1
		fi
	done
	[ "$failed" -eq 0 ]
}

@test "the exclusion list also applies to public/diagrams/internal/*.json, when that directory exists" {
	local internal_dir="$diagram_dir/internal"
	[ -d "$internal_dir" ] || skip "no internal/ component-card directory in this tree"

	local f hits failed=0
	for f in "$internal_dir"/*.json; do
		[ -e "$f" ] || continue
		hits="$(excluded_terms_found "$f")"
		if [ -n "$hits" ]; then
			echo "excluded terms found in $f:" >&2
			echo "$hits" >&2
			failed=1
		fi
	done
	[ "$failed" -eq 0 ]
}

@test "self-test: the exclusion check actually fails on a planted Kagent label" {
	local clean="$diagram_dir/osramp-azure-multitenant-saas.drawio"
	local planted="$BATS_TEST_TMPDIR/planted.drawio"
	sed 's/signal-ingest/signal-ingest (\&amp; Kagent D5)/' "$clean" >"$planted"

	run excluded_terms_found "$planted"
	[ -n "$output" ]
	[[ "$output" == *kagent* ]]
}

@test "self-test: the required-components check actually fails when a component is missing" {
	local clean="$diagram_dir/osramp-azure-multitenant-saas.drawio"
	local stripped="$BATS_TEST_TMPDIR/stripped.drawio"
	sed 's/[Tt]he warden/Removed Component/g; s/warden/removed/g' "$clean" >"$stripped"

	run required_terms_missing "$stripped"
	[ -n "$output" ]
	[[ "$output" == *"the warden"* ]]
}

@test "osramp-kind-sovereign-airgap.drawio shows policy-engine, cert-manager, Landlock LSM, PostgreSQL, and receiver" {
	local f="$diagram_dir/osramp-kind-sovereign-airgap.drawio"
	grep -qi 'policy-engine' "$f"
	grep -qi 'cert-manager' "$f"
	grep -qi 'Landlock LSM' "$f"
	grep -qi 'PostgreSQL' "$f"
	grep -qi 'Receiver' "$f"
}
