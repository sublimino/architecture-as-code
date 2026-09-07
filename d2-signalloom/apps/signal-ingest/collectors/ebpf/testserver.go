// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	tetragon "github.com/cilium/tetragon/api/v1/tetragon"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// MockTetragonServer is an in-process implementation of Tetragon's real
// FineGuidanceSensors gRPC service.
//
// It is exported (not test-only) on purpose. The same server backs three
// consumers: the unit tests in this package, the standalone mock binary in
// test/mocks/ that the BATS suite drives, and scripts/test-tetragon-stream.sh.
// Three copies of a fake would be three chances for the fake to disagree with
// itself about the wire format; one shared implementation cannot.
//
// It speaks the genuine generated protobuf service, so a test that passes
// against it exercises real protobuf marshalling and real gRPC framing — the
// only thing missing versus a live Tetragon is the kernel.
type MockTetragonServer struct {
	tetragon.UnimplementedFineGuidanceSensorsServer

	mu     sync.Mutex
	events []*tetragon.GetEventsResponse
	// interEventDelay throttles emission so a test can assert on latency
	// without the whole burst arriving in one scheduler slice.
	interEventDelay time.Duration
	// closeAfterSend makes the server end the stream once its backlog is
	// drained, which is how reconnect behaviour gets exercised.
	closeAfterSend bool

	grpcServer *grpc.Server
	socketPath string
}

// NewMockTetragonServer returns a mock server preloaded with events.
func NewMockTetragonServer(events []*tetragon.GetEventsResponse) *MockTetragonServer {
	return &MockTetragonServer{events: events}
}

// SetInterEventDelay sets the pause between emitted events.
func (m *MockTetragonServer) SetInterEventDelay(d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.interEventDelay = d
}

// SetCloseAfterSend makes GetEvents return once the backlog is exhausted.
func (m *MockTetragonServer) SetCloseAfterSend(v bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closeAfterSend = v
}

// SocketPath returns the unix socket the server is listening on.
func (m *MockTetragonServer) SocketPath() string { return m.socketPath }

// GetEvents implements the streaming half of FineGuidanceSensors.
func (m *MockTetragonServer) GetEvents(_ *tetragon.GetEventsRequest, stream tetragon.FineGuidanceSensors_GetEventsServer) error {
	m.mu.Lock()
	events := make([]*tetragon.GetEventsResponse, len(m.events))
	copy(events, m.events)
	delay := m.interEventDelay
	closeAfter := m.closeAfterSend
	m.mu.Unlock()

	for _, ev := range events {
		if err := stream.Send(ev); err != nil {
			return err
		}
		if delay > 0 {
			time.Sleep(delay)
		}
	}

	if closeAfter {
		return nil
	}

	// Hold the stream open until the client disconnects, which is what a real
	// Tetragon does on an idle node.
	<-stream.Context().Done()
	return stream.Context().Err()
}

// GetHealth implements the health half of the service so that a client probing
// health against the mock gets a real answer rather than Unimplemented.
func (m *MockTetragonServer) GetHealth(_ context.Context, _ *tetragon.GetHealthStatusRequest) (*tetragon.GetHealthStatusResponse, error) {
	return &tetragon.GetHealthStatusResponse{
		HealthStatus: []*tetragon.HealthStatus{
			{Event: tetragon.HealthStatusType_HEALTH_STATUS_TYPE_STATUS, Status: tetragon.HealthStatusResult_HEALTH_STATUS_RUNNING},
		},
	}, nil
}

// Serve starts the mock on a unix socket and returns a stop function.
//
// The socket path is placed directly under the given directory with a short
// name because a unix socket path is capped at 108 bytes by sun_path. A test
// using t.TempDir() plus a descriptive filename can exceed that, and the
// failure surfaces as "invalid argument" from bind — which reads like a code
// bug rather than a path-length limit.
func (m *MockTetragonServer) Serve(dir string) (stop func(), err error) {
	if dir == "" {
		dir = os.TempDir()
	}
	sock := filepath.Join(dir, "tg.sock")
	if len(sock) > 100 {
		return nil, fmt.Errorf("socket path %q is %d bytes; unix sun_path caps at 108", sock, len(sock))
	}

	_ = os.Remove(sock)

	lis, err := net.Listen("unix", sock)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", sock, err)
	}

	m.socketPath = sock
	m.grpcServer = grpc.NewServer()
	tetragon.RegisterFineGuidanceSensorsServer(m.grpcServer, m)

	go func() { _ = m.grpcServer.Serve(lis) }()

	return func() {
		m.grpcServer.Stop()
		_ = os.Remove(sock)
	}, nil
}

// ---------------------------------------------------------------------------
// Fixture builders — the canonical shapes of each modelled event class.
// ---------------------------------------------------------------------------

// FixturePod returns a Pod message carrying the well-known labels the
// normaliser reads PodUID and ServiceAccount from.
func FixturePod(namespace, name string) *tetragon.Pod {
	return &tetragon.Pod{
		Namespace: namespace,
		Name:      name,
		Container: &tetragon.Container{
			Id:   "containerd://c0ffee1234567890",
			Name: "agent",
			Pid:  wrapperspb.UInt32(1),
		},
		PodLabels: map[string]string{
			LabelPodUID:         "11111111-2222-3333-4444-555555555555",
			LabelServiceAccount: "agent-cardvault-sa",
			LabelAgentRole:      "cardvault-agent",
			LabelSPIFFEID:       "spiffe://signalloom/ns/" + namespace + "/sa/agent-cardvault-sa",
		},
	}
}

// FixtureProcess returns a Process message with pod attribution.
func FixtureProcess(namespace, name, binary string) *tetragon.Process {
	return &tetragon.Process{
		ExecId:    "exec-" + name,
		Pid:       wrapperspb.UInt32(4242),
		Uid:       wrapperspb.UInt32(0),
		Binary:    binary,
		Arguments: "--serve",
		Docker:    "c0ffee123456789",
		Pod:       FixturePod(namespace, name),
		StartTime: timestamppb.New(time.Unix(1757000000, 0).UTC()),
	}
}

// FixtureExecEvent builds a ProcessExec response.
func FixtureExecEvent(node, namespace, name, binary string, at time.Time) *tetragon.GetEventsResponse {
	return &tetragon.GetEventsResponse{
		NodeName: node,
		Time:     timestamppb.New(at),
		Event: &tetragon.GetEventsResponse_ProcessExec{
			ProcessExec: &tetragon.ProcessExec{
				Process: FixtureProcess(namespace, name, binary),
			},
		},
	}
}

// FixtureConnectEvent builds a ProcessKprobe(tcp_connect) response.
func FixtureConnectEvent(node, namespace, name, dstIP string, dstPort uint32, at time.Time) *tetragon.GetEventsResponse {
	return &tetragon.GetEventsResponse{
		NodeName: node,
		Time:     timestamppb.New(at),
		Event: &tetragon.GetEventsResponse_ProcessKprobe{
			ProcessKprobe: &tetragon.ProcessKprobe{
				Process:      FixtureProcess(namespace, name, "/usr/bin/curl"),
				FunctionName: SymbolTCPConnect,
				PolicyName:   "agent-tcp-connect-audit",
				Args: []*tetragon.KprobeArgument{
					{Arg: &tetragon.KprobeArgument_SockArg{SockArg: &tetragon.KprobeSock{
						Family:   "AF_INET",
						Type:     "SOCK_STREAM",
						Protocol: "IPPROTO_TCP",
						Saddr:    "10.244.0.17",
						Daddr:    dstIP,
						Sport:    53124,
						Dport:    dstPort,
						Cookie:   99887766,
						State:    "TCP_SYN_SENT",
					}}},
				},
			},
		},
	}
}

// FixtureFileEvent builds a ProcessKprobe(openat) response.
func FixtureFileEvent(node, namespace, name, path string, at time.Time) *tetragon.GetEventsResponse {
	return &tetragon.GetEventsResponse{
		NodeName: node,
		Time:     timestamppb.New(at),
		Event: &tetragon.GetEventsResponse_ProcessKprobe{
			ProcessKprobe: &tetragon.ProcessKprobe{
				Process:      FixtureProcess(namespace, name, "/bin/cat"),
				FunctionName: SymbolOpenat,
				PolicyName:   "agent-sensitive-file-audit",
				Args: []*tetragon.KprobeArgument{
					{Arg: &tetragon.KprobeArgument_FileArg{FileArg: &tetragon.KprobeFile{
						Mount:      "/",
						Path:       path,
						Flags:      "O_RDONLY",
						Permission: "-r--------",
					}}},
				},
			},
		},
	}
}

// FixtureUnattributedEvent builds an exec event with NO pod metadata, which is
// what a host-namespace process or a pre-enrichment event looks like.
func FixtureUnattributedEvent(node string, at time.Time) *tetragon.GetEventsResponse {
	return &tetragon.GetEventsResponse{
		NodeName: node,
		Time:     timestamppb.New(at),
		Event: &tetragon.GetEventsResponse_ProcessExec{
			ProcessExec: &tetragon.ProcessExec{
				Process: &tetragon.Process{ExecId: "exec-orphan", Binary: "/bin/sh"},
			},
		},
	}
}

// FixtureExitEvent builds a ProcessExit response — a well-formed event with no
// normalisable payload, used to prove skips are counted rather than errored.
func FixtureExitEvent(node string, at time.Time) *tetragon.GetEventsResponse {
	return &tetragon.GetEventsResponse{
		NodeName: node,
		Time:     timestamppb.New(at),
		Event: &tetragon.GetEventsResponse_ProcessExit{
			ProcessExit: &tetragon.ProcessExit{
				Process: FixtureProcess("fe-signalloom-agents", "agent-1", "/usr/bin/agent"),
			},
		},
	}
}

// FixtureBurst returns n exec events, for the 1,000-event burst acceptance test.
func FixtureBurst(node, namespace string, n int) []*tetragon.GetEventsResponse {
	base := time.Unix(1757000000, 0).UTC()
	out := make([]*tetragon.GetEventsResponse, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, FixtureExecEvent(node, namespace,
			fmt.Sprintf("agent-%d", i), "/usr/bin/agent", base.Add(time.Duration(i)*time.Millisecond)))
	}
	return out
}

// FixtureFlowEvents returns already-normalised events for ModeFixture, one of
// each modelled class.
func FixtureFlowEvents() []*FlowEvent {
	n := NewNormalizer()
	base := time.Unix(1757000000, 0).UTC()

	sources := []*tetragon.GetEventsResponse{
		FixtureExecEvent("osramp-control-plane", "fe-signalloom-agents", "agent-cardvault-0", "/usr/bin/agent", base),
		FixtureConnectEvent("osramp-control-plane", "fe-signalloom-agents", "agent-cardvault-0", "104.18.7.10", 443, base.Add(time.Second)),
		FixtureFileEvent("osramp-control-plane", "fe-signalloom-agents", "agent-cardvault-0",
			"/var/run/secrets/kubernetes.io/serviceaccount/token", base.Add(2*time.Second)),
	}

	out := make([]*FlowEvent, 0, len(sources))
	for _, s := range sources {
		if ev, err := n.Normalize(s); err == nil && ev != nil {
			out = append(out, ev)
		}
	}
	return out
}
