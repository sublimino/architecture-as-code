// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// DefaultGapWindow is the temporal window (5 minutes) in which kernel drops invalidate clean egress claims.
const DefaultGapWindow = 5 * time.Minute

// GapEvaluationResult holds the outcome of evaluating telemetry gap markers against clean assertions.
type GapEvaluationResult struct {
	HasActiveGap          bool                `json:"has_active_gap"`
	GapCount              int                 `json:"gap_count"`
	TotalDroppedEvents    uint64              `json:"total_dropped_events"`
	CleanAssertionValid   bool                `json:"clean_assertion_valid"`
	ActiveGaps            []model.Observation `json:"active_gaps"`
	DegradationReason     string              `json:"degradation_reason,omitempty"`
}

// TelemetryGapEvaluator enforces fail-closed validation of network security claims.
type TelemetryGapEvaluator struct {
	window time.Duration
}

// NewTelemetryGapEvaluator creates a new evaluator with the given lookback window.
func NewTelemetryGapEvaluator(window time.Duration) *TelemetryGapEvaluator {
	if window <= 0 {
		window = DefaultGapWindow
	}
	return &TelemetryGapEvaluator{window: window}
}

// Evaluate inspects a batch of observations and returns whether any active telemetry gaps invalidate clean claims.
func (e *TelemetryGapEvaluator) Evaluate(observations []model.Observation, asOf time.Time) GapEvaluationResult {
	if asOf.IsZero() {
		asOf = time.Now().UTC()
	}
	cutoff := asOf.Add(-e.window)

	res := GapEvaluationResult{
		CleanAssertionValid: true,
	}

	for _, obs := range observations {
		if obs.Layer == model.LayerNetworkEgress && obs.Labels["type"] == "telemetry_gap" {
			if obs.Timestamp.After(cutoff) || obs.Timestamp.Equal(cutoff) {
				res.HasActiveGap = true
				res.GapCount++
				res.ActiveGaps = append(res.ActiveGaps, obs)

				// Parse dropped count if present
				if countStr, ok := obs.Labels["dropped_count"]; ok {
					var c uint64
					for _, ch := range countStr {
						if ch >= '0' && ch <= '9' {
							c = c*10 + uint64(ch-'0')
						}
					}
					res.TotalDroppedEvents += c
				}

				if reason, ok := obs.Labels["reason"]; ok && res.DegradationReason == "" {
					res.DegradationReason = reason
				}
			}
		}
	}

	if res.HasActiveGap {
		// Fail-closed invariant: clean egress assertions are strictly INVALID during telemetry gaps
		res.CleanAssertionValid = false
	}

	return res
}
