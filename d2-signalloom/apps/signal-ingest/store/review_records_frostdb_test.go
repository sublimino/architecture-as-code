//go:build frostdb

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// A human's verdict on a policy decision is a policy_review observation carrying four label keys
// the allow-list did not previously admit (decision_id, verdict, reviewer, note).
//
// This is the test that matters most for the review feature, because of HOW the allow-list fails.
// A disallowed key refuses the whole batch at the Append chokepoint, before any Arrow record is
// built — so without these keys the review route would return 500 on every single POST under the
// frostdb build, while every unit test over the memory store passed. The memory store has no
// allow-list at all, which means api/ and policy/ coverage cannot see this defect: only a
// frostdb-tagged test can.
func TestFrostDBAdmitsAPolicyReviewRow(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	ts := time.Date(2026, 10, 5, 9, 15, 0, 0, time.UTC)
	review := model.Observation{
		ID: strings.Repeat("a", 64), Timestamp: ts, Layer: model.LayerNetworkEgress,
		Fidelity: model.FidelityStrong, Source: "policy_review", Confidence: 1,
		ActorHint: "alice@example.com", RawEvidenceRef: strings.Repeat("d", 64),
		Description: "policy review: decision " + strings.Repeat("d", 64) + " judged false_positive by alice@example.com",
		Labels: map[string]string{
			"tenant_id":   "kusari",
			"decision_id": strings.Repeat("d", 64),
			"verdict":     "false_positive",
			"reviewer":    "alice@example.com",
			"note":        "known nightly batch job; egress is to our own bucket",
		},
	}
	if err := s.Append(context.Background(), []model.Observation{review}); err != nil {
		t.Fatalf("FrostDB refused a policy_review row: %v", err)
	}

	rows, err := s.QueryRange(context.Background(), Query{After: ts.Add(-time.Minute), Before: ts.Add(time.Minute)})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	var found *model.Observation
	for i := range rows {
		if rows[i].ID == review.ID {
			found = &rows[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("the review row appended but did not read back; got %d rows", len(rows))
	}
	// The four review labels must survive the round trip through the columnar store: a verdict
	// that appends and then reads back empty is an unfalsifiable audit record.
	for key, want := range map[string]string{
		"decision_id": review.Labels["decision_id"],
		"verdict":     "false_positive",
		"reviewer":    "alice@example.com",
		"note":        review.Labels["note"],
		"tenant_id":   "kusari",
	} {
		if got := found.Labels[key]; got != want {
			t.Errorf("label %s read back as %q, want %q", key, got, want)
		}
	}
	if found.Source != "policy_review" {
		t.Errorf("source read back as %q, want policy_review", found.Source)
	}
}

// Each of the four keys must be in the allow-list on its own. A single missing key refuses the
// whole batch, so a test that only checks a complete review cannot say which key carries it.
func TestReviewLabelKeysAreIndividuallyAllowed(t *testing.T) {
	for _, key := range []string{"decision_id", "verdict", "reviewer", "note"} {
		if !IsAllowedLabelKey(key) {
			t.Errorf("review label key %q is not in the segment allow-list; every POST review would 500", key)
		}
	}
}
