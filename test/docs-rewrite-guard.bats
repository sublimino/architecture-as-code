#!/usr/bin/env bats
#
# scripts/docs-rewrite-guard.sh compares a rewritten Markdown file with its
# committed version and reports every fact-bearing token that changed. A
# style rewrite must keep every command, path, number, link, and heading.
#
# Each test builds a small git repository in a temporary directory, commits
# one page, changes it, and checks the verdict. A guard that reports nothing
# looks the same as a guard that checks nothing, so each token kind has a
# planted change that must fail it, and one prose-only change that must pass.
#
# No cluster and no network: bash, awk, git, and diff only.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	guard="$repo_root/scripts/docs-rewrite-guard.sh"
	fixture="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$fixture/scripts"
	cp "$guard" "$fixture/scripts/"
	git -C "$fixture" init -q
	git -C "$fixture" -c user.name=t -c user.email=t@t config commit.gpgsign false
	printf '# Page\n\n## Setup\n\nRun `make up` on port 8675; it reads [the file](docs/a.md) and https://example.com/x in 3 steps.\n\n```bash\nmake up\n```\n' >"$fixture/page.md"
	git -C "$fixture" add -A
	git -C "$fixture" -c user.name=t -c user.email=t@t commit -q -m base
}

run_guard() {
	run "$fixture/scripts/docs-rewrite-guard.sh" "$@"
}

@test "an unchanged page keeps its tokens" {
	run_guard page.md
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"page.md: tokens kept"* ]]
}

@test "a prose-only rewrite that splits the sentence passes" {
	printf '# Page\n\n## Setup\n\nRun `make up` on port 8675. It reads [the file](docs/a.md) and https://example.com/x in 3 steps.\n\n```bash\nmake up\n```\n' >"$fixture/page.md"
	run_guard page.md
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a changed number fails" {
	sed -i 's/8675/8676/' "$fixture/page.md"
	run_guard page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"< number"$'\t'"8675"* ]]
	[[ "$output" == *"> number"$'\t'"8676"* ]]
}

@test "a changed inline code span fails" {
	sed -i 's/`make up` on/`make down` on/' "$fixture/page.md"
	run_guard page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"code"$'\t'"\`make down\`"* ]]
}

@test "a changed link target fails" {
	sed -i 's|(docs/a.md)|(docs/b.md)|' "$fixture/page.md"
	run_guard page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"link"$'\t'"docs/b.md"* ]]
}

@test "a changed URL fails" {
	sed -i 's|example.com/x|example.com/y|' "$fixture/page.md"
	run_guard page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"url"$'\t'"https://example.com/y"* ]]
}

@test "a changed line inside a code fence fails" {
	sed -i '8s/make up/make up --force/' "$fixture/page.md"
	run_guard page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"fence"$'\t'"make up --force"* ]]
}

@test "a changed heading fails because its anchor changes" {
	sed -i 's/^## Setup/## Set up/' "$fixture/page.md"
	run_guard page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"heading"$'\t'"Set up"* ]]
}

@test "a deleted number fails even when the word count grows" {
	printf '# Page\n\n## Setup\n\nRun `make up` on the port. It reads [the file](docs/a.md) and https://example.com/x in several short steps.\n\n```bash\nmake up\n```\n' >"$fixture/page.md"
	run_guard page.md
	[ "$status" -eq 1 ]
	[[ "$output" == *"< number"$'\t'"8675"* ]]
	[[ "$output" == *"< number"$'\t'"3"* ]]
}

@test "a file that does not exist is a usage error" {
	run_guard missing.md
	[ "$status" -eq 2 ]
}
