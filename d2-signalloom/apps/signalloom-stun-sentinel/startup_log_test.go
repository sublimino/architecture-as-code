// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"encoding/json"
	"reflect"
	"sync"
	"testing"
)

func TestStartupLogDerivesTruthfulAttachedTracepoints(t *testing.T) {
	var mu sync.Mutex
	var buf bytes.Buffer
	SetAuditOutput(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.Write(p) }))
	t.Cleanup(func() { SetAuditOutput(nil) })

	// Test case 1: Full attach
	attachedAll := []string{"sys_enter_openat", "sys_enter_openat2", "sys_enter_execve", "sys_enter_connect"}
	logEvent(stunEvent{
		Timestamp: now(),
		Event:     "ebpf_probe_attached",
		Details: map[string]interface{}{
			"tracepoints": attachedAll,
			"ringbuf_mb":  16,
		},
	})

	var ev stunEvent
	if err := json.Unmarshal(buf.Bytes(), &ev); err != nil {
		t.Fatalf("unmarshal full attach event: %v", err)
	}
	tpsRaw, ok := ev.Details["tracepoints"].([]interface{})
	if !ok {
		t.Fatalf("tracepoints not a slice: %v", ev.Details["tracepoints"])
	}
	var gotTps []string
	for _, tp := range tpsRaw {
		gotTps = append(gotTps, tp.(string))
	}
	if !reflect.DeepEqual(gotTps, attachedAll) {
		t.Fatalf("got tracepoints %v, want %v", gotTps, attachedAll)
	}

	// Test case 2: Partial attach (e.g. kernel missing openat2)
	buf.Reset()
	attachedPartial := []string{"sys_enter_openat", "sys_enter_execve", "sys_enter_connect"}
	logEvent(stunEvent{
		Timestamp: now(),
		Event:     "ebpf_probe_attached",
		Details: map[string]interface{}{
			"tracepoints": attachedPartial,
			"ringbuf_mb":  16,
		},
	})

	var evPartial stunEvent
	if err := json.Unmarshal(buf.Bytes(), &evPartial); err != nil {
		t.Fatalf("unmarshal partial attach event: %v", err)
	}
	tpsRawPartial, ok := evPartial.Details["tracepoints"].([]interface{})
	if !ok {
		t.Fatalf("tracepoints not a slice: %v", evPartial.Details["tracepoints"])
	}
	var gotTpsPartial []string
	for _, tp := range tpsRawPartial {
		gotTpsPartial = append(gotTpsPartial, tp.(string))
	}
	if !reflect.DeepEqual(gotTpsPartial, attachedPartial) {
		t.Fatalf("got tracepoints %v, want %v", gotTpsPartial, attachedPartial)
	}
}
