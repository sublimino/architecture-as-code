package main

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

// The conformance suite enforces the verdict vocabulary BOTH WAYS, as it
// already does for placeholder <=> not_evaluated. The iff for the new token is:
//
//	not_in_force  <=>  the check's RESOLVED, VERIFIED window excludes the
//	                   fixture's assessmentDate
//
// Both directions matter and they fail differently. Forwards-only lets a pack
// claim not_in_force for a regime that is in force, which hides a real breach.
// Backwards-only lets a fixture assert pass or fail against an obligation that
// does not exist on its own stated date, which is the £256,514 defect this card
// exists to close -- now expressible in a fixture instead of only in prose.

// windowPack is syntheticPack with a framework-level window attached.
func windowPack(t *testing.T, a *frameworks.Applicability) *conformancePack {
	t.Helper()
	p := syntheticPack()
	p.fw.Applicability = a
	return newConformancePackFrom(p.dir, p.fw)
}

var futureWindow = &frameworks.Applicability{
	InForceFrom: "2027-12-11", Basis: frameworks.BasisEnforcementDate,
	Source: "https://eur-lex.europa.eu/eli/reg/2024/2847/oj", Verified: true,
}

// FORWARD. A not_in_force expectation must be earned: the fixture has to state
// an assessmentDate, and the window has to actually exclude it.
func TestConformanceHarness_NotInForceMustBeEarned(t *testing.T) {
	for name, tc := range map[string]struct {
		window *frameworks.Applicability
		asOf   string
		want   string
	}{
		"no window at all": {
			nil, "2026-10-11",
			`declares no applicability window`,
		},
		"no assessmentDate": {
			futureWindow, "",
			`needs an assessmentDate`,
		},
		"window is in force on that date": {
			futureWindow, "2027-12-11",
			`is in force on 2027-12-11`,
		},
		"window is unverified": {
			&frameworks.Applicability{InForceFrom: "2027-12-11", Basis: frameworks.BasisEnforcementDate, Source: "s", Note: "unread", Verified: false},
			"2026-10-11",
			`is not verified`,
		},
	} {
		p := windowPack(t, tc.window)
		f := fixture("a", "unit", map[string]Verdict{"non-root": VerdictNotInForce})
		f.AssessmentDate = tc.asOf
		p.fixtures = []conformanceFixture{f}
		got := strings.Join(validatePack(p), "\n")
		if !strings.Contains(got, tc.want) {
			t.Errorf("%s: problems %q do not contain %q", name, got, tc.want)
		}
	}

	// And the earned case is accepted.
	p := windowPack(t, futureWindow)
	f := fixture("a", "unit", map[string]Verdict{"non-root": VerdictNotInForce})
	f.AssessmentDate = "2026-10-11"
	p.fixtures = []conformanceFixture{f}
	if problems := validatePack(p); len(problems) != 0 {
		t.Errorf("a legitimate not_in_force expectation was rejected: %v", problems)
	}
}

// BACKWARD, and this is the direction that closes the money defect. A fixture
// dated before its regime applies CANNOT assert pass, fail or error: on that
// date there is no obligation to comply with, breach or evaluate.
func TestConformanceHarness_GatedCheckMustExpectNotInForce(t *testing.T) {
	for _, v := range []Verdict{VerdictPass, VerdictFail, VerdictError} {
		p := windowPack(t, futureWindow)
		f := fixture("a", "unit", map[string]Verdict{"non-root": v})
		f.AssessmentDate = "2026-10-11"
		f.Description = "why"
		p.fixtures = []conformanceFixture{f}
		got := strings.Join(validatePack(p), "\n")
		if !strings.Contains(got, `must expect not_in_force`) {
			t.Errorf("a %s expectation against a not-yet-in-force regime was accepted: %q", v, got)
		}
	}

	// A placeholder of a gated regime still expects not_evaluated: the engine's
	// precedence and the harness's must agree, or the two paths disagree about
	// the same pack.
	p := windowPack(t, futureWindow)
	ph := p.checks["strict-read"]
	ph.Status = "placeholder"
	p.checks["strict-read"] = ph
	f := fixture("a", "unit", map[string]Verdict{"strict-read": VerdictNotEvaluated})
	f.AssessmentDate = "2026-10-11"
	p.fixtures = []conformanceFixture{f}
	if problems := validatePack(p); len(problems) != 0 {
		t.Errorf("placeholder of a gated regime rejected for expecting not_evaluated: %v", problems)
	}
	f.Expect = map[string]Verdict{"strict-read": VerdictNotInForce}
	p.fixtures = []conformanceFixture{f}
	if got := strings.Join(validatePack(p), "\n"); !strings.Contains(got, "must expect not_evaluated") {
		t.Errorf("placeholder accepted a not_in_force expectation: %q", got)
	}
}

// A fixture's own assessmentDate is held to the same strict parse as the wire
// field, so a fixture cannot be silently ungated by a typo.
func TestConformanceHarness_RejectsMalformedFixtureAssessmentDate(t *testing.T) {
	for _, bad := range []string{"2027-13-01", "11 Dec 2027", "2027-12", "today"} {
		p := windowPack(t, futureWindow)
		f := fixture("a", "unit", map[string]Verdict{"non-root": VerdictPass})
		f.AssessmentDate = bad
		p.fixtures = []conformanceFixture{f}
		if got := strings.Join(validatePack(p), "\n"); !strings.Contains(got, "assessmentDate") {
			t.Errorf("fixture assessmentDate %q accepted: %q", bad, got)
		}
	}
}

// The harness must apply the gate the way handleScan does, or the two paths
// could pass their own suites while disagreeing about the same pack. This is
// the same reasoning that put shapeWorkload into evaluateFixture.
func TestConformanceHarness_EvaluateAppliesTheGate(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	p := windowPack(t, futureWindow)
	f := fixture("a", "unit", map[string]Verdict{"non-root": VerdictNotInForce})
	f.AssessmentDate = "2026-10-11"
	f.Input.Object = map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"name": "c"}}}}
	// Undated, the same input makes non-root FAIL. Dated before the regime
	// applies, it must not be evaluated at all -- which is the whole feature in
	// one assertion.
	undated := f
	undated.AssessmentDate = ""
	if got := evaluateFixture(eng, p, undated)["non-root"]; got.verdict != VerdictFail {
		t.Fatalf("undated: verdict %s, want fail (the input really does breach)", got.verdict)
	}
	if got := evaluateFixture(eng, p, f)["non-root"]; got.verdict != VerdictNotInForce || got.err != nil {
		t.Errorf("dated before the regime applies: verdict %s (err=%v), want not_in_force", got.verdict, got.err)
	}
}

// Every shipped pack's declared windows must be internally consistent with the
// basis they claim. Specifically: a window asserting a single in-force date on
// a TRANSPOSITION-DEADLINE basis must name the jurisdiction it is asserting it
// for, because a directive has no EU-wide in-force date for an obligated
// entity -- it has 27 national ones.
func TestConformance_TranspositionWindowsNameAJurisdiction(t *testing.T) {
	root := conformancePolicyRoot(t)
	for _, p := range loadConformancePacks(t, root) {
		for _, id := range p.order {
			a := p.window(id)
			if a == nil || a.Basis != frameworks.BasisTranspositionDeadline {
				continue
			}
			if a.Verified && strings.TrimSpace(a.Jurisdiction) == "" {
				t.Errorf("%s check %q: a verified transposition-deadline window gates with no jurisdiction; "+
					"a directive's in-force date is per Member State and asserting one EU-wide date would be wrong for 27 of them",
					p.label(), id)
			}
		}
	}
}
