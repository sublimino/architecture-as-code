package model

import "time"

// EdgeFidelity is the existing structural evidence vocabulary used by edges.
// It is an alias, deliberately introducing no new confidence constants.
type EdgeFidelity = FidelityTier

// EdgeType is the closed identity-correlation algebra.
type EdgeType string

const (
	EdgeDeterministicSameEntity EdgeType = "deterministic_same_entity"
	EdgeProbabilisticSameEntity EdgeType = "probabilistic_same_entity"
	EdgeTemporal                EdgeType = "temporal"
	EdgeIPCircumstantial        EdgeType = "ip_circumstantial"
	EdgeActsOnBehalfOf          EdgeType = "acts_on_behalf_of"
	EdgeCannotLink              EdgeType = "cannot_link"
)

// IsValid reports whether the edge belongs to the closed algebra.
func (e EdgeType) IsValid() bool {
	switch e {
	case EdgeDeterministicSameEntity, EdgeProbabilisticSameEntity, EdgeTemporal,
		EdgeIPCircumstantial, EdgeActsOnBehalfOf, EdgeCannotLink:
		return true
	default:
		return false
	}
}

// TypedIdentifier prevents equal-looking values from different authorities or
// identifier schemes from colliding.
type TypedIdentifier struct {
	Issuer string `json:"issuer"`
	Scheme string `json:"scheme"`
	Value  string `json:"value"`
}

// String supplies a stable total ordering and serialization key.
func (i TypedIdentifier) String() string { return i.Issuer + "|" + i.Scheme + "|" + i.Value }

// EdgeProvenance records exactly why an edge was produced or declined.
type EdgeProvenance struct {
	ObservationIDs []string  `json:"observation_ids"`
	Source         string    `json:"source"`
	Field          string    `json:"field"`
	Rule           string    `json:"rule,omitempty"`
	Authenticated  bool      `json:"authenticated"`
	Accepted       bool      `json:"accepted"`
	Reason         string    `json:"reason"`
	Timestamp      time.Time `json:"timestamp"`
}

// CorrelationEdge is a serializable typed relationship between observations.
type CorrelationEdge struct {
	ID              string          `json:"id"`
	Type            EdgeType        `json:"type"`
	Fidelity        EdgeFidelity    `json:"fidelity"`
	From            TypedIdentifier `json:"from"`
	To              TypedIdentifier `json:"to"`
	FromObservation string          `json:"from_observation"`
	ToObservation   string          `json:"to_observation"`
	Directed        bool            `json:"directed"`
	Provenance      EdgeProvenance  `json:"provenance"`
}

// ActorLineage records canonical-ID movement across immutable epochs.
type ActorLineage struct {
	OldCanonicalID string `json:"old_canonical_id"`
	NewCanonicalID string `json:"new_canonical_id"`
	Split          bool   `json:"split"`
	Reason         string `json:"reason"`
}

// ResolverSnapshot is the atomically published result of one full rebuild.
type ResolverSnapshot struct {
	Epoch         uint64              `json:"epoch"`
	Actors        []*ProvisionalActor `json:"actors"`
	AcceptedEdges []CorrelationEdge   `json:"accepted_edges"`
	DeclinedEdges []CorrelationEdge   `json:"declined_edges"`
	Delegations   []CorrelationEdge   `json:"delegations"`
	Lineage       []ActorLineage      `json:"lineage"`
}
