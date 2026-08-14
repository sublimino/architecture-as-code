package fair

// Guard instrumentation.
//
// WHY THIS FILE EXISTS.
//
// The sampling code in fair.go contains several defensive substitutions: samplePERT clamps a
// non-positive or NaN shape parameter to 1 and returns the triple's midpoint if the gamma variates
// degenerate; gammaVariate returns 0 for a non-finite shape; poisson caps Knuth's loop. Each of
// them exists for a good reason — they came from the fix for a symmetric-triple infinite rejection
// loop that was reachable over HTTP, where "return something" genuinely beat "wedge the process".
//
// But every one of them substitutes a FABRICATED number for a computed one, silently. If one ever
// fired, the report would carry a figure nobody computed, no error would be raised, and nothing
// downstream could tell. That is the same class of defect as a currency conversion silently
// assuming a rate of 1.0 — and having made that one fail loudly, leaving this one silent would be
// inconsistent.
//
// Measurement, not speculation: across 16,000,000 gamma draws covering every triple in the shipped
// risk estate, none of these guards fired even once. They are unreachable for well-formed input.
// But "unreachable" is a property of the LOADER's validation (min <= mode <= max, min >= 0), not of
// this package — and that validation is one refactor away from not holding. A counter costs
// nothing and converts "we believe it cannot happen" into "we can see that it did not".
//
// WHAT THIS DELIBERATELY DOES NOT DO.
//
// It does not change any guard's behaviour, does not alter the order or number of draws taken from
// the generator, and does not touch a single existing field. The counters are incremented on
// branches that were already there. Every figure this engine produces is bit-identical with the
// instrumentation in place — that is asserted by the existing regression suites, which are
// unmodified.
//
// It also does not turn a fired guard into an error. Promoting one to a hard failure would change
// behaviour, and behaviour changes to this package move numbers. Making it visible is the whole
// job; deciding what to do about a fire is a separate, reviewed decision.

// Guards counts the defensive substitutions made during a single simulation run.
//
// A non-zero count means at least one drawn value was fabricated rather than sampled, so the
// resulting figure is not fully derived from the stated inputs. Treat any non-zero count as
// invalidating the run for external use until the input that caused it has been found.
//
// The struct is comparable (all integer fields), so Result and RiskResult remain usable with `==`
// — the determinism tests depend on that.
type Guards struct {
	// ShapeClamped counts beta-PERT shape parameters (alpha or beta) that were non-positive or NaN
	// and were forced to 1. Reachable only for a triple violating min <= mode <= max, which the
	// loader rejects — so a non-zero count here means unvalidated data reached the sampler.
	ShapeClamped int `json:"shapeClamped"`

	// MidpointSubstituted counts draws where both gamma variates degenerated (x+y == 0, or either
	// NaN) and samplePERT returned the midpoint of the triple instead of a sampled value. This is
	// the most serious of the four: the returned number is invented outright.
	MidpointSubstituted int `json:"midpointSubstituted"`

	// GammaNonFinite counts gammaVariate calls that returned 0 because the shape parameter was NaN,
	// infinite, or non-positive.
	GammaNonFinite int `json:"gammaNonFinite"`

	// PoissonLoopCapped counts Knuth-method draws that hit the 1000-iteration cap and returned the
	// cap rather than a converged event count. Indicates a lambda far outside the modelled range.
	PoissonLoopCapped int `json:"poissonLoopCapped"`
}

// Fired reports whether any defensive substitution occurred.
func (g Guards) Fired() bool {
	return g.ShapeClamped > 0 || g.MidpointSubstituted > 0 || g.GammaNonFinite > 0 || g.PoissonLoopCapped > 0
}

// Total is the number of substitutions across all guards.
func (g Guards) Total() int {
	return g.ShapeClamped + g.MidpointSubstituted + g.GammaNonFinite + g.PoissonLoopCapped
}

// Explain returns a human-readable account of what fired, suitable for putting in front of someone
// who has to decide whether to trust the figure. Empty when nothing fired.
func (g Guards) Explain() string {
	if !g.Fired() {
		return ""
	}
	s := "the simulation substituted fabricated values for sampled ones:"
	if g.MidpointSubstituted > 0 {
		s += "\n  - " + plural(g.MidpointSubstituted, "draw") +
			" returned the midpoint of the triple because both gamma variates degenerated (the value was invented, not sampled)"
	}
	if g.ShapeClamped > 0 {
		s += "\n  - " + plural(g.ShapeClamped, "beta-PERT shape parameter") +
			" was non-positive or NaN and was forced to 1; this is only reachable for a triple violating min <= mode <= max, so unvalidated data reached the sampler"
	}
	if g.GammaNonFinite > 0 {
		s += "\n  - " + plural(g.GammaNonFinite, "gamma draw") + " returned 0 for a non-finite shape parameter"
	}
	if g.PoissonLoopCapped > 0 {
		s += "\n  - " + plural(g.PoissonLoopCapped, "Poisson draw") +
			" hit the 1000-event loop cap, indicating a rate far outside the modelled range"
	}
	s += "\nThe resulting figure is NOT fully derived from the stated inputs. Find the offending input before using it."
	return s
}

// add accumulates another run's counts. Used where several simulations contribute to one report.
func (g *Guards) add(o Guards) {
	g.ShapeClamped += o.ShapeClamped
	g.MidpointSubstituted += o.MidpointSubstituted
	g.GammaNonFinite += o.GammaNonFinite
	g.PoissonLoopCapped += o.PoissonLoopCapped
}

// Add is the exported accumulator, for callers aggregating several runs into one report.
func (g *Guards) Add(o Guards) { g.add(o) }

func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return itoa(n) + " " + noun + "s"
}

// itoa avoids pulling strconv into this file for one call.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
