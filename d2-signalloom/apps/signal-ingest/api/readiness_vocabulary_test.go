package api

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// See audit/vocabulary_test.go for the live incident: signal-ingest reported
// Ready while its database rejected one of its event types, so every batch
// 503'd. /readyz now refuses until the constraint admits them all.

func vocabGap() error {
	return &audit.VocabularyError{Missing: []audit.EventType{audit.EventBatchChain}}
}

func TestReadyzRefusesWhileAnEventTypeIsNotAdmitted(t *testing.T) {
	h := &Handlers{
		AuditReady:      func(context.Context) error { return nil },
		AuditVocabulary: func(context.Context) error { return vocabGap() },
	}
	w := probeGet(t, NewProbeHandler(h), http.MethodGet, "/readyz")
	body := decodeBody(t, w)
	if w.Code != http.StatusServiceUnavailable || body["reason"] != "audit_vocabulary_not_admitted" {
		t.Fatalf("GET /readyz: %d %s, want 503 audit_vocabulary_not_admitted", w.Code, w.Body.String())
	}
	if body["missing_event_types"] != "batch_chain" {
		t.Fatalf("missing_event_types = %q, want batch_chain", body["missing_event_types"])
	}
}

func TestReadyzIsReadyOnceEveryTypeIsAdmitted(t *testing.T) {
	h := &Handlers{
		AuditReady:      func(context.Context) error { return nil },
		AuditVocabulary: func(context.Context) error { return nil },
	}
	if w := probeGet(t, NewProbeHandler(h), http.MethodGet, "/readyz"); w.Code != http.StatusOK {
		t.Fatalf("GET /readyz: %d %s, want 200", w.Code, w.Body.String())
	}
}

// A check that cannot run is not a pass.
func TestReadyzFailsClosedWhenTheVocabularyCheckErrors(t *testing.T) {
	for _, err := range []error{errors.New("pq: canceling statement due to statement timeout"), audit.ErrEventTypeConstraintAbsent} {
		h := &Handlers{
			AuditReady:      func(context.Context) error { return nil },
			AuditVocabulary: func(context.Context) error { return err },
		}
		w := probeGet(t, NewProbeHandler(h), http.MethodGet, "/readyz")
		if w.Code != http.StatusServiceUnavailable || decodeBody(t, w)["reason"] != "audit_vocabulary_not_admitted" {
			t.Fatalf("%v: %d %s, want 503", err, w.Code, w.Body.String())
		}
	}
}

// The backend being down is reported as that, not as a vocabulary gap.
func TestReadyzReportsAnUnreachableBackendBeforeTheVocabulary(t *testing.T) {
	h := &Handlers{
		AuditReady:      func(context.Context) error { return errors.New("dial tcp: i/o timeout") },
		AuditVocabulary: func(context.Context) error { t.Fatal("vocabulary queried with the backend down"); return nil },
	}
	if r := decodeBody(t, probeGet(t, NewProbeHandler(h), http.MethodGet, "/readyz"))["reason"]; r != "audit_backend_unreachable" {
		t.Fatalf("reason = %q", r)
	}
}

// Never silent, never a flood: the missing types are logged at most once per
// interval however often /readyz is asked.
func TestReadyzLogsTheMissingTypesAtMostOncePerInterval(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })

	now := time.Date(2026, 10, 3, 9, 0, 0, 0, time.UTC)
	h := &Handlers{
		AuditReady:           func(context.Context) error { return nil },
		AuditVocabulary:      func(context.Context) error { return vocabGap() },
		ReadinessLogInterval: 10 * time.Second,
		now:                  func() time.Time { return now },
	}
	probe := NewProbeHandler(h)
	count := func() int { return strings.Count(buf.String(), "audit_vocabulary_not_admitted") }

	for i := 0; i < 3; i++ {
		probeGet(t, probe, http.MethodGet, "/readyz")
	}
	if count() != 1 || !strings.Contains(buf.String(), "batch_chain") {
		t.Fatalf("3 probes inside one interval logged %d times (want 1, naming batch_chain):\n%s", count(), buf.String())
	}
	now = now.Add(10 * time.Second)
	probeGet(t, probe, http.MethodGet, "/readyz")
	if count() != 2 {
		t.Fatalf("after one interval: %d log lines, want 2", count())
	}
}
