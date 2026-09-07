package fair

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

// Prometheus instrumentation for the risk engine, rendered as text exposition.
//
// Hand-rendered rather than pulling in the Prometheus client library, matching the pattern already
// established for the Tetragon lane in this service (see main.go's /metrics handler, which serves
// tetragonCollector.Metrics().Render()). One rendering convention in the process beats two.

// riskDurationBuckets are the histogram's upper bounds in seconds. Chosen around the two numbers
// that matter: the 20 ms compute budget for 10,000 trials, and the 50 ms p95 SLA. Buckets crowd
// that region because a histogram whose nearest bound is 100 ms cannot answer "is p95 under 50 ms?"
// with anything better than "somewhere below 100".
var riskDurationBuckets = []float64{
	0.001, 0.0025, 0.005, 0.010, 0.015, 0.020, 0.030, 0.050, 0.100, 0.250, 0.500, 1.0,
}

// Metrics holds the risk engine's Prometheus state. Safe for concurrent use.
type Metrics struct {
	mu sync.Mutex

	// durationCounts[i] is the count of observations falling in bucket i (non-cumulative; the
	// cumulative form is produced at render time, which is where Prometheus requires it).
	durationCounts []uint64
	durationSum    float64
	durationTotal  uint64

	// pml is the latest probable maximum loss per agent. A gauge rather than a counter: a loss
	// figure goes down when controls improve, and a counter that goes down is a reset, not a fall.
	pml map[string]float64

	evaluations uint64
	cacheHits   uint64
	failures    uint64
}

// NewMetrics returns zeroed metrics. Zeroed rather than absent so a scrape during rollout reports
// "0" instead of an empty body — an empty body reads as "this subsystem does not exist", which is a
// materially different and much more alarming claim than "it exists and has done nothing yet".
func NewMetrics() *Metrics {
	return &Metrics{
		durationCounts: make([]uint64, len(riskDurationBuckets)+1), // +1 for the +Inf overflow bucket
		pml:            make(map[string]float64),
	}
}

// Observe records one completed evaluation.
func (m *Metrics) Observe(a Assessment) {
	if m == nil {
		return
	}
	seconds := float64(a.Timings.TotalNanos) / 1e9

	m.mu.Lock()
	defer m.mu.Unlock()

	idx := sort.SearchFloat64s(riskDurationBuckets, seconds)
	// SearchFloat64s returns the insertion point; for a value exactly equal to a bound it returns
	// that bound's index, which is correct for Prometheus's "less than or equal to" semantics.
	if idx >= len(m.durationCounts) {
		idx = len(m.durationCounts) - 1
	}
	m.durationCounts[idx]++
	m.durationSum += seconds
	m.durationTotal++
	m.evaluations++

	if a.AgentID != "" {
		m.pml[a.AgentID] = a.PML
	}
}

// ObserveCacheHit records a served-from-cache evaluation. Counted separately because a cache hit
// costs no CPU and folding it into the duration histogram would flatter the p95 by exactly the hit
// rate — a benchmark that warms the cache and then reports a sub-millisecond p95 has measured the
// map, not the engine.
func (m *Metrics) ObserveCacheHit() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.cacheHits++
	m.mu.Unlock()
}

// ObserveFailure records a rejected or failed evaluation.
func (m *Metrics) ObserveFailure() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.failures++
	m.mu.Unlock()
}

// Quantile estimates the given quantile of evaluation duration in seconds from the histogram, using
// linear interpolation within the containing bucket.
//
// This is the same estimator Prometheus's histogram_quantile uses, and it carries the same caveat:
// the answer is bounded by the bucket layout, so a p95 reported as 0.02 means "in the bucket ending
// at 20 ms", not "20.0 ms". Adequate for asserting an SLA; not adequate for a benchmark headline,
// which is why test/bench-fair-engine.sh measures directly instead.
func (m *Metrics) Quantile(q float64) float64 {
	if m == nil {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.durationTotal == 0 {
		return 0
	}
	target := q * float64(m.durationTotal)
	var cum float64
	prevBound := 0.0
	for i, c := range m.durationCounts {
		next := cum + float64(c)
		if next >= target {
			if i >= len(riskDurationBuckets) {
				// Overflow bucket: no upper bound exists, so the last finite bound is the most that
				// can be honestly claimed. Returning +Inf would be truthful but unusable.
				return riskDurationBuckets[len(riskDurationBuckets)-1]
			}
			bound := riskDurationBuckets[i]
			if c == 0 {
				return bound
			}
			frac := (target - cum) / float64(c)
			return prevBound + frac*(bound-prevBound)
		}
		cum = next
		if i < len(riskDurationBuckets) {
			prevBound = riskDurationBuckets[i]
		}
	}
	return riskDurationBuckets[len(riskDurationBuckets)-1]
}

// Render produces Prometheus text exposition format (version 0.0.4).
func (m *Metrics) Render() string {
	if m == nil {
		return ""
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	var b strings.Builder

	b.WriteString("# HELP risk_calculation_duration_seconds Wall-clock duration of one OpenFAIR agent risk evaluation.\n")
	b.WriteString("# TYPE risk_calculation_duration_seconds histogram\n")
	var cum uint64
	for i, bound := range riskDurationBuckets {
		cum += m.durationCounts[i]
		fmt.Fprintf(&b, "risk_calculation_duration_seconds_bucket{le=\"%g\"} %d\n", bound, cum)
	}
	cum += m.durationCounts[len(m.durationCounts)-1]
	fmt.Fprintf(&b, "risk_calculation_duration_seconds_bucket{le=\"+Inf\"} %d\n", cum)
	fmt.Fprintf(&b, "risk_calculation_duration_seconds_sum %g\n", m.durationSum)
	fmt.Fprintf(&b, "risk_calculation_duration_seconds_count %d\n", m.durationTotal)

	b.WriteString("# HELP agent_pml_loss_dollars Probable maximum loss (95th percentile annual loss) for an agent, in the estate's reporting currency.\n")
	b.WriteString("# TYPE agent_pml_loss_dollars gauge\n")
	// Sorted so the exposition is byte-stable between scrapes. Unsorted map iteration would make
	// every diff of two scrapes noise.
	ids := make([]string, 0, len(m.pml))
	for id := range m.pml {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		fmt.Fprintf(&b, "agent_pml_loss_dollars{agent=%q} %g\n", id, m.pml[id])
	}

	b.WriteString("# HELP risk_evaluations_total Count of OpenFAIR evaluations computed.\n")
	b.WriteString("# TYPE risk_evaluations_total counter\n")
	fmt.Fprintf(&b, "risk_evaluations_total %d\n", m.evaluations)

	b.WriteString("# HELP risk_cache_hits_total Count of evaluations served from cache.\n")
	b.WriteString("# TYPE risk_cache_hits_total counter\n")
	fmt.Fprintf(&b, "risk_cache_hits_total %d\n", m.cacheHits)

	b.WriteString("# HELP risk_evaluation_failures_total Count of evaluations rejected or failed.\n")
	b.WriteString("# TYPE risk_evaluation_failures_total counter\n")
	fmt.Fprintf(&b, "risk_evaluation_failures_total %d\n", m.failures)

	return b.String()
}
