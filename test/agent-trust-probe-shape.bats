#!/usr/bin/env bats
#
# planner-egress-denied must POLL its denial, never sample it once.
#
# ─── What this exists to stop coming back ──────────────────────────────────
#
# Until da2b58f5 this probe reported "arbitrary planner egress unexpectedly
# reachable" on every single run — a security hole that did not exist. A new
# pod is UNCONFINED until the CNI programs its NetworkPolicy rules, and the
# probe sampled its denial once, immediately, inside that window.
#
# The probe already had a mitigation and the mitigation was vacuous: it waited
# for OpenBao — an ALLOWED destination — to become reachable and treated that
# as proof the rules were programmed. An unconfined pod reaches OpenBao too,
# so the control is satisfied identically whether the rules are programmed or
# entirely absent. It has zero discriminating power and passes at t=0.
#
# Only the denial itself distinguishes confined from unconfined. So the shape
# that must hold is: poll the denial against a deadline. Reachable-then-refused
# is the CNI catching up (pass); still reachable at the deadline is a real hole
# (fail). A refusal never reverts, so polling cannot launder a true failure.
#
# ─── Why this guard is static, and what that costs ─────────────────────────
#
# The live CronJob is a real detector — it fires every 5 minutes and surfaces
# in doctor-node — but it only detects on a DEPLOYED estate, roughly 28 minutes
# and one GCP VM after the mistake is made. Nothing in the repo could go red
# for a revert. This closes that gap at zero infrastructure cost. It asserts
# the SHAPE of the assertion, not the behaviour; the CronJob remains the thing
# that proves the policy actually denies.
#
# ─── Traps this file is deliberately written around ────────────────────────
#
# 1. COMMENTS SATISFYING THE GUARD. The manifest's own comment block quotes
#    "1.1.1.1:443 REACHABLE" as recorded evidence. A grep over the raw file
#    would match that prose and pass while the code said anything at all, so
#    every assertion below runs over a COMMENT-STRIPPED extract.
# 2. THE GUARD MATCHING ITS OWN SOURCE. This file contains the very literals
#    it forbids. Every assertion is scoped to the manifest, never the tree.
# 3. AN EMPTY EXTRACT PASSING EVERY ABSENCE TEST. If the awk extractor stops
#    matching — the CronJob is renamed, the document separator changes — it
#    returns nothing, and a nothing trivially satisfies "does not contain".
#    The first test asserts the mechanism is present before anything is tested
#    with it, and the negative tests re-assert non-emptiness themselves.
# 4. `! cmd` UNDER errexit. bats runs with errexit; a bare `! grep` that is not
#    the final line of a test never fails it. Every check uses `run` + status.

MANIFEST="d2-agent-trust/manifests/topology-probes.yaml"

# Each test inlines its own extraction rather than sharing a helper, so that a
# broken extractor cannot be fixed in one place and silently re-bless four
# assertions at once. The shape is always:
#
#   awk 'BEGIN{RS="\n---\n"} /name: planner-egress-denied,/{print; exit}'
#     | grep -v '^[[:space:]]*#'
#
# awk splits on the document separator and stops at the first match, so it
# cannot silently splice two CronJobs together.
#
# THE TRAILING COMMA IS LOAD-BEARING and was found by mutation, not by review.
# An earlier draft matched on `/name: planner-egress-denied/`, which is a
# substring match: renaming the CronJob to `planner-egress-denied-RENAMED`
# left all five tests GREEN, because the extractor happily returned the
# renamed document. The manifest writes `{name: <x>, namespace: <y>}`, so the
# comma pins the match to this exact CronJob and no descendant of its name.

setup() {
	cd "${BATS_TEST_DIRNAME}/.." || exit 1
}

@test "mechanism: the planner-egress-denied document is still extractable" {
	# Runs first and guards every other test in this file. If the extractor
	# returns nothing, the two negative assertions below would both pass
	# vacuously and this suite would report green over an unread file.
	[ -f "$MANIFEST" ]

	run bash -c 'awk "BEGIN{RS=\"\n---\n\"} /name: planner-egress-denied,/{print; exit}" "$0" | wc -l' "$MANIFEST"
	[ "$status" -eq 0 ]
	[ "$output" -gt 20 ]
}

@test "the denial is polled against a deadline, not sampled once" {
	run bash -c 'awk "BEGIN{RS=\"\n---\n\"} /name: planner-egress-denied,/{print; exit}" "$0" | grep -v "^[[:space:]]*#" | grep -cE "while nc .*1\.1\.1\.1 443"' "$MANIFEST"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

@test "the poll is bounded — an unreachable-forever target cannot hang the probe" {
	# Without a deadline the while loop is unbounded and the pod dies of
	# activeDeadlineSeconds with no termination message to explain it, which
	# reads as an infrastructure fault rather than the hole it is.
	run bash -c 'awk "BEGIN{RS=\"\n---\n\"} /name: planner-egress-denied,/{print; exit}" "$0" | grep -v "^[[:space:]]*#" | grep -cE "denial_deadline"' "$MANIFEST"
	[ "$status" -eq 0 ]
	[ "$output" -ge 2 ]
}

@test "the single-shot form that caused the false alarm is absent" {
	# The exact shape of the defect: `if nc -z -w 5 1.1.1.1 443; then <fail>`.
	# Re-asserts non-emptiness first — an empty extract satisfies this test
	# for entirely the wrong reason.
	run bash -c 'awk "BEGIN{RS=\"\n---\n\"} /name: planner-egress-denied,/{print; exit}" "$0" | grep -v "^[[:space:]]*#" | wc -l' "$MANIFEST"
	[ "$status" -eq 0 ]
	[ "$output" -gt 20 ]

	run bash -c 'awk "BEGIN{RS=\"\n---\n\"} /name: planner-egress-denied,/{print; exit}" "$0" | grep -v "^[[:space:]]*#" | grep -cE "if nc .*1\.1\.1\.1 443"' "$MANIFEST"
	[ "$output" -eq 0 ]
}

@test "activeDeadlineSeconds accommodates both bounded waits back to back" {
	# 60s control + 90s denial poll = 150s of legitimate waiting. The old 120s
	# ceiling would expire mid-poll on a slow CNI and produce DeadlineExceeded
	# with no termination message. Must also stay under the 300s schedule tick
	# so a slow run cannot lap itself.
	run bash -c 'awk "BEGIN{RS=\"\n---\n\"} /name: planner-egress-denied,/{print; exit}" "$0" | grep -v "^[[:space:]]*#" | grep -oE "activeDeadlineSeconds: [0-9]+" | grep -oE "[0-9]+"' "$MANIFEST"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[ "$output" -ge 150 ]
	[ "$output" -lt 300 ]
}
