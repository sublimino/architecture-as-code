package compliance

import (
	"encoding/json"
	"testing"
)

// The refusal shape. These tests pin the three properties the shape exists to have:
//
//  1. a client cannot read the refusal as a figure,
//  2. the key set is the one the other two routes (fe-signalloom's
//     GET /compliance/policy/summary and /compliance/policy/frameworks) also emit, so one
//     condition has one signal estate-wide rather than three, and
//  3. the status distinguishes the two genuinely different causes, because they demand
//     different operator actions.
//
// The cross-language half of (2) is pinned by test_refusal_shape_parity.py in fe-signalloom,
// which reads refusalShapeKeys below out of this package's own JSON. Neither side can drift
// without one of the two failing.

// refusalShapeKeys is the agreed key set of the pricing refusal object, in sorted order.
//
// It is declared here, in the Go engine, and read from the serialised response rather than
// from the struct definition -- a struct tag typo would pass a reflection check and still
// put the wrong name on the wire.
var refusalShapeKeys = []string{
	"available",
	"reason",
	"status",
	"unmappedChecks",
	"unpricedFields",
}

func pricingObject(t *testing.T, resp FleetScanResponse) map[string]json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal response: %v", err)
	}
	var envelope struct {
		Summary struct {
			Pricing map[string]json.RawMessage `json:"pricing"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if envelope.Summary.Pricing == nil {
		t.Fatal("summary.pricing absent from the response: the refusal must be a payload field, " +
			"not an absence a reader has to notice")
	}
	return envelope.Summary.Pricing
}

func TestRefusal_PricingObjectCarriesTheAgreedKeySet(t *testing.T) {
	pricing := pricingObject(t, ScanFleet(&FleetScanRequest{}))

	for _, key := range refusalShapeKeys {
		if _, ok := pricing[key]; !ok {
			t.Errorf("summary.pricing is missing key %q; the shape must be identical across all "+
				"three refusing routes, so every key is present on every one of them", key)
		}
	}
	if len(pricing) != len(refusalShapeKeys) {
		got := make([]string, 0, len(pricing))
		for k := range pricing {
			got = append(got, k)
		}
		t.Errorf("summary.pricing has %d keys %v, want exactly %d %v: an extra key here is a "+
			"fourth way to say the same thing", len(pricing), got, len(refusalShapeKeys), refusalShapeKeys)
	}
}

func TestRefusal_StatusNamesTheCauseAndIsNotAFigure(t *testing.T) {
	pricing := pricingObject(t, ScanFleet(&FleetScanRequest{}))

	var status string
	if err := json.Unmarshal(pricing["status"], &status); err != nil {
		t.Fatalf("status is not a string: %v", err)
	}
	if status != string(PricingStatusNoDeclaredLossFrequency) {
		t.Errorf("status = %q, want %q: this route's checks resolve to no control in the risk "+
			"pack, so what is missing is a declared loss-event frequency -- not a data plane",
			status, PricingStatusNoDeclaredLossFrequency)
	}
	// The status must not be parseable as a number. This is the property that distinguishes an
	// explicit refusal from an omission or a zero: a client coercing the field gets an error,
	// not a figure it can chart.
	var asNumber float64
	if err := json.Unmarshal(pricing["status"], &asNumber); err == nil {
		t.Errorf("status deserialises as the number %v; a refusal a client can read as a figure "+
			"is the defect this shape exists to remove", asNumber)
	}
}

func TestRefusal_StatusDistinguishesTheTwoCauses(t *testing.T) {
	// The two causes demand different operator actions -- declare a control mapping in the
	// policy pack, versus stand up a priced scan behind the route -- so one status for both
	// would repeat the mistake the currency path already made and fixed.
	if PricingStatusNoDeclaredLossFrequency == PricingStatusNoRiskDataPlane {
		t.Fatal("the two refusal causes share a status value; an operator reading it cannot tell " +
			"which action to take")
	}
	for _, s := range []PricingStatus{
		PricingStatusNoDeclaredLossFrequency,
		PricingStatusNoRiskDataPlane,
	} {
		if s == PricingStatusPriced {
			t.Errorf("refusal status %q collides with the priced status", s)
		}
		if s == "" {
			t.Error("a refusal status is the empty string, which serialises as absence")
		}
	}
}

func TestRefusal_AvailableIsDerivedFromStatusAndCannotDisagree(t *testing.T) {
	// `available` predates `status` and is kept so today's clients keep deserialising. It is
	// derived from the status rather than set beside it, because two hand-maintained fields
	// carrying one fact eventually disagree.
	for _, tc := range []struct {
		status PricingStatus
		want   bool
	}{
		{PricingStatusPriced, true},
		{PricingStatusNoDeclaredLossFrequency, false},
		{PricingStatusNoRiskDataPlane, false},
	} {
		if got := tc.status.Available(); got != tc.want {
			t.Errorf("PricingStatus(%q).Available() = %v, want %v", tc.status, got, tc.want)
		}
	}

	pricing := pricingObject(t, ScanFleet(&FleetScanRequest{}))
	var available bool
	if err := json.Unmarshal(pricing["available"], &available); err != nil {
		t.Fatalf("available is not a bool: %v", err)
	}
	var status PricingStatus
	if err := json.Unmarshal(pricing["status"], &status); err != nil {
		t.Fatalf("status is not a string: %v", err)
	}
	if available != status.Available() {
		t.Errorf("available = %v but status %q implies %v: the two disagree on the wire",
			available, status, status.Available())
	}
}

func TestRefusal_UnpricedFieldsNamesEveryMoneyFieldTheResponseWithheld(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{})
	pricing := pricingObject(t, resp)

	var unpriced []string
	if err := json.Unmarshal(pricing["unpricedFields"], &unpriced); err != nil {
		t.Fatalf("unpricedFields is not a string list: %v", err)
	}
	if len(unpriced) == 0 {
		t.Fatal("unpricedFields is empty on a response that withheld every money figure")
	}

	// Each named field must genuinely be absent from the response. A refusal that names a
	// field the response did in fact populate is worse than no refusal.
	raw, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var envelope struct {
		Summary map[string]json.RawMessage `json:"summary"`
		Agents  []map[string]json.RawMessage
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, field := range unpriced {
		if _, present := envelope.Summary[field]; present {
			t.Errorf("unpricedFields names %q but summary.%s is present in the response", field, field)
		}
		for i, agent := range envelope.Agents {
			if _, present := agent[field]; present {
				t.Errorf("unpricedFields names %q but agents[%d].%s is present", field, i, field)
			}
		}
	}

	// And the converse: every money field this package declares must be accounted for, so
	// adding a fifth money field without listing it fails here rather than shipping silently.
	for _, want := range []string{"ale", "var95", "tvar", "carriedGbp", "riskExposureGbp"} {
		found := false
		for _, got := range unpriced {
			if got == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("unpricedFields %v does not name the withheld money field %q", unpriced, want)
		}
	}
}

func TestRefusal_ReasonIsAHumanSentenceNotAnEnum(t *testing.T) {
	pricing := pricingObject(t, ScanFleet(&FleetScanRequest{}))
	var reason string
	if err := json.Unmarshal(pricing["reason"], &reason); err != nil {
		t.Fatalf("reason is not a string: %v", err)
	}
	// The status is for the machine and the reason is for the operator; a reason that merely
	// repeats the status adds a key and no information.
	if reason == string(PricingStatusNoDeclaredLossFrequency) {
		t.Error("reason is a copy of status: it must say what is missing and where it would be declared")
	}
	if len(reason) < 80 {
		t.Errorf("reason is %d chars; it must name the inputs pricing requires and the documents "+
			"that would declare them, so an operator knows what to do next", len(reason))
	}
}

// ---------------------------------------------------------------------------
// Evaluation mode. The verdicts the refusal is derived from are, on the no-podSpec path,
// decided by an agent-ID string match. That is a demonstration fixture, not an evaluation,
// and a carefully-worded refusal grounded in "the risk pack" lends it credibility it has not
// earned. Fixing the fixture needs a third verdict state and is a product decision; labelling
// it on the wire is not.

func TestEvaluationMode_IsReportedPerAgentAndPerResponse(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{})
	if resp.EvaluationMode != EvaluationModeDemoFixture {
		t.Errorf("response evaluationMode = %q, want %q: the standard fleet carries no pod specs, "+
			"so every verdict in it came from the agent-ID fixture", resp.EvaluationMode, EvaluationModeDemoFixture)
	}
	for _, agent := range resp.Agents {
		if agent.EvaluationMode != EvaluationModeDemoFixture {
			t.Errorf("agent %s evaluationMode = %q, want %q",
				agent.AgentID, agent.EvaluationMode, EvaluationModeDemoFixture)
		}
	}
}

func TestEvaluationMode_IsDerivedFromTheBranchThatDecidedTheVerdict(t *testing.T) {
	// A supplied pod spec is really evaluated, so it must say so -- and an agent whose ID the
	// fixture would have failed must still report pod-spec when a spec decided it. That pairing
	// is what makes the label derived rather than a constant: it has to track the branch.
	req := &FleetScanRequest{Agents: []AgentPodSpec{
		{AgentID: "agent-txn-pipeline", PodSpec: compliantPodSpec(), Checks: DefaultFleetChecks},
	}}
	resp := ScanFleet(req)
	if resp.EvaluationMode != EvaluationModePodSpec {
		t.Errorf("response evaluationMode = %q, want %q", resp.EvaluationMode, EvaluationModePodSpec)
	}
	if resp.Agents[0].EvaluationMode != EvaluationModePodSpec {
		t.Errorf("agent evaluationMode = %q, want %q", resp.Agents[0].EvaluationMode, EvaluationModePodSpec)
	}
	// agent-txn-pipeline is the ID the fixture hardcodes a securityContext failure for. Its
	// real spec passes, so a pass here proves the pod-spec branch ran and the label is honest.
	if !resp.Agents[0].Compliant {
		t.Error("agent-txn-pipeline with a compliant pod spec was failed: the fixture decided a " +
			"verdict the pod spec should have")
	}
}

func TestEvaluationMode_MixedWhenSomeAgentsHaveSpecsAndOthersDoNot(t *testing.T) {
	// Neither label is true of this response, and picking either would misdescribe half of it.
	req := &FleetScanRequest{Agents: []AgentPodSpec{
		{AgentID: "agent-with-spec", PodSpec: compliantPodSpec(), Checks: DefaultFleetChecks},
		{AgentID: "agent-txn-pipeline", Checks: DefaultFleetChecks},
	}}
	resp := ScanFleet(req)
	if resp.EvaluationMode != EvaluationModeMixed {
		t.Errorf("response evaluationMode = %q, want %q", resp.EvaluationMode, EvaluationModeMixed)
	}
	if resp.Agents[0].EvaluationMode != EvaluationModePodSpec {
		t.Errorf("agents[0] evaluationMode = %q, want %q", resp.Agents[0].EvaluationMode, EvaluationModePodSpec)
	}
	if resp.Agents[1].EvaluationMode != EvaluationModeDemoFixture {
		t.Errorf("agents[1] evaluationMode = %q, want %q", resp.Agents[1].EvaluationMode, EvaluationModeDemoFixture)
	}
}

func TestEvaluationMode_IsOnTheWire(t *testing.T) {
	raw, err := json.Marshal(ScanFleet(&FleetScanRequest{}))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var envelope struct {
		EvaluationMode *string `json:"evaluationMode"`
		Agents         []struct {
			EvaluationMode *string `json:"evaluationMode"`
		} `json:"agents"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if envelope.EvaluationMode == nil {
		t.Fatal("evaluationMode absent from the response body: the condition must be visible to a " +
			"client, which is the whole point of labelling it")
	}
	if *envelope.EvaluationMode != string(EvaluationModeDemoFixture) {
		t.Errorf("wire evaluationMode = %q, want %q", *envelope.EvaluationMode, EvaluationModeDemoFixture)
	}
	if len(envelope.Agents) == 0 {
		t.Fatal("no agents in the response")
	}
	for i, agent := range envelope.Agents {
		if agent.EvaluationMode == nil {
			t.Fatalf("agents[%d].evaluationMode absent from the wire", i)
		}
	}
}

func TestEvaluationMode_FixtureBranchIsNotSilentlyReportedAsPodSpec(t *testing.T) {
	// The mutation this is here to catch: hardcoding the honest-looking label. If the response
	// always said "pod-spec", the fixture would be invisible again; if it always said
	// "demo-fixture", a genuinely evaluated scan would be defamed. Both must fail.
	fixture := ScanFleet(&FleetScanRequest{})
	evaluated := ScanFleet(&FleetScanRequest{Agents: []AgentPodSpec{
		{AgentID: "agent-a", PodSpec: compliantPodSpec(), Checks: DefaultFleetChecks},
	}})
	if fixture.EvaluationMode == evaluated.EvaluationMode {
		t.Errorf("a fixture-decided scan and a pod-spec-decided scan both report %q; the label is "+
			"not a function of which branch ran", fixture.EvaluationMode)
	}
}
