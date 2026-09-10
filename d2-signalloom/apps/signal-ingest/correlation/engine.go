package correlation

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Engine performs deterministic full-epoch identity resolution.
type Engine struct {
	mu         sync.RWMutex
	store      store.SignalStore
	resolver   ResolverStore
	rules      []compiledRule
	options    ResolverOptions
	verifier   ProducerVerifier
	snapshot   model.ResolverSnapshot
	quarantine *QuarantineEngine
}

type compiledRule struct {
	Rule
	program cel.Program
}

func NewEngine(s store.SignalStore) (*Engine, error) {
	return NewEngineWithVerifier(s, DenyUnverifiedProducer{})
}

func NewEngineWithVerifier(s store.SignalStore, verifier ProducerVerifier) (*Engine, error) {
	return newEngine(s, NewMemoryResolverStore(), DefaultRules(), ResolverOptions{}, verifier)
}

func NewEngineWithResolverStore(s store.SignalStore, resolver ResolverStore) (*Engine, error) {
	return newEngine(s, resolver, DefaultRules(), ResolverOptions{}, DenyUnverifiedProducer{})
}

func NewEngineWithResolverStoreAndVerifier(s store.SignalStore, resolver ResolverStore, verifier ProducerVerifier) (*Engine, error) {
	return newEngine(s, resolver, DefaultRules(), ResolverOptions{}, verifier)
}

func NewEngineWithOptions(s store.SignalStore, resolver ResolverStore, options ResolverOptions) (*Engine, error) {
	return newEngine(s, resolver, DefaultRules(), options, DenyUnverifiedProducer{})
}

func NewEngineWithOptionsAndVerifier(s store.SignalStore, resolver ResolverStore, options ResolverOptions, verifier ProducerVerifier) (*Engine, error) {
	return newEngine(s, resolver, DefaultRules(), options, verifier)
}

func NewEngineWithRules(s store.SignalStore, rules []Rule) (*Engine, error) {
	return newEngine(s, NewMemoryResolverStore(), rules, ResolverOptions{}, DenyUnverifiedProducer{})
}

func NewEngineWithRulesAndResolverStore(s store.SignalStore, resolver ResolverStore, rules []Rule) (*Engine, error) {
	return newEngine(s, resolver, rules, ResolverOptions{}, DenyUnverifiedProducer{})
}

func newEngine(s store.SignalStore, resolver ResolverStore, rules []Rule, options ResolverOptions, verifier ProducerVerifier) (*Engine, error) {
	if s == nil {
		return nil, errors.New("signal store is required")
	}
	if resolver == nil {
		return nil, errors.New("resolver store is required")
	}
	if verifier == nil {
		verifier = DenyUnverifiedProducer{}
	}
	compiled := make([]compiledRule, 0, len(rules))
	for _, r := range rules {
		if !r.EdgeType.IsValid() {
			return nil, fmt.Errorf("rule %q has invalid edge classification %q", r.Name, r.EdgeType)
		}
		prg, err := compileRule(r.CEL)
		if err != nil {
			return nil, fmt.Errorf("compile rule %q: %w", r.Name, err)
		}
		compiled = append(compiled, compiledRule{Rule: r, program: prg})
	}
	snapshot, err := resolver.Snapshot(context.Background())
	if err != nil {
		return nil, fmt.Errorf("load resolver snapshot: %w", err)
	}
	quarantine := NewQuarantineEngine(QuarantineEngineOptions{Store: s})
	return &Engine{store: s, resolver: resolver, rules: compiled, options: options.defaults(), verifier: verifier, snapshot: cloneSnapshot(snapshot), quarantine: quarantine}, nil
}

func (e *Engine) verifiedIdentifiers(ctx context.Context, o model.Observation) ([]model.TypedIdentifier, error) {
	verified, err := e.verifier.VerifyProducer(ctx, o)
	if err != nil {
		return nil, err
	}
	if !verified {
		return nil, nil
	}
	return contractIdentifiers(o), nil
}

func compileRule(expr string) (cel.Program, error) {
	env, err := cel.NewEnv(cel.Variable("a", cel.MapType(cel.StringType, cel.DynType)), cel.Variable("b", cel.MapType(cel.StringType, cel.DynType)), cel.Function("abs", cel.Overload("abs_int", []*cel.Type{cel.IntType}, cel.IntType, cel.UnaryBinding(func(val ref.Val) ref.Val {
		v := val.Value().(int64)
		if v < 0 {
			return types.Int(-v)
		}
		return types.Int(v)
	}))))
	if err != nil {
		return nil, err
	}
	ast, issues := env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		return nil, issues.Err()
	}
	return env.Program(ast)
}

func obsToMap(o model.Observation) map[string]any {
	return map[string]any{"id": o.ID, "timestamp": o.Timestamp.Unix(), "layer": string(o.Layer), "fidelity": string(o.Fidelity), "source": o.Source, "confidence": o.Confidence, "actor_hint": o.ActorHint, "raw_evidence_ref": o.RawEvidenceRef, "description": o.Description, "principal_id": o.PrincipalID, "actor_id": o.ActorID, "session_id": o.SessionID, "impersonated_user": o.ImpersonatedUser, "delegation_depth": int64(o.DelegationDepth)}
}

func (e *Engine) Correlate(ctx context.Context) ([]*model.ProvisionalActor, error) {
	observations, err := e.store.QueryRange(ctx, store.Query{})
	if err != nil {
		return nil, fmt.Errorf("query observations: %w", err)
	}
	if err = e.resolver.ReplaceObservations(ctx, observations); err != nil {
		return nil, fmt.Errorf("replace resolver observations: %w", err)
	}
	return e.rebuild(ctx)
}

// Rebuild performs an immutable full epoch from the resolver store.
func (e *Engine) Rebuild(ctx context.Context) ([]*model.ProvisionalActor, error) {
	return e.rebuild(ctx)
}

func (e *Engine) rebuild(ctx context.Context) ([]*model.ProvisionalActor, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	observations, err := e.resolver.Observations(ctx)
	if err != nil {
		return nil, fmt.Errorf("read resolver observations: %w", err)
	}
	previous, err := e.resolver.Snapshot(ctx)
	if err != nil {
		return nil, fmt.Errorf("load resolver snapshot: %w", err)
	}
	next, err := e.buildSnapshot(ctx, observations, previous)
	if err != nil {
		return nil, err
	}
	if err = e.resolver.Publish(ctx, next); err != nil {
		return nil, fmt.Errorf("publish resolver epoch: %w", err)
	}
	e.snapshot = cloneSnapshot(next)
	return cloneSnapshot(next).Actors, nil
}

func (e *Engine) buildSnapshot(ctx context.Context, input []model.Observation, previous model.ResolverSnapshot) (model.ResolverSnapshot, error) {
	byID := make(map[string]model.Observation, len(input))
	for _, o := range input {
		if o.ID != "" {
			byID[o.ID] = cloneObservation(o)
		}
	}
	observations := make([]model.Observation, 0, len(byID))
	for _, o := range byID {
		observations = append(observations, o)
	}
	sort.Slice(observations, func(i, j int) bool { return observations[i].ID < observations[j].ID })

	excluded := make(map[string]bool)
	for _, r := range e.rules {
		if !r.Negative {
			continue
		}
		for _, o := range observations {
			out, _, evalErr := r.program.Eval(map[string]any{"a": obsToMap(o), "b": obsToMap(o)})
			if evalErr == nil && out.Value() == true {
				excluded[o.ID] = true
			}
		}
	}
	filtered := observations[:0]
	for _, o := range observations {
		if !excluded[o.ID] {
			filtered = append(filtered, o)
		}
	}
	observations = filtered

	verifiedIDs := make([][]model.TypedIdentifier, len(observations))
	for i, o := range observations {
		ids, verifyErr := e.verifiedIdentifiers(ctx, o)
		if verifyErr != nil {
			return model.ResolverSnapshot{}, fmt.Errorf("verify observation %q producer: %w", o.ID, verifyErr)
		}
		verifiedIDs[i] = ids
	}
	verifiedByID := make(map[string][]model.TypedIdentifier, len(observations))
	for i, o := range observations {
		verifiedByID[o.ID] = verifiedIDs[i]
	}
	index := make(map[string][]int)
	for i := range observations {
		for _, id := range verifiedIDs[i] {
			index[id.String()] = append(index[id.String()], i)
		}
	}
	pairKeys := make(map[[2]int][]string)
	for key, members := range index {
		sort.Slice(members, func(i, j int) bool { return observations[members[i]].ID < observations[members[j]].ID })
		for i := 0; i < len(members); i++ {
			for j := i + 1; j < len(members); j++ {
				pair := [2]int{members[i], members[j]}
				if pair[1] < pair[0] {
					pair[0], pair[1] = pair[1], pair[0]
				}
				pairKeys[pair] = append(pairKeys[pair], key)
			}
		}
	}
	pairs := make([][2]int, 0, len(pairKeys))
	for pair := range pairKeys {
		pairs = append(pairs, pair)
	}
	sort.Slice(pairs, func(i, j int) bool {
		ai, aj := observations[pairs[i][0]].ID, observations[pairs[j][0]].ID
		if ai == aj {
			return observations[pairs[i][1]].ID < observations[pairs[j][1]].ID
		}
		return ai < aj
	})
	var deterministic []model.CorrelationEdge
	cannot := make(map[[2]int]struct{})
	var declined, accepted []model.CorrelationEdge
	for _, pair := range pairs {
		keys := pairKeys[pair]
		sort.Strings(keys)
		a, b := observations[pair[0]], observations[pair[1]]
		if hintsConflict(a, b) {
			cannot[pair] = struct{}{}
			accepted = append(accepted, makeEdge(model.EdgeCannotLink, model.FidelityDefinitive, a, b, a.Source+","+b.Source, "actor_hint", "conflict", "nonconflicting hint gate", true, true))
			continue
		}
		edge := makeEdge(model.EdgeDeterministicSameEntity, model.FidelityDefinitive, a, b, a.Source+","+b.Source, keys[0], "authenticated_identity", "matching verified typed identity", true, true)
		edge.ID = edgeID(model.EdgeDeterministicSameEntity, a.ID, b.ID, "verified_identity")
		retracted, retractErr := e.resolver.EdgeRetracted(ctx, edge.ID)
		if retractErr != nil {
			return model.ResolverSnapshot{}, fmt.Errorf("read edge retraction: %w", retractErr)
		}
		if retracted {
			edge.Provenance.Accepted = false
			edge.Provenance.Reason = "retracted deterministic evidence"
			declined = append(declined, edge)
			cannot[pair] = struct{}{}
			accepted = append(accepted, makeEdge(model.EdgeCannotLink, model.FidelityDefinitive, a, b, "resolver-store", "retracted_edge", "", "retracted factual pair blocks transitive reunion", true, true))
			continue
		}
		deterministic = append(deterministic, edge)
	}
	sort.Slice(deterministic, func(i, j int) bool { return deterministic[i].ID < deterministic[j].ID })

	dsu := newDisjointSet(observations, verifiedIDs)
	positions := make(map[string]int, len(observations))
	for i, o := range observations {
		positions[o.ID] = i
	}
	for _, edge := range deterministic {
		a, b := positions[edge.FromObservation], positions[edge.ToObservation]
		ok, reason := dsu.union(a, b, e.options.MaxDistinctIdentities, e.options.MaxMergeDegree, cannot)
		edge.Provenance.Accepted = ok
		edge.Provenance.Reason = reason
		if ok {
			accepted = append(accepted, edge)
		} else {
			declined = append(declined, edge)
		}
	}

	seenPairs := make(map[string]struct{})
	pairCount := 0
	var weak []model.CorrelationEdge
	for _, a := range observations {
		candidates, candidateErr := e.resolver.Candidates(ctx, a, e.options.CandidateWindow, e.options.MaxWeakCandidates)
		if candidateErr != nil {
			return model.ResolverSnapshot{}, fmt.Errorf("query resolver candidates: %w", candidateErr)
		}
		for _, b := range candidates {
			if b.ID <= a.ID {
				continue
			}
			pairKey := a.ID + "\x00" + b.ID
			if _, ok := seenPairs[pairKey]; ok {
				continue
			}
			seenPairs[pairKey] = struct{}{}
			pairCount++
			if pairCount > e.options.MaxCandidatePairs {
				break
			}
			for _, r := range e.rules {
				if r.Negative {
					continue
				}
				out, _, evalErr := r.program.Eval(map[string]any{"a": obsToMap(a), "b": obsToMap(b)})
				if evalErr != nil || out.Value() != true {
					continue
				}
				fidelity := model.FidelitySuggestive
				if r.EdgeType == model.EdgeTemporal {
					fidelity = model.FidelityCircumstantial
				}
				weak = append(weak, makeEdge(r.EdgeType, fidelity, a, b, a.Source+","+b.Source, "cel", r.Name, "rule match is non-authoritative without authenticated identity gate", false, true))
			}
			if ip := a.Labels["src_ip"]; ip != "" && ip == b.Labels["src_ip"] {
				weak = append(weak, makeEdge(model.EdgeIPCircumstantial, model.FidelityCircumstantial, a, b, a.Source+","+b.Source, "labels[src_ip]", "", "shared source IP is circumstantial only", false, true))
			}
		}
		if pairCount > e.options.MaxCandidatePairs {
			break
		}
	}

	var delegations []model.CorrelationEdge
	for _, o := range observations {
		if len(verifiedByID[o.ID]) == 0 || o.Source != "k8s-apiserver-audit" || o.DelegationEdge == nil || o.ImpersonatedUser == "" {
			continue
		}
		from := o.Labels["delegator"]
		if from == "" || from == o.ImpersonatedUser || o.Labels["acting_principal"] != o.ImpersonatedUser || o.Labels["impersonated_user"] != o.ImpersonatedUser || o.Labels["delegation_basis"] != "impersonation" {
			continue
		}
		edge := model.CorrelationEdge{ID: edgeID(model.EdgeActsOnBehalfOf, from, o.ImpersonatedUser, o.ID), Type: model.EdgeActsOnBehalfOf, Fidelity: model.FidelityDefinitive, Directed: true, FromObservation: o.ID, ToObservation: o.ID, Provenance: model.EdgeProvenance{ObservationIDs: []string{o.ID}, Source: o.Source, Field: "impersonated_user", Authenticated: true, Accepted: true, Reason: "verified Kubernetes audit impersonation", Timestamp: o.Timestamp}}
		if id, ok := typedSPIFFE(from); ok {
			edge.From = id
		} else {
			edge.From = typedPrincipal(from, "kubernetes")
		}
		if id, ok := typedSPIFFE(o.ImpersonatedUser); ok {
			edge.To = id
		} else {
			edge.To = typedPrincipal(o.ImpersonatedUser, "kubernetes")
		}
		edge.FromObservation = o.ID
		edge.ToObservation = o.ID
		delegations = append(delegations, edge)
	}
	sort.Slice(accepted, func(i, j int) bool { return accepted[i].ID < accepted[j].ID })
	sort.Slice(declined, func(i, j int) bool { return declined[i].ID < declined[j].ID })
	sort.Slice(weak, func(i, j int) bool { return weak[i].ID < weak[j].ID })
	sort.Slice(delegations, func(i, j int) bool { return delegations[i].ID < delegations[j].ID })

	components := make(map[int][]int)
	for i := range observations {
		root := dsu.find(i)
		components[root] = append(components[root], i)
	}
	componentList := make([][]int, 0, len(components))
	for _, component := range components {
		sort.Slice(component, func(i, j int) bool { return observations[component[i]].ID < observations[component[j]].ID })
		componentList = append(componentList, component)
	}
	sort.Slice(componentList, func(i, j int) bool {
		return observations[componentList[i][0]].ID < observations[componentList[j][0]].ID
	})
	baseRepresentatives := make([]model.TypedIdentifier, len(componentList))
	for i, component := range componentList {
		baseRepresentatives[i] = representative(component, observations, verifiedIDs)
	}
	representativeSeen := make(map[string]int)
	previousByID := make(map[string]*model.ProvisionalActor, len(previous.Actors))
	for _, actor := range previous.Actors {
		previousByID[actor.ID] = actor
	}
	actors := make([]*model.ProvisionalActor, 0, len(componentList))
	actorByObservation := make(map[string]*model.ProvisionalActor)
	actorsByKey := make(map[string][]*model.ProvisionalActor)
	for componentIndex, component := range componentList {
		rep := baseRepresentatives[componentIndex]
		id := "actor-" + rep.String()
		if representativeSeen[rep.String()] > 0 {
			id += "|split|" + observationIdentifier(observations[component[0]].ID).String()
		}
		representativeSeen[rep.String()]++
		actor := &model.ProvisionalActor{ID: id, CanonicalID: id, Status: model.ActorProvisional, CorrelationKeys: []string{}, CreatedAt: observations[component[0]].Timestamp, UpdatedAt: observations[component[0]].Timestamp}
		keySet, aliasSet := map[string]struct{}{}, map[string]struct{}{}
		for _, idx := range component {
			o := observations[idx]
			if o.Timestamp.Before(actor.CreatedAt) || actor.CreatedAt.IsZero() {
				actor.CreatedAt = o.Timestamp
			}
			if o.Timestamp.After(actor.UpdatedAt) {
				actor.UpdatedAt = o.Timestamp
			}
			actor.EvidenceChain = append(actor.EvidenceChain, model.EvidenceLink{ObservationID: o.ID, Layer: o.Layer, Fidelity: o.Fidelity, Contribution: "identity partition observation", Timestamp: o.Timestamp})
			ids := verifiedIDs[idx]
			hasAuthenticatedID := len(ids) > 0
			if len(ids) == 0 {
				ids = []model.TypedIdentifier{observationIdentifier(o.ID)}
			}
			for _, typed := range ids {
				keySet[typed.String()] = struct{}{}
				if hasAuthenticatedID && actor.PrincipalID == "" {
					actor.PrincipalID = typed.Value
				}
			}
			if o.ActorHint != "" {
				aliasSet[o.ActorHint] = struct{}{}
				// Retain the P1 display field for compatibility. Partitioning
				// never consumes this value without an authenticated contract.
				if actor.PrincipalID == "" {
					actor.PrincipalID = o.ActorHint
				}
			}
			actorByObservation[o.ID] = actor
		}
		for key := range keySet {
			actor.CorrelationKeys = append(actor.CorrelationKeys, key)
		}
		for alias := range aliasSet {
			actor.Aliases = append(actor.Aliases, alias)
		}
		sort.Strings(actor.CorrelationKeys)
		sort.Strings(actor.Aliases)
		confidence := model.DeriveConfidence(actor.EvidenceChain)
		actor.Confidence = confidence.Score
		if actor.Confidence >= .5 {
			actor.Status = model.ActorActionable
		}
		if prior := previousByID[actor.ID]; prior != nil && prior.Status == model.ActorPromoted {
			actor.Status = model.ActorPromoted
			actor.PromotedAt = prior.PromotedAt
			if prior.UpdatedAt.After(actor.UpdatedAt) {
				actor.UpdatedAt = prior.UpdatedAt
			}
		}
		if e.quarantine != nil {
			if qRec, isQ := e.quarantine.IsActorQuarantined(actor.ID); isQ {
				actor.Status = model.ActorQuarantined
				actor.QuarantineDetails = qRec
			} else {
				for _, al := range actor.Aliases {
					if qRec, isQ := e.quarantine.IsActorQuarantined(al); isQ {
						actor.Status = model.ActorQuarantined
						actor.QuarantineDetails = qRec
						break
					}
				}
			}
		}
		resolved := actor.UpdatedAt
		actor.ResolvedAt = &resolved
		for _, key := range actor.CorrelationKeys {
			actorsByKey[key] = append(actorsByKey[key], actor)
		}
		actors = append(actors, actor)
	}
	sort.Slice(actors, func(i, j int) bool { return actors[i].ID < actors[j].ID })
	for _, edge := range append(append([]model.CorrelationEdge{}, accepted...), weak...) {
		seen := map[*model.ProvisionalActor]bool{}
		for _, oid := range []string{edge.FromObservation, edge.ToObservation} {
			if a := actorByObservation[oid]; a != nil && !seen[a] {
				attachEdge(a, edge, false)
				seen[a] = true
			}
		}
	}
	for _, edge := range delegations {
		seen := map[*model.ProvisionalActor]bool{}
		for _, key := range []string{edge.From.String(), edge.To.String()} {
			for _, actor := range actorsByKey[key] {
				if !seen[actor] {
					attachEdge(actor, edge, false)
					seen[actor] = true
				}
			}
		}
	}
	for _, edge := range declined {
		seen := map[*model.ProvisionalActor]bool{}
		for _, oid := range []string{edge.FromObservation, edge.ToObservation} {
			if a := actorByObservation[oid]; a != nil && !seen[a] {
				attachEdge(a, edge, true)
				seen[a] = true
			}
		}
	}
	next := model.ResolverSnapshot{Epoch: previous.Epoch + 1, Actors: actors, AcceptedEdges: append(accepted, weak...), DeclinedEdges: declined, Delegations: delegations}
	next.Lineage = deriveLineage(previous, actors)
	for _, a := range actors {
		for _, line := range next.Lineage {
			for _, ev := range a.EvidenceChain {
				if ev.ObservationID != "" && line.NewCanonicalID == a.ID {
					a.Lineage = append(a.Lineage, line)
					break
				}
			}
		}
	}
	return next, nil
}

func (e *Engine) Resolve(obs model.Observation) (*model.ProvisionalActor, error) {
	if obs.ID == "" && len(contractIdentifiers(obs)) == 0 && obs.Source == "" {
		return nil, ErrUnresolvableObservation
	}
	if e.quarantine != nil {
		_, _ = e.quarantine.EvaluateObservation(context.Background(), obs)
	}
	if obs.ID == "" {
		obs.ID = "anonymous-" + observationIdentifier(obs.Source+"|"+obs.ActorHint).String()
	}
	if err := e.resolver.UpsertObservation(context.Background(), obs); err != nil {
		return nil, err
	}
	actors, err := e.rebuild(context.Background())
	if err != nil {
		return nil, err
	}
	for _, a := range actors {
		for _, ev := range a.EvidenceChain {
			if ev.ObservationID == obs.ID {
				return cloneActor(a), nil
			}
		}
	}
	return nil, ErrUnresolvableObservation
}

func (e *Engine) ResolvePair(a, b model.Observation, rule Rule) (*model.ProvisionalActor, error) {
	_, err := ResolvePair(a, b, rule)
	if err != nil {
		return nil, err
	}
	if err = e.resolver.UpsertObservation(context.Background(), a); err != nil {
		return nil, err
	}
	if err = e.resolver.UpsertObservation(context.Background(), b); err != nil {
		return nil, err
	}
	actors, err := e.rebuild(context.Background())
	if err != nil {
		return nil, err
	}
	for _, candidate := range actors {
		foundA, foundB := false, false
		for _, evidence := range candidate.EvidenceChain {
			foundA = foundA || evidence.ObservationID == a.ID
			foundB = foundB || evidence.ObservationID == b.ID
		}
		if foundA && foundB {
			return cloneActor(candidate), nil
		}
	}
	return nil, fmt.Errorf("%w: observations %q and %q are in separate published actors", ErrDeterministicMergeDeclined, a.ID, b.ID)
}

func (e *Engine) RetractObservation(ctx context.Context, id string) ([]*model.ProvisionalActor, error) {
	if err := e.resolver.RetractObservation(ctx, id); err != nil {
		return nil, err
	}
	return e.rebuild(ctx)
}
func (e *Engine) Retract(ctx context.Context, id string) ([]*model.ProvisionalActor, error) {
	return e.RetractObservation(ctx, id)
}

// RetractEdge suppresses one deterministic edge in subsequent full rebuilds.
func (e *Engine) RetractEdge(ctx context.Context, id string) ([]*model.ProvisionalActor, error) {
	if err := e.resolver.RetractEdge(ctx, id); err != nil {
		return nil, err
	}
	return e.rebuild(ctx)
}

func (e *Engine) GetActors() []*model.ProvisionalActor {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return cloneSnapshot(e.snapshot).Actors
}
func (e *Engine) GetActor(id string) *model.ProvisionalActor {
	e.mu.RLock()
	defer e.mu.RUnlock()
	for _, a := range e.snapshot.Actors {
		if a.ID == id || a.CanonicalID == id {
			return cloneActor(a)
		}
		for _, al := range a.Aliases {
			if al == id {
				return cloneActor(a)
			}
		}
	}
	return nil
}

// QuarantineEngine returns the active quarantine evaluator.
func (e *Engine) QuarantineEngine() *QuarantineEngine {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.quarantine
}

// SetQuarantineEngine configures a custom QuarantineEngine.
func (e *Engine) SetQuarantineEngine(q *QuarantineEngine) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.quarantine = q
}

// IsActorQuarantined returns true if the actor has been placed in containment.
func (e *Engine) IsActorQuarantined(actorID string) (*model.QuarantineRecord, bool) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.quarantine == nil {
		return nil, false
	}
	return e.quarantine.IsActorQuarantined(actorID)
}

// GetQuarantinedActors returns all currently quarantined actors.
func (e *Engine) GetQuarantinedActors() map[string]*model.QuarantineRecord {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.quarantine == nil {
		return make(map[string]*model.QuarantineRecord)
	}
	return e.quarantine.GetQuarantinedActors()
}

// QuarantineActor triggers explicit containment and quarantine status on an actor.
func (e *Engine) QuarantineActor(ctx context.Context, actorID string, rec model.QuarantineRecord) (*model.QuarantineRecord, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.quarantine == nil {
		e.quarantine = NewQuarantineEngine(QuarantineEngineOptions{Store: e.store})
	}
	res, err := e.quarantine.QuarantineActor(ctx, actorID, rec)
	if err != nil {
		return nil, err
	}
	for _, a := range e.snapshot.Actors {
		if a.ID == actorID || a.CanonicalID == actorID {
			a.Status = model.ActorQuarantined
			a.QuarantineDetails = res
		}
	}
	return res, nil
}

// EvaluateObservationContainment assesses an observation for automated containment.
func (e *Engine) EvaluateObservationContainment(ctx context.Context, obs model.Observation) (*model.QuarantineRecord, error) {
	e.mu.RLock()
	q := e.quarantine
	e.mu.RUnlock()
	if q == nil {
		return nil, nil
	}
	return q.EvaluateObservation(ctx, obs)
}

var ErrAlreadyPromoted = fmt.Errorf("actor already promoted")

func (e *Engine) PromoteActor(id string) (*model.ProvisionalActor, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	next := cloneSnapshot(e.snapshot)
	for _, a := range next.Actors {
		if a.ID != id {
			continue
		}
		if a.Status == model.ActorPromoted {
			return nil, ErrAlreadyPromoted
		}
		now := time.Now().UTC()
		a.Status = model.ActorPromoted
		a.PromotedAt = &now
		a.UpdatedAt = now
		if err := e.resolver.Publish(context.Background(), next); err != nil {
			return nil, fmt.Errorf("persist actor promotion: %w", err)
		}
		e.snapshot = cloneSnapshot(next)
		return cloneActor(a), nil
	}
	return nil, fmt.Errorf("actor %q not found", id)
}
func absInt64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}
