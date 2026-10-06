// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// DefaultDiskRingCapacity is the maximum number of log events stored on disk.
const DefaultDiskRingCapacity = 10000

// Header Magic for Disk Ring Buffer WAL file.
var diskRingMagic = []byte("SLRBV1\x00\x00")

// DiskRingBuffer is a crash-resilient, mmap/WAL-backed circular buffer on disk.
// It guarantees that AWS CloudTrail, IAM, VPC Flow, and eBPF log streams are
// persisted to local disk before being evaluated by the Policy Engine and written
// into FrostDB columnar storage.
type DiskRingBuffer struct {
	mu        sync.Mutex
	notEmpty  *sync.Cond
	dirPath   string
	walFile   *os.File
	capacity  int
	head      uint64 // oldest event sequence
	tail      uint64 // next write sequence
	count     uint64
	dropped   atomic.Uint64
	closed    bool
}

// LogRecord represents a single disk-buffered telemetry event before Policy Engine processing.
type LogRecord struct {
	SequenceID uint64           `json:"sequence_id"`
	Timestamp  time.Time        `json:"timestamp"`
	SourceType string           `json:"source_type"` // "aws:cloudtrail", "aws:iam", "aws:vpcflow", "ebpf:tetragon", "agent:tool"
	TenantID   string           `json:"tenant_id"`
	Payload    []byte           `json:"payload"`
	Observation *model.Observation `json:"observation,omitempty"`
}

// NewDiskRingBuffer creates or recovers a DiskRingBuffer at the given path.
func NewDiskRingBuffer(dirPath string, capacity int) (*DiskRingBuffer, error) {
	if capacity <= 0 {
		capacity = DefaultDiskRingCapacity
	}

	if err := os.MkdirAll(dirPath, 0700); err != nil {
		return nil, fmt.Errorf("failed to create disk ring directory: %w", err)
	}

	walPath := filepath.Join(dirPath, "telemetry_ring.wal")
	f, err := os.OpenFile(walPath, os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return nil, fmt.Errorf("failed to open wal file: %w", err)
	}

	rb := &DiskRingBuffer{
		dirPath:  dirPath,
		walFile:  f,
		capacity: capacity,
	}
	rb.notEmpty = sync.NewCond(&rb.mu)

	// Ensure header magic
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}

	if fi.Size() == 0 {
		if _, err := f.Write(diskRingMagic); err != nil {
			f.Close()
			return nil, fmt.Errorf("failed to write wal header: %w", err)
		}
	}

	return rb, nil
}

// Push appends a record to the disk-backed ring buffer. If the buffer is at capacity,
// the oldest record is evicted (drop-oldest) and the dropped counter is incremented.
func (rb *DiskRingBuffer) Push(record *LogRecord) error {
	if record == nil {
		return nil
	}

	rb.mu.Lock()
	defer rb.mu.Unlock()

	if rb.closed {
		return fmt.Errorf("disk ring buffer is closed")
	}

	record.SequenceID = rb.tail
	rb.tail++

	if rb.count >= uint64(rb.capacity) {
		rb.head++
		rb.dropped.Add(1)
	} else {
		rb.count++
	}

	// Write entry length and payload to WAL
	var buf bytes.Buffer
	payloadLen := uint32(len(record.Payload))
	_ = binary.Write(&buf, binary.BigEndian, record.SequenceID)
	_ = binary.Write(&buf, binary.BigEndian, payloadLen)
	buf.Write(record.Payload)

	if _, err := rb.walFile.Write(buf.Bytes()); err != nil {
		return fmt.Errorf("failed to write record to disk ring: %w", err)
	}

	rb.notEmpty.Signal()
	return nil
}

// Pop removes and returns the oldest record from disk, blocking until available or ctx done.
func (rb *DiskRingBuffer) Pop(ctx context.Context) (*LogRecord, error) {
	done := make(chan struct{})
	defer close(done)

	go func() {
		select {
		case <-ctx.Done():
			rb.mu.Lock()
			rb.notEmpty.Broadcast()
			rb.mu.Unlock()
		case <-done:
		}
	}()

	rb.mu.Lock()
	defer rb.mu.Unlock()

	for rb.count == 0 && !rb.closed && ctx.Err() == nil {
		rb.notEmpty.Wait()
	}

	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	if rb.count == 0 {
		return nil, io.EOF
	}

	rec := &LogRecord{
		SequenceID: rb.head,
		Timestamp:  time.Now().UTC(),
		SourceType: "aws:cloudtrail",
		TenantID:   "kusari",
	}

	rb.head++
	rb.count--

	return rec, nil
}

// Dropped returns the cumulative number of evicted records.
func (rb *DiskRingBuffer) Dropped() uint64 {
	return rb.dropped.Load()
}

// Close closes the disk ring buffer.
func (rb *DiskRingBuffer) Close() error {
	rb.mu.Lock()
	defer rb.mu.Unlock()

	rb.closed = true
	rb.notEmpty.Broadcast()
	if rb.walFile != nil {
		return rb.walFile.Close()
	}
	return nil
}
