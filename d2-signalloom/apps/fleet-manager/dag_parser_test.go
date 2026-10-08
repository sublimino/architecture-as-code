package main

import (
	"sync"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestDAG_Acyclic5NodeBaseline(t *testing.T) {
	agents := []Agent{
		{ID: "agent-cardvault", Name: "Card Vault", Type: "data-vault", Team: "platform", TrustProfile: "high", Dependencies: []string{}},
		{ID: "agent-txn-pipeline", Name: "Transaction Pipeline", Type: "data-pipeline", Team: "payments", TrustProfile: "medium", Dependencies: []string{"agent-cardvault"}},
		{ID: "agent-llm-classifier", Name: "LLM Classifier", Type: "llm-inference", Team: "ml-ops", TrustProfile: "high", Dependencies: []string{"agent-txn-pipeline"}},
		{ID: "agent-api-gateway", Name: "API Gateway", Type: "api-gateway", Team: "platform", TrustProfile: "medium", Dependencies: []string{"agent-cardvault"}},
		{ID: "agent-monitor", Name: "Monitor", Type: "observability", Team: "sre", TrustProfile: "low", Dependencies: []string{"agent-cardvault", "agent-txn-pipeline", "agent-llm-classifier", "agent-api-gateway"}},
	}

	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("unexpected error building 5-node acyclic DAG: %v", err)
	}

	hasCycle, cyclePath := dag.DetectCycle()
	if hasCycle {
		t.Fatalf("expected acyclic graph, got cycle: %s", cyclePath)
	}

	order, err := dag.DeploymentOrder()
	if err != nil {
		t.Fatalf("deployment order failed: %v", err)
	}

	if len(order) != 5 {
		t.Fatalf("expected 5 agents in deployment order, got %d", len(order))
	}

	// Verify order constraints:
	// cardvault must come before txn-pipeline and api-gateway
	// txn-pipeline must come before llm-classifier
	// all four must come before monitor
	indexMap := make(map[string]int)
	for i, id := range order {
		indexMap[id] = i
	}

	if indexMap["agent-cardvault"] > indexMap["agent-txn-pipeline"] {
		t.Errorf("agent-cardvault (%d) must precede agent-txn-pipeline (%d)", indexMap["agent-cardvault"], indexMap["agent-txn-pipeline"])
	}
	if indexMap["agent-cardvault"] > indexMap["agent-api-gateway"] {
		t.Errorf("agent-cardvault (%d) must precede agent-api-gateway (%d)", indexMap["agent-cardvault"], indexMap["agent-api-gateway"])
	}
	if indexMap["agent-txn-pipeline"] > indexMap["agent-llm-classifier"] {
		t.Errorf("agent-txn-pipeline (%d) must precede agent-llm-classifier (%d)", indexMap["agent-txn-pipeline"], indexMap["agent-llm-classifier"])
	}
	if indexMap["agent-monitor"] != 4 {
		t.Errorf("agent-monitor (%d) must be deployed last (index 4)", indexMap["agent-monitor"])
	}
}

func TestDAG_CycleRejection(t *testing.T) {
	testCases := []struct {
		name   string
		agents []Agent
	}{
		{
			name: "self-loop",
			agents: []Agent{
				{ID: "agent-a", Dependencies: []string{"agent-a"}},
			},
		},
		{
			name: "2-node direct cycle",
			agents: []Agent{
				{ID: "agent-a", Dependencies: []string{"agent-b"}},
				{ID: "agent-b", Dependencies: []string{"agent-a"}},
			},
		},
		{
			name: "3-node circular dependency",
			agents: []Agent{
				{ID: "agent-a", Dependencies: []string{"agent-b"}},
				{ID: "agent-b", Dependencies: []string{"agent-c"}},
				{ID: "agent-c", Dependencies: []string{"agent-a"}},
			},
		},
		{
			name: "cycle in disconnected subgraph",
			agents: []Agent{
				{ID: "agent-root", Dependencies: []string{}},
				{ID: "agent-worker", Dependencies: []string{"agent-root"}},
				{ID: "agent-x", Dependencies: []string{"agent-y"}},
				{ID: "agent-y", Dependencies: []string{"agent-x"}},
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			dag, err := BuildDAG(tc.agents)
			if err == nil {
				t.Fatalf("expected cycle error for %s, got nil (dag=%+v)", tc.name, dag)
			}
		})
	}
}

func TestDAG_MultiParentDiamond(t *testing.T) {
	// Diamond DAG:
	//       Root
	//      /    \
	//   Left    Right
	//      \    /
	//       Sink
	agents := []Agent{
		{ID: "agent-root", Dependencies: []string{}},
		{ID: "agent-left", Dependencies: []string{"agent-root"}},
		{ID: "agent-right", Dependencies: []string{"agent-root"}},
		{ID: "agent-sink", Dependencies: []string{"agent-left", "agent-right"}},
	}

	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	order, err := dag.TopologicalSort()
	if err != nil {
		t.Fatalf("topological sort failed: %v", err)
	}

	pos := make(map[string]int)
	for i, id := range order {
		pos[id] = i
	}

	if pos["agent-root"] != 0 {
		t.Errorf("agent-root must be position 0, got %d", pos["agent-root"])
	}
	if pos["agent-sink"] != 3 {
		t.Errorf("agent-sink must be position 3, got %d", pos["agent-sink"])
	}
	if pos["agent-left"] <= pos["agent-root"] || pos["agent-right"] <= pos["agent-root"] {
		t.Errorf("middle nodes must follow root")
	}
	if pos["agent-sink"] <= pos["agent-left"] || pos["agent-sink"] <= pos["agent-right"] {
		t.Errorf("sink must follow middle nodes")
	}
}

func TestDAG_DisconnectedComponents(t *testing.T) {
	// Component 1: A -> B
	// Component 2: C -> D
	agents := []Agent{
		{ID: "agent-a", Dependencies: []string{}},
		{ID: "agent-b", Dependencies: []string{"agent-a"}},
		{ID: "agent-c", Dependencies: []string{}},
		{ID: "agent-d", Dependencies: []string{"agent-c"}},
	}

	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("unexpected error on disconnected components: %v", err)
	}

	order, err := dag.DeploymentOrder()
	if err != nil {
		t.Fatalf("deployment order failed: %v", err)
	}

	if len(order) != 4 {
		t.Fatalf("expected 4 agents, got %d", len(order))
	}

	pos := make(map[string]int)
	for i, id := range order {
		pos[id] = i
	}

	if pos["agent-b"] < pos["agent-a"] {
		t.Errorf("agent-b must follow agent-a")
	}
	if pos["agent-d"] < pos["agent-c"] {
		t.Errorf("agent-d must follow agent-c")
	}
}

func TestDAG_ValidationErrors(t *testing.T) {
	// Duplicate ID
	_, err := BuildDAG([]Agent{
		{ID: "agent-dup", Dependencies: []string{}},
		{ID: "agent-dup", Dependencies: []string{}},
	})
	if err == nil {
		t.Errorf("expected error on duplicate ID")
	}

	// Missing dependency
	_, err = BuildDAG([]Agent{
		{ID: "agent-orphan", Dependencies: []string{"agent-nonexistent"}},
	})
	if err == nil {
		t.Errorf("expected error on nonexistent dependency")
	}
}

func TestDAG_AgentStateManagement(t *testing.T) {
	agents := []Agent{
		{ID: "agent-cardvault", State: AgentStateActive},
		{ID: "agent-txn-pipeline", Dependencies: []string{"agent-cardvault"}, State: AgentStateDeploying},
	}

	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("failed to build DAG: %v", err)
	}

	validStates := []string{
		AgentStateAbsent,
		AgentStateDeploying,
		AgentStateActive,
		AgentStateNonCompliant,
		AgentStateGracePeriod,
		AgentStateStunned,
	}

	for _, s := range validStates {
		if !IsValidAgentState(s) {
			t.Errorf("expected state %q to be valid", s)
		}
		if err := dag.SetAgentState("agent-cardvault", s); err != nil {
			t.Errorf("failed to set valid state %q: %v", s, err)
		}
		if a := dag.GetAgent("agent-cardvault"); a.State != s {
			t.Errorf("expected state %q, got %q", s, a.State)
		}
	}

	// Invalid state rejected
	if err := dag.SetAgentState("agent-cardvault", "invalid-state"); err == nil {
		t.Errorf("expected error setting invalid state")
	}
}

func TestDAG_ConcurrentReadWriteSafety(t *testing.T) {
	agents := []Agent{
		{ID: "agent-cardvault", Dependencies: []string{}},
		{ID: "agent-txn-pipeline", Dependencies: []string{"agent-cardvault"}},
		{ID: "agent-api-gateway", Dependencies: []string{"agent-cardvault"}},
		{ID: "agent-monitor", Dependencies: []string{"agent-cardvault", "agent-txn-pipeline", "agent-api-gateway"}},
	}

	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("failed to build DAG: %v", err)
	}

	var wg sync.WaitGroup
	workers := 20
	iterations := 50

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				// Concurrent reads
				_ = dag.AllAgents()
				_ = dag.AllNodes()
				_ = dag.Edges()
				_ = dag.GetAgent("agent-cardvault")
				_, _ = dag.DeploymentOrder()
				_, _ = dag.CascadeTargets("agent-cardvault")

				// Concurrent writes
				state := AgentStateActive
				if (workerID+j)%2 == 0 {
					state = AgentStateStunned
				}
				_ = dag.SetAgentState("agent-cardvault", state)
			}
		}(i)
	}

	wg.Wait()
}

func TestConfigMap_ParseAgentProfiles(t *testing.T) {
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "fleet-agent-profiles",
			Namespace: "fe-signalloom",
		},
		Data: map[string]string{
			"agent-cardvault.yaml": `
apiVersion: signalloom.controlplane.io/v1alpha1
kind: AgentProfile
metadata:
  name: agent-cardvault
  labels:
    signalloom.ai/team: platform
spec:
  type: data-vault
  trustProfile: high
  riskClass: high
  gracePeriod: 0h
  dependencies: []
`,
			"agent-txn-pipeline.yaml": `
apiVersion: signalloom.controlplane.io/v1alpha1
kind: AgentProfile
metadata:
  name: agent-txn-pipeline
  labels:
    signalloom.ai/team: payments
spec:
  type: data-pipeline
  trustProfile: medium
  riskClass: medium
  gracePeriod: 72h
  dependencies: [agent-cardvault]
`,
		},
	}

	dag, err := ParseFleetFromConfigMap(cm)
	if err != nil {
		t.Fatalf("failed to parse ConfigMap: %v", err)
	}

	if len(dag.AllAgents()) != 2 {
		t.Fatalf("expected 2 agents from ConfigMap, got %d", len(dag.AllAgents()))
	}

	cv := dag.GetAgent("agent-cardvault")
	if cv == nil || cv.Type != "data-vault" || cv.Team != "platform" {
		t.Errorf("agent-cardvault incorrectly parsed: %+v", cv)
	}

	txn := dag.GetAgent("agent-txn-pipeline")
	if txn == nil || len(txn.Dependencies) != 1 || txn.Dependencies[0] != "agent-cardvault" {
		t.Errorf("agent-txn-pipeline incorrectly parsed: %+v", txn)
	}
}
