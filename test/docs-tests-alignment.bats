#!/usr/bin/env bats
#
# scripts/docs-tests-alignment.sh checks that what the documentation CLAIMS
# about the test suite is true. scripts/docs-lint.sh checks links, paths, make
# targets and style. test/docs-index-sync.bats checks the records index. Neither
# reads a claim about a test, so a renamed Go test, a moved bats file, or a flag
# a script never took leaves every other gate green.
#
# The first test runs the gate on the real tree. Each other test points it at
# one fixture under test/fixtures/docs-alignment/ that plants exactly one
# defect. A gate that reports nothing looks the same as a gate that checks
# nothing, so every check has a planted defect that must fail it and a positive
# control that must pass.
#
# The fixtures end in .md.fixture, not .md. A planted defect in a tracked .md
# file would be found by the real-tree run of this gate and by docs-lint, and
# both would go red on their own fixtures.
#
# No cluster and no network: bash, awk, git, and rg only.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	cd "$repo_root"
	gate="$repo_root/scripts/docs-tests-alignment.sh"
	fx="test/fixtures/docs-alignment"
}

# The fixtures are not under docs/EAP/, so a fixture whose shell blocks must be
# read needs the scope widened for that run only. Exporting it in setup() would
# also replace the real scope, and the real-tree counters would read zero.
gate_shell() {
	env ALIGN_SHELL_SCOPE="$fx/" "$gate" "$@"
}

teardown() {
	unset ALIGN_SHELL_SCOPE ALIGN_WALKTHROUGH_DOC ALIGN_WALKTHROUGH_MAP ALIGN_GAPS_DOC
}

# ---------------------------------------------------------------------------
# The real tree
# ---------------------------------------------------------------------------

@test "the tracked documentation passes the alignment gate" {
	run "$gate"
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"file(s) clean"* ]]
}

@test "the real-tree run examines a meaningful number of claims" {
	run "$gate"
	echo "$output"
	[ "$status" -eq 0 ]
	# A gate that examined nothing prints the same clean line as a gate that
	# examined everything. Pin the floor of each counter.
	local artefacts make commands rows names
	artefacts="$(sed -n 's/.*artefacts=\([0-9]*\).*/\1/p' <<<"$output")"
	make="$(sed -n 's/.*make=\([0-9]*\).*/\1/p' <<<"$output")"
	commands="$(sed -n 's/.*commands=\([0-9]*\).*/\1/p' <<<"$output")"
	rows="$(sed -n 's/.*walkthrough-rows=\([0-9]*\).*/\1/p' <<<"$output")"
	names="$(sed -n 's/.*indexed \([0-9]*\) test names.*/\1/p' <<<"$output")"
	[ "$artefacts" -ge 50 ]
	[ "$make" -ge 50 ]
	[ "$commands" -ge 20 ]
	[ "$rows" -ge 5 ]
	[ "$names" -ge 500 ]
}

@test "the tiers come from scripts/docs-lint.sh, so there is one definition" {
	grep -q 'sed -n "s/\^RECORDS=' "$gate"
	grep -q 'sed -n "s/\^IGNORED=' "$gate"
	# A docs-lint that stops declaring them must break this gate loudly, not
	# silently widen or empty its own scope.
	run env DOCS_ALIGN_ROOT="$BATS_TEST_TMPDIR" "$gate"
	echo "$output"
	[ "$status" -eq 2 ]
	[[ "$output" == *"docs-lint.sh"* ]]
}

@test "the opt-in record list names the SLAWS proposal and nothing else" {
	run sed -n '/^OPTIN_RECORDS=(/,/^)/p' "$gate"
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"docs/Proposal — Signal Loom AWS Telemetry Ingest"* ]]
	# Exactly one entry: the opening line, the entry, the closing paren.
	[ "${#lines[@]}" -eq 3 ]
}

@test "the SLAWS proposal is in scope even though it is a decision record" {
	local proposal="docs/Proposal — Signal Loom AWS Telemetry Ingest & Multilayer Policy Engine Beta (2026-Q3).md"
	[ -f "$proposal" ]
	# It matches the records tier, which the gate otherwise skips.
	local records
	records="$(sed -n "s/^RECORDS='\(.*\)'$/\1/p" scripts/docs-lint.sh)"
	[[ "$proposal" =~ $records ]]
	# A planted bad claim in it must still be reported.
	cp "$proposal" "$BATS_TEST_TMPDIR/proposal.bak"
	printf '\nThe guard is `TestNoSuchAlignmentProbeExists`.\n' >>"$proposal"
	run "$gate"
	cp "$BATS_TEST_TMPDIR/proposal.bak" "$proposal"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"TestNoSuchAlignmentProbeExists"* ]]
}

@test "the default shell-block scope is the walkthroughs and the runbooks" {
	run grep -n 'SHELL_SCOPE=' "$gate"
	echo "$output"
	[[ "$output" == *"docs/(EAP|signalloom/runbooks)"* ]]
	[ -d docs/EAP ]
	[ -d docs/signalloom/runbooks ]
}

# ---------------------------------------------------------------------------
# One planted defect per check
# ---------------------------------------------------------------------------

@test "a clean fixture passes (positive control)" {
	run gate_shell "$fx/clean.md.fixture"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a doc naming a Go test that does not exist fails" {
	run "$gate" "$fx/missing-go-test.md.fixture"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"gotest: no test named 'TestNoSuchAlignmentProbeExists'"* ]]
}

@test "a doc naming a bats suite that does not exist fails" {
	run "$gate" "$fx/missing-bats.md.fixture"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"artefact"* ]]
	[[ "$output" == *"test/no-such-alignment-probe.bats"* ]]
}

@test "a doc naming a Playwright spec that does not exist fails" {
	run "$gate" "$fx/missing-spec.md.fixture"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"artefact"* ]]
	[[ "$output" == *"no-such-alignment-probe.spec.ts"* ]]
}

@test "a doc naming a make target that does not exist fails" {
	run "$gate" "$fx/missing-make-target.md.fixture"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"make: no target 'no-such-alignment-target'"* ]]
}

@test "a shell block passing a flag the repo script does not take fails" {
	run gate_shell "$fx/bad-flag.md.fixture"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"flag: scripts/verify-eap-evidence.sh takes no --no-such-alignment-flag"* ]]
}

@test "a shell block running an executable that does not exist fails" {
	run gate_shell "$fx/unknown-command.md.fixture"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"command"* ]]
	[[ "$output" == *"no-such-alignment-binary"* ]]
}

@test "a pipe inside quotes is data, not a command separator" {
	# A grep pattern such as 'a|b' used to be split, and each alternative was
	# then reported as a missing executable.
	printf '# Page\n\n```bash\ngrep -E %sattached|cutover%s /dev/null\n```\n' "'" "'" \
		>"$BATS_TEST_TMPDIR/quoted.md"
	run env ALIGN_SHELL_SCOPE='quoted\.md$' "$gate" "$BATS_TEST_TMPDIR/quoted.md"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a go test -run reference is treated as the prefix Go makes it" {
	# `go test -run TestAcceptance` selects every test under that prefix, so
	# naming the prefix is a true claim.
	printf '# Page\n\nRun `go test -run TestAcceptance`.\n' >"$BATS_TEST_TMPDIR/prefix.md"
	run "$gate" "$BATS_TEST_TMPDIR/prefix.md"
	echo "$output"
	[ "$status" -eq 0 ]
	# An exact reference to the same name is not a true claim.
	printf '# Page\n\nThe case is `TestAcceptance`.\n' >"$BATS_TEST_TMPDIR/exact.md"
	run "$gate" "$BATS_TEST_TMPDIR/exact.md"
	echo "$output"
	[ "$status" -eq 1 ]
}

@test "prose about make targets is not read as an invocation" {
	printf '# Page\n\nThe Makefile documents every target it uses. Run make sure of nothing.\n' \
		>"$BATS_TEST_TMPDIR/prose.md"
	run "$gate" "$BATS_TEST_TMPDIR/prose.md"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a suffix that does not end the token is a different name" {
	printf '# Page\n\nThe manifest is `audit-signature.sha256`, seven lines.\n' \
		>"$BATS_TEST_TMPDIR/suffix.md"
	run "$gate" "$BATS_TEST_TMPDIR/suffix.md"
	echo "$output"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Walkthrough and spec correspondence
# ---------------------------------------------------------------------------

walk() {
	env ALIGN_WALKTHROUGH_DOC="$fx/walkthrough.md.fixture" \
		ALIGN_WALKTHROUGH_MAP="$fx/$1" \
		ALIGN_GAPS_DOC="$fx/walkthrough-gaps.md.fixture" \
		"$gate" "$fx/clean.md.fixture"
}

@test "a complete walkthrough map passes (positive control)" {
	run walk walkthrough-map-good.tsv
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"walkthrough-rows=2"* ]]
}

@test "a numbered step with no row in the map fails" {
	run walk walkthrough-map-unmapped.tsv
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"numbered step '2. Second step' has no row"* ]]
}

@test "a row naming a heading the walkthrough does not have fails" {
	run walk walkthrough-map-bad-heading.tsv
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no heading '## 9. No Such Step'"* ]]
}

@test "a row whose spec asserts no such string fails" {
	run walk walkthrough-map-bad-string.tsv
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"asserts no 'no such assertion string'"* ]]
}

@test "a row naming a spec file that does not exist fails" {
	run walk walkthrough-map-missing-spec.tsv
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no such spec:"* ]]
}

@test "an uncovered step whose gap id is not recorded fails" {
	run walk walkthrough-map-unrecorded-gap.tsv
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"GAP-FIXTURE-NOT-RECORDED"* ]]
	[[ "$output" == *"not recorded in"* ]]
}

@test "a row with fewer than three fields fails" {
	run walk walkthrough-map-short-row.tsv
	echo "$output"
	[ "$status" -eq 1 ]
	[[ "$output" == *"three tab-separated fields"* ]]
}

# ---------------------------------------------------------------------------
# The real walkthrough map
# ---------------------------------------------------------------------------

@test "every numbered step of docs/EAP/onboarding.md has a row in the real map" {
	local map="test/fixtures/walkthrough-map.tsv" doc="docs/EAP/onboarding.md"
	[ -f "$map" ]
	local steps rows
	steps="$(grep -c '^## [0-9]\+\. ' "$doc")"
	rows="$(grep -v '^#' "$map" | grep -c '	')"
	echo "steps=$steps rows=$rows"
	[ "$steps" -ge 5 ]
	[ "$rows" -ge "$steps" ]
}

@test "every gap id cited by the real map is recorded in the gaps document" {
	local map="test/fixtures/walkthrough-map.tsv" gaps="docs/signalloom/alignment-gaps.md"
	[ -f "$gaps" ]
	local cited=0 id
	while IFS=$'\t' read -r _ spec id; do
		[ "$spec" = "-" ] || continue
		cited=$((cited + 1))
		grep -qF -- "$id" "$gaps"
	done < <(grep -v '^#' "$map")
	echo "cited=$cited"
	[ "$cited" -ge 1 ]
}
