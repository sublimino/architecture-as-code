// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/json"
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
	mgr := NewSentinelProbeManager(nil, "http://localhost:8082", nil)

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

// TestDirectReactionFreeze asserts that detecting a violation on an agent pod
// triggers FreezePod and populates DirectReaction = 'cgroup_frozen'.
func TestDirectReactionFreeze(t *testing.T) {
	var freezeCalled int32
	mockFreezer := NewMockFreezeManager(func(pod *corev1.Pod) error {
		atomic.AddInt32(&freezeCalled, 1)
		return nil
	})

	mgr := NewSentinelProbeManager(nil, "http://localhost:8082", mockFreezer)

	pod := CreateTestPod("tenant-kusari", "agent-runner", "22222222-3333-4444-5555-666666666666", "agent-runner", "kusari")
	pod.Status.Phase = corev1.PodRunning

	var filename [256]byte
	copy(filename[:], "/etc/shadow\x00")

	raw := SyscallEvent{
		PID:      4567,
		TGID:     4567,
		UID:      0,
		Type:     SyscallTypeOpenat,
		Filename: filename,
	}

	obs := mgr.NormalizeObservation(raw, pod)

	if isAgentPod(pod) && mgr.freezeManager != nil {
		if err := mgr.freezeManager.FreezePod(pod); err == nil {
			obs.DirectReaction = ReactionCgroupFrozen
		}
	}

	if atomic.LoadInt32(&freezeCalled) != 1 {
		t.Errorf("expected freezeManager.FreezePod to be called once, got %d", freezeCalled)
	}

	if obs.DirectReaction != ReactionCgroupFrozen {
		t.Errorf("expected DirectReaction '%s', got '%s'", ReactionCgroupFrozen, obs.DirectReaction)
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
		if authHeader != "Bearer sentinel-in-cluster-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		var obs TelemetryObservation
		if err := json.Unmarshal(body, &obs); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}

		receivedRequest.Store(&obs)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"created"}`))
	}))
	defer server.Close()

	mgr := NewSentinelProbeManager(nil, server.URL, nil)

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

	receivedObs, ok := val.(*TelemetryObservation)
	if !ok || receivedObs == nil {
		t.Fatalf("received request is not TelemetryObservation")
	}

	if receivedObs.Target != "/etc/passwd" {
		t.Errorf("expected Target '/etc/passwd', got '%s'", receivedObs.Target)
	}
	if receivedObs.TenantID != "kusari" {
		t.Errorf("expected TenantID 'kusari', got '%s'", receivedObs.TenantID)
	}
	if receivedObs.DirectReaction != ReactionCgroupFrozen {
		t.Errorf("expected DirectReaction 'cgroup_frozen', got '%s'", receivedObs.DirectReaction)
	}
}

// TestCanonicalTenantNormalization verifies that canonical 'kusari' tenant labels are normalized.
func TestCanonicalTenantNormalization(t *testing.T) {
	mgr := NewSentinelProbeManager(nil, "http://localhost:8082", nil)

	pod := CreateTestPod("tenant-kusari", "kusari-agent", "33333333-4444-5555-6666-777777777777", "kusari-agent", "kusari")
	raw := SyscallEvent{Type: SyscallTypeOpenat}

	obs := mgr.NormalizeObservation(raw, pod)
	if obs.TenantID != "kusari" {
		t.Errorf("expected TenantID 'kusari', got '%s'", obs.TenantID)
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
