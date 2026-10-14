//go:build frostdb

package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func setupTestServerWithFrostDB(t *testing.T, obs []model.Observation) (http.Handler, func()) {
	t.Helper()
	t.Setenv(store.SegmentPseudonymKeyEnv, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")

	fs, err := store.NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}

	if len(obs) > 0 {
		if err := fs.Append(context.Background(), obs); err != nil {
			_ = fs.Close()
			t.Fatalf("append to FrostDB: %v", err)
		}
	}

	e, err := correlation.NewEngine(fs)
	if err != nil {
		_ = fs.Close()
		t.Fatal(err)
	}

	delegate, _, _ := testJWTDelegate(t)
	expires := time.Now().Add(24 * time.Hour)
	anyActor := []string{"*"}
	read := []Permission{PermissionObservationRead, PermissionStream, PermissionActorList, PermissionActorRead, PermissionAnalysisRead}

	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "reader-a", Token: tenantAToken, Subject: "static-key/reader-a", TenantID: "tenant-a", Permissions: read, ActorIDs: anyActor, ExpiresAt: expires},
		{Name: "reader-b", Token: tenantBToken, Subject: "static-key/reader-b", TenantID: "tenant-b", Permissions: read, ActorIDs: anyActor, ExpiresAt: expires},
		{Name: "reader-all", Token: crossToken, Subject: "static-key/reader-all", TenantID: "tenant-a",
			Permissions: append([]Permission{PermissionCrossTenantRead}, read...), ActorIDs: anyActor, ExpiresAt: expires},
	}, delegate)
	if err != nil {
		_ = fs.Close()
		t.Fatal(err)
	}

	aw := audit.NewFakeWriter()
	h := &Handlers{Store: fs, Engine: e, Audit: aw}

	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{
		PrincipalBudget: 1_000_000,
		MaxPageSize:     10_000,
	})
	if err != nil {
		_ = fs.Close()
		t.Fatal(err)
	}

	cleanup := func() {
		_ = fs.Close()
	}
	return a.ActingTenantGate(router), cleanup
}

// 1. FrostDB Determinism: 50 identical requests return byte-identical bodies on FrostDBStore.
func TestObservationsFrostDB_Determinism50Requests(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	var fixture []model.Observation
	for i := 0; i < 100; i++ {
		tsOffset := (i * 37) % 50
		fixture = append(fixture, model.Observation{
			ID:             fmt.Sprintf("obs-fdb-%04d", i),
			Timestamp:      baseTime.Add(time.Duration(tsOffset) * time.Second),
			Layer:          model.LayerEndpointHost,
			Fidelity:       model.FidelityStrong,
			Source:         "test",
			Confidence:     0.95,
			RawEvidenceRef: "ref-det",
			Labels:         map[string]string{ObservationTenantLabel: "tenant-a"},
		})
	}

	router, cleanup := setupTestServerWithFrostDB(t, fixture)
	defer cleanup()

	var initialBody []byte
	for reqNum := 0; reqNum < 50; reqNum++ {
		req := bearerRequest(http.MethodGet, "/api/v1/observations?limit=25", tenantAToken)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("request %d: expected status 200, got %d (%s)", reqNum, w.Code, w.Body.String())
		}

		body := w.Body.Bytes()
		if reqNum == 0 {
			initialBody = append([]byte(nil), body...)
			var items []model.Observation
			if err := json.Unmarshal(body, &items); err != nil {
				t.Fatalf("unmarshal body: %v", err)
			}
			if len(items) != 25 {
				t.Fatalf("expected 25 items, got %d", len(items))
			}
		} else {
			if !bytes.Equal(initialBody, body) {
				t.Fatalf("FrostDB request %d returned non-identical body bytes to request 0", reqNum)
			}
		}
	}
}

// 2. FrostDB Cursor walk: 1,000-row fixture with duplicate timestamps visited exactly once with no gaps or repeats.
func TestObservationsFrostDB_CursorWalk1000Rows(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	var fixture []model.Observation
	expectedIDs := make(map[string]bool)

	for i := 0; i < 1000; i++ {
		id := fmt.Sprintf("obs-fdb-row-%04d", i)
		ts := baseTime.Add(time.Duration(i%50) * time.Second)
		fixture = append(fixture, model.Observation{
			ID:             id,
			Timestamp:      ts,
			Layer:          model.LayerEndpointHost,
			Fidelity:       model.FidelityStrong,
			Source:         "test",
			RawEvidenceRef: "ref",
			Labels:         map[string]string{ObservationTenantLabel: "tenant-a"},
		})
		expectedIDs[id] = true
	}

	router, cleanup := setupTestServerWithFrostDB(t, fixture)
	defer cleanup()

	pageSize := 37
	visitedIDs := make(map[string]int)
	var cursor string
	pageCount := 0

	for {
		pageCount++
		path := fmt.Sprintf("/api/v1/observations?limit=%d", pageSize)
		if cursor != "" {
			path += "&cursor=" + cursor
		}

		req := bearerRequest(http.MethodGet, path, tenantAToken)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("page %d (cursor=%s): status %d (%s)", pageCount, cursor, w.Code, w.Body.String())
		}

		var page []model.Observation
		if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil {
			t.Fatalf("page %d unmarshal: %v", pageCount, err)
		}

		for _, o := range page {
			visitedIDs[o.ID]++
			if visitedIDs[o.ID] > 1 {
				t.Fatalf("duplicate ID %q visited on FrostDB page %d", o.ID, pageCount)
			}
		}

		nextCursor := w.Header().Get("X-Next-Cursor")
		link := w.Header().Get("Link")
		truncated := w.Header().Get("X-Result-Truncated")

		if nextCursor != "" {
			if !strings.Contains(link, `rel="next"`) {
				t.Errorf("page %d: Link header %q missing rel=\"next\"", pageCount, link)
			}
			if truncated == "false" {
				t.Errorf("page %d: X-Result-Truncated must not be false when X-Next-Cursor is set", pageCount)
			}
			cursor = nextCursor
		} else {
			if truncated != "false" {
				t.Errorf("last page %d: expected X-Result-Truncated: false, got %q", pageCount, truncated)
			}
			if link != "" {
				t.Errorf("last page %d: Link header should be empty, got %q", pageCount, link)
			}
			break
		}

		if pageCount > 100 {
			t.Fatal("cursor pagination exceeded 100 iterations (infinite loop)")
		}
	}

	if len(visitedIDs) != 1000 {
		t.Fatalf("expected 1000 unique IDs visited on FrostDB, got %d", len(visitedIDs))
	}
	for id := range expectedIDs {
		if visitedIDs[id] != 1 {
			t.Errorf("id %q was visited %d times (want 1)", id, visitedIDs[id])
		}
	}
}

// 3. FrostDB Order before limit: unsorted store order differs from (timestamp DESC, id DESC), limit < total.
func TestObservationsFrostDB_OrderBeforeLimit(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		{ID: "obs-oldest", Timestamp: baseTime.Add(1 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-middle-1", Timestamp: baseTime.Add(2 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-middle-2", Timestamp: baseTime.Add(2 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-newest", Timestamp: baseTime.Add(3 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
	}

	router, cleanup := setupTestServerWithFrostDB(t, obs)
	defer cleanup()

	req := bearerRequest(http.MethodGet, "/api/v1/observations?limit=2", tenantAToken)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}

	var got []model.Observation
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("json unmarshal: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("expected 2 observations, got %d", len(got))
	}
	if got[0].ID != "obs-newest" {
		t.Errorf("got[0] = %q, want %q", got[0].ID, "obs-newest")
	}
	if got[1].ID != "obs-middle-2" {
		t.Errorf("got[1] = %q, want %q", got[1].ID, "obs-middle-2")
	}
}

// 4. FrostDB Bounded read: other tenants' rows in newest window do not starve caller's page.
func TestObservationsFrostDB_BoundedReadNoTenantStarvation(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	var obs []model.Observation

	for i := 0; i < 100; i++ {
		obs = append(obs, model.Observation{
			ID:        fmt.Sprintf("obs-b-%03d", i),
			Timestamp: baseTime.Add(time.Duration(100+i) * time.Second),
			Layer:     model.LayerEndpointHost,
			Fidelity:  model.FidelityStrong,
			Source:    "test",
			Labels:    map[string]string{ObservationTenantLabel: "tenant-b"},
		})
	}

	for i := 0; i < 10; i++ {
		obs = append(obs, model.Observation{
			ID:        fmt.Sprintf("obs-a-%03d", i),
			Timestamp: baseTime.Add(time.Duration(i) * time.Second),
			Layer:     model.LayerEndpointHost,
			Fidelity:  model.FidelityStrong,
			Source:    "test",
			Labels:    map[string]string{ObservationTenantLabel: "tenant-a"},
		})
	}

	router, cleanup := setupTestServerWithFrostDB(t, obs)
	defer cleanup()

	req := bearerRequest(http.MethodGet, "/api/v1/observations?limit=10", tenantAToken)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}

	var got []model.Observation
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(got) != 10 {
		t.Fatalf("expected 10 observations for tenant-a, got %d", len(got))
	}
	for _, o := range got {
		if o.Labels[ObservationTenantLabel] != "tenant-a" {
			t.Errorf("received non-tenant-a observation: %v", o)
		}
	}
}
