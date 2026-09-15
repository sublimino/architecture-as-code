// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package telemetry publishes Tier 0 containment state transitions into the
// Signal Loom event bus.
//
// The wire format is JSONL — one self-contained JSON object per line — which
// is what the Signal Loom ingest path consumes from a container's stdout and
// what `jq` can read from a captured stream without a framing layer.
//
// Ownership note for CRKC-P1-3: this package is the cgroup/execution-state
// half of stun-sentinel telemetry. Network-containment events belong in a
// sibling constructor on the same Emitter rather than a second writer, so the
// two halves interleave on one ordered stream.
package telemetry

import (
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"time"
)

// Event names emitted by this package.
const (
	// EventStunExecutionHalted is published when a cgroup has been observed
	// in the frozen state — never merely when the freeze was requested.
	EventStunExecutionHalted = "StunExecutionHalted"
	// EventStunExecutionResumed is published when an authorised resume has
	// been observed to complete.
	EventStunExecutionResumed = "StunExecutionResumed"
	// EventStunExecutionHaltFailed is published when containment could not
	// be proven. A silent failure here would be worse than no telemetry at
	// all: the control plane would show a contained agent that is running.
	EventStunExecutionHaltFailed = "StunExecutionHaltFailed"
)

// Tier identifies the containment tier for cross-referencing with the
// two-tier lifetime invariant (SP-2).
const TierKernelExecutionState = "tier-0-kernel-execution-state"

// Event is a single Signal Loom telemetry record.
type Event struct {
	Timestamp  string  `json:"timestamp"`
	Event      string  `json:"event"`
	Tier       string  `json:"tier"`
	PodUID     string  `json:"pod_uid,omitempty"`
	PodName    string  `json:"pod,omitempty"`
	Namespace  string  `json:"namespace,omitempty"`
	CgroupPath string  `json:"cgroup_path,omitempty"`
	Frozen     bool    `json:"frozen"`
	LatencyMS  float64 `json:"latency_ms"`
	DeadlineMS float64 `json:"deadline_ms,omitempty"`
	Polls      int     `json:"polls,omitempty"`
	PIDs       []int   `json:"pids"`
	PIDCount    int      `json:"pid_count"`
	Reason      string   `json:"reason,omitempty"`
	OperatorID  string   `json:"operator_id,omitempty"`
	OperatorIDs []string `json:"operator_ids,omitempty"`
	TokenID     string   `json:"token_id,omitempty"`
}

// Emitter serialises events onto a writer. It is safe for concurrent use: the
// stun path is driven by a work queue with multiple workers, and interleaved
// partial writes would corrupt the JSONL framing that downstream ingest
// depends on.
type Emitter struct {
	mu  sync.Mutex
	w   io.Writer
	now func() time.Time
}

// NewEmitter returns an Emitter writing to w.
func NewEmitter(w io.Writer) *Emitter {
	return &Emitter{w: w, now: time.Now}
}

// SetClock overrides the timestamp source. Test-only seam.
func (e *Emitter) SetClock(now func() time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if now != nil {
		e.now = now
	}
}

// Emit writes one event as a JSON line.
func (e *Emitter) Emit(ev Event) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if ev.Timestamp == "" {
		ev.Timestamp = e.now().UTC().Format(time.RFC3339Nano)
	}
	if ev.Tier == "" {
		ev.Tier = TierKernelExecutionState
	}
	// A nil slice marshals to `null`; an empty one marshals to `[]`. A
	// consumer doing `.pids | length` gets an error on the first and 0 on
	// the second, so normalise.
	if ev.PIDs == nil {
		ev.PIDs = []int{}
	}
	ev.PIDCount = len(ev.PIDs)

	line, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("telemetry: marshalling %s: %w", ev.Event, err)
	}
	if _, err := e.w.Write(append(line, '\n')); err != nil {
		return fmt.Errorf("telemetry: writing %s: %w", ev.Event, err)
	}
	return nil
}

// FreezeObservation is the subset of a cgroup freeze result this package
// needs. It is declared here rather than importing pkg/cgroup so telemetry
// stays a leaf dependency and can be reused by the network-containment half.
type FreezeObservation struct {
	PodUID      string
	PodName     string
	Namespace   string
	CgroupPath  string
	Frozen      bool
	LatencyMS   float64
	DeadlineMS  float64
	Polls       int
	PIDs        []int
	OperatorID  string
	OperatorIDs []string
	TokenID     string
}

// StunExecutionHalted publishes a proven execution halt.
func (e *Emitter) StunExecutionHalted(obs FreezeObservation) error {
	return e.Emit(Event{
		Event:      EventStunExecutionHalted,
		PodUID:     obs.PodUID,
		PodName:    obs.PodName,
		Namespace:  obs.Namespace,
		CgroupPath: obs.CgroupPath,
		Frozen:     true,
		LatencyMS:  obs.LatencyMS,
		DeadlineMS: obs.DeadlineMS,
		Polls:      obs.Polls,
		PIDs:       obs.PIDs,
	})
}

// StunExecutionResumed publishes an authorised, verified resume.
func (e *Emitter) StunExecutionResumed(obs FreezeObservation) error {
	opID := obs.OperatorID
	if opID == "" && len(obs.OperatorIDs) > 0 {
		opID = obs.OperatorIDs[0]
	}
	return e.Emit(Event{
		Event:       EventStunExecutionResumed,
		PodUID:      obs.PodUID,
		PodName:     obs.PodName,
		Namespace:   obs.Namespace,
		CgroupPath:  obs.CgroupPath,
		Frozen:      false,
		LatencyMS:   obs.LatencyMS,
		DeadlineMS:  obs.DeadlineMS,
		Polls:       obs.Polls,
		PIDs:        obs.PIDs,
		OperatorID:  opID,
		OperatorIDs: obs.OperatorIDs,
		TokenID:     obs.TokenID,
	})
}

// StunExecutionHaltFailed publishes a containment failure with its cause.
func (e *Emitter) StunExecutionHaltFailed(obs FreezeObservation, reason string) error {
	return e.Emit(Event{
		Event:      EventStunExecutionHaltFailed,
		PodUID:     obs.PodUID,
		PodName:    obs.PodName,
		Namespace:  obs.Namespace,
		CgroupPath: obs.CgroupPath,
		Frozen:     obs.Frozen,
		LatencyMS:  obs.LatencyMS,
		DeadlineMS: obs.DeadlineMS,
		Polls:      obs.Polls,
		PIDs:       obs.PIDs,
		Reason:     reason,
	})
}
