// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"crypto/sha256"
	"encoding/hex"
	"time"
	"unicode/utf8"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// SourceReview is the third policy source written back into the signal store, beside
// obscel.SourceFinding and obscel.SourceDecision.
//
// # Why a review is an observation and not a row in a side table
//
// A decision is evidence: it is derived, idempotent, signed into a segment with everything else
// the pipeline saw, and a replay re-derives it byte for byte. A human's verdict on that decision
// is a different kind of fact — it is not derivable from the data, it is an assertion by a named
// person at a named moment — but it has exactly the same evidentiary job to do. Somebody will
// later ask "who called this a false positive, and when, and on what", and the answer has to be
// as durable, as attributable and as tamper-evident as the decision it judges.
//
// The store already gives all of that: append-only segments, a tenant label, a signer, a
// retention sweep, and one read path (QueryRange) that every consumer already trusts. A separate
// `policy_reviews` table would need its own migration, its own tenancy enforcement, its own
// retention, its own attestation, and its own place in every export — four of which are the
// controls an auditor actually asks about, re-implemented beside the ones that already pass.
//
// So a review is an observation whose Source says it is a review. The cost is honestly stated:
// the review's Timestamp is wall-clock, which no other observation's is (see ReviewObservation),
// and the store cannot by itself prove the reviewer label was not forged by a key that holds
// policy:review — attribution is only as strong as the credential, exactly as it is for an
// ingested observation.
const SourceReview = "policy_review"

// Closed label set written onto a review observation. As with a finding and a decision, nothing
// else is added and the reviewed decision's own labels are NOT copied: a review must not restate
// a projected value under a third source.
const (
	LabelDecisionID = "decision_id"
	LabelVerdict    = "verdict"
	LabelReviewer   = "reviewer"
	LabelNote       = "note"
)

// MaxReviewNoteLen bounds the free-text note, in runes.
//
// A label VALUE is unconstrained free text as far as the segment allow-list is concerned (see
// store.defaultLabelAllowList), so the only bound a note has is the one applied here. 500 is
// enough for a sentence of justification and small enough that a note cannot be used as a bulk
// side-channel into a signed segment.
const MaxReviewNoteLen = 500

// Verdict is the objective value judgement a human records against a decision.
//
// Three values, deliberately: the question a reviewer is answering is "was the pipeline right",
// and the honest answers are yes, no, and not-yet-knowable. A free-text verdict would make the
// whole point of the exercise — counting how often the policy is wrong — unanswerable.
type Verdict string

const (
	// VerdictTruePositive: the decision described something that really happened and really mattered.
	VerdictTruePositive Verdict = "true_positive"
	// VerdictFalsePositive: the decision fired on something benign. This is the number that pays for the feature.
	VerdictFalsePositive Verdict = "false_positive"
	// VerdictNeedsInfo: the evidence on hand does not settle it. Recorded rather than guessed, so
	// an unresolved decision is visibly unresolved instead of silently absent.
	VerdictNeedsInfo Verdict = "needs_info"
)

// Verdicts returns the closed verdict vocabulary, in a stable order.
func Verdicts() []Verdict {
	return []Verdict{VerdictTruePositive, VerdictFalsePositive, VerdictNeedsInfo}
}

// IsValid reports whether v is one of the three recorded verdicts.
func (v Verdict) IsValid() bool {
	switch v {
	case VerdictTruePositive, VerdictFalsePositive, VerdictNeedsInfo:
		return true
	default:
		return false
	}
}

// Review is one human judgement of one decision.
type Review struct {
	ID         string    `json:"id"`
	DecisionID string    `json:"decision_id"`
	TenantID   string    `json:"tenant_id"`
	Verdict    Verdict   `json:"verdict"`
	Note       string    `json:"note"`
	Reviewer   string    `json:"reviewer"`
	ReviewedAt time.Time `json:"reviewed_at"`
}

// ReviewID derives the review's identifier from everything a reviewer asserted.
//
// The derivation is the idempotency rule, not a convenience. Note and verdict are INSIDE the
// hash, so re-sending the identical judgement (a double-clicked button, a retried fetch, an SQS
// redelivery of a dashboard action) derives the same ID and is collapsed by the same deduper that
// collapses a replayed observation — one row, not two. Change the verdict or a character of the
// note and it is a different assertion with a different ID, which is correct: a reviewer who
// revises a judgement has made a second, separately attributable statement, and the first one
// stays on the record.
//
// The reviewer is in the hash too, so two people reaching the same verdict on the same decision
// are two reviews. Collapsing those would destroy the only interesting case — agreement.
func ReviewID(tenantID, decisionID, reviewer, verdict, note string) string {
	sum := sha256.Sum256([]byte(tenantID + "|" + decisionID + "|" + reviewer + "|" + verdict + "|" + note))
	return hex.EncodeToString(sum[:])
}

// NormaliseNote trims a note to MaxReviewNoteLen runes and reports whether it was truncated.
//
// Runes rather than bytes: a byte slice of UTF-8 can cut a codepoint in half, and a label value
// holding half a character is a corrupted record rather than a shortened one.
func NormaliseNote(note string) (string, bool) {
	if utf8.RuneCountInString(note) <= MaxReviewNoteLen {
		return note, false
	}
	runes := []rune(note)
	return string(runes[:MaxReviewNoteLen]), true
}

// ReviewObservation renders a review as a storable observation.
//
// Layer, Fidelity and Confidence are NOT inherited the way findingObservation inherits them.
// Layer is, because a review of a decision about the network layer is itself about the network
// layer and the rates chart groups by layer; but Fidelity and Confidence are the review's own.
// A decision derived from circumstantial evidence can be judged with certainty by a person who
// knows what the workload does, so inheriting the decision's tier here would understate the
// review, and inheriting its confidence would make a human's statement vary with the strength of
// the thing it contradicts.
//
// FidelityStrong, not FidelityDefinitive: definitive is reserved for cryptographic proof, and a
// person's judgement is not that. Strong — "verified chain" — is what an authenticated,
// attributable, first-party assertion is.
//
// # The one wall-clock timestamp in the pipeline
//
// Every other observation's Timestamp comes from the data: a finding's is its source
// observation's, a decision's is the moment its threshold was crossed in the data, and the
// replay oracle depends on that. A review has no such moment to borrow. It happened when the
// person clicked, and the only clock that knows is the server's. So ReviewObservation takes the
// timestamp from its caller and the caller takes it from the wall clock, which is stated here
// rather than buried because it is the one place the determinism contract does not hold —
// a replay cannot re-derive a review, and must not try to.
func ReviewObservation(rv Review, decision *model.Observation) model.Observation {
	layer := model.LayerBehavioural
	if decision != nil && decision.Layer.IsValid() {
		layer = decision.Layer
	}
	return model.Observation{
		ID:             rv.ID,
		Timestamp:      rv.ReviewedAt,
		Layer:          layer,
		Fidelity:       model.FidelityStrong,
		Source:         SourceReview,
		Confidence:     1.0,
		ActorHint:      rv.Reviewer,
		RawEvidenceRef: rv.DecisionID,
		Description:    reviewDescription(rv),
		Labels: map[string]string{
			LabelDecisionID: rv.DecisionID,
			LabelVerdict:    string(rv.Verdict),
			LabelReviewer:   rv.Reviewer,
			LabelNote:       rv.Note,
			TenantLabel:     rv.TenantID,
		},
	}
}

// ReviewFromObservation rebuilds a review from its stored projection. The inverse of
// ReviewObservation over exactly the fields ReviewObservation wrote; nothing is inferred.
func ReviewFromObservation(obs model.Observation) Review {
	return Review{
		ID:         obs.ID,
		DecisionID: obs.Labels[LabelDecisionID],
		TenantID:   obs.Labels[TenantLabel],
		Verdict:    Verdict(obs.Labels[LabelVerdict]),
		Note:       obs.Labels[LabelNote],
		Reviewer:   obs.Labels[LabelReviewer],
		ReviewedAt: obs.Timestamp,
	}
}

// reviewDescription is one line built only from the review's own fields. The note is deliberately
// excluded: it is already a label, and restating free text in a second column doubles whatever
// the redactors have to cover.
func reviewDescription(rv Review) string {
	return "policy review: decision " + rv.DecisionID + " judged " + string(rv.Verdict) +
		" by " + rv.Reviewer
}

// IsReview reports whether obs is a stored review.
func IsReview(obs *model.Observation) bool {
	return obs != nil && obs.Source == SourceReview
}
