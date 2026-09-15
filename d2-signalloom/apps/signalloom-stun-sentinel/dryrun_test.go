package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func TestDryRunFreezerDoesNotMutateCgroup(t *testing.T) {
	dir := t.TempDir()
	freezeFile := filepath.Join(dir, "cgroup.freeze")
	if err := os.WriteFile(freezeFile, []byte("0"), 0644); err != nil {
		t.Fatal(err)
	}

	freezer := newCgroupFreezer(dir, true, "token", "token")

	// Freeze in dry-run mode
	if err := freezer.freeze(dir); err != nil {
		t.Fatalf("dry-run freeze failed: %v", err)
	}
	data, _ := os.ReadFile(freezeFile)
	if string(data) != "0" {
		t.Errorf("cgroup.freeze was mutated in dry-run mode: got %q, want 0", string(data))
	}

	// Unfreeze in dry-run mode with 1 in file
	_ = os.WriteFile(freezeFile, []byte("1"), 0644)
	if err := freezer.unfreeze(dir); err != nil {
		t.Fatalf("dry-run unfreeze failed: %v", err)
	}
	data, _ = os.ReadFile(freezeFile)
	if string(data) != "1" {
		t.Errorf("cgroup.freeze was mutated in dry-run unfreeze: got %q, want 1", string(data))
	}
}

func TestDryRunFreezerResolvesPlannedPathWhenMissing(t *testing.T) {
	freezer := newCgroupFreezer("/sys/fs/cgroup", true, "token", "token")
	path, err := freezer.resolvePodCgroup("abc-123-def")
	if err != nil {
		t.Fatalf("resolvePodCgroup failed in dry-run: %v", err)
	}
	if path == "" {
		t.Fatal("expected non-empty resolved cgroup path in dry-run mode")
	}
}

func TestDryRunFreezerResolvesPlannedPathWhenInaccessibleCgroupRoot(t *testing.T) {
	freezer := newCgroupFreezer("/nonexistent/inaccessible/sys/fs/cgroup", true, "token", "token")
	path, err := freezer.resolvePodCgroup("abc-123-def")
	if err != nil {
		t.Fatalf("resolvePodCgroup failed in dry-run with inaccessible cgroupRoot: %v", err)
	}
	expected := filepath.Join("/nonexistent/inaccessible/sys/fs/cgroup", "kubepods.slice", "kubepods-burstable-podabc_123_def.slice")
	if path != expected {
		t.Fatalf("expected path %q, got %q", expected, path)
	}
}

func TestDryRunTCDropFilterDoesNotInvokeTC(t *testing.T) {
	var tcCalls []string
	tc := newTCDropFilter()
	tc.dryRun = true
	tc.run = func(name string, args ...string) ([]byte, error) {
		tcCalls = append(tcCalls, name)
		return nil, nil
	}

	if err := tc.attachDrop("veth-test"); err != nil {
		t.Fatalf("attachDrop failed in dry-run: %v", err)
	}
	if err := tc.detachDrop("veth-test"); err != nil {
		t.Fatalf("detachDrop failed in dry-run: %v", err)
	}
	if len(tcCalls) != 0 {
		t.Errorf("tc was invoked %d times in dry-run mode; want 0", len(tcCalls))
	}

	ingress, egress, err := tc.hasDropFilter("veth-test")
	if err != nil || !ingress || !egress {
		t.Errorf("hasDropFilter in dry-run = (%v, %v, %v), want (true, true, nil)", ingress, egress, err)
	}
}

func TestDryRunReconcilerLogsPlanWithoutMutatingState(t *testing.T) {
	buf := &bytes.Buffer{}
	SetAuditOutput(buf)
	defer SetAuditOutput(nil)

	dir := t.TempDir()
	cgroupPath := filepath.Join(dir, "podtest_uid.slice")
	if err := os.MkdirAll(cgroupPath, 0755); err != nil {
		t.Fatal(err)
	}
	freezeFile := filepath.Join(cgroupPath, "cgroup.freeze")
	if err := os.WriteFile(freezeFile, []byte("0"), 0644); err != nil {
		t.Fatal(err)
	}

	freezer := newCgroupFreezer(dir, true, "token", "token")
	tc := newTCDropFilter()
	tc.dryRun = true
	probes := newProbePreserver()
	probes.dryRun = true

	reconciler := newStunReconciler(freezer, tc, probes)
	reconciler.dryRun = true
	reconciler.reconcileCount = &atomic.Int64{}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-cardvault",
			Namespace: "fe-signalloom-agents",
			UID:       "test-uid",
			Labels:    map[string]string{labelStunned: stunnedValue},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name: "cardvault",
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/healthz", Port: intstr.FromInt32(8080)},
						},
					},
				},
			},
		},
	}

	// 1. Reconcile Stun (Dry-Run)
	if err := reconciler.reconcile(pod); err != nil {
		t.Fatalf("dry-run stun reconcile failed: %v", err)
	}

	// Verify cgroup file was NOT modified to 1
	data, _ := os.ReadFile(freezeFile)
	if string(data) != "0" {
		t.Errorf("cgroup.freeze was modified to %q during dry-run stun; want 0", string(data))
	}

	// Verify probe preserver tracked the probe
	if !probes.isPreserved("test-uid") {
		t.Errorf("probe state was not tracked in memory")
	}

	// Verify audit log output
	lines := bytes.Split(bytes.TrimSpace(buf.Bytes()), []byte("\n"))
	if len(lines) < 2 {
		t.Fatalf("expected at least 2 audit log lines, got %d", len(lines))
	}

	var stunEv stunEvent
	if err := json.Unmarshal(lines[len(lines)-1], &stunEv); err != nil {
		t.Fatalf("unmarshal stun event: %v", err)
	}

	if stunEv.Event != "stun" {
		t.Errorf("event = %q, want stun", stunEv.Event)
	}
	if !stunEv.DryRun {
		t.Errorf("dry_run = false, want true")
	}
	if stunEv.Decision != "containment_planned_dry_run" {
		t.Errorf("decision = %q, want containment_planned_dry_run", stunEv.Decision)
	}
	if stunEv.ReconcileCount != 1 {
		t.Errorf("reconcile_count = %d, want 1", stunEv.ReconcileCount)
	}
	if stunEv.TCIngressFilter == "" || stunEv.TCEgressFilter == "" {
		t.Errorf("TC filter plans missing from dry-run audit event: %+v", stunEv)
	}

	// 2. Reconcile Unstun (Dry-Run)
	buf.Reset()
	pod.Labels[labelStunned] = "idle"
	if err := reconciler.reconcile(pod); err != nil {
		t.Fatalf("dry-run unstun reconcile failed: %v", err)
	}

	// Verify probe released
	if probes.isPreserved("test-uid") {
		t.Errorf("probe was not released after unstun")
	}

	unstunLines := bytes.Split(bytes.TrimSpace(buf.Bytes()), []byte("\n"))
	var unstunEv stunEvent
	if err := json.Unmarshal(unstunLines[len(unstunLines)-1], &unstunEv); err != nil {
		t.Fatalf("unmarshal unstun event: %v", err)
	}
	if unstunEv.Event != "unstun" || !unstunEv.DryRun || unstunEv.Decision != "containment_release_planned_dry_run" {
		t.Errorf("unexpected unstun event: %+v", unstunEv)
	}
	if unstunEv.ReconcileCount != 2 {
		t.Errorf("reconcile_count = %d, want 2", unstunEv.ReconcileCount)
	}
}
