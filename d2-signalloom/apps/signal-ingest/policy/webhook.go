// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// WebhookURLEnv configures the decision alert destination. Unset means no
// alerting: warn and enforce still store their decisions, and the absence is
// logged once at boot rather than per decision.
const WebhookURLEnv = "POLICY_ALERT_WEBHOOK_URL"

// Webhook retry budget (D5: "alert webhook with bounded retry").
const (
	// WebhookAttempts is the total number of POSTs for one decision, first try
	// included.
	WebhookAttempts = 3
	// WebhookBaseBackoff is the first inter-attempt delay; it doubles.
	WebhookBaseBackoff = 200 * time.Millisecond
	// WebhookBudget caps the wall-clock cost of all attempts together. It is a
	// HARD cap: the budget, not the attempt count, is what bounds the worst case,
	// because three attempts against a server that accepts the connection and
	// never answers would otherwise block for three client timeouts.
	WebhookBudget = 5 * time.Second
)

// Alerter delivers a decision to an external system.
type Alerter interface {
	Alert(ctx context.Context, d obscel.Decision) error
}

// Webhook POSTs the decision JSON to a configured URL with bounded retry.
//
// Retry is on the response, not on the decision: a 5xx or a transport error is
// retried, a 4xx is not. Retrying a 400 three times turns a permanent
// misconfiguration into three times the load and still loses the alert.
type Webhook struct {
	URL     string
	Client  *http.Client
	Metrics *Metrics
	Log     *slog.Logger

	// Attempts, BaseBackoff and Budget default to the constants above when zero.
	Attempts    int
	BaseBackoff time.Duration
	Budget      time.Duration

	// sleep and now are injected by tests so the backoff is not real time.
	sleep func(time.Duration)
	now   func() time.Time
}

// NewWebhookFromEnv returns a Webhook, or nil when POLICY_ALERT_WEBHOOK_URL is
// unset. A nil *Webhook is a valid Alerter that never alerts, so the caller does
// not branch.
func NewWebhookFromEnv(m *Metrics, log *slog.Logger) *Webhook {
	url := os.Getenv(WebhookURLEnv)
	if url == "" {
		return nil
	}
	return &Webhook{
		URL:     url,
		Client:  &http.Client{Timeout: WebhookBudget},
		Metrics: m,
		Log:     log,
	}
}

func (w *Webhook) attempts() int {
	if w.Attempts > 0 {
		return w.Attempts
	}
	return WebhookAttempts
}

func (w *Webhook) baseBackoff() time.Duration {
	if w.BaseBackoff > 0 {
		return w.BaseBackoff
	}
	return WebhookBaseBackoff
}

func (w *Webhook) budget() time.Duration {
	if w.Budget > 0 {
		return w.Budget
	}
	return WebhookBudget
}

func (w *Webhook) sleepFor(d time.Duration) {
	if w.sleep != nil {
		w.sleep(d)
		return
	}
	time.Sleep(d)
}

func (w *Webhook) clock() time.Time {
	if w.now != nil {
		return w.now()
	}
	return time.Now()
}

// Alert posts the decision, retrying within the budget. It returns the last
// error when every attempt failed, so the caller can count it; it never panics
// and never blocks past the budget.
func (w *Webhook) Alert(ctx context.Context, d obscel.Decision) error {
	if w == nil || w.URL == "" {
		return nil
	}

	body, err := json.Marshal(d)
	if err != nil {
		return fmt.Errorf("policy: marshalling decision %s: %w", d.ID, err)
	}

	client := w.Client
	if client == nil {
		client = &http.Client{Timeout: w.budget()}
	}

	deadline := w.clock().Add(w.budget())
	backoff := w.baseBackoff()
	var lastErr error

	for attempt := 1; attempt <= w.attempts(); attempt++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !w.clock().Before(deadline) {
			lastErr = fmt.Errorf("policy: webhook budget %s exhausted after %d attempt(s): %w",
				w.budget(), attempt-1, lastErr)
			break
		}

		err := w.post(ctx, client, body)
		if err == nil {
			w.Metrics.observeAlertSent()
			return nil
		}
		lastErr = err

		var perm *permanentError
		if asPermanent(err, &perm) {
			return err
		}

		if attempt < w.attempts() {
			w.sleepFor(backoff)
			backoff *= 2
		}
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("policy: webhook for decision %s failed with no recorded error", d.ID)
	}
	return lastErr
}

func (w *Webhook) post(ctx context.Context, client *http.Client, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.URL, bytes.NewReader(body))
	if err != nil {
		return &permanentError{err: err}
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != http.StatusTooManyRequests:
		return &permanentError{err: fmt.Errorf("policy: webhook rejected the alert with %d", resp.StatusCode)}
	default:
		return fmt.Errorf("policy: webhook returned %d", resp.StatusCode)
	}
}

// permanentError marks a response that retrying cannot fix.
type permanentError struct{ err error }

func (e *permanentError) Error() string { return e.err.Error() }
func (e *permanentError) Unwrap() error { return e.err }

func asPermanent(err error, target **permanentError) bool {
	for err != nil {
		if p, ok := err.(*permanentError); ok {
			*target = p
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

// AsyncAlerter hands decisions to a bounded background worker so alerting cannot
// extend the ingest path, which is what "never blocks ingest" (ISC-53) requires:
// the Webhook's own 5s budget is bounded but is still 5s of a collector's time.
//
// The queue is bounded and DROPS on overflow rather than blocking, counting the
// drop as an alert failure. Blocking would reintroduce exactly the coupling the
// wrapper exists to remove.
type AsyncAlerter struct {
	inner   Alerter
	queue   chan obscel.Decision
	wg      sync.WaitGroup
	metrics *Metrics
	log     *slog.Logger

	closeOnce sync.Once
}

// NewAsyncAlerter starts the worker. Close must be called to drain it.
func NewAsyncAlerter(inner Alerter, depth int, m *Metrics, log *slog.Logger) *AsyncAlerter {
	if log == nil {
		log = slog.Default()
	}
	if depth <= 0 {
		depth = 256
	}
	a := &AsyncAlerter{
		inner:   inner,
		queue:   make(chan obscel.Decision, depth),
		metrics: m,
		log:     log,
	}
	a.wg.Add(1)
	go a.run()
	return a
}

func (a *AsyncAlerter) run() {
	defer a.wg.Done()
	for d := range a.queue {
		// A fresh context: the ingest request that produced the decision may
		// already have returned, and inheriting its cancellation would cancel
		// every alert the moment the writer disconnected.
		ctx, cancel := context.WithTimeout(context.Background(), WebhookBudget)
		if err := a.inner.Alert(ctx, d); err != nil {
			a.metrics.observeAlertFailure()
			a.log.Error("policy decision alert failed", "decision", d.ID, "error", err)
		}
		cancel()
	}
}

// Alert enqueues the decision. It never blocks and never returns an error, so
// the Sink's own failure counting is driven by the worker rather than here.
func (a *AsyncAlerter) Alert(_ context.Context, d obscel.Decision) error {
	select {
	case a.queue <- d:
		return nil
	default:
		a.metrics.observeAlertFailure()
		a.log.Error("policy alert queue full; decision alert dropped (the decision itself is stored)",
			"decision", d.ID, "depth", cap(a.queue))
		return nil
	}
}

// Close drains the queue and waits for the worker.
func (a *AsyncAlerter) Close() {
	a.closeOnce.Do(func() { close(a.queue) })
	a.wg.Wait()
}
