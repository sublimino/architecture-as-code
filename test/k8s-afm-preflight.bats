#!/usr/bin/env bats
# The KubeSec-AFM slice backs Signal Loom's RBAC Explorer and RBAC Analysis
# pages: rbac_correlation.py reads /api/rbac/* from afm-platform.fe-k8s-afm, and
# seven nginx locations proxy there. The slice was complete in the repo but
# deployed by nothing in the Signal Loom bring-up path, so the page failed with
# a DNS error against a Service that had never existed.
#
# These cover that gap without needing a cluster: the deploy script says which
# input is missing, the Signal Loom lifecycle actually invokes the deploy, and
# the deploy REFUSES rather than warning when it cannot proceed.
#
# ─── Why the warn-not-fail contract was replaced ────────────────────────────
#
# This file used to assert the opposite of what it asserts now: that an absent
# AFM source checkout produced a WARNING and let the bring-up continue. That was
# correct while the source was the only way to obtain the image and a remote
# lane could never have it — failing would have taken down bring-ups that were
# otherwise fine, for a cause nobody could fix.
#
# scripts/k8s-afm.sh now also accepts a delivered image archive, and both lane
# drivers ship one, so "AFM is unavailable here" became a fact about a run
# rather than about the world. What the warning bought in the meantime was
# silence: four lanes came up green with d2-k8s-afm/ applied and no image behind
# it, and the only place it ever surfaced was /afm/ answering 502 in a browser.
#
# The escape hatch survives as AFM_REQUIRED=0, tested below, because a
# contributor with only this repo cloned still has a legitimate reason to skip
# the slice. It is opt-in so that it is a decision rather than an accident.

repo_root="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
	afm_source="$BATS_TEST_TMPDIR/kubesec-afm"
	mkdir -p "$afm_source/AFM/docker"
	touch "$afm_source/AFM/docker/backend.Dockerfile"

	missing_source="$BATS_TEST_TMPDIR/absent"

	# Every test pins AFM_IMAGE_ARCHIVE explicitly. Without this the script falls
	# back to ${repo_root}/.afm-image/kubesec-afm.tar.gz, which is gitignored
	# build output — so these tests would pass or fail depending on whether the
	# developer running them had happened to run `k8s-afm.sh save`. A test whose
	# verdict depends on untracked local state is worse than no test.
	absent_archive="$BATS_TEST_TMPDIR/no-such-archive.tar.gz"
	present_archive="$BATS_TEST_TMPDIR/kubesec-afm.tar.gz"
	printf 'not-a-real-image-but-non-empty' > "$present_archive"
}

# ── Route reporting ─────────────────────────────────────────────────────────

@test "preflight passes and names the source route when the checkout is present" {
	run env KUBESEC_AFM_ROOT="$afm_source" AFM_IMAGE_ARCHIVE="$absent_archive" \
		"$repo_root/scripts/k8s-afm.sh" preflight

	[ "$status" -eq 0 ]
	[[ "$output" == *"$afm_source"* ]]
	# WHICH route, not merely that one exists: a lane running a three-week-old
	# archive and a laptop building from a fresh checkout are different enough
	# facts that a log reading identically for both cannot diagnose staleness.
	[[ "$output" == *"source checkout"* ]]
}

@test "preflight passes on a delivered archive with NO source checkout" {
	# The lane case, and the whole point of the change: a machine that has only
	# ever seen 'git archive HEAD' of this repo can still deploy AFM.
	run env KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$present_archive" \
		"$repo_root/scripts/k8s-afm.sh" preflight

	[ "$status" -eq 0 ]
	[[ "$output" == *"$present_archive"* ]]
	[[ "$output" == *"archive"* ]]
}

@test "an EMPTY archive is not a usable archive" {
	# A zero-byte file is what a failed or interrupted transfer leaves behind,
	# and it is the shape that reads as success to every `[ -f ]` test.
	: > "$present_archive"
	run env KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$present_archive" \
		"$repo_root/scripts/k8s-afm.sh" preflight

	[ "$status" -eq 1 ]
}

@test "preflight names BOTH routes, and the variable that relocates each" {
	run env KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$absent_archive" \
		"$repo_root/scripts/k8s-afm.sh" preflight

	[ "$status" -eq 1 ]
	[[ "$output" == *"$missing_source"* ]]
	[[ "$output" == *"KUBESEC_AFM_ROOT"* ]]
	# The second route has to be named too. Naming only the source is what sent
	# every previous reader to clone a repo onto a VM that cannot have one.
	[[ "$output" == *"$absent_archive"* ]]
	[[ "$output" == *"AFM_IMAGE_ARCHIVE"* ]]
	# The consequence, so the failure is traceable back to the broken page.
	[[ "$output" == *"RBAC Explorer"* ]]
}

@test "up refuses before spending anything on a docker build" {
	run env KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$absent_archive" \
		"$repo_root/scripts/k8s-afm.sh" up

	[ "$status" -eq 1 ]
	[[ "$output" == *"no way to obtain the KubeSec-AFM image"* ]]
	# Guard is a preflight, not a post-mortem: the build never started.
	[[ "$output" != *"Building kubesec-afm image"* ]]
}

@test "save refuses without source and says an archive cannot substitute" {
	# 'save' is the one subcommand an archive genuinely cannot satisfy, because
	# producing the archive is what it does. Told plainly, so nobody tries to
	# fix it by pointing AFM_IMAGE_ARCHIVE at the file they are trying to create.
	run env KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$present_archive" \
		"$repo_root/scripts/k8s-afm.sh" save "$BATS_TEST_TMPDIR/out.tar.gz"

	[ "$status" -eq 1 ]
	[[ "$output" == *"OUTPUT of this command"* ]]
	[ ! -e "$BATS_TEST_TMPDIR/out.tar.gz" ]
}

# ── Lifecycle membership and the fail-closed contract ───────────────────────

# Recipe body of demo-signalloom-up with COMMENT LINES STRIPPED, up to the next
# target definition.
#
# Stripping comments is not tidiness, it is the difference between a guard and
# decoration. The recipe explains each of these steps in tab-indented comment
# blocks that name the very targets asserted below, so a match against the raw
# body is satisfied by the prose describing the rule even after the rule is
# deleted. Measured: test/afm-delivery-mutation-proof.sh M8 deleted
# `$(MAKE) check-backends` from the recipe and the assertion stayed GREEN,
# matching the comment above the line it had just removed. Same shape as
# scripts/check-ci-build-parity.sh's own `if (line ~ /^#/) next`, and for the
# same reason — that guard learned it first.
recipe_body() {
	awk -v target="$1" '
		index($0, target ":") == 1 { f = 1; next }
		f && /^\t/ {
			line = $0
			sub(/^\t+/, "", line)
			sub(/^[@+-]+/, "", line)
			if (line ~ /^#/) next
			print line
			next
		}
		f && !/^\t/ && !/^[ \t]*$/ { exit }
	' "$repo_root/Makefile"
}

@test "the Signal Loom lifecycle deploys the AFM slice its RBAC page reads from" {
	run recipe_body demo-signalloom-up

	[ "$status" -eq 0 ]
	[[ "$output" == *"demo-signalloom-afm-up"* ]]
}

@test "the lifecycle asserts every dashboard backend is actually reachable" {
	# check-backends.sh was written for this exact incident and, until it was
	# added here, no pipeline invoked it. A guard nothing calls is documentation.
	run recipe_body demo-signalloom-up

	[ "$status" -eq 0 ]
	[[ "$output" == *"check-backends"* ]]
}

# ── The fail-closed contract, asserted by RUNNING it ────────────────────────
#
# These invoke the real target rather than grepping its recipe text. The
# difference matters: a text guard looking for "exit 1" in the recipe is
# satisfied by a COMMENT containing "exit 1", and this repo has already shipped
# a guard that stayed green matching only the prose that explained the rule.
#
# Running it is safe here precisely because the thing under test is the refusal:
# preflight fails first, so the target reaches its error branch without ever
# invoking kubectl, docker or kind. Nothing is deployed and no cluster is read.

@test "the AFM deploy step FAILS the bring-up when no image can be obtained" {
	run make -C "$repo_root" demo-signalloom-afm-up \
		KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$absent_archive"

	# The inversion of the old contract. A missing AFM slice must stop the run,
	# not annotate it: the warning it replaced is why four lanes shipped a 502.
	[ "$status" -ne 0 ]
	[[ "$output" == *"ERROR"* ]]
	# It must still say what breaks, which the old warning did get right.
	[[ "$output" == *"502"* ]]
	# And it must not have started deploying anything before refusing.
	[[ "$output" != *"Deploying AFM platform"* ]]
}

@test "the refusal names the opt-out rather than being unconditional" {
	# Fail-closed with no documented way out is how a gate gets ripped out
	# wholesale by the next person it blocks. The escape hatch is part of the
	# design, and it must be discoverable from the failure itself.
	run make -C "$repo_root" demo-signalloom-afm-up \
		KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$absent_archive"

	[ "$status" -ne 0 ]
	[[ "$output" == *"AFM_REQUIRED=0"* ]]
}

@test "AFM_REQUIRED=0 still warns rather than failing" {
	run make -C "$repo_root" demo-signalloom-afm-up \
		KUBESEC_AFM_ROOT="$missing_source" AFM_IMAGE_ARCHIVE="$absent_archive" \
		AFM_REQUIRED=0

	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING"* ]]
	[[ "$output" == *"not deployed"* ]]
}
