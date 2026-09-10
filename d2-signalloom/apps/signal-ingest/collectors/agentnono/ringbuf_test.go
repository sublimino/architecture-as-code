// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRingBuffer_BoundedCapacityAndDropTail(t *testing.T) {
	capacity := 5
	rb := NewRingBuffer(capacity)

	for i := 1; i <= capacity; i++ {
		pushed := rb.Push(&NonoAuditEvent{Seq: int64(i)})
		if !pushed {
			t.Fatalf("expected item %d to be pushed", i)
		}
	}

	if rb.Len() != capacity {
		t.Fatalf("expected buffer len %d, got %d", capacity, rb.Len())
	}

	// Saturated buffer: next push must drop and return false
	pushed := rb.Push(&NonoAuditEvent{Seq: 999})
	if pushed {
		t.Fatal("expected item to be dropped when buffer is full")
	}

	if rb.DropsTotal() != 1 {
		t.Fatalf("expected 1 drop, got %d", rb.DropsTotal())
	}

	// Drain one item
	ev, ok := rb.Pop()
	if !ok || ev.Seq != 1 {
		t.Fatalf("expected pop seq 1, got %v", ev)
	}

	// Now room is available for 1 item
	pushed = rb.Push(&NonoAuditEvent{Seq: 1000})
	if !pushed {
		t.Fatal("expected item to be pushed after drain")
	}
}

func TestRingBuffer_ConcurrentRace(t *testing.T) {
	rb := NewRingBuffer(50)
	var wg sync.WaitGroup
	var poppedCount uint64
	var pushedCount uint64

	// 5 Producers
	for p := 0; p < 5; p++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				if rb.Push(&NonoAuditEvent{Seq: int64(id*1000 + i)}) {
					atomic.AddUint64(&pushedCount, 1)
				}
				time.Sleep(50 * time.Microsecond)
			}
		}(p)
	}

	// 3 Consumers
	for c := 0; c < 3; c++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				ev, ok := rb.Pop()
				if !ok {
					return
				}
				if ev != nil {
					atomic.AddUint64(&poppedCount, 1)
				}
			}
		}()
	}

	time.Sleep(50 * time.Millisecond)
	rb.Close()
	wg.Wait()
}
