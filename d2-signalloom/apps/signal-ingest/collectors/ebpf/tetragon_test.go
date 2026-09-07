// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"bytes"
	"context"
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	tetragon "github.com/cilium/tetragon/api/v1/tetragon"
	"google.golang.org/protobuf/encoding/protojson"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

const (
	testNode = "osramp-control-plane"
	testNS   = "fe-signalloom-agents"
)

var testBase = time.Unix(1757000000, 0).UTC()

// shortTempDir returns a directory with a path short enough for a unix socket.
// t.TempDir() embeds the test name, which for a table-driven subtest easily
// exceeds sun_path's 108-byte limit; bind then fails with "invalid argument",
// which reads like a bug in the server rather than a path-length problem.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "tg")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// ---------------------------------------------------------------------------
// Normalisation (ISC-23..30)
// ---------------------------------------------------------------------------

func TestNormalizeProcessExecPopulatesPodAttribution(t *testing.T) {
	n := NewNormalizer()

	ev, err := n.Normalize(FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", testBase))
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if ev == nil {
		t.Fatal("expected an event, got nil")
	}

	// ISC-23.1 — direct from the Tetragon Pod message.
	if ev.PodName != "agent-0" {
		t.Errorf("PodName = %q, want %q", ev.PodName, "agent-0")
	}
	if ev.PodNamespace != testNS {
		t.Errorf("PodNamespace = %q, want %q", ev.PodNamespace, testNS)
	}

	// ISC-23.2 — derived from pod labels, because Tetragon v1.1.0's Pod message
	// carries neither a UID nor a service account.
	if ev.PodUID != "11111111-2222-3333-4444-555555555555" {
		t.Errorf("PodUID = %q, want the value from the %s label", ev.PodUID, LabelPodUID)
	}
	if ev.ServiceAccount != "agent-cardvault-sa" {
		t.Errorf("ServiceAccount = %q, want the value from the %s label", ev.ServiceAccount, LabelServiceAccount)
	}
	if ev.AgentRole != "cardvault-agent" {
		t.Errorf("AgentRole = %q, want cardvault-agent", ev.AgentRole)
	}
	if !strings.HasPrefix(ev.SPIFFEID, "spiffe://") {
		t.Errorf("SPIFFEID = %q, want a spiffe:// URI", ev.SPIFFEID)
	}

	if ev.Classification != ClassProcessExec {
		t.Errorf("Classification = %q, want %q", ev.Classification, ClassProcessExec)
	}
	if ev.Provider != "tetragon" {
		t.Errorf("Provider = %q, want tetragon", ev.Provider)
	}
	if ev.Domain != "/usr/bin/agent" {
		t.Errorf("Domain = %q, want the executed binary", ev.Domain)
	}
}

// A pod-uid label is not always present. When it is absent the normaliser must
// fall back to the container id rather than leaving an empty string, because an
// empty PodUID is shared by every unattributed event in the cluster and would
// collapse them into one identity-graph node.
func TestNormalizePodUIDFallsBackToContainerID(t *testing.T) {
	n := NewNormalizer()

	src := FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", testBase)
	delete(src.GetProcessExec().GetProcess().GetPod().GetPodLabels(), LabelPodUID)

	ev, err := n.Normalize(src)
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if ev.PodUID != "containerd://c0ffee1234567890" {
		t.Errorf("PodUID = %q, want the container id fallback", ev.PodUID)
	}
}

func TestNormalizeTCPConnectPopulatesDestination(t *testing.T) {
	n := NewNormalizer()

	ev, err := n.Normalize(FixtureConnectEvent(testNode, testNS, "agent-0", "104.18.7.10", 443, testBase))
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}

	if ev.DstIP != "104.18.7.10" {
		t.Errorf("DstIP = %q, want 104.18.7.10", ev.DstIP)
	}
	if ev.DstPort != 443 {
		t.Errorf("DstPort = %d, want 443", ev.DstPort)
	}
	if ev.SrcIP != "10.244.0.17" {
		t.Errorf("SrcIP = %q, want 10.244.0.17", ev.SrcIP)
	}
	if ev.SrcPort != 53124 {
		t.Errorf("SrcPort = %d, want 53124", ev.SrcPort)
	}
	if ev.Family != 2 {
		t.Errorf("Family = %d, want 2 (AF_INET)", ev.Family)
	}
	if ev.SockCookie != 99887766 {
		t.Errorf("SockCookie = %d, want 99887766", ev.SockCookie)
	}
	if ev.Classification != ClassNetworkConnect {
		t.Errorf("Classification = %q, want %q", ev.Classification, ClassNetworkConnect)
	}
	if got := Destination(ev); got != "104.18.7.10:443" {
		t.Errorf("Destination = %q, want 104.18.7.10:443", got)
	}
}

func TestNormalizeOpenatPreservesFilePath(t *testing.T) {
	n := NewNormalizer()
	const path = "/var/run/secrets/kubernetes.io/serviceaccount/token"

	ev, err := n.Normalize(FixtureFileEvent(testNode, testNS, "agent-0", path, testBase))
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if ev.Domain != path {
		t.Errorf("Domain = %q, want the accessed path %q", ev.Domain, path)
	}
	if ev.Classification != ClassFileAccess {
		t.Errorf("Classification = %q, want %q", ev.Classification, ClassFileAccess)
	}
}

// A port above 65535 is truncated data or a wire-format skew. It must be zeroed,
// not wrapped: a wrapped value looks like a plausible destination port and would
// poison correlation with a destination that was never contacted.
func TestNormalizeClampsOutOfRangePort(t *testing.T) {
	if got := clampPort(70000); got != 0 {
		t.Errorf("clampPort(70000) = %d, want 0 (not a truncating wrap)", got)
	}
	if got := clampPort(443); got != 443 {
		t.Errorf("clampPort(443) = %d, want 443", got)
	}
	if got := clampPort(65535); got != 65535 {
		t.Errorf("clampPort(65535) = %d, want 65535", got)
	}
}

// ISC-26: per-node sequence numbers must be strictly monotonic and independent
// across nodes, because the existing gap detector keys on (node, seq).
func TestNormalizeSequenceNumbersAreMonotonicPerNode(t *testing.T) {
	n := NewNormalizer()

	var nodeA, nodeB []uint64
	for i := 0; i < 5; i++ {
		a, _ := n.Normalize(FixtureExecEvent("node-a", testNS, "p", "/bin/a", testBase))
		b, _ := n.Normalize(FixtureExecEvent("node-b", testNS, "p", "/bin/b", testBase))
		nodeA = append(nodeA, a.SeqNum)
		nodeB = append(nodeB, b.SeqNum)
	}

	want := []uint64{1, 2, 3, 4, 5}
	for i := range want {
		if nodeA[i] != want[i] {
			t.Errorf("node-a seq[%d] = %d, want %d", i, nodeA[i], want[i])
		}
		if nodeB[i] != want[i] {
			t.Errorf("node-b seq[%d] = %d, want %d (nodes must not share a counter)", i, nodeB[i], want[i])
		}
	}
}

// ISC-27: timestamps must round-trip into BOTH Time and TimestampNs. Setting
// only one is the failure that makes a store query and a correlation window
// disagree about when an event happened.
func TestNormalizeTimestampRoundTrip(t *testing.T) {
	n := NewNormalizer()
	at := time.Date(2026, 9, 7, 14, 30, 45, 123456789, time.UTC)

	ev, err := n.Normalize(FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", at))
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if !ev.Time.Equal(at) {
		t.Errorf("Time = %v, want %v", ev.Time, at)
	}
	if ev.TimestampNs != uint64(at.UnixNano()) {
		t.Errorf("TimestampNs = %d, want %d", ev.TimestampNs, at.UnixNano())
	}
}

// ISC-28: an event with no pod metadata must normalise without panicking and be
// flagged, not dropped. This is the hostile case — the LLM-adjacent failure mode
// is to handle populated events correctly and crash on the sparse one.
func TestNormalizeUnattributedEventDoesNotPanic(t *testing.T) {
	n := NewNormalizer()

	ev, err := n.Normalize(FixtureUnattributedEvent(testNode, testBase))
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if ev == nil {
		t.Fatal("unattributed event was dropped; it must be ingested and flagged")
	}
	if ev.Classification != ClassUnattributed {
		t.Errorf("Classification = %q, want %q", ev.Classification, ClassUnattributed)
	}
	if ev.PodName != "" || ev.PodNamespace != "" {
		t.Errorf("expected empty pod attribution, got %q/%q", ev.PodNamespace, ev.PodName)
	}
}

// Every field-sparse permutation must survive. Constructed deliberately from
// the outside in: nil response, nil process, nil pod, nil args, empty args.
func TestNormalizeHostileSparseInputs(t *testing.T) {
	n := NewNormalizer()

	if _, err := n.Normalize(nil); err == nil {
		t.Error("Normalize(nil) must return an error, not a zero event")
	}

	cases := map[string]*tetragon.GetEventsResponse{
		"exec with nil process": {
			NodeName: testNode,
			Event:    &tetragon.GetEventsResponse_ProcessExec{ProcessExec: &tetragon.ProcessExec{}},
		},
		"kprobe with nil process and nil args": {
			NodeName: testNode,
			Event: &tetragon.GetEventsResponse_ProcessKprobe{
				ProcessKprobe: &tetragon.ProcessKprobe{FunctionName: SymbolTCPConnect},
			},
		},
		"kprobe with a nil arg element": {
			NodeName: testNode,
			Event: &tetragon.GetEventsResponse_ProcessKprobe{
				ProcessKprobe: &tetragon.ProcessKprobe{
					FunctionName: SymbolTCPConnect,
					Args:         []*tetragon.KprobeArgument{nil, nil},
				},
			},
		},
		"tracepoint with no args": {
			NodeName: testNode,
			Event: &tetragon.GetEventsResponse_ProcessTracepoint{
				ProcessTracepoint: &tetragon.ProcessTracepoint{Subsys: "syscalls", Event: "sys_enter_openat"},
			},
		},
		"response with no time and no node": {
			Event: &tetragon.GetEventsResponse_ProcessExec{ProcessExec: &tetragon.ProcessExec{}},
		},
	}

	for name, in := range cases {
		t.Run(name, func(t *testing.T) {
			ev, err := n.Normalize(in)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if ev == nil {
				t.Fatal("expected an event")
			}
			if ev.NodeName == "" {
				t.Error("NodeName must never be empty; the gap detector keys on it")
			}
			if ev.Time.IsZero() {
				t.Error("Time must be defaulted, never zero")
			}
		})
	}
}

// ISC-30: normalised events must be accepted by the EXISTING netebpf collector
// without modification. This is the contract that makes Tetragon a drop-in
// producer rather than a parallel pipeline.
func TestNormalizedEventsAreAcceptedByNetEBPFCollector(t *testing.T) {
	sink := &recordingSink{}
	flow := newNetEBPFCollector(t, sink)

	n := NewNormalizer()
	sources := []*tetragon.GetEventsResponse{
		FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", testBase),
		FixtureConnectEvent(testNode, testNS, "agent-0", "104.18.7.10", 443, testBase),
		FixtureFileEvent(testNode, testNS, "agent-0", "/etc/shadow", testBase),
	}

	for _, src := range sources {
		ev, err := n.Normalize(src)
		if err != nil {
			t.Fatalf("normalize: %v", err)
		}
		if err := flow.ProcessFlowEvent(context.Background(), ev); err != nil {
			t.Fatalf("netebpf collector rejected a normalised tetragon event: %v", err)
		}
	}

	if got := sink.count(); got != len(sources) {
		t.Errorf("sink received %d observations, want %d", got, len(sources))
	}
}

// ISC-29 (anti): the canonical schema must not be extended by this package. If
// someone adds a Tetragon-specific field to InboundFlowEvent, the SFDP-P2-4
// contract and every sibling fixture break silently — this fails loudly instead.
func TestAntiInboundFlowEventStructIsUnmodified(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "netebpf", "collector.go"))
	if err != nil {
		t.Fatalf("read netebpf collector: %v", err)
	}

	// The exact field set as of the SFDP-P2-4 contract. Counted, not just
	// substring-matched, so an ADDED field is caught as well as a removed one.
	want := []string{
		"TimestampNs", "Time", "CgroupID", "SockCookie", "SeqNum",
		"SrcIP", "DstIP", "SrcPort", "DstPort", "Family",
		"OldState", "NewState", "BytesSent", "BytesRecv",
		"PodName", "PodNamespace", "PodUID", "ServiceAccount",
		"SPIFFEID", "AgentRole", "Provider", "Classification",
		"Domain", "NodeName",
	}

	start := bytes.Index(src, []byte("type InboundFlowEvent struct {"))
	if start < 0 {
		t.Fatal("InboundFlowEvent struct not found — the canonical schema moved")
	}
	end := bytes.Index(src[start:], []byte("\n}"))
	if end < 0 {
		t.Fatal("could not find the end of the InboundFlowEvent struct")
	}
	body := string(src[start : start+end])

	fieldCount := 0
	for _, line := range strings.Split(body, "\n")[1:] {
		if strings.TrimSpace(line) != "" {
			fieldCount++
		}
	}
	if fieldCount != len(want) {
		t.Errorf("InboundFlowEvent has %d fields, want %d — the canonical schema was modified", fieldCount, len(want))
	}
	for _, f := range want {
		if !strings.Contains(body, f+" ") {
			t.Errorf("InboundFlowEvent lost field %q", f)
		}
	}
}

// ---------------------------------------------------------------------------
// Ring buffer (ISC-31..36)
// ---------------------------------------------------------------------------

func TestRingBufferBoundsAndDropPolicy(t *testing.T) {
	rb := NewRingBuffer(3)

	if rb.Capacity() != 3 {
		t.Fatalf("Capacity = %d, want 3", rb.Capacity())
	}

	for i := 1; i <= 3; i++ {
		if ok := rb.Push(&FlowEvent{SeqNum: uint64(i)}); !ok {
			t.Fatalf("push %d reported a drop while the buffer had room", i)
		}
	}
	if rb.Dropped() != 0 {
		t.Fatalf("Dropped = %d before overflow, want 0", rb.Dropped())
	}

	// Overflow. The drop must be COUNTED, not silent — this assertion is the
	// point of the test: a buffer that silently discards satisfies "bounded"
	// while destroying evidence.
	if ok := rb.Push(&FlowEvent{SeqNum: 4}); ok {
		t.Error("push into a full buffer reported success; it must report the eviction")
	}
	if rb.Dropped() != 1 {
		t.Errorf("Dropped = %d after one overflow, want 1", rb.Dropped())
	}
	if rb.Len() != 3 {
		t.Errorf("Len = %d, want 3 — the buffer must not have grown", rb.Len())
	}

	// Drop-oldest: seq 1 is gone, 2/3/4 remain in order.
	var got []uint64
	for {
		ev, ok := rb.TryPop()
		if !ok {
			break
		}
		got = append(got, ev.SeqNum)
	}
	want := []uint64{2, 3, 4}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("drained %v, want %v (drop-oldest, FIFO order)", got, want)
	}
}

func TestRingBufferZeroCapacityFallsBackToDefault(t *testing.T) {
	// A zero-capacity ring would drop 100% of input while every counter still
	// moved — the worst kind of failure, because it looks like it is working.
	rb := NewRingBuffer(0)
	if rb.Capacity() != DefaultRingCapacity {
		t.Errorf("Capacity = %d, want the %d default", rb.Capacity(), DefaultRingCapacity)
	}
	if ok := rb.Push(&FlowEvent{SeqNum: 1}); !ok {
		t.Error("a fresh default-capacity buffer must accept its first event")
	}
}

func TestRingBufferConcurrentProducerConsumer(t *testing.T) {
	rb := NewRingBuffer(64)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const total = 2000
	var wg sync.WaitGroup

	consumed := make(chan int, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		n := 0
		for {
			ev, ok := rb.Pop(ctx)
			if !ok {
				break
			}
			if ev != nil {
				n++
			}
		}
		consumed <- n
	}()

	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(base int) {
			defer wg.Done()
			for j := 0; j < total/4; j++ {
				rb.Push(&FlowEvent{SeqNum: uint64(base*1000 + j)})
			}
		}(i)
	}

	// Wait for producers, then close so the consumer terminates.
	go func() {
		time.Sleep(500 * time.Millisecond)
		rb.Close()
	}()

	wg.Wait()
	n := <-consumed

	// The exact count depends on scheduling, but consumed + dropped + still
	// buffered must never exceed what was produced. Conservation is the
	// invariant; a violation means the buffer duplicated or lost silently.
	accounted := uint64(n) + rb.Dropped() + uint64(rb.Len())
	if accounted > total {
		t.Errorf("accounted for %d events but only %d were produced", accounted, total)
	}
	if n == 0 {
		t.Error("consumer received nothing")
	}
}

func TestRingBufferPopUnblocksOnContextCancel(t *testing.T) {
	rb := NewRingBuffer(4)
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		rb.Pop(ctx)
		close(done)
	}()

	time.Sleep(50 * time.Millisecond)
	cancel()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Pop did not unblock on context cancellation; shutdown would hang")
	}
}

// ---------------------------------------------------------------------------
// Metrics (ISC-37..41)
// ---------------------------------------------------------------------------

func TestMetricsExposeAllRequiredSeries(t *testing.T) {
	m := NewMetrics()
	out := m.Render()

	required := []string{
		MetricFlowEventsIngested, // named in the card's deliverables
		MetricStreamErrors,       // named in the card's deliverables
		MetricEventsReceived,     // named in the card's polling loop
		MetricEventsDropped,      // required to make the drop policy observable
		MetricEventsSkipped,
	}

	for _, name := range required {
		if !strings.Contains(out, "# HELP "+name+" ") {
			t.Errorf("missing HELP line for %s", name)
		}
		if !strings.Contains(out, "# TYPE "+name+" counter") {
			t.Errorf("missing TYPE line for %s", name)
		}
		if !strings.Contains(out, "\n"+name+" ") && !strings.HasPrefix(out, name+" ") {
			t.Errorf("missing sample line for %s", name)
		}
	}

	// Every metric with a HELP entry must be rendered, and vice versa. Without
	// this, adding a counter to metricHelp but not to Snapshot would produce a
	// documented metric that never appears.
	if len(metricHelp) != len(m.Snapshot()) {
		t.Errorf("metricHelp has %d entries but Snapshot returns %d", len(metricHelp), len(m.Snapshot()))
	}
}

func TestMetricsRenderIsDeterministic(t *testing.T) {
	m := NewMetrics()
	m.incReceived()
	first := m.Render()
	for i := 0; i < 20; i++ {
		if m.Render() != first {
			t.Fatal("Render output is not byte-stable; a map range leaked into the ordering")
		}
	}
}

func TestMetricsCountersIncrement(t *testing.T) {
	m := NewMetrics()
	m.incReceived()
	m.incReceived()
	m.incIngested()
	m.incErrors()
	m.incSkipped()
	m.addDropped(7)
	m.addDropped(0) // must be a no-op

	snap := m.Snapshot()
	for name, want := range map[string]uint64{
		MetricEventsReceived:     2,
		MetricFlowEventsIngested: 1,
		MetricStreamErrors:       1,
		MetricEventsSkipped:      1,
		MetricEventsDropped:      7,
	} {
		if snap[name] != want {
			t.Errorf("%s = %d, want %d", name, snap[name], want)
		}
	}
}

// ---------------------------------------------------------------------------
// JSON export path (ISC-19..20)
// ---------------------------------------------------------------------------

func TestStreamJSONDecodesNDJSON(t *testing.T) {
	events := []*tetragon.GetEventsResponse{
		FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", testBase),
		FixtureConnectEvent(testNode, testNS, "agent-0", "104.18.7.10", 443, testBase),
		FixtureFileEvent(testNode, testNS, "agent-0", "/etc/shadow", testBase),
	}

	var buf bytes.Buffer
	for _, ev := range events {
		line, err := protojson.Marshal(ev)
		if err != nil {
			t.Fatalf("marshal fixture: %v", err)
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}

	sc := NewStreamClient(StreamConfig{SocketPath: "/tmp/unused.sock"}, nil)

	n, err := sc.StreamJSON(context.Background(), &buf)
	if err != nil {
		t.Fatalf("StreamJSON: %v", err)
	}
	if n != len(events) {
		t.Errorf("decoded %d lines, want %d", n, len(events))
	}

	snap := sc.Metrics().Snapshot()
	if snap[MetricEventsReceived] != uint64(len(events)) {
		t.Errorf("%s = %d, want %d", MetricEventsReceived, snap[MetricEventsReceived], len(events))
	}
	if snap[MetricStreamErrors] != 0 {
		t.Errorf("%s = %d on a clean stream, want 0", MetricStreamErrors, snap[MetricStreamErrors])
	}
	if got := sc.Ring().Len(); got != len(events) {
		t.Errorf("ring holds %d events, want %d — no data loss permitted", got, len(events))
	}
}

// ISC-20: one malformed line must not terminate the stream. Log rotation racing
// the exporter produces exactly this, and aborting would silently end telemetry
// ingestion for the rest of the process lifetime.
func TestStreamJSONSurvivesMalformedLine(t *testing.T) {
	good, err := protojson.Marshal(FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", testBase))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	input := strings.Join([]string{
		string(good),
		"{ this is not json",
		"",
		`{"node_name":"n","time":"not-a-timestamp"}`,
		string(good),
	}, "\n")

	sc := NewStreamClient(StreamConfig{SocketPath: "/tmp/unused.sock"}, nil)

	n, err := sc.StreamJSON(context.Background(), strings.NewReader(input))
	if err != nil {
		t.Fatalf("StreamJSON returned an error; a bad line must not be fatal: %v", err)
	}
	if n != 2 {
		t.Errorf("decoded %d good lines, want 2", n)
	}

	snap := sc.Metrics().Snapshot()
	if snap[MetricStreamErrors] < 2 {
		t.Errorf("%s = %d, want at least 2 — malformed lines must be counted, not swallowed",
			MetricStreamErrors, snap[MetricStreamErrors])
	}
}

// A blank line is not an error; it is what a trailing newline produces.
func TestDecodeJSONEventBlankLineIsNotAnError(t *testing.T) {
	resp, err := DecodeJSONEvent([]byte("   \n"))
	if err != nil {
		t.Fatalf("blank line returned an error: %v", err)
	}
	if resp != nil {
		t.Error("blank line produced an event")
	}
}

// Forward compatibility: an agent one minor version ahead adds fields. Those
// events must still decode, or a Tetragon upgrade silently blanks the pipeline.
func TestDecodeJSONEventDiscardsUnknownFields(t *testing.T) {
	line := `{"node_name":"n","some_future_field":{"a":1},"process_exec":{"process":{"binary":"/bin/ls"}}}`
	resp, err := DecodeJSONEvent([]byte(line))
	if err != nil {
		t.Fatalf("unknown field was fatal; a Tetragon minor upgrade would blank the stream: %v", err)
	}
	if resp.GetProcessExec().GetProcess().GetBinary() != "/bin/ls" {
		t.Error("known fields were not preserved alongside the unknown one")
	}
}

// ---------------------------------------------------------------------------
// gRPC stream against the real generated service (ISC-15..18, 35)
// ---------------------------------------------------------------------------

func TestStreamClientIngestsFromMockGRPCServer(t *testing.T) {
	srv := NewMockTetragonServer([]*tetragon.GetEventsResponse{
		FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", testBase),
		FixtureConnectEvent(testNode, testNS, "agent-0", "104.18.7.10", 443, testBase),
		FixtureFileEvent(testNode, testNS, "agent-0", "/etc/shadow", testBase),
		FixtureExitEvent(testNode, testBase), // no normalisable payload → skipped
	})

	stop, err := srv.Serve(shortTempDir(t))
	if err != nil {
		t.Fatalf("serve mock: %v", err)
	}
	defer stop()

	sink := &recordingSink{}
	flow := newNetEBPFCollector(t, sink)

	sc := NewStreamClient(StreamConfig{
		SocketPath:     srv.SocketPath(),
		InitialBackoff: 10 * time.Millisecond,
		MaxBackoff:     50 * time.Millisecond,
	}, flow)
	defer sc.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	go func() { _ = sc.Run(ctx) }()
	go func() { _ = sc.Drain(ctx) }()

	waitFor(t, 5*time.Second, func() bool {
		return sc.Metrics().Snapshot()[MetricFlowEventsIngested] >= 3
	}, "3 flow events ingested over gRPC")

	snap := sc.Metrics().Snapshot()
	if snap[MetricEventsReceived] < 4 {
		t.Errorf("%s = %d, want >= 4", MetricEventsReceived, snap[MetricEventsReceived])
	}
	if snap[MetricEventsSkipped] < 1 {
		t.Errorf("%s = %d, want >= 1 (the ProcessExit event)", MetricEventsSkipped, snap[MetricEventsSkipped])
	}
	if snap[MetricEventsDropped] != 0 {
		t.Errorf("%s = %d, want 0", MetricEventsDropped, snap[MetricEventsDropped])
	}
	if got := sink.count(); got < 3 {
		t.Errorf("sink received %d observations, want >= 3", got)
	}
}

// ISC-35: a 1,000-event burst with a draining consumer must lose nothing. This
// is the card's stated acceptance threshold.
func TestStreamClientBurstOfOneThousandDropsNothing(t *testing.T) {
	const burst = 1000

	srv := NewMockTetragonServer(FixtureBurst(testNode, testNS, burst))
	stop, err := srv.Serve(shortTempDir(t))
	if err != nil {
		t.Fatalf("serve mock: %v", err)
	}
	defer stop()

	sink := &recordingSink{}
	flow := newNetEBPFCollector(t, sink)

	sc := NewStreamClient(StreamConfig{
		SocketPath:     srv.SocketPath(),
		InitialBackoff: 10 * time.Millisecond,
		MaxBackoff:     50 * time.Millisecond,
		RingCapacity:   DefaultRingCapacity,
	}, flow)
	defer sc.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	start := time.Now()
	go func() { _ = sc.Run(ctx) }()
	go func() { _ = sc.Drain(ctx) }()

	waitFor(t, 20*time.Second, func() bool {
		return sc.Metrics().Snapshot()[MetricFlowEventsIngested] >= burst
	}, fmt.Sprintf("%d events ingested", burst))

	elapsed := time.Since(start)
	snap := sc.Metrics().Snapshot()

	if snap[MetricEventsDropped] != 0 {
		t.Errorf("%s = %d after a %d-event burst, want 0", MetricEventsDropped, snap[MetricEventsDropped], burst)
	}
	if snap[MetricEventsReceived] != burst {
		t.Errorf("%s = %d, want exactly %d", MetricEventsReceived, snap[MetricEventsReceived], burst)
	}
	if snap[MetricFlowEventsIngested] != burst {
		t.Errorf("%s = %d, want exactly %d", MetricFlowEventsIngested, snap[MetricFlowEventsIngested], burst)
	}
	t.Logf("burst of %d ingested in %s with 0 drops", burst, elapsed)
}

// ISC-17: the client must reconnect after the server ends the stream. Tetragon
// restarts are routine; a collector that gave up would leave a permanent hole.
func TestStreamClientReconnectsAfterStreamEnds(t *testing.T) {
	srv := NewMockTetragonServer([]*tetragon.GetEventsResponse{
		FixtureExecEvent(testNode, testNS, "agent-0", "/usr/bin/agent", testBase),
	})
	srv.SetCloseAfterSend(true) // end the stream each time, forcing reconnects

	stop, err := srv.Serve(shortTempDir(t))
	if err != nil {
		t.Fatalf("serve mock: %v", err)
	}
	defer stop()

	sc := NewStreamClient(StreamConfig{
		SocketPath:     srv.SocketPath(),
		InitialBackoff: 5 * time.Millisecond,
		MaxBackoff:     20 * time.Millisecond,
	}, nil)
	defer sc.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	go func() { _ = sc.Run(ctx) }()

	// More events received than the server holds proves the client reconnected
	// and re-consumed — a single connection could only ever deliver one.
	waitFor(t, 5*time.Second, func() bool {
		return sc.Metrics().Snapshot()[MetricEventsReceived] >= 3
	}, "at least 3 events across reconnects")

	if got := sc.Metrics().Snapshot()[MetricStreamErrors]; got < 2 {
		t.Errorf("%s = %d, want >= 2 — each reconnect must be counted", MetricStreamErrors, got)
	}
}

// ISC-18: backoff must be non-decreasing and capped. Asserted on the schedule
// rather than by timing real reconnects, which would be slow and flaky.
func TestBackoffScheduleIsNonDecreasingAndCapped(t *testing.T) {
	sc := NewStreamClient(StreamConfig{
		SocketPath:     "/tmp/unused.sock",
		InitialBackoff: 100 * time.Millisecond,
		MaxBackoff:     time.Second,
	}, nil)

	sched := sc.BackoffSchedule(10)

	for i := 1; i < len(sched); i++ {
		if sched[i] < sched[i-1] {
			t.Errorf("backoff decreased at step %d: %v then %v", i, sched[i-1], sched[i])
		}
	}
	for i, d := range sched {
		if d > time.Second {
			t.Errorf("backoff[%d] = %v exceeds the 1s cap", i, d)
		}
	}
	if sched[0] != 100*time.Millisecond {
		t.Errorf("first backoff = %v, want the configured initial 100ms", sched[0])
	}
	if last := sched[len(sched)-1]; last != time.Second {
		t.Errorf("backoff did not reach the cap; last = %v, want 1s", last)
	}
}

// Jitter must stay within the base..base+25% band. Unbounded jitter would let a
// 30s cap become an arbitrary delay.
func TestJitterStaysWithinBand(t *testing.T) {
	sc := NewStreamClient(StreamConfig{SocketPath: "/tmp/a.sock"}, nil)
	base := time.Second

	got := sc.jitter(base)
	if got < base || got > base+base/4 {
		t.Errorf("jitter(%v) = %v, want within [%v, %v]", base, got, base, base+base/4)
	}

	// Deterministic: same socket, same offset. A random source here would make
	// the reconnect schedule untestable.
	if sc.jitter(base) != got {
		t.Error("jitter is not deterministic for a fixed socket path")
	}
}

// ISC-22: ModeOff must do nothing at all — no dial, no goroutines.
func TestCollectorModeOffDoesNothing(t *testing.T) {
	sink := &recordingSink{}
	c := NewCollector(collectors.ModeOff, sink, StreamConfig{SocketPath: "/tmp/nonexistent.sock"})

	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start in ModeOff returned an error: %v", err)
	}
	if c.Client() != nil {
		t.Error("ModeOff created a stream client")
	}
	if sink.count() != 0 {
		t.Error("ModeOff ingested observations")
	}
	if c.Name() != CollectorName {
		t.Errorf("Name = %q, want %q", c.Name(), CollectorName)
	}
	// ISC-21: distinct from the netebpf collector so the two are independently
	// gateable and independently diagnosable.
	if c.Name() == "netebpf" {
		t.Error("the tetragon collector must not shadow the netebpf collector name")
	}
}

func TestCollectorModeFixtureIngestsOneOfEachClass(t *testing.T) {
	sink := &recordingSink{}
	c := NewCollector(collectors.ModeFixture, sink, StreamConfig{})

	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start in ModeFixture: %v", err)
	}
	if got := sink.count(); got != 3 {
		t.Errorf("fixture mode produced %d observations, want 3", got)
	}
}

func TestCollectorFromEnvDefaultsToOff(t *testing.T) {
	for _, k := range []string{EnvMode, EnvModeAlt, EnvModeLegacy} {
		t.Setenv(k, "")
	}
	c := NewCollectorFromEnv(&recordingSink{})
	if c.Mode() != collectors.ModeOff {
		t.Errorf("Mode = %q with no env set, want off", c.Mode())
	}
}

func TestCollectorFromEnvReadsConfiguration(t *testing.T) {
	t.Setenv(EnvMode, "live")
	t.Setenv(EnvSocketPath, "/tmp/custom.sock")
	t.Setenv(EnvRingCapacity, "128")
	t.Setenv(EnvAllowedNamespaces, "fe-signalloom-agents, kagent ")

	c := NewCollectorFromEnv(&recordingSink{})
	if c.Mode() != collectors.ModeLive {
		t.Errorf("Mode = %q, want live", c.Mode())
	}
	if c.cfg.SocketPath != "/tmp/custom.sock" {
		t.Errorf("SocketPath = %q, want /tmp/custom.sock", c.cfg.SocketPath)
	}
	if c.cfg.RingCapacity != 128 {
		t.Errorf("RingCapacity = %d, want 128", c.cfg.RingCapacity)
	}
	if len(c.cfg.AllowedNamespaces) != 2 {
		t.Fatalf("AllowedNamespaces = %v, want 2 entries with whitespace trimmed", c.cfg.AllowedNamespaces)
	}
	if c.cfg.AllowedNamespaces[1] != "kagent" {
		t.Errorf("AllowedNamespaces[1] = %q, want %q (untrimmed)", c.cfg.AllowedNamespaces[1], "kagent")
	}
}

// Namespace filtering is defence in depth behind the TracingPolicy scoping.
// An unattributed event must still get through: a syscall we cannot place is
// exactly what an escaped workload produces, so filtering it would blind us to
// the case the control exists for.
func TestNamespaceFilterAllowsUnattributedButRejectsOutOfContract(t *testing.T) {
	sc := NewStreamClient(StreamConfig{
		SocketPath:        "/tmp/unused.sock",
		AllowedNamespaces: []string{"fe-signalloom-agents"},
	}, nil)

	if !sc.namespaceAllowed("fe-signalloom-agents") {
		t.Error("in-contract namespace was rejected")
	}
	if sc.namespaceAllowed("kube-system") {
		t.Error("out-of-contract namespace was allowed")
	}
	if !sc.namespaceAllowed("") {
		t.Error("unattributed event was filtered out; that hides the escape case")
	}

	// No allow-list configured means no restriction.
	open := NewStreamClient(StreamConfig{SocketPath: "/tmp/unused.sock"}, nil)
	if !open.namespaceAllowed("anything") {
		t.Error("an empty allow-list must not restrict")
	}
}

func TestIngestCountsOutOfContractNamespaceAsSkipped(t *testing.T) {
	sc := NewStreamClient(StreamConfig{
		SocketPath:        "/tmp/unused.sock",
		AllowedNamespaces: []string{"fe-signalloom-agents"},
	}, nil)

	sc.Ingest(context.Background(), FixtureExecEvent(testNode, "kube-system", "kubelet", "/usr/bin/kubelet", testBase))

	snap := sc.Metrics().Snapshot()
	if snap[MetricEventsReceived] != 1 {
		t.Errorf("%s = %d, want 1", MetricEventsReceived, snap[MetricEventsReceived])
	}
	if snap[MetricEventsSkipped] != 1 {
		t.Errorf("%s = %d, want 1", MetricEventsSkipped, snap[MetricEventsSkipped])
	}
	if sc.Ring().Len() != 0 {
		t.Error("an out-of-contract event reached the ring buffer")
	}
}

func TestCollectorHealthReportsMissingSocket(t *testing.T) {
	c := NewCollector(collectors.ModeLive, &recordingSink{},
		StreamConfig{SocketPath: "/tmp/definitely-not-a-tetragon-socket-9f8e7d.sock"})

	if err := c.Health(context.Background()); err == nil {
		t.Error("Health returned nil with the socket absent; the most common misconfiguration would read as healthy")
	}

	// ModeOff must be healthy regardless — an off collector has nothing to dial.
	off := NewCollector(collectors.ModeOff, &recordingSink{}, StreamConfig{SocketPath: "/tmp/nope.sock"})
	if err := off.Health(context.Background()); err != nil {
		t.Errorf("ModeOff Health = %v, want nil", err)
	}
}

// ---------------------------------------------------------------------------
// Package isolation (anti-criterion)
// ---------------------------------------------------------------------------

// This package imports its parent for the shared Mode type. That is legal only
// while the parent does not import back. If someone registers the tetragon
// collector inside collectors/registry.go, the build breaks with an import
// cycle — this test explains why before the compiler does, and guards the
// "isolated subpackage" requirement from the card's collision note.
func TestAntiParentPackageDoesNotImportEbpf(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, "..", func(fi os.FileInfo) bool {
		return strings.HasSuffix(fi.Name(), ".go")
	}, parser.ImportsOnly)
	if err != nil {
		t.Fatalf("parse parent package: %v", err)
	}

	const self = "collectors/ebpf"
	for pkgName, pkg := range pkgs {
		for fileName, file := range pkg.Files {
			for _, imp := range file.Imports {
				if strings.Contains(imp.Path.Value, self) {
					t.Errorf("%s/%s imports %s — this creates an import cycle, because "+
						"collectors/ebpf imports collectors for the Mode type. Register the "+
						"tetragon collector from main.go instead.", pkgName, fileName, self)
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// newNetEBPFCollector returns the REAL netebpf collector, not a double. The
// contract under test is that Tetragon events are accepted by the existing
// pipeline; a stub would test only that our own struct satisfies our own
// interface, which proves nothing about the integration.
func newNetEBPFCollector(t *testing.T, sink *recordingSink) *netebpf.LiveNetworkEgressCollector {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	return netebpf.NewLiveNetworkEgressCollector(ctx, sink)
}

type recordingSink struct {
	mu  sync.Mutex
	obs []*model.Observation
}

func (r *recordingSink) IngestObservation(_ context.Context, obs *model.Observation) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.obs = append(r.obs, obs)
	return nil
}

func (r *recordingSink) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.obs)
}

func waitFor(t *testing.T, limit time.Duration, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out after %s waiting for: %s", limit, what)
}
