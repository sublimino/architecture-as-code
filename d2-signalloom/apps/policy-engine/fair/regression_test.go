package fair

import (
	"math"
	"math/rand/v2"
	"testing"
)

// These two tests were written to REPRODUCE defects found while converging the two FAIR
// implementations in this repository. They are kept as regression tests.

// Defect 1 — symmetric triples divide by zero.
//
// samplePERT computes alpha via (mu - min)*(2*mode - min - max) / ((mode - mu)*(max - min)).
// For any symmetric triple the PERT mean mu equals the mode exactly, so (mode - mu) is 0 and
// alpha becomes +Inf. The `alpha <= 0` guard does not catch +Inf, so the Inf propagates into
// gammaVariate and the sample comes back NaN.
//
// Symmetric triples are not exotic — (0.1, 0.5, 0.9) is the sort of thing anyone writes by hand.
func TestSamplePERTHandlesSymmetricTriple(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	tri := RiskTriple{Min: 0, Mode: 5, Max: 10} // mu = (0 + 4*5 + 10)/6 = 5 = mode

	for i := 0; i < 200; i++ {
		got := samplePERT(rng, tri)
		if math.IsNaN(got) || math.IsInf(got, 0) {
			t.Fatalf("symmetric triple produced non-finite sample %v on iteration %d", got, i)
		}
		if got < tri.Min || got > tri.Max {
			t.Fatalf("sample %v outside [%v, %v]", got, tri.Min, tri.Max)
		}
	}
}

// Defect 2 — Simulate silently rewrites its own output to satisfy a false invariant.
//
// The original implementation ended with:
//
//	if tvar < var95 { tvar = var95 }
//	if var95 < ale  { var95 = ale  }
//
// The second clamp is the dangerous one. VaR95 >= ALE is NOT a property of loss distributions.
// For a low-frequency/high-severity risk the great majority of simulated years cost nothing, so
// the 95th percentile sits at (or near) zero while the mean stays positive. Clamping then reports
// a "bad year" figure equal to the average year — a fabricated number, silently, with no error and
// no flag, in exactly the well-governed case a client most wants to see.
//
// The number must never be quietly rewritten to fit an assumption. Report it and explain it.
func TestSimulateDoesNotFabricateVaR95(t *testing.T) {
	// A rare, severe risk: ~0.02 events/year, £1m-£9m per event.
	freq := RiskTriple{Min: 0.001, Mode: 0.02, Max: 0.08}
	loss := RiskTriple{Min: 1_000_000, Mode: 3_000_000, Max: 9_000_000}

	got := Simulate(loss, freq, 42)

	if got.ALE <= 0 {
		t.Fatalf("expected a positive ALE for a rare severe risk, got %v", got.ALE)
	}
	// TVaR >= VaR95 is a genuine identity and must hold.
	if got.TVaR < got.VaR95 {
		t.Fatalf("TVaR (%v) below VaR95 (%v)", got.TVaR, got.VaR95)
	}
	// TVaR >= ALE is a genuine identity and must hold.
	if got.TVaR < got.ALE {
		t.Fatalf("TVaR (%v) below ALE (%v)", got.TVaR, got.ALE)
	}
	// The clamp's fingerprint: when the true VaR95 is below ALE the old code assigned
	// var95 = ale, producing an exact float equality that essentially never occurs naturally
	// between a percentile and a mean. If these are bit-identical, the number was fabricated.
	if got.VaR95 == got.ALE && got.ALE != 0 {
		t.Fatalf("VaR95 (%v) is bit-identical to ALE — the value was clamped, not computed. "+
			"A percentile that equals the mean exactly is a fabricated figure.", got.VaR95)
	}

	// The engine must expose the inversion rather than clamp it away.
	if got.TailDominated != (got.VaR95 < got.ALE) {
		t.Fatalf("TailDominated (%v) disagrees with VaR95 (%v) < ALE (%v)",
			got.TailDominated, got.VaR95, got.ALE)
	}
}

// Determinism is the contract the whole reporting story rests on.
func TestSimulateIsDeterministic(t *testing.T) {
	loss := RiskTriple{Min: 20_000, Mode: 90_000, Max: 500_000}
	freq := RiskTriple{Min: 0.2, Mode: 0.8, Max: 2.5}

	a := Simulate(loss, freq, 20260801)
	b := Simulate(loss, freq, 20260801)
	if a != b {
		t.Fatalf("Simulate not deterministic:\n first=%+v\nsecond=%+v", a, b)
	}

	c := Simulate(loss, freq, 20260802)
	if c.ALE == a.ALE {
		t.Fatalf("seed appears unused: seeds 20260801 and 20260802 both produced ALE %v", a.ALE)
	}
}
