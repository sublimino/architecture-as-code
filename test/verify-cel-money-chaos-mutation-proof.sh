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
SI="$ROOT/d2-signalloom/apps/signal-ingest"
BAK="$(mktemp -d "${TMPDIR:-/tmp}/j2-mutation-proof.XXXXXX")"

# The files any mutant may touch. Backed up before anything is changed.
TARGETS=(
  "$PE/compliance.go"
  "$PE/fair/fair.go"
  "$PE/money/money.go"
  "$PE/types.go"
  "$SI/pkg/fair/engine.go"
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
expect_red() { expect_red_in "$PE" "$1" "$2" "$3" './'; }

# expect_red_in <module-dir> <mutant-name> <test-regex> <why> <package-pattern>
# The module-aware form. signal-ingest is a separate Go module, so its tests
# cannot be reached from the policy engine's directory.
expect_red_in() {
  local dir="$1" name="$2" regex="$3" why="$4" pkg="${5:-./}"
  local out rc
  set +e
  out="$(cd "$dir" && go test -count=1 -run "$regex" "$pkg" 2>&1)"
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

# ── M11 (INVERTED): fix the empty summary ─────────────────────────────────────
# Same buffer-then-check at the summary's encode site. The persistent-empty
# characterisation must go red.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(summary)"""
assert old in s, "M11 anchor absent"
new="""	// MUTANT M11: buffer-then-check on the summary.
	if encoded, err := json.Marshal(summary); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": "unrenderable total: " + err.Error()})
	} else {
		w.WriteHeader(http.StatusOK)
		w.Write(encoded)
	}"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M11-fix-empty-summary 'TestAnOverflowingScanLeavesEverySubsequentSummaryEmpty_DEFECT' \
  "INVERTED: fixing the empty summary must break its characterisation"
restore_all

# ── M12: the summary reads the shared cross-tenant slot ───────────────────────
# Stop handleSummary reading ch.lastResults. The cross-tenant leak test must go
# red: if it survives, it is not actually demonstrating that the slot is shared.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	results := ch.lastResults
	ungated := ch.lastUngated"""
assert old in s, "M12 anchor absent"
new="""	var results []ComplianceScanResult // MUTANT M12: shared slot not read
	ungated := ch.lastUngated"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M12-summary-shared-slot 'TestTheSummaryReturnsTheLastScannersFiguresToAnyCaller_DEFECT' \
  "the leak test must depend on handleSummary reading the shared slot"
restore_all

# ── M13: per-scan profile isolation ───────────────────────────────────────────
# Cache the resolved profile on the handler, so one tenant's declaration leaks
# into the next tenant's scan. The isolation test must catch it.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	p := effectiveRiskProfile{Currency: defaultReportingCurrency, RiskLoad: fair.DefaultRiskLoad}"""
assert old in s, "M13 anchor absent"
new="""	p := effectiveRiskProfile{Currency: defaultReportingCurrency, RiskLoad: fair.DefaultRiskLoad}
	if mutantLastProfile.Declared { // MUTANT M13: leak the previous declaration
		p = mutantLastProfile
	}
	defer func() { mutantLastProfile = p }()"""
s=s.replace(old,new,1)
s=s.replace("const defaultReportingCurrency money.Currency = \"GBP\"",
            "const defaultReportingCurrency money.Currency = \"GBP\"\n\nvar mutantLastProfile effectiveRiskProfile // MUTANT M13",1)
open(p,"w").write(s)
'
expect_red M13-profile-not-cached 'TestOneTenantsDeclaredProfileNeverMovesAnotherTenantsRows' \
  "a cached profile must not leak one tenant's declaration into another's scan"
restore_all

# ── M14: money refuses to add across denominations ───────────────────────────
apply "$PE/money/money.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	if a.Currency != b.Currency {"""
assert old in s, "M14 anchor absent"
open(p,"w").write(s.replace(old,"	if false { // MUTANT M14: denomination check disabled",1))
'
expect_red M14-add-mixes-denominations 'TestMoneyStillRefusesToMixDenominationsEverywhereItIsUsed' \
  "money.Add must refuse two different denominations"
restore_all

# ── M15 (INVERTED): give the bundle response a denomination as data ──────────
# The bundle roll-up is denominated only by its json tag. Adding a real currency
# field is the fix; the characterisation test must then go red.
apply "$PE/types.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="	TotalExposure float64                `json:\"total_exposure_gbp\"`"
assert old in s, "M15 anchor absent"
new=old+"\n	Currency      string                 `json:\"currency\"` // MUTANT M15"
open(p,"w").write(s.replace(old,new,1))
'
expect_red M15-fix-bundle-denomination 'TestTheBundleRollUpIgnoresTheDeclaredProfileAndIsDenominatedByItsFieldName_DEFECT' \
  "INVERTED: carrying the denomination as data must break the characterisation"
restore_all

# ── M16 (INVERTED): reject a currency absent from the rate table ─────────────
# An allow-list is the natural fix for ZZZ/XXX/AAA. The test that measures the
# gap must go red once the gap is closed.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""		p.Currency = declared
		p.Declared = true"""
assert old in s, "M16 anchor absent"
new="""		// MUTANT M16: allow-list drawn from risk/fx/rates.yaml
		switch declared {
		case "USD", "GBP", "EUR", "CHF", "JPY", "CAD", "AUD", "SEK", "NOK",
			"DKK", "SGD", "HKD", "INR", "ZAR", "AED":
		default:
			return effectiveRiskProfile{}, fmt.Errorf("reportingCurrency: no rate for %s", declared)
		}
		p.Currency = declared
		p.Declared = true"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M16-fix-unconvertible-currency 'TestAValidShapeIsNotAValidCurrency' \
  "INVERTED: an FX allow-list must break the unconvertible-label measurement"
restore_all

# ── M17 (INVERTED): make a declared zero expressible in signal-ingest ────────
# Drop the `== 0` proxy for RiskLoad. The characterisation of the second
# engine's defect must go red, and so must the two-engine divergence test.
apply "$SI/pkg/fair/engine.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	if in.RiskLoad == 0 {
		in.RiskLoad = DefaultRiskLoad
	}"""
assert old in s, "M17 anchor absent"
open(p,"w").write(s.replace(old,"	// MUTANT M17: a declared zero is preserved",1))
'
expect_red_in "$SI" M17-fix-unexpressible-zero \
  'TestADeclaredZeroRiskLoadIsUnexpressible_DEFECT|TestTheTwoEnginesDisagreeAboutWhatAZeroLoadMeans_DEFECT' \
  "INVERTED: preserving a declared zero must break both characterisations" \
  './pkg/fair/'
restore_all

# ── M18: the seed proxy in signal-ingest ─────────────────────────────────────
apply "$SI/pkg/fair/engine.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	if in.Seed == 0 {
		in.Seed = DefaultSeed
	}"""
assert old in s, "M18 anchor absent"
open(p,"w").write(s.replace(old,"	// MUTANT M18: a declared zero seed is preserved",1))
'
expect_red_in "$SI" M18-fix-unexpressible-seed \
  'TestADeclaredSeedOfZeroIsUnexpressible_DEFECT' \
  "INVERTED: preserving a declared zero seed must break its characterisation" \
  './pkg/fair/'
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
