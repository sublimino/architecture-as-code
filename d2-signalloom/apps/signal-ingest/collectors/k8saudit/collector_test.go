// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package k8saudit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type captureSink struct {
	obs []model.Observation
}

func (s *captureSink) IngestObservation(_ context.Context, o *model.Observation) error {
	s.obs = append(s.obs, *o)
	return nil
}

// TestCollector_OffIngestsNothing: an off collector touches no source.
func TestCollector_OffIngestsNothing(t *testing.T) {
	sink := &captureSink{}
	c := New(ModeOff, Config{}, sink)
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start(off): %v", err)
	}
	if len(sink.obs) != 0 {
		t.Errorf("off mode ingested %d observations, want 0", len(sink.obs))
	}
}

// TestCollector_FixtureProjectsEveryEmbeddedEvent ties fixture mode to the
// embedded corpus: every projected fixture observation reaches the sink, and
// every one is LayerKubernetes with the k8saudit-kube source.
func TestCollector_FixtureProjectsEveryEmbeddedEvent(t *testing.T) {
	want, err := FixtureObservations()
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	sink := &captureSink{}
	c := New(ModeFixture, Config{}, sink)
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start(fixture): %v", err)
	}
	if len(sink.obs) != len(want) {
		t.Fatalf("fixture mode ingested %d observations, want %d (the projected corpus)", len(sink.obs), len(want))
	}
	for _, o := range sink.obs {
		if o.Layer != model.LayerKubernetes {
			t.Errorf("observation %s has layer %q, want kubernetes", o.ID, o.Layer)
		}
		if o.Source != ObservationSource {
			t.Errorf("observation %s has source %q, want %q", o.ID, o.Source, ObservationSource)
		}
	}
}

// TestCollector_LiveWardenLocalReadsTheFile: warden-local live mode reads a real
// audit log file off disk and projects it. This is the live path for on-node
// gathering, not a fixture.
func TestCollector_LiveWardenLocalReadsTheFile(t *testing.T) {
	// A two-line JSON-lines audit log, the apiserver --audit-log-path format.
	jsonl := `{"auditID":"w-1","stage":"ResponseComplete","verb":"create","user":{"username":"carol@corp"},"objectRef":{"resource":"pods","subresource":"exec","namespace":"x","name":"p"},"responseStatus":{"code":201},"annotations":{"authorization.k8s.io/decision":"allow"},"stageTimestamp":"2026-02-01T10:00:00Z"}
{"auditID":"w-2","stage":"ResponseComplete","verb":"get","user":{"username":"carol@corp"},"objectRef":{"resource":"pods","namespace":"x","name":"p"},"responseStatus":{"code":200},"stageTimestamp":"2026-02-01T10:01:00Z"}`
	path := filepath.Join(t.TempDir(), "audit.log")
	if err := os.WriteFile(path, []byte(jsonl), 0o600); err != nil {
		t.Fatalf("write audit log: %v", err)
	}
	sink := &captureSink{}
	c := New(ModeLive, Config{SourceName: "warden-local", AuditLogPath: path}, sink)
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start(live warden-local): %v", err)
	}
	if len(sink.obs) != 2 {
		t.Fatalf("warden-local ingested %d observations, want 2", len(sink.obs))
	}
}

// TestCollector_LiveWardenLocalRequiresPath: no path configured is a loud
// configuration error, never a silently empty collector.
func TestCollector_LiveWardenLocalRequiresPath(t *testing.T) {
	c := New(ModeLive, Config{SourceName: "warden-local"}, &captureSink{})
	err := c.Start(context.Background())
	if !errors.Is(err, ErrNoAuditLogPath) {
		t.Fatalf("Start with no path = %v, want ErrNoAuditLogPath", err)
	}
}

// TestCollector_LiveCloudIsDeferred: EKS/GKE/AKS live mode returns the deferred
// error until a live cloud client factory is registered.
func TestCollector_LiveCloudIsDeferred(t *testing.T) {
	for _, p := range []string{"eks", "gke", "aks"} {
		c := New(ModeLive, Config{SourceName: p, Cloud: CloudConfig{Provider: CloudProvider(p)}}, &captureSink{})
		err := c.Start(context.Background())
		if !errors.Is(err, ErrCloudLiveDeferred) {
			t.Errorf("Start(live %s) = %v, want ErrCloudLiveDeferred", p, err)
		}
	}
}

// TestCollector_LiveCloudWithFactoryDrains proves the cloud seam is real, not a
// permanent stub: a registered factory's client feeds the same projection. The
// factory is cleared in a cleanup so no other test sees it.
func TestCollector_LiveCloudWithFactoryDrains(t *testing.T) {
	SetLiveCloudClientFactory(func(_ CloudProvider, _ CloudConfig) (CloudAuditClient, error) {
		return fakeCloudClient{events: []AuditEvent{{
			AuditID: "gke-1", Stage: "ResponseComplete", Verb: "get",
			User:      UserInfo{Username: "svc@project.iam"},
			ObjectRef: &ObjectRef{Resource: "secrets", Namespace: "default", Name: "s"},
		}}}, nil
	})
	t.Cleanup(func() { SetLiveCloudClientFactory(nil) })

	sink := &captureSink{}
	c := New(ModeLive, Config{SourceName: "gke"}, sink)
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start(live gke with factory): %v", err)
	}
	if len(sink.obs) != 1 || sink.obs[0].Layer != model.LayerKubernetes {
		t.Fatalf("cloud factory drain produced %d observations; want 1 kubernetes", len(sink.obs))
	}
}

type fakeCloudClient struct{ events []AuditEvent }

func (f fakeCloudClient) FetchAuditEvents(_ context.Context) ([]AuditEvent, error) {
	return f.events, nil
}

// TestFixtureCorpusCount is the canary the e2e expectation table is written
// against: the embedded corpus projects exactly this many observations. A
// fixture edit that changes the count fails here first, pointing at the table.
func TestFixtureCorpusCount(t *testing.T) {
	obs, err := FixtureObservations()
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	const wantObservations = 40
	if len(obs) != wantObservations {
		t.Fatalf("embedded corpus projects %d observations, want %d", len(obs), wantObservations)
	}
}
