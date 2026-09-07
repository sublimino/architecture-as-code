package fair

import (
	"math"
	"sort"
	"sync"
)

// Telemetry is the observed operational state of one agent, as signal-ingest holds it: what the
// runtime saw, what the credentials look like, what the network did, what the scanner found.
//
// This is the input side of the mapping the card calls for. Everything here is a COUNT or a STATE —
// nothing here is already a risk figure. The whole point of the layer below is that the conversion
// from "17 runtime violations" to "£2.1M probable maximum loss" is written down, arguable, and
// reproducible, rather than being a colour someone chose.
type Telemetry struct {
	AgentID string `json:"agentId"`

	RuntimeViolations int `json:"runtimeViolations"`
	NetworkAnomalies  int `json:"networkAnomalies"`

	// CredentialState is one of: healthy, rotating, expired, compromised. An unrecognised value is
	// treated as the worst case rather than the best — an unknown credential posture is not
	// evidence of a good one.
	CredentialState string `json:"credentialState"`

	CVECritical int `json:"cveCritical"`
	CVEHigh     int `json:"cveHigh"`
	CVEMedium   int `json:"cveMedium"`

	// Contained reports Tier 0 containment (cgroup freeze + veth packet drop). A frozen agent can
	// still be attacked but can no longer act, which is a vulnerability reduction, not a threat
	// reduction — see DeriveInputs for why it moves V and not TEF.
	Contained bool `json:"contained"`

	// ObservationWindowDays and ObservationCount describe how much evidence the above rests on.
	// Distribution parameters fitted to four data points are not the same claim as parameters
	// fitted to four hundred, and the output says which it is.
	ObservationWindowDays int `json:"observationWindowDays"`
	ObservationCount      int `json:"observationCount"`
}

// Baseline parameters for an agent with a clean record. These are subjective priors, which is the
// normal state of affairs in FAIR — the alternative to a stated prior is an unstated one.
//
// Units: TEF and LEF are events per year. Loss magnitudes are GBP. The repository prices in GBP
// throughout; see the FX handling in tools/riskctl for cross-currency estates.
var (
	baselineTEF = Triple{Min: 0.5, Mode: 2.0, Max: 6.0}

	// A well-governed agent still has residual vulnerability. Zero would assert that no threat
	// event can ever become a loss event, which no control set earns.
	baselineVuln = Triple{Min: 0.02, Mode: 0.10, Max: 0.30}

	// Direct cost of one loss event on a clean agent: incident response, rebuild, lost work.
	baselinePrimary = Triple{Min: 5_000, Mode: 40_000, Max: 250_000}
)

// observationThreshold is the number of observations below which the derived parameters are treated
// as a broad subjective prior rather than an empirical fit. Thirty is the conventional
// small-sample boundary; it is a stated convention, not a discovered constant.
const observationThreshold = 30

// credentialVulnMultiplier maps credential posture onto a vulnerability multiplier.
//
// The mapping is a lookup table on purpose. A formula here would imply a precision the underlying
// judgement does not have, and a table can be argued with line by line in a risk committee, which
// is the only review that matters for these numbers.
func credentialVulnMultiplier(state string) float64 {
	switch state {
	case "healthy":
		return 1.0
	case "rotating":
		return 1.3
	case "expired":
		return 2.2
	case "compromised":
		return 4.0
	default:
		// Unknown posture is treated as compromised. An unrecognised state is a gap in observation,
		// and a gap in observation is not evidence of health.
		return 4.0
	}
}

// scale multiplies a triple by a non-negative factor, preserving ordering.
func scale(t Triple, f float64) Triple {
	return Triple{Min: t.Min * f, Mode: t.Mode * f, Max: t.Max * f}
}

// clampProbability forces a triple into [0,1] while preserving ordering. Applied only to
// vulnerability, and only AFTER the multipliers, because a multiplier can legitimately push a
// probability above 1 arithmetically while the quantity it represents cannot exceed certainty.
func clampProbability(t Triple) Triple {
	c := func(v float64) float64 {
		if v < 0 {
			return 0
		}
		if v > 1 {
			return 1
		}
		return v
	}
	out := Triple{Min: c(t.Min), Mode: c(t.Mode), Max: c(t.Max)}
	// Clamping can flatten ordering (e.g. mode and max both hit 1.0); it cannot invert it, because
	// c is monotonic. Assert anyway — a silently unordered triple reaches the sampler's guard path
	// and starts fabricating midpoints.
	if out.Mode < out.Min {
		out.Mode = out.Min
	}
	if out.Max < out.Mode {
		out.Max = out.Mode
	}
	return out
}

// widen broadens a triple around its mode by factor f >= 1, representing parameter uncertainty
// under sparse observation. The mode is unmoved: sparse data makes the estimate less certain, not
// systematically higher or lower, and shifting the mode would encode a bias that is not evidenced.
func widen(t Triple, f float64) Triple {
	if f <= 1 {
		return t
	}
	lo := t.Mode - (t.Mode-t.Min)*f
	if lo < 0 {
		lo = 0
	}
	return Triple{Min: lo, Mode: t.Mode, Max: t.Mode + (t.Max-t.Mode)*f}
}

// DeriveInputs maps observed telemetry onto OpenFAIR distribution parameters.
//
// THE MAPPING, AND WHY EACH ARROW POINTS WHERE IT DOES.
//
//	runtime violations  → TEF     an agent that keeps tripping runtime policy is being acted
//	                              against (or is misbehaving) more often. It is a FREQUENCY signal.
//	network anomalies   → TEF     same class of evidence: more observed activity, same per-event
//	                              severity. Weighted lower than a runtime violation because an
//	                              anomaly is a weaker signal than a policy trip.
//	credential state    → V       a compromised credential does not make attacks more frequent; it
//	                              makes them more likely to SUCCEED. That is vulnerability.
//	containment         → V       a frozen agent is still targeted at the same rate but can no
//	                              longer act on a successful attempt.
//	CVE counts          → LM      a vulnerable dependency does not change how often you are hit; it
//	                              changes how far an attacker gets, and therefore what it costs.
//	                              Severity-weighted 5:1.5:0.4 (critical:high:medium).
//
// Getting these arrows right is the substance of the model. Pointing them all at one aggregate
// "risk score" is what the ordinal-severity approach does, and it is why an ordinal score cannot be
// aggregated across an estate or handed to an underwriter.
//
// The second return value reports whether the result rests on a broad prior rather than sufficient
// observation.
func DeriveInputs(t Telemetry) (Inputs, bool) {
	// ── Frequency ──────────────────────────────────────────────────────────────────────────────
	// Additive in the counts rather than multiplicative: ten violations is ten pieces of evidence
	// of elevated activity, not a tenfold multiplier on the baseline rate. A multiplicative form
	// would put a single noisy collector in charge of the headline figure.
	freqFactor := 1.0 +
		0.35*float64(maxInt(t.RuntimeViolations, 0)) +
		0.12*float64(maxInt(t.NetworkAnomalies, 0))
	tef := scale(baselineTEF, freqFactor)

	// ── Vulnerability ──────────────────────────────────────────────────────────────────────────
	vulnFactor := credentialVulnMultiplier(t.CredentialState)
	if t.Contained {
		// Tier 0 containment is a strong but not total control. 0.2 rather than 0 because the
		// freeze can be lifted, raced, or mis-scoped, and a control credited at 100% is a control
		// nobody will ever check.
		vulnFactor *= 0.2
	}
	vuln := clampProbability(scale(baselineVuln, vulnFactor))

	// ── Magnitude ──────────────────────────────────────────────────────────────────────────────
	cveWeight := 5.0*float64(maxInt(t.CVECritical, 0)) +
		1.5*float64(maxInt(t.CVEHigh, 0)) +
		0.4*float64(maxInt(t.CVEMedium, 0))
	primary := scale(baselinePrimary, 1.0+0.08*cveWeight)

	// Secondary loss — regulatory, notification, legal, reputational — is modelled as a fraction of
	// primary loss that GROWS with severity: a minor incident stays internal, a critical one
	// becomes a notification event. The band is wide because this is the least well-evidenced
	// component of any FAIR model and a narrow band would misrepresent that.
	secondaryRatio := 0.25 + math.Min(1.75, 0.05*cveWeight)
	secondary := Triple{
		Min:  primary.Min * secondaryRatio * 0.2,
		Mode: primary.Mode * secondaryRatio,
		Max:  primary.Max * secondaryRatio * 2.0,
	}

	// ── Sparse-data fallback ───────────────────────────────────────────────────────────────────
	prior := t.ObservationCount < observationThreshold
	if prior {
		// Widen by up to 2.5x as the observation count approaches zero. The figure is still
		// produced — refusing to price an under-observed agent just moves the guess somewhere
		// less visible — but the band reflects what is actually known, and Assessment.Prior says so.
		deficit := float64(observationThreshold-maxInt(t.ObservationCount, 0)) / float64(observationThreshold)
		f := 1.0 + 1.5*deficit
		tef = widen(tef, f)
		vuln = clampProbability(widen(vuln, f))
		primary = widen(primary, f)
		secondary = widen(secondary, f)
	}

	return Inputs{
		AgentID:        t.AgentID,
		TEF:            tef,
		Vulnerability:  vuln,
		PrimaryLoss:    primary,
		SecondaryLoss:  secondary,
		MagnitudeModel: ModelPERT,
	}.WithDefaults(), prior
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Evaluation service: telemetry source + cache + metrics + audit.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TelemetrySource supplies the observed state for an agent. An interface rather than a concrete
// store so the engine is testable without a cluster: every external boundary in this package is
// injectable, which is the only way the unit tier can cover the error paths.
type TelemetrySource interface {
	// AgentTelemetry returns the telemetry for id. ok is false when the agent is unknown, which
	// the HTTP layer turns into a 404. It is deliberately a separate signal from an error: "no such
	// agent" and "the store is broken" are different answers and must not share a code path.
	AgentTelemetry(id string) (Telemetry, bool)

	// AgentIDs lists known agents, sorted, for the CLI's inventory mode.
	AgentIDs() []string
}

// cacheEntry is a memoised assessment keyed on everything that can change the answer.
type cacheKey struct {
	agentID string
	trials  int
	seed    int64
	model   MagnitudeModel
	// gen is the source's invalidation generation. Including it in the KEY rather than sweeping the
	// map on invalidation means a stale entry can never be read: it simply stops being addressable.
	gen uint64
}

// Service evaluates agent risk with caching, metrics and an audit trail. It is safe for concurrent
// use; the card's 500-concurrent-request budget is met by this type, not by the caller.
type Service struct {
	Source TelemetrySource

	mu    sync.RWMutex
	cache map[cacheKey]Assessment
	gen   uint64

	Metrics *Metrics
	Audit   *AuditLog
}

// NewService builds a Service over the given telemetry source.
func NewService(src TelemetrySource) *Service {
	return &Service{
		Source:  src,
		cache:   make(map[cacheKey]Assessment),
		Metrics: NewMetrics(),
		Audit:   NewAuditLog(DefaultAuditCapacity),
	}
}

// Invalidate drops every cached assessment. Called when new findings are ingested for any agent:
// a risk figure computed before a critical CVE landed is not merely stale, it is wrong, and serving
// it from cache would be the most confident possible way to be wrong.
func (s *Service) Invalidate() {
	s.mu.Lock()
	s.gen++
	// Bounded memory: entries from superseded generations are unreachable by key, so the map is
	// reset rather than left to grow. Reset is O(1) in Go and cannot leave a reachable stale entry.
	s.cache = make(map[cacheKey]Assessment)
	s.mu.Unlock()
}

// Options are the per-request knobs the CLI and the HTTP endpoint both expose.
type Options struct {
	Trials int
	Seed   int64
	Model  MagnitudeModel
}

// ErrUnknownAgent is returned when the telemetry source has no record of the requested agent.
var ErrUnknownAgent = errorString("fair: unknown agent")

type errorString string

func (e errorString) Error() string { return string(e) }

// Assess prices one agent, using the cache when the answer cannot have changed.
//
// THE PATH BOTH SURFACES TAKE. riskctl calls this. The REST handler calls this. Neither has any
// other way to obtain a figure, which is what the parity contract is really asserting.
func (s *Service) Assess(agentID string, opt Options) (Assessment, error) {
	tel, ok := s.Source.AgentTelemetry(agentID)
	if !ok {
		return Assessment{}, ErrUnknownAgent
	}

	in, prior := DeriveInputs(tel)
	if opt.Trials != 0 {
		in.Trials = opt.Trials
	}
	if opt.Seed != 0 {
		in.Seed = opt.Seed
	}
	if opt.Model != "" {
		in.MagnitudeModel = opt.Model
	}
	in = in.WithDefaults()

	// Validate BEFORE consulting the cache. A bad trial count must be rejected identically whether
	// or not something happens to be memoised; otherwise the same request returns 400 or 200
	// depending on cache state, which is the kind of nondeterminism that takes a day to diagnose.
	if err := in.Validate(); err != nil {
		return Assessment{}, err
	}

	s.mu.RLock()
	key := cacheKey{agentID: agentID, trials: in.Trials, seed: in.Seed, model: in.MagnitudeModel, gen: s.gen}
	hit, found := s.cache[key]
	s.mu.RUnlock()
	if found {
		s.Metrics.ObserveCacheHit()
		return hit, nil
	}

	a, err := Evaluate(in)
	if err != nil {
		return Assessment{}, err
	}
	a.Prior = prior

	s.Metrics.Observe(a)

	s.mu.Lock()
	prev, hadPrev := s.lastPMLLocked(agentID)
	s.cache[key] = a
	s.mu.Unlock()

	if s.Audit != nil {
		s.Audit.Record(a, prev, hadPrev)
	}

	return a, nil
}

// lastPMLLocked returns the most recent PML recorded for an agent, for transition auditing.
// Caller holds s.mu.
func (s *Service) lastPMLLocked(agentID string) (float64, bool) {
	if s.Audit == nil {
		return 0, false
	}
	return s.Audit.LastPML(agentID)
}

// AgentIDs exposes the source's inventory, sorted for stable CLI output.
func (s *Service) AgentIDs() []string {
	ids := s.Source.AgentIDs()
	out := make([]string, len(ids))
	copy(out, ids)
	sort.Strings(out)
	return out
}
