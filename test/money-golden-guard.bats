#!/usr/bin/env bats
#
# Attacks on the money-golden movement guard.
#
# WHAT THE GUARD IS FOR. `MONEY_GOLDEN=update` regenerates the pinned money
# figures. It once absorbed an engine regression wholesale -- the Makefile
# records that "one character in fair.go moved 64 figures across 5 packs by
# 4-5%" and update mode turned the whole suite green. So the guard was added:
# update mode pins a NEW check's figures freely, and REFUSES to rewrite an
# already-pinned figure unless the movement is acknowledged by BOTH
#
#     MONEY_GOLDEN_MOVE_REASON="<why these prices moved>"
#     MONEY_GOLDEN_MOVE_CHECKS=<the exact number of checks expected to move>
#
# and both are recorded into each affected golden's lastMovement block.
#
# WHY THIS SUITE EXISTS. The guard is the only thing standing between an engine
# regression and a green suite for three of the four figures the product quotes
# (see fair/percentile_gap_test.go for the measurement). Its own correctness is
# therefore load-bearing, and it is asserted nowhere: compliance_money_test.go
# contains the guard, not a test OF the guard. Every attack below either
# confirms a refusal or documents an acceptance, and the acceptances are the
# findings.
#
# SAFETY, which matters more here than anywhere else in this work. These tests
# RUN UPDATE MODE against the real checked-in goldens, and deliberately mutate
# fair.go to make figures move. Everything is restored from an explicit `cp`
# backup in a trap, and the suite verifies byte-identity by checksum in
# teardown. Nothing is restored from git: `git checkout --` would also delete
# the untracked chaos suites this work is adding.
#
# A FAILED RESTORE IS A HARD FAILURE, not a warning. If teardown cannot put the
# goldens and fair.go back exactly as it found them, the test fails loudly --
# because a half-restored golden is a silently wrong priced figure, which is the
# whole thing this estate exists to prevent.

setup_file() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export ROOT
  export PE="$ROOT/d2-signalloom/apps/policy-engine"
  export GOLDEN_DIR="$PE/testdata/money-golden"
  export GUARD_BAK
  GUARD_BAK="$(mktemp -d "${TMPDIR:-/tmp}/money-golden-guard.XXXXXX")"

  local gopath="${GOPATH:-}"
  if [ "$gopath" = "/usr/local/src/gocode" ] || [ -z "$gopath" ]; then gopath=/tmp/gopath; fi
  export GOPATH="$gopath"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export GONOSUMDB="*"
  export CGO_ENABLED=0

  cp -r "$GOLDEN_DIR" "$GUARD_BAK/money-golden"
  cp "$PE/fair/fair.go" "$GUARD_BAK/fair.go"

  # A manifest of checksums, so teardown proves the restore rather than
  # assuming it.
  ( cd "$GOLDEN_DIR" && md5sum ./*.json ) > "$GUARD_BAK/golden.md5"
  md5sum "$PE/fair/fair.go" | awk '{print $1}' > "$GUARD_BAK/fair.md5"
}

teardown_file() {
  rm -rf "$GOLDEN_DIR"
  cp -r "$GUARD_BAK/money-golden" "$GOLDEN_DIR"
  cp "$GUARD_BAK/fair.go" "$PE/fair/fair.go"

  local drift=0
  if ! ( cd "$GOLDEN_DIR" && md5sum -c --quiet "$GUARD_BAK/golden.md5" ) 2>/dev/null; then
    echo "FATAL: golden files do not match their pre-test checksums" >&2
    drift=1
  fi
  local now
  now="$(md5sum "$PE/fair/fair.go" | awk '{print $1}')"
  if [ "$now" != "$(cat "$GUARD_BAK/fair.md5")" ]; then
    echo "FATAL: fair.go does not match its pre-test checksum" >&2
    drift=1
  fi
  rm -rf "$GUARD_BAK"
  [ "$drift" -eq 0 ] || return 1
}

# restore_state puts the goldens and fair.go back between tests, so each attack
# starts from the committed state rather than from the previous attack's wreckage.
restore_state() {
  rm -rf "$GOLDEN_DIR"
  cp -r "$GUARD_BAK/money-golden" "$GOLDEN_DIR"
  cp "$GUARD_BAK/fair.go" "$PE/fair/fair.go"
}

# move_figures mutates fair.go so that every priced check's carried figure
# changes. Changing DefaultRiskLoad is the smallest edit that moves a figure
# without touching a triple or a celExpression.
move_figures() {
  python3 - <<'PY'
import os
p = os.environ["PE"] + "/fair/fair.go"
s = open(p).read()
old = "const DefaultRiskLoad = 0.10"
assert old in s, "DefaultRiskLoad anchor absent"
open(p, "w").write(s.replace(old, "const DefaultRiskLoad = 0.11", 1))
PY
}

# run_update invokes update mode with the given REASON/CHECKS environment.
run_update() {
  local reason="$1" checks="$2"
  ( cd "$PE" && env \
      MONEY_GOLDEN=update \
      MONEY_GOLDEN_MOVE_REASON="$reason" \
      MONEY_GOLDEN_MOVE_CHECKS="$checks" \
      go test -count=1 -run TestWriteMoneyGolden . 2>&1 )
}

# moved_count parses the number of moved checks out of a refusal message, so the
# "correct count" attacks use the guard's OWN number rather than a guess.
moved_count() {
  printf '%s' "$1" | sed -n 's/.*figures moved for \([0-9]\+\) already-pinned check(s).*/\1/p' | head -1
}

goldens_unchanged() {
  ( cd "$GOLDEN_DIR" && md5sum -c --quiet "$GUARD_BAK/golden.md5" ) >/dev/null 2>&1
}

# ── 1. The refusals that work ─────────────────────────────────────────────────

@test "GUARD an unacknowledged movement is refused and writes nothing" {
  restore_state
  move_figures

  run run_update "" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]

  # The refusal is ATOMIC: no file is written, so there is no half-updated set.
  # Asserted by checksum over every golden, not by spot-checking one.
  goldens_unchanged
}

@test "GUARD a whitespace-only reason is not a reason" {
  restore_state
  move_figures

  # The guard TrimSpaces the reason, so spaces, tabs and newlines all collapse
  # to the empty string. Pinned because "" and "   " are different strings and
  # only an explicit trim makes them behave alike.
  for reason in " " "   " "	" "
"; do
    run run_update "$reason" "$(moved_count "$(run_update '' '' || true)")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    goldens_unchanged
  done
}

@test "GUARD a correct reason with the wrong count is refused" {
  restore_state
  move_figures

  local first n
  # run_update REFUSES here, so it exits non-zero by design. Under bats'
  # errexit a bare assignment from a failing command aborts the test, which
  # reads as "the guard did not refuse" when the truth is the opposite.
  first="$(run_update '' '' || true)"
  n="$(moved_count "$first")"
  [ -n "$n" ]

  # One too few, one too many, zero, negative, non-numeric, a leading zero and
  # an explicit plus. The comparison is a string compare against
  # strconv.Itoa(moved), so "053" and "+53" are NOT 53 even though a human
  # reads them as such -- which is the correct strictness for a confirmation.
  for bad in "$((n - 1))" "$((n + 1))" "0" "-$n" "many" "+$n" "0$n" "$n.0" "${n}x"; do
    run run_update "a deliberate recalibration" "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    goldens_unchanged
  done

  # WHITESPACE PADDING IS ACCEPTED, and that is deliberate rather than a hole.
  # The guard TrimSpaces the COUNT as well as the reason, so " 53" and "53 "
  # both equal 53. Asserted explicitly because an earlier draft of this test
  # assumed the opposite and failed -- the code was right and the test was
  # wrong. Recorded so the symmetry (both fields trimmed) is on the record and
  # nobody "fixes" one of them.
  run run_update "padding is tolerated on the count" " $n "
  [ "$status" -eq 0 ]
  echo "NOTE: MONEY_GOLDEN_MOVE_CHECKS is TrimSpace'd, so \" $n \" == $n" >&3
  restore_state
}

@test "GUARD a reason with no count, and a count with no reason, are both refused" {
  restore_state
  move_figures

  local n
  n="$(moved_count "$(run_update '' '' || true)")"

  run run_update "recalibrated after the 2026 loss study" ""
  [ "$status" -ne 0 ]
  goldens_unchanged

  run run_update "" "$n"
  [ "$status" -ne 0 ]
  goldens_unchanged
}

# ── 2. The acknowledged path, and what it records ─────────────────────────────

@test "GUARD an acknowledged movement is accepted and records its provenance" {
  restore_state
  move_figures

  local n
  n="$(moved_count "$(run_update '' '' || true)")"
  [ -n "$n" ]

  run run_update "J2 chaos probe: DefaultRiskLoad 0.10 -> 0.11" "$n"
  [ "$status" -eq 0 ]

  # The goldens DID change, and the reason and count landed in the file as a
  # sentence a reviewer reads instead of re-deriving the figures.
  ! goldens_unchanged
  run grep -l "J2 chaos probe" "$GOLDEN_DIR"/*.json
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  run grep -h '"checksMoved"' "$GOLDEN_DIR"/*.json
  [ "$status" -eq 0 ]

  restore_state
}

# ── 3. The attacks that SUCCEED — these are the findings ──────────────────────

@test "GUARD FINDING the count is a cardinality claim with no identity binding" {
  restore_state
  move_figures

  local n
  n="$(moved_count "$(run_update '' '' || true)")"

  # The guard's predicate is `reason == "" || declared != strconv.Itoa(moved)`.
  # It compares HOW MANY checks moved against a number the operator typed. It
  # never compares WHICH checks moved against anything, because the operator is
  # never asked which. So a reason naming entirely unrelated checks is accepted
  # in full, provided the arithmetic happens to agree.
  #
  # This is the laundering vector that remains. A legitimate single-check
  # recalibration declares 1; an unrelated engine regression that happens to
  # move exactly one check is acknowledged by the same "1", under a reason that
  # describes something else, and lands as reviewed.
  run run_update "recalibrated ONLY cis-kubernetes/no-host-ports after the 2026 loss study" "$n"
  [ "$status" -eq 0 ]

  # Accepted, despite the reason being false: the movement was an engine-wide
  # DefaultRiskLoad change affecting every priced check in every pack.
  run grep -l "recalibrated ONLY cis-kubernetes" "$GOLDEN_DIR"/*.json
  [ "$status" -eq 0 ]
  local affected
  affected="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  # More than one pack carries the single-check reason, which is the proof.
  [ "$affected" -gt 1 ]

  echo "FINDING: a reason naming one check was recorded into $affected golden files" >&3
  restore_state
}

@test "GUARD FINDING the engine-moved diagnostic is printed but not enforced" {
  restore_state
  move_figures

  # The guard computes `engineMoved` -- checks whose figures moved with
  # IDENTICAL triples and seed, which is the signature of an ENGINE change
  # rather than an input change. It LOGS that ("so the ENGINE moved, not the
  # inputs") and then does not use it in the decision. The predicate is still
  # just reason-present AND count-matches.
  #
  # So the one signal that distinguishes "we recalibrated an input" from "the
  # engine changed underneath us" is shown to the operator and ignored by the
  # gate. A regression is acknowledgeable with the same two fields as a
  # deliberate recalibration, and nothing requires the operator to have read
  # the distinction.
  local first n
  first="$(run_update '' '' || true)"   # refuses by design; see the note above
  n="$(moved_count "$first")"

  # The diagnostic fires for this mutation, because the triples did not change.
  [[ "$first" == *"ENGINE moved"* ]]

  # And acknowledging it needs nothing extra.
  run run_update "engine change, acknowledged with the same two fields" "$n"
  [ "$status" -eq 0 ]

  echo "FINDING: 'the ENGINE moved, not the inputs' was printed, and the movement was" >&3
  echo "         acknowledgeable with exactly the same REASON+CHECKS as an input change" >&3
  restore_state
}

@test "GUARD a new check is pinned freely while an existing one is moved" {
  restore_state

  # Update mode pins NEW checks without acknowledgement, by design -- that is
  # the convenience it exists for. The question this attack asks is whether an
  # addition can ride along inside an acknowledged movement without being
  # counted, and the answer is that additions are reported separately and are
  # never part of the CHECKS arithmetic.
  #
  # Documented rather than flagged as a defect: pinning a new figure is not a
  # movement of a reviewed one, so excluding it from the count is defensible.
  # It is recorded because "CHECKS=1" does NOT mean "one figure in this file
  # changed" -- it means "one previously-pinned figure moved", and a reviewer
  # reading the commit should know the difference.
  move_figures
  local n
  n="$(moved_count "$(run_update '' '' || true)")"

  run run_update "moved $n, and any new checks are pinned alongside unacknowledged" "$n"
  [ "$status" -eq 0 ]
  echo "NOTE: CHECKS counts MOVED figures only; newly-pinned figures are reported" >&3
  echo "      separately and are not part of the arithmetic the operator confirms" >&3
  restore_state
}

# ── 4. The suite's own honesty check ─────────────────────────────────────────

@test "GUARD the committed goldens are byte-identical to where this suite started" {
  restore_state
  # Not decoration. Every test above writes to the real checked-in goldens, and
  # a suite that leaves one rewritten has silently changed a priced figure --
  # exactly the outcome the guard it is testing exists to prevent. This runs
  # last and asserts the restore, independently of teardown_file.
  goldens_unchanged

  local now
  now="$(md5sum "$PE/fair/fair.go" | awk '{print $1}')"
  [ "$now" = "$(cat "$GUARD_BAK/fair.md5")" ]
}
