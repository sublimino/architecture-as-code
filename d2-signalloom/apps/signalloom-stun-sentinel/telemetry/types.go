// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"net"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/ebpf"
)

// AI Provider Identifiers
const (
	ProviderOpenAI    = "OpenAI"
	ProviderAnthropic = "Anthropic"
	ProviderOllama    = "Ollama"
	ProviderDeepSeek  = "DeepSeek"
	ProviderUnknown   = "Unknown"
	ProviderC2        = "C2_Exfiltration"
)

// Classification Categories
const (
	ClassApprovedModelEgress = "approved_model_egress"
	ClassLocalInference      = "local_inference"
	ClassUnknownDirectIP     = "unknown_direct_ip"
	ClassPotentialExfil      = "potential_exfiltration"
)

// PodMetadata encapsulates identity and tenant tags for an autonomous agent workload.
type PodMetadata struct {
	PodName        string            `json:"pod_name"`
	PodNamespace   string            `json:"pod_namespace"`
	PodUID         string            `json:"pod_uid"`
	ServiceAccount string            `json:"service_account"`
	SPIFFEID       string            `json:"spiffe_id"`
	AgentRole      string            `json:"agent_role"`
	Labels         map[string]string `json:"labels,omitempty"`
}

// EnrichedFlowEvent joins raw kernel socket telemetry with Kubernetes pod identity and AI classification.
type EnrichedFlowEvent struct {
	ebpf.FlowEvent
	PodName        string    `json:"pod_name"`
	PodNamespace   string    `json:"pod_namespace"`
	PodUID         string    `json:"pod_uid"`
	ServiceAccount string    `json:"service_account"`
	SPIFFEID       string    `json:"spiffe_id"`
	AgentRole      string    `json:"agent_role"`
	Provider       string    `json:"provider"`
	Classification string    `json:"classification"`
	Domain         string    `json:"domain,omitempty"`
	EnrichedAt     time.Time `json:"enriched_at"`
}

// DNSResolver resolves IP addresses to hostnames.
type DNSResolver interface {
	LookupAddr(ip net.IP) (string, bool)
	Set(ip net.IP, host string)
}
