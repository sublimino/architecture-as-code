package privacy

import (
	"crypto/ed25519"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
	"time"
)

// MaxExceptionValidity bounds how far into the future a retention exception may run.
//
// An exception with no upper bound is a policy change wearing an exception's clothes, and policy
// changes belong on a slower reviewed path. Ninety days is chosen to comfortably span a quarterly
// legal review cycle — long enough that a genuine litigation matter does not need re-authorising
// every fortnight, short enough that an exception granted during an incident cannot quietly outlive
// the incident by a year. Like MaxOperators it is a compile-time constant, because a configurable
// ceiling is a ceiling that gets raised at 3am.
const MaxExceptionValidity = 90 * 24 * time.Hour

// MinApprovals is the number of distinct operator approvals a retention exception requires.
//
// It is a MINIMUM, not an equality. Three approvals are better than two and are accepted; the rule
// being violated is "fewer than two people were involved", not "exactly two were".
const MinApprovals = 2

// exceptionDomainPrefix domain-separates retention-exception signatures from every other Ed25519
// signature in this estate (DSSE segment attestations, agent-nono audit envelopes). Without it, a
// signature produced for one purpose could in principle be presented for another; with it, the
// signed byte strings live in disjoint spaces.
const exceptionDomainPrefix = "signalloom.retention-exception.v1"

var (
	// ErrInsufficientApprovals is returned when fewer than MinApprovals distinct approvals are
	// present.
	ErrInsufficientApprovals = errors.New("retention exception requires at least two distinct operator approvals")

	// ErrRequesterIsApprover is returned when the erasure requester also signed the override. One
	// person who can both request and approve is one person, and dual authorisation has not
	// occurred.
	ErrRequesterIsApprover = errors.New("the erasure requester may not also approve the override")

	// ErrExceptionNotTimeBounded is returned when an exception has no expiry, no review date, or an
	// expiry beyond MaxExceptionValidity.
	ErrExceptionNotTimeBounded = errors.New("retention exception must be time-bounded: a non-expiring exception is a policy change, not an exception")

	// ErrUnenumeratedGround is returned when the named ground is not one of the five Article 17(3)
	// grounds.
	ErrUnenumeratedGround = errors.New("retention exception must name an enumerated Article 17(3) ground")

	// ErrExceptionMismatch is returned when a structurally valid exception is bound to a different
	// subject, tenant or request than the erasure being attempted.
	ErrExceptionMismatch = errors.New("retention exception is not bound to this erasure request")

	// ErrInvalidSignature is returned when an approval's signature does not verify.
	ErrInvalidSignature = errors.New("operator approval signature did not verify")
)

// OperatorApproval is one operator's signature over a retention exception.
type OperatorApproval struct {
	// OperatorID names the approving operator. It is bound into the signed message, so a signature
	// produced by one operator cannot be re-labelled as another's.
	OperatorID string `json:"operator_id"`

	// Signature is the Ed25519 signature over signingMessage(exception, OperatorID).
	Signature []byte `json:"signature"`
}

// RetentionException is a signed, time-bounded authorisation to erase a subject despite an active
// legal hold.
//
// Every field below is load-bearing for at least one refusal path. There is no optional field: an
// exception missing any of them is refused rather than defaulted, because every default here would
// be a default in the permissive direction.
type RetentionException struct {
	// SubjectID is the data subject this exception covers.
	SubjectID string `json:"subject_id"`

	// TenantID scopes the exception.
	TenantID string `json:"tenant_id"`

	// Ground is the Article 17(3) subparagraph relied upon.
	Ground LegalGround `json:"ground"`

	// RequestID binds the exception to one specific erasure request. Without it, an exception
	// granted for one request could be replayed against a later request for the same subject,
	// after the incident picture had changed.
	RequestID string `json:"request_id"`

	// IssuedAt is when the exception was granted.
	IssuedAt time.Time `json:"issued_at"`

	// ExpiresAt is when it ceases to authorise anything. Mandatory and bounded.
	ExpiresAt time.Time `json:"expires_at"`

	// ReviewBy is when a human must re-examine the exception. Mandatory, and must not be after
	// ExpiresAt — a review scheduled after the thing being reviewed has lapsed reviews nothing.
	ReviewBy time.Time `json:"review_by"`

	// Approvals carries the operator signatures.
	Approvals []OperatorApproval `json:"approvals"`
}

// signingMessage builds the canonical, unambiguous byte string an operator signs.
//
// Every component is length-prefixed with a fixed-width big-endian uint32, mirroring
// identity.AliasEnvelopeAAD. Plain concatenation would let two different field assignments produce
// identical bytes — ("ab","c") and ("a","bc") collide — which would let a signature over one
// exception verify against a different one. Times are serialised as UTC RFC3339Nano so the encoding
// is stable across a process whose local zone changes.
func signingMessage(e RetentionException, operatorID string) []byte {
	parts := []string{
		exceptionDomainPrefix,
		e.SubjectID,
		e.TenantID,
		string(e.Ground),
		e.RequestID,
		e.IssuedAt.UTC().Format(time.RFC3339Nano),
		e.ExpiresAt.UTC().Format(time.RFC3339Nano),
		e.ReviewBy.UTC().Format(time.RFC3339Nano),
		operatorID,
	}
	out := make([]byte, 0, 128)
	for _, p := range parts {
		out = binary.BigEndian.AppendUint32(out, uint32(len(p)))
		out = append(out, p...)
	}
	return out
}

// SignApproval produces an operator's approval over the exception. It exists so that tests and
// operator tooling construct signatures the same way the verifier expects, rather than each
// re-deriving the canonical encoding and drifting apart.
func SignApproval(e RetentionException, operatorID string, key ed25519.PrivateKey) (OperatorApproval, error) {
	if operatorID == "" {
		return OperatorApproval{}, errors.New("operator id is required")
	}
	if len(key) != ed25519.PrivateKeySize {
		return OperatorApproval{}, fmt.Errorf("private key is %d bytes, want %d", len(key), ed25519.PrivateKeySize)
	}
	return OperatorApproval{
		OperatorID: operatorID,
		Signature:  ed25519.Sign(key, signingMessage(e, operatorID)),
	}, nil
}

// validateShape checks every field-level rule that does not need the registry, the clock, or the
// erasure request. Separating it out means the structural rules can be tested without constructing
// a Service, and means a malformed exception is refused before any signature arithmetic runs.
func (e RetentionException) validateShape(now time.Time) error {
	if e.SubjectID == "" {
		return fmt.Errorf("%w: subject id is empty", ErrExceptionMismatch)
	}
	if e.TenantID == "" {
		return fmt.Errorf("%w: tenant id is empty", ErrExceptionMismatch)
	}
	if e.RequestID == "" {
		return fmt.Errorf("%w: request id is empty", ErrExceptionMismatch)
	}
	if !e.Ground.Valid() {
		return fmt.Errorf("%w: %q is not one of the five Article 17(3) grounds", ErrUnenumeratedGround, e.Ground)
	}
	if e.IssuedAt.IsZero() {
		return fmt.Errorf("%w: issued_at is unset", ErrExceptionNotTimeBounded)
	}
	if e.ExpiresAt.IsZero() {
		return fmt.Errorf("%w: expires_at is unset", ErrExceptionNotTimeBounded)
	}
	if e.ReviewBy.IsZero() {
		return fmt.Errorf("%w: review_by is unset", ErrExceptionNotTimeBounded)
	}
	if !e.ExpiresAt.After(e.IssuedAt) {
		return fmt.Errorf("%w: expires_at is not after issued_at", ErrExceptionNotTimeBounded)
	}
	// Exclusive boundary. An exception expiring at exactly this instant no longer authorises
	// anything; an inclusive comparison would make the last nanosecond of validity a race.
	if !now.Before(e.ExpiresAt) {
		return fmt.Errorf("%w: expired at %s", ErrExceptionNotTimeBounded, e.ExpiresAt.UTC().Format(time.RFC3339))
	}
	// The window must be bounded relative to ISSUE...
	if e.ExpiresAt.Sub(e.IssuedAt) > MaxExceptionValidity {
		return fmt.Errorf("%w: validity of %s exceeds MaxExceptionValidity of %s", ErrExceptionNotTimeBounded, e.ExpiresAt.Sub(e.IssuedAt), MaxExceptionValidity)
	}
	// ...AND relative to NOW, which the issue-relative check alone does not give.
	//
	// Bounding only ExpiresAt-minus-IssuedAt lets an approver choose the issue date and thereby the
	// effective horizon: IssuedAt = now + 10 years with an 89-day window passes every other check
	// here — expiry is after issue, now is before expiry, the window fits — and authorises erasure
	// from today until a decade hence. That defeats the stated purpose of MaxExceptionValidity,
	// which is that an exception granted during an incident cannot quietly outlive it. The ceiling
	// has to bind from the decision clock, which is the one an attacker does not choose.
	if e.ExpiresAt.Sub(now) > MaxExceptionValidity {
		return fmt.Errorf("%w: expires %s from now, exceeding MaxExceptionValidity of %s", ErrExceptionNotTimeBounded, e.ExpiresAt.Sub(now), MaxExceptionValidity)
	}
	if e.IssuedAt.After(now) {
		return fmt.Errorf("%w: issued_at is in the future", ErrExceptionNotTimeBounded)
	}
	if e.ReviewBy.After(e.ExpiresAt) {
		return fmt.Errorf("%w: review_by is after expires_at, so the review would examine a lapsed exception", ErrExceptionNotTimeBounded)
	}
	// A review scheduled before the exception existed reviews nothing, for exactly the reason the
	// check above gives. ReviewBy of 1970-01-01 is non-zero and not after expiry, so only this
	// catches it.
	if e.ReviewBy.Before(e.IssuedAt) {
		return fmt.Errorf("%w: review_by is before issued_at, so the review would predate the exception", ErrExceptionNotTimeBounded)
	}
	return nil
}

// verifyApprovals checks that the exception carries at least MinApprovals approvals from distinct,
// registered, capable operators, none of whom is the requester, each with a signature that verifies
// over this exact exception.
//
// It returns the approver IDs in sorted order so the recorded decision is byte-stable regardless of
// the order the approvals arrived in.
func (e RetentionException) verifyApprovals(registry *OperatorRegistry, requesterID string) ([]string, error) {
	if registry == nil {
		return nil, errors.New("operator registry is required")
	}
	seen := make(map[string]bool, len(e.Approvals))
	for i, approval := range e.Approvals {
		if approval.OperatorID == "" {
			return nil, fmt.Errorf("approval %d has an empty operator id", i)
		}
		if seen[approval.OperatorID] {
			return nil, fmt.Errorf("%w: operator %q appears twice; two signatures from one person is one person", ErrInsufficientApprovals, approval.OperatorID)
		}
		if requesterID != "" && approval.OperatorID == requesterID {
			return nil, fmt.Errorf("%w: %q", ErrRequesterIsApprover, approval.OperatorID)
		}
		operator, err := registry.authorise(approval.OperatorID)
		if err != nil {
			return nil, err
		}
		if len(approval.Signature) != ed25519.SignatureSize {
			return nil, fmt.Errorf("%w: operator %q signature is %d bytes, want %d", ErrInvalidSignature, approval.OperatorID, len(approval.Signature), ed25519.SignatureSize)
		}
		if !ed25519.Verify(operator.PublicKey, signingMessage(e, approval.OperatorID), approval.Signature) {
			return nil, fmt.Errorf("%w: operator %q", ErrInvalidSignature, approval.OperatorID)
		}
		seen[approval.OperatorID] = true
	}
	// Counted from `seen` rather than from len(e.Approvals): the distinctness loop above already
	// rejects duplicates, so the two are equal here, but counting the deduplicated set is the
	// statement of intent and survives a future edit that tolerates duplicates.
	if len(seen) < MinApprovals {
		return nil, fmt.Errorf("%w: got %d distinct approvals, need %d", ErrInsufficientApprovals, len(seen), MinApprovals)
	}
	approvers := make([]string, 0, len(seen))
	for id := range seen {
		approvers = append(approvers, id)
	}
	sort.Strings(approvers)
	return approvers, nil
}

// authorises reports whether the exception validly permits the given erasure request at now, and
// returns the sorted approver identities when it does.
func (e RetentionException) authorises(req ErasureRequest, registry *OperatorRegistry, now time.Time) ([]string, error) {
	if err := e.validateShape(now); err != nil {
		return nil, err
	}
	if e.SubjectID != req.SubjectID {
		return nil, fmt.Errorf("%w: exception covers subject %q, request targets %q", ErrExceptionMismatch, e.SubjectID, req.SubjectID)
	}
	if e.TenantID != req.TenantID {
		return nil, fmt.Errorf("%w: exception covers tenant %q, request is for %q", ErrExceptionMismatch, e.TenantID, req.TenantID)
	}
	if e.RequestID != req.RequestID {
		return nil, fmt.Errorf("%w: exception is bound to request %q, not %q", ErrExceptionMismatch, e.RequestID, req.RequestID)
	}
	return e.verifyApprovals(registry, req.RequestedBy)
}
