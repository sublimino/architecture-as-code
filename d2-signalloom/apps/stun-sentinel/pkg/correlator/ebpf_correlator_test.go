// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// TestLookupPodByPID verifies that reading /proc/<pid>/cgroup correctly correlates
// both systemd slice and cgroupfs paths to active Kubernetes pod identities.
func TestLookupPodByPID(t *testing.T) {
	tempProcDir := t.TempDir()

	informer := NewMockSharedIndexInformer()
	mgr := NewSentinelProbeManager(informer, "http://localhost:8082", nil, WithProcRoot(tempProcDir))

	podUID := "771fb437-10ec-47dc-89a0-538e1fc16d3f"
	testPod := CreateTestPod("tenant-kusari", "agent-builder-1", podUID, "agent-builder-1", "kusari")
	informer.InjectPod(testPod)

	// Case 1: systemd slice syntax (Kind / standard containerd on Linux systemd)
	pidSystemd := uint32(1001)
	pidSystemdDir := filepath.Join(tempProcDir, fmt.Sprintf("%d", pidSystemd))
	if err := os.MkdirAll(pidSystemdDir, 0755); err != nil {
		t.Fatalf("failed to create mock proc dir: %v", err)
	}
	cgroupSystemdContent := "0::/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod771fb437_10ec_47dc_89a0_538e1fc16d3f.slice/cri-containerd-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.scope\n"
	if err := os.WriteFile(filepath.Join(pidSystemdDir, "cgroup"), []byte(cgroupSystemdContent), 0644); err != nil {
		t.Fatalf("failed to write mock cgroup file: %v", err)
	}

	foundPod := mgr.lookupPodByPID(pidSystemd)
	if foundPod == nil {
		t.Fatalf("lookupPodByPID(%d) returned nil, expected pod %s", pidSystemd, testPod.Name)
	}
	if string(foundPod.UID) != podUID {
		t.Errorf("lookupPodByPID returned pod UID %s, expected %s", foundPod.UID, podUID)
	}

	// Case 2: cgroupfs syntax (traditional cgroupfs driver)
	pidCgroupfs := uint32(1002)
	pidCgroupfsDir := filepath.Join(tempProcDir, fmt.Sprintf("%d", pidCgroupfs))
	if err := os.MkdirAll(pidCgroupfsDir, 0755); err != nil {
		t.Fatalf("failed to create mock proc dir: %v", err)
	}
	cgroupfsContent := "0::/kubepods/burstable/pod771fb437-10ec-47dc-89a0-538e1fc16d3f/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"
	if err := os.WriteFile(filepath.Join(pidCgroupfsDir, "cgroup"), []byte(cgroupfsContent), 0644); err != nil {
		t.Fatalf("failed to write mock cgroup file: %v", err)
	}

	foundCgroupfsPod := mgr.lookupPodByPID(pidCgroupfs)
	if foundCgroupfsPod == nil {
		t.Fatalf("lookupPodByPID(%d) returned nil for cgroupfs layout", pidCgroupfs)
	}
	if string(foundCgroupfsPod.UID) != podUID {
		t.Errorf("lookupPodByPID returned pod UID %s, expected %s", foundCgroupfsPod.UID, podUID)
	}

	// Case 3: Non-existent PID
	if pod := mgr.lookupPodByPID(99999); pod != nil {
		t.Errorf("lookupPodByPID(99999) expected nil, got %v", pod)
	}
}

// TestNormalizeTelemetryObservation validates the conversion of binary SyscallEvent into TelemetryObservation.
func TestNormalizeTelemetryObservation(t *testing.T) {
	tenants, err := ParseTenantMap("tenant-kusari=kusari")
	if err != nil {
		t.Fatal(err)
	}
	mgr := NewSentinelProbeManager(nil, "http://localhost:8082", nil, WithTenantMap(tenants))

	var comm [16]byte
	copy(comm[:], "cat\x00")

	var filename [256]byte
	copy(filename[:], "/etc/passwd\x00")

	raw := SyscallEvent{
		PID:      1234,
		TGID:     1234,
		UID:      0,
		Type:     SyscallTypeOpenat,
		Comm:     comm,
		Filename: filename,
	}

	pod := CreateTestPod("tenant-kusari", "kusari-builder", "11111111-2222-3333-4444-555555555555", "kusari-builder", "kusari")

	obs := mgr.NormalizeObservation(raw, pod)

	// Validate RFC3339Nano timestamp
	parsedTime, err := time.Parse(time.RFC3339Nano, obs.Timestamp)
	if err != nil {
		t.Fatalf("invalid RFC3339Nano timestamp: %v", err)
	}
	if time.Since(parsedTime) > 5*time.Second {
		t.Errorf("timestamp is too old or inaccurate: %s", obs.Timestamp)
	}

	// Validate ActorID
	if obs.ActorID != "kusari-builder" {
		t.Errorf("expected ActorID 'kusari-builder', got '%s'", obs.ActorID)
	}

	// Validate TenantID (Canonical Tenant Vector)
	if obs.TenantID != "kusari" {
		t.Errorf("expected TenantID 'kusari', got '%s'", obs.TenantID)
	}

	// Validate Severity
	if obs.Severity != SeverityCritical {
		t.Errorf("expected Severity '%s', got '%s'", SeverityCritical, obs.Severity)
	}

	// Validate Syscall
	if obs.Syscall != SyscallNameOpenat {
		t.Errorf("expected Syscall '%s', got '%s'", SyscallNameOpenat, obs.Syscall)
	}

	// Validate Target
	if obs.Target != "/etc/passwd" {
		t.Errorf("expected Target '/etc/passwd', got '%s'", obs.Target)
	}

	// Validate Pod metadata
	if obs.PodName != "kusari-builder" {
		t.Errorf("expected PodName 'kusari-builder', got '%s'", obs.PodName)
	}
	if obs.Namespace != "tenant-kusari" {
		t.Errorf("expected Namespace 'tenant-kusari', got '%s'", obs.Namespace)
	}
}

// TestSensitivePrefixFilter asserts that sensitive paths trigger alerts while benign paths are ignored.
func TestSensitivePrefixFilter(t *testing.T) {
	mgr := NewSentinelProbeManager(nil, "http://localhost:8082", nil)

	sensitivePaths := []string{
		"/etc/passwd",
		"/etc/shadow",
		"/var/run/secrets/kubernetes.io/serviceaccount/token",
		"/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
		"/root/.ssh/id_rsa",
		"/root/.ssh/authorized_keys",
	}

	for _, p := range sensitivePaths {
		if !mgr.IsSensitivePath(p) {
			t.Errorf("expected IsSensitivePath(%q) to be true, got false", p)
		}
	}

	benignPaths := []string{
		"/usr/lib/libc.so",
		"/app/index.js",
		"/tmp/test.log",
		"/var/log/syslog",
		"/bin/sh",
	}

	for _, p := range benignPaths {
		if mgr.IsSensitivePath(p) {
			t.Errorf("expected IsSensitivePath(%q) to be false, got true", p)
		}
	}
}

// TestDispatchObservation validates HTTP POST transmission to mock signal-ingest:8082
// with Bearer authentication and schema fidelity.
func TestDispatchObservation(t *testing.T) {
	var receivedRequest atomic.Value

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/observations" {
			http.NotFound(w, r)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		authHeader := r.Header.Get("Authorization")
		if authHeader != "Bearer "+testIngestToken {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		// The real signal-ingest decodes a JSON ARRAY of observations; this mock
		// used to decode a single object, i.e. the shape the real service
		// rejects with 400, so it certified a contract that never existed.
		var batch []ingestObservation
		if err := json.Unmarshal(body, &batch); err != nil || len(batch) != 1 {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}

		receivedRequest.Store(&batch[0])
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"created"}`))
	}))
	defer server.Close()

	mgr := NewSentinelProbeManager(nil, server.URL, nil, WithBearerToken(testIngestToken))

	testObs := TelemetryObservation{
		Timestamp:      time.Now().UTC().Format(time.RFC3339Nano),
		ActorID:        "kusari-agent",
		TenantID:       "kusari",
		PodName:        "kusari-agent-pod",
		Namespace:      "tenant-kusari",
		Syscall:        SyscallNameOpenat,
		Target:         "/etc/passwd",
		Severity:       SeverityCritical,
		DirectReaction: ReactionCgroupFrozen,
		Labels: map[string]string{
			"signalloom.ai/agent": "true",
			"tenant":              "kusari",
		},
	}

	err := mgr.dispatchObservation(testObs)
	if err != nil {
		t.Fatalf("dispatchObservation failed: %v", err)
	}

	val := receivedRequest.Load()
	if val == nil {
		t.Fatalf("server did not receive telemetry observation")
	}

	receivedObs, ok := val.(*ingestObservation)
	if !ok || receivedObs == nil {
		t.Fatalf("received request is not an ingest observation")
	}

	if receivedObs.Labels["target"] != "/etc/passwd" {
		t.Errorf("expected target '/etc/passwd', got '%s'", receivedObs.Labels["target"])
	}
	if receivedObs.Labels["tenant_id"] != "kusari" {
		t.Errorf("expected tenant_id 'kusari', got '%s'", receivedObs.Labels["tenant_id"])
	}
	if receivedObs.Labels["direct_reaction"] != ReactionCgroupFrozen {
		t.Errorf("expected direct_reaction 'cgroup_frozen', got '%s'", receivedObs.Labels["direct_reaction"])
	}
}

// TestKusariAgentIsAttributedToKusariByItsServiceAccount pins the live Step 4
// expectation (tenant_id == kusari) to the kusari-agent Deployment as it ships:
// namespace fe-signalloom-agents, serviceAccountName kusari-agent, and no
// `tenant` label at all. It was kusari before only because every pod defaulted
// to kusari (review M5).
func TestKusariAgentIsAttributedToKusariByItsServiceAccount(t *testing.T) {
	tenants, err := ParseTenantMap("fe-signalloom-agents/kusari-agent=kusari")
	if err != nil {
		t.Fatal(err)
	}
	mgr := NewSentinelProbeManager(nil, "http://localhost:8082", nil, WithTenantMap(tenants))

	pod := CreateTestPod("fe-signalloom-agents", "kusari-agent-5d8c", "33333333-4444-5555-6666-777777777777", "kusari-agent", "")
	delete(pod.Labels, "tenant")
	pod.Labels["signalloom.ai/tenant"] = "kusari"
	pod.Spec.ServiceAccountName = "kusari-agent"

	if got := mgr.NormalizeObservation(SyscallEvent{Type: SyscallTypeOpenat}, pod).TenantID; got != "kusari" {
		t.Errorf("expected TenantID 'kusari', got '%s'", got)
	}
}

// TestOwnerRecordPhaseGating verifies that cgroup freezing refuses execution if pod is outside Running phase.
func TestOwnerRecordPhaseGating(t *testing.T) {
	mockFreezer := NewMockFreezeManager(func(pod *corev1.Pod) error {
		return nil
	})

	pod := CreateTestPod("tenant-kusari", "pending-agent", "44444444-5555-6666-7777-888888888888", "pending-agent", "kusari")
	pod.Status.Phase = corev1.PodPending

	err := mockFreezer.FreezePod(pod)
	if err == nil {
		t.Errorf("expected error freezing pod in Pending phase, got nil")
	}
	if !strings.Contains(err.Error(), "not Running") && !strings.Contains(err.Error(), "refusing freeze outside Running phase") {
		t.Errorf("unexpected error message: %v", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// SLAAT-P2-4: stdout alarm logging survives a signal-ingest outage
//
// Before this change, dispatchWorker's only record of a detection was the
// HTTP POST to signal-ingest, and that POST's error was discarded
// (`_ = m.dispatchObservation(obs)`). An observation generated no evidence
// anywhere `kubectl logs` could show if signal-ingest was unreachable --
// which is exactly the condition under test here. These tests swap the
// package-level correlatorLogOut for a buffer rather than driving the real
// queue/worker goroutines, so they are deterministic and need no sleep.
// ─────────────────────────────────────────────────────────────────────────────

func withCapturedCorrelatorLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	original := correlatorLogOut
	correlatorLogOut = &buf
	t.Cleanup(func() { correlatorLogOut = original })
	return &buf
}

func TestLogObservationWritesStructuredJSONLine(t *testing.T) {
	buf := withCapturedCorrelatorLog(t)
	obs := TelemetryObservation{PodName: "agent-1", Syscall: SyscallNameEvasiveBurst, Severity: SeverityCritical}

	logObservation(obs)

	var ev correlatorEvent
	if err := json.Unmarshal(buf.Bytes(), &ev); err != nil {
		t.Fatalf("logObservation did not emit valid JSON: %v (%q)", err, buf.String())
	}
	if ev.Event != "ebpf_detection" || ev.Observation.PodName != "agent-1" || ev.Error != "" {
		t.Errorf("event = %+v", ev)
	}
}

func TestLogDispatchFailureRecordsTheErrorAlongsideTheObservation(t *testing.T) {
	buf := withCapturedCorrelatorLog(t)
	obs := TelemetryObservation{PodName: "agent-1", Syscall: SyscallNameEvasiveBurst}

	logDispatchFailure(obs, errors.New("signal-ingest unreachable"))

	var ev correlatorEvent
	if err := json.Unmarshal(buf.Bytes(), &ev); err != nil {
		t.Fatalf("logDispatchFailure did not emit valid JSON: %v (%q)", err, buf.String())
	}
	if ev.Event != "ebpf_detection_dispatch_failed" || ev.Observation.PodName != "agent-1" {
		t.Errorf("event = %+v", ev)
	}
	if ev.Error != "signal-ingest unreachable" {
		t.Errorf("Error = %q, want the dispatch error surfaced, not swallowed", ev.Error)
	}
}

func TestDispatchWorkerLogsEveryObservationIndependentlyOfIngestReachability(t *testing.T) {
	buf := withCapturedCorrelatorLog(t)
	// No httptest server backing this URL: every dispatch attempt fails.
	m := NewSentinelProbeManager(nil, "http://127.0.0.1:1/unreachable", nil, WithBearerToken(testIngestToken))
	m.queue <- TelemetryObservation{PodName: "agent-2", Syscall: SyscallNameEvasiveBurst}
	close(m.queue)

	m.wg.Add(1)
	m.dispatchWorker(context.Background())

	// Two lines, not one: the unconditional "every observation is logged"
	// record, PLUS the dispatch-failure record naming why the POST itself
	// did not land. Losing either half would silently reopen the gap this
	// card found -- the first is what proves the detection happened at all,
	// the second is what proves the operator is told ingest is unreachable
	// rather than that being swallowed as `_ = m.dispatchObservation(obs)`
	// used to.
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d log line(s), want exactly 2: %q", len(lines), buf.String())
	}
	var events []string
	for _, line := range lines {
		var ev correlatorEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("invalid JSON %q: %v", line, err)
		}
		if ev.Observation.PodName != "agent-2" {
			t.Errorf("observation.pod_name = %q, want agent-2", ev.Observation.PodName)
		}
		events = append(events, ev.Event)
	}
	if events[0] != "ebpf_detection" || events[1] != "ebpf_detection_dispatch_failed" {
		t.Errorf("events = %v, want [ebpf_detection, ebpf_detection_dispatch_failed] in that order", events)
	}
}
