package identity

import (
	"context"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// ResolveActorAsOf resolves an actor and its time-valid graph edges at an explicit action timestamp.
// It never defaults to now(); the caller must explicitly supply asOf.
func ResolveActorAsOf(ctx context.Context, repo Repository, actorID string, asOf time.Time) (*AsOfResolution, error) {
	if actorID == "" {
		return nil, fmt.Errorf("actorID cannot be empty")
	}
	if asOf.IsZero() {
		return nil, fmt.Errorf("asOf timestamp must be explicit and non-zero")
	}

	snapshot, err := repo.GetActiveGraphForActorAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	res := &AsOfResolution{
		ActorID:           actorID,
		CanonicalID:       actorID,
		ActiveAliases:     snapshot.Aliases,
		ActiveDelegations: snapshot.DelegationsAsDelegate,
		AsOf:              asOf,
	}

	// Determine principal ID from active delegation chain if present
	if len(snapshot.DelegationsAsDelegate) > 0 {
		res.PrincipalID = snapshot.DelegationsAsDelegate[0].PrincipalActorID
	}

	// Build in-memory ProvisionalActor without re-deciding merge algebra
	provActor := &model.ProvisionalActor{
		ID:              actorID,
		Status:          snapshot.Actor.Status,
		CanonicalID:     actorID,
		PrincipalID:     res.PrincipalID,
		CreatedAt:       snapshot.Actor.CreatedAt,
		UpdatedAt:       snapshot.Actor.UpdatedAt,
		CorrelationKeys: make([]string, 0, len(snapshot.Aliases)),
		Aliases:         make([]string, 0, len(snapshot.Aliases)),
		EvidenceChain:   make([]model.EvidenceLink, 0, len(snapshot.Aliases)+len(snapshot.DelegationsAsDelegate)),
	}

	for _, a := range snapshot.Aliases {
		provActor.Aliases = append(provActor.Aliases, a.AliasValue)
		provActor.CorrelationKeys = append(provActor.CorrelationKeys, a.AliasValue)

		// Map persisted alias edge to in-memory EvidenceLink
		provActor.EvidenceChain = append(provActor.EvidenceChain, model.EvidenceLink{
			ObservationID: fmt.Sprintf("alias-%s-%d", a.AliasType, a.ID),
			Layer:         model.LayerIdentityAuth,
			Fidelity:      a.EdgeFidelity,
			Contribution:  fmt.Sprintf("time-valid alias %s:%s", a.AliasType, a.AliasValue),
			Timestamp:     a.ValidFrom,
		})
	}

	for _, d := range snapshot.DelegationsAsDelegate {
		provActor.EvidenceChain = append(provActor.EvidenceChain, model.EvidenceLink{
			ObservationID: fmt.Sprintf("delegation-%d", d.ID),
			Layer:         model.LayerIdentityAuth,
			Fidelity:      model.FidelityDefinitive,
			Contribution:  fmt.Sprintf("acts-on-behalf-of %s (authz: %s)", d.PrincipalActorID, d.AuthzRef),
			Timestamp:     d.ValidFrom,
		})
	}

	if len(provActor.EvidenceChain) > 0 {
		conf := model.DeriveConfidence(provActor.EvidenceChain)
		provActor.Confidence = conf.Score
		if provActor.Confidence >= 0.5 && provActor.Status == model.ActorProvisional {
			provActor.Status = model.ActorActionable
		}
	}

	res.ProvisionalActor = provActor
	return res, nil
}

// ResolveAliasAsOf resolves an alias string at an explicit action timestamp to its canonical actor.
func ResolveAliasAsOf(ctx context.Context, repo Repository, aliasValue string, asOf time.Time) (*AsOfResolution, error) {
	if aliasValue == "" {
		return nil, fmt.Errorf("aliasValue cannot be empty")
	}
	if asOf.IsZero() {
		return nil, fmt.Errorf("asOf timestamp must be explicit and non-zero")
	}

	aliases, err := repo.FindAliasesAsOf(ctx, aliasValue, asOf)
	if err != nil {
		return nil, err
	}
	if len(aliases) == 0 {
		return nil, ErrAliasNotFound
	}

	matched := aliases[0]
	res, err := ResolveActorAsOf(ctx, repo, matched.ActorID, asOf)
	if err != nil {
		return nil, err
	}
	res.MatchedAlias = &matched
	return res, nil
}

// TraceDelegationChainAsOf traces acts-on-behalf-of authority chains from delegate to principals at asOf.
func TraceDelegationChainAsOf(ctx context.Context, repo Repository, delegateID string, asOf time.Time, maxDepth int) ([]DelegationEdge, error) {
	if maxDepth <= 0 {
		maxDepth = 10
	}

	var (
		chain   []DelegationEdge
		current = delegateID
		visited = make(map[string]bool)
		depth   = 1
	)

	visited[delegateID] = true

	for depth <= maxDepth {
		delegations, err := repo.GetDelegationsForDelegateAsOf(ctx, current, asOf)
		if err != nil {
			return nil, err
		}
		if len(delegations) == 0 {
			break
		}

		// Take the active delegation (first in temporal order)
		active := delegations[0]
		edge := DelegationEdge{
			DelegateActorID:  active.DelegateActorID,
			PrincipalActorID: active.PrincipalActorID,
			AuthzRef:         active.AuthzRef,
			ValidFrom:        active.ValidFrom,
			ValidTo:          active.ValidTo,
			Depth:            depth,
		}
		chain = append(chain, edge)

		if visited[active.PrincipalActorID] {
			// Prevent infinite delegation cycles
			break
		}
		visited[active.PrincipalActorID] = true
		current = active.PrincipalActorID
		depth++
	}

	return chain, nil
}
