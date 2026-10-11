package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

// PricingStatus is the machine-readable cause of a route declining to report a money
// figure. It is the fleet-manager copy of the estate's shared refusal vocabulary.
//
// WHY A LOCAL COPY AND NOT AN IMPORT. policy-engine's pkg/compliance owns the original.
// fleet-manager is an independently deployable service in its own Go module, and a
// require+replace across that boundary would couple two deployables for the sake of five
// small types, invisibly to anyone reading either service alone. fe-signalloom faced the
// same boundary between Go and Python and resolved it the same way: declare the shape
// locally, then pin the agreement with a test that reads the other side's declaration out
// of its source. See TestRefusalShapeParityWithPolicyEngine, and
// fe-signalloom/src/tests/test_refusal_shape_parity.py for the pattern.
//
// The duplication is the lesser cost; the parity test is what makes it safe. A client
// deserialising one service's refusal must deserialise the other's without branching on
// which service answered, so the KEY SET and the STATUS STRINGS are the contract -- not
// these Go types.
type PricingStatus string

const (
	// PricingStatusPriced: a figure is present and was computed from declared inputs.
	// Declared here for vocabulary parity with the engine; this service never emits it,
	// because it has nothing to compute a fleet figure from.
	PricingStatusPriced PricingStatus = "PRICED"
	// PricingStatusNoDeclaredLossFrequency and PricingStatusNoRiskDataPlane are the
	// engine's two refusal causes. This service never emits either — its cause is
	// different, see below — but the whole vocabulary is declared on both sides so that a
	// client reading either service branches on one set of strings, and so that a
	// respelling on one side fails the parity test rather than silently falling through
	// every client branch.
	//
	// NO_DECLARED_LOSS_FREQUENCY: the checks evaluated resolve to no control in the risk
	// pack. Operator action: declare the mapping in the pack.
	PricingStatusNoDeclaredLossFrequency PricingStatus = "NO_DECLARED_LOSS_FREQUENCY"
	// NO_RISK_DATA_PLANE: the route answers from a store that holds no money at all.
	// Operator action: run a priced scan, or give the route a risk data plane.
	PricingStatusNoRiskDataPlane PricingStatus = "NO_RISK_DATA_PLANE"
	// PricingStatusAuthoredNotComputed: a figure for this field exists, but it was
	// AUTHORED — typed into a manifest by a human — and no computation stands behind it.
	// Emitted by GET /api/v1/fleet/topology, whose aggregateRisk was read straight out of
	// fleet.yaml and rendered on a risk gauge. Operator action: build a fleet risk model
	// that declares loss magnitude and loss-event frequency per agent, because nothing in
	// risk/packs maps an agent's riskClass to either.
	//
	// WHY A THIRD VALUE AND NOT ONE OF THE ENGINE'S TWO. Both of those describe a MISSING
	// input: no control in the risk pack maps to the checks evaluated
	// (NO_DECLARED_LOSS_FREQUENCY), or there is no risk data plane to read from
	// (NO_RISK_DATA_PLANE). This one describes a PRESENT datum of the wrong kind. The
	// number is right there in the config, which is exactly why it was served for so long
	// and why it is the more dangerous case — nothing looked missing. The operator actions
	// differ accordingly: declaring a control mapping or wiring up a priced scan will not
	// help here, and a reader told NO_DECLARED_LOSS_FREQUENCY would go hunting in the risk
	// pack for a figure that was never going to be there.
	PricingStatusAuthoredNotComputed PricingStatus = "AUTHORED_NOT_COMPUTED"
)

// Available reports whether a figure accompanies this status.
//
// FleetPricingStatus.Available is derived through this method rather than set beside the
// status, because two hand-maintained fields carrying one fact eventually disagree — and a
// boolean that disagrees with the status beside it is worse than either alone. Here it
// would be particularly bad: `available: true` next to a refusing status is exactly the
// field a client already reads and trusts.
func (s PricingStatus) Available() bool { return s == PricingStatusPriced }

// FleetPricingStatus is the refusal object. Its key set is deliberately identical to the
// policy engine's and fe-signalloom's, so a client has one shape to deserialise and one to
// render across every route in the estate that withholds money.
type FleetPricingStatus struct {
	Available bool          `json:"available"`
	Status    PricingStatus `json:"status"`
	Reason    string        `json:"reason"`
	// UnpricedFields names the money fields this response withheld, by their JSON names,
	// so a client can tell "withheld" from "this version has no such field" without a
	// schema.
	UnpricedFields []string `json:"unpricedFields"`
	// Unmapped names the checks that resolved to no declared control. Empty on this route,
	// whose refusal is not per-check — but always allocated, never nil: nil marshals to
	// `null` and an empty slice to `[]`, and the shared shape promises one type per key on
	// every route.
	Unmapped []string `json:"unmappedChecks"`
}

// newAuthoredNotComputedPricing builds the refusal for a figure that was authored in a
// manifest rather than computed.
//
// There is deliberately NO parameter for Available. Its only source is the status, and a
// constructor that accepted it would let a caller write a boolean contradicting the status
// beside it — which is how a refusal comes to claim a figure is available. A test asserts
// this signature, so the property cannot be lost by a later edit.
func newAuthoredNotComputedPricing(reason string, unpricedFields []string) FleetPricingStatus {
	status := PricingStatusAuthoredNotComputed
	if unpricedFields == nil {
		unpricedFields = []string{}
	}
	return FleetPricingStatus{
		// Derived, never written beside the status. See PricingStatus.Available.
		Available:      status.Available(),
		Status:         status,
		Reason:         reason,
		UnpricedFields: unpricedFields,
		Unmapped:       []string{},
	}
}

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

// AuthoredRiskInputs is what `aggregateRisk` in fleet.yaml declares: numbers a human
// typed into a manifest. It is parsed and retained, and deliberately NOT served.
//
// It is kept rather than deleted for two reasons. The values are evidence — they are
// what a previous version of this service published as measured risk, and
// base/configmap.yaml carries the comment explaining their provenance. And a future
// fleet risk model may legitimately want a declared ALE as an INPUT, which is a
// different thing from echoing one as an output.
//
// There are no `json` tags on any field, which is load-bearing rather than tidy: it is
// what stops this struct becoming the leak that undoes the refusal. If it is ever
// embedded in a response by accident it marshals to `{}`, and a test asserts exactly
// that. The yaml tags are the only serialisation this type participates in.
type AuthoredRiskInputs struct {
	ALE         *float64 `json:"-" yaml:"ale"`
	Var95       *float64 `json:"-" yaml:"var95"`
	Trend       string   `json:"-" yaml:"trend"`
	PreviousALE *float64 `json:"-" yaml:"previousAle"`
}

// RiskSummary is the `aggregateRisk` member of GET /api/v1/fleet/topology.
//
// IT NO LONGER CARRIES MONEY, and that is the fix. This type used to declare ALE and
// Var95 as required float64s populated straight from fleet.yaml, so an authored number
// was served to a dashboard that renders it on a risk gauge — a figure typed by a human
// presented as a measurement. The contract test REQUIRED those two keys to be numbers,
// which meant the test pinned the fabrication rather than catching it.
//
// Nothing in this repository can compute the figure. AgentProfile, the only per-agent
// input this service has, declares no loss magnitude and no loss-event frequency;
// risk/packs/ has zero matches for `riskClass` or `trustProfile`; and the only money the
// packs declare is `annual_cost`, which pack.yaml documents as the cost of the CONTROL
// ENVIRONMENT and explicitly not an institution's loss magnitude. Computing here would
// have meant inventing the missing input. `ale: 847000` in base/configmap.yaml is also
// the same literal policy-engine returned from `carried := 847000.0` after discarding a
// real Monte Carlo — the same claim, one service along.
//
// So the money fields are pointers with omitempty and are never populated: absent, not
// zero, because a zero in a money field is read by a human and by a dashboard as the
// claim "no loss expected", which is itself a figure. Trend goes with them: "up" asserts
// that an ALE rose, and with no ALE computed there is no movement to report.
//
// Pricing carries the estate's shared refusal shape, declared locally and held in
// agreement with the policy engine's by TestRefusalShapeParityWithPolicyEngine.
type RiskSummary struct {
	ALE         *float64 `json:"ale,omitempty"`
	Var95       *float64 `json:"var95,omitempty"`
	Trend       string   `json:"trend,omitempty"`
	PreviousALE *float64 `json:"previousAle,omitempty"`
	// Pricing is always present. An omission is silent rather than honest: a missing
	// money field is indistinguishable from a field this version does not implement,
	// from version skew, and from a crash midway through encoding. The status says who
	// withheld the figure and why.
	Pricing FleetPricingStatus `json:"pricing"`
}

// authoredRiskRefusalReason is the operator-facing explanation. It names the two things
// that would have to exist for a figure to be computable, so a reader knows what to go
// and build rather than merely that something is missing.
const authoredRiskRefusalReason = "aggregateRisk in fleet.yaml is authored configuration, not a computation: " +
	"no fleet risk model exists in this repository. AgentProfile declares no loss magnitude or " +
	"loss-event frequency, and risk/packs/ maps no agent riskClass to either, so no ALE or VaR95 " +
	"can be derived for this fleet. Serving the authored numbers would present a figure typed into " +
	"a manifest as a measurement."

// authoredRiskUnpricedFields names, by JSON name, every key this response withheld.
//
// `trend` is in the list though it is not itself money. It is a claim ABOUT money — the
// direction an ALE moved — and withholding the figure while serving its trend would leave
// a gauge with an arrow and no number, which reads as a measurement just as well.
var authoredRiskUnpricedFields = []string{"ale", "var95", "previousAle", "trend"}

// refusedAggregateRisk is the only constructor for the served summary. It takes no figures,
// which is deliberate: there is no parameter through which an authored number could be
// passed back in, so the refusal cannot be undone by a caller.
func refusedAggregateRisk() RiskSummary {
	return RiskSummary{
		// ALE, Var95, PreviousALE and Trend are left at their zero values so omitempty
		// drops them from the response entirely. Absent, not zero — and absent WITH a
		// status saying so.
		Pricing: newAuthoredNotComputedPricing(
			authoredRiskRefusalReason,
			authoredRiskUnpricedFields,
		),
	}
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
	Agents []Agent `json:"agents" yaml:"agents"`
	// AggregateRisk is parsed into AuthoredRiskInputs rather than into the wire type.
	// The config declares authored numbers; the API serves a refusal. Keeping the two
	// types distinct is what makes it impossible to author a `pricing` block, and what
	// stops a future edit reconnecting the manifest to the response by accident.
	AggregateRisk AuthoredRiskInputs `json:"aggregateRisk" yaml:"aggregateRisk"`
}

// DAG holds the agent dependency graph and provides traversal methods.
type DAG struct {
	mu sync.RWMutex
	// authoredRisk is what the config declared, carried alongside the graph so
	// LoadFleet keeps its single return value. It is never served; see
	// AuthoredRiskInputs and AggregateRisk.
	authoredRisk AuthoredRiskInputs
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
	// Retained, not served. The former default of Trend to "stable" is gone with it:
	// that default existed to keep an authored trend inside the client's up/down/stable
	// union, and the response no longer carries a trend to constrain.
	d.authoredRisk = cfg.AggregateRisk
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

// AggregateRisk returns the served fleet risk summary, which carries no figures.
//
// It takes no account of what the config authored, and that is the point: there is no
// code path from the manifest's numbers to this return value. The method is kept rather
// than removed because the response member it populates is still part of the client
// contract — what changed is that it now reports a refusal instead of a figure.
func (d *DAG) AggregateRisk() RiskSummary {
	return refusedAggregateRisk()
}

// AuthoredRiskInputs returns the figures the fleet config declared. Retained for review
// and for any future fleet risk model that wants them as a declared input; never served.
func (d *DAG) AuthoredRiskInputs() AuthoredRiskInputs {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.authoredRisk
}

// SetAggregateRisk is deliberately absent. It had no callers, and its only possible use
// was to write a money figure into the served summary at runtime — the exact move this
// type now exists to prevent. A setter kept "just in case" is the route by which the
// authored number comes back.

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
