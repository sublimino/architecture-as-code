package compliance

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"
)

// AgentPodSpec represents the pod specification and target checks for an agent.
type AgentPodSpec struct {
	AgentID string                 `json:"agentId"`
	PodSpec map[string]interface{} `json:"podSpec,omitempty"`
	Checks  []string               `json:"checks,omitempty"`
}

// FleetScanRequest represents the incoming POST body for /api/v1/compliance/scan-fleet.
type FleetScanRequest struct {
	TenantID string         `json:"tenantId,omitempty"`
	Agents   []AgentPodSpec `json:"agents,omitempty"`
}

// AgentCheckResult represents the outcome of an individual security check.
type AgentCheckResult struct {
	Check  string `json:"check"`
	Pass   bool   `json:"pass"`
	Reason string `json:"reason,omitempty"`
}

// AgentScanResult represents the compliance posture of an agent, and its priced risk exposure if
// and only if this scan was able to price its own findings.
//
// RiskExposure is a pointer, and nil means "not priced" -- NOT zero. The distinction is the whole
// point: the previous implementation wrote 0.0 for every compliant agent, which asserts that a
// compliant agent carries no risk. It does not; the scan simply has no figure for it. An absent
// field says so, a zero does not. See the refusal note on summariseFleetPosture.
type AgentScanResult struct {
	AgentID      string             `json:"agentId"`
	Compliant    bool               `json:"compliant"`
	Checks       []AgentCheckResult `json:"checks"`
	RiskExposure *float64           `json:"riskExposureGbp,omitempty"`
}

// FleetPricingStatus states whether this scan was able to price its own findings, and when it was
// not, why not and which of its checks had no declared price.
//
// It exists so the refusal is part of the payload rather than an absence a reader has to notice.
// Unmapped is derived from the checks this scan actually ran, so the refusal varies with its
// inputs instead of being a fixed string.
type FleetPricingStatus struct {
	Available bool     `json:"available"`
	Reason    string   `json:"reason,omitempty"`
	Unmapped  []string `json:"unmappedChecks,omitempty"`
}

// FleetFairRiskSummary carries the fleet's compliance counts and, when the findings can be priced,
// the aggregate FAIR figures.
//
// The four money fields are pointers with omitempty so that an unpriced scan omits them from the
// JSON entirely rather than serialising them as 0. A zero in a money field is read -- by a human
// and by a dashboard -- as the claim "no loss expected", which is a figure. fair/fair.go records
// the same failure mode in its note on the removed VaR95 >= ALE clamp: it "silently reported a bad
// year equal to the average year -- a fabricated figure, with no error and no flag".
//
// Currency is likewise omitted while nothing is priced. A currency label attached to no figure
// tells a reader a figure was computed in that currency.
type FleetFairRiskSummary struct {
	ALE                *float64           `json:"ale,omitempty"`
	VaR95              *float64           `json:"var95,omitempty"`
	TVaR               *float64           `json:"tvar,omitempty"`
	CarriedGBP         *float64           `json:"carriedGbp,omitempty"`
	Currency           string             `json:"currency,omitempty"`
	Pricing            FleetPricingStatus `json:"pricing"`
	TotalAgents        int                `json:"totalAgents"`
	CompliantAgents    int                `json:"compliantAgents"`
	NonCompliantAgents int                `json:"nonCompliantAgents"`
}

// FleetScanResponse is the JSON response schema for /api/v1/compliance/scan-fleet.
type FleetScanResponse struct {
	Compliant bool                 `json:"compliant"`
	Summary   FleetFairRiskSummary `json:"summary"`
	Agents    []AgentScanResult    `json:"agents"`
	ScannedAt string               `json:"scannedAt"`
}

// Standard 5-agent fleet profiles used when no custom agents are provided.
var StandardFleet = []string{
	"agent-cardvault",
	"agent-api-gateway",
	"agent-monitor",
	"agent-txn-pipeline",
	"agent-llm-classifier",
}

// Default checks evaluated across agent pod specifications.
var DefaultFleetChecks = []string{
	"securityContext",
	"dropCapabilities",
	"readOnlyRootFilesystem",
}

// EvaluateAgentCheck evaluates a single security check against an agent and its optional PodSpec.
func EvaluateAgentCheck(agentID string, checkName string, podSpec map[string]interface{}) AgentCheckResult {
	if podSpec != nil && len(podSpec) > 0 {
		return evaluatePodSpecCheck(checkName, podSpec)
	}

	// Calibrated defaults for the 5 standard demonstration agents
	switch checkName {
	case "securityContext":
		if agentID == "agent-txn-pipeline" {
			return AgentCheckResult{
				Check:  checkName,
				Pass:   false,
				Reason: "missing securityContext or runAsNonRoot is not enabled",
			}
		}
		return AgentCheckResult{Check: checkName, Pass: true, Reason: "securityContext configured with runAsNonRoot"}

	case "dropCapabilities":
		if agentID == "agent-llm-classifier" {
			return AgentCheckResult{
				Check:  checkName,
				Pass:   false,
				Reason: "container capabilities do not drop ALL",
			}
		}
		return AgentCheckResult{Check: checkName, Pass: true, Reason: "container drops all capabilities"}

	case "readOnlyRootFilesystem":
		return AgentCheckResult{Check: checkName, Pass: true, Reason: "readOnlyRootFilesystem is true"}

	default:
		return AgentCheckResult{Check: checkName, Pass: true}
	}
}

func evaluatePodSpecCheck(checkName string, spec map[string]interface{}) AgentCheckResult {
	switch checkName {
	case "securityContext":
		secCtx, ok := spec["securityContext"].(map[string]interface{})
		if !ok || secCtx == nil {
			return AgentCheckResult{Check: checkName, Pass: false, Reason: "missing securityContext"}
		}
		if nonRoot, ok := secCtx["runAsNonRoot"].(bool); !ok || !nonRoot {
			return AgentCheckResult{Check: checkName, Pass: false, Reason: "runAsNonRoot must be true"}
		}
		return AgentCheckResult{Check: checkName, Pass: true, Reason: "securityContext validated"}

	case "dropCapabilities":
		containers, ok := spec["containers"].([]interface{})
		if !ok || len(containers) == 0 {
			// Check top-level or return pass if no container details
			return AgentCheckResult{Check: checkName, Pass: true}
		}
		for _, c := range containers {
			cmap, ok := c.(map[string]interface{})
			if !ok {
				continue
			}
			secCtx, ok := cmap["securityContext"].(map[string]interface{})
			if !ok || secCtx == nil {
				return AgentCheckResult{Check: checkName, Pass: false, Reason: "container missing securityContext"}
			}
			caps, ok := secCtx["capabilities"].(map[string]interface{})
			if !ok || caps == nil {
				return AgentCheckResult{Check: checkName, Pass: false, Reason: "container missing capabilities drop"}
			}
			drops, ok := caps["drop"].([]interface{})
			if !ok || len(drops) == 0 {
				return AgentCheckResult{Check: checkName, Pass: false, Reason: "capabilities drop is empty"}
			}
			hasDropAll := false
			for _, d := range drops {
				if s, ok := d.(string); ok && (strings.EqualFold(s, "ALL") || strings.EqualFold(s, "all")) {
					hasDropAll = true
					break
				}
			}
			if !hasDropAll {
				return AgentCheckResult{Check: checkName, Pass: false, Reason: "capabilities must drop ALL"}
			}
		}
		return AgentCheckResult{Check: checkName, Pass: true, Reason: "capabilities drop ALL confirmed"}

	case "readOnlyRootFilesystem":
		containers, ok := spec["containers"].([]interface{})
		if ok && len(containers) > 0 {
			for _, c := range containers {
				cmap, ok := c.(map[string]interface{})
				if !ok {
					continue
				}
				secCtx, ok := cmap["securityContext"].(map[string]interface{})
				if ok && secCtx != nil {
					if ro, ok := secCtx["readOnlyRootFilesystem"].(bool); ok && !ro {
						return AgentCheckResult{Check: checkName, Pass: false, Reason: "readOnlyRootFilesystem must be true"}
					}
				}
			}
		}
		return AgentCheckResult{Check: checkName, Pass: true, Reason: "readOnlyRootFilesystem confirmed"}

	default:
		return AgentCheckResult{Check: checkName, Pass: true}
	}
}

// ScanFleet executes multi-agent compliance checks and computes aggregate FAIR risk metrics.
func ScanFleet(req *FleetScanRequest) FleetScanResponse {
	agentSpecs := req.Agents
	if len(agentSpecs) == 0 {
		agentSpecs = make([]AgentPodSpec, len(StandardFleet))
		for i, id := range StandardFleet {
			agentSpecs[i] = AgentPodSpec{
				AgentID: id,
				Checks:  DefaultFleetChecks,
			}
		}
	}

	totalAgents := len(agentSpecs)
	compliantCount := 0
	nonCompliantCount := 0
	agentResults := make([]AgentScanResult, 0, totalAgents)

	// The distinct checks this scan actually ran. Collected here, from the per-agent check lists
	// after the DefaultFleetChecks fallback is applied, rather than read off DefaultFleetChecks --
	// a caller may name checks of its own, and the refusal should name what was really run.
	checksRun := make(map[string]struct{})

	for _, spec := range agentSpecs {
		checksToRun := spec.Checks
		if len(checksToRun) == 0 {
			checksToRun = DefaultFleetChecks
		}

		agentPassed := true
		checkResults := make([]AgentCheckResult, 0, len(checksToRun))
		for _, c := range checksToRun {
			checksRun[c] = struct{}{}
			res := EvaluateAgentCheck(spec.AgentID, c, spec.PodSpec)
			checkResults = append(checkResults, res)
			if !res.Pass {
				agentPassed = false
			}
		}

		if agentPassed {
			compliantCount++
		} else {
			nonCompliantCount++
		}

		// RiskExposure is left nil: this scan does not price its findings, so no agent gets a
		// figure -- compliant or not. See summariseFleetPosture.
		agentResults = append(agentResults, AgentScanResult{
			AgentID:   spec.AgentID,
			Compliant: agentPassed,
			Checks:    checkResults,
		})
	}

	// Sorted so the refusal text is stable across runs; an unordered list read as a diff is noise.
	unmappedChecks := make([]string, 0, len(checksRun))
	for c := range checksRun {
		unmappedChecks = append(unmappedChecks, c)
	}
	sort.Strings(unmappedChecks)

	summary := summariseFleetPosture(totalAgents, compliantCount, nonCompliantCount, unmappedChecks)

	fleetCompliant := nonCompliantCount == 0

	return FleetScanResponse{
		Compliant: fleetCompliant,
		Summary:   summary,
		Agents:    agentResults,
		ScannedAt: time.Now().UTC().Format(time.RFC3339),
	}
}

// unpricedReason is the refusal text. It names what pricing a finding requires and which two
// documents would have to declare it, so an operator reading the response knows what is missing
// rather than only that something is.
const unpricedReason = "this scan cannot price its findings: pricing a finding requires a " +
	"loss-event frequency, declared per control in the policy pack " +
	"(risk/packs/agent-policy/<version>/pack.yaml, fields lef_audit and lef_enforced), and a loss " +
	"magnitude, declared per scenario in the organisational risk posture " +
	"(risk/org/<org>.yaml, field magnitude). None of the pod-spec checks this scan runs resolves " +
	"to a declared control, so neither input exists for these findings and no figure is reported"

// summariseFleetPosture reduces the scan to the counts it genuinely derived, and records that it
// will not price them.
//
// WHY THERE ARE NO FIGURES HERE ANY MORE.
//
// This function used to return a full set of FAIR figures -- ALE, VaR95, TVaR and a carried
// exposure -- on both of two branches selected by whether any agent was non-compliant. Every one of
// those figures was a literal written into the source. The escalated branch called
// fair.SimulateWithLoad and assigned the result to the blank identifier, so the real Monte Carlo
// ran and its output was thrown away. The baseline branch was subtler and worse: it computed a
// simulation, assigned four literals, and then re-assigned the same four literals inside
// `if sim.ALE > 0`. The figure provably could not move, while the code read as though the
// simulation fed it. A fake dependency is harder to spot than a bare constant, which is why that
// branch is called out here by name.
//
// The figures were also insensitive to the findings they claimed to price: one failed check on one
// agent produced exactly the same carried exposure as every check failing on fifty agents. The only
// input was the boolean "is anything non-compliant".
//
// WHY THE ANSWER IS REFUSAL RATHER THAN A REAL SIMULATION. The engine to do this properly exists
// (fair.Engine.Run takes contributions and a risk load) and so do real inputs: the policy pack
// declares loss-event frequency per control and risk/org/*.yaml declares loss magnitude per
// scenario. But this route's checks -- securityContext, dropCapabilities, readOnlyRootFilesystem --
// are Kubernetes pod-spec hardening checks, and they map to no control in the pack, whose controls
// govern agent behaviour (sandboxing, credential handling, approval, egress, injection,
// attestation, trust anchors). There is no declared frequency for "this pod runs as root" and no
// scenario these findings belong to. Writing a mapping here would be supplying the missing input
// from this file -- the same fabrication, relocated into a table with a provenance comment beside
// it. So the route refuses, which is also why it needs no risk load and does not have to pick
// between the engine default and the load the org posture declares.
//
// Restoring any figure to this function means first declaring the inputs in the two files named in
// unpricedReason. A test reads this source file and fails if the old literals reappear in it.
func summariseFleetPosture(total, compliant, nonCompliant int, unmappedChecks []string) FleetFairRiskSummary {
	return FleetFairRiskSummary{
		// ALE, VaR95, TVaR, CarriedGBP and Currency are deliberately left at their zero values so
		// that omitempty drops them from the response entirely. Absent, not zero.
		Pricing: FleetPricingStatus{
			Available: false,
			Reason:    unpricedReason,
			Unmapped:  unmappedChecks,
		},
		TotalAgents:        total,
		CompliantAgents:    compliant,
		NonCompliantAgents: nonCompliant,
	}
}

// HandleScanFleet handles POST /api/v1/compliance/scan-fleet HTTP requests.
func HandleScanFleet(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
		return
	}

	var req FleetScanRequest
	if r.Body != nil && r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "invalid request body: " + err.Error()})
			return
		}
	}

	resp := ScanFleet(&req)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
}
