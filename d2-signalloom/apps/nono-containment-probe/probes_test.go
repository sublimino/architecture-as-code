package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────
// Probe result structure tests.
// ─────────────────────────────────────────────────────────────────────────────

func TestProbeResultJSON(t *testing.T) {
	r := ProbeResult{
		Probe:           "test_probe",
		Action:          "read /etc/test",
		Result:          "blocked",
		Errno:           "EACCES",
		LandlockEnforced: true,
	}
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded ProbeResult
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.Probe != "test_probe" {
		t.Errorf("probe: got %q, want %q", decoded.Probe, "test_probe")
	}
	if decoded.LandlockEnforced != true {
		t.Error("landlock_enforced should be true")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Workspace probe tests (these use real temp dirs).
// ─────────────────────────────────────────────────────────────────────────────

func TestProbeWorkspaceRead(t *testing.T) {
	dir := t.TempDir()
	testFile := filepath.Join(dir, "test.txt")
	if err := os.WriteFile(testFile, []byte("test content"), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}

	r := probeWorkspaceRead(testFile)
	if r.Result != "allowed" {
		t.Errorf("result: got %q, want %q", r.Result, "allowed")
	}
	if r.LandlockEnforced != false {
		t.Error("landlock_enforced should be false for allowed operations")
	}
}

func TestProbeWorkspaceReadMissing(t *testing.T) {
	r := probeWorkspaceRead("/nonexistent/file.txt")
	if r.Result != "blocked" {
		t.Errorf("result: got %q, want %q", r.Result, "blocked")
	}
}

func TestProbeWorkspaceWrite(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "probe-result.txt")

	r := probeWorkspaceWrite(target)
	if r.Result != "allowed" {
		t.Errorf("result: got %q, want %q", r.Result, "allowed")
	}

	// Verify the file was actually written.
	data, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read written file: %v", err)
	}
	if len(data) == 0 {
		t.Error("written file should not be empty")
	}
}

func TestProbeWorkspaceWriteReadOnly(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0555); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	defer os.Chmod(dir, 0755) // cleanup

	target := filepath.Join(dir, "probe-result.txt")
	r := probeWorkspaceWrite(target)
	if r.Result != "blocked" {
		t.Errorf("result: got %q, want %q", r.Result, "blocked")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Forbidden-path probe tests (read shadow, write outside).
// ─────────────────────────────────────────────────────────────────────────────

func TestProbeReadShadowStructure(t *testing.T) {
	// On a developer machine /etc/shadow may or may not be readable,
	// but the probe should always return a valid structure.
	r := probeReadShadow()
	if r.Probe != "read_shadow" {
		t.Errorf("probe: got %q, want %q", r.Probe, "read_shadow")
	}
	if r.Action != "read /etc/shadow" {
		t.Errorf("action: got %q, want %q", r.Action, "read /etc/shadow")
	}
	// Result is environment-dependent -- just verify it's one of the valid values.
	if r.Result != "blocked" && r.Result != "allowed" {
		t.Errorf("result: got %q, want blocked or allowed", r.Result)
	}
}

func TestProbeWriteOutsideStructure(t *testing.T) {
	r := probeWriteOutside()
	if r.Probe != "write_outside" {
		t.Errorf("probe: got %q, want %q", r.Probe, "write_outside")
	}
	if r.Action != "write /usr/local/evil" {
		t.Errorf("action: got %q, want %q", r.Action, "write /usr/local/evil")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Network probe test.
// ─────────────────────────────────────────────────────────────────────────────

func TestProbeMetadataExfilStructure(t *testing.T) {
	r := probeMetadataExfil()
	if r.Probe != "metadata_exfil" {
		t.Errorf("probe: got %q, want %q", r.Probe, "metadata_exfil")
	}
	if r.Action != "GET http://169.254.169.254/latest/meta-data/" {
		t.Errorf("action: got %q", r.Action)
	}
	// On any normal machine, 169.254.169.254 should be unreachable.
	if r.Result != "blocked" {
		t.Logf("metadata probe returned %q -- expected blocked on non-cloud machines", r.Result)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// RunAllProbes integration test.
// ─────────────────────────────────────────────────────────────────────────────

func TestRunAllProbesReturnsExpectedCount(t *testing.T) {
	dir := t.TempDir()
	readFile := filepath.Join(dir, "test.txt")
	os.WriteFile(readFile, []byte("hello"), 0644)
	writeTarget := filepath.Join(dir, "probe-result.txt")

	results := runAllProbes(readFile, writeTarget)
	if len(results) != 5 {
		t.Fatalf("expected 5 probes, got %d", len(results))
	}

	// Verify probe names are all distinct.
	seen := make(map[string]bool)
	for _, r := range results {
		if seen[r.Probe] {
			t.Errorf("duplicate probe name: %q", r.Probe)
		}
		seen[r.Probe] = true
	}
}
