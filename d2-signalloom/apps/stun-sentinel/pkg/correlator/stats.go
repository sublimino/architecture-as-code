// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"sync"
	"sync/atomic"
)

// Stats is a point-in-time count of what the correlator did with every
// ring-buffer record. The pipeline drops records at several stages by design;
// these counters make each drop visible, because a silent drop is
// indistinguishable from a probe that never fired.
type Stats struct {
	RecordsRead  uint64 `json:"records_read"`
	ReadErrors   uint64 `json:"read_errors"`
	DecodeErrors uint64 `json:"decode_errors"`
	NotSensitive uint64 `json:"not_sensitive"`
	NoPod        uint64 `json:"no_pod"`
	// SelfExcluded counts records from a sentinel's own pod (its tc execs,
	// its own opens): never a detection, never posted.
	SelfExcluded uint64 `json:"self_excluded"`
	// RuntimeLookups counts the container runtime's own user-database
	// opens (runc init, before it execs the entrypoint): not a detection.
	RuntimeLookups uint64 `json:"runtime_lookups"`
	// RuntimeLookupsAtEvent is the subset decided by the caller's executable
	// identity recorded at the syscall (exe_ino/exe_size), not by reading
	// the process afterwards.
	RuntimeLookupsAtEvent uint64 `json:"runtime_lookups_at_event"`
	Matched               uint64 `json:"matched"`
	Enqueued              uint64 `json:"enqueued"`
	QueueDropped          uint64 `json:"queue_dropped"`
	DispatchOK            uint64 `json:"dispatch_ok"`
	DispatchErrors        uint64 `json:"dispatch_errors"`
	// IngestTokenMissing counts observations not posted because no ingest
	// bearer is configured. Detection and freeze are unaffected.
	IngestTokenMissing uint64 `json:"ingest_token_missing"`
	LastDispatchError  string `json:"last_dispatch_error,omitempty"`

	// Spool and batch dispatch counters (Phase 2)
	SpoolBatches        uint64 `json:"spool_batches"`
	SpoolBytes          uint64 `json:"spool_bytes"`
	SpoolEvicted        uint64 `json:"spool_evicted"`
	SpoolExpired        uint64 `json:"spool_expired"`
	SpoolReplayed       uint64 `json:"spool_replayed"`
	SpoolCorrupt        uint64 `json:"spool_corrupt"`
	DispatchAuthRefused uint64 `json:"dispatch_auth_refused"`
	DispatchRejected    uint64 `json:"dispatch_rejected"`
	RetryAfterWaits     uint64 `json:"retry_after_waits"`
}

type pipelineStats struct {
	recordsRead, readErrors, decodeErrors, notSensitive, noPod,
	selfExcluded, runtimeLookups, runtimeLookupsAtEvent, matched, enqueued, queueDropped, dispatchOK, dispatchErrors,
	ingestTokenMissing,
	spoolBatches, spoolBytes, spoolEvicted, spoolExpired, spoolReplayed, spoolCorrupt,
	dispatchAuthRefused, dispatchRejected, retryAfterWaits atomic.Uint64

	mu      sync.Mutex
	lastErr string
}

// Stats returns a consistent snapshot of the pipeline counters.
func (m *SentinelProbeManager) Stats() Stats {
	s := &m.stats
	s.mu.Lock()
	last := s.lastErr
	s.mu.Unlock()
	return Stats{
		RecordsRead:           s.recordsRead.Load(),
		ReadErrors:            s.readErrors.Load(),
		DecodeErrors:          s.decodeErrors.Load(),
		NotSensitive:          s.notSensitive.Load(),
		NoPod:                 s.noPod.Load(),
		SelfExcluded:          s.selfExcluded.Load(),
		RuntimeLookups:        s.runtimeLookups.Load(),
		RuntimeLookupsAtEvent: s.runtimeLookupsAtEvent.Load(),
		Matched:               s.matched.Load(),
		Enqueued:              s.enqueued.Load(),
		QueueDropped:          s.queueDropped.Load(),
		DispatchOK:            s.dispatchOK.Load(),
		DispatchErrors:        s.dispatchErrors.Load(),
		IngestTokenMissing:    s.ingestTokenMissing.Load(),
		LastDispatchError:     last,
		SpoolBatches:          s.spoolBatches.Load(),
		SpoolBytes:            s.spoolBytes.Load(),
		SpoolEvicted:          s.spoolEvicted.Load(),
		SpoolExpired:          s.spoolExpired.Load(),
		SpoolReplayed:         s.spoolReplayed.Load(),
		SpoolCorrupt:          s.spoolCorrupt.Load(),
		DispatchAuthRefused:   s.dispatchAuthRefused.Load(),
		DispatchRejected:      s.dispatchRejected.Load(),
		RetryAfterWaits:       s.retryAfterWaits.Load(),
	}
}

// recordDispatch counts the outcome of one POST to signal-ingest. It replaces
// a `_ =` that discarded every error, which hid a 401 or an unresolvable URL.
func (m *SentinelProbeManager) recordDispatch(err error) {
	if err == nil {
		m.stats.dispatchOK.Add(1)
		return
	}
	m.stats.dispatchErrors.Add(1)
	m.stats.mu.Lock()
	m.stats.lastErr = err.Error()
	m.stats.mu.Unlock()
}
