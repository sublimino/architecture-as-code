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

// ResumeTokenSignature is one operator's Ed25519 signature over a ResumeToken.
//
// The signature covers the token body AND this entry's own OperatorID, KeyID and
// SignedAt — see SigningInputFor in resume_token.go. Binding the signer's
// identity into the signed bytes is what makes the token *attributable* rather
// than merely authentic. If the signature covered only the body, an attacker
// holding one valid token could move the signature bytes into a different
// signatures[] entry and rewrite operator_id to name somebody else; the
// signature would still verify and the forensic record would name the wrong
// human. That is the exact property this card exists to deliver, so it is
// cryptographic, not conventional.
type ResumeTokenSignature struct {
	// OperatorID is the signer's identity, normatively a SPIFFE ID.
	OperatorID string `json:"operator_id"`
	// KeyID is the self-certifying key handle "sha256:<hex>" over the raw
	// 32-byte Ed25519 public key. Self-certifying so a verifier can detect a
	// registry that has been re-pointed at an attacker's key.
	KeyID string `json:"key_id"`
	// Algorithm MUST be ResumeTokenAlgEd25519. Present so an unknown algorithm
	// is rejected explicitly rather than assumed, and so a post-quantum
	// migration is representable without a breaking change.
	Algorithm string `json:"alg"`
	// SignedAt is RFC3339 UTC, covered by the signature.
	SignedAt string `json:"signed_at"`
	// Signature is the raw 64-byte Ed25519 signature, base64 std-encoded
	// (with padding). See ResumeTokenSignatureEncoding.
	Signature string `json:"signature"`
}

// ResumeToken carries an attributable governance token required to reverse a stun.
//
// Every field below is part of the signed body except Signatures itself and the
// two scalar projections. The claim set is deliberately explicit: a claim that
// is not signed cannot be relied on, and a claim that is not present cannot be
// checked.
//
// The scalar OperatorID/Signature pair predates SLER-P1-3 and is retained: it is
// the FIRST signer's projection, so a single-operator break-glass token remains
// representable without an array, and a field a sibling card shipped one commit
// ago is not removed for tidiness. The duplication is made safe by an enforced
// invariant (ValidateStructure) rather than by convention — Signatures[0] must
// agree with both scalars or the token is malformed.
type ResumeToken struct {
	// SchemaVersion makes a detached token self-describing. ResumeRequest also
	// carries one; a token lifted out of its request must still be checkable.
	SchemaVersion string `json:"schema_version"`
	TokenID       string `json:"token_id"`
	// Algorithm MUST be ResumeTokenAlgEd25519 and must agree with every entry
	// in Signatures.
	Algorithm string `json:"alg"`
	// AgentID and Namespace together are the target binding. Namespace is not
	// optional: without it a token minted for agent-x in a staging namespace
	// resumes agent-x in production.
	AgentID   string `json:"agent_id"`
	Namespace string `json:"namespace"`
	// Audience names the cluster or sentinel fleet the token is valid at.
	Audience string `json:"audience"`
	// OperatorID is the first signer's identity — see Signatures.
	OperatorID            string `json:"operator_id"`
	GovernanceApprovalRef string `json:"governance_approval_ref"`
	IssuedAt              string `json:"issued_at"`
	ExpiresAt             string `json:"expires_at"`
	// Nonce is base64 std-encoded and MUST decode to at least
	// ResumeTokenMinNonceBytes of entropy. One encoding, not "hex or base64":
	// an alternative permitted by the spec is an alternative two
	// implementations can disagree about. It makes two otherwise-identical
	// tokens distinguishable, which
	// is what lets a verifier keep a single-use ledger without that ledger
	// collapsing legitimate retries — see the replay rule in the frozen
	// contract document.
	Nonce string `json:"nonce"`
	// TrustRootID names the operator-key trust root under which the minter
	// expects this token to be verified. The verifier MUST reject a token
	// naming a trust root other than its own pinned one.
	//
	// It exists because the self-certifying KeyID closes registry MIS-INDEXING
	// (an entry re-pointed at another key) but NOT a registry-WRITE adversary:
	// someone who can add a whole entry binding their own key to a victim's
	// operator_id passes every other check cleanly. No token format can close
	// that — it is a trust-root problem — but naming the root in the signed
	// body makes the pinning obligation part of the wire contract instead of an
	// assumption, and converts a silent substitution under a different root
	// into an explicit rejection. See the residual recorded in
	// docs/signalloom/sler-p1-3-frozen-contract.md §7.
	TrustRootID string `json:"trust_root_id"`
	// RequiredSignatures is the approval threshold recorded AT MINT TIME, from
	// the governance approval this token executes.
	//
	// The verifier enforces max(its own policy, this value), never this value
	// alone. That asymmetry is the whole point: the token may RAISE the bar but
	// can never lower it, so an attacker minting a token that claims 1 gains
	// nothing, while a genuine two-approval token that has had a signature
	// STRIPPED now fails — because the surviving body still says two were
	// required. Without this claim, "every signature must verify" is a validity
	// predicate and not a quorum predicate, and a stripped token is
	// indistinguishable from a legitimate single-operator one in the attested
	// record.
	RequiredSignatures int `json:"required_signatures"`
	// Signature is the first signer's signature — see Signatures.
	Signature string `json:"signature"`
	// Signatures carries every signer. A dual-control policy requires at least
	// two entries with DISTINCT OperatorID and DISTINCT KeyID; counting
	// signatures rather than distinct operators would be satisfied by one
	// operator holding two keys, which is not dual control.
	Signatures []ResumeTokenSignature `json:"signatures"`
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
