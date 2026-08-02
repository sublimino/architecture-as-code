// Package fair implements the Factor Analysis of Information Risk calculation named on stage:
//
//	"Calibrated estimates, a Monte Carlo simulation, and the tail your board actually fears —
//	 the insurance industry's own maths."
//
// Risk = Loss Event Frequency x Loss Magnitude.
//
// Per iteration, for each contributing control:
//
//	lambda ~ betaPERT(lef_triple)            annual rate of the loss event
//	n      ~ Poisson(lambda)                 number of events this simulated year
//	loss   = sum over n of betaPERT(mag)     magnitude drawn per event, at THIS institution
//
// Iteration loss is the sum across controls; the aggregate annual-loss distribution is the sorted
// vector of iteration losses. From it:
//
//	ALE    = mean                 the average year
//	VaR95  = 95th percentile      the bad year
//	TVaR   = mean beyond VaR95    the tail
//	carried = TVaR * (1 + load)   never charge the mean
//
// Determinism is a hard requirement, not a nicety: a number nobody can reproduce is not evidence.
// Every draw comes from a single explicitly seeded generator, consumed in a fixed order.
package fair

import (
	"fmt"
	"math"
	"math/rand"
	"sort"

	"github.com/acme-co/osramp/tools/riskctl/internal/model"
)

// DefaultIterations is the Monte Carlo trial count. Large enough that the 95th percentile is
// stable to the pound at demo scale, small enough to run instantly with no cluster.
const DefaultIterations = 200000

// DefaultSeed fixes the generator. Change it and every number in every report changes; that is the
// point of pinning it here rather than seeding from the clock.
const DefaultSeed int64 = 20260801

// Contribution is one control's input to the aggregate distribution: how often the loss event
// happens (frequency, from the pack) and what it costs when it does (magnitude, from the org).
type Contribution struct {
	ControlID string
	Scenario  string
	LEF       model.Triple // effective frequency after posture, enforcement and cage are applied
	Magnitude model.Triple // loss magnitude at this institution
}

// Result is the aggregate annual-loss distribution reduced to the four figures a board reads.
type Result struct {
	Iterations int
	Seed       int64
	ALE        float64 // mean annual loss
	VaR95      float64 // 95th percentile
	TVaR       float64 // mean of the tail beyond VaR95
	Carried    float64 // TVaR with the risk load applied
	RiskLoad   float64
}

// SelfCheck asserts the ordering invariants that must hold for any well-formed loss distribution.
// A violation means the simulation is wrong, and a wrong number is worse than no number.
//
// Note on what is NOT asserted. It is tempting to require VaR95 >= ALE, and for a dense
// distribution that holds. It does NOT hold in general, and the exception is important rather than
// pathological: once controls are tight enough that more than 5% of simulated years contain no loss
// event at all, the 95th percentile sits at zero while the mean stays positive, carried entirely by
// rare severe years. Asserting VaR95 >= ALE would make the engine fail precisely when the estate is
// well governed. What always holds is TVaR >= VaR95 (a tail mean cannot be below its own threshold)
// and TVaR >= ALE (the mean of the worst 5% cannot be below the mean of all of it).
func (r Result) SelfCheck() error {
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

// TailDominated reports whether the risk has become rare-but-severe: most years cost nothing, and
// the entire expected loss lives in the tail.
//
// This is a risk-financing signal, not a warning. Of the four moves — avoid, reduce, transfer,
// retain — a tail-dominated residual is the regime where TRANSFER (insurance) starts to beat
// further control spend, because you are no longer buying down a frequency you can feel. It is
// exactly the shape an underwriter prices.
func (r Result) TailDominated() bool { return r.VaR95 < r.ALE }

// Engine runs the simulation from a fixed seed.
type Engine struct {
	Iterations int
	Seed       int64
}

// NewEngine returns an engine with the pinned defaults.
func NewEngine() *Engine {
	return &Engine{Iterations: DefaultIterations, Seed: DefaultSeed}
}

// Run simulates the aggregate annual loss for the given contributions.
func (e *Engine) Run(contribs []Contribution, riskLoad float64) Result {
	iters := e.Iterations
	if iters <= 0 {
		iters = DefaultIterations
	}
	// One generator, seeded once, consumed in a fixed order. rand.New(rand.NewSource(seed)) is
	// specified to be reproducible across runs and platforms for a given Go release.
	rng := rand.New(rand.NewSource(e.Seed))

	losses := make([]float64, iters)
	for i := 0; i < iters; i++ {
		var total float64
		// Fixed iteration order over the slice — never a map — so draws align run to run.
		for _, c := range contribs {
			lambda := pert(rng, c.LEF)
			n := poisson(rng, lambda)
			for k := 0; k < n; k++ {
				total += pert(rng, c.Magnitude)
			}
		}
		losses[i] = total
	}
	sort.Float64s(losses)

	var sum float64
	for _, v := range losses {
		sum += v
	}
	ale := sum / float64(iters)

	var95 := percentile(losses, 0.95)

	// TVaR: mean of the losses at or beyond the 95th percentile index.
	idx := int(math.Floor(0.95 * float64(iters)))
	if idx >= iters {
		idx = iters - 1
	}
	var tailSum float64
	tailN := iters - idx
	for _, v := range losses[idx:] {
		tailSum += v
	}
	tvar := ale
	if tailN > 0 {
		tvar = tailSum / float64(tailN)
	}

	return Result{
		Iterations: iters,
		Seed:       e.Seed,
		ALE:        ale,
		VaR95:      var95,
		TVaR:       tvar,
		Carried:    tvar * (1 + riskLoad),
		RiskLoad:   riskLoad,
	}
}

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

// pert draws from a beta-PERT distribution over (min, mode, max).
//
// PERT is the standard way to turn a calibrated three-point estimate into a smooth distribution
// that respects the expert's mode without the hard shoulders of a triangular distribution. The
// shape parameters use the conventional lambda = 4 weighting on the mode:
//
//	alpha = 1 + 4 * (mode - min) / (max - min)
//	beta  = 1 + 4 * (max - mode) / (max - min)
func pert(rng *rand.Rand, t model.Triple) float64 {
	span := t.Max - t.Min
	if span <= 0 {
		return t.Min
	}
	alpha := 1 + 4*(t.Mode-t.Min)/span
	beta := 1 + 4*(t.Max-t.Mode)/span
	return t.Min + span*betaSample(rng, alpha, beta)
}

// betaSample draws from Beta(a, b) via the ratio of two Gamma variates:
// X~Gamma(a,1), Y~Gamma(b,1)  =>  X/(X+Y) ~ Beta(a,b).
func betaSample(rng *rand.Rand, a, b float64) float64 {
	x := gammaSample(rng, a)
	y := gammaSample(rng, b)
	if x+y == 0 {
		return 0.5
	}
	return x / (x + y)
}

// gammaSample draws from Gamma(shape, 1) using Marsaglia-Tsang (2000), with the standard
// boost for shape < 1.
func gammaSample(rng *rand.Rand, shape float64) float64 {
	if shape < 1 {
		// Boost: Gamma(a) = Gamma(a+1) * U^(1/a)
		u := rng.Float64()
		for u == 0 {
			u = rng.Float64()
		}
		return gammaSample(rng, shape+1) * math.Pow(u, 1/shape)
	}
	d := shape - 1.0/3.0
	c := 1 / math.Sqrt(9*d)
	for {
		var x, v float64
		for {
			x = rng.NormFloat64()
			v = 1 + c*x
			if v > 0 {
				break
			}
		}
		v = v * v * v
		u := rng.Float64()
		if u < 1-0.0331*x*x*x*x {
			return d * v
		}
		if math.Log(u) < 0.5*x*x+d*(1-v+math.Log(v)) {
			return d * v
		}
	}
}

// poisson draws the number of loss events in a simulated year given rate lambda, using Knuth's
// method for small lambda and a normal approximation above the threshold where Knuth's loop
// becomes expensive.
func poisson(rng *rand.Rand, lambda float64) int {
	if lambda <= 0 {
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
