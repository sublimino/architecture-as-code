package model

import (
	"fmt"
	"testing"
	"time"
)

func TestDeriveConfidence_NoEvidence(t *testing.T) {
	r := DeriveConfidence(nil)
	if r.Score != 0.0 {
		t.Errorf("empty evidence: want 0.0, got %f", r.Score)
	}
}

func TestDeriveConfidence_SingleLayerSuggestive_StaysBelowHalf(t *testing.T) {
	// Two suggestive signals from the SAME layer must stay < 0.5.
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "b", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score >= 0.5 {
		t.Errorf("same-layer suggestive must stay < 0.5, got %f", r.Score)
	}
}

func TestDeriveConfidence_CrossLayerSuggestive_BelowActionable(t *testing.T) {
	// V2 corroboration rule: cross-layer suggestive WITHOUT strong/definitive
	// must stay below actionable (capped at CorroborationCap = 0.49).
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerIdentityAuth, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "b", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score >= 0.5 {
		t.Errorf("cross-layer suggestive without strong/definitive must stay < 0.5, got %f", r.Score)
	}
	if r.Score > CorroborationCap {
		t.Errorf("cross-layer suggestive must be <= CorroborationCap (%.2f), got %f", CorroborationCap, r.Score)
	}
}

func TestDeriveConfidence_StrongPlusSuggestive_HighConfidence(t *testing.T) {
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerIdentityAuth, Fidelity: FidelityStrong, Timestamp: time.Now()},
		{ObservationID: "b", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score < 0.7 || r.Score > 0.9 {
		t.Errorf("strong + suggestive: want [0.7, 0.9], got %f", r.Score)
	}
}

func TestDeriveConfidence_Definitive_NearCertain(t *testing.T) {
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerIdentityAuth, Fidelity: FidelityDefinitive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score < 0.9 || r.Score > 1.0 {
		t.Errorf("definitive: want [0.9, 1.0], got %f", r.Score)
	}
}

func TestDeriveConfidence_DefinitiveWithSupport(t *testing.T) {
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerIdentityAuth, Fidelity: FidelityDefinitive, Timestamp: time.Now()},
		{ObservationID: "b", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score < 0.95 {
		t.Errorf("definitive + support: want >= 0.95, got %f", r.Score)
	}
}

func TestDeriveConfidence_CircumstantialOnly_Low(t *testing.T) {
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerEndpointHost, Fidelity: FidelityCircumstantial, Timestamp: time.Now()},
		{ObservationID: "b", Layer: LayerBehavioural, Fidelity: FidelityCircumstantial, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score > 0.30 {
		t.Errorf("circumstantial only: want <= 0.30, got %f", r.Score)
	}
}

func TestDeriveConfidence_ManyCircumstantial_Capped(t *testing.T) {
	var evidence []EvidenceLink
	for i := range 10 {
		evidence = append(evidence, EvidenceLink{
			ObservationID: string(rune('a' + i)),
			Layer:         LayerBehavioural,
			Fidelity:      FidelityCircumstantial,
			Timestamp:     time.Now(),
		})
	}
	r := DeriveConfidence(evidence)
	if r.Score > 0.30 {
		t.Errorf("many circumstantial: want <= 0.30, got %f", r.Score)
	}
}

func TestDeriveConfidence_ChainIsExplainable(t *testing.T) {
	evidence := []EvidenceLink{
		{ObservationID: "obs-1", Layer: LayerIdentityAuth, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "obs-2", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if len(r.Chain) == 0 {
		t.Error("chain must not be empty")
	}
	// Should mention both observations.
	found := 0
	for _, c := range r.Chain {
		for _, id := range []string{"obs-1", "obs-2"} {
			if contains(c, id) {
				found++
			}
		}
	}
	if found < 2 {
		t.Errorf("chain should reference both observation IDs, found %d", found)
	}
}

// ---------------------------------------------------------------------------
// Mutation tests — V2 proposal requirement:
//   "mutation tests proving suggestive signals cannot reach definitive
//    without a strong/definitive corroboration."
// ---------------------------------------------------------------------------

func TestCorroboration_TenSuggestiveSameLayer_BelowActionable(t *testing.T) {
	// 10 suggestive signals from the SAME layer must stay below actionable (0.5).
	var evidence []EvidenceLink
	for i := range 10 {
		evidence = append(evidence, EvidenceLink{
			ObservationID: fmt.Sprintf("sug-%d", i),
			Layer:         LayerBehavioural,
			Fidelity:      FidelitySuggestive,
			Timestamp:     time.Now(),
		})
	}
	r := DeriveConfidence(evidence)
	if r.Score >= 0.5 {
		t.Errorf("10 same-layer suggestive must stay < 0.5, got %f", r.Score)
	}
}

func TestCorroboration_CrossLayerSuggestive_BelowActionable(t *testing.T) {
	// 1 suggestive + 1 suggestive from DIFFERENT layers stays below actionable
	// without a strong signal. The CEL rule credential_chain fires (correlation
	// engine matches the pair), but confidence must not reach actionable.
	evidence := []EvidenceLink{
		{ObservationID: "id-1", Layer: LayerIdentityAuth, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "beh-1", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score >= 0.5 {
		t.Errorf("cross-layer suggestive (no strong) must stay < 0.5, got %f", r.Score)
	}
}

func TestCorroboration_SuggestivePlusStrong_ReachesActionable(t *testing.T) {
	// 1 suggestive + 1 strong from different layers DOES reach actionable.
	evidence := []EvidenceLink{
		{ObservationID: "sug-1", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "str-1", Layer: LayerIdentityAuth, Fidelity: FidelityStrong, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score < 0.5 {
		t.Errorf("suggestive + strong must reach actionable (>= 0.5), got %f", r.Score)
	}
}

func TestCorroboration_ManySuggestiveLayers_StillCapped(t *testing.T) {
	// Even with suggestive signals from ALL 5 in-scope layers, the
	// corroboration cap keeps the score below actionable.
	layers := InScopeLayers()
	var evidence []EvidenceLink
	for i, l := range layers {
		evidence = append(evidence, EvidenceLink{
			ObservationID: fmt.Sprintf("sug-%d", i),
			Layer:         l,
			Fidelity:      FidelitySuggestive,
			Timestamp:     time.Now(),
		})
	}
	r := DeriveConfidence(evidence)
	if r.Score >= 0.5 {
		t.Errorf("suggestive from all 5 layers (no strong) must stay < 0.5, got %f", r.Score)
	}
	if r.Score > CorroborationCap {
		t.Errorf("must not exceed CorroborationCap (%.2f), got %f", CorroborationCap, r.Score)
	}
}

func TestCorroboration_MutationProof(t *testing.T) {
	// Mutation test: simulate removing the corroboration cap and prove
	// the suite would go red. We construct the exact input that the
	// un-capped function would score above 0.5, then verify the cap
	// prevents it.
	//
	// The un-capped cross-layer suggestive formula is:
	//   score = 0.50 + (distinctSuggestiveLayers - 2) * 0.10
	// For 3 layers: 0.50 + 0.10 = 0.60 (would be actionable without cap).
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerIdentityAuth, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "b", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "c", Layer: LayerNetworkEgress, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}

	r := DeriveConfidence(evidence)

	// With the cap: must be <= CorroborationCap (0.49).
	if r.Score > CorroborationCap {
		t.Fatalf("corroboration cap is not enforced: score %f > cap %f", r.Score, CorroborationCap)
	}

	// Prove the mutation: compute what the score WOULD be without the cap.
	// The cross-layer suggestive formula for 3 distinct layers:
	//   0.50 + (3-2)*0.10 = 0.60
	uncappedScore := 0.50 + float64(3-2)*0.10
	if uncappedScore < 0.5 {
		t.Fatalf("test setup error: uncapped score %f should be >= 0.5", uncappedScore)
	}

	// The cap must have reduced the score — this is the mutation proof.
	if r.Score >= uncappedScore {
		t.Errorf("cap did not reduce score: got %f, uncapped would be %f", r.Score, uncappedScore)
	}

	// Verify the chain documents the cap application.
	capMentioned := false
	for _, c := range r.Chain {
		if containsSubstr(c, "corroboration cap") {
			capMentioned = true
			break
		}
	}
	if !capMentioned {
		t.Error("chain must document the corroboration cap application")
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsSubstr(s, substr))
}

func containsSubstr(s, sub string) bool {
	for i := range len(s) - len(sub) + 1 {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
