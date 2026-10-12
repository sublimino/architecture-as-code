package main

import (
	"encoding/json"
	"testing"
)

// GET /api/v1/fleet/topology used to serve aggregateRisk.ale and .var95 as required
// numbers, read straight out of fleet.yaml. The figures were authored configuration, the
// dashboard rendered them on a risk gauge, and the contract test REQUIRED them to be
// numbers -- so the test pinned the fabrication in place rather than catching it.
//
// This is the fifth site of that defect in this estate. The evidence that it is site five
// and not a legitimate computation:
//
//   - AgentProfile, the only per-agent input this service has, declares no loss magnitude,
//     no loss-event frequency and no money field of any kind. The input type cannot carry
//     the input a FAIR computation needs.
//   - risk/packs/ returns zero matches for `riskClass` and `trustProfile`: nothing maps an
//     agent's risk class to a loss figure.
//   - the only money the packs declare is `annual_cost`, which pack.yaml documents as the
//     cost of running the CONTROL ENVIRONMENT and explicitly "not necessarily denominated
//     in the same currency as an institution's loss magnitudes". Control cost is not loss
//     magnitude.
//   - `ale: 847000` in base/configmap.yaml is the same literal policy-engine returned from
//     `carried := 847000.0` after discarding a real Monte Carlo. Same number, same claim,
//     one service along.
//
// So the figure cannot be computed from anything declared in this repository, and the
// doctrine is that it must therefore refuse rather than carry an authored number to a risk
// gauge. These tests assert the refusal, which is the opposite of what the old contract
// test asserted about the same two keys.

// TestAggregateRiskWithholdsAuthoredMoney is the core assertion: the authored figures in
// the fleet config do not reach the wire as money, however they are spelled there.
func TestAggregateRiskWithholdsAuthoredMoney(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	risk, ok := body["aggregateRisk"].(map[string]any)
	if !ok {
		t.Fatalf("aggregateRisk = %#v, want an object", body["aggregateRisk"])
	}

	// Absent, not zero. A zero in a money field is read by a human and by a dashboard as
	// the claim "no loss expected", which is itself a figure.
	for _, key := range []string{"ale", "var95", "previousAle"} {
		if v, present := risk[key]; present {
			t.Errorf("aggregateRisk.%s = %#v, want the key absent: no computation stands behind it", key, v)
		}
	}
}

// TestAggregateRiskWithholdsTrend covers the field that is not money but is a claim about
// money. "trend: up" asserts that an ALE rose; with no ALE computed there is no movement to
// report, and an arrow on a gauge is as readable as a number.
func TestAggregateRiskWithholdsTrend(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)
	risk := body["aggregateRisk"].(map[string]any)

	if v, present := risk["trend"]; present {
		t.Errorf("aggregateRisk.trend = %#v, want the key absent: a trend in an uncomputed figure is a claim, not an observation", v)
	}
}

// TestAggregateRiskCarriesW6RefusalShape asserts the shared shape, key for key. The point
// of adopting W6's object is that a client has ONE shape to deserialise across every route
// in the estate that withholds a money figure, so the key set is part of the contract.
func TestAggregateRiskCarriesW6RefusalShape(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)
	risk := body["aggregateRisk"].(map[string]any)

	pricing, ok := risk["pricing"].(map[string]any)
	if !ok {
		t.Fatalf("aggregateRisk.pricing = %#v, want the shared refusal object", risk["pricing"])
	}

	for _, key := range []string{"available", "status", "reason", "unpricedFields", "unmappedChecks"} {
		if _, present := pricing[key]; !present {
			t.Errorf("aggregateRisk.pricing.%s is missing: every key of the shared shape is always present", key)
		}
	}

	if available, _ := pricing["available"].(bool); available {
		t.Errorf("pricing.available = true while no figure is served")
	}

	if got := pricing["status"]; got != string(PricingStatusAuthoredNotComputed) {
		t.Errorf("pricing.status = %#v, want %q", got, PricingStatusAuthoredNotComputed)
	}

	// The reason must name the cause, not merely assert one. An operator reading it should
	// know which of the three refusals they are looking at without decoding the status.
	reason, _ := pricing["reason"].(string)
	if reason == "" {
		t.Fatalf("pricing.reason is empty: the refusal must say why")
	}

	// unmappedChecks is always allocated, never nil: nil marshals to `null` and an empty
	// slice to `[]`, and the shared shape promises one type per key on every route. This
	// refusal is not per-check, so it is empty here -- but it is still a list.
	if _, ok := pricing["unmappedChecks"].([]any); !ok {
		t.Errorf("pricing.unmappedChecks = %#v, want [] rather than null", pricing["unmappedChecks"])
	}

	// unpricedFields names what was withheld, by JSON name, so a client can tell
	// "withheld" from "this version has no such field" without consulting a schema.
	fields, ok := pricing["unpricedFields"].([]any)
	if !ok {
		t.Fatalf("pricing.unpricedFields = %#v, want a list", pricing["unpricedFields"])
	}
	named := map[string]bool{}
	for _, f := range fields {
		s, _ := f.(string)
		named[s] = true
	}
	for _, want := range []string{"ale", "var95", "previousAle", "trend"} {
		if !named[want] {
			t.Errorf("pricing.unpricedFields does not name %q, but that key was withheld", want)
		}
	}
}

// TestPricingAvailableIsDerivedFromStatus is the property the coordinator asked be
// preserved: `available` has exactly one source, the status. A field that can be set to
// contradict the status beside it is a fabrication waiting to happen, so the constructor
// must offer no way to write it.
func TestPricingAvailableIsDerivedFromStatus(t *testing.T) {
	p := newAuthoredNotComputedPricing("because", []string{"ale"})

	if p.Available != PricingStatusAuthoredNotComputed.Available() {
		t.Errorf("Available = %v, want the value the status implies", p.Available)
	}
	if p.Available {
		t.Errorf("a refusal reported Available = true")
	}
}

// TestAuthoredNotComputedIsADistinctStatus guards the third value against being collapsed
// into either of W6's two. The three causes demand different operator actions: declare a
// control mapping in the risk pack; put a priced scan behind the route; or build a fleet
// risk model at all. One label over three facts reads as authoritative precisely because
// it is uniform.
func TestAuthoredNotComputedIsADistinctStatus(t *testing.T) {
	third := PricingStatusAuthoredNotComputed

	if third == PricingStatusNoDeclaredLossFrequency {
		t.Errorf("the authored-figure refusal collapsed into NO_DECLARED_LOSS_FREQUENCY")
	}
	if third == PricingStatusNoRiskDataPlane {
		t.Errorf("the authored-figure refusal collapsed into NO_RISK_DATA_PLANE")
	}
	if third == PricingStatusPriced {
		t.Errorf("a refusal is equal to PRICED")
	}
	if third.Available() {
		t.Errorf("%q reports a figure as available", third)
	}
}

// TestAuthoredFiguresDoNotReachTheWireFromAnyConfig is the mutation-resistant form of the
// first test. The old contract test asserted ale == 847000 and, with a second config, that
// 11 and 22 came through -- so it required the authored numbers to be served and would have
// gone red on this fix. Here the same two configs must BOTH yield no money, which fails if
// anyone reconnects the config to the wire for either one.
func TestAuthoredFiguresDoNotReachTheWireFromAnyConfig(t *testing.T) {
	configs := []string{contractFleetYAML, `
aggregateRisk:
  ale: 11
  var95: 22
  trend: down
agents:
  - id: solo
    type: api-gateway
    team: t
    trustProfile: low
    dependencies: []
    namespace: ns
`}

	for i, cfg := range configs {
		body := topologyBody(t, cfg)
		risk := body["aggregateRisk"].(map[string]any)
		for _, key := range []string{"ale", "var95", "previousAle", "trend"} {
			if v, present := risk[key]; present {
				t.Errorf("config %d: aggregateRisk.%s = %#v reached the wire from authored config", i, key, v)
			}
		}
	}
}

// TestAuthoredRiskInputsStillParse keeps the authored values readable in the manifest. The
// fix withholds them from the API; it does not delete them from the config, because the
// numbers a previous version served are evidence and a future fleet risk model may want
// them as a declared input. Parsing them and not serving them is the deliberate state.
func TestAuthoredRiskInputsStillParse(t *testing.T) {
	d, err := ParseFleet([]byte(contractFleetYAML))
	if err != nil {
		t.Fatalf("ParseFleet: %v", err)
	}

	in := d.AuthoredRiskInputs()
	if in.ALE == nil || *in.ALE != 847000 {
		t.Errorf("AuthoredRiskInputs().ALE = %v, want the authored 847000 retained", in.ALE)
	}
	if in.Var95 == nil || *in.Var95 != 1200000 {
		t.Errorf("AuthoredRiskInputs().Var95 = %v, want the authored 1200000 retained", in.Var95)
	}
	if in.Trend != "up" {
		t.Errorf("AuthoredRiskInputs().Trend = %q, want the authored value retained", in.Trend)
	}
}

// TestAuthoredRiskInputsAreNotJSONSerialisable stops the retained inputs becoming the leak
// that undoes the fix. Keeping them in memory is only safe while nothing marshals them into
// a response, so the type carries no JSON tags that would put money on a wire.
func TestAuthoredRiskInputsAreNotJSONSerialisable(t *testing.T) {
	d, err := ParseFleet([]byte(contractFleetYAML))
	if err != nil {
		t.Fatalf("ParseFleet: %v", err)
	}

	b, err := json.Marshal(d.AuthoredRiskInputs())
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if got := string(b); got != "{}" {
		t.Errorf("AuthoredRiskInputs marshals to %s, want {}: the authored money must not be serialisable", got)
	}
}
