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
	RecordsRead       uint64 `json:"records_read"`
	ReadErrors        uint64 `json:"read_errors"`
	DecodeErrors      uint64 `json:"decode_errors"`
	NotSensitive      uint64 `json:"not_sensitive"`
	NoPod             uint64 `json:"no_pod"`
	Matched           uint64 `json:"matched"`
	Enqueued          uint64 `json:"enqueued"`
	QueueDropped      uint64 `json:"queue_dropped"`
	DispatchOK        uint64 `json:"dispatch_ok"`
	DispatchErrors    uint64 `json:"dispatch_errors"`
	LastDispatchError string `json:"last_dispatch_error,omitempty"`
}

type pipelineStats struct {
	recordsRead, readErrors, decodeErrors, notSensitive, noPod,
	matched, enqueued, queueDropped, dispatchOK, dispatchErrors atomic.Uint64

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
		RecordsRead:       s.recordsRead.Load(),
		ReadErrors:        s.readErrors.Load(),
		DecodeErrors:      s.decodeErrors.Load(),
		NotSensitive:      s.notSensitive.Load(),
		NoPod:             s.noPod.Load(),
		Matched:           s.matched.Load(),
		Enqueued:          s.enqueued.Load(),
		QueueDropped:      s.queueDropped.Load(),
		DispatchOK:        s.dispatchOK.Load(),
		DispatchErrors:    s.dispatchErrors.Load(),
		LastDispatchError: last,
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
