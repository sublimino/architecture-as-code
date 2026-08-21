#!/usr/bin/env bash
#
# bats-exclusion-registration-mutation-proof.sh — prove the registration
# invariant in d2-signalloom/test/bats-registry-coverage.bats can actually go
# red.
#
# The guard under proof is:
#
#   "every excluded d2-signalloom bats suite is invoked by another runner"
#
# It exists because opting a suite out of the `make -C d2-signalloom test` glob
# removes the only thing that ran it. Tests 4 and 5 in that file already require
# an exclusion to name a real file and to state a reason; neither asks whether
# anything still RUNS it. Three suites sat on EXCLUDED_BATS when this was
# written and two of them — dashboard-image.bats and supercred-demo.bats — were
# invoked by nothing at all, each with a reason paragraph naming the stage it
# had supposedly been moved to. The move was never made. A reason paragraph
# describing a relocation nobody performed reads as a decision and functions as
# a deletion.
#
# A green suite is evidence of nothing until something has been broken and the
# suite has noticed, so each mutation below breaks ONE thing in a REAL file,
# runs the REAL test, and requires red. Two of them additionally require the
# failure to be red for the RIGHT REASON, matched against the message.
#
# ─── Restoration is from a byte copy, never from git ───────────────────────
#
# `git checkout -- <path>` is the obvious way to undo a mutation and it is the
# wrong one here: it would also discard any uncommitted work in the same file,
# and this repo has already lost in-progress edits to a proof harness that did
# exactly that. The original bytes are copied aside before the first mutation
# and copied back in an EXIT trap.
#
# ─── Refuse, do not repair ─────────────────────────────────────────────────
#
# The trap covers a normal exit, an error and SIGTERM/SIGINT. It cannot cover
# SIGKILL, and a harness killed mid-run leaves real Makefiles mutated. A
# sentinel file is written before the first mutation and removed on the way out,
# so a leftover sentinel means "a previous run died while the tree was broken".
# This script REFUSES to start in that state rather than repairing it: repairing
# would overwrite whatever the operator has since done to those files, and would
# hide the fact that a run died. The operator is told exactly which files to
# check and what a leftover diff looks like.

# SC2329: `restore` is invoked by the EXIT/INT/TERM trap, which shellcheck
# cannot see.
# SC2016: the sed expressions below and the operator guidance printed above are
# literal text — `bats d2-signalloom/test/...` is the string being matched in a
# Makefile, not a value to expand here. Single quotes are the correct form.
# shellcheck disable=SC2016,SC2329

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_MK="${REPO_ROOT}/Makefile"
D2_MK="${REPO_ROOT}/d2-signalloom/Makefile"
SUITE="${REPO_ROOT}/d2-signalloom/test/bats-registry-coverage.bats"
TEST_NAME='every excluded d2-signalloom bats suite is invoked by another runner'
SENTINEL="${REPO_ROOT}/.bats-exclusion-registration-mutation-proof.inprogress"

BATS_BIN="${BATS_BIN:-bats}"

ROOT_MK_BACKUP=""
D2_MK_BACKUP=""

restore() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$ROOT_MK_BACKUP" ] && [ -s "$ROOT_MK_BACKUP" ] && cp "$ROOT_MK_BACKUP" "$ROOT_MK" 2>/dev/null
  [ -n "$D2_MK_BACKUP" ] && [ -s "$D2_MK_BACKUP" ] && cp "$D2_MK_BACKUP" "$D2_MK" 2>/dev/null
  rm -f "$ROOT_MK_BACKUP" "$D2_MK_BACKUP" 2>/dev/null
  rm -f "$SENTINEL" 2>/dev/null
  # Explicit exit with the captured status. Under errexit a failing last command
  # in an EXIT trap REPLACES the status the script asked for, and this repo has
  # already lost a run with 8/8 green stages to precisely that.
  exit "$rc"
}

fail() {
  printf 'bats-exclusion-registration-mutation-proof: %s\n' "$*" >&2
  exit 1
}

# Presence before behaviour. A proof harness pointed at files that do not exist
# reports whatever the shell does with a missing path.
[ -f "$ROOT_MK" ] || fail "no root Makefile at ${ROOT_MK}"
[ -f "$D2_MK" ] || fail "no d2-signalloom Makefile at ${D2_MK}"
[ -f "$SUITE" ] || fail "no suite at ${SUITE}"
command -v "$BATS_BIN" >/dev/null 2>&1 || fail "bats is not on PATH"

if [ -e "$SENTINEL" ]; then
  printf 'bats-exclusion-registration-mutation-proof: REFUSING TO RUN.\n' >&2
  printf '\n' >&2
  printf 'A sentinel from a previous run is present:\n  %s\n' "$SENTINEL" >&2
  printf '\n' >&2
  printf 'That run died (SIGKILL, or the machine went away) while these files were\n' >&2
  printf 'MUTATED, and its EXIT trap never restored them:\n' >&2
  printf '  %s\n  %s\n' "$ROOT_MK" "$D2_MK" >&2
  printf '\n' >&2
  printf 'Check them before doing anything else:\n' >&2
  printf '  git diff -- Makefile d2-signalloom/Makefile\n' >&2
  printf '\n' >&2
  printf 'A diff that deletes a `bats d2-signalloom/test/...` line, or that empties\n' >&2
  printf 'EXCLUDED_BATS, is this harness leftovers rather than a real change.\n' >&2
  printf '\n' >&2
  printf 'This script does NOT repair it for you on purpose: repairing would\n' >&2
  printf 'overwrite anything you have done to those files since, and would hide the\n' >&2
  printf 'fact that a run died. Restore what you want, then remove the sentinel:\n' >&2
  printf '  rm %s\n' "$SENTINEL" >&2
  exit 1
fi

# The named test must exist and must be the ONLY thing the filter selects.
# A `-f` regex matching nothing makes bats exit 0 having run zero tests, and
# every mutation below would then read as "the suite still passed" — a harness
# reporting holes it never tested.
selected="$("$BATS_BIN" -f "$TEST_NAME" --count "$SUITE" 2>/dev/null || true)"
[ "$selected" = "1" ] || fail "filter selected '${selected:-0}' tests, expected exactly 1 — has the test been renamed?"

ROOT_MK_BACKUP="$(mktemp "${TMPDIR:-/tmp}/Makefile.root.orig.XXXXXX")"
D2_MK_BACKUP="$(mktemp "${TMPDIR:-/tmp}/Makefile.d2.orig.XXXXXX")"
cp "$ROOT_MK" "$ROOT_MK_BACKUP"
cp "$D2_MK" "$D2_MK_BACKUP"
printf 'in progress since %s (pid %s)\n' "$(date -Is)" "$$" > "$SENTINEL"
trap restore EXIT INT TERM

printf 'bats-exclusion-registration-mutation-proof: originals saved to\n  %s\n  %s\n' \
  "$ROOT_MK_BACKUP" "$D2_MK_BACKUP"

# The test must be GREEN before anything is broken. Without this a test that was
# already failing would make every mutation below look detected, and the harness
# would certify a guard that was red for unrelated reasons.
printf '\n──── BASELINE: the guard must be green before any mutation ────\n'
if ! "$BATS_BIN" -f "$TEST_NAME" "$SUITE" >/dev/null 2>&1; then
  "$BATS_BIN" -f "$TEST_NAME" "$SUITE" 2>&1 | tail -30 >&2
  fail "the guard is RED before any mutation — nothing below would mean anything"
fi
printf 'baseline green.\n'

FAILURES=0
CHECKED=0

restore_all() {
  cp "$ROOT_MK_BACKUP" "$ROOT_MK"
  cp "$D2_MK_BACKUP" "$D2_MK"
}

# prove <label> <file> <sed-expression> [expected-output-regex]
#
# Applies the mutation, PROVES it applied (a sed that matches nothing exits 0
# and changes nothing, which would make the check that follows vacuous — this
# repo has shipped exactly that), runs the named test, and requires red. When an
# expected-output regex is given, the failure must also be red for that reason:
# a guard that fails for an unrelated reason is not evidence about the thing
# being mutated.
prove() {
  local label="$1" target="$2" expr="$3" expected="${4:-}" before after out
  CHECKED=$((CHECKED + 1))

  restore_all
  before="$(md5sum <"$target")"
  sed -i "$expr" "$target"
  after="$(md5sum <"$target")"

  if [ "$before" = "$after" ]; then
    printf '  NO-OP   %s\n' "$label" >&2
    printf '          the expression matched nothing, so the guard was never tested\n' >&2
    printf '          against this mutation. Reported as a HOLE rather than a pass.\n' >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if out="$("$BATS_BIN" -f "$TEST_NAME" "$SUITE" 2>&1)"; then
    printf '  HOLE    %s\n' "$label" >&2
    printf '          the registration was broken and the guard still passed.\n' >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if [ -n "$expected" ] && ! grep -qE "$expected" <<<"$out"; then
    printf '  WRONG-REASON  %s\n' "$label" >&2
    printf '          the guard went red, but not for the expected reason.\n' >&2
    printf '          wanted output matching: %s\n' "$expected" >&2
    printf '%s\n' "$out" | tail -20 >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  printf '  CAUGHT  %s\n' "$label"
}

printf '\n──── MUTATIONS ────\n'

# ── The defect this guard was written for ─────────────────────────────────
#
# supercred-step1-runtime.bats is on EXCLUDED_BATS because it is a pure runtime
# probe that the glob was executing in two stages where nothing deploys the
# objects it waits on. Its coverage survives that exclusion only because the
# root Makefile target demo-signalloom-supercred-runtime-test still runs it.
# Delete that one line and the exclusion becomes a deletion.
prove "the excluded runtime suite loses its only Makefile target" \
  "$ROOT_MK" \
  '\|^[[:space:]]*bats d2-signalloom/test/supercred-step1-runtime\.bats[[:space:]]*$|d' \
  'supercred-step1-runtime\.bats'

# ── The comment trap, which this repo has been bitten by before ───────────
#
# A wiring guard that greps a runner for a NAME counts a mention as an
# invocation, so a commented-out target reads as a running one. That exact
# defect shipped here once: a stage's own comment contained the script name, so
# deleting the real invocation left the test green. The excluded suites are the
# worst case for it, because each one is NAMED at length in the reason paragraph
# explaining its exclusion.
prove "the target is commented out but still names the suite" \
  "$ROOT_MK" \
  's|^[[:space:]]*bats \(d2-signalloom/test/supercred-step1-runtime\.bats\)|# was: bats \1|' \
  'supercred-step1-runtime\.bats'

# ── The two orphans this guard found on its first run ─────────────────────
#
# Both were excluded with a stated destination and invoked by nothing. These
# mutations prove the targets that now own them are load-bearing rather than
# decorative.
prove "the excluded dashboard image suite loses its Makefile target" \
  "$ROOT_MK" \
  '\|^[[:space:]]*bats d2-signalloom/test/dashboard-image\.bats[[:space:]]*$|d' \
  'dashboard-image\.bats'

prove "the excluded supercred demo suite loses its Makefile target" \
  "$ROOT_MK" \
  '\|^[[:space:]]*bats d2-signalloom/test/supercred-demo\.bats[[:space:]]*$|d' \
  'supercred-demo\.bats'

# ── Anti-vacuity ──────────────────────────────────────────────────────────
#
# With EXCLUDED_BATS empty the guard's loop iterates zero times, finds nothing
# unrun, and would report success having checked nothing. Two tests in this very
# file once passed exactly that way. The explicit mechanism assertion is what
# turns it into a failure, and this mutation is the only thing that proves that
# assertion is present and load-bearing.
prove "an empty exclusion list is reported rather than passed over" \
  "$D2_MK" \
  's|^EXCLUDED_BATS = .*|EXCLUDED_BATS =|' \
  'parsed as empty|not ok'

printf '\n──── RESULT ────\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'ALL %d MUTATIONS CAUGHT — the exclusion-registration guard can go red.\n' "$CHECKED"
  exit 0
fi

printf '%d of %d mutations were NOT caught.\n' "$FAILURES" "$CHECKED" >&2
printf 'The guard is decoration: an exclusion can silently delete a suite without it noticing.\n' >&2
exit 1
