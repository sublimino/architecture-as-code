// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package quarantine

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// DefaultRetention returns a production retention policy.
func DefaultRetention() RetentionPolicy {
	return RetentionPolicy{
		MaxSnapshots:      50,
		MaxTotalSizeBytes: 5 * 1024 * 1024 * 1024, // 5 GB
		MaxAge:            7 * 24 * time.Hour,     // 7 days
	}
}

type snapshotEntry struct {
	id        string
	dirPath   string
	createdAt time.Time
	sizeBytes int64
}

// CalculateDirectorySize sums the size of all regular files in a directory.
func CalculateDirectorySize(dir string) (int64, error) {
	var total int64
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			info, err := d.Info()
			if err == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total, err
}

// Prune sweeps storageDir and removes snapshots violating the retention policy.
// Oldest snapshots are pruned first.
func Prune(storageDir string, policy RetentionPolicy) (*PruneResult, error) {
	result := &PruneResult{
		PrunedIDs: []string{},
	}

	if storageDir == "" {
		return result, nil
	}

	entries, err := os.ReadDir(storageDir)
	if err != nil {
		if os.IsNotExist(err) {
			return result, nil
		}
		return result, fmt.Errorf("read storage dir: %w", err)
	}

	var snapshots []snapshotEntry
	var totalSize int64

	now := time.Now()

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dirPath := filepath.Join(storageDir, entry.Name())
		manifestPath := filepath.Join(dirPath, "manifest.json")

		var createdAt time.Time
		var captureID string

		// Attempt to read manifest for exact metadata; fall back to dir info
		if data, err := os.ReadFile(manifestPath); err == nil {
			var m QuarantineManifest
			if jsonErr := json.Unmarshal(data, &m); jsonErr == nil {
				createdAt = m.CreatedAt
				captureID = m.CaptureID
			}
		}

		info, infoErr := entry.Info()
		if createdAt.IsZero() {
			if infoErr == nil {
				createdAt = info.ModTime()
			} else {
				createdAt = now
			}
		}
		if captureID == "" {
			captureID = entry.Name()
		}

		size, _ := CalculateDirectorySize(dirPath)
		snapshots = append(snapshots, snapshotEntry{
			id:        captureID,
			dirPath:   dirPath,
			createdAt: createdAt,
			sizeBytes: size,
		})
		totalSize += size
	}

	// Sort snapshots oldest first
	sort.Slice(snapshots, func(i, j int) bool {
		return snapshots[i].createdAt.Before(snapshots[j].createdAt)
	})

	var surviving []snapshotEntry

	for _, snap := range snapshots {
		shouldPrune := false

		// 1. Age check
		if policy.MaxAge > 0 && now.Sub(snap.createdAt) > policy.MaxAge {
			shouldPrune = true
		}

		// 2. Count check (if remaining count after this would exceed MaxSnapshots)
		// We count how many surviving snapshots we have
		remainingCount := len(snapshots) - len(result.PrunedIDs)
		if !shouldPrune && policy.MaxSnapshots > 0 && remainingCount > policy.MaxSnapshots {
			shouldPrune = true
		}

		// 3. Size check (if current total size exceeds MaxTotalSizeBytes)
		if !shouldPrune && policy.MaxTotalSizeBytes > 0 && totalSize > policy.MaxTotalSizeBytes {
			shouldPrune = true
		}

		if shouldPrune {
			if err := os.RemoveAll(snap.dirPath); err == nil {
				result.PrunedCount++
				result.PrunedSizeBytes += snap.sizeBytes
				result.PrunedIDs = append(result.PrunedIDs, snap.id)
				totalSize -= snap.sizeBytes
			}
		} else {
			surviving = append(surviving, snap)
		}
	}

	result.RemainingCount = len(surviving)
	result.RemainingSizeBytes = totalSize

	return result, nil
}
