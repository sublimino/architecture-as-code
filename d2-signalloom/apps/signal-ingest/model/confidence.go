package model

import "fmt"

// ConfidenceResult holds a derived confidence score and its explanation.
type ConfidenceResult struct {
	Score float64  `json:"score"`
	Chain []string `json:"chain"`
}

// CorroborationCap is the maximum confidence score when no evidence link
// has fidelity "strong" or "definitive". This enforces the V2 proposal's
// hard corroboration rule:
//
//	"Fidelity tiers are structural, not additive: no quantity of suggestive
//	 signals reaches definitive without a corroborating strong or definitive
//	 signal."
//
// The cap is set below the 0.5 actionable threshold so that purely
// suggestive/circumstantial evidence chains never reach actionable status.
const CorroborationCap = 0.49

// DeriveConfidence computes an actor confidence from a set of evidence links.
//
// Critical invariant (V2 proposal): fidelity tiers are structural, not additive.
//   - No quantity of suggestive/circumstantial signals can reach actionable (0.5)
//     without a corroborating strong or definitive signal.
//   - Any strong signal + suggestive = high confidence (0.7-0.9).
//   - A definitive signal = near-certain (0.9-1.0).
func DeriveConfidence(evidence []EvidenceLink) ConfidenceResult {
	if len(evidence) == 0 {
		return ConfidenceResult{Score: 0.0, Chain: []string{"no evidence"}}
	}

	var chain []string
	hasDefinitive := false
	hasStrong := false
	layerSet := make(map[Layer]struct{})
	suggestiveLayers := make(map[Layer]int)
	circumstantialCount := 0

	for _, e := range evidence {
		layerSet[e.Layer] = struct{}{}
		switch e.Fidelity {
		case FidelityDefinitive:
			hasDefinitive = true
			chain = append(chain, fmt.Sprintf("definitive evidence from %s (%s)", e.Layer, e.ObservationID))
		case FidelityStrong:
			hasStrong = true
			chain = append(chain, fmt.Sprintf("strong evidence from %s (%s)", e.Layer, e.ObservationID))
		case FidelitySuggestive:
			suggestiveLayers[e.Layer]++
			chain = append(chain, fmt.Sprintf("suggestive evidence from %s (%s)", e.Layer, e.ObservationID))
		case FidelityCircumstantial:
			circumstantialCount++
			chain = append(chain, fmt.Sprintf("circumstantial evidence from %s (%s)", e.Layer, e.ObservationID))
		}
	}

	distinctLayers := len(layerSet)
	distinctSuggestiveLayers := len(suggestiveLayers)

	var score float64

	switch {
	case hasDefinitive:
		// Definitive signal: near-certain regardless of supporting evidence.
		score = 0.95
		if hasStrong || distinctSuggestiveLayers > 0 {
			score = 0.98
		}
		chain = append(chain, "-> definitive tier: near-certain")

	case hasStrong:
		// Strong + any supporting signal -> high confidence.
		score = 0.75
		if distinctSuggestiveLayers > 0 {
			score = 0.85
		}
		if distinctLayers >= 3 {
			score = 0.90
		}
		chain = append(chain, "-> strong tier: high confidence")

	case distinctSuggestiveLayers >= 2:
		// Cross-layer suggestive: actionable range (0.5-0.8).
		score = 0.50 + float64(distinctSuggestiveLayers-2)*0.10
		if score > 0.80 {
			score = 0.80
		}
		if circumstantialCount > 0 {
			score += 0.05
			if score > 0.80 {
				score = 0.80
			}
		}
		chain = append(chain, fmt.Sprintf("-> cross-layer suggestive (%d layers): actionable", distinctSuggestiveLayers))

	case distinctSuggestiveLayers == 1:
		// Single-layer suggestive: stays below 0.5 regardless of count.
		count := 0
		for _, c := range suggestiveLayers {
			count = c
		}
		score = 0.30
		if count > 1 {
			score = 0.40
		}
		if circumstantialCount > 0 {
			score = 0.45
		}
		chain = append(chain, "-> single-layer suggestive: below actionable threshold")

	default:
		// Only circumstantial signals.
		score = 0.10 + float64(circumstantialCount)*0.05
		if score > 0.30 {
			score = 0.30
		}
		chain = append(chain, "-> circumstantial only: low confidence")
	}

	// V2 hard corroboration rule: if no evidence link has fidelity "strong"
	// or "definitive", cap the score below the actionable threshold.
	// "Fidelity tiers are structural, not additive: no quantity of suggestive
	//  signals reaches definitive without a corroborating strong or definitive
	//  signal."
	if !hasStrong && !hasDefinitive && score > CorroborationCap {
		chain = append(chain, fmt.Sprintf("-> corroboration cap applied: %.2f -> %.2f (no strong/definitive evidence)", score, CorroborationCap))
		score = CorroborationCap
	}

	return ConfidenceResult{Score: score, Chain: chain}
}
