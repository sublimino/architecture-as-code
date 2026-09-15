// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package cgroup

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// BenchmarkFreezeMeasuresPreAndPostUnificationFreezeLatency measures the CPU
// and wall-clock latency of the unified freeze operation against mock cgroupfs.
func BenchmarkFreeze(b *testing.B) {
	dir := b.TempDir()
	cgroupPath := filepath.Join(dir, "bench-pod")
	if err := os.MkdirAll(cgroupPath, 0o755); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cgroupPath, freezeFile), []byte("0"), 0o644); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cgroupPath, eventsFile), []byte("populated 1\nfrozen 1\n"), 0o644); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cgroupPath, procsFile), []byte("1001\n1002\n"), 0o644); err != nil {
		b.Fatal(err)
	}

	freezer := New(dir,
		WithDeadline(50*time.Millisecond),
		WithFreezeCredentialValidator(func(string) bool { return true }),
		WithCredentialValidator(func(string) bool { return true }),
	)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		res, err := freezer.Freeze(cgroupPath, "valid-token")
		if err != nil {
			b.Fatalf("freeze failed: %v", err)
		}
		if !res.Frozen {
			b.Fatal("freeze did not observe frozen state")
		}
	}
}

// BenchmarkUnfreeze measures the CPU and wall-clock latency of the unfreeze operation.
func BenchmarkUnfreeze(b *testing.B) {
	dir := b.TempDir()
	cgroupPath := filepath.Join(dir, "bench-pod")
	if err := os.MkdirAll(cgroupPath, 0o755); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cgroupPath, freezeFile), []byte("1"), 0o644); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cgroupPath, eventsFile), []byte("populated 1\nfrozen 0\n"), 0o644); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cgroupPath, procsFile), []byte("1001\n1002\n"), 0o644); err != nil {
		b.Fatal(err)
	}

	freezer := New(dir,
		WithDeadline(50*time.Millisecond),
		WithFreezeCredentialValidator(func(string) bool { return true }),
		WithCredentialValidator(func(string) bool { return true }),
	)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		res, err := freezer.Unfreeze(cgroupPath, "valid-token")
		if err != nil {
			b.Fatalf("unfreeze failed: %v", err)
		}
		if res.Frozen {
			b.Fatal("unfreeze did not observe unfrozen state")
		}
	}
}

// BenchmarkResolvePodCgroup measures candidate matrix lookup latency.
func BenchmarkResolvePodCgroup(b *testing.B) {
	dir := b.TempDir()
	podUID := "e4fc67c7-054b-4934-bfdd-d13b6390e2c3"
	podUIDUnderscored := "e4fc67c7_054b_4934_bfdd_d13b6390e2c3"
	podDir := filepath.Join(dir, "kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod"+podUIDUnderscored+".slice")
	if err := os.MkdirAll(podDir, 0o755); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(podDir, freezeFile), []byte("0"), 0o644); err != nil {
		b.Fatal(err)
	}

	freezer := New(dir)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		path, err := freezer.ResolvePodCgroup(podUID)
		if err != nil || path != podDir {
			b.Fatalf("resolve failed: %v, path=%q", err, path)
		}
	}
}
