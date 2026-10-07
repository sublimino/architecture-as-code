//go:build frostdb

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

// TestPeakHeap_ObservationsAndStats_FrostDBStore verifies that a 100k-row FrostDB store executes
// /observations?limit=100 and /store/stats with bounded heap allocation (well under 512Mi).
func TestPeakHeap_ObservationsAndStats_FrostDBStore(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping 100k row heap test in short mode")
	}

	t.Setenv(store.SegmentPseudonymKeyEnv, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")

	fs, err := store.NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer fs.Close()

	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)

	// Seed 100,000 observations in batches
	const totalRows = 100000
	const batchSize = 10000
	for b := 0; b < totalRows/batchSize; b++ {
		batch := make([]model.Observation, batchSize)
		for i := 0; i < batchSize; i++ {
			idx := b*batchSize + i
			batch[i] = model.Observation{
				ID:             fmt.Sprintf("obs-fdb-heap-%06d", idx),
				Timestamp:      baseTime.Add(time.Duration(idx) * time.Millisecond),
				Layer:          model.LayerEndpointHost,
				Fidelity:       model.FidelityStrong,
				Source:         "heap-test",
				Confidence:     0.9,
				RawEvidenceRef: "ref-heap",
				Labels:         map[string]string{ObservationTenantLabel: "tenant-a"},
			}
		}
		if err := fs.Append(context.Background(), batch); err != nil {
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
	h := &Handlers{Store: fs, Audit: aw}
	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{
		PrincipalBudget: 1_000_000,
		MaxPageSize:     10_000,
	})
	if err != nil {
		t.Fatal(err)
	}
	handler := a.ActingTenantGate(router)

	// 1. Peak allocation for GET /api/v1/observations?limit=100 (min of heapTrials)
	obsAllocDelta := minAllocDelta(t, handler, "/api/v1/observations?limit=100")
	t.Logf("FrostDBStore: /observations?limit=100 over 100k rows: TotalAlloc delta = %d KiB (%.2f MiB)",
		obsAllocDelta/1024, float64(obsAllocDelta)/(1024*1024))

	if obsAllocDelta > maxPermittedHeapAllocDeltaBytes {
		t.Errorf("TotalAlloc delta %d bytes exceeded bound %d bytes (128 MiB)",
			obsAllocDelta, maxPermittedHeapAllocDeltaBytes)
	}

	// 2. Peak allocation for GET /api/v1/store/stats (min of heapTrials)
	statsAllocDelta := minAllocDelta(t, handler, "/api/v1/store/stats")
	t.Logf("FrostDBStore: /store/stats over 100k rows: TotalAlloc delta = %d KiB (%.2f MiB)",
		statsAllocDelta/1024, float64(statsAllocDelta)/(1024*1024))

	if statsAllocDelta > maxPermittedHeapAllocDeltaBytes {
		t.Errorf("TotalAlloc delta %d bytes exceeded bound %d bytes (128 MiB)",
			statsAllocDelta, maxPermittedHeapAllocDeltaBytes)
	}
}

// minAllocDelta serves req heapTrials times and returns the smallest
// TotalAlloc delta seen. TotalAlloc is process-wide, so FrostDB's background
// compaction after the 100k-row seed lands inside a single window and inflates
// it (observed: 204 MiB once, under 128 MiB on the rerun). Background work can
// only ADD to a reading, so the minimum is still an upper bound on the request's
// own allocation, and a request that is genuinely unbounded fails every trial.
const heapTrials = 3

func minAllocDelta(t *testing.T, handler http.Handler, path string) int64 {
	t.Helper()
	best := int64(-1)
	for i := 0; i < heapTrials; i++ {
		runtime.GC()
		var before runtime.MemStats
		runtime.ReadMemStats(&before)

		w := httptest.NewRecorder()
		handler.ServeHTTP(w, bearerRequest(http.MethodGet, path, tenantAToken))

		var after runtime.MemStats
		runtime.ReadMemStats(&after)

		if w.Code != http.StatusOK {
			t.Fatalf("GET %s: %d %s", path, w.Code, w.Body.String())
		}
		d := int64(after.TotalAlloc - before.TotalAlloc)
		if best < 0 || d < best {
			best = d
		}
	}
	return best
}
