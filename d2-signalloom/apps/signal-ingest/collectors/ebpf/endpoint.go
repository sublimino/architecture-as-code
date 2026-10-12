// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"fmt"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// EndpointObservationSource is the obs.source every Tetragon endpoint_host
// observation carries. It is deliberately distinct from both the netebpf socket
// trace ("sentinel.ebpf.socket_trace", a network_egress stream) and the
// agent-nono Landlock evidence ("agent-nono-evidenced", the other endpoint_host
// stream). The endpoint-runtime CEL bundle source-gates on this value so it never
// double-fires with the landlock-denial rule, which shares the endpoint_host
// layer but gates on verification_status — a label Tetragon events never carry.
const EndpointObservationSource = "tetragon"

// IsEndpointClass reports whether a normalised Tetragon classification is a
// host-endpoint syscall event (a process, a file access, or any other kprobe /
// tracepoint) as opposed to a network flow.
//
// network_connect is NOT an endpoint event: it is egress, projected by the
// netebpf collector onto the network_egress layer, and projecting it here too
// would duplicate the signal across two layers. "unattributed" is also skipped —
// the normaliser replaces the real class with it when a pod could not be
// attributed, so it carries no syscall to detect on.
func IsEndpointClass(classification string) bool {
	switch classification {
	case ClassProcessExec, ClassFileAccess:
		return true
	case ClassNetworkConnect, ClassUnattributed, "":
		return false
	default:
		// The normaliser emits "kprobe:<fn>" / "tracepoint:<subsys>/<event>" for
		// classes it does not model (ptrace, capability checks, etc). Those ARE
		// host-endpoint evidence.
		return strings.HasPrefix(classification, "kprobe:") ||
			strings.HasPrefix(classification, "tracepoint:")
	}
}

// EndpointSyscall derives the syscall discriminator label from the normalised
// classification, so a rule can gate on a specific syscall (ptrace, cap_capable)
// without re-deriving it. It mirrors the normaliser's own vocabulary:
//   - file_access             -> "openat"  (the modelled file-open path)
//   - process_exec            -> "execve"  (the modelled exec path)
//   - "kprobe:<fn>"           -> "<fn>"
//   - "tracepoint:<sub>/<ev>" -> "<ev>"
//   - anything else           -> ""        (no syscall label is emitted)
func EndpointSyscall(classification string) string {
	switch classification {
	case ClassFileAccess:
		return "openat"
	case ClassProcessExec:
		return "execve"
	}
	if fn, ok := strings.CutPrefix(classification, "kprobe:"); ok {
		return fn
	}
	if rest, ok := strings.CutPrefix(classification, "tracepoint:"); ok {
		if _, ev, found := strings.Cut(rest, "/"); found {
			return ev
		}
		return rest
	}
	return ""
}

// ProjectEndpoint maps one normalised Tetragon event to an endpoint_host
// observation, or (zero, false) when the event is not a host-endpoint syscall
// (a network flow, an unattributed event, or a nil event).
//
// It is the production projection the endpoint-runtime bundle is written against
// and that FixtureObservations replays, so the e2e asserts production and not a
// test-only corpus. Every label key it emits is in the segment label allow-list
// (store/label_allowlist.go): classification, syscall, target, pod_name,
// namespace, node, agent_role, service_account, pod_uid, provider, direction.
// Labels are emitted only when their source field is present, which is why the
// bundle guards every read with has(): a file access has a target, a bare kprobe
// may not, and an unattributed-but-classed event may lack pod identity.
//
// Identity is NOT a label. The acting workload's service account goes to
// ActorHint, which the store pseudonymises into obs.actor, so an actor-scoped
// rule (unexpected-execve) compares obs.actor against an actor_vars set and a
// cleartext service-account label can never leak the identity into a segment.
func ProjectEndpoint(ev *netebpf.InboundFlowEvent, originRef string) (model.Observation, bool) {
	if ev == nil || !IsEndpointClass(ev.Classification) {
		return model.Observation{}, false
	}

	ts := ev.Time
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	labels := map[string]string{
		"classification": ev.Classification,
		// A syscall event is host-local activity, not a directional flow; the
		// direction label records that explicitly so a reader is not left to infer
		// it from an absent src/dst.
		"direction": "none",
	}
	if sys := EndpointSyscall(ev.Classification); sys != "" {
		labels["syscall"] = sys
	}
	// Domain carries the file path (file_access) or the executed binary
	// (process_exec); both are the "target" of the syscall in endpoint terms.
	if ev.Domain != "" {
		labels["target"] = ev.Domain
	}
	if ev.PodName != "" {
		labels["pod_name"] = ev.PodName
	}
	if ev.PodNamespace != "" {
		labels["namespace"] = ev.PodNamespace
	}
	if ev.NodeName != "" {
		labels["node"] = ev.NodeName
	}
	if ev.AgentRole != "" {
		labels["agent_role"] = ev.AgentRole
	}
	if ev.ServiceAccount != "" {
		labels["service_account"] = ev.ServiceAccount
	}
	if ev.PodUID != "" {
		labels["pod_uid"] = ev.PodUID
	}
	if ev.Provider != "" {
		labels["provider"] = ev.Provider
	}

	obs := model.Observation{
		ID:             fmt.Sprintf("tetragon-%s-%d-%d", ev.PodName, ev.CgroupID, ev.SeqNum),
		Timestamp:      ts,
		Layer:          model.LayerEndpointHost,
		Fidelity:       model.FidelityStrong,
		Confidence:     0.85,
		Source:         EndpointObservationSource,
		ActorHint:      ev.ServiceAccount,
		RawEvidenceRef: originRef,
		Labels:         labels,
	}
	return obs, true
}
