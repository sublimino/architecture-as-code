package correlation

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func seedStore(t *testing.T, obs []model.Observation) store.SignalStore {
	t.Helper()
	s := store.NewMemoryStore()
	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestCorrelation_CrossLayerIdentity(t *testing.T) {
	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "net-1", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "src-a", ActorHint: "sa-shadow-bot", Description: "outbound to AI API"},
		{ID: "id-1", Timestamp: now.Add(time.Minute), Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive, Source: "src-b", ActorHint: "sa-shadow-bot", Description: "API-only service account"},
	}
	s := seedStore(t, obs)

	e, err := NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}

	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if len(actors) != 1 {
		t.Fatalf("want 1 actor, got %d", len(actors))
	}

	actor := actors[0]
	if len(actor.EvidenceChain) != 2 {
		t.Errorf("want 2 evidence links, got %d", len(actor.EvidenceChain))
	}
	// V2 corroboration rule: cross-layer suggestive without strong/definitive
	// is capped below actionable (0.49). The actor is correlated but provisional.
	if actor.Confidence >= 0.5 {
		t.Errorf("cross-layer suggestive-only must be < 0.5 (corroboration cap), got %f", actor.Confidence)
	}
	if actor.Status != model.ActorProvisional {
		t.Errorf("want status provisional (no strong/definitive corroboration), got %s", actor.Status)
	}
}

func TestCorrelation_TimingCorrelation(t *testing.T) {
	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "net-1", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "workload-x"},
		{ID: "beh-1", Timestamp: now.Add(2 * time.Minute), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "workload-x", ActorHint: "workload-x"},
	}
	s := seedStore(t, obs)

	e, err := NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}

	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if len(actors) == 0 {
		t.Fatal("timing correlation should produce at least 1 actor")
	}
}

func TestCorrelation_ScheduledJobExclusion(t *testing.T) {
	// A behavioural observation with no actor_hint (scheduled job pattern)
	// must NOT produce an actor.
	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "cron-1", Timestamp: now, Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "cron-runner", ActorHint: "", Description: "regular 5min pattern"},
	}
	s := seedStore(t, obs)

	e, err := NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}

	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	// Should produce zero actors — single observation and it's excluded.
	if len(actors) != 0 {
		t.Errorf("scheduled job exclusion: want 0 actors, got %d", len(actors))
	}
}

func TestCorrelation_ScheduledJobNotCorrelatedWithIdentity(t *testing.T) {
	// Even if a scheduled job and an identity signal share a source,
	// the scheduled job observation should be excluded first.
	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "cron-1", Timestamp: now, Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "workload-y", ActorHint: "", Description: "cron pattern"},
		{ID: "id-1", Timestamp: now.Add(time.Minute), Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive, Source: "workload-y", ActorHint: "sa-legit", Description: "service account"},
	}
	s := seedStore(t, obs)

	e, err := NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}

	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	// The cron observation is excluded, so there's only one observation left = no pair = no actor.
	if len(actors) != 0 {
		t.Errorf("scheduled job + identity: want 0 actors (cron excluded leaves 1 obs), got %d", len(actors))
	}
}

func TestCorrelation_CredentialChain(t *testing.T) {
	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "id-1", Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive, Source: "auth-server", ActorHint: "sa-shadow-bot"},
		{ID: "beh-1", Timestamp: now.Add(30 * time.Second), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "api-server", ActorHint: "sa-shadow-bot"},
	}
	s := seedStore(t, obs)

	e, err := NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}

	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if len(actors) != 1 {
		t.Fatalf("credential chain: want 1 actor, got %d", len(actors))
	}

	// V2 corroboration rule: credential chain with only suggestive signals
	// stays provisional — needs strong/definitive to reach actionable.
	if actors[0].Status != model.ActorProvisional {
		t.Errorf("credential chain (suggestive-only) should be provisional, got %s", actors[0].Status)
	}
	if actors[0].Confidence >= 0.5 {
		t.Errorf("credential chain (suggestive-only) confidence must be < 0.5, got %f", actors[0].Confidence)
	}
}
