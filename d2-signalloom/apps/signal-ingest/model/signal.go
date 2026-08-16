// Package model defines the core domain types for the signal-ingest service.
package model

import "time"

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
