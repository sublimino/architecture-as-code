package main

import (
	"fmt"
	"time"
)

// CurrentSchemaVersion is the default and active wire schema version for SLER enforcement contracts.
const CurrentSchemaVersion = "sler.signalloom.io/v1alpha1"

// SchemaVersionV1Alpha1 identifies the initial v1alpha1 version.
const SchemaVersionV1Alpha1 = "sler.signalloom.io/v1alpha1"

// PlaneOutcome represents the tri-state outcome of an enforcement or containment action on a specific plane.
// Defined as a typed string constant set rather than a bare int for self-describing JSON logs.
type PlaneOutcome string

const (
	// OutcomeContained indicates the plane successfully and fully enforced containment.
	OutcomeContained PlaneOutcome = "contained"
	// OutcomePartial indicates partial enforcement (e.g. partial lease revocation or non-fatal degraded state).
	OutcomePartial PlaneOutcome = "partial"
	// OutcomeUnavailable indicates the plane enforcement failed completely or the enforcement service was unreachable.
	OutcomeUnavailable PlaneOutcome = "unavailable"
	// OutcomeNotFound indicates there was no such target to enforce against.
	//
	// Added by SLER-P1-5. This is deliberately NOT a synonym for
	// OutcomeUnavailable. "Unavailable" tells an operator that the enforcement
	// plane could not be reached and sends them to check plane connectivity;
	// "not found" tells them the target ID itself was stale or mistyped and
	// sends them to check their targeting. Collapsing the two costs the
	// operator the one distinction that decides where to look, at the moment
	// they can least afford to look in the wrong place. It is also not a
	// failure: nothing was contained because there was nothing to contain.
	OutcomeNotFound PlaneOutcome = "not_found"
)

// IsValid checks if the PlaneOutcome is one of the recognized values.
func (o PlaneOutcome) IsValid() bool {
	switch o {
	case OutcomeContained, OutcomePartial, OutcomeUnavailable, OutcomeNotFound:
		return true
	default:
		return false
	}
}

// EnforcementPlane represents a distinct subsystem or plane responsible for containment.
type EnforcementPlane string

const (
	// PlaneMesh isolates network communication (e.g. Cilium / Istio / Envoy Gateway AuthorizationPolicy).
	PlaneMesh EnforcementPlane = "mesh"
	// PlaneBao revokes active credentials, tokens, and leases in OpenBao.
	PlaneBao EnforcementPlane = "bao"
	// PlaneSpire evicts SPIRE server entries and invalidates SVIDs.
	PlaneSpire EnforcementPlane = "spire"
	// PlaneAdmission blocks pod reconstitution and rescheduling via admission webhooks (node-capability-guard).
	PlaneAdmission EnforcementPlane = "admission"
	// PlaneFreeze freezes container processes in-place using cgroup v2 or SIGSTOP (stun-sentinel).
	PlaneFreeze EnforcementPlane = "freeze"
)

// IsValid checks if the EnforcementPlane is one of the recognized planes.
func (p EnforcementPlane) IsValid() bool {
	switch p {
	case PlaneMesh, PlaneBao, PlaneSpire, PlaneAdmission, PlaneFreeze:
		return true
	default:
		return false
	}
}

// AllEnforcementPlanes returns the standard list of 5 containment enforcement planes.
func AllEnforcementPlanes() []EnforcementPlane {
	return []EnforcementPlane{
		PlaneMesh,
		PlaneBao,
		PlaneSpire,
		PlaneAdmission,
		PlaneFreeze,
	}
}

// PlaneResult carries the detailed containment result from a single enforcement plane.
type PlaneResult struct {
	Plane     EnforcementPlane `json:"plane"`
	Outcome   PlaneOutcome     `json:"outcome"`
	Error     string           `json:"error,omitempty"`
	Timestamp string           `json:"timestamp"`
	LatencyMs int64            `json:"latency_ms,omitempty"`
	Details   map[string]any   `json:"details,omitempty"`
}

// TargetRef uniquely identifies the target workload/agent to be contained.
type TargetRef struct {
	AgentID   string `json:"agent_id"`
	Namespace string `json:"namespace"`
	PodName   string `json:"pod_name,omitempty"`
	SPIFFEID  string `json:"spiffe_id,omitempty"`
	NodeName  string `json:"node_name,omitempty"`
}

// ContainmentReason captures the context and trigger behind the containment decision.
type ContainmentReason struct {
	Code                  string `json:"code"`
	Description           string `json:"description"`
	TriggeredBy           string `json:"triggered_by"`
	DelegationEdgeRevoked bool   `json:"delegation_edge_revoked"`
	AttestationDigest     string `json:"attestation_digest,omitempty"`
}

// ContainmentDecision is the top-level dispatch and aggregation envelope for multi-plane containment.
type ContainmentDecision struct {
	DecisionID           string             `json:"decision_id"`
	SchemaVersion        string             `json:"schema_version"`
	IdempotencyKey       string             `json:"idempotency_key"`
	Target               TargetRef          `json:"target"`
	Reason               ContainmentReason  `json:"reason"`
	RequestedPlanes      []EnforcementPlane `json:"requested_planes"`
	PlaneResults         []PlaneResult      `json:"plane_results"`
	OverallOutcome       PlaneOutcome       `json:"overall_outcome"`
	DurationMs           int64              `json:"duration_ms"`
	Timestamp            string             `json:"timestamp"`
	AttestedRecordDigest string             `json:"attested_record_digest,omitempty"`
}

// NewContainmentDecision initializes a ContainmentDecision envelope with default schema version and timestamp.
func NewContainmentDecision(decisionID string, target TargetRef, reason ContainmentReason, planes []EnforcementPlane, idempotencyKey string) *ContainmentDecision {
	if planes == nil {
		planes = AllEnforcementPlanes()
	}
	return &ContainmentDecision{
		DecisionID:      decisionID,
		SchemaVersion:   CurrentSchemaVersion,
		IdempotencyKey:  idempotencyKey,
		Target:          target,
		Reason:          reason,
		RequestedPlanes: planes,
		PlaneResults:    make([]PlaneResult, 0, len(planes)),
		Timestamp:       time.Now().UTC().Format(time.RFC3339),
	}
}

// AggregateOutcome computes the aggregated PlaneOutcome from a set of PlaneResults.
func AggregateOutcome(results []PlaneResult) PlaneOutcome {
	if len(results) == 0 {
		return OutcomeUnavailable
	}
	containedCount := 0
	unavailableCount := 0
	partialCount := 0
	notFoundCount := 0

	for _, r := range results {
		switch r.Outcome {
		case OutcomeContained:
			containedCount++
		case OutcomeUnavailable:
			unavailableCount++
		case OutcomePartial:
			partialCount++
		case OutcomeNotFound:
			// Counted separately and NOT folded into unavailableCount. Falling
			// through to the default arm here is exactly the coercion
			// SLER-P1-5 exists to prevent.
			notFoundCount++
		default:
			// An outcome this build does not recognise is treated as a failure,
			// never as a success. Fail closed on the unknown.
			unavailableCount++
		}
	}

	switch {
	case containedCount == len(results):
		return OutcomeContained
	case notFoundCount == len(results):
		return OutcomeNotFound
	case containedCount == 0 && partialCount == 0:
		// Nothing was contained anywhere. A not_found entry contributes no
		// containment, so a mix of not_found and unavailable is still zero
		// containment achieved and must not read as "partial".
		return OutcomeUnavailable
	default:
		return OutcomePartial
	}
}

// MeshIsolationRequest defines the wire request for network mesh isolation.
type MeshIsolationRequest struct {
	SchemaVersion  string            `json:"schema_version"`
	IdempotencyKey string            `json:"idempotency_key"`
	AgentID        string            `json:"agent_id"`
	Namespace      string            `json:"namespace"`
	PodName        string            `json:"pod_name,omitempty"`
	SPIFFEID       string            `json:"spiffe_id,omitempty"`
	TargetIPs      []string          `json:"target_ips,omitempty"`
	Reason         string            `json:"reason"`
	Timestamp      string            `json:"timestamp"`
	Metadata       map[string]string `json:"metadata,omitempty"`
}

// MeshIsolationResponse defines the wire response for network mesh isolation.
type MeshIsolationResponse struct {
	SchemaVersion  string           `json:"schema_version"`
	IdempotencyKey string           `json:"idempotency_key"`
	AgentID        string           `json:"agent_id"`
	Plane          EnforcementPlane `json:"plane"`
	Outcome        PlaneOutcome     `json:"outcome"`
	PolicyApplied  bool             `json:"policy_applied"`
	ConnectionsCut int              `json:"connections_cut"`
	LatencyMs      int64            `json:"latency_ms"`
	Error          string           `json:"error,omitempty"`
	Timestamp      string           `json:"timestamp"`
}

// BaoRevokeRequest defines the wire request for OpenBao credential and lease revocation.
type BaoRevokeRequest struct {
	SchemaVersion   string   `json:"schema_version"`
	IdempotencyKey  string   `json:"idempotency_key"`
	AgentID         string   `json:"agent_id"`
	Namespace       string   `json:"namespace,omitempty"`
	LeaseIDs        []string `json:"lease_ids,omitempty"`
	TokenAccessor   string   `json:"token_accessor,omitempty"`
	RevokeAllTokens bool     `json:"revoke_all_tokens,omitempty"`
	Reason          string   `json:"reason"`
	Timestamp       string   `json:"timestamp"`
}

// BaoRevokeResponse defines the wire response for OpenBao credential and lease revocation.
type BaoRevokeResponse struct {
	SchemaVersion     string           `json:"schema_version"`
	IdempotencyKey    string           `json:"idempotency_key"`
	AgentID           string           `json:"agent_id"`
	Plane             EnforcementPlane `json:"plane"`
	Outcome           PlaneOutcome     `json:"outcome"`
	RevokedLeases     int              `json:"revoked_leases"`
	TokensInvalidated int              `json:"tokens_invalidated"`
	LatencyMs         int64            `json:"latency_ms"`
	Error             string           `json:"error,omitempty"`
	Timestamp         string           `json:"timestamp"`
}

// SpireEvictionRequest defines the wire request for SPIRE server entry eviction and SVID invalidation.
type SpireEvictionRequest struct {
	SchemaVersion  string   `json:"schema_version"`
	IdempotencyKey string   `json:"idempotency_key"`
	AgentID        string   `json:"agent_id"`
	SPIFFEID       string   `json:"spiffe_id"`
	EntryIDs       []string `json:"entry_ids,omitempty"`
	Reason         string   `json:"reason"`
	Timestamp      string   `json:"timestamp"`
}

// SpireEvictionResponse defines the wire response for SPIRE server entry eviction and SVID invalidation.
type SpireEvictionResponse struct {
	SchemaVersion    string           `json:"schema_version"`
	IdempotencyKey   string           `json:"idempotency_key"`
	AgentID          string           `json:"agent_id"`
	Plane            EnforcementPlane `json:"plane"`
	Outcome          PlaneOutcome     `json:"outcome"`
	EntriesEvicted   int              `json:"entries_evicted"`
	SVIDsInvalidated int              `json:"svids_invalidated"`
	LatencyMs        int64            `json:"latency_ms"`
	Error            string           `json:"error,omitempty"`
	Timestamp        string           `json:"timestamp"`
}

// AdmissionBlockRequest defines the wire request to block pod reconstitution at the admission controller.
type AdmissionBlockRequest struct {
	SchemaVersion  string            `json:"schema_version"`
	IdempotencyKey string            `json:"idempotency_key"`
	AgentID        string            `json:"agent_id"`
	Namespace      string            `json:"namespace"`
	SPIFFEID       string            `json:"spiffe_id,omitempty"`
	MatchLabels    map[string]string `json:"match_labels,omitempty"`
	TTLSeconds     int64             `json:"ttl_seconds,omitempty"`
	Reason         string            `json:"reason"`
	Timestamp      string            `json:"timestamp"`
}

// AdmissionBlockResponse defines the wire response from the admission controller.
type AdmissionBlockResponse struct {
	SchemaVersion  string           `json:"schema_version"`
	IdempotencyKey string           `json:"idempotency_key"`
	AgentID        string           `json:"agent_id"`
	Plane          EnforcementPlane `json:"plane"`
	Outcome        PlaneOutcome     `json:"outcome"`
	RuleID         string           `json:"rule_id,omitempty"`
	BlockEnforced  bool             `json:"block_enforced"`
	LatencyMs      int64            `json:"latency_ms"`
	Error          string           `json:"error,omitempty"`
	Timestamp      string           `json:"timestamp"`
}

// FreezeRequest defines the wire request for cgroup v2 / SIGSTOP process freeze.
type FreezeRequest struct {
	SchemaVersion  string            `json:"schema_version"`
	IdempotencyKey string            `json:"idempotency_key"`
	AgentID        string            `json:"agent_id"`
	Namespace      string            `json:"namespace"`
	PodName        string            `json:"pod_name,omitempty"`
	ContainerID    string            `json:"container_id,omitempty"`
	CgroupPath     string            `json:"cgroup_path,omitempty"`
	FreezeMethod   string            `json:"freeze_method,omitempty"`
	Reason         string            `json:"reason"`
	Timestamp      string            `json:"timestamp"`
	Metadata       map[string]string `json:"metadata,omitempty"`
}

// FreezeResponse defines the wire response from the stun sentinel freeze engine.
type FreezeResponse struct {
	SchemaVersion   string           `json:"schema_version"`
	IdempotencyKey  string           `json:"idempotency_key"`
	AgentID         string           `json:"agent_id"`
	Plane           EnforcementPlane `json:"plane"`
	Outcome         PlaneOutcome     `json:"outcome"`
	ProcessesFrozen int              `json:"processes_frozen"`
	CgroupState     string           `json:"cgroup_state,omitempty"`
	MemoryPreserved bool             `json:"memory_preserved"`
	LatencyMs       int64            `json:"latency_ms"`
	Error           string           `json:"error,omitempty"`
	Timestamp       string           `json:"timestamp"`
}

// ResumeToken carries an attributable governance token required to reverse a stun.
type ResumeToken struct {
	TokenID               string `json:"token_id"`
	AgentID               string `json:"agent_id"`
	OperatorID            string `json:"operator_id"`
	GovernanceApprovalRef string `json:"governance_approval_ref"`
	IssuedAt              string `json:"issued_at"`
	ExpiresAt             string `json:"expires_at"`
	Signature             string `json:"signature"`
}

// ResumeRequest defines the wire request to unfreeze a stunned agent.
type ResumeRequest struct {
	SchemaVersion  string      `json:"schema_version"`
	IdempotencyKey string      `json:"idempotency_key"`
	AgentID        string      `json:"agent_id"`
	Namespace      string      `json:"namespace"`
	Token          ResumeToken `json:"token"`
	Timestamp      string      `json:"timestamp"`
}

// ResumeResponse defines the wire response after unfreezing an agent.
type ResumeResponse struct {
	SchemaVersion      string `json:"schema_version"`
	IdempotencyKey     string `json:"idempotency_key"`
	AgentID            string `json:"agent_id"`
	Success            bool   `json:"success"`
	ProcessesResumed   int    `json:"processes_resumed"`
	CredentialsRotated bool   `json:"credentials_rotated"`
	LatencyMs          int64  `json:"latency_ms"`
	Error              string `json:"error,omitempty"`
	Timestamp          string `json:"timestamp"`
}

// ValidateDecision checks whether a ContainmentDecision meets all structural invariants.
func (d *ContainmentDecision) ValidateDecision() error {
	if d.DecisionID == "" {
		return fmt.Errorf("decision_id is required")
	}
	if d.SchemaVersion == "" {
		return fmt.Errorf("schema_version is required")
	}
	if d.IdempotencyKey == "" {
		return fmt.Errorf("idempotency_key is required")
	}
	if d.Target.AgentID == "" {
		return fmt.Errorf("target.agent_id is required")
	}
	if !d.OverallOutcome.IsValid() {
		return fmt.Errorf("overall_outcome %q is invalid", d.OverallOutcome)
	}
	for i, pr := range d.PlaneResults {
		if !pr.Plane.IsValid() {
			return fmt.Errorf("plane_results[%d].plane %q is invalid", i, pr.Plane)
		}
		if !pr.Outcome.IsValid() {
			return fmt.Errorf("plane_results[%d].outcome %q is invalid", i, pr.Outcome)
		}
	}
	return nil
}
