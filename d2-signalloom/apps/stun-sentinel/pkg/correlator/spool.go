// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Spool defaults per SLTM Phase 2 wire contract
const (
	DefaultSpoolDir                = "/var/lib/signalloom/spool"
	DefaultSpoolMaxBytes     int64 = 268435456 // 256 MiB
	DefaultSpoolMaxAge             = 8 * time.Hour
	spoolFilePrefix                = "spool_"
	spoolFileSuffix                = ".batch"
)

// ErrSpoolUnavailable indicates the spool directory cannot be used securely.
var ErrSpoolUnavailable = errors.New("spool_unavailable: directory has insecure permissions or invalid owner")

// SpoolEnvelope defines the persisted JSON schema for spooled batches.
type SpoolEnvelope struct {
	V       int             `json:"v"`
	Epoch   string          `json:"epoch"`
	Seq     uint64          `json:"seq"`
	Prev    string          `json:"prev"`
	Created string          `json:"created"`
	Body    json.RawMessage `json:"body"`
}

// SpoolEntry represents an on-disk batch envelope ready for replay.
type SpoolEntry struct {
	Path     string
	Envelope SpoolEnvelope
	Size     int64
}

// Spool manages crash-safe, ordered, bounded on-disk batch storage.
type Spool struct {
	dir                string
	maxBytes           int64
	maxAge             time.Duration
	clock              Clock
	stats              *pipelineStats
	unavailable        bool
	logUnavailableOnce sync.Once
	mu                 sync.Mutex
}

// NewSpool initializes and validates the on-node spool directory.
func NewSpool(dir string, maxBytes int64, maxAge time.Duration, clk Clock, stats *pipelineStats) (*Spool, error) {
	if dir == "" {
		dir = DefaultSpoolDir
	}
	if maxBytes <= 0 {
		maxBytes = DefaultSpoolMaxBytes
	}
	if maxAge <= 0 {
		maxAge = DefaultSpoolMaxAge
	}
	if clk == nil {
		clk = realClock{}
	}
	if stats == nil {
		stats = &pipelineStats{}
	}

	s := &Spool{
		dir:      dir,
		maxBytes: maxBytes,
		maxAge:   maxAge,
		clock:    clk,
		stats:    stats,
	}

	if err := s.ensureDir(); err != nil {
		s.unavailable = true
		return s, nil
	}

	// Update existing spool count and bytes in stats on start
	s.syncStats()
	return s, nil
}

func (s *Spool) IsUnavailable() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.unavailable
}

func (s *Spool) ensureDir() error {
	if err := os.MkdirAll(s.dir, 0700); err != nil {
		return fmt.Errorf("mkdir spool dir %s: %w", s.dir, err)
	}

	// Chmod directory to 0700 explicitly
	if err := os.Chmod(s.dir, 0700); err != nil {
		return fmt.Errorf("chmod spool dir %s: %w", s.dir, err)
	}

	info, err := os.Lstat(s.dir)
	if err != nil {
		return fmt.Errorf("lstat spool dir %s: %w", s.dir, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("spool path %s is not a directory", s.dir)
	}

	// Reject if group/world accessible
	if info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("spool dir %s has insecure mode %04o", s.dir, info.Mode().Perm())
	}

	// Check UID ownership on unix
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		euid := uint32(os.Geteuid())
		if euid != 0 && stat.Uid != euid {
			return fmt.Errorf("spool dir %s owned by uid %d, process running as uid %d", s.dir, stat.Uid, euid)
		}
	}

	return nil
}

// WriteBatch writes a new batch envelope atomically to the spool.
func (s *Spool) WriteBatch(env SpoolEnvelope) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.unavailable {
		s.logUnavailableOnce.Do(func() {
			logSpoolUnavailable(s.dir, errors.New("insecure permissions or unwritable"))
		})
		return "", ErrSpoolUnavailable
	}

	data, err := json.Marshal(env)
	if err != nil {
		return "", fmt.Errorf("marshal spool envelope: %w", err)
	}

	// 1. Evict expired and enforce byte bounds before writing
	s.pruneExpiredLocked()
	s.evictForSizeLocked(int64(len(data)))

	// 2. Generate random temp filename
	var randBytes [8]byte
	_, _ = rand.Read(randBytes[:])
	tmpName := fmt.Sprintf(".tmp-%s-%d-%s.batch", env.Epoch, env.Seq, hex.EncodeToString(randBytes[:]))
	tmpPath := filepath.Join(s.dir, tmpName)

	// 3. Write temp file with O_EXCL and 0600 permissions
	f, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return "", fmt.Errorf("create spool temp file: %w", err)
	}

	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("write spool data: %w", err)
	}

	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("fsync spool file: %w", err)
	}

	if err := f.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("close spool file: %w", err)
	}

	// 4. Atomic rename to order-sortable final filename
	nowNs := s.clock.Now().UTC().UnixNano()
	finalName := fmt.Sprintf("%s%020d_%s_%016x%s", spoolFilePrefix, nowNs, env.Epoch, env.Seq, spoolFileSuffix)
	finalPath := filepath.Join(s.dir, finalName)

	if err := os.Rename(tmpPath, finalPath); err != nil {
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("rename spool file: %w", err)
	}

	syncDir(s.dir)

	s.stats.spoolBatches.Add(1)
	s.stats.spoolBytes.Add(uint64(len(data)))

	return finalPath, nil
}

// ListBatches lists all valid spooled batches in FIFO order.
func (s *Spool) ListBatches() ([]SpoolEntry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.unavailable {
		return nil, nil
	}

	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, fmt.Errorf("read spool dir: %w", err)
	}

	var files []string
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".corrupt") {
			continue
		}
		if !strings.HasPrefix(name, spoolFilePrefix) || !strings.HasSuffix(name, spoolFileSuffix) {
			continue
		}
		files = append(files, name)
	}

	sort.Strings(files)

	var batches []SpoolEntry
	for _, name := range files {
		fullPath := filepath.Join(s.dir, name)
		info, err := os.Lstat(fullPath)
		if err != nil {
			continue
		}
		// Skip symlinks
		if info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		content, err := os.ReadFile(fullPath)
		if err != nil {
			s.quarantineFileLocked(fullPath)
			continue
		}

		var env SpoolEnvelope
		if err := json.Unmarshal(content, &env); err != nil || env.V == 0 || env.Epoch == "" || len(env.Body) == 0 {
			s.quarantineFileLocked(fullPath)
			continue
		}

		batches = append(batches, SpoolEntry{
			Path:     fullPath,
			Envelope: env,
			Size:     info.Size(),
		})
	}

	return batches, nil
}

// DeleteBatch removes a successfully processed spooled batch.
func (s *Spool) DeleteBatch(path string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	size := info.Size()
	if err := os.Remove(path); err != nil {
		return err
	}

	syncDir(s.dir)

	if s.stats.spoolBatches.Load() > 0 {
		s.stats.spoolBatches.Add(^uint64(0)) // decrement
	}
	if s.stats.spoolBytes.Load() >= uint64(size) {
		s.stats.spoolBytes.Add(^uint64(size - 1)) // decrement size
	} else {
		s.stats.spoolBytes.Store(0)
	}

	return nil
}

func (s *Spool) quarantineFileLocked(path string) {
	corruptPath := path + ".corrupt"
	_ = os.Rename(path, corruptPath)
	syncDir(s.dir)
	s.stats.spoolCorrupt.Add(1)
	logSpoolCorrupt(path)
}

func (s *Spool) pruneExpiredLocked() {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}

	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".corrupt") {
			continue
		}
		if !strings.HasPrefix(name, spoolFilePrefix) || !strings.HasSuffix(name, spoolFileSuffix) {
			continue
		}

		fullPath := filepath.Join(s.dir, name)
		info, err := os.Lstat(fullPath)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		// Extract timestampNs from filename: spool_<timestampNs>_<epoch>_<seq>.batch
		fileTime := info.ModTime()
		parts := strings.Split(name, "_")
		if len(parts) >= 4 {
			if ts, err := strconv.ParseInt(parts[1], 10, 64); err == nil {
				fileTime = time.Unix(0, ts)
			}
		}

		if s.clock.Since(fileTime) > s.maxAge {
			size := info.Size()
			if err := os.Remove(fullPath); err == nil {
				s.stats.spoolExpired.Add(1)
				if s.stats.spoolBatches.Load() > 0 {
					s.stats.spoolBatches.Add(^uint64(0))
				}
				if s.stats.spoolBytes.Load() >= uint64(size) {
					s.stats.spoolBytes.Add(^uint64(size - 1))
				}
				logSpoolEviction("expired", name, 1, size)
			}
		}
	}
	syncDir(s.dir)
}

func (s *Spool) evictForSizeLocked(incomingBytes int64) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}

	type fileInfo struct {
		name string
		path string
		size int64
	}

	var validFiles []fileInfo
	var totalBytes int64

	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".corrupt") {
			continue
		}
		if !strings.HasPrefix(name, spoolFilePrefix) || !strings.HasSuffix(name, spoolFileSuffix) {
			continue
		}

		fullPath := filepath.Join(s.dir, name)
		info, err := os.Lstat(fullPath)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		validFiles = append(validFiles, fileInfo{
			name: name,
			path: fullPath,
			size: info.Size(),
		})
		totalBytes += info.Size()
	}

	sort.Slice(validFiles, func(i, j int) bool {
		return validFiles[i].name < validFiles[j].name
	})

	for (totalBytes+incomingBytes) > s.maxBytes && len(validFiles) > 0 {
		oldest := validFiles[0]
		validFiles = validFiles[1:]

		if err := os.Remove(oldest.path); err == nil {
			totalBytes -= oldest.size
			s.stats.spoolEvicted.Add(1)
			if s.stats.spoolBatches.Load() > 0 {
				s.stats.spoolBatches.Add(^uint64(0))
			}
			if s.stats.spoolBytes.Load() >= uint64(oldest.size) {
				s.stats.spoolBytes.Add(^uint64(oldest.size - 1))
			}
			logSpoolEviction("size_cap_exceeded", oldest.name, 1, oldest.size)
		}
	}
	syncDir(s.dir)
}

func (s *Spool) syncStats() {
	s.mu.Lock()
	defer s.mu.Unlock()

	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}

	var count uint64
	var totalBytes uint64

	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".corrupt") {
			continue
		}
		if !strings.HasPrefix(name, spoolFilePrefix) || !strings.HasSuffix(name, spoolFileSuffix) {
			continue
		}
		fullPath := filepath.Join(s.dir, name)
		info, err := os.Lstat(fullPath)
		if err == nil && info.Mode()&os.ModeSymlink == 0 {
			count++
			totalBytes += uint64(info.Size())
		}
	}

	s.stats.spoolBatches.Store(count)
	s.stats.spoolBytes.Store(totalBytes)
}

func syncDir(dir string) {
	d, err := os.Open(dir)
	if err != nil {
		return
	}
	_ = d.Sync()
	_ = d.Close()
}

func logSpoolUnavailable(dir string, err error) {
	writeCorrelatorEvent(correlatorEvent{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Event:     "spool_unavailable",
		Error:     fmt.Sprintf("spool dir %s unavailable: %v", dir, err),
	})
}

func logSpoolCorrupt(path string) {
	writeCorrelatorEvent(correlatorEvent{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Event:     "spool_file_corrupt",
		Error:     fmt.Sprintf("quarantined corrupt spool file: %s", path),
	})
}

func logSpoolEviction(reason, filename string, count int, bytes int64) {
	writeCorrelatorEvent(correlatorEvent{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Event:     "spool_eviction",
		Error:     fmt.Sprintf("evicted %d spool batch (%d bytes, file %s) due to %s", count, bytes, filename, reason),
	})
}
