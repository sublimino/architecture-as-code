#!/usr/bin/env bash
#
# demo-mission-honesty-mutation-proof.sh — prove test/demo-mission-honesty.bats
# can actually go red when the theatre comes back.
#
# The suite under proof guards scripts/demo-crkc-mission.sh, which is the script
# someone runs in front of an audience. A green suite is evidence of nothing
# until something has been broken and the suite has noticed, and that matters
# more here than anywhere else in this repo: every other figure in this estate
# is read by an engineer who can check it, and this one is read aloud to a room
# that cannot.
#
# Nine mutations, each reinstating ONE of the four verified fabrications in a
# REAL file, each required to turn a NAMED test red FOR THE STATED REASON. A
# mutation that goes red for an unrelated reason is not evidence about the thing
# mutated.
#
# Registration is by name: Makefile's GCP_TF_PROOFS globs
# `test/*-mutation-proof.sh`, so this file is executed the day it lands.
#
# ─── Restoration is from a byte copy, never from git ───────────────────────
#
# `git checkout -- <path>` would also discard any uncommitted work in the same
# files, and this repo has already lost in-progress edits to a proof harness
# that did exactly that. Originals are copied aside by the shared sentinel
# before the first mutation and copied back in the EXIT trap, verified on
# content and mode.

# SC2329: `restore_all` is invoked by the EXIT/INT/TERM trap, which shellcheck
# cannot see.
# SC2016: the sed expressions are literal text to insert into shell and JSON
# files, not values to expand here. Single quotes are the correct form.
# shellcheck disable=SC2016,SC2329

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${REPO_ROOT}/test/demo-mission-honesty.bats"
DEMO="${REPO_ROOT}/scripts/demo-crkc-mission.sh"
REPRO="${REPO_ROOT}/scripts/verify-demo-reproducibility.sh"
BENCH="${REPO_ROOT}/docs/signalloom/benchmarks/mission-benchmarks.json"
BATS_BIN="${BATS_BIN:-bats}"

fail() {
  printf 'demo-mission-honesty-mutation-proof: %s\n' "$*" >&2
  exit 1
}

# Presence before behaviour. A proof harness pointed at files that do not exist
# reports whatever the shell does with a missing path.
for f in "$SUITE" "$DEMO" "$REPRO" "$BENCH"; do
  [ -f "$f" ] || fail "missing ${f}"
done
command -v "$BATS_BIN" >/dev/null 2>&1 || fail "bats is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

# Every name this harness targets must select EXACTLY ONE test. A `-f` regex
# matching nothing makes bats exit 0 having run zero tests, and every mutation
# would then read as "the guard still passed" — a harness reporting holes it
# never tested. This is the instrument check, and it is not optional: `go test
# -run`, `pytest -k` and vitest name filters all share the same exit-0-on-zero
# behaviour, and this repo has already shipped a 12-case mutation sweep that ran
# against an unchanged file and certified every guard as decoration.
TEST_NAMES=(
  'demo script source carries no metric-shaped literal'
  'demo script output contains no figure that is also a literal in its source'
  'demo script prints no unmeasured success banner'
  'demo script never swallows a failed computation'
  'demo script does not delegate to the simulated freeze benchmark'
  'demo script refuses the three metrics with no producer'
  'demo script fails loudly when the risk engine is unavailable'
  'benchmarks json carries no percentile ladder'
  'every benchmarks json entry declares its evidence state and a reason or provenance'
  'reproducibility script asserts no authored literal against an authored threshold'
)
for n in "${TEST_NAMES[@]}"; do
  selected="$("$BATS_BIN" -f "$n" --count "$SUITE" 2>/dev/null || true)"
  [ "$selected" = "1" ] \
    || fail "filter '${n}' selected '${selected:-0}' tests, expected exactly 1 — has it been renamed?"
done
printf 'instrument check: %d test names each select exactly 1 test.\n' "${#TEST_NAMES[@]}"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# A sentinel from a previous run means that run died with these files MUTATED
# and its EXIT trap never reached. The rail REFUSES to start on top of it rather
# than repairing: repairing would overwrite anything done to those files since,
# and would hide that a run died.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init demo-mission-honesty "$DEMO" "$REPRO" "$BENCH"
trap ms_guard_on_exit EXIT INT TERM

printf 'originals saved under\n  %s\n' "$MS_BACKUP_DIR"

printf '\n──── BASELINE: the whole suite must be green before any mutation ────\n'
if ! "$BATS_BIN" "$SUITE" >/dev/null 2>&1; then
  "$BATS_BIN" "$SUITE" 2>&1 | tail -40 >&2
  fail "the suite is RED before any mutation — nothing below would mean anything"
fi
printf 'baseline green.\n'

FAILURES=0
CHECKED=0

restore_all() { ms_guard_restore; }

# prove <label> <file> <sed-expression> <test-name> [expected-output-regex]
#
# Applies the mutation, PROVES it applied (a sed that matches nothing exits 0
# and changes nothing, which would make the check that follows vacuous — this
# repo has shipped exactly that), runs the NAMED test, and requires red.
prove() {
  local label="$1" target="$2" expr="$3" name="$4" expected="${5:-}" before after out
  CHECKED=$((CHECKED + 1))

  restore_all
  # Armed by hand and BEFORE the write. Deliberately not ms_sed: ms_sed ABORTS
  # on a no-op, and this harness reports a no-op as a HOLE and keeps going so
  # that one dead pattern cannot hide the verdict on every mutation after it.
  ms_guard_arm "${label}: ${target}"
  before="$(md5sum <"$target")"
  sed -i "$expr" "$target"
  after="$(md5sum <"$target")"

  if [ "$before" = "$after" ]; then
    printf '  NO-OP   %s\n' "$label" >&2
    printf '          the expression matched nothing, so the guard was never tested\n' >&2
    printf '          against this mutation. Reported as a HOLE, not a pass.\n' >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if out="$("$BATS_BIN" -f "$name" "$SUITE" 2>&1)"; then
    printf '  HOLE    %s\n' "$label" >&2
    printf '          the theatre was reinstated and "%s" still passed.\n' "$name" >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if [ -n "$expected" ] && ! grep -qE "$expected" <<<"$out"; then
    printf '  WRONG-REASON  %s\n' "$label" >&2
    printf '          red, but not for the expected reason.\n' >&2
    printf '          wanted output matching: %s\n' "$expected" >&2
    printf '%s\n' "$out" | tail -20 >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  printf '  CAUGHT  %s\n' "$label"
}

printf '\n──── MUTATIONS ────\n'

# ── Fabrication 1: the hardcoded closing banner ────────────────────────────
#
# The original printed five figures with no shell expansion anywhere in them,
# and contradicted its own measurement doing it: it measured a value into
# ${CALC_MS}, printed it, and four lines later printed an unrelated 18.4ms for
# the same metric.

prove 'reinstate one hardcoded killswitch latency figure' \
  "$DEMO" \
  '$a echo "  Killswitch Latency p95:  12.0ms (SLA: < 1000ms, Target: < 250ms)"' \
  'demo script source carries no metric-shaped literal' \
  '12\.0ms'

prove 'reinstate one hardcoded FAIR latency figure' \
  "$DEMO" \
  '$a echo "  FAIR Risk Calculation:   18.4ms"' \
  'demo script output contains no figure that is also a literal in its source' \
  '18\.4ms'

prove 'reinstate the unmeasured success banner' \
  "$DEMO" \
  '$a echo "  Mission Demonstration Completed Successfully (100% Green)"' \
  'demo script prints no unmeasured success banner' \
  'banner text survives'

prove 'reinstate the hardcoded 100.0% drop rate' \
  "$DEMO" \
  '$a echo "  TC Packet Drop Rate:     100.0%"' \
  'demo script prints no unmeasured success banner' \
  'banner text survives'

# ── Fabrication 2: a real computation invoked and discarded ────────────────

prove 'swallow the risk engine failure with || true' \
  "$DEMO" \
  's|^"${RISK_CMD\[@\]}" > "${RISK_JSON}"$|"${RISK_CMD[@]}" > "${RISK_JSON}" \|\| true|' \
  'demo script never swallows a failed computation' \
  'failure cannot be seen'

prove 'ignore the RISKCTL_BIN injection point' \
  "$DEMO" \
  's|^RISKCTL_BIN="${RISKCTL_BIN:-${REPO_ROOT}/tools/riskctl/riskctl}"$|RISKCTL_BIN="${REPO_ROOT}/tools/riskctl/riskctl"|' \
  'demo script fails loudly when the risk engine is unavailable' \
  'exited 0 with no risk engine'

# ── Fabrication 3: narrating what cannot be measured ──────────────────────

prove 'turn the refusals into passes' \
  "$DEMO" \
  's|UNAVAILABLE\\n|OK\\n|' \
  'demo script refuses the three metrics with no producer' \
  'fewer than three UNAVAILABLE'

prove 'reinstate the simulated freeze benchmark delegation' \
  "$DEMO" \
  '$a "$REPO_ROOT/test/bench-redteam-stress.sh"' \
  'demo script does not delegate to the simulated freeze benchmark' \
  'delegates to a simulated benchmark'

# ── Fabrication 4: an authored benchmark with no producer ──────────────────
#
# The percentile ladders are the tell. You cannot author a distribution, so four
# quantiles of a run that never happened are the clearest possible signal — and
# the reproducibility harness then read them back and asserted them against
# thresholds in the same file, which is an assertion with no failure mode.

prove 'reinstate one authored percentile' \
  "$BENCH" \
  's|"internal_target_ms": 250.0,|"internal_target_ms": 250.0, "p95_ms": 12.0,|' \
  'benchmarks json carries no percentile ladder' \
  'percentile ladders survive'

prove 'declare an unproducible metric as measured, with no provenance' \
  "$BENCH" \
  's|"evidence_state": "unavailable",|"evidence_state": "measured",|' \
  'every benchmarks json entry declares its evidence state and a reason or provenance' \
  'measured with no provenance'

prove 'reinstate the tautological threshold assertion' \
  "$REPRO" \
  '$a python3 -c "assert 12.0 < 250.0" # p95_ms' \
  'reproducibility script asserts no authored literal against an authored threshold' \
  'tautological assertions survive'

restore_all

printf '\n──── VERDICT ────\n'
if [ "$FAILURES" -ne 0 ]; then
  printf '%d of %d mutations were NOT caught. The guard is not what it claims.\n' \
    "$FAILURES" "$CHECKED" >&2
  exit 1
fi
printf 'all %d mutations caught, each by the named test and for the stated reason.\n' "$CHECKED"
