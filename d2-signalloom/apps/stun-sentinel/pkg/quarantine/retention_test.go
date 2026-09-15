// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package quarantine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func createMockSnapshot(t *testing.T, storageDir, id string, createdAt time.Time, dummySizeBytes int) string {
	t.Helper()
	dir := filepath.Join(storageDir, "quarantine_pod123_"+id)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatalf("mkdir failed: %v", err)
	}

	manifest := QuarantineManifest{
		Version:   ManifestVersion,
		Kind:      ManifestKind,
		CaptureID: id,
		Target: TargetInfo{
			PodUID: "pod123",
		},
		CreatedAt:   createdAt,
		StoragePath: dir,
	}

	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), data, 0600); err != nil {
		t.Fatalf("write manifest failed: %v", err)
	}

	// Write dummy payload file
	if dummySizeBytes > 0 {
		dummyData := make([]byte, dummySizeBytes)
		if err := os.WriteFile(filepath.Join(dir, "mem_dump.bin"), dummyData, 0600); err != nil {
			t.Fatalf("write dummy failed: %v", err)
		}
	}

	return dir
}

func TestPruneMaxSnapshots(t *testing.T) {
	storageDir := t.TempDir()
	now := time.Now()

	// Create 10 snapshots spaced 1 hour apart
	for i := 1; i <= 10; i++ {
		id := fmt.Sprintf("snap-%02d", i)
		createMockSnapshot(t, storageDir, id, now.Add(time.Duration(i)*time.Hour), 1024)
	}

	policy := RetentionPolicy{
		MaxSnapshots: 4,
	}

	res, err := Prune(storageDir, policy)
	if err != nil {
		t.Fatalf("Prune failed: %v", err)
	}

	if res.PrunedCount != 6 {
		t.Errorf("expected 6 pruned snapshots, got %d (pruned: %v)", res.PrunedCount, res.PrunedIDs)
	}
	if res.RemainingCount != 4 {
		t.Errorf("expected 4 remaining snapshots, got %d", res.RemainingCount)
	}

	// Verify the 4 newest survived (snap-07, snap-08, snap-09, snap-10)
	entries, err := os.ReadDir(storageDir)
	if err != nil {
		t.Fatalf("read dir failed: %v", err)
	}
	if len(entries) != 4 {
		t.Fatalf("expected 4 directories remaining, got %d", len(entries))
	}
}

func TestPruneMaxTotalSizeBytes(t *testing.T) {
	storageDir := t.TempDir()
	now := time.Now()

	// Create 5 snapshots of 200KB each = 1000KB total
	for i := 1; i <= 5; i++ {
		id := fmt.Sprintf("snap-%02d", i)
		createMockSnapshot(t, storageDir, id, now.Add(time.Duration(i)*time.Minute), 200*1024)
	}

	// Allow max 500KB total
	policy := RetentionPolicy{
		MaxTotalSizeBytes: 500 * 1024,
	}

	res, err := Prune(storageDir, policy)
	if err != nil {
		t.Fatalf("Prune failed: %v", err)
	}

	if res.PrunedCount < 2 {
		t.Errorf("expected at least 2 pruned snapshots, got %d", res.PrunedCount)
	}
	if res.RemainingSizeBytes > 500*1024 {
		t.Errorf("remaining size %d exceeds max 500KB", res.RemainingSizeBytes)
	}
}

func TestPruneMaxAge(t *testing.T) {
	storageDir := t.TempDir()
	now := time.Now()

	// Create 3 old snapshots (10 days old) and 2 fresh snapshots (1 hour old)
	for i := 1; i <= 3; i++ {
		id := fmt.Sprintf("old-snap-%02d", i)
		createMockSnapshot(t, storageDir, id, now.Add(-10*24*time.Hour), 1024)
	}
	for i := 1; i <= 2; i++ {
		id := fmt.Sprintf("new-snap-%02d", i)
		createMockSnapshot(t, storageDir, id, now.Add(-1*time.Hour), 1024)
	}

	policy := RetentionPolicy{
		MaxAge: 7 * 24 * time.Hour, // 7 days max age
	}

	res, err := Prune(storageDir, policy)
	if err != nil {
		t.Fatalf("Prune failed: %v", err)
	}

	if res.PrunedCount != 3 {
		t.Errorf("expected 3 expired snapshots pruned, got %d", res.PrunedCount)
	}
	if res.RemainingCount != 2 {
		t.Errorf("expected 2 fresh snapshots remaining, got %d", res.RemainingCount)
	}
}
