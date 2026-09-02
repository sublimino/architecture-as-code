package client

import (
	"context"
	"testing"
	"time"
)

func TestMockReportsClient_PollEvents(t *testing.T) {
	client := NewMockReportsClient()
	ctx := context.Background()

	// Initial poll without filter
	events, err := client.PollEvents(ctx, time.Time{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(events) != 3 {
		t.Fatalf("expected 3 seeded events, got %d", len(events))
	}

	// Filter by timestamp
	cutoff := time.Now().UTC().Add(-4 * time.Minute)
	filtered, err := client.PollEvents(ctx, cutoff)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(filtered) != 1 {
		t.Fatalf("expected 1 event after cutoff, got %d", len(filtered))
	}
	if filtered[0].Type != EventTypeLogin {
		t.Errorf("expected login event, got %s", filtered[0].Type)
	}

	// Add dynamic event
	newEvent := WorkspaceEvent{
		ID:         "ws-evt-4",
		Type:       EventTypeDrive,
		ActorEmail: "agent-doc-summarizer@corp.internal",
		ActorID:    "spiffe://osramp.local/ns/agents/sa/doc-summarizer",
		Timestamp:  time.Now().UTC(),
		EventName:  "permission_change",
	}
	client.AddEvents(newEvent)

	all, _ := client.PollEvents(ctx, time.Time{})
	if len(all) != 4 {
		t.Errorf("expected 4 events after AddEvents, got %d", len(all))
	}
}
