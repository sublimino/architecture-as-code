// Package frameworks loads the Gemara tension hierarchy from YAML files:
// Framework > ControlSet > Control > Check.
package frameworks

import (
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
)

// Framework is the top-level regulatory framework (e.g. nist-800-53, eu-ai-act).
type Framework struct {
	ID          string       `json:"id" yaml:"id"`
	Name        string       `json:"name" yaml:"name"`
	Version     string       `json:"version" yaml:"version"`
	Status      string       `json:"status,omitempty" yaml:"status,omitempty"`
	Description string       `json:"description,omitempty" yaml:"description,omitempty"`
	ControlSets []ControlSet `json:"controlSets" yaml:"controlSets"`
}

// ControlSet groups related controls (e.g. "AC - Access Control").
type ControlSet struct {
	ID          string    `json:"id" yaml:"id"`
	Name        string    `json:"name" yaml:"name"`
	Description string    `json:"description,omitempty" yaml:"description,omitempty"`
	Controls    []Control `json:"controls" yaml:"controls"`
}

// Control is a specific regulatory control (e.g. "AC-6 Least Privilege").
type Control struct {
	ID          string  `json:"id" yaml:"id"`
	Name        string  `json:"name" yaml:"name"`
	Description string  `json:"description,omitempty" yaml:"description,omitempty"`
	Checks      []Check `json:"checks" yaml:"checks"`
}

// Check is the atomic evaluation unit mapped to a CEL expression.
type Check struct {
	ID             string          `json:"id" yaml:"id"`
	Name           string          `json:"name" yaml:"name"`
	Description    string          `json:"description,omitempty" yaml:"description,omitempty"`
	CELExpression  string          `json:"celExpression" yaml:"celExpression"`
	Severity       string          `json:"severity,omitempty" yaml:"severity,omitempty"`
	Remediation    string          `json:"remediation,omitempty" yaml:"remediation,omitempty"`
	Status         string          `json:"status,omitempty" yaml:"status,omitempty"`
	RiskTriple     fair.RiskTriple `json:"riskTriple" yaml:"riskTriple"`
	FreqTriple     fair.RiskTriple `json:"freqTriple" yaml:"freqTriple"`
	PolicyVersions []string        `json:"policyVersions" yaml:"policyVersions"`
}
