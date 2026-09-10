// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// TestUntrustedDelegationContainment verifies that unverified privileged actions trigger
// automated containment dispatch to Stun Sentinel in <100ms and record cryptographic audit evidence.
func TestUntrustedDelegationContainment(t *testing.T) {
	var stunCalled uint32
	var lastReceivedReq StunFreezeRequest

	// Mock Stun Sentinel HTTP Server
	mockSentinel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddUint32(&stunCalled, 1)
		var req StunFreezeRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		lastReceivedReq = req

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(StunFreezeResponse{
			Frozen:    true,
			PodName:   req.PodName,
			LatencyMS: 12.5,
			Polls:     1,
			PIDs:      []int{4102, 4103},
		})
	}))
	defer mockSentinel.Close()

	metrics := NewQuarantineMetrics()
	stunClient := NewHTTPStunClient(StunClientOptions{
		BaseURL:     mockSentinel.URL,
		Timeout:     50 * time.Millisecond,
		DebounceTTL: 10 * time.Millisecond,
		GraceWindow: 1 * time.Nanosecond, // disable grace window for test
		Metrics:     metrics,
	})

	memStore := store.NewMemoryStore()
	quarantineEngine := NewQuarantineEngine(QuarantineEngineOptions{
		Store:      memStore,
		StunClient: stunClient,
		Metrics:    metrics,
	})

	engine, err := NewEngine(memStore)
	if err != nil {
		t.Fatalf("NewEngine: %v", err)
	}
	engine.SetQuarantineEngine(quarantineEngine)

	ctx := context.Background()
	startTime := time.Now()

	// Ingest an observation representing a forged delegation executing a high-severity action
	forgedObs := model.Observation{
		ID:             "obs-attack-vault-001",
		Timestamp:      time.Now().UTC(),
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityCircumstantial,
		Source:         "agent-nono-evidenced",
		Confidence:     0.0,
		ActorID:        "actor-rogue-agent-99",
		ActorHint:      "spiffe://osramp.local/ns/fe-signalloom-agents/sa/rogue-agent-99",
		RawEvidenceRef: "nono://session/sess-attack-1/event/42",
		Description:    "Unauthorized secret read attempt on credential vault (/v1/secret/data/transit/keys)",
		Labels: map[string]string{
			"action":              "vault:read_secret",
			"path":                "/v1/secret/data/transit/keys",
			"privileged":          "true",
			"high_severity":       "true",
			"verification_status": "tampered",
			"signature":           "forged-signature-digest",
			"violation_type":      "forged_signature",
			"pod_name":            "pod-rogue-agent-99-7f6d",
			"namespace":           "fe-signalloom-agents",
		},
	}

	rec, err := engine.EvaluateObservationContainment(ctx, forgedObs)
	duration := time.Since(startTime)

	// Invariant: Containment evaluation and dispatch must execute in <100ms
	if duration > 100*time.Millisecond {
		t.Errorf("Containment dispatch latency exceeded 100ms threshold: %v", duration)
	}

	if err != nil {
		t.Fatalf("EvaluateObservationContainment returned error: %v", err)
	}
	if rec == nil {
		t.Fatal("Expected non-nil QuarantineRecord for forged privileged action")
	}

	if rec.ViolationReason != model.ViolationForgedClaim {
		t.Errorf("Expected violation reason %q, got %q", model.ViolationForgedClaim, rec.ViolationReason)
	}
	if !rec.StunDispatched {
		t.Error("Expected StunDispatched == true")
	}

	// Verify Stun Sentinel mock endpoint was called
	if atomic.LoadUint32(&stunCalled) != 1 {
		t.Errorf("Expected 1 Stun Sentinel freeze call, got %d", atomic.LoadUint32(&stunCalled))
	}
	if lastReceivedReq.PodName != "pod-rogue-agent-99-7f6d" {
		t.Errorf("Expected pod name %q, got %q", "pod-rogue-agent-99-7f6d", lastReceivedReq.PodName)
	}

	// Verify immutable violation record was written to the store
	storeObs, _ := memStore.QueryRange(ctx, store.Query{})
	var foundViolation bool
	for _, o := range storeObs {
		if o.ID == rec.ImmutableAuditID || strings.HasPrefix(o.ID, "quarantine-violation-") {
			foundViolation = true
			if o.Labels["violation_reason"] != string(model.ViolationForgedClaim) {
				t.Errorf("Store violation record has wrong reason: %s", o.Labels["violation_reason"])
			}
			if o.Fidelity != model.FidelityDefinitive {
				t.Errorf("Store violation record must have definitive fidelity, got %s", o.Fidelity)
			}
		}
	}
	if !foundViolation {
		t.Error("Expected immutable cryptographic violation record written to store")
	}

	// Verify Prometheus metrics counter increment
	snap, dispatches, failures, _ := metrics.Snapshot()
	pairKey := string(model.ViolationForgedClaim) + "|actor-rogue-agent-99"
	if snap[pairKey] != 1 {
		t.Errorf("Expected metric count 1 for key %q, got %d", pairKey, snap[pairKey])
	}
	if dispatches != 1 {
		t.Errorf("Expected 1 stun dispatch recorded in metrics, got %d", dispatches)
	}
	if failures != 0 {
		t.Errorf("Expected 0 stun failures, got %d", failures)
	}

	renderedMetrics := metrics.Render()
	if !strings.Contains(renderedMetrics, "signal_ingest_delegation_quarantine_total") {
		t.Errorf("Rendered metrics missing signal_ingest_delegation_quarantine_total: %s", renderedMetrics)
	}
}

// TestQuarantine_AllViolationRules exercises all quarantine rules.
func TestQuarantine_AllViolationRules(t *testing.T) {
	tests := []struct {
		name           string
		obs            model.Observation
		expectedReason model.ViolationReason
		shouldContain  bool
	}{
		{
			name: "Missing Landlock Attestation on Privileged Egress",
			obs: model.Observation{
				ID:          "obs-landlock-01",
				Timestamp:   time.Now().UTC(),
				Layer:       model.LayerEndpointHost,
				Fidelity:    model.FidelityStrong,
				Source:      "agent-nono-evidenced",
				ActorID:     "actor-unconfined-01",
				Description: "network:alter_routing rule addition without sandbox",
				Labels: map[string]string{
					"action":          "network:alter_routing",
					"landlock_status": "disabled",
					"privileged":      "true",
				},
			},
			expectedReason: model.ViolationMissingLandlockAttestation,
			shouldContain:  true,
		},
		{
			name: "Delegation Depth Exceeded (> 7)",
			obs: model.Observation{
				ID:              "obs-depth-01",
				Timestamp:       time.Now().UTC(),
				Layer:           model.LayerIdentityAuth,
				Fidelity:        model.FidelityDefinitive,
				Source:          "k8s-apiserver-audit",
				ActorID:         "actor-deep-chain-01",
				DelegationDepth: 8,
				Description:     "Execution under 8-hop cascade delegation",
				Labels: map[string]string{
					"action": "vault:read_secret",
				},
			},
			expectedReason: model.ViolationDelegationDepthExceeded,
			shouldContain:  true,
		},
		{
			name: "Missing Cosign Signature on Privileged Action",
			obs: model.Observation{
				ID:          "obs-cosign-01",
				Timestamp:   time.Now().UTC(),
				Layer:       model.LayerIdentityAuth,
				Fidelity:    model.FidelityStrong,
				Source:      "k8s-apiserver-audit",
				ActorID:     "actor-unsigned-01",
				Description: "secret:read attempted by unverified container image",
				Labels: map[string]string{
					"action":          "secret:read",
					"cosign_verified": "false",
					"privileged":      "true",
				},
			},
			expectedReason: model.ViolationMissingCosignSignature,
			shouldContain:  true,
		},
		{
			name: "Shadow Identity Privileged Execution",
			obs: model.Observation{
				ID:          "obs-shadow-01",
				Timestamp:   time.Now().UTC(),
				Layer:       model.LayerIdentityAuth,
				Fidelity:    model.FidelityCircumstantial,
				Source:      "unknown-proxy",
				ActorID:     "shadow-ghost-actor",
				ActorHint:   "shadow-ghost-actor",
				Description: "rbac:bind_cluster_admin attempted by unknown shadow identity",
				Labels: map[string]string{
					"action":     "rbac:bind_cluster_admin",
					"privileged": "true",
				},
			},
			expectedReason: model.ViolationShadowIdentity,
			shouldContain:  true,
		},
		{
			name: "Incomplete Delegation Chain on Privileged Action",
			obs: model.Observation{
				ID:          "obs-incomplete-01",
				Timestamp:   time.Now().UTC(),
				Layer:       model.LayerIdentityAuth,
				Fidelity:    model.FidelityStrong,
				Source:      "k8s-apiserver-audit",
				ActorID:     "actor-broken-chain-01",
				Description: "credentials:access attempted under broken delegation chain",
				Labels: map[string]string{
					"action":       "credentials:access",
					"chain_status": "incomplete",
					"privileged":   "true",
				},
			},
			expectedReason: model.ViolationIncompleteChain,
			shouldContain:  true,
		},
		{
			name: "Untrusted Delegation Hop Executing High Severity Action",
			obs: model.Observation{
				ID:               "obs-untrusted-01",
				Timestamp:        time.Now().UTC(),
				Layer:            model.LayerIdentityAuth,
				Fidelity:         model.FidelityCircumstantial,
				Confidence:       0.3,
				Source:           "k8s-apiserver-audit",
				ActorID:          "actor-untrusted-delegation",
				ImpersonatedUser: "admin-target-user",
				Description:      "vault:read_secret under unverified delegation",
				Labels: map[string]string{
					"action":           "vault:read_secret",
					"delegation_basis": "untrusted",
					"privileged":       "true",
				},
			},
			expectedReason: model.ViolationUntrustedDelegationAttempt,
			shouldContain:  true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			memStore := store.NewMemoryStore()
			stunMock := &mockStunClient{}
			qEngine := NewQuarantineEngine(QuarantineEngineOptions{
				Store:      memStore,
				StunClient: stunMock,
				Metrics:    NewQuarantineMetrics(),
			})

			rec, err := qEngine.EvaluateObservation(context.Background(), tc.obs)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tc.shouldContain {
				if rec == nil {
					t.Fatalf("expected quarantine record, got nil")
				}
				if rec.ViolationReason != tc.expectedReason {
					t.Errorf("expected reason %s, got %s", tc.expectedReason, rec.ViolationReason)
				}
				if !stunMock.called {
					t.Errorf("expected Stun Sentinel freeze dispatched")
				}
			} else {
				if rec != nil {
					t.Fatalf("expected nil quarantine record, got %v", rec)
				}
			}
		})
	}
}

// TestQuarantine_BaselineExemptions verifies that verified baseline demo agents NEVER trigger containment.
func TestQuarantine_BaselineExemptions(t *testing.T) {
	stunMock := &mockStunClient{}
	qEngine := NewQuarantineEngine(QuarantineEngineOptions{
		Store:      store.NewMemoryStore(),
		StunClient: stunMock,
		Metrics:    NewQuarantineMetrics(),
	})

	baselineObs := model.Observation{
		ID:          "obs-baseline-01",
		Timestamp:   time.Now().UTC(),
		Layer:       model.LayerIdentityAuth,
		Fidelity:    model.FidelityDefinitive,
		Source:      "k8s-apiserver-audit",
		ActorID:     "agent-baseline",
		ActorHint:   "spiffe://fe-signalloom/sa/agent-baseline",
		Description: "Authorized read secret by baseline agent",
		Labels: map[string]string{
			"action":    "vault:read_secret",
			"spiffe_id": "spiffe://fe-signalloom/sa/agent-baseline",
		},
	}

	rec, err := qEngine.EvaluateObservation(context.Background(), baselineObs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if rec != nil {
		t.Errorf("Baseline agent must NEVER be quarantined, got %v", rec)
	}
	if stunMock.called {
		t.Errorf("Stun Sentinel freeze must NEVER be called for baseline agent")
	}
}

// TestQuarantine_DebounceRateLimiting verifies that rapid repeated violations are debounced.
func TestQuarantine_DebounceRateLimiting(t *testing.T) {
	var callCount int32
	mockSentinel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&callCount, 1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(StunFreezeResponse{Frozen: true})
	}))
	defer mockSentinel.Close()

	metrics := NewQuarantineMetrics()
	stunClient := NewHTTPStunClient(StunClientOptions{
		BaseURL:     mockSentinel.URL,
		DebounceTTL: 1 * time.Second,
		Metrics:     metrics,
	})

	qEngine := NewQuarantineEngine(QuarantineEngineOptions{
		Store:      store.NewMemoryStore(),
		StunClient: stunClient,
		Metrics:    metrics,
	})

	// First call -> dispatches to sentinel
	_, _ = qEngine.QuarantineActor(context.Background(), "actor-flood-01", model.QuarantineRecord{
		ActorID:         "actor-flood-01",
		ViolationReason: model.ViolationForgedClaim,
		Action:          "vault:read_secret",
	})

	// Immediate second call -> debounced / throttled
	_, _ = qEngine.QuarantineActor(context.Background(), "actor-flood-01", model.QuarantineRecord{
		ActorID:         "actor-flood-01",
		ViolationReason: model.ViolationForgedClaim,
		Action:          "vault:read_secret",
	})

	if atomic.LoadInt32(&callCount) != 1 {
		t.Errorf("Expected 1 sentinel dispatch due to debouncing, got %d", atomic.LoadInt32(&callCount))
	}

	_, _, _, throttled := metrics.Snapshot()
	if throttled != 1 {
		t.Errorf("Expected 1 throttled metric increment, got %d", throttled)
	}
}

type mockStunClient struct {
	called bool
	req    StunFreezeRequest
}

func (m *mockStunClient) DispatchFreeze(ctx context.Context, req StunFreezeRequest) (*StunFreezeResponse, error) {
	m.called = true
	m.req = req
	return &StunFreezeResponse{Frozen: true, PodName: req.PodName, LatencyMS: 5.0}, nil
}

func (m *mockStunClient) IsExempt(actorID, spiffeID string) bool {
	return strings.Contains(actorID, "baseline") || strings.Contains(spiffeID, "baseline")
}

func (m *mockStunClient) IsInGracePeriod(actorID string, reg time.Time) bool {
	return false
}
