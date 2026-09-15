// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package quarantine

import (
	"time"
)

// ManifestVersion is the schema version for quarantine state manifests.
const ManifestVersion = "signalloom.io/v1alpha1"

// ManifestKind identifies this artifact type in Signal Loom forensics.
const ManifestKind = "QuarantineSnapshotManifest"

// Default storage and bounds constants.
const (
	DefaultStorageDir         = "/var/log/signalloom/quarantine"
	DefaultMaxMemorySizeBytes = 64 * 1024 * 1024 // 64 MB
	DefaultMaxTimeBudget      = 500 * time.Millisecond
	DefaultSnapshotDirPerm    = 0700
	DefaultSnapshotFilePerm   = 0600
)

// TargetInfo identifies the workload target being quarantined.
type TargetInfo struct {
	PodUID     string `json:"pod_uid"`
	PodName    string `json:"pod_name,omitempty"`
	Namespace  string `json:"namespace,omitempty"`
	CgroupPath string `json:"cgroup_path,omitempty"`
}

// MemoryStatistics captures memory usage metrics from /proc/<pid>/status and statm.
type MemoryStatistics struct {
	RSSBytes     int64 `json:"rss_bytes"`
	VMSwapBytes  int64 `json:"vm_swap_bytes"`
	VMDataBytes  int64 `json:"vm_data_bytes"`
	VMStackBytes int64 `json:"vm_stack_bytes"`
	VMSizeBytes  int64 `json:"vm_size_bytes"`
}

// MemoryRegion represents one virtual memory mapping from /proc/<pid>/maps.
type MemoryRegion struct {
	StartAddr     string `json:"start_addr"`
	EndAddr       string `json:"end_addr"`
	StartUint     uint64 `json:"-"`
	EndUint       uint64 `json:"-"`
	Perms         string `json:"perms"`
	Offset        uint64 `json:"offset"`
	Dev           string `json:"dev"`
	Inode         uint64 `json:"inode"`
	Pathname      string `json:"pathname,omitempty"`
	IsAnonymous   bool   `json:"is_anonymous"`
	IsWritable    bool   `json:"is_writable"`
	IsDumped      bool   `json:"is_dumped"`
	DumpFile      string `json:"dump_file,omitempty"`
	DumpSizeBytes int64  `json:"dump_size_bytes,omitempty"`
	SHA256        string `json:"sha256,omitempty"`
}

// FDInfo describes an open file descriptor from /proc/<pid>/fd.
type FDInfo struct {
	FD     int    `json:"fd"`
	Target string `json:"target"`
	Kind   string `json:"kind"` // "file", "socket", "pipe", "anon_inode", "device", "unknown"
	Flags  string `json:"flags,omitempty"`
	Pos    int64  `json:"pos,omitempty"`
	Inode  uint64 `json:"inode,omitempty"`
}

// SocketInfo describes an open network socket correlated with /proc/<pid>/net/tcp etc.
type SocketInfo struct {
	FD         int    `json:"fd"`
	Protocol   string `json:"protocol"` // "tcp", "tcp6", "udp", "udp6", "unix"
	LocalAddr  string `json:"local_addr"`
	RemoteAddr string `json:"remote_addr"`
	State      string `json:"state"` // e.g. "LISTEN", "ESTABLISHED", "CLOSE_WAIT"
	Inode      uint64 `json:"inode"`
}

// LockRecord describes a file lock held by the process, from /proc/locks and /proc/<pid>/fdinfo.
type LockRecord struct {
	PID      int    `json:"pid"`
	FD       int    `json:"fd,omitempty"`
	LockType string `json:"lock_type"` // "POSIX", "FLOCK", "OFD", "LEASE"
	LockMode string `json:"lock_mode"` // "READ", "WRITE"
	Start    int64  `json:"start"`
	End      int64  `json:"end"` // -1 represents EOF
	Path     string `json:"path,omitempty"`
	Inode    uint64 `json:"inode"`
	Device   string `json:"device,omitempty"`
}

// ProcessQuarantineState records the forensic state of one process in the cgroup.
type ProcessQuarantineState struct {
	PID             int              `json:"pid"`
	PPID            int              `json:"ppid"`
	Comm            string           `json:"comm"`
	Cmdline         []string         `json:"cmdline"`
	State           string           `json:"state"`
	MemoryStats     MemoryStatistics `json:"memory_stats"`
	MemoryRegions   []MemoryRegion   `json:"memory_regions"`
	FileDescriptors []FDInfo         `json:"file_descriptors"`
	Sockets         []SocketInfo     `json:"sockets"`
	HeldLocks       []LockRecord     `json:"held_locks"`
}

// CaptureSummary provides machine-readable aggregate metrics for attestation.
type CaptureSummary struct {
	ProcessCount           int               `json:"process_count"`
	TotalFDCount           int               `json:"total_fd_count"`
	TotalSocketCount       int               `json:"total_socket_count"`
	TotalLockCount         int               `json:"total_lock_count"`
	MemoryBytesMapped      int64             `json:"memory_bytes_mapped"`
	MemoryBytesDumped      int64             `json:"memory_bytes_dumped"`
	TotalSnapshotSizeBytes int64             `json:"total_snapshot_size_bytes"`
	ArtifactHashes         map[string]string `json:"artifact_hashes"` // relative path -> sha256
}

// QuarantineManifest is the root forensic metadata artifact emitted at freeze time.
type QuarantineManifest struct {
	Version           string                   `json:"version"`
	Kind              string                   `json:"kind"`
	CaptureID         string                   `json:"capture_id"`
	Target            TargetInfo               `json:"target"`
	CreatedAt         time.Time                `json:"created_at"`
	CaptureDurationMS float64                  `json:"capture_duration_ms"`
	Partial           bool                     `json:"partial"`
	PartialReason     string                   `json:"partial_reason,omitempty"`
	StoragePath       string                   `json:"storage_path"`
	Summary           CaptureSummary           `json:"summary"`
	Processes         []ProcessQuarantineState `json:"processes"`
}

// RetentionPolicy defines bounds for pruning stored snapshots on node disk.
type RetentionPolicy struct {
	MaxSnapshots      int           `json:"max_snapshots"`
	MaxTotalSizeBytes int64         `json:"max_total_size_bytes"`
	MaxAge            time.Duration `json:"max_age"`
}

// PruneResult records the outcome of a retention cleanup sweep.
type PruneResult struct {
	PrunedCount        int      `json:"pruned_count"`
	PrunedSizeBytes    int64    `json:"pruned_size_bytes"`
	RemainingCount     int      `json:"remaining_count"`
	RemainingSizeBytes int64    `json:"remaining_size_bytes"`
	PrunedIDs          []string `json:"pruned_ids"`
}

// CaptureConfig configures the quarantine capture engine.
type CaptureConfig struct {
	StorageDir         string
	MaxMemorySizeBytes int64
	MaxTimeBudget      time.Duration
	ProcRoot           string // Defaults to "/proc", injectable for testing
	DumpAnonymousOnly  bool   // If true, dumps anonymous/heap/stack pages; skips clean file maps
	RetentionPolicy    RetentionPolicy
}
