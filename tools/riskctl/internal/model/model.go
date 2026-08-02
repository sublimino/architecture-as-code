// Package model holds the on-disk schema for the three versioned inputs to the risk calculation:
// the policy pack (controls + frequency), the agent posture (what is actually true), and the
// organisational risk posture (loss magnitude + appetite).
//
// The separation is deliberate and load-bearing:
//
//	pack  -> loss event FREQUENCY  (a property of the control environment)
//	org   -> loss MAGNITUDE        (a property of the institution)
//
// Multiplying one pack by two org files is what makes "same control, two institutions, opposite
// verdict" arithmetic rather than opinion.
package model

import (
	"fmt"
	"os"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"gopkg.in/yaml.v3"
)

// Triple is a calibrated three-point estimate used as the input to a beta-PERT distribution.
// Ordering min <= mode <= max is validated on load; an unordered triple is a data error, not a
// judgement call.
//
// This is an alias for the shared engine's RiskTriple, not a copy. The policy-engine service and
// this CLI read the same triples through the same sampler, so the two surfaces cannot drift apart
// on what a number means.
type Triple = fair.RiskTriple

// Evidence cites the artefact in the repository that substantiates a control or an assertion.
// A control without evidence is a hope; the loader rejects it.
type Evidence struct {
	Artifact  string `yaml:"artifact"`
	Assertion string `yaml:"assertion"`
}

// Action is the enforcement-action axis (hub ADR-0003). Independent of adoption cadence.
type Action string

const (
	ActionAudit Action = "audit" // lane-keeping: nudge + report
	ActionDeny  Action = "deny"  // the gate: a locked door
)

// Control is one policy in the pack.
type Control struct {
	ID          string   `yaml:"id"`
	Title       string   `yaml:"title"`
	Scenario    string   `yaml:"scenario"`
	Action      Action   `yaml:"action"`
	Rationale   string   `yaml:"rationale"`
	Evidence    Evidence `yaml:"evidence"`
	CEL         string   `yaml:"cel"`
	LEFAudit    Triple   `yaml:"lef_audit"`
	LEFEnforced Triple   `yaml:"lef_enforced"`
	AnnualCost  float64  `yaml:"annual_cost_gbp"`
}

// Conditional is a "you may X if C" branch — the replacement for the exemption. It relaxes a
// control uniformly for anyone meeting the conditions, and carries its own priced residual.
type Conditional struct {
	ID          string   `yaml:"id"`
	Title       string   `yaml:"title"`
	Relaxes     string   `yaml:"relaxes"`
	CEL         string   `yaml:"cel"`
	Conditions  []string `yaml:"conditions"`
	LEFResidual Triple   `yaml:"lef_residual"`
}

// Cage is one rung of the graded enforcement envelope. Deny is the bottom rung, not the only rung.
// Multiplier scales loss event frequency; AnnualCost is the run-cost of the cage, which lands in
// Total Cost of Risk.
type Cage struct {
	Multiplier  float64 `yaml:"multiplier"`
	AnnualCost  float64 `yaml:"annual_cost_gbp"`
	Description string  `yaml:"description"`
}

// Scenario is a named loss scenario the controls act upon.
type Scenario struct {
	ID    string `yaml:"id"`
	Title string `yaml:"title"`
}

// EnforcementFriction is the operational cost of gating, as opposed to the cost of running a
// control. Blocked deploys, false positives, and the engineer-hours spent getting unblocked.
//
// Without this term the model can only ever recommend tightening, which makes it a sales prop
// rather than a decision instrument. With it, the tool is able to say "do not bother — this control
// costs more than it buys", which is the output that earns it credibility.
type EnforcementFriction struct {
	PerDenyControlGBP float64 `yaml:"per_deny_control_gbp"`
	Note              string  `yaml:"note"`
}

// Pack is a complete versioned policy pack — what a semver git tag resolves to.
type Pack struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name        string   `yaml:"name"`
		Version     string   `yaml:"version"`
		Subject     string   `yaml:"subject"`
		Description string   `yaml:"description"`
		Changes     []string `yaml:"changes"`
	} `yaml:"metadata"`
	Scenarios   []Scenario          `yaml:"scenarios"`
	Controls    []Control           `yaml:"controls"`
	Conditional []Conditional       `yaml:"conditional"`
	Cages       map[string]Cage     `yaml:"cages"`
	Friction    EnforcementFriction `yaml:"enforcement_friction"`
}

// Control returns the control with the given ID.
func (p *Pack) Control(id string) (Control, bool) {
	for _, c := range p.Controls {
		if c.ID == id {
			return c, true
		}
	}
	return Control{}, false
}

// Satisfaction is one posture assertion: does this agent meet this control, and what proves it.
type Satisfaction struct {
	Control  string `yaml:"control"`
	Met      bool   `yaml:"met"`
	Evidence string `yaml:"evidence"`
	Note     string `yaml:"note"`
}

// AgentPosture is what is actually true about a named agent, plus the pack version it claims.
// "The policy version you satisfy becomes your identity."
type AgentPosture struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name        string `yaml:"name"`
		DisplayName string `yaml:"displayName"`
		Owner       string `yaml:"owner"`
		Description string `yaml:"description"`
	} `yaml:"metadata"`
	Claims struct {
		Pack    string `yaml:"pack"`
		Version string `yaml:"version"`
	} `yaml:"claims"`
	Tier               string         `yaml:"tier"`
	Satisfies          []Satisfaction `yaml:"satisfies"`
	ConditionalElected []string       `yaml:"conditional_elected"`
}

// Met reports whether the agent asserts it meets the given control.
func (a *AgentPosture) Met(controlID string) (Satisfaction, bool) {
	for _, s := range a.Satisfies {
		if s.Control == controlID {
			return s, true
		}
	}
	return Satisfaction{}, false
}

// Elected reports whether the agent has taken a conditional branch.
func (a *AgentPosture) Elected(id string) bool {
	for _, c := range a.ConditionalElected {
		if c == id {
			return true
		}
	}
	return false
}

// Magnitude is the loss magnitude for one scenario at one institution, with its calibration
// provenance. Provenance is mandatory: an unsourced number is not reviewable, and an unreviewable
// number is the binary lie in a different costume.
type Magnitude struct {
	Triple     Triple `yaml:"triple"`
	Provenance string `yaml:"provenance"`
}

// Regime is a regulatory regime in force at the institution.
type Regime struct {
	ID        string `yaml:"id"`
	Authority string `yaml:"authority"`
	Note      string `yaml:"note"`
}

// OrgRiskPosture is the institution's half: what a loss event costs here, and how much annualised
// loss it will tolerate before enforcement escalation is justified.
type OrgRiskPosture struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name         string `yaml:"name"`
		DisplayName  string `yaml:"displayName"`
		Sector       string `yaml:"sector"`
		Jurisdiction string `yaml:"jurisdiction"`
		Description  string `yaml:"description"`
	} `yaml:"metadata"`
	Regimes  []Regime `yaml:"regimes"`
	Appetite struct {
		ToleranceGBP float64 `yaml:"tolerance_gbp"`
		Note         string  `yaml:"note"`
	} `yaml:"appetite"`
	RiskLoad float64 `yaml:"risk_load"`
	Transfer struct {
		AnnualPremiumGBP float64 `yaml:"annual_premium_gbp"`
		RetentionGBP     float64 `yaml:"retention_gbp"`
		LimitGBP         float64 `yaml:"limit_gbp"`
		Note             string  `yaml:"note"`
	} `yaml:"transfer"`
	Magnitude map[string]Magnitude `yaml:"magnitude"`
}

func load(path string, into any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	if err := yaml.Unmarshal(b, into); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	return nil
}

// LoadPack reads and validates a policy pack.
func LoadPack(path string) (*Pack, error) {
	var p Pack
	if err := load(path, &p); err != nil {
		return nil, err
	}
	if p.Metadata.Version == "" {
		return nil, fmt.Errorf("%s: pack has no metadata.version; the version string is the pin, the selector and the identity", path)
	}
	if len(p.Controls) == 0 {
		return nil, fmt.Errorf("%s: pack declares no controls", path)
	}
	seen := map[string]bool{}
	scenarios := map[string]bool{}
	for _, s := range p.Scenarios {
		scenarios[s.ID] = true
	}
	for _, c := range p.Controls {
		if seen[c.ID] {
			return nil, fmt.Errorf("%s: duplicate control id %s", path, c.ID)
		}
		seen[c.ID] = true
		if c.Action != ActionAudit && c.Action != ActionDeny {
			return nil, fmt.Errorf("%s: control %s has action %q; want audit or deny", path, c.ID, c.Action)
		}
		if !scenarios[c.Scenario] {
			return nil, fmt.Errorf("%s: control %s references unknown scenario %q", path, c.ID, c.Scenario)
		}
		if c.Rationale == "" {
			return nil, fmt.Errorf("%s: control %s carries no rationale; purposeless policy is potentially practically pointless policy", path, c.ID)
		}
		if c.Evidence.Artifact == "" {
			return nil, fmt.Errorf("%s: control %s cites no evidence artifact", path, c.ID)
		}
		if err := c.LEFAudit.Validate(c.ID + ".lef_audit"); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if err := c.LEFEnforced.Validate(c.ID + ".lef_enforced"); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if c.LEFEnforced.Mode > c.LEFAudit.Mode {
			return nil, fmt.Errorf("%s: control %s claims enforcement raises frequency (%g > %g); a control that makes things worse is a modelling error",
				path, c.ID, c.LEFEnforced.Mode, c.LEFAudit.Mode)
		}
	}
	for _, cd := range p.Conditional {
		if _, ok := p.Control(cd.Relaxes); !ok {
			return nil, fmt.Errorf("%s: conditional %s relaxes unknown control %s", path, cd.ID, cd.Relaxes)
		}
		if err := cd.LEFResidual.Validate(cd.ID + ".lef_residual"); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}
	for name, cage := range p.Cages {
		if cage.Multiplier <= 0 {
			return nil, fmt.Errorf("%s: cage %s has non-positive multiplier %g", path, name, cage.Multiplier)
		}
	}
	return &p, nil
}

// LoadAgentPosture reads and validates an agent posture assertion.
func LoadAgentPosture(path string) (*AgentPosture, error) {
	var a AgentPosture
	if err := load(path, &a); err != nil {
		return nil, err
	}
	if a.Claims.Version == "" {
		return nil, fmt.Errorf("%s: posture claims no pack version; an agent with no claimed version has no identity", path)
	}
	for _, s := range a.Satisfies {
		if s.Evidence == "" {
			return nil, fmt.Errorf("%s: assertion for %s cites no evidence; an assertion without evidence is not an assertion", path, s.Control)
		}
	}
	return &a, nil
}

// LoadOrgRiskPosture reads and validates an institution's risk posture.
func LoadOrgRiskPosture(path string) (*OrgRiskPosture, error) {
	var o OrgRiskPosture
	if err := load(path, &o); err != nil {
		return nil, err
	}
	if o.Appetite.ToleranceGBP <= 0 {
		return nil, fmt.Errorf("%s: appetite.tolerance_gbp must be > 0; without a tolerance band a number cannot become a verdict", path)
	}
	if len(o.Magnitude) == 0 {
		return nil, fmt.Errorf("%s: no loss magnitudes declared", path)
	}
	for id, m := range o.Magnitude {
		if err := m.Triple.Validate("magnitude." + id); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if m.Provenance == "" {
			return nil, fmt.Errorf("%s: magnitude %s has no provenance; an unsourced number is not reviewable", path, id)
		}
	}
	return &o, nil
}
