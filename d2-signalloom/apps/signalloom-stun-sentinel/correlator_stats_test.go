// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/correlator"
)

// Review M6 (2026-10-02): the BPF program counts ring-buffer reserve failures,
// but the stats line reported only user-space stages, so an event the kernel
// discarded (a stalled reader at ~70k events/s) left every counter still.
func TestCorrelatorStatsReportKernelRingBufferDrops(t *testing.T) {
	var mu sync.Mutex
	var buf bytes.Buffer
	SetAuditOutput(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.Write(p) }))
	t.Cleanup(func() { SetAuditOutput(nil) })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go reportCorrelatorStats(ctx,
		func() correlator.Stats { return correlator.Stats{} }, // user space unchanged
		func() (uint64, error) { return 42, nil },             // only the kernel dropped
		func() (uint64, error) { return 0, nil },
		nil,
		10*time.Millisecond)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		out := buf.String()
		mu.Unlock()
		if strings.Contains(out, `"ringbuf_drops":42`) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("no stats line carried the kernel ring-buffer drop count; got %q", buf.String())
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

// The probe now keeps never-sensitive opens out of the ring (path prefilter).
// The stats line must say how many, beside the drops, and a change in that
// count alone is a change worth a line: it is how the live check sees the
// filter working while not_sensitive and ringbuf_drops fall.
func TestCorrelatorStatsReportThePrefilteredCountAndItsChanges(t *testing.T) {
	var mu sync.Mutex
	var buf bytes.Buffer
	SetAuditOutput(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.Write(p) }))
	t.Cleanup(func() { SetAuditOutput(nil) })

	var n atomic.Uint64
	n.Store(7)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go reportCorrelatorStats(ctx,
		func() correlator.Stats { return correlator.Stats{} },
		func() (uint64, error) { return 0, nil },
		func() (uint64, error) { return n.Load(), nil },
		nil,
		10*time.Millisecond)

	waitFor := func(want string) {
		t.Helper()
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			mu.Lock()
			out := buf.String()
			mu.Unlock()
			if strings.Contains(out, want) {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("no stats line carried %s; got %q", want, buf.String())
	}
	waitFor(`"ringbuf_prefiltered":7`)
	n.Store(9) // nothing else changes
	waitFor(`"ringbuf_prefiltered":9`)
}

func TestCorrelatorStatsTriggersDropAnomalyCallback(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var dropsNotified atomic.Uint64
	var dropsVal atomic.Uint64
	dropsVal.Store(0)

	go reportCorrelatorStats(ctx,
		func() correlator.Stats { return correlator.Stats{} },
		func() (uint64, error) { return dropsVal.Load(), nil },
		func() (uint64, error) { return 0, nil },
		func(newDrops uint64) {
			dropsNotified.Add(newDrops)
		},
		10*time.Millisecond)

	time.Sleep(25 * time.Millisecond)
	if got := dropsNotified.Load(); got != 0 {
		t.Fatalf("expected 0 drops notified initially, got %d", got)
	}

	dropsVal.Store(15)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if got := dropsNotified.Load(); got == 15 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("drop anomaly callback not triggered; got %d notified, want 15", dropsNotified.Load())
}
