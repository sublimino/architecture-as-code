// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package quarantine

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

var (
	// ErrNoProcesses indicates no PIDs were supplied for quarantine capture.
	ErrNoProcesses = errors.New("quarantine: no processes to capture")
	// ErrSnapshotNotFound indicates the requested snapshot ID was not found.
	ErrSnapshotNotFound = errors.New("quarantine: snapshot not found")
)

// Capturer executes bounded forensic capture of a frozen workload.
type Capturer struct {
	mu  sync.RWMutex
	cfg CaptureConfig
}

// New constructs a Capturer with default bounds applied.
func New(cfg CaptureConfig) *Capturer {
	if cfg.StorageDir == "" {
		cfg.StorageDir = DefaultStorageDir
	}
	if cfg.MaxMemorySizeBytes <= 0 {
		cfg.MaxMemorySizeBytes = DefaultMaxMemorySizeBytes
	}
	if cfg.MaxTimeBudget <= 0 {
		cfg.MaxTimeBudget = DefaultMaxTimeBudget
	}
	if cfg.ProcRoot == "" {
		cfg.ProcRoot = DefaultProcRoot
	}
	if cfg.RetentionPolicy.MaxSnapshots == 0 && cfg.RetentionPolicy.MaxTotalSizeBytes == 0 && cfg.RetentionPolicy.MaxAge == 0 {
		cfg.RetentionPolicy = DefaultRetention()
	}
	return &Capturer{cfg: cfg}
}

// StorageDir returns the configured storage path.
func (c *Capturer) StorageDir() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.cfg.StorageDir
}

// generateCaptureID creates a collision-resistant capture ID.
func generateCaptureID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return fmt.Sprintf("snap-%d-%s", time.Now().UnixNano(), hex.EncodeToString(b))
}

// Capture executes forensic memory and held-resource capture for the given target and PIDs.
func (c *Capturer) Capture(ctx context.Context, target TargetInfo, pids []int) (*QuarantineManifest, error) {
	c.mu.RLock()
	cfg := c.cfg
	c.mu.RUnlock()

	start := time.Now()
	captureID := generateCaptureID()

	// Safe sanitized pod identifier for directory name
	safeUID := strings.ReplaceAll(target.PodUID, "/", "_")
	if safeUID == "" {
		safeUID = "unknown"
	}
	snapDir := filepath.Join(cfg.StorageDir, fmt.Sprintf("quarantine_%s_%s", safeUID, captureID))

	// Ensure directory permissions are strictly 0700 (owner only)
	if err := os.MkdirAll(snapDir, DefaultSnapshotDirPerm); err != nil {
		return nil, fmt.Errorf("quarantine: create snapshot dir %s: %w", snapDir, err)
	}

	manifest := &QuarantineManifest{
		Version:     ManifestVersion,
		Kind:        ManifestKind,
		CaptureID:   captureID,
		Target:      target,
		CreatedAt:   start.UTC(),
		StoragePath: snapDir,
		Summary: CaptureSummary{
			ArtifactHashes: make(map[string]string),
		},
		Processes: make([]ProcessQuarantineState, 0, len(pids)),
	}

	if len(pids) == 0 {
		manifest.Partial = true
		manifest.PartialReason = "no_processes_in_cgroup"
		manifest.CaptureDurationMS = float64(time.Since(start).Nanoseconds()) / 1e6
		_ = c.writeManifest(snapDir, manifest)
		return manifest, nil
	}

	deadline := start.Add(cfg.MaxTimeBudget)
	var timeBudgetExceeded bool
	var sizeBudgetExceeded bool

	for _, pid := range pids {
		// Check context or time budget
		if ctx.Err() != nil {
			manifest.Partial = true
			manifest.PartialReason = "context_cancelled: " + ctx.Err().Error()
			break
		}
		if time.Now().After(deadline) {
			timeBudgetExceeded = true
			manifest.Partial = true
			manifest.PartialReason = "time_budget_exceeded"
			break
		}

		pState := ProcessQuarantineState{
			PID: pid,
		}

		// 1. Process status and memory stats
		stats, comm, state, ppid, err := ParseStatus(pid, cfg.ProcRoot)
		if err == nil {
			pState.MemoryStats = stats
			pState.Comm = comm
			pState.State = state
			pState.PPID = ppid
		}

		// 2. Cmdline
		cmdline, err := ParseCmdline(pid, cfg.ProcRoot)
		if err == nil {
			pState.Cmdline = cmdline
		}

		// 3. Memory regions from maps
		regions, err := ParseMaps(pid, cfg.ProcRoot)
		if err == nil {
			pState.MemoryRegions = regions
		}

		// 4. File descriptors
		fds, err := ParseFDs(pid, cfg.ProcRoot)
		if err == nil {
			pState.FileDescriptors = fds
		}

		// 5. File locks (from /proc/locks and fdinfo)
		locks, err := ParseLocks(pid, cfg.ProcRoot, pState.FileDescriptors)
		if err == nil {
			pState.HeldLocks = locks
		}

		// 6. Network sockets
		socks, err := ParseSockets(pid, cfg.ProcRoot, pState.FileDescriptors)
		if err == nil {
			pState.Sockets = socks
		}

		// 7. Memory dump of writable/anonymous regions (heap, stack, anonymous mappings)
		for i := range pState.MemoryRegions {
			reg := &pState.MemoryRegions[i]
			manifest.Summary.MemoryBytesMapped += int64(reg.EndUint - reg.StartUint)

			// Skip file-backed clean executable pages if DumpAnonymousOnly is set
			if cfg.DumpAnonymousOnly && !reg.IsAnonymous && !reg.IsWritable {
				continue
			}

			// Check budgets before dumping region
			if time.Now().After(deadline) {
				timeBudgetExceeded = true
				manifest.Partial = true
				manifest.PartialReason = "time_budget_exceeded"
				break
			}
			if manifest.Summary.MemoryBytesDumped >= cfg.MaxMemorySizeBytes {
				sizeBudgetExceeded = true
				manifest.Partial = true
				manifest.PartialReason = "memory_size_budget_exceeded"
				break
			}

			remainingBytes := cfg.MaxMemorySizeBytes - manifest.Summary.MemoryBytesDumped
			dumpFileName := fmt.Sprintf("mem_%d_%s.bin", pid, reg.StartAddr)
			dumpFilePath := filepath.Join(snapDir, dumpFileName)

			dumpFile, err := os.OpenFile(dumpFilePath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, DefaultSnapshotFilePerm)
			if err != nil {
				continue
			}

			dumped, hash, err := DumpMemoryRegion(pid, reg, cfg.ProcRoot, remainingBytes, dumpFile)
			dumpFile.Close()

			if dumped > 0 {
				reg.IsDumped = true
				reg.DumpFile = dumpFileName
				reg.DumpSizeBytes = dumped
				reg.SHA256 = hash
				manifest.Summary.MemoryBytesDumped += dumped
				manifest.Summary.ArtifactHashes[dumpFileName] = hash

				// If region was truncated by byte budget
				if dumped < int64(reg.EndUint-reg.StartUint) && manifest.Summary.MemoryBytesDumped >= cfg.MaxMemorySizeBytes {
					sizeBudgetExceeded = true
					manifest.Partial = true
					manifest.PartialReason = "memory_size_budget_exceeded"
				}
			} else {
				// Clean up empty dump file
				_ = os.Remove(dumpFilePath)
			}
		}

		manifest.Processes = append(manifest.Processes, pState)
		manifest.Summary.ProcessCount++
		manifest.Summary.TotalFDCount += len(pState.FileDescriptors)
		manifest.Summary.TotalSocketCount += len(pState.Sockets)
		manifest.Summary.TotalLockCount += len(pState.HeldLocks)

		if timeBudgetExceeded || sizeBudgetExceeded {
			break
		}
	}

	manifest.CaptureDurationMS = float64(time.Since(start).Nanoseconds()) / 1e6

	// Calculate total snapshot size on disk
	dirSize, _ := CalculateDirectorySize(snapDir)
	manifest.Summary.TotalSnapshotSizeBytes = dirSize

	// Write manifest.json atomically with 0600 permissions
	if err := c.writeManifest(snapDir, manifest); err != nil {
		return manifest, fmt.Errorf("quarantine: write manifest: %w", err)
	}

	// Trigger retention pruning
	_, _ = Prune(cfg.StorageDir, cfg.RetentionPolicy)

	return manifest, nil
}

func (c *Capturer) writeManifest(snapDir string, manifest *QuarantineManifest) error {
	manifestPath := filepath.Join(snapDir, "manifest.json")
	tmpPath := filepath.Join(snapDir, "manifest.json.tmp")

	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}

	hasher := sha256.New()
	hasher.Write(data)
	manifestHash := "sha256:" + hex.EncodeToString(hasher.Sum(nil))
	manifest.Summary.ArtifactHashes["manifest.json"] = manifestHash

	// Re-marshal with manifest hash included
	data, _ = json.MarshalIndent(manifest, "", "  ")

	if err := os.WriteFile(tmpPath, data, DefaultSnapshotFilePerm); err != nil {
		return err
	}
	return os.Rename(tmpPath, manifestPath)
}

// ListSnapshots returns all quarantine manifests stored on disk.
func (c *Capturer) ListSnapshots() ([]*QuarantineManifest, error) {
	c.mu.RLock()
	storageDir := c.cfg.StorageDir
	c.mu.RUnlock()

	entries, err := os.ReadDir(storageDir)
	if err != nil {
		if os.IsNotExist(err) {
			return []*QuarantineManifest{}, nil
		}
		return nil, err
	}

	var manifests []*QuarantineManifest
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		manifestPath := filepath.Join(storageDir, entry.Name(), "manifest.json")
		data, err := os.ReadFile(manifestPath)
		if err != nil {
			continue
		}
		var m QuarantineManifest
		if err := json.Unmarshal(data, &m); err == nil {
			manifests = append(manifests, &m)
		}
	}

	sort.Slice(manifests, func(i, j int) bool {
		return manifests[i].CreatedAt.After(manifests[j].CreatedAt)
	})

	return manifests, nil
}

// GetSnapshot retrieves a specific snapshot manifest by capture ID.
func (c *Capturer) GetSnapshot(captureID string) (*QuarantineManifest, error) {
	manifests, err := c.ListSnapshots()
	if err != nil {
		return nil, err
	}
	for _, m := range manifests {
		if m.CaptureID == captureID {
			return m, nil
		}
	}
	return nil, fmt.Errorf("%w: %s", ErrSnapshotNotFound, captureID)
}

// Prune manually executes the retention policy sweep.
func (c *Capturer) Prune() (*PruneResult, error) {
	c.mu.RLock()
	cfg := c.cfg
	c.mu.RUnlock()
	return Prune(cfg.StorageDir, cfg.RetentionPolicy)
}
