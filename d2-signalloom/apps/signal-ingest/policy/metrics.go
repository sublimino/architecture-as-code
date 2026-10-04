// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Metrics counts what the pipeline did and, more importantly, what it failed to
// do (ISC-53).
//
// It follows the existing signal-ingest pattern — a mutex-guarded struct with a
// Render() that writes Prometheus text, composed into main.go's single
// metricsHandler — rather than introducing an expvar surface or a new route.
// That keeps the counters behind the same authentication as every other series
// and means no api/ route table edit.
//
// Every series renders at zero rather than being absent, for the reason stated
// in retention/metrics.go: an absent `evaluator_errors_total` reads as "no
// evaluator faults", which is indistinguishable from "this counter was never
// wired up".
type Metrics struct {
	mu sync.Mutex

	findingsBySeverity map[string]uint64
	decisionsByMode    map[string]uint64

	evaluatorErrors     uint64
	findingWriteErrors  uint64
	decisionWriteErrors uint64
	alertFailures       uint64
	alertsSent          uint64
	warmupFindings      uint64
	windowsLoaded       int
}

// Snapshot is a point-in-time copy, for tests and for the stats surface.
type Snapshot struct {
	Findings            uint64
	Decisions           uint64
	EvaluatorErrors     uint64
	FindingWriteErrors  uint64
	DecisionWriteErrors uint64
	AlertFailures       uint64
	AlertsSent          uint64
	WarmupFindings      uint64
	WindowsLoaded       int
	FindingsBySeverity  map[string]uint64
	DecisionsByMode     map[string]uint64
}

// NewMetrics returns a zeroed counter set with every mode pre-populated.
func NewMetrics() *Metrics {
	m := &Metrics{
		findingsBySeverity: make(map[string]uint64),
		decisionsByMode:    make(map[string]uint64),
	}
	for _, mode := range allModes {
		m.decisionsByMode[string(mode)] = 0
	}
	return m
}

var allModes = []obscel.Mode{obscel.ModeShadow, obscel.ModeWarn, obscel.ModeEnforce}

func (m *Metrics) observeFinding(severity string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.findingsBySeverity[severity]++
}

func (m *Metrics) observeDecision(mode string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.decisionsByMode[mode]++
}

func (m *Metrics) observeEvaluatorError() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.evaluatorErrors++
}

func (m *Metrics) observeFindingWriteError() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.findingWriteErrors++
}

func (m *Metrics) observeDecisionWriteError() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.decisionWriteErrors++
}

func (m *Metrics) observeAlertFailure() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.alertFailures++
}

func (m *Metrics) observeAlertSent() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.alertsSent++
}

// ObserveWarmup records what boot-time warm-up rebuilt (ISC-50). Exported
// because warm-up is driven from main.go, not from the sink.
func (m *Metrics) ObserveWarmup(findings uint64, windows int) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.warmupFindings = findings
	m.windowsLoaded = windows
}

// Snapshot returns a copy of every counter.
func (m *Metrics) Snapshot() Snapshot {
	if m == nil {
		return Snapshot{}
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	s := Snapshot{
		EvaluatorErrors:     m.evaluatorErrors,
		FindingWriteErrors:  m.findingWriteErrors,
		DecisionWriteErrors: m.decisionWriteErrors,
		AlertFailures:       m.alertFailures,
		AlertsSent:          m.alertsSent,
		WarmupFindings:      m.warmupFindings,
		WindowsLoaded:       m.windowsLoaded,
		FindingsBySeverity:  make(map[string]uint64, len(m.findingsBySeverity)),
		DecisionsByMode:     make(map[string]uint64, len(m.decisionsByMode)),
	}
	for k, v := range m.findingsBySeverity {
		s.FindingsBySeverity[k] = v
		s.Findings += v
	}
	for k, v := range m.decisionsByMode {
		s.DecisionsByMode[k] = v
		s.Decisions += v
	}
	return s
}

// Render writes the counters in Prometheus text format, for composition into
// main.go's metricsHandler.
func (m *Metrics) Render() string {
	if m == nil {
		return ""
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	var b strings.Builder

	b.WriteString("# HELP signalloom_policy_findings_total Stage-1 observation-policy findings emitted, by severity.\n")
	b.WriteString("# TYPE signalloom_policy_findings_total counter\n")
	for _, sev := range sortedKeys(m.findingsBySeverity) {
		fmt.Fprintf(&b, "signalloom_policy_findings_total{severity=%q} %d\n", sev, m.findingsBySeverity[sev])
	}

	b.WriteString("# HELP signalloom_policy_decisions_total Stage-2 observation-policy decisions emitted, by bundle mode.\n")
	b.WriteString("# TYPE signalloom_policy_decisions_total counter\n")
	for _, mode := range allModes {
		fmt.Fprintf(&b, "signalloom_policy_decisions_total{mode=%q} %d\n", string(mode), m.decisionsByMode[string(mode)])
	}

	b.WriteString("# HELP signalloom_policy_evaluator_errors_total Rules that faulted at evaluation. Detection is degraded; ingest is not.\n")
	b.WriteString("# TYPE signalloom_policy_evaluator_errors_total counter\n")
	fmt.Fprintf(&b, "signalloom_policy_evaluator_errors_total %d\n", m.evaluatorErrors)

	b.WriteString("# HELP signalloom_policy_finding_write_errors_total Findings that were detected and could not be stored.\n")
	b.WriteString("# TYPE signalloom_policy_finding_write_errors_total counter\n")
	fmt.Fprintf(&b, "signalloom_policy_finding_write_errors_total %d\n", m.findingWriteErrors)

	b.WriteString("# HELP signalloom_policy_decision_write_errors_total Decisions that were reached and could not be stored.\n")
	b.WriteString("# TYPE signalloom_policy_decision_write_errors_total counter\n")
	fmt.Fprintf(&b, "signalloom_policy_decision_write_errors_total %d\n", m.decisionWriteErrors)

	b.WriteString("# HELP signalloom_policy_alerts_total Decision alerts delivered to the configured webhook.\n")
	b.WriteString("# TYPE signalloom_policy_alerts_total counter\n")
	fmt.Fprintf(&b, "signalloom_policy_alerts_total %d\n", m.alertsSent)

	b.WriteString("# HELP signalloom_policy_alert_failures_total Decision alerts abandoned after the bounded retry budget.\n")
	b.WriteString("# TYPE signalloom_policy_alert_failures_total counter\n")
	fmt.Fprintf(&b, "signalloom_policy_alert_failures_total %d\n", m.alertFailures)

	b.WriteString("# HELP signalloom_policy_warmup_findings Findings replayed from the store at boot to rebuild stage-2 counters.\n")
	b.WriteString("# TYPE signalloom_policy_warmup_findings gauge\n")
	fmt.Fprintf(&b, "signalloom_policy_warmup_findings %d\n", m.warmupFindings)

	b.WriteString("# HELP signalloom_policy_windows_loaded Stage-2 windows declared by the boot-loaded bundle set.\n")
	b.WriteString("# TYPE signalloom_policy_windows_loaded gauge\n")
	fmt.Fprintf(&b, "signalloom_policy_windows_loaded %d\n", m.windowsLoaded)

	return b.String()
}

func sortedKeys(m map[string]uint64) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
