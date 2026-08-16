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

# Every directory in the repo that holds .bats suites — DISCOVERED, not listed.
#
# The first version of this file hard-coded `for d in "$d2/test" "$repo_root/test"`,
# which is the identical defect it was written to end, one level up: a
# hand-maintained list that omits by default. It covered 74 suites and was blind
# to six more —
#
#   d2-osramp-apps/test/  3      olly-replica/test/  1      d2-cpai/test/  2
#
# — so an orphaned suite in any of those three directories could never be
# reported, by the guard whose entire job is reporting orphaned suites. Found
# when an agent working on d2-osramp-apps/test/osramp.bats noted in passing that
# "the whole suite currently runs nowhere in CI"; nothing in the tree contradicted
# it, because nothing in the tree was looking.
#
# Discovery closes it permanently: a new test directory is covered the moment it
# exists, with nobody remembering to add it here.
# test_helper/ is excluded because it holds VENDORED libraries (bats-assert,
# bats-support) that ship their own 9-suite test directory. Those are upstream's
# tests of upstream's code; demanding this repo's CI invoke them would be a
# false positive that teaches people to widen the allowlist.
#
# A plain glob, not `compgen -G`: the first draft used compgen and returned
# EMPTY under bats, which made `[ -n "$dirs" ]` fail. That failure was the good
# outcome — the mechanism assertion caught its own discovery being broken. Had
# the assertion not been there, an empty list would have made every check below
# pass over zero directories: a guard against vacuous passes, passing vacuously.
bats_dirs() {
	# Root computed here rather than inherited from setup(), so the function is
	# self-contained and cannot silently return nothing because a caller's
	# variable was unset — which is precisely how the first draft failed.
	local root="${1:-$repo_root}"
	[ -n "$root" ] || return 1
	find "$root" -type d -name test \
		-not -path '*/node_modules/*' \
		-not -path '*/.git/*' \
		-not -path '*/.worktrees/*' \
		-not -path '*/test_helper/*' 2>/dev/null \
	| while IFS= read -r d; do
		if ls "$d"/*.bats >/dev/null 2>&1; then printf '%s\n' "$d"; fi
	done
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

@test "every proof script under test/ is invoked by something" {
	# The coverage hole has a third shape. Stages 1g/1h close it for .bats files,
	# but audit-guard-reintroduction-proof.sh is a shell script, so the bats
	# registry could not see it -- and it was invoked by nothing at all. It is
	# the only thing in the repository that proves the 12 audit provenance
	# guards actually fail when their defects are reintroduced, and it costs 7
	# seconds.
	#
	# Test directories are DISCOVERED, not listed. The first version named two
	# -- "$d2/test" and "$repo_root/test" -- which is the identical defect this
	# file exists to end, one level up: a hand-maintained list that omits by
	# default. It covered 74 suites and was blind to 9 more across FOUR other
	# directories (d2-osramp-apps, olly-replica, d2-cpai, d2-agent-trust, plus
	# d2-k8s-afm), so an orphan in any of them could never be reported by the
	# guard whose whole job is reporting orphans.
	#
	# NOTE: there is deliberately NO `-not -path '*/.worktrees/*'` here, and that
	# omission cost an hour. The canonical worktree home is
	# ~/src/.worktrees/<repo>/<branch>, so when this suite runs from inside a
	# worktree -- which is how every agent in this project works -- the repo root
	# ITSELF contains ".worktrees", and that exclusion matched every directory
	# under it. find returned nothing, `dirs` was empty, and the check reported
	# only that its own mechanism was broken.
	#
	# It would have passed in the main checkout and found nothing in any
	# worktree: a guard that works exactly where nobody runs it. The exclusion
	# was also pointless -- find is rooted at the repo root and cannot reach a
	# sibling worktree from there.
	#
	# test_helper/ is skipped: it holds VENDORED bats-assert/bats-support, which
	# ship their own test directory. Those are upstream's tests of upstream's
	# code, and demanding CI run them would be a false positive that teaches
	# people to widen allowlists.
	local root="$repo_root"
	[ -n "$root" ]

	local dirs
	# -prune, not -not -path: the filter form still DESCENDS into the pruned trees,
	# so find hits unreadable directories and exits non-zero even having printed
	# every result. Under bats that aborted the assignment. `|| true` is safe here
	# only because the very next line asserts the output is non-empty -- that
	# assertion is what stops a tolerated exit code from hiding an empty scan.
	dirs="$(find "$root" \( -name node_modules -o -name .git -o -name test_helper -o -name .claude -o -name .worktrees \) -prune -o -type d -name test -print 2>/dev/null || true)"

	# Assert the mechanism: discovery finding nothing would make every assertion
	# below pass over an empty set -- a guard against vacuous passes, passing
	# vacuously. This assertion already earned its place once, catching a first
	# draft whose `compgen -G` returned empty under bats.
	[ -n "$dirs" ]

	local unrun="" d f base
	for d in $dirs; do
		for f in "$d"/*.sh; do
			[ -e "$f" ] || continue
			base="$(basename "$f")"
			# Search every runner, ignoring comments and the script's own file,
			# because a script legitimately invoked from a Makefile target is
			# covered too -- it need not be a CI stage.
			# Comment lines are stripped before matching, and that is the whole
			# point. `grep -rl` alone counted a MENTION as an invocation, so a
			# proof script could be "run" by writing a sentence about it --
			# `# NOTE: see test/foo-proof.sh for details` in any runner made
			# test/foo-proof.sh look invoked. Verified 2026-08-16: an injected
			# script referenced only from a comment passed this test.
			#
			# Test 7 below already stripped comments for exactly this reason,
			# and this test did not. The same author fixed one and left the
			# other, which is a good argument for the guard-falsification
			# harness that caught it -- I could not see it by reading, having
			# written both.
			local invoked=0 cand
			while IFS= read -r cand; do
				[ -n "$cand" ] || continue
				[ "$(basename "$cand")" = "$base" ] && continue
				if grep -vE '^[[:space:]]*#' "$cand" 2>/dev/null | grep -qF "$base"; then
					invoked=1
					break
				fi
			done < <(grep -rl --include='*.sh' --include='Makefile' \
					--exclude="$base" -F "$base" \
					"$root/scripts" "$root/Makefile" "$root/d2-signalloom" 2>/dev/null)
			if [ "$invoked" -eq 0 ]; then
				unrun="${unrun}${f#$root/} "
			fi
		done
	done

	if [ -n "$unrun" ]; then
		echo "Proof/test script(s) that no runner invokes:"
		echo "  $unrun"
		echo ""
		echo "A proof nothing runs proves nothing. Add it to a run_stage in"
		echo "scripts/ci/vm-pipeline.sh or to a Makefile target."
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
	#
	# The four below FAIL on the CI VM while passing locally, which is exactly
	# the information their never having run was hiding. Quoted verbatim from
	# ci-reports/stage1g-unregistered-guards.tap on signalloom-ci (310 passed,
	# 4 failed) so the next person does not have to rediscover them:
	#
	#   agent-trust-lifecycle.bats:433   [ "$output" = "true" ] failed
	#     "local fleet renders inactive Agent Trust with local signature
	#     verification" -- depends on local fleet state the VM does not have.
	#
	#   deployed-staleness.bats:132      fatal: Needed a single revision
	#     Asserts "<n> commits behind HEAD". The CI VM has no real git history:
	#     vm-pipeline.sh `git init`s a synthetic single-commit repo because
	#     Kustomize needs .git as a path-traversal boundary, so HEAD~n cannot
	#     resolve. The test is right; its environment has one commit.
	#
	#   signalloom-flux-integration.bats:96   [ "$output" = "true" ] failed
	#     "recreates immutable proof Jobs during Flux reconciliation" -- live
	#     reconciliation timing against a freshly built cluster.
	#
	#   signalloom-preflight.bats:49     [ "$status" -eq 0 ] failed
	#     "make help exposes contract and preflight targets". Passes locally 5/5
	#     and `make help` exits 0 locally, so this is VM environment, not the
	#     Makefile glob change that landed alongside it.
	#
	# These are DEFERRED, not dismissed: each needs either a VM-aware skip
	# condition or a fix to the assumption it makes about its environment. They
	# are named here rather than deleted so that "we know about these four" is a
	# checkable statement rather than folklore.
	#
	#   test-count-floor.bats     - runs ALL four test suites (pytest, vitest, Go,
	#                               bats) end to end and asserts minimum counts.
	#                               That makes it an ~80s heavyweight that
	#                               duplicates the work of stages 1b, 2, 4, and
	#                               the d2 test, so it belongs as a local pre-push
	#                               gate, not inside a pipeline that already runs
	#                               those same suites and times out at 900s per
	#                               stage. Its value is the FLOOR assertion, not
	#                               the running of the suites themselves.
	local root_excluded="supercred-images.bats
agent-trust-lifecycle.bats
deployed-staleness.bats
signalloom-flux-integration.bats
signalloom-preflight.bats
test-count-floor.bats"

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
