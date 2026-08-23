#!/usr/bin/env bash
#
# dual-lane-registration-mutation-proof.sh — prove every assertion in
# test/terraform-dual-lane-registration.bats can actually go red.
#
# That suite was 6/6 green the moment it was written, which is the state a
# registry guard is least trustworthy in: the estate it examines was already
# symmetric, so a suite that measured nothing at all would have produced the
# identical output. This repo has shipped that shape at least five times, and
# every instance was found by accident. So each mutation below breaks ONE thing
# in a REAL file, runs the REAL suite, and requires red for the RIGHT REASON.
#
# ── Per-test coverage, so a green run means something specific ─────────────
#
#   test 1 (floor/mechanism)   MUT-EXTRACTOR-BLIND, MUT-ALLOWLIST-BLOB
#   test 2 (demo -> CI)        MUT-DROP-FROM-CI, MUT-RENAME-IN-DEMO
#   test 3 (CI -> demo)        MUT-DROP-FROM-DEMO, MUT-RENAME-IN-DEMO
#   test 4 (allowlist exists)  MUT-RENAME-ALLOWLISTED-SUITE
#   test 5 (allowlist reason)  MUT-REASON-REMOVED
#   test 6 (allowlist stale)   MUT-ALLOWLIST-SPENT
#
# ── The rename case is called out on purpose ──────────────────────────────
#
# Another guard in this repo matched an object name as a SUBSTRING, so renaming
# the object left all five of its tests green — the guard reported on a name
# that no longer referred to anything. MUT-RENAME-IN-DEMO and
# MUT-RENAME-ALLOWLISTED-SUITE exist because "the guard notices a deletion" and
# "the guard notices a rename" are different claims, and only the first one is
# obvious.
#
# ── Restoration is from a byte copy, never from git ───────────────────────
#
# `git checkout -- <path>` would also discard uncommitted work in the same
# files, and this repo has already lost in-progress edits to a proof harness
# that did exactly that. Originals are copied aside before the first mutation
# and copied back in an EXIT trap.
#
# ── Refuse, do not repair ─────────────────────────────────────────────────
#
# The trap covers exit, error and SIGTERM/SIGINT. It cannot cover SIGKILL, so a
# sentinel is written before the first mutation and removed on the way out. A
# leftover sentinel means a previous run died with the tree mutated; this script
# REFUSES rather than repairing, because repairing would overwrite whatever the
# operator has done since and would hide the fact that a run died.

# SC2329: `restore` is invoked by the EXIT/INT/TERM trap, which shellcheck
# cannot see.
# shellcheck disable=SC2329

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${REPO_ROOT}/test/terraform-dual-lane-registration.bats"
DEMO="${REPO_ROOT}/scripts/gcp-tf/demo-pipeline.sh"
VM="${REPO_ROOT}/scripts/ci/vm-pipeline.sh"
KNOBS="${REPO_ROOT}/test/supervise-port-forward-knobs.bats"
BATS_BIN="${BATS_BIN:-bats}"

KNOBS_RENAMED=0

fail() {
  printf 'dual-lane-registration-mutation-proof: %s\n' "$*" >&2
  exit 1
}

# Presence before behaviour. A proof harness pointed at files that do not exist
# reports whatever the shell does with a missing path.
[ -f "$SUITE" ] || fail "no suite at ${SUITE}"
[ -f "$DEMO" ] || fail "no demo pipeline at ${DEMO}"
[ -f "$VM" ] || fail "no CI pipeline at ${VM}"
[ -f "$KNOBS" ] || fail "no allowlisted suite at ${KNOBS}"
command -v "$BATS_BIN" >/dev/null 2>&1 || fail "bats is not on PATH"

# Every test this harness claims to cover must EXIST and be selected by exactly
# one filter. `bats --filter` matching nothing exits 0 having run zero tests, so
# a renamed test would turn every mutation below into a guaranteed pass — a
# harness reporting coverage of holes it never looked at.
TESTS=(
  'DUALREG both lane suite lists are non-empty and above the floor'
  'DUALREG every suite the demo lane runs is also run by the CI lane'
  'DUALREG every suite the CI lane runs is also run by the demo lane'
  'DUALREG every allowlisted single-lane suite exists on disk'
  'DUALREG every allowlisted single-lane suite has a stated reason'
  'DUALREG no allowlist entry is stale: each is registered in exactly one lane'
)
for t in "${TESTS[@]}"; do
  selected="$("$BATS_BIN" --count --filter "$t" "$SUITE" 2>/dev/null || true)"
  [ "$selected" = "1" ] \
    || fail "filter '${t}' selected '${selected:-0}' tests, expected exactly 1 — renamed?"
done

# ── The shared safety rail ────────────────────────────────────────────
#
# A sentinel from a previous run means that run died (SIGKILL, or the machine
# went away) with these files MUTATED and its EXIT trap never reached. The rail
# REFUSES to start on top of it rather than repairing: a diff that drops a .bats
# name from a run_stage list, or that empties SINGLE_LANE_ALLOWED, is harness
# leftovers rather than a real change, and only a human should decide which.
#
# Three things the hand-rolled version this replaces could not do. Its marker
# ended in a suffix `.gitignore` does not match. Its restore was
# `[ -s "$BACKUP" ] && cp ...`, which SILENTLY SKIPS a missing backup and
# silently installs a damaged one. And it removed the marker unconditionally, so
# a restore that failed left a mutated tree with nothing recording it.
#
# $KNOBS is guarded too even though it is RENAMED rather than edited: the rail
# then verifies it came back, and reports it by name if it did not.
# See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init dual-lane-registration "$SUITE" "$DEMO" "$VM" "$KNOBS"

# The rename is this harness's own business, so the trap is a wrapper.
#
# The rename is undone FIRST. The rail would restore $KNOBS from its pristine
# copy, but a stray ${KNOBS}.renamed left beside it is a second copy of a bats
# suite — and the registry guards in this very suite count suites on disk.
#
# The subshell preserves the verdict: ms_guard_on_exit reads `$?` to decide the
# script's status, and by then `$?` is the status of the `mv` above it. This
# harness has the strongest reason in the tree to get that right — it is the one
# that lost an 8/8-green run to a trap rewriting its own exit status.
cleanup() {
  local status=$?
  if [ "$KNOBS_RENAMED" -eq 1 ] && [ -f "${KNOBS}.renamed" ]; then
    mv "${KNOBS}.renamed" "$KNOBS" 2>/dev/null
    KNOBS_RENAMED=0
  fi
  (exit "$status")
  ms_guard_on_exit
}
trap cleanup EXIT INT TERM

printf 'dual-lane-registration-mutation-proof: originals saved under\n  %s\n' \
  "$MS_BACKUP_DIR"

printf '\n──── BASELINE: the whole suite must be green before any mutation ────\n'
if ! "$BATS_BIN" "$SUITE" >/dev/null 2>&1; then
  "$BATS_BIN" --tap "$SUITE" 2>&1 | tail -30 >&2
  fail "the suite is RED before any mutation — nothing below would mean anything"
fi
printf 'baseline green.\n'

FAILURES=0
CHECKED=0

restore_all() {
  # The rename is undone BEFORE the rail restores, for the reason given on the
  # trap above: $KNOBS is guarded, so the rail would put it back from its
  # pristine copy and leave ${KNOBS}.renamed sitting beside it as a second copy
  # of a bats suite — which the registry guards in this suite count.
  if [ "$KNOBS_RENAMED" -eq 1 ]; then
    [ -f "${KNOBS}.renamed" ] && mv "${KNOBS}.renamed" "$KNOBS"
    KNOBS_RENAMED=0
  fi
  ms_guard_restore
}

# prove <label> <test-name> <expected-output-regex> <mutate-fn>
#
# Applies the mutation via a function (some of these are renames, not seds),
# PROVES it changed something, runs the ONE named test, and requires red for the
# stated reason. A mutation that changes nothing is reported as a HOLE, never as
# a pass: a sed whose pattern stopped matching exits 0 and no-ops, and this repo
# has shipped exactly that.
prove() {
  local label="$1" test_name="$2" expected="$3" mutate="$4" before after out
  CHECKED=$((CHECKED + 1))

  restore_all
  # Armed by hand, and BEFORE the mutation runs. The mutators below are a mix of
  # seds and renames, so ms_sed cannot arm on their behalf; without this a kill
  # between "$mutate" and the assertions would leave the tree broken with
  # nothing on disk recording that a harness did it.
  ms_guard_arm "${label}: ${test_name}"
  before="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | md5sum; md5sum "$SUITE" "$DEMO" "$VM")"
  "$mutate"
  after="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | md5sum; md5sum "$SUITE" "$DEMO" "$VM")"

  if [ "$before" = "$after" ]; then
    printf '  NO-OP   %s\n' "$label" >&2
    printf '          the mutation changed nothing, so the guard was never tested\n' >&2
    printf '          against it. Reported as a HOLE rather than a pass.\n' >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if out="$("$BATS_BIN" --tap --filter "$test_name" "$SUITE" 2>&1)"; then
    printf '  HOLE    %s\n' "$label" >&2
    printf '          the registration was broken and "%s" still passed.\n' "$test_name" >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if ! grep -qE "$expected" <<<"$out"; then
    printf '  WRONG-REASON  %s\n' "$label" >&2
    printf '          red, but not for the expected reason: %s\n' "$expected" >&2
    printf '%s\n' "$out" | tail -20 >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  printf '  CAUGHT  %s\n' "$label"
}

printf '\n──── MUTATIONS ────\n'

# ── MUT-DROP-FROM-CI ──────────────────────────────────────────────────────
#
# The exact reproduction two agents performed by hand before this guard existed:
# remove a suite from vm-pipeline.sh alone. bats-registry-coverage.bats stayed
# 9/9 green because demo-pipeline.sh still names it, which is the whole reason
# this file is a second guard rather than a tightening of that one.
mut_drop_from_ci() {
  sed -i 's|test/zot-cache\.bats||' "$VM"
}
prove "MUT-DROP-FROM-CI: a suite deleted from the CI lane only" \
  'DUALREG every suite the demo lane runs is also run by the CI lane' \
  'zot-cache\.bats' \
  mut_drop_from_ci

# ── MUT-DROP-FROM-DEMO ────────────────────────────────────────────────────
#
# The other direction, and the one that had actually happened twice unnoticed:
# acceptance-gateway-forward.bats and resourceset-inputs-declarative.bats were
# both registered in vm-pipeline.sh and never in demo-pipeline.sh.
mut_drop_from_demo() {
  sed -i 's|test/acceptance-gateway-forward\.bats||' "$DEMO"
}
prove "MUT-DROP-FROM-DEMO: a suite deleted from the demo lane only" \
  'DUALREG every suite the CI lane runs is also run by the demo lane' \
  'acceptance-gateway-forward\.bats' \
  mut_drop_from_demo

# ── MUT-RENAME-IN-DEMO — the substring trap, driven deliberately ──────────
#
# A guard that matches names as substrings reports on a name rather than on a
# file, so a rename leaves it green. `test/ci-lock.bats` renamed to
# `test/ci-lockX.bats` in ONE lane must be caught from BOTH directions: the CI
# lane still runs test/ci-lock.bats and the demo lane no longer does.
mut_rename_in_demo() {
  sed -i 's|test/ci-lock\.bats|test/ci-lockX.bats|' "$DEMO"
}
prove "MUT-RENAME-IN-DEMO: renamed in one lane, seen from the CI side" \
  'DUALREG every suite the CI lane runs is also run by the demo lane' \
  'test/ci-lock\.bats' \
  mut_rename_in_demo

prove "MUT-RENAME-IN-DEMO: renamed in one lane, seen from the demo side" \
  'DUALREG every suite the demo lane runs is also run by the CI lane' \
  'test/ci-lockX\.bats' \
  mut_rename_in_demo

# ── MUT-EXTRACTOR-BLIND ───────────────────────────────────────────────────
#
# The failure that makes every set difference above empty. If the token regex
# stops matching, both lanes extract nothing, both directions agree perfectly,
# and this file certifies symmetry having looked at zero suites. Test 1's floor
# is the only thing standing between that and a green run.
mut_extractor_blind() {
  sed -i "s|grep -oE '(\^\|\[\^A-Za-z0-9._/-\])|grep -oE '(^\|[^A-Za-z0-9._/-])ZZZ|" "$SUITE"
}
prove "MUT-EXTRACTOR-BLIND: the token regex matches nothing" \
  'DUALREG both lane suite lists are non-empty and above the floor' \
  'extracted only 0 suite|The extractor is broken' \
  mut_extractor_blind

# ── MUT-ALLOWLIST-BLOB ────────────────────────────────────────────────────
#
# EXCLUDED_BATS shipped this exact bug: a space-separated variable used where a
# newline-separated list was needed matched no filename at all, and BOTH
# exclusions became silent no-ops. It was invisible locally and failed on the CI
# VM twice. Here the equivalent is an allowlist that reads as one blob, which
# would excuse nothing while looking like a populated policy.
mut_allowlist_blob() {
  sed -i 's|^  printf .%s\\n. \${SINGLE_LANE_ALLOWED}|  printf "%s\\n" "${SINGLE_LANE_ALLOWED}"|' "$SUITE"
}
prove "MUT-ALLOWLIST-BLOB: the allowlist is read as one blob, not a list" \
  'DUALREG both lane suite lists are non-empty and above the floor' \
  'is not a test/<name>.bats path|not ok' \
  mut_allowlist_blob

# ── MUT-RENAME-ALLOWLISTED-SUITE — the rename case, again, on the policy ──
#
# An allowlist entry survives a rename of its suite looking perfectly healthy:
# it still names a path, still carries its reason paragraph, and now describes
# nothing. Worse than a missing entry, because it silently pre-approves any file
# later created at that path. This is a REAL file rename, not a text edit —
# nothing else proves test 4 consults the filesystem at all.
mut_rename_allowlisted_suite() {
  mv "$KNOBS" "${KNOBS}.renamed"
  KNOBS_RENAMED=1
}
prove "MUT-RENAME-ALLOWLISTED-SUITE: an allowlisted suite is renamed on disk" \
  'DUALREG every allowlisted single-lane suite exists on disk' \
  'supervise-port-forward-knobs\.bats' \
  mut_rename_allowlisted_suite

# ── MUT-REASON-REMOVED ────────────────────────────────────────────────────
#
# An exclusion without a reason is an accident wearing a decision's clothes.
# Strip the reason paragraph and leave the entry: the policy still reads as
# deliberate to anyone scanning the variable.
mut_reason_removed() {
  sed -i '/^#       Demo lane only, and deliberately paired/,/^#       a second lane until it is understood\./d' "$SUITE"
  sed -i '/^#   test\/supervise-port-forward-knobs\.bats$/d' "$SUITE"
}
prove "MUT-REASON-REMOVED: an allowlist entry loses its stated reason" \
  'DUALREG every allowlisted single-lane suite has a stated reason' \
  'supervise-port-forward-knobs\.bats' \
  mut_reason_removed

# ── MUT-ALLOWLIST-SPENT ───────────────────────────────────────────────────
#
# The entry that quietly stopped being an exception. Register the allowlisted
# suite in the second lane too and the entry excuses nothing — but it remains
# standing permission for a FUTURE de-registration of that same suite, which is
# the thing this whole file exists to catch. An allowlist nobody prunes decays
# into blanket pre-approval.
mut_allowlist_spent() {
  sed -i 's|test/zot-cache\.bats|test/zot-cache.bats test/supervise-port-forward-knobs.bats|' "$VM"
}
prove "MUT-ALLOWLIST-SPENT: an allowlisted suite becomes dual-registered" \
  'DUALREG no allowlist entry is stale: each is registered in exactly one lane' \
  'demo=1,ci=1' \
  mut_allowlist_spent

printf '\n──── RESULT ────\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'ALL %d MUTATIONS CAUGHT — the dual-lane registration guard can go red.\n' "$CHECKED"
  exit 0
fi

printf '%d of %d mutations were NOT caught.\n' "$FAILURES" "$CHECKED" >&2
printf 'The guard is decoration: a suite can run in one lane without it noticing.\n' >&2
exit 1
