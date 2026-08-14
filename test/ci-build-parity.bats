#!/usr/bin/env bats
#
# scripts/ci/vm-pipeline.sh cannot call `make demo-signalloom-up` — the shared
# `wait` target expects ResourceSets the signalloom-only path does not create
# until later — so it hand-copies the recipe body instead. That copy has drifted
# twice. The second time, one missing `$(MAKE) demo-signalloom-supercred-images`
# failed three stages ~40 minutes into a lane: stage 6b could not read a
# workload stuck in ImagePullBackOff, and stages 8 and 8b failed on the
# preflight that calls 6b while every test they own passed.
#
# These tests drive scripts/check-ci-build-parity.sh against fixture Makefiles
# and fixture pipelines, in the shape of test/deployed-staleness.bats and
# test/kind-load-verified.bats, because the outcomes worth proving are the
# FAILURE outcomes. The real tree is green today; a guard exercised only against
# a green tree proves nothing about the day it goes red.
#
# The property that matters most is that the guard CANNOT PASS VACUOUSLY. A
# renamed target, a reindented recipe or a pattern that stops matching must be
# distinguishable from parity, in the exit code AND in the words — because a
# guard that reports OK when it could not look manufactures exactly the
# confidence that let the last two omissions reach a VM.

setup() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	script="${repo_root}/scripts/check-ci-build-parity.sh"
	fix="$BATS_TEST_TMPDIR"

	# A fixture pair in the shape of the real ones: a bring-up recipe that builds
	# three things and then hands over to signalloom-local.sh, and a pipeline that
	# hand-copies it. Tests perturb exactly one thing each.
	#
	# printf with explicit \t rather than a heredoc, because the recipe tabs are
	# the fixture. `<<-` strips leading tabs by definition, which silently
	# produced a Makefile with no recipe at all — the guard then reported NO
	# STEPS for every test and the suite was measuring its own fixture.
	printf '%s\n' \
		'.PHONY: demo-signalloom-up' \
		'demo-signalloom-up: healthcheck ## Start the demo.' \
		$'\t$(MAKE) build-alpha' \
		$'\t# A comment inside the recipe: $(MAKE) build-commented' \
		$'\t$(MAKE) build-beta' \
		$'\t$(MAKE) -C d2-signalloom test' \
		$'\t$(MAKE) build-gamma' \
		$'\tSIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up' \
		'' \
		'other-target:' \
		$'\t$(MAKE) build-unrelated' \
		>"$fix/Makefile"

	cat >"$fix/pipeline.sh" <<-'PIPE'
		#!/usr/bin/env bash
		# Use individual targets instead of `make up`; `make build-gamma` is
		# discussed here in prose and must not count as running it.
		make cluster
		retry 3 make build-alpha
		retry 3 make build-beta
		make -C d2-signalloom test
		SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up
	PIPE

	export MAKEFILE="$fix/Makefile"
	export PIPELINE="$fix/pipeline.sh"
	export CI_PARITY_TARGET=demo-signalloom-up
	export CI_PARITY_ALLOW=""
}

# ── The real tree ───────────────────────────────────────────────────────────

@test "PARITY the repo's own pipeline builds everything demo-signalloom-up builds" {
	# The regression lock on the fix this guard was written for. If someone drops
	# demo-signalloom-supercred-images from stage 4 again, this is where it lands
	# — in ~1s in stage 1, not in three red stages 40 minutes in.
	run env -u MAKEFILE -u PIPELINE -u CI_PARITY_TARGET -u CI_PARITY_ALLOW "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"demo-signalloom-supercred-images"* ]]
}

@test "PARITY the repo's opt-outs are all still live decisions" {
	# Covers DEAD ALLOW and STALE ALLOW against the real Makefile: an entry for a
	# step the recipe dropped, or one CI turns out to run, fails here. An
	# allowlist nobody rechecks decays into a blanket exemption.
	run env -u MAKEFILE -u PIPELINE -u CI_PARITY_TARGET -u CI_PARITY_ALLOW "$script"
	[ "$status" -eq 0 ]
	[[ "$output" != *"DEAD ALLOW"* ]]
	[[ "$output" != *"STALE ALLOW"* ]]
}

# ── Drift: the case this exists for ─────────────────────────────────────────

@test "PARITY a step in the recipe and not in the pipeline fails, and is named" {
	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"build-gamma"* ]]
	# Naming the target is the whole value: the incident version of this failure
	# surfaced as an HTML media-type error from Docker Hub.
	[[ "$output" == *"CI does not build what it deploys"* ]]
}

@test "PARITY mutation — deleting a build line from the pipeline turns it red" {
	# Same mutation, applied to a pipeline that was passing a moment ago, so the
	# green above is proven to depend on the line rather than on the parser
	# giving up.
	#
	# Inserted BEFORE the handover rather than appended, which is not a detail:
	# appending puts the build after the deploy, and the TOO LATE test below
	# exists because that is also a failure.
	sed -i 's|^SIGNALLOOM_SKIP_PREPARE=1|retry 3 make build-gamma\n&|' "$fix/pipeline.sh"
	run "$script"
	[ "$status" -eq 0 ]

	grep -v 'make build-alpha' "$fix/pipeline.sh" >"$fix/mutated" && mv "$fix/mutated" "$fix/pipeline.sh"
	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"build-alpha"* ]]
}

@test "PARITY prose in the pipeline does not count as running a step" {
	# The pipeline explains itself at length, including `make up` and the very
	# target it omits. A guard that reads its own documentation as coverage is
	# how this class of bug survives a guard.
	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"build-gamma"* ]]
	[[ "$output" != *"BUILT       build-gamma"* ]]
}

@test "PARITY a build step scheduled after the deploy fails as TOO LATE" {
	# Present but late is not present. The workload is created before its image
	# exists, which is the same ImagePullBackOff with a later timestamp.
	printf '%s\n' 'retry 3 make build-gamma' >>"$fix/pipeline.sh"
	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"TOO LATE"* ]]
	[[ "$output" == *"build-gamma"* ]]
}

@test "PARITY a sub-make into a slice directory is not treated as a build step" {
	# `$(MAKE) -C d2-signalloom test` is not a root-Makefile target CI could
	# invoke by that name; treating it as one would report a permanent false
	# MISSING, and a guard that cries wolf gets muted.
	run "$script"
	[[ "$output" != *"MISSING     -C"* ]]
	[[ "$output" != *"MISSING     test"* ]]
}

@test "PARITY a commented-out step in the recipe is not required of CI" {
	run "$script"
	[[ "$output" != *"build-commented"* ]]
}

@test "PARITY steps of other targets are not attributed to this one" {
	run "$script"
	[[ "$output" != *"build-unrelated"* ]]
}

# ── The allowlist is checked too ────────────────────────────────────────────

@test "PARITY a documented opt-out is reported, not failed" {
	CI_PARITY_ALLOW="build-gamma=runtime-only:_nothing_in_CI_uses_it" run "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"OPT-OUT"* ]]
	[[ "$output" == *"build-gamma"* ]]
	# The reason travels with the entry, so the next reader can tell a decision
	# from an accident without archaeology.
	[[ "$output" == *"runtime-only"* ]]
}

@test "PARITY an opt-out the pipeline actually runs fails as STALE ALLOW" {
	printf '%s\n' 'retry 3 make build-gamma' >>"$fix/pipeline.sh"
	CI_PARITY_ALLOW="build-alpha=stale_claim" run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"STALE ALLOW"* ]]
	[[ "$output" == *"build-alpha"* ]]
}

@test "PARITY an opt-out for a step the recipe dropped fails as DEAD ALLOW" {
	printf '%s\n' 'retry 3 make build-gamma' >>"$fix/pipeline.sh"
	CI_PARITY_ALLOW="build-deleted=exempted_years_ago" run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"DEAD ALLOW"* ]]
	[[ "$output" == *"build-deleted"* ]]
}

# ── Cannot pass vacuously ───────────────────────────────────────────────────

@test "PARITY a renamed or unparseable target fails rather than reporting parity" {
	CI_PARITY_TARGET=demo-signalloom-up-renamed run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"NO STEPS"* ]]
	[[ "$output" != *"Every build step"* ]]
}

@test "PARITY an empty pipeline fails every step rather than passing quietly" {
	: >"$fix/pipeline.sh"
	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"build-alpha"* ]]
	[[ "$output" == *"build-beta"* ]]
	[[ "$output" == *"build-gamma"* ]]
}

@test "PARITY --target reaches other bring-up recipes" {
	# The divergence is structural, not specific to signalloom: any target whose
	# body gets hand-copied is exposed to it. Keeping the target a parameter
	# means the next copied recipe costs one line rather than a second script.
	run "$script" --target other-target
	[ "$status" -eq 1 ]
	[[ "$output" == *"build-unrelated"* ]]
}
