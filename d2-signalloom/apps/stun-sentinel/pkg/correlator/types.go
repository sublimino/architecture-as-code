// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"net"
	"strconv"
)

const (
	// Syscall event type identifiers matching eBPF probe definitions
	SyscallTypeOpenat  uint8 = 1
	SyscallTypeExecve  uint8 = 2
	SyscallTypeConnect uint8 = 3
	SyscallTypeOpenat2 uint8 = 4

	// Normalized syscall names
	SyscallNameOpenat       = "sys_enter_openat"
	SyscallNameOpenat2      = "sys_enter_openat2"
	SyscallNameExecve       = "sys_enter_execve"
	SyscallNameConnect      = "tcp_connect"
	SyscallNameRingbufDrops = "ringbuf_drops_anomaly"

	// SyscallNameEvasiveBurst names a behavioural detection (SLAAT-P2-4): a
	// rapid run of execve events from one cgroup within a short window, as
	// produced by a process-spawn flood or the forked child left behind by
	// unshare(CLONE_NEWPID). It is reported independently of the
	// sensitive-path filter, because the signal here is RATE, not WHICH path
	// was touched -- a burst that never opens a sensitive file still has
	// none to match against under the per-path rule alone.
	SyscallNameEvasiveBurst = "evasive_syscall_burst"

	// Severity levels
	SeverityCritical = "CRITICAL"
	SeverityWarn     = "WARN"

	// Direct reaction outcomes
	ReactionCgroupFrozen = "cgroup_frozen"
	ReactionNone         = "none"
)

// SyscallEvent is the correlator's view of one decoded kernel record
// (pkg/ebpf.SyscallEvent): the fields the normaliser reads. Family, DestPort
// and DestAddr are set only for a connect, from the probe's own capture
// (bpf/sentinel_probe.c trace_enter_connect); a connect has no Filename.
type SyscallEvent struct {
	TsNs     uint64 // bpf_ktime_get_ns() at the syscall (CLOCK_MONOTONIC)
	PID      uint32
	TGID     uint32
	UID      uint32
	Type     uint8
	Comm     [16]byte
	Filename [256]byte
	Family   uint16 // AF_INET or AF_INET6; 0 for a non-connect
	DestPort uint16
	DestAddr net.IP
}

// RemoteEndpoint formats a connect's destination as host:port ("[v6]:port"
// for IPv6). Empty for a non-connect or an address the probe did not fill.
func (e SyscallEvent) RemoteEndpoint() string {
	if e.Type != SyscallTypeConnect || e.DestAddr == nil {
		return ""
	}
	return net.JoinHostPort(e.DestAddr.String(), strconv.Itoa(int(e.DestPort)))
}

// TelemetryObservation defines the normalized telemetry payload streamed to signal-ingest.
type TelemetryObservation struct {
	Timestamp      string            `json:"timestamp"`
	ActorID        string            `json:"actor_id"`
	TenantID       string            `json:"tenant_id"`
	PodName        string            `json:"pod_name"`
	Namespace      string            `json:"namespace"`
	Syscall        string            `json:"syscall"`
	Target         string            `json:"target"`
	Severity       string            `json:"severity"`
	Labels         map[string]string `json:"labels"`
	DirectReaction string            `json:"direct_reaction"`
	CgroupPath     string            `json:"cgroup_path,omitempty"`
	// Opener is the process that made the syscall, as the probe saw it AT
	// the syscall. It rides on the stdout audit line only; toIngest does not
	// carry it, so the signal-ingest wire is unchanged.
	Opener *OpenerIdentity `json:"opener,omitempty"`
}

// OpenerIdentity names the calling process of a detection. ExeIno and
// ExeSize are its executable's inode and size from the probe (0 = unknown).
type OpenerIdentity struct {
	Comm    string `json:"comm"`
	TGID    uint32 `json:"tgid"`
	UID     uint32 `json:"uid"`
	ExeIno  uint64 `json:"exe_ino"`
	ExeSize uint64 `json:"exe_size"`
	// NodeRuntime, set only for a runtime-setup target (runtime_lookup.go),
	// is the node runc identities the runtime exemption compared ExeIno and
	// ExeSize against: a setup open reported as a detection says exactly why
	// it was not the runtime's.
	NodeRuntime []BinaryIdentity `json:"node_runtime,omitempty"`
}

// BinaryIdentity is a node binary's path (as read through the node root),
// inode and size.
type BinaryIdentity struct {
	Path string `json:"path"`
	Ino  uint64 `json:"ino"`
	Size uint64 `json:"size"`
	// Comm, for a script OCI hook, is the comm the hook runs under; its
	// interpreter's identity alone does not exempt (runtime_hooks.go).
	Comm string `json:"comm,omitempty"`
}
