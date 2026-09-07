// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Command tetragon_grpc_mock runs an offline mock of Tetragon's
// FineGuidanceSensors gRPC service on a unix socket.
//
// It exists so that test/tetragon-telemetry-stream.bats and
// scripts/test-tetragon-stream.sh can verify the end-to-end ingestion path with
// no Kubernetes cluster, no Tetragon installation, and no kernel privileges.
//
// The server implementation is NOT duplicated here. It is
// collectors/ebpf.MockTetragonServer — the same type the Go unit tests use.
// Two independent fakes would be two chances for the fake to disagree with
// itself about the wire format, and the whole value of a mock that speaks the
// genuine generated protobuf service is that there is exactly one of it.
//
// Usage:
//
//	tetragon_grpc_mock -socket-dir /tmp/tg -events 1000 -mode exec
//	tetragon_grpc_mock -socket-dir /tmp/tg -mode mixed -close-after-send
//
// The process prints the socket path on stdout as `SOCKET=<path>` and then
// blocks until SIGINT/SIGTERM, so a shell harness can capture the path without
// guessing it.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	tetragon "github.com/cilium/tetragon/api/v1/tetragon"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/ebpf"
)

const (
	defaultNode      = "osramp-control-plane"
	defaultNamespace = "fe-signalloom-agents"
)

func main() {
	var (
		socketDir      = flag.String("socket-dir", "", "directory to create the unix socket in (default: a fresh dir under /tmp)")
		events         = flag.Int("events", 3, "number of events to emit")
		mode           = flag.String("mode", "mixed", "event mix: mixed | exec | connect | file")
		node           = flag.String("node", defaultNode, "node name stamped on each event")
		namespace      = flag.String("namespace", defaultNamespace, "pod namespace stamped on each event")
		delay          = flag.Duration("delay", 0, "pause between emitted events")
		closeAfterSend = flag.Bool("close-after-send", false, "end the stream once the backlog drains, forcing client reconnects")
		metricsAddr    = flag.String("metrics-addr", "", "when set, also run a StreamClient against this mock and serve its collector metrics on this address (e.g. 127.0.0.1:0)")
	)
	flag.Parse()

	dir := *socketDir
	if dir == "" {
		d, err := os.MkdirTemp("/tmp", "tgmock")
		if err != nil {
			fatalf("create socket dir: %v", err)
		}
		dir = d
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fatalf("mkdir %s: %v", dir, err)
	}

	srv := ebpf.NewMockTetragonServer(buildEvents(*mode, *node, *namespace, *events))
	srv.SetInterEventDelay(*delay)
	srv.SetCloseAfterSend(*closeAfterSend)

	stop, err := srv.Serve(dir)
	if err != nil {
		fatalf("serve: %v", err)
	}
	defer stop()

	// Emitted on stdout so a shell harness can capture the path rather than
	// reconstructing it — the filename is an implementation detail of Serve.
	fmt.Printf("SOCKET=%s\n", srv.SocketPath())
	fmt.Printf("EVENTS=%d\n", *events)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if *metricsAddr != "" {
		addr, err := runSelfConsumer(ctx, srv.SocketPath(), *metricsAddr)
		if err != nil {
			fatalf("start self-consumer: %v", err)
		}
		// The harness polls this endpoint. Printing the RESOLVED address
		// matters: passing :0 lets the OS pick a free port, which is what makes
		// the suite safe to run concurrently with a sibling card's harness.
		fmt.Printf("METRICS=http://%s/metrics\n", addr)
	}
	os.Stdout.Sync()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	<-sigs
}

// runSelfConsumer wires a real StreamClient to the mock server and exposes its
// collector metrics over HTTP, mirroring what signal-ingest does in-cluster.
//
// This is what makes the shell harness a genuine end-to-end proof rather than a
// server smoke test: the bytes traverse real gRPC framing, are decoded by the
// real generated protobuf, pass through the real normaliser and the real
// bounded ring buffer, and the counters that come out are the same counters
// signal-ingest publishes.
func runSelfConsumer(ctx context.Context, socketPath, listenAddr string) (string, error) {
	sc := ebpf.NewStreamClient(ebpf.StreamConfig{
		SocketPath:     socketPath,
		InitialBackoff: 10 * time.Millisecond,
		MaxBackoff:     500 * time.Millisecond,
	}, nil)

	go func() { _ = sc.Run(ctx) }()
	go func() { _ = sc.Drain(ctx) }()

	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return "", fmt.Errorf("listen on %s: %w", listenAddr, err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = io.WriteString(w, sc.Metrics().Render())
	})

	go func() { _ = http.Serve(lis, mux) }()
	return lis.Addr().String(), nil
}

// BuildEvents is the event-mix builder, exported through buildEvents so that
// tetragon_grpc_test.go can assert the mix without starting a server.
func buildEvents(mode, node, namespace string, n int) []*tetragon.GetEventsResponse {
	if n <= 0 {
		return nil
	}
	base := time.Unix(1757000000, 0).UTC()
	out := make([]*tetragon.GetEventsResponse, 0, n)

	for i := 0; i < n; i++ {
		at := base.Add(time.Duration(i) * time.Millisecond)
		pod := fmt.Sprintf("agent-%d", i)

		switch mode {
		case "exec":
			out = append(out, ebpf.FixtureExecEvent(node, namespace, pod, "/usr/bin/agent", at))
		case "connect":
			out = append(out, ebpf.FixtureConnectEvent(node, namespace, pod, "104.18.7.10", 443, at))
		case "file":
			out = append(out, ebpf.FixtureFileEvent(node, namespace, pod,
				"/var/run/secrets/kubernetes.io/serviceaccount/token", at))
		default: // mixed — round-robin the three modelled classes
			switch i % 3 {
			case 0:
				out = append(out, ebpf.FixtureExecEvent(node, namespace, pod, "/usr/bin/agent", at))
			case 1:
				out = append(out, ebpf.FixtureConnectEvent(node, namespace, pod, "104.18.7.10", 443, at))
			case 2:
				out = append(out, ebpf.FixtureFileEvent(node, namespace, pod,
					"/var/run/secrets/kubernetes.io/serviceaccount/token", at))
			}
		}
	}
	return out
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "tetragon_grpc_mock: "+format+"\n", args...)
	os.Exit(1)
}
