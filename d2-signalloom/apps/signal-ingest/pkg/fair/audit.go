package fair

import (
	"sync"
	"time"
)

// DefaultAuditCapacity bounds the in-memory audit ring. The trail must not be able to grow without
// limit: this is a long-lived server process and an unbounded slice fed by an HTTP endpoint is a
// memory-exhaustion primitive, not an audit trail.
const DefaultAuditCapacity = 1024

// AuditRecord captures one risk evaluation and, when the figure moved, what it moved from.
//
// WHY THE DERIVED PARAMETERS ARE IN HERE. A risk figure without its inputs is an assertion. The
// question an auditor asks six months later is not "what was the PML" but "why was it that", and
// the answer is the triples — which is why LEF and LM are recorded alongside the headline, not just
// referenced by a run id that may no longer resolve.
type AuditRecord struct {
	Timestamp time.Time `json:"timestamp"`
	AgentID   string    `json:"agentId"`

	Seed   int64          `json:"seed"`
	Trials int            `json:"trials"`
	Model  MagnitudeModel `json:"magnitudeModel"`

	LEF Triple `json:"lef"`
	LM  Triple `json:"lm"`

	ALE float64 `json:"ale"`
	PML float64 `json:"pml"`

	// PreviousPML and Transition are set only when this agent has been priced before. A first
	// evaluation is not a transition, and recording one as a move from zero would manufacture a
	// spurious increase on every agent's first appearance.
	PreviousPML float64 `json:"previousPml,omitempty"`
	Transition  bool    `json:"transition"`

	// Delta is PML - PreviousPML, present only on a transition.
	Delta float64 `json:"delta,omitempty"`

	// Prior records that this figure rested on a broad subjective prior rather than sufficient
	// observation, so a later reader can tell an evidenced number from an estimated one.
	Prior bool `json:"prior"`

	// GuardsFired is non-zero when the simulation substituted a value rather than sampling it.
	// A non-zero count invalidates the run for external use until the cause is found.
	GuardsFired int `json:"guardsFired"`
}

// AuditLog is a bounded, concurrency-safe ring of risk-score transitions.
type AuditLog struct {
	mu       sync.RWMutex
	capacity int
	records  []AuditRecord
	// lastPML is the most recent PML per agent, kept separately from the ring so a transition is
	// still detected after the agent's previous record has aged out of it. Bounded by the agent
	// count, which is bounded by the estate.
	lastPML map[string]float64
}

// NewAuditLog returns a log holding at most capacity records. A non-positive capacity falls back to
// the default rather than producing a log that silently discards everything.
func NewAuditLog(capacity int) *AuditLog {
	if capacity <= 0 {
		capacity = DefaultAuditCapacity
	}
	return &AuditLog{
		capacity: capacity,
		records:  make([]AuditRecord, 0, capacity),
		lastPML:  make(map[string]float64),
	}
}

// Record appends an evaluation to the trail. prev/hadPrev describe the agent's previous PML.
func (l *AuditLog) Record(a Assessment, prev float64, hadPrev bool) {
	if l == nil {
		return
	}
	r := AuditRecord{
		Timestamp:   time.Now().UTC(),
		AgentID:     a.AgentID,
		Seed:        a.Seed,
		Trials:      a.Trials,
		Model:       a.MagnitudeModel,
		LEF:         a.LEF,
		LM:          a.LM,
		ALE:         a.ALE,
		PML:         a.PML,
		Prior:       a.Prior,
		GuardsFired: a.Guards.Total(),
	}
	if hadPrev {
		r.PreviousPML = prev
		r.Transition = prev != a.PML
		r.Delta = a.PML - prev
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	if len(l.records) == l.capacity {
		// Drop the oldest. copy rather than re-slicing so the backing array does not grow.
		copy(l.records, l.records[1:])
		l.records[len(l.records)-1] = r
	} else {
		l.records = append(l.records, r)
	}
	l.lastPML[a.AgentID] = a.PML
}

// LastPML returns the most recently recorded PML for an agent.
func (l *AuditLog) LastPML(agentID string) (float64, bool) {
	if l == nil {
		return 0, false
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	v, ok := l.lastPML[agentID]
	return v, ok
}

// Records returns a copy of the trail, oldest first. A copy because handing out the internal slice
// would let a reader observe a torn write mid-append.
func (l *AuditLog) Records() []AuditRecord {
	if l == nil {
		return nil
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	out := make([]AuditRecord, len(l.records))
	copy(out, l.records)
	return out
}

// Len reports how many records are currently held.
func (l *AuditLog) Len() int {
	if l == nil {
		return 0
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	return len(l.records)
}

// Capacity reports the ring's bound.
func (l *AuditLog) Capacity() int {
	if l == nil {
		return 0
	}
	return l.capacity
}
