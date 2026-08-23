#!/usr/bin/env bash
# acceptance-gateway-mutation-proof.sh — prove the two repaired TEST-1 harness
# assertions in test/signalloom-test-1-harness.bats can actually fail.
#
# ─── What this proves ────────────────────────────────────────────────────────
#
# "TEST-1 acceptance preflight validates dashboard readiness semantics" and
# "TEST-1 discovers the shared Gateway data-plane Service dynamically" both
# failed on this branch because they pinned literals — a $dashboard_ready
# variable and a `kubectl get service -A` invocation — that two same-day
# refactors (04c341a6, f9a00af9) legitimately changed. The repair replaced
# those literals with checks on the underlying CONTRACT: readiness-probe
# failure must set PREFLIGHT_FAILED, and Gateway discovery must go through the
# owning-gateway label selector, not a hardcoded name.
#
# A repaired assertion that always passes is worse than the stale one it
# replaced — the stale one at least failed loudly. This harness mutates the
# REAL scripts/acceptance-test.sh to reintroduce each defect independently and
# requires the matching test, and ONLY the matching test, to go red.
#
# ─── Safety, per terraform/CONTRACT.md §7b ──────────────────────────────────
#
#   * The REAL scripts/acceptance-test.sh is mutated, in place, not a copy.
#   * A pristine copy is kept OUTSIDE the repo, at a deterministic mktemp -d
#     path, so a SIGKILL that outruns the trap is still recoverable by hand.
#   * Restore is `cp` from that pristine copy, never `git checkout` — checkout
#     would also revert any other uncommitted work sitting in this tree.
#   * Every mutation is asserted to have applied (line count before/after,
#     plus a SHA-256 change) before any verdict is trusted.
#   * A sentinel dropped while the tree is dirty is a REFUSAL on the next run,
#     never an auto-repair.
#   * Restoration is verified by SHA-256 against the pre-run hash, printed.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGET_REL="scripts/acceptance-test.sh"
BATS_FILE="test/signalloom-test-1-harness.bats"

READY_TEST='TEST-1 acceptance preflight validates dashboard readiness semantics'
DISCOVERY_TEST='TEST-1 discovers the shared Gateway data-plane Service dynamically'

BATS_BIN="${BATS_BIN:-$(command -v bats || true)}"

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn() { printf '\033[1;32m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }

if [ -z "$BATS_BIN" ]; then
	red "CANNOT RUN: bats is not on PATH. This is not a pass."
	exit 2
fi

# ── The shared safety rail ──────────────────────────────────────────────────
#
# The marker this replaces ended in a suffix that `.gitignore` does NOT match —
# the glob there is `*mutation-in-progress`. One `git add -A` during an
# interrupted run would have COMMITTED a file announcing the tree was mutated.
# Every sentinel minted through the rail falls under the existing glob by
# construction.
#
# The old suffix is deliberately not spelled out here. The fleet-wide check in
# test/terraform-mutation-sentinel.bats greps every proof for that literal to
# find hand-rolled markers, and a comment quoting it would match — a guard
# firing on the prose that explains it, reported as a real finding.
#
# The rail also verifies the restore on content AND mode, which matters more
# here than anywhere: apply_mutation_ready below replaces the target via `mv`
# from a fresh temp file, so the executable bit is dropped on every mutation and
# a content-only check reads that as a clean restore.
# See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

sha() { sha256sum "$1" | cut -d' ' -f1; }

SHA0="$(sha "$TARGET_REL")"
MODE0="$(stat -c '%a' "$TARGET_REL")"

ms_guard_init acceptance-gateway "$TARGET_REL"
trap ms_guard_on_exit EXIT

# ms_guard_restore reapplies the recorded mode and then VERIFIES it, so the
# explicit chmod the old restore carried is subsumed rather than dropped.
restore() { ms_guard_restore; }

# re-arm: restore, then re-write the sentinel, because a successful restore
# clears it and this harness runs two independent mutations against the same
# target. A kill between mutation A and mutation B must still leave a marker.
rearm() {
	ms_guard_restore
	ms_guard_arm "mutation B: Gateway discovery loses its label selector"
}

run_named() { # <exact test name> ; echoes PASS | FAIL | NOMATCH
	local name="$1" rc=0 out
	out="$("$BATS_BIN" --filter "$(printf '%s' "$name" | sed 's/[][\.*^$(){}?+|/]/\\&/g')" \
		"$BATS_FILE" 2>&1)" || rc=$?
	if ! grep -qE '^(ok|not ok) ' <<<"$out"; then
		printf 'NOMATCH'
		return 0
	fi
	[ "$rc" -eq 0 ] && printf 'PASS' || printf 'FAIL'
}

FINDINGS=0

say ""
say "=== baseline: unmutated acceptance-test.sh (both must be GREEN) ========="
for t in "$READY_TEST" "$DISCOVERY_TEST"; do
	r="$(run_named "$t")"
	if [ "$r" = "PASS" ]; then
		grn "  GREEN  ${t}"
	else
		red "  ${r}  ${t}"
		red "         not green on a clean tree; nothing below is measurable"
		FINDINGS=$((FINDINGS + 1))
	fi
done

# ── Mutation 1: readiness-probe failure no longer sets PREFLIGHT_FAILED ─────
#
# Deletes exactly the PREFLIGHT_FAILED=1 line that follows the "could not
# establish supervised shared Gateway forward" error — the one tied to the
# readiness probe, not the sibling one a few lines above tied to the
# already-listening refusal. Isolation matters: this must move ONLY the
# readiness test, not the discovery test.
#
# awk into a temp file, not ms_sed, so the sentinel is armed BY HAND and BEFORE
# the write. A kill landing between the `mv` and the assertions below would
# otherwise leave acceptance-test.sh short one PREFLIGHT_FAILED line with
# nothing on disk recording that a harness did it.
apply_mutation_ready() {
	ms_guard_arm "mutation A: readiness-probe failure silently ignored"
	awk '
		found { found = 0; next }
		/could not establish supervised shared Gateway forward/ { found = 1 }
		{ print }
	' "$TARGET_REL" >"${TARGET_REL}.tmp"
	mv "${TARGET_REL}.tmp" "$TARGET_REL"
}

say ""
say "=== mutation A: readiness-probe failure silently ignored ================"
LINES_BEFORE="$(wc -l <"$TARGET_REL")"
apply_mutation_ready
LINES_AFTER="$(wc -l <"$TARGET_REL")"
if [ "$LINES_AFTER" -ne $((LINES_BEFORE - 1)) ]; then
	red "THE MUTATION DID NOT APPLY AS EXPECTED (before ${LINES_BEFORE}, after ${LINES_AFTER})."
	restore; trap - EXIT
	exit 2
fi
if [ "$(sha "$TARGET_REL")" = "$SHA0" ]; then
	red "TARGET IS BYTE-IDENTICAL AFTER MUTATION. Not a pass."
	restore; trap - EXIT
	exit 2
fi
r_ready="$(run_named "$READY_TEST")"
r_discovery="$(run_named "$DISCOVERY_TEST")"
if [ "$r_ready" = "FAIL" ]; then
	grn "  RED    ${READY_TEST}"
else
	red "  ${r_ready}  ${READY_TEST}"
	red "         STILL PASSES: swallowing the readiness-probe failure went undetected."
	FINDINGS=$((FINDINGS + 1))
fi
if [ "$r_discovery" = "PASS" ]; then
	grn "  GREEN  ${DISCOVERY_TEST}  (unaffected, as expected)"
else
	red "  ${r_discovery}  ${DISCOVERY_TEST}"
	red "         moved on a mutation it should be blind to — coupling is too loose."
	FINDINGS=$((FINDINGS + 1))
fi

rearm

# ── Mutation 2: Gateway discovery reverts to a hardcoded lookup ────────────
#
# Deletes the owning-gateway label-selector line entirely. Whatever a future
# rewrite replaces the kubectl invocation with, if it stops filtering by this
# label it has regressed to a static/hardcoded discovery, and this test's
# whole reason to exist is to catch that.
apply_mutation_discovery() {
	sed -i '/-l gateway\.envoyproxy\.io\/owning-gateway-name=cluster/d' "$TARGET_REL"
}

say ""
say "=== mutation B: Gateway discovery loses its label selector =============="
LINES_BEFORE="$(wc -l <"$TARGET_REL")"
apply_mutation_discovery
LINES_AFTER="$(wc -l <"$TARGET_REL")"
if [ "$LINES_AFTER" -ne $((LINES_BEFORE - 1)) ]; then
	red "THE MUTATION DID NOT APPLY AS EXPECTED (before ${LINES_BEFORE}, after ${LINES_AFTER})."
	restore; trap - EXIT
	exit 2
fi
if [ "$(sha "$TARGET_REL")" = "$SHA0" ]; then
	red "TARGET IS BYTE-IDENTICAL AFTER MUTATION. Not a pass."
	restore; trap - EXIT
	exit 2
fi
r_ready="$(run_named "$READY_TEST")"
r_discovery="$(run_named "$DISCOVERY_TEST")"
if [ "$r_discovery" = "FAIL" ]; then
	grn "  RED    ${DISCOVERY_TEST}"
else
	red "  ${r_discovery}  ${DISCOVERY_TEST}"
	red "         STILL PASSES: losing the label selector went undetected."
	FINDINGS=$((FINDINGS + 1))
fi
if [ "$r_ready" = "PASS" ]; then
	grn "  GREEN  ${READY_TEST}  (unaffected, as expected)"
else
	red "  ${r_ready}  ${READY_TEST}"
	red "         moved on a mutation it should be blind to — coupling is too loose."
	FINDINGS=$((FINDINGS + 1))
fi

# ── Restore and prove it ────────────────────────────────────────────────────
#
# ms_guard_finish is restore + verify + drop the pristine copy, which is what
# the old `restore` followed by `rm -rf` did — with the verification in the
# middle rather than absent. The trap is then disarmed because the work is done.
# A failure here is counted as a finding rather than swallowed: the tree is
# still mutated, and the sentinel is deliberately still on disk to say so.
if ! ms_guard_finish; then
	red "  RESTORE FAILED — the tree is NOT clean; the sentinel has been kept."
	FINDINGS=$((FINDINGS + 1))
fi
trap - EXIT

say ""
say "--- restore proof ---"
GOT_SHA="$(sha "$TARGET_REL")"
GOT_MODE="$(stat -c '%a' "$TARGET_REL")"
if [ "$GOT_SHA" = "$SHA0" ]; then
	say "  OK   ${TARGET_REL} content"
	say "       ${GOT_SHA}"
else
	red "  DIFF ${TARGET_REL} content"
	red "       want ${SHA0}"
	red "       got  ${GOT_SHA}"
	FINDINGS=$((FINDINGS + 1))
fi
if [ "$GOT_MODE" = "$MODE0" ]; then
	say "  OK   ${TARGET_REL} mode (${GOT_MODE})"
else
	red "  DIFF ${TARGET_REL} mode"
	red "       want ${MODE0}"
	red "       got  ${GOT_MODE}"
	FINDINGS=$((FINDINGS + 1))
fi
# The pristine copy is the rail's now, and ms_guard_finish drops it — but only
# once the restore has VERIFIED. A failed restore keeps it, because at that
# point it is the only clean copy left and the next run's refusal points at it.

say ""
say "=== summary ==============================================================="
say "  findings : ${FINDINGS}"
if [ "$FINDINGS" -ne 0 ]; then
	red "FINDINGS PRESENT — at least one repaired assertion still cannot fail,"
	red "or coupling is too loose, or the tree was not restored."
	exit 1
fi
grn "Both repaired assertions detect their matching defect and stay silent on"
grn "the other one, and the tree is restored byte-identical."
