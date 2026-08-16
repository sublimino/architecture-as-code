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
//
// TWO AXES WERE ADDED TO THAT SPLIT: DENOMINATION AND TERRITORY.
//
// Denomination. Every amount in these files used to be a bare float64 with the currency welded into
// the field NAME — annual_cost_gbp, tolerance_gbp, per_deny_control_gbp. A name is not carried
// across a wire, a database column or a chart axis, so nothing downstream could convert, and a UI
// defaulting to USD over GBP source data would relabel the figure rather than convert it. Every
// amount is now a money.Money that carries its own currency as DATA. See package money for the
// rounding decision and for why the rates are a checked-in dated file rather than an API call.
//
// The two halves of the model can legitimately be denominated differently: a control's run cost is
// a property of the CONTROL ENVIRONMENT (a vendor licence, quoted in the vendor's currency) while a
// loss magnitude is a property of the INSTITUTION (quoted in the currency it reports in). Total Cost
// of Risk sums both. That sum is the exact place a currency mismatch would silently corrupt a board
// figure, so the report resolves everything into one declared reporting currency first. See
// baseline.Run.
//
// Territory. A loss scenario is not always global. A UK-GDPR administrative fine is not a loss an
// American provider can incur, and pricing it into their exposure inflates the number in a way an
// informed reader will catch. A scenario may therefore scope itself to named jurisdictions, matched
// against the institution's EXISTING metadata.jurisdiction field. Scenarios that declare no
// territories are global, which is what every scenario in the shipped packs is — so this axis
// changes no existing figure until someone deliberately scopes one.
package model

import (
	"fmt"
	"math"
	"os"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
	"gopkg.in/yaml.v3"
)

// Triple is a calibrated three-point estimate used as the input to a beta-PERT distribution.
// Ordering min <= mode <= max is validated on load; an unordered triple is a data error, not a
// judgement call.
//
// This is an alias for the shared engine's RiskTriple, not a copy. The policy-engine service and
// this CLI read the same triples through the same sampler, so the two surfaces cannot drift apart
// on what a number means.
//
// A Triple is deliberately UNDENOMINATED. It is used for two different quantities: loss event
// frequency, which is a dimensionless rate per year and has no currency, and loss magnitude, which
// does. Magnitude therefore carries its currency on the enclosing Magnitude struct rather than here,
// so a frequency triple cannot accidentally acquire a denomination it has no business having.
type Triple = fair.RiskTriple

// Global is the territory wildcard: a scenario that applies to every institution.
const Global = "*"

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
	ID          string      `yaml:"id"`
	Title       string      `yaml:"title"`
	Scenario    string      `yaml:"scenario"`
	Action      Action      `yaml:"action"`
	Rationale   string      `yaml:"rationale"`
	Evidence    Evidence    `yaml:"evidence"`
	CEL         string      `yaml:"cel"`
	LEFAudit    Triple      `yaml:"lef_audit"`
	LEFEnforced Triple      `yaml:"lef_enforced"`
	AnnualCost  money.Money `yaml:"annual_cost"`
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
	Multiplier  float64     `yaml:"multiplier"`
	AnnualCost  money.Money `yaml:"annual_cost"`
	Description string      `yaml:"description"`
}

// Scenario is a named loss scenario the controls act upon.
//
// Territories scopes the scenario to the jurisdictions where it can actually be incurred. It is
// matched against OrgRiskPosture.Metadata.Jurisdiction, the field that already existed — a parallel
// concept would have meant two answers to "where is this institution" and eventually two different
// answers.
//
//	territories: ["*"]            global; applies to every institution (the default)
//	territories: ["UK"]           applies only where jurisdiction is UK
//	territories: ["UK","DE","FR"] applies in any of the named jurisdictions
//
// Omitting the field means global. That is the permissive default on purpose: it is the behaviour
// every existing pack already had, so adding this axis moves no existing number. Scoping is an
// affirmative act by an author who knows the scenario is not universal.
type Scenario struct {
	ID          string   `yaml:"id"`
	Title       string   `yaml:"title"`
	Territories []string `yaml:"territories"`
	// TerritoryNote records WHY the scenario is scoped, for the same reason magnitudes carry
	// provenance: an unexplained exclusion is indistinguishable from an oversight.
	TerritoryNote string `yaml:"territory_note"`
}

// IsGlobal reports whether the scenario applies everywhere.
func (s Scenario) IsGlobal() bool {
	if len(s.Territories) == 0 {
		return true
	}
	for _, t := range s.Territories {
		if strings.TrimSpace(t) == Global {
			return true
		}
	}
	return false
}

// AppliesTo reports whether this scenario can be incurred by an institution in the given
// jurisdiction. Comparison is case-insensitive and whitespace-trimmed: "uk" and "UK" naming
// different things would be a data trap, not a feature.
func (s Scenario) AppliesTo(jurisdiction string) bool {
	if s.IsGlobal() {
		return true
	}
	j := strings.ToUpper(strings.TrimSpace(jurisdiction))
	if j == "" {
		// An institution that does not say where it is cannot match a scoped scenario. The scenario
		// is excluded rather than assumed, and baseline.Run surfaces that as an explicit reason —
		// silence must never read as a match.
		return false
	}
	for _, t := range s.Territories {
		if strings.ToUpper(strings.TrimSpace(t)) == j {
			return true
		}
	}
	return false
}

// EnforcementFriction is the operational cost of gating, as opposed to the cost of running a
// control. Blocked deploys, false positives, and the engineer-hours spent getting unblocked.
//
// Without this term the model can only ever recommend tightening, which makes it a sales prop
// rather than a decision instrument. With it, the tool is able to say "do not bother — this control
// costs more than it buys", which is the output that earns it credibility.
type EnforcementFriction struct {
	PerDenyControl money.Money `yaml:"per_deny_control"`
	Note           string      `yaml:"note"`
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
	// Currency is the document default denomination for every bare amount in this file. Declaring
	// it once beats repeating it against each of a dozen control costs, which is a dozen chances to
	// denominate one line differently by accident. A file containing money and no currency is a load
	// error, never a guess.
	Currency    money.Currency      `yaml:"currency"`
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

// Scenario returns the scenario with the given ID.
func (p *Pack) Scenario(id string) (Scenario, bool) {
	for _, s := range p.Scenarios {
		if s.ID == id {
			return s, true
		}
	}
	return Scenario{}, false
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
//
// Currency denominates all three points of the triple. It defaults to the org file's document
// currency; a scenario priced in a different currency from the rest of the file may state its own,
// and baseline.Run converts it into the reporting currency before it reaches the sampler.
type Magnitude struct {
	Triple     Triple         `yaml:"triple"`
	Currency   money.Currency `yaml:"currency"`
	Provenance string         `yaml:"provenance"`
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
		Name        string `yaml:"name"`
		DisplayName string `yaml:"displayName"`
		Sector      string `yaml:"sector"`
		// Jurisdiction is matched against Scenario.Territories. It predates this change and is
		// reused rather than duplicated.
		Jurisdiction string `yaml:"jurisdiction"`
		Description  string `yaml:"description"`
	} `yaml:"metadata"`
	// Currency is this institution's REPORTING currency: the denomination every figure in its
	// report is expressed in, and the document default for bare amounts in this file.
	Currency money.Currency `yaml:"currency"`
	Regimes  []Regime       `yaml:"regimes"`
	Appetite struct {
		Tolerance money.Money `yaml:"tolerance"`
		Note      string      `yaml:"note"`
	} `yaml:"appetite"`
	RiskLoad float64 `yaml:"risk_load"`
	Transfer struct {
		AnnualPremium money.Money `yaml:"annual_premium"`
		Retention     money.Money `yaml:"retention"`
		Limit         money.Money `yaml:"limit"`
		Note          string      `yaml:"note"`
	} `yaml:"transfer"`
	Magnitude map[string]Magnitude `yaml:"magnitude"`
}

func load(path string, into any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	if err := rejectLegacyCurrencyKeys(b, path); err != nil {
		return err
	}
	if err := yaml.Unmarshal(b, into); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	return nil
}

// rejectLegacyCurrencyKeys fails loudly on the pre-Money field names.
//
// This guard is not tidiness. yaml.v3 silently ignores keys the target struct does not declare, so
// an unmigrated file carrying `annual_cost_gbp: 4000` would load cleanly with AnnualCost at ZERO —
// every control silently free, Total Cost of Risk understated, and no error anywhere. That is
// precisely the class of silent wrong number this whole change exists to eliminate, so the loader
// names the offending key and the file rather than absorbing it.
func rejectLegacyCurrencyKeys(b []byte, path string) error {
	var root yaml.Node
	if err := yaml.Unmarshal(b, &root); err != nil {
		return nil // let the real unmarshal report the syntax error, with its better message
	}
	var found []string
	var walk func(n *yaml.Node)
	walk = func(n *yaml.Node) {
		if n == nil {
			return
		}
		if n.Kind == yaml.MappingNode {
			for i := 0; i+1 < len(n.Content); i += 2 {
				k := n.Content[i]
				if lower := strings.ToLower(k.Value); strings.HasSuffix(lower, "_gbp") ||
					strings.HasSuffix(lower, "_usd") || strings.HasSuffix(lower, "_eur") {
					found = append(found, fmt.Sprintf("line %d: %s", k.Line, k.Value))
				}
				walk(n.Content[i+1])
			}
			return
		}
		for _, c := range n.Content {
			walk(c)
		}
	}
	walk(&root)
	if len(found) == 0 {
		return nil
	}
	return fmt.Errorf("%s: currency-suffixed field name(s) are no longer supported — %s.\n"+
		"  Amounts now carry their denomination as data. Declare `currency: GBP` once at the top of\n"+
		"  the document and rename the key without its suffix (annual_cost_gbp -> annual_cost), or\n"+
		"  denominate the amount explicitly as { amount: N, currency: XXX }.\n"+
		"  This is an error rather than a silently ignored key because ignoring it would load the\n"+
		"  amount as zero and understate the figure with no warning",
		path, strings.Join(found, "; "))
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
	if p.Currency != "" {
		if err := p.Currency.Validate(); err != nil {
			return nil, fmt.Errorf("%s: top-level currency: %w", path, err)
		}
	}
	seen := map[string]bool{}
	scenarios := map[string]bool{}
	for i, s := range p.Scenarios {
		if scenarios[s.ID] {
			return nil, fmt.Errorf("%s: duplicate scenario id %s", path, s.ID)
		}
		scenarios[s.ID] = true
		// Normalise the absent case to the explicit wildcard so every consumer sees one shape and
		// nobody has to remember that "empty means global".
		if len(s.Territories) == 0 {
			p.Scenarios[i].Territories = []string{Global}
		}
		for _, t := range p.Scenarios[i].Territories {
			if strings.TrimSpace(t) == "" {
				return nil, fmt.Errorf("%s: scenario %s declares an empty territory; use %q for global",
					path, s.ID, Global)
			}
		}
	}
	for i, c := range p.Controls {
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
		m, err := c.AnnualCost.Resolve(p.Currency, fmt.Sprintf("%s: control %s annual_cost", path, c.ID))
		if err != nil {
			return nil, err
		}
		p.Controls[i].AnnualCost = m
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
		m, err := cage.AnnualCost.Resolve(p.Currency, fmt.Sprintf("%s: cage %s annual_cost", path, name))
		if err != nil {
			return nil, err
		}
		cage.AnnualCost = m
		p.Cages[name] = cage
	}
	fr, err := p.Friction.PerDenyControl.Resolve(p.Currency, path+": enforcement_friction.per_deny_control")
	if err != nil {
		return nil, err
	}
	p.Friction.PerDenyControl = fr
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
	if o.Currency == "" {
		return nil, fmt.Errorf("%s: institution declares no `currency:`; it is the reporting denomination for "+
			"every figure in its report and cannot be inferred", path)
	}
	if err := o.Currency.Validate(); err != nil {
		return nil, fmt.Errorf("%s: top-level currency: %w", path, err)
	}
	tol, err := o.Appetite.Tolerance.Resolve(o.Currency, path+": appetite.tolerance")
	if err != nil {
		return nil, err
	}
	o.Appetite.Tolerance = tol
	if o.Appetite.Tolerance.Amount <= 0 {
		return nil, fmt.Errorf("%s: appetite.tolerance must be > 0; without a tolerance band a number cannot become a verdict", path)
	}
	// risk_load is the percentage markup on TVaR that produces the Carried figure. It must be a
	// finite non-negative number; NaN or Inf would silently propagate through the multiplication
	// `tvar * (1 + riskLoad)` and produce a NaN Carried that passes structural checks but is not
	// a number anyone can use. A negative load would make Carried < TVaR, violating a distribution
	// identity. YAML parsers accept `.nan` and `.inf` as valid float64 tokens, so the check
	// belongs here at the input boundary rather than deep in the simulation.
	if math.IsNaN(o.RiskLoad) || math.IsInf(o.RiskLoad, 0) {
		return nil, fmt.Errorf("%s: risk_load must be a finite number, got %g", path, o.RiskLoad)
	}
	if o.RiskLoad < 0 {
		return nil, fmt.Errorf("%s: risk_load must be >= 0, got %g; a negative load would make "+
			"carried risk less than tail risk, which is not a coherent risk posture", path, o.RiskLoad)
	}
	for name, m := range map[string]*money.Money{
		"transfer.annual_premium": &o.Transfer.AnnualPremium,
		"transfer.retention":      &o.Transfer.Retention,
		"transfer.limit":          &o.Transfer.Limit,
	} {
		r, err := m.Resolve(o.Currency, path+": "+name)
		if err != nil {
			return nil, err
		}
		*m = r
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
		if m.Currency == "" {
			m.Currency = o.Currency
		} else if err := m.Currency.Validate(); err != nil {
			return nil, fmt.Errorf("%s: magnitude %s: %w", path, id, err)
		}
		o.Magnitude[id] = m
	}
	return &o, nil
}
