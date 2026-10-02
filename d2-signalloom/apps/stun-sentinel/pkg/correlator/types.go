// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

const (
	// Syscall event type identifiers matching eBPF probe definitions
	SyscallTypeOpenat  uint8 = 1
	SyscallTypeExecve  uint8 = 2
	SyscallTypeConnect uint8 = 3

	// Normalized syscall names
	SyscallNameOpenat  = "sys_enter_openat"
	SyscallNameExecve  = "sys_enter_execve"
	SyscallNameConnect = "tcp_connect"

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

	// Default tenant identity (Canonical Tenant Vector - Kusari)
	DefaultTenantID = "kusari"
)

// SyscallEvent represents the binary layout of raw syscall events emitted by kernel eBPF probes.
type SyscallEvent struct {
	TsNs     uint64 // bpf_ktime_get_ns() at the syscall (CLOCK_MONOTONIC)
	PID      uint32
	TGID     uint32
	UID      uint32
	Type     uint8
	Comm     [16]byte
	Filename [256]byte
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
}
