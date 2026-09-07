// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"fmt"
	"hash/fnv"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	tetragon "github.com/cilium/tetragon/api/v1/tetragon"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
)

// Classification values written into InboundFlowEvent.Classification. These are
// the discriminator downstream correlation uses to tell a process event from a
// socket event once both are flattened into the same struct.
const (
	ClassProcessExec    = "process_exec"
	ClassNetworkConnect = "network_connect"
	ClassFileAccess     = "file_access"
	// ClassUnattributed marks an event that carried no Kubernetes pod metadata.
	// Such events are still ingested — a syscall we cannot attribute is more
	// interesting than one we can, not less — but they are flagged so that
	// confidence scoring downstream can discount them.
	ClassUnattributed = "unattributed"
)

// Well-known pod-label keys used to recover fields Tetragon does not carry.
//
// Tetragon v1.1.0's Pod message has exactly six fields: Namespace, Name,
// Container, PodLabels, Workload, WorkloadKind. There is NO pod UID and NO
// service account. The canonical InboundFlowEvent wants both. Rather than
// leave them empty (which would make every Tetragon-sourced observation fail
// the identity-graph join that the SPIRE and kagent collectors satisfy), we
// recover them from pod labels, which Tetragon does propagate when
// tetragon.enableK8sAPI is true.
//
// The downstream contract is: if these labels are absent, the fields are empty
// and the event is still ingested. Absence degrades attribution; it never drops
// evidence.
const (
	LabelPodUID         = "signalloom.io/pod-uid"
	LabelServiceAccount = "signalloom.io/service-account"
	LabelAgentRole      = "signalloom.io/agent-role"
	LabelSPIFFEID       = "signalloom.io/spiffe-id"
)

// Kprobe symbols the normaliser understands. Anything else is skipped rather
// than guessed at — a mis-shaped normalisation is worse than a missing one
// because it enters the evidence store looking authoritative.
const (
	SymbolTCPConnect = "tcp_connect"
	SymbolOpenat     = "sys_enter_openat"
	SymbolOpenat2    = "__x64_sys_openat"
	SymbolFilePerm   = "security_file_permission"
)

// Normalizer converts Tetragon protobuf events into netebpf.InboundFlowEvent.
//
// It owns per-node sequence numbering. The existing
// netebpf.LiveNetworkEgressCollector detects telemetry gaps by looking for
// discontinuities in SeqNum per node; Tetragon's wire format has no sequence
// field, so the Normalizer supplies a strictly monotonic one. This is what
// lets the gap detector work unchanged against a Tetragon-sourced stream —
// including detecting the drops that our own ring buffer reports.
type Normalizer struct {
	mu     sync.Mutex
	seqPer map[string]uint64
}

// NewNormalizer returns a Normalizer with empty per-node sequence state.
func NewNormalizer() *Normalizer {
	return &Normalizer{seqPer: make(map[string]uint64)}
}

// nextSeq returns the next sequence number for a node, starting at 1.
func (n *Normalizer) nextSeq(node string) uint64 {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.seqPer[node]++
	return n.seqPer[node]
}

// MarkLoss advances a node's sequence counter by n, deliberately creating a
// discontinuity that the downstream gap detector will observe.
//
// # Why this exists — read before touching the sequence logic
//
// The counter is synthesised here, so a naive implementation makes the gap
// detector VACUOUS: it looks for discontinuities in a series produced by the
// same code that increments it, so the series is monotonic by construction and
// the detector can never fire. It would sit on the dashboard looking like a live
// coverage control while being structurally incapable of reporting anything.
//
// MarkLoss is what makes it a real control. Every genuine loss source calls it:
//
//   - a gRPC stream reconnect (events emitted while disconnected are gone)
//   - a ring-buffer drop under backpressure
//   - a malformed line in the JSON export
//
// n is the number of events believed lost, or 1 when the count is unknown but
// loss definitely occurred — a reconnect is an unbounded hole, so it is reported
// as at least one and the ADDITIONAL evidence is the paired
// tetragon_stream_errors_total increment. Under-reporting a known-unknowable
// quantity is honest; inventing a number for it is not.
func (n *Normalizer) MarkLoss(node string, lost uint64) {
	if node == "" {
		node = "unknown-node"
	}
	if lost == 0 {
		lost = 1
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	n.seqPer[node] += lost
}

// SeqFor reports the current sequence position for a node, for test assertions.
func (n *Normalizer) SeqFor(node string) uint64 {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.seqPer[node]
}

// Normalize converts a Tetragon GetEventsResponse into an InboundFlowEvent.
//
// It returns (nil, nil) for events that are well-formed but carry no
// normalisable payload — ProcessExit, ProcessLoader, RateLimitInfo, Test. That
// is a skip, not an error: the caller increments tetragon_events_skipped_total.
// It returns an error only when the input is structurally unusable.
func (n *Normalizer) Normalize(resp *tetragon.GetEventsResponse) (*netebpf.InboundFlowEvent, error) {
	if resp == nil {
		return nil, fmt.Errorf("nil tetragon response")
	}

	node := resp.GetNodeName()
	if node == "" {
		node = "unknown-node"
	}

	ts := time.Now().UTC()
	if t := resp.GetTime(); t != nil && t.IsValid() {
		ts = t.AsTime().UTC()
	}

	switch {
	case resp.GetProcessExec() != nil:
		return n.fromExec(node, ts, resp.GetProcessExec()), nil
	case resp.GetProcessKprobe() != nil:
		return n.fromKprobe(node, ts, resp.GetProcessKprobe()), nil
	case resp.GetProcessTracepoint() != nil:
		return n.fromTracepoint(node, ts, resp.GetProcessTracepoint()), nil
	default:
		// ProcessExit / ProcessLoader / ProcessUprobe / RateLimitInfo / Test.
		return nil, nil
	}
}

// base builds the fields common to every normalised event.
func (n *Normalizer) base(node string, ts time.Time, proc *tetragon.Process) *netebpf.InboundFlowEvent {
	ev := &netebpf.InboundFlowEvent{
		NodeName:    node,
		Time:        ts,
		TimestampNs: uint64(ts.UnixNano()),
		SeqNum:      n.nextSeq(node),
		Provider:    "tetragon",
	}

	if proc == nil {
		ev.Classification = ClassUnattributed
		return ev
	}

	// CgroupID: Tetragon does not expose the numeric cgroup id on Process, but
	// the container id is a stable per-cgroup identifier. Hashing it gives a
	// deterministic uint64 that correlates events from the same container,
	// which is what every downstream consumer of CgroupID actually uses it for.
	if proc.GetDocker() != "" {
		ev.CgroupID = hashToUint64(proc.GetDocker())
	}

	pod := proc.GetPod()
	if pod == nil {
		ev.Classification = ClassUnattributed
		return ev
	}

	ev.PodName = pod.GetName()
	ev.PodNamespace = pod.GetNamespace()

	labels := pod.GetPodLabels()
	ev.PodUID = labels[LabelPodUID]
	ev.ServiceAccount = labels[LabelServiceAccount]
	ev.AgentRole = labels[LabelAgentRole]
	ev.SPIFFEID = labels[LabelSPIFFEID]

	// Fall back to the container id when the pod-uid label is absent, so the
	// identity join has something stable to key on rather than an empty string
	// shared by every unattributed event in the cluster.
	//
	// The container id is NOT a pod UID and must never be treated as one. It is
	// a correlation key: events from the same container share it. Downstream
	// consumers distinguish the two cases via HasPodIdentity below.
	if ev.PodUID == "" {
		if c := pod.GetContainer(); c != nil && c.GetId() != "" {
			ev.PodUID = c.GetId()
		}
	}

	return ev
}

// HasPodIdentity reports whether an event carries REAL Kubernetes identity —
// a pod UID and a service account sourced from the labels, not a container-id
// correlation key.
//
// # Why callers must check this before making an authorization claim
//
// Tetragon v1.1.0's Pod message carries neither a pod UID nor a service account.
// This package recovers both from `signalloom.io/*` pod labels, and NOTHING IN
// THIS REPOSITORY SETS THOSE LABELS TODAY. On the current cluster these fields
// will therefore be empty and this function returns false for every live event.
// The labels are the injection point for a future mutating webhook or an
// informer-backed enricher (see docs/signalloom/tetragon-telemetry-pipeline.md
// § 5, "Known limitation").
//
// The distinction matters because an empty ServiceAccount reads downstream as
// "unknown", and "unknown" in a tenancy filter or an authz decision is a
// security defect rather than a cosmetic gap. A Tetragon-sourced event is
// evidence of a syscall; it is NOT, on its own, an attributable identity claim.
func HasPodIdentity(ev *netebpf.InboundFlowEvent) bool {
	if ev == nil {
		return false
	}
	return ev.PodNamespace != "" && ev.ServiceAccount != "" &&
		ev.PodUID != "" && !strings.HasPrefix(ev.PodUID, "containerd://") &&
		!strings.HasPrefix(ev.PodUID, "docker://") && !strings.HasPrefix(ev.PodUID, "cri-o://")
}

// Direction reports the flow direction a normalised event represents.
//
// The canonical struct is named InboundFlowEvent because it is inbound TO
// signal-ingest, not because the traffic is inbound to the pod — a legacy
// misnomer in the existing schema. `tcp_connect` fires on the CONNECTING side,
// so a normalised connect event is EGRESS from the observed workload, and
// SrcIP/SrcPort are the pod while DstIP/DstPort are the remote peer.
//
// Getting this backwards would reverse every attribution downstream while every
// field remained populated and plausible, so the mapping is asserted by test
// rather than left to the struct's name.
func Direction(ev *netebpf.InboundFlowEvent) string {
	if ev == nil {
		return ""
	}
	switch ev.Classification {
	case ClassNetworkConnect:
		return "egress"
	case ClassProcessExec, ClassFileAccess:
		// Not flows at all. They are packed into the flow struct because it is
		// the schema Signal Fusion consumes, but they have no direction and
		// their SrcIP/DstIP are deliberately left empty.
		return "none"
	default:
		return "unknown"
	}
}

func (n *Normalizer) fromExec(node string, ts time.Time, exec *tetragon.ProcessExec) *netebpf.InboundFlowEvent {
	proc := exec.GetProcess()
	ev := n.base(node, ts, proc)

	if ev.Classification != ClassUnattributed {
		ev.Classification = ClassProcessExec
	}

	if proc != nil {
		ev.Domain = binaryToDomain(proc.GetBinary())
	}
	return ev
}

func (n *Normalizer) fromKprobe(node string, ts time.Time, kp *tetragon.ProcessKprobe) *netebpf.InboundFlowEvent {
	ev := n.base(node, ts, kp.GetProcess())
	fn := kp.GetFunctionName()

	switch {
	case strings.Contains(fn, SymbolTCPConnect):
		if sock := firstSockArg(kp.GetArgs()); sock != nil {
			applySock(ev, sock)
		}
		if ev.Classification != ClassUnattributed {
			ev.Classification = ClassNetworkConnect
		}
	case strings.Contains(fn, "openat") || fn == SymbolFilePerm:
		if path := firstFilePath(kp.GetArgs()); path != "" {
			ev.Domain = path
		}
		if ev.Classification != ClassUnattributed {
			ev.Classification = ClassFileAccess
		}
	default:
		// A kprobe we do not model. Keep the process attribution — the fact
		// that a policy fired is itself evidence — but do not invent a
		// classification for it.
		if ev.Classification != ClassUnattributed {
			ev.Classification = "kprobe:" + fn
		}
	}

	return ev
}

func (n *Normalizer) fromTracepoint(node string, ts time.Time, tp *tetragon.ProcessTracepoint) *netebpf.InboundFlowEvent {
	ev := n.base(node, ts, tp.GetProcess())

	subsys := tp.GetSubsys()
	event := tp.GetEvent()

	switch {
	case strings.Contains(event, "execve"):
		if ev.Classification != ClassUnattributed {
			ev.Classification = ClassProcessExec
		}
		if proc := tp.GetProcess(); proc != nil {
			ev.Domain = binaryToDomain(proc.GetBinary())
		}
	case strings.Contains(event, "openat"):
		if ev.Classification != ClassUnattributed {
			ev.Classification = ClassFileAccess
		}
		// The openat tracepoint carries the filename as a string arg. Take the
		// LAST string argument rather than the first: the policy declares
		// (dfd int, filename string), so the first arg is the directory fd.
		if path := lastStringArg(tp.GetArgs()); path != "" {
			ev.Domain = path
		}
	default:
		if ev.Classification != ClassUnattributed {
			ev.Classification = "tracepoint:" + subsys + "/" + event
		}
	}

	return ev
}

// applySock copies the socket 5-tuple out of a Tetragon KprobeSock.
func applySock(ev *netebpf.InboundFlowEvent, sock *tetragon.KprobeSock) {
	ev.SrcIP = sock.GetSaddr()
	ev.DstIP = sock.GetDaddr()
	ev.SrcPort = clampPort(sock.GetSport())
	ev.DstPort = clampPort(sock.GetDport())
	ev.SockCookie = sock.GetCookie()
	ev.Family = familyToUint16(sock.GetFamily())
}

// clampPort narrows Tetragon's uint32 port to the uint16 the canonical schema
// uses. A value above 65535 is not a valid port; it is truncated data or a
// wire-format skew, so it is zeroed rather than silently wrapped — a wrapped
// port number would look like a plausible destination and poison correlation.
func clampPort(p uint32) uint16 {
	if p > 65535 {
		return 0
	}
	return uint16(p)
}

// familyToUint16 maps Tetragon's string address family onto the numeric
// AF_* constants the canonical schema stores.
func familyToUint16(family string) uint16 {
	switch strings.ToUpper(strings.TrimSpace(family)) {
	case "AF_INET", "INET", "IPV4":
		return 2 // AF_INET
	case "AF_INET6", "INET6", "IPV6":
		return 10 // AF_INET6
	case "AF_UNIX", "UNIX", "AF_LOCAL":
		return 1 // AF_UNIX
	default:
		return 0
	}
}

// firstSockArg returns the first sock-typed kprobe argument, or nil.
func firstSockArg(args []*tetragon.KprobeArgument) *tetragon.KprobeSock {
	for _, a := range args {
		if a == nil {
			continue
		}
		if s := a.GetSockArg(); s != nil {
			return s
		}
	}
	return nil
}

// firstFilePath returns a file path from the first file- or path-typed kprobe
// argument, falling back to a string argument that looks like an absolute path.
func firstFilePath(args []*tetragon.KprobeArgument) string {
	for _, a := range args {
		if a == nil {
			continue
		}
		if f := a.GetFileArg(); f != nil && f.GetPath() != "" {
			return f.GetPath()
		}
		if p := a.GetPathArg(); p != nil && p.GetPath() != "" {
			return p.GetPath()
		}
	}
	for _, a := range args {
		if a == nil {
			continue
		}
		if s := a.GetStringArg(); strings.HasPrefix(s, "/") {
			return s
		}
	}
	return ""
}

// lastStringArg returns the final string-valued tracepoint argument.
func lastStringArg(args []*tetragon.KprobeArgument) string {
	out := ""
	for _, a := range args {
		if a == nil {
			continue
		}
		if s := a.GetStringArg(); s != "" {
			out = s
		}
	}
	return out
}

// binaryToDomain records the executed binary in the Domain label. Domain is the
// canonical schema's free-text "what was reached" field; for a process event
// the analogue of a destination hostname is the binary that was executed.
func binaryToDomain(binary string) string {
	return strings.TrimSpace(binary)
}

// hashToUint64 gives a stable numeric id for a container id string.
func hashToUint64(s string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(s))
	return h.Sum64()
}

// Destination renders the normalised destination for logging and test
// assertions, matching the format the netebpf collector writes into labels.
func Destination(ev *netebpf.InboundFlowEvent) string {
	if ev == nil || ev.DstIP == "" {
		return ""
	}
	return net.JoinHostPort(ev.DstIP, strconv.Itoa(int(ev.DstPort)))
}
