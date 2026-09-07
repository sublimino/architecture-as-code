// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"fmt"
	"hash/fnv"
	"io"
	"log/slog"
	"strings"
	"sync"
	"time"

	tetragon "github.com/cilium/tetragon/api/v1/tetragon"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
)

// DefaultSocketPath is the Tetragon gRPC export socket. It is the same value
// asserted in the tetragon-telemetry-contract ConfigMap and set in
// tetragon-helm-values.yaml; all three must agree.
const DefaultSocketPath = "/var/run/cilium/tetragon/tetragon.sock"

// Backoff bounds for stream reconnection.
//
// Tetragon restarts are routine (DaemonSet rollout, policy reload, node
// pressure eviction). A collector that gives up on the first stream error would
// leave a silent telemetry hole for the rest of the process lifetime, which is
// exactly the failure the gap detector exists to catch but cannot fix. So the
// client reconnects forever, with a cap so a genuinely dead Tetragon does not
// become a busy loop against the socket.
const (
	DefaultInitialBackoff = 100 * time.Millisecond
	DefaultMaxBackoff     = 30 * time.Second
	backoffMultiplier     = 2
)

// FlowEvent is an alias for the canonical schema, not a new type. Using an
// alias rather than a defined type is deliberate: it keeps the package readable
// without creating a parallel struct that could drift from
// netebpf.InboundFlowEvent, and it means netebpf.LiveNetworkEgressCollector
// satisfies FlowProcessor with no adapter.
type FlowEvent = netebpf.InboundFlowEvent

// FlowProcessor consumes normalised flow events. netebpf.LiveNetworkEgressCollector
// satisfies this interface, which is the whole point — Tetragon events enter the
// existing pipeline through the existing door, including its sequence-gap
// detection and its observation conversion.
type FlowProcessor interface {
	ProcessFlowEvent(ctx context.Context, ev *FlowEvent) error
}

// StreamConfig configures a StreamClient. Every external boundary here is
// injectable so the client is testable against a mock server without a live
// Tetragon: SocketPath points at a test socket, Dialer can be overridden, and
// the backoff bounds are shrunk in tests so a reconnect assertion does not take
// 30 seconds.
type StreamConfig struct {
	// SocketPath is the unix socket Tetragon serves FineGuidanceSensors on.
	SocketPath string
	// InitialBackoff is the first reconnect delay.
	InitialBackoff time.Duration
	// MaxBackoff caps the reconnect delay.
	MaxBackoff time.Duration
	// RingCapacity sizes the bounded buffer between reader and consumer.
	RingCapacity int
	// AllowedNamespaces, when non-empty, restricts ingestion to these
	// namespaces. This is defence in depth behind the TracingPolicy namespace
	// scoping: if a cluster-wide policy is ever applied by mistake, the
	// collector still refuses to ingest out-of-contract namespaces rather than
	// flooding the store.
	AllowedNamespaces []string
	// Logger receives structured stream lifecycle events.
	Logger *slog.Logger
}

// withDefaults returns a copy of cfg with zero values filled in.
func (c StreamConfig) withDefaults() StreamConfig {
	if c.SocketPath == "" {
		c.SocketPath = DefaultSocketPath
	}
	if c.InitialBackoff <= 0 {
		c.InitialBackoff = DefaultInitialBackoff
	}
	if c.MaxBackoff <= 0 {
		c.MaxBackoff = DefaultMaxBackoff
	}
	if c.MaxBackoff < c.InitialBackoff {
		c.MaxBackoff = c.InitialBackoff
	}
	if c.RingCapacity <= 0 {
		c.RingCapacity = DefaultRingCapacity
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
	return c
}

// StreamClient consumes the Tetragon gRPC event stream, normalises each event,
// buffers it, and forwards it to a FlowProcessor.
type StreamClient struct {
	cfg        StreamConfig
	normalizer *Normalizer
	ring       *RingBuffer
	metrics    *Metrics
	proc       FlowProcessor
	nsAllow    map[string]struct{}

	nodeMu       sync.RWMutex
	lastSeenNode string
}

// NewStreamClient constructs a StreamClient. proc may be nil, in which case
// events are normalised and buffered but not forwarded — useful for measuring
// stream throughput in isolation.
func NewStreamClient(cfg StreamConfig, proc FlowProcessor) *StreamClient {
	cfg = cfg.withDefaults()

	var nsAllow map[string]struct{}
	if len(cfg.AllowedNamespaces) > 0 {
		nsAllow = make(map[string]struct{}, len(cfg.AllowedNamespaces))
		for _, ns := range cfg.AllowedNamespaces {
			if ns = strings.TrimSpace(ns); ns != "" {
				nsAllow[ns] = struct{}{}
			}
		}
	}

	return &StreamClient{
		cfg:        cfg,
		normalizer: NewNormalizer(),
		ring:       NewRingBuffer(cfg.RingCapacity),
		metrics:    NewMetrics(),
		proc:       proc,
		nsAllow:    nsAllow,
	}
}

// Metrics exposes the client's counters.
func (s *StreamClient) Metrics() *Metrics { return s.metrics }

// Ring exposes the bounded buffer, for drain loops and test assertions.
func (s *StreamClient) Ring() *RingBuffer { return s.ring }

// BackoffSchedule returns the reconnect delays the client would use for the
// first n attempts.
//
// This exists so the backoff policy is directly assertable. Testing backoff by
// timing real reconnects is slow and flaky; testing the schedule that drives
// them is neither, and it is the property that actually matters (non-decreasing,
// capped, deterministic).
func (s *StreamClient) BackoffSchedule(n int) []time.Duration {
	out := make([]time.Duration, 0, n)
	d := s.cfg.InitialBackoff
	for i := 0; i < n; i++ {
		out = append(out, d)
		if d < s.cfg.MaxBackoff {
			d *= backoffMultiplier
			if d > s.cfg.MaxBackoff {
				d = s.cfg.MaxBackoff
			}
		}
	}
	return out
}

// jitter spreads reconnect attempts so that a fleet of collectors reconnecting
// after a Tetragon rollout does not synchronise into a thundering herd against
// a single socket.
//
// The offset is derived from the socket path rather than a random source so the
// schedule stays deterministic and testable: two clients on different sockets
// get different offsets, and the same client always gets the same one.
func (s *StreamClient) jitter(d time.Duration) time.Duration {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s.cfg.SocketPath))
	// Up to +25% of the base delay.
	frac := time.Duration(h.Sum32()%25) * d / 100
	return d + frac
}

// Run connects to Tetragon and streams events until ctx is cancelled. It
// reconnects on stream failure with capped exponential backoff and only returns
// when ctx is done.
func (s *StreamClient) Run(ctx context.Context) error {
	backoff := s.cfg.InitialBackoff

	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}

		err := s.runOnce(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}

		s.metrics.incErrors()

		// A disconnect is an unbounded telemetry hole: whatever Tetragon
		// emitted while we were gone is lost. Punch a discontinuity into the
		// synthesised sequence so the downstream gap detector actually fires.
		// Without this the detector is vacuous — see Normalizer.MarkLoss.
		s.normalizer.MarkLoss(s.lastNode(), 1)

		s.cfg.Logger.Warn("tetragon stream ended; reconnecting",
			"socket", s.cfg.SocketPath,
			"backoff", backoff.String(),
			"error", err)

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(s.jitter(backoff)):
		}

		if backoff < s.cfg.MaxBackoff {
			backoff *= backoffMultiplier
			if backoff > s.cfg.MaxBackoff {
				backoff = s.cfg.MaxBackoff
			}
		}
	}
}

// runOnce establishes one connection and reads until the stream ends.
func (s *StreamClient) runOnce(ctx context.Context) error {
	conn, err := Dial(ctx, s.cfg.SocketPath)
	if err != nil {
		return fmt.Errorf("dial tetragon %s: %w", s.cfg.SocketPath, err)
	}
	defer conn.Close()

	client := tetragon.NewFineGuidanceSensorsClient(conn)

	stream, err := client.GetEvents(ctx, &tetragon.GetEventsRequest{})
	if err != nil {
		return fmt.Errorf("open GetEvents stream: %w", err)
	}

	s.cfg.Logger.Info("tetragon stream established", "socket", s.cfg.SocketPath)

	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			return fmt.Errorf("tetragon stream closed by server")
		}
		if err != nil {
			return fmt.Errorf("recv: %w", err)
		}
		s.Ingest(ctx, resp)
	}
}

// lastNode returns the most recently observed node name, so a reconnect
// discontinuity is punched into the right node's sequence. Before any event has
// arrived there is nothing to be discontinuous with, and MarkLoss defaults the
// empty string to "unknown-node".
func (s *StreamClient) lastNode() string {
	s.nodeMu.RLock()
	defer s.nodeMu.RUnlock()
	return s.lastSeenNode
}

func (s *StreamClient) setLastNode(node string) {
	if node == "" {
		return
	}
	s.nodeMu.Lock()
	s.lastSeenNode = node
	s.nodeMu.Unlock()
}

// Ingest normalises a single response and pushes it through the ring buffer.
//
// It is exported so that the JSON export path, the mock-driven tests, and the
// gRPC path all share exactly one implementation of the receive-side accounting.
// A second copy of this logic in the JSON decoder would be the obvious place for
// the two paths to drift apart in what they count.
func (s *StreamClient) Ingest(ctx context.Context, resp *tetragon.GetEventsResponse) {
	s.metrics.incReceived()

	if resp != nil {
		s.setLastNode(resp.GetNodeName())
	}

	ev, err := s.normalizer.Normalize(resp)
	if err != nil {
		s.metrics.incErrors()
		return
	}
	if ev == nil {
		s.metrics.incSkipped()
		return
	}

	if !s.namespaceAllowed(ev.PodNamespace) {
		s.metrics.incSkipped()
		return
	}

	// Count events that carry no real Kubernetes identity. Without this series,
	// a cluster where nothing sets the signalloom.io/* pod labels produces a
	// full-looking event stream in which EVERY identity field is empty, and
	// nothing surfaces that fact. See Normalizer.HasPodIdentity.
	if !HasPodIdentity(ev) {
		s.metrics.incIdentityless()
	}

	before := s.ring.Dropped()
	s.ring.Push(ev)

	if lost := s.ring.Dropped() - before; lost > 0 {
		s.metrics.addDropped(lost)
		// A drop is real telemetry loss. Punch it into the sequence so the
		// downstream gap detector reports degraded coverage rather than
		// silently receiving a shorter, still-monotonic stream.
		s.normalizer.MarkLoss(ev.NodeName, lost)
	}
}

// namespaceAllowed reports whether an event's namespace is in contract. An
// empty allow-list means "no restriction". An unattributed event (empty
// namespace) is always allowed through: a syscall we cannot place is a signal,
// not noise, and dropping it would hide exactly the events an escaped workload
// would generate.
func (s *StreamClient) namespaceAllowed(ns string) bool {
	if s.nsAllow == nil || ns == "" {
		return true
	}
	_, ok := s.nsAllow[ns]
	return ok
}

// Drain forwards buffered events to the FlowProcessor until ctx is cancelled or
// the ring is closed. Run and Drain are separate goroutines on purpose: the
// kernel-facing reader must never block on a slow FrostDB write, which is the
// entire reason the bounded ring sits between them.
func (s *StreamClient) Drain(ctx context.Context) error {
	for {
		ev, ok := s.ring.Pop(ctx)
		if !ok {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return nil
		}
		if s.proc != nil {
			if err := s.proc.ProcessFlowEvent(ctx, ev); err != nil {
				s.metrics.incErrors()
				s.cfg.Logger.Warn("flow processor rejected tetragon event",
					"pod", ev.PodName, "namespace", ev.PodNamespace, "error", err)
				continue
			}
		}
		s.metrics.incIngested()
	}
}

// Close releases the ring buffer and wakes any blocked drain loop.
func (s *StreamClient) Close() { s.ring.Close() }

// Dial opens a gRPC connection to a Tetragon unix socket.
//
// The "unix://" prefix is added when absent so callers can pass a bare
// filesystem path — which is what the ConfigMap, the Helm values, and every
// operator-facing document use. Passing a bare path to grpc.NewClient without
// the scheme resolves it as a DNS name and fails with a confusing lookup error
// rather than a connection error.
func Dial(ctx context.Context, socketPath string) (*grpc.ClientConn, error) {
	target := socketPath
	if !strings.Contains(target, "://") {
		target = "unix://" + target
	}
	return grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
}
