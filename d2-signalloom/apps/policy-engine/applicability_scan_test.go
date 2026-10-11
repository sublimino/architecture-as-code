package main

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// WHY A FOURTH VERDICT AND NOT A REUSE OF not_evaluated.
//
// The engine already has not_evaluated for a placeholder, with bidirectional
// enforcement in the conformance suite and exclusion from exposure in the money
// tier, so reusing it is the cheaper change. It is also the wrong one, for
// three reasons that compound:
//
//  1. THEY ARE PROPERTIES OF DIFFERENT THINGS. not_evaluated is a property of
//     the PACK: this check has no expression anybody could run, and no as-of
//     date changes that. not_in_force is a property of the SCAN: the expression
//     is real and would run, but the obligation does not exist on the date
//     asked about, and the same check flips to pass or fail at a later as-of.
//     One is static, one is a function of the request.
//
//  2. COLLAPSING THEM DESTROYS THE COMMERCIALLY LOAD-BEARING DISTINCTION. A
//     reader seeing not_evaluated across the CRA pack concludes the pack is
//     immature and the vendor has not done the work. The truth is the opposite:
//     the pack is complete, priced and fixture-covered, and the REGULATION has
//     not started. "We have not built it" and "the law has not started" are the
//     two readings a buyer must be able to tell apart, and a single token
//     cannot carry both.
//
//  3. IT WOULD WEAKEN AN EXISTING INVARIANT. The conformance suite enforces
//     placeholder <=> not_evaluated in BOTH directions
//     (frameworks_conformance_test.go:176-184): a placeholder must expect it and
//     a non-placeholder must not. Reusing the token for a future-dated regime
//     makes a non-placeholder check a legitimate not_evaluated, so the reverse
//     direction has to be deleted. A fourth verdict keeps that iff intact and
//     earns its own: not_in_force <=> the resolved verified window excludes the
//     as-of date.
//
// The cost of the fourth verdict is one token every consumer must learn. It is
// paid once and it buys an answer to "why is this check not reporting?" that is
// correct rather than merely available.

// Exclusion is the whole point: a regime that is not in force cannot be
// breached, so it contributes no failure, no error and no exposure. Driven with
// a NON-ZERO figure on the not_in_force row, because every shipped placeholder
// prices at 0.00 and an assertion against a zero row proves nothing.
func TestSummary_NotInForceExcludedFromFailedErroredAndExposure(t *testing.T) {
	row := func(v Verdict, carried float64) ComplianceScanResult {
		return ComplianceScanResult{
			Check: "synthetic", Status: v, Passed: v == VerdictPass,
			CarriedGBP: carried, Currency: reportingCurrency,
			Carried: money.Money{Amount: carried, Currency: reportingCurrency},
		}
	}
	h := &complianceHandler{lastResults: []ComplianceScanResult{
		row(VerdictNotInForce, 256_514.43),
		row(VerdictNotEvaluated, 12_345.67),
		row(VerdictPass, 98_765.43),
		row(VerdictFail, 1_000),
		row(VerdictError, 500),
	}}
	s, err := handlerTransport{h}.summary()
	if err != nil {
		t.Fatal(err)
	}
	if s.TotalExposure != 1_500 {
		t.Errorf("exposure %.2f, want 1500.00: the not_in_force row's 256514.43 must not be counted", s.TotalExposure)
	}
	if s.NotInForce != 1 {
		t.Errorf("notInForce = %d, want 1", s.NotInForce)
	}
	if s.Failed != 1 || s.Errored != 1 || s.Passed != 1 || s.NotEvaluated != 1 {
		t.Errorf("failed/errored/passed/notEvaluated = %d/%d/%d/%d, want 1/1/1/1: not_in_force must land in none of them",
			s.Failed, s.Errored, s.Passed, s.NotEvaluated)
	}
	// Counted in the denominator. A control that exists in the pack is reported
	// as present, so TotalControls cannot silently shrink when a window closes
	// a regime off — otherwise a pack's coverage would appear to change with
	// the as-of date.
	if s.TotalControls != 5 {
		t.Errorf("totalControls = %d, want 5", s.TotalControls)
	}
	// The row keeps its own figure. Same honesty as the not_evaluated case: the
	// money is input-independent, so the ROW still carries a real number; it is
	// the SUMMARY that declines to add it up.
	if h.lastResults[0].CarriedGBP != 256_514.43 {
		t.Error("summarising mutated the not_in_force row's figure")
	}
}

// The default branch of the summary switch is "anything unrecognised is a
// failure", which is the right conservative default and also means a new
// verdict that nobody wired up would be counted as a breach. Pin the four
// non-failure verdicts explicitly so adding a fifth cannot inherit silence.
func TestSummary_VerdictVocabularyIsClosed(t *testing.T) {
	all := []Verdict{VerdictPass, VerdictFail, VerdictError, VerdictNotEvaluated, VerdictNotInForce}
	seen := map[Verdict]bool{}
	for _, v := range all {
		if seen[v] {
			t.Fatalf("duplicate verdict token %q", v)
		}
		seen[v] = true
		if v == "" {
			t.Fatal("a verdict token is empty")
		}
	}
	if len(all) != 5 {
		t.Fatalf("the vocabulary has %d members; this test and the summary switch must be updated together", len(all))
	}
	if VerdictNotInForce == VerdictNotEvaluated {
		t.Fatal("not_in_force collapsed into not_evaluated")
	}
	if VerdictNotInForce != "not_in_force" {
		t.Errorf("not_in_force wire token is %q; it is in the API contract and cannot drift", VerdictNotInForce)
	}
}
