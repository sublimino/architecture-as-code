package main

import (
	"encoding/json"
	"testing"
)

// THE CRA BOUNDARY, both sides. This is the test the whole card exists for.
//
// The CRA pack prices GBP 256,514.43 of ALE across its three checks (the sum of
// the ale column of testdata/money-golden/cra@v1.0.0.json; the carried column
// sums to GBP 781,506.09, which is what actually reaches exposure). Every one of
// those checks evidences an Annex I essential requirement, and Article 71(2) of
// Regulation (EU) 2024/2847 says those do not apply until 11 December 2027.
// Pricing a breach of them before that date is wrong BY STATUTE, not by
// opinion: there is no obligation to breach, so there is nothing to price.
//
// Two as-of dates either side of the boundary, ONE DAY APART, the same request
// otherwise. Before: every check not_in_force, zero exposure. On the day: every
// check evaluated and the exposure is real. The one-day step is deliberate --
// a wider gap would also pass with an off-by-a-year comparison, and the day a
// regulation starts applying is the day everybody will check.
func TestScan_CRAEssentialRequirementsBoundary(t *testing.T) {
	const boundary = "2027-12-11"
	tr := newScanTransport(t)

	// A workload that breaches all three checks: no security_profile, no sbom,
	// no provenance. Undated, this is the full-exposure CRA scan.
	breaching := func(asOf string) ([]ComplianceScanResult, ComplianceSummary) {
		t.Helper()
		body := map[string]any{
			"frameworks":    []string{"cra"},
			"policyVersion": "v1.0.0",
			"agent":         map[string]any{"name": "breaching-agent"},
		}
		if asOf != "" {
			body["assessmentDate"] = asOf
		}
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		rows, err := tr.scan(raw)
		if err != nil {
			t.Fatalf("scan at %q: %v", asOf, err)
		}
		s, err := tr.summary()
		if err != nil {
			t.Fatal(err)
		}
		return rows, s
	}

	// SIDE 1: the day before. Nothing applies, so nothing can be breached.
	rowsBefore, before := breaching("2027-12-10")
	if len(rowsBefore) != 3 {
		t.Fatalf("got %d CRA rows, want 3", len(rowsBefore))
	}
	for _, r := range rowsBefore {
		if r.Status != VerdictNotInForce {
			t.Errorf("as-of 2027-12-10: check %q status %q, want not_in_force", r.Check, r.Status)
		}
		if r.Passed {
			t.Errorf("as-of 2027-12-10: check %q reports passed=true; a regime that has not started cannot be complied with either", r.Check)
		}
		if r.Applicability == nil || !r.Applicability.Gated || r.Applicability.InForceFrom != boundary {
			t.Errorf("as-of 2027-12-10: check %q applicability %+v, want gated with inForceFrom %s", r.Check, r.Applicability, boundary)
		}
		// The ROW keeps its priced figure. The money is input-independent, and
		// blanking it would be a different dishonesty -- it is the SUMMARY that
		// declines to add it up.
		if r.ALE <= 0 {
			t.Errorf("as-of 2027-12-10: check %q lost its row-level figure", r.Check)
		}
	}
	if before.TotalExposure != 0 {
		t.Errorf("as-of 2027-12-10: totalExposureGbp = %.2f, want 0.00 -- the CRA essential requirements do not apply until %s", before.TotalExposure, boundary)
	}
	if before.NotInForce != 3 || before.Failed != 0 || before.Errored != 0 || before.Passed != 0 {
		t.Errorf("as-of 2027-12-10: notInForce/failed/errored/passed = %d/%d/%d/%d, want 3/0/0/0",
			before.NotInForce, before.Failed, before.Errored, before.Passed)
	}
	if before.TotalControls != 3 {
		t.Errorf("as-of 2027-12-10: totalControls = %d, want 3: coverage must not shrink with the as-of date", before.TotalControls)
	}
	if !before.ApplicabilityGated || before.AssessmentDate != "2027-12-10" {
		t.Errorf("as-of 2027-12-10: summary gated=%v assessmentDate=%q", before.ApplicabilityGated, before.AssessmentDate)
	}
	if len(before.UngatedFrameworks) != 0 {
		t.Errorf("as-of 2027-12-10: ungatedFrameworks = %v, want none: the window WAS applied", before.UngatedFrameworks)
	}

	// SIDE 2: the day itself. Article 71(2) says "from 11 December 2027", so the
	// 11th is inside the obligation, not outside it.
	rowsOn, on := breaching(boundary)
	if len(rowsOn) != 3 {
		t.Fatalf("got %d CRA rows on the boundary, want 3", len(rowsOn))
	}
	for _, r := range rowsOn {
		if r.Status != VerdictFail {
			t.Errorf("as-of %s: check %q status %q, want fail -- the workload breaches all three and the obligation applies ON that date",
				boundary, r.Check, r.Status)
		}
		if r.Applicability == nil || r.Applicability.Gated || r.Applicability.Status != "in_force" {
			t.Errorf("as-of %s: check %q applicability %+v, want in_force and not gated", boundary, r.Check, r.Applicability)
		}
	}
	if on.NotInForce != 0 || on.Failed != 3 {
		t.Errorf("as-of %s: notInForce/failed = %d/%d, want 0/3", boundary, on.NotInForce, on.Failed)
	}
	if on.TotalExposure <= 0 {
		t.Fatalf("as-of %s: totalExposureGbp = %.2f, want the real figure", boundary, on.TotalExposure)
	}

	// And the two sides must actually DIFFER, which is the one assertion a gate
	// that never fires cannot satisfy.
	if before.TotalExposure == on.TotalExposure {
		t.Errorf("exposure is identical either side of %s (%.2f): the gate did nothing", boundary, on.TotalExposure)
	}

	// The undated scan is unchanged by all of this: it still prices the whole
	// pack, which is the documented default and the reason this is not a
	// breaking change -- while the summary names the CRA as a regime whose
	// verified window went unapplied, so the silence is visible.
	_, undated := breaching("")
	if undated.TotalExposure != on.TotalExposure {
		t.Errorf("undated exposure %.2f differs from the in-force figure %.2f: the default must behave as it did before windows existed",
			undated.TotalExposure, on.TotalExposure)
	}
	if undated.ApplicabilityGated {
		t.Error("undated scan claims applicabilityGated")
	}
	if len(undated.UngatedFrameworks) != 1 || undated.UngatedFrameworks[0] != "cra" {
		t.Errorf("undated ungatedFrameworks = %v, want [cra]", undated.UngatedFrameworks)
	}
}

// The gate must move EXPOSURE, not just a status token. Pinned separately and
// against the golden's own arithmetic, because a gate that produced the right
// verdicts while leaving the money untouched would be the exact defect this
// card was opened to fix, and every assertion above would still pass if
// handleSummary counted not_in_force into TotalExposure.
func TestScan_CRAGatedExposureIsExactlyZeroNotMerelySmaller(t *testing.T) {
	tr := newScanTransport(t)
	raw, err := json.Marshal(map[string]any{
		"frameworks": []string{"cra"}, "policyVersion": "v1.0.0",
		"assessmentDate": "2026-10-11",
		"agent":          map[string]any{"name": "breaching-agent"},
	})
	if err != nil {
		t.Fatal(err)
	}
	rows, err := tr.scan(raw)
	if err != nil {
		t.Fatal(err)
	}
	var rowSum float64
	for _, r := range rows {
		rowSum += r.CarriedGBP
	}
	if rowSum <= 0 {
		t.Fatalf("the rows carry %.2f: the figures were blanked rather than excluded", rowSum)
	}
	s, err := tr.summary()
	if err != nil {
		t.Fatal(err)
	}
	if s.TotalExposure != 0 {
		t.Errorf("exposure %.2f with %.2f sitting on the rows: not_in_force must be excluded from the sum, not scaled down", s.TotalExposure, rowSum)
	}
	if s.Exposure.Amount != 0 || s.Exposure.Currency != reportingCurrency {
		t.Errorf("denominated exposure %v, want 0 %s", s.Exposure, reportingCurrency)
	}
}
