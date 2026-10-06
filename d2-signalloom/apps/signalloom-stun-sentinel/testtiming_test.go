// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"os"
	"strconv"
	"time"
)

// Load tolerance for the warden tests that drive a fake kernel.
//
// The failure this exists for: TestLocalFreezeWritesAWardenCaptureWithTheTwo-
// SpecAnalogues fails with "cgroup: freeze deadline exceeded before frozen
// state observed" when the host load average is 10 or more, and passes when the
// host is quiet.
//
// Why. simulateKernel() in stunhold_test.go is the fake kernel: a goroutine
// that reads cgroup.freeze and mirrors it into cgroup.events, sleeping 1ms
// between passes. cgroup.DefaultFreezeDeadline is 50ms. On a quiet host the
// mirror lands in ~1-2ms and there are ~50 chances to spare; on a host with
// nproc runnable threads per core the goroutine's 1ms sleep becomes tens of
// milliseconds of wall time and the mirror misses the window. Nothing about the
// product changed -- the test measured the Go scheduler.
//
// What is scaled and what is not. Only the freeze deadline and the harness's
// own "did the capture run" wait. Every assertion is untouched: the capture
// still has to run, the manifest still has to carry both spec analogues, the
// digests still have to match, and cgroup.events still has to read `frozen 1`.
// A product regression that never freezes, freezes the wrong cgroup, or writes
// the wrong manifest fails exactly as before -- on a loaded host it now takes
// proportionally longer to say so instead of blaming the deadline.
//
// Freeze LATENCY is a real property and it is still tested: that is
// pkg/cgroup/freezer_test.go, which drives the deadline directly with explicit
// cgroup.WithDeadline values against a controlled fake. This file does not
// touch those.

// testTimeoutScale reads TEST_TIMEOUT_SCALE (default 1). Below 1, or
// unparseable, falls back to 1 -- a typo must not silently shorten a budget.
func testTimeoutScale() int {
	raw := os.Getenv("TEST_TIMEOUT_SCALE")
	if raw == "" {
		return 1
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return 1
	}
	return n
}

// scaledDuration multiplies base by TEST_TIMEOUT_SCALE.
func scaledDuration(base time.Duration) time.Duration {
	return base * time.Duration(testTimeoutScale())
}

// harnessFreezeDeadline is the budget the fake kernel gets to mirror
// cgroup.freeze into cgroup.events. 500ms at scale 1 -- ten times
// cgroup.DefaultFreezeDeadline, because the fake kernel is a userspace
// goroutine on a 1ms poll and the real one is not.
func harnessFreezeDeadline() time.Duration {
	return scaledDuration(500 * time.Millisecond)
}
