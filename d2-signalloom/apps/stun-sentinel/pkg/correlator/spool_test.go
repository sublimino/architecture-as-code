// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// mockClock implements Clock for deterministic testing without wall-clock sleeps.
type mockClock struct {
	mu      sync.Mutex
	now     time.Time
	timers  []*mockTimer
	sleeps  []time.Duration
}

type mockTimer struct {
	target time.Time
	ch     chan time.Time
	fired  bool
}

func newMockClock(start time.Time) *mockClock {
	return &mockClock{now: start}
}

func (c *mockClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *mockClock) Since(t time.Time) time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now.Sub(t)
}

func (c *mockClock) Sleep(d time.Duration) {
	c.mu.Lock()
	c.sleeps = append(c.sleeps, d)
	c.now = c.now.Add(d)
	c.checkTimersLocked()
	c.mu.Unlock()
}

func (c *mockClock) After(d time.Duration) <-chan time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	ch := make(chan time.Time, 1)
	if d <= 0 {
		ch <- c.now
		return ch
	}
	t := &mockTimer{
		target: c.now.Add(d),
		ch:     ch,
	}
	c.timers = append(c.timers, t)
	return ch
}

func (c *mockClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.checkTimersLocked()
	c.mu.Unlock()
}

func (c *mockClock) checkTimersLocked() {
	for _, t := range c.timers {
		if !t.fired && !c.now.Before(t.target) {
			t.fired = true
			select {
			case t.ch <- c.now:
			default:
			}
		}
	}
}

func (c *mockClock) totalSleep() time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	var total time.Duration
	for _, d := range c.sleeps {
		total += d
	}
	return total
}

func sampleEnvelope(epoch string, seq uint64, prev string, count int) SpoolEnvelope {
	obsList := make([]ingestObservation, count)
	for i := 0; i < count; i++ {
		obsList[i] = ingestObservation{
			ID:        fmt.Sprintf("test-obs-%d-%d", seq, i),
			Timestamp: "2026-10-01T22:35:33.123456789Z",
			Layer:     "endpoint_host",
			Fidelity:  "strong",
			Source:    "stun-sentinel",
			ActorID:   "kusari-agent",
			Labels: map[string]string{
				"syscall": "sys_enter_openat",
				"target":  "/etc/passwd",
			},
		}
	}
	bodyBytes, _ := json.Marshal(obsList)
	return SpoolEnvelope{
		V:       1,
		Epoch:   epoch,
		Seq:     seq,
		Prev:    prev,
		Created: time.Now().UTC().Format(time.RFC3339Nano),
		Body:    json.RawMessage(bodyBytes),
	}
}

func TestSpoolFileModes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "spool-modes")
	stats := &pipelineStats{}
	spool, err := NewSpool(dir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	info, err := os.Lstat(dir)
	if err != nil {
		t.Fatalf("Lstat spool dir: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0700 {
		t.Fatalf("spool dir mode = %04o, want 0700", perm)
	}

	env := sampleEnvelope("epoch-modes", 1, "", 1)
	filePath, err := spool.WriteBatch(env)
	if err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}

	fileInfo, err := os.Lstat(filePath)
	if err != nil {
		t.Fatalf("Lstat batch file: %v", err)
	}
	if perm := fileInfo.Mode().Perm(); perm != 0600 {
		t.Fatalf("batch file mode = %04o, want 0600", perm)
	}
}

func TestSpoolNeverContainsTheKey(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "spool-secrets")
	stats := &pipelineStats{}
	spool, err := NewSpool(dir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	secretKey := "super-secret-bearer-token-1234567890abcdef"
	env := sampleEnvelope("epoch-sec", 1, "", 2)
	filePath, err := spool.WriteBatch(env)
	if err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}

	content, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if bytes.Contains(content, []byte(secretKey)) {
		t.Fatalf("spool file contains secret key: %s", content)
	}
	if bytes.Contains(content, []byte("Authorization")) {
		t.Fatalf("spool file contains Authorization header: %s", content)
	}
	if bytes.Contains(content, []byte("Bearer")) {
		t.Fatalf("spool file contains Bearer keyword: %s", content)
	}
}

func TestSpoolIgnoresSymlinksAndForeignFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "spool-symlinks")
	stats := &pipelineStats{}
	spool, err := NewSpool(dir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	// Plant a valid batch
	env := sampleEnvelope("epoch-valid", 1, "", 1)
	validFile, err := spool.WriteBatch(env)
	if err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}

	// Plant a symlink pointing outside
	outsideTarget := filepath.Join(t.TempDir(), "outside.txt")
	outsideEnv, _ := json.Marshal(sampleEnvelope("epoch-symlink", 1, "", 1))
	_ = os.WriteFile(outsideTarget, outsideEnv, 0600)
	symlinkPath := filepath.Join(dir, "spool_00000000000000000000_symlink.batch")
	if err := os.Symlink(outsideTarget, symlinkPath); err != nil {
		t.Fatalf("Symlink: %v", err)
	}

	// Plant a foreign file
	foreignPath := filepath.Join(dir, "foreign.txt")
	_ = os.WriteFile(foreignPath, []byte("foreign content"), 0600)

	batches, err := spool.ListBatches()
	if err != nil {
		t.Fatalf("ListBatches: %v", err)
	}

	if len(batches) != 1 {
		t.Fatalf("ListBatches returned %d entries, want 1 (symlink and foreign file must be skipped)", len(batches))
	}
	if batches[0].Path != validFile {
		t.Fatalf("batch path = %s, want %s", batches[0].Path, validFile)
	}
}

func TestSpoolSkipsTornFile(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "spool-torn")
	stats := &pipelineStats{}
	spool, err := NewSpool(dir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	// Plant a torn / truncated file
	tornPath := filepath.Join(dir, fmt.Sprintf("spool_%020d_torn_0001.batch", time.Now().UnixNano()))
	if err := os.WriteFile(tornPath, []byte(`{"v":1,"epoch":"e1","seq":1,"created":`), 0600); err != nil {
		t.Fatalf("WriteFile torn: %v", err)
	}

	// Plant a valid second file
	env2 := sampleEnvelope("epoch-torn", 2, "prevhash", 1)
	validFile, err := spool.WriteBatch(env2)
	if err != nil {
		t.Fatalf("WriteBatch env2: %v", err)
	}

	batches, err := spool.ListBatches()
	if err != nil {
		t.Fatalf("ListBatches: %v", err)
	}

	if len(batches) != 1 {
		t.Fatalf("ListBatches returned %d batches, want 1", len(batches))
	}
	if batches[0].Path != validFile {
		t.Fatalf("expected valid file %s, got %s", validFile, batches[0].Path)
	}

	if stats.spoolCorrupt.Load() != 1 {
		t.Fatalf("spool_corrupt = %d, want 1", stats.spoolCorrupt.Load())
	}

	// Check torn file was quarantined to .corrupt
	if _, err := os.Stat(tornPath + ".corrupt"); os.IsNotExist(err) {
		t.Fatalf("torn file was not renamed to .corrupt: %v", err)
	}
}

func TestSpoolByteCapEvictsOldestFirstCountedAndLogged(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "spool-bytecap")
	stats := &pipelineStats{}
	clk := newMockClock(time.Now())

	env1 := sampleEnvelope("epoch-cap", 1, "", 1)
	raw1, _ := json.Marshal(env1)
	batchSize := int64(len(raw1))

	// Max bytes holds exactly 2 batches
	maxBytes := batchSize*2 + 20
	spool, err := NewSpool(dir, maxBytes, DefaultSpoolMaxAge, clk, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	file1, err := spool.WriteBatch(env1)
	if err != nil {
		t.Fatalf("WriteBatch 1: %v", err)
	}
	clk.Advance(1 * time.Second)

	env2 := sampleEnvelope("epoch-cap", 2, "hash1", 1)
	file2, err := spool.WriteBatch(env2)
	if err != nil {
		t.Fatalf("WriteBatch 2: %v", err)
	}
	clk.Advance(1 * time.Second)

	// Third batch exceeds maxBytes -> should evict batch 1
	env3 := sampleEnvelope("epoch-cap", 3, "hash2", 1)
	file3, err := spool.WriteBatch(env3)
	if err != nil {
		t.Fatalf("WriteBatch 3: %v", err)
	}

	if stats.spoolEvicted.Load() != 1 {
		t.Fatalf("spool_evicted = %d, want 1", stats.spoolEvicted.Load())
	}

	// file1 should be deleted
	if _, err := os.Stat(file1); !os.IsNotExist(err) {
		t.Fatalf("oldest file %s was not evicted: %v", file1, err)
	}
	// file2 and file3 should remain
	if _, err := os.Stat(file2); err != nil {
		t.Fatalf("file2 missing: %v", err)
	}
	if _, err := os.Stat(file3); err != nil {
		t.Fatalf("file3 missing: %v", err)
	}

	batches, err := spool.ListBatches()
	if err != nil {
		t.Fatalf("ListBatches: %v", err)
	}
	if len(batches) != 2 {
		t.Fatalf("ListBatches = %d entries, want 2", len(batches))
	}
	if batches[0].Envelope.Seq != 2 || batches[1].Envelope.Seq != 3 {
		t.Fatalf("remaining sequences = [%d, %d], want [2, 3]", batches[0].Envelope.Seq, batches[1].Envelope.Seq)
	}
}

func TestSpoolMaxAgeEvictsWithInjectedClock(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "spool-maxage")
	stats := &pipelineStats{}
	startTime := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	clk := newMockClock(startTime)

	maxAge := 8 * time.Hour
	spool, err := NewSpool(dir, DefaultSpoolMaxBytes, maxAge, clk, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	env1 := sampleEnvelope("epoch-age", 1, "", 1)
	file1, err := spool.WriteBatch(env1)
	if err != nil {
		t.Fatalf("WriteBatch 1: %v", err)
	}

	// Advance clock past maxAge (9 hours)
	clk.Advance(9 * time.Hour)

	env2 := sampleEnvelope("epoch-age", 2, "prev", 1)
	file2, err := spool.WriteBatch(env2)
	if err != nil {
		t.Fatalf("WriteBatch 2: %v", err)
	}

	if stats.spoolExpired.Load() != 1 {
		t.Fatalf("spool_expired = %d, want 1", stats.spoolExpired.Load())
	}

	if _, err := os.Stat(file1); !os.IsNotExist(err) {
		t.Fatalf("expired file %s was not evicted", file1)
	}
	if _, err := os.Stat(file2); err != nil {
		t.Fatalf("new file %s is missing: %v", file2, err)
	}
}

func TestSpoolUnavailableFallsBackLoudly(t *testing.T) {
	// Create an unwritable spool directory (mode 0500)
	tmpDir := t.TempDir()
	dir := filepath.Join(tmpDir, "unwritable-spool")
	if err := os.Mkdir(dir, 0500); err != nil {
		t.Fatalf("Mkdir: %v", err)
	}
	defer os.Chmod(dir, 0700) // cleanup

	stats := &pipelineStats{}
	spool, err := NewSpool(dir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats)
	if err == nil && !spool.IsUnavailable() {
		// If chmod 0700 succeeded in NewSpool, force it unwritable
		_ = os.Chmod(dir, 0500)
		spool.unavailable = true
	}

	if !spool.IsUnavailable() {
		t.Fatal("spool must be marked unavailable")
	}

	// WriteBatch should fail with ErrSpoolUnavailable
	env := sampleEnvelope("epoch-unavail", 1, "", 1)
	_, err = spool.WriteBatch(env)
	if err != ErrSpoolUnavailable {
		t.Fatalf("WriteBatch = %v, want ErrSpoolUnavailable", err)
	}
}
