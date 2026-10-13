#!/usr/bin/env bats
#
# Worktree hygiene and 21-day osramp prune check.
#
# @id      worktree-hygiene
# @target  scripts/check-worktree-hygiene.sh, .gitignore
# @doc     AGENTS.md

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	SCRIPT="$REPO_ROOT/scripts/check-worktree-hygiene.sh"
	TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/worktree-hygiene.XXXXXX")"
	FAKE_REPO="/home/andy/src/cp/osramp-demo"
	NOW_EPOCH=1791914400 # 2026-10-13T18:00:00Z
}

teardown() {
	rm -rf "$TEST_TMP"
}

@test "check-worktree-hygiene.sh is executable and .claude/worktrees/ is gitignored" {
	[ -x "$SCRIPT" ]
	grep -qxF '.claude/worktrees/' "$REPO_ROOT/.gitignore"
}

@test "rejects worktree created inside REPO_ROOT/.claude/worktrees/agent-xyz or REPO_ROOT/sub-worktree" {
	local wt_file="$TEST_TMP/porcelain-inrepo.txt"
	cat > "$wt_file" <<-EOF
	worktree $FAKE_REPO
	HEAD e01cc2bf00000000000000000000000000000000
	branch refs/heads/main

	worktree $FAKE_REPO/.claude/worktrees/agent-xyz
	HEAD 1111111111111111111111111111111111111111
	branch refs/heads/worktree-agent-xyz
	# mtime $(( NOW_EPOCH - 3600 ))

	worktree $FAKE_REPO/sub-worktree
	HEAD 2222222222222222222222222222222222222222
	detached
	# mtime $(( NOW_EPOCH - 7200 ))
	EOF

	run "$SCRIPT" --repo-root "$FAKE_REPO" --worktree-list-file "$wt_file" --now-epoch "$NOW_EPOCH"
	[ "$status" -eq 1 ]
	[[ "$output" == *"in-repo secondary git worktree detected: $FAKE_REPO/.claude/worktrees/agent-xyz"* ]]
	[[ "$output" == *"in-repo secondary git worktree detected: $FAKE_REPO/sub-worktree"* ]]
	[[ "$output" == *"FAILED: 2 offending in-repo worktree(s) found"* ]]
}

@test "accepts valid external worktrees in ~/src/.worktrees/osramp-demo/..." {
	local wt_file="$TEST_TMP/porcelain-external.txt"
	cat > "$wt_file" <<-EOF
	worktree $FAKE_REPO
	HEAD e01cc2bf00000000000000000000000000000000
	branch refs/heads/main

	worktree /home/andy/src/.worktrees/osramp-demo/feat/clean-branch
	HEAD 3333333333333333333333333333333333333333
	branch refs/heads/feat/clean-branch
	# mtime $(( NOW_EPOCH - 86400 ))

	worktree /tmp/osramp-worktrees/cleanup-job1-hygiene
	HEAD 4444444444444444444444444444444444444444
	branch refs/heads/cleanup/job1-worktree-hygiene
	# mtime $(( NOW_EPOCH - 600 ))
	EOF

	run "$SCRIPT" --repo-root "$FAKE_REPO" --worktree-list-file "$wt_file" --now-epoch "$NOW_EPOCH"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "baseline exemption allows legacy in-repo worktree <= 21 days old but rejects when > 21 days old" {
	local wt_file="$TEST_TMP/porcelain-baseline.txt"
	local baseline_file="$TEST_TMP/baseline.txt"
	echo ".claude/worktrees/agent-legacy" > "$baseline_file"

	# 21 days old exactly: allowed by baseline
	cat > "$wt_file" <<-EOF
	worktree $FAKE_REPO
	HEAD e01cc2bf00000000000000000000000000000000
	branch refs/heads/main

	worktree $FAKE_REPO/.claude/worktrees/agent-legacy
	HEAD 5555555555555555555555555555555555555555
	branch refs/heads/legacy-agent
	# mtime $(( NOW_EPOCH - 21 * 86400 ))
	EOF

	run "$SCRIPT" --repo-root "$FAKE_REPO" --worktree-list-file "$wt_file" --baseline-file "$baseline_file" --max-age-days 21 --now-epoch "$NOW_EPOCH"
	[ "$status" -eq 0 ]

	# 22 days old: exceeds 21 days, baseline exemption expires and guard rejects it
	cat > "$wt_file" <<-EOF
	worktree $FAKE_REPO
	HEAD e01cc2bf00000000000000000000000000000000
	branch refs/heads/main

	worktree $FAKE_REPO/.claude/worktrees/agent-legacy
	HEAD 5555555555555555555555555555555555555555
	branch refs/heads/legacy-agent
	# mtime $(( NOW_EPOCH - 22 * 86400 ))
	EOF

	run "$SCRIPT" --repo-root "$FAKE_REPO" --worktree-list-file "$wt_file" --baseline-file "$baseline_file" --max-age-days 21 --now-epoch "$NOW_EPOCH"
	[ "$status" -eq 1 ]
	[[ "$output" == *"in-repo secondary git worktree detected: $FAKE_REPO/.claude/worktrees/agent-legacy"* ]]
}

@test "age filter --list-stale-osramp --max-age-days 21 only flags osramp worktrees > 21 days old" {
	local wt_file="$TEST_TMP/porcelain-ages.txt"
	cat > "$wt_file" <<-EOF
	worktree $FAKE_REPO
	HEAD e01cc2bf00000000000000000000000000000000
	branch refs/heads/main
	# mtime $(( NOW_EPOCH - 90 * 86400 ))

	worktree /home/andy/src/.worktrees/osramp-demo/fresh-10d
	HEAD 1111111111111111111111111111111111111111
	branch refs/heads/feat/fresh-10d
	# mtime $(( NOW_EPOCH - 10 * 86400 ))

	worktree /home/andy/src/.worktrees/osramp-demo/boundary-21d
	HEAD 2222222222222222222222222222222222222222
	branch refs/heads/feat/boundary-21d
	# mtime $(( NOW_EPOCH - 21 * 86400 ))

	worktree /home/andy/src/.worktrees/osramp-demo/stale-22d
	HEAD 3333333333333333333333333333333333333333
	branch refs/heads/feat/stale-22d
	# mtime $(( NOW_EPOCH - 22 * 86400 ))

	worktree /home/andy/src/.worktrees/00043/osramp-demo
	HEAD 4444444444444444444444444444444444444444
	detached
	# mtime $(( NOW_EPOCH - 35 * 86400 ))

	worktree /home/andy/src/.worktrees/other-project/stale-40d
	HEAD 5555555555555555555555555555555555555555
	branch refs/heads/feat/other-40d
	# mtime $(( NOW_EPOCH - 40 * 86400 ))
	EOF

	run "$SCRIPT" --repo-root "$FAKE_REPO" --worktree-list-file "$wt_file" --list-stale-osramp --max-age-days 21 --now-epoch "$NOW_EPOCH"
	[ "$status" -eq 0 ]
	[[ "$output" == *"path=/home/andy/src/.worktrees/osramp-demo/stale-22d"* ]]
	[[ "$output" == *"path=/home/andy/src/.worktrees/00043/osramp-demo"* ]]
	[[ "$output" != *"fresh-10d"* ]]
	[[ "$output" != *"boundary-21d"* ]]
	[[ "$output" != *"other-project"* ]]
	[[ "$output" != *"path=$FAKE_REPO	"* ]]
}
