package audit

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

func TestAllEventTypesWritable(t *testing.T) {
	fake := NewFakeWriter()
	ctx := context.Background()

	for _, et := range AllEventTypes {
		detail, _ := json.Marshal(map[string]string{"test": "true"})
		err := fake.WriteAuditEvent(ctx, Event{
			TenantID:  "tenant-demo",
			EventType: et,
			Detail:    detail,
		})
		if err != nil {
			t.Errorf("WriteAuditEvent(%s) returned error: %v", et, err)
		}
	}

	events := fake.Events()
	if len(events) != len(AllEventTypes) {
		t.Fatalf("want %d events, got %d", len(AllEventTypes), len(events))
	}

	// Verify each event type appears exactly once.
	seen := make(map[EventType]int)
	for _, e := range events {
		seen[e.EventType]++
	}
	for _, et := range AllEventTypes {
		if seen[et] != 1 {
			t.Errorf("event type %s: want 1, got %d", et, seen[et])
		}
	}
}

func TestFakeWriter_FailWith(t *testing.T) {
	fake := NewFakeWriter()
	fake.FailWith = errors.New("postgres down")

	err := fake.WriteAuditEvent(context.Background(), Event{
		TenantID:  "tenant-demo",
		EventType: EventActorPromoted,
		Detail:    json.RawMessage(`{}`),
	})
	if err == nil {
		t.Fatal("expected error when FailWith is set")
	}
	if err.Error() != "postgres down" {
		t.Errorf("unexpected error: %v", err)
	}

	// No events recorded on failure.
	if len(fake.Events()) != 0 {
		t.Error("events should not be recorded on failure")
	}
}

func TestFakeWriter_EventsByType(t *testing.T) {
	fake := NewFakeWriter()
	ctx := context.Background()

	fake.WriteAuditEvent(ctx, Event{EventType: EventActorPromoted, Detail: json.RawMessage(`{}`)})
	fake.WriteAuditEvent(ctx, Event{EventType: EventCorrelationRun, Detail: json.RawMessage(`{}`)})
	fake.WriteAuditEvent(ctx, Event{EventType: EventActorPromoted, Detail: json.RawMessage(`{}`)})

	promoted := fake.EventsByType(EventActorPromoted)
	if len(promoted) != 2 {
		t.Errorf("want 2 promoted events, got %d", len(promoted))
	}

	dismissed := fake.EventsByType(EventActorDismissed)
	if len(dismissed) != 0 {
		t.Errorf("want 0 dismissed events, got %d", len(dismissed))
	}
}

// TestNopWriter_FailClosedByDefault asserts that NopWriter fails closed by default
// returning ErrAuditDisabled to prevent silent un-audited operations in production.
func TestNopWriter_FailClosedByDefault(t *testing.T) {
	var w NopWriter
	err := w.WriteAuditEvent(context.Background(), Event{
		EventType: EventActorPromoted,
		Detail:    json.RawMessage(`{}`),
	})
	if err == nil {
		t.Fatal("expected ErrAuditDisabled from default NopWriter")
	}
	if !errors.Is(err, ErrAuditDisabled) {
		t.Errorf("expected ErrAuditDisabled, got: %v", err)
	}

	posture := w.AuditPosture()
	if posture.Healthy {
		t.Errorf("expected posture Healthy to be false")
	}
	if posture.Policy != "refuse_all" {
		t.Errorf("expected policy refuse_all, got %s", posture.Policy)
	}
}

// TestNopWriter_DevelopmentOptInAllowed asserts that NopWriter permits event discard
// only when explicitly configured with AllowDiscard: true.
func TestNopWriter_DevelopmentOptInAllowed(t *testing.T) {
	w := NewNopWriter(true)
	err := w.WriteAuditEvent(context.Background(), Event{
		EventType: EventActorPromoted,
		Detail:    json.RawMessage(`{}`),
	})
	if err != nil {
		t.Fatalf("expected nil error when AllowDiscard=true, got: %v", err)
	}

	posture := w.AuditPosture()
	if posture.Healthy {
		t.Errorf("expected posture Healthy to be false for dev discard")
	}
	if posture.Policy != "discard_insecure" {
		t.Errorf("expected policy discard_insecure, got %s", posture.Policy)
	}
}

// TestAuditPosture_Reporting asserts accurate compliance posture reporting across writers.
func TestAuditPosture_Reporting(t *testing.T) {
	nilPosture := GetAuditPosture(nil)
	if nilPosture.Healthy || nilPosture.Backend != "none" {
		t.Errorf("unexpected posture for nil audit writer: %+v", nilPosture)
	}

	fake := NewFakeWriter()
	fakePosture := GetAuditPosture(fake)
	if !fakePosture.Healthy || fakePosture.Backend != "fake_memory" {
		t.Errorf("unexpected posture for fake writer: %+v", fakePosture)
	}

	fake.FailWith = errors.New("simulated error")
	fakeDegraded := GetAuditPosture(fake)
	if fakeDegraded.Healthy {
		t.Errorf("expected fake degraded posture to be unhealthy")
	}
}

func TestFakeWriter_Reset(t *testing.T) {
	fake := NewFakeWriter()
	fake.WriteAuditEvent(context.Background(), Event{EventType: EventCollectorRun, Detail: json.RawMessage(`{}`)})
	if len(fake.Events()) != 1 {
		t.Fatal("expected 1 event before reset")
	}
	fake.Reset()
	if len(fake.Events()) != 0 {
		t.Error("expected 0 events after reset")
	}
}
