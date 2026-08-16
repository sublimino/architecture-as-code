package fair

// Adversarial tests for the FAIR engine.
//
// These target numeric edge cases and validation gaps that the existing suite does not exercise.

import (
	"math"
	"math/rand/v2"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────────────────────
// RiskTriple validation gaps.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestRiskTripleValidateRejectsInfinity demonstrates that a triple with +Inf in Max passes
// validation, even though the resulting PERT sampling produces Inf loss figures.
//
// THE DEFECT. Validate checks `t.Min < 0` (which is false for 0) and
// `!(t.Min <= t.Mode && t.Mode <= t.Max)` (which is true when the ordering holds).
// Since 5 <= +Inf is true, the triple (0, 5, +Inf) passes validation. But samplePERT
// with Max=+Inf computes span=+Inf, alpha=1+4*(5-0)/Inf=1, beta=1+4*(Inf-5)/Inf=NaN
// (because Inf/Inf=NaN), the guard clamps beta to 1, and the return is Min+span*(...)=Inf.
//
// That Inf propagates into the loss figure, through the sort, into ALE/VaR95/TVaR — all Inf
// or NaN, with no error returned.
func TestRiskTripleValidateRejectsInfinity(t *testing.T) {
	for _, tc := range []struct {
		name   string
		triple RiskTriple
	}{
		{"Max=+Inf", RiskTriple{Min: 0, Mode: 5, Max: math.Inf(1)}},
		{"Mode=+Inf", RiskTriple{Min: 0, Mode: math.Inf(1), Max: math.Inf(1)}},
		{"Min=+Inf", RiskTriple{Min: math.Inf(1), Mode: math.Inf(1), Max: math.Inf(1)}},
		{"Max=-Inf", RiskTriple{Min: math.Inf(-1), Mode: 0, Max: 5}},
		{"Min=NaN", RiskTriple{Min: math.NaN(), Mode: 5, Max: 10}},
		{"Mode=NaN", RiskTriple{Min: 0, Mode: math.NaN(), Max: 10}},
		{"Max=NaN", RiskTriple{Min: 0, Mode: 5, Max: math.NaN()}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.triple.Validate("test")
			if err == nil {
				t.Errorf("RiskTriple%v.Validate() = nil; a triple with a non-finite value must "+
					"be rejected at validation, not carried into the simulation where it produces "+
					"Inf or NaN loss figures with no error returned", tc.triple)
			}
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Result.SelfCheck gaps.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestSelfCheckCatchesNaN demonstrates that Result.SelfCheck does not detect NaN values.
//
// THE DEFECT. Every SelfCheck comparison uses >=, <, etc. All of these are false when either
// operand is NaN. So a result with ALE=NaN passes every check:
//   !(NaN >= NaN) → !(false) → true... but wait, the check is `if !(r.TVaR >= r.VaR95)`.
//   Actually if TVaR=NaN, VaR95=NaN: !(NaN >= NaN) → !(false) → true, so it DOES error.
//   But if only ALE=NaN and TVaR/VaR95 are finite: every check involving ALE uses `r.ALE < 0`
//   which is false for NaN, so the negativity check passes. And `r.TVaR >= r.ALE` is
//   !(NaN >= finite) → !(false) which would fail... actually let me trace through.
//
// For ALE=NaN, VaR95=0, TVaR=0, Carried=0:
//   !(TVaR >= VaR95) → !(0 >= 0) → false → no error
//   !(TVaR >= ALE) → !(0 >= NaN) → !(false) → true → ERROR "TVaR < ALE"
//
// OK so SelfCheck does catch some NaN cases through the ordering comparisons. But the
// negativity check at the end uses `r.ALE < 0` which is false for NaN, so that check is
// bypassed.
//
// A more direct test: if Carried=NaN but everything else is zero:
//   !(TVaR >= VaR95) → !(0 >= 0) → false → pass
//   !(TVaR >= ALE) → !(0 >= 0) → false → pass
//   Carried < TVaR → NaN < 0 → false → pass
//   ALE < 0 → false, VaR95 < 0 → false, TVaR < 0 → false → pass
// So Carried=NaN passes SelfCheck completely silently.
func TestSelfCheckCatchesNaN(t *testing.T) {
	for _, tc := range []struct {
		name string
		r    Result
	}{
		{"Carried=NaN", Result{ALE: 0, VaR95: 0, TVaR: 0, Carried: math.NaN(), RiskLoad: 0.1}},
		{"ALE=NaN", Result{ALE: math.NaN(), VaR95: 0, TVaR: 0, Carried: 0, RiskLoad: 0.1}},
		{"VaR95=NaN", Result{ALE: 0, VaR95: math.NaN(), TVaR: 0, Carried: 0, RiskLoad: 0.1}},
		{"TVaR=NaN", Result{ALE: 0, VaR95: 0, TVaR: math.NaN(), Carried: 0, RiskLoad: 0.1}},
		{"all NaN", Result{ALE: math.NaN(), VaR95: math.NaN(), TVaR: math.NaN(), Carried: math.NaN()}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.r.SelfCheck()
			if err == nil {
				t.Errorf("Result%+v.SelfCheck() = nil; a NaN result must be caught as a self-check "+
					"failure, not silently passed as a valid loss distribution", tc.r)
			}
		})
	}
}

// TestSelfCheckCatchesInf verifies that Inf values in results are caught.
func TestSelfCheckCatchesInf(t *testing.T) {
	for _, tc := range []struct {
		name string
		r    Result
	}{
		{"ALE=+Inf", Result{ALE: math.Inf(1), VaR95: 0, TVaR: math.Inf(1), Carried: math.Inf(1)}},
		{"Carried=+Inf", Result{ALE: 0, VaR95: 0, TVaR: 0, Carried: math.Inf(1)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.r.SelfCheck()
			if err == nil {
				t.Errorf("Result%+v.SelfCheck() = nil; an Inf result must be caught as a self-check "+
					"failure", tc.r)
			}
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Poisson with extreme lambda.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestPoissonWithInfLambda demonstrates that poissonCounted with +Inf lambda produces a
// dangerous value. Lambda = +Inf bypasses the `lambda <= 0` and `IsNaN` guards and enters
// the normal approximation path where NormFloat64*Sqrt(+Inf) + Inf can produce MaxInt-scale
// event counts, causing the inner loop of Engine.Run to iterate for ages.
func TestPoissonWithInfLambda(t *testing.T) {
	rng := newTestRNG()
	n := poissonCounted(rng, math.Inf(1), nil)
	// +Inf lambda should return 0 (no events), not a huge number that causes a hang.
	if n > 1000 {
		t.Errorf("poisson(+Inf) = %d; an infinite rate should be clamped to 0 events or "+
			"a safe maximum, not %d which would cause the simulation inner loop to hang", n, n)
	}
}

// TestPoissonWithNegInfLambda is already handled (lambda <= 0 returns 0), but verify.
func TestPoissonWithNegInfLambda(t *testing.T) {
	rng := newTestRNG()
	n := poissonCounted(rng, math.Inf(-1), nil)
	if n != 0 {
		t.Errorf("poisson(-Inf) = %d, want 0", n)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Guards instrumentation edge cases.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestGuardsExplainIsEmptyWhenNothingFired ensures no false positives in the guard report.
func TestGuardsExplainIsEmptyWhenNothingFired(t *testing.T) {
	g := Guards{}
	if got := g.Explain(); got != "" {
		t.Errorf("Guards{}.Explain() = %q, want empty string", got)
	}
	if g.Fired() {
		t.Error("Guards{}.Fired() = true, want false")
	}
	if g.Total() != 0 {
		t.Errorf("Guards{}.Total() = %d, want 0", g.Total())
	}
}

// TestGuardsAddIsCommutative checks that guard accumulation is order-independent.
func TestGuardsAddIsCommutative(t *testing.T) {
	a := Guards{ShapeClamped: 2, PoissonLoopCapped: 1}
	b := Guards{MidpointSubstituted: 3, GammaNonFinite: 1}

	ab := Guards{}
	ab.Add(a)
	ab.Add(b)

	ba := Guards{}
	ba.Add(b)
	ba.Add(a)

	if ab != ba {
		t.Errorf("Guard accumulation is not commutative: a+b=%+v, b+a=%+v", ab, ba)
	}
	if ab.Total() != 7 {
		t.Errorf("Total = %d, want 7", ab.Total())
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Zero-frequency edge case.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestSimulateZeroFrequencyIsZeroRisk verifies the fast path.
func TestSimulateZeroFrequencyIsZeroRisk(t *testing.T) {
	loss := RiskTriple{Min: 1000, Mode: 5000, Max: 10000}
	freq := RiskTriple{Min: 0, Mode: 0, Max: 0}
	result := Simulate(loss, freq, 42)
	if result.ALE != 0 || result.VaR95 != 0 || result.TVaR != 0 || result.CarriedGBP != 0 {
		t.Errorf("zero frequency should produce zero risk, got ALE=%g VaR95=%g TVaR=%g Carried=%g",
			result.ALE, result.VaR95, result.TVaR, result.CarriedGBP)
	}
}

// TestEngineRunEmptyContributions checks that no contributions produces a zero result.
func TestEngineRunEmptyContributions(t *testing.T) {
	e := NewEngine()
	r := e.Run(nil, 0.10)
	if r.ALE != 0 || r.VaR95 != 0 || r.TVaR != 0 {
		t.Errorf("empty contributions should produce zero risk, got %+v", r)
	}
}

// TestEngineRunNegativeRiskLoadIsCaught checks that a negative risk load is handled.
func TestEngineRunNegativeRiskLoad(t *testing.T) {
	e := NewEngine()
	contribs := []Contribution{{
		ControlID: "test",
		Scenario:  "test",
		LEF:       RiskTriple{Min: 0.1, Mode: 0.5, Max: 1.0},
		Magnitude: RiskTriple{Min: 1000, Mode: 5000, Max: 10000},
	}}
	r := e.Run(contribs, -0.5)
	// A negative risk load means Carried < TVaR, which violates SelfCheck.
	if err := r.SelfCheck(); err == nil && r.Carried < r.TVaR {
		t.Errorf("negative risk load produced Carried (%g) < TVaR (%g) but SelfCheck passed",
			r.Carried, r.TVaR)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Determinism.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestSimulateDeterminism verifies that the same inputs always produce the same output.
func TestSimulateDeterminism(t *testing.T) {
	loss := RiskTriple{Min: 5000, Mode: 25000, Max: 100000}
	freq := RiskTriple{Min: 0.1, Mode: 0.5, Max: 2.0}
	a := Simulate(loss, freq, 12345)
	b := Simulate(loss, freq, 12345)
	if a != b {
		t.Errorf("Simulate is not deterministic: first=%+v, second=%+v", a, b)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Helper.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func newTestRNG() *rand.Rand {
	return rand.New(rand.NewPCG(42, 42^0xdeadbeef))
}
