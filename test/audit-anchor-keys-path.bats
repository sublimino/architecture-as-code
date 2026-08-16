#!/usr/bin/env bats
#
# Tier 1 for signing-key path resolution — no cluster, no database, no keys.
#
# THE INCIDENT
#
# `make audit-anchor-tamper-demo` passes KEYS_DIR as an absolute path, because
# in a worktree the Makefile resolves it through --git-common-dir. The demo
# script concatenated the repo root onto it:
#
#     --private-key "${OLDPWD}/${KEYS_DIR}/witness.pem"
#
# which for KEYS_DIR=/home/andy/src/cp/osramp-demo/.keys produced
#
#     /tmp/osramp-wt/audit-transparency-anchor/home/andy/src/cp/osramp-demo/.keys/witness.pem
#
# The leading slash is simply swallowed by the join. It went unnoticed because
# the authoring worktree happened to contain its own .keys, so the relative
# default worked there — and .keys is gitignored and therefore per-checkout, so
# a fresh worktree having none and the Makefile pointing elsewhere is the NORMAL
# case, not an exotic one.
#
# The Makefile had the mirror-image bug at the same time. Its recipes cd into
# the package directory before invoking the CLI, so a RELATIVE KEYS_DIR — the
# default in a single checkout, and on a CI VM which gcp-ci.sh tars without
# .git so no git branch can fire — resolved against that subdirectory instead of
# the repo root. Absolute broke one side, relative broke the other.
#
# Following test/supercred-state.bats: every guarantee below is proved to be
# capable of failing, by asserting the exact shape of the bug and not merely
# that the happy path works. An assertion that cannot go red is not coverage.

setup() {
	repo="$BATS_TEST_DIRNAME/.."
	# Deliberately OUTSIDE the repository, which is the case that was broken.
	outside="$BATS_TEST_TMPDIR/elsewhere/.keys"
	mkdir -p "$outside"

	# shellcheck source=scripts/lib/keys.sh
	source "$BATS_TEST_DIRNAME/../scripts/lib/keys.sh"
}

# ── keys_dir_abs ──────────────────────────────────────────────────────────────

@test "an absolute KEYS_DIR is returned unchanged" {
	KEYS_DIR="$outside" run keys_dir_abs /some/base
	[ "$status" -eq 0 ]
	[ "$output" = "$outside" ]
}

@test "an absolute KEYS_DIR is NOT joined onto the base (the regression)" {
	KEYS_DIR="$outside" run keys_dir_abs /repo/root
	# The precise shape of the shipped bug: base swallowed the leading slash.
	[ "$output" != "/repo/root${outside}" ]
	case "$output" in
		/repo/root/*) false ;;
		*) true ;;
	esac
}

@test "a relative KEYS_DIR is anchored to the base" {
	KEYS_DIR=".keys" run keys_dir_abs /repo/root
	[ "$output" = "/repo/root/.keys" ]
}

@test "a relative KEYS_DIR does not resolve against the caller's subdirectory" {
	# What broke the Makefile side: resolved against the package dir after cd.
	KEYS_DIR=".keys" run keys_dir_abs /repo/root
	[ "$output" != ".keys" ]
	[ "$output" != "/repo/root/d2-signalloom/apps/fe-signalloom/src/.keys" ]
}

@test "a trailing slash on the base does not double up" {
	KEYS_DIR=".keys" run keys_dir_abs /repo/root/
	[ "$output" = "/repo/root/.keys" ]
}

@test "the base defaults to the working directory" {
	cd "$BATS_TEST_TMPDIR"
	KEYS_DIR=".keys" run keys_dir_abs
	[ "$output" = "$BATS_TEST_TMPDIR/.keys" ]
}

@test "keys_dir itself is unchanged for the four scripts that already use it" {
	# push-local.sh, admission-demo.sh, revocation-demo.sh and
	# build-sign-dashboard.sh all call keys_dir() and never change directory.
	# Adding keys_dir_abs() must not have altered what they see.
	KEYS_DIR="$outside" run keys_dir
	[ "$output" = "$outside" ]
	KEYS_DIR=".keys" run keys_dir
	[ "$output" = ".keys" ]
}

# ── The demo script ───────────────────────────────────────────────────────────

@test "the demo script never concatenates a base onto KEYS_DIR" {
	local demo="$repo/scripts/audit-anchor-tamper-demo.sh"
	# Assert the subject exists before reading a pass out of grep's silence. If
	# the script is renamed or moved, grep exits 2 and `-ne 0` reports the
	# forbidden pattern as absent -- a pass earned by scanning nothing.
	[ -f "$demo" ]

	run grep -n 'OLDPWD}/${KEYS_DIR}' "$demo"
	# Exactly 1, not merely non-zero. grep reserves 1 for "ran fine, selected no
	# lines" and 2 for "something went wrong", and those are different findings.
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "the demo script resolves keys through the shared helper" {
	run grep -c 'keys_dir_abs' "$repo/scripts/audit-anchor-tamper-demo.sh"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

@test "the demo script reports the absolute keys path it was given" {
	# The preflight states the resolved path once, before touching the database,
	# and every later invocation is built from that same variable. An earlier
	# version of this test only asserted the script exited non-zero, which it did
	# with and without the bug -- an assertion that cannot go red is not
	# coverage, so it asserts the resolved path instead.
	run timeout 120 env KEYS_DIR="$outside" \
		DATABASE_URL="postgresql://127.0.0.1:1/none" \
		"$repo/scripts/audit-anchor-tamper-demo.sh"
	[[ "$output" == *"signing keys: $outside"* ]]
	# And never the swallowed-slash shape the bug produced.
	[[ "$output" != *"$repo/$outside"* ]]
}

@test "the demo script refuses to run when the resolved key is absent" {
	# Absent AND uncreatable, so the generate branch cannot paper over it.
	unwritable="$BATS_TEST_TMPDIR/unwritable"
	mkdir -p "$unwritable"
	chmod 500 "$unwritable"
	run timeout 120 env KEYS_DIR="$unwritable/nope/.keys" \
		DATABASE_URL="postgresql://127.0.0.1:1/none" \
		"$repo/scripts/audit-anchor-tamper-demo.sh"
	chmod 700 "$unwritable"
	[ "$status" -ne 0 ]
}

# ── The Makefile ──────────────────────────────────────────────────────────────

@test "make passes an absolute key path when KEYS_DIR is absolute" {
	run make -C "$repo" -n audit-anchor-verify KEYS_DIR="$outside"
	[ "$status" -eq 0 ]
	[[ "$output" == *"--public-key $outside/witness-pub.pem"* ]]
}

@test "make passes an absolute key path when KEYS_DIR is relative" {
	# The recipes cd into the package directory, so a bare '.keys' would resolve
	# against d2-signalloom/apps/fe-signalloom/src and silently miss.
	run make -C "$repo" -n audit-anchor-verify KEYS_DIR=.keys
	[ "$status" -eq 0 ]
	[[ "$output" == *"--public-key /"* ]]
	[[ "$output" != *"--public-key .keys/"* ]]
}

@test "every audit-anchor recipe that cds uses the absolutised key variable" {
	for target in audit-anchor-checkpoint audit-anchor-verify audit-anchor-show; do
		run make -C "$repo" -n "$target" KEYS_DIR=.keys
		[ "$status" -eq 0 ]
		[[ "$output" != *"-key .keys/"* ]]
	done
}
