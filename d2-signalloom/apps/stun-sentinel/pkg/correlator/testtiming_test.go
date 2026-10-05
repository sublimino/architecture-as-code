// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"os"
	"strconv"
	"testing"
	"time"
)

// Load tolerance for the correlator's wait loops.
//
// The failure this exists for: TestSpoolRetainsBatchesAcrossIngestOutage polled
// Stats().SpoolBatches 50 times with a 10ms sleep, so it gave the sender
// goroutine 500ms of WALL time to spool three batches. On a host with
// load average 10+ the sender is not scheduled often enough inside that window
// and the test reports "spool_batches = 1, want at least 3" — a scheduling
// result, not a product regression.
//
// What is deliberately NOT done here: the assertion is unchanged. The test
// still requires three batches on disk, and still fails if they never arrive.
// Only the wall-clock budget for the goroutine to get there is scaled. A real
// regression (the sender never spools, spools the wrong count, spools out of
// order) still fails, it just takes longer to say so on a loaded host.

// unreachableIngestURL is for managers that are constructed but whose sender is
// never started, so the URL is only ever a struct field.
//
// It replaced a hardcoded localhost ingest port. Nothing dialled that address,
// but naming a real port in a test is still a cross-run coupling waiting to
// happen: the day someone starts the sender in one of these tests, it would
// reach whatever a concurrent run had bound there and assert against a
// neighbour's server.
// `.invalid` is reserved by RFC 2606 and never resolves, so that mistake fails
// loudly and deterministically instead.
const unreachableIngestURL = "http://ingest.invalid"

// testTimeoutScale reads TEST_TIMEOUT_SCALE (default 1). Values below 1 and
// unparseable values fall back to 1 so a typo cannot silently shorten a budget.
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

// scaledDeadline returns base multiplied by TEST_TIMEOUT_SCALE.
func scaledDeadline(base time.Duration) time.Duration {
	return base * time.Duration(testTimeoutScale())
}

// waitForCond polls cond until it returns true or the scaled budget expires.
// It returns whether cond was ever satisfied; the caller owns the assertion, so
// a timeout is still reported as the caller's own failure message.
//
// tick is called on every iteration before re-checking, which is how the mock
// clock gets advanced. Keeping it inside the helper means the clock advances for
// as long as the real deadline allows, instead of a fixed iteration count that
// conflated "how many clock ticks" with "how long to wait".
func waitForCond(t *testing.T, base time.Duration, tick func(), cond func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(scaledDeadline(base))
	for {
		if cond() {
			return true
		}
		if time.Now().After(deadline) {
			return cond() // one last read, so a just-in-time success is not lost
		}
		if tick != nil {
			tick()
		}
		time.Sleep(10 * time.Millisecond)
	}
}
