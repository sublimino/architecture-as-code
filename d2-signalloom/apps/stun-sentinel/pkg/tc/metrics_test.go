// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"strings"
	"testing"
	"time"
)

// requireLine fails unless the exposition text contains the exact line.
func requireLine(t *testing.T, out, want string) {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == want {
			return
		}
	}
	t.Errorf("missing line:\n  want: %s\n  got:\n%s", want, out)
}

func TestRenderExportsTheTwoCardMandatedMetrics(t *testing.T) {
	r := NewRegistry()
	r.ObserveDrops("veth123", 4711, 620000)
	r.ObserveIsolationDuration("veth123", 3*time.Millisecond)

	out := r.Render()

	// The card names these two by name. A rename is a contract break for
	// every dashboard and alert built on them.
	for _, name := range []string{"stun_tc_packets_dropped_total", "stun_tc_isolation_duration_seconds"} {
		if !strings.Contains(out, name) {
			t.Errorf("exposition is missing the card-mandated metric %q", name)
		}
		if !strings.Contains(out, "# HELP "+name) {
			t.Errorf("missing # HELP for %q", name)
		}
		if !strings.Contains(out, "# TYPE "+name) {
			t.Errorf("missing # TYPE for %q", name)
		}
	}

	requireLine(t, out, `# TYPE stun_tc_packets_dropped_total counter`)
	requireLine(t, out, `# TYPE stun_tc_isolation_duration_seconds histogram`)
	requireLine(t, out, `stun_tc_packets_dropped_total{interface="veth123"} 4711`)
	requireLine(t, out, `stun_tc_bytes_dropped_total{interface="veth123"} 620000`)
}

func TestObserveDropsSetsRatherThanAccumulates(t *testing.T) {
	// The BPF map value is itself a monotonic total. Adding on each scrape
	// would double-count, and the counter would grow quadratically while
	// still looking superficially plausible.
	r := NewRegistry()
	r.ObserveDrops("veth1", 100, 1000)
	r.ObserveDrops("veth1", 150, 1500)
	requireLine(t, r.Render(), `stun_tc_packets_dropped_total{interface="veth1"} 150`)
}

func TestHistogramBucketsBracketThe100msBudget(t *testing.T) {
	r := NewRegistry()
	r.ObserveIsolationDuration("veth1", 2*time.Millisecond)
	out := r.Render()

	// A 2ms observation must land in every bucket at or above 5ms, and in
	// none below. If the le="0.1" bucket did not exist, a breach of the
	// card's 100ms budget would be unmeasurable.
	requireLine(t, out, `stun_tc_isolation_duration_seconds_bucket{interface="veth1",le="0.005"} 1`)
	requireLine(t, out, `stun_tc_isolation_duration_seconds_bucket{interface="veth1",le="0.1"} 1`)
	requireLine(t, out, `stun_tc_isolation_duration_seconds_bucket{interface="veth1",le="0.001"} 0`)
	requireLine(t, out, `stun_tc_isolation_duration_seconds_count{interface="veth1"} 1`)
	requireLine(t, out, `stun_tc_isolation_duration_seconds_bucket{interface="veth1",le="+Inf"} 1`)
}

func TestSlowIsolationIsVisibleAboveTheBudgetBucket(t *testing.T) {
	r := NewRegistry()
	r.ObserveIsolationDuration("veth1", 250*time.Millisecond) // a breach
	out := r.Render()
	requireLine(t, out, `stun_tc_isolation_duration_seconds_bucket{interface="veth1",le="0.1"} 0`)
	requireLine(t, out, `stun_tc_isolation_duration_seconds_bucket{interface="veth1",le="+Inf"} 1`)
}

func TestIsolationActiveGauge(t *testing.T) {
	r := NewRegistry()
	r.SetIsolated("veth1", true)
	r.SetIsolated("veth2", false)
	out := r.Render()
	requireLine(t, out, `# TYPE stun_tc_isolation_active gauge`)
	requireLine(t, out, `stun_tc_isolation_active{interface="veth1"} 1`)
	requireLine(t, out, `stun_tc_isolation_active{interface="veth2"} 0`)
}

func TestConntrackAndAttachedCounters(t *testing.T) {
	r := NewRegistry()
	r.AddConntrackDeleted(3)
	r.AddConntrackDeleted(2)
	r.AddConntrackDeleted(0)
	r.AddConntrackDeleted(-5) // nonsense input must not corrupt the counter
	r.SetAttachedFilters(4)
	out := r.Render()
	requireLine(t, out, `stun_tc_conntrack_entries_deleted_total 5`)
	requireLine(t, out, `stun_tc_attached_filters 4`)
}

func TestRenderIsDeterministicallyOrdered(t *testing.T) {
	// Unstable ordering makes every scrape diff noisy and breaks golden-file
	// comparison in the BATS suite.
	r := NewRegistry()
	for _, n := range []string{"vethZ", "vethA", "vethM"} {
		r.ObserveDrops(n, 1, 1)
	}
	first := r.Render()
	for i := 0; i < 20; i++ {
		if r.Render() != first {
			t.Fatal("Render() output is not deterministic across calls")
		}
	}
	a := strings.Index(first, `vethA`)
	m := strings.Index(first, `vethM`)
	z := strings.Index(first, `vethZ`)
	if !(a < m && m < z) {
		t.Errorf("interfaces are not sorted: A@%d M@%d Z@%d", a, m, z)
	}
}

func TestEmptyRegistryStillRendersTypeMetadata(t *testing.T) {
	// A scrape of an idle node must still declare the metrics, otherwise
	// Prometheus sees them appear and disappear and alert rules on
	// absent() misfire.
	out := NewRegistry().Render()
	for _, name := range []string{
		MetricPacketsDropped, MetricBytesDropped, MetricIsolationDuration,
		MetricIsolationActive, MetricAttachedFilters, MetricConntrackDeleted,
	} {
		if !strings.Contains(out, "# TYPE "+name) {
			t.Errorf("empty registry omits # TYPE for %q", name)
		}
	}
}
