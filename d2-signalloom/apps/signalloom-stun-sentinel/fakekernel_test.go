// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"
)

// Under full-lane load, TestLocalFreezeWritesAWardenCaptureWithTheTwoSpecAnalogues failed once
// with an EMPTY "# cgroup.events" section in its freeze artifact (2026-10-06). The capture waits
// for cgroup.events to say `frozen 1`, then reads it again to render the artifact; the fake kernel
// (simulateKernel) rewrote the file every millisecond with os.WriteFile, which truncates first,
// so the second read could land between the truncate and the write. A real cgroupfs read is
// atomic. The fake kernel must be too: no reader may ever see anything but a whole file.
func TestSimulatedKernelNeverExposesAPartialCgroupEvents(t *testing.T) {
	cg := filepath.Join(t.TempDir(), "pod.slice")
	mockFreezableCgroup(t, cg, false)
	simulateKernel(t, cg)

	stop := make(chan struct{})
	var toggles atomic.Int64
	go func() {
		state := []string{"0\n", "1\n"}
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			_ = os.WriteFile(filepath.Join(cg, "cgroup.freeze"), []byte(state[i%2]), 0o644)
			toggles.Add(1)
			time.Sleep(500 * time.Microsecond)
		}
	}()
	whole := map[string]bool{"populated 1\nfrozen 0\n": true, "populated 1\nfrozen 1\n": true}
	var reads, bad int
	var sample string
	// Run until the race has been exercised enough, not for a fixed time: under load the
	// toggler can be starved, and a timed loop would then prove nothing (or fail its own guard).
	deadline := time.Now().Add(scaledDuration(5 * time.Second))
	for (toggles.Load() < 50 || reads < 2000) && time.Now().Before(deadline) {
		runtime.Gosched()
		b, err := os.ReadFile(filepath.Join(cg, "cgroup.events"))
		if err != nil {
			continue
		}
		reads++
		if !whole[string(b)] {
			bad++
			sample = string(b)
		}
	}
	close(stop)
	if toggles.Load() < 50 || reads < 2000 {
		t.Fatalf("the race was not exercised: %d toggles, %d reads", toggles.Load(), reads)
	}
	if bad > 0 {
		t.Fatalf("%d of %d reads of the fake kernel's cgroup.events were partial (e.g. %q)", bad, reads, sample)
	}
}
