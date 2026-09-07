// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"sync"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
)

// DefaultRingCapacity is the default number of in-flight flow events buffered
// between the Tetragon stream reader and the downstream flow processor.
//
// Sized at 4096: the card's acceptance burst is 1,000 simultaneous execve
// tracepoints, and a 4x headroom over the stated worst case means a burst is
// absorbed even when the consumer is mid-write to FrostDB. Raising this is
// cheap in memory (an InboundFlowEvent is ~300 bytes, so 4096 ≈ 1.2 MB) and the
// bound is the point — an unbounded queue on a kernel telemetry stream is a
// memory-exhaustion vector, which is why Push never grows the backing array.
const DefaultRingCapacity = 4096

// RingBuffer is a bounded circular buffer of flow events with an explicit,
// counted drop-oldest policy.
//
// # Why drop-oldest rather than drop-newest
//
// Under sustained overrun the newest events describe what the workload is doing
// NOW, which is what a containment decision needs. Dropping the oldest keeps the
// buffer's contents relevant. The alternative — refusing the write — would make
// the buffer a silent bottleneck on the kernel reader goroutine.
//
// # Why drops are counted, never silent
//
// A dropped telemetry event is a hole in the evidence chain. The existing
// netebpf gap detector synthesises a degraded-coverage observation from sequence
// discontinuities; that only works if drops are visible. Every drop increments
// tetragon_events_dropped_total.
type RingBuffer struct {
	mu       sync.Mutex
	notEmpty *sync.Cond

	buf    []*netebpf.InboundFlowEvent
	head   int // index of the oldest element
	length int

	dropped uint64
	closed  bool
}

// NewRingBuffer returns a ring buffer with the given capacity. A capacity of
// zero or less falls back to DefaultRingCapacity rather than producing a buffer
// that drops 100% of input — a zero-capacity ring would satisfy "bounded" while
// silently discarding the entire stream, which is the worst possible failure
// because every counter still moves.
func NewRingBuffer(capacity int) *RingBuffer {
	if capacity <= 0 {
		capacity = DefaultRingCapacity
	}
	rb := &RingBuffer{buf: make([]*netebpf.InboundFlowEvent, capacity)}
	rb.notEmpty = sync.NewCond(&rb.mu)
	return rb
}

// Capacity returns the fixed buffer size.
func (r *RingBuffer) Capacity() int { return len(r.buf) }

// Len returns the number of buffered events.
func (r *RingBuffer) Len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.length
}

// Dropped returns the cumulative count of events discarded by the drop policy.
func (r *RingBuffer) Dropped() uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.dropped
}

// Push appends an event. It returns true when the event was buffered without
// loss, and false when the buffer was full and the oldest event was evicted to
// make room. Push never blocks and never grows the backing array.
func (r *RingBuffer) Push(ev *netebpf.InboundFlowEvent) bool {
	if ev == nil {
		return true
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	if r.closed {
		return false
	}

	capacity := len(r.buf)
	evicted := false

	if r.length == capacity {
		// Full: evict the oldest by advancing head. length stays at capacity.
		r.head = (r.head + 1) % capacity
		r.length--
		r.dropped++
		evicted = true
	}

	tail := (r.head + r.length) % capacity
	r.buf[tail] = ev
	r.length++

	r.notEmpty.Signal()
	return !evicted
}

// Pop removes and returns the oldest event, blocking until one is available,
// the buffer is closed, or ctx is done.
//
// The ctx wakeup is delivered by a watchdog goroutine because sync.Cond has no
// context-aware Wait. Without it a consumer blocked on an idle stream would
// never observe cancellation and Close would hang.
func (r *RingBuffer) Pop(ctx context.Context) (*netebpf.InboundFlowEvent, bool) {
	done := make(chan struct{})
	defer close(done)

	go func() {
		select {
		case <-ctx.Done():
			r.mu.Lock()
			r.notEmpty.Broadcast()
			r.mu.Unlock()
		case <-done:
		}
	}()

	r.mu.Lock()
	defer r.mu.Unlock()

	for r.length == 0 && !r.closed && ctx.Err() == nil {
		r.notEmpty.Wait()
	}

	if r.length == 0 {
		return nil, false
	}

	ev := r.buf[r.head]
	r.buf[r.head] = nil
	r.head = (r.head + 1) % len(r.buf)
	r.length--
	return ev, true
}

// TryPop removes and returns the oldest event without blocking.
func (r *RingBuffer) TryPop() (*netebpf.InboundFlowEvent, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.length == 0 {
		return nil, false
	}

	ev := r.buf[r.head]
	r.buf[r.head] = nil
	r.head = (r.head + 1) % len(r.buf)
	r.length--
	return ev, true
}

// Close marks the buffer closed and wakes every blocked consumer. Buffered
// events remain drainable via TryPop so that a shutdown does not silently
// discard evidence already read off the kernel.
func (r *RingBuffer) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	r.notEmpty.Broadcast()
}
