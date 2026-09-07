package fair

import (
	"fmt"
	"sort"
	"sync"
)

// Fixture telemetry profiles.
//
// WHY FIXTURES SHIP IN THE PACKAGE RATHER THAN IN A TEST FILE. The parity contract
// (test/fair-api-parity.bats) has to drive the CLI and the REST endpoint over 50 agents and compare
// the results. Both surfaces must therefore see IDENTICAL telemetry, from a source that needs no
// cluster and no database — otherwise the contract measures whether two data sources agree, which
// is a different and much less interesting question than whether two code paths do.
//
// These are demonstrably synthetic and named as such. They are the offline telemetry source; the
// live source is injected in production via the TelemetrySource interface. Per SP-3, live mode must
// surface live attested APIs — FixtureSource is the offline half of that split, not a bypass of it.

// profileShape describes a point on the clean → compromised spectrum.
type profileShape struct {
	name              string
	runtimeViolations int
	networkAnomalies  int
	credentialState   string
	cveCritical       int
	cveHigh           int
	cveMedium         int
	contained         bool
	observationCount  int
}

// shapes spans the range the card asks the fixtures to cover: pristine through actively
// compromised, including the two cases most likely to be modelled wrongly — a contained but
// compromised agent (high vulnerability, strong control) and a sparsely observed agent (a real
// figure resting on a prior).
var shapes = []profileShape{
	{"pristine", 0, 0, "healthy", 0, 0, 0, false, 400},
	{"clean", 0, 1, "healthy", 0, 1, 3, false, 250},
	{"routine", 1, 2, "healthy", 0, 2, 6, false, 180},
	{"rotating-creds", 1, 2, "rotating", 0, 3, 8, false, 160},
	{"patch-debt", 2, 3, "healthy", 1, 6, 20, false, 200},
	{"noisy", 6, 12, "healthy", 0, 3, 9, false, 300},
	{"expired-creds", 2, 4, "expired", 1, 4, 11, false, 140},
	{"critical-cves", 1, 2, "healthy", 4, 12, 30, false, 220},
	{"compromised", 14, 22, "compromised", 3, 9, 24, false, 190},
	{"compromised-contained", 14, 22, "compromised", 3, 9, 24, true, 190},
	{"sparse-observation", 1, 1, "healthy", 0, 1, 2, false, 4},
	{"unknown-cred-posture", 3, 5, "", 1, 5, 12, false, 120},
}

// FixtureSource is a deterministic in-memory TelemetrySource. Deterministic is the operative word:
// nothing here is drawn from a clock or a generator, so the same agent id yields the same telemetry
// in the CLI process and in the server process, which is a precondition for the parity contract
// meaning anything at all.
type FixtureSource struct {
	mu     sync.RWMutex
	agents map[string]Telemetry
}

// NewFixtureSource builds n synthetic agents spanning the profile shapes, plus the named agents the
// card's probes reference by hand.
//
// n is clamped to at least len(shapes) so every shape is always represented; a fixture set that
// silently omits the compromised profile would let a parity run go green over twelve pristine
// agents and prove nothing about the interesting arithmetic.
func NewFixtureSource(n int) *FixtureSource {
	if n < len(shapes) {
		n = len(shapes)
	}
	s := &FixtureSource{agents: make(map[string]Telemetry, n+1)}

	for i := range n {
		sh := shapes[i%len(shapes)]
		// A small deterministic ramp on top of the shape so the n agents are genuinely distinct
		// rather than len(shapes) profiles repeated — repeated inputs would make a 50-agent parity
		// run only as strong as a 12-agent one.
		ramp := i / len(shapes)
		id := fmt.Sprintf("agent-%03d-%s", i, sh.name)
		s.agents[id] = Telemetry{
			AgentID:               id,
			RuntimeViolations:     sh.runtimeViolations + ramp,
			NetworkAnomalies:      sh.networkAnomalies + 2*ramp,
			CredentialState:       sh.credentialState,
			CVECritical:           sh.cveCritical,
			CVEHigh:               sh.cveHigh + ramp,
			CVEMedium:             sh.cveMedium + 3*ramp,
			Contained:             sh.contained,
			ObservationWindowDays: 90,
			ObservationCount:      sh.observationCount,
		}
	}

	// test-agent is referenced verbatim by the card's required curl probe. It must exist, and it
	// must be a middling profile rather than a pristine one — a probe against an agent whose every
	// figure is zero cannot distinguish a working engine from a broken one.
	s.agents["test-agent"] = Telemetry{
		AgentID:               "test-agent",
		RuntimeViolations:     3,
		NetworkAnomalies:      5,
		CredentialState:       "rotating",
		CVECritical:           1,
		CVEHigh:               4,
		CVEMedium:             12,
		Contained:             false,
		ObservationWindowDays: 90,
		ObservationCount:      120,
	}

	return s
}

// AgentTelemetry implements TelemetrySource.
func (s *FixtureSource) AgentTelemetry(id string) (Telemetry, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	t, ok := s.agents[id]
	return t, ok
}

// AgentIDs implements TelemetrySource.
func (s *FixtureSource) AgentIDs() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ids := make([]string, 0, len(s.agents))
	for id := range s.agents {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// Set installs or replaces one agent's telemetry. Present so tests can drive a specific profile
// without constructing a whole source, and so the live wiring can seed a known agent.
func (s *FixtureSource) Set(t Telemetry) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.agents[t.AgentID] = t
}

// DefaultFixtureCount is the fixture-set size the parity contract runs over. Fifty, because that is
// the number the card's evidence requirement names.
const DefaultFixtureCount = 50
