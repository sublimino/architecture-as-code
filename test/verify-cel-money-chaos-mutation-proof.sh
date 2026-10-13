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
# SOME MUTANTS DELIBERATELY INVERT THE DIRECTION OF PROOF. M8, M15, M17 and M18
# do not break the code — they FIX a defect the suites still characterise. The
# test that pins the defect must then go red, because a characterisation test
# whose subject has been fixed and which still passes is pinning nothing. This is
# the only way to prove a `_DEFECT` test is a tripwire rather than a tautology.
#
# M3, M11, M12 AND M16 USED TO BE INVERTED AND ARE NOW ORDINARY FORWARD MUTANTS,
# because the three defects they described have been fixed for real (F4): the
# empty-200 on an unrenderable figure, the unkeyed cross-tenant summary slot, and
# a declared currency with no rate in the table. A mutant that applies a fix and
# a mutant that removes one are the same instrument pointed in opposite
# directions; which direction is correct depends only on whether the fix is in
# the tree, so these flipped when it landed.
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
declare -a BLIND=()

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
  if [ "$rc" -eq 0 ] && grep -q 'no tests to run' <<<"$out"; then
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

# expect_green_in <module-dir> <mutant-name> <test-regex> <why> <package-pattern>
#
# The NEGATIVE CONTROL. Requires the named tests to PASS while the mutant is in
# place, i.e. to be blind to it.
#
# This is not a weaker expect_red. It asserts a different and equally falsifiable
# claim: that a named verification tier cannot detect a specific regression. That
# is the only honest way to measure the size of a gap -- "three of the four
# quoted figures rest on the golden alone" is a claim about what the OTHER tiers
# fail to see, and a suite that can only demand red cannot state it.
#
# A missing test is still MISSING here, for the same reason as above: a regex
# that matches nothing passes vacuously and would read as "blind as expected"
# when the truth is "nothing ran".
expect_green_in() {
  local dir="$1" name="$2" regex="$3" why="$4" pkg="${5:-./}"
  local out rc
  set +e
  out="$(cd "$dir" && go test -count=1 -run "$regex" "$pkg" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q 'no tests to run' <<<"$out"; then
    MISSING+=("$name :: $regex")
    printf '  MISSING  %-28s %s\n' "$name" "no test matches /$regex/"
    return
  fi
  if [ "$rc" -eq 0 ]; then
    BLIND+=("$name")
    printf '  BLIND    %-28s %s\n' "$name" "$why"
  else
    # The tier DID catch it. That is good news for the product and means this
    # script's description of the gap is out of date.
    SURVIVORS+=("$name (expected blind, but it CAUGHT the mutant) :: $regex")
    printf '  CAUGHT   %-28s %s\n' "$name" "unexpectedly detected -- the gap is SMALLER than documented"
    echo "$out" | tail -4 | sed 's/^/           /'
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

# ── M3: the application-time refusal of an unapplicable load ──────────────────
# WAS INVERTED (it used to APPLY the buffer-then-check fix and require the
# characterisation test to go red). The fix is real now, so this is an ordinary
# forward mutant: delete the guard and the test that pins the refusal must fail.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
i=s.index("			if bad := nonFiniteFigure(risk); bad != \"\" {")
j=s.index("				return\n			}",i)+len("				return\n			}")
open(p,"w").write(s[:i]+"			// MUTANT M3: application-time overflow refusal deleted"+s[j:])
'
expect_red M3-overflow-refused 'TestAnOverflowingRiskLoadIsRefusedAndNeverServedAsAnEmptySuccess' \
  "a load whose application overflows must be refused where it is applied"
restore_all

# ── M3b: the same guard, proved from the summary's blast radius ───────────────
# Without the refusal an unrenderable figure is STORED in ch.lastResults, so
# every subsequent summary -- for every caller -- is affected. That is a wider
# claim than M3 makes and it needs its own mutant.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
i=s.index("			if bad := nonFiniteFigure(risk); bad != \"\" {")
j=s.index("				return\n			}",i)+len("				return\n			}")
open(p,"w").write(s[:i]+"			// MUTANT M3b: refusal deleted; the +Inf reaches the stored slot"+s[j:])
'
expect_red M3b-summary-blast-radius 'TestAnOverflowingScanLeavesEverySubsequentSummaryIntact' \
  "an unrenderable figure must never reach the slot every caller's summary reads"
restore_all

# ── M4: the currency shape check, which is now a DIAGNOSIS and not a gate ────
#
# THIS MUTANT SURVIVED WHEN THE ALLOW-LIST LANDED, and the reason is worth
# recording because the fix was to the TEST'S CLAIM, not to the test's strength.
#
# Fix 3 added a rate-table allow-list that rejects by exact set membership. A
# malformed code is not a member, so it is refused whether or not Validate runs:
# the allow-list SUBSUMES the shape check as a gate at this call site, and
# `code == 400` stopped depending on Validate at all. The old assertion was
# pinning the allow-list while claiming to pin the shape check.
#
# It was NOT resurrected by inventing an assertion. The shape check still makes
# exactly one contribution here -- it distinguishes "usd" (a typo; fix the
# caller) from "KWD" (a real currency with no rate; add it to rates.yaml), which
# are opposite operator actions -- and that is what the test now pins. Nor is
# deleting Validate an option: it has eleven other callers in the money package
# where it IS the only guard, and migration 062's DB CHECK is deliberately
# `^[A-Z]{3}$` with the semantic set enforced one layer up, so the two checks
# guard different things and only their outcomes coincide at this one site.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""		if err := declared.Validate(); err != nil {
			return effectiveRiskProfile{}, fmt.Errorf("reportingCurrency: %w", err)
		}"""
assert old in s, "M4 anchor absent"
open(p,"w").write(s.replace(old,"		// MUTANT M4: currency validation deleted",1))
'
expect_red M4-currency-shape-diagnosis 'TestMalformedReportingCurrenciesAreRefused' \
  "a malformed code must be DIAGNOSED as malformed, not reported as rate-less"
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

# ── M9: invert the tailDominated DEFINITION ───────────────────────────────────
#
# WHY THIS IS NOT THE MUTANT IT OUGHT TO BE, stated here because an honest
# mutation proof has to admit what it cannot test.
#
# The mutant this slot WANTED was a re-introduction of the clamp
# `if var95 < ale { var95 = ale }` -- the exact fabrication fair.go's header
# records as removed for reporting "a bad year equal to the average year". That
# mutant is UNKILLABLE, and not because the tests are weak.
#
# SimulateWithLoad computes annualLosses[i] = f * l from two continuous beta-PERT
# draws. A PERT variate has no mass at zero, so the product is never
# zero-inflated and var95 > ale always -- measured across five deliberately
# extreme skews (freq modes to 1e-6, loss maxima to 1e9), every one giving
# var95/ale ~3.7. The clamp's condition is therefore never true, so inserting it
# changes no figure and no test can observe it. CONFORMANCE.md:166 already
# records this as "a reachability sweep ... pinned at zero".
#
# The protection against that fabrication is that the clamp is ABSENT, not that
# anything would catch it coming back. That is a real limitation of the test
# estate and it is reported rather than papered over.
#
# So this slot mutates what IS observable: the flag's definition. TailDominated
# is specified as exactly `var95 < ale`, and the gap suite asserts that
# definition in both directions over five distributions.
apply "$PE/fair/fair.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="		TailDominated: var95 < ale,"
assert old in s, "M9 anchor absent"
open(p,"w").write(s.replace(old,"		TailDominated: var95 > ale, // MUTANT M9: definition inverted",1))
'
expect_red_in "$PE" M9-taildominated-definition \
  'TestTheTailDominatedFlagIsTheOnlySignalOfAnInvertedPercentile' \
  "tailDominated must be exactly var95 < ale" './fair/'
restore_all

# ── M9b: the tail-index convention in RunDistribution ────────────────────────
# Move the portfolio path's tail index by one rank. The divergence test measures
# the two conventions' distance, so changing one must move the measurement.
apply "$PE/fair/fair.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="	idx := int(math.Floor(0.95 * float64(iters)))"
assert old in s, "M9b anchor absent"
open(p,"w").write(s.replace(old,"	idx := int(math.Floor(0.95*float64(iters))) - 1 // MUTANT M9b",1))
'
expect_red_in "$PE" M9b-rundistribution-index \
  'TestAnOffByOnePercentileIndexMovesEveryTailFigure|TestTheTwoTailIndexConventionsInThisFileDisagreeByOneRank' \
  "the measured gap must depend on the actual tail index" './fair/'
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
# M10 is the brief's named example and it is handled differently from every
# other mutant here, because the POINT of it is which tier reacts.
#
# The mutant moves SimulateWithLoad's tail index by one rank -- the per-check
# scan path. Three assertions are made about the SAME mutant:
#
#   M10a  the money GOLDEN must go red          (the only tier that catches it)
#   M10b  the ordering identities must stay GREEN (they cannot see it)
#   M10c  the closed-form ALE oracle must stay GREEN (ale does not move)
#
# M10b and M10c are NEGATIVE controls and are the actual deliverable for item 6
# of the brief: "show precisely which tier catches it and which does not". A
# mutation proof that only ever demands red cannot express "this tier is blind
# here", and that blindness is the measurement.
expect_red_in "$PE" M10a-golden-catches-off-by-one \
  'TestConformance_MoneyGoldenMatchesEngine' \
  "the deterministic golden is the ONLY tier that catches a one-rank error" './'
expect_green_in "$PE" M10b-ordering-is-blind \
  'TestConformance_MoneyFigureOrdering' \
  "NEGATIVE CONTROL: ordering identities cannot see a one-rank error" './'
expect_green_in "$PE" M10c-ale-oracle-is-blind \
  'TestConformance_MoneyAnalyticAnchor' \
  "NEGATIVE CONTROL: the closed-form ale anchor cannot see a one-rank error" './'
restore_all

# ── M11: buffer-then-check before committing a status line ───────────────────
# WAS INVERTED. Now a forward mutant on the real guard: make writeJSONChecked
# commit the status BEFORE it knows the document can be produced -- which is
# verbatim the `WriteHeader` then discarded-`Encode` shape the defect had. Every
# StatusOK site in compliance.go routes through this helper, so one mutant
# covers all four.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""func writeJSONChecked(w http.ResponseWriter, status int, v any) {
	encoded, err := json.Marshal(v)"""
assert old in s, "M11 anchor absent"
new="""func writeJSONChecked(w http.ResponseWriter, status int, v any) {
	// MUTANT M11: status committed first, encode error discarded.
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
	if true {
		return
	}
	encoded, err := json.Marshal(v)"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M11-buffer-then-check 'TestWriteJSONCheckedNeverCommitsASuccessItCannotRender' \
  "a status line must never be committed before the document is known to marshal"
restore_all

# ── M12: the summary is scoped to the CALLING tenant ─────────────────────────
# WAS INVERTED (it used to stop handleSummary reading the shared slot, so that
# the leak characterisation had to go red). The slot is keyed by tenant now, so
# this is an ordinary forward mutant: make the lookup ignore the key and return
# the most recent scan instead -- verbatim the old defect -- and the test that
# pins the scoping must fail.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	s, ok := ch.scans[tenantID]
	return s, ok"""
assert old in s, "M12 anchor absent"
new="""	// MUTANT M12: tenant key ignored; the most recent scan is served to anyone.
	_ = tenantID
	var newest tenantScan
	var found bool
	for _, v := range ch.scans {
		if !found || v.seq > newest.seq {
			newest, found = v, true
		}
	}
	return newest, found"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M12-summary-tenant-scoped 'TestTheSummaryIsScopedToTheCallingTenant' \
  "a tenant must read back its OWN scan, never the most recent one"
restore_all

# ── M12b: a tenant with no scan gets a refusal, not a zeroed summary ─────────
# The other half of the same fix, and a different claim: the ABSENCE of a scan
# must not be expressible as a document full of zeroes, because zero exposure is
# a real and meaningful answer on this product and the two must not be
# confusable. Serve an empty summary instead of the 404.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
i=s.index("	scan, ok := ch.scanFor(tenantID)")
j=s.index("		return\n	}",i)+len("		return\n	}")
new="""	scan, _ := ch.scanFor(tenantID) // MUTANT M12b: no scan is a zeroed 200"""
open(p,"w").write(s[:i]+new+s[j:])
'
expect_red M12b-no-scan-is-not-zeroes 'TestComplianceSummary_NoScan|TestSummaryBeforeScan_Is404AndNotAZeroedSummary' \
  "an absent scan must not be served as a zeroed summary a client reads as clean"
restore_all

# ── M12c: the scan store is bounded ──────────────────────────────────────────
# Keying by tenant made the store grow on a caller-supplied string. Remove the
# eviction and the bound test must fail -- otherwise "it is bounded" is a claim
# in a comment rather than a property of the code.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
i=s.index("	if _, replacing := ch.scans[tenantID]; !replacing && len(ch.scans) >= maxRememberedTenants {")
j=s.index("			\"evicted_tenant\", oldestKey, \"cap\", maxRememberedTenants)\n	}",i)
j=s.index("\n	}",j)+len("\n	}")
open(p,"w").write(s[:i]+"	// MUTANT M12c: eviction removed; the store grows without bound"+s[j:])
'
expect_red M12c-store-is-bounded 'TestTheScanStoreIsBoundedAndEvictsTheOldest' \
  "the per-tenant store must be bounded; its key comes straight off the request"
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

# ── M16: a declared currency with no rate is refused ─────────────────────────
# WAS INVERTED (it used to ADD the allow-list so the "unconvertible label is
# accepted" measurement had to go red). The allow-list is real now, so this is
# an ordinary forward mutant: delete it and the refusal test must fail.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
i=s.index("		if !reportableCurrencies[declared] {")
j=s.index("		}",s.index("reportableCurrencyList()",i))+len("		}")
open(p,"w").write(s[:i]+"		// MUTANT M16: rate-table allow-list deleted"+s[j:])
'
expect_red M16-currency-has-a-rate 'TestAShapeValidCurrencyWithNoRateIsRefused' \
  "a declared currency with no rate in risk/fx/rates.yaml must be refused, not labelled on"
restore_all

# ── M16b: the allow-list IS the checked-in table ─────────────────────────────
# The allow-list is a literal in Go, deliberately (an offline request validator
# must not depend on a file path). The cost of that choice is that two things
# have to agree, and an agreement nobody checks is one that drifts -- so drop a
# currency that IS in the table and the drift test must fail. Without this
# mutant "drawn from risk/fx/rates.yaml" is a claim in a comment.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
old="""	"SGD": true, "HKD": true, "INR": true, "ZAR": true, "AED": true,"""
assert old in s, "M16b anchor absent"
new="""	"SGD": true, "HKD": true, "INR": true, "ZAR": true, // MUTANT M16b: AED dropped"""
open(p,"w").write(s.replace(old,new,1))
'
expect_red M16b-allowlist-matches-table 'TestTheReportableCurrencyAllowListIsExactlyTheCheckedInRateTable' \
  "the allow-list must be exactly the rate table's key set, checked in both directions"
restore_all

# ── M16c: the refusal names the table it was refused by ──────────────────────
# A refusal an operator cannot act on is barely better than a silent relabel.
# Strip the detail from the message and the test must notice.
apply "$PE/compliance.go" '
import os
p=os.environ["MUT_FILE"]; s=open(p).read()
i=s.index("			return effectiveRiskProfile{}, fmt.Errorf(\n				\"reportingCurrency %s has no rate")
j=s.index("strings.Join(reportableCurrencyList(), \", \"))",i)+len("strings.Join(reportableCurrencyList(), \", \"))")
new="""			return effectiveRiskProfile{}, fmt.Errorf("reportingCurrency: unsupported") // MUTANT M16c"""
open(p,"w").write(s[:i]+new+s[j:])
'
expect_red M16c-refusal-is-actionable 'TestAShapeValidCurrencyWithNoRateIsRefused' \
  "the refusal must name the currency, the rate table and its as-of date"
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
echo "killed: ${#KILLED[@]}   blind-as-expected: ${#BLIND[@]}   survived: ${#SURVIVORS[@]}   missing: ${#MISSING[@]}"

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

echo "all ${#KILLED[@]} mutants killed; ${#BLIND[@]} negative controls confirmed blind"
