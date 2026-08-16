package model

import "time"

// ActorStatus tracks the lifecycle of a provisional actor.
type ActorStatus string

const (
	ActorProvisional ActorStatus = "provisional"
	ActorActionable  ActorStatus = "actionable"
	ActorPromoted    ActorStatus = "promoted"
)

// ProvisionalActor is a correlated entity assembled from cross-layer signals.
type ProvisionalActor struct {
	ID              string         `json:"id"`
	Status          ActorStatus    `json:"status"`
	Confidence      float64        `json:"confidence"`
	EvidenceChain   []EvidenceLink `json:"evidence_chain"`
	CorrelationKeys []string       `json:"correlation_keys"`
	CreatedAt       time.Time      `json:"created_at"`
	UpdatedAt       time.Time      `json:"updated_at"`
	PromotedAt      *time.Time     `json:"promoted_at,omitempty"`
	AgentRegistryID *string        `json:"agent_registry_id,omitempty"`
}

// EvidenceLink records one observation's contribution to an actor hypothesis.
type EvidenceLink struct {
	ObservationID string       `json:"observation_id"`
	Layer         Layer        `json:"layer"`
	Fidelity      FidelityTier `json:"fidelity"`
	Contribution  string       `json:"contribution"`
	Timestamp     time.Time    `json:"timestamp"`
}
