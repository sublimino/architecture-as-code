package correlation

import (
	"errors"
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
