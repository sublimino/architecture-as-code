package fair

import (
	"math"
	"testing"

	"github.com/acme-co/osramp/tools/riskctl/internal/model"
)

func contribs() []Contribution {
	return []Contribution{
		{
			ControlID: "T-1",
			Scenario:  "SCN-A",
			LEF:       model.Triple{Min: 0.2, Mode: 0.8, Max: 2.5},
			Magnitude: model.Triple{Min: 20000, Mode: 90000, Max: 500000},
		},
		{
			ControlID: "T-2",
			Scenario:  "SCN-B",
			LEF:       model.Triple{Min: 0.05, Mode: 0.2, Max: 0.9},
			Magnitude: model.Triple{Min: 50000, Mode: 250000, Max: 2000000},
		},
	}
}

// The number must be reproducible or it is not evidence. Same seed, same inputs, same pounds.
func TestDeterministicUnderFixedSeed(t *testing.T) {
	e := &Engine{Iterations: 20000, Seed: DefaultSeed}
	a := e.Run(contribs(), 0.15)
	b := e.Run(contribs(), 0.15)

	if a.ALE != b.ALE || a.VaR95 != b.VaR95 || a.TVaR != b.TVaR || a.Carried != b.Carried {
		t.Fatalf("non-deterministic under fixed seed:\n first=%+v\nsecond=%+v", a, b)
	}
}

// A different seed must actually move the number, otherwise the seed is not being consumed and the
// determinism test above is vacuous.
func TestDifferentSeedChangesResult(t *testing.T) {
	a := (&Engine{Iterations: 20000, Seed: 1}).Run(contribs(), 0.15)
	b := (&Engine{Iterations: 20000, Seed: 2}).Run(contribs(), 0.15)
	if a.ALE == b.ALE {
		t.Fatalf("seed appears unused: both seeds produced ALE %.6f", a.ALE)
	}
}

func TestSelfCheckPasses(t *testing.T) {
	r := (&Engine{Iterations: 50000, Seed: DefaultSeed}).Run(contribs(), 0.15)
	if err := r.SelfCheck(); err != nil {
		t.Fatalf("self-check failed on a well-formed distribution: %v", err)
	}
	if r.TVaR < r.VaR95 {
		t.Fatalf("TVaR (%.2f) below VaR95 (%.2f)", r.TVaR, r.VaR95)
	}
	if r.TVaR < r.ALE {
		t.Fatalf("TVaR (%.2f) below ALE (%.2f)", r.TVaR, r.ALE)
	}
}

// The risk load must actually load: never charge the mean.
func TestRiskLoadApplied(t *testing.T) {
	r := (&Engine{Iterations: 20000, Seed: DefaultSeed}).Run(contribs(), 0.25)
	want := r.TVaR * 1.25
	if math.Abs(r.Carried-want) > 1e-6 {
		t.Fatalf("carried = %.6f, want TVaR*1.25 = %.6f", r.Carried, want)
	}
}

// Tightening a control must lower the number. If it does not, the whole thesis is unfalsifiable.
func TestLoweringFrequencyLowersLoss(t *testing.T) {
	base := contribs()
	tight := contribs()
	tight[0].LEF = model.Triple{Min: 0.01, Mode: 0.04, Max: 0.15}

	e := &Engine{Iterations: 50000, Seed: DefaultSeed}
	a := e.Run(base, 0.15)
	b := e.Run(tight, 0.15)

	if !(b.ALE < a.ALE) {
		t.Fatalf("tightening a control did not lower ALE: before %.2f, after %.2f", a.ALE, b.ALE)
	}
}

// A tail-dominated distribution is legitimate, not an error: it is what a well-governed estate
// looks like. Verify the engine reports it rather than failing on it.
func TestTailDominatedIsNotAnError(t *testing.T) {
	rare := []Contribution{{
		ControlID: "T-rare",
		Scenario:  "SCN-RARE",
		LEF:       model.Triple{Min: 0.001, Mode: 0.004, Max: 0.02},
		Magnitude: model.Triple{Min: 500000, Mode: 2000000, Max: 9000000},
	}}
	r := (&Engine{Iterations: 50000, Seed: DefaultSeed}).Run(rare, 0.15)
	if err := r.SelfCheck(); err != nil {
		t.Fatalf("self-check rejected a legitimate rare-but-severe distribution: %v", err)
	}
	if !r.TailDominated() {
		t.Fatalf("expected tail-dominated for a 0.004/yr event, got VaR95 %.2f >= ALE %.2f", r.VaR95, r.ALE)
	}
}

// beta-PERT must respect its bounds and centre near the mode.
func TestPERTBoundsAndCentre(t *testing.T) {
	tr := model.Triple{Min: 10, Mode: 40, Max: 100}
	e := &Engine{Iterations: 1, Seed: 7}
	_ = e
	rng := newTestRNG(7)
	var sum float64
	const n = 100000
	for i := 0; i < n; i++ {
		v := pert(rng, tr)
		if v < tr.Min || v > tr.Max {
			t.Fatalf("PERT sample %.4f outside [%.1f, %.1f]", v, tr.Min, tr.Max)
		}
		sum += v
	}
	mean := sum / n
	// PERT mean = (min + 4*mode + max) / 6 = (10 + 160 + 100)/6 = 45.
	want := (tr.Min + 4*tr.Mode + tr.Max) / 6
	if math.Abs(mean-want) > 1.0 {
		t.Fatalf("PERT mean %.3f, want ~%.3f", mean, want)
	}
}

func TestZeroWidthTripleIsStable(t *testing.T) {
	rng := newTestRNG(3)
	tr := model.Triple{Min: 5, Mode: 5, Max: 5}
	for i := 0; i < 100; i++ {
		if got := pert(rng, tr); got != 5 {
			t.Fatalf("degenerate triple returned %v, want 5", got)
		}
	}
}

func TestPoissonMeanApproximatesLambda(t *testing.T) {
	rng := newTestRNG(11)
	const n = 200000
	lambda := 2.5
	total := 0
	for i := 0; i < n; i++ {
		total += poisson(rng, lambda)
	}
	mean := float64(total) / n
	if math.Abs(mean-lambda) > 0.05 {
		t.Fatalf("Poisson mean %.4f, want ~%.2f", mean, lambda)
	}
}
