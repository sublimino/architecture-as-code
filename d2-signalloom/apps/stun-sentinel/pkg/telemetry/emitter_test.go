// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

func decodeLines(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimRight(buf.String(), "\n"), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("line %q is not valid JSON: %v", line, err)
		}
		out = append(out, m)
	}
	return out
}

func sampleObservation() FreezeObservation {
	return FreezeObservation{
		PodUID:     "e4fc67c7-054b-4934-bfdd-d13b6390e2c3",
		PodName:    "agent-arthur",
		Namespace:  "fe-signalloom-agents",
		CgroupPath: "/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/x.slice",
		LatencyMS:  0.42,
		DeadlineMS: 50,
		Polls:      1,
		PIDs:       []int{4242, 4243},
	}
}

// ISC-28: the halt event carries timestamp, pod UID, cgroup path, latency and
// the PID list. Those five fields are what makes the record an audit artifact
// rather than a log line.
func TestStunExecutionHaltedCarriesRequiredFields(t *testing.T) {
	buf := &bytes.Buffer{}
	if err := NewEmitter(buf).StunExecutionHalted(sampleObservation()); err != nil {
		t.Fatalf("StunExecutionHalted: %v", err)
	}

	lines := decodeLines(t, buf)
	if len(lines) != 1 {
		t.Fatalf("emitted %d lines, want 1", len(lines))
	}
	ev := lines[0]

	if ev["event"] != EventStunExecutionHalted {
		t.Errorf("event = %v, want %s", ev["event"], EventStunExecutionHalted)
	}
	if ev["tier"] != TierKernelExecutionState {
		t.Errorf("tier = %v, want %s", ev["tier"], TierKernelExecutionState)
	}
	if ev["pod_uid"] != "e4fc67c7-054b-4934-bfdd-d13b6390e2c3" {
		t.Errorf("pod_uid = %v", ev["pod_uid"])
	}
	if ev["cgroup_path"] == "" || ev["cgroup_path"] == nil {
		t.Error("cgroup_path missing")
	}
	if ev["frozen"] != true {
		t.Errorf("frozen = %v, want true", ev["frozen"])
	}
	if ev["latency_ms"] != 0.42 {
		t.Errorf("latency_ms = %v, want 0.42", ev["latency_ms"])
	}
	ts, ok := ev["timestamp"].(string)
	if !ok || ts == "" {
		t.Fatalf("timestamp = %v, want a non-empty RFC3339 string", ev["timestamp"])
	}
	if _, err := time.Parse(time.RFC3339Nano, ts); err != nil {
		t.Errorf("timestamp %q does not parse as RFC3339Nano: %v", ts, err)
	}
	pids, ok := ev["pids"].([]any)
	if !ok || len(pids) != 2 {
		t.Fatalf("pids = %v, want two entries", ev["pids"])
	}
	if ev["pid_count"] != float64(2) {
		t.Errorf("pid_count = %v, want 2", ev["pid_count"])
	}
}

// ISC-29.
func TestStunExecutionResumedReportsThawed(t *testing.T) {
	buf := &bytes.Buffer{}
	if err := NewEmitter(buf).StunExecutionResumed(sampleObservation()); err != nil {
		t.Fatalf("StunExecutionResumed: %v", err)
	}
	ev := decodeLines(t, buf)[0]
	if ev["event"] != EventStunExecutionResumed {
		t.Errorf("event = %v, want %s", ev["event"], EventStunExecutionResumed)
	}
	if ev["frozen"] != false {
		t.Errorf("frozen = %v, want false on a resume event", ev["frozen"])
	}
}

// A failed containment must be loud. A silent failure here shows the control
// plane a contained agent that is in fact still running.
func TestStunExecutionHaltFailedCarriesReason(t *testing.T) {
	buf := &bytes.Buffer{}
	obs := sampleObservation()
	obs.Frozen = false
	err := NewEmitter(buf).StunExecutionHaltFailed(obs, "cgroup: freeze deadline exceeded")
	if err != nil {
		t.Fatalf("StunExecutionHaltFailed: %v", err)
	}
	ev := decodeLines(t, buf)[0]
	if ev["event"] != EventStunExecutionHaltFailed {
		t.Errorf("event = %v", ev["event"])
	}
	if ev["frozen"] != false {
		t.Errorf("frozen = %v, want false", ev["frozen"])
	}
	if !strings.Contains(ev["reason"].(string), "deadline") {
		t.Errorf("reason = %v, want the cause named", ev["reason"])
	}
}

// ISC-30: strictly one JSON object per line. A multi-line record would break
// every downstream `jq -c` and `while read` consumer.
func TestEmitIsOneObjectPerLine(t *testing.T) {
	buf := &bytes.Buffer{}
	e := NewEmitter(buf)
	for i := 0; i < 3; i++ {
		if err := e.StunExecutionHalted(sampleObservation()); err != nil {
			t.Fatal(err)
		}
	}
	raw := buf.String()
	if !strings.HasSuffix(raw, "\n") {
		t.Error("output does not end with a newline")
	}
	if got := strings.Count(raw, "\n"); got != 3 {
		t.Errorf("newline count = %d, want 3", got)
	}
	if strings.Contains(strings.TrimRight(raw, "\n"), "\n\n") {
		t.Error("output contains a blank line")
	}
	if len(decodeLines(t, buf)) != 3 {
		t.Error("not every line parsed independently")
	}
}

// A nil PID slice must marshal as [] not null: `.pids | length` errors on null.
func TestNilPIDsMarshalAsEmptyArray(t *testing.T) {
	buf := &bytes.Buffer{}
	if err := NewEmitter(buf).StunExecutionHalted(FreezeObservation{PodUID: "x"}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(buf.String(), `"pids":null`) {
		t.Errorf("pids marshalled as null: %s", buf.String())
	}
	ev := decodeLines(t, buf)[0]
	if _, ok := ev["pids"].([]any); !ok {
		t.Errorf("pids = %v, want an array", ev["pids"])
	}
	if ev["pid_count"] != float64(0) {
		t.Errorf("pid_count = %v, want 0", ev["pid_count"])
	}
}

// PIDCount is derived, never trusted from the caller — a mismatch between the
// list and the count would make the audit record self-contradictory.
func TestPIDCountIsDerivedNotTrusted(t *testing.T) {
	buf := &bytes.Buffer{}
	err := NewEmitter(buf).Emit(Event{
		Event:    EventStunExecutionHalted,
		PIDs:     []int{1, 2, 3},
		PIDCount: 99, // a lie
	})
	if err != nil {
		t.Fatal(err)
	}
	if ev := decodeLines(t, buf)[0]; ev["pid_count"] != float64(3) {
		t.Errorf("pid_count = %v, want 3 (derived from the list)", ev["pid_count"])
	}
}

func TestEmitPreservesExplicitTimestampAndTier(t *testing.T) {
	buf := &bytes.Buffer{}
	err := NewEmitter(buf).Emit(Event{
		Timestamp: "2026-09-07T12:00:00Z",
		Tier:      "tier-1-configuration-state",
		Event:     "Custom",
	})
	if err != nil {
		t.Fatal(err)
	}
	ev := decodeLines(t, buf)[0]
	if ev["timestamp"] != "2026-09-07T12:00:00Z" {
		t.Errorf("timestamp = %v, want the supplied value", ev["timestamp"])
	}
	if ev["tier"] != "tier-1-configuration-state" {
		t.Errorf("tier = %v, want the supplied value", ev["tier"])
	}
}

func TestSetClockOverridesTimestampSource(t *testing.T) {
	buf := &bytes.Buffer{}
	e := NewEmitter(buf)
	fixed := time.Date(2026, 9, 7, 20, 0, 0, 0, time.UTC)
	e.SetClock(func() time.Time { return fixed })
	if err := e.StunExecutionHalted(sampleObservation()); err != nil {
		t.Fatal(err)
	}
	if ts := decodeLines(t, buf)[0]["timestamp"]; ts != "2026-09-07T20:00:00Z" {
		t.Errorf("timestamp = %v, want the injected clock value", ts)
	}
	// A nil clock must not disarm the emitter.
	e.SetClock(nil)
	buf.Reset()
	if err := e.StunExecutionHalted(sampleObservation()); err != nil {
		t.Fatal(err)
	}
	if decodeLines(t, buf)[0]["timestamp"] != "2026-09-07T20:00:00Z" {
		t.Error("SetClock(nil) replaced the injected clock")
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("pipe closed") }

func TestEmitSurfacesWriteFailure(t *testing.T) {
	err := NewEmitter(failingWriter{}).StunExecutionHalted(sampleObservation())
	if err == nil {
		t.Fatal("Emit swallowed a writer failure")
	}
	if !strings.Contains(err.Error(), EventStunExecutionHalted) {
		t.Errorf("error %q should name the event that failed to publish", err)
	}
}

// ISC-31: the stun path runs on a multi-worker queue. Interleaved partial
// writes would corrupt JSONL framing, and `go test -race` must be clean.
func TestEmitIsConcurrencySafe(t *testing.T) {
	buf := &bytes.Buffer{}
	e := NewEmitter(buf)

	const workers, each = 8, 25
	var wg sync.WaitGroup
	wg.Add(workers)
	for w := 0; w < workers; w++ {
		go func() {
			defer wg.Done()
			for i := 0; i < each; i++ {
				if err := e.StunExecutionHalted(sampleObservation()); err != nil {
					t.Error(err)
					return
				}
			}
		}()
	}
	wg.Wait()

	lines := decodeLines(t, buf)
	if len(lines) != workers*each {
		t.Fatalf("emitted %d parseable lines, want %d — framing was corrupted", len(lines), workers*each)
	}
}
