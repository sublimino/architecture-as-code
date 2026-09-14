package privacy

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// HoldKind classifies why a subject is held.
//
// The kinds are not interchangeable in an audit trail: "this actor is under active containment
// right now" and "an operator placed a hold last Tuesday" are different claims about the world, and
// a refusal that cannot say which one applies is a refusal an operator cannot act on.
type HoldKind string

const (
	// HoldUnresolvedIncident is a hold derived from a security incident that has not been closed.
	HoldUnresolvedIncident HoldKind = "unresolved_incident"

	// HoldActiveContainment is a hold derived from a live containment record — in this service, a
	// quarantined actor. Containment is the strongest form: the subject is being actively
	// restrained because of something it did, so its attribution chain is under maximum demand.
	HoldActiveContainment HoldKind = "active_containment"

	// HoldOperatorPlaced is a hold placed deliberately by an operator, typically on advice of
	// counsel ahead of litigation. It is enumerated explicitly rather than folded into
	// HoldUnresolvedIncident because a litigation hold outlives the incident that prompted it and
	// is released by a different person for a different reason.
	HoldOperatorPlaced HoldKind = "operator_placed"
)

// Valid reports whether k is one of the enumerated hold kinds.
func (k HoldKind) Valid() bool {
	switch k {
	case HoldUnresolvedIncident, HoldActiveContainment, HoldOperatorPlaced:
		return true
	default:
		return false
	}
}

// Hold is a single reason a subject's data may not be destroyed.
type Hold struct {
	// ID uniquely identifies the hold so a refusal can name exactly what blocked it.
	ID string `json:"id"`

	// SubjectID is the data subject the hold covers.
	//
	// IDENTIFIER SPACE, pinned here because leaving it implicit is how this silently becomes a
	// no-op. A hold's SubjectID is in the CLEARTEXT actor-ID space — the same space as
	// model.ProvisionalActor.ID, correlation's quarantine keys, and ErasureRequest.SubjectID. It is
	// NOT in the (tenant, epoch)-bound HMAC pseudonym space that identity.PseudonymKeyRing
	// produces and that the persisted graph is keyed by. Pseudonymisation happens exactly once in
	// this package, at the audit boundary, and never on the comparison path.
	//
	// This matters because SLDP-P2-1 measured that an epoch rotation silently turns pseudonym-space
	// exact-equality comparisons into no-ops. Comparing in cleartext space makes hold matching
	// immune to rotation. The cost is that the crossing into pseudonym space is deferred rather
	// than solved: SLDP-P4-1, which owns the per-subject key hierarchy, must decide how a hold on a
	// cleartext actor ID maps onto the epoch-bound keys it destroys. That crossing is an explicit
	// unowned boundary recorded in this card's errata, not an assumption this package has made.
	//
	// Comparison is exact equality. No prefix, substring or case-insensitive matching is performed
	// anywhere in this package: prefix matching would over-hold, and substring matching would be
	// evadable by renaming.
	SubjectID string `json:"subject_id"`

	// TenantID scopes the hold. A hold from one tenant never blocks another tenant's erasure.
	TenantID string `json:"tenant_id"`

	// Kind classifies the hold.
	Kind HoldKind `json:"kind"`

	// IncidentRef points at the incident, containment record or matter that justifies the hold.
	IncidentRef string `json:"incident_ref"`

	// OpenedAt is when the hold came into effect.
	OpenedAt time.Time `json:"opened_at"`

	// ReleasedAt is when the hold ceases to have effect. The zero value means "not released", which
	// is the open-ended case and is deliberately the zero value: a hold constructed with no
	// thought about release is indefinite rather than instantly expired.
	ReleasedAt time.Time `json:"released_at,omitempty"`
}

// Active reports whether the hold is in effect at now.
//
// A zero ReleasedAt is indefinite. A ReleasedAt in the future is still in effect. Only a
// ReleasedAt at or before now releases the hold.
func (h Hold) Active(now time.Time) bool {
	if h.ReleasedAt.IsZero() {
		return true
	}
	return now.Before(h.ReleasedAt)
}

// HoldQueryResult is a source's answer about one subject.
//
// The Jurisdiction field exists because "I looked and found nothing" and "I had no authority to
// look" are different facts that an empty slice cannot distinguish. Without it, a source asked
// about a tenant it does not serve returns an empty slice — the wire encoding of "determined: no
// holds" — and the whole fail-closed design inverts at exactly the point it is load-bearing.
//
// This is the same defect the package refuses elsewhere (an empty CompositeIncidentSource would
// answer "no holds" to every subject), one level up. It is fixed representationally rather than by
// a detector: success and no-op no longer share a bit.
type HoldQueryResult struct {
	// Holds are the holds found. Meaningful only when Jurisdiction is true.
	Holds []Hold

	// Jurisdiction reports whether this source was authoritative for the queried tenant. A source
	// that declines must set this false and MUST NOT signal declination by returning zero holds.
	Jurisdiction bool
}

// IncidentSource answers whether a subject is under any hold.
//
// The three-valued contract is the whole point, and every implementation must honour all three:
//
//	(HoldQueryResult{Holds: hs, Jurisdiction: true}, nil)  — determined: these holds
//	(HoldQueryResult{Jurisdiction: false}, nil)            — declined: not my tenant, I did not look
//	(anything, err)                                        — undetermined: the lookup failed
//
// Implementations MUST NOT signal failure or declination by returning an empty slice with a nil
// error and Jurisdiction true, because that is the legal encoding of "no holds" and a failure that
// looks like one permits the erasure it was meant to block.
type IncidentSource interface {
	ActiveHolds(ctx context.Context, tenantID, subjectID string) (HoldQueryResult, error)
}

var (
	// ErrIncidentStateUnavailable is returned when incident state could not be determined. It is a
	// distinct sentinel from ErrLegalHold so that a caller — and a test — can tell "we know you are
	// held" apart from "we do not know whether you are held". Both refuse; they refuse for
	// different reasons and produce different HTTP statuses.
	ErrIncidentStateUnavailable = errors.New("incident state unavailable: erasure refused because the absence of a legal hold could not be demonstrated")

	// ErrNoJurisdiction is returned when no configured source was authoritative for the tenant. It
	// wraps into ErrIncidentStateUnavailable because the operational consequence is identical —
	// nobody looked, so nothing was demonstrated — but it is separately named so an operator
	// reading a refusal can tell a broken dependency apart from a missing configuration.
	ErrNoJurisdiction = errors.New("no incident source has jurisdiction over this tenant: holds could not be evaluated")
)

// QuarantineLookup is the slice of correlation.QuarantineEngine this package depends on.
//
// Depending on the narrow interface rather than the concrete engine keeps the dependency direction
// clean and, more usefully, makes the adapter testable without constructing a correlation engine.
type QuarantineLookup interface {
	IsActorQuarantined(actorID string) (*model.QuarantineRecord, bool)
}

// QuarantineIncidentSource derives active-containment holds from the live quarantine engine.
//
// A quarantined actor is an actor under active containment: the engine restrained it because its
// delegation chain failed verification, and the evidence of that failure is precisely what an
// erasure would destroy.
type QuarantineIncidentSource struct {
	lookup   QuarantineLookup
	tenantID string
}

// NewQuarantineIncidentSource adapts a quarantine engine into an IncidentSource.
//
// tenantID scopes every hold this source produces. The quarantine engine is not tenant-aware, so
// binding the tenant here is what stops one tenant's quarantine from blocking another's erasure.
func NewQuarantineIncidentSource(lookup QuarantineLookup, tenantID string) (*QuarantineIncidentSource, error) {
	if lookup == nil {
		return nil, errors.New("quarantine lookup is required")
	}
	if tenantID == "" {
		return nil, errors.New("tenant id is required")
	}
	return &QuarantineIncidentSource{lookup: lookup, tenantID: tenantID}, nil
}

// ActiveHolds implements IncidentSource.
func (q *QuarantineIncidentSource) ActiveHolds(_ context.Context, tenantID, subjectID string) (HoldQueryResult, error) {
	if q.lookup == nil {
		// Unreachable via the constructor, but a nil lookup here would otherwise panic or, worse,
		// be recovered into an empty result that reads as "no holds".
		return HoldQueryResult{}, fmt.Errorf("%w: quarantine lookup is nil", ErrIncidentStateUnavailable)
	}
	if tenantID != q.tenantID {
		// Declined, NOT "no holds". This source knows nothing about other tenants and says so.
		return HoldQueryResult{Jurisdiction: false}, nil
	}
	record, quarantined := q.lookup.IsActorQuarantined(subjectID)
	if !quarantined || record == nil {
		return HoldQueryResult{Jurisdiction: true}, nil
	}
	return HoldQueryResult{
		Jurisdiction: true,
		Holds: []Hold{{
			ID:          "quarantine:" + subjectID,
			SubjectID:   subjectID,
			TenantID:    tenantID,
			Kind:        HoldActiveContainment,
			IncidentRef: "quarantine/" + record.ViolationReason.String(),
			OpenedAt:    record.QuarantinedAt,
		}},
	}, nil
}

// CompositeIncidentSource unions several incident sources.
//
// Two rules, and both are refusals rather than best-effort answers:
//
//   - It refuses if ANY constituent errors, rather than returning the holds it did collect. A union
//     computed from a partial view is not a union: the source that failed is exactly the one that
//     might have been holding this subject.
//   - It refuses if NO constituent had jurisdiction. A composite whose every member declines is
//     functionally an empty composite, and an empty composite would answer "no holds" to every
//     subject in that tenant — which is why the constructor refuses one.
type CompositeIncidentSource struct {
	sources []IncidentSource
}

// NewCompositeIncidentSource builds a composite over one or more sources.
func NewCompositeIncidentSource(sources ...IncidentSource) (*CompositeIncidentSource, error) {
	if len(sources) == 0 {
		return nil, errors.New("at least one incident source is required: an empty composite would answer 'no holds' to every subject")
	}
	for i, s := range sources {
		if s == nil {
			return nil, fmt.Errorf("incident source %d is nil", i)
		}
	}
	return &CompositeIncidentSource{sources: sources}, nil
}

// ActiveHolds implements IncidentSource.
func (c *CompositeIncidentSource) ActiveHolds(ctx context.Context, tenantID, subjectID string) (HoldQueryResult, error) {
	var all []Hold
	authoritative := 0
	for i, s := range c.sources {
		res, err := s.ActiveHolds(ctx, tenantID, subjectID)
		if err != nil {
			return HoldQueryResult{}, fmt.Errorf("%w: source %d: %v", ErrIncidentStateUnavailable, i, err)
		}
		if !res.Jurisdiction {
			continue
		}
		authoritative++
		all = append(all, res.Holds...)
	}
	if authoritative == 0 {
		return HoldQueryResult{}, fmt.Errorf("%w: %w: tenant %q, %d source(s) consulted, none authoritative",
			ErrIncidentStateUnavailable, ErrNoJurisdiction, tenantID, len(c.sources))
	}
	return HoldQueryResult{Holds: all, Jurisdiction: true}, nil
}

// activeHoldsAt filters holds to those in effect at now, and returns them in a deterministic order
// so that a refusal body and its audit record agree byte-for-byte across repeated evaluations.
func activeHoldsAt(holds []Hold, now time.Time) []Hold {
	out := make([]Hold, 0, len(holds))
	for _, h := range holds {
		if h.Active(now) {
			out = append(out, h)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// holdIDs projects a hold slice to its IDs, preserving order.
func holdIDs(holds []Hold) []string {
	out := make([]string, 0, len(holds))
	for _, h := range holds {
		out = append(out, h.ID)
	}
	return out
}
