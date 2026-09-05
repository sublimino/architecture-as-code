package correlation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func authenticatedSPIFFE(id, hint, principal string, at time.Time) model.Observation {
	labels := map[string]string{"event_type": "spire_svid_issuance", "spiffe_id": hint}
	if principal != "" {
		labels["sa_principal"] = principal
	}
	return model.Observation{ID: id, Timestamp: at, Layer: model.LayerIdentityAuth,
		Fidelity: model.FidelityStrong, Source: "spire-agent", ActorHint: hint,
		PrincipalID: principal, Labels: labels}
}

func authenticatedGCP(id, principal, project string, at time.Time) model.Observation {
	return model.Observation{ID: id, Timestamp: at, Layer: model.LayerCloudControlPlane,
		Fidelity: model.FidelityDefinitive, Source: "gcp-cloud-audit", ActorHint: principal,
		Labels: map[string]string{"principal_email": principal, "project_id": project}}
}

func actorMembers(actors []*model.ProvisionalActor) [][]string {
	out := make([][]string, 0, len(actors))
	for _, actor := range actors {
		ids := make([]string, 0, len(actor.EvidenceChain))
		for _, ev := range actor.EvidenceChain {
			ids = append(ids, ev.ObservationID)
		}
		sort.Strings(ids)
		out = append(out, ids)
	}
	sort.Slice(out, func(i, j int) bool { return fmt.Sprint(out[i]) < fmt.Sprint(out[j]) })
	return out
}

func TestTypedAlgebraClosedAndFidelityAliased(t *testing.T) {
	want := []model.EdgeType{model.EdgeDeterministicSameEntity, model.EdgeProbabilisticSameEntity,
		model.EdgeTemporal, model.EdgeIPCircumstantial, model.EdgeActsOnBehalfOf, model.EdgeCannotLink}
	for _, typ := range want {
		if !typ.IsValid() {
			t.Errorf("edge type %q must be valid", typ)
		}
	}
	if model.EdgeType("invented").IsValid() {
		t.Fatal("unknown edge type accepted")
	}
	var f model.EdgeFidelity = model.FidelityStrong
	if f != model.FidelityStrong {
		t.Fatal("EdgeFidelity is not a FidelityTier alias")
	}
}

func TestAuthenticatedIdentityMergesButPlainHintNeverDoes(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	spiffe := "spiffe://cluster.local/ns/prod/sa/payments"
	principal := "system:serviceaccount:prod:payments"
	obs := []model.Observation{
		authenticatedSPIFFE("issued", spiffe, principal, now),
		{ID: "k8s", Timestamp: now.Add(24 * time.Hour), Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive,
			Source: "k8s-apiserver-audit", ActorHint: spiffe, PrincipalID: spiffe, Labels: map[string]string{"spiffe_id": spiffe}},
		{ID: "weak-a", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "sensor-a", ActorHint: "shared"},
		{ID: "weak-b", Timestamp: now, Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "sensor-b", ActorHint: "shared"},
	}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got := actorMembers(actors)
	want := [][]string{{"issued", "k8s"}, {"weak-a"}, {"weak-b"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("partitions = %v, want %v", got, want)
	}
	for _, a := range actors {
		if len(a.EvidenceChain) == 2 && len(a.AcceptedEdges) == 0 {
			t.Fatal("merge lacks accepted provenance")
		}
	}
}

func TestLabelledFalseMergeFatalGate(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		authenticatedGCP("alice", "alice@p.iam.gserviceaccount.com", "p", now),
		authenticatedGCP("bob", "bob@p.iam.gserviceaccount.com", "p", now),
		{ID: "alias-a", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "shared", ActorHint: "same-alias", Labels: map[string]string{"src_ip": "10.0.0.1"}},
		{ID: "alias-b", Timestamp: now, Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "shared", ActorHint: "same-alias", Labels: map[string]string{"src_ip": "10.0.0.1"}},
	}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, members := range actorMembers(actors) {
		hasAlice, hasBob := false, false
		for _, id := range members {
			hasAlice = hasAlice || id == "alice"
			hasBob = hasBob || id == "bob"
		}
		if hasAlice && hasBob {
			t.Fatalf("FATAL false merge: distinct labelled principals collapsed: %v", members)
		}
	}
}

func TestTrustDomainAndIssuerBoundaries(t *testing.T) {
	now := time.Now().UTC()
	a := authenticatedSPIFFE("a", "spiffe://one.example/ns/x/sa/bot", "", now)
	b := authenticatedSPIFFE("b", "spiffe://two.example/ns/x/sa/bot", "", now)
	e := trustedEngine(t, []model.Observation{a, b})
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("trust domains merged: %v", actorMembers(actors))
	}
}

func TestPermutationConfluenceAndLexicographicRepresentative(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	base := []model.Observation{authenticatedSPIFFE("z", spiffe, "system:serviceaccount:n:s", now), authenticatedSPIFFE("a", spiffe, "system:serviceaccount:n:s", now.Add(time.Second)), authenticatedSPIFFE("m", spiffe, "system:serviceaccount:n:s", now.Add(-time.Second))}
	var baseline [][]string
	baselineID := ""
	for _, p := range [][]int{{0, 1, 2}, {2, 0, 1}, {1, 2, 0}} {
		obs := []model.Observation{base[p[0]], base[p[1]], base[p[2]]}
		e := trustedEngine(t, obs)
		actors, err := e.Correlate(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if len(actors) != 1 {
			t.Fatalf("confluence fixture split: %v", actorMembers(actors))
		}
		if baseline == nil {
			baseline = actorMembers(actors)
			baselineID = actors[0].ID
		} else if !reflect.DeepEqual(baseline, actorMembers(actors)) {
			t.Fatalf("FATAL confluence failure: %v != %v", baseline, actorMembers(actors))
		}
		if actors[0].ID != baselineID {
			t.Fatalf("FATAL representative confluence failure: %q != %q", actors[0].ID, baselineID)
		}
		if actors[0].CanonicalID != actors[0].ID || actors[0].ID == "" {
			t.Fatalf("bad representative: %+v", actors[0])
		}
	}
}

func TestRetractionSplitsEpochAndRecordsLineage(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	obs := []model.Observation{authenticatedSPIFFE("a", spiffe, "", now), authenticatedSPIFFE("b", spiffe, "", now)}
	e := trustedEngine(t, obs)
	before, err := e.Correlate(context.Background())
	if err != nil || len(before) != 1 {
		t.Fatalf("before: %v %v", actorMembers(before), err)
	}
	after, err := e.RetractObservation(context.Background(), "b")
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 1 || len(after[0].EvidenceChain) != 1 {
		t.Fatalf("after: %v", actorMembers(after))
	}
	if len(after[0].Lineage) == 0 {
		t.Fatal("retraction omitted lineage")
	}
}

type failingResolverStore struct {
	*MemoryResolverStore
	fail bool
}

func (s *failingResolverStore) Publish(_ context.Context, _ model.ResolverSnapshot) error {
	if s.fail {
		return errors.New("publish failed")
	}
	return nil
}

func TestAtomicPublicationAndImmutableReads(t *testing.T) {
	rs := NewMemoryResolverStore()
	now := time.Now().UTC()
	e, err := NewEngineWithResolverStoreAndVerifier(seedStore(t, []model.Observation{authenticatedGCP("a", "a@p", "p", now), authenticatedGCP("b", "a@p", "p", now)}), rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	actors[0].Aliases = append(actors[0].Aliases, "tamper")
	got := e.GetActors()
	for _, v := range got[0].Aliases {
		if v == "tamper" {
			t.Fatal("read API leaked mutable alias")
		}
	}
	snap, err := rs.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Actors) != 1 || len(snap.AcceptedEdges) == 0 {
		t.Fatal("snapshot missing actor")
	}
	b, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	var round model.ResolverSnapshot
	if err = json.Unmarshal(b, &round); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(snap, round) {
		t.Fatalf("snapshot JSON changed data")
	}
}

func TestHubObservationsDoNotTriggerIdentityCap(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/hub"
	obs := make([]model.Observation, 500)
	for i := range obs {
		obs[i] = authenticatedSPIFFE(fmt.Sprintf("o-%03d", i), spiffe, "system:serviceaccount:n:hub", now.Add(time.Duration(i)*time.Second))
	}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 1 || len(actors[0].EvidenceChain) != 500 {
		t.Fatalf("500 observations split: actors=%d members=%v", len(actors), actorMembers(actors))
	}
}

func TestConcurrentResolveRaceMatchesSerial(t *testing.T) {
	now := time.Now().UTC()
	e, _ := NewEngineWithVerifier(seedStore(t, nil), TrustedCollectorAdapter{})
	const n = 100
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _ = e.Resolve(authenticatedGCP(fmt.Sprintf("g-%d", i), "same@p", "p", now))
		}(i)
	}
	wg.Wait()
	actors := e.GetActors()
	if len(actors) != 1 || len(actors[0].EvidenceChain) != n {
		t.Fatalf("concurrent partition mismatch: %v", actorMembers(actors))
	}
}

func TestEveryDefaultRuleHasExplicitNonDeterministicClassification(t *testing.T) {
	for _, r := range DefaultRules() {
		if !r.EdgeType.IsValid() {
			t.Errorf("rule %s unclassified", r.Name)
		}
		if r.EdgeType == model.EdgeDeterministicSameEntity {
			t.Errorf("CEL rule %s must not independently authorize merge", r.Name)
		}
	}
}

func TestSharedServiceAccountPlainHintFanoutStaysSeparate(t *testing.T) {
	now := time.Now().UTC()
	obs := make([]model.Observation, 40)
	for i := range obs {
		obs[i] = model.Observation{ID: fmt.Sprintf("fanout-%02d", i), Timestamp: now,
			Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive,
			Source: fmt.Sprintf("sensor-%d", i), ActorHint: "system:serviceaccount:shared:runner"}
	}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != len(obs) {
		t.Fatalf("plain-hint fanout collapsed: got %d actors, want %d", len(actors), len(obs))
	}
}

func TestIPAndBindAccessorEvidenceStayWeak(t *testing.T) {
	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "ip-a", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelityStrong, Source: "sensor-a", ActorHint: "accessor:mutable", Labels: map[string]string{"src_ip": "10.0.0.9"}},
		{ID: "ip-b", Timestamp: now.Add(time.Second), Layer: model.LayerBehavioural, Fidelity: model.FidelityStrong, Source: "spire-tracker", ActorHint: "accessor:mutable", Labels: map[string]string{"src_ip": "10.0.0.9"}},
	}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("IP/accessor weak evidence merged actors: %v", actorMembers(actors))
	}
	foundIP := false
	for _, a := range actors {
		for _, edge := range a.AcceptedEdges {
			if edge.Type == model.EdgeIPCircumstantial && edge.Provenance.Field == "labels[src_ip]" {
				foundIP = true
			}
		}
	}
	if !foundIP {
		t.Fatal("actual labels[src_ip] evidence was not represented")
	}
}

func TestCannotLinkPrecedesTransitiveUnion(t *testing.T) {
	now := time.Now().UTC()
	principal := "system:serviceaccount:n:shared"
	makeObs := func(id, spiffe string) model.Observation {
		return model.Observation{ID: id, Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive,
			Source: "openbao-audit", ActorHint: spiffe, PrincipalID: principal,
			Labels: map[string]string{"spiffe_id": spiffe, "sa_principal": principal}}
	}
	obs := []model.Observation{makeObs("a", "spiffe://td/ns/n/sa/a"), makeObs("b", "spiffe://td/ns/n/sa/a"), makeObs("c", "spiffe://td/ns/n/sa/c")}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("cannot-link failed to block transitive union: %v", actorMembers(actors))
	}
	found := false
	for _, a := range actors {
		for _, edge := range a.AcceptedEdges {
			if edge.Type == model.EdgeCannotLink {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("cannot-link provenance missing")
	}
}

func TestDeterministicEdgeRetractionSplitsComponent(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	obs := []model.Observation{authenticatedSPIFFE("a", spiffe, "", now), authenticatedSPIFFE("b", spiffe, "", now), authenticatedSPIFFE("c", spiffe, "", now)}
	rs := NewMemoryResolverStore()
	e, err := NewEngineWithResolverStoreAndVerifier(seedStore(t, obs), rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil || len(actors) != 1 {
		t.Fatalf("initial: %v %v", actorMembers(actors), err)
	}
	var edgeID string
	for _, edge := range actors[0].AcceptedEdges {
		if edge.Type == model.EdgeDeterministicSameEntity {
			edgeID = edge.ID
			break
		}
	}
	if edgeID == "" {
		t.Fatal("no retractable deterministic edge")
	}
	after, err := e.RetractEdge(context.Background(), edgeID)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 2 {
		t.Fatalf("edge retraction did not split: %v", actorMembers(after))
	}
	found := false
	for _, a := range after {
		for _, edge := range a.DeclinedEdges {
			if edge.ID == edgeID && edge.Provenance.Reason == "retracted deterministic evidence" {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("retracted edge decline provenance missing")
	}
}

func TestWeakCandidateLookupIsIndependentlyBounded(t *testing.T) {
	now := time.Now().UTC()
	a := model.Observation{ID: "target", Timestamp: now, ActorHint: "shared", Source: "one"}
	b := model.Observation{ID: "b", Timestamp: now, ActorHint: "shared", Source: "two"}
	c := model.Observation{ID: "c", Timestamp: now, ActorHint: "shared", Source: "three"}
	rs := NewMemoryResolverStore()
	if err := rs.ReplaceObservations(context.Background(), []model.Observation{a, b, c}); err != nil {
		t.Fatal(err)
	}
	got, err := rs.Candidates(context.Background(), a, time.Minute, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != "b" {
		t.Fatalf("bounded weak candidate result = %+v", got)
	}
}

func TestReplayAndOutOfOrderAreIdempotent(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	a := authenticatedSPIFFE("later", spiffe, "", now.Add(time.Hour))
	b := authenticatedSPIFFE("earlier", spiffe, "", now)
	e := trustedEngine(t, []model.Observation{a, b, a, b})
	first, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	second, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actorMembers(first), actorMembers(second)) {
		t.Fatalf("replay changed partition: %v vs %v", actorMembers(first), actorMembers(second))
	}
	if len(first) != 1 || len(first[0].EvidenceChain) != 2 {
		t.Fatalf("duplicate observations were not idempotent: %v", actorMembers(first))
	}
}

func TestIdentityCapDeclinesBridgeWithoutCountingObservations(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/s"
	obs := []model.Observation{
		authenticatedSPIFFE("a", spiffe, "system:serviceaccount:n:first", now), authenticatedSPIFFE("b", spiffe, "system:serviceaccount:n:second", now),
	}
	e, err := NewEngineWithOptionsAndVerifier(seedStore(t, obs), NewMemoryResolverStore(), ResolverOptions{MaxDistinctIdentities: 2, MaxMergeDegree: 1}, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("identity cap not enforced: %v", actorMembers(actors))
	}
	declined := 0
	for _, a := range actors {
		for _, edge := range a.DeclinedEdges {
			if edge.Provenance.Reason == "distinct identity cap" {
				declined++
			}
		}
	}
	if declined == 0 {
		t.Fatal("identity-cap decline was not audited")
	}
}

func TestMergeDegreeCapDeclinesIdentityHubBridges(t *testing.T) {
	now := time.Now().UTC()
	spiffe := "spiffe://td/ns/n/sa/hub"
	obs := []model.Observation{
		authenticatedSPIFFE("a", spiffe, "system:serviceaccount:n:a", now),
		authenticatedSPIFFE("b", spiffe, "system:serviceaccount:n:b", now),
		authenticatedSPIFFE("c", spiffe, "system:serviceaccount:n:c", now),
	}
	e, err := NewEngineWithOptionsAndVerifier(seedStore(t, obs), NewMemoryResolverStore(), ResolverOptions{MaxDistinctIdentities: 16, MaxMergeDegree: 1}, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("merge degree cap expected two components, got %v", actorMembers(actors))
	}
	found := false
	for _, a := range actors {
		for _, edge := range a.DeclinedEdges {
			if edge.Provenance.Reason == "merge degree cap" {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("merge-degree decline provenance missing")
	}
}

func TestGCPProjectIssuerBoundary(t *testing.T) {
	now := time.Now().UTC()
	obs := []model.Observation{authenticatedGCP("p1", "same@example.com", "one", now), authenticatedGCP("p2", "same@example.com", "two", now)}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 2 {
		t.Fatalf("GCP project issuers collided: %v", actorMembers(actors))
	}
}

func TestAtomicPublishFailurePreservesLastEpoch(t *testing.T) {
	now := time.Now().UTC()
	signalStore := seedStore(t, []model.Observation{authenticatedGCP("a", "a@p", "p", now)})
	rs := &failingResolverStore{MemoryResolverStore: NewMemoryResolverStore()}
	e, err := NewEngineWithResolverStoreAndVerifier(signalStore, rs, TrustedCollectorAdapter{})
	if err != nil {
		t.Fatal(err)
	}
	before, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	rs.fail = true
	if err = signalStore.Append(context.Background(), []model.Observation{authenticatedGCP("b", "b@p", "p", now)}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.Correlate(context.Background()); err == nil {
		t.Fatal("publish failure was hidden")
	}
	after := e.GetActors()
	if !reflect.DeepEqual(actorMembers(before), actorMembers(after)) {
		t.Fatalf("failed publication changed visible epoch: %v -> %v", actorMembers(before), actorMembers(after))
	}
}

func TestDirectedDelegationDoesNotUnionActors(t *testing.T) {
	now := time.Now().UTC()
	delegation := &model.EvidenceLink{ObservationID: "d", Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive, Contribution: "impersonation", Timestamp: now}
	obs := model.Observation{ID: "d", Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive, Source: "k8s-apiserver-audit", ActorHint: "spiffe://td/ns/n/sa/acting", PrincipalID: "spiffe://td/ns/n/sa/acting", ImpersonatedUser: "spiffe://td/ns/n/sa/acting", DelegationEdge: delegation, Labels: map[string]string{"spiffe_id": "spiffe://td/ns/n/sa/acting", "acting_principal": "spiffe://td/ns/n/sa/acting", "impersonated_user": "spiffe://td/ns/n/sa/acting", "delegation_basis": "impersonation", "delegator": "spiffe://td/ns/n/sa/caller"}}
	e := trustedEngine(t, []model.Observation{obs})
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 1 || len(actors[0].Delegations) != 1 {
		t.Fatalf("delegation missing: %+v", actors)
	}
	if actors[0].Delegations[0].Type != model.EdgeActsOnBehalfOf || !actors[0].Delegations[0].Directed {
		t.Fatal("delegation edge is not directed")
	}
}

func TestThousandsMixedEdgesRemainDeterministic(t *testing.T) {
	if testing.Short() {
		t.Skip("stress test")
	}
	now := time.Now().UTC()
	obs := make([]model.Observation, 0, 1200)
	for identity := 0; identity < 400; identity++ {
		principal := fmt.Sprintf("id-%03d@p", identity)
		for event := 0; event < 3; event++ {
			obs = append(obs, authenticatedGCP(fmt.Sprintf("%03d-%d", identity, event), principal, "p", now.Add(time.Duration(event)*time.Second)))
		}
	}
	e := trustedEngine(t, obs)
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 400 {
		t.Fatalf("mixed stress partition count=%d want=400", len(actors))
	}
}
