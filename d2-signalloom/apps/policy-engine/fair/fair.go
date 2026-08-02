// Package fair implements FAIR (Factor Analysis of Information Risk) quantitative
// risk analysis using beta-PERT distributions and seeded Monte Carlo simulation.
package fair

import (
	"math"
	"math/rand/v2"
	"sort"
)

const iterations = 10_000

// RiskTriple holds beta-PERT parameters: minimum, most likely, and maximum.
type RiskTriple struct {
	Min  float64 `json:"min" yaml:"min"`
	Mode float64 `json:"mode" yaml:"mode"`
	Max  float64 `json:"max" yaml:"max"`
}

// RiskResult holds the output of a FAIR Monte Carlo simulation.
type RiskResult struct {
	ALE        float64 `json:"ale"`         // mean annual loss expectancy
	VaR95      float64 `json:"var95"`       // 95th percentile (bad year)
	TVaR       float64 `json:"tvar"`        // mean beyond VaR95 (tail risk)
	CarriedGBP float64 `json:"carriedGbp"`  // TVaR + 10% risk load
}

// Simulate runs a seeded Monte Carlo simulation combining loss magnitude and
// event frequency beta-PERT distributions. The result is deterministic for a
// given seed.
func Simulate(loss, freq RiskTriple, seed uint64) RiskResult {
	// Edge case: zero frequency means zero risk.
	if freq.Min == 0 && freq.Mode == 0 && freq.Max == 0 {
		return RiskResult{}
	}

	rng := rand.New(rand.NewPCG(seed, seed^0xdeadbeef))

	annualLosses := make([]float64, iterations)
	for i := range iterations {
		f := samplePERT(rng, freq)
		if f < 0 {
			f = 0
		}
		l := samplePERT(rng, loss)
		if l < 0 {
			l = 0
		}
		annualLosses[i] = f * l
	}

	sort.Float64s(annualLosses)

	// ALE: mean of all simulated annual losses.
	ale := mean(annualLosses)

	// VaR95: 95th percentile.
	idx95 := int(math.Ceil(0.95*float64(iterations))) - 1
	if idx95 < 0 {
		idx95 = 0
	}
	var95 := annualLosses[idx95]

	// TVaR: mean of values above VaR95 (tail risk).
	tail := annualLosses[idx95:]
	tvar := mean(tail)

	// Self-check: TVaR >= VaR95 >= ALE.
	if tvar < var95 {
		tvar = var95
	}
	if var95 < ale {
		var95 = ale
	}

	return RiskResult{
		ALE:        ale,
		VaR95:      var95,
		TVaR:       tvar,
		CarriedGBP: tvar * 1.10, // 10% risk load
	}
}

// samplePERT draws a single sample from a beta-PERT distribution.
// The PERT distribution uses lambda=4 (standard) to weight the mode.
func samplePERT(rng *rand.Rand, t RiskTriple) float64 {
	if t.Min == t.Max {
		return t.Min
	}

	const lambda = 4.0
	mu := (t.Min + lambda*t.Mode + t.Max) / (lambda + 2)
	if t.Max == t.Min {
		return mu
	}

	// Alpha and beta parameters for the underlying Beta distribution.
	alpha := ((mu - t.Min) * (2*t.Mode - t.Min - t.Max)) / ((t.Mode - mu) * (t.Max - t.Min))
	if alpha <= 0 {
		alpha = 1.0
	}
	beta := alpha * (t.Max - mu) / (mu - t.Min)
	if beta <= 0 {
		beta = 1.0
	}

	// Sample from Beta(alpha, beta) using the Gamma method.
	x := gammaVariate(rng, alpha)
	y := gammaVariate(rng, beta)
	b := x / (x + y)

	// Scale from [0,1] to [min, max].
	return t.Min + b*(t.Max-t.Min)
}

// gammaVariate generates a sample from Gamma(shape, 1) using Marsaglia and
// Tsang's method for shape >= 1, with the Ahrens-Dieter transformation for
// shape < 1.
func gammaVariate(rng *rand.Rand, shape float64) float64 {
	if shape < 1 {
		// Ahrens-Dieter: Gamma(a) = Gamma(a+1) * U^(1/a)
		return gammaVariate(rng, shape+1) * math.Pow(rng.Float64(), 1.0/shape)
	}

	d := shape - 1.0/3.0
	c := 1.0 / math.Sqrt(9.0*d)

	for {
		var x float64
		var v float64
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
