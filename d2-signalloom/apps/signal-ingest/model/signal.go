// Package model defines the core domain types for the signal-ingest service.
package model

import (
	"fmt"
	"math"
	"time"
)

// MaxLabelValueLen is the maximum length in bytes for a label value.
const MaxLabelValueLen = 4096

// Layer identifies which observability layer produced a signal.
type Layer string

const (
	LayerNetworkEgress    Layer = "network_egress"
	LayerIdentityAuth     Layer = "identity_authorization"
	LayerApplicationSaaS  Layer = "application_saas"
	LayerEndpointHost     Layer = "endpoint_host"
	LayerBehavioural      Layer = "behavioural"
	LayerCloudControlPlane Layer = "cloud_control_plane" // out of scope
	LayerProtocol         Layer = "protocol"              // out of scope
)

// ValidLayers returns the set of all known layers.
func ValidLayers() []Layer {
	return []Layer{
		LayerNetworkEgress,
		LayerIdentityAuth,
		LayerApplicationSaaS,
		LayerEndpointHost,
		LayerBehavioural,
		LayerCloudControlPlane,
		LayerProtocol,
	}
}

// InScopeLayers returns the five layers deployed in this build.
func InScopeLayers() []Layer {
	return []Layer{
		LayerNetworkEgress,
		LayerIdentityAuth,
		LayerApplicationSaaS,
		LayerEndpointHost,
		LayerBehavioural,
	}
}

// IsValid returns true if l is a known layer.
func (l Layer) IsValid() bool {
	for _, v := range ValidLayers() {
		if l == v {
			return true
		}
	}
	return false
}

// FidelityTier represents the structural quality of evidence.
// Tiers are structural, not additive: no quantity of suggestive signals
// reaches definitive without a corroborating strong or definitive signal.
type FidelityTier string

const (
	FidelityDefinitive     FidelityTier = "definitive"     // cryptographic proof
	FidelityStrong         FidelityTier = "strong"          // verified chain
	FidelitySuggestive     FidelityTier = "suggestive"      // pattern match
	FidelityCircumstantial FidelityTier = "circumstantial"  // timing/correlation
)

// FidelityWeight returns a numeric weight for confidence derivation.
func (f FidelityTier) FidelityWeight() float64 {
	switch f {
	case FidelityDefinitive:
		return 1.0
	case FidelityStrong:
		return 0.8
	case FidelitySuggestive:
		return 0.4
	case FidelityCircumstantial:
		return 0.2
	default:
		return 0.0
	}
}

// IsValid returns true if f is a known fidelity tier.
func (f FidelityTier) IsValid() bool {
	switch f {
	case FidelityDefinitive, FidelityStrong, FidelitySuggestive, FidelityCircumstantial:
		return true
	default:
		return false
	}
}

// Observation is a single signal from any layer.
type Observation struct {
	ID             string            `json:"id"`
	Timestamp      time.Time         `json:"timestamp"`
	Layer          Layer             `json:"layer"`
	Fidelity       FidelityTier      `json:"fidelity"`
	Source         string            `json:"source"`
	Confidence     float64           `json:"confidence"`
	ActorHint      string            `json:"actor_hint,omitempty"`
	RawEvidenceRef string            `json:"raw_evidence_ref"`
	Labels         map[string]string `json:"labels,omitempty"`
	Description    string            `json:"description"`
}

// Validate checks that all required fields are present and values are in range.
// Returns nil if the observation is valid, or an error describing the first
// violation found.
func (o Observation) Validate() error {
	if o.ID == "" {
		return fmt.Errorf("observation ID is required")
	}
	if o.Timestamp.IsZero() {
		return fmt.Errorf("observation timestamp is required (got zero)")
	}
	if !o.Layer.IsValid() {
		return fmt.Errorf("invalid layer %q", o.Layer)
	}
	if !o.Fidelity.IsValid() {
		return fmt.Errorf("invalid fidelity tier %q", o.Fidelity)
	}
	if o.Source == "" {
		return fmt.Errorf("observation source is required")
	}
	if math.IsNaN(o.Confidence) || math.IsInf(o.Confidence, 0) {
		return fmt.Errorf("confidence must be a finite number, got %v", o.Confidence)
	}
	if o.Confidence < 0 || o.Confidence > 1 {
		return fmt.Errorf("confidence must be in [0, 1], got %v", o.Confidence)
	}
	for k, v := range o.Labels {
		if k == "" {
			return fmt.Errorf("label key must not be empty")
		}
		if len(v) > MaxLabelValueLen {
			return fmt.Errorf("label value for key %q exceeds max length (%d > %d)", k, len(v), MaxLabelValueLen)
		}
	}
	return nil
}
