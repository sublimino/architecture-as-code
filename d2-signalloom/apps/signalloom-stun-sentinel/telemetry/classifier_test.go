// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"net"
	"testing"
)

func TestClassifierAIProviders(t *testing.T) {
	c := NewAIProviderClassifier()

	tests := []struct {
		name         string
		dstIP        net.IP
		dstPort      uint16
		domain       string
		wantProvider string
		wantClass    string
	}{
		{
			name:         "OpenAI API Domain",
			dstIP:        net.ParseIP("104.18.2.161"),
			dstPort:      443,
			domain:       "api.openai.com",
			wantProvider: ProviderOpenAI,
			wantClass:    ClassApprovedModelEgress,
		},
		{
			name:         "OpenAI Subdomain Wildcard",
			dstIP:        net.ParseIP("104.18.2.161"),
			dstPort:      443,
			domain:       "chat.openai.com",
			wantProvider: ProviderOpenAI,
			wantClass:    ClassApprovedModelEgress,
		},
		{
			name:         "Anthropic Claude API",
			dstIP:        net.ParseIP("160.155.1.1"),
			dstPort:      443,
			domain:       "api.anthropic.com",
			wantProvider: ProviderAnthropic,
			wantClass:    ClassApprovedModelEgress,
		},
		{
			name:         "DeepSeek API",
			dstIP:        net.ParseIP("103.21.244.0"),
			dstPort:      443,
			domain:       "api.deepseek.com",
			wantProvider: ProviderDeepSeek,
			wantClass:    ClassApprovedModelEgress,
		},
		{
			name:         "Ollama Local Inference Port",
			dstIP:        net.ParseIP("127.0.0.1"),
			dstPort:      11434,
			domain:       "localhost",
			wantProvider: ProviderOllama,
			wantClass:    ClassLocalInference,
		},
		{
			name:         "Ollama In-Cluster Service",
			dstIP:        net.ParseIP("10.96.120.45"),
			dstPort:      11434,
			domain:       "ollama.default.svc",
			wantProvider: ProviderOllama,
			wantClass:    ClassLocalInference,
		},
		{
			name:         "Direct Public IP / C2 Exfiltration",
			dstIP:        net.ParseIP("198.51.100.42"),
			dstPort:      8443,
			domain:       "198.51.100.42",
			wantProvider: ProviderC2,
			wantClass:    ClassPotentialExfil,
		},
		{
			name:         "Unknown Private IP",
			dstIP:        net.ParseIP("10.0.5.12"),
			dstPort:      9000,
			domain:       "",
			wantProvider: ProviderUnknown,
			wantClass:    ClassUnknownDirectIP,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotProvider, gotClass := c.Classify(tt.dstIP, tt.dstPort, tt.domain)
			if gotProvider != tt.wantProvider {
				t.Errorf("Classify() gotProvider = %v, want %v", gotProvider, tt.wantProvider)
			}
			if gotClass != tt.wantClass {
				t.Errorf("Classify() gotClass = %v, want %v", gotClass, tt.wantClass)
			}
		})
	}
}
