package privacy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// MaxRequestAge bounds how long an erasure request may sit between being made and being decided.
//
// This is a policy choice, not a derivation, and it is stated here rather than buried at a call
// site. A request carries an implicit claim that the world has not materially changed since it was
// made; that claim decays. Seven days is long enough to survive a weekend, a public holiday and a
// round of internal review, and short enough that a request made before an incident opened cannot
// be executed after it. Requests older than this are refused with ErrRequestStale and must be
// re-submitted, which puts a fresh human and a fresh incident check back in the loop.
const MaxRequestAge = 7 * 24 * time.Hour

// Trace phase markers. The Decision records these in the order the phases actually executed, which
// is what makes "the hold check runs before any key operation" an assertable property rather than a
// claim in a comment.
const (
	TraceValidateRequest   = "validate_request"
	TraceEvaluateHold      = "evaluate_legal_hold"
	TraceEvaluateException = "evaluate_retention_exception"
	TraceWriteAudit        = "write_audit"
	TraceDestroyKeys       = "destroy_subject_keys"
)

// Outcome is the machine-readable result of an erasure decision.
type Outcome string

const (
	// OutcomeErased means key destruction was permitted and performed.
	OutcomeErased Outcome = "erased"
	// OutcomeErasedUnderException means an active hold was overridden by a valid retention
	// exception and key destruction proceeded.
	OutcomeErasedUnderException Outcome = "erased_under_exception"
	// OutcomeRefusedLegalHold means an active hold blocked the erasure and no valid override was
	// presented.
	OutcomeRefusedLegalHold Outcome = "refused_legal_hold"
	// OutcomeRefusedIncidentStateUnavailable means incident state could not be determined.
	OutcomeRefusedIncidentStateUnavailable Outcome = "refused_incident_state_unavailable"
	// OutcomeRefusedInvalidOverride means an override was presented and rejected.
	OutcomeRefusedInvalidOverride Outcome = "refused_invalid_override"
	// OutcomeRefusedInvalidRequest means the request itself was malformed or stale.
	OutcomeRefusedInvalidRequest Outcome = "refused_invalid_request"
	// OutcomeRefusedAuditUnavailable means the decision could not be recorded, so it was not acted
	// upon.
	OutcomeRefusedAuditUnavailable Outcome = "refused_audit_unavailable"
	// OutcomeRefusedDestructionFailed means every gate passed but key destruction itself errored.
	OutcomeRefusedDestructionFailed Outcome = "refused_destruction_failed"
)

var (
	// ErrLegalHold is returned when an active hold blocks erasure. Distinct from
	// ErrIncidentStateUnavailable: this one means "we know you are held".
	ErrLegalHold = errors.New("erasure refused: subject is under an active Article 17(3) legal hold")

	// ErrRequestStale is returned when a request is older than MaxRequestAge.
	ErrRequestStale = errors.New("erasure refused: request is stale and must be re-submitted against current incident state")

	// ErrInvalidRequest is returned when the request is structurally malformed.
	ErrInvalidRequest = errors.New("erasure request is invalid")

	// ErrAuditUnavailable is returned when the decision could not be written to the audit trail.
	// Because an unrecorded destruction is indistinguishable from one that never happened, this
	// refuses rather than proceeding.
	ErrAuditUnavailable = errors.New("erasure refused: the decision could not be written to the audit trail")

	// ErrRefusalNotRecorded wraps a refusal whose audit write itself failed. The refusal stands —
	// nothing was destroyed — but the caller is told that no trace of it exists, because a refusal
	// nobody can see is an Article 12 transparency problem of its own.
	ErrRefusalNotRecorded = errors.New("erasure was refused but the refusal could not be recorded")
)

// KeyDestructionReceipt is what a KeyDestroyer returns on success.
//
// SLDP-P4-1 filled this in. The first four fields are the original seam and are unchanged; the rest
// are additive and carry the values SLDP-P4-2's attested tombstone needs. The rich, per-version form
// lives in package subjectkey as DestructionReceipt — only scalars cross into this package, because
// privacy declares the KeyDestroyer interface that subjectkey implements and importing it back would
// be a cycle.
//
// ReceiptDigest is the field the tombstone carries. It is a SHA-256 over subjectkey's canonical
// encoding of the full receipt, salted by a persisted per-operation nonce so the digest cannot be
// ground out from a guessed subject identifier — which would turn the tombstone into the
// re-identification oracle SLDP-P4-PRE §6.1 forbids.
//
// NOTE for SLDP-P4-2: SubjectID here is CLEARTEXT, because privacy.KeyDestroyer is called with the
// cleartext subject and this struct is an in-process return value, not an audit row. It must NOT be
// copied into a tombstone; use SubjectPseudonym from Decision, or nothing at all.
type KeyDestructionReceipt struct {
	SubjectID   string    `json:"subject_id"`
	TenantID    string    `json:"tenant_id"`
	KeysRemoved int       `json:"keys_removed"`
	DestroyedAt time.Time `json:"destroyed_at"`

	// OperationID is the deterministic, keyed identifier of the erasure saga. Two erasure requests
	// naming the same subject resolve to the same operation, and therefore to one destruction and
	// one tombstone.
	OperationID string `json:"operation_id,omitempty"`
	// ReceiptSchema is the version-pinned schema label the digest was computed under.
	ReceiptSchema string `json:"receipt_schema,omitempty"`
	// ReceiptDigest is the hex SHA-256 a tombstone references.
	ReceiptDigest string `json:"receipt_digest,omitempty"`
	// ResidualPseudonym states what the destruction could not remove.
	ResidualPseudonym string `json:"residual_pseudonym,omitempty"`
	// StorageResidual states which copies of the ciphertext survive.
	StorageResidual string `json:"storage_residual,omitempty"`
	// ComplianceNote states which obligation was discharged and which was not.
	ComplianceNote string `json:"compliance_note,omitempty"`
}

// KeyDestroyer performs the irreversible act this package gates.
//
// Nothing in this package implements it against real key material. It is declared here so the gate
// exists before the mechanism, and so there is never a commit in which unconstrained on-demand
// crypto-shredding is reachable.
type KeyDestroyer interface {
	DestroySubjectKeys(ctx context.Context, tenantID, subjectID string) (KeyDestructionReceipt, error)
}

// SubjectPseudonymiser produces a tenant-scoped keyed pseudonym for a subject identifier. It is the
// narrow slice of identity.Encryptor this package needs.
//
// It is mandatory rather than optional: an audit trail of refused erasures is a list of the exact
// identifiers a data subject asked to have removed, so writing the cleartext subject into it would
// make the transparency mechanism a re-identification corpus.
type SubjectPseudonymiser interface {
	Pseudonym(tenantID, value string) (string, error)
}

// ErasureRequest is one data subject's Article 17 request as presented to the service.
type ErasureRequest struct {
	// RequestID uniquely identifies the request. It is bound into any retention exception, so a
	// override granted for one request cannot be replayed against another.
	RequestID string `json:"request_id"`

	// TenantID scopes the request.
	TenantID string `json:"tenant_id"`

	// SubjectID is the data subject whose keys would be destroyed.
	SubjectID string `json:"subject_id"`

	// RequestedBy identifies the operator submitting the request. It is checked against the
	// override approvers so that one person cannot both request and approve.
	RequestedBy string `json:"requested_by"`

	// RequestedAt is when the request was made. Mandatory: a zero value would be treated as age
	// zero, which would make every stale request look fresh.
	RequestedAt time.Time `json:"requested_at"`

	// Exception, when present, is the dual-operator signed override.
	Exception *RetentionException `json:"exception,omitempty"`
}

// Decision is the complete, recordable result of evaluating an erasure request.
type Decision struct {
	RequestID string  `json:"request_id"`
	TenantID  string  `json:"tenant_id"`
	Permitted bool    `json:"permitted"`
	Outcome   Outcome `json:"outcome"`
	Reason    string  `json:"reason"`

	// SubjectPseudonym is the keyed pseudonym of the subject. The cleartext subject is deliberately
	// absent from this struct so it cannot reach an audit row by accident.
	SubjectPseudonym string `json:"subject_pseudonym"`

	// Holds are the active holds considered, in deterministic order.
	Holds []Hold `json:"holds,omitempty"`

	// HoldIDs is the projection of Holds used in refusal bodies and audit detail.
	HoldIDs []string `json:"hold_ids,omitempty"`

	// RequiredGround is the Article 17(3) ground a legitimate override would name. Populated on
	// every hold-based refusal so the operator is told what would unblock them rather than merely
	// that they are blocked.
	RequiredGround LegalGround `json:"required_ground,omitempty"`

	// Ground is the ground actually relied upon, populated when an override was accepted.
	Ground LegalGround `json:"ground,omitempty"`

	// Approvers are the distinct operator identities that authorised an accepted override, sorted.
	Approvers []string `json:"approvers,omitempty"`

	// ExceptionExpiresAt and ExceptionReviewBy record the time bounds of an accepted override.
	ExceptionExpiresAt time.Time `json:"exception_expires_at,omitempty"`
	ExceptionReviewBy  time.Time `json:"exception_review_by,omitempty"`

	// Trace is the ordered list of phases that executed.
	Trace []string `json:"trace"`

	// DecidedAt is the decision-time clock reading against which holds were evaluated.
	DecidedAt time.Time `json:"decided_at"`

	// AuditRecorded reports whether the decision reached the audit trail.
	AuditRecorded bool `json:"audit_recorded"`

	// Receipt is populated only when key destruction actually occurred.
	Receipt *KeyDestructionReceipt `json:"receipt,omitempty"`
}

// TraceIndex returns the position of phase in the trace, or -1 if it did not execute. Ordering
// assertions use it directly.
func (d Decision) TraceIndex(phase string) int {
	for i, p := range d.Trace {
		if p == phase {
			return i
		}
	}
	return -1
}

// Config carries the Service's injectable dependencies. Every external boundary is here; none is
// reached for implicitly.
type Config struct {
	Incidents     IncidentSource
	Destroyer     KeyDestroyer
	Audit         audit.AuditWriter
	Operators     *OperatorRegistry
	Pseudonymiser SubjectPseudonymiser

	// Now overrides the clock. A nil Now defaults to time.Now, which is a safe default because a
	// real clock is the conservative choice; contrast Incidents, where no safe default exists and
	// nil is refused.
	Now func() time.Time
}

// Service evaluates erasure requests against legal holds.
type Service struct {
	incidents     IncidentSource
	destroyer     KeyDestroyer
	audit         audit.AuditWriter
	operators     *OperatorRegistry
	pseudonymiser SubjectPseudonymiser
	now           func() time.Time
}

// NewService constructs the erasure gate.
//
// Every dependency is rejected when nil. There is deliberately no partially-configured Service and
// no permissive default: a Service with a nil IncidentSource that treated nil as "no holds" would
// be the exact defect this package exists to prevent, and it would be reachable from a single
// forgotten wiring line in main.go.
func NewService(cfg Config) (*Service, error) {
	if cfg.Incidents == nil {
		return nil, errors.New("incident source is required: without it the service cannot demonstrate the absence of a legal hold, and absence of evidence is not evidence of absence")
	}
	if cfg.Destroyer == nil {
		return nil, errors.New("key destroyer is required")
	}
	if cfg.Audit == nil {
		return nil, errors.New("audit writer is required: an unrecorded erasure decision is indistinguishable from one that never happened")
	}
	if !audit.GetAuditPosture(cfg.Audit).Healthy {
		return nil, errors.New("healthy fail-closed audit writer is required")
	}
	if cfg.Operators == nil || cfg.Operators.Len() == 0 {
		return nil, errors.New("a non-empty operator registry is required")
	}
	if cfg.Pseudonymiser == nil {
		return nil, errors.New("subject pseudonymiser is required: refusal audit records must not carry cleartext subject identifiers")
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &Service{
		incidents:     cfg.Incidents,
		destroyer:     cfg.Destroyer,
		audit:         cfg.Audit,
		operators:     cfg.Operators,
		pseudonymiser: cfg.Pseudonymiser,
		now:           now,
	}, nil
}

// Erase evaluates req and, only if every gate passes, destroys the subject's keys.
//
// The phase order below is the control. Reading top to bottom: the request is validated, incident
// state is resolved, holds are evaluated, any override is verified, the decision is written to the
// audit trail, and only then is the KeyDestroyer reached. Every early return leaves the destroyer
// untouched, and Decision.Trace records which phases ran so the ordering is assertable from outside.
func (s *Service) Erase(ctx context.Context, req ErasureRequest) (Decision, error) {
	now := s.now().UTC()
	d := Decision{
		RequestID: req.RequestID,
		TenantID:  req.TenantID,
		DecidedAt: now,
	}

	// ---- Phase 1: request validation. -------------------------------------------------------
	d.Trace = append(d.Trace, TraceValidateRequest)
	if err := validateRequest(req, now); err != nil {
		outcome := OutcomeRefusedInvalidRequest
		return s.refuse(ctx, d, req, outcome, err)
	}
	// Pseudonymisation happens before any audit write so that no refusal path can fall back to a
	// cleartext subject when it is in a hurry.
	pseudonym, err := s.pseudonymiser.Pseudonym(req.TenantID, req.SubjectID)
	if err != nil {
		return s.refuse(ctx, d, req, OutcomeRefusedInvalidRequest, fmt.Errorf("%w: pseudonymise subject: %v", ErrInvalidRequest, err))
	}
	d.SubjectPseudonym = pseudonym

	// ---- Phase 2: legal hold evaluation. ----------------------------------------------------
	// This runs before the KeyDestroyer is referenced anywhere in this function. An error here is
	// "undetermined", and undetermined refuses.
	d.Trace = append(d.Trace, TraceEvaluateHold)
	res, err := s.incidents.ActiveHolds(ctx, req.TenantID, req.SubjectID)
	if err != nil {
		return s.refuse(ctx, d, req, OutcomeRefusedIncidentStateUnavailable,
			fmt.Errorf("%w: %v", ErrIncidentStateUnavailable, err))
	}
	// A source that declined jurisdiction did not look, and "did not look" is not "found nothing".
	// CompositeIncidentSource already refuses an all-declined query, but a bare single source wired
	// straight into the Service would not, so the check lives here too — the Service must not be
	// safe only when it happens to be composed.
	if !res.Jurisdiction {
		return s.refuse(ctx, d, req, OutcomeRefusedIncidentStateUnavailable,
			fmt.Errorf("%w: %w: tenant %q", ErrIncidentStateUnavailable, ErrNoJurisdiction, req.TenantID))
	}
	// Holds are filtered against the DECISION-time clock, never the request-time clock. See the
	// package comment on a hold expiring while a request is pending.
	active := activeHoldsAt(res.Holds, now)
	d.Holds = active
	d.HoldIDs = holdIDs(active)

	// ---- Phase 3: override evaluation, only when something is actually blocking. -------------
	if len(active) > 0 {
		d.RequiredGround = GroundLegalClaims
		d.Trace = append(d.Trace, TraceEvaluateException)
		if req.Exception == nil {
			return s.refuse(ctx, d, req, OutcomeRefusedLegalHold,
				fmt.Errorf("%w: %d active hold(s): %v", ErrLegalHold, len(active), d.HoldIDs))
		}
		approvers, err := req.Exception.authorises(req, s.operators, now)
		if err != nil {
			return s.refuse(ctx, d, req, OutcomeRefusedInvalidOverride, err)
		}
		d.Ground = req.Exception.Ground
		d.Approvers = approvers
		d.ExceptionExpiresAt = req.Exception.ExpiresAt.UTC()
		d.ExceptionReviewBy = req.Exception.ReviewBy.UTC()
		d.Outcome = OutcomeErasedUnderException
		d.Reason = fmt.Sprintf("active hold(s) %v overridden under %s by %v", d.HoldIDs, req.Exception.Ground.Description(), approvers)
	} else {
		d.Outcome = OutcomeErased
		d.Reason = "no active legal hold"
	}
	d.Permitted = true

	// ---- Phase 4: record the decision BEFORE acting on it. -----------------------------------
	// Writing the audit row first is what makes an unrecorded destruction impossible. If the audit
	// backend is down the erasure is refused, because "destroyed but not recorded" is strictly
	// worse than "not destroyed".
	d.Trace = append(d.Trace, TraceWriteAudit)
	if err := s.writeDecision(ctx, d); err != nil {
		d.Permitted = false
		d.Receipt = nil
		d.AuditRecorded = false
		d.Outcome = OutcomeRefusedAuditUnavailable
		d.Reason = "audit trail unavailable; erasure refused rather than performed unrecorded"
		slog.Error("erasure refused: audit trail unavailable",
			"request_id", req.RequestID, "tenant_id", req.TenantID, "error", err)
		return d, fmt.Errorf("%w: %v", ErrAuditUnavailable, err)
	}
	d.AuditRecorded = true

	// ---- Phase 5: the irreversible act. ------------------------------------------------------
	d.Trace = append(d.Trace, TraceDestroyKeys)
	receipt, err := s.destroyer.DestroySubjectKeys(ctx, req.TenantID, req.SubjectID)
	if err != nil {
		d.Permitted = false
		d.Outcome = OutcomeRefusedDestructionFailed
		d.Reason = "key destruction failed after authorisation"
		return d, fmt.Errorf("destroy subject keys: %w", err)
	}
	d.Receipt = &receipt
	return d, nil
}

// validateRequest enforces every structural and freshness rule on the request itself.
func validateRequest(req ErasureRequest, now time.Time) error {
	if req.RequestID == "" {
		return fmt.Errorf("%w: request_id is required", ErrInvalidRequest)
	}
	if req.TenantID == "" {
		return fmt.Errorf("%w: tenant_id is required", ErrInvalidRequest)
	}
	if req.SubjectID == "" {
		return fmt.Errorf("%w: subject_id is required", ErrInvalidRequest)
	}
	if req.RequestedBy == "" {
		return fmt.Errorf("%w: requested_by is required so that requester and approver can be compared", ErrInvalidRequest)
	}
	if req.RequestedAt.IsZero() {
		return fmt.Errorf("%w: requested_at is unset; a zero timestamp would make every stale request read as fresh", ErrInvalidRequest)
	}
	if req.RequestedAt.After(now) {
		return fmt.Errorf("%w: requested_at is in the future", ErrInvalidRequest)
	}
	if now.Sub(req.RequestedAt) > MaxRequestAge {
		return fmt.Errorf("%w: request is %s old, exceeding MaxRequestAge of %s", ErrRequestStale, now.Sub(req.RequestedAt).Truncate(time.Second), MaxRequestAge)
	}
	return nil
}

// refuse finalises a refused decision, records it, and returns it alongside the refusal error.
//
// The KeyDestroyer is unreachable from here by construction — this function has no reference to it.
// That is not decoration: it means no refusal path can acquire one through a later edit without the
// edit being visible in this function's body.
func (s *Service) refuse(ctx context.Context, d Decision, req ErasureRequest, outcome Outcome, cause error) (Decision, error) {
	d.Permitted = false
	d.Outcome = outcome
	d.Reason = cause.Error()
	if d.SubjectPseudonym == "" {
		// A refusal before pseudonymisation succeeded still needs an audit row. The marker is a
		// fixed non-empty string rather than the cleartext subject or an empty field: empty would
		// read as "not populated", and the cleartext would defeat the point.
		d.SubjectPseudonym = "unavailable"
	}
	slog.Warn("erasure refused",
		"request_id", req.RequestID,
		"tenant_id", req.TenantID,
		"outcome", string(outcome),
		"hold_ids", d.HoldIDs,
		"required_ground", string(d.RequiredGround),
		"reason", cause.Error())

	if err := s.writeDecision(ctx, d); err != nil {
		d.AuditRecorded = false
		slog.Error("erasure refusal could not be recorded",
			"request_id", req.RequestID, "outcome", string(outcome), "error", err)
		return d, fmt.Errorf("%w: %w (audit error: %v)", ErrRefusalNotRecorded, cause, err)
	}
	d.AuditRecorded = true
	return d, cause
}

// writeDecision persists the decision to the tamper-evident audit trail.
//
// Event type selection, and why it is not a new constant: signal_audit_trail's event_type CHECK
// constraint lives in d2-signalloom/contracts/discovery-portal-bootstrap.sql, outside this card's
// ownership boundary, so adding a value would require changing a contract this card does not own.
// The established precedent (api/auth.go, SLDP-P1-1) is to reuse a legal event type and carry the
// specific semantics in the detail's "category" key. A permitted erasure uses partition_dropped,
// whose meaning — data destroyed — is exact, and which had zero call sites until now.
func (s *Service) writeDecision(ctx context.Context, d Decision) error {
	eventType := audit.EventActorUpdated
	if d.Permitted {
		eventType = audit.EventPartitionDropped
	}
	payload := map[string]any{
		"category":          "erasure_decision",
		"outcome":           string(d.Outcome),
		"permitted":         d.Permitted,
		"request_id":        d.RequestID,
		"subject_pseudonym": d.SubjectPseudonym,
		"reason":            d.Reason,
		"hold_ids":          d.HoldIDs,
		"trace":             d.Trace,
		"decided_at":        d.DecidedAt.Format(time.RFC3339Nano),
	}
	if d.RequiredGround != "" {
		payload["required_ground"] = string(d.RequiredGround)
		payload["required_ground_description"] = d.RequiredGround.Description()
	}
	if d.Ground != "" {
		payload["ground"] = string(d.Ground)
		payload["ground_description"] = d.Ground.Description()
	}
	if len(d.Approvers) > 0 {
		payload["approvers"] = d.Approvers
		payload["exception_expires_at"] = d.ExceptionExpiresAt.Format(time.RFC3339Nano)
		payload["exception_review_by"] = d.ExceptionReviewBy.Format(time.RFC3339Nano)
	}
	detail, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal erasure audit detail: %w", err)
	}
	tenant := d.TenantID
	if tenant == "" {
		tenant = "unknown"
	}
	return s.audit.WriteAuditEvent(ctx, audit.Event{
		TenantID:  tenant,
		EventType: eventType,
		Detail:    detail,
		CreatedAt: d.DecidedAt,
	})
}
