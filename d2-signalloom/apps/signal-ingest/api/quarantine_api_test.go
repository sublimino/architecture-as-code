// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"encoding/json"
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

func TestQuarantine_Authorization_HTTP403(t *testing.T) {
	ms := store.NewMemoryStore()
	eng, err := correlation.NewEngine(ms)
	if err != nil {
		t.Fatalf("NewEngine: %v", err)
	}

	fw := audit.NewFakeWriter()
	h := &Handlers{Store: ms, Engine: eng, Audit: fw}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	ctx := context.Background()
	now := time.Now().UTC()

	// 1. Ingest baseline legitimate actor observation
	validObs := model.Observation{
		ID:             "obs-valid-agent-01",
		Timestamp:      now,
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityDefinitive,
		Source:         "k8s-apiserver-audit",
		Confidence:     1.0,
		ActorID:        "actor-legit-agent",
		ActorHint:      "actor-legit-agent",
		PrincipalID:    "alice@example.com",
		ImpersonatedUser: "alice@example.com",
		RawEvidenceRef: "spiffe://osramp.local/ns/fe-signalloom-agents/sa/legit-agent",
		Description:    "Legitimate delegation execution",
		Labels: map[string]string{
			"delegator":        "alice@example.com",
			"acting_principal": "alice@example.com",
			"impersonated_user": "alice@example.com",
			"delegation_basis": "impersonation",
		},
		DelegationEdge: &model.EvidenceLink{
			ObservationID: "obs-valid-agent-01",
			Layer:         model.LayerIdentityAuth,
			Fidelity:      model.FidelityDefinitive,
			Contribution:  "acts-on-behalf-of",
			Timestamp:     now,
		},
	}
	if err := ms.Append(ctx, []model.Observation{validObs}); err != nil {
		t.Fatalf("Append validObs: %v", err)
	}

	// 2. Ingest quarantined rogue actor observation
	rogueObs := model.Observation{
		ID:             "obs-rogue-agent-01",
		Timestamp:      now,
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityCircumstantial,
		Source:         "agent-nono-evidenced",
		Confidence:     0.0,
		ActorID:        "actor-rogue-agent",
		ActorHint:      "actor-rogue-agent",
		RawEvidenceRef: "nono://session/sess-rogue/event/1",
		Description:    "vault:read_secret attempted with forged signature",
		Labels: map[string]string{
			"action":              "vault:read_secret",
			"path":                "/v1/secret/data/keys",
			"privileged":          "true",
			"verification_status": "tampered",
			"signature":           "forged-signature",
			"violation_type":      "forged_signature",
		},
	}
	if err := ms.Append(ctx, []model.Observation{rogueObs}); err != nil {
		t.Fatalf("Append rogueObs: %v", err)
	}

	// Correlate to build actors
	actors, err := eng.Correlate(ctx)
	if err != nil {
		t.Fatalf("Correlate: %v", err)
	}

	// Manually ensure quarantine state is triggered on rogue actor
	_, _ = eng.QuarantineActor(ctx, "actor-rogue-agent", model.QuarantineRecord{
		ActorID:         "actor-rogue-agent",
		ViolationReason: model.ViolationForgedClaim,
		Action:          "vault:read_secret",
		AttemptedAt:     now,
		QuarantinedAt:   now,
		StunDispatched:  true,
		StunLatencyMS:   8.4,
		EvidenceGitOID:  "nono://session/sess-rogue/event/1",
	})

	t.Run("GET /api/v1/authorization?actor_id=quarantined returns HTTP 403", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/authorization?actor_id=actor-rogue-agent", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("Expected HTTP 403 Forbidden, got %d: %s", w.Code, w.Body.String())
		}

		var resp AuthorizationChainResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("Failed to unmarshal 403 response: %v", err)
		}

		if resp.Complete {
			t.Errorf("Expected Complete == false for quarantined actor")
		}
		if resp.Decision != "denied:quarantined" {
			t.Errorf("Expected Decision == 'denied:quarantined', got %q", resp.Decision)
		}
		if resp.ViolationReason != string(model.ViolationForgedClaim) {
			t.Errorf("Expected ViolationReason == %q, got %q", model.ViolationForgedClaim, resp.ViolationReason)
		}
		if resp.QuarantineDetails == nil {
			t.Errorf("Expected non-nil QuarantineDetails in 403 response")
		}
		if !strings.Contains(resp.Error, "quarantined") {
			t.Errorf("Expected Error message mentioning quarantined, got %q", resp.Error)
		}
	})

	t.Run("GET /api/v1/actors/{id}/authorization returns HTTP 403", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/actor-rogue-agent/authorization", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("Expected HTTP 403 Forbidden, got %d: %s", w.Code, w.Body.String())
		}

		var resp AuthorizationChainResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("Failed to unmarshal 403 response: %v", err)
		}
		if resp.Decision != "denied:quarantined" {
			t.Errorf("Expected Decision == 'denied:quarantined', got %q", resp.Decision)
		}
	})

	t.Run("GET /api/v1/authorization?action=obs-rogue-agent-01 returns HTTP 403", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/authorization?action=obs-rogue-agent-01", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("Expected HTTP 403 Forbidden for quarantined action, got %d: %s", w.Code, w.Body.String())
		}
	})

	var legitActorID string
	for _, a := range actors {
		for _, e := range a.EvidenceChain {
			if e.ObservationID == "obs-valid-agent-01" {
				legitActorID = a.ID
				break
			}
		}
	}
	if legitActorID == "" && len(actors) > 0 {
		legitActorID = actors[0].ID
	}

	t.Run("GET /api/v1/authorization for legitimate actor returns HTTP 200", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/authorization?actor_id="+legitActorID, nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("Expected HTTP 200 OK for legit actor (%s), got %d: %s", legitActorID, w.Code, w.Body.String())
		}

		var resp AuthorizationChainResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("Failed to unmarshal 200 response: %v", err)
		}
		if resp.Decision == "denied:quarantined" {
			t.Errorf("Legitimate actor must NOT have quarantined decision")
		}
	})

	t.Run("Estate-wide GET /api/v1/authorization reports quarantine status accurately", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/authorization", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("Expected HTTP 200 OK for estate query, got %d: %s", w.Code, w.Body.String())
		}

		var resp AuthorizationQueryResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("Failed to unmarshal estate response: %v", err)
		}

		var foundQuarantined bool
		for _, ch := range resp.Chains {
			if ch.ActorID == "actor-rogue-agent" {
				foundQuarantined = true
				if ch.Decision != "denied:quarantined" {
					t.Errorf("Expected quarantined decision in estate chain, got %q", ch.Decision)
				}
				if ch.Complete {
					t.Errorf("Quarantined chain must not report Complete == true")
				}
			}
		}
		if !foundQuarantined {
			t.Errorf("Expected actor-rogue-agent in estate chains response")
		}
	})
}
