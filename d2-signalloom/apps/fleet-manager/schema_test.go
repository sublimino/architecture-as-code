package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// Compile-time backward compatibility assertions proving existing callers of
// CascadeResult and StateChangeEvent still compile without changes.
var (
	_ = StateChangeEvent{
		AgentID:   "agent-cardvault",
		FromState: StateRunning,
		ToState:   StateStunned,
		Timestamp: "2026-09-15T01:00:00Z",
	}

	_ = CascadeResult{
		TargetAgent:    "agent-cardvault",
		AffectedAgents: []string{"agent-cardvault", "agent-txn-pipeline"},
		Events: []StateChangeEvent{
			{
				AgentID:   "agent-cardvault",
				FromState: StateRunning,
				ToState:   StateStunned,
				Timestamp: "2026-09-15T01:00:00Z",
				Success:   true,
			},
		},
		DurationMs:    12,
		RecoveryOrder: []string{"agent-cardvault", "agent-txn-pipeline"},
	}
)

func TestSchemaVersionConstants(t *testing.T) {
	if CurrentSchemaVersion != "sler.signalloom.io/v1alpha1" {
		t.Fatalf("unexpected CurrentSchemaVersion: %q", CurrentSchemaVersion)
	}
	if SchemaVersionV1Alpha1 != "sler.signalloom.io/v1alpha1" {
		t.Fatalf("unexpected SchemaVersionV1Alpha1: %q", SchemaVersionV1Alpha1)
	}
}

func TestPlaneOutcome_StringConstantsAndValidation(t *testing.T) {
	cases := []struct {
		outcome  PlaneOutcome
		expected string
		valid    bool
	}{
		{OutcomeContained, "contained", true},
		{OutcomePartial, "partial", true},
		{OutcomeUnavailable, "unavailable", true},
		{PlaneOutcome("unknown"), "unknown", false},
		{PlaneOutcome(""), "", false},
		{PlaneOutcome("1"), "1", false},
	}

	for _, c := range cases {
		if string(c.outcome) != c.expected {
			t.Errorf("outcome string mismatch: got %q, want %q", c.outcome, c.expected)
		}
		if c.outcome.IsValid() != c.valid {
			t.Errorf("outcome %q IsValid() = %v, want %v", c.outcome, c.outcome.IsValid(), c.valid)
		}
	}
}

func TestEnforcementPlane_StringConstantsAndValidation(t *testing.T) {
	cases := []struct {
		plane    EnforcementPlane
		expected string
		valid    bool
	}{
		{PlaneMesh, "mesh", true},
		{PlaneBao, "bao", true},
		{PlaneSpire, "spire", true},
		{PlaneAdmission, "admission", true},
		{PlaneFreeze, "freeze", true},
		{EnforcementPlane("unknown"), "unknown", false},
		{EnforcementPlane(""), "", false},
	}

	for _, c := range cases {
		if string(c.plane) != c.expected {
			t.Errorf("plane string mismatch: got %q, want %q", c.plane, c.expected)
		}
		if c.plane.IsValid() != c.valid {
			t.Errorf("plane %q IsValid() = %v, want %v", c.plane, c.plane.IsValid(), c.valid)
		}
	}

	planes := AllEnforcementPlanes()
	if len(planes) != 5 {
		t.Fatalf("expected 5 enforcement planes, got %d", len(planes))
	}
}

func TestPartialContainment_SurvivesJSONRoundTripWithoutCoercion(t *testing.T) {
	// A multi-plane containment where Mesh and Freeze succeeded, OpenBao failed,
	// SPIRE was partial, and Admission succeeded.
	decision := ContainmentDecision{
		DecisionID:     "dec-test-partial-001",
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "idem-key-9988-aabb",
		Target: TargetRef{
			AgentID:   "agent-cardvault",
			Namespace: "fe-signalloom-agents",
			PodName:   "agent-cardvault-7d8b89c4-x9q2p",
			SPIFFEID:  "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault",
			NodeName:  "kind-worker",
		},
		Reason: ContainmentReason{
			Code:                  "UNAUTHORIZED_DELEGATION",
			Description:           "Agent attempted unverified delegation edge traversal to payment service",
			TriggeredBy:           "signal-fusion-engine",
			DelegationEdgeRevoked: true,
			AttestationDigest:     "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		},
		RequestedPlanes: []EnforcementPlane{
			PlaneMesh,
			PlaneBao,
			PlaneSpire,
			PlaneAdmission,
			PlaneFreeze,
		},
		PlaneResults: []PlaneResult{
			{
				Plane:     PlaneMesh,
				Outcome:   OutcomeContained,
				LatencyMs: 8,
				Timestamp: "2026-09-15T01:00:00Z",
				Details: map[string]any{
					"connections_cut": float64(4),
					"policy":          "deny-all-ingress-egress",
				},
			},
			{
				Plane:     PlaneBao,
				Outcome:   OutcomeUnavailable,
				Error:     "connection refused to openbao.inf-bao.svc.cluster.local:8200",
				LatencyMs: 1500,
				Timestamp: "2026-09-15T01:00:01Z",
			},
			{
				Plane:     PlaneSpire,
				Outcome:   OutcomePartial,
				Error:     "spire-server entry deleted, but SVID cache invalidation returned partial ack",
				LatencyMs: 45,
				Timestamp: "2026-09-15T01:00:01Z",
			},
			{
				Plane:     PlaneAdmission,
				Outcome:   OutcomeContained,
				LatencyMs: 12,
				Timestamp: "2026-09-15T01:00:01Z",
				Details: map[string]any{
					"webhook_rule_id": "ncg-block-agent-cardvault",
				},
			},
			{
				Plane:     PlaneFreeze,
				Outcome:   OutcomeContained,
				LatencyMs: 4,
				Timestamp: "2026-09-15T01:00:01Z",
				Details: map[string]any{
					"cgroup_path":      "/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/agent-cardvault",
					"processes_frozen": float64(3),
				},
			},
		},
		OverallOutcome: OutcomePartial,
		DurationMs:     1569,
		Timestamp:      "2026-09-15T01:00:01Z",
	}

	data, err := json.MarshalIndent(decision, "", "  ")
	if err != nil {
		t.Fatalf("json.Marshal failed: %v", err)
	}

	jsonStr := string(data)

	// Verify key fields in JSON text
	if !strings.Contains(jsonStr, `"overall_outcome": "partial"`) {
		t.Fatalf("expected JSON to contain overall_outcome: partial, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"outcome": "unavailable"`) {
		t.Fatalf("expected JSON to contain outcome: unavailable for Bao plane, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"outcome": "partial"`) {
		t.Fatalf("expected JSON to contain outcome: partial for Spire plane, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"outcome": "contained"`) {
		t.Fatalf("expected JSON to contain outcome: contained for Mesh/Freeze/Admission, got:\n%s", jsonStr)
	}

	// Unmarshal back
	var decoded ContainmentDecision
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("json.Unmarshal failed: %v", err)
	}

	if decoded.OverallOutcome != OutcomePartial {
		t.Fatalf("expected OverallOutcome %q, got %q", OutcomePartial, decoded.OverallOutcome)
	}
	if len(decoded.PlaneResults) != 5 {
		t.Fatalf("expected 5 PlaneResults, got %d", len(decoded.PlaneResults))
	}

	// Assert Bao plane result survived verbatim
	baoResult := decoded.PlaneResults[1]
	if baoResult.Plane != PlaneBao {
		t.Fatalf("expected PlaneResults[1] to be Bao, got %q", baoResult.Plane)
	}
	if baoResult.Outcome != OutcomeUnavailable {
		t.Fatalf("expected Bao outcome %q, got %q", OutcomeUnavailable, baoResult.Outcome)
	}
	if baoResult.Error != "connection refused to openbao.inf-bao.svc.cluster.local:8200" {
		t.Fatalf("unexpected Bao error: %q", baoResult.Error)
	}

	// Validate decision invariants
	if err := decoded.ValidateDecision(); err != nil {
		t.Fatalf("ValidateDecision failed: %v", err)
	}
}

func TestAggregateOutcome(t *testing.T) {
	cases := []struct {
		name     string
		results  []PlaneResult
		expected PlaneOutcome
	}{
		{
			name:     "empty returns unavailable",
			results:  []PlaneResult{},
			expected: OutcomeUnavailable,
		},
		{
			name: "all contained returns contained",
			results: []PlaneResult{
				{Plane: PlaneMesh, Outcome: OutcomeContained},
				{Plane: PlaneBao, Outcome: OutcomeContained},
				{Plane: PlaneSpire, Outcome: OutcomeContained},
				{Plane: PlaneAdmission, Outcome: OutcomeContained},
				{Plane: PlaneFreeze, Outcome: OutcomeContained},
			},
			expected: OutcomeContained,
		},
		{
			name: "all unavailable returns unavailable",
			results: []PlaneResult{
				{Plane: PlaneMesh, Outcome: OutcomeUnavailable},
				{Plane: PlaneBao, Outcome: OutcomeUnavailable},
			},
			expected: OutcomeUnavailable,
		},
		{
			name: "mixed contained and unavailable returns partial",
			results: []PlaneResult{
				{Plane: PlaneMesh, Outcome: OutcomeContained},
				{Plane: PlaneBao, Outcome: OutcomeUnavailable},
			},
			expected: OutcomePartial,
		},
		{
			name: "mixed contained and partial returns partial",
			results: []PlaneResult{
				{Plane: PlaneMesh, Outcome: OutcomeContained},
				{Plane: PlaneSpire, Outcome: OutcomePartial},
			},
			expected: OutcomePartial,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := AggregateOutcome(c.results)
			if got != c.expected {
				t.Fatalf("AggregateOutcome() = %q, want %q", got, c.expected)
			}
		})
	}
}

func TestStateChangeEvent_SuccessAndErrorRoundTrip(t *testing.T) {
	failedEvent := StateChangeEvent{
		AgentID:   "agent-cardvault",
		FromState: StateRunning,
		ToState:   StateRunning, // couldn't transition
		Timestamp: "2026-09-15T01:00:00Z",
		Success:   false,
		Error:     "failed to set pod state label: admission webhook denied update",
	}

	data, err := json.Marshal(failedEvent)
	if err != nil {
		t.Fatalf("failed to marshal StateChangeEvent: %v", err)
	}

	var decoded StateChangeEvent
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("failed to unmarshal StateChangeEvent: %v", err)
	}

	if decoded.Success != false {
		t.Fatalf("expected Success = false, got %v", decoded.Success)
	}
	if decoded.Error != "failed to set pod state label: admission webhook denied update" {
		t.Fatalf("unexpected Error: %q", decoded.Error)
	}
}

func TestCascadeResult_PlanesAndOverallOutcome(t *testing.T) {
	cr := CascadeResult{
		SchemaVersion:  CurrentSchemaVersion,
		TargetAgent:    "agent-cardvault",
		AffectedAgents: []string{"agent-cardvault"},
		Events: []StateChangeEvent{
			{
				AgentID:   "agent-cardvault",
				FromState: StateRunning,
				ToState:   StateStunned,
				Timestamp: "2026-09-15T01:00:00Z",
				Success:   true,
			},
		},
		Planes: []PlaneResult{
			{
				Plane:     PlaneFreeze,
				Outcome:   OutcomeContained,
				LatencyMs: 3,
				Timestamp: "2026-09-15T01:00:00Z",
			},
			{
				Plane:     PlaneBao,
				Outcome:   OutcomeUnavailable,
				Error:     "OpenBao timeout",
				LatencyMs: 500,
				Timestamp: "2026-09-15T01:00:00Z",
			},
		},
		DurationMs:     503,
		RecoveryOrder:  []string{"agent-cardvault"},
		OverallOutcome: OutcomePartial,
	}

	data, err := json.Marshal(cr)
	if err != nil {
		t.Fatalf("failed to marshal CascadeResult: %v", err)
	}

	var decoded CascadeResult
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("failed to unmarshal CascadeResult: %v", err)
	}

	if decoded.OverallOutcome != OutcomePartial {
		t.Fatalf("expected OverallOutcome %q, got %q", OutcomePartial, decoded.OverallOutcome)
	}
	if len(decoded.Planes) != 2 {
		t.Fatalf("expected 2 planes, got %d", len(decoded.Planes))
	}
	if decoded.Planes[1].Outcome != OutcomeUnavailable {
		t.Fatalf("expected second plane OutcomeUnavailable, got %q", decoded.Planes[1].Outcome)
	}
}

func TestPlaneWireModels_RoundTrip(t *testing.T) {
	t.Run("MeshIsolation", func(t *testing.T) {
		req := MeshIsolationRequest{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: "idem-mesh-001",
			AgentID:        "agent-llm",
			Namespace:      "fe-signalloom-agents",
			PodName:        "agent-llm-123",
			SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-llm",
			TargetIPs:      []string{"10.244.0.15"},
			Reason:         "Unauthorized egress detected",
			Timestamp:      "2026-09-15T01:00:00Z",
		}
		data, err := json.Marshal(req)
		if err != nil {
			t.Fatalf("marshal req: %v", err)
		}
		var decodedReq MeshIsolationRequest
		if err := json.Unmarshal(data, &decodedReq); err != nil {
			t.Fatalf("unmarshal req: %v", err)
		}
		if decodedReq.IdempotencyKey != "idem-mesh-001" {
			t.Fatalf("unexpected idempotency key: %q", decodedReq.IdempotencyKey)
		}

		resp := MeshIsolationResponse{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: "idem-mesh-001",
			AgentID:        "agent-llm",
			Plane:          PlaneMesh,
			Outcome:        OutcomeContained,
			PolicyApplied:  true,
			ConnectionsCut: 2,
			LatencyMs:      15,
			Timestamp:      "2026-09-15T01:00:00Z",
		}
		dataResp, err := json.Marshal(resp)
		if err != nil {
			t.Fatalf("marshal resp: %v", err)
		}
		var decodedResp MeshIsolationResponse
		if err := json.Unmarshal(dataResp, &decodedResp); err != nil {
			t.Fatalf("unmarshal resp: %v", err)
		}
		if decodedResp.ConnectionsCut != 2 || decodedResp.Outcome != OutcomeContained {
			t.Fatalf("unexpected resp content: %+v", decodedResp)
		}
	})

	t.Run("BaoRevoke", func(t *testing.T) {
		req := BaoRevokeRequest{
			SchemaVersion:   CurrentSchemaVersion,
			IdempotencyKey:  "idem-bao-001",
			AgentID:         "agent-cardvault",
			Namespace:       "fe-signalloom-agents",
			LeaseIDs:        []string{"database/creds/readonly/sler-1234"},
			TokenAccessor:   "accessor-abcdef123456",
			RevokeAllTokens: true,
			Reason:          "Cascade stun trigger",
			Timestamp:       "2026-09-15T01:00:00Z",
		}
		data, err := json.Marshal(req)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		var decodedReq BaoRevokeRequest
		if err := json.Unmarshal(data, &decodedReq); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if len(decodedReq.LeaseIDs) != 1 || !decodedReq.RevokeAllTokens {
			t.Fatalf("unexpected decoded: %+v", decodedReq)
		}

		resp := BaoRevokeResponse{
			SchemaVersion:     CurrentSchemaVersion,
			IdempotencyKey:    "idem-bao-001",
			AgentID:           "agent-cardvault",
			Plane:             PlaneBao,
			Outcome:           OutcomeContained,
			RevokedLeases:     1,
			TokensInvalidated: 3,
			LatencyMs:         42,
			Timestamp:         "2026-09-15T01:00:00Z",
		}
		dataResp, _ := json.Marshal(resp)
		var decodedResp BaoRevokeResponse
		json.Unmarshal(dataResp, &decodedResp)
		if decodedResp.TokensInvalidated != 3 {
			t.Fatalf("unexpected tokens invalidated: %d", decodedResp.TokensInvalidated)
		}
	})

	t.Run("SpireEviction", func(t *testing.T) {
		req := SpireEvictionRequest{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: "idem-spire-001",
			AgentID:        "agent-cardvault",
			SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault",
			EntryIDs:       []string{"entry-001", "entry-002"},
			Reason:         "Attested containment order",
			Timestamp:      "2026-09-15T01:00:00Z",
		}
		data, _ := json.Marshal(req)
		var decodedReq SpireEvictionRequest
		json.Unmarshal(data, &decodedReq)
		if len(decodedReq.EntryIDs) != 2 {
			t.Fatalf("unexpected entry IDs: %v", decodedReq.EntryIDs)
		}

		resp := SpireEvictionResponse{
			SchemaVersion:    CurrentSchemaVersion,
			IdempotencyKey:   "idem-spire-001",
			AgentID:          "agent-cardvault",
			Plane:            PlaneSpire,
			Outcome:          OutcomeContained,
			EntriesEvicted:   2,
			SVIDsInvalidated: 2,
			LatencyMs:        18,
			Timestamp:        "2026-09-15T01:00:00Z",
		}
		dataResp, _ := json.Marshal(resp)
		var decodedResp SpireEvictionResponse
		json.Unmarshal(dataResp, &decodedResp)
		if decodedResp.EntriesEvicted != 2 {
			t.Fatalf("unexpected entries evicted: %d", decodedResp.EntriesEvicted)
		}
	})

	t.Run("AdmissionBlock", func(t *testing.T) {
		req := AdmissionBlockRequest{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: "idem-adm-001",
			AgentID:        "agent-cardvault",
			Namespace:      "fe-signalloom-agents",
			SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault",
			MatchLabels: map[string]string{
				"app.kubernetes.io/name": "agent-cardvault",
			},
			TTLSeconds: 3600,
			Reason:     "Quarantine active",
			Timestamp:  "2026-09-15T01:00:00Z",
		}
		data, _ := json.Marshal(req)
		var decodedReq AdmissionBlockRequest
		json.Unmarshal(data, &decodedReq)
		if decodedReq.TTLSeconds != 3600 {
			t.Fatalf("unexpected TTL: %d", decodedReq.TTLSeconds)
		}

		resp := AdmissionBlockResponse{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: "idem-adm-001",
			AgentID:        "agent-cardvault",
			Plane:          PlaneAdmission,
			Outcome:        OutcomeContained,
			RuleID:         "ncg-rule-9988",
			BlockEnforced:  true,
			LatencyMs:      9,
			Timestamp:      "2026-09-15T01:00:00Z",
		}
		dataResp, _ := json.Marshal(resp)
		var decodedResp AdmissionBlockResponse
		json.Unmarshal(dataResp, &decodedResp)
		if !decodedResp.BlockEnforced {
			t.Fatalf("expected block enforced")
		}
	})

	t.Run("Freeze", func(t *testing.T) {
		req := FreezeRequest{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: "idem-frz-001",
			AgentID:        "agent-cardvault",
			Namespace:      "fe-signalloom-agents",
			PodName:        "agent-cardvault-pod-1",
			ContainerID:    "containerd://1234567890abcdef",
			CgroupPath:     "/sys/fs/cgroup/kubepods.slice/agent-cardvault",
			FreezeMethod:   "cgroup.freeze",
			Reason:         "Host-level memory preservation",
			Timestamp:      "2026-09-15T01:00:00Z",
		}
		data, _ := json.Marshal(req)
		var decodedReq FreezeRequest
		json.Unmarshal(data, &decodedReq)
		if decodedReq.FreezeMethod != "cgroup.freeze" {
			t.Fatalf("unexpected freeze method: %s", decodedReq.FreezeMethod)
		}

		resp := FreezeResponse{
			SchemaVersion:   CurrentSchemaVersion,
			IdempotencyKey:  "idem-frz-001",
			AgentID:         "agent-cardvault",
			Plane:           PlaneFreeze,
			Outcome:         OutcomeContained,
			ProcessesFrozen: 4,
			CgroupState:     "FROZEN",
			MemoryPreserved: true,
			LatencyMs:       5,
			Timestamp:       "2026-09-15T01:00:00Z",
		}
		dataResp, _ := json.Marshal(resp)
		var decodedResp FreezeResponse
		json.Unmarshal(dataResp, &decodedResp)
		if decodedResp.ProcessesFrozen != 4 || !decodedResp.MemoryPreserved {
			t.Fatalf("unexpected freeze response: %+v", decodedResp)
		}
	})

	t.Run("Resume", func(t *testing.T) {
		req := ResumeRequest{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: "idem-res-001",
			AgentID:        "agent-cardvault",
			Namespace:      "fe-signalloom-agents",
			Token: ResumeToken{
				TokenID:               "tok-res-7788",
				AgentID:               "agent-cardvault",
				OperatorID:            "secops-lead@company.internal",
				GovernanceApprovalRef: "gov-rec-20260915-01",
				IssuedAt:              "2026-09-15T01:05:00Z",
				ExpiresAt:             "2026-09-15T01:15:00Z",
				Signature:             "sig-ecdsa-p256-verified",
			},
			Timestamp: "2026-09-15T01:06:00Z",
		}
		data, _ := json.Marshal(req)
		var decodedReq ResumeRequest
		json.Unmarshal(data, &decodedReq)
		if decodedReq.Token.OperatorID != "secops-lead@company.internal" {
			t.Fatalf("unexpected operator ID: %s", decodedReq.Token.OperatorID)
		}

		resp := ResumeResponse{
			SchemaVersion:      CurrentSchemaVersion,
			IdempotencyKey:     "idem-res-001",
			AgentID:            "agent-cardvault",
			Success:            true,
			ProcessesResumed:   4,
			CredentialsRotated: true,
			LatencyMs:          35,
			Timestamp:          "2026-09-15T01:06:01Z",
		}
		dataResp, _ := json.Marshal(resp)
		var decodedResp ResumeResponse
		json.Unmarshal(dataResp, &decodedResp)
		if !decodedResp.CredentialsRotated || !decodedResp.Success {
			t.Fatalf("unexpected resume response: %+v", decodedResp)
		}
	})
}
