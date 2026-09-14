// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// Prometheus instrumentation for the retention controller, rendered as text exposition.
//
// Hand-rendered rather than pulling in the Prometheus client library, matching pkg/fair/metrics.go
// and the Tetragon lane already served from main.go's /metrics handler. One rendering convention in
// the process beats two.

// overdueKey identifies one overdue bucket.
//
// Labelled by tenant, sink AND disposition. The disposition label is the one that earns its keep: it
// separates overdue_held from overdue_unreachable, so a DPO reading the gauge can see hold-driven
// retention as hold-driven rather than as a generic backlog. Without it, a permanently held copy and
// a broken backup sink look identical.
type overdueKey struct {
	tenant      string
	sink        string
	disposition string

	// reach separates three conditions an earlier version conflated into one number: "we tried and
	// failed" (in_process — a defect, alertable), "we are forbidden to delete" (continuity_bearing — a
	// correct state), and "we have no purger here" (external_attestation — a coverage gap). Eleven of
	// thirty-five sinks are external, so without this label the gauge has a permanent non-zero floor,
	// and an alert threshold set above that floor hides every real in-process failure underneath it.
	reach string
}

// Metrics holds the retention controller's Prometheus state. Safe for concurrent use.
type Metrics struct {
	mu sync.Mutex

	// overdue is a gauge, not a counter: an overdue count falls when copies are finally purged, and a
	// counter that falls is a reset rather than a decrease.
	overdue map[overdueKey]int

	// outstanding is every copy without a complete receipt, overdue or not. Exposed separately so
	// "expired but inside the propagation window" is visible before it becomes a breach.
	outstanding map[overdueKey]int

	// receipts counts receipts by disposition.
	receipts map[Disposition]uint64

	// sinkFailures counts CONSECUTIVE failures per sink. Consecutive rather than cumulative because
	// the operational question is "is this sink still broken?", which a monotonic total cannot answer.
	sinkFailures map[string]uint64

	sweeps         uint64
	clockUntrusted uint64

	// lastSuccessfulSweep distinguishes "nothing is expired" from "we stopped looking". A zero
	// overdue gauge means nothing at all if the last sweep was three weeks ago.
	lastSuccessfulSweep time.Time

	// maxOverdueAge is the worst breach in the last reconciliation, in seconds.
	maxOverdueAge float64

	// retainedPastPeriod counts copies deliberately retained past their retention period under
	// DispositionRetainedUnresolvableToken. It is PERMANENTLY non-zero once the attested plane is swept,
	// and that is the point: retained_unresolvable_token is a complete disposition, so those copies leave
	// the outstanding set and the overdue gauge reads zero for them. A dashboard showing only the overdue
	// gauge would therefore read "expired data remaining: 0" while the bytes are still on disk. This
	// keeps the residual on the screen rather than only in a compliance note.
	retainedPastPeriod map[string]int

	// stateUnknown is 1 when the last reconciliation could not run because the clock was untrusted.
	// Without it, a clock refusal leaves the previous clean gauge value standing while deadlines pass:
	// fail-closed on purging, fail-SILENT on detection. A zero overdue gauge means nothing if the
	// process stopped being able to look.
	stateUnknown int
}

// NewMetrics returns zeroed metrics.
//
// Zeroed rather than absent so a scrape during rollout reports 0 instead of an empty body. An empty
// body reads as "this subsystem does not exist", which is a materially different and much more
// reassuring claim than "it exists and has found nothing overdue" — and the reassuring reading is the
// wrong one during a rollout.
func NewMetrics() *Metrics {
	return &Metrics{
		overdue:            make(map[overdueKey]int),
		outstanding:        make(map[overdueKey]int),
		receipts:           make(map[Disposition]uint64),
		sinkFailures:       make(map[string]uint64),
		retainedPastPeriod: make(map[string]int),
	}
}

// ObserveSweep records that a sweep started.
func (m *Metrics) ObserveSweep() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sweeps++
}

// ObserveSuccessfulSweep records that a sweep completed its reconciliation.
func (m *Metrics) ObserveSuccessfulSweep(at time.Time) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.lastSuccessfulSweep = at.UTC()
	m.stateUnknown = 0
}

// ObserveClockUntrusted records a sweep aborted by an untrusted clock.
func (m *Metrics) ObserveClockUntrusted() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.clockUntrusted++
	m.stateUnknown = 1
}

// ObserveReceipt counts one receipt by disposition.
func (m *Metrics) ObserveReceipt(r DeletionReceipt) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.receipts[r.Disposition]++
	if r.Disposition == DispositionRetainedUnresolvableToken {
		m.retainedPastPeriod[r.SinkID] = 1
	}
}

// ObserveSinkFailure increments a sink's consecutive-failure count.
func (m *Metrics) ObserveSinkFailure(sinkID string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sinkFailures[sinkID]++
}

// ResetSinkFailures clears a sink's consecutive-failure count after a success.
func (m *Metrics) ResetSinkFailures(sinkID string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sinkFailures[sinkID] = 0
}

// SetOutstanding replaces the outstanding and overdue gauges from a ledger-derived set.
//
// The argument is the whole point: this is fed from Ledger.Outstanding, never from the sweep's own
// working memory. A gauge computed from the list the sweep just cleared cannot report non-zero, so it
// would pass every test and detect nothing. Reconcile exists so this can be refreshed with no sweep
// at all, and TestRetentionMetrics_GaugeRisesFromLedgerAlone asserts exactly that path.
func (m *Metrics) SetOutstanding(tenantID string, outstanding []Outstanding, asOf time.Time) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	// Clear this tenant's buckets first. Without it a copy that becomes complete leaves a stale
	// non-zero gauge behind and the alert never clears — which trains an operator to ignore it.
	for k := range m.overdue {
		if k.tenant == tenantID {
			delete(m.overdue, k)
		}
	}
	for k := range m.outstanding {
		if k.tenant == tenantID {
			delete(m.outstanding, k)
		}
	}

	m.maxOverdueAge = 0
	for _, o := range outstanding {
		disposition := string(o.Disposition)
		if disposition == "" {
			disposition = "never_evaluated"
		}
		reach := "unknown"
		if spec, ok := SpecByID(o.SinkID); ok {
			reach = string(spec.Reach)
		}
		key := overdueKey{tenant: o.TenantID, sink: o.SinkID, disposition: disposition, reach: reach}
		m.outstanding[key]++
		if age := o.OverdueAge(asOf); age > 0 {
			m.overdue[key]++
			if seconds := age.Seconds(); seconds > m.maxOverdueAge {
				m.maxOverdueAge = seconds
			}
		}
	}
}

// OverdueCount returns the total overdue objects across every bucket.
func (m *Metrics) OverdueCount() int {
	if m == nil {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	total := 0
	for _, n := range m.overdue {
		total += n
	}
	return total
}

// OverdueForSink returns the overdue count for one sink.
func (m *Metrics) OverdueForSink(tenantID, sinkID string) int {
	if m == nil {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	total := 0
	for k, n := range m.overdue {
		if k.tenant == tenantID && k.sink == sinkID {
			total += n
		}
	}
	return total
}

// ReceiptCount returns how many receipts carried a disposition.
func (m *Metrics) ReceiptCount(d Disposition) uint64 {
	if m == nil {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.receipts[d]
}

// ConsecutiveFailures returns a sink's consecutive-failure count.
func (m *Metrics) ConsecutiveFailures(sinkID string) uint64 {
	if m == nil {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sinkFailures[sinkID]
}

// Render produces Prometheus text exposition.
func (m *Metrics) Render() string {
	if m == nil {
		return ""
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	var b strings.Builder

	b.WriteString("# HELP signalloom_retention_overdue_objects Storage copies past their retention propagation deadline with no complete deletion receipt.\n")
	b.WriteString("# TYPE signalloom_retention_overdue_objects gauge\n")
	writeGauge(&b, "signalloom_retention_overdue_objects", m.overdue)

	b.WriteString("# HELP signalloom_retention_outstanding_objects Storage copies with no complete deletion receipt, whether or not their deadline has passed.\n")
	b.WriteString("# TYPE signalloom_retention_outstanding_objects gauge\n")
	writeGauge(&b, "signalloom_retention_outstanding_objects", m.outstanding)

	b.WriteString("# HELP signalloom_retention_overdue_age_seconds_max Age of the worst deadline breach observed at the last reconciliation.\n")
	b.WriteString("# TYPE signalloom_retention_overdue_age_seconds_max gauge\n")
	fmt.Fprintf(&b, "signalloom_retention_overdue_age_seconds_max %g\n", m.maxOverdueAge)

	b.WriteString("# HELP signalloom_retention_receipts_total Deletion receipts written, by disposition.\n")
	b.WriteString("# TYPE signalloom_retention_receipts_total counter\n")
	// Every disposition is rendered even at zero, for the same reason NewMetrics zeroes the maps: an
	// absent unreachable series reads as "no unreachable sinks", which is indistinguishable from
	// "this label has never been populated".
	for _, d := range allDispositions {
		fmt.Fprintf(&b, "signalloom_retention_receipts_total{disposition=%q} %d\n", string(d), m.receipts[d])
	}

	b.WriteString("# HELP signalloom_retention_sweeps_total Retention sweeps started.\n")
	b.WriteString("# TYPE signalloom_retention_sweeps_total counter\n")
	fmt.Fprintf(&b, "signalloom_retention_sweeps_total %d\n", m.sweeps)

	b.WriteString("# HELP signalloom_retention_clock_untrusted_total Sweeps aborted because the clock could not be trusted.\n")
	b.WriteString("# TYPE signalloom_retention_clock_untrusted_total counter\n")
	fmt.Fprintf(&b, "signalloom_retention_clock_untrusted_total %d\n", m.clockUntrusted)

	b.WriteString("# HELP signalloom_retention_sink_consecutive_failures Consecutive sweep failures per sink.\n")
	b.WriteString("# TYPE signalloom_retention_sink_consecutive_failures gauge\n")
	sinks := make([]string, 0, len(m.sinkFailures))
	for id := range m.sinkFailures {
		sinks = append(sinks, id)
	}
	sort.Strings(sinks)
	for _, id := range sinks {
		fmt.Fprintf(&b, "signalloom_retention_sink_consecutive_failures{sink=%q} %d\n", id, m.sinkFailures[id])
	}

	b.WriteString("# HELP signalloom_retention_retained_past_period Copies deliberately retained past their retention period as unresolvable tokens; permanently non-zero by design.\n")
	b.WriteString("# TYPE signalloom_retention_retained_past_period gauge\n")
	if len(m.retainedPastPeriod) == 0 {
		b.WriteString("signalloom_retention_retained_past_period{sink=\"\"} 0\n")
	} else {
		retained := make([]string, 0, len(m.retainedPastPeriod))
		for id := range m.retainedPastPeriod {
			retained = append(retained, id)
		}
		sort.Strings(retained)
		for _, id := range retained {
			fmt.Fprintf(&b, "signalloom_retention_retained_past_period{sink=%q} %d\n", id, m.retainedPastPeriod[id])
		}
	}

	b.WriteString("# HELP signalloom_retention_state_unknown Set when the last reconciliation could not run because the clock was untrusted; a zero overdue gauge is meaningless while this is set.\n")
	b.WriteString("# TYPE signalloom_retention_state_unknown gauge\n")
	fmt.Fprintf(&b, "signalloom_retention_state_unknown %d\n", m.stateUnknown)

	b.WriteString("# HELP signalloom_retention_last_successful_sweep_unix Unix seconds of the last completed reconciliation; 0 means none.\n")
	b.WriteString("# TYPE signalloom_retention_last_successful_sweep_unix gauge\n")
	var last int64
	if !m.lastSuccessfulSweep.IsZero() {
		last = m.lastSuccessfulSweep.Unix()
	}
	fmt.Fprintf(&b, "signalloom_retention_last_successful_sweep_unix %d\n", last)

	return b.String()
}

// writeGauge renders a labelled gauge, always emitting at least a zero series so an empty map is
// distinguishable from an absent subsystem.
func writeGauge(b *strings.Builder, name string, buckets map[overdueKey]int) {
	if len(buckets) == 0 {
		fmt.Fprintf(b, "%s{tenant=\"\",sink=\"\",disposition=\"\",reach=\"\"} 0\n", name)
		return
	}
	keys := make([]overdueKey, 0, len(buckets))
	for k := range buckets {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].tenant != keys[j].tenant {
			return keys[i].tenant < keys[j].tenant
		}
		if keys[i].sink != keys[j].sink {
			return keys[i].sink < keys[j].sink
		}
		return keys[i].disposition < keys[j].disposition
	})
	for _, k := range keys {
		fmt.Fprintf(b, "%s{tenant=%q,sink=%q,disposition=%q,reach=%q} %d\n", name, k.tenant, k.sink, k.disposition, k.reach, buckets[k])
	}
}
