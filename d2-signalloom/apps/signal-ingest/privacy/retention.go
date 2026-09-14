package privacy

import (
	"context"
	"fmt"
	"time"
)

// RetentionDecision separates two questions that are easy to conflate and must not be.
//
//	Due      — has the retention schedule elapsed?
//	Deletable — may the record actually be removed right now?
//
// They are different because a legal hold can make a due record undeletable. Collapsing them into
// one boolean is how a retention sweeper ends up destroying evidence on a timer: the sweeper asks
// "is it due?", gets true, and deletes. Keeping them separate forces every caller to ask the second
// question explicitly.
type RetentionDecision struct {
	// Due reports whether the retention period has elapsed.
	Due bool `json:"due"`

	// Deletable reports whether the record may be removed. Deletable implies Due; the converse does
	// not hold.
	Deletable bool `json:"deletable"`

	// Holds are the active holds blocking deletion, if any.
	Holds []Hold `json:"holds,omitempty"`

	// HoldIDs is the projection used in logs and API bodies.
	HoldIDs []string `json:"hold_ids,omitempty"`

	// Reason states the decision in words an operator can act on.
	Reason string `json:"reason"`

	// EvaluatedAt is the clock reading used.
	EvaluatedAt time.Time `json:"evaluated_at"`
}

// Retention evaluates whether a record may be deleted, reconciling the retention schedule against
// active legal holds.
//
// PRECEDENCE, stated once and implemented in exactly one place: a legal hold beats retention
// expiry. A record past its retention period but under an active hold is Due and not Deletable. The
// reasoning is that retention expiry is a schedule and a hold is a fact about the world; letting a
// schedule silently override a fact is a fail-open path with a calendar attached. See the package
// comment for the full truth table.
type Retention struct {
	incidents IncidentSource
	now       func() time.Time
}

// NewRetention constructs a retention evaluator.
//
// Like Service, it refuses a nil incident source. A retention sweeper that cannot see holds is a
// retention sweeper that deletes through them.
func NewRetention(incidents IncidentSource, now func() time.Time) (*Retention, error) {
	if incidents == nil {
		return nil, fmt.Errorf("incident source is required: a retention evaluator that cannot see legal holds would delete through them")
	}
	if now == nil {
		now = time.Now
	}
	return &Retention{incidents: incidents, now: now}, nil
}

// Evaluate decides whether the record for subject, whose retention period ends at retentionEndsAt,
// may be deleted.
//
// It fails closed for the same reason Service.Erase does: an error from the incident source means
// the absence of a hold could not be demonstrated, and the retention sweeper is not a special case.
func (r *Retention) Evaluate(ctx context.Context, tenantID, subjectID string, retentionEndsAt time.Time) (RetentionDecision, error) {
	now := r.now().UTC()
	d := RetentionDecision{EvaluatedAt: now}

	res, err := r.incidents.ActiveHolds(ctx, tenantID, subjectID)
	if err != nil {
		d.Reason = "incident state unavailable; retention deletion refused"
		return d, fmt.Errorf("%w: %v", ErrIncidentStateUnavailable, err)
	}
	if !res.Jurisdiction {
		d.Reason = "no incident source has jurisdiction over this tenant; retention deletion refused"
		return d, fmt.Errorf("%w: %w: tenant %q", ErrIncidentStateUnavailable, ErrNoJurisdiction, tenantID)
	}
	active := activeHoldsAt(res.Holds, now)
	d.Holds = active
	d.HoldIDs = holdIDs(active)

	// Due is computed from the schedule alone and is deliberately independent of hold state: an
	// operator needs to be able to see "this should have gone six weeks ago, and here is what is
	// stopping it".
	d.Due = !now.Before(retentionEndsAt)

	switch {
	case !d.Due:
		d.Deletable = false
		d.Reason = fmt.Sprintf("retention period runs until %s", retentionEndsAt.UTC().Format(time.RFC3339))
	case len(active) > 0:
		d.Deletable = false
		d.Reason = fmt.Sprintf("retention period elapsed but %d active legal hold(s) %v take precedence over retention expiry", len(active), d.HoldIDs)
	default:
		d.Deletable = true
		d.Reason = "retention period elapsed and no active legal hold"
	}
	return d, nil
}
