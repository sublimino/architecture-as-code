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
	writeIdentityFile(t, dir, "identity-ns.kusari-agent", "fe-signalloom-agents\n")
	writeIdentityFile(t, dir, "identity.cardvault", "agent-cardvault")
	writeIdentityFile(t, dir, "identity-ns.cardvault", "fe-signalloom-agents")

	m, err := LoadAgentIdentityMap(dir)
	if err != nil {
		t.Fatalf("LoadAgentIdentityMap: %v", err)
	}
	if m.Len() != 2 {
		t.Fatalf("Len() = %d, want 2 (fleet.yaml must not be read as an identity entry)", m.Len())
	}
	if id, ok := m.Expected("kusari-agent"); !ok || id != (AgentIdentity{Namespace: "fe-signalloom-agents", ServiceAccount: "kusari-agent"}) {
		t.Fatalf("Expected(kusari-agent) = %+v, %v", id, ok)
	}
	if id, ok := m.Expected("cardvault"); !ok || id != (AgentIdentity{Namespace: "fe-signalloom-agents", ServiceAccount: "agent-cardvault"}) {
		t.Fatalf("Expected(cardvault) = %+v, %v (trailing whitespace must be trimmed)", id, ok)
	}
}

func TestLoadAgentIdentityMap_AgentWithOnlyOneHalfOfTheKeyPairIsDropped(t *testing.T) {
	dir := t.TempDir()
	writeIdentityFile(t, dir, "identity.sa-only", "some-sa")
	// no identity-ns.sa-only
	writeIdentityFile(t, dir, "identity-ns.ns-only", "some-ns")
	// no identity.ns-only

	m, err := LoadAgentIdentityMap(dir)
	if err != nil {
		t.Fatalf("LoadAgentIdentityMap: %v", err)
	}
	if m.Len() != 0 {
		t.Fatalf("Len() = %d, want 0: a half-authored entry must be dropped, never guessed at", m.Len())
	}
	if _, ok := m.Expected("sa-only"); ok {
		t.Fatal("sa-only must not be registered with no namespace half")
	}
	if _, ok := m.Expected("ns-only"); ok {
		t.Fatal("ns-only must not be registered with no ServiceAccount half")
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
	m := NewAgentIdentityMap(map[string]AgentIdentity{
		"kusari-agent": {Namespace: "fe-signalloom-agents", ServiceAccount: "kusari-agent"},
	})

	if !m.Matches("kusari-agent", "fe-signalloom-agents", "kusari-agent") {
		t.Error("the registered namespace and ServiceAccount must match")
	}
	if m.Matches("kusari-agent", "fe-signalloom-agents", "hosted-daytona-coder") {
		t.Error("a pod claiming the kusari-agent identity while running as a different ServiceAccount must not match")
	}
	if !m.Matches("some-unregistered-name", "anywhere", "anything") {
		t.Error("an unregistered agent name must match everything: this guard only narrows a spoof of a KNOWN identity")
	}
}

func TestAgentIdentityMap_MatchesRejectsTheRightServiceAccountNameInTheWrongNamespace(t *testing.T) {
	// A ServiceAccount name is only unique within its namespace. A decoy in
	// hosted-daytona-coder's own namespace naming its ServiceAccount
	// "kusari-agent" must not pass a check that compares the SA name alone.
	m := NewAgentIdentityMap(map[string]AgentIdentity{
		"kusari-agent": {Namespace: "fe-signalloom-agents", ServiceAccount: "kusari-agent"},
	})

	if m.Matches("kusari-agent", "hosted-daytona-coder-workspace", "kusari-agent") {
		t.Error("the right ServiceAccount name in the wrong namespace must not match")
	}
}

func TestAgentIdentityMap_NilIsSafeAndPermissive(t *testing.T) {
	var m *AgentIdentityMap
	if !m.Matches("kusari-agent", "anywhere", "anything") {
		t.Error("a nil map (e.g. a server built directly by a test with no mapping wired) must not reject anything")
	}
	if got := m.Len(); got != 0 {
		t.Fatalf("Len() = %d, want 0", got)
	}
	if _, ok := m.Expected("kusari-agent"); ok {
		t.Fatal("a nil map must report nothing registered")
	}
}

func writeIdentityFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}
