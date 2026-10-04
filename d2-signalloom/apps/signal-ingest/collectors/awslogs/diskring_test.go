// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// recordingSink captures everything the ring emits so eviction observations are
// assertable rather than inferred.
type recordingSink struct {
	obs []model.Observation
	err error
}

func (s *recordingSink) IngestObservation(_ context.Context, o *model.Observation) error {
	if s.err != nil {
		return s.err
	}
	if o != nil {
		s.obs = append(s.obs, *o)
	}
	return nil
}

func testRecord(i int) *LogRecord {
	return &LogRecord{
		Timestamp:     time.Date(2026, 10, 2, 9, 0, i, 0, time.UTC),
		TenantID:      "kusari",
		Bucket:        "kusari-trail",
		Key:           fmt.Sprintf("AWSLogs/object-%03d.json", i),
		ReceiptHandle: fmt.Sprintf("rh-%03d", i),
		Payload:       []byte(fmt.Sprintf(`{"Records":[{"eventName":"Event%03d"}]}`, i)),
	}
}

func walPath(dir string) string { return filepath.Join(dir, walFileName) }

// --- round trip -------------------------------------------------------------

// TestDiskRing_PopReturnsWhatWasPushed is the test the old stub could not pass: its
// Pop fabricated a constant record and never read the WAL, so the buffer was a
// counter wearing a queue's clothes.
func TestDiskRing_PopReturnsWhatWasPushed(t *testing.T) {
	rb, err := NewDiskRingBuffer(t.TempDir(), 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	ctx := context.Background()
	for i := 0; i < 3; i++ {
		if err := rb.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
	}
	if got := rb.Len(); got != 3 {
		t.Fatalf("Len() = %d, want 3", got)
	}

	for i := 0; i < 3; i++ {
		got, err := rb.Pop(ctx)
		if err != nil {
			t.Fatalf("Pop(%d): %v", i, err)
		}
		want := testRecord(i)
		if got.Key != want.Key {
			t.Errorf("Pop(%d).Key = %q, want %q", i, got.Key, want.Key)
		}
		if got.Bucket != want.Bucket {
			t.Errorf("Pop(%d).Bucket = %q, want %q", i, got.Bucket, want.Bucket)
		}
		if got.ReceiptHandle != want.ReceiptHandle {
			t.Errorf("Pop(%d).ReceiptHandle = %q, want %q", i, got.ReceiptHandle, want.ReceiptHandle)
		}
		if string(got.Payload) != string(want.Payload) {
			t.Errorf("Pop(%d).Payload = %q, want %q", i, got.Payload, want.Payload)
		}
		if !got.Timestamp.Equal(want.Timestamp) {
			t.Errorf("Pop(%d).Timestamp = %s, want %s", i, got.Timestamp, want.Timestamp)
		}
		if got.SequenceID != uint64(i) {
			t.Errorf("Pop(%d).SequenceID = %d, want %d", i, got.SequenceID, i)
		}
	}

	if got := rb.Len(); got != 0 {
		t.Errorf("Len() after draining = %d, want 0", got)
	}
}

func TestDiskRing_PopIsFIFO(t *testing.T) {
	rb, err := NewDiskRingBuffer(t.TempDir(), 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	ctx := context.Background()
	for i := 0; i < 5; i++ {
		if err := rb.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
	}
	var keys []string
	for i := 0; i < 5; i++ {
		rec, err := rb.Pop(ctx)
		if err != nil {
			t.Fatalf("Pop: %v", err)
		}
		keys = append(keys, rec.Key)
	}
	for i, k := range keys {
		if want := testRecord(i).Key; k != want {
			t.Errorf("pop order position %d = %q, want %q", i, k, want)
		}
	}
}

func TestDiskRing_PopBlocksUntilPushAndRespectsContext(t *testing.T) {
	rb, err := NewDiskRingBuffer(t.TempDir(), 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := rb.Pop(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Pop on an empty ring: err = %v, want context.DeadlineExceeded", err)
	}

	popped := make(chan *LogRecord, 1)
	go func() {
		rec, err := rb.Pop(context.Background())
		if err != nil {
			popped <- nil
			return
		}
		popped <- rec
	}()
	time.Sleep(20 * time.Millisecond)
	if err := rb.Push(context.Background(), testRecord(7)); err != nil {
		t.Fatalf("Push: %v", err)
	}
	select {
	case rec := <-popped:
		if rec == nil || rec.Key != testRecord(7).Key {
			t.Fatalf("blocked Pop woke with %v, want record 7", rec)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("blocked Pop did not wake on Push")
	}
}

// --- durability -------------------------------------------------------------

// TestDiskRing_PushFsyncsBeforeReturning proves the durability claim the ack ordering
// rests on: the bytes are on the device before Push returns, so a record that has
// been pushed survives a crash and the SQS message can be safely deleted later.
func TestDiskRing_PushFsyncsBeforeReturning(t *testing.T) {
	dir := t.TempDir()
	rb, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	if got := rb.Syncs(); got != 0 {
		t.Fatalf("Syncs() before any push = %d, want 0", got)
	}
	if err := rb.Push(context.Background(), testRecord(0)); err != nil {
		t.Fatalf("Push: %v", err)
	}
	if got := rb.Syncs(); got != 1 {
		t.Errorf("Syncs() after one push = %d, want 1 (Push must fsync, not just write)", got)
	}

	// The frame is readable from the file by a second, independent reader before
	// anything else happened — which is what "durable" has to mean here.
	fi, err := os.Stat(walPath(dir))
	if err != nil {
		t.Fatalf("Stat WAL: %v", err)
	}
	if fi.Size() <= int64(len(diskRingMagic)) {
		t.Errorf("WAL size = %d, want more than the %d-byte header", fi.Size(), len(diskRingMagic))
	}
}

// TestDiskRing_ReplaysAfterReopen is the restart case: push, close, reopen, and the
// records are still there in order. The old stub never read the WAL back, so a
// restart silently lost everything buffered.
func TestDiskRing_ReplaysAfterReopen(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()

	first, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	for i := 0; i < 4; i++ {
		if err := first.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
	}
	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	second, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer second.Close()

	if got := second.Len(); got != 4 {
		t.Fatalf("Len() after reopen = %d, want 4 (replay on open)", got)
	}
	for i := 0; i < 4; i++ {
		rec, err := second.Pop(ctx)
		if err != nil {
			t.Fatalf("Pop(%d) after reopen: %v", i, err)
		}
		if want := testRecord(i); rec.Key != want.Key || string(rec.Payload) != string(want.Payload) {
			t.Errorf("Pop(%d) after reopen = %q/%q, want %q/%q", i, rec.Key, rec.Payload, want.Key, want.Payload)
		}
	}
}

// TestDiskRing_CleanCloseCompactsSoReopenIsExact pins the clean-shutdown guarantee:
// Close compacts, so a reopened ring holds exactly the records that were still
// unacknowledged and does not re-deliver drained ones.
func TestDiskRing_CleanCloseCompactsSoReopenIsExact(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()

	rb, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	for i := 0; i < 5; i++ {
		if err := rb.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
	}
	for i := 0; i < 3; i++ {
		if _, err := rb.Pop(ctx); err != nil {
			t.Fatalf("Pop(%d): %v", i, err)
		}
	}
	if got := rb.Len(); got != 2 {
		t.Fatalf("Len() before Close = %d, want 2", got)
	}
	if err := rb.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	reopened, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	if got := reopened.Len(); got != 2 {
		t.Fatalf("Len() after a clean close+reopen = %d, want 2 (drained records must not replay)", got)
	}
	for _, want := range []int{3, 4} {
		rec, err := reopened.Pop(ctx)
		if err != nil {
			t.Fatalf("Pop after reopen: %v", err)
		}
		if rec.Key != testRecord(want).Key {
			t.Errorf("survivor = %q, want %q", rec.Key, testRecord(want).Key)
		}
	}
}

// TestDiskRing_UncleanExitIsAtLeastOnceNotExactlyOnce documents the crash guarantee
// rather than leaving it to be discovered. A pop does not erase its frame — that would
// cost a second fsync per record — so a process that dies without closing replays
// records it had already drained. This asserts the duplicate, because the safe
// direction is re-delivery (deduplicable: Observation.ID is derived from the evidence
// ref) and not loss. If this test ever starts failing because reopen returns fewer
// records, the buffer has started losing data and that is the serious direction.
func TestDiskRing_UncleanExitIsAtLeastOnceNotExactlyOnce(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()

	rb, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	for i := 0; i < 4; i++ {
		if err := rb.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
	}
	if _, err := rb.Pop(ctx); err != nil {
		t.Fatalf("Pop: %v", err)
	}
	// No Close: the process is gone. The WAL is whatever Push fsynced.

	reopened, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("reopen after unclean exit: %v", err)
	}
	defer reopened.Close()

	if got := reopened.Len(); got < 3 {
		t.Fatalf("Len() after unclean exit = %d, want at least 3: the buffer LOST an unacknowledged record", got)
	} else if got != 4 {
		t.Errorf("Len() after unclean exit = %d, want 4 (documented at-least-once replay of the popped frame)", got)
	}
}

// TestDiskRing_ReplaySkipsAPartiallyWrittenTailFrame covers the crash-mid-write case:
// a torn final frame is discarded and the records before it still replay, rather than
// the whole buffer failing to open.
func TestDiskRing_ReplaySkipsAPartiallyWrittenTailFrame(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()

	rb, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	for i := 0; i < 3; i++ {
		if err := rb.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
	}
	if err := rb.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Simulate a crash partway through a fourth frame.
	f, err := os.OpenFile(walPath(dir), os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open WAL to append a torn frame: %v", err)
	}
	if _, err := f.Write([]byte{0x00, 0x00, 0x04, 0x00, 'j', 'u'}); err != nil {
		t.Fatalf("write torn frame: %v", err)
	}
	f.Close()

	reopened, err := NewDiskRingBuffer(dir, 16)
	if err != nil {
		t.Fatalf("reopen over a torn tail frame: %v", err)
	}
	defer reopened.Close()

	if got := reopened.Len(); got != 3 {
		t.Errorf("Len() = %d, want 3 (torn tail frame discarded, earlier records kept)", got)
	}
}

// --- bounded capacity and eviction -----------------------------------------

// TestDiskRing_DropsOldestAtCapacityAndCountsIt asserts the §2.1 claim that eviction
// is never silent: the oldest record goes, the counter increments, and the data loss
// is itself an observation in the sink.
func TestDiskRing_DropsOldestAtCapacityAndCountsIt(t *testing.T) {
	sink := &recordingSink{}
	rb, err := NewDiskRingBuffer(t.TempDir(), 3, WithEvictionSink(sink), WithEvictionTenant("kusari"))
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	ctx := context.Background()
	for i := 0; i < 5; i++ {
		if err := rb.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
	}

	if got := rb.Len(); got != 3 {
		t.Errorf("Len() = %d, want 3 (capacity is a bound, not a hint)", got)
	}
	if got := rb.Dropped(); got != 2 {
		t.Errorf("Dropped() = %d, want 2", got)
	}

	// Records 0 and 1 were evicted, so the survivors are 2, 3, 4 — drop-OLDEST, not
	// drop-newest, because the newest record is the one still worth evaluating.
	for _, want := range []int{2, 3, 4} {
		rec, err := rb.Pop(ctx)
		if err != nil {
			t.Fatalf("Pop: %v", err)
		}
		if rec.Key != testRecord(want).Key {
			t.Errorf("survivor = %q, want %q", rec.Key, testRecord(want).Key)
		}
	}

	if len(sink.obs) != 2 {
		t.Fatalf("sink received %d eviction observations, want 2", len(sink.obs))
	}
	for i, o := range sink.obs {
		if o.Source != SourceCollector {
			t.Errorf("eviction[%d] Source = %q, want %q", i, o.Source, SourceCollector)
		}
		if o.Labels[LabelType] != TypeBufferEviction {
			t.Errorf("eviction[%d] type = %q, want %q", i, o.Labels[LabelType], TypeBufferEviction)
		}
		if got, want := o.Labels[LabelCount], strconv.Itoa(i+1); got != want {
			t.Errorf("eviction[%d] count = %q, want %q (cumulative)", i, got, want)
		}
		if o.Labels[LabelTenantID] != "kusari" {
			t.Errorf("eviction[%d] tenant_id = %q, want kusari", i, o.Labels[LabelTenantID])
		}
		if o.ID == "" {
			t.Errorf("eviction[%d] has no ID", i)
		}
		if err := o.Validate(); err != nil {
			t.Errorf("eviction[%d] fails Validate: %v", i, err)
		}
		required, documented := ContractKeysFor(SourceCollector)
		for _, k := range required {
			if o.Labels[k] == "" {
				t.Errorf("eviction[%d] missing required label %q", i, k)
			}
		}
		for k := range o.Labels {
			if !contains(documented, k) {
				t.Errorf("eviction[%d] carries undocumented label %q", i, k)
			}
		}
	}
}

// TestDiskRing_EvictionSinkFailureDoesNotLoseTheRing proves the eviction emit cannot
// take the buffer down with it: a failing sink surfaces as an error but the ring is
// still usable and still correctly bounded.
func TestDiskRing_EvictionSinkFailureIsReportedNotSwallowed(t *testing.T) {
	sink := &recordingSink{err: errors.New("sink disk full")}
	rb, err := NewDiskRingBuffer(t.TempDir(), 1, WithEvictionSink(sink), WithEvictionTenant("kusari"))
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	ctx := context.Background()
	if err := rb.Push(ctx, testRecord(0)); err != nil {
		t.Fatalf("Push(0): %v", err)
	}
	err = rb.Push(ctx, testRecord(1))
	if err == nil {
		t.Fatal("Push that evicted a record reported nil while the eviction observation was lost")
	}
	if got := rb.Dropped(); got != 1 {
		t.Errorf("Dropped() = %d, want 1 (the eviction still happened)", got)
	}
	if got := rb.Len(); got != 1 {
		t.Errorf("Len() = %d, want 1 (the newest record was still accepted)", got)
	}
}

// --- compaction -------------------------------------------------------------

// TestDiskRing_CompactsSoTheWALDoesNotGrowUnbounded is the §8 defect: the old
// implementation appended for ever and never reclaimed a popped frame, so a
// long-running collector filled its volume.
func TestDiskRing_CompactsSoTheWALDoesNotGrowUnbounded(t *testing.T) {
	dir := t.TempDir()
	rb, err := NewDiskRingBuffer(dir, 8, WithCompactThreshold(8*1024))
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	ctx := context.Background()
	var totalPayload int
	for i := 0; i < 500; i++ {
		rec := testRecord(i)
		totalPayload += len(rec.Payload)
		if err := rb.Push(ctx, rec); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
		if _, err := rb.Pop(ctx); err != nil {
			t.Fatalf("Pop(%d): %v", i, err)
		}
	}

	fi, err := os.Stat(walPath(dir))
	if err != nil {
		t.Fatalf("Stat WAL: %v", err)
	}
	if fi.Size() > 32*1024 {
		t.Errorf("WAL is %d bytes after 500 push/pop cycles (%d bytes of payload written); compaction did not run", fi.Size(), totalPayload)
	}
	if rb.Compactions() == 0 {
		t.Error("Compactions() = 0 after 500 push/pop cycles")
	}
	if got := rb.Len(); got != 0 {
		t.Errorf("Len() = %d, want 0", got)
	}
}

// TestDiskRing_CompactionPreservesLiveRecords is the safety half of compaction: a
// rewrite that dropped or reordered an unacknowledged record would be silent data
// loss, so the surviving records are asserted by identity, not by count.
func TestDiskRing_CompactionPreservesLiveRecords(t *testing.T) {
	dir := t.TempDir()
	rb, err := NewDiskRingBuffer(dir, 64, WithCompactThreshold(1024))
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	ctx := context.Background()

	// Churn enough to force at least one compaction, leaving a known live tail.
	for i := 0; i < 100; i++ {
		if err := rb.Push(ctx, testRecord(i)); err != nil {
			t.Fatalf("Push(%d): %v", i, err)
		}
		if i >= 3 {
			if _, err := rb.Pop(ctx); err != nil {
				t.Fatalf("Pop: %v", err)
			}
		}
	}
	if rb.Compactions() == 0 {
		t.Fatal("no compaction ran; the rest of this test would be vacuous")
	}
	if got := rb.Len(); got != 3 {
		t.Fatalf("Len() = %d, want 3", got)
	}

	// Those three live records must survive a close and reopen, which is the only
	// way to prove compaction rewrote the file correctly rather than merely leaving
	// the in-memory index intact.
	if err := rb.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	reopened, err := NewDiskRingBuffer(dir, 64)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()

	if got := reopened.Len(); got != 3 {
		t.Fatalf("Len() after reopen = %d, want 3", got)
	}
	for _, want := range []int{97, 98, 99} {
		rec, err := reopened.Pop(ctx)
		if err != nil {
			t.Fatalf("Pop after reopen: %v", err)
		}
		if rec.Key != testRecord(want).Key {
			t.Errorf("survivor = %q, want %q", rec.Key, testRecord(want).Key)
		}
	}
}

// TestDiskRing_ConcurrentProducersAndConsumers exercises every mutating path at once
// — Push, Pop, eviction, compaction and the counters — so that `go test -race` has
// something to find. Note that -race cannot be run in the build sandbox this was
// written in (it requires cgo, and /usr/include is not readable there), so this test
// is the thing that makes the lead's unsandboxed -race run meaningful rather than
// vacuous: without concurrent access, a clean -race report proves nothing.
func TestDiskRing_ConcurrentProducersAndConsumers(t *testing.T) {
	sink := &concurrentSink{}
	rb, err := NewDiskRingBuffer(t.TempDir(), 8, WithEvictionSink(sink), WithEvictionTenant("kusari"), WithCompactThreshold(4*1024))
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	defer rb.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const producers, perProducer, consumers = 4, 50, 3

	var produced sync.WaitGroup
	for p := 0; p < producers; p++ {
		produced.Add(1)
		go func(p int) {
			defer produced.Done()
			for i := 0; i < perProducer; i++ {
				// An eviction error is expected under contention and is not a failure
				// here; losing the ring would be.
				_ = rb.Push(ctx, testRecord(p*perProducer+i))
			}
		}(p)
	}

	var consumed sync.WaitGroup
	stop := make(chan struct{})
	var popped atomic.Int64
	for c := 0; c < consumers; c++ {
		consumed.Add(1)
		go func() {
			defer consumed.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				rec, ok, err := rb.TryPop()
				if err != nil {
					return
				}
				if ok && rec != nil {
					popped.Add(1)
					continue
				}
				time.Sleep(time.Millisecond)
			}
		}()
	}

	produced.Wait()
	time.Sleep(100 * time.Millisecond)
	close(stop)
	consumed.Wait()

	total := int64(producers * perProducer)
	accounted := popped.Load() + int64(rb.Dropped()) + int64(rb.Len())
	if accounted != total {
		t.Errorf("accounted for %d records (popped %d + dropped %d + buffered %d), want %d: a record was neither delivered, evicted nor buffered",
			accounted, popped.Load(), rb.Dropped(), rb.Len(), total)
	}
	if rb.Len() > 8 {
		t.Errorf("Len() = %d under concurrent load, want at most the capacity 8", rb.Len())
	}
}

// concurrentSink counts without retaining, so the concurrency test does not measure
// its own memory growth.
type concurrentSink struct {
	count atomic.Int64
}

func (s *concurrentSink) IngestObservation(_ context.Context, _ *model.Observation) error {
	s.count.Add(1)
	return nil
}

func TestDiskRing_PushAfterCloseIsAnError(t *testing.T) {
	rb, err := NewDiskRingBuffer(t.TempDir(), 4)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer: %v", err)
	}
	if err := rb.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := rb.Push(context.Background(), testRecord(0)); err == nil {
		t.Error("Push on a closed ring returned nil error")
	}
}
