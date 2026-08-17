package main

import (
	"os"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// TestDeploymentManifest_ValidYAML verifies the deployment manifest is valid
// YAML and contains the volume mount, env vars, and probe references that
// the cluster needs.
func TestDeploymentManifest_ValidYAML(t *testing.T) {
	data, err := os.ReadFile("base/deployment.yaml")
	if err != nil {
		t.Fatalf("read deployment.yaml: %v", err)
	}

	var doc map[string]any
	if err := yaml.Unmarshal(data, &doc); err != nil {
		t.Fatalf("invalid YAML: %v", err)
	}

	raw := string(data)

	// Volume mount for signal store.
	if !strings.Contains(raw, "signal-store") {
		t.Error("missing volume name 'signal-store'")
	}
	if !strings.Contains(raw, "/data/signals") {
		t.Error("missing mount path '/data/signals'")
	}
	if !strings.Contains(raw, "emptyDir") {
		t.Error("missing emptyDir volume definition")
	}

	// Env vars.
	if !strings.Contains(raw, "SIGNAL_STORE_DIR") {
		t.Error("missing SIGNAL_STORE_DIR env var")
	}
	if !strings.Contains(raw, "DATABASE_URL") {
		t.Error("missing DATABASE_URL env var")
	}

	// Probes reference the health endpoints.
	if !strings.Contains(raw, "/healthz") {
		t.Error("missing /healthz probe path")
	}
	if !strings.Contains(raw, "/readyz") {
		t.Error("missing /readyz probe path")
	}
}
