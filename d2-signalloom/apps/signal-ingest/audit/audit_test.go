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

func TestNopWriter(t *testing.T) {
	var w NopWriter
	err := w.WriteAuditEvent(context.Background(), Event{
		EventType: EventActorPromoted,
		Detail:    json.RawMessage(`{}`),
	})
	if err != nil {
		t.Errorf("NopWriter should never error, got: %v", err)
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
