package frameworks

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/cel-go/cel"
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

func newTestCELEnv(t *testing.T) *cel.Env {
	t.Helper()
	env, err := cel.NewEnv(
		cel.Variable("agent", cel.DynType),
		cel.Variable("request", cel.DynType),
		cel.Variable("object", cel.DynType),
		cel.Variable("manifest", cel.DynType),
	)
	if err != nil {
		t.Fatalf("failed to create CEL env: %v", err)
	}
	return env
}

func evalCEL(t *testing.T, env *cel.Env, expr string, input map[string]any) bool {
	t.Helper()
	ast, issues := env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		t.Fatalf("CEL compile error for %q: %v", expr, issues.Err())
	}
	prg, err := env.Program(ast)
	if err != nil {
		t.Fatalf("CEL program creation error for %q: %v", expr, err)
	}
	out, _, err := prg.ContextEval(context.Background(), input)
	if err != nil {
		t.Fatalf("CEL eval error for %q with input %v: %v", expr, input, err)
	}
	b, ok := out.Value().(bool)
	if !ok {
		t.Fatalf("CEL expr %q did not return bool, got %T (%v)", expr, out.Value(), out.Value())
	}
	return b
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

func TestLoad_CRA(t *testing.T) {
	root := testPolicyRoot(t)
	fw, err := Load(root, "cra", "v1.0")
	if err != nil {
		t.Fatal(err)
	}

	if fw.ID != "cra" {
		t.Fatalf("expected id cra, got %q", fw.ID)
	}
	if len(fw.ControlSets) == 0 {
		t.Fatal("expected at least 1 control set in CRA")
	}
}

func TestLoad_FINOSAIGF(t *testing.T) {
	root := testPolicyRoot(t)
	fw, err := Load(root, "finos-aigf", "v1.0")
	if err != nil {
		t.Fatal(err)
	}

	if fw.ID != "finos-aigf" {
		t.Fatalf("expected id finos-aigf, got %q", fw.ID)
	}
	if len(fw.ControlSets) == 0 {
		t.Fatal("expected at least 1 control set in FINOS AIGF")
	}
}

func TestLoad_PlaceholderFrameworks(t *testing.T) {
	root := testPolicyRoot(t)

	// DORA placeholder
	doraFw, err := Load(root, "dora", "v1.0")
	if err != nil {
		t.Fatalf("failed loading DORA framework: %v", err)
	}
	if doraFw.Status != "placeholder" {
		t.Fatalf("expected DORA status to be placeholder, got %q", doraFw.Status)
	}

	// NIS2 placeholder
	nis2Fw, err := Load(root, "nis2", "v1.0")
	if err != nil {
		t.Fatalf("failed loading NIS2 framework: %v", err)
	}
	if nis2Fw.Status != "placeholder" {
		t.Fatalf("expected NIS2 status to be placeholder, got %q", nis2Fw.Status)
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

	expectedFrameworks := []string{"nist-800-53", "eu-ai-act", "cra", "finos-aigf", "dora", "nis2"}
	for _, ef := range expectedFrameworks {
		if versions, ok := fws[ef]; !ok || len(versions) == 0 {
			t.Fatalf("framework %q should be listed with at least one version", ef)
		}
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

// Table-driven test verifying allow and deny fixtures for every single regulatory rule across all frameworks.
func TestAllRegulatoryRules_TableDrivenAllowDeny(t *testing.T) {
	root := testPolicyRoot(t)
	env := newTestCELEnv(t)

	type RuleFixtureTest struct {
		FrameworkID  string
		Version      string
		CheckID      string
		AllowFixture map[string]any
		DenyFixture  map[string]any
	}

	tests := []RuleFixtureTest{
		// EU AI Act Rules
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "container-run-as-non-root",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"runAsNonRoot": true}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"runAsNonRoot": false}}}}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "no-privilege-escalation",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"allowPrivilegeEscalation": false}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"allowPrivilegeEscalation": true}}}}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "training-data-provenance",
			AllowFixture: map[string]any{"agent": map[string]any{"training_data_provenance": map[string]any{"validated": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"training_data_provenance": map[string]any{"validated": false}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "annex-iv-technical-documentation",
			AllowFixture: map[string]any{"agent": map[string]any{"technical_documentation": map[string]any{"annex_iv_compliant": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"technical_documentation": map[string]any{"annex_iv_compliant": false}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "automatic-record-keeping",
			AllowFixture: map[string]any{"agent": map[string]any{"logging_config": map[string]any{"automatic_record_keeping": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"logging_config": map[string]any{"automatic_record_keeping": false}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "user-instructions-transparency",
			AllowFixture: map[string]any{"agent": map[string]any{"transparency": map[string]any{"user_instructions_available": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"transparency": map[string]any{"user_instructions_available": false}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "block-unauthorized-host-exec",
			AllowFixture: map[string]any{"request": map[string]any{"tool_call": map[string]any{"action": "exec"}, "context": map[string]any{"claims": []any{map[string]any{"type": "human_approval_svid", "valid": true}}}}},
			DenyFixture:  map[string]any{"request": map[string]any{"tool_call": map[string]any{"action": "exec"}, "context": map[string]any{"claims": []any{map[string]any{"type": "unrelated", "valid": true}}}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "drop-all-capabilities",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"capabilities": map[string]any{"drop": []any{"ALL"}}}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"capabilities": map[string]any{"drop": []any{"NET_ADMIN"}}}}}}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "resource-limits-set",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"resources": map[string]any{"limits": map[string]any{"cpu": "500m"}}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"resources": map[string]any{}}}}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "deployer-monitoring-active",
			AllowFixture: map[string]any{"agent": map[string]any{"deployer_oversight": map[string]any{"continuous_monitoring": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"deployer_oversight": map[string]any{"continuous_monitoring": false}}},
		},
		{
			FrameworkID: "eu-ai-act", Version: "v2.1", CheckID: "synthetic-content-marking",
			AllowFixture: map[string]any{"agent": map[string]any{"model_type": "generative", "transparency": map[string]any{"synthetic_content_watermarking": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"model_type": "generative", "transparency": map[string]any{"synthetic_content_watermarking": false}}},
		},

		// NIST SP 800-53 Rules
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "no-automount-sa-token",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"automountServiceAccountToken": false}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"automountServiceAccountToken": true}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "spiffe-peer-authorization",
			AllowFixture: map[string]any{"request": map[string]any{"peer": map[string]any{"spiffe_id": "spiffe://signalloom.demo/ns/default/sa/agent-alpha"}}},
			DenyFixture:  map[string]any{"request": map[string]any{"peer": map[string]any{"spiffe_id": "spiffe://external.domain/ns/default/sa/unknown"}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "cross-namespace-egress-authorization",
			AllowFixture: map[string]any{"request": map[string]any{"source": map[string]any{"namespace": "agents"}, "destination": map[string]any{"namespace": "agents"}}},
			DenyFixture:  map[string]any{"request": map[string]any{"source": map[string]any{"namespace": "agents"}, "destination": map[string]any{"namespace": "isolated-db"}, "context": map[string]any{"egress_authorized": false}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "container-run-as-non-root",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"runAsNonRoot": true}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"runAsNonRoot": false}}}}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "no-privilege-escalation",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"allowPrivilegeEscalation": false}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"allowPrivilegeEscalation": true}}}}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "no-privileged-mode",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"privileged": false}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"privileged": true}}}}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "immutable-audit-sink",
			AllowFixture: map[string]any{"agent": map[string]any{"audit_config": map[string]any{"event_logging_enabled": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"audit_config": map[string]any{"event_logging_enabled": false}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "read-only-rootfs",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"readOnlyRootFilesystem": true}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"readOnlyRootFilesystem": false}}}}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "mfa-spiffe-svid-required",
			AllowFixture: map[string]any{"request": map[string]any{"auth": map[string]any{"svid_presented": true}}},
			DenyFixture:  map[string]any{"request": map[string]any{"auth": map[string]any{"svid_presented": false}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "drop-all-capabilities",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"capabilities": map[string]any{"drop": []any{"ALL"}}}}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"securityContext": map[string]any{"capabilities": map[string]any{"drop": []any{}}}}}}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "network-boundary-enforcement",
			AllowFixture: map[string]any{"request": map[string]any{"network_policy": map[string]any{"ingress_isolated": true}}},
			DenyFixture:  map[string]any{"request": map[string]any{"network_policy": map[string]any{"ingress_isolated": false}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "anomaly-detection-telemetry",
			AllowFixture: map[string]any{"agent": map[string]any{"telemetry": map[string]any{"monitoring_active": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"telemetry": map[string]any{"monitoring_active": false}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "image-digest",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"image": "zot.local/agent:v1.0@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"image": "zot.local/agent:latest"}}}}},
		},
		{
			FrameworkID: "nist-800-53", Version: "v2.1", CheckID: "trusted-registry",
			AllowFixture: map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"image": "zot.local/agent:v1.0"}}}}},
			DenyFixture:  map[string]any{"object": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"image": "docker.io/untrusted/agent:latest"}}}}},
		},

		// Cyber Resilience Act (CRA) Rules
		{
			FrameworkID: "cra", Version: "v1.0", CheckID: "default-secure-configuration",
			AllowFixture: map[string]any{"agent": map[string]any{"security_profile": map[string]any{"secure_by_default": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"security_profile": map[string]any{"secure_by_default": false}}},
		},
		{
			FrameworkID: "cra", Version: "v1.0", CheckID: "sbom-verified-provenance",
			AllowFixture: map[string]any{"agent": map[string]any{"sbom": map[string]any{"format": "CycloneDX", "verified": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"sbom": map[string]any{"format": "Custom", "verified": false}}},
		},
		{
			FrameworkID: "cra", Version: "v1.0", CheckID: "signed-cryptographic-updates",
			AllowFixture: map[string]any{"agent": map[string]any{"provenance": map[string]any{"slsa_level": "SLSA_LEVEL_3"}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"provenance": map[string]any{"slsa_level": "SLSA_LEVEL_1"}}},
		},

		// FINOS AIGF Rules
		{
			FrameworkID: "finos-aigf", Version: "v1.0", CheckID: "registered-model-registry-entry",
			AllowFixture: map[string]any{"agent": map[string]any{"registry": map[string]any{"model_registered": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"registry": map[string]any{"model_registered": false}}},
		},
		{
			FrameworkID: "finos-aigf", Version: "v1.0", CheckID: "prompt-injection-guardrail-active",
			AllowFixture: map[string]any{"agent": map[string]any{"guardrails": map[string]any{"prompt_injection_filter": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"guardrails": map[string]any{"prompt_injection_filter": false}}},
		},
		{
			FrameworkID: "finos-aigf", Version: "v1.0", CheckID: "decision-explainability-metadata",
			AllowFixture: map[string]any{"agent": map[string]any{"governance": map[string]any{"decision_explainability": true}}},
			DenyFixture:  map[string]any{"agent": map[string]any{"governance": map[string]any{"decision_explainability": false}}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.FrameworkID+"/"+tt.CheckID, func(t *testing.T) {
			fw, err := Load(root, tt.FrameworkID, tt.Version)
			if err != nil {
				t.Fatalf("failed loading framework %s/%s: %v", tt.FrameworkID, tt.Version, err)
			}

			var targetCheck *Check
			for _, cs := range fw.ControlSets {
				for _, ctrl := range cs.Controls {
					for _, chk := range ctrl.Checks {
						if chk.ID == tt.CheckID {
							targetCheck = &chk
							break
						}
					}
				}
			}

			if targetCheck == nil {
				t.Fatalf("check %s not found in framework %s", tt.CheckID, tt.FrameworkID)
			}

			if targetCheck.CELExpression == "" {
				t.Fatalf("check %s has empty CEL expression", tt.CheckID)
			}

			// Evaluate Allow Fixture
			allowVerdict := evalCEL(t, env, targetCheck.CELExpression, tt.AllowFixture)
			if !allowVerdict {
				t.Errorf("expected ALLOW fixture to evaluate to true for rule %s, got false", tt.CheckID)
			}

			// Evaluate Deny Fixture
			denyVerdict := evalCEL(t, env, targetCheck.CELExpression, tt.DenyFixture)
			if denyVerdict {
				t.Errorf("expected DENY fixture to evaluate to false for rule %s, got true", tt.CheckID)
			}
		})
	}
}
