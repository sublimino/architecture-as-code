package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

// DefaultAgentState is the state an agent is reported in when the fleet config
// does not say otherwise.
//
// "active" and not "": fleetApi.ts declares AgentState.state non-optional and
// types it as AgentStateValue, so an empty string is not a member of the union.
// The dashboard does not reject it: stateToken()/stateColour() simply miss,
// every roster count lands on zero, and the Fleet page renders a fleet in no
// state at all. A believable wrong answer is the failure mode to design out.
const DefaultAgentState = "active"

// Standard AgentStateValue constants matching TypeScript definitions.
const (
	AgentStateAbsent       = "absent"
	AgentStateDeploying    = "deploying"
	AgentStateActive       = "active"
	AgentStateNonCompliant = "non-compliant"
	AgentStateGracePeriod  = "grace-period"
	AgentStateStunned      = "stunned"
)

// IsValidAgentState checks if a state string is one of the recognized AgentStateValue options.
func IsValidAgentState(state string) bool {
	switch state {
	case AgentStateAbsent, AgentStateDeploying, AgentStateActive,
		AgentStateNonCompliant, AgentStateGracePeriod, AgentStateStunned:
		return true
	default:
		return false
	}
}

// AgentProfile represents a single agent in the fleet topology with identity,
// governance, and trust boundary configuration.
type AgentProfile struct {
	ID string `json:"id" yaml:"id"`
	// Name is the human label the topology graph renders (FleetTopology.tsx:145).
	// Defaulted to ID by BuildDAG when the config omits it, because a blank here
	// draws an unlabelled node rather than raising anything.
	Name              string   `json:"name" yaml:"name"`
	Type              string   `json:"type" yaml:"type"`
	Team              string   `json:"team" yaml:"team"`
	TrustProfile      string   `json:"trustProfile" yaml:"trustProfile"`
	RiskClass         string   `json:"riskClass" yaml:"riskClass"`
	GracePeriod       string   `json:"gracePeriod" yaml:"gracePeriod"`
	Dependencies      []string `json:"dependencies" yaml:"dependencies"`
	Namespace         string   `json:"namespace" yaml:"namespace"`
	// No omitempty: the client requires this key to be present. With omitempty
	// an unset state vanished from the wire entirely, which is how the Fleet
	// page came to render agents with no state and counts of zero.
	State             string   `json:"state" yaml:"state"`
	DataSensitivity   string   `json:"dataSensitivity,omitempty" yaml:"dataSensitivity,omitempty"`
	GracePeriodExpiry string   `json:"gracePeriodExpiry,omitempty" yaml:"gracePeriodExpiry,omitempty"`
	RemainingHours    float64  `json:"remainingHours,omitempty" yaml:"remainingHours,omitempty"`
}

// Agent is an alias for AgentProfile for compatibility across the codebase.
type Agent = AgentProfile

// RiskSummary is the aggregate fleet risk the dashboard renders as currency.
// Mirrors the RiskSummary interface in fleetApi.ts.
//
// These figures are AUTHORED DEMO DATA read straight from the fleet ConfigMap,
// and deliberately not computed here. There is no fleet risk model in this
// repository — risk/ and tools/riskctl model CVE baselines for components, not
// agent fleets — so any number this service derived would be a risk figure
// invented in code. Serving authored config keeps the figures reviewable in a
// manifest and changeable without a rebuild.
type RiskSummary struct {
	ALE   float64 `json:"ale" yaml:"ale"`
	Var95 float64 `json:"var95" yaml:"var95"`
	Trend string  `json:"trend" yaml:"trend"`
	// Pointer + omitempty: previousAle is the one optional member of the client
	// interface, and a plain float64 would put a spurious 0 on the wire.
	PreviousALE *float64 `json:"previousAle,omitempty" yaml:"previousAle"`
}

// Node represents an agent node in the topology DAG with adjacency relationships.
type Node struct {
	ID      string   `json:"id" yaml:"id"`
	Agent   *Agent   `json:"agent,omitempty" yaml:"agent,omitempty"`
	InDeps  []string `json:"inDeps,omitempty" yaml:"inDeps,omitempty"`
	OutDeps []string `json:"outDeps,omitempty" yaml:"outDeps,omitempty"`
}

// Edge represents a directed trust/dependency edge in the topology.
type Edge struct {
	From string `json:"from" yaml:"from"`
	To   string `json:"to" yaml:"to"`
	Type string `json:"type,omitempty" yaml:"type,omitempty"`
}

// FleetConfig is the top-level YAML / JSON structure.
type FleetConfig struct {
	Agents        []Agent     `json:"agents" yaml:"agents"`
	AggregateRisk RiskSummary `json:"aggregateRisk" yaml:"aggregateRisk"`
}

// DAG holds the agent dependency graph and provides traversal methods.
type DAG struct {
	mu sync.RWMutex
	// risk is the authored aggregate carried alongside the graph so
	// LoadFleet keeps its single return value and main.go's wiring is unchanged.
	risk   RiskSummary
	agents map[string]*Agent
	nodes  map[string]*Node
	// forward edges: agent -> agents it depends on
	deps map[string][]string
	// reverse edges: agent -> agents that depend on it
	rdeps map[string][]string
	edges []Edge
	// ordered list of agent IDs (insertion order)
	order []string
}

// Graph is a type alias for DAG.
type Graph = DAG

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
	d, err := BuildDAG(cfg.Agents)
	if err != nil {
		return nil, err
	}
	d.risk = cfg.AggregateRisk
	if d.risk.Trend == "" {
		// "stable" and not "": trend is a union of up/down/stable in the client
		// and an empty string is not a member of it.
		d.risk.Trend = "stable"
	}
	return d, nil
}

// BuildDAG constructs a DAG from a list of agents. Returns an error if:
// - duplicate agent IDs are found
// - a dependency references a non-existent agent
// - the graph contains a cycle
func BuildDAG(agents []Agent) (*DAG, error) {
	d := &DAG{
		agents: make(map[string]*Agent, len(agents)),
		nodes:  make(map[string]*Node, len(agents)),
		deps:   make(map[string][]string, len(agents)),
		rdeps:  make(map[string][]string, len(agents)),
		edges:  make([]Edge, 0),
		order:  make([]string, 0, len(agents)),
	}

	for i := range agents {
		a := &agents[i]
		if _, exists := d.agents[a.ID]; exists {
			return nil, fmt.Errorf("duplicate agent ID: %s", a.ID)
		}
		// Defaulted here rather than in ParseFleet so every construction path
		// gets it — the cascade tests and the orchestrator build DAGs directly.
		if a.Name == "" {
			a.Name = a.ID
		}
		if a.State == "" {
			a.State = DefaultAgentState
		}
		d.agents[a.ID] = a
		d.nodes[a.ID] = &Node{
			ID:      a.ID,
			Agent:   a,
			InDeps:  make([]string, 0),
			OutDeps: make([]string, 0),
		}
		d.order = append(d.order, a.ID)
	}

	for _, a := range agents {
		for _, dep := range a.Dependencies {
			if _, exists := d.agents[dep]; !exists {
				return nil, fmt.Errorf("agent %q depends on unknown agent %q", a.ID, dep)
			}
			d.deps[a.ID] = append(d.deps[a.ID], dep)
			d.rdeps[dep] = append(d.rdeps[dep], a.ID)
			d.edges = append(d.edges, Edge{From: a.ID, To: dep, Type: "data"})
			d.nodes[a.ID].InDeps = append(d.nodes[a.ID].InDeps, dep)
			d.nodes[dep].OutDeps = append(d.nodes[dep].OutDeps, a.ID)
		}
	}

	if cycle := d.detectCycle(); cycle != "" {
		return nil, fmt.Errorf("cycle detected: %s", cycle)
	}

	return d, nil
}

// detectCycle uses DFS-based cycle detection with a 3-colour state machine,
// returning a description of the cycle if one exists, or "" if the graph is acyclic.
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
			if dep == id {
				return fmt.Sprintf("%s -> %s", id, dep)
			}
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

// DetectCycle checks if the graph contains any cycle. Returns (hasCycle, cyclePath).
func (d *DAG) DetectCycle() (bool, string) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	c := d.detectCycle()
	return c != "", c
}

// DeploymentOrder computes the deterministic topological deployment order using Kahn's algorithm.
// Root agents (those with no upstream dependencies) appear first, followed by downstream dependants.
func (d *DAG) DeploymentOrder() ([]string, error) {
	d.mu.RLock()
	defer d.mu.RUnlock()

	return d.kahnDeploymentOrder()
}

func (d *DAG) kahnDeploymentOrder() ([]string, error) {
	// inDegree represents the count of unresolved dependencies for each agent
	inDegree := make(map[string]int, len(d.agents))
	for id, a := range d.agents {
		inDegree[id] = len(a.Dependencies)
	}

	// Deterministic initial queue: find all root agents (in-degree 0) in insertion order
	var queue []string
	for _, id := range d.order {
		if inDegree[id] == 0 {
			queue = append(queue, id)
		}
	}

	var result []string
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		result = append(result, current)

		for _, rdep := range d.rdeps[current] {
			inDegree[rdep]--
			if inDegree[rdep] == 0 {
				queue = append(queue, rdep)
			}
		}
	}

	if len(result) != len(d.agents) {
		return nil, fmt.Errorf("cycle detected: topological sort failed to resolve all nodes (%d of %d resolved)", len(result), len(d.agents))
	}

	return result, nil
}

// TopologicalSort computes the deterministic topological order for deployment.
func (d *DAG) TopologicalSort() ([]string, error) {
	return d.DeploymentOrder()
}

// CascadeTargets returns the set of agents that must be stunned when the given
// agent is stunned. This is the target agent plus all agents that transitively
// depend on it (BFS on reverse edges). Agents designated for observability
// (e.g. agent-monitor) are strictly excluded from the cascade (they stay alive to observe).
//
// The result is ordered: target first, then direct dependants, then transitive.
func (d *DAG) CascadeTargets(agentID string) ([]string, error) {
	d.mu.RLock()
	defer d.mu.RUnlock()

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

		// Observability agents are preserved (they are read-only watchers and remain running)
		if d.isObservability(current) && current != agentID {
			// Traverse reverse dependencies so downstream non-observability agents are reached
			for _, rdep := range d.rdeps[current] {
				if !visited[rdep] {
					visited[rdep] = true
					queue = append(queue, rdep)
				}
			}
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

// isObservability returns true if the agent is designated for observability or monitoring.
func (d *DAG) isObservability(agentID string) bool {
	a, ok := d.agents[agentID]
	if !ok {
		return false
	}
	t := strings.ToLower(strings.TrimSpace(a.Type))
	return t == "observability" || t == "monitor" || t == "logging" || strings.Contains(t, "observability") || agentID == "agent-monitor"
}

// IsObservabilityAgent returns true if the agent is designated for observability or monitoring.
func (d *DAG) IsObservabilityAgent(agentID string) bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.isObservability(agentID)
}

// RecoveryOrder returns the topological order for recovering stunned agents.
// Root-ward agents come first (agents with no dependencies among the stunned set),
// then their dependants. This ensures each agent's upstream is healthy before
// it is recovered.
func (d *DAG) RecoveryOrder(stunnedIDs []string) []string {
	d.mu.RLock()
	defer d.mu.RUnlock()

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

// AggregateRisk returns the authored fleet risk summary.
func (d *DAG) AggregateRisk() RiskSummary {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.risk
}

// SetAggregateRisk updates the aggregate risk summary in-memory.
func (d *DAG) SetAggregateRisk(risk RiskSummary) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.risk = risk
}

// GetAgent returns the agent with the given ID, or nil if not found.
func (d *DAG) GetAgent(id string) *Agent {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.agents[id]
}

// AllAgents returns all agents in insertion order.
func (d *DAG) AllAgents() []*Agent {
	d.mu.RLock()
	defer d.mu.RUnlock()
	result := make([]*Agent, 0, len(d.order))
	for _, id := range d.order {
		result = append(result, d.agents[id])
	}
	return result
}

// GetNode returns the Node with adjacency information for the given ID.
func (d *DAG) GetNode(id string) *Node {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.nodes[id]
}

// AllNodes returns all Nodes in insertion order.
func (d *DAG) AllNodes() []*Node {
	d.mu.RLock()
	defer d.mu.RUnlock()
	result := make([]*Node, 0, len(d.order))
	for _, id := range d.order {
		result = append(result, d.nodes[id])
	}
	return result
}

// Edges returns all directed trust/dependency edges in the DAG.
func (d *DAG) Edges() []Edge {
	d.mu.RLock()
	defer d.mu.RUnlock()
	result := make([]Edge, len(d.edges))
	copy(result, d.edges)
	return result
}

// SetAgentState updates the in-memory state of a specific agent.
func (d *DAG) SetAgentState(id, state string) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	a, exists := d.agents[id]
	if !exists {
		return fmt.Errorf("unknown agent: %s", id)
	}
	if !IsValidAgentState(state) {
		return fmt.Errorf("invalid agent state: %q", state)
	}
	a.State = state
	return nil
}

// SetAgentGracePeriod updates the grace period expiry and remaining hours of a specific agent.
func (d *DAG) SetAgentGracePeriod(id, expiry string, remainingHours float64) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	a, exists := d.agents[id]
	if !exists {
		return fmt.Errorf("unknown agent: %s", id)
	}
	a.GracePeriodExpiry = expiry
	a.RemainingHours = remainingHours
	return nil
}

// SetAgentCompliance updates an agent state and grace period based on compliance evaluation.
func (d *DAG) SetAgentCompliance(id string, compliant bool, detectedAt, now time.Time) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	a, exists := d.agents[id]
	if !exists {
		return fmt.Errorf("unknown agent: %s", id)
	}
	evaluator := NewGracePeriodEvaluator()
	evaluator.ApplyEvaluation(a, compliant, detectedAt, now)
	return nil
}


// FilterAgentsByTeam returns all agents belonging to the specified team in insertion order.
// If team is empty, all agents are returned.
func (d *DAG) FilterAgentsByTeam(team string) []*Agent {
	d.mu.RLock()
	defer d.mu.RUnlock()
	if team == "" {
		result := make([]*Agent, 0, len(d.order))
		for _, id := range d.order {
			result = append(result, d.agents[id])
		}
		return result
	}
	var result []*Agent
	for _, id := range d.order {
		if strings.EqualFold(d.agents[id].Team, team) {
			result = append(result, d.agents[id])
		}
	}
	return result
}

// FilterEdgesBetween returns only edges where both source and destination agents are present in visibleIDs.
func (d *DAG) FilterEdgesBetween(visibleIDs map[string]bool) []Edge {
	d.mu.RLock()
	defer d.mu.RUnlock()
	var result []Edge
	for _, edge := range d.edges {
		if visibleIDs[edge.From] && visibleIDs[edge.To] {
			result = append(result, edge)
		}
	}
	return result
}
