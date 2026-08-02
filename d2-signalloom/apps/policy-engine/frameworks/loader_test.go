package frameworks

import (
	"os"
	"path/filepath"
	"testing"
)

func testPolicyRoot(t *testing.T) string {
	t.Helper()
	// Walk up from the test binary to find the policy/ directory.
	// The test runs from d2-signalloom/apps/policy-engine/frameworks/
	// and policy/ is at the repo root.
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, "policy")
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not find policy/ directory")
		}
		dir = parent
	}
}

func TestLoad_NIST(t *testing.T) {
	root := testPolicyRoot(t)
	fw, err := Load(root, "nist-800-53", "v2.1")
	if err != nil {
		t.Fatal(err)
	}

	if fw.ID != "nist-800-53" {
		t.Fatalf("expected id nist-800-53, got %q", fw.ID)
	}
	if fw.Version != "v2.1.0" && fw.Version != "v2.1" {
		t.Fatalf("expected version v2.1.0 or v2.1, got %q", fw.Version)
	}
	if len(fw.ControlSets) == 0 {
		t.Fatal("expected at least one control set")
	}

	// Verify we can find the no-privilege-escalation check.
	found := false
	for _, cs := range fw.ControlSets {
		for _, ctrl := range cs.Controls {
			for _, chk := range ctrl.Checks {
				if chk.ID == "no-privilege-escalation" {
					found = true
					if chk.CELExpression == "" {
						t.Fatal("CEL expression should not be empty")
					}
					if chk.RiskTriple.Min == 0 && chk.RiskTriple.Max == 0 {
						t.Fatal("risk triple should be populated")
					}
				}
			}
		}
	}
	if !found {
		t.Fatal("no-privilege-escalation check not found in NIST framework")
	}
}

func TestLoad_EUAIAct(t *testing.T) {
	root := testPolicyRoot(t)
	fw, err := Load(root, "eu-ai-act", "v2.1")
	if err != nil {
		t.Fatal(err)
	}

	if fw.ID != "eu-ai-act" {
		t.Fatalf("expected id eu-ai-act, got %q", fw.ID)
	}
	if len(fw.ControlSets) == 0 {
		t.Fatal("expected at least 1 control set in EU AI Act")
	}
}

func TestLoad_NotFound(t *testing.T) {
	root := testPolicyRoot(t)
	_, err := Load(root, "nonexistent", "v1.0.0")
	if err == nil {
		t.Fatal("expected error for nonexistent framework")
	}
}

func TestListFrameworks(t *testing.T) {
	root := testPolicyRoot(t)
	fws, err := ListFrameworks(root)
	if err != nil {
		t.Fatal(err)
	}

	if len(fws) < 2 {
		t.Fatalf("expected at least 2 frameworks, got %d", len(fws))
	}
	if versions, ok := fws["nist-800-53"]; !ok || len(versions) == 0 {
		t.Fatal("nist-800-53 should be listed with at least one version")
	}
	if versions, ok := fws["eu-ai-act"]; !ok || len(versions) == 0 {
		t.Fatal("eu-ai-act should be listed with at least one version")
	}
}

func TestChecksForVersion(t *testing.T) {
	root := testPolicyRoot(t)
	fw, err := Load(root, "nist-800-53", "v2.1")
	if err != nil {
		t.Fatal(err)
	}

	// All checks in the JSON file are tagged v2.1.0.
	checks := ChecksForVersion(fw, "v2.1.0")
	if len(checks) == 0 {
		t.Fatal("expected checks for v2.1.0")
	}

	// v2.0.0 should exclude the v2.1.0-only checks (read-only-rootfs, image-digest, trusted-registry).
	v2Checks := ChecksForVersion(fw, "v2.0.0")
	if len(v2Checks) >= len(checks) {
		t.Fatalf("v2.0.0 should have fewer checks than v2.1.0: got %d vs %d", len(v2Checks), len(checks))
	}

	// Empty version returns all checks.
	allChecks := ChecksForVersion(fw, "")
	if len(allChecks) == 0 {
		t.Fatal("expected checks with empty version filter")
	}
}

func TestChecksForVersion_Context(t *testing.T) {
	root := testPolicyRoot(t)
	fw, err := Load(root, "nist-800-53", "v2.1")
	if err != nil {
		t.Fatal(err)
	}

	checks := ChecksForVersion(fw, "v2.1.0")
	for _, cwc := range checks {
		if cwc.Framework != "nist-800-53" {
			t.Fatalf("expected framework nist-800-53, got %q", cwc.Framework)
		}
		if cwc.ControlSet == "" {
			t.Fatal("control set name should not be empty")
		}
		if cwc.Control == "" {
			t.Fatal("control name should not be empty")
		}
	}
}
