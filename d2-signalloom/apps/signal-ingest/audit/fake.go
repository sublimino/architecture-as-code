package audit

import (
	"context"
	"sync"
)

// FakeWriter records audit events in memory for test assertions.
type FakeWriter struct {
	mu     sync.Mutex
	events []Event

	// FailWith, when non-nil, is returned from WriteAuditEvent to simulate
	// a Postgres failure.
	FailWith error
}

// NewFakeWriter returns a test-ready in-memory AuditWriter.
func NewFakeWriter() *FakeWriter {
	return &FakeWriter{}
}

func (f *FakeWriter) WriteAuditEvent(_ context.Context, event Event) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.FailWith != nil {
		return f.FailWith
	}
	f.events = append(f.events, event)
	return nil
}

// Events returns a snapshot of all recorded events.
func (f *FakeWriter) Events() []Event {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Event, len(f.events))
	copy(out, f.events)
	return out
}

// EventsByType returns events matching the given type.
func (f *FakeWriter) EventsByType(t EventType) []Event {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []Event
	for _, e := range f.events {
		if e.EventType == t {
			out = append(out, e)
		}
	}
	return out
}

// Reset clears all recorded events.
func (f *FakeWriter) Reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = nil
}
