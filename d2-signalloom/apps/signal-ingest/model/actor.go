package model

import "time"

// ActorStatus tracks the lifecycle of a provisional actor.
type ActorStatus string

const (
	ActorProvisional ActorStatus = "provisional"
	ActorActionable  ActorStatus = "actionable"
	ActorPromoted    ActorStatus = "promoted"
	ActorRevoked     ActorStatus = "revoked"
)

// Actor is an alias for ProvisionalActor representing a resolved or provisional actor entity.
type Actor = ProvisionalActor

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

	// Additive resolution fields (SFDP-P1-2)
	CanonicalID string            `json:"canonical_id,omitempty"`
	PrincipalID string            `json:"principal_id,omitempty"`
	Aliases     []string          `json:"aliases,omitempty"`
	Attributes  map[string]string `json:"attributes,omitempty"`
	ResolvedAt  *time.Time        `json:"resolved_at,omitempty"`

	// Additive deterministic-correlation fields (SFDP-P3-1).
	AcceptedEdges []CorrelationEdge `json:"accepted_edges,omitempty"`
	DeclinedEdges []CorrelationEdge `json:"declined_edges,omitempty"`
	Delegations   []CorrelationEdge `json:"delegations,omitempty"`
	Lineage       []ActorLineage    `json:"lineage,omitempty"`
}

// EvidenceLink records one observation's contribution to an actor hypothesis.
type EvidenceLink struct {
	ObservationID string       `json:"observation_id"`
	Layer         Layer        `json:"layer"`
	Fidelity      FidelityTier `json:"fidelity"`
	Contribution  string       `json:"contribution"`
	Timestamp     time.Time    `json:"timestamp"`
}
