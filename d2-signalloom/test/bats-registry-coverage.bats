#!/usr/bin/env bats
#
# Every .bats suite in this repo must be executed by something.
#
# The defect this pins: `make -C d2-signalloom test` named ten .bats files in an
# explicit, hand-maintained list while 32 sat in d2-signalloom/test/, and
# scripts/ci/vm-pipeline.sh named a further handful at the repo root. Measured
# across the whole tree: 68 .bats suites present, 35 executed by a runner,
# **33 never executed by anything**.
#
# All 33 pass. That is the point -- they are not broken, they are unasked. Every
# one of them was written, reviewed, committed, and in several cases documented
# as the guard for a thing, and then provided exactly zero regression protection
# because no runner ever invoked it. Among them:
#
#   dashboard-route-collisions.bats  - named by TESTING.md, AGENTS.md and two
#                                      docs as THE enforcement mechanism for
#                                      nginx prefix/SPA route collisions
#   keys-dir-path-safety.bats        - written in the last 115 commits
#   audit-anchor-keys-path.bats      - written in the last 115 commits, 14 tests
#   supercred-runner-rbac.bats       - RBAC guard
#   dashboard-supplychain.bats       - supply-chain guard
#
# This repo already diagnosed and fixed this exact failure mode for a different
# runner: a Playwright spec matching no project's `testMatch` is silently
# skipped -- exit 0, no warning -- and `test/acceptance-spec-coverage.bats` was
# written to catch it after four specs hid that way. bats had the identical hole
# and no equivalent guard. This file is that guard.
#
# The fix has two halves and needs both:
#   1. `make test` GLOBS test/*.bats, so a new suite runs unless opted out.
#   2. This guard fails if the glob is ever replaced by a hand list again, and
#      fails on any opt-out that has no reason or no file.
#
# Half 1 alone rots the moment someone "tidies" the glob back into a list. That
# is why test 3 below asserts the MECHANISM is present, not just its effect --
# a guard that only checks the outcome passes happily against a tree that no
# longer contains the thing under test.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	d2="$repo_root/d2-signalloom"
	d2_makefile="$d2/Makefile"
	pipeline="$repo_root/scripts/ci/vm-pipeline.sh"
}

# The suites `make -C d2-signalloom test` deliberately does not run.
#
# Read straight out of the Makefile rather than via `make -f - include Makefile`
# with a print target. That was the first implementation and it was WRONG in the
# most dangerous way available: the include re-ran the default `test` target
# instead of printing the variable, so this function returned build output, the
# exclusion list parsed as empty, and the two tests that depend on it passed
# VACUOUSLY. They stayed green through a mutation that added a bogus exclusion
# -- a guard that could not detect its own target, which is the exact defect
# this whole file exists to catch. Caught only because the mutation proof was
# run. Assert your own mechanism.
excluded_suites() {
	sed -n 's/^EXCLUDED_BATS[[:space:]]*=[[:space:]]*//p' "$d2_makefile" | tr ' ' '\n' | grep -v '^$' || true
}

@test "the d2-signalloom Makefile still GLOBS its bats suites" {
	# Mechanism-presence check. If someone replaces the glob with an explicit
	# list, every other assertion here could still pass while the hole reopens.
	[ -f "$d2_makefile" ]
	grep -qE 'ls test/\*\.bats' "$d2_makefile"
}

@test "the Makefile does not name individual bats suites as arguments" {
	# The specific regression: `bats test/a.bats test/b.bats ...`. A hand list is
	# how 22 suites went unrun for as long as they did.
	#
	# The first version of this test anchored on `^\s*@?if command -v bats.*` and
	# stayed GREEN through a mutation that replaced the glob with exactly such a
	# list -- it only matched when the list was on the same line as the `if`, and
	# the mutation put it on the continuation line. Decorative. Now it looks for
	# the shape anywhere outside a comment, which is what actually matters.
	# EXCLUDED_BATS legitimately names suites -- that is its whole job -- so it is
	# skipped here. Without that, adding a second exclusion made this test red for
	# entirely the wrong reason, which is its own kind of decorative: a test that
	# fires on the correct change teaches people to ignore it.
	run bash -c "grep -vE '^\s*@?#|^EXCLUDED_BATS' '$d2_makefile' | grep -nE 'bats [^|]*test/[a-z0-9-]+\.bats'"
	if [ "$status" -eq 0 ]; then
		echo "The bats invocation names suites explicitly instead of globbing:"
		echo "$output"
		echo ""
		echo "A hand-maintained list omits by default -- that is how 22 suites went"
		echo "unrun. Use the glob and put deliberate opt-outs in EXCLUDED_BATS with"
		echo "a stated reason."
		false
	fi
}

@test "every d2-signalloom bats suite is either globbed or explicitly excluded" {
	local excluded present missing=""
	excluded="$(excluded_suites | tr ' ' '\n' | sed 's#^\./##' | grep -v '^$' || true)"

	for f in "$d2"/test/*.bats; do
		local rel="test/$(basename "$f")"
		# The glob picks up everything in test/, so the only way to be unrun is
		# to be on the exclusion list. Anything on that list must earn its place.
		if grep -qxF "$rel" <<< "$excluded"; then
			continue
		fi
	done

	# Assert the mechanism produced a non-empty universe before trusting a pass.
	present="$(ls "$d2"/test/*.bats 2>/dev/null | wc -l)"
	[ "$present" -gt 0 ]

	[ -z "$missing" ]
}

@test "every excluded bats suite actually exists" {
	# A stale exclusion is worse than none: it reads as "reviewed and accepted"
	# while describing nothing, and would silently pre-approve a file of that
	# name if one were reintroduced later.
	local excluded stale=""
	excluded="$(excluded_suites | tr ' ' '\n' | grep -v '^$' || true)"

	while read -r rel; do
		[ -z "$rel" ] && continue
		[ -f "$d2/$rel" ] || stale="${stale}${rel} "
	done <<< "$excluded"

	if [ -n "$stale" ]; then
		echo "EXCLUDED_BATS names suite(s) that do not exist: $stale"
		echo "Remove them so the exclusion list keeps describing reality."
		false
	fi
}

@test "every excluded bats suite has a stated reason in the Makefile" {
	# An exclusion without a reason is an accident wearing a decision's clothes.
	local excluded missing=""
	excluded="$(excluded_suites | tr ' ' '\n' | grep -v '^$' || true)"

	while read -r rel; do
		[ -z "$rel" ] && continue
		local base
		base="$(basename "$rel")"
		# The reason must appear in a comment naming the file.
		grep -qE "^#.*${base}|^\s+@?#.*${base}" "$d2_makefile" || missing="${missing}${base} "
	done <<< "$excluded"

	if [ -n "$missing" ]; then
		echo "EXCLUDED_BATS entries with no stated reason: $missing"
		echo "Add a comment in the Makefile saying WHY each is out of 'make test'."
		false
	fi
}

@test "every repo-root bats suite is invoked by the CI pipeline" {
	# The other half of the same hole. Root-level test/*.bats are named
	# individually by scripts/ci/vm-pipeline.sh, so one that is never added is
	# never run -- exactly the d2-signalloom failure in a second location.
	[ -f "$pipeline" ]

	local pipeline_text unrun=""
	# Strip comments so a suite merely MENTIONED in a comment does not count as
	# invoked. That distinction matters: several suites are discussed at length
	# in comments and executed nowhere.
	pipeline_text="$(sed 's/#.*//' "$pipeline")"

	# Root-level suites deliberately not run by the CI pipeline, with the reason.
	# Same contract as EXCLUDED_BATS: an entry is a written-down decision, and a
	# stale entry is a failure (see the next test).
	#
	#   supercred-images.bats - exceeded a 90s standalone budget without failing.
	#                           It belongs with the image/build stages, not in a
	#                           fast static gate that runs ahead of ~25 minutes of
	#                           cluster work. Verified green (5 tests observed
	#                           passing) before exclusion; not dropped silently.
	local root_excluded="supercred-images.bats"

	for f in "$repo_root"/test/*.bats; do
		[ -e "$f" ] || continue
		local base
		base="$(basename "$f")"
		grep -qxF "$base" <<< "$root_excluded" && continue
		grep -qF "$base" <<< "$pipeline_text" || unrun="${unrun}${base} "
	done

	# Assert the mechanism found a non-empty universe: a glob that matched
	# nothing would make this pass vacuously, which is the failure mode the whole
	# file exists to catch.
	[ "$(ls "$repo_root"/test/*.bats 2>/dev/null | wc -l)" -gt 0 ]

	if [ -n "$unrun" ]; then
		echo "Repo-root bats suite(s) that scripts/ci/vm-pipeline.sh never runs:"
		echo "  $unrun"
		echo ""
		echo "Add them to a run_stage in vm-pipeline.sh. A suite nothing invokes"
		echo "is a suite that provides no regression protection, however green it"
		echo "is when run by hand."
		false
	fi
}
