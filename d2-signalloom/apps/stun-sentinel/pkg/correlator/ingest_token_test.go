// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// The ingest credential used to default to "sentinel-in-cluster-token", a
// string in public source that signal-ingest was configured to accept. It now
// comes only from the Secret stun-sentinel-ingest-token via SIGNAL_INGEST_TOKEN;
// without one the correlator posts nothing, says so, and keeps freezing.

const testIngestToken = "test-ingest-token-0123456789abcdef0123456789"

func countingIngest(t *testing.T) (*httptest.Server, *atomic.Int32, *atomic.Value) {
	t.Helper()
	var hits atomic.Int32
	var auth atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		auth.Store(r.Header.Get("Authorization"))
		w.WriteHeader(http.StatusCreated)
	}))
	t.Cleanup(srv.Close)
	return srv, &hits, &auth
}

func TestNoTokenMeansNothingIsPostedNotAPublicDefault(t *testing.T) {
	srv, hits, _ := countingIngest(t)
	m := NewSentinelProbeManager(nil, srv.URL, nil)

	err := m.dispatchObservation(sampleObservation())
	if !errors.Is(err, ErrIngestTokenMissing) {
		t.Fatalf("err = %v, want ErrIngestTokenMissing", err)
	}
	if hits.Load() != 0 {
		t.Fatalf("signal-ingest received %d requests with no configured credential", hits.Load())
	}
}

func TestWhitespaceTokenIsTreatedAsMissing(t *testing.T) {
	srv, hits, _ := countingIngest(t)
	m := NewSentinelProbeManager(nil, srv.URL, nil, WithBearerToken(" \t\n "))

	if err := m.dispatchObservation(sampleObservation()); !errors.Is(err, ErrIngestTokenMissing) || hits.Load() != 0 {
		t.Fatalf("err=%v hits=%d, want ErrIngestTokenMissing and no request", err, hits.Load())
	}
	if m.IngestTokenConfigured() {
		t.Fatal("a whitespace token must not count as configured")
	}
}

func TestConfiguredTokenIsSentAsTheBearer(t *testing.T) {
	srv, hits, auth := countingIngest(t)
	m := NewSentinelProbeManager(nil, srv.URL, nil, WithBearerToken("  "+testIngestToken+"\n"))

	if err := m.dispatchObservation(sampleObservation()); err != nil {
		t.Fatal(err)
	}
	if hits.Load() != 1 || auth.Load() != "Bearer "+testIngestToken {
		t.Fatalf("hits=%d Authorization=%q, want one request bearing the trimmed token", hits.Load(), auth.Load())
	}
}

func TestMissingTokenIsCountedAndTheDetectionStillLogged(t *testing.T) {
	buf := withCapturedCorrelatorLog(t)
	srv, hits, _ := countingIngest(t)
	m := NewSentinelProbeManager(nil, srv.URL, nil)
	m.queue <- sampleObservation()
	m.queue <- sampleObservation()
	close(m.queue)
	m.wg.Add(1)
	m.dispatchWorker(context.Background())

	s := m.Stats()
	if s.IngestTokenMissing != 2 || s.DispatchOK != 0 || s.DispatchErrors != 0 || hits.Load() != 0 {
		t.Fatalf("stats=%+v hits=%d, want ingest_token_missing=2 and nothing posted", s, hits.Load())
	}
	if got := strings.Count(buf.String(), `"event":"ebpf_detection"`); got != 2 {
		t.Fatalf("%d detection lines logged, want 2: losing the credential must not lose the evidence\n%s", got, buf.String())
	}
}

func TestMissingTokenDoesNotStopTheFreeze(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	if m.IngestTokenConfigured() {
		t.Fatal("pipeline() configures no token; this test needs the missing-token state")
	}
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow"))
	if !ok || *calls != 1 || obs.DirectReaction != ReactionCgroupFrozen {
		t.Fatalf("ok=%v freezes=%d reaction=%q: containment must not depend on the ingest credential", ok, *calls, obs.DirectReaction)
	}
}

func TestTokenNeverAppearsInADispatchFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()
	m := NewSentinelProbeManager(nil, srv.URL, nil, WithBearerToken(testIngestToken))

	m.recordDispatch(m.dispatchObservation(sampleObservation()))
	if s := m.Stats(); strings.Contains(s.LastDispatchError, testIngestToken) {
		t.Fatalf("last_dispatch_error leaks the bearer: %q", s.LastDispatchError)
	}
}
