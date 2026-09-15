// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Cgroup freezer adapter tests with mock filesystem and unified engine.
// ─────────────────────────────────────────────────────────────────────────────

func mockFreezableCgroup(t *testing.T, dir string, frozen bool) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	freezeVal := "0"
	eventsVal := "populated 1\nfrozen 0\n"
	if frozen {
		freezeVal = "1"
		eventsVal = "populated 1\nfrozen 1\n"
	}
	if err := os.WriteFile(filepath.Join(dir, "cgroup.freeze"), []byte(freezeVal), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cgroup.events"), []byte(eventsVal), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cgroup.procs"), []byte("101\n102\n"), 0644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestFreezePodWritesOneAndVerifies(t *testing.T) {
	dir := t.TempDir()
	cgroupDir := mockFreezableCgroup(t, filepath.Join(dir, "pod-test"), false)

	// Simulate kernel settling after write
	go func() {
		time.Sleep(5 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(cgroupDir, "cgroup.events"), []byte("populated 1\nfrozen 1\n"), 0644)
	}()

	f := newCgroupFreezer(dir, false, "token", "token")
	err := f.freeze(cgroupDir)
	if err != nil {
		t.Fatalf("freeze: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(cgroupDir, "cgroup.freeze"))
	if strings.TrimSpace(string(data)) != "1" {
		t.Errorf("cgroup.freeze: got %q, want %q", string(data), "1")
	}
}

func TestUnfreezePodWritesZeroAndVerifies(t *testing.T) {
	dir := t.TempDir()
	cgroupDir := mockFreezableCgroup(t, filepath.Join(dir, "pod-test"), true)

	go func() {
		time.Sleep(5 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(cgroupDir, "cgroup.events"), []byte("populated 1\nfrozen 0\n"), 0644)
	}()

	f := newCgroupFreezer(dir, false, "token", "token")
	err := f.unfreeze(cgroupDir)
	if err != nil {
		t.Fatalf("unfreeze: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(cgroupDir, "cgroup.freeze"))
	if strings.TrimSpace(string(data)) != "0" {
		t.Errorf("cgroup.freeze: got %q, want %q", string(data), "0")
	}
}

func TestFreezeNonexistentPath(t *testing.T) {
	f := newCgroupFreezer("/nonexistent", false, "token", "token")
	err := f.freeze("/nonexistent/pod-abc")
	if err == nil {
		t.Fatal("expected error for nonexistent cgroup path")
	}
}

func TestUnfreezeNonexistentPath(t *testing.T) {
	f := newCgroupFreezer("/nonexistent", false, "token", "token")
	err := f.unfreeze("/nonexistent/pod-abc")
	if err == nil {
		t.Fatal("expected error for nonexistent cgroup path")
	}
}

func TestResolvePodCgroupPath(t *testing.T) {
	dir := t.TempDir()
	podDir := filepath.Join(dir, "kubepods", "burstable", "pod-test-uid")
	mockFreezableCgroup(t, podDir, false)

	f := newCgroupFreezer(dir, false, "", "")
	path, err := f.resolvePodCgroup("test-uid")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if path != podDir {
		t.Errorf("path: got %q, want %q", path, podDir)
	}
}

func TestResolvePodCgroupGuaranteed(t *testing.T) {
	dir := t.TempDir()
	podDir := filepath.Join(dir, "kubepods", "pod-guaranteed-uid")
	mockFreezableCgroup(t, podDir, false)

	f := newCgroupFreezer(dir, false, "", "")
	path, err := f.resolvePodCgroup("guaranteed-uid")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if path != podDir {
		t.Errorf("path: got %q, want %q", path, podDir)
	}
}

func TestResolvePodCgroupSystemdSlice(t *testing.T) {
	dir := t.TempDir()
	podDir := filepath.Join(dir, "kubelet.slice", "kubelet-kubepods.slice", "kubelet-kubepods-burstable-podtest_uid.slice")
	mockFreezableCgroup(t, podDir, false)

	path, err := newCgroupFreezer(dir, false, "", "").resolvePodCgroup("test-uid")
	if err != nil || path != podDir {
		t.Fatalf("resolve systemd cgroup = %q, %v; want %q, nil", path, err, podDir)
	}
}

func TestResolvePodCgroupRejectsPartialSystemdUIDMatch(t *testing.T) {
	dir := t.TempDir()
	podDir := filepath.Join(dir, "kubelet.slice", "kubelet-kubepods.slice", "kubelet-kubepods-burstable-podtest_uid-extra.slice")
	mockFreezableCgroup(t, podDir, false)

	_, err := newCgroupFreezer(dir, false, "", "").resolvePodCgroup("test-uid")
	if err == nil {
		t.Fatal("partial systemd UID match unexpectedly resolved")
	}
}

func TestResolvePodCgroupNotFound(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "kubepods"), 0755); err != nil {
		t.Fatal(err)
	}

	f := newCgroupFreezer(dir, false, "", "")
	_, err := f.resolvePodCgroup("nonexistent-uid")
	if err == nil {
		t.Fatal("expected error for nonexistent pod cgroup")
	}
}

func TestFreezeIdempotent(t *testing.T) {
	dir := t.TempDir()
	cgroupDir := mockFreezableCgroup(t, filepath.Join(dir, "pod-test"), true)

	f := newCgroupFreezer(dir, false, "token", "token")
	err := f.freeze(cgroupDir)
	if err != nil {
		t.Fatalf("freeze already-frozen: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(cgroupDir, "cgroup.freeze"))
	if strings.TrimSpace(string(data)) != "1" {
		t.Errorf("cgroup.freeze: got %q, want %q", string(data), "1")
	}
}

func TestFreezeWithCgroupEvents(t *testing.T) {
	dir := t.TempDir()
	cgroupDir := mockFreezableCgroup(t, filepath.Join(dir, "pod-test"), false)

	go func() {
		time.Sleep(5 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(cgroupDir, "cgroup.events"), []byte("populated 1\nfrozen 1\n"), 0644)
	}()

	f := newCgroupFreezer(dir, false, "token", "token")
	if err := f.freeze(cgroupDir); err != nil {
		t.Fatalf("freeze with events: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(cgroupDir, "cgroup.freeze"))
	if strings.TrimSpace(string(data)) != "1" {
		t.Errorf("cgroup.freeze: got %q, want 1", string(data))
	}
}

func TestUnfreezeWithCgroupEvents(t *testing.T) {
	dir := t.TempDir()
	cgroupDir := mockFreezableCgroup(t, filepath.Join(dir, "pod-test"), true)

	go func() {
		time.Sleep(5 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(cgroupDir, "cgroup.events"), []byte("populated 1\nfrozen 0\n"), 0644)
	}()

	f := newCgroupFreezer(dir, false, "token", "token")
	if err := f.unfreeze(cgroupDir); err != nil {
		t.Fatalf("unfreeze with events: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(cgroupDir, "cgroup.freeze"))
	if strings.TrimSpace(string(data)) != "0" {
		t.Errorf("cgroup.freeze: got %q, want 0", string(data))
	}
}
