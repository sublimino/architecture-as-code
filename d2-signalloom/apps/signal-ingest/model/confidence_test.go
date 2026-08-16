package model

import (
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

func TestDeriveConfidence_CrossLayerSuggestive_Actionable(t *testing.T) {
	// One suggestive identity + one suggestive behavioural = actionable (0.5-0.8).
	evidence := []EvidenceLink{
		{ObservationID: "a", Layer: LayerIdentityAuth, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
		{ObservationID: "b", Layer: LayerBehavioural, Fidelity: FidelitySuggestive, Timestamp: time.Now()},
	}
	r := DeriveConfidence(evidence)
	if r.Score < 0.5 || r.Score > 0.8 {
		t.Errorf("cross-layer suggestive: want [0.5, 0.8], got %f", r.Score)
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
