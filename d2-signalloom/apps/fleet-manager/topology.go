package main

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Agent represents a single agent in the fleet topology.
type Agent struct {
	ID           string   `json:"id" yaml:"id"`
	Type         string   `json:"type" yaml:"type"`
	Team         string   `json:"team" yaml:"team"`
	TrustProfile string   `json:"trustProfile" yaml:"trustProfile"`
	RiskClass    string   `json:"riskClass" yaml:"riskClass"`
	GracePeriod  string   `json:"gracePeriod" yaml:"gracePeriod"`
	Dependencies []string `json:"dependencies" yaml:"dependencies"`
	Namespace    string   `json:"namespace" yaml:"namespace"`
	State        string   `json:"state,omitempty" yaml:"-"`
}

// FleetConfig is the top-level YAML structure.
type FleetConfig struct {
	Agents []Agent `yaml:"agents"`
}

// DAG holds the agent dependency graph and provides traversal methods.
type DAG struct {
	agents   map[string]*Agent
	// forward edges: agent -> agents it depends on
	deps map[string][]string
	// reverse edges: agent -> agents that depend on it
	rdeps map[string][]string
	// ordered list of agent IDs (insertion order)
	order []string
}

// LoadFleet reads the fleet YAML from a file path and returns a DAG.
func LoadFleet(path string) (*DAG, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read fleet config: %w", err)
	}
	return ParseFleet(data)
}

// ParseFleet parses fleet YAML bytes into a DAG.
func ParseFleet(data []byte) (*DAG, error) {
	var cfg FleetConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse fleet config: %w", err)
	}
	return BuildDAG(cfg.Agents)
}

// BuildDAG constructs a DAG from a list of agents. Returns an error if:
// - duplicate agent IDs are found
// - a dependency references a non-existent agent
// - the graph contains a cycle
func BuildDAG(agents []Agent) (*DAG, error) {
	d := &DAG{
		agents: make(map[string]*Agent, len(agents)),
		deps:   make(map[string][]string, len(agents)),
		rdeps:  make(map[string][]string, len(agents)),
		order:  make([]string, 0, len(agents)),
	}

	for i := range agents {
		a := &agents[i]
		if _, exists := d.agents[a.ID]; exists {
			return nil, fmt.Errorf("duplicate agent ID: %s", a.ID)
		}
		d.agents[a.ID] = a
		d.order = append(d.order, a.ID)
	}

	for _, a := range agents {
		for _, dep := range a.Dependencies {
			if _, exists := d.agents[dep]; !exists {
				return nil, fmt.Errorf("agent %q depends on unknown agent %q", a.ID, dep)
			}
			d.deps[a.ID] = append(d.deps[a.ID], dep)
			d.rdeps[dep] = append(d.rdeps[dep], a.ID)
		}
	}

	if cycle := d.detectCycle(); cycle != "" {
		return nil, fmt.Errorf("cycle detected: %s", cycle)
	}

	return d, nil
}

// detectCycle uses DFS-based cycle detection, returning a description of the
// cycle if one exists, or "" if the graph is acyclic.
func (d *DAG) detectCycle() string {
	const (
		white = 0
		grey  = 1
		black = 2
	)
	color := make(map[string]int, len(d.agents))

	var visit func(id string) string
	visit = func(id string) string {
		color[id] = grey
		for _, dep := range d.deps[id] {
			switch color[dep] {
			case grey:
				return fmt.Sprintf("%s -> %s", id, dep)
			case white:
				if c := visit(dep); c != "" {
					return c
				}
			}
		}
		color[id] = black
		return ""
	}

	for _, id := range d.order {
		if color[id] == white {
			if c := visit(id); c != "" {
				return c
			}
		}
	}
	return ""
}

// CascadeTargets returns the set of agents that must be stunned when the given
// agent is stunned. This is the target agent plus all agents that transitively
// depend on it (BFS on reverse edges). Agents with type "observability" are
// excluded from the cascade (they stay alive to observe).
//
// The result is ordered: target first, then direct dependants, then transitive.
func (d *DAG) CascadeTargets(agentID string) ([]string, error) {
	if _, exists := d.agents[agentID]; !exists {
		return nil, fmt.Errorf("unknown agent: %s", agentID)
	}

	var result []string
	visited := make(map[string]bool)

	// BFS from the target on reverse edges
	queue := []string{agentID}
	visited[agentID] = true

	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]

		// Skip observability agents (they are read-only watchers)
		if d.agents[current].Type == "observability" && current != agentID {
			continue
		}

		result = append(result, current)

		for _, rdep := range d.rdeps[current] {
			if !visited[rdep] {
				visited[rdep] = true
				queue = append(queue, rdep)
			}
		}
	}

	return result, nil
}

// RecoveryOrder returns the topological order for recovering stunned agents.
// Root-ward agents come first (agents with no dependencies among the stunned set),
// then their dependants. This ensures each agent's upstream is healthy before
// it is recovered.
func (d *DAG) RecoveryOrder(stunnedIDs []string) []string {
	stunSet := make(map[string]bool, len(stunnedIDs))
	for _, id := range stunnedIDs {
		stunSet[id] = true
	}

	// Kahn's algorithm on the subgraph of stunned agents
	// In-degree: count of dependencies that are also stunned
	inDegree := make(map[string]int, len(stunnedIDs))
	for _, id := range stunnedIDs {
		count := 0
		for _, dep := range d.deps[id] {
			if stunSet[dep] {
				count++
			}
		}
		inDegree[id] = count
	}

	var queue []string
	for _, id := range stunnedIDs {
		if inDegree[id] == 0 {
			queue = append(queue, id)
		}
	}

	var order []string
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		order = append(order, current)

		for _, rdep := range d.rdeps[current] {
			if stunSet[rdep] {
				inDegree[rdep]--
				if inDegree[rdep] == 0 {
					queue = append(queue, rdep)
				}
			}
		}
	}

	return order
}

// GetAgent returns the agent with the given ID, or nil if not found.
func (d *DAG) GetAgent(id string) *Agent {
	return d.agents[id]
}

// AllAgents returns all agents in insertion order.
func (d *DAG) AllAgents() []*Agent {
	result := make([]*Agent, 0, len(d.order))
	for _, id := range d.order {
		result = append(result, d.agents[id])
	}
	return result
}
