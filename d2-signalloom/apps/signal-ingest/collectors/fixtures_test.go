package collectors

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestSeedAll_ProducesObservations(t *testing.T) {
	obs := SeedAll(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("SeedAll should produce observations")
	}
}

func TestSeedAll_CoversAllInScopeLayers(t *testing.T) {
	obs := SeedAll(time.Now().UTC())
	layers := make(map[model.Layer]bool)
	for _, o := range obs {
		layers[o.Layer] = true
	}
	for _, l := range model.InScopeLayers() {
		if !layers[l] {
			t.Errorf("missing layer in fixtures: %s", l)
		}
	}
}

func TestFixtures_HaveValidFields(t *testing.T) {
	obs := SeedAll(time.Now().UTC())
	for _, o := range obs {
		if o.ID == "" {
			t.Error("observation missing ID")
		}
		if o.Timestamp.IsZero() {
			t.Errorf("observation %s has zero timestamp", o.ID)
		}
		if !o.Layer.IsValid() {
			t.Errorf("observation %s has invalid layer: %s", o.ID, o.Layer)
		}
		if o.Source == "" {
			t.Errorf("observation %s missing source", o.ID)
		}
		if o.Description == "" {
			t.Errorf("observation %s missing description", o.ID)
		}
	}
}

func TestScheduledJobFixtures_NoActorHint(t *testing.T) {
	obs := ScheduledJobFixtures(time.Now().UTC())
	for _, o := range obs {
		if o.ActorHint != "" {
			t.Errorf("scheduled job fixture %s should have empty actor_hint, got %q", o.ID, o.ActorHint)
		}
	}
}

func TestNetworkEgressFixtures_NonEmpty(t *testing.T) {
	obs := NetworkEgressFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("network egress fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerNetworkEgress {
			t.Errorf("wrong layer: want %s, got %s", model.LayerNetworkEgress, o.Layer)
		}
	}
}

func TestIdentityAuthFixtures_NonEmpty(t *testing.T) {
	obs := IdentityAuthFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("identity auth fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerIdentityAuth {
			t.Errorf("wrong layer: want %s, got %s", model.LayerIdentityAuth, o.Layer)
		}
	}
}

func TestApplicationSaaSFixtures_NonEmpty(t *testing.T) {
	obs := ApplicationSaaSFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("application SaaS fixtures should not be empty")
	}
}

func TestEndpointHostFixtures_NonEmpty(t *testing.T) {
	obs := EndpointHostFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("endpoint host fixtures should not be empty")
	}
}

func TestBehaviouralFixtures_NonEmpty(t *testing.T) {
	obs := BehaviouralFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("behavioural fixtures should not be empty")
	}
}
