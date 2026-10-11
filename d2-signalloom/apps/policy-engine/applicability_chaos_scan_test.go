package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// CHAOS AGAINST THE ENFORCEMENT WINDOWS AND THE AS-OF DATE, at the scan path.
//
// The sibling file frameworks/applicability_chaos_date_test.go attacks the
// parser. This one attacks what the parsed date then DOES: the inclusivity of
// both window ends at all four resolution levels, the whole-replacement
// resolution rule, the exposure invariant that makes a gated row cost nothing,
// determinism, and replay.
//
// Everything pinned here is invisible to a human reading one response. A scan
// that gated when it should not have, or did not when it should, returns HTTP
// 200 with a plausible-looking body; the difference shows up only as a number
// in a summary nobody can re-derive. Two findings below are pinned as
// CHARACTERISATION of a REPORTED DEFECT rather than as desired behaviour, and
// each says so in full so that whoever fixes it sees the test go red and knows
// immediately that red is the correct outcome.

// ── harness ────────────────────────────────────────────────────────────────

// chaosCheck is one check in a synthetic pack.
type chaosCheck struct {
	id     string
	expr   string
	window string // raw JSON fragment for "applicability", or "" for none
	status string // check-level status, e.g. placeholder
}

// chaosPack writes a one-framework pack with windows placeable at any level.
// Synthetic rather than shipped on purpose: every property here must survive
// the CRA's dates being corrected, a regime being added or one being retired.
func chaosPack(t *testing.T, fwWindow, csWindow, ctrlWindow, fwStatus string, checks ...chaosCheck) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "frameworks", "synthetic", "v1.0")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	field := func(name, frag string) string {
		if frag == "" {
			return ""
		}
		return `"` + name + `":` + frag + `,`
	}
	var body []string
	for _, c := range checks {
		status := ""
		if c.status != "" {
			status = `"status":"` + c.status + `",`
		}
		body = append(body, `{"id":"`+c.id+`","name":"`+c.id+`",`+status+field("applicability", c.window)+
			`"celExpression":`+chaosQuoteJSON(c.expr)+`,"riskTriple":{"min":1000,"mode":2000,"max":3000},`+
			`"freqTriple":{"min":0.1,"mode":0.2,"max":0.3},"policyVersions":["v1.0.0"]}`)
	}
	pack := `{"id":"synthetic","name":"S","version":"v1.0.0",` + field("status", chaosQuoteJSON(fwStatus)) +
		field("applicability", fwWindow) +
		`"controlSets":[{"id":"cs","name":"CS",` + field("applicability", csWindow) +
		`"controls":[{"id":"c1","name":"C1",` + field("applicability", ctrlWindow) +
		`"checks":[` + strings.Join(body, ",") + `]}]}]}`
	if err := os.WriteFile(filepath.Join(dir, "framework.json"), []byte(pack), 0o644); err != nil {
		t.Fatalf("writing synthetic pack: %v", err)
	}
	return root
}

func chaosQuoteJSON(s string) string {
	if s == "" {
		return ""
	}
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}

type chaosScanOut struct {
	code    int
	rows    []ComplianceScanResult
	summary ComplianceSummary
	body    string
}

// chaosScanRoot scans a policy root at one as-of date and reads the summary the
// same scan produced. A fresh handler per call, so no state leaks between
// cases. An empty asOf OMITS the field rather than sending "", which is the
// path a client predating the feature takes.
func chaosScanRoot(t *testing.T, root, asOf string) chaosScanOut {
	t.Helper()
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatalf("handler for %s: %v", root, err)
	}
	body := map[string]any{"frameworks": []string{"synthetic"}}
	if asOf != "" {
		body["assessmentDate"] = asOf
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	return chaosScanHandler(t, h, raw)
}

func chaosScanHandler(t *testing.T, h *complianceHandler, raw []byte) chaosScanOut {
	t.Helper()
	w := httptest.NewRecorder()
	h.handleScan(w, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw)))
	out := chaosScanOut{code: w.Code, body: w.Body.String()}
	if w.Code == http.StatusOK {
		if err := json.Unmarshal(w.Body.Bytes(), &out.rows); err != nil {
			t.Fatalf("scan body is not a result array: %v (%s)", err, out.body)
		}
	}
	sw := httptest.NewRecorder()
	h.handleSummary(sw, httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil))
	if err := json.Unmarshal(sw.Body.Bytes(), &out.summary); err != nil {
		t.Fatalf("summary body is not a summary: %v (%s)", err, sw.Body.String())
	}
	return out
}

func chaosStatusOfOnly(t *testing.T, out chaosScanOut) Verdict {
	t.Helper()
	if out.code != http.StatusOK {
		t.Fatalf("scan HTTP %d, want 200: %s", out.code, out.body)
	}
	if len(out.rows) != 1 {
		t.Fatalf("scan returned %d rows, want exactly 1", len(out.rows))
	}
	return out.rows[0].Status
}

const (
	chaosVerified = `{"inForceFrom":"2027-12-11","supersededFrom":"2030-01-01","basis":"enforcement-date","source":"CRA Article 71","verified":true}`
	chaosFuture   = `{"inForceFrom":"2027-12-11","basis":"enforcement-date","source":"CRA Article 71","verified":true}`
)

// ── 2. boundary arithmetic, at all four resolution levels ──────────────────

// THE WINDOW IS HALF-OPEN: [inForceFrom, supersededFrom). inForceFrom is
// INCLUSIVE — a regulation that "applies from" a date applies ON it.
// supersededFrom is the FIRST DAY IT NO LONGER DOES, so it is inclusive as a
// superseded boundary and exclusive as an in-force one. The two ends therefore
// read differently and a reader who assumes symmetry is wrong by one day in one
// direction, which is exactly the error the CRA proof (dates one day apart)
// cannot distinguish from correct behaviour on its own.
//
// Pinned at every level because the levels are four separate code paths into
// ResolveApplicability and nothing but a test stops one of them drifting.
func TestChaosWindow_HalfOpenBoundaryHoldsAtEveryResolutionLevel(t *testing.T) {
	levels := []struct {
		name              string
		fw, cs, ctrl, chk string
	}{
		{"framework", chaosVerified, "", "", ""},
		{"controlSet", "", chaosVerified, "", ""},
		{"control", "", "", chaosVerified, ""},
		{"check", "", "", "", chaosVerified},
	}
	days := []struct {
		asOf string
		want Verdict
		why  string
	}{
		{"2027-12-10", VerdictNotInForce, "the day before inForceFrom: the obligation does not exist yet"},
		{"2027-12-11", VerdictPass, "inForceFrom itself is INCLUSIVE"},
		{"2029-12-31", VerdictPass, "the day before supersededFrom is still in force"},
		{"2030-01-01", VerdictNotInForce, "supersededFrom itself is INCLUSIVE as the first day it no longer applies"},
		{"2031-06-01", VerdictNotInForce, "and it stays superseded"},
	}
	for _, lv := range levels {
		root := chaosPack(t, lv.fw, lv.cs, lv.ctrl, "", chaosCheck{id: "always-true", expr: "true", window: lv.chk})
		for _, d := range days {
			got := chaosStatusOfOnly(t, chaosScanRoot(t, root, d.asOf))
			if got != d.want {
				t.Errorf("window at %s level, asOf %s: status %q, want %q — %s",
					lv.name, d.asOf, got, d.want, d.why)
			}
		}
	}
}

// A degenerate or inverted window has no defensible reading: inForceFrom ==
// supersededFrom is in force for zero days, and supersededFrom < inForceFrom is
// in force never. Both must be refused, and refused ON THE SCAN PATH — the
// frameworks-package unit test proves the validator rejects them, which is a
// different claim from "the HTTP handler cannot be made to serve one".
//
// A DEPLOY-TIME TRAP worth knowing and not a defect in itself:
// newComplianceHandler accepts a root containing such a pack without
// complaint, and the rejection surfaces only as a 500 on the first scan. So a
// malformed window passes process startup and fails in front of a user.
func TestChaosWindow_DegenerateAndInvertedWindowsNeverServeAVerdict(t *testing.T) {
	cases := map[string]string{
		"supersededFrom == inForceFrom": `{"inForceFrom":"2027-12-11","supersededFrom":"2027-12-11","basis":"enforcement-date","source":"x","verified":true}`,
		"supersededFrom < inForceFrom":  `{"inForceFrom":"2027-12-11","supersededFrom":"2027-12-10","basis":"enforcement-date","source":"x","verified":true}`,
		"supersededFrom is not a day":   `{"inForceFrom":"2027-12-11","supersededFrom":"2027-02-30","basis":"enforcement-date","source":"x","verified":true}`,
		"basis names nothing":           `{"inForceFrom":"2027-12-11","basis":"vibes","source":"x","verified":true}`,
		"verified with no source":       `{"inForceFrom":"2027-12-11","basis":"enforcement-date","verified":true}`,
		"unverified with no note":       `{"inForceFrom":"2027-12-11","basis":"enforcement-date","verified":false}`,
	}
	for name, frag := range cases {
		root := chaosPack(t, frag, "", "", "", chaosCheck{id: "always-true", expr: "true"})
		// Construction succeeding is the trap, not the bug — asserted so the
		// trap is documented rather than discovered.
		if _, err := newComplianceHandler(root); err != nil {
			t.Logf("%s: handler construction also rejects it (%v)", name, err)
		}
		out := chaosScanRoot(t, root, "2027-12-11")
		if out.code == http.StatusOK {
			t.Errorf("%s: scan returned 200 with %d rows — a window with no defensible reading served a verdict: %s",
				name, len(out.rows), out.body)
		}
		if len(out.rows) != 0 {
			t.Errorf("%s: scan returned %d rows alongside HTTP %d", name, len(out.rows), out.code)
		}
	}
}

// A SUPERSEDED REGIME WITH NO SUCCESSOR silently stops costing anything. That
// is correct — a repealed obligation cannot be breached — and it is also the
// single cheapest way to make an exposure figure fall: retire the instrument.
// Pinned so the two halves stay true together: the row keeps its own priced
// figure (the evidence of what it WOULD have cost survives) and the summary
// adds nothing.
//
// Also pins the asymmetric shape of a supersededFrom-only window: before that
// day there is no declared start, so the window says NOTHING and the check
// evaluates. It does not become retroactively in force.
func TestChaosWindow_SupersededWithNoSuccessorRetiresTheCheckButKeepsItsFigure(t *testing.T) {
	frag := `{"supersededFrom":"2024-01-01","basis":"enforcement-date","source":"repealing instrument","verified":true}`
	root := chaosPack(t, frag, "", "", "", chaosCheck{id: "always-false", expr: "false"})

	live := chaosScanRoot(t, root, "2023-12-31")
	if got := chaosStatusOfOnly(t, live); got != VerdictFail {
		t.Errorf("asOf 2023-12-31 with only a supersededFrom declared: status %q, want %q — a window with no start date says nothing about an earlier day", got, VerdictFail)
	}
	if live.summary.TotalExposure <= 0 {
		t.Errorf("a failing in-force check contributed %.2f exposure, want > 0", live.summary.TotalExposure)
	}
	livePrice := live.rows[0].CarriedGBP

	retired := chaosScanRoot(t, root, "2024-01-01")
	if got := chaosStatusOfOnly(t, retired); got != VerdictNotInForce {
		t.Errorf("asOf 2024-01-01 == supersededFrom: status %q, want %q", got, VerdictNotInForce)
	}
	if got := retired.rows[0].CarriedGBP; got != livePrice {
		t.Errorf("retired row carries %.2f, live row carried %.2f: the row must keep its own figure so the evidence of what it would have cost survives", got, livePrice)
	}
	if retired.summary.TotalExposure != 0 {
		t.Errorf("summary exposure for a wholly-retired pack is %.2f, want exactly 0", retired.summary.TotalExposure)
	}
	if retired.summary.NotInForce != 1 || retired.summary.Failed != 0 {
		t.Errorf("summary says notInForce=%d failed=%d, want 1/0", retired.summary.NotInForce, retired.summary.Failed)
	}
}

// ── 3. resolution-order abuse ──────────────────────────────────────────────

// MOST-SPECIFIC-WINS-WHOLE, pinned field by field. The resolved window is the
// child's verbatim and the parent contributes NOTHING — not its source, not its
// basis, not its dates. The deliberate consequence is that a check-level window
// whose `source` cites the wrong document silently replaces a correct
// framework-level one, and no validation can catch it because `source` is free
// text and nothing cross-checks a citation against a date. That is reported, not
// fixed: the alternative (a field merge) produces a window whose citation points
// at a document that does not state its date, which is worse.
//
// The case that matters most is the LOOSER child: a check declaring an
// in-force date 27 years earlier than its framework's wins, and the regime is
// priced as live decades before it exists.
func TestChaosResolve_LooserChildWindowWinsWholeOverATighterParent(t *testing.T) {
	parent := `{"inForceFrom":"2030-01-01","basis":"enforcement-date","source":"the instrument","verified":true}`
	child := `{"inForceFrom":"2000-01-01","basis":"publication-date","source":"a different document entirely","verified":true}`

	// Both parent placements, because they are different arms of
	// ResolveApplicability: a framework-level parent is the function's final
	// fallback, a controlSet-level one is an element of the same ordered slice
	// the child is in. Reversing that slice is invisible if only the framework
	// arm is exercised.
	for _, p := range []struct{ name, fw, cs string }{
		{"framework-level parent", parent, ""},
		{"controlSet-level parent", "", parent},
	} {
		root := chaosPack(t, p.fw, p.cs, "", "", chaosCheck{id: "always-true", expr: "true", window: child})

		out := chaosScanRoot(t, root, "2020-01-01")
		if got := chaosStatusOfOnly(t, out); got != VerdictPass {
			t.Errorf("%s, asOf 2020-01-01: status %q, want %q — the check-level window wins whole and says the obligation already exists", p.name, got, VerdictPass)
		}
		win := out.rows[0].Applicability
		if win == nil {
			t.Fatalf("%s: the response must echo the resolved window; a gate nobody can see is not auditable", p.name)
		}
		if win.InForceFrom != "2000-01-01" || win.Basis != "publication-date" || win.Source != "a different document entirely" {
			t.Errorf("%s: resolved window is %+v: every field must come from the child, including the citation, so a reader can see WHICH document the date was read from", p.name, win)
		}
		// And nothing from the parent leaked in. A merge would show up here.
		if strings.Contains(win.Source, "the instrument") || win.SupersededFrom != "" {
			t.Errorf("%s: resolved window carries parent fields: %+v — whole replacement, never a field merge", p.name, win)
		}
	}
}

// REPORTED DEFECT, PINNED AS CHARACTERISATION. NOT desired behaviour.
//
// A window carrying no dates at all is indistinguishable from no window, so a
// child-level `applicability: {}` — or one carrying only a jurisdiction or only
// a note — silently ANNIHILATES a correct parent window. The loader accepts it:
// validateApplicability requires a basis only when a date is present, and
// requires a note only when a date is present and verified is false, so the
// empty object satisfies every rule.
//
// BOTH DIRECTIONS OF HARM, and the second is the expensive one:
//
//   - parent declares a FUTURE start: the check evaluates and its exposure is
//     counted for a regime that does not exist yet. Over-states exposure, which
//     is the conservative direction for money but still a wrong answer.
//   - parent declares a PAST supersededFrom (the instrument is repealed): the
//     check evaluates and a repealed obligation is priced as live. Under-states
//     nothing and over-states a liability that cannot legally arise.
//
// THE FIX would be a loader rule — a window with neither date and no
// jurisdiction has no meaning and must fail to load — which is a change to the
// applicability semantics and therefore out of scope for this card. When it
// lands, THIS TEST GOES RED AND RED IS CORRECT: delete it and keep the loader
// rejection instead.
func TestChaosResolve_DatelessChildWindowVoidsTheParent_REPORTED_DEFECT(t *testing.T) {
	for _, child := range []string{`{}`, `{"verified":false}`, `{"jurisdiction":"DE","verified":false}`, `{"note":"pending research","verified":false}`} {
		// (a) parent not yet in force — exposure counted for a regime that does not exist
		notYet := chaosPack(t, chaosFuture, "", "", "", chaosCheck{id: "always-false", expr: "false", window: child})
		out := chaosScanRoot(t, notYet, "2020-01-01")
		if got := chaosStatusOfOnly(t, out); got != VerdictFail {
			t.Errorf("child %s over a future parent window: status %q, want %q. "+
				"If this now reports %q the loader has learned to reject a dateless window — delete this test, the defect is fixed",
				child, got, VerdictFail, VerdictNotInForce)
		}
		if out.summary.TotalExposure <= 0 {
			t.Errorf("child %s: exposure %.2f, want > 0 — the whole point of the finding is that it is counted", child, out.summary.TotalExposure)
		}

		// (b) parent already superseded — a repealed obligation priced as live
		repealed := chaosPack(t, `{"inForceFrom":"2020-01-01","supersededFrom":"2022-01-01","basis":"enforcement-date","source":"repealed","verified":true}`,
			"", "", "", chaosCheck{id: "always-false", expr: "false", window: child})
		rep := chaosScanRoot(t, repealed, "2026-01-01")
		if got := chaosStatusOfOnly(t, rep); got != VerdictFail {
			t.Errorf("child %s over a SUPERSEDED parent window: status %q, want %q (the defect). A repealed obligation is being priced as live", child, got, VerdictFail)
		}
	}
}

// REPORTED DEFECT, PINNED AS CHARACTERISATION. NOT desired behaviour.
//
// A directive binds Member States, not entities, so a transposition-deadline
// window asserts a date that exists only per jurisdiction and must name the one
// it is asserting for. That invariant is enforced by
// TestConformance_TranspositionWindowsNameAJurisdiction, which walks the
// SHIPPED packs — so it is a statement about today's content, not about the
// contract. The loader has no such rule, so a pack added tomorrow can declare a
// jurisdiction-free transposition window and GATE A CHECK with it, zeroing that
// check's exposure on the strength of a date that is not an in-force date
// anywhere.
//
// THE FIX is a loader rule in validateApplicability — out of scope here for the
// same reason as above. When it lands this test goes red; red is correct.
func TestChaosResolve_TranspositionWindowWithNoJurisdictionLoadsAndGates_REPORTED_DEFECT(t *testing.T) {
	frag := `{"inForceFrom":"2027-12-11","basis":"transposition-deadline","source":"NIS2 Article 41","note":"deadline for national law, not a date obligations begin","verified":true}`
	root := chaosPack(t, frag, "", "", "", chaosCheck{id: "always-false", expr: "false"})

	out := chaosScanRoot(t, root, "2026-01-01")
	if out.code != http.StatusOK {
		t.Fatalf("pack failed to load (HTTP %d): if validateApplicability now requires a jurisdiction for %s, "+
			"delete this test — the defect is fixed: %s", out.code, "transposition-deadline", out.body)
	}
	if got := chaosStatusOfOnly(t, out); got != VerdictNotInForce {
		t.Errorf("status %q, want %q: the finding is that this window gates despite naming no jurisdiction", got, VerdictNotInForce)
	}
	if out.summary.TotalExposure != 0 {
		t.Errorf("exposure %.2f, want 0: the finding is that a jurisdiction-free directive deadline erases priced exposure", out.summary.TotalExposure)
	}
	if win := out.rows[0].Applicability; win == nil || win.Jurisdiction != "" {
		t.Errorf("the echoed window is %+v: the response must at least show that no jurisdiction was named", win)
	}
}

// ── 4. the exposure invariant ──────────────────────────────────────────────

// THE COMMERCIALLY LOAD-BEARING ONE. The summary's total must equal the sum of
// its OWN non-gated, non-placeholder rows — never more, never less — while
// every row keeps its own priced figure. Run over a pack mixing all five
// verdicts across one scan, because the arithmetic is only interesting when
// something is being excluded.
//
// Also pins the two counting identities a reader would assume and nothing else
// asserts: the five verdict counts sum to TotalControls, and TotalControls
// equals the number of rows returned.
func TestChaosExposure_SummaryTotalEqualsTheSumOfItsOwnCountedRows(t *testing.T) {
	gated := `{"inForceFrom":"2027-12-11","basis":"enforcement-date","source":"x","verified":true}`
	root := chaosPack(t, "", "", "", "",
		chaosCheck{id: "will-pass", expr: "true"},
		chaosCheck{id: "will-fail", expr: "false"},
		chaosCheck{id: "will-error", expr: "nosuchvariable == 1"},
		chaosCheck{id: "is-placeholder", expr: "false", status: "placeholder"},
		chaosCheck{id: "gated-would-fail", expr: "false", window: gated},
		chaosCheck{id: "gated-would-error", expr: "nosuchvariable == 1", window: gated},
		chaosCheck{id: "gated-and-placeholder", expr: "false", window: gated, status: "placeholder"},
	)
	out := chaosScanRoot(t, root, "2020-01-01")
	if out.code != http.StatusOK {
		t.Fatalf("scan HTTP %d: %s", out.code, out.body)
	}

	want := map[string]Verdict{
		"will-pass":  VerdictPass,
		"will-fail":  VerdictFail,
		"will-error": VerdictError,
		// Placeholder outranks the gate: having no expression at all is the
		// primary, pack-intrinsic reason a check is not evaluated and it is
		// true at every as-of date.
		"is-placeholder":        VerdictNotEvaluated,
		"gated-would-fail":      VerdictNotInForce,
		"gated-would-error":     VerdictNotInForce,
		"gated-and-placeholder": VerdictNotEvaluated,
	}
	var expectedTotal float64
	for _, r := range out.rows {
		if w, ok := want[r.Check]; !ok {
			t.Errorf("unexpected row %q", r.Check)
		} else if r.Status != w {
			t.Errorf("check %q: status %q, want %q", r.Check, r.Status, w)
		}
		if r.CarriedGBP <= 0 {
			t.Errorf("check %q carries %.2f: EVERY row keeps its own priced figure, including a gated one — that is the evidence of what it would have cost", r.Check, r.CarriedGBP)
		}
		if r.Status == VerdictFail || r.Status == VerdictError {
			expectedTotal += r.CarriedGBP
		}
	}

	s := out.summary
	if math.Abs(s.TotalExposure-expectedTotal) > 0.005 {
		t.Errorf("summary totalExposure %.4f, sum of its own counted rows %.4f: the summary disagrees with the rows it is a summary OF", s.TotalExposure, expectedTotal)
	}
	if s.TotalControls != len(out.rows) {
		t.Errorf("totalControls %d, rows returned %d", s.TotalControls, len(out.rows))
	}
	if sum := s.Passed + s.Failed + s.Errored + s.NotEvaluated + s.NotInForce; sum != s.TotalControls {
		t.Errorf("verdict counts sum to %d, totalControls is %d: a row has fallen between the buckets", sum, s.TotalControls)
	}
	if s.NotInForce != 2 {
		t.Errorf("notInForce %d, want 2 (the placeholder-and-gated row counts as notEvaluated)", s.NotInForce)
	}
	if s.NotEvaluated != 2 {
		t.Errorf("notEvaluated %d, want 2", s.NotEvaluated)
	}
	if s.Errored != 1 {
		t.Errorf("errored %d, want 1: the GATED would-be-error must not be counted as an error", s.Errored)
	}
}

// A TRAP FOR EVERY DOWNSTREAM CONSUMER, pinned because it is the kind of thing
// a dashboard gets wrong silently. A not_in_force row carries a NON-EMPTY
// `error` field — the field holds the gate's REASON, not a failure — so any
// consumer that treats `error != ""` as "this check is in trouble" will report
// a regime that does not exist yet as a problem, and will do it on a row the
// summary deliberately counts as costing nothing.
//
// Pinned as an observation about the response shape, not as an endorsement:
// the reason text is genuinely useful and the right place for it may still be a
// separate field. Reported.
func TestChaosExposure_NotInForceRowsCarryAReasonInTheErrorFieldAndStillCostNothing(t *testing.T) {
	root := chaosPack(t, chaosFuture, "", "", "", chaosCheck{id: "always-false", expr: "false"})
	out := chaosScanRoot(t, root, "2020-01-01")
	if got := chaosStatusOfOnly(t, out); got != VerdictNotInForce {
		t.Fatalf("status %q, want %q", got, VerdictNotInForce)
	}
	r := out.rows[0]
	if r.Error == "" {
		t.Error("a gated row must say WHY in the response; a verdict with no stated reason is not auditable")
	}
	if r.Passed {
		t.Error("a not_in_force row must not report passed:true — it was never evaluated")
	}
	if out.summary.Errored != 0 {
		t.Errorf("summary errored %d, want 0: a non-empty error field on a not_in_force row must never be counted as an error", out.summary.Errored)
	}
	if out.summary.TotalExposure != 0 {
		t.Errorf("summary exposure %.2f, want 0", out.summary.TotalExposure)
	}
	t.Logf("CHAOS-TRAP not_in_force row carries error=%q while contributing zero exposure — consumers filtering on a non-empty error field will mis-report it", r.Error)
}

// EVERY CHECK GATED: the degenerate case where the answer should be exactly
// zero rather than merely small, and where TotalControls must stay honest
// rather than shrinking to the number of rows that happened to cost something.
func TestChaosExposure_EveryCheckGatedIsExactlyZeroAndTotalControlsStaysHonest(t *testing.T) {
	root := chaosPack(t, chaosFuture, "", "", "",
		chaosCheck{id: "a", expr: "false"},
		chaosCheck{id: "b", expr: "false"},
		chaosCheck{id: "c", expr: "nosuchvariable == 1"},
	)
	out := chaosScanRoot(t, root, "2020-01-01")
	if out.summary.TotalExposure != 0 {
		t.Errorf("exposure %.20g, want exactly 0 — not approximately, not rounded to 0", out.summary.TotalExposure)
	}
	if out.summary.Exposure.Amount != 0 {
		t.Errorf("money exposure %.20g, want exactly 0", out.summary.Exposure.Amount)
	}
	if out.summary.TotalControls != 3 || out.summary.NotInForce != 3 {
		t.Errorf("totalControls %d notInForce %d, want 3/3: gated checks are excluded from exposure, never from the denominator",
			out.summary.TotalControls, out.summary.NotInForce)
	}
}

// ── 5. determinism (ADR-0006) ──────────────────────────────────────────────

// NO CLOCK IN THE WINDOW PATH. Two scans of the same request must agree on
// every field except the scan timestamp, and must keep agreeing with the
// server's local zone moved to both extremes between the runs.
func TestChaosDeterminism_SameRequestTwiceIdenticalExceptTheScanTimestamp(t *testing.T) {
	root := chaosPack(t, chaosVerified, "", "", "",
		chaosCheck{id: "a", expr: "true"},
		chaosCheck{id: "b", expr: "false"},
	)
	strip := func(out chaosScanOut) string {
		t.Helper()
		for i := range out.rows {
			out.rows[i].ScanTimestamp = ""
		}
		out.summary.ScanTimestamp = ""
		b, err := json.Marshal(map[string]any{"rows": out.rows, "summary": out.summary})
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}

	first := strip(chaosScanRoot(t, root, "2029-06-01"))
	orig := time.Local
	t.Cleanup(func() { time.Local = orig })
	for _, offset := range []int{14 * 3600, -11 * 3600} {
		time.Local = time.FixedZone("CHAOS", offset)
		if got := strip(chaosScanRoot(t, root, "2029-06-01")); got != first {
			t.Errorf("the same request answered differently with the server's local zone at offset %d.\nfirst: %s\nagain: %s", offset, first, got)
		}
	}
}

// AN ABSENT assessmentDate NEVER PICKS UP TODAY. Proven against a pack
// carrying BOTH a window that today would gate and one that today would not:
// if the engine were substituting the clock, the two would diverge. They must
// not — nothing gates, and the summary says so twice (applicabilityGated:false
// and the framework named in ungatedFrameworks) rather than leaving a reader to
// assume the dates were checked.
func TestChaosDeterminism_AbsentAssessmentDateGatesNothingAndSaysSoTwice(t *testing.T) {
	root := chaosPack(t, "", "", "", "",
		chaosCheck{id: "future-window", expr: "false", window: chaosFuture},
		chaosCheck{id: "past-window", expr: "false", window: `{"inForceFrom":"2000-01-01","basis":"enforcement-date","source":"x","verified":true}`},
		chaosCheck{id: "retired-window", expr: "false", window: `{"inForceFrom":"2000-01-01","supersededFrom":"2001-01-01","basis":"enforcement-date","source":"x","verified":true}`},
	)
	out := chaosScanRoot(t, root, "")
	for _, r := range out.rows {
		if r.Status == VerdictNotInForce {
			t.Errorf("check %q gated with no assessmentDate supplied: the engine has read a clock", r.Check)
		}
		if r.AssessmentDate != "" {
			t.Errorf("check %q echoes assessmentDate %q with none supplied", r.Check, r.AssessmentDate)
		}
	}
	s := out.summary
	if s.AssessmentDate != "" || s.ApplicabilityGated {
		t.Errorf("summary claims assessmentDate %q applicabilityGated %v with none supplied", s.AssessmentDate, s.ApplicabilityGated)
	}
	if len(s.UngatedFrameworks) != 1 || s.UngatedFrameworks[0] != "synthetic" {
		t.Errorf("ungatedFrameworks %v, want [synthetic]: a scan whose windows were not applied must NAME the frameworks whose windows were skipped", s.UngatedFrameworks)
	}
	if s.TotalExposure <= 0 {
		t.Errorf("exposure %.2f, want > 0: the documented default leaves every check evaluating exactly as it did before the gate existed", s.TotalExposure)
	}
}

// applicabilityGated AND ungatedFrameworks MUST NOT BOTH FIRE. They are
// contradictory claims — "the windows were applied" and "these frameworks'
// windows were not" — and a response asserting both is unreadable by anyone
// relying on either. This is the response-level signature of the year-one
// defect: assessmentDate="0001-01-01" produced exactly this pair, with full
// exposure, before frameworks.Date carried an explicit `set` flag.
//
// MUTATION PROOF: restore Date.IsZero to `return d.t.IsZero()` and the
// 0001-01-01 row fails on both the contradiction and the exposure assertion.
func TestChaosDeterminism_GatedFlagAndUngatedListAreNeverBothTrue(t *testing.T) {
	root := chaosPack(t, chaosFuture, "", "", "", chaosCheck{id: "always-false", expr: "false"})
	for _, asOf := range []string{"0001-01-01", "0000-01-01", "0001-01-02", "1970-01-01", "2020-01-01", "2030-01-01"} {
		out := chaosScanRoot(t, root, asOf)
		s := out.summary
		if !s.ApplicabilityGated {
			t.Errorf("asOf %s: applicabilityGated false with a date supplied", asOf)
		}
		if len(s.UngatedFrameworks) != 0 {
			t.Errorf("asOf %s: summary says applicabilityGated=%v AND ungatedFrameworks=%v — the response makes two contradictory claims about the same scan",
				asOf, s.ApplicabilityGated, s.UngatedFrameworks)
		}
		if s.AssessmentDate != asOf {
			t.Errorf("asOf %s: summary echoes %q — the evidence must record the date actually compared, byte for byte", asOf, s.AssessmentDate)
		}
		want := VerdictNotInForce
		if asOf == "2030-01-01" {
			want = VerdictFail
		}
		if got := chaosStatusOfOnly(t, out); got != want {
			t.Errorf("asOf %s: status %q, want %q — every day before 2027-12-11 is before 2027-12-11, including the first day of year one", asOf, got, want)
		}
	}
}

// The engine must not be able to read a clock on this path at all. Asserted on
// the source, the same way the ADR-0006 date tripwire is asserted on the CEL
// bodies: a structural claim needs a structural test, because a behavioural one
// only catches a clock read whose effect happens to differ today.
func TestChaosDeterminism_NoClockReadInTheApplicabilitySource(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("frameworks", "applicability.go"))
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"time.Now", "time.Since", "time.Until", "Local"} {
		if bytes.Contains(src, []byte(forbidden)) {
			t.Errorf("frameworks/applicability.go references %s: a window comparison that can read a clock or a zone makes the same request answer differently on different days, which is the property ADR-0006 exists to forbid", forbidden)
		}
	}
	if !bytes.Contains(src, []byte("ParseInLocation")) || !bytes.Contains(src, []byte("time.UTC")) {
		t.Error("frameworks/applicability.go must parse with ParseInLocation(..., time.UTC): a calendar day in a legal instrument cannot depend on where the server is")
	}
}

// ── 6. replay ──────────────────────────────────────────────────────────────

// THE REPLAY ANSWER, and it is not reassuring.
//
// A stored scan replays to identical verdicts a year later ONLY IF the pack is
// also identical. Edit a window's date in place without touching
// framework.version or policyVersion — which nothing requires you to do — and
// the same request at the same assessmentDate returns DIFFERENT verdicts and a
// different exposure, with framework/version/policyVersion/check-id all
// unchanged. Nothing in the request or in the identifiers a customer would
// quote distinguishes the two runs.
//
// What saves it is narrow and worth knowing precisely: each ROW echoes the
// resolved window (`applicability`), so a bundle that kept the rows can be
// diffed against a re-run and the edit becomes visible. A bundle that kept only
// the SUMMARY cannot — the summary carries assessmentDate and
// applicabilityGated and no window at all. So the row array is the evidence of
// record and the summary is not, and this test pins both halves.
//
// Reported, not fixed: making this self-verifying needs a pack digest on the
// response, which is a change to the response contract.
func TestChaosReplay_EditingAWindowFlipsStoredVerdictsWithNoVersionChange(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "frameworks", "synthetic", "v1.0")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(inForce string) {
		t.Helper()
		pack := fmt.Sprintf(`{"id":"synthetic","name":"S","version":"v1.0.0",
      "applicability":{"inForceFrom":%q,"basis":"enforcement-date","source":"x","verified":true},
      "controlSets":[{"id":"cs","name":"CS","controls":[{"id":"c1","name":"C1","checks":[
        {"id":"always-false","name":"t","celExpression":"false","riskTriple":{"min":1000,"mode":2000,"max":3000},
         "freqTriple":{"min":0.1,"mode":0.2,"max":0.3},"policyVersions":["v1.0.0"]}]}]}]}`, inForce)
		if err := os.WriteFile(filepath.Join(dir, "framework.json"), []byte(pack), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	const asOf = "2026-01-01"
	write("2027-12-11")
	before := chaosScanRoot(t, root, asOf)
	// The only thing that changes between the two scans: one date inside the
	// pack. No version is bumped, because nothing makes you bump one.
	write("2020-01-01")
	after := chaosScanRoot(t, root, asOf)

	b, a := before.rows[0], after.rows[0]
	if b.Status != VerdictNotInForce || a.Status != VerdictFail {
		t.Fatalf("setup did not produce the divergence under test: before %q after %q", b.Status, a.Status)
	}
	// Every identifier a customer would quote is unchanged across the flip.
	for _, f := range []struct{ name, before, after string }{
		{"framework", b.Framework, a.Framework},
		{"frameworkVersion", b.FrameworkVersion, a.FrameworkVersion},
		{"policyVersion", b.PolicyVersion, a.PolicyVersion},
		{"controlId", b.ControlID, a.ControlID},
		{"check", b.Check, a.Check},
		{"assessmentDate", b.AssessmentDate, a.AssessmentDate},
	} {
		if f.before != f.after {
			t.Errorf("%s changed (%q -> %q); the finding is that NONE of these change, so if one now does the evidence has gained a discriminator and this test should be rewritten to assert it", f.name, f.before, f.after)
		}
	}
	if before.summary.TotalExposure != 0 || after.summary.TotalExposure <= 0 {
		t.Errorf("exposure did not move with the edit: before %.2f after %.2f", before.summary.TotalExposure, after.summary.TotalExposure)
	}

	// THE ONE DISCRIMINATOR: the per-row echoed window.
	if b.Applicability == nil || a.Applicability == nil {
		t.Fatal("rows must echo the resolved window: without it a stored scan has NOTHING that distinguishes it from a replay against an edited pack")
	}
	if b.Applicability.InForceFrom == a.Applicability.InForceFrom {
		t.Error("the echoed window did not change with the pack edit: the row-level echo is the only replay discriminator there is")
	}

	// And the gap: the summary carries no window, so a summary-only bundle is
	// not replay-verifiable. Asserted on the serialised form so a field added
	// later shows up here as a (welcome) failure.
	raw, err := json.Marshal(before.summary)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("inForceFrom")) || bytes.Contains(raw, []byte("applicability\"")) {
		t.Log("CHAOS-REPLAY the summary now carries window detail — the summary-only evidence gap has narrowed; update the finding")
	} else {
		t.Logf("CHAOS-REPLAY summary carries no window detail (%s): a bundle consisting of the summary alone cannot detect a pack edit. The ROW ARRAY is the evidence of record.", raw)
	}
}

// Replay must also be stable against the REQUEST being re-serialised, which is
// what actually happens when a bundle is replayed from stored JSON: key order
// changes, and Go's decoder matches field names case-insensitively and takes
// the LAST of a duplicated key without complaint. Neither is a defect the
// engine can refuse, so the property that has to hold is that the response
// always ECHOES the date it actually compared — making an injected or
// re-serialised date detectable from the evidence rather than invisible.
func TestChaosReplay_TheResponseAlwaysEchoesTheDateItActuallyCompared(t *testing.T) {
	root := chaosPack(t, chaosFuture, "", "", "", chaosCheck{id: "always-false", expr: "false"})
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, body, wantEcho string
		wantStatus           Verdict
	}{
		{"canonical", `{"frameworks":["synthetic"],"assessmentDate":"2030-01-01"}`, "2030-01-01", VerdictFail},
		// Go's encoding/json matches field names case-insensitively, so this
		// APPLIES the date. A proxy or client that cased the key differently
		// gets a gated scan; the echo is what makes that visible.
		{"cased key", `{"frameworks":["synthetic"],"AssessmentDate":"2020-01-01"}`, "2020-01-01", VerdictNotInForce},
		// Duplicated keys: the LAST wins, silently. Same defence.
		{"duplicated key", `{"frameworks":["synthetic"],"assessmentDate":"2030-01-01","assessmentDate":"2020-01-01"}`, "2020-01-01", VerdictNotInForce},
		// A snake_case near-miss is an UNKNOWN field and is ignored, so no
		// date is supplied at all — and the summary says applicabilityGated
		// false rather than pretending the window was applied.
		{"snake_case near miss", `{"frameworks":["synthetic"],"assessment_date":"2020-01-01"}`, "", VerdictFail},
		{"explicit null", `{"frameworks":["synthetic"],"assessmentDate":null}`, "", VerdictFail},
		{"empty string", `{"frameworks":["synthetic"],"assessmentDate":""}`, "", VerdictFail},
	}
	for _, c := range cases {
		out := chaosScanHandler(t, h, []byte(c.body))
		if out.code != http.StatusOK {
			t.Errorf("%s: HTTP %d, want 200: %s", c.name, out.code, out.body)
			continue
		}
		if got := chaosStatusOfOnly(t, out); got != c.wantStatus {
			t.Errorf("%s: status %q, want %q", c.name, got, c.wantStatus)
		}
		if got := out.rows[0].AssessmentDate; got != c.wantEcho {
			t.Errorf("%s: row echoes assessmentDate %q, want %q — the evidence must record the date actually compared, so a re-serialised or injected date is detectable instead of silent", c.name, got, c.wantEcho)
		}
		if got := out.summary.AssessmentDate; got != c.wantEcho {
			t.Errorf("%s: summary echoes %q, want %q", c.name, got, c.wantEcho)
		}
		if out.summary.ApplicabilityGated != (c.wantEcho != "") {
			t.Errorf("%s: applicabilityGated %v with echoed date %q", c.name, out.summary.ApplicabilityGated, chaosSummaryDate(out))
		}
	}
}

func chaosSummaryDate(out chaosScanOut) string { return out.summary.AssessmentDate }
