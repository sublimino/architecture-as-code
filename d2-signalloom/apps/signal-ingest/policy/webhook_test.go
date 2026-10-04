// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

func testDecision() obscel.Decision {
	return obscel.Decision{
		ID:            "decision-1",
		Timestamp:     baseTime,
		TenantID:      testTenant,
		Actor:         "arn:aws:iam::1:user/agent",
		WindowID:      "iam-change-burst",
		RuleID:        "iam-priv-change",
		BundleID:      "test-iam",
		BundleVersion: "1.0.0",
		Severity:      "high",
		Mode:          obscel.ModeWarn,
		FindingIDs:    []string{"f-a", "f-b", "f-c"},
		Count:         3,
	}
}

// newTestWebhook returns a Webhook whose backoff is recorded rather than slept,
// so retry is deterministic and the suite stays fast. No network: httptest only.
func newTestWebhook(url string, m *Metrics, slept *[]time.Duration) *Webhook {
	return &Webhook{
		URL:         url,
		Client:      &http.Client{Timeout: 2 * time.Second},
		Metrics:     m,
		Attempts:    WebhookAttempts,
		BaseBackoff: 10 * time.Millisecond,
		Budget:      WebhookBudget,
		sleep:       func(d time.Duration) { *slept = append(*slept, d) },
	}
}

// ISC-53: two failures then success, inside the budget.
func TestWebhook_RetriesTwiceThenSucceeds(t *testing.T) {
	var calls atomic.Int32
	var bodies []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(b))
		if calls.Add(1) <= 2 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	m := NewMetrics()
	var slept []time.Duration
	wh := newTestWebhook(srv.URL, m, &slept)

	if err := wh.Alert(context.Background(), testDecision()); err != nil {
		t.Fatalf("Alert should have succeeded on the third attempt, got %v", err)
	}
	if got := calls.Load(); got != 3 {
		t.Errorf("POST attempts = %d, want 3", got)
	}
	if len(slept) != 2 {
		t.Fatalf("backoff waits = %d, want 2 (one between each pair of attempts)", len(slept))
	}
	if slept[1] <= slept[0] {
		t.Errorf("backoff did not grow: %v then %v", slept[0], slept[1])
	}
	if n := m.Snapshot().AlertsSent; n != 1 {
		t.Errorf("alerts_total = %d, want 1", n)
	}
	if n := m.Snapshot().AlertFailures; n != 0 {
		t.Errorf("alert_failures_total = %d, want 0", n)
	}

	// The payload is the decision JSON, and it carries the derived identity.
	var round obscel.Decision
	if err := json.Unmarshal([]byte(bodies[0]), &round); err != nil {
		t.Fatalf("webhook body is not decision JSON: %v", err)
	}
	if round.ID != "decision-1" || round.Count != 3 || round.Mode != obscel.ModeWarn {
		t.Errorf("round-tripped decision = %+v, want the posted one", round)
	}
	if !round.Timestamp.Equal(baseTime) {
		t.Errorf("posted timestamp = %v, want %v", round.Timestamp, baseTime)
	}
}

// A server that always fails exhausts the attempt budget, is counted, and
// returns an error rather than retrying for ever.
func TestWebhook_AlwaysFailingIsBoundedAndCounted(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()

	m := NewMetrics()
	var slept []time.Duration
	wh := newTestWebhook(srv.URL, m, &slept)

	err := wh.Alert(context.Background(), testDecision())
	if err == nil {
		t.Fatal("Alert should report failure after the budget is spent")
	}
	if !strings.Contains(err.Error(), "502") {
		t.Errorf("error should name the status, got %v", err)
	}
	if got := calls.Load(); got != WebhookAttempts {
		t.Errorf("POST attempts = %d, want exactly %d", got, WebhookAttempts)
	}
	if n := m.Snapshot().AlertsSent; n != 0 {
		t.Errorf("alerts_total = %d, want 0", n)
	}
}

// A 4xx is permanent: retrying a rejected payload three times triples the load
// and still loses the alert.
func TestWebhook_DoesNotRetryAPermanentRejection(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer srv.Close()

	var slept []time.Duration
	wh := newTestWebhook(srv.URL, NewMetrics(), &slept)

	if err := wh.Alert(context.Background(), testDecision()); err == nil {
		t.Fatal("a 400 must be reported as a failure")
	}
	if got := calls.Load(); got != 1 {
		t.Errorf("POST attempts on a 400 = %d, want 1 (no retry)", got)
	}
	if len(slept) != 0 {
		t.Errorf("a permanent rejection must not back off, slept %v", slept)
	}
}

// 429 is the one 4xx that IS retried.
func TestWebhook_RetriesTooManyRequests(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	var slept []time.Duration
	wh := newTestWebhook(srv.URL, NewMetrics(), &slept)
	if err := wh.Alert(context.Background(), testDecision()); err != nil {
		t.Fatalf("a 429 should be retried to success, got %v", err)
	}
	if got := calls.Load(); got != 2 {
		t.Errorf("POST attempts = %d, want 2", got)
	}
}

// The budget, not the attempt count, bounds the worst case.
func TestWebhook_BudgetStopsRetryingEvenWithAttemptsLeft(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	// A clock that jumps past the budget after the first attempt.
	now := baseTime
	wh := &Webhook{
		URL:         srv.URL,
		Client:      &http.Client{Timeout: time.Second},
		Metrics:     NewMetrics(),
		Attempts:    10,
		BaseBackoff: time.Millisecond,
		Budget:      5 * time.Second,
		sleep:       func(time.Duration) { now = now.Add(10 * time.Second) },
		now:         func() time.Time { return now },
	}

	err := wh.Alert(context.Background(), testDecision())
	if err == nil {
		t.Fatal("want a failure once the budget is spent")
	}
	if !strings.Contains(err.Error(), "budget") {
		t.Errorf("error should name the exhausted budget, got %v", err)
	}
	if got := calls.Load(); got != 1 {
		t.Errorf("POST attempts = %d, want 1 (the budget stopped it with 9 attempts left)", got)
	}
}

// An unset POLICY_ALERT_WEBHOOK_URL yields a nil *Webhook, which is a valid
// Alerter that never alerts, so no caller branches on configuration.
func TestWebhook_NilAlerterIsSafe(t *testing.T) {
	t.Setenv(WebhookURLEnv, "")
	wh := NewWebhookFromEnv(NewMetrics(), nil)
	if wh != nil {
		t.Fatalf("unset %s should yield a nil Webhook, got %+v", WebhookURLEnv, wh)
	}
	if err := wh.Alert(context.Background(), testDecision()); err != nil {
		t.Errorf("a nil Webhook must be a no-op Alerter, got %v", err)
	}
}

func TestWebhook_FromEnvReadsTheURL(t *testing.T) {
	t.Setenv(WebhookURLEnv, "http://example.invalid/hook")
	wh := NewWebhookFromEnv(NewMetrics(), nil)
	if wh == nil || wh.URL != "http://example.invalid/hook" {
		t.Fatalf("NewWebhookFromEnv did not read %s", WebhookURLEnv)
	}
}

// ---------------------------------------------------------------------------
// AsyncAlerter: alerting must never extend the ingest path
// ---------------------------------------------------------------------------

func TestAsyncAlerter_DoesNotBlockIngest(t *testing.T) {
	release := make(chan struct{})
	slow := &blockingAlerter{release: release}
	m := NewMetrics()
	a := NewAsyncAlerter(slow, 8, m, nil)

	start := time.Now()
	for range 4 {
		if err := a.Alert(context.Background(), testDecision()); err != nil {
			t.Fatalf("Alert must never return an error to the caller, got %v", err)
		}
	}
	elapsed := time.Since(start)
	if elapsed > time.Second {
		t.Errorf("enqueueing 4 alerts took %v; the caller is being blocked by delivery", elapsed)
	}

	close(release)
	a.Close()
	if n := slow.delivered.Load(); n != 4 {
		t.Errorf("delivered %d alerts, want 4 after Close drained the queue", n)
	}
}

// Overflow drops and counts rather than blocking, which is the whole point of
// the wrapper.
func TestAsyncAlerter_OverflowDropsAndCounts(t *testing.T) {
	release := make(chan struct{})
	slow := &blockingAlerter{release: release}
	m := NewMetrics()
	a := NewAsyncAlerter(slow, 1, m, nil)

	// 1 in the worker, 1 in the queue, the rest must be dropped.
	for range 12 {
		_ = a.Alert(context.Background(), testDecision())
	}
	if n := m.Snapshot().AlertFailures; n == 0 {
		t.Error("overflowing a depth-1 queue recorded no alert failures")
	}
	close(release)
	a.Close()
}

type blockingAlerter struct {
	release   chan struct{}
	delivered atomic.Int32
}

func (b *blockingAlerter) Alert(_ context.Context, _ obscel.Decision) error {
	<-b.release
	b.delivered.Add(1)
	return nil
}

// ---------------------------------------------------------------------------
// Counters render as Prometheus text for main.go's metricsHandler
// ---------------------------------------------------------------------------

func TestMetrics_RenderCarriesEverySeriesEvenAtZero(t *testing.T) {
	m := NewMetrics()
	out := m.Render()
	for _, want := range []string{
		"signalloom_policy_findings_total",
		"signalloom_policy_decisions_total",
		"signalloom_policy_evaluator_errors_total",
		"signalloom_policy_finding_write_errors_total",
		"signalloom_policy_decision_write_errors_total",
		"signalloom_policy_alerts_total",
		"signalloom_policy_alert_failures_total",
		"signalloom_policy_warmup_findings",
		"signalloom_policy_windows_loaded",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("Render() omits %s; an absent series reads as 'no faults' rather than 'not wired up'", want)
		}
	}
	// Every mode renders even with no decisions.
	for _, mode := range allModes {
		if !strings.Contains(out, `mode="`+string(mode)+`"} 0`) {
			t.Errorf("Render() omits a zeroed series for mode %q", mode)
		}
	}
}

func TestMetrics_CountsThroughTheSink(t *testing.T) {
	inner, m := runBurst(t, obscel.ModeWarn, 3, nil, &recordingAlerter{})
	snap := m.Snapshot()
	if snap.Findings != 3 {
		t.Errorf("findings = %d, want 3", snap.Findings)
	}
	if snap.Decisions != 1 {
		t.Errorf("decisions = %d, want 1", snap.Decisions)
	}
	if snap.FindingsBySeverity["high"] != 3 {
		t.Errorf("findings{severity=high} = %d, want 3", snap.FindingsBySeverity["high"])
	}
	if n := len(inner.bySource(obscel.SourceFinding)); uint64(n) != snap.Findings {
		t.Errorf("stored findings (%d) and counted findings (%d) disagree", n, snap.Findings)
	}
	if !strings.Contains(m.Render(), `signalloom_policy_findings_total{severity="high"} 3`) {
		t.Errorf("Render() does not reflect the counted findings:\n%s", m.Render())
	}
}

// A decision alert that fails is counted and does not fail ingest.
func TestSink_AlertFailureIsCountedNotReturned(t *testing.T) {
	alerter := &recordingAlerter{err: io.ErrUnexpectedEOF}
	_, m := runBurst(t, obscel.ModeEnforce, 3, nil, alerter)
	if n := m.Snapshot().AlertFailures; n != 1 {
		t.Errorf("alert_failures_total = %d, want 1", n)
	}
}

func TestMetrics_NilIsANoOp(t *testing.T) {
	var m *Metrics
	m.observeFinding("high")
	m.observeDecision("warn")
	m.observeEvaluatorError()
	m.ObserveWarmup(5, 2)
	if got := m.Render(); got != "" {
		t.Errorf("a nil Metrics must render nothing, got %q", got)
	}
	if snap := m.Snapshot(); snap.Findings != 0 {
		t.Errorf("a nil Metrics must snapshot zero, got %+v", snap)
	}
}
