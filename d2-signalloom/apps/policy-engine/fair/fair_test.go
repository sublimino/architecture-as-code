package fair

import (
	"math"
	"testing"
)

func TestBetaPERT_Deterministic(t *testing.T) {
	triple := RiskTriple{Min: 10_000, Mode: 50_000, Max: 200_000}
	r1 := Simulate(triple, triple, 42)
	r2 := Simulate(triple, triple, 42)

	if r1 != r2 {
		t.Fatalf("same seed must produce identical results:\n  r1=%+v\n  r2=%+v", r1, r2)
	}
}

func TestSelfCheck_Ordering(t *testing.T) {
	loss := RiskTriple{Min: 10_000, Mode: 50_000, Max: 200_000}
	freq := RiskTriple{Min: 0.5, Mode: 2.0, Max: 5.0}
	r := Simulate(loss, freq, 99)

	if r.ALE <= 0 {
		t.Fatalf("ALE must be positive, got %f", r.ALE)
	}
	if r.VaR95 < r.ALE {
		t.Fatalf("VaR95 (%f) must be >= ALE (%f)", r.VaR95, r.ALE)
	}
	if r.TVaR < r.VaR95 {
		t.Fatalf("TVaR (%f) must be >= VaR95 (%f)", r.TVaR, r.VaR95)
	}
	if r.CarriedGBP < r.TVaR {
		t.Fatalf("CarriedGBP (%f) must be >= TVaR (%f)", r.CarriedGBP, r.TVaR)
	}
}

func TestCarriedGBP_RiskLoad(t *testing.T) {
	loss := RiskTriple{Min: 10_000, Mode: 50_000, Max: 200_000}
	freq := RiskTriple{Min: 0.5, Mode: 2.0, Max: 5.0}
	r := Simulate(loss, freq, 1)

	expected := r.TVaR * 1.10
	if math.Abs(r.CarriedGBP-expected) > 0.01 {
		t.Fatalf("CarriedGBP should be TVaR + 10%% risk load: got %f, expected %f", r.CarriedGBP, expected)
	}
}

func TestSimulate_DifferentSeeds(t *testing.T) {
	loss := RiskTriple{Min: 10_000, Mode: 50_000, Max: 200_000}
	freq := RiskTriple{Min: 0.5, Mode: 2.0, Max: 5.0}
	r1 := Simulate(loss, freq, 1)
	r2 := Simulate(loss, freq, 2)

	// Different seeds should (almost certainly) produce different results
	if r1.ALE == r2.ALE && r1.VaR95 == r2.VaR95 {
		t.Fatal("different seeds produced identical results — suspicious")
	}
}

func TestSimulate_ZeroFrequency(t *testing.T) {
	loss := RiskTriple{Min: 10_000, Mode: 50_000, Max: 200_000}
	freq := RiskTriple{Min: 0, Mode: 0, Max: 0}
	r := Simulate(loss, freq, 1)

	if r.ALE != 0 {
		t.Fatalf("zero frequency should produce zero ALE, got %f", r.ALE)
	}
}

func TestSimulate_IterationCount(t *testing.T) {
	// The default is 10,000 iterations; just verify the function completes
	// and produces sane results for a realistic input.
	loss := RiskTriple{Min: 5_000, Mode: 25_000, Max: 100_000}
	freq := RiskTriple{Min: 1, Mode: 3, Max: 8}
	r := Simulate(loss, freq, 7)

	if r.ALE <= 0 || r.VaR95 <= 0 || r.TVaR <= 0 || r.CarriedGBP <= 0 {
		t.Fatalf("all risk metrics should be positive for realistic input: %+v", r)
	}
}
