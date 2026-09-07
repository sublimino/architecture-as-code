package fair

import (
	"math"
	"sort"
	"testing"
)

// distContribs is the fixture used to pin the refactor. Two contributions rather than one, because
// a single contribution cannot catch a change in the order the generator is consumed across the
// contribution loop — and that ordering is the whole determinism guarantee.
func distContribs() []Contribution {
	return []Contribution{
		{ControlID: "c1", Scenario: "s1", LEF: RiskTriple{Min: 0.1, Mode: 0.5, Max: 2.0}, Magnitude: RiskTriple{Min: 1000, Mode: 50000, Max: 900000}},
		{ControlID: "c2", Scenario: "s2", LEF: RiskTriple{Min: 0.01, Mode: 0.2, Max: 1.0}, Magnitude: RiskTriple{Min: 5000, Mode: 200000, Max: 4000000}},
	}
}

// TestRunDistributionPreservesRunFigures pins the values Run produced BEFORE RunDistribution was
// extracted from it (CRKC-P2-1). These constants were captured from the pre-refactor binary and
// pasted here; if the extraction had perturbed the generator by so much as one draw, every one of
// them would move.
//
// This is deliberately a pinned-constant test and not a "Run equals RunDistribution" test. The
// latter would pass trivially after the refactor no matter what the refactor did to the numbers,
// because both sides would be the same new code. Only a value captured from the old code can
// falsify "the extraction changed nothing".
func TestRunDistributionPreservesRunFigures(t *testing.T) {
	e := NewEngine()
	e.Iterations = 20000

	const (
		wantALE     = 365687.3900429519
		wantVaR95   = 1655486.6769162337
		wantTVaR    = 2338901.3919162997
		wantCarried = 2689736.6007037447
	)

	got := e.Run(distContribs(), 0.15)

	for _, c := range []struct {
		name      string
		got, want float64
	}{
		{"ALE", got.ALE, wantALE},
		{"VaR95", got.VaR95, wantVaR95},
		{"TVaR", got.TVaR, wantTVaR},
		{"Carried", got.Carried, wantCarried},
	} {
		if math.Abs(c.got-c.want) > 1e-6 {
			t.Errorf("%s changed across the RunDistribution extraction: got %.10f, pre-refactor value was %.10f",
				c.name, c.got, c.want)
		}
	}
}

// TestRunDelegatesToRunDistribution asserts the two entry points cannot drift apart. It is weaker
// than the pinned test above and exists for a different reason: to fail if someone later gives Run
// its own loop again.
func TestRunDelegatesToRunDistribution(t *testing.T) {
	e := NewEngine()
	e.Iterations = 5000

	viaRun := e.Run(distContribs(), 0.1)
	viaDist, _ := e.RunDistribution(distContribs(), 0.1)

	if viaRun != viaDist {
		t.Fatalf("Run and RunDistribution disagree:\n  Run  = %+v\n  Dist = %+v", viaRun, viaDist)
	}
}

// TestRunDistributionSampleShape covers the contract the new return value makes: exactly Iterations
// elements, sorted ascending, all finite.
func TestRunDistributionSampleShape(t *testing.T) {
	e := NewEngine()
	e.Iterations = 4096

	res, losses := e.RunDistribution(distContribs(), 0.1)

	if len(losses) != e.Iterations {
		t.Fatalf("sample length: got %d, want %d", len(losses), e.Iterations)
	}
	if !sort.Float64sAreSorted(losses) {
		t.Error("sample is not sorted ascending; percentile extraction would be wrong")
	}
	for i, v := range losses {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			t.Fatalf("sample[%d] is non-finite (%g)", i, v)
		}
		if v < 0 {
			t.Fatalf("sample[%d] is negative (%g); a loss cannot be negative", i, v)
		}
	}

	// The headline VaR95 must be reproducible from the returned sample using the exported helper.
	// If these disagree, a caller deriving p50/p90/p99 would be using a different convention from
	// the p95 printed beside them.
	if fromSample := Percentile(losses, 0.95); fromSample != res.VaR95 {
		t.Errorf("Percentile(sample, 0.95) = %.10f but Result.VaR95 = %.10f", fromSample, res.VaR95)
	}
}

// TestPercentileIsMonotonic guards the exported helper directly.
func TestPercentileIsMonotonic(t *testing.T) {
	e := NewEngine()
	e.Iterations = 4096
	_, losses := e.RunDistribution(distContribs(), 0.1)

	prev := math.Inf(-1)
	for _, p := range []float64{0.05, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99, 1.0} {
		v := Percentile(losses, p)
		if v < prev {
			t.Errorf("percentile is not monotonic: p=%g gave %.4f after %.4f", p, v, prev)
		}
		prev = v
	}
}

// TestPercentileEmptySample: an empty sample must return zero rather than panic on index -1.
func TestPercentileEmptySample(t *testing.T) {
	if got := Percentile(nil, 0.95); got != 0 {
		t.Errorf("Percentile(nil, 0.95) = %g, want 0", got)
	}
}
