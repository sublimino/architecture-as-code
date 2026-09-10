package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

var (
	// ErrZeroTimestamp is returned when a query omits the action timestamp.
	ErrZeroTimestamp = errors.New("action timestamp must be explicitly provided and non-zero")
)

// ResolverStore defines the contract consumed by actor resolution to query persisted graph state.
type ResolverStore interface {
	// LookupActorAsOf resolves an actor and its time-valid graph edges as of action timestamp.
	LookupActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*model.ProvisionalActor, error)

	// LookupAliasAsOf resolves an alias string to its canonical ProvisionalActor as of action timestamp.
	LookupAliasAsOf(ctx context.Context, aliasValue string, asOf time.Time) (*model.ProvisionalActor, error)

	// ResolveObservationAsOf resolves an observation against the persisted graph as of observation.Timestamp.
	ResolveObservationAsOf(ctx context.Context, obs model.Observation) (*model.ProvisionalActor, error)

	// GetDelegationsAsOf returns active acts-on-behalf-of delegations for delegateID at asOf.
	GetDelegationsAsOf(ctx context.Context, delegateID string, asOf time.Time) ([]DelegationEdge, error)

	// RevokeActiveDelegations clamps active delegations and updates actor status to revoked.
	RevokeActiveDelegations(ctx context.Context, actorID string, timestamp time.Time) error

	// Repository returns the underlying graph Repository.
	Repository() Repository
}

// GraphResolverStore implements ResolverStore backed by a Repository (PostgresRepository or MemoryRepository).
type GraphResolverStore struct {
	repo Repository
}

// NewGraphResolverStore constructs a GraphResolverStore.
func NewGraphResolverStore(repo Repository) *GraphResolverStore {
	return &GraphResolverStore{repo: repo}
}

// Repository returns the underlying graph repository.
func (s *GraphResolverStore) Repository() Repository {
	return s.repo
}

// LookupActorAsOf retrieves the actor and its valid edges at asOf.
func (s *GraphResolverStore) LookupActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*model.ProvisionalActor, error) {
	if asOf.IsZero() {
		return nil, ErrZeroTimestamp
	}
	res, err := ResolveActorAsOf(ctx, s.repo, actorID, asOf)
	if err != nil {
		return nil, err
	}
	return res.ProvisionalActor, nil
}

// LookupAliasAsOf resolves an alias string at asOf to its canonical ProvisionalActor.
func (s *GraphResolverStore) LookupAliasAsOf(ctx context.Context, aliasValue string, asOf time.Time) (*model.ProvisionalActor, error) {
	if asOf.IsZero() {
		return nil, ErrZeroTimestamp
	}
	res, err := ResolveAliasAsOf(ctx, s.repo, aliasValue, asOf)
	if err != nil {
		return nil, err
	}
	return res.ProvisionalActor, nil
}

// ResolveObservationAsOf resolves an observation against the persisted identity graph as of obs.Timestamp.
// It maps the observation's hints/aliases to canonical actors without duplicating the merge algebra.
func (s *GraphResolverStore) ResolveObservationAsOf(ctx context.Context, obs model.Observation) (*model.ProvisionalActor, error) {
	if obs.Timestamp.IsZero() {
		return nil, ErrZeroTimestamp
	}
	asOf := obs.Timestamp.UTC()

	// 1. Try resolving via ActorHint, PrincipalID, or ActorID against persisted aliases
	var res *AsOfResolution
	hints := []string{obs.ActorHint, obs.PrincipalID, obs.ActorID}
	for _, hint := range hints {
		if hint == "" {
			continue
		}
		r, err := ResolveAliasAsOf(ctx, s.repo, hint, asOf)
		if err == nil && r != nil {
			res = r
			break
		}
	}

	// 2. If not matched by alias, check if ActorID directly exists in actors table
	if res == nil && obs.ActorID != "" {
		r, err := ResolveActorAsOf(ctx, s.repo, obs.ActorID, asOf)
		if err == nil && r != nil {
			res = r
		}
	}

	// 3. If matched against persisted graph, enrich with observation's evidence link
	if res != nil && res.ProvisionalActor != nil {
		actor := res.ProvisionalActor

		// Add observation as an evidence link
		obsLink := model.EvidenceLink{
			ObservationID: obs.ID,
			Layer:         obs.Layer,
			Fidelity:      obs.Fidelity,
			Contribution:  "resolved observation",
			Timestamp:     obs.Timestamp,
		}
		actor.EvidenceChain = append(actor.EvidenceChain, obsLink)

		// If observation carries an impersonated user, record delegation
		if obs.ImpersonatedUser != "" && actor.PrincipalID == "" {
			actor.PrincipalID = obs.ImpersonatedUser
		}

		conf := model.DeriveConfidence(actor.EvidenceChain)
		actor.Confidence = conf.Score
		if actor.Confidence >= 0.5 && actor.Status == model.ActorProvisional {
			actor.Status = model.ActorActionable
		}

		return actor, nil
	}

	// 4. Fallback: construct provisional actor for new / unaliased observation
	key := obs.ActorHint
	if key == "" {
		key = obs.PrincipalID
	}
	if key == "" {
		key = obs.ActorID
	}
	if key == "" && obs.Source != "" {
		key = fmt.Sprintf("src-%s", obs.Source)
	}
	if key == "" && obs.ID != "" {
		key = fmt.Sprintf("obs-%s", obs.ID)
	}
	if key == "" {
		return nil, errors.New("unresolvable observation: no identifier or source")
	}

	actorID := fmt.Sprintf("actor-%s", key)
	provActor := &model.ProvisionalActor{
		ID:              actorID,
		Status:          model.ActorProvisional,
		CanonicalID:     actorID,
		PrincipalID:     obs.ActorHint,
		CreatedAt:       asOf,
		UpdatedAt:       asOf,
		CorrelationKeys: []string{key},
		Aliases:         []string{key},
		EvidenceChain: []model.EvidenceLink{
			{
				ObservationID: obs.ID,
				Layer:         obs.Layer,
				Fidelity:      obs.Fidelity,
				Contribution:  "resolved observation",
				Timestamp:     obs.Timestamp,
			},
		},
	}
	conf := model.DeriveConfidence(provActor.EvidenceChain)
	provActor.Confidence = conf.Score
	if provActor.Confidence >= 0.5 {
		provActor.Status = model.ActorActionable
	}

	return provActor, nil
}

// GetDelegationsAsOf returns delegation chain edges for delegateID active at asOf.
func (s *GraphResolverStore) GetDelegationsAsOf(ctx context.Context, delegateID string, asOf time.Time) ([]DelegationEdge, error) {
	if asOf.IsZero() {
		return nil, ErrZeroTimestamp
	}
	return TraceDelegationChainAsOf(ctx, s.repo, delegateID, asOf, 10)
}

// RevokeActiveDelegations clamps active delegations and updates actor status to revoked.
func (s *GraphResolverStore) RevokeActiveDelegations(ctx context.Context, actorID string, timestamp time.Time) error {
	return s.repo.RevokeActiveDelegations(ctx, actorID, timestamp)
}
