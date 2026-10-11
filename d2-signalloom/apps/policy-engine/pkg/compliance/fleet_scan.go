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

// EvaluationMode names the code path that decided the verdicts in a response.
//
// WHY THIS IS ON THE WIRE. EvaluateAgentCheck has two branches. One reads a supplied pod spec and
// is a real evaluation. The other, taken when no pod spec is supplied, decides pass and fail by
// matching the agent's ID against two hardcoded strings -- agent-txn-pipeline fails
// securityContext, agent-llm-classifier fails dropCapabilities, everything else passes. That
// branch is a demonstration fixture: its verdicts are not a function of any input describing the
// agent, so neither is the compliance posture derived from them.
//
// That matters here more than it would elsewhere, because this route now carries a carefully
// worded refusal to price its findings, grounded in what the risk pack declares. A refusal in that
// register reads as the output of a calibrated system. If the layer feeding it is a string match,
// the refusal lends the string match credibility it has not earned. Labelling the layer is the
// cheap half of the fix and it is in scope; replacing the fixture needs a third "not evaluated"
// verdict state and would move the `compliant` boolean the dashboard renders, which is a product
// decision and is not.
//
// The label is derived from the branch each check actually took and folded upwards, never set from
// a constant -- see evaluateAgentCheck and foldEvaluationMode.
type EvaluationMode string

const (
	// EvaluationModePodSpec: every verdict came from reading a supplied pod spec.
	EvaluationModePodSpec EvaluationMode = "pod-spec"
	// EvaluationModeDemoFixture: every verdict came from the agent-ID fixture.
	EvaluationModeDemoFixture EvaluationMode = "demo-fixture"
	// EvaluationModeMixed: both branches ran. Neither label is true of the whole, and picking
	// either would misdescribe half of it.
	EvaluationModeMixed EvaluationMode = "mixed"
)

// foldEvaluationMode reduces the modes of a response's parts to the mode of the whole.
func foldEvaluationMode(modes []EvaluationMode) EvaluationMode {
	sawPodSpec, sawFixture := false, false
	for _, m := range modes {
		switch m {
		case EvaluationModePodSpec:
			sawPodSpec = true
		case EvaluationModeDemoFixture:
			sawFixture = true
		case EvaluationModeMixed:
			sawPodSpec, sawFixture = true, true
		}
	}
	switch {
	case sawPodSpec && sawFixture:
		return EvaluationModeMixed
	case sawPodSpec:
		return EvaluationModePodSpec
	default:
		// An empty fleet runs no evaluation at all. The fixture is this route's default path,
		// and claiming pod-spec evaluation for a response with no evaluations in it would be the
		// one direction of error that flatters the payload.
		return EvaluationModeDemoFixture
	}
}

// AgentScanResult represents the compliance posture of an agent, and its priced risk exposure if
// and only if this scan was able to price its own findings.
//
// RiskExposure is a pointer, and nil means "not priced" -- NOT zero. The distinction is the whole
// point: the previous implementation wrote 0.0 for every compliant agent, which asserts that a
// compliant agent carries no risk. It does not; the scan simply has no figure for it. An absent
// field says so, a zero does not. See the refusal note on summariseFleetPosture.
//
// EvaluationMode records which branch decided this agent's checks. See EvaluationMode.
type AgentScanResult struct {
	AgentID        string             `json:"agentId"`
	Compliant      bool               `json:"compliant"`
	EvaluationMode EvaluationMode     `json:"evaluationMode"`
	Checks         []AgentCheckResult `json:"checks"`
	RiskExposure   *float64           `json:"riskExposureGbp,omitempty"`
}

// PricingStatus is the machine-readable cause of a route declining to report a money figure.
//
// WHY A STATUS AND NOT AN ABSENCE. Three routes in this estate withhold the same class of figure,
// and until this type existed they said so three different ways: this one omitted the fields,
// fe-signalloom's GET /compliance/policy/summary and /compliance/policy/frameworks returned null,
// and older paths returned 0. An API that signals one condition three ways invites the reader to
// ask whether any of it is deliberate.
//
// Worse, structural absence is not self-describing. A missing field is indistinguishable from a
// field this version does not implement, from version skew between client and server, from a
// serialisation bug, and from a crash midway through encoding. Omission makes a field silent, not
// honest; the reader fills in the blank themselves, and a dashboard fills it in with zero. So the
// value is still absent -- the figure must not be forgeable -- but the absence is now accompanied
// by a status saying who withheld it and why.
//
// WHY TWO REFUSAL VALUES AND NOT ONE. The two causes demand different operator actions. A missing
// loss-event frequency is fixed by declaring a control mapping in the policy pack. A missing risk
// data plane is fixed by putting a priced scan behind the route. Collapsing them would repeat the
// mistake the currency path already made and fixed: one label over two facts, which reads as
// authoritative precisely because it is uniform.
type PricingStatus string

const (
	// PricingStatusPriced: a figure is present and was computed from declared inputs.
	PricingStatusPriced PricingStatus = "PRICED"
	// PricingStatusNoDeclaredLossFrequency: the checks evaluated resolve to no control in the
	// risk pack, so no loss-event frequency is declared for these findings and no figure can be
	// derived. Operator action: declare the mapping in risk/packs/agent-policy/<version>/pack.yaml.
	PricingStatusNoDeclaredLossFrequency PricingStatus = "NO_DECLARED_LOSS_FREQUENCY"
	// PricingStatusNoRiskDataPlane: the route answers from a store that holds no money at all, so
	// there is nothing to aggregate. Used by fe-signalloom's two persisted-summary routes, whose
	// rows come from agent_compliance_results (migration 004, no money column). Operator action:
	// run a priced scan, or give the route a risk data plane.
	PricingStatusNoRiskDataPlane PricingStatus = "NO_RISK_DATA_PLANE"
)

// Available reports whether a figure accompanies this status.
//
// FleetPricingStatus.Available is derived through this method rather than set beside the status,
// because two hand-maintained fields carrying one fact eventually disagree -- and a boolean that
// disagrees with the status beside it is worse than either alone.
func (s PricingStatus) Available() bool { return s == PricingStatusPriced }

// FleetPricingStatus is the refusal object. Its key set is deliberately identical on all three
// routes that withhold money, so a client has one shape to deserialise and one to render.
//
// Unmapped is derived from the checks this scan actually ran, so the refusal varies with its
// inputs instead of being a fixed string. It is always allocated, never nil: nil marshals to
// `null` and an empty slice to `[]`, and the point of the shared shape is that every key is
// present with the same type on every route.
type FleetPricingStatus struct {
	Available bool          `json:"available"`
	Status    PricingStatus `json:"status"`
	Reason    string        `json:"reason"`
	// UnpricedFields names the money fields this response withheld, by their JSON names, so a
	// client can tell "withheld" from "this version has no such field" without a schema.
	UnpricedFields []string `json:"unpricedFields"`
	// Unmapped names the checks that resolved to no declared control. Empty where the refusal is
	// not per-check -- the two persisted-summary routes, whose cause is the absent data plane.
	Unmapped []string `json:"unmappedChecks"`
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
//
// EvaluationMode is the fold of the per-agent modes: it tells a reader whether the compliance
// posture in this response was evaluated or fixtured. See EvaluationMode.
type FleetScanResponse struct {
	Compliant      bool                 `json:"compliant"`
	EvaluationMode EvaluationMode       `json:"evaluationMode"`
	Summary        FleetFairRiskSummary `json:"summary"`
	Agents         []AgentScanResult    `json:"agents"`
	ScannedAt      string               `json:"scannedAt"`
}

// unpricedMoneyFields is every money field this response type can carry, by JSON name: four on
// the summary and one per agent. It is the list the refusal reports as withheld.
//
// A test marshals a refusing response and fails if any name here is actually present in it, and
// also fails if a name is missing from the refusal -- so adding a sixth money field without
// listing it breaks the build's tests rather than shipping a refusal that quietly under-reports.
var unpricedMoneyFields = []string{"ale", "var95", "tvar", "carriedGbp", "riskExposureGbp"}

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
	res, _ := evaluateAgentCheck(agentID, checkName, podSpec)
	return res
}

// evaluateAgentCheck is EvaluateAgentCheck plus the mode of the branch it took.
//
// The mode is returned BY the dispatch rather than recomputed from podSpec by the caller. That is
// the point: if the two were computed independently from the same predicate they could drift, and
// if the caller recomputed it, a change to the dispatch condition would leave the label behind
// while the verdicts moved. Reporting it from inside means the label cannot describe a branch
// other than the one that ran.
func evaluateAgentCheck(
	agentID string,
	checkName string,
	podSpec map[string]interface{},
) (AgentCheckResult, EvaluationMode) {
	if len(podSpec) > 0 {
		return evaluatePodSpecCheck(checkName, podSpec), EvaluationModePodSpec
	}
	return evaluateFixtureCheck(agentID, checkName), EvaluationModeDemoFixture
}

// evaluateFixtureCheck decides a verdict by matching the agent's ID.
//
// This is not an evaluation. Nothing about the agent is read: the result is a function of the
// agent's name and the check's name and nothing else, so it is identical for a hardened agent and
// a root-running one that happen to share an ID. It is retained because the five-agent
// demonstration fleet has no pod specs to read and the dashboard renders its verdicts; responses
// that reach it are labelled EvaluationModeDemoFixture so a consumer is told as much.
func evaluateFixtureCheck(agentID string, checkName string) AgentCheckResult {
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
		checkModes := make([]EvaluationMode, 0, len(checksToRun))
		for _, c := range checksToRun {
			checksRun[c] = struct{}{}
			res, mode := evaluateAgentCheck(spec.AgentID, c, spec.PodSpec)
			checkResults = append(checkResults, res)
			checkModes = append(checkModes, mode)
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
		//
		// EvaluationMode is folded from the branches this agent's own checks took, so it reports
		// what decided these verdicts and not what decided the fleet's.
		agentResults = append(agentResults, AgentScanResult{
			AgentID:        spec.AgentID,
			Compliant:      agentPassed,
			EvaluationMode: foldEvaluationMode(checkModes),
			Checks:         checkResults,
		})
	}

	agentModes := make([]EvaluationMode, 0, len(agentResults))
	for _, a := range agentResults {
		agentModes = append(agentModes, a.EvaluationMode)
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
		Compliant:      fleetCompliant,
		EvaluationMode: foldEvaluationMode(agentModes),
		Summary:        summary,
		Agents:         agentResults,
		ScannedAt:      time.Now().UTC().Format(time.RFC3339),
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
	status := PricingStatusNoDeclaredLossFrequency
	return FleetFairRiskSummary{
		// ALE, VaR95, TVaR, CarriedGBP and Currency are deliberately left at their zero values so
		// that omitempty drops them from the response entirely. Absent, not zero -- and now
		// absent WITH a status saying so, because an omission alone is silent rather than honest.
		Pricing: FleetPricingStatus{
			// Derived, never written beside the status. See PricingStatus.Available.
			Available:      status.Available(),
			Status:         status,
			Reason:         unpricedReason,
			UnpricedFields: unpricedMoneyFields,
			Unmapped:       unmappedChecks,
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
