// Package fair implements the OpenFAIR (Factor Analysis of Information Risk) quantitative risk
// model for a single agent, on top of the repository's canonical Monte Carlo engine.
//
// WHAT THIS PACKAGE IS, AND DELIBERATELY IS NOT.
//
// It is NOT a Monte Carlo engine. There is exactly one of those in this repository, at
// d2-signalloom/apps/policy-engine/fair, and its package doc says plainly that a second
// implementation of that maths anywhere in the repo is a defect. Two samplers eventually disagree
// about a number, and the person who notices is in the audience. So every stochastic draw below is
// delegated; this package contains no generator, no gamma variate, and no Poisson loop.
//
// What it IS, is the OpenFAIR layer the canonical engine deliberately does not have: the algebra
// that turns the factors a risk analyst actually states into the two triples the sampler consumes.
//
//	Threat Event Frequency (TEF)  ─┐
//	                               ├─ x ─→  Loss Event Frequency (LEF)   ─┐
//	Vulnerability (V) ∈ [0,1]     ─┘                                      ├─→ Monte Carlo ─→ ALE
//	                                                                      │                  PML
//	Primary Loss Magnitude        ─┐                                      │                  VaR
//	                               ├─ + ─→  Loss Magnitude (LM)          ─┘                  TVaR
//	Secondary Loss Magnitude      ─┘
//
// THE PARITY PROPERTY. The riskctl CLI and the signal-ingest REST endpoint both call Evaluate in
// this file. They are not two implementations kept in agreement by a contract test; they are one
// implementation with two front doors. test/fair-api-parity.bats asserts 0% divergence, but what it
// is really asserting is that this property still holds — which is why it is checkable at all.
//
// DETERMINISM. Every figure is reproducible from the (inputs, seed, trials) triple printed beside
// it. A number nobody can reproduce is not evidence, and an unseeded Monte Carlo assertion is a
// flaky test waiting to happen.
package fair

import (
	"errors"
	"fmt"
	"math"
	"time"

	cfair "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
)

// Triple is the beta-PERT (minimum, most likely, maximum) parameterisation. Aliased rather than
// redefined so a triple can cross into the canonical engine without a conversion function — a
// conversion function is somewhere for the two representations to drift apart.
type Triple = cfair.RiskTriple

const (
	// DefaultTrials is the per-evaluation trial count. The card's latency budget is stated against
	// this number: 10,000 trials in under 20 ms.
	DefaultTrials = 10_000

	// MaxTrials caps a single evaluation. The endpoint is reachable over HTTP, so the trial count
	// is attacker-influenced input, and an uncapped trial count is a CPU-exhaustion primitive
	// dressed up as a query parameter.
	MaxTrials = 20_000

	// DefaultSeed pins the generator. Seeding from the clock would make every published figure
	// unreproducible, which is the one property a risk figure cannot afford to lack.
	DefaultSeed int64 = 20260907

	// DefaultRiskLoad is the institution's loading above the tail mean. It belongs to the
	// institution's risk posture, not to the engine; it is a default, not a constant of nature.
	DefaultRiskLoad = 0.10
)

// MagnitudeModel selects how the loss-magnitude triple is shaped before sampling.
type MagnitudeModel string

const (
	// ModelPERT interprets the magnitude triple directly as beta-PERT (min, mode, max). This is
	// standard OpenFAIR practice and the default.
	ModelPERT MagnitudeModel = "pert"

	// ModelLognormal interprets the magnitude triple as lognormal (p5, median, p95) quantiles and
	// re-derives the mode so the sampled shape carries the lognormal's right skew.
	//
	// It is a REPARAMETERISATION, not a second sampler — see LognormalShape for the derivation and
	// for an honest statement of what the approximation does and does not preserve.
	ModelLognormal MagnitudeModel = "lognormal"
)

// z95 is the standard-normal quantile at 0.95, used to invert a lognormal's p5/p95 spread into a
// sigma. Written out rather than computed so the derivation in LognormalShape is auditable.
const z95 = 1.6448536269514722

// Errors returned by Validate. Named so callers (the HTTP handler in particular) can distinguish a
// client mistake from a server fault without string matching.
var (
	ErrNonFinite       = errors.New("fair: parameter must be finite")
	ErrNegative        = errors.New("fair: loss and frequency parameters must be non-negative")
	ErrUnordered       = errors.New("fair: triple must satisfy min <= mode <= max")
	ErrVulnRange       = errors.New("fair: vulnerability must lie in [0,1]")
	ErrTrialsRange     = errors.New("fair: trials must be in [1, 20000]")
	ErrRiskLoadRange   = errors.New("fair: risk load must be finite and >= 0")
	ErrUnknownModel    = errors.New("fair: unknown magnitude model")
	ErrDegenerateInput = errors.New("fair: loss magnitude has zero spread and zero mode")
)

// Inputs are the OpenFAIR factors for one agent evaluation.
type Inputs struct {
	AgentID string `json:"agentId"`

	// TEF is the annual rate at which a threat agent acts against this asset, before any
	// consideration of whether the action succeeds.
	TEF Triple `json:"tef"`

	// Vulnerability is the probability that a threat event becomes a loss event. Bounded [0,1];
	// it is a probability, and a "probability" of 1.4 is a data-entry error, not a severe risk.
	Vulnerability Triple `json:"vulnerability"`

	// PrimaryLoss is the direct cost of a loss event: response, replacement, lost productivity.
	PrimaryLoss Triple `json:"primaryLoss"`

	// SecondaryLoss is the consequential cost: regulatory penalty, notification, reputational and
	// legal follow-on. Zero is a legitimate value and means "we model none".
	SecondaryLoss Triple `json:"secondaryLoss"`

	MagnitudeModel MagnitudeModel `json:"magnitudeModel"`
	Trials         int            `json:"trials"`
	Seed           int64          `json:"seed"`
	RiskLoad       float64        `json:"riskLoad"`
}

// VaR holds Value at Risk at the percentiles a risk committee reads together. A struct rather than
// a map so the JSON key order is fixed and a byte-level diff between the CLI and the API is
// meaningful rather than an artefact of map iteration.
type VaR struct {
	P50 float64 `json:"p50"`
	P90 float64 `json:"p90"`
	P95 float64 `json:"p95"`
	P99 float64 `json:"p99"`
}

// Timings records where the wall clock went. Present so a latency regression can be attributed to a
// stage rather than guessed at; the card asks for profiling probes and this is the cheapest form of
// one that survives into production.
type Timings struct {
	ComposeNanos    int64 `json:"composeNanos"`
	SimulateNanos   int64 `json:"simulateNanos"`
	PercentileNanos int64 `json:"percentileNanos"`
	TotalNanos      int64 `json:"totalNanos"`
}

// Guards mirrors the canonical engine's defensive-substitution counters. A non-zero count means at
// least one sampled value was fabricated rather than drawn, so the figures are not fully derived
// from the stated inputs. It is surfaced, never swallowed.
type Guards struct {
	ShapeClamped        int `json:"shapeClamped"`
	MidpointSubstituted int `json:"midpointSubstituted"`
	GammaNonFinite      int `json:"gammaNonFinite"`
	PoissonLoopCapped   int `json:"poissonLoopCapped"`
}

// Total reports whether any guard fired at all.
func (g Guards) Total() int {
	return g.ShapeClamped + g.MidpointSubstituted + g.GammaNonFinite + g.PoissonLoopCapped
}

// Assessment is one agent's priced risk posture. This struct is the parity contract: it is what the
// CLI marshals for `--json` and what the REST handler marshals for its response body, so the two
// cannot carry different fields even in principle.
type Assessment struct {
	AgentID        string         `json:"agentId"`
	Trials         int            `json:"trials"`
	Seed           int64          `json:"seed"`
	MagnitudeModel MagnitudeModel `json:"magnitudeModel"`

	// The stated factors, echoed so a reader can reproduce the run from the output alone.
	TEF           Triple `json:"tef"`
	Vulnerability Triple `json:"vulnerability"`

	// The derived factors actually handed to the sampler. Echoed because "LEF = TEF x V" is the
	// step most likely to be disputed, and a disputed step that is not shown is unarguable.
	LEF Triple `json:"lef"`
	LM  Triple `json:"lm"`

	// Analytic means of the derived triples, for sanity-checking the simulation against arithmetic.
	LEFMean float64 `json:"lefMean"`
	LMMean  float64 `json:"lmMean"`

	// Simulated annual loss distribution.
	ALE      float64 `json:"ale"`      // mean annual loss expectancy
	PML      float64 `json:"pml"`      // probable maximum loss == VaR at p95
	TVaR     float64 `json:"tvar"`     // mean loss beyond PML
	Carried  float64 `json:"carried"`  // TVaR with the risk load applied
	VaR      VaR     `json:"var"`      // p50/p90/p95/p99
	RiskLoad float64 `json:"riskLoad"`

	// TailDominated reports VaR95 < ALE: most simulated years cost nothing and the whole expected
	// loss lives in the tail. It is a risk-financing signal (the regime where transfer starts to
	// beat further control spend), NOT an error, and specifically not something to clamp away.
	TailDominated bool `json:"tailDominated"`

	// Prior is set when the parameters came from a broad subjective prior rather than sufficient
	// observation. A figure derived from a prior is still a figure, but it is a different kind of
	// claim and the output says so rather than letting the reader assume otherwise.
	Prior bool `json:"prior"`

	Guards  Guards  `json:"guards"`
	Timings Timings `json:"timings"`
}

// pertMean is the analytic beta-PERT mean, (min + 4*mode + max) / 6.
func pertMean(t Triple) float64 { return (t.Min + 4*t.Mode + t.Max) / 6 }

// ComposeLEF derives Loss Event Frequency from Threat Event Frequency and Vulnerability.
//
//	LEF = TEF x V
//
// Composed element-wise on the triple. This is exact rather than approximate for the quantity it
// claims to be: because both operands are non-negative and ordered, the products are ordered too,
// so (min*min, mode*mode, max*max) is a well-formed triple whose endpoints are the true extremes of
// the product. The MODE of the product is not in general the product of the modes — that is an
// approximation, and it is the standard one in OpenFAIR practice, chosen because the alternative
// (sampling V per trial and multiplying) would require a second sampler in this package. Documented
// here rather than left for a reader to discover.
func ComposeLEF(tef, vuln Triple) Triple {
	return Triple{
		Min:  tef.Min * vuln.Min,
		Mode: tef.Mode * vuln.Mode,
		Max:  tef.Max * vuln.Max,
	}
}

// ComposeLM derives total Loss Magnitude by summing primary and secondary loss.
//
//	LM = LM_primary + LM_secondary
//
// Element-wise addition is exact on the endpoints (the minimum of a sum of independent non-negative
// quantities is the sum of the minima, and likewise the maximum). As with ComposeLEF the mode is
// the standard approximation.
func ComposeLM(primary, secondary Triple) Triple {
	return Triple{
		Min:  primary.Min + secondary.Min,
		Mode: primary.Mode + secondary.Mode,
		Max:  primary.Max + secondary.Max,
	}
}

// LognormalShape reinterprets a magnitude triple stated as lognormal (p5, median, p95) quantiles
// and returns the beta-PERT triple whose skew matches that lognormal.
//
// THE DERIVATION.
//
//	mu    = ln(median)
//	sigma = (ln(p95) - ln(p5)) / (2 * z95)
//	mode  = exp(mu - sigma^2)          // the lognormal's mode sits BELOW its median
//
// The endpoints are left alone: they are already the stated p5 and p95. Only the mode moves, and it
// moves downward, which is exactly the right-skew that distinguishes a lognormal loss curve from a
// symmetric one. A triple stated as (100k, 500k, 4M) has a mode of 500k under PERT and roughly
// 208k under this transform, and the resulting ALE differs accordingly.
//
// WHAT THIS DOES NOT DO. It does not reproduce a lognormal's unbounded right tail — beta-PERT is
// bounded at max by construction, so losses beyond the stated p95 cannot occur. For a tail-risk
// question that matters, and the honest answer is to state a higher p95 rather than to pretend the
// bound is not there. This is a skew match, not a distribution replacement, and it is implemented
// as a parameter transform precisely so that it adds no second sampling path.
//
// Non-positive or non-finite inputs fall through unchanged; validation rejects them upstream, and
// a transform is not the place to invent a value.
func LognormalShape(t Triple) Triple {
	if t.Min <= 0 || t.Mode <= 0 || t.Max <= 0 {
		return t
	}
	if math.IsInf(t.Max, 0) || math.IsNaN(t.Mode) {
		return t
	}
	sigma := (math.Log(t.Max) - math.Log(t.Min)) / (2 * z95)
	if sigma <= 0 || math.IsNaN(sigma) || math.IsInf(sigma, 0) {
		return t
	}
	mode := math.Exp(math.Log(t.Mode) - sigma*sigma)

	// Keep the result a well-formed triple. Clamping into [min, max] here cannot fabricate a
	// figure: mode is already inside the interval for every sigma the formula can produce from an
	// ordered triple, and the clamp exists only so a pathological input cannot emit an unordered
	// triple that the sampler would then have to guard against.
	if mode < t.Min {
		mode = t.Min
	}
	if mode > t.Max {
		mode = t.Max
	}
	return Triple{Min: t.Min, Mode: mode, Max: t.Max}
}

// validateTriple applies the shared finiteness/non-negativity/ordering rules and wraps the failure
// in a sentinel error so callers can classify it.
func validateTriple(name string, t Triple) error {
	if math.IsNaN(t.Min) || math.IsInf(t.Min, 0) ||
		math.IsNaN(t.Mode) || math.IsInf(t.Mode, 0) ||
		math.IsNaN(t.Max) || math.IsInf(t.Max, 0) {
		return fmt.Errorf("%w: %s = (%g, %g, %g)", ErrNonFinite, name, t.Min, t.Mode, t.Max)
	}
	if t.Min < 0 || t.Mode < 0 || t.Max < 0 {
		return fmt.Errorf("%w: %s = (%g, %g, %g)", ErrNegative, name, t.Min, t.Mode, t.Max)
	}
	if !(t.Min <= t.Mode && t.Mode <= t.Max) {
		return fmt.Errorf("%w: %s = (%g, %g, %g)", ErrUnordered, name, t.Min, t.Mode, t.Max)
	}
	return nil
}

// WithDefaults fills unset fields. Separated from Validate so the defaulting rules are inspectable
// and so Validate can be called on an already-defaulted struct without changing its meaning.
func (in Inputs) WithDefaults() Inputs {
	if in.Trials == 0 {
		in.Trials = DefaultTrials
	}
	if in.Seed == 0 {
		in.Seed = DefaultSeed
	}
	if in.RiskLoad == 0 {
		in.RiskLoad = DefaultRiskLoad
	}
	if in.MagnitudeModel == "" {
		in.MagnitudeModel = ModelPERT
	}
	return in
}

// Validate rejects every input the sampler cannot safely consume. Rejection happens HERE, at the
// boundary, rather than by clamping downstream: a clamp turns a data error into a plausible number,
// and a plausible wrong number is worse than a refusal.
func (in Inputs) Validate() error {
	for _, c := range []struct {
		name string
		t    Triple
	}{
		{"tef", in.TEF},
		{"vulnerability", in.Vulnerability},
		{"primaryLoss", in.PrimaryLoss},
		{"secondaryLoss", in.SecondaryLoss},
	} {
		if err := validateTriple(c.name, c.t); err != nil {
			return err
		}
	}

	// Vulnerability is a probability. The ordering check above has already passed, so testing the
	// endpoints is sufficient to bound the whole triple.
	if in.Vulnerability.Max > 1 {
		return fmt.Errorf("%w: max = %g", ErrVulnRange, in.Vulnerability.Max)
	}

	if in.Trials < 1 || in.Trials > MaxTrials {
		return fmt.Errorf("%w: got %d", ErrTrialsRange, in.Trials)
	}

	if math.IsNaN(in.RiskLoad) || math.IsInf(in.RiskLoad, 0) || in.RiskLoad < 0 {
		return fmt.Errorf("%w: got %g", ErrRiskLoadRange, in.RiskLoad)
	}

	switch in.MagnitudeModel {
	case ModelPERT, ModelLognormal:
	default:
		return fmt.Errorf("%w: %q", ErrUnknownModel, in.MagnitudeModel)
	}

	return nil
}

// Evaluate prices one agent's risk.
//
// This is the single computation path. The riskctl CLI calls it; the REST handler calls it. There
// is no third caller and no second implementation, which is what makes the 0%-divergence contract
// a structural property rather than a hope.
func Evaluate(in Inputs) (Assessment, error) {
	start := time.Now()
	in = in.WithDefaults()

	if err := in.Validate(); err != nil {
		return Assessment{}, err
	}

	lef := ComposeLEF(in.TEF, in.Vulnerability)
	lm := ComposeLM(in.PrimaryLoss, in.SecondaryLoss)
	if in.MagnitudeModel == ModelLognormal {
		lm = LognormalShape(lm)
	}

	// The composed triples must themselves be well-formed. They are derived, not stated, so a
	// failure here is a bug in the composition, not a user error — but it is still not something to
	// pass to the sampler and hope.
	if err := validateTriple("lef", lef); err != nil {
		return Assessment{}, err
	}
	if err := validateTriple("lm", lm); err != nil {
		return Assessment{}, err
	}

	composeDone := time.Now()

	eng := &cfair.Engine{Iterations: in.Trials, Seed: in.Seed}
	res, losses := eng.RunDistribution([]cfair.Contribution{{
		ControlID: "agent",
		Scenario:  in.AgentID,
		LEF:       lef,
		Magnitude: lm,
	}}, in.RiskLoad)

	simulateDone := time.Now()

	// Percentiles come from the canonical helper so p50/p90/p99 use exactly the nearest-rank
	// convention that produced the p95 sitting beside them. Two conventions in one output is two
	// different numbers presented as one family.
	v := VaR{
		P50: cfair.Percentile(losses, 0.50),
		P90: cfair.Percentile(losses, 0.90),
		P95: cfair.Percentile(losses, 0.95),
		P99: cfair.Percentile(losses, 0.99),
	}

	percentileDone := time.Now()

	if err := res.SelfCheck(); err != nil {
		return Assessment{}, fmt.Errorf("fair: simulation produced an inconsistent result: %w", err)
	}

	a := Assessment{
		AgentID:        in.AgentID,
		Trials:         in.Trials,
		Seed:           in.Seed,
		MagnitudeModel: in.MagnitudeModel,
		TEF:            in.TEF,
		Vulnerability:  in.Vulnerability,
		LEF:            lef,
		LM:             lm,
		LEFMean:        pertMean(lef),
		LMMean:         pertMean(lm),
		ALE:            res.ALE,
		PML:            res.VaR95,
		TVaR:           res.TVaR,
		Carried:        res.Carried,
		VaR:            v,
		RiskLoad:       res.RiskLoad,
		TailDominated:  res.TailDominated(),
		Guards: Guards{
			ShapeClamped:        res.Guards.ShapeClamped,
			MidpointSubstituted: res.Guards.MidpointSubstituted,
			GammaNonFinite:      res.Guards.GammaNonFinite,
			PoissonLoopCapped:   res.Guards.PoissonLoopCapped,
		},
		Timings: Timings{
			ComposeNanos:    composeDone.Sub(start).Nanoseconds(),
			SimulateNanos:   simulateDone.Sub(composeDone).Nanoseconds(),
			PercentileNanos: percentileDone.Sub(simulateDone).Nanoseconds(),
			TotalNanos:      time.Since(start).Nanoseconds(),
		},
	}

	// PML is defined as VaR at the 95th percentile. Asserting the identity here rather than
	// trusting it means a future change to either path cannot silently make the two disagree while
	// both continue to look like plausible currency figures.
	if a.PML != a.VaR.P95 {
		return Assessment{}, fmt.Errorf(
			"fair: internal inconsistency: PML (%.6f) != VaR95 (%.6f)", a.PML, a.VaR.P95)
	}

	return a, nil
}
