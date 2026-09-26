#!/usr/bin/env bats
#
# scripts/docs-lint.sh enforces the rules in docs/documentation-style.md on the
# living documentation. Decision records get link checks only.
#
# The first test runs the lint on the real tree. Each other test builds a small
# git repository in a temporary directory, plants one defect, and checks that
# the lint reports it. A lint that reports nothing looks the same as a lint that
# checks nothing, so every check has a planted defect that must fail it.
# test/docs-index-sync.bats proves that the RECORDS pattern in the script and
# the "Decision records" section of docs/README.md agree.
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

@test "the tracked documentation passes the lint" {
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

@test "an inline-code path under a tracked top-level directory that does not exist fails" {
	printf '# Page\n\nRead `docs/missing/file.md` and `docs/target.md`.\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:3: path: no such path in the tree: docs/missing/file.md"* ]]
	[[ "$output" != *"docs/target.md"* ]]
}

@test "an inline-code path that is gitignored, outside the tree, or an MCP method passes" {
	printf 'docs/build/\n' >"$fixture/.gitignore"
	printf '# Page\n\nRead `docs/build/out.json`, `/etc/hosts`, `other-repo/x/y.md`, and call `tools/list`.\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
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

@test "a root-level record missing from the index fails, and passes once linked" {
	printf '# Report\n\nText.\n' >"$fixture/PREFLIGHT-REPORT.md"
	lint_fixture docs/README.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"orphan: root-level record not linked from the index: PREFLIGHT-REPORT.md"* ]]
	printf '# Index\n\nRead [the target](target.md) and [the report](../PREFLIGHT-REPORT.md).\n' >"$fixture/docs/README.md"
	lint_fixture docs/README.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a Mermaid fence directly after a heading fails" {
	printf '# Page\n\n## Flow\n\n```mermaid\nflowchart LR\n  a --> b\n```\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:5: diagram: no prose line before this Mermaid diagram"* ]]
}

@test "a Mermaid fence directly after another code block fails" {
	printf '# Page\n\nText.\n\n```bash\nmake up\n```\n\n```mermaid\nflowchart LR\n  a --> b\n```\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:9: diagram:"* ]]
}

@test "a Mermaid fence after a prose sentence passes" {
	printf '# Page\n\n## Flow\n\nThe diagram shows the flow from a to b.\n\n```mermaid\nflowchart LR\n  a --> b\n```\n\n- The list item before this diagram is prose too.\n\n```mermaid\nflowchart LR\n  b --> c\n```\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
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

@test "a broken link inside a table row fails" {
	printf '# Page\n\n| Doc | Purpose |\n|---|---|\n| [guide](docs/missing.md) | text |\n' >"$fixture/page.md"
	lint_fixture page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"page.md:5: link: target does not exist: docs/missing.md"* ]]
}

@test "a heading that contains a link has the anchor of its label" {
	printf '# Page\n\n## Read [the guide](docs/target.md) first\n\nText.\n\nSee [above](#read-the-guide-first).\n' >"$fixture/page.md"
	lint_fixture page.md
	echo "$output"
	[ "$status" -eq 0 ]
}

# default_lint — run the lint with no file arguments, the way `make docs-lint`
# does. Every tracked file in the fixture gets its tier from the patterns in
# the script. An extra argument replaces the correctness-only pattern.
default_lint() {
	git -C "$fixture" add -A
	DOCS_LINT_ROOT="$fixture" DOCS_LINT_CORRECTNESS_ONLY="${1:-^paper/}" run "$lint"
}

@test "default mode: a decision record gets link checks only" {
	mkdir -p "$fixture/MEMORY"
	printf '# Record\n\nWe ran `make gone-target`; it worked in the past.\n' >"$fixture/MEMORY/old.md"
	default_lint
	echo "$output"
	[ "$status" -eq 0 ]
	printf '# Record\n\nSee [the file](missing.md).\n' >"$fixture/MEMORY/old.md"
	default_lint
	[ "$status" -eq 1 ]
	[[ "$output" == *"MEMORY/old.md:3: link: target does not exist"* ]]
}

@test "default mode: a living doc gets every check" {
	mkdir -p "$fixture/runbook"
	printf '# Runbook\n\nThis sentence is fine; it has a semicolon that the style tier checks.\n' >"$fixture/runbook/README.md"
	default_lint
	[ "$status" -eq 1 ]
	[[ "$output" == *"runbook/README.md:3: semicolon:"* ]]
	[[ "$output" != *"docs/target.md"* ]]
}

@test "default mode: a correctness-only doc gets make and fence checks but not prose checks" {
	mkdir -p "$fixture/paper"
	printf '# Paper\n\nThis sentence is fine; the author wrote it and the lint leaves it alone.\n' >"$fixture/paper/README.md"
	default_lint '^paper/'
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"correctness checks: 1"* ]]
	printf '# Paper\n\nRun `make gone-target`.\n\n```bash\nmake up\n' >"$fixture/paper/README.md"
	default_lint '^paper/'
	[ "$status" -eq 1 ]
	[[ "$output" == *"paper/README.md:3: make: no target 'gone-target'"* ]]
	[[ "$output" == *"paper/README.md:5: fence:"* ]]
}

# pattern_of NAME — the value of the single-quoted or default-quoted pattern
# NAME in the lint script, without sourcing the script.
pattern_of() {
	sed -n "s/^$1='\(.*\)'$/\1/p; s/^$1=\"\${DOCS_LINT_[A-Z_]*:-\(.*\)}\"$/\1/p" "$lint"
}

@test "the correctness-only list names exactly these files, and each exists" {
	pattern="$(pattern_of CORRECTNESS_ONLY)"
	[ -n "$pattern" ]
	matched="$(git -C "$repo_root" -c core.quotepath=off ls-files '*.md' | while IFS= read -r f; do [[ "$f" =~ $pattern ]] && echo "$f"; true; done)"
	echo "$matched"
	expected="d2-signalloom/apps/dashboard-signalloom/src/help-content/connectors/entra.md
d2-signalloom/apps/dashboard-signalloom/src/help-content/connectors/okta.md
d2-signalloom/apps/dashboard-signalloom/src/help-content/connectors/openai.md"
	[ "$(printf '%s\n' "$matched" | sort)" = "$(printf '%s\n' "$expected" | sort)" ]
}

@test "the correctness-only pattern never matches a new file in the same directory" {
	pattern="$(pattern_of CORRECTNESS_ONLY)"
	f="d2-signalloom/apps/dashboard-signalloom/src/help-content/connectors/new-connector.md"
	! [[ "$f" =~ $pattern ]]
	f="d2-signalloom/apps/dashboard-signalloom/src/help-content/new-page.md"
	! [[ "$f" =~ $pattern ]]
}

@test "the ignored list is pinned, and every entry matches a tracked file" {
	pattern="$(pattern_of IGNORED)"
	parts=(
		'/bats-assert/'
		'^d2-signalloom/apps/docs-signalloom/src/'
		'(^|/)\.forge-prompt[^/]*\.md$'
		'(^|/)THIRD_PARTY_NOTICES\.md$'
	)
	joined="$(IFS='|'; echo "${parts[*]}")"
	[ "$pattern" = "$joined" ]
	for part in "${parts[@]}"; do
		n="$(git -C "$repo_root" -c core.quotepath=off ls-files '*.md' | while IFS= read -r f; do [[ "$f" =~ $part ]] && echo "$f"; done | wc -l)"
		echo "$part: $n"
		[ "$n" -ge 1 ]
	done
}

@test "docs-lint off markers appear only in the style guide" {
	files="$(git -C "$repo_root" -c core.quotepath=off grep -l 'docs-lint: off' -- '*.md' || true)"
	echo "$files"
	[ "$files" = "docs/documentation-style.md" ]
}

@test "default mode: an ignored file is not checked" {
	mkdir -p "$fixture/app"
	printf '# Prompt\n\nUtilize this; see [gone](missing.md).\n' >"$fixture/app/.forge-prompt.md"
	printf '# Notices\n\nUtilize this; see [gone](missing.md).\n' >"$fixture/app/THIRD_PARTY_NOTICES.md"
	printf '# Notices\n\nUtilize this; see [gone](missing.md).\n' >"$fixture/THIRD_PARTY_NOTICES.md"
	default_lint
	echo "$output"
	[ "$status" -eq 0 ]
}
