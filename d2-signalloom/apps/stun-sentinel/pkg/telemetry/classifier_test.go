// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"net"
	"testing"
)

func TestClassifierIdentifiesProvidersAndCategories(t *testing.T) {
	c := NewAIProviderClassifier()

	tests := []struct {
		name       string
		dstIP      net.IP
		dstPort    uint16
		domain     string
		wantProv   string
		wantClass  string
	}{
		{
			name:      "OpenAI API",
			dstIP:     net.ParseIP("104.18.2.1"),
			dstPort:   443,
			domain:    "api.openai.com",
			wantProv:  ProviderOpenAI,
			wantClass: ClassApprovedModelEgress,
		},
		{
			name:      "Anthropic API",
			dstIP:     net.ParseIP("104.18.3.1"),
			dstPort:   443,
			domain:    "api.anthropic.com",
			wantProv:  ProviderAnthropic,
			wantClass: ClassApprovedModelEgress,
		},
		{
			name:      "DeepSeek API",
			dstIP:     net.ParseIP("104.18.4.1"),
			dstPort:   443,
			domain:    "api.deepseek.com",
			wantProv:  ProviderDeepSeek,
			wantClass: ClassApprovedModelEgress,
		},
		{
			name:      "Local Ollama",
			dstIP:     net.ParseIP("127.0.0.1"),
			dstPort:   11434,
			domain:    "localhost",
			wantProv:  ProviderOllama,
			wantClass: ClassLocalInference,
		},
		{
			name:      "Potential Exfil to Raw Public IP",
			dstIP:     net.ParseIP("198.51.100.23"),
			dstPort:   9001,
			domain:    "",
			wantProv:  ProviderC2,
			wantClass: ClassPotentialExfil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotProv, gotClass := c.Classify(tt.dstIP, tt.dstPort, tt.domain)
			if gotProv != tt.wantProv || gotClass != tt.wantClass {
				t.Errorf("Classify(%v, %d, %q) = (%q, %q); want (%q, %q)",
					tt.dstIP, tt.dstPort, tt.domain, gotProv, gotClass, tt.wantProv, tt.wantClass)
			}
		})
	}
}
