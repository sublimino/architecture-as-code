// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package attestation

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Schema and Predicate constants per SLER-P5-PRE contract.
const (
	ForensicSchemaVersion    = "sler.signalloom.io/v1alpha1"
	ContainmentPredicateType = "https://controlplane.io/attestations/signalloom-containment/v1"
	ResumePredicateType      = "https://controlplane.io/attestations/signalloom-resume/v1"
	InTotoStatementType      = "https://in-toto.io/Statement/v1"
	DSSEPayloadType          = "application/vnd.in-toto+json"
	SigningAlgorithmEd25519  = "ed25519"
)

// ForensicEventType identifies the lifecycle phase of the containment action.
type ForensicEventType string

const (
	EventContainmentDispatched   ForensicEventType = "containment_dispatched"
	EventContainmentCompleted    ForensicEventType = "containment_completed"
	EventContainmentFailed       ForensicEventType = "containment_failed"
	EventContainmentResumed      ForensicEventType = "containment_resumed"
	EventContainmentResumeFailed ForensicEventType = "containment_resume_failed"
)

// AuthorizationEvidence captures the decision authority that mandated containment.
type AuthorizationEvidence struct {
	DecisionID            string `json:"decision_id"`
	TriggerReason         string `json:"trigger_reason"`
	TriggerDescription    string `json:"trigger_description,omitempty"`
	TriggeredBy           string `json:"triggered_by"`
	DelegationEdgeRevoked bool   `json:"delegation_edge_revoked"`
	AttestationDigest     string `json:"attestation_digest,omitempty"`
}

// TargetIdentity captures the complete runtime coordinates of the contained entity.
// This representation directly matches the identity models in admission_client and mesh_client.
type TargetIdentity struct {
	AgentID     string `json:"agent_id"`
	Namespace   string `json:"namespace"`
	PodName     string `json:"pod_name,omitempty"`
	PodUID      string `json:"pod_uid,omitempty"`
	SPIFFEID    string `json:"spiffe_id,omitempty"`
	NodeName    string `json:"node_name,omitempty"`
	ContainerID string `json:"container_id,omitempty"`
	CgroupPath  string `json:"cgroup_path,omitempty"`
	PIDs        []int  `json:"pids,omitempty"`
	TenantID    string `json:"tenant_id,omitempty"`
}

// PlaneExecutionEvidence captures the per-plane enforcement outcome and residual window.
type PlaneExecutionEvidence struct {
	Plane               string         `json:"plane"` // mesh, bao, spire, admission, freeze
	Outcome             string         `json:"outcome"`
	LatencyMs           int64          `json:"latency_ms"`
	WorstCaseResidualMs int64          `json:"worst_case_residual_ms"`
	Error               string         `json:"error,omitempty"`
	Details             map[string]any `json:"details,omitempty"`
}

// ExecutionEvidence captures aggregate multi-plane execution outcomes.
type ExecutionEvidence struct {
	OverallOutcome string                   `json:"overall_outcome"` // contained, partial, unavailable, not_found
	TotalLatencyMs int64                    `json:"total_latency_ms"`
	Planes         []PlaneExecutionEvidence `json:"planes"`
}

// GovernanceResumeEvidence captures operator attribution and unfreeze audit data.
type GovernanceResumeEvidence struct {
	TokenID               string   `json:"token_id"`
	OperatorIDs           []string `json:"operator_ids"`
	GovernanceApprovalRef string   `json:"governance_approval_ref,omitempty"`
	CredentialsRotated    bool     `json:"credentials_rotated"`
	ProcessesResumed      int      `json:"processes_resumed"`
	UnfreezeLatencyMs     int64    `json:"unfreeze_latency_ms"`
}

// AttestationEnvelopeMetadata carries cryptographic signature provenance.
type AttestationEnvelopeMetadata struct {
	AttesterComponent string `json:"attester_component"`
	KeyID             string `json:"key_id"`
	Algorithm         string `json:"algorithm"`
	StatementDigest   string `json:"statement_digest"`
	Signature         string `json:"signature"`
}

// InTotoSubject identifies the subject of an in-toto statement.
type InTotoSubject struct {
	Name   string            `json:"name"`
	Digest map[string]string `json:"digest"`
}

// ForensicLedgerRecord is the complete, canonical attested forensic event.
type ForensicLedgerRecord struct {
	SchemaVersion    string                      `json:"schema_version"`
	EventID          string                      `json:"event_id"`
	EventType        ForensicEventType           `json:"event_type"`
	Timestamp        string                      `json:"timestamp"` // RFC3339Nano UTC
	IdempotencyKey   string                      `json:"idempotency_key"`
	Authorization    AuthorizationEvidence       `json:"authorization"`
	Target           TargetIdentity              `json:"target"`
	Execution        ExecutionEvidence           `json:"execution"`
	GovernanceResume *GovernanceResumeEvidence   `json:"governance_resume,omitempty"`
	Attestation      AttestationEnvelopeMetadata `json:"attestation"`

	// Forward-compatible extension bucket for future additive schema evolutions
	Extensions map[string]any `json:"extensions,omitempty"`
}

// Validate ensures all mandatory schema invariants are satisfied.
func (r *ForensicLedgerRecord) Validate() error {
	if r.SchemaVersion == "" {
		return errors.New("schema_version is required")
	}
	if r.EventID == "" {
		return errors.New("event_id is required")
	}
	if r.EventType == "" {
		return errors.New("event_type is required")
	}
	if r.Timestamp == "" {
		return errors.New("timestamp is required")
	}
	if _, err := time.Parse(time.RFC3339Nano, r.Timestamp); err != nil {
		if _, err := time.Parse(time.RFC3339, r.Timestamp); err != nil {
			return fmt.Errorf("invalid RFC3339 timestamp %q: %w", r.Timestamp, err)
		}
	}
	if r.Authorization.DecisionID == "" {
		return errors.New("authorization.decision_id is required")
	}
	if r.Authorization.TriggerReason == "" {
		return errors.New("authorization.trigger_reason is required")
	}
	if r.Authorization.TriggeredBy == "" {
		return errors.New("authorization.triggered_by is required")
	}
	if r.Target.AgentID == "" {
		return errors.New("target.agent_id is required")
	}
	if r.Target.Namespace == "" {
		return errors.New("target.namespace is required")
	}
	if r.Execution.OverallOutcome == "" {
		return errors.New("execution.overall_outcome is required")
	}
	return nil
}

// ToInTotoStatement builds a canonical in-toto Statement v1 structure.
func (r *ForensicLedgerRecord) ToInTotoStatement() (map[string]any, error) {
	if err := r.Validate(); err != nil {
		return nil, fmt.Errorf("validate record before statement conversion: %w", err)
	}

	predicateType := ContainmentPredicateType
	if r.EventType == EventContainmentResumed || r.EventType == EventContainmentResumeFailed {
		predicateType = ResumePredicateType
	}

	// Calculate target digest for subject mapping
	targetBytes, _ := json.Marshal(r.Target)
	targetDigest := sha256.Sum256(targetBytes)

	subject := []InTotoSubject{
		{
			Name: fmt.Sprintf("agent:%s/%s", r.Target.Namespace, r.Target.AgentID),
			Digest: map[string]string{
				"sha256": hex.EncodeToString(targetDigest[:]),
			},
		},
	}
	if r.Target.PodUID != "" {
		subject = append(subject, InTotoSubject{
			Name: fmt.Sprintf("k8s:pod:%s/%s", r.Target.Namespace, r.Target.PodUID),
			Digest: map[string]string{
				"sha256": hex.EncodeToString(targetDigest[:]),
			},
		})
	}

	// Prepare predicate payload excluding attestation envelope itself
	predicateCopy := *r
	predicateCopy.Attestation = AttestationEnvelopeMetadata{} // zero out to prevent recursive digest loops

	stmt := map[string]any{
		"_type":         InTotoStatementType,
		"subject":       subject,
		"predicateType": predicateType,
		"predicate":     predicateCopy,
	}

	return stmt, nil
}

// ComputeStatementDigest returns the SHA-256 hex digest of the in-toto statement representation.
func ComputeStatementDigest(statement map[string]any) (string, error) {
	raw, err := json.Marshal(statement)
	if err != nil {
		return "", fmt.Errorf("marshal statement for digest: %w", err)
	}
	h := sha256.Sum256(raw)
	return hex.EncodeToString(h[:]), nil
}
