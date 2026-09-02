package appraiser

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/factory-appraiser/validator"
)

func TestAppraise(t *testing.T) {
	now := time.Now().UTC()
	staleTTL := 30 * time.Minute

	candidates := []validator.Candidate{
		{
			CandidateID: "cand-fresh",
			IntentID:    "intent-1",
			CreatedAt:   now.Add(-5 * time.Minute),
		},
		{
			CandidateID: "cand-stale-ttl",
			IntentID:    "intent-2",
			CreatedAt:   now.Add(-45 * time.Minute),
		},
		{
			CandidateID: "cand-expired-intent",
			IntentID:    "intent-expired",
			CreatedAt:   now.Add(-10 * time.Minute),
		},
	}

	intents := map[string]validator.Intent{
		"intent-1": {
			ID:     "intent-1",
			Expiry: now.Add(2 * time.Hour),
		},
		"intent-2": {
			ID:     "intent-2",
			Expiry: now.Add(2 * time.Hour),
		},
		"intent-expired": {
			ID:     "intent-expired",
			Expiry: now.Add(-1 * time.Minute),
		},
	}

	res, esc := Appraise(candidates, intents, now, staleTTL)

	if len(res.ActiveCandidates) != 1 || res.ActiveCandidates[0] != "cand-fresh" {
		t.Errorf("expected 1 active candidate [cand-fresh], got %v", res.ActiveCandidates)
	}
	if len(res.StaleCandidates) != 2 {
		t.Errorf("expected 2 stale candidates, got %v", res.StaleCandidates)
	}
	if res.Status != "escalated" {
		t.Errorf("expected status escalated, got %s", res.Status)
	}
	if esc == nil {
		t.Fatalf("expected escalation record, got nil")
	}
	if esc.Severity != "high" {
		t.Errorf("expected high severity, got %s", esc.Severity)
	}
}
