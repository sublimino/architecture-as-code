package main

import (
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
)

// PolicyRule is an individual evaluation rule in a bundle.
type PolicyRule struct {
	ID            string          `json:"id" yaml:"id"`
	Name          string          `json:"name" yaml:"name"`
	Description   string          `json:"description,omitempty" yaml:"description,omitempty"`
	CELExpression string          `json:"cel_expression" yaml:"cel_expression"`
	Severity      string          `json:"severity,omitempty" yaml:"severity,omitempty"`
	Remediation   string          `json:"remediation,omitempty" yaml:"remediation,omitempty"`
	Status        string          `json:"status,omitempty" yaml:"status,omitempty"`
	RiskTriple    fair.RiskTriple `json:"risk_triple,omitempty" yaml:"risk_triple,omitempty"`
	FreqTriple    fair.RiskTriple `json:"freq_triple,omitempty" yaml:"freq_triple,omitempty"`
}

// PolicyBundle represents a versioned set of rules for a framework and tenant.
type PolicyBundle struct {
	ID          string       `json:"id" yaml:"id"`
	FrameworkID string       `json:"framework_id" yaml:"framework_id"`
	TenantID    string       `json:"tenant_id,omitempty" yaml:"tenant_id,omitempty"`
	Version     string       `json:"version" yaml:"version"`
	Author      string       `json:"author" yaml:"author"`
	Description string       `json:"description,omitempty" yaml:"description,omitempty"`
	CreatedAt   string       `json:"created_at" yaml:"created_at"`
	Status      string       `json:"status,omitempty" yaml:"status,omitempty"`
	Rules       []PolicyRule `json:"rules" yaml:"rules"`
	RawBundle   string       `json:"raw_bundle,omitempty" yaml:"raw_bundle,omitempty"`
	Checksum    string       `json:"checksum" yaml:"checksum"`
}

// VersionHistoryItem provides a summary for a historical version of a bundle.
type VersionHistoryItem struct {
	Version     string `json:"version"`
	Author      string `json:"author"`
	Description string `json:"description"`
	CreatedAt   string `json:"created_at"`
	RuleCount   int    `json:"rule_count"`
	Checksum    string `json:"checksum"`
}

// PolicyBundleSummary summarizes the active bundle and version history for a framework.
type PolicyBundleSummary struct {
	FrameworkID    string               `json:"framework_id"`
	TenantID       string               `json:"tenant_id,omitempty"`
	ActiveVersion  string               `json:"active_version"`
	LatestVersion  string               `json:"latest_version"`
	ActiveBundle   *PolicyBundle        `json:"active_bundle"`
	VersionHistory []VersionHistoryItem `json:"version_history"`
}

// EvaluatePoliciesRequest defines the context for evaluating policies.
type EvaluatePoliciesRequest struct {
	TenantID      string         `json:"tenant_id,omitempty"`
	FrameworkID   string         `json:"framework_id,omitempty"`
	PolicyVersion string         `json:"policy_version,omitempty"`
	Agent         map[string]any `json:"agent,omitempty"`
	Request       map[string]any `json:"request,omitempty"`
	Manifest      map[string]any `json:"manifest,omitempty"`
	Object        map[string]any `json:"object,omitempty"`
}

// RuleEvaluationResult represents the outcome of evaluating a single rule.
type RuleEvaluationResult struct {
	RuleID      string  `json:"rule_id"`
	Name        string  `json:"name"`
	Passed      bool    `json:"passed"`
	Status      string  `json:"status,omitempty"`
	Severity    string  `json:"severity,omitempty"`
	Remediation string  `json:"remediation,omitempty"`
	Error       string  `json:"error,omitempty"`
	Cost        uint64  `json:"cost,omitempty"`
	LatencyMs   float64 `json:"latency_ms"`
	ALE         float64 `json:"ale"`
	VaR95       float64 `json:"var95"`
	TVaR        float64 `json:"tvar"`
	CarriedGBP  float64 `json:"carried_gbp"`
}

// EvaluatePoliciesResponse contains overall verdict and individual rule results.
type EvaluatePoliciesResponse struct {
	Compliant     bool                   `json:"compliant"`
	TenantID      string                 `json:"tenant_id,omitempty"`
	FrameworkID   string                 `json:"framework_id,omitempty"`
	PolicyVersion string                 `json:"policy_version"`
	TotalRules    int                    `json:"total_rules"`
	PassedRules   int                    `json:"passed_rules"`
	FailedRules   int                    `json:"failed_rules"`
	TotalExposure float64                `json:"total_exposure_gbp"`
	Results       []RuleEvaluationResult `json:"results"`
	EvaluatedAt   string                 `json:"evaluated_at"`
	EvaluationMs  float64                `json:"evaluation_ms"`
}

// RollbackRequest defines parameters for reverting a bundle to an earlier version.
type RollbackRequest struct {
	TenantID      string `json:"tenant_id,omitempty"`
	FrameworkID   string `json:"framework_id"`
	TargetVersion string `json:"target_version"`
}
