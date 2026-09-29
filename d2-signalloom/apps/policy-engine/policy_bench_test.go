package main

import (
	"context"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
)

func BenchmarkCELEvaluation(b *testing.B) {
	engine, err := NewCELEngine()
	if err != nil {
		b.Fatalf("failed creating CEL engine: %v", err)
	}
	store := NewPolicyStore(engine)

	bundle := &PolicyBundle{
		FrameworkID: "benchmark-framework",
		Version:     "v1.0.0",
		Author:      "benchmarker",
		Rules: []PolicyRule{
			{
				ID:            "R1",
				Name:          "Model Check",
				CELExpression: `agent.model in ["gpt-4o", "claude-3-5-sonnet", "gemini-1.5-pro"]`,
				RiskTriple:    fair.RiskTriple{Min: 100, Mode: 500, Max: 2000},
				FreqTriple:    fair.RiskTriple{Min: 1, Mode: 2, Max: 5},
			},
			{
				ID:            "R2",
				Name:          "Tool Permission Check",
				CELExpression: `agent.tool_permissions.all(p, !p.startsWith("admin:"))`,
				RiskTriple:    fair.RiskTriple{Min: 500, Mode: 2000, Max: 10000},
				FreqTriple:    fair.RiskTriple{Min: 0.5, Mode: 1, Max: 3},
			},
			{
				ID:            "R3",
				Name:          "Trust Domain Check",
				CELExpression: `request.spiffe_id.startsWith("spiffe://controlplane.io/ns/" + agent.trust_domain)`,
				RiskTriple:    fair.RiskTriple{Min: 200, Mode: 1000, Max: 5000},
				FreqTriple:    fair.RiskTriple{Min: 1, Mode: 2, Max: 4},
			},
			{
				ID:            "R4",
				Name:          "Egress Check",
				CELExpression: `agent.egress_allowlist.exists(e, e == request.target_service)`,
				RiskTriple:    fair.RiskTriple{Min: 1000, Mode: 5000, Max: 20000},
				FreqTriple:    fair.RiskTriple{Min: 0.1, Mode: 0.5, Max: 1},
			},
		},
	}
	if err := store.RegisterBundle("tenant-bench", bundle); err != nil {
		b.Fatalf("failed registering bundle: %v", err)
	}

	req := &EvaluatePoliciesRequest{
		TenantID:    "tenant-bench",
		FrameworkID: "benchmark-framework",
		Agent: map[string]any{
			"id":               "agent-bench-1",
			"model":            "claude-3-5-sonnet",
			"trust_domain":     "production",
			"tool_permissions": []any{"read:files", "search:web", "invoke:subagent"},
			"egress_allowlist": []any{"api.openai.com", "anthropic.com", "vault.internal"},
		},
		Request: map[string]any{
			"spiffe_id":      "spiffe://controlplane.io/ns/production/sa/agent-bench-1",
			"target_service": "vault.internal",
			"action":         "read_secret",
		},
	}

	ctx := context.Background()
	b.ResetTimer()
	b.ReportAllocs()

	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			resp, err := store.EvaluateBundle(ctx, bundle, req)
			if err != nil || !resp.Compliant {
				b.Fatalf("evaluation failed: err=%v resp=%v", err, resp)
			}
		}
	})
}
