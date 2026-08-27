// swarm-governor: task complexity evaluation and dispatch logic.
//
// Evaluates incoming tasks for complexity (simple vs complex) based on
// description length and requirement count, then matches agent capabilities
// to task requirements and assigns token budgets per agent.
package main

import (
	"fmt"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/swarm-governor/a2a"
)

// Complexity represents the estimated complexity of a task.
type Complexity int

const (
	ComplexitySimple  Complexity = iota
	ComplexityComplex
)

func (c Complexity) String() string {
	switch c {
	case ComplexitySimple:
		return "simple"
	case ComplexityComplex:
		return "complex"
	default:
		return "unknown"
	}
}

// Assignment maps a sub-task to an agent with a token budget.
type Assignment struct {
	AgentName   string   `json:"agent_name"`
	AgentURL    string   `json:"agent_url"`
	SubTask     a2a.Task `json:"sub_task"`
	TokenBudget int      `json:"token_budget"`
}

// DispatchPlan is the result of dispatching a task to agents.
type DispatchPlan struct {
	OriginalTask a2a.Task     `json:"original_task"`
	Complexity   Complexity   `json:"complexity"`
	Assignments  []Assignment `json:"assignments"`
	TotalBudget  int          `json:"total_budget"`
}

// complexityThresholds control when a task is considered complex.
const (
	descriptionLengthThreshold = 100 // characters
	requirementCountThreshold  = 2   // number of distinct requirements
)

// EvaluateComplexity scores a task as simple or complex.
//
// A task is complex if:
//   - Its description exceeds 100 characters, OR
//   - It has more than 1 distinct requirement
func EvaluateComplexity(task a2a.Task) Complexity {
	if len(task.Description) > descriptionLengthThreshold {
		return ComplexityComplex
	}
	if len(task.Requirements) > requirementCountThreshold {
		return ComplexityComplex
	}
	return ComplexitySimple
}

// Dispatch evaluates a task and assigns it to matching agents.
//
// For simple tasks, a single agent is selected. For complex tasks,
// work is split across multiple agents by requirement. Each agent
// receives an equal share of the total token budget.
//
// Returns an error if:
//   - The budget is zero or negative
//   - No agent matches a required capability
func Dispatch(task a2a.Task, agents []a2a.AgentCard, maxTokenBudget int) (*DispatchPlan, error) {
	if maxTokenBudget <= 0 {
		return nil, fmt.Errorf("token budget must be positive, got %d", maxTokenBudget)
	}

	complexity := EvaluateComplexity(task)

	// Build a capability index: capability name -> list of agents.
	capIndex := make(map[string][]a2a.AgentCard)
	for _, agent := range agents {
		for _, cap := range agent.Capabilities {
			capIndex[strings.ToLower(cap.Name)] = append(capIndex[strings.ToLower(cap.Name)], agent)
		}
	}

	// If no requirements specified, match any agent.
	requirements := task.Requirements
	if len(requirements) == 0 {
		if len(agents) == 0 {
			return nil, fmt.Errorf("no agents available")
		}
		requirements = []string{strings.ToLower(agents[0].Capabilities[0].Name)}
	}

	// Match requirements to agents.
	var assignments []Assignment
	seen := make(map[string]bool)

	for _, req := range requirements {
		matching, ok := capIndex[strings.ToLower(req)]
		if !ok || len(matching) == 0 {
			return nil, fmt.Errorf("no agent with capability %q for task %s", req, task.ID)
		}

		// Pick the first matching agent not already assigned (for diversity).
		var selected a2a.AgentCard
		found := false
		for _, candidate := range matching {
			if !seen[candidate.Name] {
				selected = candidate
				found = true
				break
			}
		}
		if !found {
			// All matching agents already assigned; reuse the first.
			selected = matching[0]
		}
		seen[selected.Name] = true

		assignments = append(assignments, Assignment{
			AgentName: selected.Name,
			AgentURL:  selected.URL,
			SubTask: a2a.Task{
				ID:           fmt.Sprintf("%s-%s", task.ID, req),
				Description:  fmt.Sprintf("[%s] %s", req, task.Description),
				Requirements: []string{req},
				Input:        task.Input,
				Metadata:     task.Metadata,
			},
		})
	}

	// Distribute budget evenly.
	budgetPerAgent := maxTokenBudget / len(assignments)
	for i := range assignments {
		assignments[i].TokenBudget = budgetPerAgent
	}

	return &DispatchPlan{
		OriginalTask: task,
		Complexity:   complexity,
		Assignments:  assignments,
		TotalBudget:  maxTokenBudget,
	}, nil
}
