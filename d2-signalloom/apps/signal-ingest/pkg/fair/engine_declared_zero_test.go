package fair

// A declared zero is UNEXPRESSIBLE in this engine, and so is a declared seed of
// zero. Both are silently replaced by defaults.
//
// WHY THIS FILE IS HERE RATHER THAN IN THE POLICY ENGINE. There are two FAIR
// engines in this repository and they disagree about what a zero means:
//
//	policy-engine/fair         SimulateWithLoad(.., riskLoad float64), called
//	                           with a load resolved from a *float64 on the
//	                           request, so 0 and absent are distinguishable.
//	signal-ingest/pkg/fair     Inputs.RiskLoad is a PLAIN float64 and
//	                           WithDefaults() (engine.go:307-321) does
//	                               if in.RiskLoad == 0 { in.RiskLoad = DefaultRiskLoad }
//
// The policy engine's own comment explains why it chose a pointer: "0 is a
// coherent declared posture ('carry the tail with no load on top') and a plain
// float64 could not tell it apart from absent, which would silently price a
// declared zero as the 0.10 default". That is a precise description of what this
// engine does. One side took the lesson; this side is the counter-example, and it
// is still shipping.
//
// THREE FIELDS, ONE PATTERN. WithDefaults uses `== 0` as a proxy for "unset" on
// RiskLoad, Seed and Trials. For Trials it is harmless -- zero trials is not a
// coherent request and Validate would reject it anyway. For the other two it
// silently discards a legitimate declaration:
//
//	RiskLoad: 0  -> 0.10. A no-load posture cannot be expressed.
//	Seed:     0  -> DefaultSeed. A run deliberately seeded 0 is not the run that
//	                executes, and nothing says so. For an engine whose stated
//	                purpose is that "a number nobody can reproduce is not
//	                evidence", a seed that cannot be set to a specific legal
//	                value is the same class of problem as an unpinned one.
//
// NEGATIVE ZERO MAKES IT WORSE. In Go `-0.0 == 0` is TRUE, so a caller who
// computes a load and arrives at negative zero -- which any multiplication by a
// negative, or a parse of "-0.0", will produce -- also silently gets 0.10.
//
// ORDERING IS WHY IT IS INVISIBLE. WithDefaults runs BEFORE Validate, and
// Validate's riskLoad check (`IsNaN || IsInf || < 0`) would pass a zero happily.
// So there is no layer at which a declared zero is refused; it is accepted,
// replaced, and priced. The response reports RiskLoad: 0.10, which is truthful
// about what was used and silent about what was asked for.
//
// REPORTED, NOT FIXED. Making a zero expressible here means changing Inputs to
// carry a *float64 (or an explicit `RiskLoadSet bool`), which changes figures for
// any caller currently relying on the zero-value default. That is a change to
// the money and out of scope for this chaos work. These tests pin the behaviour
// so the fix is deliberate and so the divergence between the two engines is on
// the record.

import (
	"math"
	"testing"
)

// ── 1. The defect: a declared zero becomes the default ────────────────────────

// TestADeclaredZeroRiskLoadIsUnexpressible_DEFECT pins the replacement at the
// unit that performs it.
//
// THIS IS A DEFECT. The fix is a pointer or a companion "set" flag on Inputs,
// matching what the policy engine already does. Until then this test is the
// record, and its failure means someone has made a zero expressible -- which is
// the desired outcome, at which point this test should be deleted and the
// divergence note in the file header removed.
func TestADeclaredZeroRiskLoadIsUnexpressible_DEFECT(t *testing.T) {
	for _, declared := range []float64{0, math.Copysign(0, -1)} {
		in := Inputs{RiskLoad: declared}
		got := in.WithDefaults().RiskLoad

		if got != DefaultRiskLoad {
			t.Fatalf("WithDefaults turned a declared %v into %v, not the %v default. "+
				"If a zero is now expressible THIS DEFECT IS FIXED -- delete this test "+
				"and the divergence note in the file header.", declared, got, DefaultRiskLoad)
		}
		t.Logf("DEFECT CONFIRMED: Inputs{RiskLoad: %v}.WithDefaults().RiskLoad = %v; "+
			"a no-load posture cannot be expressed in this engine",
			declared, got)
	}

	// And there is no layer that refuses it either: WithDefaults runs before
	// Validate, and Validate would accept a zero. So the declaration is not
	// rejected, it is overwritten.
	if err := (Inputs{RiskLoad: 0}).validateRiskLoadOnly(); err != nil {
		t.Errorf("Validate rejects a zero load (%v), which would at least make the "+
			"replacement visible; re-read this test", err)
	}
}

// validateRiskLoadOnly isolates Validate's riskLoad predicate so the test can
// show that a zero passes it, without having to construct a fully valid Inputs.
//
// It duplicates the predicate rather than calling Validate because Validate
// checks triples first and would fail on those, masking the answer to the
// question actually being asked. Keeping the duplicate adjacent to the test that
// uses it, and asserting it against the real Validate below, is the honest way
// to isolate one clause.
func (in Inputs) validateRiskLoadOnly() error {
	if math.IsNaN(in.RiskLoad) || math.IsInf(in.RiskLoad, 0) || in.RiskLoad < 0 {
		return ErrRiskLoadRange
	}
	return nil
}

// TestTheIsolatedRiskLoadPredicateMatchesValidate stops the helper above from
// drifting away from the clause it claims to mirror.
//
// Without this, a change to Validate's riskLoad check would leave
// validateRiskLoadOnly asserting something Validate no longer does, and the
// DEFECT test would keep passing while describing code that had moved. A
// hand-copied predicate is only honest if something ties it to the original.
func TestTheIsolatedRiskLoadPredicateMatchesValidate(t *testing.T) {
	base := validInputsForZeroTest()
	for _, load := range []float64{0, 0.1, 1, 1e9, -0.1, -1, math.NaN(), math.Inf(1), math.Inf(-1)} {
		in := base
		in.RiskLoad = load
		in.Trials = DefaultTrials // keep Trials out of the comparison
		in.Seed = DefaultSeed

		full := in.Validate()
		isolated := in.validateRiskLoadOnly()

		// Validate may fail for reasons other than riskLoad; what must hold is
		// that whenever the isolated predicate rejects, Validate also rejects.
		if isolated != nil && full == nil {
			t.Errorf("load %v: the isolated predicate rejects but Validate accepts; the "+
				"helper no longer mirrors Validate", load)
		}
		// And for a load the isolated predicate accepts, Validate must not be
		// failing ON THE LOAD -- checked by confirming the valid baseline passes.
		if isolated == nil && full != nil {
			t.Logf("load %v: Validate rejects for a non-riskLoad reason (%v)", load, full)
		}
	}
	// The baseline itself must be valid, or the comparison above is vacuous.
	if err := base.WithDefaults().Validate(); err != nil {
		t.Fatalf("baseline Inputs are not valid, so this test proves nothing: %v", err)
	}
}

// ── 2. The same pattern on the seed, which is a reproducibility hazard ────────

// TestADeclaredSeedOfZeroIsUnexpressible_DEFECT pins the sibling defect.
//
// The seed matters more than it looks. This engine's whole claim is
// reproducibility -- the same inputs give the same figure forever. A caller who
// pins Seed: 0 gets DefaultSeed, so the run that executes is not the run that
// was requested, and the audit record reports the seed that was USED. Nothing
// anywhere says the request was altered. The figure is reproducible; it is just
// not reproducing what the caller asked for.
//
// THIS IS A DEFECT of the same family and the same fix (an explicit "set" flag,
// or treating the zero value as legitimate and requiring callers to opt out).
func TestADeclaredSeedOfZeroIsUnexpressible_DEFECT(t *testing.T) {
	in := Inputs{Seed: 0}
	got := in.WithDefaults().Seed
	if got != DefaultSeed {
		t.Fatalf("WithDefaults turned a declared seed of 0 into %v, not DefaultSeed %v. "+
			"If a zero seed is now expressible THIS DEFECT IS FIXED -- delete this test.",
			got, DefaultSeed)
	}
	t.Logf("DEFECT CONFIRMED: Inputs{Seed: 0}.WithDefaults().Seed = %v; a run "+
		"deliberately seeded 0 is not the run that executes, and the audit record "+
		"reports the substituted seed", got)
}

// TestTrialsZeroIsTheOneCaseWhereTheProxyIsHarmless records the boundary, so the
// report does not overstate the finding.
//
// `Trials == 0` is also treated as unset, and there it is fine: zero trials is
// not a coherent request, Validate rejects `Trials < 1` anyway, and no
// information is lost. Stating which of the three fields is NOT a problem is
// what keeps the other two credible.
func TestTrialsZeroIsTheOneCaseWhereTheProxyIsHarmless(t *testing.T) {
	if got := (Inputs{Trials: 0}).WithDefaults().Trials; got != DefaultTrials {
		t.Errorf("Trials: 0 -> %v, want DefaultTrials %v", got, DefaultTrials)
	}
	// And a zero would have been refused regardless, so nothing expressible was
	// discarded -- unlike RiskLoad and Seed.
	in := validInputsForZeroTest()
	in.Trials = 0
	in.Seed = DefaultSeed
	in.RiskLoad = DefaultRiskLoad
	if err := in.Validate(); err == nil {
		t.Error("Validate accepted Trials: 0; if zero trials is now meaningful then the " +
			"defaulting proxy discards a legitimate value here too, and this test is wrong")
	}
}

// ── 3. The divergence, asserted as a single sentence ──────────────────────────

// TestTheTwoEnginesDisagreeAboutWhatAZeroLoadMeans_DEFECT is the finding in one
// assertion, for the report.
//
// It cannot import the policy engine (different package, and importing a `main`
// package is not possible), so it asserts THIS side's behaviour and states the
// other side's in the message. The policy-engine side is pinned by
// TestADeclaredZeroSurvivesTheWholePathAndNegativeZeroWithIt in
// compliance_money_declared_zero_test.go; the two tests together are the
// evidence, and neither alone is.
func TestTheTwoEnginesDisagreeAboutWhatAZeroLoadMeans_DEFECT(t *testing.T) {
	const zero = 0.0
	thisEngine := (Inputs{RiskLoad: zero}).WithDefaults().RiskLoad

	if thisEngine == zero {
		t.Fatal("this engine now preserves a declared zero, so the two engines AGREE and " +
			"this DEFECT IS FIXED -- delete this test and the header note")
	}
	t.Logf("DIVERGENCE CONFIRMED: for riskLoad=0, signal-ingest/pkg/fair prices at %v "+
		"(DefaultRiskLoad) while policy-engine/fair prices at 0. Same declared posture, "+
		"two different carried figures, from two engines in one repository. The policy "+
		"engine used a *float64 precisely to avoid this; see its comment at "+
		"compliance.go:57-60.", thisEngine)
}

// validInputsForZeroTest returns an Inputs that passes Validate, so tests can
// vary one field at a time without fighting unrelated validation.
//
// Built from the engine's own ordering rules (min <= mode <= max, vulnerability
// a probability) rather than from a fixture, so it stays valid if a fixture
// changes.
func validInputsForZeroTest() Inputs {
	return Inputs{
		TEF:            Triple{Min: 1, Mode: 2, Max: 4},
		Vulnerability:  Triple{Min: 0.1, Mode: 0.3, Max: 0.6},
		PrimaryLoss:    Triple{Min: 1000, Mode: 5000, Max: 20000},
		SecondaryLoss:  Triple{Min: 100, Mode: 500, Max: 2000},
		Trials:         DefaultTrials,
		Seed:           DefaultSeed,
		RiskLoad:       DefaultRiskLoad,
		MagnitudeModel: ModelPERT,
	}
}
