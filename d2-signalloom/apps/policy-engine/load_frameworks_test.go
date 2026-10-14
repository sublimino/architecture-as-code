package main

import (
	"path/filepath"
	"testing"
)

func TestLoadFrameworksReal(t *testing.T) {
	store, _ := setupTestStore(t)
	policyRoot, err := filepath.Abs("../../../policy")
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	err = store.LoadFrameworks(policyRoot)
	if err != nil {
		t.Fatalf("LoadFrameworks failed: %v", err)
	}
	policies := store.ListPolicies("")
	t.Logf("Loaded %d policy summaries", len(policies))
	for _, p := range policies {
		t.Logf("Policy: %s, active: %s, latest: %s, rules: %d", p.FrameworkID, p.ActiveVersion, p.LatestVersion, len(p.ActiveBundle.Rules))
	}
}

func TestLoadBuiltinFrameworks(t *testing.T) {
	store, _ := setupTestStore(t)
	err := store.LoadBuiltinFrameworks()
	if err != nil {
		t.Fatalf("LoadBuiltinFrameworks failed: %v", err)
	}
	policies := store.ListPolicies("")
	if len(policies) < 7 {
		t.Fatalf("expected at least 7 policies, got %d", len(policies))
	}
	// Verify eu-ai-act bundle is present and active
	bundle, err := store.GetActiveBundle("", "eu-ai-act", "")
	if err != nil {
		t.Fatalf("failed to get active bundle for eu-ai-act: %v", err)
	}
	if len(bundle.Rules) == 0 {
		t.Fatalf("expected rules in eu-ai-act bundle, got 0")
	}

	// Verify k8s-cis-benchmark and cis-kubernetes aliases
	cis1, err := store.GetActiveBundle("", "k8s-cis-benchmark", "")
	if err != nil {
		t.Fatalf("failed to get active bundle for k8s-cis-benchmark: %v", err)
	}
	cis2, err := store.GetActiveBundle("", "cis-kubernetes", "")
	if err != nil {
		t.Fatalf("failed to get active bundle for cis-kubernetes: %v", err)
	}
	if len(cis1.Rules) != len(cis2.Rules) {
		t.Fatalf("rule count mismatch: k8s-cis-benchmark=%d, cis-kubernetes=%d", len(cis1.Rules), len(cis2.Rules))
	}
}

