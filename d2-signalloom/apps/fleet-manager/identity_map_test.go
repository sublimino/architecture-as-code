package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAgentIdentityMap_ReadsIdentityPrefixedFiles(t *testing.T) {
	dir := t.TempDir()
	// Mirrors what a ConfigMap volume mount materialises from base/configmap.yaml:
	// one file per data key, named after the key.
	writeIdentityFile(t, dir, "fleet.yaml", "agents: []\n") // must be ignored
	writeIdentityFile(t, dir, "identity.kusari-agent", "kusari-agent\n")
	writeIdentityFile(t, dir, "identity.cardvault", "agent-cardvault")

	m, err := LoadAgentIdentityMap(dir)
	if err != nil {
		t.Fatalf("LoadAgentIdentityMap: %v", err)
	}
	if m.Len() != 2 {
		t.Fatalf("Len() = %d, want 2 (fleet.yaml must not be read as an identity entry)", m.Len())
	}
	if sa, ok := m.ExpectedServiceAccount("kusari-agent"); !ok || sa != "kusari-agent" {
		t.Fatalf("ExpectedServiceAccount(kusari-agent) = %q, %v", sa, ok)
	}
	if sa, ok := m.ExpectedServiceAccount("cardvault"); !ok || sa != "agent-cardvault" {
		t.Fatalf("ExpectedServiceAccount(cardvault) = %q, %v (trailing whitespace must be trimmed)", sa, ok)
	}
}

func TestLoadAgentIdentityMap_MissingDirIsNotAnError(t *testing.T) {
	m, err := LoadAgentIdentityMap(filepath.Join(t.TempDir(), "does-not-exist"))
	if err != nil {
		t.Fatalf("LoadAgentIdentityMap: %v, want nil (an unmounted map is 'no registered mapping', not an error)", err)
	}
	if m.Len() != 0 {
		t.Fatalf("Len() = %d, want 0", m.Len())
	}
}

func TestLoadAgentIdentityMap_EmptyPathIsNotAnError(t *testing.T) {
	m, err := LoadAgentIdentityMap("")
	if err != nil {
		t.Fatalf("LoadAgentIdentityMap(\"\"): %v", err)
	}
	if m.Len() != 0 {
		t.Fatalf("Len() = %d, want 0", m.Len())
	}
}

func TestAgentIdentityMap_Matches(t *testing.T) {
	m := NewAgentIdentityMap(map[string]string{"kusari-agent": "kusari-agent"})

	if !m.Matches("kusari-agent", "kusari-agent") {
		t.Error("the registered ServiceAccount must match")
	}
	if m.Matches("kusari-agent", "hosted-daytona-coder") {
		t.Error("a pod claiming the kusari-agent identity while running as a different ServiceAccount must not match")
	}
	if !m.Matches("some-unregistered-name", "anything") {
		t.Error("an unregistered agent name must match everything: this guard only narrows a spoof of a KNOWN identity")
	}
}

func TestAgentIdentityMap_NilIsSafeAndPermissive(t *testing.T) {
	var m *AgentIdentityMap
	if !m.Matches("kusari-agent", "anything") {
		t.Error("a nil map (e.g. a server built directly by a test with no mapping wired) must not reject anything")
	}
	if got := m.Len(); got != 0 {
		t.Fatalf("Len() = %d, want 0", got)
	}
	if _, ok := m.ExpectedServiceAccount("kusari-agent"); ok {
		t.Fatal("a nil map must report nothing registered")
	}
}

func writeIdentityFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}
