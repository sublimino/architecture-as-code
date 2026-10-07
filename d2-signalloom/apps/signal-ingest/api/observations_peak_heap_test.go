package api

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"runtime"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// PeakHeap bound for 100k-row fixture: 128 MiB ceiling (target < 512 MiB working set).
const maxPermittedHeapAllocDeltaBytes = 128 * 1024 * 1024 // 128 MiB

// TestPeakHeap_ObservationsAndStats_MemoryStore verifies that a 100k-row store can execute
// /observations?limit=100 and /store/stats with bounded heap allocation (well under 512Mi).
func TestPeakHeap_ObservationsAndStats_MemoryStore(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping 100k row heap test in short mode")
	}

	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	memStore := store.NewMemoryStore()

	// Seed 100,000 observations in batches
	const totalRows = 100000
	const batchSize = 10000
	for b := 0; b < totalRows/batchSize; b++ {
		batch := make([]model.Observation, batchSize)
		for i := 0; i < batchSize; i++ {
			idx := b*batchSize + i
			batch[i] = model.Observation{
				ID:             fmt.Sprintf("obs-heap-%06d", idx),
				Timestamp:      baseTime.Add(time.Duration(idx) * time.Millisecond),
				Layer:          model.LayerEndpointHost,
				Fidelity:       model.FidelityStrong,
				Source:         "heap-test",
				Confidence:     0.9,
				RawEvidenceRef: "ref-heap",
				Labels:         map[string]string{ObservationTenantLabel: "tenant-a"},
			}
		}
		if err := memStore.Append(context.Background(), batch); err != nil {
			t.Fatalf("append batch %d: %v", b, err)
		}
	}

	delegate, _, _ := testJWTDelegate(t)
	expires := time.Now().Add(24 * time.Hour)
	anyActor := []string{"*"}
	read := []Permission{PermissionObservationRead, PermissionAnalysisRead, PermissionActorList}

	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "reader-a", Token: tenantAToken, Subject: "static-key/reader-a", TenantID: "tenant-a", Permissions: read, ActorIDs: anyActor, ExpiresAt: expires},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}

	aw := audit.NewFakeWriter()
	h := &Handlers{Store: memStore, Audit: aw}
	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{
		PrincipalBudget: 1_000_000,
		MaxPageSize:     10_000,
	})
	if err != nil {
		t.Fatal(err)
	}
	handler := a.ActingTenantGate(router)

	// 1. Measure Peak Heap for GET /api/v1/observations?limit=100
	runtime.GC()
	var mBeforeObs runtime.MemStats
	runtime.ReadMemStats(&mBeforeObs)

	reqObs := bearerRequest(http.MethodGet, "/api/v1/observations?limit=100", tenantAToken)
	wObs := httptest.NewRecorder()
	handler.ServeHTTP(wObs, reqObs)

	var mAfterObs runtime.MemStats
	runtime.ReadMemStats(&mAfterObs)

	if wObs.Code != http.StatusOK {
		t.Fatalf("GET /observations: %d %s", wObs.Code, wObs.Body.String())
	}

	obsAllocDelta := int64(mAfterObs.TotalAlloc - mBeforeObs.TotalAlloc)
	t.Logf("MemoryStore: /observations?limit=100 over 100k rows: TotalAlloc delta = %d KiB (%.2f MiB)",
		obsAllocDelta/1024, float64(obsAllocDelta)/(1024*1024))

	if obsAllocDelta > maxPermittedHeapAllocDeltaBytes {
		t.Errorf("TotalAlloc delta %d bytes exceeded bound %d bytes (64 MiB)",
			obsAllocDelta, maxPermittedHeapAllocDeltaBytes)
	}

	// 2. Measure Peak Heap for GET /api/v1/store/stats
	runtime.GC()
	var mBeforeStats runtime.MemStats
	runtime.ReadMemStats(&mBeforeStats)

	reqStats := bearerRequest(http.MethodGet, "/api/v1/store/stats", tenantAToken)
	wStats := httptest.NewRecorder()
	handler.ServeHTTP(wStats, reqStats)

	var mAfterStats runtime.MemStats
	runtime.ReadMemStats(&mAfterStats)

	if wStats.Code != http.StatusOK {
		t.Fatalf("GET /store/stats: %d %s", wStats.Code, wStats.Body.String())
	}

	statsAllocDelta := int64(mAfterStats.TotalAlloc - mBeforeStats.TotalAlloc)
	t.Logf("MemoryStore: /store/stats over 100k rows: TotalAlloc delta = %d KiB (%.2f MiB)",
		statsAllocDelta/1024, float64(statsAllocDelta)/(1024*1024))

	if statsAllocDelta > maxPermittedHeapAllocDeltaBytes {
		t.Errorf("TotalAlloc delta %d bytes exceeded bound %d bytes (64 MiB)",
			statsAllocDelta, maxPermittedHeapAllocDeltaBytes)
	}
}
