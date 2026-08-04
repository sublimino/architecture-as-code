package main

import (
	"testing"
)

func testFleetYAML() []byte {
	return []byte(`
agents:
  - id: agent-cardvault
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
  - id: agent-llm-classifier
    type: llm-inference
    team: ml-ops
    trustProfile: high
    riskClass: high
    gracePeriod: 0h
    dependencies: [agent-txn-pipeline]
    namespace: fe-signalloom-agents
  - id: agent-api-gateway
    type: api-gateway
    team: platform
    trustProfile: medium
    riskClass: medium
    gracePeriod: 24h
    dependencies: [agent-cardvault]
    namespace: fe-signalloom-agents
  - id: agent-monitor
    type: observability
    team: sre
    trustProfile: low
    riskClass: low
    gracePeriod: 0h
    dependencies: [agent-cardvault, agent-txn-pipeline, agent-llm-classifier, agent-api-gateway]
    namespace: fe-signalloom-agents
`)
}

func mustBuildTestDAG(t *testing.T) *DAG {
	t.Helper()
	dag, err := ParseFleet(testFleetYAML())
	if err != nil {
		t.Fatalf("failed to parse fleet YAML: %v", err)
	}
	return dag
}

func TestParseFleet_ValidConfig(t *testing.T) {
	dag := mustBuildTestDAG(t)

	agents := dag.AllAgents()
	if len(agents) != 5 {
		t.Fatalf("expected 5 agents, got %d", len(agents))
	}

	cardvault := dag.GetAgent("agent-cardvault")
	if cardvault == nil {
		t.Fatal("agent-cardvault not found")
	}
	if cardvault.Type != "data-vault" {
		t.Fatalf("expected type data-vault, got %q", cardvault.Type)
	}
	if cardvault.Team != "platform" {
		t.Fatalf("expected team platform, got %q", cardvault.Team)
	}
}

func TestParseFleet_DuplicateID(t *testing.T) {
	data := []byte(`
agents:
  - id: agent-a
    type: test
    team: t
    trustProfile: low
    riskClass: low
    gracePeriod: 0h
    dependencies: []
    namespace: ns
  - id: agent-a
    type: test
    team: t
    trustProfile: low
    riskClass: low
    gracePeriod: 0h
    dependencies: []
    namespace: ns
`)
	_, err := ParseFleet(data)
	if err == nil {
		t.Fatal("expected error for duplicate IDs")
	}
}

func TestParseFleet_UnknownDependency(t *testing.T) {
	data := []byte(`
agents:
  - id: agent-a
    type: test
    team: t
    trustProfile: low
    riskClass: low
    gracePeriod: 0h
    dependencies: [agent-nonexistent]
    namespace: ns
`)
	_, err := ParseFleet(data)
	if err == nil {
		t.Fatal("expected error for unknown dependency")
	}
}

func TestParseFleet_CycleDetection(t *testing.T) {
	data := []byte(`
agents:
  - id: agent-a
    type: test
    team: t
    trustProfile: low
    riskClass: low
    gracePeriod: 0h
    dependencies: [agent-b]
    namespace: ns
  - id: agent-b
    type: test
    team: t
    trustProfile: low
    riskClass: low
    gracePeriod: 0h
    dependencies: [agent-a]
    namespace: ns
`)
	_, err := ParseFleet(data)
	if err == nil {
		t.Fatal("expected error for cycle")
	}
}

func TestCascadeTargets_RootAgent(t *testing.T) {
	dag := mustBuildTestDAG(t)

	// Stunning the root (agent-cardvault) should cascade to everything
	// except agent-monitor (type: observability)
	targets, err := dag.CascadeTargets("agent-cardvault")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	targetSet := make(map[string]bool)
	for _, id := range targets {
		targetSet[id] = true
	}

	// Should include the root and all non-observability dependants
	expected := []string{"agent-cardvault", "agent-txn-pipeline", "agent-llm-classifier", "agent-api-gateway"}
	for _, id := range expected {
		if !targetSet[id] {
			t.Fatalf("expected %q in cascade targets", id)
		}
	}

	// Should NOT include agent-monitor (observability type)
	if targetSet["agent-monitor"] {
		t.Fatal("agent-monitor (observability) should be excluded from cascade")
	}

	// First target should be the stunned agent itself
	if targets[0] != "agent-cardvault" {
		t.Fatalf("expected first target to be agent-cardvault, got %q", targets[0])
	}
}

func TestCascadeTargets_LeafAgent(t *testing.T) {
	dag := mustBuildTestDAG(t)

	// Stunning a leaf (agent-llm-classifier) should only cascade to itself
	targets, err := dag.CascadeTargets("agent-llm-classifier")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// agent-monitor depends on it but is observability type, so excluded
	if len(targets) != 1 {
		t.Fatalf("expected 1 target, got %d: %v", len(targets), targets)
	}
	if targets[0] != "agent-llm-classifier" {
		t.Fatalf("expected agent-llm-classifier, got %q", targets[0])
	}
}

func TestCascadeTargets_MidLevel(t *testing.T) {
	dag := mustBuildTestDAG(t)

	// Stunning agent-txn-pipeline should cascade to itself + agent-llm-classifier
	targets, err := dag.CascadeTargets("agent-txn-pipeline")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	targetSet := make(map[string]bool)
	for _, id := range targets {
		targetSet[id] = true
	}

	if !targetSet["agent-txn-pipeline"] {
		t.Fatal("expected agent-txn-pipeline in targets")
	}
	if !targetSet["agent-llm-classifier"] {
		t.Fatal("expected agent-llm-classifier in targets")
	}
	if targetSet["agent-cardvault"] {
		t.Fatal("agent-cardvault should not be in cascade (it's upstream)")
	}
	if targetSet["agent-api-gateway"] {
		t.Fatal("agent-api-gateway should not be in cascade (different branch)")
	}
}

func TestCascadeTargets_UnknownAgent(t *testing.T) {
	dag := mustBuildTestDAG(t)

	_, err := dag.CascadeTargets("nonexistent")
	if err == nil {
		t.Fatal("expected error for unknown agent")
	}
}

func TestCascadeTargets_ObservabilityAgentItself(t *testing.T) {
	dag := mustBuildTestDAG(t)

	// If we stun the observability agent directly, it should be in the targets
	// (the exclusion only applies to dependants, not the target itself)
	targets, err := dag.CascadeTargets("agent-monitor")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(targets) != 1 || targets[0] != "agent-monitor" {
		t.Fatalf("expected [agent-monitor], got %v", targets)
	}
}

func TestRecoveryOrder_FullFleet(t *testing.T) {
	dag := mustBuildTestDAG(t)

	stunned := []string{"agent-cardvault", "agent-txn-pipeline", "agent-llm-classifier", "agent-api-gateway"}
	order := dag.RecoveryOrder(stunned)

	if len(order) != 4 {
		t.Fatalf("expected 4 agents in recovery order, got %d", len(order))
	}

	// Build position map
	pos := make(map[string]int)
	for i, id := range order {
		pos[id] = i
	}

	// agent-cardvault has no stunned dependencies, should be first
	if pos["agent-cardvault"] != 0 {
		t.Fatalf("expected agent-cardvault first, got position %d", pos["agent-cardvault"])
	}

	// agent-txn-pipeline depends on agent-cardvault: must come after
	if pos["agent-txn-pipeline"] <= pos["agent-cardvault"] {
		t.Fatal("agent-txn-pipeline must come after agent-cardvault")
	}

	// agent-llm-classifier depends on agent-txn-pipeline: must come after
	if pos["agent-llm-classifier"] <= pos["agent-txn-pipeline"] {
		t.Fatal("agent-llm-classifier must come after agent-txn-pipeline")
	}

	// agent-api-gateway depends on agent-cardvault: must come after
	if pos["agent-api-gateway"] <= pos["agent-cardvault"] {
		t.Fatal("agent-api-gateway must come after agent-cardvault")
	}
}

func TestRecoveryOrder_Partial(t *testing.T) {
	dag := mustBuildTestDAG(t)

	// Only txn-pipeline and llm-classifier are stunned
	stunned := []string{"agent-txn-pipeline", "agent-llm-classifier"}
	order := dag.RecoveryOrder(stunned)

	if len(order) != 2 {
		t.Fatalf("expected 2, got %d", len(order))
	}

	// txn-pipeline has no stunned dependencies (cardvault is healthy), so it goes first
	if order[0] != "agent-txn-pipeline" {
		t.Fatalf("expected agent-txn-pipeline first, got %q", order[0])
	}
	if order[1] != "agent-llm-classifier" {
		t.Fatalf("expected agent-llm-classifier second, got %q", order[1])
	}
}

func TestRecoveryOrder_Empty(t *testing.T) {
	dag := mustBuildTestDAG(t)

	order := dag.RecoveryOrder(nil)
	if len(order) != 0 {
		t.Fatalf("expected empty recovery order, got %v", order)
	}
}

func TestAllAgents_PreservesOrder(t *testing.T) {
	dag := mustBuildTestDAG(t)

	agents := dag.AllAgents()
	expectedOrder := []string{"agent-cardvault", "agent-txn-pipeline", "agent-llm-classifier", "agent-api-gateway", "agent-monitor"}
	for i, a := range agents {
		if a.ID != expectedOrder[i] {
			t.Fatalf("expected agent %q at position %d, got %q", expectedOrder[i], i, a.ID)
		}
	}
}

func TestGetAgent_NotFound(t *testing.T) {
	dag := mustBuildTestDAG(t)
	if dag.GetAgent("nonexistent") != nil {
		t.Fatal("expected nil for nonexistent agent")
	}
}
