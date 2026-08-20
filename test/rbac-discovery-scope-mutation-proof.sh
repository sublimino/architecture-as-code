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

SENTINEL="${REPO_ROOT}/.rbac-discovery-scope-mutation-proof.RUNNING"
SAFE="${TMPDIR:-/tmp}/osramp-rbac-discovery-scope-proof"

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn() { printf '\033[1;32m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }

if ! command -v python3 >/dev/null 2>&1; then
	red "CANNOT RUN: python3 is not on PATH. This is not a pass."
	exit 2
fi

if [ -e "$SENTINEL" ]; then
	red "REFUSING TO START: a previous run left a sentinel."
	say "  $SENTINEL"
	say "  The working tree may still contain a mutated ${ORACLE_REL} or"
	say "  ${GRANT_REL}. This harness will NOT repair it. Pristine copies, if any:"
	cat "$SENTINEL" 2>/dev/null | sed 's/^/    /'
	say "  Restore by hand, confirm with 'git status', delete the sentinel, re-run."
	exit 2
fi

mkdir -p "$SAFE"
rm -f "${SAFE:?}"/*

sha() { sha256sum "$1" | cut -d' ' -f1; }

cp "$ORACLE_REL" "${SAFE}/oracle.pristine"
cp "$GRANT_REL" "${SAFE}/grant.pristine"
ORACLE_SHA0="$(sha "$ORACLE_REL")"
GRANT_SHA0="$(sha "$GRANT_REL")"
ORACLE_MODE0="$(stat -c '%a' "$ORACLE_REL")"
GRANT_MODE0="$(stat -c '%a' "$GRANT_REL")"

write_sentinel() {
	cat >"$SENTINEL" <<EOF
Killed mid-run. Pristine copies (restore BY HAND, do not git checkout):
  ${SAFE}/oracle.pristine  -> ${ORACLE_REL}
  ${SAFE}/grant.pristine   -> ${GRANT_REL}
Expected SHA-256 after restore:
  ${ORACLE_SHA0}  ${ORACLE_REL}
  ${GRANT_SHA0}  ${GRANT_REL}
EOF
}
write_sentinel

restore() {
	cp "${SAFE}/oracle.pristine" "$ORACLE_REL"
	cp "${SAFE}/grant.pristine" "$GRANT_REL"
	chmod "$ORACLE_MODE0" "$ORACLE_REL"
	chmod "$GRANT_MODE0" "$GRANT_REL"
	rm -f "$SENTINEL"
}
rearm() { restore; write_sentinel; }
trap restore EXIT

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
sed -i 's/"d2-signalloom", "d2-osramp-fleet"\]/"d2-signalloom"]/' "$ORACLE_REL"
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
sed -i 's/fe-signalloom-agents/agents-ns-mutated/g' "$GRANT_REL"
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
restore
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
rm -rf "${SAFE:?}"

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
