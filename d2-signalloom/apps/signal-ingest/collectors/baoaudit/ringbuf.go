// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package baoaudit

import (
	"sync"
	"sync/atomic"
)

// DefaultRingBufferSize defines the maximum capacity of the bounded ring buffer (e.g. 16,384 slots).
const DefaultRingBufferSize = 16384

// AuditRingBuffer implements a high-throughput bounded circular ring buffer with atomic drop-tail telemetry.
type AuditRingBuffer struct {
	buffer     []*OpenBaoAuditEvent
	capacity   uint64
	writeIndex uint64
	readIndex  uint64
	dropsTotal uint64
	mu         sync.Mutex
	notEmpty   *sync.Cond
	closed     uint32
}

// NewAuditRingBuffer initializes a bounded circular ring buffer pool.
func NewAuditRingBuffer(capacity int) *AuditRingBuffer {
	if capacity <= 0 {
		capacity = DefaultRingBufferSize
	}
	rb := &AuditRingBuffer{
		buffer:   make([]*OpenBaoAuditEvent, capacity),
		capacity: uint64(capacity),
	}
	rb.notEmpty = sync.NewCond(&rb.mu)
	return rb
}

// Push appends an event to the circular buffer. If full, it drops the newest event and increments drop-tail counter.
// It never blocks the caller, guaranteeing zero backpressure on OpenBao.
func (rb *AuditRingBuffer) Push(event *OpenBaoAuditEvent) bool {
	if atomic.LoadUint32(&rb.closed) == 1 || event == nil {
		return false
	}

	rb.mu.Lock()
	defer rb.mu.Unlock()

	if atomic.LoadUint32(&rb.closed) == 1 {
		return false
	}

	occupied := rb.writeIndex - rb.readIndex
	if occupied >= rb.capacity {
		// Ring buffer full: drop tail to protect OpenBao from blocking
		atomic.AddUint64(&rb.dropsTotal, 1)
		return false
	}

	slot := rb.writeIndex % rb.capacity
	rb.buffer[slot] = event
	rb.writeIndex++
	rb.notEmpty.Signal()
	return true
}

// Pop retrieves the next available event, blocking until an event arrives or the buffer is closed.
func (rb *AuditRingBuffer) Pop() (*OpenBaoAuditEvent, bool) {
	rb.mu.Lock()
	defer rb.mu.Unlock()

	for rb.writeIndex == rb.readIndex {
		if atomic.LoadUint32(&rb.closed) == 1 {
			return nil, false
		}
		rb.notEmpty.Wait()
	}

	slot := rb.readIndex % rb.capacity
	event := rb.buffer[slot]
	rb.buffer[slot] = nil // Avoid memory retention
	rb.readIndex++
	return event, true
}

// DropsTotal returns the cumulative count of dropped events due to buffer saturation.
func (rb *AuditRingBuffer) DropsTotal() uint64 {
	return atomic.LoadUint64(&rb.dropsTotal)
}

// Len returns the current number of queued events.
func (rb *AuditRingBuffer) Len() int {
	rb.mu.Lock()
	defer rb.mu.Unlock()
	return int(rb.writeIndex - rb.readIndex)
}

// Close closes the ring buffer and wakes all waiting consumers.
func (rb *AuditRingBuffer) Close() {
	if atomic.CompareAndSwapUint32(&rb.closed, 0, 1) {
		rb.mu.Lock()
		rb.notEmpty.Broadcast()
		rb.mu.Unlock()
	}
}
