package policy_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/policy"
)

func TestPolicyCompilation(t *testing.T) {
	manifestPath := filepath.Join("..", "..", "..", "config", "security-invariants.yaml")
	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("failed to read invariants manifest: %v", err)
	}

	manifest, err := policy.Parse(raw)
	if err != nil {
		t.Fatalf("failed to parse manifest: %v", err)
	}

	opts := policy.Options{
		Targets: []policy.Target{policy.TargetVAP, policy.TargetLandlock},
	}

	res, err := policy.Compile(manifest, opts)
	if err != nil {
		t.Fatalf("failed to compile policies: %v", err)
	}

	if len(res.Artifacts) == 0 {
		t.Fatalf("expected generated artifacts, got 0")
	}

	if res.SP4 == nil || !res.SP4.Compliant {
		t.Fatalf("expected Rule SP-4 compliance, got non-compliant")
	}

	if res.Equivalence == nil || !res.Equivalence.Equivalent {
		t.Fatalf("expected cross-tier semantic equivalence, got non-equivalent")
	}

	// Test drift detection
	tmpDir := t.TempDir()
	if err := policy.WriteArtifacts(res, tmpDir, "security-invariants.yaml"); err != nil {
		t.Fatalf("failed to write artifacts: %v", err)
	}

	report, err := policy.CheckDrift(res, tmpDir)
	if err != nil {
		t.Fatalf("failed to check drift: %v", err)
	}
	if !report.InSync {
		t.Fatalf("expected in-sync report, got drift: %+v", report.Findings)
	}
}
