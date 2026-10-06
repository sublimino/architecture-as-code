// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestVerdictVocabularyIsClosed(t *testing.T) {
	for _, v := range Verdicts() {
		if !v.IsValid() {
			t.Errorf("verdict %q is in Verdicts() but not IsValid", v)
		}
	}
	for _, bad := range []Verdict{"", "TRUE_POSITIVE", "true-positive", "maybe", "needs_info "} {
		if bad.IsValid() {
			t.Errorf("verdict %q must not validate", bad)
		}
	}
}

func TestReviewIDIsDerivedFromEveryAssertedField(t *testing.T) {
	base := ReviewID("t", "dec-1", "alice", "true_positive", "looks real")
	if len(base) != 64 {
		t.Fatalf("review id is %d chars, want 64 hex", len(base))
	}
	// Identical input derives the identical ID: that IS the idempotency rule.
	if again := ReviewID("t", "dec-1", "alice", "true_positive", "looks real"); again != base {
		t.Errorf("same assertion derived two IDs: %s != %s", base, again)
	}
	// Each field alone must move the ID, or two distinct assertions would collapse onto one row.
	for name, got := range map[string]string{
		"tenant":   ReviewID("other", "dec-1", "alice", "true_positive", "looks real"),
		"decision": ReviewID("t", "dec-2", "alice", "true_positive", "looks real"),
		"reviewer": ReviewID("t", "dec-1", "bob", "true_positive", "looks real"),
		"verdict":  ReviewID("t", "dec-1", "alice", "false_positive", "looks real"),
		"note":     ReviewID("t", "dec-1", "alice", "true_positive", "looks reaL"),
	} {
		if got == base {
			t.Errorf("changing %s did not change the review ID", name)
		}
	}
}

func TestNormaliseNoteTruncatesOnRunesNotBytes(t *testing.T) {
	if got, cut := NormaliseNote("short"); got != "short" || cut {
		t.Errorf("short note was altered: %q cut=%v", got, cut)
	}
	// A multi-byte note of exactly the limit must survive whole.
	exact := strings.Repeat("é", MaxReviewNoteLen)
	if got, cut := NormaliseNote(exact); got != exact || cut {
		t.Errorf("note of exactly the limit was truncated (cut=%v)", cut)
	}
	over := strings.Repeat("é", MaxReviewNoteLen+10)
	got, cut := NormaliseNote(over)
	if !cut {
		t.Fatal("over-long note was not reported as truncated")
	}
	if n := len([]rune(got)); n != MaxReviewNoteLen {
		t.Errorf("truncated to %d runes, want %d", n, MaxReviewNoteLen)
	}
	// Byte-wise truncation would have left a half codepoint here.
	if strings.ContainsRune(got, '�') {
		t.Error("truncation produced a replacement rune: it cut mid-codepoint")
	}
}

func decisionFixture() *model.Observation {
	return &model.Observation{
		ID: "dec-1", Timestamp: time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC),
		Layer: model.LayerNetworkEgress, Fidelity: model.FidelityCircumstantial,
		Source: "policy_decision", Confidence: 0.2,
		Labels: map[string]string{TenantLabel: "tenant-a", LabelRuleID: "r1"},
	}
}

func TestReviewObservationIsAValidStorableObservation(t *testing.T) {
	reviewedAt := time.Date(2026, 10, 4, 12, 30, 0, 0, time.UTC)
	rv := Review{
		ID:         ReviewID("tenant-a", "dec-1", "alice@example.com", "false_positive", "known batch job"),
		DecisionID: "dec-1", TenantID: "tenant-a", Verdict: VerdictFalsePositive,
		Note: "known batch job", Reviewer: "alice@example.com", ReviewedAt: reviewedAt,
	}
	obs := ReviewObservation(rv, decisionFixture())
	if err := obs.Validate(); err != nil {
		t.Fatalf("review observation does not validate: %v", err)
	}
	if obs.Source != SourceReview {
		t.Errorf("source %q, want %q", obs.Source, SourceReview)
	}
	if obs.Layer != model.LayerNetworkEgress {
		t.Errorf("layer %q, want the decision's layer", obs.Layer)
	}
	// Fidelity and confidence are the review's own, NOT the judged decision's.
	if obs.Fidelity != model.FidelityStrong {
		t.Errorf("fidelity %q, want strong", obs.Fidelity)
	}
	if obs.Confidence != 1.0 {
		t.Errorf("confidence %v, want 1.0", obs.Confidence)
	}
	if !obs.Timestamp.Equal(reviewedAt) {
		t.Errorf("timestamp %v, want the review's own %v", obs.Timestamp, reviewedAt)
	}
	if obs.ActorHint != rv.Reviewer || obs.RawEvidenceRef != rv.DecisionID {
		t.Errorf("attribution lost: actor_hint=%q evidence_ref=%q", obs.ActorHint, obs.RawEvidenceRef)
	}
}

func TestReviewObservationLabelSetIsClosed(t *testing.T) {
	rv := Review{ID: "r", DecisionID: "dec-1", TenantID: "tenant-a", Verdict: VerdictNeedsInfo,
		Note: "zqx-distinctive-note", Reviewer: "alice", ReviewedAt: time.Now().UTC()}
	// The judged decision carries a label a review must not restate.
	dec := decisionFixture()
	dec.Labels["source_ip"] = "10.0.0.1"
	obs := ReviewObservation(rv, dec)
	want := map[string]string{
		LabelDecisionID: "dec-1", LabelVerdict: "needs_info", LabelReviewer: "alice",
		LabelNote: "zqx-distinctive-note", TenantLabel: "tenant-a",
	}
	if len(obs.Labels) != len(want) {
		t.Fatalf("review labels %v, want exactly %v", obs.Labels, want)
	}
	for k, v := range want {
		if obs.Labels[k] != v {
			t.Errorf("label %s = %q, want %q", k, obs.Labels[k], v)
		}
	}
	if _, leaked := obs.Labels["source_ip"]; leaked {
		t.Error("the judged decision's labels were copied onto the review")
	}
	if strings.Contains(obs.Description, rv.Note) {
		t.Error("the note was restated in the description column")
	}
}

func TestReviewRoundTripsThroughItsObservation(t *testing.T) {
	rv := Review{ID: "r1", DecisionID: "dec-1", TenantID: "tenant-a", Verdict: VerdictTruePositive,
		Note: "escalated to IR", Reviewer: "bob", ReviewedAt: time.Date(2026, 10, 4, 1, 2, 3, 0, time.UTC)}
	back := ReviewFromObservation(ReviewObservation(rv, decisionFixture()))
	if back != rv {
		t.Errorf("round trip lost data:\n got %+v\nwant %+v", back, rv)
	}
}

func TestReviewObservationFallsBackToAValidLayer(t *testing.T) {
	// A decision that is absent, or carries a layer this build does not know, must still produce
	// a storable review: refusing the write would lose the human's judgement to a data defect.
	for name, dec := range map[string]*model.Observation{
		"nil":     nil,
		"invalid": {Layer: model.Layer("made_up")},
	} {
		obs := ReviewObservation(Review{ID: "r", DecisionID: "d", TenantID: "t",
			Verdict: VerdictNeedsInfo, Reviewer: "alice", ReviewedAt: time.Now().UTC()}, dec)
		if err := obs.Validate(); err != nil {
			t.Errorf("%s decision: review does not validate: %v", name, err)
		}
	}
}

func TestIsReview(t *testing.T) {
	if IsReview(nil) {
		t.Error("nil is not a review")
	}
	if IsReview(decisionFixture()) {
		t.Error("a decision is not a review")
	}
	rv := ReviewObservation(Review{ID: "r", Verdict: VerdictNeedsInfo, ReviewedAt: time.Now()}, nil)
	if !IsReview(&rv) {
		t.Error("a review observation is not recognised as one")
	}
}
