#!/usr/bin/env bash
#
# Prove test/user-surface-gate.bats is not vacuous, by breaking the gate on
# purpose and requiring a NAMED test to notice.
#
# A suite that went 17/17 on its first run is a suite that has not yet
# demonstrated it can fail. That is the exact shape this whole slice exists to
# correct — 29/29 PASS over two dead demos — so the gate's own suite is held to
# the standard it enforces.
#
# Restoration is by FILE COPY, never `git checkout`. A proof harness that runs
# `git checkout` reverts the operator's uncommitted work and reads exactly like
# a real finding. Backups are taken up front, restored in an EXIT trap, and
# verified byte-for-byte at the end.
#
# Note the trap covers SIGTERM but cannot cover SIGKILL. If this is -9'd, the
# repo is left mutated; the final checksum line is what tells you it was not.

set -o pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

GATE="scripts/ci/user-surface-gate.sh"
REG="scripts/ci/demo-surface-registry.py"
FAILURES=0
# Counted, never hardcoded: a literal here drifts the moment a mutation is added,
# and a proof that misreports its own size is a small version of the problem this
# whole slice is about.
CHECKS=0

GATE_SUM="$(sha256sum "$GATE" | cut -d' ' -f1)"
REG_SUM="$(sha256sum "$REG"   | cut -d' ' -f1)"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# An EXIT trap was the whole protection here, and it does not survive SIGKILL —
# which is what a tool timeout escalates to. A hard kill leaves these two files
# mutated, the &&-chained gate carries on into the next proof, and the leak
# reads as content lost in a merge. The helper leaves a marker that outlives the
# kill, REFUSES to start on top of one rather than repairing it, and verifies
# the restore on content AND mode.
# See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "$(pwd)/test/helpers/mutation-sentinel.bash"

ms_guard_init user-surface-gate "$GATE" "$REG"
trap ms_guard_on_exit EXIT

restore() { ms_guard_restore; }

# apply_mutation <file> <old-literal> <new-literal>
#
# Old and new travel through argv, never through the script text. An earlier
# draft interpolated them into a heredoc and needed \x27 gymnastics to survive
# two levels of quoting; every one of those mutations silently failed to parse.
# The guard below is what turned that into a visible HARNESS ERROR instead of
# four fabricated "this assertion is vacuous" findings — which is exactly the
# claim it would have made, about assertions that are in fact fine.
#
# Asserts the edit CHANGED the file: a no-op mutation leaves the original code
# in place, the test then passes for the RIGHT reason, and a harness without
# this check reports it as a vacuous assertion.
#
# The sentinel is armed BY HAND here and BEFORE the write: the mutation is a
# python3 rewrite rather than an ms_sed, so the rail cannot arm on this call
# site's behalf, and a kill between the write and the check below would leave
# the file broken with nothing on disk recording that a harness did it.
apply_mutation() {
  local file="$1" old="$2" new="$3" before after
  ms_guard_arm "${file}: ${old} -> ${new}"
  before="$(sha256sum "$file" | cut -d' ' -f1)"
  python3 -c '
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if old not in s:
    sys.exit(0)          # leave the file alone; the checksum guard reports it
open(path, "w").write(s.replace(old, new, 1))
' "$file" "$old" "$new"
  after="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    echo "    HARNESS ERROR: mutation did not change ${file} — pattern no longer matches."
    echo "    Refusing to report a verdict from an unmutated file."
    return 1
  fi
  return 0
}

# check <label> <test-name> <file> <old-literal> <new-literal>
check() {
  local label="$1" test_name="$2" file="$3" old="$4" new="$5"
  CHECKS=$(( CHECKS + 1 ))
  printf '\n──── %s\n' "$label"
  restore
  if ! apply_mutation "$file" "$old" "$new"; then
    FAILURES=$(( FAILURES + 1 )); return
  fi
  # bats -f filters by test name; the mutation must make THAT test fail.
  local out status
  out="$(timeout 240 bats -f "$test_name" test/user-surface-gate.bats 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "    RED as required — '${test_name}' caught it."
    printf '%s\n' "$out" | grep -E '^(not ok|# )' | head -4 | sed 's/^/      /'
  else
    echo "    STILL GREEN — the mutation was NOT caught. This assertion is vacuous."
    printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    FAILURES=$(( FAILURES + 1 ))
  fi
}

echo "════ MUTATION PROOF: test/user-surface-gate.bats ═══════════════════"

# M1 — the assertion that catches BOTH real outages. Both demos returned 200
# with script_available=false, so removing this check restores the blindness.
check "M1  accept any 200 as healthy (drop the script_available check)" \
  "200 with script_available=false is BROKEN" \
  "$GATE" \
  'if [ "$available" != "true" ]; then' \
  'if [ "$available" = "__never_matches__" ]; then'

# M2 — the root cause this repo keeps re-committing. Replace the derived
# enumeration with a hand-written list of the demos that exist TODAY. The
# suite must notice the third demo the list does not know about.
check "M2  hand-written demo list instead of registry enumeration" \
  "a demo added to the registry alone is probed and FAILS the gate" \
  "$GATE" \
  'registry_out="$(python3 "$REGISTRY_TOOL" "$REGISTRY_SOURCE" "$SPA_API_DIR" 2>&1)"' \
  "$(printf 'registry_out="supercred\tSuperCred\ts.sh\t/api/demo/supercred\nsignalfusion\tSignal Fusion\ts.sh\t/api/demo/signalfusion"')"

# M3 — a zero-demo registry passing vacuously is how a gate reports coverage
# over nothing at all.
check "M3  empty registry no longer hard-stops" \
  "a registry with zero demos is a hard stop" \
  "$REG" \
  '        raise SystemExit(f"{REGISTRY_NAME} parsed to zero demos — a gate over an empty set proves nothing")' \
  '        pass'

# M4 — collapsing 404 into the generic broken bucket destroys the
# "not deployed vs deployed and broken" distinction the operator acts on.
check "M4  404 reported as BROKEN rather than NOT_DEPLOYED" \
  "a 404 route is NOT_DEPLOYED" \
  "$GATE" \
  'echo NOT_DEPLOYED; return' \
  'echo BROKEN; return'

# M5 — a broken token reported as a product outage is a whole-estate false RED.
check "M5  token-mint failure reported as a demo failure (exit 1)" \
  "an unmintable token is CANNOT-RUN" \
  "$GATE" \
  'outage teaches its operator to disbelieve it."
  exit 2' \
  'outage teaches its operator to disbelieve it."
  exit 1'

# M6 — the failure counter is the only thing standing between a red run and
# exit 0. Incrementing nothing is a classic always-green gate.
check "M6  failures never counted (gate always exits 0)" \
  "200 with script_available=false is BROKEN" \
  "$GATE" \
  'log "    VERDICT: ${verdict} — FAILED"; failures=$(( failures + 1 ))' \
  'log "    VERDICT: ${verdict} — FAILED"'

# M7 — a run that starts and fails must not be counted as completion.
check "M7  terminal 'failed' treated as success" \
  "--execute reports RAN_FAILED" \
  "$GATE" \
  '      failed|cancelled|timed_out)' \
  '      cancelled|timed_out)'

# M8 — assume the client calls the server prefix. This is the exact defect the
# gate shipped with for one run: it reported SuperCred BROKEN at
# /api/demo/supercred, a path no client uses and which is broken by design.
check "M8  client prefix assumed equal to the server prefix" \
  "the real SPA prefixes are read per-demo" \
  "$REG" \
  '    for src in sorted(spa_dir.glob("*.ts")):' \
  '    return f"/api/demo/{demo_type}"
    for src in sorted(spa_dir.glob("*.ts")):'

# M10 — revert the client<->demo linkage to matching the server path, which in
# the real modules appears only in a doc comment. This is the exact fragility
# measured against the in-flight signalfusion fix.
check "M10 client linkage matched on a doc-comment string" \
  "client prefix resolves with no server path anywhere in the module" \
  "$REG" \
  '        if token not in _norm(src.name) and token not in _norm(text):' \
  '        if f"/api/demo/{demo_type}" not in text:'

# M9 — a demo no client can reach must not be waved through.
check "M9  demo with no client module silently skipped" \
  "a demo with no client module is NO_CLIENT_PATH" \
  "$GATE" \
  '  if [ -z "$pfx" ]; then' \
  '  if [ "$pfx" = "__never_matches__" ]; then'

restore
echo ""
echo "════ RESTORATION ═══════════════════════════════════════════════════"
now_gate="$(sha256sum "$GATE" | cut -d' ' -f1)"
now_reg="$(sha256sum "$REG"   | cut -d' ' -f1)"
if [ "$now_gate" = "$GATE_SUM" ] && [ "$now_reg" = "$REG_SUM" ]; then
  echo "  both files restored byte-for-byte to their pre-mutation checksums"
else
  echo "  RESTORATION FAILED — files differ from their originals. Do not commit."
  FAILURES=$(( FAILURES + 1 ))
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "MUTATION PROOF FAILED: ${FAILURES} mutation(s) went unnoticed or the harness erred."
  exit 1
fi
echo "MUTATION PROOF PASSED: all ${CHECKS} mutations were caught by a named test."
exit 0
