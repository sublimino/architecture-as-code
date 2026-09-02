// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"net"
	"strings"
)

// AIProviderClassifier inspects socket destination and metadata to identify AI model providers.
type AIProviderClassifier interface {
	Classify(dstIP net.IP, dstPort uint16, domain string) (provider string, class string)
}

type aiProviderClassifierImpl struct {
	customKnown map[string]string // domain -> provider
}

// NewAIProviderClassifier returns a default AI model endpoint classifier.
func NewAIProviderClassifier() AIProviderClassifier {
	return &aiProviderClassifierImpl{
		customKnown: map[string]string{
			"api.openai.com":       ProviderOpenAI,
			"chatgpt.com":          ProviderOpenAI,
			"api.anthropic.com":    ProviderAnthropic,
			"claude.ai":            ProviderAnthropic,
			"api.deepseek.com":     ProviderDeepSeek,
			"ollama.local":         ProviderOllama,
			"ollama.default.svc":   ProviderOllama,
		},
	}
}

func (c *aiProviderClassifierImpl) Classify(dstIP net.IP, dstPort uint16, domain string) (string, string) {
	d := strings.ToLower(strings.TrimSpace(domain))

	// 1. Check direct domain matches
	if p, ok := c.customKnown[d]; ok {
		if p == ProviderOllama {
			return p, ClassLocalInference
		}
		return p, ClassApprovedModelEgress
	}

	// 2. Check domain suffix rules
	if strings.HasSuffix(d, ".openai.com") || strings.HasSuffix(d, ".oaistatic.com") {
		return ProviderOpenAI, ClassApprovedModelEgress
	}
	if strings.HasSuffix(d, ".anthropic.com") || strings.HasSuffix(d, ".claude.ai") {
		return ProviderAnthropic, ClassApprovedModelEgress
	}
	if strings.HasSuffix(d, ".deepseek.com") {
		return ProviderDeepSeek, ClassApprovedModelEgress
	}

	// 3. Check Local Inference port (Ollama 11434)
	if dstPort == 11434 {
		return ProviderOllama, ClassLocalInference
	}

	// 4. Check for loopback / local network inference
	if dstIP != nil && (dstIP.IsLoopback() || dstIP.IsPrivate()) && (dstPort == 11434 || dstPort == 8000 || dstPort == 8080) {
		if strings.Contains(d, "ollama") || strings.Contains(d, "vllm") || strings.Contains(d, "tgi") {
			return ProviderOllama, ClassLocalInference
		}
	}

	// 5. Unknown Direct IP / Potential Exfiltration
	if d == "" || d == dstIP.String() {
		// Connection without DNS domain or raw public IP
		if dstIP != nil && !dstIP.IsPrivate() && !dstIP.IsLoopback() {
			return ProviderC2, ClassPotentialExfil
		}
		return ProviderUnknown, ClassUnknownDirectIP
	}

	return ProviderUnknown, ClassUnknownDirectIP
}
