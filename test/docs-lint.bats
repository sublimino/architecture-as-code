#!/usr/bin/env bats
#
# scripts/docs-lint.sh enforces the rules in docs/documentation-style.md on the
# navigation-layer documentation.
#
# The first test runs the lint on the real tree. Each other test builds a small
# git repository in a temporary directory, plants one defect, and checks that
# the lint reports it. A lint that reports nothing looks the same as a lint that
# checks nothing, so every check has a planted defect that must fail it.
#
# The fixtures are made in $BATS_TEST_TMPDIR, never in the scanned tree. A
# fixture inside the tree would make the lint scan its own planted defects.
#
# No cluster and no network: bash, awk, git, and rg only.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	lint="$repo_root/scripts/docs-lint.sh"
	fixture="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$fixture/docs" "$fixture/slice"
	git -C "$fixture" init -q
	printf 'up:\n\ttrue\ndemo-%%-up:\n\ttrue\n' >"$fixture/Makefile"
	printf 'build:\n\ttrue\n' >"$fixture/slice/Makefile"
	printf '# Target\n\n## Known Section\n\nText.\n' >"$fixture/docs/target.md"
	printf '# Index\n\nRead [the target](target.md).\n' >"$fixture/docs/README.md"
}

# lint_fixture FILE... — run the lint against the fixture repository.
lint_fixture() {
	git -C "$fixture" add -A
	DOCS_LINT_ROOT="$fixture" run "$lint" "$@"
}

@test "the navigation layer passes the lint" {
	run "$lint"
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"file(s) clean"* ]]
}

@test "a clean fixture passes (positive control)" {
	printf '# Clean\n\nRun `make up`. Then run `make -C slice build`.\nRead [the section](docs/target.md#known-section).\n' >"$fixture/clean.md"
	lint_fixture clean.md docs/README.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a broken relative link fails" {
	printf '# Page\n\nRead [the guide](docs/missing.md).\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:3: link: target does not exist: docs/missing.md"* ]]
}

@test "a broken heading anchor fails" {
	printf '# Page\n\nRead [the section](docs/target.md#no-such-section).\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"anchor: no heading '#no-such-section'"* ]]
}

@test "a raw space in a link target fails" {
	printf '# Page\n\nRead [the proposal](docs/My Proposal.md).\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"space: link target has a raw space"* ]]
}

@test "a missing make target fails" {
	printf '# Page\n\nRun `make no-such-target` to start.\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"make: no target 'no-such-target'"* ]]
}

@test "a missing make target inside a fenced block fails" {
	printf '# Page\n\nRun this command.\n\n```bash\nmake no-such-target\n```\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:6: make: no target 'no-such-target'"* ]]
}

@test "a pattern make target and a make -C target pass" {
	printf '# Page\n\nRun `make demo-signalloom-up`. Then run `make -C slice build`.\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a make -C target missing from that Makefile fails" {
	printf '# Page\n\nRun `make -C slice up`.\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"no target 'up' in slice/Makefile"* ]]
}

@test "a semicolon in prose fails" {
	printf '# Page\n\nThe cache persists; the cluster does not.\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:3: semicolon:"* ]]
}

@test "a semicolon inside inline code passes" {
	printf '# Page\n\nRun `a; b` in the shell.\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a sentence over the word limit fails" {
	printf '# Page\n\nOne two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix.\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"long: 26 words (max 25)"* ]]
}

@test "the word limit is configurable" {
	printf '# Page\n\nThis sentence has exactly seven words here.\n' >"$fixture/page.md"
	git -C "$fixture" add -A
	DOCS_LINT_ROOT="$fixture" DOCS_LINT_MAX_WORDS=5 run "$lint" page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"long: 7 words (max 5)"* ]]
}

@test "a banned word fails" {
	printf '# Page\n\nUtilize the cache to save time.\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"word: banned word 'utilize'"* ]]
}

@test "a banned word inside a docs-lint off region passes" {
	printf '# Page\n\n<!-- docs-lint: off -->\nUtilize the cache; it is fast.\n<!-- docs-lint: on -->\n\nUse the cache.\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "prose inside a fenced code block and a table is not checked" {
	printf '# Page\n\n```text\nUtilize this; it is output.\n```\n\n| a | b |\n|---|---|\n| x; y | utilize |\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "an unclosed code fence fails" {
	printf '# Page\n\nText.\n\n```bash\nmake up\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:5: fence: code fence opened here is never closed"* ]]
}

@test "a docs page missing from the index fails" {
	printf '# Lost\n\nText.\n' >"$fixture/docs/lost.md"
	lint_fixture docs/README.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"orphan: not linked from the index: docs/lost.md"* ]]
}

@test "an indexed page with spaces in its name passes when the link is encoded" {
	printf '# Spaced\n\nText.\n' >"$fixture/docs/My Page.md"
	printf '# Index\n\nRead [the target](target.md) and [the page](My%%20Page.md).\n' >"$fixture/docs/README.md"
	lint_fixture docs/README.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a file that does not exist is a usage error" {
	lint_fixture no-such-file.md
	[ "$status" -eq 2 ]
}

@test "a repeated heading gets a numbered anchor" {
	printf '# Page\n\n## Setup\n\nOne.\n\n## Setup\n\nTwo.\n\nRead [the second](#setup-1) and [the first](#setup).\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
}
