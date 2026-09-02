package appraiser

import (
	"crypto/sha256"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/factory-appraiser/validator"
)

// AppraisalResult is the outcome of a periodic appraisal cycle.
type AppraisalResult struct {
	AppraisalID      string    `json:"appraisal_id"`
	EvaluatedAt      time.Time `json:"evaluated_at"`
	ActiveCandidates []string  `json:"active_candidates"`
	StaleCandidates  []string  `json:"stale_candidates"`
	Status           string    `json:"status"`
}

// EscalationRecord represents an idempotent notification of stalled delivery.
type EscalationRecord struct {
	EscalationID string    `json:"escalation_id"`
	AppraisalID  string    `json:"appraisal_id"`
	Reason       string    `json:"reason"`
	TargetOncall string    `json:"target_oncall"`
	EscalatedAt  time.Time `json:"escalated_at"`
	Severity     string    `json:"severity"`
}

// Appraise evaluates candidates against intent expiries and TTL.
func Appraise(candidates []validator.Candidate, intents map[string]validator.Intent, now time.Time, staleTTL time.Duration) (AppraisalResult, *EscalationRecord) {
	appraisalID := fmt.Sprintf("appr-%d", now.Unix())
	var active []string
	var stale []string

	for _, c := range candidates {
		intent, hasIntent := intents[c.IntentID]
		isStale := false

		if hasIntent && !intent.Expiry.IsZero() && now.After(intent.Expiry) {
			isStale = true
		} else if now.Sub(c.CreatedAt) > staleTTL {
			isStale = true
		}

		if isStale {
			stale = append(stale, c.CandidateID)
		} else {
			active = append(active, c.CandidateID)
		}
	}

	status := "healthy"
	var escalation *EscalationRecord

	if len(stale) > 0 {
		status = "escalated"
		h := sha256.New()
		for _, s := range stale {
			h.Write([]byte(s))
		}
		digest := fmt.Sprintf("%x", h.Sum(nil))[:12]

		escalation = &EscalationRecord{
			EscalationID: fmt.Sprintf("esc-%s", digest),
			AppraisalID:  appraisalID,
			Reason:       fmt.Sprintf("%d candidate(s) exceed SLA/expiry TTL: %v", len(stale), stale),
			TargetOncall: "platform-delivery-oncall",
			EscalatedAt:  now,
			Severity:     "high",
		}
	}

	return AppraisalResult{
		AppraisalID:      appraisalID,
		EvaluatedAt:      now,
		ActiveCandidates: active,
		StaleCandidates:  stale,
		Status:           status,
	}, escalation
}
