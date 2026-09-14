// Package audit defines the AuditWriter interface and event types for the
// signal_audit_trail table.
package audit

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

var (
	// ErrAuditDisabled is returned when an audit event is submitted to an unconfigured or disabled audit writer.
	ErrAuditDisabled = errors.New("audit backend is unconfigured or disabled: audit event cannot be persisted")
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

// AuditPosture captures the runtime audit state for compliance posture and health reporting.
type AuditPosture struct {
	Backend string `json:"backend"`
	Mode    string `json:"mode"`
	Policy  string `json:"policy"`
	Healthy bool   `json:"healthy"`
}

// PostureAware is implemented by audit writers that can report their posture.
type PostureAware interface {
	AuditPosture() AuditPosture
}

// AuditWriter is the injectable interface for writing audit events.
// Implementations must be safe for concurrent use.
type AuditWriter interface {
	// WriteAuditEvent persists one audit event to the tamper-evident audit trail.
	// Failures must never be silently swallowed or discarded; implementations
	// must return an error when persistence fails so callers and operators can
	// enforce compliance policy (refuse the operation or record degradation).
	WriteAuditEvent(ctx context.Context, event Event) error
}

// NopWriter is an AuditWriter used for development or test environments where audit persistence is disabled.
// In default mode, it fails closed by returning ErrAuditDisabled to prevent silent non-audited executions.
// Development fixtures may explicitly construct NopWriter with AllowDiscard: true.
type NopWriter struct {
	AllowDiscard bool
}

// NewNopWriter constructs a NopWriter with an explicit discard policy.
func NewNopWriter(allowDiscard bool) *NopWriter {
	return &NopWriter{AllowDiscard: allowDiscard}
}

// WriteAuditEvent writes an event or returns ErrAuditDisabled if discarding is not opted into.
func (n NopWriter) WriteAuditEvent(_ context.Context, _ Event) error {
	if n.AllowDiscard {
		return nil
	}
	return ErrAuditDisabled
}

// AuditPosture returns the compliance posture of the NopWriter.
func (n NopWriter) AuditPosture() AuditPosture {
	if n.AllowDiscard {
		return AuditPosture{
			Backend: "nop",
			Mode:    "development_discard_opt_in",
			Policy:  "discard_insecure",
			Healthy: false,
		}
	}
	return AuditPosture{
		Backend: "nop",
		Mode:    "fail_closed_unconfigured",
		Policy:  "refuse_all",
		Healthy: false,
	}
}

// GetAuditPosture inspects any AuditWriter and returns its effective security and compliance posture.
func GetAuditPosture(w AuditWriter) AuditPosture {
	if w == nil {
		return AuditPosture{
			Backend: "none",
			Mode:    "unconfigured",
			Policy:  "refuse_all",
			Healthy: false,
		}
	}
	if pa, ok := w.(PostureAware); ok {
		return pa.AuditPosture()
	}
	return AuditPosture{
		Backend: "custom",
		Mode:    "enforced",
		Policy:  "fail_closed",
		Healthy: true,
	}
}
