// Package audit defines the AuditWriter interface and event types for the
// signal_audit_trail table.
package audit

import (
	"context"
	"encoding/json"
	"time"
)

// EventType enumerates the legal values for signal_audit_trail.event_type.
type EventType string

const (
	EventObservationIngested EventType = "observation_ingested"
	EventCorrelationRun      EventType = "correlation_run"
	EventActorCreated        EventType = "actor_created"
	EventActorUpdated        EventType = "actor_updated"
	EventActorPromoted       EventType = "actor_promoted"
	EventActorDismissed      EventType = "actor_dismissed"
	EventCollectorRun        EventType = "collector_run"
	EventPartitionDropped    EventType = "partition_dropped"
)

// AllEventTypes lists every event type admitted by the CHECK constraint.
var AllEventTypes = []EventType{
	EventObservationIngested,
	EventCorrelationRun,
	EventActorCreated,
	EventActorUpdated,
	EventActorPromoted,
	EventActorDismissed,
	EventCollectorRun,
	EventPartitionDropped,
}

// Event is a single audit trail record destined for signal_audit_trail.
type Event struct {
	TenantID  string          `json:"tenant_id"`
	EventType EventType       `json:"event_type"`
	ActorID   string          `json:"actor_id,omitempty"` // empty if not actor-scoped
	Detail    json.RawMessage `json:"detail"`
	CreatedAt time.Time       `json:"created_at"`
}

// AuditWriter is the injectable interface for writing audit events.
// Implementations must be safe for concurrent use.
type AuditWriter interface {
	// WriteAuditEvent persists one audit event. Implementations should not
	// return errors for transient failures in demo-grade deployments —
	// log and continue.
	WriteAuditEvent(ctx context.Context, event Event) error
}

// NopWriter is an AuditWriter that silently discards all events.
// Used when no Postgres connection is configured.
type NopWriter struct{}

func (NopWriter) WriteAuditEvent(context.Context, Event) error { return nil }
