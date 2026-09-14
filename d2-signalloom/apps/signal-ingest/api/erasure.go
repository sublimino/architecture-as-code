package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// ErasureRequestBody is the wire form of a GDPR Article 17 erasure request.
//
// The subject is taken from the route path, not from the body, so that the router's actor-scoping
// check and the subject actually erased cannot disagree. A body-supplied subject would let a
// principal authorised for actor A pass the route guard and then name actor B.
type ErasureRequestBody struct {
	RequestID   string                      `json:"request_id"`
	RequestedBy string                      `json:"requested_by"`
	RequestedAt time.Time                   `json:"requested_at"`
	Exception   *privacy.RetentionException `json:"exception,omitempty"`
}

// ErasureResponse is what the caller reads. It carries the whole decision rather than a bare status
// because an operator blocked by a hold needs to know which hold, and what would unblock them.
//
// A silent block is indistinguishable from a broken feature. Remediation is therefore a populated
// field on every refusal, not prose in a log line nobody reads.
type ErasureResponse struct {
	privacy.Decision
	Remediation string `json:"remediation,omitempty"`
}

// handleEraseSubject serves POST /api/v1/privacy/erasure/{id}.
func (h *Handlers) handleEraseSubject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	// 503 rather than 500: an unconfigured privacy service is a deployment that cannot answer, not
	// a request that went wrong. It is also the fail-closed answer — with no gate configured, no
	// erasure may proceed.
	if h.Privacy == nil {
		writeError(w, http.StatusServiceUnavailable, "erasure gate is not configured; no erasure may proceed")
		return
	}
	subjectID := r.PathValue("id")
	if subjectID == "" {
		writeError(w, http.StatusBadRequest, "subject id is required")
		return
	}
	tenant, ok := TenantContextFromContext(r.Context())
	if !ok || tenant.TenantID == "" {
		writeError(w, http.StatusServiceUnavailable, "tenant context missing")
		return
	}

	var body ErasureRequestBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid json erasure request: %v", err))
		return
	}
	// THE REQUESTER IS THE AUTHENTICATED PRINCIPAL, NEVER THE BODY.
	//
	// The first version of this handler used body.RequestedBy when present and fell back to the
	// principal only when it was omitted, with a comment reasoning that the default "can only ever
	// ADD a name to the comparison". That reasoning was about the fallback branch and was wrong
	// about the branch that actually runs: RequestedBy is the sole input to the
	// requester-is-approver check, so a caller supplying "nobody" made the comparison
	// `"alice" == "nobody"` and alice could both request and approve her own erasure. Dual
	// authorisation dropped from three humans to two, silently, at the client's choosing.
	//
	// A mismatch is refused rather than ignored, so a client that believes it is acting for someone
	// else is told it is not, instead of having its intent quietly rewritten.
	if body.RequestedBy != "" && body.RequestedBy != tenant.Principal {
		writeError(w, http.StatusBadRequest,
			"requested_by must match the authenticated principal; the requester identity is taken from the credential, not the body")
		return
	}
	requestedBy := tenant.Principal

	decision, err := h.Privacy.Erase(r.Context(), privacy.ErasureRequest{
		RequestID:   body.RequestID,
		TenantID:    tenant.TenantID,
		SubjectID:   subjectID,
		RequestedBy: requestedBy,
		RequestedAt: body.RequestedAt,
		Exception:   body.Exception,
	})
	resp := ErasureResponse{Decision: decision}
	if err == nil {
		writeJSON(w, http.StatusOK, resp)
		return
	}
	resp.Remediation = remediationFor(decision, err)
	writeJSON(w, erasureStatusFor(err), resp)
}

// erasureStatusFor maps a refusal to an HTTP status.
//
// The order of these checks matters. ErrRefusalNotRecorded wraps the underlying refusal, so it must
// be tested first: otherwise a legal-hold refusal whose audit write also failed would report 409
// "you are held" and hide the fact that nothing was recorded, which is the more urgent of the two
// facts for an operator.
func erasureStatusFor(err error) int {
	switch {
	case errors.Is(err, privacy.ErrRefusalNotRecorded), errors.Is(err, privacy.ErrAuditUnavailable):
		return http.StatusServiceUnavailable
	case errors.Is(err, privacy.ErrIncidentStateUnavailable):
		return http.StatusServiceUnavailable
	case errors.Is(err, privacy.ErrLegalHold), errors.Is(err, privacy.ErrRequestStale):
		return http.StatusConflict
	case errors.Is(err, privacy.ErrInsufficientApprovals),
		errors.Is(err, privacy.ErrRequesterIsApprover),
		errors.Is(err, privacy.ErrExceptionNotTimeBounded),
		errors.Is(err, privacy.ErrUnenumeratedGround),
		errors.Is(err, privacy.ErrExceptionMismatch),
		errors.Is(err, privacy.ErrInvalidSignature),
		errors.Is(err, privacy.ErrOperatorNotRegistered),
		errors.Is(err, privacy.ErrOperatorLacksCapability):
		return http.StatusForbidden
	case errors.Is(err, privacy.ErrInvalidRequest):
		return http.StatusBadRequest
	default:
		return http.StatusInternalServerError
	}
}

// remediationFor tells the operator what would unblock them.
//
// Every branch names a concrete next action. "Refused" on its own is the failure mode this function
// exists to prevent: an operator who cannot tell a policy decision from an outage will retry, then
// escalate to an engineer, then eventually route around the control.
func remediationFor(d privacy.Decision, err error) string {
	switch {
	case errors.Is(err, privacy.ErrRefusalNotRecorded):
		return "the erasure was refused AND the refusal could not be written to the audit trail; restore the audit backend, then re-submit so the decision is recorded"
	case errors.Is(err, privacy.ErrAuditUnavailable):
		return "the audit trail is unavailable; erasure is refused rather than performed unrecorded. Restore the audit backend and re-submit"
	case errors.Is(err, privacy.ErrIncidentStateUnavailable):
		return "incident state could not be determined, so the absence of a legal hold could not be demonstrated. Restore the incident source and re-submit; this is an outage, not a policy decision"
	case errors.Is(err, privacy.ErrLegalHold):
		return fmt.Sprintf(
			"subject is under %d active legal hold(s) %v. To proceed, supply a retention exception naming %s, signed by at least %d DISTINCT registered operators holding %q, neither of whom is the requester, with an expiry no more than %s after issue and a review date no later than the expiry",
			len(d.HoldIDs), d.HoldIDs, d.RequiredGround.Description(),
			privacy.MinApprovals, privacy.CapabilityGrantErasureOverride, privacy.MaxExceptionValidity)
	case errors.Is(err, privacy.ErrRequestStale):
		return fmt.Sprintf("the request is older than %s and was not evaluated against current incident state; re-submit it with a current requested_at", privacy.MaxRequestAge)
	case errors.Is(err, privacy.ErrRequesterIsApprover):
		return "the requester also signed the override; dual authorisation requires two people, so obtain approvals from two operators other than the requester"
	case errors.Is(err, privacy.ErrInsufficientApprovals):
		return fmt.Sprintf("the override carries fewer than %d distinct operator approvals; two signatures from one operator is one operator", privacy.MinApprovals)
	case errors.Is(err, privacy.ErrExceptionNotTimeBounded):
		return fmt.Sprintf("the override is not properly time-bounded; it must carry issued_at, expires_at and review_by, with expires_at no more than %s after issued_at and review_by no later than expires_at", privacy.MaxExceptionValidity)
	case errors.Is(err, privacy.ErrUnenumeratedGround):
		return "the override names a ground that is not one of the five enumerated Article 17(3) exemptions; free-form justifications are refused"
	case errors.Is(err, privacy.ErrExceptionMismatch):
		return "the override is not bound to this subject, tenant and request id; an override granted for one request may not be replayed against another"
	case errors.Is(err, privacy.ErrInvalidSignature):
		return "an operator approval signature did not verify against the registered public key for that operator"
	case errors.Is(err, privacy.ErrOperatorNotRegistered):
		return "an approving operator is not in the authorised registry; the set of operators who may override a hold is bounded and explicit"
	case errors.Is(err, privacy.ErrOperatorLacksCapability):
		return fmt.Sprintf("an approving operator is registered but does not hold %q", privacy.CapabilityGrantErasureOverride)
	case errors.Is(err, privacy.ErrInvalidRequest):
		return "the erasure request is malformed; request_id, requested_by and a non-zero requested_at are all required"
	default:
		return "erasure did not complete; see the decision outcome and reason"
	}
}
