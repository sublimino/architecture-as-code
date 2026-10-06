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
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// setupTestServerWithMemoryStore creates a test router backed by MemoryStore populated with observations.
func setupTestServerWithMemoryStore(t *testing.T, obs []model.Observation) http.Handler {
	t.Helper()
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
		t.Fatal(err)
	}

	aw := audit.NewFakeWriter()
	h, _ := newTestHandlersWithAudit(t, aw)
	if len(obs) > 0 {
		if err := h.Store.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}
	}

	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{
		PrincipalBudget: 1_000_000,
		MaxPageSize:     10_000,
	})
	if err != nil {
		t.Fatal(err)
	}
	return a.ActingTenantGate(router)
}

// 1. Determinism: 50 identical GET /api/v1/observations requests return byte-identical bodies on MemoryStore.
func TestObservations_Determinism50Requests(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	var fixture []model.Observation
	// Seed with shuffled timestamps and IDs
	for i := 0; i < 100; i++ {
		// Non-monotonic timestamps with duplicate timestamps to verify tie-breaking
		tsOffset := (i * 37) % 50
		fixture = append(fixture, model.Observation{
			ID:             fmt.Sprintf("obs-%04d", i),
			Timestamp:      baseTime.Add(time.Duration(tsOffset) * time.Second),
			Layer:          model.LayerEndpointHost,
			Fidelity:       model.FidelityStrong,
			Source:         "test",
			Confidence:     0.95,
			RawEvidenceRef: "ref-det",
			Labels:         map[string]string{ObservationTenantLabel: "tenant-a"},
		})
	}

	router := setupTestServerWithMemoryStore(t, fixture)

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
			// Verify body is a valid JSON array
			var items []model.Observation
			if err := json.Unmarshal(body, &items); err != nil {
				t.Fatalf("unmarshal body: %v", err)
			}
			if len(items) != 25 {
				t.Fatalf("expected 25 items, got %d", len(items))
			}
		} else {
			if !bytes.Equal(initialBody, body) {
				t.Fatalf("request %d returned non-identical body bytes to request 0", reqNum)
			}
		}
	}
}

// 2. Order before limit: unsorted store order differs from (timestamp DESC, id DESC), limit < total.
func TestObservations_OrderBeforeLimit(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	// Append in order: oldest to newest
	obs := []model.Observation{
		{ID: "obs-oldest", Timestamp: baseTime.Add(1 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-middle-1", Timestamp: baseTime.Add(2 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-middle-2", Timestamp: baseTime.Add(2 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-newest", Timestamp: baseTime.Add(3 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
	}

	router := setupTestServerWithMemoryStore(t, obs)

	// Query with limit=2: must return obs-newest and obs-middle-2 (since "obs-middle-2" > "obs-middle-1" for equal timestamp)
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

// 3. Cursor walk: 1,000-row fixture with duplicate timestamps visited exactly once with no gaps or repeats.
func TestObservations_CursorWalk1000Rows(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	var fixture []model.Observation
	expectedIDs := make(map[string]bool)

	// 1,000 rows across 50 timestamps (20 rows per duplicate timestamp)
	for i := 0; i < 1000; i++ {
		id := fmt.Sprintf("obs-row-%04d", i)
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

	router := setupTestServerWithMemoryStore(t, fixture)

	pageSize := 37 // odd page size to stress boundaries
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
				t.Fatalf("duplicate ID %q visited on page %d", o.ID, pageCount)
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
		t.Fatalf("expected 1000 unique IDs visited, got %d", len(visitedIDs))
	}
	for id := range expectedIDs {
		if visitedIDs[id] != 1 {
			t.Errorf("id %q was visited %d times (want 1)", id, visitedIDs[id])
		}
	}
}

// 4. Headers contract: Link has rel="next" iff X-Next-Cursor is present; last page has X-Result-Truncated: false; JSON array body.
func TestObservations_HeadersContract(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		{ID: "obs-1", Timestamp: baseTime.Add(1 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-2", Timestamp: baseTime.Add(2 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
		{ID: "obs-3", Timestamp: baseTime.Add(3 * time.Second), Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}},
	}
	router := setupTestServerWithMemoryStore(t, obs)

	// Page 1: limit 2
	req1 := bearerRequest(http.MethodGet, "/api/v1/observations?limit=2", tenantAToken)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, req1)

	if w1.Code != http.StatusOK {
		t.Fatalf("p1: status %d", w1.Code)
	}
	cur1 := w1.Header().Get("X-Next-Cursor")
	if cur1 == "" {
		t.Fatal("p1: expected X-Next-Cursor header")
	}
	link1 := w1.Header().Get("Link")
	if !strings.Contains(link1, `rel="next"`) || !strings.Contains(link1, cur1) {
		t.Fatalf("p1: Link header = %q, want rel=\"next\" with cursor", link1)
	}
	if w1.Header().Get("X-Result-Truncated") != "" {
		t.Errorf("p1: X-Result-Truncated should not be set when next cursor exists")
	}

	// Verify body is bare JSON array
	var list1 []any
	if err := json.Unmarshal(w1.Body.Bytes(), &list1); err != nil {
		t.Fatalf("p1: body not JSON array: %v", err)
	}
	if len(list1) != 2 {
		t.Fatalf("p1: len = %d, want 2", len(list1))
	}

	// Page 2: with cursor
	req2 := bearerRequest(http.MethodGet, "/api/v1/observations?limit=2&cursor="+cur1, tenantAToken)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, req2)

	if w2.Code != http.StatusOK {
		t.Fatalf("p2: status %d", w2.Code)
	}
	if cur2 := w2.Header().Get("X-Next-Cursor"); cur2 != "" {
		t.Fatalf("p2: unexpected X-Next-Cursor: %q", cur2)
	}
	if link2 := w2.Header().Get("Link"); link2 != "" {
		t.Fatalf("p2: unexpected Link header: %q", link2)
	}
	if trunc := w2.Header().Get("X-Result-Truncated"); trunc != "false" {
		t.Fatalf("p2: X-Result-Truncated = %q, want \"false\"", trunc)
	}

	var list2 []any
	if err := json.Unmarshal(w2.Body.Bytes(), &list2); err != nil {
		t.Fatalf("p2: body not JSON array: %v", err)
	}
	if len(list2) != 1 {
		t.Fatalf("p2: len = %d, want 1", len(list2))
	}
}

// 5. Malformed cursor: garbage, truncated base64, foreign scope, unknown version, bad time -> 400 with exact error message.
func TestObservations_MalformedCursorReturns400(t *testing.T) {
	router := setupTestServerWithMemoryStore(t, nil)

	testCases := []struct {
		name   string
		cursor string
	}{
		{"garbage characters", "not-a-valid-cursor-at-all!!"},
		{"truncated base64", "eyJ2IjoxLCJ0Ijo"},
		{"empty json object", "e30="},
		{"unknown version", EncodeCursor(time.Now(), "obs-1", ComputeScopeDigest("tenant-a", false))}, // will be modified below
		{"bad time format", "eyJ2IjoxLCJ0Ijoibm90LWEtdGltZSIsImlkIjoib2JzLTEiLCJzY29wZSI6ImFiYyJ9"},
		{"empty id", "eyJ2IjoxLCJ0IjoiMjAyNi0xMC0wNlQxMjowMDowMFoiLCJpZCI6IiIsInNjb3BlIjoiYWJjIn0="},
	}

	// Craft specific payloads
	// 1. Unknown version (v=2)
	v2Payload, _ := json.Marshal(map[string]any{"v": 2, "t": time.Now().Format(time.RFC3339Nano), "id": "obs-1", "scope": ComputeScopeDigest("tenant-a", false)})
	testCases[3].cursor = strings.TrimRight(strings.ReplaceAll(string(v2Payload), "=", ""), " ")

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			req := bearerRequest(http.MethodGet, "/api/v1/observations?cursor="+tc.cursor, tenantAToken)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)

			if w.Code != http.StatusBadRequest {
				t.Fatalf("%s: expected status 400, got %d (%s)", tc.name, w.Code, w.Body.String())
			}

			var errResp struct {
				Error string `json:"error"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &errResp); err != nil {
				t.Fatalf("unmarshal error response: %v", err)
			}
			if errResp.Error != ErrInvalidCursorMsg {
				t.Errorf("error message = %q, want %q", errResp.Error, ErrInvalidCursorMsg)
			}
		})
	}
}

// 6. Cross-tenant cursor rejected: a cursor minted for tenant-a is rejected when presented by tenant-b.
func TestObservations_CrossTenantCursorRejected(t *testing.T) {
	router := setupTestServerWithMemoryStore(t, nil)

	// Mint cursor for tenant-a
	scopeA := ComputeScopeDigest("tenant-a", false)
	cursorA := EncodeCursor(time.Now(), "obs-1", scopeA)

	// Present by tenant-b
	req := bearerRequest(http.MethodGet, "/api/v1/observations?cursor="+cursorA, tenantBToken)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for cross-tenant cursor, got %d (%s)", w.Code, w.Body.String())
	}

	var errResp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("unmarshal error response: %v", err)
	}
	if errResp.Error != ErrInvalidCursorMsg {
		t.Errorf("error message = %q, want %q", errResp.Error, ErrInvalidCursorMsg)
	}
}

// 7. Bounded read: other tenants' rows in newest window do not starve caller's page.
func TestObservations_BoundedReadNoTenantStarvation(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	var obs []model.Observation

	// 100 newer rows for tenant-b
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

	// 10 older rows for tenant-a
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

	router := setupTestServerWithMemoryStore(t, obs)

	// Tenant-a requests limit=10: must receive all 10 tenant-a rows, not starved by the 100 tenant-b rows
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
