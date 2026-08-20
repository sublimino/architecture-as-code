#!/usr/bin/env bash
# vacuous-run-status-mutation-proof.sh — prove five repaired assertions can fail.
#
# ─── What this proves, and why the control half is the important half ───────
#
# scripts/check-vacuous-assertions.sh VAC006 found five bats tests whose `run`
# captured an exit code that nothing then examined. Each asserted a SIDE EFFECT
# — a line in the stubbed gcloud log, a line in the stubbed dex log — and never
# the exit status. A driver that emits those lines and then dies satisfies every
# one of them. All five were merged tonight, by suites that were green, through
# a gate that counted passing tests.
#
# Adding `[ "$status" -eq 0 ]` makes the lint go quiet. That is not evidence.
# The lint checks a SHAPE; it cannot tell a live assertion from a decorative one
# any more than the gate could. So this harness runs each test TWICE against the
# same mutated driver:
#
#   CONTROL   the test file with the repaired assertions stripped back out,
#             which is what it looked like before the repair.
#             Expected GREEN — the mutation is invisible to it. A RED control
#             means the assertion was never vacuous and this whole exercise
#             mis-diagnosed the file.
#
#   REPAIRED  the test file with the status assertion.
#             Expected RED — the mutation is detected.
#
# GREEN-then-RED across that pair is the proof. Either half alone is not:
# a RED repaired run with no control cannot distinguish "my assertion detects
# the defect" from "the mutation broke the test some other way", which is the
# UNFAITHFUL MUTATION shape terraform/CONTRACT.md §7b names.
#
# ─── The mutation, and why it is this one ───────────────────────────────────
#
# ONE mutation, appended to the dispatch `case` at the end of demo-up.sh, so the
# driver does ALL of its work, writes every log line the five tests read, and
# only then exits non-zero. Exactly one variable changes: the exit code, which
# is precisely the variable the five repairs added. A mutation that made the
# driver fail EARLY would break the log assertions too, and a red test would
# then prove nothing about the status assertion specifically.
#
# It is a real defect, not a synthetic one. A driver that completes and then
# reports failure sends `make` into its retry path, and a retried ts-up on a
# live demo is how a working estate gets torn down and rebuilt for nothing.
#
# ─── Safety, per terraform/CONTRACT.md §7b ──────────────────────────────────
#
#   * The REAL scripts/gcp-tf/demo-up.sh is mutated. Both suites copy it into a
#     per-test tmpdir, so a fixture would prove only that the fixture is wired.
#   * Pristine copies live OUTSIDE the repository, at a DETERMINISTIC path, so
#     a SIGKILL that outruns the trap is still recoverable by hand.
#   * `git checkout` is never used to restore — it silently reverts uncommitted
#     work in the same directory.
#   * The mutation is ASSERTED to have applied. A sed whose pattern stopped
#     matching exits 0 and changes nothing, and the run that follows then tests
#     correct code and passes, proving the opposite of what it claims.
#   * A sentinel is dropped while the tree is dirty. Finding one at startup is a
#     REFUSAL, never an auto-repair: a harness that quietly fixes a half-restored
#     tree is the same shape as the guards this repo keeps finding dead.
#   * Restoration is verified by SHA-256 against the pre-run hashes, and the
#     hashes are printed.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRIVER_REL="scripts/gcp-tf/demo-up.sh"
TS_REL="test/terraform-tailscale-access.bats"
DD_REL="test/terraform-demo-driver.bats"

SENTINEL="${REPO_ROOT}/.vacuous-run-status-mutation-proof.RUNNING"
SAFE="${TMPDIR:-/tmp}/osramp-vacuous-run-status-proof"

BATS_BIN="${BATS_BIN:-$(command -v bats || true)}"

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn() { printf '\033[1;32m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }

if [ -z "$BATS_BIN" ]; then
	red "CANNOT RUN: bats is not on PATH. This is not a pass."
	exit 2
fi

# ── Refuse, never repair ────────────────────────────────────────────────────
if [ -e "$SENTINEL" ]; then
	red "REFUSING TO START: a previous run left a sentinel."
	say ""
	say "  $SENTINEL"
	say ""
	say "  That run was killed while the tree was mutated, so the working tree may"
	say "  still contain a deliberately broken driver or an out-of-date test file."
	say "  This harness will NOT repair it: auto-repair is how a broken component"
	say "  ships green, and you would have no way to tell a repaired tree from one"
	say "  that was never damaged."
	say ""
	say "  Pristine copies were left here:"
	say ""
	cat "$SENTINEL" 2>/dev/null | sed 's/^/    /'
	say ""
	say "  Restore each file from that directory by hand, confirm with"
	say "  'git status', delete the sentinel, then re-run."
	exit 2
fi

mkdir -p "$SAFE"
rm -f "${SAFE:?}"/*

# ── Snapshot: pristine working-tree copies, and the HEAD control copies ─────
cp "$DRIVER_REL" "${SAFE}/demo-up.sh.pristine"
cp "$TS_REL" "${SAFE}/tailscale.bats.repaired"
cp "$DD_REL" "${SAFE}/demo-driver.bats.repaired"

# ── Deriving the control ────────────────────────────────────────────────────
#
# The control is the repaired file with the status assertions STRIPPED, not
# `git show HEAD:` of it.
#
# The first draft did use HEAD, and it was wrong in a way worth recording: it
# worked exactly once. The moment the repair was committed, HEAD became the
# repaired file, the control and the repaired copy were identical, and the
# harness could no longer run at all. A proof whose validity expires on commit
# is a proof that runs green in review and never again.
#
# Stripping an ANCHORED block is also the stronger question. `git show HEAD`
# asks "is this file different from a particular past commit?", which stops
# being interesting the moment that commit scrolls away. Stripping asks "is this
# assertion load-bearing RIGHT NOW?" — the same question a reader asks when
# deciding whether the line can be deleted, and the one this repo keeps
# answering wrongly.
ANCHOR='vacuity-proof anchor'
EXPECTED_ANCHORS=6

strip_anchored() { # <src> <dst>
	awk -v anchor="$ANCHOR" '
		index($0, anchor) > 0 { skipping = 1; next }
		skipping && /^[ \t]*\}[ \t]*$/ { skipping = 0; next }
		skipping { next }
		{ print }
	' "$1" >"$2"
}

strip_anchored "${SAFE}/tailscale.bats.repaired" "${SAFE}/tailscale.bats.control"
strip_anchored "${SAFE}/demo-driver.bats.repaired" "${SAFE}/demo-driver.bats.control"

# ASSERT THE STRIP APPLIED, and assert the COUNT.
#
# An awk that matched nothing writes a byte-identical copy and exits 0, and the
# control run that follows would then be the repaired run under another name —
# reporting GREEN-then-RED as proof of a detection that never happened. The
# count matters as much as the presence: stripping four of six anchors leaves
# two tests measuring themselves.
found_anchors="$(grep -c "$ANCHOR" "${SAFE}/tailscale.bats.repaired" "${SAFE}/demo-driver.bats.repaired" |
	awk -F: '{ n += $2 } END { print n + 0 }')"
if [ "$found_anchors" -ne "$EXPECTED_ANCHORS" ]; then
	red "CANNOT RUN: expected ${EXPECTED_ANCHORS} '${ANCHOR}' comments, found ${found_anchors}."
	say "  Either an assertion was added without its anchor, or one was removed"
	say "  and this harness would silently stop covering it. Refusing to run."
	rm -f "${SAFE:?}"/*
	exit 2
fi
for pair in "tailscale.bats" "demo-driver.bats"; do
	if cmp -s "${SAFE}/${pair}.control" "${SAFE}/${pair}.repaired"; then
		red "CANNOT RUN: stripping the anchors changed nothing in ${pair}."
		say "  The control and the repaired copy are the same file, so the two halves"
		say "  below would be one run reported as two. Refusing a vacuous pass."
		rm -f "${SAFE:?}"/*
		exit 2
	fi
	if grep -q "$ANCHOR" "${SAFE}/${pair}.control"; then
		red "CANNOT RUN: an anchor survived the strip in ${pair}.control."
		rm -f "${SAFE:?}"/*
		exit 2
	fi
done

sha() { sha256sum "$1" | cut -d' ' -f1; }

DRIVER_SHA0="$(sha "$DRIVER_REL")"
TS_SHA0="$(sha "$TS_REL")"
DD_SHA0="$(sha "$DD_REL")"

cat >"$SENTINEL" <<EOF
Killed mid-run. Pristine copies (restore BY HAND, do not git checkout):
  ${SAFE}/demo-up.sh.pristine          -> ${DRIVER_REL}
  ${SAFE}/tailscale.bats.repaired      -> ${TS_REL}
  ${SAFE}/demo-driver.bats.repaired    -> ${DD_REL}
Expected SHA-256 after restore:
  ${DRIVER_SHA0}  ${DRIVER_REL}
  ${TS_SHA0}  ${TS_REL}
  ${DD_SHA0}  ${DD_REL}
EOF

restore() {
	cp "${SAFE}/demo-up.sh.pristine" "$DRIVER_REL"
	cp "${SAFE}/tailscale.bats.repaired" "$TS_REL"
	cp "${SAFE}/demo-driver.bats.repaired" "$DD_REL"
	rm -f "$SENTINEL"
}
trap restore EXIT

# ── The mutation ────────────────────────────────────────────────────────────
MUT_MARK='__VACUOUS_PROOF_LATE_FAILURE__'

apply_mutation() {
	cat >>"$DRIVER_REL" <<EOF

# ${MUT_MARK} — injected by test/vacuous-run-status-mutation-proof.sh.
# Every side effect above has already happened; only the exit code changes.
exit 70
EOF
	# ASSERT IT APPLIED. An append cannot silently no-op the way a sed can, but
	# asserting anyway costs nothing and the day this becomes a sed is the day
	# the assertion matters.
	grep -q "$MUT_MARK" "$DRIVER_REL" || {
		red "THE MUTATION DID NOT APPLY. Every verdict below would be vacuous."
		exit 2
	}
	[ "$(sha "$DRIVER_REL")" != "$DRIVER_SHA0" ] || {
		red "THE DRIVER IS BYTE-IDENTICAL AFTER MUTATION. Not a pass."
		exit 2
	}
}

unmutate() { cp "${SAFE}/demo-up.sh.pristine" "$DRIVER_REL"; }

# ── The five tests, by exact name ───────────────────────────────────────────
T1='MUTATION public-down-release: dropping the holder check steals a live origin'
T2='TS ts-up configures serve on the VM, not funnel'
T3='TS ts-up serves the dashboard nginx over loopback, with no VM hosts alias'
T4='TS ts-up claims the Dex origin at the MagicDNS URL'
T5='TS funnel-up and ts-up claim the SAME origin'

# run_named <file> <exact test name> ; echoes PASS | FAIL | NOMATCH
#
# The bats output goes to a FILE, not a variable. run_named is always called in
# a command substitution, so anything it assigns dies with that subshell — an
# earlier draft of this harness set LAST_OUTPUT here and read an empty string
# back, which under `set -u` aborted the run half way through the proof phase.
LAST_OUTPUT_FILE="${SAFE}/last-bats-output.txt"
run_named() {
	local file="$1" name="$2" rc=0
	"$BATS_BIN" --filter "$(printf '%s' "$name" | sed 's/[][\.*^$(){}?+|/]/\\&/g')" \
		"$file" >"$LAST_OUTPUT_FILE" 2>&1 || rc=$?
	# A filter that matches NOTHING exits 0 with no tests — indistinguishable
	# from a pass, and the exact defect this file exists to hunt.
	if ! grep -qE '^(ok|not ok) ' "$LAST_OUTPUT_FILE"; then
		printf 'NOMATCH'
		return 0
	fi
	[ "$rc" -eq 0 ] && printf 'PASS' || printf 'FAIL'
}

declare -a NAMES=("$T1" "$T2" "$T3" "$T4" "$T5")
declare -a FILES=("$DD_REL" "$TS_REL" "$TS_REL" "$TS_REL" "$TS_REL")

FINDINGS=0
say ""
say "=== baseline: unmutated driver, repaired tests (all must be GREEN) ======"
say ""
unmutate
for i in "${!NAMES[@]}"; do
	r="$(run_named "${FILES[$i]}" "${NAMES[$i]}")"
	if [ "$r" = "PASS" ]; then
		grn "  GREEN  ${NAMES[$i]}"
	else
		red "  ${r}  ${NAMES[$i]}"
		red "         the repaired test is not green on a CLEAN tree; nothing below is measurable"
		FINDINGS=$((FINDINGS + 1))
	fi
done

say ""
say "=== control: MUTATED driver, assertions STRIPPED (all must stay GREEN) =="
say "    A green here is the vacuity itself, reproduced on demand."
say ""
apply_mutation
cp "${SAFE}/tailscale.bats.control" "$TS_REL"
cp "${SAFE}/demo-driver.bats.control" "$DD_REL"
declare -a CONTROL=()
for i in "${!NAMES[@]}"; do
	r="$(run_named "${FILES[$i]}" "${NAMES[$i]}")"
	CONTROL+=("$r")
	if [ "$r" = "PASS" ]; then
		grn "  GREEN  ${NAMES[$i]}"
		say "         ^ the pre-repair assertion did NOT notice the driver exited 70"
	else
		red "  ${r}  ${NAMES[$i]}"
		red "         control went red — this test was NOT vacuous in the way claimed"
		FINDINGS=$((FINDINGS + 1))
	fi
done

say ""
say "=== proof: MUTATED driver, repaired tests (all must go RED) ============="
say ""
cp "${SAFE}/tailscale.bats.repaired" "$TS_REL"
cp "${SAFE}/demo-driver.bats.repaired" "$DD_REL"
for i in "${!NAMES[@]}"; do
	r="$(run_named "${FILES[$i]}" "${NAMES[$i]}")"
	if [ "$r" = "FAIL" ]; then
		grn "  RED    ${NAMES[$i]}"
		grep -E '^#' "$LAST_OUTPUT_FILE" | head -3 | sed 's/^/           /' || true
	else
		red "  ${r}  ${NAMES[$i]}"
		red "         STILL DECORATIVE: the driver exited 70 and this test did not care."
		FINDINGS=$((FINDINGS + 1))
	fi
done

# ── Restore and prove it ────────────────────────────────────────────────────
restore
trap - EXIT

say ""
say "--- restore proof ---"
ok_restore=1
for pair in "${DRIVER_REL}:${DRIVER_SHA0}" "${TS_REL}:${TS_SHA0}" "${DD_REL}:${DD_SHA0}"; do
	f="${pair%:*}"
	want="${pair##*:}"
	got="$(sha "$f")"
	if [ "$got" = "$want" ]; then
		say "  OK   ${f}"
		say "       ${got}"
	else
		red "  DIFF ${f}"
		red "       want ${want}"
		red "       got  ${got}"
		ok_restore=0
		FINDINGS=$((FINDINGS + 1))
	fi
done
[ "$ok_restore" -eq 1 ] && say "  all three files byte-identical to their pre-run state."
rm -rf "${SAFE:?}"

say ""
say "=== summary ============================================================"
say "  cases          : ${#NAMES[@]}"
say "  findings       : ${FINDINGS}"
if [ "$FINDINGS" -ne 0 ]; then
	red "FINDINGS PRESENT — at least one assertion is still incapable of failing,"
	red "or the tree was not restored. Read the lines above; do not re-run blind."
	exit 1
fi
grn "All ${#NAMES[@]} repaired assertions went GREEN on a clean tree, stayed GREEN"
grn "under mutation once stripped, and went RED under mutation once restored."
grn "The vacuity is removed, not moved."
