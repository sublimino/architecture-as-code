package main

import (
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

	// ale and var95 must be numbers. The Fleet page formats them as currency,
	// and a string renders as NaN rather than failing — so the TYPE is part of
	// the contract, not just the key.
	for _, key := range []string{"ale", "var95"} {
		if _, ok := risk[key].(float64); !ok {
			t.Errorf("aggregateRisk.%s = %#v, want a number", key, risk[key])
		}
	}

	switch risk["trend"] {
	case "up", "down", "stable":
	default:
		t.Errorf("aggregateRisk.trend = %#v, want one of up/down/stable", risk["trend"])
	}
}

func TestTopologyAggregateRiskComesFromFleetConfig(t *testing.T) {
	body := topologyBody(t, contractFleetYAML)
	risk := body["aggregateRisk"].(map[string]any)

	// The figures are authored demo data in the fleet ConfigMap, deliberately
	// not computed in Go. Serving them straight through is what makes them
	// reviewable and changeable without a rebuild; a hardcoded constant here
	// would be a risk figure invented in code, which is the failure mode this
	// repo has already shipped once. This test fails if anyone replaces the
	// config lookup with a literal.
	if risk["ale"].(float64) != 847000 {
		t.Errorf("aggregateRisk.ale = %v, want the value from the fleet config", risk["ale"])
	}
	if risk["var95"].(float64) != 1200000 {
		t.Errorf("aggregateRisk.var95 = %v, want the value from the fleet config", risk["var95"])
	}

	// A config with different figures must produce different output.
	other := topologyBody(t, `
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
	otherRisk := other["aggregateRisk"].(map[string]any)
	if otherRisk["ale"].(float64) != 11 || otherRisk["var95"].(float64) != 22 {
		t.Errorf("aggregateRisk ignores the fleet config: got %#v", otherRisk)
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
