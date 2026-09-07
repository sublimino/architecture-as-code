// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea"
)

func TestIdentityRules_Compile(t *testing.T) {
	for _, r := range IdentityAuditRules() {
		_, err := compileRule(r.CEL)
		if err != nil {
			t.Errorf("identity rule %q failed to compile: %v", r.Name, err)
		}
	}
}

func TestRule_VaultOutOfRoleAccess_Symmetric(t *testing.T) {
	rules := IdentityAuditRules()
	var rule Rule
	for _, r := range rules {
		if r.Name == "vault_out_of_role_access" {
			rule = r
			break
		}
	}
	if rule.Name == "" {
		t.Fatalf("vault_out_of_role_access rule not found")
	}

	a := map[string]any{
		"layer":      "identity_authorization",
		"actor_hint": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		"source":     "openbao-audit",
		"timestamp":  int64(100),
	}
	b := map[string]any{
		"layer":      "network_egress",
		"actor_hint": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		"source":     "sentinel.ebpf",
		"timestamp":  int64(150),
	}

	// Forward match: correlate(a, b)
	if !evalRule(t, rule.CEL, a, b) {
		t.Fatalf("expected vault_out_of_role_access match for (a, b)")
	}

	// Symmetric match: correlate(b, a) == correlate(a, b)
	if !evalRule(t, rule.CEL, b, a) {
		t.Fatalf("expected symmetric vault_out_of_role_access match for (b, a)")
	}

	// Different actor hints should not match
	c := map[string]any{
		"layer":      "network_egress",
		"actor_hint": "spiffe://cluster.local/ns/default/sa/other-sa",
		"source":     "sentinel.ebpf",
		"timestamp":  int64(150),
	}
	if evalRule(t, rule.CEL, a, c) {
		t.Fatalf("expected no match for mismatched actor hints")
	}
}

func TestRule_VaultPrivilegeEscalation_Symmetric(t *testing.T) {
	rules := IdentityAuditRules()
	var rule Rule
	for _, r := range rules {
		if r.Name == "vault_privilege_escalation" {
			rule = r
			break
		}
	}
	if rule.Name == "" {
		t.Fatalf("vault_privilege_escalation rule not found")
	}

	a := map[string]any{
		"layer":      "identity_authorization",
		"actor_hint": "agent-cardvault-0",
		"source":     "openbao-audit",
		"timestamp":  int64(200),
	}
	b := map[string]any{
		"layer":      "behavioural",
		"actor_hint": "agent-cardvault-0",
		"source":     "agent-monitor",
		"timestamp":  int64(250),
	}

	if !evalRule(t, rule.CEL, a, b) {
		t.Fatalf("expected vault_privilege_escalation match for (a, b)")
	}
	if !evalRule(t, rule.CEL, b, a) {
		t.Fatalf("expected symmetric vault_privilege_escalation match for (b, a)")
	}
}

func TestRule_VaultSecretExfiltrationSpike_Symmetric(t *testing.T) {
	rules := IdentityAuditRules()
	var rule Rule
	for _, r := range rules {
		if r.Name == "vault_secret_exfiltration_spike" {
			rule = r
			break
		}
	}
	if rule.Name == "" {
		t.Fatalf("vault_secret_exfiltration_spike rule not found")
	}

	a := map[string]any{
		"layer":      "identity_authorization",
		"actor_hint": "agent-cardvault-0",
		"source":     "openbao-audit",
		"timestamp":  int64(1000),
	}
	b := map[string]any{
		"layer":      "application_saas",
		"actor_hint": "agent-cardvault-0",
		"source":     "slack-audit",
		"timestamp":  int64(1200), // 200s diff <= 300s
	}

	if !evalRule(t, rule.CEL, a, b) {
		t.Fatalf("expected match within 300s window")
	}
	if !evalRule(t, rule.CEL, b, a) {
		t.Fatalf("expected symmetric match within 300s window")
	}

	// Beyond 300s window
	bLate := map[string]any{
		"layer":      "application_saas",
		"actor_hint": "agent-cardvault-0",
		"source":     "slack-audit",
		"timestamp":  int64(1400), // 400s diff > 300s
	}
	if evalRule(t, rule.CEL, a, bLate) {
		t.Fatalf("expected no match beyond 300s window")
	}
}

func TestSA_SPIFFE_JoinDiscriminator_Table(t *testing.T) {
	tests := []struct {
		name        string
		saPrincipal string
		spiffeID    string
		wantMatch   bool
		wantNS      string
		wantSA      string
	}{
		{
			name:        "exact match standard cluster.local",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   true,
			wantNS:      "fe-signalloom-agents",
			wantSA:      "agent-cardvault-sa",
		},
		{
			name:        "exact match alternate domain",
			saPrincipal: "system:serviceaccount:prod-infra:vault-agent",
			spiffeID:    "spiffe://controlplane.identity/ns/prod-infra/sa/vault-agent",
			wantMatch:   true,
			wantNS:      "prod-infra",
			wantSA:      "vault-agent",
		},
		{
			name:        "namespace mismatch negative",
			saPrincipal: "system:serviceaccount:default:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "serviceaccount mismatch negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:other-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "malformed spiffe missing sa prefix negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents",
			wantMatch:   false,
		},
		{
			name:        "malformed spiffe missing ns prefix negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "malformed spiffe http scheme negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "http://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "malformed sa principal non-sa prefix negative",
			saPrincipal: "system:user:alice",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "empty principal negative",
			saPrincipal: "",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			match, ns, sa := spirea.MatchSAPrincipalAndSPIFFEID(tt.saPrincipal, tt.spiffeID)
			if match != tt.wantMatch {
				t.Errorf("MatchSAPrincipalAndSPIFFEID(%q, %q) match = %v, want %v", tt.saPrincipal, tt.spiffeID, match, tt.wantMatch)
			}
			if tt.wantMatch {
				if ns != tt.wantNS {
					t.Errorf("namespace = %q, want %q", ns, tt.wantNS)
				}
				if sa != tt.wantSA {
					t.Errorf("serviceAccount = %q, want %q", sa, tt.wantSA)
				}
			}
		})
	}
}

