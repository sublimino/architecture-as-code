// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// A request path whose cost tracked the size of the store rather than the request
// (signal-ingest OOM-killed at 2 GiB on kind-osramp, 2026-10-15). The FrostDB-side bounds are in
// store/frostdb_bounded_memory_test.go; this pins the handler seam.

const streamReaderToken = "boundedMemoryStreamReaderTenantAkey00000000"

// TestStream_LastEventIDReplayCostDoesNotGrowWithTheStore: Last-Event-ID is client-supplied.
// The replay used to QueryRange everything after it and then keep 100, so an old ID read the
// whole store. Measured as rows pulled out of the store, the same quantity the bounded-read
// tests use: 5000 before, 100 after.
func TestStream_LastEventIDReplayCostDoesNotGrowWithTheStore(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "stream-reader", Token: streamReaderToken, Subject: "static-key/stream-reader",
			TenantID: "tenant-a", Permissions: []Permission{PermissionStream}, ExpiresAt: time.Now().Add(time.Hour)},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}
	aw := audit.NewFakeWriter()
	s := store.NewMemoryStore()
	e, err := correlation.NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}
	fillStore(t, s, boundedReadFillRows)
	cs := &countingStore{SignalStore: s}
	h := &Handlers{Store: cs, Engine: e, Audit: aw}
	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	srv := a.ActingTenantGate(router)

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/stream", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+streamReaderToken)
	req.Header.Set("Last-Event-ID", time.Now().Add(-24*time.Hour).UTC().Format(time.RFC3339))
	rr := httptest.NewRecorder()
	srv.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status %d body %s", rr.Code, rr.Body.String())
	}
	if got := strings.Count(rr.Body.String(), "event: observation"); got != streamReplayCap {
		t.Fatalf("replayed %d observations, want %d: the fixture no longer exercises the replay", got, streamReplayCap)
	}
	if cs.totalRows > streamReplayCap {
		t.Errorf("the replay pulled %d rows out of a %d-row store to send %d", cs.totalRows,
			boundedReadFillRows, streamReplayCap)
	}
}
