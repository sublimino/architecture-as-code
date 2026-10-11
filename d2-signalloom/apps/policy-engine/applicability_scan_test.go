package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// scanAt POSTs a scan for one framework at one as-of date. An empty asOf omits
// the field entirely rather than sending "", so the default path is exercised
// the way a client that predates this feature exercises it.
func scanAt(t *testing.T, tr handlerTransport, fwID, policyVersion, asOf string) []ComplianceScanResult {
	t.Helper()
	body := map[string]any{"frameworks": []string{fwID}, "policyVersion": policyVersion}
	if asOf != "" {
		body["assessmentDate"] = asOf
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	out, err := tr.scan(raw)
	if err != nil {
		t.Fatalf("scan %s at %q: %v", fwID, asOf, err)
	}
	return out
}

func newScanTransport(t *testing.T) handlerTransport {
	t.Helper()
	h, err := newComplianceHandler(conformancePolicyRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	return handlerTransport{h}
}

// syntheticWindowHandler builds a one-check pack in a temp policy root with the
// given applicability fragment and framework status. Synthetic rather than a
// shipped pack so the gate's behaviour is pinned independently of whatever
// dates the shipped packs happen to declare -- these properties must hold after
// the CRA's dates are corrected, or a regime is added, or one is retired.
func syntheticWindowHandler(t *testing.T, applicabilityFragment, frameworkStatus string) *complianceHandler {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "frameworks", "synthetic", "v1.0")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	status := ""
	if frameworkStatus != "" {
		status = `"status":"` + frameworkStatus + `",`
	}
	pack := `{"id":"synthetic","name":"S","version":"v1.0.0",` + status + applicabilityFragment + `
      "controlSets":[{"id":"cs","name":"CS","controls":[{"id":"c1","name":"C1","checks":[
        {"id":"always-true","name":"t","celExpression":"true","riskTriple":{"min":1,"mode":2,"max":3},"freqTriple":{"min":0.1,"mode":0.2,"max":0.3},"policyVersions":["v1.0.0"]}]}]}]}`
	if err := os.WriteFile(filepath.Join(dir, "framework.json"), []byte(pack), 0o644); err != nil {
		t.Fatal(err)
	}
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// A malformed as-of date is a 400, never a silent fallback to today and never a
// silently ungated scan. The caller asserted a date; if the engine cannot read
// it, the only honest answer is to refuse.
func TestScan_RejectsMalformedAssessmentDate(t *testing.T) {
	tr := newScanTransport(t)
	for _, bad := range []string{"today", "2027-13-01", "11 Dec 2027", "2027-12-11T00:00:00Z", "2027-12"} {
		raw, err := json.Marshal(map[string]any{"frameworks": []string{"cra"}, "assessmentDate": bad})
		if err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		tr.h.handleScan(w, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw)))
		if w.Code != http.StatusBadRequest {
			t.Errorf("assessmentDate %q: HTTP %d, want 400 (body %s)", bad, w.Code, w.Body.String())
			continue
		}
		if !bytes.Contains(w.Body.Bytes(), []byte("invalid_assessment_date")) {
			t.Errorf("assessmentDate %q: 400 body does not name the error: %s", bad, w.Body.String())
		}
	}
}

// THE DEFAULT, pinned. An absent assessmentDate leaves every check evaluating
// exactly as it did before this feature existed -- and says so on the summary
// rather than leaving a reader to assume the dates were checked.
//
// Three alternatives were available and all three are worse:
//
//   - SUBSTITUTE TODAY. The same request would replay differently next year,
//     which is the exact failure mode ADR-0006 and the FAIR seed exist to
//     prevent. The engine must never read the clock.
//   - FAIL LOUDLY ON EVERY REQUEST. A breaking API change on a path owned by
//     callers outside this card (pkg/compliance/fleet_scan.go, fe-signalloom,
//     the dashboard, every one of the conformance fixtures).
//   - A PACK-LEVEL DEFAULT DATE. A date the engine supplies is the same
//     fabrication as now(), just staler and harder to spot.
//
// So: an absent assessmentDate means the caller has not asserted an as-of date,
// and a gate that cannot be dated does not fire.
func TestScan_NoAssessmentDateLeavesEveryCheckEvaluatedAndSaysSo(t *testing.T) {
	// A synthetic pack with a VERIFIED future window, so the gate would
	// certainly have fired had a date been supplied. Synthetic rather than a
	// shipped pack so this property holds whatever the shipped dates become.
	tr := handlerTransport{syntheticWindowHandler(t, `"applicability":{"inForceFrom":"2099-01-01","basis":"enforcement-date","source":"s","verified":true},`, "")}
	rows := scanAt(t, tr, "synthetic", "v1.0.0", "")
	if len(rows) == 0 {
		t.Fatal("no rows")
	}
	for _, r := range rows {
		if r.Status == VerdictNotInForce {
			t.Errorf("check %q reported not_in_force with no assessmentDate: the gate fired on a date nobody supplied", r.Check)
		}
		if r.AssessmentDate != "" {
			t.Errorf("check %q echoed assessmentDate %q when none was sent", r.Check, r.AssessmentDate)
		}
		if r.Applicability == nil {
			t.Errorf("check %q carries no applicability report; the declared window must still be visible", r.Check)
			continue
		}
		if r.Applicability.Gated {
			t.Errorf("check %q reports gated=true with no assessmentDate", r.Check)
		}
		if r.Applicability.Status != "unknown" {
			t.Errorf("check %q window status %q, want unknown with no as-of date", r.Check, r.Applicability.Status)
		}
	}

	s, err := tr.summary()
	if err != nil {
		t.Fatal(err)
	}
	if s.ApplicabilityGated {
		t.Error("summary claims applicabilityGated with no assessmentDate")
	}
	if s.AssessmentDate != "" {
		t.Errorf("summary assessmentDate = %q, want empty", s.AssessmentDate)
	}
	if len(s.UngatedFrameworks) != 1 || s.UngatedFrameworks[0] != "synthetic" {
		t.Errorf("ungatedFrameworks = %v, want [synthetic]: a verified window went unapplied and the summary must name it", s.UngatedFrameworks)
	}
	if s.NotInForce != 0 {
		t.Errorf("notInForce = %d, want 0", s.NotInForce)
	}
}

// Reproducibility, stated as a test because it is the hard requirement: the
// same request at the same as-of date must produce byte-identical verdicts, and
// the engine must not consult the clock to get there.
func TestScan_SameAsOfDateReplaysIdentically(t *testing.T) {
	tr := newScanTransport(t)
	first := scanAt(t, tr, "cra", "v1.0.0", "2026-10-11")
	second := scanAt(t, tr, "cra", "v1.0.0", "2026-10-11")
	norm := func(rows []ComplianceScanResult) []byte {
		for i := range rows {
			// scanTimestamp IS a clock read, and is deliberately not part of the
			// verdict. Blanking it is the point: everything else must match.
			rows[i].ScanTimestamp = ""
		}
		raw, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	if a, b := norm(first), norm(second); !bytes.Equal(a, b) {
		t.Errorf("two scans at the same as-of date disagree:\n%s\n%s", a, b)
	}
}

// An UNVERIFIED window must not change a verdict even on the scan path. Proved
// end to end against a synthetic pack rather than only at the unit level,
// because the scan path is where a mistake would actually cost money.
func TestScan_UnverifiedWindowDoesNotGateTheScan(t *testing.T) {
	h := syntheticWindowHandler(t, `"applicability":{"inForceFrom":"2099-01-01","basis":"enforcement-date","source":"s","note":"primary text not read","verified":false},`, "")
	rows := scanAt(t, handlerTransport{h}, "synthetic", "v1.0.0", "2026-10-11")
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	if rows[0].Status != VerdictPass {
		t.Errorf("status %q, want pass: an unverified future window must not gate", rows[0].Status)
	}
	// And the report tells the truth about why it did not: the declared window
	// says not-yet-in-force, and the engine declined to act on it.
	a := rows[0].Applicability
	if a == nil || a.Status != "not_yet_in_force" || a.Gated || a.Verified {
		t.Errorf("applicability report %+v: want status not_yet_in_force, gated false, verified false", a)
	}
}

// Precedence. A placeholder check of a future-dated regime reports
// not_evaluated, not not_in_force: having no expression at all is the primary
// and pack-intrinsic reason it was not evaluated, and it is true at every as-of
// date. Stated explicitly because two reasonable people would order these
// differently and a silent choice would be a silent bug.
func TestScan_PlaceholderBeatsNotInForce(t *testing.T) {
	h := syntheticWindowHandler(t, `"applicability":{"inForceFrom":"2099-01-01","basis":"enforcement-date","source":"s","verified":true},`, "placeholder")
	rows := scanAt(t, handlerTransport{h}, "synthetic", "v1.0.0", "2026-10-11")
	if len(rows) != 1 || rows[0].Status != VerdictNotEvaluated {
		t.Fatalf("status %q, want not_evaluated: a placeholder is not evaluated for a reason that outranks the window", rows[0].Status)
	}
}

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
			CarriedGBP: carried, Currency: defaultReportingCurrency,
			Carried: money.Money{Amount: carried, Currency: defaultReportingCurrency},
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
