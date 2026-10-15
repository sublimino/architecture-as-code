//go:build slco_privacy_probe

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// TestSLCOStoredObservationPrivacy is an opt-in certification probe, not a
// known-bad-behaviour acceptance test. A failure is the SLCO-P2-3 mandatory stop.
// It uses synthetic identities, the real protected HTTP router, and a queried
// store rather than a mock Append expectation. It makes no live-lane claim.
func TestSLCOStoredObservationPrivacy(t *testing.T) {
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_KEY", strings.Repeat("42", 32))
	router, handlers := writeRouter(t)
	observation := model.Observation{
		ID:        "slco-p2-3-synthetic-privacy-probe",
		Timestamp: time.Now().UTC(), Layer: model.LayerEndpointHost,
		Fidelity: model.FidelityStrong, Source: "slco-offline-probe",
		Confidence: 0.9, RawEvidenceRef: "synthetic-evidence",
		ActorHint: "SLCO Synthetic Person", PrincipalID: "slco-synthetic@example.invalid",
		ImpersonatedUser: "slco-user@example.invalid",
	}
	body, err := json.Marshal([]model.Observation{observation})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/v1/observations", strings.NewReader(string(body)))
	request.Header.Set("Authorization", "Bearer "+writerAToken)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusCreated {
		t.Fatalf("probe did not reach storage: HTTP %d %s", response.Code, response.Body.String())
	}
	rows, err := handlers.Store.QueryRange(context.Background(), store.Query{TenantID: "tenant-a"})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != observation.ID {
		t.Fatalf("expected exactly the probe observation, got %d rows", len(rows))
	}
	stored, err := json.Marshal(rows[0])
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("HTTP=%d Content-Type=%q ingested=%s tenant=%q store=%T", response.Code,
		response.Header().Get("Content-Type"), strings.TrimSpace(response.Body.String()),
		rows[0].Labels[ObservationTenantLabel], handlers.Store)
	for _, field := range []struct{ name, raw string }{
		{"actor_hint", observation.ActorHint},
		{"principal_id", observation.PrincipalID},
		{"impersonated_user", observation.ImpersonatedUser},
	} {
		if strings.Contains(string(stored), field.raw) {
			t.Errorf("HARD BLOCKER: stored observation retains synthetic cleartext %s", field.name)
		}
	}
}
