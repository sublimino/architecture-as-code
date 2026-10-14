package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TestStoreStats_GoldenEquivalence tests that handleStoreStats produces exact counts and shape
// without full decode, matching the contract across layers, fidelities, and actors.
func TestStoreStats_GoldenEquivalence(t *testing.T) {
	baseTime := time.Date(2026, 10, 6, 10, 0, 0, 0, time.UTC)
	var obs []model.Observation

	// 10 observations for tenant-a across different layers and fidelities
	layers := []model.Layer{model.LayerEndpointHost, model.LayerNetworkEgress, model.LayerCloudControlPlane}
	fidelities := []model.FidelityTier{model.FidelityStrong, model.FidelitySuggestive}

	for i := 0; i < 10; i++ {
		layer := layers[i%len(layers)]
		fidelity := fidelities[i%len(fidelities)]
		obs = append(obs, model.Observation{
			ID:        fmt.Sprintf("obs-stats-a-%02d", i),
			Timestamp: baseTime.Add(time.Duration(i*10) * time.Second),
			Layer:     layer,
			Fidelity:  fidelity,
			Source:    "test",
			Labels:    map[string]string{ObservationTenantLabel: "tenant-a"},
		})
	}

	// 5 observations for tenant-b
	for i := 0; i < 5; i++ {
		obs = append(obs, model.Observation{
			ID:        fmt.Sprintf("obs-stats-b-%02d", i),
			Timestamp: baseTime.Add(time.Duration(100+i*10) * time.Second),
			Layer:     model.LayerCloudControlPlane,
			Fidelity:  model.FidelityStrong,
			Source:    "test",
			Labels:    map[string]string{ObservationTenantLabel: "tenant-b"},
		})
	}

	delegate, _, _ := testJWTDelegate(t)
	expires := time.Now().Add(24 * time.Hour)
	anyActor := []string{"*"}
	read := []Permission{PermissionObservationRead, PermissionAnalysisRead, PermissionActorList}

	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "reader-a", Token: tenantAToken, Subject: "static-key/reader-a", TenantID: "tenant-a", Permissions: read, ActorIDs: anyActor, ExpiresAt: expires},
		{Name: "reader-all", Token: crossToken, Subject: "static-key/reader-all", TenantID: "tenant-a",
			Permissions: append([]Permission{PermissionCrossTenantRead}, read...), ActorIDs: anyActor, ExpiresAt: expires},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}

	aw := audit.NewFakeWriter()
	h, _ := newTestHandlersWithAudit(t, aw)
	if err := h.Store.Append(context.Background(), obs); err != nil {
		t.Fatal(err)
	}

	// Resolve one actor for tenant-a
	o := obs[0]
	o.ActorHint = "agent-stats-1"
	if _, err := h.Engine.Resolve(o); err != nil {
		t.Fatal(err)
	}

	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}

	// 1. Scoped read for tenant-a
	reqA := bearerRequest(http.MethodGet, "/api/v1/store/stats", tenantAToken)
	wA := httptest.NewRecorder()
	router.ServeHTTP(wA, reqA)

	if wA.Code != http.StatusOK {
		t.Fatalf("tenant-a stats: %d %s", wA.Code, wA.Body.String())
	}

	var statsA StoreStatsResponse
	if err := json.Unmarshal(wA.Body.Bytes(), &statsA); err != nil {
		t.Fatalf("unmarshal statsA: %v", err)
	}

	if statsA.TotalObservations != 10 {
		t.Errorf("statsA.TotalObservations = %d, want 10", statsA.TotalObservations)
	}
	if statsA.ActorCount != 1 {
		t.Errorf("statsA.ActorCount = %d, want 1", statsA.ActorCount)
	}
	if statsA.LastIngestion == nil || !statsA.LastIngestion.Equal(baseTime.Add(90*time.Second)) {
		t.Errorf("statsA.LastIngestion = %v, want %v", statsA.LastIngestion, baseTime.Add(90*time.Second))
	}
	// Check layer counts: 10 items modulo 3: indices 0,3,6,9 (4 host), 1,4,7 (3 egress), 2,5,8 (3 cloud)
	if statsA.ObservationsByLayer[string(model.LayerEndpointHost)] != 4 {
		t.Errorf("layer host = %d, want 4", statsA.ObservationsByLayer[string(model.LayerEndpointHost)])
	}
	if statsA.ObservationsByLayer[string(model.LayerNetworkEgress)] != 3 {
		t.Errorf("layer egress = %d, want 3", statsA.ObservationsByLayer[string(model.LayerNetworkEgress)])
	}
	if statsA.ObservationsByLayer[string(model.LayerCloudControlPlane)] != 3 {
		t.Errorf("layer cloud = %d, want 3", statsA.ObservationsByLayer[string(model.LayerCloudControlPlane)])
	}

	// 2. Cross-tenant read for all
	reqAll := bearerRequest(http.MethodGet, "/api/v1/store/stats", crossToken)
	wAll := httptest.NewRecorder()
	router.ServeHTTP(wAll, reqAll)

	if wAll.Code != http.StatusOK {
		t.Fatalf("cross-tenant stats: %d %s", wAll.Code, wAll.Body.String())
	}

	var statsAll StoreStatsResponse
	if err := json.Unmarshal(wAll.Body.Bytes(), &statsAll); err != nil {
		t.Fatalf("unmarshal statsAll: %v", err)
	}

	if statsAll.TotalObservations != 15 {
		t.Errorf("statsAll.TotalObservations = %d, want 15", statsAll.TotalObservations)
	}
	if statsAll.LastIngestion == nil || !statsAll.LastIngestion.Equal(baseTime.Add(140*time.Second)) {
		t.Errorf("statsAll.LastIngestion = %v, want %v", statsAll.LastIngestion, baseTime.Add(140*time.Second))
	}
}
