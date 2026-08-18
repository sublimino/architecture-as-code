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
		$'\t./scripts/activate-thing.sh up' \
		'' \
		'other-target:' \
		$'\t$(MAKE) build-unrelated' \
		$'\t./scripts/other-thing.sh up' \
		>"$fix/Makefile"

	cat >"$fix/pipeline.sh" <<-'PIPE'
		#!/usr/bin/env bash
		# Use individual targets instead of `make up`; `make build-gamma` is
		# discussed here in prose and must not count as running it.
		make cluster
		retry 3 make build-alpha
		retry 3 make build-beta
		make -C d2-signalloom test
		./scripts/other-thing.sh up
		SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up
		./scripts/activate-thing.sh up
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

@test "PARITY the repo's pipeline activates the Agent Trust slice, in recipe order" {
	# The regression lock on the defect that widened this guard. The activation
	# step is what patches concrete inputs into a ResourceSet declared
	# `inputs: []`; without it a cold cluster has zero of six agent-trust-*
	# namespaces and reports the failure against signalloom-infra, naming neither
	# the slice nor the missing step.
	#
	# Asserting the RAN verdict rather than mere presence, because that verdict is
	# what survives the ordering checks: MISSING, TOO EARLY and NO ANCHOR each
	# leave the step named in the output but not run.
	run env -u MAKEFILE -u PIPELINE -u CI_PARITY_TARGET -u CI_PARITY_ALLOW "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"RAN         scripts/signalloom-local.sh:up"* ]]
	[[ "$output" == *"RAN         scripts/agent-trust-local.sh:up"* ]]
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

@test "PARITY a step disabled by a trailing comment does not count as built" {
	# The gap the falsification harness measured on 2026-08-16. Full-line comments
	# were already dropped, so `# make build-alpha` did not count as coverage — but
	# a comment TRAILING a live line survived that filter, and the extractor then
	# lifted the target name straight back out of the dead text. The guard printed
	#
	#   BUILT       demo-signalloom-supercred-images         vm-pipeline.sh:267
	#
	# naming, as proof of a build, the exact line that had stopped building.
	#
	# `true #` is how a step gets disabled in a hurry — during a bisect, or to skip
	# one slow build "just for this run". It is the same absent step as a deleted
	# line, wearing the deleted line's own name.
	sed -i 's|^retry 3 make build-alpha$|retry 3 true # make build-alpha|' "$fix/pipeline.sh"
	# Assert the mutation landed. A sed whose pattern misses is a no-op that exits
	# 0, and the test would then pass against an unmutated fixture.
	grep -qF 'retry 3 true # make build-alpha' "$fix/pipeline.sh"

	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"build-alpha"* ]]
	[[ "$output" != *"BUILT       build-alpha"* ]]
}

@test "PARITY a # that is not a comment does not hide the step beside it" {
	# The other direction, and the reason the stripper is quote-aware rather than
	# a cut at the first `#`. `${#arr[@]}` is a length expansion and `"a # b"` is
	# a string; neither starts a comment. A stripper that treats them as one
	# deletes live invocations and reports a MISSING that is not there. The real
	# pipeline holds four `${#...}` expansions today, so this is not hypothetical
	# — and a guard that cries wolf gets muted, which costs the same as blindness.
	cat >"$fix/pipeline.sh" <<-'PIPE'
		#!/usr/bin/env bash
		make cluster
		retry 3 make build-alpha
		echo "stage ${#stage_results[@]} # of many" && retry 3 make build-beta
		make -C d2-signalloom test
		retry 3 make build-gamma   # trailing comment beside a live invocation
		SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up
		./scripts/activate-thing.sh up
	PIPE
	run "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"BUILT"*"build-alpha"* ]]
	[[ "$output" == *"BUILT"*"build-beta"* ]]
	[[ "$output" == *"BUILT"*"build-gamma"* ]]
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

# ── Script steps: the half of the recipe the guard used to be blind to ──────
#
# demo-signalloom-up ends in two direct script invocations, and a $(MAKE)-only
# reader saw neither. Commit a86df1f added `./scripts/agent-trust-local.sh up`
# to the recipe — the only step that patches concrete inputs into the
# agent-trust ResourceSet, which ships `inputs: []` by design. vm-pipeline.sh
# got that commit's two $(MAKE) lines (this guard flagged them MISSING at merge
# time) and not its script line, because nothing could see it. The guard then
# printed "Every build step demo-signalloom-up runs is run or explicitly opted
# out of by CI." at exit 0 over a pipeline that could not bring the slice up.
#
# The from-scratch run that followed reached 21/27 stages with zero of six
# agent-trust-* namespaces, reporting
#   signalloom-infra  ... at <inputs>: map has no entry for key "tenant"
# — the PREREQUISITE, not the slice, because agent-trust-local.sh up is also the
# only caller of suspend_root_reconciliation, so the ten-minute flux-system sync
# reapplied `inputs: []` over what signalloom-local.sh had just patched in.

@test "PARITY an activation script the pipeline never runs fails, and is named" {
	grep -v 'activate-thing.sh up' "$fix/pipeline.sh" >"$fix/mutated" && mv "$fix/mutated" "$fix/pipeline.sh"
	# Assert the mutation landed: a grep -v whose pattern misses rewrites the file
	# unchanged and exits 0, and the test would then measure an unmutated fixture.
	! grep -qF 'activate-thing.sh up' "$fix/pipeline.sh"

	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"scripts/activate-thing.sh:up"* ]]
}

@test "PARITY the script verb is part of the step identity" {
	# `up` and `down` are opposite operations against the same ResourceSet. A
	# guard that matched on the path alone would read a teardown as proof of a
	# bring-up — and agent-trust-local.sh really does take both verbs.
	sed -i 's|^\./scripts/activate-thing.sh up$|./scripts/activate-thing.sh down|' "$fix/pipeline.sh"
	grep -qF './scripts/activate-thing.sh down' "$fix/pipeline.sh"

	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"scripts/activate-thing.sh:up"* ]]
}

@test "PARITY prose naming the activation script does not count as running it" {
	# The same property already proven for `make`, on the path that now carries
	# the deploy half of the recipe. vm-pipeline.sh discusses agent-trust in two
	# comment blocks; a guard that reads its own documentation as coverage is how
	# this class of defect survives a guard.
	sed -i 's|^\./scripts/activate-thing.sh up$|# ./scripts/activate-thing.sh up|' "$fix/pipeline.sh"
	grep -qF '# ./scripts/activate-thing.sh up' "$fix/pipeline.sh"

	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"scripts/activate-thing.sh:up"* ]]
	[[ "$output" != *"RAN         scripts/activate-thing.sh:up"* ]]
}

@test "PARITY a step disabled by a trailing comment does not count as run either" {
	sed -i 's|^\./scripts/activate-thing.sh up$|true # ./scripts/activate-thing.sh up|' "$fix/pipeline.sh"
	grep -qF 'true # ./scripts/activate-thing.sh up' "$fix/pipeline.sh"

	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"scripts/activate-thing.sh:up"* ]]
}

@test "PARITY an activation step that precedes the handover fails as TOO EARLY" {
	# Present but early is not present, and here it is worse than absent. The
	# recipe runs this after signalloom-local.sh because the activation snapshots
	# its sibling ResourceSets' inputs and restores them after a fleet refresh
	# that reapplies `inputs: []`. Snapshotting before they are active captures
	# nothing, restores nothing, and the bring-up then waits its full 600s
	# preflight on a prerequisite that will never go Ready — a ten-minute hang
	# where the omission at least failed fast.
	grep -v 'activate-thing.sh up' "$fix/pipeline.sh" >"$fix/mutated" && mv "$fix/mutated" "$fix/pipeline.sh"
	sed -i 's|^SIGNALLOOM_SKIP_PREPARE=1|./scripts/activate-thing.sh up\n&|' "$fix/pipeline.sh"
	grep -qF './scripts/activate-thing.sh up' "$fix/pipeline.sh"

	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"TOO EARLY"* ]]
	[[ "$output" == *"scripts/activate-thing.sh:up"* ]]
	# Scoped to the verdict column, not `*"MISSING"*"activate-thing"*`: the
	# fixture's build-gamma is MISSING in every one of these tests, so the loose
	# glob matches across two unrelated lines and can never fail.
	[[ "$output" != *"MISSING     scripts/activate-thing.sh:up"* ]]
}

@test "PARITY a pipeline with no handover reports ordering as unchecked" {
	# The anchor decides every TOO LATE and TOO EARLY verdict. If the pipeline
	# loses it, those checks silently stop running and the guard degrades to a
	# membership test while still printing a pass. "Could not look" and "looked
	# and found nothing" are different answers here too.
	sed -i 's|^SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up$|deploy_somehow|' "$fix/pipeline.sh"
	! grep -qF 'signalloom-local.sh up' "$fix/pipeline.sh"

	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"NO ANCHOR"* ]]
	[[ "$output" == *"Ordering was not checked"* ]]
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
	# "Every build step" until the guard was widened past $(MAKE) lines and the
	# success line became "Every step". An absence assertion against a string the
	# guard can no longer emit passes for free — the shape this suite exists to
	# catch, found in the suite itself.
	[[ "$output" != *"Every step"* ]]
}

@test "PARITY an empty pipeline fails every step rather than passing quietly" {
	: >"$fix/pipeline.sh"
	run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"build-alpha"* ]]
	[[ "$output" == *"build-beta"* ]]
	[[ "$output" == *"build-gamma"* ]]
}

@test "PARITY an unreadable pipeline is reported as unchecked, not as total drift" {
	# "Could not look" and "looked and found nothing" are different answers, and
	# the second one written over the first is how check-flux-substitution.sh
	# reported no unsubstituted tokens against no cluster at all.
	#
	# Before this, a renamed or moved pipeline produced a full page of MISSING and
	# the words "CI does not build what it deploys" — a confident diagnosis of a
	# file the guard had never opened, sending the reader to add build steps to
	# something that is not there. Note the CONTRAST with the empty-pipeline test
	# above: a pipeline that exists and builds nothing IS total drift and must
	# still fail that way. Only absence is unchecked.
	PIPELINE="$fix/no-such-pipeline.sh" run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"CANNOT READ"* ]]
	[[ "$output" != *"MISSING"* ]]
	[[ "$output" != *"CI does not build what it deploys"* ]]
}

@test "PARITY an unreadable Makefile is reported as unchecked, not as parity" {
	# Same property on the other input. This path previously surfaced as awk's own
	# "fatal: cannot open file" and an exit code of 2 — accurate by accident,
	# because nothing in the guard had decided what should happen.
	MAKEFILE="$fix/no-such-makefile" run "$script"
	[ "$status" -eq 1 ]
	[[ "$output" == *"CANNOT READ"* ]]
	[[ "$output" != *"Every step"* ]]
}

@test "PARITY --target reaches other bring-up recipes" {
	# The divergence is structural, not specific to signalloom: any target whose
	# body gets hand-copied is exposed to it. Keeping the target a parameter
	# means the next copied recipe costs one line rather than a second script.
	run "$script" --target other-target
	[ "$status" -eq 1 ]
	[[ "$output" == *"build-unrelated"* ]]
}

@test "PARITY the handover anchor is read from the target's own recipe" {
	# The anchor decides every ordering verdict, and it used to be found by
	# scanning the whole Makefile — so ANY target checked with --target was
	# compared against demo-signalloom-up's handover line, from a recipe it is
	# not in.
	#
	# other-target has no handover of its own, and the fixture pipeline runs its
	# script step BEFORE the signalloom handover. Under the file-global anchor
	# that combination is `recipe_line > recipe_anchor && hit < pipeline_anchor`
	# — a TOO EARLY for a step with nothing to be early for. The real tree
	# produced exactly this against `--target demo-agent-trust-up`, a usage in
	# the guard's own synopsis: a TOO LATE citing another recipe's handover and
	# an image the step does not have.
	#
	# No handover in the recipe means no ordering claim, which is the honest
	# answer rather than a confident wrong one.
	run "$script" --target other-target
	[[ "$output" == *"RAN         scripts/other-thing.sh:up"* ]]
	[[ "$output" != *"TOO EARLY"* ]]
	[[ "$output" != *"TOO LATE"* ]]
}
