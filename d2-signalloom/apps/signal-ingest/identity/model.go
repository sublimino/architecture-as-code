package identity

import (
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// ActorRecord represents a canonical actor persisted in Postgres.
type ActorRecord struct {
	ActorID   string            `json:"actor_id"`
	Status    model.ActorStatus `json:"status"`
	Metadata  map[string]any    `json:"metadata,omitempty"`
	CreatedAt time.Time         `json:"created_at"`
	UpdatedAt time.Time         `json:"updated_at"`
}

// AliasRecord represents a typed identity alias with half-open temporal validity [valid_from, valid_to).
//
// AliasValue holds the cleartext identifier in memory only. At rest it is AES-GCM envelope
// ciphertext in aliases.alias_value_encrypted; the cleartext alias_value column is not written.
// AliasValueHash holds the keyed, tenant-and-epoch-scoped HMAC pseudonym, and is the only indexed
// representation of the identifier.
//
// TenantID scopes pseudonymisation. It is not yet persisted — the tenant_id column is SLDP-P2-2,
// migration 006 — so an empty value falls back to the repository's configured tenant.
type AliasRecord struct {
	ID             int64              `json:"id,omitempty"`
	ActorID        string             `json:"actor_id"`
	TenantID       string             `json:"tenant_id,omitempty"`
	AliasType      string             `json:"alias_type"`
	AliasValue     string             `json:"alias_value"`
	AliasValueHash string             `json:"alias_value_hash"`
	EdgeFidelity   model.FidelityTier `json:"edge_fidelity"`
	ValidFrom      time.Time          `json:"valid_from"`
	ValidTo        *time.Time         `json:"valid_to,omitempty"` // nil means open-ended / still active
	CreatedAt      time.Time          `json:"created_at"`
}

// IsActiveAt evaluates half-open interval [valid_from, valid_to) at timestamp ts.
// Boundary rule: valid_from <= ts AND (valid_to == nil OR ts < *valid_to).
func (a AliasRecord) IsActiveAt(ts time.Time) bool {
	if ts.Before(a.ValidFrom) {
		return false
	}
	if a.ValidTo != nil && !ts.Before(*a.ValidTo) {
		return false
	}
	return true
}

// DelegationRecord represents an acts-on-behalf-of delegation relationship.
// Invariant: Delegations are distinct from aliases. A delegate never merges into its principal.
type DelegationRecord struct {
	ID                      int64          `json:"id,omitempty"`
	DelegateActorID         string         `json:"delegate_actor_id"`
	PrincipalActorID        string         `json:"principal_actor_id"`
	DelegateActorPseudonym  string         `json:"delegate_actor_pseudonym,omitempty"`
	PrincipalActorPseudonym string         `json:"principal_actor_pseudonym,omitempty"`
	TenantID                string         `json:"tenant_id,omitempty"`
	AuthzRef                string         `json:"authz_ref"`
	ValidFrom               time.Time      `json:"valid_from"`
	ValidTo                 *time.Time     `json:"valid_to,omitempty"` // nil means open-ended / still active
	Status                  string         `json:"status,omitempty"`   // "active", "revoked", "expired"
	Metadata                map[string]any `json:"metadata,omitempty"`
	CreatedAt               time.Time      `json:"created_at"`
}

// IsActiveAt evaluates half-open interval [valid_from, valid_to) at timestamp ts.
// Boundary rule: valid_from <= ts AND (valid_to == nil OR ts < *valid_to).
func (d DelegationRecord) IsActiveAt(ts time.Time) bool {
	if ts.Before(d.ValidFrom) {
		return false
	}
	if d.ValidTo != nil && !ts.Before(*d.ValidTo) {
		return false
	}
	return true
}

// DelegationEdge represents an active traversal edge along an acts-on-behalf-of chain.
type DelegationEdge struct {
	DelegateActorID  string     `json:"delegate_actor_id"`
	PrincipalActorID string     `json:"principal_actor_id"`
	AuthzRef         string     `json:"authz_ref"`
	ValidFrom        time.Time  `json:"valid_from"`
	ValidTo          *time.Time `json:"valid_to,omitempty"`
	Status           string     `json:"status,omitempty"`
	Depth            int        `json:"depth"`
}

// ActorGraphSnapshot captures an actor and its time-valid aliases and delegations at as-of timestamp.
type ActorGraphSnapshot struct {
	Actor                  ActorRecord        `json:"actor"`
	Aliases                []AliasRecord      `json:"aliases"`
	DelegationsAsDelegate  []DelegationRecord `json:"delegations_as_delegate"`
	DelegationsAsPrincipal []DelegationRecord `json:"delegations_as_principal"`
	AsOf                   time.Time          `json:"as_of"`
}

// AsOfQuery specifies an explicit action timestamp lookup.
type AsOfQuery struct {
	ActorID    string    `json:"actor_id,omitempty"`
	AliasValue string    `json:"alias_value,omitempty"`
	AsOf       time.Time `json:"as_of"`
}

// AsOfResolution holds the resolved canonical actor and active edges as of the action timestamp.
type AsOfResolution struct {
	ActorID           string                  `json:"actor_id"`
	CanonicalID       string                  `json:"canonical_id"`
	PrincipalID       string                  `json:"principal_id,omitempty"`
	MatchedAlias      *AliasRecord            `json:"matched_alias,omitempty"`
	ActiveAliases     []AliasRecord           `json:"active_aliases"`
	ActiveDelegations []DelegationRecord      `json:"active_delegations"`
	DelegationPath    []DelegationRecord      `json:"delegation_path,omitempty"`
	CycleDetected     bool                    `json:"cycle_detected,omitempty"`
	ProvisionalActor  *model.ProvisionalActor `json:"provisional_actor"`
	AsOf              time.Time               `json:"as_of"`
}
