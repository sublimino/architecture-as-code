package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The consumer contract for GET /api/v1/fleet/topology is the `FleetTopology`
// interface in apps/dashboard-signalloom/src/api/fleetApi.ts. These tests
// assert the wire format against that interface rather than against whatever
// the handler currently emits.
//
// They were written after the endpoint was finally reachable and answered 200
// with a body the client could not use: `agents` and `edges` only, no
// `aggregateRisk` and no `cascadeHistory`, and every agent missing `name` and
// `state`. That does not throw. FleetDemoPage.tsx:328 defaults a missing
// aggregateRisk to `{ale: 0, var95: 0}` and the roster counts every state as
// zero, so the Fleet page renders a fully-populated, entirely believable,
// completely wrong picture: a fleet of unnamed agents in no state carrying no
// risk. A 200 with the wrong shape is worse than a 502, because nothing in the
// UI reports it.

const contractFleetYAML = `
aggregateRisk:
  ale: 847000
  var95: 1200000
  trend: up
  previousAle: 650000
agents:
  - id: agent-cardvault
    name: Card Vault
    type: data-vault
    team: platform
    trustProfile: high
    riskClass: high
    gracePeriod: 0h
    dependencies: []
    namespace: fe-signalloom-agents
  - id: agent-txn-pipeline
    type: data-pipeline
    team: payments
    trustProfile: medium
    riskClass: medium
    gracePeriod: 72h
    dependencies: [agent-cardvault]
    namespace: fe-signalloom-agents
`

// topologyBody drives the real handler and returns the decoded JSON body.
func topologyBody(t *testing.T, fleetYAML string) map[string]any {
	t.Helper()

	dag, err := ParseFleet([]byte(fleetYAML))
	if err != nil {
		t.Fatalf("ParseFleet: %v", err)
	}
	s := &server{dag: dag}

	rec := httptest.NewRecorder()
	s.handleTopology(rec, httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response is not JSON: %v (body %q)", err, rec.Body.String())
	}
	return body
}

func TestTopologyCarriesEveryFleetTopologyKey(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	// All four are non-optional in the FleetTopology interface.
	for _, key := range []string{"agents", "edges", "aggregateRisk", "cascadeHistory"} {
		if _, ok := body[key]; !ok {
			t.Errorf("response has no %q key; FleetTopology declares it non-optional", key)
		}
	}
}

func TestTopologyArraysAreNeverNull(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	// A nil Go slice marshals to `null`, not `[]`. The client maps over these
	// directly, so `null` is a runtime error on a response that looks fine.
	for _, key := range []string{"agents", "edges", "cascadeHistory"} {
		if _, ok := body[key].([]any); !ok {
			t.Errorf("%q = %#v, want a JSON array (a nil slice marshals to null)", key, body[key])
		}
	}
}

func TestTopologyAgentsCarryRequiredAgentStateFields(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	agents, ok := body["agents"].([]any)
	if !ok || len(agents) == 0 {
		t.Fatalf("agents = %#v, want a non-empty array", body["agents"])
	}

	// fleetApi.ts: interface AgentState. gracePeriod and riskClass are declared
	// optional and are deliberately not required here.
	required := []string{"id", "name", "type", "team", "trustProfile", "state"}
	for i, raw := range agents {
		agent, ok := raw.(map[string]any)
		if !ok {
			t.Fatalf("agents[%d] is not an object: %#v", i, raw)
		}
		for _, key := range required {
			v, present := agent[key]
			if !present || v == "" {
				t.Errorf("agents[%d] (%v) has no non-empty %q; AgentState requires it",
					i, agent["id"], key)
			}
		}
	}
}

func TestTopologyAgentNameDefaultsToIDWhenUnset(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	agents := body["agents"].([]any)
	byID := map[string]map[string]any{}
	for _, raw := range agents {
		a := raw.(map[string]any)
		byID[a["id"].(string)] = a
	}

	// An authored name is preserved verbatim.
	if got := byID["agent-cardvault"]["name"]; got != "Card Vault" {
		t.Errorf("authored name = %v, want %q", got, "Card Vault")
	}

	// An agent with no authored name falls back to its ID rather than to "".
	// Empty is the dangerous outcome: FleetTopology.tsx:145 renders {agent.name}
	// into the node label, so a blank renders an unlabelled graph rather than
	// an error.
	if got := byID["agent-txn-pipeline"]["name"]; got != "agent-txn-pipeline" {
		t.Errorf("defaulted name = %v, want the agent ID", got)
	}
}

func TestTopologyAgentStateIsAClientKnownValue(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	// fleetApi.ts: type AgentStateValue. Anything outside this set fails
	// stateToken()/stateColour() lookups and renders an uncoloured badge.
	valid := map[string]bool{
		"absent": true, "deploying": true, "active": true,
		"non-compliant": true, "grace-period": true, "stunned": true,
	}
	for _, raw := range body["agents"].([]any) {
		a := raw.(map[string]any)
		state, _ := a["state"].(string)
		if !valid[state] {
			t.Errorf("agent %v has state %q, which is not an AgentStateValue", a["id"], state)
		}
	}
}

func TestTopologyAggregateRiskMatchesRiskSummary(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	risk, ok := body["aggregateRisk"].(map[string]any)
	if !ok {
		t.Fatalf("aggregateRisk = %#v, want an object", body["aggregateRisk"])
	}

	// ale and var95 used to be REQUIRED to be numbers here, on the reasoning that the
	// Fleet page formats them as currency and a string would render as NaN — so the
	// type, not just the key, was part of the contract. That reasoning was sound about
	// the client and wrong about the figure: the only numbers available to satisfy it
	// were authored in fleet.yaml, so this assertion is what kept an authored figure
	// flowing to a risk gauge. It is inverted rather than relaxed. The keys must now be
	// ABSENT, and the response must say why in the shared refusal object.
	//
	// Absent and not zero: FleetDemoPage.tsx:328 defaults a missing aggregateRisk to
	// zeros, which is the failure this file was originally written to catch. That is why
	// `pricing` is mandatory below — the client needs something it cannot mistake for a
	// measurement, rather than merely nothing.
	for _, key := range []string{"ale", "var95", "previousAle", "trend"} {
		if v, present := risk[key]; present {
			t.Errorf("aggregateRisk.%s = %#v, want absent: no computation stands behind it", key, v)
		}
	}

	pricing, ok := risk["pricing"].(map[string]any)
	if !ok {
		t.Fatalf("aggregateRisk.pricing = %#v, want the shared refusal object", risk["pricing"])
	}
	for _, key := range []string{"available", "status", "reason", "unpricedFields", "unmappedChecks"} {
		if _, present := pricing[key]; !present {
			t.Errorf("aggregateRisk.pricing.%s is missing from the shared shape", key)
		}
	}
}

// TestTopologyAggregateRiskDoesNotComeFromFleetConfig replaces a test that asserted the
// exact opposite, and the inversion is the fix rather than a weakening.
//
// It used to require aggregateRisk.ale == 847000 and, with a second config, that 11 and 22
// came through — on the reasoning that serving the authored config kept the figures
// reviewable and that a hardcoded constant here would be a figure invented in code. The
// second half of that reasoning was right and is still enforced below. The first half was
// wrong: it made "the authored number reaches the client" a thing the suite REQUIRED, so
// the test could only pass while an authored figure was being presented as a measurement
// on a risk gauge. A literal in Go and a literal in YAML are the same fabrication; the
// manifest only makes it reviewable, not computed.
//
// So the assertion is now that NO figure from the config reaches the wire, from either
// config. That still fails if anyone hardcodes a number here — a constant would show up as
// a present key — and it additionally fails if anyone reconnects the manifest to the
// response, which the old test demanded.
func TestTopologyAggregateRiskDoesNotComeFromFleetConfig(t *testing.T) {
	// Two configs with different authored figures must be indistinguishable on the wire.
	// If either number were being served, these two bodies would differ.
	first := topologyBody(t, contractFleetYAML)
	second := topologyBody(t, `
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
`)

	firstRisk, err := json.Marshal(first["aggregateRisk"])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	secondRisk, err := json.Marshal(second["aggregateRisk"])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	if string(firstRisk) != string(secondRisk) {
		t.Errorf("aggregateRisk differs between two configs with different authored figures:\n"+
			" 847000/1200000 -> %s\n      11/22 -> %s\n"+
			"the authored numbers are reaching the client", firstRisk, secondRisk)
	}

	// And neither of the authored values appears anywhere in the response, in any field.
	// Belt and braces against a figure arriving under a key this test did not think to
	// check — including one a future edit adds.
	whole, err := json.Marshal(first)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, authored := range []string{"847000", "1200000", "650000"} {
		if bytes.Contains(whole, []byte(authored)) {
			t.Errorf("authored figure %s appears in the topology response: %s", authored, whole)
		}
	}
}

func TestTopologyEdgesPointFromDependentToDependency(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)

	edges, _ := body["edges"].([]any)
	if len(edges) != 1 {
		t.Fatalf("edges = %#v, want exactly one", edges)
	}
	e := edges[0].(map[string]any)
	if e["from"] != "agent-txn-pipeline" || e["to"] != "agent-cardvault" {
		t.Errorf("edge = %#v, want agent-txn-pipeline -> agent-cardvault", e)
	}
}
