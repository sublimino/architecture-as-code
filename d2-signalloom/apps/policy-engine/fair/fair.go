// Package fair implements FAIR (Factor Analysis of Information Risk) quantitative risk analysis
// using beta-PERT distributions and seeded Monte Carlo simulation.
//
// This is the single canonical FAIR implementation for the repository. It serves two callers:
//
//   - the policy-engine service, via Simulate(loss, freq, seed) — one check, one loss scenario;
//   - tools/riskctl, via Engine.Run(contributions, riskLoad) — a whole agent's posture aggregated
//     across scenarios, with graded enforcement, per-control deltas and sensitivity analysis.
//
// Both share the distribution sampling below so the two surfaces can never disagree about a
// number. A second implementation of this maths anywhere in the repo is a defect.
//
// Determinism is a hard requirement, not a nicety: a number nobody can reproduce is not evidence.
// Every draw comes from a single explicitly seeded generator consumed in a fixed order.
package fair

import (
	"fmt"
	"math"
	"math/rand/v2"
	"sort"
)

// iterations is the trial count for the single-scenario Simulate path.
const iterations = 10_000

// DefaultIterations is the trial count for the aggregate Engine path. Large enough that the 95th
// percentile is stable to the pound at demo scale, small enough to run instantly with no cluster.
const DefaultIterations = 200_000

// DefaultSeed pins the aggregate generator. Change it and every number in every report changes;
// that is the point of pinning it here rather than seeding from the clock.
const DefaultSeed int64 = 20260801

// RiskTriple holds beta-PERT parameters: minimum, most likely, and maximum.
type RiskTriple struct {
	Min  float64 `json:"min" yaml:"min"`
	Mode float64 `json:"mode" yaml:"mode"`
	Max  float64 `json:"max" yaml:"max"`
}

// Validate enforces the ordering invariant, non-negativity, and finiteness. An unordered
// triple is a data error, not a judgement call. A non-finite triple is a computation error
// that produces Inf or NaN loss figures if carried into the simulation.
func (t RiskTriple) Validate(context string) error {
	if math.IsNaN(t.Min) || math.IsInf(t.Min, 0) ||
		math.IsNaN(t.Mode) || math.IsInf(t.Mode, 0) ||
		math.IsNaN(t.Max) || math.IsInf(t.Max, 0) {
		return fmt.Errorf("%s: triple values must be finite, got (%g, %g, %g)",
			context, t.Min, t.Mode, t.Max)
	}
	if t.Min < 0 {
		return fmt.Errorf("%s: min must be >= 0, got %g", context, t.Min)
	}
	if !(t.Min <= t.Mode && t.Mode <= t.Max) {
		return fmt.Errorf("%s: triple must satisfy min <= mode <= max, got (%g, %g, %g)",
			context, t.Min, t.Mode, t.Max)
	}
	return nil
}

// RiskResult holds the output of a single-scenario FAIR Monte Carlo simulation.
type RiskResult struct {
	ALE        float64 `json:"ale"`        // mean annual loss expectancy
	VaR95      float64 `json:"var95"`      // 95th percentile (bad year)
	TVaR       float64 `json:"tvar"`       // mean beyond VaR95 (tail risk)
	CarriedGBP float64 `json:"carriedGbp"` // TVaR plus the risk load

	// TailDominated reports that VaR95 sits below ALE: most simulated years cost nothing and the
	// entire expected loss lives in the tail.
	//
	// This is a risk-financing signal, not an error. Of the four moves — avoid, reduce, transfer,
	// retain — a tail-dominated residual is the regime where TRANSFER (insurance) starts to beat
	// further control spend, because you are no longer buying down a frequency anyone can feel.
	// It is exactly the shape an underwriter prices.
	TailDominated bool `json:"tailDominated"`

	// Guards counts defensive substitutions made during this run. Non-zero means at least one
	// value was fabricated rather than sampled -- see guards.go. Additive: it changes no figure.
	Guards Guards `json:"guards"`
}

// Simulate runs a seeded Monte Carlo simulation combining loss magnitude and event frequency
// beta-PERT distributions. The result is deterministic for a given seed.
//
// NOTE ON A CORRECTED SELF-CHECK. An earlier revision ended by clamping its own output:
//
//	if tvar < var95 { tvar = var95 }
//	if var95 < ale  { var95 = ale  }   // <- this one fabricated numbers
//
// The second clamp enforced `VaR95 >= ALE`, which is NOT a property of loss distributions. For a
// low-frequency/high-severity risk the great majority of simulated years cost nothing, so the 95th
// percentile sits at or near zero while the mean stays positive. The clamp then silently reported
// a "bad year" equal to the average year — a fabricated figure, with no error and no flag, in
// precisely the well-governed case a client most wants to see. The inversion is now surfaced via
// TailDominated instead. See regression_test.go.
func Simulate(loss, freq RiskTriple, seed uint64) RiskResult {
	return SimulateWithLoad(loss, freq, seed, 0.10)
}

// SimulateWithLoad is Simulate with an explicit risk load. Never charge the mean; the load belongs
// to the institution (its risk posture), not to the engine.
func SimulateWithLoad(loss, freq RiskTriple, seed uint64, riskLoad float64) RiskResult {
	// Edge case: zero frequency means zero risk.
	if freq.Min == 0 && freq.Mode == 0 && freq.Max == 0 {
		return RiskResult{}
	}

	rng := rand.New(rand.NewPCG(seed, seed^0xdeadbeef))
	g := &Guards{}

	annualLosses := make([]float64, iterations)
	for i := range iterations {
		f := samplePERTCounted(rng, freq, g)
		if f < 0 {
			f = 0
		}
		l := samplePERTCounted(rng, loss, g)
		if l < 0 {
			l = 0
		}
		annualLosses[i] = f * l
	}

	sort.Float64s(annualLosses)

	ale := mean(annualLosses)
	var95 := percentile(annualLosses, 0.95)

	idx95 := int(math.Ceil(0.95*float64(iterations))) - 1
	if idx95 < 0 {
		idx95 = 0
	}
	tvar := mean(annualLosses[idx95:])

	// TVaR >= VaR95 is a genuine identity (a tail mean cannot sit below its own threshold) and
	// TVaR >= ALE is a genuine identity. Floating point can nudge them by an ulp; correcting that
	// is legitimate. Clamping VaR95 up to ALE is not, and is deliberately absent.
	if tvar < var95 {
		tvar = var95
	}
	if tvar < ale {
		tvar = ale
	}

	return RiskResult{
		ALE:           ale,
		VaR95:         var95,
		TVaR:          tvar,
		CarriedGBP:    tvar * (1 + riskLoad),
		TailDominated: var95 < ale,
		Guards:        *g,
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Aggregate path — a whole posture across many loss scenarios.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// Contribution is one scenario's input to the aggregate distribution: how often the loss event
// happens (frequency, from the policy pack) and what it costs when it does (magnitude, from the
// institution's risk posture).
type Contribution struct {
	ControlID string
	Scenario  string
	LEF       RiskTriple // effective frequency after posture, enforcement and cage are applied
	Magnitude RiskTriple // loss magnitude at this institution
}

// Result is the aggregate annual-loss distribution reduced to the figures a board reads.
type Result struct {
	Iterations int
	Seed       int64
	ALE        float64 // mean annual loss
	VaR95      float64 // 95th percentile
	TVaR       float64 // mean of the tail beyond VaR95
	Carried    float64 // TVaR with the risk load applied
	RiskLoad   float64

	// Guards counts defensive substitutions made during this run. Non-zero means at least one
	// value was fabricated rather than sampled -- see guards.go. Additive: it changes no figure.
	Guards Guards
}

// SelfCheck asserts the ordering invariants that must hold for any well-formed loss distribution.
// A violation means the simulation is wrong, and a wrong number is worse than no number.
//
// See the note on Simulate: `VaR95 >= ALE` is deliberately NOT asserted, because it is false
// exactly when the estate is well governed.
func (r Result) SelfCheck() error {
	// Non-finite values must be caught first: every IEEE 754 comparison against NaN is false,
	// so NaN silently passes all of the ordering checks below. A NaN or Inf figure is a
	// computation error, not a valid loss distribution.
	for _, pair := range []struct {
		name string
		val  float64
	}{
		{"ALE", r.ALE}, {"VaR95", r.VaR95}, {"TVaR", r.TVaR}, {"Carried", r.Carried},
	} {
		if math.IsNaN(pair.val) || math.IsInf(pair.val, 0) {
			return fmt.Errorf("self-check failed: %s is %g; all figures must be finite", pair.name, pair.val)
		}
	}
	if !(r.TVaR >= r.VaR95) {
		return fmt.Errorf("self-check failed: TVaR (%.2f) < VaR95 (%.2f)", r.TVaR, r.VaR95)
	}
	if !(r.TVaR >= r.ALE) {
		return fmt.Errorf("self-check failed: TVaR (%.2f) < ALE (%.2f)", r.TVaR, r.ALE)
	}
	if r.Carried < r.TVaR {
		return fmt.Errorf("self-check failed: carried (%.2f) < TVaR (%.2f)", r.Carried, r.TVaR)
	}
	if r.ALE < 0 || r.VaR95 < 0 || r.TVaR < 0 {
		return fmt.Errorf("self-check failed: negative loss figure (ALE %.2f, VaR95 %.2f, TVaR %.2f)",
			r.ALE, r.VaR95, r.TVaR)
	}
	return nil
}

// TailDominated reports whether the risk has become rare-but-severe. See RiskResult.TailDominated.
func (r Result) TailDominated() bool { return r.VaR95 < r.ALE }

// Engine runs the aggregate simulation from a fixed seed.
type Engine struct {
	Iterations int
	Seed       int64
}

// NewEngine returns an engine with the pinned defaults.
func NewEngine() *Engine {
	return &Engine{Iterations: DefaultIterations, Seed: DefaultSeed}
}

// Run simulates the aggregate annual loss for the given contributions.
//
// Per iteration, for each contribution:
//
//	lambda ~ betaPERT(LEF)             annual rate of the loss event
//	n      ~ Poisson(lambda)           number of events this simulated year
//	loss   = sum over n of PERT(Mag)   magnitude drawn per event, at THIS institution
//
// Poisson event counts rather than a continuous frequency×magnitude product, because the latter
// cannot produce the zero-loss years that make a well-governed distribution the shape it actually
// is — and those years are the whole point of the tail-dominated signal.
func (e *Engine) Run(contribs []Contribution, riskLoad float64) Result {
	iters := e.Iterations
	if iters <= 0 {
		iters = DefaultIterations
	}
	seed := e.Seed
	if seed == 0 {
		seed = DefaultSeed
	}
	rng := rand.New(rand.NewPCG(uint64(seed), uint64(seed)^0xdeadbeef))
	g := &Guards{}

	losses := make([]float64, iters)
	for i := range iters {
		var total float64
		// Fixed iteration order over the slice — never a map — so draws align run to run.
		for _, c := range contribs {
			lambda := samplePERTCounted(rng, c.LEF, g)
			n := poissonCounted(rng, lambda, g)
			for k := 0; k < n; k++ {
				total += samplePERTCounted(rng, c.Magnitude, g)
			}
		}
		losses[i] = total
	}
	sort.Float64s(losses)

	ale := mean(losses)
	var95 := percentile(losses, 0.95)

	idx := int(math.Floor(0.95 * float64(iters)))
	if idx >= iters {
		idx = iters - 1
	}
	tvar := ale
	if iters-idx > 0 {
		tvar = mean(losses[idx:])
	}
	if tvar < var95 {
		tvar = var95
	}
	if tvar < ale {
		tvar = ale
	}

	return Result{
		Iterations: iters,
		Seed:       seed,
		ALE:        ale,
		VaR95:      var95,
		TVaR:       tvar,
		Carried:    tvar * (1 + riskLoad),
		RiskLoad:   riskLoad,
		Guards:     *g,
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Distribution sampling — shared by both paths.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// percentile returns the value at p in a pre-sorted slice using nearest-rank.
func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(p*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

// samplePERT draws a single sample from a beta-PERT distribution over (min, mode, max), using the
// standard lambda=4 weighting on the mode.
//
// The shape parameters use the direct parameterisation
//
//	alpha = 1 + 4*(mode-min)/(max-min)
//	beta  = 1 + 4*(max-mode)/(max-min)
//
// rather than the mu-based form
//
//	alpha = ((mu-min)*(2*mode-min-max)) / ((mode-mu)*(max-min))
//
// The two are algebraically equivalent, but the mu-based form divides by (mode - mu), and for ANY
// symmetric triple the PERT mean mu equals the mode exactly — so that denominator is zero, alpha
// becomes NaN, and `alpha <= 0` does not catch NaN. The NaN then propagates into gammaVariate
// where `v > 0` is also false for NaN, and the rejection loop never terminates: the process hangs
// rather than returning a bad number. Symmetric triples like (0.1, 0.5, 0.9) are entirely ordinary
// to write by hand, and this package is reachable over HTTP. See regression_test.go.
func samplePERT(rng *rand.Rand, t RiskTriple) float64 {
	return samplePERTCounted(rng, t, nil)
}

// samplePERTCounted is samplePERT with optional guard instrumentation. g may be nil.
//
// The guard branches are UNCHANGED — the only additions are the counter increments. See guards.go
// for why these substitutions are counted rather than removed or promoted to errors.
func samplePERTCounted(rng *rand.Rand, t RiskTriple, g *Guards) float64 {
	span := t.Max - t.Min
	if span <= 0 {
		return t.Min
	}
	alpha := 1 + 4*(t.Mode-t.Min)/span
	beta := 1 + 4*(t.Max-t.Mode)/span
	if alpha <= 0 || math.IsNaN(alpha) {
		alpha = 1
		if g != nil {
			g.ShapeClamped++
		}
	}
	if beta <= 0 || math.IsNaN(beta) {
		beta = 1
		if g != nil {
			g.ShapeClamped++
		}
	}

	x := gammaVariateCounted(rng, alpha, g)
	y := gammaVariateCounted(rng, beta, g)
	if x+y == 0 || math.IsNaN(x) || math.IsNaN(y) {
		if g != nil {
			g.MidpointSubstituted++
		}
		return t.Min + 0.5*span
	}
	return t.Min + span*(x/(x+y))
}

// gammaVariate generates a sample from Gamma(shape, 1) using Marsaglia and Tsang's method for
// shape >= 1, with the Ahrens-Dieter transformation for shape < 1.
//
// Guarded against non-finite shape: the caller should never pass one, but an unbounded rejection
// loop in an HTTP-reachable code path is not an acceptable failure mode.
func gammaVariate(rng *rand.Rand, shape float64) float64 {
	return gammaVariateCounted(rng, shape, nil)
}

// gammaVariateCounted is gammaVariate with optional guard instrumentation. g may be nil.
func gammaVariateCounted(rng *rand.Rand, shape float64, g *Guards) float64 {
	if math.IsNaN(shape) || math.IsInf(shape, 0) || shape <= 0 {
		if g != nil {
			g.GammaNonFinite++
		}
		return 0
	}
	if shape < 1 {
		// Ahrens-Dieter: Gamma(a) = Gamma(a+1) * U^(1/a)
		u := rng.Float64()
		for u == 0 {
			u = rng.Float64()
		}
		return gammaVariateCounted(rng, shape+1, g) * math.Pow(u, 1.0/shape)
	}

	d := shape - 1.0/3.0
	c := 1.0 / math.Sqrt(9.0*d)

	for {
		var x, v float64
		for {
			x = rng.NormFloat64()
			v = 1.0 + c*x
			if v > 0 {
				break
			}
		}
		v = v * v * v
		u := rng.Float64()

		if u < 1.0-0.0331*(x*x)*(x*x) {
			return d * v
		}
		if math.Log(u) < 0.5*x*x+d*(1.0-v+math.Log(v)) {
			return d * v
		}
	}
}

// poisson draws the number of loss events in a simulated year given rate lambda, using Knuth's
// method for small lambda and a normal approximation above the threshold where Knuth's loop
// becomes expensive.
func poisson(rng *rand.Rand, lambda float64) int {
	return poissonCounted(rng, lambda, nil)
}

// poissonCounted is poisson with optional guard instrumentation. g may be nil.
//
// Note the lambda <= 0 case is NOT counted: "no rate means no events" is correct semantics, not a
// substitution. Only the loop cap fabricates a value.
func poissonCounted(rng *rand.Rand, lambda float64, g *Guards) int {
	if lambda <= 0 || math.IsNaN(lambda) || math.IsInf(lambda, 0) {
		return 0
	}
	if lambda < 30 {
		l := math.Exp(-lambda)
		k := 0
		p := 1.0
		for {
			p *= rng.Float64()
			if p <= l {
				return k
			}
			k++
			if k > 1000 {
				if g != nil {
					g.PoissonLoopCapped++
				}
				return k
			}
		}
	}
	n := int(math.Round(rng.NormFloat64()*math.Sqrt(lambda) + lambda))
	if n < 0 {
		return 0
	}
	return n
}

func mean(vals []float64) float64 {
	if len(vals) == 0 {
		return 0
	}
	sum := 0.0
	for _, v := range vals {
		sum += v
	}
	return sum / float64(len(vals))
}
