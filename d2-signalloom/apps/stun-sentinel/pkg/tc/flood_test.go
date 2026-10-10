// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"bufio"
	"os"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/ringbuf"
	ebpfPkg "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// getProcessVmRSSKB reads the current process VmRSS from /proc/self/status in KiB.
func getProcessVmRSSKB() (uint64, error) {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0, err
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "VmRSS:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				val, err := strconv.ParseUint(fields[1], 10, 64)
				if err == nil {
					return val, nil
				}
			}
		}
	}
	return 0, os.ErrNotExist
}

// readDropCounter reads the sum of a per-CPU drop map across all CPUs.
func readDropCounter(t *testing.T, m *ebpf.Map) uint64 {
	t.Helper()
	var key uint32 = 0
	var values []uint64
	if err := m.Lookup(&key, &values); err != nil {
		t.Fatalf("map lookup for drops failed: %v", err)
	}
	var total uint64
	for _, v := range values {
		total += v
	}
	return total
}

// TestRingbufferFlood executes a saturating flood sized to exceed the 4 MiB ringbuffer,
// asserting kernel drop counter increments, bounded RSS, and 100% packet accounting.
func TestRingbufferFlood(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	dnsDropsMap := coll.Maps["dns_drops"]
	tlsDropsMap := coll.Maps["tls_drops"]
	dnsRingMap := coll.Maps["dns_events"]
	tlsRingMap := coll.Maps["tls_events"]

	// Baseline RSS and Memory stats
	runtime.GC()
	rssBefore, err := getProcessVmRSSKB()
	if err != nil {
		t.Logf("warning: cannot read /proc/self/status VmRSS: %v", err)
	}
	var mBefore runtime.MemStats
	runtime.ReadMemStats(&mBefore)

	t.Logf("[FLOOD-PRE] Baseline VmRSS: %d KiB, HeapAlloc: %d KiB", rssBefore, mBefore.HeapAlloc/1024)

	// 1. DNS Ringbuffer Saturation Flood
	t.Run("DNS_Ringbuffer_Saturation_Flood", func(t *testing.T) {
		const floodCount = 20000 // 20,000 * ~376 bytes = ~7.5 MiB (exceeds 4 MiB ringbuffer)
		t.Logf("Generating %d synthetic DNS frames to saturate 4 MiB ringbuffer...", floodCount)
		dnsBatch := BuildFloodBatch(floodCount, true)

		dropsBefore := readDropCounter(t, dnsDropsMap)

		t.Logf("Injecting %d DNS frames without draining ringbuffer...", floodCount)
		start := time.Now()
		for i, frame := range dnsBatch {
			ret, _, err := prog.Test(frame)
			if err != nil {
				t.Fatalf("prog.Test at frame %d: %v", i, err)
			}
			if ret != 0 {
				t.Fatalf("ret = %d, want TC_ACT_OK (0)", ret)
			}
		}
		duration := time.Since(start)
		t.Logf("Injection of %d packets completed in %v (%.2f packets/sec)", floodCount, duration, float64(floodCount)/duration.Seconds())

		rssDuring, _ := getProcessVmRSSKB()
		var mDuring runtime.MemStats
		runtime.ReadMemStats(&mDuring)
		t.Logf("[FLOOD-DURING] VmRSS: %d KiB (delta: +%d KiB), HeapAlloc: %d KiB", rssDuring, rssDuring-rssBefore, mDuring.HeapAlloc/1024)

		dropsAfter := readDropCounter(t, dnsDropsMap)
		dropDelta := dropsAfter - dropsBefore
		t.Logf("Kernel dns_drops counter delta: %d drops observed", dropDelta)

		if dropDelta == 0 {
			t.Errorf("expected ringbuffer drops > 0 for %d packets into 4 MiB ringbuffer, got 0", floodCount)
		}

		// Drain ringbuffer and count successfully committed events
		rd, err := ringbuf.NewReader(dnsRingMap)
		if err != nil {
			t.Fatalf("ringbuf.NewReader: %v", err)
		}
		defer rd.Close()

		var drainedCount uint64
		for {
			rd.SetDeadline(time.Now().Add(100 * time.Millisecond))
			rec, err := rd.Read()
			if err != nil {
				break
			}
			_, err = ebpfPkg.DecodeDNSEvent(rec.RawSample)
			if err != nil {
				t.Fatalf("DecodeDNSEvent failed during flood drain: %v", err)
			}
			drainedCount++
			if drainedCount+dropDelta >= floodCount {
				break
			}
		}

		t.Logf("Drained %d events from ringbuffer + %d drops = %d total accounted (injected: %d)",
			drainedCount, dropDelta, drainedCount+dropDelta, floodCount)

		totalAccounted := drainedCount + dropDelta
		if totalAccounted != floodCount {
			t.Errorf("accounting mismatch: drained (%d) + drops (%d) = %d, want %d (gap: %d)",
				drainedCount, dropDelta, totalAccounted, floodCount, int(floodCount)-int(totalAccounted))
		}
	})

	// 2. TLS Ringbuffer Saturation Flood
	t.Run("TLS_Ringbuffer_Saturation_Flood", func(t *testing.T) {
		const floodCount = 30000 // 30,000 * ~168 bytes = ~5.0 MiB (exceeds 4 MiB ringbuffer)
		t.Logf("Generating %d synthetic TLS frames to saturate 4 MiB ringbuffer...", floodCount)
		tlsBatch := BuildFloodBatch(floodCount, false)

		dropsBefore := readDropCounter(t, tlsDropsMap)

		start := time.Now()
		for i, frame := range tlsBatch {
			ret, _, err := prog.Test(frame)
			if err != nil {
				t.Fatalf("prog.Test at frame %d: %v", i, err)
			}
			if ret != 0 {
				t.Fatalf("ret = %d, want TC_ACT_OK (0)", ret)
			}
		}
		duration := time.Since(start)
		t.Logf("Injection of %d TLS packets completed in %v (%.2f packets/sec)", floodCount, duration, float64(floodCount)/duration.Seconds())

		dropsAfter := readDropCounter(t, tlsDropsMap)
		dropDelta := dropsAfter - dropsBefore
		t.Logf("Kernel tls_drops counter delta: %d drops observed", dropDelta)

		if dropDelta == 0 {
			t.Errorf("expected ringbuffer drops > 0 for %d packets into 4 MiB ringbuffer, got 0", floodCount)
		}

		rd, err := ringbuf.NewReader(tlsRingMap)
		if err != nil {
			t.Fatalf("ringbuf.NewReader: %v", err)
		}
		defer rd.Close()

		var drainedCount uint64
		for {
			rd.SetDeadline(time.Now().Add(100 * time.Millisecond))
			rec, err := rd.Read()
			if err != nil {
				break
			}
			_, err = ebpfPkg.DecodeTLSSNIEvent(rec.RawSample)
			if err != nil {
				t.Fatalf("DecodeTLSSNIEvent failed during flood drain: %v", err)
			}
			drainedCount++
			if drainedCount+dropDelta >= floodCount {
				break
			}
		}

		t.Logf("Drained %d TLS events + %d drops = %d total accounted (injected: %d)",
			drainedCount, dropDelta, drainedCount+dropDelta, floodCount)

		totalAccounted := drainedCount + dropDelta
		if totalAccounted != floodCount {
			t.Errorf("accounting mismatch: drained (%d) + drops (%d) = %d, want %d",
				drainedCount, dropDelta, totalAccounted, floodCount)
		}
	})

	// Post-flood RSS verification
	runtime.GC()
	rssAfter, _ := getProcessVmRSSKB()
	var mAfter runtime.MemStats
	runtime.ReadMemStats(&mAfter)

	t.Logf("[FLOOD-POST] Final VmRSS: %d KiB (delta from baseline: +%d KiB), HeapAlloc: %d KiB",
		rssAfter, rssAfter-rssBefore, mAfter.HeapAlloc/1024)

	// Assert Warden process RSS growth is bounded (e.g. less than 64 MiB total RSS growth during test)
	const maxAllowedRSSGrowthKB = 64 * 1024 // 64 MiB
	if rssAfter > rssBefore && (rssAfter-rssBefore) > maxAllowedRSSGrowthKB {
		t.Errorf("unbounded RSS growth: before=%d KiB, after=%d KiB, delta=%d KiB exceeds limit %d KiB",
			rssBefore, rssAfter, rssAfter-rssBefore, maxAllowedRSSGrowthKB)
	}
}
