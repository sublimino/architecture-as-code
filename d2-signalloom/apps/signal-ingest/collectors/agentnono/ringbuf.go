// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"sync"
	"sync/atomic"
)

// DefaultRingBufferSize defines the maximum capacity of the bounded ring buffer.
const DefaultRingBufferSize = 1000

// RingBuffer provides a thread-safe, bounded FIFO ring buffer with drop-tail backpressure.
type RingBuffer struct {
	buffer     []*NonoAuditEvent
	capacity   uint64
	writeIndex uint64
	readIndex  uint64
	dropsTotal uint64
	mu         sync.Mutex
	notEmpty   *sync.Cond
	closed     uint32
}

// NewRingBuffer allocates a bounded ring buffer with the specified capacity.
func NewRingBuffer(capacity int) *RingBuffer {
	if capacity <= 0 {
		capacity = DefaultRingBufferSize
	}
	rb := &RingBuffer{
		buffer:   make([]*NonoAuditEvent, capacity),
		capacity: uint64(capacity),
	}
	rb.notEmpty = sync.NewCond(&rb.mu)
	return rb
}

// Push adds an event to the buffer. If full, it drops the event (drop-tail)
// and returns false to prevent unbounded memory allocation under bursty loads.
func (rb *RingBuffer) Push(event *NonoAuditEvent) bool {
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
func (rb *RingBuffer) Pop() (*NonoAuditEvent, bool) {
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
	rb.buffer[slot] = nil
	rb.readIndex++
	return event, true
}

// DropsTotal returns the cumulative count of dropped events due to buffer saturation.
func (rb *RingBuffer) DropsTotal() uint64 {
	return atomic.LoadUint64(&rb.dropsTotal)
}

// Len returns the current number of queued items.
func (rb *RingBuffer) Len() int {
	rb.mu.Lock()
	defer rb.mu.Unlock()
	return int(rb.writeIndex - rb.readIndex)
}

// Cap returns the maximum capacity of the ring buffer.
func (rb *RingBuffer) Cap() int {
	return int(rb.capacity)
}

// Close closes the ring buffer and wakes all waiting Pop calls.
func (rb *RingBuffer) Close() {
	if atomic.CompareAndSwapUint32(&rb.closed, 0, 1) {
		rb.mu.Lock()
		rb.notEmpty.Broadcast()
		rb.mu.Unlock()
	}
}
