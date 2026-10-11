package compliance

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

// NOTE. A test named TestFAIR_SimulationConsistency stood here. It asserted
//
//	CarriedGBP == TVaR * 1.10
//
// against a summary in which TVaR had been *defined* as `carried / 1.10` three lines earlier. That
// is an identity true of every float, so the assertion held for any carried figure whatsoever,
// including the fabricated literal it was actually run against. It was the green test on a route
// that could not be wrong, and it is deleted rather than repaired: there is no figure left for it
// to check, and the tests below pin the absence instead.

// compliantPodSpec returns a pod spec that passes all three default checks.
func compliantPodSpec() map[string]interface{} {
	return map[string]interface{}{
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
	}
}

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

	// Verify per-agent statuses
	agentMap := make(map[string]AgentScanResult)
	for _, a := range resp.Agents {
		agentMap[a.AgentID] = a
	}

	for _, id := range []string{"agent-cardvault", "agent-api-gateway", "agent-monitor"} {
		res, ok := agentMap[id]
		if !ok {
			t.Fatalf("agent %s missing from scan results", id)
		}
		if !res.Compliant {
			t.Fatalf("expected agent %s to be compliant", id)
		}
	}

	txPipeline, ok := agentMap["agent-txn-pipeline"]
	if !ok || txPipeline.Compliant {
		t.Fatalf("expected agent-txn-pipeline to fail compliance")
	}

	llmClassifier, ok := agentMap["agent-llm-classifier"]
	if !ok || llmClassifier.Compliant {
		t.Fatalf("expected agent-llm-classifier to fail compliance")
	}
}

func TestFleetScan_AllCompliant(t *testing.T) {
	// Construct fleet where all pod specs pass compliance checks
	req := &FleetScanRequest{
		Agents: []AgentPodSpec{
			{AgentID: "agent-cardvault", PodSpec: compliantPodSpec()},
			{AgentID: "agent-api-gateway", PodSpec: compliantPodSpec()},
		},
	}

	resp := ScanFleet(req)

	if !resp.Compliant {
		t.Fatalf("expected all-compliant fleet, got compliant=false")
	}
	if resp.Summary.NonCompliantAgents != 0 {
		t.Fatalf("expected 0 non-compliant agents, got %d", resp.Summary.NonCompliantAgents)
	}
}

// TestFleetScan_RefusesToPriceUnmappedChecks pins the refusal on the path that used to return the
// escalated figures: the summary states it could not price, says why, and carries no money field.
func TestFleetScan_RefusesToPriceUnmappedChecks(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{})

	if resp.Summary.Pricing.Available {
		t.Fatalf("pricing.available must be false: this scan has no declared price for its checks")
	}
	if strings.TrimSpace(resp.Summary.Pricing.Reason) == "" {
		t.Fatalf("pricing.reason must explain why no figure is reported, got empty string")
	}
	for _, f := range []struct {
		name string
		val  *float64
	}{
		{"ale", resp.Summary.ALE},
		{"var95", resp.Summary.VaR95},
		{"tvar", resp.Summary.TVaR},
		{"carriedGbp", resp.Summary.CarriedGBP},
	} {
		if f.val != nil {
			t.Fatalf("summary.%s must be nil (not priced), got %f", f.name, *f.val)
		}
	}
	if resp.Summary.Currency != "" {
		t.Fatalf("summary.currency must be empty while nothing is priced, got %q", resp.Summary.Currency)
	}
}

// TestFleetScan_CompliantFleetAlsoRefusesToPrice pins the OTHER branch. The old code had a separate
// baseline branch with its own set of literals, so a fix that cured only the escalated path would
// pass TestFleetScan_RefusesToPriceUnmappedChecks while still fabricating a baseline figure.
func TestFleetScan_CompliantFleetAlsoRefusesToPrice(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{
		Agents: []AgentPodSpec{
			{AgentID: "agent-cardvault", PodSpec: compliantPodSpec()},
		},
	})

	if !resp.Compliant {
		t.Fatalf("precondition failed: expected a compliant fleet for this branch")
	}
	if resp.Summary.Pricing.Available {
		t.Fatalf("pricing.available must be false on the all-compliant path too")
	}
	if resp.Summary.CarriedGBP != nil {
		t.Fatalf("a compliant estate must not carry a fabricated baseline figure, got %f", *resp.Summary.CarriedGBP)
	}
	if resp.Summary.ALE != nil || resp.Summary.VaR95 != nil || resp.Summary.TVaR != nil {
		t.Fatalf("no money field may be present on the all-compliant path")
	}
}

// TestFleetScan_PerAgentExposureIsAbsentNotZero covers both kinds of agent. The old allocator wrote
// 0.0 for every compliant agent, which asserts "no risk" rather than "no figure".
func TestFleetScan_PerAgentExposureIsAbsentNotZero(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{})

	sawCompliant, sawNonCompliant := false, false
	for _, a := range resp.Agents {
		if a.Compliant {
			sawCompliant = true
		} else {
			sawNonCompliant = true
		}
		if a.RiskExposure != nil {
			t.Fatalf("agent %s: riskExposureGbp must be nil (not priced), got %f", a.AgentID, *a.RiskExposure)
		}
	}
	if !sawCompliant || !sawNonCompliant {
		t.Fatalf("precondition failed: need both compliant and non-compliant agents in this fixture (compliant=%v nonCompliant=%v)",
			sawCompliant, sawNonCompliant)
	}
}

// TestFleetScanJSON_OmitsMoneyFieldsEntirely asserts key ABSENCE in the serialised response, not
// that the value is zero. That is the point of the pointer fields: a test asserting `ale == 0`
// would pass against the very bug being fixed, because an unpriced scan and a zero-risk scan would
// look identical on the wire.
func TestFleetScanJSON_OmitsMoneyFieldsEntirely(t *testing.T) {
	raw, err := json.Marshal(ScanFleet(&FleetScanRequest{}))
	if err != nil {
		t.Fatalf("marshalling the response failed: %v", err)
	}

	var decoded struct {
		Summary map[string]any   `json:"summary"`
		Agents  []map[string]any `json:"agents"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("decoding the response failed: %v", err)
	}

	for _, key := range []string{"ale", "var95", "tvar", "carriedGbp", "currency"} {
		if v, present := decoded.Summary[key]; present {
			t.Fatalf("summary.%s must be absent from the JSON, not present as %v", key, v)
		}
	}
	if _, present := decoded.Summary["pricing"]; !present {
		t.Fatalf("summary.pricing must be present so the refusal is legible to a client")
	}
	if len(decoded.Agents) == 0 {
		t.Fatalf("precondition failed: expected agents in the response")
	}
	for _, a := range decoded.Agents {
		if v, present := a["riskExposureGbp"]; present {
			t.Fatalf("agent %v: riskExposureGbp must be absent from the JSON, not present as %v", a["agentId"], v)
		}
	}
}

// TestFleetScan_UnmappedChecksAreDerivedFromTheRequest is the movement tripwire. Under a refusal
// there is no figure to perturb, so the thing that must vary with its inputs is the refusal itself:
// two different requests must produce two different unmapped-check lists, built from the checks
// actually run rather than read off DefaultFleetChecks.
func TestFleetScan_UnmappedChecksAreDerivedFromTheRequest(t *testing.T) {
	custom := ScanFleet(&FleetScanRequest{
		Agents: []AgentPodSpec{
			{AgentID: "agent-a", Checks: []string{"zeta-custom-check", "securityContext"}},
			{AgentID: "agent-b", Checks: []string{"alpha-custom-check", "securityContext"}},
		},
	})

	// Distinct, sorted, and drawn from both agents' lists.
	want := []string{"alpha-custom-check", "securityContext", "zeta-custom-check"}
	if !reflect.DeepEqual(custom.Summary.Pricing.Unmapped, want) {
		t.Fatalf("unmappedChecks must be the distinct sorted checks actually run\n got: %v\nwant: %v",
			custom.Summary.Pricing.Unmapped, want)
	}

	// A different request must yield a different list, which a hardcoded value cannot do.
	defaults := ScanFleet(&FleetScanRequest{})
	wantDefaults := []string{"dropCapabilities", "readOnlyRootFilesystem", "securityContext"}
	if !reflect.DeepEqual(defaults.Summary.Pricing.Unmapped, wantDefaults) {
		t.Fatalf("default fleet unmappedChecks\n got: %v\nwant: %v",
			defaults.Summary.Pricing.Unmapped, wantDefaults)
	}
	if reflect.DeepEqual(custom.Summary.Pricing.Unmapped, defaults.Summary.Pricing.Unmapped) {
		t.Fatalf("two different requests produced the same unmappedChecks (%v): the refusal is not derived from its inputs",
			custom.Summary.Pricing.Unmapped)
	}
}

// TestFleetScanSource_ContainsNoCalibratedMoneyLiterals reads the implementation and fails if any
// of the fabricated figures reappears in it. The figures were literals, so the only durable way to
// pin their absence is to look at the source: a behavioural test can be satisfied by a literal
// routed through one more variable.
//
// If this test fails on a legitimate change, the fix is to declare the inputs in the two files
// named by unpricedReason and compute the figure -- not to add an exemption here.
func TestFleetScanSource_ContainsNoCalibratedMoneyLiterals(t *testing.T) {
	const path = "fleet_scan.go"
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s failed: %v", path, err)
	}
	body := string(src)

	// The fabricated fleet figures, and the two per-agent exposures paid by agent-ID string match.
	fabricated := []string{"847000", "742000", "615000", "12400", "11200", "9800", "350000", "497000"}

	var found []string
	for _, lit := range fabricated {
		if strings.Contains(body, lit) {
			found = append(found, lit)
		}
	}
	if len(found) > 0 {
		t.Fatalf("%s contains fabricated money literal(s) %v; a figure must be a function of its inputs or absent",
			path, found)
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
	body, err := json.Marshal(FleetScanRequest{})
	if err != nil {
		t.Fatalf("marshalling the request failed: %v", err)
	}
	postReq := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan-fleet", bytes.NewReader(body))
	postReq.Header.Set("Content-Type", "application/json")
	postRec := httptest.NewRecorder()
	HandleScanFleet(postRec, postReq)

	if postRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", postRec.Code, postRec.Body.String())
	}

	// 200 with the real part of the answer (the compliance verdict) and an explicit refusal to
	// price, rather than a 4xx that would discard the checks this scan genuinely evaluated.
	var resp FleetScanResponse
	if err := json.NewDecoder(postRec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response JSON: %v", err)
	}
	if resp.Summary.Pricing.Available {
		t.Fatalf("pricing.available must be false over HTTP too")
	}
	if resp.Summary.CarriedGBP != nil {
		t.Fatalf("expected no carried figure over HTTP, got %f", *resp.Summary.CarriedGBP)
	}
	if resp.Summary.TotalAgents != 5 {
		t.Fatalf("expected the standard 5-agent fleet, got %d", resp.Summary.TotalAgents)
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
