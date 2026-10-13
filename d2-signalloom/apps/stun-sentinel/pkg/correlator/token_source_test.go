// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A key that is not there at start (Secret mounted late, key file still
// absent) must not cost observations: they spool, and drain once it is.
func TestObservationsSpoolUntilTheTokenSourceProducesAKey(t *testing.T) {
	var auths []string
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		auths = append(auths, r.Header.Get("Authorization"))
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	var key atomic.Value
	key.Store("")
	clk := newMockClock(time.Now())
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
		WithBearerTokenSource(func() string { return key.Load().(string) }),
		WithSpoolDir(t.TempDir()),
		WithBatchMax(1),
		WithBatchLinger(10*time.Millisecond),
		WithClock(clk),
	)
	if m.IngestTokenConfigured() {
		t.Fatal("no key yet")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m.wg.Add(1)
	go m.sender.run(ctx)

	m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/passwd"}
	m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/shadow"}
	for i := 0; i < 200 && m.Stats().SpoolBatches < 2; i++ {
		clk.Advance(time.Second)
		time.Sleep(10 * time.Millisecond)
	}
	s := m.Stats()
	if s.SpoolBatches != 2 || s.IngestTokenMissing != 0 || s.DispatchAuthRefused != 0 {
		t.Fatalf("stats = %+v, want both batches spooled and nothing dropped or refused", s)
	}
	mu.Lock()
	if len(auths) != 0 {
		t.Fatalf("nothing may be posted without a key, got %v", auths)
	}
	mu.Unlock()

	key.Store(" " + testIngestToken + "\n")
	if !m.IngestTokenConfigured() {
		t.Fatal("key present")
	}
	for i := 0; i < 100; i++ {
		mu.Lock()
		n := len(auths)
		mu.Unlock()
		if n >= 2 && m.Stats().SpoolBatches == 0 {
			break
		}
		clk.Advance(2 * time.Second)
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	m.wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	if len(auths) != 2 || auths[0] != "Bearer "+testIngestToken {
		t.Fatalf("auths = %v", auths)
	}
	if m.Stats().SpoolReplayed != 2 {
		t.Fatalf("spool_replayed = %d", m.Stats().SpoolReplayed)
	}
}

// Without any source the legacy rule stands: no token, drop and count.
func TestNoTokenAndNoSourceStillDrops(t *testing.T) {
	clk := newMockClock(time.Now())
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), "http://127.0.0.1:1", nil,
		WithSpoolDir(t.TempDir()), WithBatchMax(1), WithClock(clk))
	ctx, cancel := context.WithCancel(context.Background())
	m.wg.Add(1)
	go m.sender.run(ctx)
	m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/passwd"}
	for i := 0; i < 100 && m.Stats().IngestTokenMissing < 1; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	m.wg.Wait()
	if s := m.Stats(); s.IngestTokenMissing != 1 || s.SpoolBatches != 0 {
		t.Fatalf("stats = %+v", s)
	}
}

func TestFixedTokenOutranksTheSource(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil, WithBearerToken("fixed"), WithBearerTokenSource(func() string { return "" }))
	if m.token() != "fixed" || !m.IngestTokenConfigured() {
		t.Fatalf("token = %q", m.token())
	}
}
