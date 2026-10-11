#!/usr/bin/env bash
#
# Mutation proof for the money-chaos suites.
#
# WHY THIS EXISTS. The suites it proves (compliance_money_poison_test.go,
# compliance_money_currency_chaos_test.go, compliance_money_isolation_test.go,
# compliance_money_percentile_gap_test.go) are green on an unmutated tree. So is
# a file containing nothing but `func TestX(t *testing.T) {}`. A chaos suite that
# asserts the wrong thing, asserts nothing, or asserts something the code cannot
# violate reports PASS identically to one that pins a real invariant — which is
# the failure mode test/jev-loop.bats names in its header, applied to tests
# rather than to a bot.
#
# So each mutant below deletes or inverts ONE guard in the production code and
# requires a NAMED test to go red. A mutant that survives is reported as a
# SURVIVOR and fails this script: it means the named test does not actually
# depend on the guard it claims to pin.
#
# THREE MUTANTS DELIBERATELY INVERT THE DIRECTION OF PROOF. M3, M8 and M9 do not
# break the code — they FIX a defect the suites characterise. The test that
# pins the defect must then go red, because a characterisation test whose
# subject has been fixed and which still passes is pinning nothing. This is the
# only way to prove a `_DEFECT` test is a tripwire rather than a tautology.
#
# SAFETY. Every mutated file is restored from an explicit `cp` backup taken at
# the top, never from git — the suites under proof are untracked while this
# work is in progress, and `git checkout -- .` would delete them while leaving
# a mutated tracked file in place (the exact pairing that costs a session).
# The restore runs from an EXIT trap, so an interrupt still restores, and the
# script verifies byte-identity by checksum at the end and fails if it differs.
#
# Run: test/verify-cel-money-chaos-mutation-proof.sh
#      make verify-cel-money-chaos-mutation-proof

set -eo pipefail
# NOTE: deliberately no `set -u`. Claude Code's bash snapshot defines grep/rg
# wrapper functions whose cross-shell guard references $ZSH_VERSION unguarded,
# which nounset turns into a fatal error on every grep call.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PE="$ROOT/d2-signalloom/apps/policy-engine"
BAK="$(mktemp -d "${TMPDIR:-/tmp}/j2-mutation-proof.XXXXXX")"

# The files any mutant may touch. Backed up before anything is changed.
TARGETS=(
  "$PE/compliance.go"
  "$PE/fair/fair.go"
)

declare -a SURVIVORS=()
declare -a KILLED=()
declare -a MISSING=()

cleanup() {
  local rc=$?
  for f in "${TARGETS[@]}"; do
    local name
    name="$(echo "$f" | tr '/' '_')"
    if [ -f "$BAK/$name" ]; then
      cp "$BAK/$name" "$f"
    fi
  done
  # Prove the restore worked rather than assuming it. A mutation proof that
  # leaves a mutant behind has poisoned every suite that runs after it.
  local drift=0
  for f in "${TARGETS[@]}"; do
    local name
    name="$(echo "$f" | tr '/' '_')"
    if ! cmp -s "$BAK/$name" "$f"; then
      echo "FATAL: $f does NOT match its backup after restore" >&2
      drift=1
    fi
  done
  rm -rf "$BAK"
  if [ "$drift" -ne 0 ]; then
    exit 90
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

for f in "${TARGETS[@]}"; do
  [ -f "$f" ] || { echo "missing target $f" >&2; exit 2; }
  cp "$f" "$BAK/$(echo "$f" | tr '/' '_')"
done
echo "backups in $BAK"

restore_all() {
  for f in "${TARGETS[@]}"; do
    cp "$BAK/$(echo "$f" | tr '/' '_')" "$f"
  done
}

# apply <file> <python-mutation-body>
# The mutation is python so an anchor that is absent is a hard AssertionError
# rather than a silent no-op sed. A mutation that did not apply would otherwise
# look exactly like a surviving mutant.
apply() {
  local file="$1" body="$2"
  MUT_FILE="$file" python3 -c "$body"
}

# expect_red <mutant-name> <test-regex> <why>
# Requires `go test -run <regex>` to FAIL. Anything else is a survivor.
#
# THE THIRD OUTCOME, which is the one that bites. `go test -run NoSuchTest`
# exits 0 and prints "[no tests to run]". Without the check below, a typo in a
# test name — or a mutant written before its test exists — reports SURVIVED,
# i.e. "your test is weak", when the truth is "your test is absent". Those
# demand opposite responses, and the exit status cannot tell them apart. So the
# marker is matched explicitly and reported as MISSING, which is a distinct
# failure class with its own exit code.
expect_red() {
  local name="$1" regex="$2" why="$3"
  local out rc
  set +e
  out="$(cd "$PE" && go test -count=1 -run "$regex" ./ 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'no tests to run'; then
    MISSING+=("$name :: $regex")
    printf '  MISSING  %-28s %s\n' "$name" "no test matches /$regex/"
    return
  fi
  if [ "$rc" -ne 0 ]; then
    KILLED+=("$name")
    printf '  KILLED   %-28s %s\n' "$name" "$why"
  else
    SURVIVORS+=("$name :: $regex")
    printf '  SURVIVED %-28s %s\n' "$name" "$why"
    echo "$out" | tail -5 | sed 's/^/           /'
  fi
}

echo
echo "mutant                        proof"
echo "---------------------------------------------------------------------------"

# ── M1: the engine's NaN/Inf guard on riskLoad ────────────────────────────────
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""		if math.IsNaN(load) || math.IsInf(load, 0) {
			return effectiveRiskProfile{}, fmt.Errorf("riskLoad must be a finite number, got %g", load)
		}"""
assert old in s, "M1 anchor absent"
open(p,"w").write(s.replace(old,"		_ = math.IsNaN // MUTANT M1",1))
'
expect_red M1-nan-inf-guard 'TestTheEngineGuardAndTheDatabaseCheckDisagreeOnOverflow' \
  "riskProfileFor must refuse a NaN or Inf load"
restore_all

# ── M2: the engine's negative-load guard ──────────────────────────────────────
apply "$PE/compliance.go" '
import os,re
p=os.environ["MUT_FILE"]; s=open(p).read()
i=s.index("		if load < 0 {")
j=s.index("coherent risk posture\", load)")
j=s.index("}",s.index("\n",j))+1
assert i<j, "M2 anchor absent"
open(p,"w").write(s[:i]+"		// MUTANT M2: negative-load guard deleted\n"+s[j+1:])
'
expect_red M2-negative-guard 'TestTheEngineGuardAndTheDatabaseCheckDisagreeOnOverflow' \
  "riskProfileFor must refuse a negative load"
restore_all

# ── M3 (INVERTED): fix the empty-200 defect ───────────────────────────────────
# Encode into a buffer and check the error BEFORE committing a status line.
# This is one of the three fixes the DEFECT test's comment proposes. The DEFECT
# test must go red — if it survives, it is not pinning the defect.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(results)"""
assert old in s, "M3 anchor absent"
new="""	// MUTANT M3: buffer-then-check, the proposed fix.
	if encoded, err := json.Marshal(results); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": "unrenderable figure: " + err.Error()})
	} else {
		w.WriteHeader(http.StatusOK)
		w.Write(encoded)
	}"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M3-fix-empty-200 'TestAnOverflowingRiskLoadIsServedAs200WithAnEmptyBody_DEFECT' \
  "INVERTED: fixing the empty-200 must break its characterisation test"
restore_all

# ── M4: the currency shape check ──────────────────────────────────────────────
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""		if err := declared.Validate(); err != nil {
			return effectiveRiskProfile{}, fmt.Errorf("reportingCurrency: %w", err)
		}"""
assert old in s, "M4 anchor absent"
open(p,"w").write(s.replace(old,"		// MUTANT M4: currency validation deleted",1))
'
expect_red M4-currency-shape 'TestMalformedReportingCurrenciesAreRefused' \
  "a malformed currency code must be refused, not labelled onto figures"
restore_all

# ── M5: the summary reads its currency from the results ───────────────────────
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="		summary.Currency = results[0].Currency"
assert old in s, "M5 anchor absent"
open(p,"w").write(s.replace(old,"		summary.Currency = defaultReportingCurrency // MUTANT M5",1))
'
expect_red M5-summary-denomination 'TestTheSummaryNeverMixesDenominations' \
  "a declared-currency scan must not be totalled under the default label"
restore_all

# ── M6: the declared-zero pointer ─────────────────────────────────────────────
# Collapse the pointer semantics to the `== 0 means absent` form the OTHER
# engine (signal-ingest/pkg/fair) actually uses. A declared zero then becomes
# the 0.10 default, which is the defect this mutant proves is pinned here.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""		p.RiskLoad = load
		p.Declared = true"""
assert old in s, "M6 anchor absent"
new="""		// MUTANT M6: == 0 treated as absent, as signal-ingest does
		if load == 0 {
			load = fair.DefaultRiskLoad
		}
		p.RiskLoad = load
		p.Declared = true"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M6-declared-zero 'TestADeclaredZeroSurvivesTheWholePathAndNegativeZeroWithIt' \
  "a declared zero must not be silently replaced by the 0.10 default"
restore_all

# ── M7: the load is actually applied to the carried figure ────────────────────
apply "$PE/fair/fair.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="		CarriedGBP:    tvar * (1 + riskLoad),"
assert old in s, "M7 anchor absent"
open(p,"w").write(s.replace(old,"		CarriedGBP:    tvar * (1 + DefaultRiskLoad), // MUTANT M7",1))
'
expect_red M7-load-is-applied 'TestADeclaredZeroSurvivesTheWholePathAndNegativeZeroWithIt' \
  "the declared load, not the default, must reach the carried product"
restore_all

# ── M8 (INVERTED): make the engine convert instead of relabel ─────────────────
# The relabel-not-convert defect, "fixed" by scaling the figures with a stub
# rate. The characterisation test must go red.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""func roundMoney(v float64, c money.Currency) float64 {
	return money.Money{Amount: v, Currency: c}.Round().Amount
}"""
assert old in s, "M8 anchor absent"
new="""func roundMoney(v float64, c money.Currency) float64 {
	// MUTANT M8: convert rather than relabel, with a stub non-unity rate.
	if c != defaultReportingCurrency {
		v = v * 1.27
	}
	return money.Money{Amount: v, Currency: c}.Round().Amount
}"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M8-fix-relabel 'TestADeclaredCurrencyRelabelsWithoutConverting_DEFECT' \
  "INVERTED: converting must break the relabel characterisation"
restore_all

# ── M9 (INVERTED): clamp var95 up to ale ──────────────────────────────────────
# Re-introduce the exact fabrication fair.go's header records as removed. The
# percentile-gap suite must catch it; if it survives, that suite does not
# actually measure the gap it claims to.
apply "$PE/fair/fair.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	if tvar < ale {
		tvar = ale
	}"""
assert old in s, "M9 anchor absent"
new="""	if tvar < ale {
		tvar = ale
	}
	if var95 < ale { // MUTANT M9: the fabricating clamp, re-introduced
		var95 = ale
	}"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M9-var95-clamp 'TestTheTailDominatedFlagIsTheOnlySignalOfAnInvertedPercentile' \
  "re-introducing the var95>=ale clamp must be caught"
restore_all

# ── M10: off-by-one in the TVaR percentile index ──────────────────────────────
# The known example from the brief. Which tier catches it is the subject of the
# percentile-gap suite; this mutant proves that suite is not decoration.
apply "$PE/fair/fair.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="	idx95 := int(math.Ceil(0.95*float64(iterations))) - 1"
assert old in s, "M10 anchor absent"
open(p,"w").write(s.replace(old,"	idx95 := int(math.Ceil(0.95*float64(iterations))) // MUTANT M10: off by one",1))
'
expect_red M10-percentile-off-by-one 'TestAnOffByOnePercentileIndexMovesEveryTailFigure' \
  "an off-by-one in the TVaR index must move a figure a test reads"
restore_all

echo "---------------------------------------------------------------------------"
echo "killed: ${#KILLED[@]}   survived: ${#SURVIVORS[@]}   missing: ${#MISSING[@]}"

if [ "${#MISSING[@]}" -ne 0 ]; then
  echo
  echo "MISSING TESTS — a mutant names a test that does not exist. This is NOT a"
  echo "weak test, it is no test; `go test` exited 0 only because it ran nothing:"
  for s in "${MISSING[@]}"; do echo "  - $s"; done
fi

if [ "${#SURVIVORS[@]}" -ne 0 ]; then
  echo
  echo "SURVIVING MUTANTS — the named test does not depend on the guard it claims:"
  for s in "${SURVIVORS[@]}"; do echo "  - $s"; done
fi

if [ "${#MISSING[@]}" -ne 0 ]; then exit 3; fi
if [ "${#SURVIVORS[@]}" -ne 0 ]; then exit 1; fi

echo "all ${#KILLED[@]} mutants killed"
