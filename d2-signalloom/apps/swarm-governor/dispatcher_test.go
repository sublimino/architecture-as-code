// swarm-governor: dispatcher unit tests.
//
// TDD RED phase — defines the contract for task evaluation and dispatch:
//   - Simple tasks get dispatched to a single agent
//   - Complex tasks get split across multiple agents
//   - Token budget is enforced
//   - Missing agents produce an error, not a silent drop
//   - Agent capabilities are matched to task requirements
package main

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/swarm-governor/a2a"
)

func TestEvaluateComplexity_Simple(t *testing.T) {
	task := a2a.Task{
		ID:          "task-001",
		Description: "scan a single container image for CVEs",
	}

	level := EvaluateComplexity(task)
	if level != ComplexitySimple {
		t.Errorf("EvaluateComplexity=%v, want ComplexitySimple", level)
	}
}

func TestEvaluateComplexity_Complex(t *testing.T) {
	task := a2a.Task{
		ID:          "task-002",
		Description: "audit the full kubernetes cluster for RBAC misconfigurations, network policy gaps, and supply chain attestation failures across all namespaces",
	}

	level := EvaluateComplexity(task)
	if level != ComplexityComplex {
		t.Errorf("EvaluateComplexity=%v, want ComplexityComplex", level)
	}
}

func TestDispatch_SingleAgent(t *testing.T) {
	agents := []a2a.AgentCard{
		{
			Name:         "cve-scanner",
			URL:          "http://cve-scanner.fe-signalloom-agents.svc:8080",
			Capabilities: []a2a.Capability{{Name: "scan", Description: "container image CVE scanning"}},
		},
	}

	task := a2a.Task{
		ID:          "task-003",
		Description: "scan container image for CVEs",
		Requirements: []string{"scan"},
	}

	plan, err := Dispatch(task, agents, 100000)
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}
	if len(plan.Assignments) != 1 {
		t.Fatalf("Dispatch produced %d assignments, want 1", len(plan.Assignments))
	}
	if plan.Assignments[0].AgentName != "cve-scanner" {
		t.Errorf("assigned to %q, want %q", plan.Assignments[0].AgentName, "cve-scanner")
	}
}

func TestDispatch_MultipleAgents(t *testing.T) {
	agents := []a2a.AgentCard{
		{
			Name:         "cve-scanner",
			URL:          "http://cve-scanner.fe-signalloom-agents.svc:8080",
			Capabilities: []a2a.Capability{{Name: "scan", Description: "CVE scanning"}},
		},
		{
			Name:         "rbac-auditor",
			URL:          "http://rbac-auditor.fe-signalloom-agents.svc:8080",
			Capabilities: []a2a.Capability{{Name: "audit", Description: "RBAC auditing"}},
		},
	}

	task := a2a.Task{
		ID:           "task-004",
		Description:  "full security audit",
		Requirements: []string{"scan", "audit"},
	}

	plan, err := Dispatch(task, agents, 250000)
	if err != nil {
		t.Fatalf("Dispatch failed: %v", err)
	}
	if len(plan.Assignments) != 2 {
		t.Fatalf("Dispatch produced %d assignments, want 2", len(plan.Assignments))
	}
}

func TestDispatch_BudgetExceeded(t *testing.T) {
	agents := []a2a.AgentCard{
		{
			Name:         "cve-scanner",
			URL:          "http://cve-scanner.fe-signalloom-agents.svc:8080",
			Capabilities: []a2a.Capability{{Name: "scan", Description: "CVE scanning"}},
		},
	}

	task := a2a.Task{
		ID:           "task-005",
		Description:  "scan container image",
		Requirements: []string{"scan"},
	}

	// Budget of 0 tokens — should fail.
	_, err := Dispatch(task, agents, 0)
	if err == nil {
		t.Fatal("Dispatch should fail with zero budget")
	}
}

func TestDispatch_NoMatchingAgent(t *testing.T) {
	agents := []a2a.AgentCard{
		{
			Name:         "cve-scanner",
			URL:          "http://cve-scanner.fe-signalloom-agents.svc:8080",
			Capabilities: []a2a.Capability{{Name: "scan", Description: "CVE scanning"}},
		},
	}

	task := a2a.Task{
		ID:           "task-006",
		Description:  "deploy to production",
		Requirements: []string{"deploy"},
	}

	_, err := Dispatch(task, agents, 100000)
	if err == nil {
		t.Fatal("Dispatch should fail when no agent matches requirements")
	}
}
