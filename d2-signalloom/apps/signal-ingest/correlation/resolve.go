// Package correlation provides deterministic actor identity resolution.
package correlation

import (
	"errors"
	"fmt"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

var (
	ErrUnresolvableObservation           = errors.New("unresolvable observation: no identifier or source")
	ErrContradictoryPrincipals           = errors.New("contradictory principal hints: cannot merge distinct identities")
	ErrInsufficientDeterministicEvidence = errors.New("insufficient deterministic identity evidence")
	ErrDeterministicMergeDeclined        = errors.New("deterministic merge declined by epoch constraints")
)

// principalHint remains for P1 callers, but is descriptive only. It never
// authorizes an identity merge.
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

// deriveResolutionKey returns a collector-contract typed key where available
// and otherwise an observation-scoped key. Direct callers hold the producer
// authentication precondition documented on Resolve.
func deriveResolutionKey(o model.Observation) string {
	ids := contractIdentifiers(o)
	if len(ids) > 0 {
		return ids[0].String()
	}
	if o.ID != "" {
		return observationIdentifier(o.ID).String()
	}
	if o.Source != "" {
		return observationIdentifier("source:" + o.Source).String()
	}
	return ""
}

// Resolve preserves the P1 signature. Direct callers are responsible for
// supplying observations from a producer-authenticated channel; use Engine's
// verifier-aware constructors when that precondition is not externally held.
func Resolve(obs model.Observation) (*model.ProvisionalActor, error) {
	key := deriveResolutionKey(obs)
	if key == "" {
		return nil, ErrUnresolvableObservation
	}
	id := "actor-" + key
	at := obs.Timestamp.UTC()
	actor := &model.ProvisionalActor{ID: id, CanonicalID: id, Status: model.ActorProvisional, CorrelationKeys: []string{key}, CreatedAt: at, UpdatedAt: at, Aliases: []string{}, EvidenceChain: []model.EvidenceLink{{ObservationID: obs.ID, Layer: obs.Layer, Fidelity: obs.Fidelity, Contribution: "resolved observation", Timestamp: obs.Timestamp}}}
	if hint := principalHint(obs); hint != "" {
		actor.Aliases = []string{hint}
		actor.PrincipalID = hint
	}
	if ids := contractIdentifiers(obs); len(ids) > 0 {
		actor.PrincipalID = ids[0].Value
	}
	confidence := model.DeriveConfidence(actor.EvidenceChain)
	actor.Confidence = confidence.Score
	if actor.Confidence >= .5 {
		actor.Status = model.ActorActionable
	}
	return actor, nil
}

func resolvePairKey(a, b model.Observation) (string, error) {
	if hintsConflict(a, b) {
		return "", ErrContradictoryPrincipals
	}
	common, ok := commonIdentifier(contractIdentifiers(a), contractIdentifiers(b))
	if !ok {
		return "", ErrInsufficientDeterministicEvidence
	}
	return common.String(), nil
}

// ResolvePair preserves the P1 signature for trusted direct callers and accepts
// only non-conflicting collector-contract identity evidence. Engine callers use
// ProducerVerifier; rule matches are evidence, never merge authority.
func ResolvePair(a, b model.Observation, rule Rule) (*model.ProvisionalActor, error) {
	key, err := resolvePairKey(a, b)
	if err != nil {
		return nil, err
	}
	id := "actor-" + key
	created := a.Timestamp
	if created.IsZero() || (!b.Timestamp.IsZero() && b.Timestamp.Before(created)) {
		created = b.Timestamp
	}
	updated := maxTime(a.Timestamp, b.Timestamp)
	ruleName := ""
	contribution := "matching trusted typed identity"
	if rule.CEL != "" {
		program, compileErr := compileRule(rule.CEL)
		if compileErr != nil {
			return nil, fmt.Errorf("compile rule %q: %w", rule.Name, compileErr)
		}
		out, _, evalErr := program.Eval(map[string]any{"a": obsToMap(a), "b": obsToMap(b)})
		if evalErr != nil {
			return nil, fmt.Errorf("evaluate rule %q: %w", rule.Name, evalErr)
		}
		if out.Value() == true {
			ruleName = rule.Name
			contribution = fmt.Sprintf("authenticated identity also matched rule %q", rule.Name)
		}
	}
	actor := &model.ProvisionalActor{ID: id, CanonicalID: id, Status: model.ActorProvisional, CorrelationKeys: []string{key}, CreatedAt: created, UpdatedAt: updated, EvidenceChain: []model.EvidenceLink{{ObservationID: a.ID, Layer: a.Layer, Fidelity: a.Fidelity, Contribution: contribution, Timestamp: a.Timestamp}, {ObservationID: b.ID, Layer: b.Layer, Fidelity: b.Fidelity, Contribution: contribution, Timestamp: b.Timestamp}}}
	aliases := map[string]struct{}{}
	for _, o := range []model.Observation{a, b} {
		if o.ActorHint != "" {
			aliases[o.ActorHint] = struct{}{}
		}
	}
	for alias := range aliases {
		actor.Aliases = append(actor.Aliases, alias)
	}
	sort.Strings(actor.Aliases)
	if ids := contractIdentifiers(a); len(ids) > 0 {
		actor.PrincipalID = ids[0].Value
	}
	edge := makeEdge(model.EdgeDeterministicSameEntity, model.FidelityDefinitive, a, b, a.Source+","+b.Source, key, ruleName, "matching trusted typed identity", true, true)
	edge.ID = edgeID(model.EdgeDeterministicSameEntity, a.ID, b.ID, "verified_identity")
	actor.AcceptedEdges = []model.CorrelationEdge{edge}
	confidence := model.DeriveConfidence(actor.EvidenceChain)
	actor.Confidence = confidence.Score
	if actor.Confidence >= .5 {
		actor.Status = model.ActorActionable
	}
	return actor, nil
}
