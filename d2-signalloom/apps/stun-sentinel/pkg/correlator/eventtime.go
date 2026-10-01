// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"time"

	"golang.org/x/sys/unix"
)

// monotonicNow and wallNow are the two clocks eventWallTime reconciles; tests
// replace them.
var (
	monotonicNow = func() uint64 {
		var ts unix.Timespec
		if unix.ClockGettime(unix.CLOCK_MONOTONIC, &ts) != nil {
			return 0
		}
		return uint64(ts.Nano())
	}
	wallNow = time.Now
)

// eventWallTime converts the probe's bpf_ktime_get_ns() stamp (CLOCK_MONOTONIC,
// the same kernel clock this process reads) to wall time. With no usable stamp
// it falls back to now rather than inventing a time.
func eventWallTime(tsNs uint64) time.Time {
	mono := monotonicNow()
	if tsNs == 0 || mono == 0 || tsNs > mono {
		return wallNow()
	}
	return wallNow().Add(-time.Duration(mono - tsNs))
}
