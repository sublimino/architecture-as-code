// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// DefaultDiskRingCapacity bounds the number of unacknowledged objects held on disk.
const DefaultDiskRingCapacity = 10000

// DefaultCompactThresholdBytes is how much dead space the WAL tolerates before it is
// rewritten. Compaction is what stops a long-running collector filling its volume
// with frames it has already drained.
const DefaultCompactThresholdBytes int64 = 1 << 20 // 1 MiB

const walFileName = "telemetry_ring.wal"

// diskRingMagic is the WAL header. Version 2: length-prefixed JSON frames, each one
// a complete LogRecord, which is what makes replay on open possible at all. V1 wrote
// a bare payload with no record envelope and could not be read back.
var diskRingMagic = []byte("SLRBV2\x00\x00")

// frameHeaderLen is the size of the per-frame length prefix.
const frameHeaderLen = 4

// maxFrameLen caps a single frame so a corrupt length prefix cannot make replay
// allocate unboundedly.
const maxFrameLen = 64 << 20 // 64 MiB

// ErrRingClosed is returned by Push and Pop after Close.
var ErrRingClosed = errors.New("awslogs: disk ring buffer is closed")

// Sink is the subset of collectors.IngestionSink this package needs. It is declared
// here rather than imported so collectors can register awslogs without an import
// cycle, exactly as gcpaudit and baoaudit do.
type Sink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// LogRecord is one buffered S3 object: the raw bytes, where they came from, and the
// SQS receipt handle that acknowledges them.
//
// The record carries the raw object rather than projected observations on purpose.
// Projection happens after the buffer, so a replayed record is re-projected by the
// current code and a projection fix applies to the backlog too.
type LogRecord struct {
	SequenceID    uint64    `json:"sequence_id"`
	Timestamp     time.Time `json:"timestamp"`
	TenantID      string    `json:"tenant_id"`
	Bucket        string    `json:"bucket"`
	Key           string    `json:"key"`
	ReceiptHandle string    `json:"receipt_handle"`
	Payload       []byte    `json:"payload"`
}

// Origin returns the evidence origin for this record's payload.
func (r LogRecord) Origin() Origin {
	return Origin{Bucket: r.Bucket, Key: r.Key}
}

// Object returns the object locator without a record index, used as the evidence ref
// of an eviction: what was lost is the whole object, and it is still in S3.
func (r LogRecord) Object() string {
	if r.Bucket == "" {
		return r.Key
	}
	return fmt.Sprintf("s3://%s/%s", r.Bucket, r.Key)
}

// frame is the index entry for a live record in the WAL.
type frame struct {
	offset int64
	length int64 // frame header + body
	seq    uint64
}

// DiskRingBuffer is a bounded, crash-resilient FIFO on disk.
//
// Guarantees, each covered by a test in diskring_test.go:
//
//   - Pop returns what Push stored, in order (the v1 Pop fabricated records).
//   - Push fsyncs before returning, so a pushed record survives a crash. The whole
//     ack ordering rests on this: SQS delete is only safe because the record is
//     already durable here and past the sink.
//   - Records replay on open, including over a torn tail frame from a crash
//     mid-write.
//   - Capacity is a hard bound. At capacity the oldest record is evicted, the
//     counter increments, and the loss is emitted as an observation — §2.1 requires
//     that eviction is never silent.
//   - The WAL is compacted, so drained frames are reclaimed and the file does not
//     grow without bound.
//
// It guarantees nothing past the sink, which is why the acknowledgement point is
// after the sink and not here.
type DiskRingBuffer struct {
	mu       sync.Mutex
	notEmpty *sync.Cond

	dirPath  string
	walFile  *os.File
	capacity int

	live     []frame // live records, oldest first
	nextSeq  uint64
	writeOff int64
	deadByte int64

	compactThreshold int64
	compactions      atomic.Uint64
	syncs            atomic.Uint64
	dropped          atomic.Uint64

	evictionSink   Sink
	evictionTenant string

	closed bool
}

// RingOption configures a DiskRingBuffer.
type RingOption func(*DiskRingBuffer)

// WithEvictionSink makes eviction observable: every drop-oldest emits an observation
// into sink. Without it, eviction is still counted but only a metric reader sees it.
func WithEvictionSink(sink Sink) RingOption {
	return func(rb *DiskRingBuffer) { rb.evictionSink = sink }
}

// WithEvictionTenant sets the tenant_id stamped on eviction observations.
func WithEvictionTenant(tenantID string) RingOption {
	return func(rb *DiskRingBuffer) { rb.evictionTenant = tenantID }
}

// WithCompactThreshold overrides how much dead space the WAL tolerates.
func WithCompactThreshold(bytes int64) RingOption {
	return func(rb *DiskRingBuffer) {
		if bytes > 0 {
			rb.compactThreshold = bytes
		}
	}
}

// NewDiskRingBuffer opens or recovers a ring buffer at dirPath. Any records left in
// the WAL by a previous process are replayed into the index before it returns.
func NewDiskRingBuffer(dirPath string, capacity int, opts ...RingOption) (*DiskRingBuffer, error) {
	if capacity <= 0 {
		capacity = DefaultDiskRingCapacity
	}
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		return nil, fmt.Errorf("awslogs: creating ring directory %s: %w", dirPath, err)
	}

	f, err := os.OpenFile(filepath.Join(dirPath, walFileName), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("awslogs: opening WAL: %w", err)
	}

	rb := &DiskRingBuffer{
		dirPath:          dirPath,
		walFile:          f,
		capacity:         capacity,
		compactThreshold: DefaultCompactThresholdBytes,
	}
	rb.notEmpty = sync.NewCond(&rb.mu)
	for _, opt := range opts {
		opt(rb)
	}

	if err := rb.replay(); err != nil {
		f.Close()
		return nil, err
	}
	return rb, nil
}

// replay rebuilds the live index from the WAL. A frame whose header or body is short
// is a crash mid-write: the file is truncated at that point and the earlier records
// are kept, because losing the whole buffer to one torn frame would be a far worse
// failure than losing the frame that was never acknowledged anyway.
func (rb *DiskRingBuffer) replay() error {
	fi, err := rb.walFile.Stat()
	if err != nil {
		return fmt.Errorf("awslogs: stat WAL: %w", err)
	}

	header := int64(len(diskRingMagic))
	if fi.Size() == 0 {
		if _, err := rb.walFile.Write(diskRingMagic); err != nil {
			return fmt.Errorf("awslogs: writing WAL header: %w", err)
		}
		if err := rb.walFile.Sync(); err != nil {
			return fmt.Errorf("awslogs: syncing WAL header: %w", err)
		}
		rb.writeOff = header
		return nil
	}

	got := make([]byte, header)
	if _, err := rb.walFile.ReadAt(got, 0); err != nil {
		return fmt.Errorf("awslogs: reading WAL header: %w", err)
	}
	if string(got) != string(diskRingMagic) {
		return fmt.Errorf("awslogs: WAL at %s has magic %q, want %q (incompatible or corrupt)", rb.dirPath, got, diskRingMagic)
	}

	offset := header
	lenBuf := make([]byte, frameHeaderLen)
	for offset < fi.Size() {
		if _, err := rb.walFile.ReadAt(lenBuf, offset); err != nil {
			break // torn length prefix
		}
		bodyLen := int64(binary.BigEndian.Uint32(lenBuf))
		if bodyLen <= 0 || bodyLen > maxFrameLen {
			break // corrupt prefix
		}
		if offset+frameHeaderLen+bodyLen > fi.Size() {
			break // torn body
		}

		body := make([]byte, bodyLen)
		if _, err := rb.walFile.ReadAt(body, offset+frameHeaderLen); err != nil {
			break
		}
		var rec LogRecord
		if err := json.Unmarshal(body, &rec); err != nil {
			break // a frame we cannot decode ends the readable region
		}

		rb.live = append(rb.live, frame{offset: offset, length: frameHeaderLen + bodyLen, seq: rec.SequenceID})
		if rec.SequenceID >= rb.nextSeq {
			rb.nextSeq = rec.SequenceID + 1
		}
		offset += frameHeaderLen + bodyLen
	}

	if offset < fi.Size() {
		if err := rb.walFile.Truncate(offset); err != nil {
			return fmt.Errorf("awslogs: truncating torn WAL tail at %d: %w", offset, err)
		}
	}
	rb.writeOff = offset

	// A replayed buffer can exceed a capacity that was lowered between runs. Trim
	// the oldest down to the bound rather than silently honouring the old one.
	for len(rb.live) > rb.capacity {
		rb.deadByte += rb.live[0].length
		rb.live = rb.live[1:]
		rb.dropped.Add(1)
	}
	return nil
}

// Push appends a record and fsyncs. At capacity the oldest record is evicted first;
// the newest is always accepted, because the freshest telemetry is the most worth
// evaluating. An error from the eviction sink is returned to the caller — the record
// is still buffered and the eviction still counted, but the caller must know the
// loss notification did not land.
func (rb *DiskRingBuffer) Push(ctx context.Context, record *LogRecord) error {
	if record == nil {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	rb.mu.Lock()
	if rb.closed {
		rb.mu.Unlock()
		return ErrRingClosed
	}

	record.SequenceID = rb.nextSeq
	rb.nextSeq++

	body, err := json.Marshal(record)
	if err != nil {
		rb.mu.Unlock()
		return fmt.Errorf("awslogs: encoding record %d: %w", record.SequenceID, err)
	}

	buf := make([]byte, frameHeaderLen+len(body))
	binary.BigEndian.PutUint32(buf[:frameHeaderLen], uint32(len(body)))
	copy(buf[frameHeaderLen:], body)

	if _, err := rb.walFile.WriteAt(buf, rb.writeOff); err != nil {
		rb.mu.Unlock()
		return fmt.Errorf("awslogs: writing record %d to WAL: %w", record.SequenceID, err)
	}
	// fsync before the record is visible to a reader: a record the caller believes is
	// buffered but that is only in the page cache would make the ack ordering a lie.
	if err := rb.walFile.Sync(); err != nil {
		rb.mu.Unlock()
		return fmt.Errorf("awslogs: syncing record %d: %w", record.SequenceID, err)
	}
	rb.syncs.Add(1)

	rb.live = append(rb.live, frame{offset: rb.writeOff, length: int64(len(buf)), seq: record.SequenceID})
	rb.writeOff += int64(len(buf))

	var evicted *LogRecord
	var evictedTotal uint64
	if len(rb.live) > rb.capacity {
		oldest := rb.live[0]
		if rec, err := rb.readFrameLocked(oldest); err == nil {
			evicted = rec
		} else {
			// The frame is unreadable, so there is nothing to describe the loss with
			// beyond the fact of it. Synthesise the minimum so the count still moves.
			evicted = &LogRecord{Timestamp: record.Timestamp, TenantID: rb.evictionTenant}
		}
		rb.deadByte += oldest.length
		rb.live = rb.live[1:]
		evictedTotal = rb.dropped.Add(1)
	}

	if err := rb.maybeCompactLocked(); err != nil {
		rb.mu.Unlock()
		return err
	}

	rb.notEmpty.Signal()
	sink := rb.evictionSink
	tenant := rb.evictionTenant
	rb.mu.Unlock()

	// Emitted outside the lock: the sink is downstream code and may be slow or may
	// call back, and holding the ring's mutex across it would be a deadlock waiting
	// for a reason.
	if evicted != nil && sink != nil {
		obs := evictionObservation(*evicted, tenant, evictedTotal)
		if err := sink.IngestObservation(ctx, &obs); err != nil {
			return fmt.Errorf("awslogs: buffer evicted record %d but the eviction observation could not be delivered: %w", evicted.SequenceID, err)
		}
	}
	return nil
}

// Pop removes and returns the oldest record, blocking until one is available, the
// ring is closed, or ctx is done.
func (rb *DiskRingBuffer) Pop(ctx context.Context) (*LogRecord, error) {
	// A watcher wakes the condition variable on cancellation, since sync.Cond has no
	// context-aware Wait.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		select {
		case <-ctx.Done():
			rb.mu.Lock()
			rb.notEmpty.Broadcast()
			rb.mu.Unlock()
		case <-stop:
		}
	}()

	rb.mu.Lock()
	defer rb.mu.Unlock()

	for len(rb.live) == 0 && !rb.closed && ctx.Err() == nil {
		rb.notEmpty.Wait()
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if len(rb.live) == 0 {
		if rb.closed {
			return nil, ErrRingClosed
		}
		return nil, io.EOF
	}
	return rb.popOldestLocked()
}

// TryPop removes and returns the oldest record without blocking. The second result
// is false when the ring is empty.
func (rb *DiskRingBuffer) TryPop() (*LogRecord, bool, error) {
	rb.mu.Lock()
	defer rb.mu.Unlock()

	if rb.closed {
		return nil, false, ErrRingClosed
	}
	if len(rb.live) == 0 {
		return nil, false, nil
	}
	rec, err := rb.popOldestLocked()
	if err != nil {
		return nil, false, err
	}
	return rec, true, nil
}

// Peek returns the oldest record WITHOUT removing it. The second result is false when
// the ring is empty.
//
// Peek/Commit is the pair the acknowledgement ordering is built on, and it is why the
// collector does not use Pop. The sequence has to be: durable in the WAL, then past
// the sink, then acknowledged to SQS, and only then released from the buffer. A Pop
// that removed the record first would mean a sink failure silently dropped a record
// that SQS still believes was delivered — buffered, unacknowledged and gone.
func (rb *DiskRingBuffer) Peek() (*LogRecord, bool, error) {
	rb.mu.Lock()
	defer rb.mu.Unlock()

	if rb.closed {
		return nil, false, ErrRingClosed
	}
	if len(rb.live) == 0 {
		return nil, false, nil
	}
	rec, err := rb.readFrameLocked(rb.live[0])
	if err != nil {
		return nil, false, err
	}
	return rec, true, nil
}

// Commit releases the oldest record, which the caller has acknowledged downstream.
// It is a no-op on an empty ring.
func (rb *DiskRingBuffer) Commit() error {
	rb.mu.Lock()
	defer rb.mu.Unlock()

	if rb.closed {
		return ErrRingClosed
	}
	if len(rb.live) == 0 {
		return nil
	}
	rb.deadByte += rb.live[0].length
	rb.live = rb.live[1:]
	return rb.maybeCompactLocked()
}

func (rb *DiskRingBuffer) popOldestLocked() (*LogRecord, error) {
	oldest := rb.live[0]
	rec, err := rb.readFrameLocked(oldest)
	if err != nil {
		// Drop the unreadable frame rather than wedging the queue on it for ever.
		rb.deadByte += oldest.length
		rb.live = rb.live[1:]
		return nil, err
	}

	rb.deadByte += oldest.length
	rb.live = rb.live[1:]
	if err := rb.maybeCompactLocked(); err != nil {
		return rec, err
	}
	return rec, nil
}

func (rb *DiskRingBuffer) readFrameLocked(fr frame) (*LogRecord, error) {
	body := make([]byte, fr.length-frameHeaderLen)
	if _, err := rb.walFile.ReadAt(body, fr.offset+frameHeaderLen); err != nil {
		return nil, fmt.Errorf("awslogs: reading frame at offset %d: %w", fr.offset, err)
	}
	var rec LogRecord
	if err := json.Unmarshal(body, &rec); err != nil {
		return nil, fmt.Errorf("awslogs: decoding frame at offset %d: %w", fr.offset, err)
	}
	return &rec, nil
}

// maybeCompactLocked rewrites the WAL with only the live frames once dead space has
// grown past the threshold. Called with rb.mu held.
func (rb *DiskRingBuffer) maybeCompactLocked() error {
	if rb.deadByte < rb.compactThreshold {
		return nil
	}
	return rb.compactLocked()
}

// compactLocked writes the live frames to a temporary file, fsyncs it, and renames it
// over the WAL. The rename is atomic, so a crash during compaction leaves either the
// old complete WAL or the new complete one, never a half-rewritten file.
func (rb *DiskRingBuffer) compactLocked() error {
	tmpPath := filepath.Join(rb.dirPath, walFileName+".compact")
	tmp, err := os.OpenFile(tmpPath, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("awslogs: opening compaction temp file: %w", err)
	}
	cleanup := func() {
		tmp.Close()
		os.Remove(tmpPath)
	}

	if _, err := tmp.Write(diskRingMagic); err != nil {
		cleanup()
		return fmt.Errorf("awslogs: writing compacted header: %w", err)
	}

	offset := int64(len(diskRingMagic))
	rebuilt := make([]frame, 0, len(rb.live))
	for _, fr := range rb.live {
		raw := make([]byte, fr.length)
		if _, err := rb.walFile.ReadAt(raw, fr.offset); err != nil {
			cleanup()
			return fmt.Errorf("awslogs: reading frame at %d during compaction: %w", fr.offset, err)
		}
		if _, err := tmp.WriteAt(raw, offset); err != nil {
			cleanup()
			return fmt.Errorf("awslogs: writing frame during compaction: %w", err)
		}
		rebuilt = append(rebuilt, frame{offset: offset, length: fr.length, seq: fr.seq})
		offset += fr.length
	}

	if err := tmp.Sync(); err != nil {
		cleanup()
		return fmt.Errorf("awslogs: syncing compacted WAL: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("awslogs: closing compacted WAL: %w", err)
	}
	if err := rb.walFile.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("awslogs: closing WAL before rename: %w", err)
	}
	walPath := filepath.Join(rb.dirPath, walFileName)
	if err := os.Rename(tmpPath, walPath); err != nil {
		return fmt.Errorf("awslogs: renaming compacted WAL: %w", err)
	}

	reopened, err := os.OpenFile(walPath, os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("awslogs: reopening compacted WAL: %w", err)
	}
	rb.walFile = reopened
	rb.live = rebuilt
	rb.writeOff = offset
	rb.deadByte = 0
	rb.compactions.Add(1)
	return nil
}

// Len returns the number of buffered, unacknowledged records.
func (rb *DiskRingBuffer) Len() int {
	rb.mu.Lock()
	defer rb.mu.Unlock()
	return len(rb.live)
}

// Dropped returns the cumulative number of evicted records.
func (rb *DiskRingBuffer) Dropped() uint64 { return rb.dropped.Load() }

// Syncs returns the number of fsyncs performed, so a test can assert that Push
// actually synced rather than merely wrote.
func (rb *DiskRingBuffer) Syncs() uint64 { return rb.syncs.Load() }

// Compactions returns the number of WAL rewrites.
func (rb *DiskRingBuffer) Compactions() uint64 { return rb.compactions.Load() }

// Close compacts the WAL down to the live records, then releases it and wakes any
// blocked Pop.
//
// The compaction is what makes a clean restart exact. A popped frame is not erased
// from the WAL at pop time — that would cost a second fsync per record — so without
// this, reopening would replay records that had already been drained. Compacting here
// means the file a clean shutdown leaves behind contains exactly the unacknowledged
// records, and Len() after reopen equals Len() before Close.
//
// After an UNCLEAN exit the delivery guarantee is at-least-once, not exactly-once:
// frames popped since the last compaction are still in the file and replay. That is
// deliberate and is the safe direction. SQS is itself at-least-once, Observation.ID is
// derived from the evidence ref so a re-projected record is byte-identical and
// deduplicable at the store, and §2.1 requires that a buffer loss always be replayable
// from S3. Duplicate delivery after a crash is recoverable; silent loss is not.
func (rb *DiskRingBuffer) Close() error {
	rb.mu.Lock()
	defer rb.mu.Unlock()

	if rb.closed {
		return nil
	}

	var compactErr error
	if rb.walFile != nil && rb.deadByte > 0 {
		compactErr = rb.compactLocked()
	}

	rb.closed = true
	rb.notEmpty.Broadcast()
	if rb.walFile != nil {
		if err := rb.walFile.Close(); err != nil {
			return fmt.Errorf("awslogs: closing WAL: %w", err)
		}
		rb.walFile = nil
	}
	if compactErr != nil {
		return fmt.Errorf("awslogs: compacting WAL on close: %w", compactErr)
	}
	return nil
}

// evictionObservation renders a drop-oldest as an observation under the aws:collector
// contract. Its Timestamp is the evicted record's, never time.Now(): an operational
// observation still has to be reproducible, and the record's buffered-at time is the
// only honest time available for an event whose subject is that record.
func evictionObservation(evicted LogRecord, tenantID string, cumulative uint64) model.Observation {
	if tenantID == "" {
		tenantID = evicted.TenantID
	}
	count := strconv.FormatUint(cumulative, 10)

	seed := fmt.Sprintf("awslogs:%s:%s:%s", TypeBufferEviction, tenantID, count)
	sum := sha256.Sum256([]byte(seed))

	ts := evicted.Timestamp
	if ts.IsZero() {
		// A record with no timestamp would fail Validate and take the sink down with
		// it. The epoch is wrong but visibly wrong, which beats an unstorable zero.
		ts = time.Unix(0, 0).UTC()
	}

	return model.Observation{
		ID:        hex.EncodeToString(sum[:]),
		Timestamp: ts.UTC(),
		Layer:     model.LayerCloudControlPlane,
		// The collector's own counter is the strongest evidence class there is: it is
		// not inferred from a payload, it is a fact about our own execution.
		Fidelity:       model.FidelityDefinitive,
		Source:         SourceCollector,
		Confidence:     1.0,
		RawEvidenceRef: evicted.Object(),
		Labels: map[string]string{
			LabelTenantID: tenantID,
			LabelProvider: ProviderAWS,
			LabelType:     TypeBufferEviction,
			LabelCount:    count,
		},
		Description: oneLine(fmt.Sprintf(
			"awslogs transport buffer evicted the oldest buffered object %s; cumulative evictions %s",
			evicted.Object(), count)),
	}
}
