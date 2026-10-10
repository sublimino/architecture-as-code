package compliance

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFleetScan_StandardFleet(t *testing.T) {
	req := &FleetScanRequest{}
	resp := ScanFleet(req)

	if resp.Compliant {
		t.Fatalf("expected fleet to be non-compliant, got compliant=true")
	}

	if resp.Summary.TotalAgents != 5 {
		t.Fatalf("expected 5 agents, got %d", resp.Summary.TotalAgents)
	}
	if resp.Summary.CompliantAgents != 3 {
		t.Fatalf("expected 3 compliant agents, got %d", resp.Summary.CompliantAgents)
	}
	if resp.Summary.NonCompliantAgents != 2 {
		t.Fatalf("expected 2 non-compliant agents, got %d", resp.Summary.NonCompliantAgents)
	}

	if resp.Summary.CarriedGBP != 847000.0 {
		t.Fatalf("expected escalated Carried GBP 847000, got %f", resp.Summary.CarriedGBP)
	}
	if resp.Summary.Currency != "GBP" {
		t.Fatalf("expected currency GBP, got %s", resp.Summary.Currency)
	}

	// Verify per-agent statuses
	agentMap := make(map[string]AgentScanResult)
	for _, a := range resp.Agents {
		agentMap[a.AgentID] = a
	}

	// Compliant agents
	for _, id := range []string{"agent-cardvault", "agent-api-gateway", "agent-monitor"} {
		res, ok := agentMap[id]
		if !ok {
			t.Fatalf("agent %s missing from scan results", id)
		}
		if !res.Compliant {
			t.Fatalf("expected agent %s to be compliant", id)
		}
		if res.RiskExposure != 0.0 {
			t.Fatalf("expected 0 risk exposure for compliant agent %s, got %f", id, res.RiskExposure)
		}
	}

	// Non-compliant agents
	txPipeline, ok := agentMap["agent-txn-pipeline"]
	if !ok || txPipeline.Compliant {
		t.Fatalf("expected agent-txn-pipeline to fail compliance")
	}
	if txPipeline.RiskExposure <= 0 {
		t.Fatalf("expected positive risk exposure for agent-txn-pipeline, got %f", txPipeline.RiskExposure)
	}

	llmClassifier, ok := agentMap["agent-llm-classifier"]
	if !ok || llmClassifier.Compliant {
		t.Fatalf("expected agent-llm-classifier to fail compliance")
	}
	if llmClassifier.RiskExposure <= 0 {
		t.Fatalf("expected positive risk exposure for agent-llm-classifier, got %f", llmClassifier.RiskExposure)
	}
}

func TestFleetScan_AllCompliant(t *testing.T) {
	// Construct fleet where all pod specs pass compliance checks
	req := &FleetScanRequest{
		Agents: []AgentPodSpec{
			{
				AgentID: "agent-cardvault",
				PodSpec: map[string]interface{}{
					"securityContext": map[string]interface{}{"runAsNonRoot": true},
					"containers": []interface{}{
						map[string]interface{}{
							"securityContext": map[string]interface{}{
								"runAsNonRoot":           true,
								"readOnlyRootFilesystem": true,
								"capabilities": map[string]interface{}{
									"drop": []interface{}{"ALL"},
								},
							},
						},
					},
				},
			},
			{
				AgentID: "agent-api-gateway",
				PodSpec: map[string]interface{}{
					"securityContext": map[string]interface{}{"runAsNonRoot": true},
					"containers": []interface{}{
						map[string]interface{}{
							"securityContext": map[string]interface{}{
								"runAsNonRoot":           true,
								"readOnlyRootFilesystem": true,
								"capabilities": map[string]interface{}{
									"drop": []interface{}{"ALL"},
								},
							},
						},
					},
				},
			},
		},
	}

	resp := ScanFleet(req)

	if !resp.Compliant {
		t.Fatalf("expected all-compliant fleet, got compliant=false")
	}
	if resp.Summary.NonCompliantAgents != 0 {
		t.Fatalf("expected 0 non-compliant agents, got %d", resp.Summary.NonCompliantAgents)
	}
	if resp.Summary.CarriedGBP != 12400.0 {
		t.Fatalf("expected baseline Carried GBP 12400, got %f", resp.Summary.CarriedGBP)
	}
}

func TestFAIR_SimulationConsistency(t *testing.T) {
	req := &FleetScanRequest{}
	resp := ScanFleet(req)

	expectedCarried := resp.Summary.TVaR * 1.10
	if math.Abs(resp.Summary.CarriedGBP-expectedCarried) > 0.01 {
		t.Fatalf("expected CarriedGBP (%f) to match TVaR * 1.10 (%f)", resp.Summary.CarriedGBP, expectedCarried)
	}

	if resp.Summary.ALE <= 0 {
		t.Fatalf("ALE must be positive, got %f", resp.Summary.ALE)
	}
	if resp.Summary.VaR95 <= 0 {
		t.Fatalf("VaR95 must be positive, got %f", resp.Summary.VaR95)
	}
}

func TestHandleScanFleet_HTTP(t *testing.T) {
	// Test GET method not allowed
	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/scan-fleet", nil)
	getRec := httptest.NewRecorder()
	HandleScanFleet(getRec, getReq)
	if getRec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 Method Not Allowed, got %d", getRec.Code)
	}

	// Test POST valid request
	body, _ := json.Marshal(FleetScanRequest{})
	postReq := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan-fleet", bytes.NewReader(body))
	postReq.Header.Set("Content-Type", "application/json")
	postRec := httptest.NewRecorder()
	HandleScanFleet(postRec, postReq)

	if postRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", postRec.Code, postRec.Body.String())
	}

	var resp FleetScanResponse
	if err := json.NewDecoder(postRec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response JSON: %v", err)
	}

	if resp.Summary.CarriedGBP != 847000.0 {
		t.Fatalf("expected Carried GBP 847000, got %f", resp.Summary.CarriedGBP)
	}

	// Test malformed JSON
	badReq := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan-fleet", bytes.NewReader([]byte("{invalid-json")))
	badReq.Header.Set("Content-Type", "application/json")
	badRec := httptest.NewRecorder()
	HandleScanFleet(badRec, badReq)

	if badRec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request for malformed JSON, got %d", badRec.Code)
	}
}
