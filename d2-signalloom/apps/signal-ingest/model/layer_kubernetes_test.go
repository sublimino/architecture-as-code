// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package model

import (
	"slices"
	"strings"
	"testing"
	"time"
)

// TestLayerKubernetes_ExistsIsValidAndInScope pins the three facts the k8saudit
// reference vertical depends on (catalogue "Adversarial-review corrections":
// the layer must exist FIRST, or every k8s rule's `obs.layer == "kubernetes"`
// gate matches nothing and the whole vertical is a silent no-op).
func TestLayerKubernetes_ExistsIsValidAndInScope(t *testing.T) {
	if LayerKubernetes != "kubernetes" {
		t.Fatalf("LayerKubernetes = %q, want %q", LayerKubernetes, "kubernetes")
	}
	if !LayerKubernetes.IsValid() {
		t.Error("LayerKubernetes must be a valid layer")
	}
	if !slices.Contains(ValidLayers(), LayerKubernetes) {
		t.Error("LayerKubernetes must be in ValidLayers()")
	}
	if !slices.Contains(InScopeLayers(), LayerKubernetes) {
		t.Error("LayerKubernetes must be in InScopeLayers(): the collector is registered and feeding it")
	}
}

// TestLayerKubernetes_ConfidenceHandlesIt proves DeriveConfidence treats a
// Kubernetes evidence link as a first-class distinct layer. confidence.go is
// generic over Layer, so the "wire it into confidence.go's layer handling"
// deliverable is satisfied by demonstrating a Kubernetes link is counted in the
// layer set and named in the chain, not dropped.
func TestLayerKubernetes_ConfidenceHandlesIt(t *testing.T) {
	now := time.Now()
	r := DeriveConfidence([]EvidenceLink{
		{ObservationID: "k8s-1", Layer: LayerKubernetes, Fidelity: FidelityStrong, Timestamp: now},
		{ObservationID: "net-1", Layer: LayerNetworkEgress, Fidelity: FidelitySuggestive, Timestamp: now},
	})
	if r.Score < 0.5 {
		t.Errorf("strong k8s + suggestive egress must be actionable (>=0.5), got %f; LayerKubernetes was not counted", r.Score)
	}
	found := false
	for _, c := range r.Chain {
		if strings.Contains(c, "kubernetes") {
			found = true
		}
	}
	if !found {
		t.Errorf("the confidence chain never names the kubernetes layer: %v", r.Chain)
	}
}
