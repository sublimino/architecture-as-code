#!/usr/bin/env bats
#
# @id      tombstone-mutation-check
# @target  d2-signalloom/apps/signal-ingest/privacy/tombstone/mutation-check.sh
#
# The tombstone mutation harness aborted half-way: the "reinstate the P4-PRE
# subject-oracle digest" mutant still matched ReceiptCommitment(nonce,
# projection), the call had gained req.ReceiptDigest, apply() exited 1 under
# set -e, and every later mutant silently never ran. A pattern that no longer
# matches must be reported by name, counted as a failure, and must not stop
# the remaining mutants.
#
# Runs in a shared clone (HEAD plus this worktree's uncommitted tracked
# edits, committed there): the harness mutates tombstone.go in place, which
# must never touch the tree the rest of the lane compiles.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  c="$BATS_TEST_TMPDIR/repo"
  git clone -q --shared --no-checkout "$repo_root" "$c"
  git -C "$c" checkout -q --detach "$(git -C "$repo_root" rev-parse HEAD)"
  local f
  git -C "$repo_root" diff --name-only -z HEAD | while IFS= read -r -d '' f; do
    if [ -e "$repo_root/$f" ]; then cp -p "$repo_root/$f" "$c/$f"; else rm -f "$c/$f"; fi
  done
  git -C "$c" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -am "worktree overlay"
  pkg="$c/d2-signalloom/apps/signal-ingest/privacy/tombstone"
  export GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
}

@test "a stale pattern is named, counted, and the remaining mutants still run" {
  # Make the second of two selected mutants stale.
  python3 - "$pkg/mutation-check.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
o = "  'return t.UTC().Format(\"2006-01-02\")' \\\n  'return t.Format(\"2006-01-02\")' \\"
assert s.count(o) == 1, "fixture anchor moved"
s = s.replace(o, "  'return t.UTC().Format(\"STALE-ANCHOR\")' \\\n  'return t.Format(\"2006-01-02\")' \\")
open(p, "w").write(s)
PY
  MUTCHECK_ONLY='coarsen' run bash "$pkg/mutation-check.sh"
  [ "$status" -ne 0 ] || { echo "a stale pattern exited 0: $output"; return 1; }
  # The STALE PATTERN line itself names both the mutant and the pattern (apply()'s own stderr
  # also prints the pattern, so a match anywhere in the output would prove nothing).
  rg -q -e '^STALE PATTERN +coarsen in local time rather than UTC .*STALE-ANCHOR' <<<"$output" \
    || { echo "no STALE PATTERN line naming the mutant and its pattern: $output"; return 1; }
  [[ "$output" == *"killed"*"coarsen to the nanosecond instead of the day"* ]] || { echo "the other mutant did not run: $output"; return 1; }
  [[ "$output" == *"killed=1 survived_or_inconclusive=0 stale=1"* ]] || { echo "$output"; return 1; }
  git -C "$c" diff --quiet -- d2-signalloom/apps/signal-ingest/privacy/tombstone/tombstone.go || { echo "tombstone.go left mutated"; return 1; }
}

@test "a stale pattern ahead of other mutants does not stop them (the abort that hid the rest)" {
  python3 - "$pkg/mutation-check.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
o = "ReceiptCommitment(nonce, projection, req.ReceiptDigest),"
assert o in s, "the oracle mutant's pattern is not the current call"
s = s.replace(o, "ReceiptCommitment(nonce, projection),", 1)
open(p, "w").write(s)
PY
  MUTCHECK_ONLY='subject-oracle|unkeyed' run bash "$pkg/mutation-check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE PATTERN"*"reinstate the P4-PRE subject-oracle digest"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"killed"*"make the confirmation commitment unkeyed"* ]] || { echo "the later mutant never ran: $output"; return 1; }
}

@test "the subject-oracle mutant matches the current call and is killed" {
  MUTCHECK_ONLY='subject-oracle' run bash "$pkg/mutation-check.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"killed"*"reinstate the P4-PRE subject-oracle digest"* ]]
}

@test "a filter that selects no mutant fails rather than passing vacuously" {
  MUTCHECK_ONLY='no-such-mutant' run bash "$pkg/mutation-check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"selected no mutant"* ]]
}
