package correlation

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Authenticated SPIFFE identities in distinct trust domains stay distinct even
// when their local Kubernetes service-account names coincide. Conflicting hints
// veto that apparent shared principal in the approved resolution contract.
func TestCardinalResolveDistinctTrustDomainsFalseMergeZero(t *testing.T) {
	at := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	principal := "system:serviceaccount:prod:payments"
	observation := func(id, domain string) model.Observation {
		spiffe := "spiffe://" + domain + "/ns/prod/sa/payments"
		return model.Observation{
			ID: id, Timestamp: at, Layer: model.LayerIdentityAuth,
			Fidelity: model.FidelityStrong, Source: "spire-agent",
			ActorHint: spiffe, PrincipalID: principal,
			Labels: map[string]string{
				"event_type": "spire_svid_issuance",
				"spiffe_id": spiffe, "sa_principal": principal,
			},
		}
	}
	a := observation("principal-a", "z-one.example")
	b := observation("principal-b", "z-two.example")
	if _, err := ResolvePair(a, b, Rule{}); !errors.Is(err, ErrContradictoryPrincipals) {
		t.Fatalf("fixture must exercise conflicting authenticated hints; pair error=%v", err)
	}
	left, err := Resolve(a)
	if err != nil {
		t.Fatal(err)
	}
	right, err := Resolve(b)
	if err != nil {
		t.Fatal(err)
	}
	falseMerges := 0
	if left.CanonicalID == right.CanonicalID {
		falseMerges++
	}
	if falseMerges != 0 {
		t.Fatalf("false-merge == %d, want 0: distinct labelled SPIFFE principals %q and %q collapse to canonical actor_id %q", falseMerges, a.ActorHint, b.ActorHint, left.CanonicalID)
	}
}

// Positive control and engine-level regression for the authorized ranking fix.
// Both domains sort after "kubernetes", so a lexical-only implementation fails.
func TestSPIFFEFirstRepresentativeAcrossResolutionEntryPoints(t *testing.T) {
	at := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	principal := "system:serviceaccount:prod:payments"
	a := authenticatedSPIFFE("a", "spiffe://z-one.example/ns/prod/sa/payments", principal, at)
	b := a
	b.ID = "b"
	c := authenticatedSPIFFE("c", "spiffe://z-two.example/ns/prod/sa/payments", principal, at)
	id, _ := typedSPIFFE(a.ActorHint)
	want := "actor-" + id.String()
	for _, obs := range []model.Observation{a, b} {
		actor, err := Resolve(obs)
		if err != nil || actor.CanonicalID != want || actor.PrincipalID != a.ActorHint {
			t.Fatalf("Resolve canonical representative: actor=%+v err=%v want=%s", actor, err, want)
		}
	}
	pair, err := ResolvePair(a, b, Rule{})
	if err != nil || pair.CanonicalID != want {
		t.Fatalf("ResolvePair representative: actor=%+v err=%v want=%s", pair, err, want)
	}
	var baseline map[string]string
	for _, order := range [][]model.Observation{{a, b, c}, {c, b, a}, {b, a, c}} {
		engine := trustedEngine(t, order)
		actors, err := engine.Correlate(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]string{}
		for _, actor := range actors {
			for _, evidence := range actor.EvidenceChain {
				got[evidence.ObservationID] = actor.CanonicalID
			}
		}
		if got["a"] != want || got["b"] != want {
			t.Fatalf("same-principal recall or representative failure: %v", got)
		}
		otherID, ok := typedSPIFFE(c.ActorHint)
		if !ok || len(got) != 3 || got["c"] != "actor-"+otherID.String() {
			t.Fatalf("distinct-principal representative or observation loss: %v", got)
		}
		if got["a"] == got["c"] {
			t.Fatalf("false-merge == 1, want 0: distinct trust domains: %v", got)
		}
		if baseline != nil && !reflect.DeepEqual(got, baseline) {
			t.Fatalf("non-confluent canonical partition: %v != %v", got, baseline)
		}
		baseline = got
	}
}
