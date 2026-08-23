#!/usr/bin/env bash
# Mutation proof for test/terraform-observability-fleet-parity.bats.
#
# A guard that has never been watched failing is worth less than no guard: it
# occupies the slot where a working one would go. This reintroduces the real
# defect — and each assertion's specific failure mode — into the REAL files on
# disk, runs the suite, and requires the expected test to go RED.
#
# Real-file mutation, not a fixture copy, because the suite reads the actual
# scripts/push-local.sh and scripts/lib/fleet-source.sh by absolute path. A
# proof against a copy would exonerate the shipped file for a defect in a
# throwaway.
#
# ─── Safety ─────────────────────────────────────────────────────────────────
#
# Pristine copies are taken before anything is touched and restored by a trap on
# EXIT, INT, TERM and HUP. That trap survives Ctrl-C and `kill`, but NOT
# SIGKILL. A `kill -9` still leaves the tree mutated — no trap can be written
# that prevents it — so the shared rail below leaves a SENTINEL that outlives
# the kill, and the next run REFUSES to start rather than measuring a tree
# nobody has looked at. The refusal prints the exact command that tells a leaked
# mutation from a real regression; do not reach for `git checkout` first, it
# would also revert unrelated uncommitted work in this tree.
#
# Deliberately no `set -e` and no `set -o pipefail`: a mutation harness spends
# its life running commands that are SUPPOSED to fail, and errexit turns each
# expected failure into a harness abort. Statuses are checked explicitly instead.
# For the same reason the EXIT trap must not end on a failing command — under
# errexit that would overwrite a successful exit 0 with the trap's own status,
# which this repo has watched happen (8/8 green reporting failure).

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"

PUSH="scripts/push-local.sh"
LIB="scripts/lib/fleet-source.sh"
SUITE="test/terraform-observability-fleet-parity.bats"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# An EXIT trap was the whole protection here, and it does not survive SIGKILL —
# which is what a tool timeout escalates to. The helper leaves a marker that
# outlives a hard kill, REFUSES to start on top of one rather than repairing
# it, and verifies the restore on content AND mode.
#
# ms_guard_on_exit captures $? FIRST and re-raises it, which is the same
# invariant the old `return 0` was protecting: under errexit a failing last
# command in an EXIT trap replaces the status the script asked for, and this
# repo has watched 8/8 green report failure that way. It adds the other half —
# a PASSING run whose restore failed is promoted to a harness error rather than
# handing the next proof in the &&-chain a mutated file and calling it green.
#
# The signal list is kept: EXIT alone does not fire for an untrapped SIGTERM.
# See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init observability-fleet-parity "$PUSH" "$LIB"
trap ms_guard_on_exit EXIT INT TERM HUP

# The rail's pristine copies, mirrored under their repo-relative paths.
PUSH_PRISTINE="${MS_BACKUP_DIR}/${PUSH}"
LIB_PRISTINE="${MS_BACKUP_DIR}/${LIB}"

PASS=0
FAIL=0

# Run one test by name and report whether it FAILED (which is what we want).
# bats -f takes an extended regex over test names.
expect_red() {
  local label="$1" test_name="$2" out status
  out="$(bats -f "$test_name" "$SUITE" 2>&1)"
  status=$?
  if [[ $status -ne 0 ]]; then
    echo "  ok   $label -> '$test_name' went RED as required"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label -> '$test_name' stayed GREEN under mutation (vacuous guard)"
    echo "$out" | sed 's/^/       /'
    FAIL=$((FAIL + 1))
  fi
}

# Assert the mutation actually changed the file. A sed that matches nothing
# no-ops and exits 0, which would make every expect_red below a measurement of
# the unmutated tree.
assert_mutated() {
  local label="$1" file="$2" pristine="$3"
  if cmp -s "$file" "$pristine"; then
    echo "  FAIL $label -> mutation did not apply to $file; this proves nothing"
    FAIL=$((FAIL + 1))
    return 1
  fi
  return 0
}

reset_files() { ms_guard_restore; }

# Every mutation below is applied by python3, not by ms_sed, so the sentinel is
# armed BY HAND and BEFORE the write. A mutation applied with no marker on disk
# leaves nothing behind when the run is killed — which is the entire hole the
# sentinel exists to close. reset_files disarms on a successful restore, so each
# mutation re-arms with its own label; the label is what the next run's refusal
# prints.
arm() { ms_guard_arm "$1"; }

echo "=== baseline: the suite must be GREEN before any mutation ==="
if bats "$SUITE" >/dev/null 2>&1; then
  echo "  ok   baseline green"
  PASS=$((PASS + 1))
else
  echo "  FAIL baseline is already red; every result below is meaningless"
  bats "$SUITE" 2>&1 | sed 's/^/       /'
  exit 1
fi

# ── M1 — THE HISTORICAL DEFECT ──────────────────────────────────────────────
# push_fleet falls back to the raw unfiltered tree, exactly as it did before
# 2026-08-22. This is the mutation that matters: it is not a hypothetical, it is
# the code that shipped and broke three of four lanes.
echo "=== M1 push_fleet defaults to the unfiltered d2-osramp-fleet ==="
arm "M1 push_fleet defaults to the unfiltered fleet"
python3 - "$PUSH" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
new = 'push_fleet() {\n  push_and_sign "fleet" "${1:-d2-osramp-fleet}"\n}\n'
s2 = re.sub(r'^push_fleet\(\) \{.*?^\}\n', new, s, count=1, flags=re.S | re.M)
sys.exit(0 if s2 != s else 1) if s2 == s else open(p, 'w').write(s2)
PY
if assert_mutated M1 "$PUSH" "$PUSH_PRISTINE"; then
  expect_red M1 "every fleet publisher resolves its path through the filter"
  expect_red M1 "no push path names the raw fleet tree as a default argument"
fi
reset_files

# ── M2 — the two sides stop being derived from one list ─────────────────────
echo "=== M2 push_foundation carries a hardcoded artifact list again ==="
arm "M2 push_foundation hardcodes its artifact list"
python3 - "$PUSH" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace(
    'while IFS= read -r tenant; do',
    'artifacts+=( "infra/monitoring|d2-infra/components/monitoring" )\n  while IFS= read -r tenant; do',
    1)
if s2 != s:
    open(p, 'w').write(s2)
PY
if assert_mutated M2 "$PUSH" "$PUSH_PRISTINE"; then
  expect_red M2 "the filtered fleet's tenants are exactly what foundation pushes"
fi
reset_files

# ── M3 — the absent-before bracket is removed ───────────────────────────────
# This is the silent-no-op class: without the pre-check, a sed whose pattern no
# longer matches removes nothing and returns success.
echo "=== M3 the absent-before assertion is dropped from _fleet_strip_tenant ==="
arm "M3 absent-before assertion dropped"
python3 - "$LIB" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(
    r'  if \[\[ "\$before" -eq 0 \]\]; then.*?\n  fi\n',
    '  if [[ "$before" -eq 0 ]]; then\n    :\n  fi\n',
    s, count=1, flags=re.S)
if s2 != s:
    open(p, 'w').write(s2)
PY
if assert_mutated M3 "$LIB" "$LIB_PRISTINE"; then
  # NOT "refuses a fleet it cannot edit" — that case is caught by the
  # present-AFTER check (the drifted line is still there once sed no-ops), so it
  # stays green under this mutation and would have made M3 a false negative.
  # Observed on the first run of this harness. The already-removed case is the
  # only one the absent-BEFORE check uniquely owns.
  expect_red M3 "the filter refuses a fleet with the tenant already gone"
fi
reset_files

# ── M4 — the stray-reference sweep is removed ───────────────────────────────
echo "=== M4 the post-filter stray-reference sweep is disabled ==="
arm "M4 stray-reference sweep disabled"
python3 - "$LIB" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace(
    '''    stray="$(grep -rl --include='*.yaml' --include='*.yml' \\
      "tenant: \\"${tenant}\\"" "$dest" 2>/dev/null || true)"''',
    '    stray=""',
    1)
if s2 != s:
    open(p, 'w').write(s2)
PY
if assert_mutated M4 "$LIB" "$LIB_PRISTINE"; then
  expect_red M4 "the filter refuses a tenant that reappears elsewhere"
fi
reset_files

# ── M5 — the tenant list is emptied ─────────────────────────────────────────
# Nothing is stripped, and the helper reports success. The closest thing to
# "the filter silently did nothing", which is the failure this whole suite is
# about.
echo "=== M5 OBSERVABILITY_TENANTS is emptied ==="
arm "M5 OBSERVABILITY_TENANTS emptied"
python3 - "$LIB" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace('OBSERVABILITY_TENANTS=(monitoring trivy-system)',
               'OBSERVABILITY_TENANTS=()', 1)
if s2 != s:
    open(p, 'w').write(s2)
PY
if assert_mutated M5 "$LIB" "$LIB_PRISTINE"; then
  expect_red M5 "observability=false strips monitoring and trivy-system"
  expect_red M5 "the observability tenant list is the single source of truth"
fi
reset_files

echo
echo "=== restored; the suite must be GREEN again ==="
if bats "$SUITE" >/dev/null 2>&1; then
  echo "  ok   post-restore green"
  PASS=$((PASS + 1))
else
  echo "  FAIL suite did not recover after restore; the tree may still be mutated"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== mutation proof: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
