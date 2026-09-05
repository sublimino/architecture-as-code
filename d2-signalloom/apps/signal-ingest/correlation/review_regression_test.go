package correlation

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func trustedEngine(t *testing.T, observations []model.Observation) *Engine {
	t.Helper()
	e, err := NewEngineWithVerifier(seedStore(t, observations), TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func TestDefaultVerifierDeniesSourceFieldSelfAssertion(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	obs := []model.Observation{authenticatedSPIFFE("a", spiffe, "", now), authenticatedSPIFFE("b", spiffe, "", now)}
	e, err := NewEngine(seedStore(t, obs))
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("default verifier trusted attacker-controlled fields: %v", actorMembers(actors))
	}
}

func TestCompatibleClosureFindsXAcrossConflictingMiddleHint(t *testing.T) {
	now := time.Now().UTC()
	principal := "system:serviceaccount:n:shared"
	makeObs := func(id, hint string) model.Observation {
		return model.Observation{ID: id, Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive, Source: "openbao-audit", ActorHint: hint, PrincipalID: principal, Labels: map[string]string{"spiffe_id": hint, "sa_principal": principal}}
	}
	actors, err := trustedEngine(t, []model.Observation{makeObs("a-x", "spiffe://td/ns/n/sa/x"), makeObs("b-y", "spiffe://td/ns/n/sa/y"), makeObs("c-x", "spiffe://td/ns/n/sa/x")}).Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := [][]string{{"a-x", "c-x"}, {"b-y"}}
	if got := actorMembers(actors); !reflect.DeepEqual(got, want) {
		t.Fatalf("compatible closure=%v want=%v", got, want)
	}
}

func TestSemanticRepresentativeAndConflictDisambiguation(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://cluster.local/ns/n/sa/s"
	actors, err := trustedEngine(t, []model.Observation{authenticatedSPIFFE("z", spiffe, "", now), authenticatedSPIFFE("a", spiffe, "", now)}).Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := "actor-cluster.local|spiffe|" + spiffe
	if len(actors) != 1 || actors[0].ID != want {
		t.Fatalf("semantic representative=%v want=%q", actors, want)
	}
	principal := "system:serviceaccount:n:shared"
	makeObs := func(id, hint string) model.Observation {
		return model.Observation{ID: id, Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive, Source: "openbao-audit", ActorHint: hint, PrincipalID: principal, Labels: map[string]string{"spiffe_id": hint, "sa_principal": principal}}
	}
	split, err := trustedEngine(t, []model.Observation{makeObs("x", "spiffe://z/ns/n/sa/x"), makeObs("y", "spiffe://z/ns/n/sa/y")}).Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(split) != 2 || split[0].ID == split[1].ID {
		t.Fatalf("conflicting semantic actors not disambiguated: %v", split)
	}
}

func TestResolvePairReturnsDeclinedErrorWhenEpochRejects(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	a := authenticatedSPIFFE("a", spiffe, "system:serviceaccount:n:a", now)
	b := authenticatedSPIFFE("b", spiffe, "system:serviceaccount:n:b", now)
	e, err := NewEngineWithOptionsAndVerifier(seedStore(t, nil), NewMemoryResolverStore(), ResolverOptions{MaxDistinctIdentities: 2}, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actor, err := e.ResolvePair(a, b, Rule{Name: "identity", CEL: `a.actor_hint == b.actor_hint`, EdgeType: model.EdgeProbabilisticSameEntity})
	if actor != nil || !errors.Is(err, ErrDeterministicMergeDeclined) {
		t.Fatalf("declined epoch returned actor=%v err=%v", actor, err)
	}
}

func TestStandaloneResolvePairOnlyRecordsActuallyMatchedRule(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	a := authenticatedSPIFFE("a", spiffe, "", now)
	b := authenticatedSPIFFE("b", spiffe, "", now)
	actor, err := ResolvePair(a, b, Rule{Name: "false_rule", CEL: `a.actor_hint != b.actor_hint`, EdgeType: model.EdgeProbabilisticSameEntity})
	if err != nil {
		t.Fatal(err)
	}
	if actor.AcceptedEdges[0].Provenance.Rule != "" {
		t.Fatalf("unmatched CEL rule invented provenance: %+v", actor.AcceptedEdges[0].Provenance)
	}
	actor, err = ResolvePair(a, b, Rule{Name: "true_rule", CEL: `a.actor_hint == b.actor_hint`, EdgeType: model.EdgeProbabilisticSameEntity})
	if err != nil {
		t.Fatal(err)
	}
	if actor.AcceptedEdges[0].Provenance.Rule != "true_rule" {
		t.Fatalf("matched CEL rule provenance missing: %+v", actor.AcceptedEdges[0].Provenance)
	}
}

func TestEnginePreservesActualCELProvenanceForVerifiedPair(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	a := authenticatedSPIFFE("a", spiffe, "", now)
	b := authenticatedSPIFFE("b", spiffe, "", now)
	b.Layer = model.LayerCloudControlPlane
	rules := []Rule{
		{Name: "actual_match", CEL: `a.actor_hint == b.actor_hint`, EdgeType: model.EdgeProbabilisticSameEntity},
		{Name: "not_a_match", CEL: `a.actor_hint != b.actor_hint`, EdgeType: model.EdgeProbabilisticSameEntity},
	}
	e, err := newEngine(seedStore(t, []model.Observation{a, b}), NewMemoryResolverStore(), rules, ResolverOptions{}, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, edge := range actors[0].AcceptedEdges {
		if edge.Provenance.Rule == "actual_match" {
			found = true
		}
		if edge.Provenance.Rule == "not_a_match" {
			t.Fatal("engine recorded unmatched CEL provenance")
		}
	}
	if !found {
		t.Fatal("engine omitted matched CEL provenance")
	}
}

func TestObservationTombstoneSurvivesRefreshNewObservationAndRestart(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	a := authenticatedSPIFFE("a", spiffe, "", now)
	b := authenticatedSPIFFE("b", spiffe, "", now)
	signals := seedStore(t, []model.Observation{a, b})
	rs := NewMemoryResolverStore()
	e, err := NewEngineWithResolverStoreAndVerifier(signals, rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	if actors, err := e.Correlate(ctx); err != nil || len(actors) != 1 {
		t.Fatalf("initial=%v %v", actorMembers(actors), err)
	}
	if _, err = e.RetractObservation(ctx, "b"); err != nil {
		t.Fatal(err)
	}
	if actors, err := e.Correlate(ctx); err != nil || len(actors) != 1 || len(actors[0].EvidenceChain) != 1 {
		t.Fatalf("refresh resurrected tombstone: %v %v", actorMembers(actors), err)
	}
	c := authenticatedSPIFFE("c", spiffe, "", now)
	if err = signals.Append(ctx, []model.Observation{c}); err != nil {
		t.Fatal(err)
	}
	if actors, err := e.Correlate(ctx); err != nil || !reflect.DeepEqual(actorMembers(actors), [][]string{{"a", "c"}}) {
		t.Fatalf("new observation/tombstone=%v %v", actorMembers(actors), err)
	}
	restarted, err := NewEngineWithResolverStoreAndVerifier(signals, rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	if actors, err := restarted.Correlate(ctx); err != nil || !reflect.DeepEqual(actorMembers(actors), [][]string{{"a", "c"}}) {
		t.Fatalf("restart resurrected tombstone: %v %v", actorMembers(actors), err)
	}
}

func TestFactualEdgeRetractionSurvivesNewObservationAndRestart(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	a := authenticatedSPIFFE("a", spiffe, "", now)
	b := authenticatedSPIFFE("b", spiffe, "", now)
	signals := seedStore(t, []model.Observation{a, b})
	rs := NewMemoryResolverStore()
	e, err := NewEngineWithResolverStoreAndVerifier(signals, rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(ctx)
	if err != nil {
		t.Fatal(err)
	}
	edgeID := ""
	for _, edge := range actors[0].AcceptedEdges {
		if edge.Type == model.EdgeDeterministicSameEntity {
			edgeID = edge.ID
			break
		}
	}
	if edgeID == "" {
		t.Fatal("missing factual edge")
	}
	if _, err = e.RetractEdge(ctx, edgeID); err != nil {
		t.Fatal(err)
	}
	c := authenticatedSPIFFE("c", spiffe, "", now)
	if err = signals.Append(ctx, []model.Observation{c}); err != nil {
		t.Fatal(err)
	}
	after, err := e.Correlate(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, members := range actorMembers(after) {
		if reflect.DeepEqual(members, []string{"a", "b", "c"}) {
			t.Fatalf("retracted pair rejoined transitively: %v", actorMembers(after))
		}
	}
	restarted, err := NewEngineWithResolverStoreAndVerifier(signals, rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	again, err := restarted.Correlate(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actorMembers(after), actorMembers(again)) {
		t.Fatalf("edge tombstone lost on restart: %v -> %v", actorMembers(after), actorMembers(again))
	}
}

func TestPromotionPersistsAcrossRebuildAndRestart(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	signals := seedStore(t, []model.Observation{authenticatedSPIFFE("a", spiffe, "", now), authenticatedSPIFFE("b", spiffe, "", now)})
	rs := NewMemoryResolverStore()
	e, err := NewEngineWithResolverStoreAndVerifier(signals, rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(ctx)
	if err != nil {
		t.Fatal(err)
	}
	id := actors[0].ID
	if _, err = e.PromoteActor(id); err != nil {
		t.Fatal(err)
	}
	rebuilt, err := e.Correlate(ctx)
	if err != nil || rebuilt[0].Status != model.ActorPromoted {
		t.Fatalf("promotion lost on rebuild: %+v %v", rebuilt, err)
	}
	restarted, err := NewEngineWithResolverStoreAndVerifier(signals, rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	if got := restarted.GetActor(id); got == nil || got.Status != model.ActorPromoted {
		t.Fatalf("promotion lost on restart: %+v", got)
	}
}

func TestDelegationCloneIsDeepAndTwoActorsRemainSeparate(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	caller := "spiffe://td/ns/n/sa/caller"
	acting := "spiffe://td/ns/n/sa/acting"
	base := authenticatedSPIFFE("caller", caller, "", now)
	acted := authenticatedSPIFFE("acting", acting, "", now)
	delegation := acted
	delegation.ID = "delegation"
	delegation.Source = "k8s-apiserver-audit"
	delegation.PrincipalID = acting
	delegation.ActorHint = acting
	delegation.ImpersonatedUser = acting
	delegation.DelegationEdge = &model.EvidenceLink{ObservationID: "delegation", Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive}
	delegation.Labels = map[string]string{"spiffe_id": acting, "acting_principal": acting, "delegator": caller, "impersonated_user": acting, "delegation_basis": "impersonation"}
	e := trustedEngine(t, []model.Observation{base, acted, delegation})
	actors, err := e.Correlate(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("delegation merged identities: %v", actorMembers(actors))
	}
	var source *model.ProvisionalActor
	for _, a := range actors {
		if len(a.Delegations) > 0 {
			source = a
			break
		}
	}
	if source == nil {
		t.Fatal("delegation missing")
	}
	source.Delegations[0].Provenance.ObservationIDs[0] = "tampered"
	for _, a := range e.GetActors() {
		for _, edge := range a.Delegations {
			if edge.Provenance.ObservationIDs[0] == "tampered" {
				t.Fatal("delegation provenance slice was shallow-copied")
			}
		}
	}
	snapshot, err := e.resolver.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	snapshot.Delegations[0].Provenance.ObservationIDs[0] = "snapshot-tamper"
	again, err := e.resolver.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if again.Delegations[0].Provenance.ObservationIDs[0] == "snapshot-tamper" {
		t.Fatal("snapshot delegation provenance slice was shallow-copied")
	}
}

type noWeakCandidateStore struct{ *MemoryResolverStore }

func (s *noWeakCandidateStore) Candidates(context.Context, model.Observation, time.Duration, int) ([]model.Observation, error) {
	return nil, nil
}

func TestAuthenticatedClosureDoesNotDependOnWeakCandidateSeam(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	rs := &noWeakCandidateStore{MemoryResolverStore: NewMemoryResolverStore()}
	e, err := NewEngineWithResolverStoreAndVerifier(seedStore(t, []model.Observation{authenticatedSPIFFE("a", spiffe, "", now), authenticatedSPIFFE("b", spiffe, "", now.AddDate(1, 0, 0))}), rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil || len(actors) != 1 {
		t.Fatalf("authenticated closure depended on weak candidates: %v %v", actorMembers(actors), err)
	}
}

func TestCombinedComponentDegreeCannotExceedCap(t *testing.T) {
	d := &disjointSet{parent: []int{0, 1, 2, 3}, size: []int{1, 1, 1, 1}, ids: []map[string]struct{}{{"a": {}}, {"b": {}}, {"c": {}}, {"d": {}}}, hints: []map[string]struct{}{{}, {}, {}, {}}, degree: []int{1, 1, 0, 0}}
	if ok, _ := d.union(0, 1, 16, 2, map[[2]int]struct{}{}); ok {
		t.Fatal("combined degree 1+1+1 exceeded cap 2")
	}
}

func TestMixedStressExactMembershipSurvivesShuffle(t *testing.T) {
	now := time.Now().UTC()
	obs := make([]model.Observation, 0, 300)
	want := make([][]string, 0, 100)
	for i := 0; i < 100; i++ {
		principal := fmt.Sprintf("id-%03d@p", i)
		members := []string{}
		for j := 0; j < 3; j++ {
			id := fmt.Sprintf("%03d-%d", i, j)
			members = append(members, id)
			obs = append(obs, authenticatedGCP(id, principal, "p", now))
		}
		want = append(want, members)
	}
	sort.Slice(want, func(i, j int) bool { return fmt.Sprint(want[i]) < fmt.Sprint(want[j]) })
	reversed := append([]model.Observation(nil), obs...)
	sort.Slice(reversed, func(i, j int) bool { return reversed[i].ID > reversed[j].ID })
	first, err := trustedEngine(t, obs).Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	second, err := trustedEngine(t, reversed).Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actorMembers(first), want) || !reflect.DeepEqual(actorMembers(second), want) {
		t.Fatal("mixed shuffled membership mismatch")
	}
}
