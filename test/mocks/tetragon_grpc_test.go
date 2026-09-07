// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/ebpf"
)

// shortTempDir keeps the socket path under the 108-byte sun_path limit. A
// t.TempDir() path embeds the test name and can exceed it, and the failure
// surfaces from bind as "invalid argument", which reads like a server bug.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "tgm")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func TestBuildEventsMixedRoundRobinsAllThreeClasses(t *testing.T) {
	events := buildEvents("mixed", "node-a", "ns-a", 6)
	if len(events) != 6 {
		t.Fatalf("built %d events, want 6", len(events))
	}

	execs, connects, files := 0, 0, 0
	for _, ev := range events {
		switch {
		case ev.GetProcessExec() != nil:
			execs++
		case ev.GetProcessKprobe() != nil:
			if ev.GetProcessKprobe().GetFunctionName() == ebpf.SymbolTCPConnect {
				connects++
			} else {
				files++
			}
		}
	}

	if execs != 2 || connects != 2 || files != 2 {
		t.Errorf("mix = %d exec / %d connect / %d file, want 2 of each", execs, connects, files)
	}
}

func TestBuildEventsSingleClassModes(t *testing.T) {
	for _, tc := range []struct {
		mode  string
		check func(t *testing.T, i int, node, ns string)
	}{
		{"exec", func(t *testing.T, _ int, node, ns string) {
			ev := buildEvents("exec", node, ns, 3)[0]
			if ev.GetProcessExec() == nil {
				t.Error("mode=exec did not produce a ProcessExec event")
			}
		}},
		{"connect", func(t *testing.T, _ int, node, ns string) {
			ev := buildEvents("connect", node, ns, 3)[0]
			kp := ev.GetProcessKprobe()
			if kp == nil || kp.GetFunctionName() != ebpf.SymbolTCPConnect {
				t.Error("mode=connect did not produce a tcp_connect kprobe event")
			}
		}},
		{"file", func(t *testing.T, _ int, node, ns string) {
			ev := buildEvents("file", node, ns, 3)[0]
			kp := ev.GetProcessKprobe()
			if kp == nil || kp.GetFunctionName() != ebpf.SymbolOpenat {
				t.Error("mode=file did not produce an openat kprobe event")
			}
		}},
	} {
		t.Run(tc.mode, func(t *testing.T) { tc.check(t, 0, "node-a", "ns-a") })
	}
}

// A non-positive count must yield no events rather than panicking on a negative
// make() capacity.
func TestBuildEventsRejectsNonPositiveCount(t *testing.T) {
	for _, n := range []int{0, -1, -1000} {
		if got := buildEvents("mixed", "n", "ns", n); len(got) != 0 {
			t.Errorf("buildEvents(n=%d) produced %d events, want 0", n, len(got))
		}
	}
}

func TestBuildEventsStampsNodeAndNamespace(t *testing.T) {
	events := buildEvents("exec", "my-node", "my-ns", 1)
	ev := events[0]

	if ev.GetNodeName() != "my-node" {
		t.Errorf("NodeName = %q, want my-node", ev.GetNodeName())
	}
	pod := ev.GetProcessExec().GetProcess().GetPod()
	if pod.GetNamespace() != "my-ns" {
		t.Errorf("Pod.Namespace = %q, want my-ns", pod.GetNamespace())
	}
}

// The mock must serve the genuine gRPC service and a real StreamClient must
// consume it. This is the test that proves the offline harness is a valid stand-in
// for a live Tetragon: real protobuf marshalling, real gRPC framing over a real
// unix socket — only the kernel is absent.
func TestMockServerIsConsumableByRealStreamClient(t *testing.T) {
	srv := ebpf.NewMockTetragonServer(buildEvents("mixed", "node-a", "fe-signalloom-agents", 9))

	stop, err := srv.Serve(shortTempDir(t))
	if err != nil {
		t.Fatalf("serve: %v", err)
	}
	defer stop()

	if srv.SocketPath() == "" {
		t.Fatal("SocketPath is empty after Serve")
	}
	if _, err := os.Stat(srv.SocketPath()); err != nil {
		t.Fatalf("socket was not created: %v", err)
	}

	sc := ebpf.NewStreamClient(ebpf.StreamConfig{
		SocketPath:     srv.SocketPath(),
		InitialBackoff: 10 * time.Millisecond,
		MaxBackoff:     50 * time.Millisecond,
	}, nil)
	defer sc.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	go func() { _ = sc.Run(ctx) }()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if sc.Metrics().Snapshot()[ebpf.MetricEventsReceived] >= 9 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	snap := sc.Metrics().Snapshot()
	if snap[ebpf.MetricEventsReceived] < 9 {
		t.Fatalf("%s = %d, want >= 9", ebpf.MetricEventsReceived, snap[ebpf.MetricEventsReceived])
	}
	if snap[ebpf.MetricEventsDropped] != 0 {
		t.Errorf("%s = %d, want 0", ebpf.MetricEventsDropped, snap[ebpf.MetricEventsDropped])
	}
	if got := sc.Ring().Len(); got != 9 {
		t.Errorf("ring holds %d events, want 9 — no loss across the gRPC boundary", got)
	}
}

// The 500ms end-to-end latency budget from the card, measured over the real
// gRPC transport rather than in-process.
func TestMockServerDeliversFirstEventWithin500ms(t *testing.T) {
	srv := ebpf.NewMockTetragonServer(buildEvents("mixed", "node-a", "fe-signalloom-agents", 1))

	stop, err := srv.Serve(shortTempDir(t))
	if err != nil {
		t.Fatalf("serve: %v", err)
	}
	defer stop()

	sc := ebpf.NewStreamClient(ebpf.StreamConfig{
		SocketPath:     srv.SocketPath(),
		InitialBackoff: 5 * time.Millisecond,
		MaxBackoff:     20 * time.Millisecond,
	}, nil)
	defer sc.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	start := time.Now()
	go func() { _ = sc.Run(ctx) }()

	deadline := time.Now().Add(5 * time.Second)
	var elapsed time.Duration
	for time.Now().Before(deadline) {
		if sc.Metrics().Snapshot()[ebpf.MetricEventsReceived] >= 1 {
			elapsed = time.Since(start)
			break
		}
		time.Sleep(time.Millisecond)
	}

	if elapsed == 0 {
		t.Fatal("no event was received")
	}
	if elapsed > 500*time.Millisecond {
		t.Errorf("first event took %s, want < 500ms", elapsed)
	}
	t.Logf("first event delivered in %s", elapsed)
}
