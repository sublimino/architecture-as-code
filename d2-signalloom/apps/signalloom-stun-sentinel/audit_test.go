package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestAuditLoggerEmitsValidJSON(t *testing.T) {
	buf := &bytes.Buffer{}
	logger := &AuditLogger{out: buf}

	event := stunEvent{
		Timestamp:       now(),
		Event:           "stun",
		Pod:             "agent-arthur",
		Namespace:       "fe-signalloom-agents",
		UID:             "uid-12345",
		DryRun:          true,
		Latency:         "1.2",
		CgroupPath:      "/sys/fs/cgroup/kubepods.slice/poduid_12345.slice",
		HostVeth:        "veth-test",
		TCIngressFilter: "pref 49152 ingress handle 1 matchall action drop",
		TCEgressFilter:  "pref 49153 egress handle 2 matchall action drop",
		Decision:        "containment_planned_dry_run",
		ProbesCount:     2,
		ReconcileCount:  5,
	}

	logger.Log(event)

	line := strings.TrimSpace(buf.String())
	if line == "" {
		t.Fatal("expected audit log output, got empty")
	}

	parsed, err := ValidateAuditEvent([]byte(line))
	if err != nil {
		t.Fatalf("ValidateAuditEvent failed: %v", err)
	}

	if parsed.Event != "stun" {
		t.Errorf("Event = %q, want stun", parsed.Event)
	}
	if parsed.Pod != "agent-arthur" {
		t.Errorf("Pod = %q, want agent-arthur", parsed.Pod)
	}
	if !parsed.DryRun {
		t.Errorf("DryRun = false, want true")
	}
	if parsed.Decision != "containment_planned_dry_run" {
		t.Errorf("Decision = %q, want containment_planned_dry_run", parsed.Decision)
	}
	if parsed.ReconcileCount != 5 {
		t.Errorf("ReconcileCount = %d, want 5", parsed.ReconcileCount)
	}
}

func TestValidateAuditEventRejectsInvalidJSON(t *testing.T) {
	_, err := ValidateAuditEvent([]byte("not valid json"))
	if err == nil {
		t.Error("expected error for invalid JSON")
	}

	// Missing timestamp
	noTimestamp := `{"event":"stun","pod":"agent-1"}`
	_, err = ValidateAuditEvent([]byte(noTimestamp))
	if err == nil || !strings.Contains(err.Error(), "timestamp") {
		t.Errorf("expected timestamp error, got %v", err)
	}

	// Missing event
	noEvent := `{"timestamp":"2026-09-02T00:00:00Z","pod":"agent-1"}`
	_, err = ValidateAuditEvent([]byte(noEvent))
	if err == nil || !strings.Contains(err.Error(), "event") {
		t.Errorf("expected event error, got %v", err)
	}
}

func TestGlobalAuditOutputCapture(t *testing.T) {
	buf := &bytes.Buffer{}
	SetAuditOutput(buf)
	defer SetAuditOutput(nil)

	logEvent(stunEvent{
		Timestamp: now(),
		Event:     "started",
		Namespace: "test-ns",
		DryRun:    true,
	})

	var ev map[string]interface{}
	if err := json.Unmarshal(buf.Bytes(), &ev); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if ev["event"] != "started" || ev["namespace"] != "test-ns" || ev["dry_run"] != true {
		t.Errorf("unexpected event payload: %+v", ev)
	}
}
