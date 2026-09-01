package main

import (
	"os"
	"path/filepath"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────
// Cgroup freezer tests with mock filesystem.
// ─────────────────────────────────────────────────────────────────────────────

func TestFreezePodWritesOne(t *testing.T) {
	dir := t.TempDir()
	cgroupFile := filepath.Join(dir, "cgroup.freeze")
	os.WriteFile(cgroupFile, []byte("0"), 0644)

	f := &cgroupFreezer{cgroupRoot: dir}
	err := f.freeze(dir)
	if err != nil {
		t.Fatalf("freeze: %v", err)
	}

	data, _ := os.ReadFile(cgroupFile)
	if string(data) != "1" {
		t.Errorf("cgroup.freeze: got %q, want %q", string(data), "1")
	}
}

func TestUnfreezePodWritesZero(t *testing.T) {
	dir := t.TempDir()
	cgroupFile := filepath.Join(dir, "cgroup.freeze")
	os.WriteFile(cgroupFile, []byte("1"), 0644)

	f := &cgroupFreezer{cgroupRoot: dir}
	err := f.unfreeze(dir)
	if err != nil {
		t.Fatalf("unfreeze: %v", err)
	}

	data, _ := os.ReadFile(cgroupFile)
	if string(data) != "0" {
		t.Errorf("cgroup.freeze: got %q, want %q", string(data), "0")
	}
}

func TestFreezeNonexistentPath(t *testing.T) {
	f := &cgroupFreezer{cgroupRoot: "/nonexistent"}
	err := f.freeze("/nonexistent/pod-abc")
	if err == nil {
		t.Fatal("expected error for nonexistent cgroup path")
	}
}

func TestUnfreezeNonexistentPath(t *testing.T) {
	f := &cgroupFreezer{cgroupRoot: "/nonexistent"}
	err := f.unfreeze("/nonexistent/pod-abc")
	if err == nil {
		t.Fatal("expected error for nonexistent cgroup path")
	}
}

func TestResolvePodCgroupPath(t *testing.T) {
	// Create a mock cgroup hierarchy.
	dir := t.TempDir()
	podDir := filepath.Join(dir, "kubepods", "burstable", "pod-test-uid")
	os.MkdirAll(podDir, 0755)
	os.WriteFile(filepath.Join(podDir, "cgroup.freeze"), []byte("0"), 0644)

	f := &cgroupFreezer{cgroupRoot: dir}
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
	os.MkdirAll(podDir, 0755)
	os.WriteFile(filepath.Join(podDir, "cgroup.freeze"), []byte("0"), 0644)

	f := &cgroupFreezer{cgroupRoot: dir}
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
	if err := os.MkdirAll(podDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(podDir, "cgroup.freeze"), []byte("0"), 0644); err != nil {
		t.Fatal(err)
	}

	path, err := (&cgroupFreezer{cgroupRoot: dir}).resolvePodCgroup("test-uid")
	if err != nil || path != podDir {
		t.Fatalf("resolve systemd cgroup = %q, %v; want %q, nil", path, err, podDir)
	}
}

func TestResolvePodCgroupRejectsPartialSystemdUIDMatch(t *testing.T) {
	dir := t.TempDir()
	podDir := filepath.Join(dir, "kubelet.slice", "kubelet-kubepods.slice", "kubelet-kubepods-burstable-podtest_uid-extra.slice")
	if err := os.MkdirAll(podDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(podDir, "cgroup.freeze"), []byte("0"), 0644); err != nil {
		t.Fatal(err)
	}

	_, err := (&cgroupFreezer{cgroupRoot: dir}).resolvePodCgroup("test-uid")
	if err == nil {
		t.Fatal("partial systemd UID match unexpectedly resolved")
	}
}

func TestResolvePodCgroupNotFound(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "kubepods"), 0755)

	f := &cgroupFreezer{cgroupRoot: dir}
	_, err := f.resolvePodCgroup("nonexistent-uid")
	if err == nil {
		t.Fatal("expected error for nonexistent pod cgroup")
	}
}

func TestFreezeIdempotent(t *testing.T) {
	dir := t.TempDir()
	cgroupFile := filepath.Join(dir, "cgroup.freeze")
	os.WriteFile(cgroupFile, []byte("1"), 0644) // already frozen

	f := &cgroupFreezer{cgroupRoot: dir}
	err := f.freeze(dir)
	if err != nil {
		t.Fatalf("freeze already-frozen: %v", err)
	}

	data, _ := os.ReadFile(cgroupFile)
	if string(data) != "1" {
		t.Errorf("cgroup.freeze: got %q, want %q", string(data), "1")
	}
}

func TestFreezeWithCgroupEvents(t *testing.T) {
	dir := t.TempDir()
	cgroupFile := filepath.Join(dir, "cgroup.freeze")
	eventsFile := filepath.Join(dir, "cgroup.events")
	os.WriteFile(cgroupFile, []byte("0"), 0644)
	os.WriteFile(eventsFile, []byte("populated 1\nfrozen 1\n"), 0644)

	f := &cgroupFreezer{cgroupRoot: dir}
	if err := f.freeze(dir); err != nil {
		t.Fatalf("freeze with events: %v", err)
	}

	data, _ := os.ReadFile(cgroupFile)
	if string(data) != "1" {
		t.Errorf("cgroup.freeze: got %q, want 1", string(data))
	}
}

func TestUnfreezeWithCgroupEvents(t *testing.T) {
	dir := t.TempDir()
	cgroupFile := filepath.Join(dir, "cgroup.freeze")
	eventsFile := filepath.Join(dir, "cgroup.events")
	os.WriteFile(cgroupFile, []byte("1"), 0644)
	os.WriteFile(eventsFile, []byte("populated 1\nfrozen 0\n"), 0644)

	f := &cgroupFreezer{cgroupRoot: dir}
	if err := f.unfreeze(dir); err != nil {
		t.Fatalf("unfreeze with events: %v", err)
	}

	data, _ := os.ReadFile(cgroupFile)
	if string(data) != "0" {
		t.Errorf("cgroup.freeze: got %q, want 0", string(data))
	}
}
