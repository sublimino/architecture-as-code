// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"context"
	"strings"
	"sync"
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
