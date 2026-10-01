// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"testing"
	"time"
)

// An observation's timestamp is when the syscall happened, not when a worker
// got round to it. The correlator stamped processing time, and on a live node
// the ring buffer carried ~70k openat events/s, so a provoked read was stamped
// ~18s late and fell outside the containment suite's 15s correlation window
// (measured 2026-10-01). The probe stamps bpf_ktime_get_ns (CLOCK_MONOTONIC).

func withClocks(t *testing.T, mono uint64, wall time.Time) {
	t.Helper()
	oldMono, oldWall := monotonicNow, wallNow
	monotonicNow = func() uint64 { return mono }
	wallNow = func() time.Time { return wall }
	t.Cleanup(func() { monotonicNow, wallNow = oldMono, oldWall })
}

func TestObservationTimestampIsTheKernelEventTimeNotProcessingTime(t *testing.T) {
	wall := time.Date(2026, 10, 1, 22, 44, 39, 0, time.UTC)
	mono := uint64(5_000 * time.Second)
	withClocks(t, mono, wall)

	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)
	ev := SyscallEvent{TsNs: mono - uint64(18*time.Second)}
	got := m.NormalizeObservation(ev, agentPod("tenant-kusari")).Timestamp

	want := wall.Add(-18 * time.Second).Format(time.RFC3339Nano)
	if got != want {
		t.Fatalf("timestamp = %s, want the syscall's own time %s", got, want)
	}
}

func TestObservationTimestampFallsBackToNowWithoutAUsableKernelTime(t *testing.T) {
	wall := time.Date(2026, 10, 1, 22, 44, 39, 0, time.UTC)
	withClocks(t, uint64(100*time.Second), wall)
	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)

	for name, ts := range map[string]uint64{"absent": 0, "from the future": uint64(200 * time.Second)} {
		if got := m.NormalizeObservation(SyscallEvent{TsNs: ts}, nil).Timestamp; got != wall.Format(time.RFC3339Nano) {
			t.Fatalf("%s kernel time: timestamp = %s, want now", name, got)
		}
	}
}
