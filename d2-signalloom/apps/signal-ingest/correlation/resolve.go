// Package correlation provides CEL-based signal correlation and identity resolution for actors.
package correlation

import (
	"errors"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

var (
	// ErrUnresolvableObservation is returned when an observation cannot be resolved due to missing identity or source.
	ErrUnresolvableObservation = errors.New("unresolvable observation: no identifier or source")
	// ErrContradictoryPrincipals is returned when two observations have differing non-empty principal hints and cannot be merged.
	ErrContradictoryPrincipals = errors.New("contradictory principal hints: cannot merge distinct identities")
)

// principalHint extracts the preferred principal identifier from an observation.
func principalHint(o model.Observation) string {
	if o.ActorHint != "" {
		return o.ActorHint
	}
	if o.PrincipalID != "" {
		return o.PrincipalID
	}
	if o.ActorID != "" {
		return o.ActorID
	}
	return ""
}

// deriveResolutionKey derives the pure, deterministic correlation key for a single observation.
func deriveResolutionKey(o model.Observation) string {
	if h := principalHint(o); h != "" {
		return h
	}
	if o.Source != "" {
		return fmt.Sprintf("src-%s", o.Source)
	}
	if o.ID != "" {
		return fmt.Sprintf("obs-%s", o.ID)
	}
	return ""
}

// Resolve resolves a single observation into a canonical provisional actor.
// The derived Actor.ID is pure and deterministic over resolution inputs.
// If the observation has no resolvable identifier or source, Resolve returns ErrUnresolvableObservation.
func Resolve(obs model.Observation) (*model.ProvisionalActor, error) {
	key := deriveResolutionKey(obs)
	if key == "" {
		return nil, ErrUnresolvableObservation
	}

	now := time.Now().UTC()
	if !obs.Timestamp.IsZero() {
		now = obs.Timestamp.UTC()
	}

	actorID := fmt.Sprintf("actor-%s", key)
	actor := &model.ProvisionalActor{
		ID:              actorID,
		Status:          model.ActorProvisional,
		CorrelationKeys: []string{key},
		EvidenceChain: []model.EvidenceLink{
			{
				ObservationID: obs.ID,
				Layer:         obs.Layer,
				Fidelity:      obs.Fidelity,
				Contribution:  "resolved observation",
				Timestamp:     obs.Timestamp,
			},
		},
		CreatedAt:   now,
		UpdatedAt:   now,
		CanonicalID: actorID,
		PrincipalID: principalHint(obs),
		Aliases:     []string{key},
	}

	confidence := model.DeriveConfidence(actor.EvidenceChain)
	actor.Confidence = confidence.Score
	if actor.Confidence >= 0.5 {
		actor.Status = model.ActorActionable
	}

	return actor, nil
}

// resolvePairKey determines the resolution key for a pair of correlated observations.
// Invariant: zero false merges. If both observations have non-empty principal hints
// that differ (hintA != "" && hintB != "" && hintA != hintB), resolvePairKey returns ErrContradictoryPrincipals.
func resolvePairKey(a, b model.Observation) (string, error) {
	hintA := principalHint(a)
	hintB := principalHint(b)

	// Contradictory principal hints: hard refusal to prevent false merges.
	if hintA != "" && hintB != "" && hintA != hintB {
		return "", ErrContradictoryPrincipals
	}

	// 1. Shared non-empty principal hint
	if hintA != "" && hintA == hintB {
		return hintA, nil
	}

	// 2. Shared source for anonymous or single-hinted signals
	if a.Source != "" && a.Source == b.Source {
		return fmt.Sprintf("src-%s", a.Source), nil
	}

	// 3. Fallback to sorted pair of IDs
	if a.ID != "" || b.ID != "" {
		if a.ID < b.ID {
			return fmt.Sprintf("pair-%s-%s", a.ID, b.ID), nil
		}
		return fmt.Sprintf("pair-%s-%s", b.ID, a.ID), nil
	}

	return "", ErrUnresolvableObservation
}

// ResolvePair resolves and merges a pair of observations into a provisional actor.
// If the observations have contradictory principal hints, it returns ErrContradictoryPrincipals.
func ResolvePair(a, b model.Observation, rule Rule) (*model.ProvisionalActor, error) {
	key, err := resolvePairKey(a, b)
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	actorID := fmt.Sprintf("actor-%s", key)
	actor := &model.ProvisionalActor{
		ID:              actorID,
		Status:          model.ActorProvisional,
		CorrelationKeys: []string{key},
		CreatedAt:       now,
		UpdatedAt:       now,
		CanonicalID:     actorID,
		Aliases:         []string{key},
	}
	if h := principalHint(a); h != "" {
		actor.PrincipalID = h
	} else if h := principalHint(b); h != "" {
		actor.PrincipalID = h
	}

	actor.EvidenceChain = append(actor.EvidenceChain,
		model.EvidenceLink{
			ObservationID: a.ID,
			Layer:         a.Layer,
			Fidelity:      a.Fidelity,
			Contribution:  fmt.Sprintf("matched rule %q", rule.Name),
			Timestamp:     a.Timestamp,
		},
		model.EvidenceLink{
			ObservationID: b.ID,
			Layer:         b.Layer,
			Fidelity:      b.Fidelity,
			Contribution:  fmt.Sprintf("matched rule %q", rule.Name),
			Timestamp:     b.Timestamp,
		},
	)

	confidence := model.DeriveConfidence(actor.EvidenceChain)
	actor.Confidence = confidence.Score
	if actor.Confidence >= 0.5 {
		actor.Status = model.ActorActionable
	}

	return actor, nil
}
