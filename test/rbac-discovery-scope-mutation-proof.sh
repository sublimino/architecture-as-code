#!/usr/bin/env bash
# rbac-discovery-scope-mutation-proof.sh — prove the orc_rbac_discovery scope
# widening in test/guard-falsification-proof.sh both fixes the false positive
# it was added to fix, and still catches a genuine gap.
#
# ─── What this proves, and why both halves matter ───────────────────────────
#
# orc_rbac_discovery() previously grepped only d2-signalloom for `kind: Role`
# manifests. The fe-signalloom-agents Role/RoleBinding pair was relocated to
# d2-osramp-fleet/tenants/local/signalloom.yaml on 2026-08-01 (141a757f), two
# weeks BEFORE the oracle was written (1216c97c, 2026-08-16) — so the oracle
# reported that namespace as ungranted from the day it existed, and
# guard-falsification-proof.sh's RBAC-DISCOVERY-UNGRANTED case has read UNKNOWN
# ever since ("the property oracle reports 1 violation(s) BEFORE any
# mutation"). Widening the grep path to include d2-osramp-fleet is the fix.
#
# A widened search path is easy to get backwards: it is trivial to write a scope
# so broad the oracle can no longer distinguish "granted" from "not granted" at
# all, which would silence the UNKNOWN by making the check meaningless rather
# than by making it correct. So this proves two things independently:
#
#   REGRESSION   revert ONLY the search-path widening (put the grep args back
#                to d2-signalloom alone) -> the oracle must report the original
#                1 violation again. Proves the widening is what fixes it, not
#                some other incidental change in the same edit.
#
#   CONTROL      keep the FIXED (widened) oracle, but remove the real grant
#                from d2-osramp-fleet/tenants/local/signalloom.yaml -> the
#                oracle must report 1 violation again. Proves the fix did not
#                blind the check; it still finds a genuine gap when there is
#                one, it just no longer misses this specific relocated one.
#
# Both cases land on the same "reports 1" outcome for different, deliberate
# reasons — that is not a coincidence to be confused with a single mutation.
#
# ─── Why the REAL orc_rbac_discovery is run, not a reimplementation ─────────
#
# test/guard-falsification-proof.sh has no source-guard, so `source`-ing it
# runs its entire ~2600-line self-test and CLI. Re-implementing the oracle's
# logic by hand here would test a copy, not the guard — precisely the shape
# terraform/CONTRACT.md §7b exists to rule out. Instead, this harness extracts
# ONLY the orc_rbac_discovery() function body out of the real file (by awk,
# bounded by its own opening and closing braces, both at column 0) and runs
# THAT, so every case below executes the function exactly as it reads in the
# real file at that point in the run.
#
# ─── Safety, per terraform/CONTRACT.md §7b ──────────────────────────────────
#
#   * Both REAL files are mutated in place: test/guard-falsification-proof.sh
#     and d2-osramp-fleet/tenants/local/signalloom.yaml. Neither is copied to
#     a fixture first.
#   * Pristine copies live OUTSIDE the repo, at a deterministic mktemp -d path.
#   * Restore is always `cp` from those pristine copies, never `git checkout`.
#   * Every mutation is asserted to have applied (byte diff + a targeted grep)
#     before any verdict is trusted.
#   * A sentinel dropped while the tree is dirty is a REFUSAL on the next run.
#   * Restoration is verified by SHA-256 against the pre-run hashes, printed.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ORACLE_REL="test/guard-falsification-proof.sh"
GRANT_REL="d2-osramp-fleet/tenants/local/signalloom.yaml"

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn() { printf '\033[1;32m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }

if ! command -v python3 >/dev/null 2>&1; then
	red "CANNOT RUN: python3 is not on PATH. This is not a pass."
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
# See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

sha() { sha256sum "$1" | cut -d' ' -f1; }

ORACLE_SHA0="$(sha "$ORACLE_REL")"
GRANT_SHA0="$(sha "$GRANT_REL")"
ORACLE_MODE0="$(stat -c '%a' "$ORACLE_REL")"
GRANT_MODE0="$(stat -c '%a' "$GRANT_REL")"

ms_guard_init rbac-discovery-scope "$ORACLE_REL" "$GRANT_REL"
trap ms_guard_on_exit EXIT

# ms_guard_restore reapplies the recorded mode and then VERIFIES it, so the two
# explicit chmods the old restore carried are subsumed rather than dropped.
restore() { ms_guard_restore; }

# re-arm: restore, then re-write the sentinel, because a successful restore
# clears it and this harness runs more than one mutation against the same
# targets. A kill between them must still leave a marker.
rearm() {
	ms_guard_restore
	ms_guard_arm "rbac discovery scope: next mutation"
}

# ── Extract-and-run the REAL function ───────────────────────────────────────
run_oracle() {
	local func_src tmp
	func_src="$(awk '
		/^orc_rbac_discovery\(\) \{/ { p = 1 }
		p { print }
		p && /^}$/ { exit }
	' "$ORACLE_REL")"
	if [ -z "$func_src" ]; then
		red "CANNOT RUN: could not extract orc_rbac_discovery() from ${ORACLE_REL}."
		exit 2
	fi
	tmp="$(mktemp)"
	{
		printf '%s\n' "$func_src"
		printf 'orc_rbac_discovery\n'
	} >"$tmp"
	bash "$tmp"
	rm -f "$tmp"
}

FINDINGS=0

say ""
say "=== baseline: real files as they stand right now ========================"
n0="$(run_oracle)"
say "  orc_rbac_discovery reports: ${n0} violation(s)"
if [ "$n0" = "0" ]; then
	grn "  OK — the fix is in place and the property holds at baseline."
else
	red "  NOT ZERO on a clean tree; nothing below is measurable."
	FINDINGS=$((FINDINGS + 1))
fi

# ── Mutation A (regression): revert the widening only ──────────────────────
say ""
say "=== mutation A: revert the search-path widening (d2-signalloom only) ===="
BEFORE="$(grep -c 'd2-signalloom", "d2-osramp-fleet"' "$ORACLE_REL" || true)"
# ms_sed rather than a bare `sed -i`: it ARMS the sentinel before the write, so
# a kill here leaves a marker, and it refuses a no-op instead of letting the
# occurrence counts below be the only thing standing between a non-matching
# pattern and a verdict about correct code.
ms_sed "$ORACLE_REL" 's/"d2-signalloom", "d2-osramp-fleet"\]/"d2-signalloom"]/'
AFTER="$(grep -c 'd2-signalloom", "d2-osramp-fleet"' "$ORACLE_REL" || true)"
if [ "$BEFORE" -ne 1 ] || [ "$AFTER" -ne 0 ]; then
	red "THE MUTATION DID NOT APPLY AS EXPECTED (before=${BEFORE}, after=${AFTER})."
	restore; trap - EXIT
	exit 2
fi
if [ "$(sha "$ORACLE_REL")" = "$ORACLE_SHA0" ]; then
	red "ORACLE FILE IS BYTE-IDENTICAL AFTER MUTATION. Not a pass."
	restore; trap - EXIT
	exit 2
fi
nA="$(run_oracle)"
say "  orc_rbac_discovery reports: ${nA} violation(s)"
if [ "$nA" = "1" ]; then
	grn "  RED as required — reverting the widening reproduces the original UNKNOWN."
else
	red "  Expected 1, got ${nA}. The widening is not what fixes this, or the"
	red "  revert did not land where expected."
	FINDINGS=$((FINDINGS + 1))
fi
rearm

# ── Mutation B (control): fixed oracle, real grant removed ─────────────────
say ""
say "=== mutation B: fixed oracle, but the real grant is removed ============="
say "    (fe-signalloom-agents -> agents-ns-mutated, whole-file, so the"
say "     substring the oracle searches for is gone from every occurrence)"
BEFORE="$(grep -c 'fe-signalloom-agents' "$GRANT_REL" || true)"
ms_sed "$GRANT_REL" 's/fe-signalloom-agents/agents-ns-mutated/g'
AFTER="$(grep -c 'fe-signalloom-agents' "$GRANT_REL" || true)"
say "  occurrences of the literal before/after: ${BEFORE} / ${AFTER}"
if [ "$BEFORE" -lt 20 ] || [ "$AFTER" -ne 0 ]; then
	red "THE MUTATION DID NOT APPLY AS EXPECTED (before=${BEFORE}, after=${AFTER})."
	restore; trap - EXIT
	exit 2
fi
if [ "$(sha "$GRANT_REL")" = "$GRANT_SHA0" ]; then
	red "GRANT FILE IS BYTE-IDENTICAL AFTER MUTATION. Not a pass."
	restore; trap - EXIT
	exit 2
fi
nB="$(run_oracle)"
say "  orc_rbac_discovery reports: ${nB} violation(s)"
if [ "$nB" = "1" ]; then
	grn "  RED as required — the fixed (widened) oracle still catches a real gap."
else
	red "  Expected 1, got ${nB}. The widened scope may be too broad to detect a"
	red "  genuine missing grant — that would be a blind spot, not a fix."
	FINDINGS=$((FINDINGS + 1))
fi

# ── Restore and prove it ────────────────────────────────────────────────────
#
# ms_guard_finish is restore + verify + drop the pristine copies, which is what
# the old `restore` followed by `rm -rf` did — with the verification in the
# middle rather than absent. The trap is then disarmed because the work is done.
# A failure is counted as a finding rather than swallowed: the tree is still
# mutated, and the sentinel is deliberately still on disk to say so.
if ! ms_guard_finish; then
	red "  RESTORE FAILED — the tree is NOT clean; the sentinel has been kept."
	FINDINGS=$((FINDINGS + 1))
fi
trap - EXIT

say ""
say "--- restore proof ---"
for pair in "${ORACLE_REL}:${ORACLE_SHA0}:${ORACLE_MODE0}" "${GRANT_REL}:${GRANT_SHA0}:${GRANT_MODE0}"; do
	f="${pair%%:*}"
	rest="${pair#*:}"
	want_sha="${rest%%:*}"
	want_mode="${rest#*:}"
	got_sha="$(sha "$f")"
	got_mode="$(stat -c '%a' "$f")"
	if [ "$got_sha" = "$want_sha" ]; then
		say "  OK   ${f} content"
		say "       ${got_sha}"
	else
		red "  DIFF ${f} content"
		red "       want ${want_sha}"
		red "       got  ${got_sha}"
		FINDINGS=$((FINDINGS + 1))
	fi
	if [ "$got_mode" = "$want_mode" ]; then
		say "  OK   ${f} mode (${got_mode})"
	else
		red "  DIFF ${f} mode: want ${want_mode}, got ${got_mode}"
		FINDINGS=$((FINDINGS + 1))
	fi
done
# The pristine copies are the rail's now, and ms_guard_finish above dropped
# them — but only because the restore VERIFIED. A failed restore keeps them,
# because at that point they are the only clean copies left.

say ""
say "=== summary ==============================================================="
say "  findings : ${FINDINGS}"
if [ "$FINDINGS" -ne 0 ]; then
	red "FINDINGS PRESENT — the widened scope does not behave as claimed, or the"
	red "tree was not restored."
	exit 1
fi
grn "The scope widening is what fixes the false positive (regression case), it"
grn "still catches a genuine gap (control case), and both real files are"
grn "restored byte-identical, mode included."
