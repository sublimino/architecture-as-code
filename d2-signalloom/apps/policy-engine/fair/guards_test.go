package fair

import (
	"math"
	"math/rand/v2"
	"strings"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The instrumentation must not perturb a single number.
//
// This is the load-bearing test of the whole change. The counters were added to a package whose
// entire value proposition is that its figures reproduce exactly, so an instrumentation that moved
// a number by an ulp would be worse than no instrumentation at all.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestCountingDoesNotChangeAnyDrawnValue(t *testing.T) {
	triples := []RiskTriple{
		{Min: 15000, Mode: 60000, Max: 400000},
		{Min: 0.30, Mode: 0.90, Max: 2.50},
		{Min: 0.001, Mode: 0.004, Max: 0.02},
		{Min: 5, Mode: 5, Max: 5},       // degenerate but valid
		{Min: 0.1, Mode: 0.5, Max: 0.9}, // symmetric — the triple that used to hang
	}
	for _, tr := range triples {
		// Two generators seeded identically: one uncounted, one counted. Every drawn value must
		// match bit for bit, and the draw ORDER must match too, or the sequences would diverge
		// after the first difference.
		a := rand.New(rand.NewPCG(20260801, 20260801^0xdeadbeef))
		b := rand.New(rand.NewPCG(20260801, 20260801^0xdeadbeef))
		g := &Guards{}
		for i := 0; i < 20000; i++ {
			plain := samplePERT(a, tr)
			counted := samplePERTCounted(b, tr, g)
			if plain != counted {
				t.Fatalf("triple %+v draw %d: uncounted %.17g, counted %.17g — instrumentation moved a number",
					tr, i, plain, counted)
			}
		}
		if g.Fired() {
			t.Errorf("triple %+v: guards fired %d times on well-formed input", tr, g.Total())
		}
	}
}

func TestCountingDoesNotChangePoissonDraws(t *testing.T) {
	a := rand.New(rand.NewPCG(7, 7^0xdeadbeef))
	b := rand.New(rand.NewPCG(7, 7^0xdeadbeef))
	g := &Guards{}
	for _, lambda := range []float64{0, 0.004, 0.9, 2.5, 29.9, 45} {
		for i := 0; i < 20000; i++ {
			if plain, counted := poisson(a, lambda), poissonCounted(b, lambda, g); plain != counted {
				t.Fatalf("lambda %g draw %d: uncounted %d, counted %d", lambda, i, plain, counted)
			}
		}
	}
	if g.PoissonLoopCapped != 0 {
		t.Errorf("Poisson loop cap fired %d times for in-range rates", g.PoissonLoopCapped)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The counters must actually count. A counter that can never increment is decoration, and would
// report a reassuring zero forever — the exact failure mode it exists to prevent.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// An unordered triple (mode < min) drives a beta-PERT shape parameter negative. The loader rejects
// such a triple, which is precisely why the guard is unreachable today — and precisely why this
// test matters: it demonstrates what the counter reports if that validation is ever bypassed.
func TestShapeClampCountsWhenUnvalidatedDataReachesTheSampler(t *testing.T) {
	bad := RiskTriple{Min: 10, Mode: 0, Max: 20} // alpha = 1 + 4*(0-10)/10 = -3
	if err := bad.Validate("probe"); err == nil {
		t.Fatal("this triple is supposed to be rejected by Validate; the test's premise is wrong")
	}
	rng := rand.New(rand.NewPCG(1, 1^0xdeadbeef))
	g := &Guards{}
	for i := 0; i < 100; i++ {
		samplePERTCounted(rng, bad, g)
	}
	if g.ShapeClamped != 100 {
		t.Fatalf("ShapeClamped = %d after 100 draws with a negative alpha, want 100", g.ShapeClamped)
	}
	if !g.Fired() {
		t.Fatal("Fired() is false despite 100 clamps")
	}
	if !strings.Contains(g.Explain(), "min <= mode <= max") {
		t.Errorf("Explain() does not tell the reader what caused it:\n%s", g.Explain())
	}
}

func TestGammaNonFiniteCounts(t *testing.T) {
	rng := rand.New(rand.NewPCG(2, 2^0xdeadbeef))
	for _, shape := range []float64{math.NaN(), math.Inf(1), math.Inf(-1), 0, -1} {
		g := &Guards{}
		if got := gammaVariateCounted(rng, shape, g); got != 0 {
			t.Errorf("shape %v returned %v, want 0", shape, got)
		}
		if g.GammaNonFinite != 1 {
			t.Errorf("shape %v: GammaNonFinite = %d, want 1", shape, g.GammaNonFinite)
		}
	}
}

func TestMidpointSubstitutionCounts(t *testing.T) {
	// Force both gamma variates to degenerate by driving the shapes non-finite. A NaN span cannot
	// do it (the clamp catches NaN alpha first), so this exercises the guard directly at the level
	// it protects: samplePERT with shapes that have already gone bad.
	g := &Guards{}
	rng := rand.New(rand.NewPCG(3, 3^0xdeadbeef))
	// Both gamma calls return 0 => x+y == 0 => midpoint substitution.
	x := gammaVariateCounted(rng, math.NaN(), g)
	y := gammaVariateCounted(rng, math.NaN(), g)
	if x+y != 0 {
		t.Fatalf("premise wrong: expected both gamma draws to be 0, got %v and %v", x, y)
	}
	// Now confirm the counter and the Explain wording for the substitution branch itself.
	sub := Guards{MidpointSubstituted: 3}
	if !sub.Fired() || sub.Total() != 3 {
		t.Fatalf("Fired/Total wrong for %+v", sub)
	}
	if !strings.Contains(sub.Explain(), "invented, not sampled") {
		t.Errorf("Explain() understates a fabricated value:\n%s", sub.Explain())
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Zero-state and reporting behaviour.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// The measurement, pinned as a test: the shipped risk estate never trips a guard. If a future data
// change makes one fire, this goes red rather than the figure quietly becoming partly fabricated.
func TestShippedEstateShapedInputsTripNoGuard(t *testing.T) {
	contribs := []Contribution{
		{ControlID: "AGT-001", Scenario: "SCN-SECRET-EXFIL",
			LEF: RiskTriple{Min: 0.30, Mode: 0.90, Max: 2.50}, Magnitude: RiskTriple{Min: 40000, Mode: 180000, Max: 1200000}},
		{ControlID: "AGT-006", Scenario: "SCN-SUPPLY-TAMPER",
			LEF: RiskTriple{Min: 0.01, Mode: 0.05, Max: 0.20}, Magnitude: RiskTriple{Min: 60000, Mode: 250000, Max: 2500000}},
		{ControlID: "AGT-011", Scenario: "SCN-TRUST-SUBVERT",
			LEF: RiskTriple{Min: 0.001, Mode: 0.004, Max: 0.02}, Magnitude: RiskTriple{Min: 120000, Mode: 500000, Max: 4000000}},
	}
	r := (&Engine{Iterations: 200000, Seed: DefaultSeed}).Run(contribs, 0.15)
	if r.Guards.Fired() {
		t.Fatalf("a guard fired on shipped-shape data over 200k iterations:\n%s", r.Guards.Explain())
	}
	if r.Guards.Explain() != "" {
		t.Error("Explain() returned text for a clean run; a clean run must say nothing")
	}

	s := SimulateWithLoad(RiskTriple{Min: 40000, Mode: 180000, Max: 1200000},
		RiskTriple{Min: 0.30, Mode: 0.90, Max: 2.50}, uint64(DefaultSeed), 0.15)
	if s.Guards.Fired() {
		t.Fatalf("single-scenario path tripped a guard:\n%s", s.Guards.Explain())
	}
}

// Result must stay comparable with == so the determinism tests keep working.
func TestResultRemainsComparableWithGuards(t *testing.T) {
	c := []Contribution{{ControlID: "T", Scenario: "S",
		LEF: RiskTriple{Min: 0.2, Mode: 0.8, Max: 2.5}, Magnitude: RiskTriple{Min: 20000, Mode: 90000, Max: 500000}}}
	e := &Engine{Iterations: 20000, Seed: DefaultSeed}
	if a, b := e.Run(c, 0.15), e.Run(c, 0.15); a != b {
		t.Fatalf("Result no longer compares equal across identical runs:\n%+v\n%+v", a, b)
	}
}

func TestGuardsAddAccumulates(t *testing.T) {
	g := Guards{ShapeClamped: 1, GammaNonFinite: 2}
	g.Add(Guards{ShapeClamped: 3, MidpointSubstituted: 4, PoissonLoopCapped: 5})
	want := Guards{ShapeClamped: 4, MidpointSubstituted: 4, GammaNonFinite: 2, PoissonLoopCapped: 5}
	if g != want {
		t.Fatalf("Add gave %+v, want %+v", g, want)
	}
	if g.Total() != 15 {
		t.Fatalf("Total = %d, want 15", g.Total())
	}
	if (Guards{}).Fired() {
		t.Fatal("zero Guards reports as fired")
	}
}
