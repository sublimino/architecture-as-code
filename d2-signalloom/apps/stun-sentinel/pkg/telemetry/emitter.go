// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package telemetry publishes Tier 0 containment state transitions into the
// Signal Loom event bus.
//
// The wire format is JSONL — one self-contained JSON object per line — which
// is what the Signal Loom ingest path consumes from a container's stdout and
// what `jq` can read from a captured stream without a framing layer.
//
// Ownership note for CRKC-P1-3 & SLER-P4-1: this package provides the unified
// structured, machine-readable event logging across cgroup freezer, TC severance,
// and audit pipelines, with forward compatibility for P5-1 Witness attestation.
package telemetry

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
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
	// EventStunProbePreserved is emitted when probe interception is activated.
	EventStunProbePreserved = "StunProbePreserved"
	// EventStunProbeReleased is emitted when probe interception is deactivated.
	EventStunProbeReleased = "StunProbeReleased"
)

// Tier identifies the containment tier for cross-referencing with the
// two-tier lifetime invariant (SP-2).
const TierKernelExecutionState = "tier-0-kernel-execution-state"

// Event is a single Signal Loom telemetry and audit record.
type Event struct {
	Timestamp       string                 `json:"timestamp"`
	Event           string                 `json:"event"`
	Tier            string                 `json:"tier"`
	PodUID          string                 `json:"pod_uid,omitempty"`
	PodName         string                 `json:"pod,omitempty"`
	Namespace       string                 `json:"namespace,omitempty"`
	CgroupPath      string                 `json:"cgroup_path,omitempty"`
	Frozen          bool                   `json:"frozen"`
	DryRun          bool                   `json:"dry_run,omitempty"`
	Decision        string                 `json:"decision,omitempty"`
	LatencyMS       float64                `json:"latency_ms"`
	DeadlineMS      float64                `json:"deadline_ms,omitempty"`
	Polls           int                    `json:"polls,omitempty"`
	PIDs            []int                  `json:"pids"`
	PIDCount        int                    `json:"pid_count"`
	HostVeth        string                 `json:"host_veth,omitempty"`
	TCIngressFilter string                 `json:"tc_ingress_filter,omitempty"`
	TCEgressFilter  string                 `json:"tc_egress_filter,omitempty"`
	ProbesCount     int                    `json:"probes_count,omitempty"`
	ReconcileCount  int64                  `json:"reconcile_count,omitempty"`
	Reason          string                 `json:"reason,omitempty"`
	Error           string                 `json:"error,omitempty"`
	AttestationID   string                 `json:"attestation_id,omitempty"`
	WitnessDigest   string                 `json:"witness_digest,omitempty"`
	Details         map[string]interface{} `json:"details,omitempty"`
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
	if w == nil {
		w = os.Stdout
	}
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

// FreezeObservation is the subset of a cgroup freeze result this package needs.
type FreezeObservation struct {
	PodUID     string
	PodName    string
	Namespace  string
	CgroupPath string
	Frozen     bool
	DryRun     bool
	LatencyMS  float64
	DeadlineMS float64
	Polls      int
	PIDs       []int
	HostVeth   string
}

// StunExecutionHalted publishes a proven execution halt.
func (e *Emitter) StunExecutionHalted(obs FreezeObservation) error {
	decision := "containment_applied"
	if obs.DryRun {
		decision = "containment_planned_dry_run"
	}
	return e.Emit(Event{
		Event:      EventStunExecutionHalted,
		PodUID:     obs.PodUID,
		PodName:    obs.PodName,
		Namespace:  obs.Namespace,
		CgroupPath: obs.CgroupPath,
		Frozen:     true,
		DryRun:     obs.DryRun,
		Decision:   decision,
		LatencyMS:  obs.LatencyMS,
		DeadlineMS: obs.DeadlineMS,
		Polls:      obs.Polls,
		PIDs:       obs.PIDs,
		HostVeth:   obs.HostVeth,
	})
}

// StunExecutionResumed publishes an authorised, verified resume.
func (e *Emitter) StunExecutionResumed(obs FreezeObservation) error {
	decision := "containment_released"
	if obs.DryRun {
		decision = "containment_release_planned_dry_run"
	}
	return e.Emit(Event{
		Event:      EventStunExecutionResumed,
		PodUID:     obs.PodUID,
		PodName:    obs.PodName,
		Namespace:  obs.Namespace,
		CgroupPath: obs.CgroupPath,
		Frozen:     false,
		DryRun:     obs.DryRun,
		Decision:   decision,
		LatencyMS:  obs.LatencyMS,
		DeadlineMS: obs.DeadlineMS,
		Polls:      obs.Polls,
		PIDs:       obs.PIDs,
		HostVeth:   obs.HostVeth,
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
		DryRun:     obs.DryRun,
		Decision:   "containment_failed",
		LatencyMS:  obs.LatencyMS,
		DeadlineMS: obs.DeadlineMS,
		Polls:      obs.Polls,
		PIDs:       obs.PIDs,
		HostVeth:   obs.HostVeth,
		Reason:     reason,
		Error:      reason,
	})
}

// ValidateAuditEvent parses raw JSON bytes and verifies that mandatory audit fields are present.
func ValidateAuditEvent(data []byte) (*Event, error) {
	var ev Event
	if err := json.Unmarshal(data, &ev); err != nil {
		return nil, fmt.Errorf("invalid audit JSON: %w", err)
	}
	if ev.Timestamp == "" {
		return nil, fmt.Errorf("audit event missing mandatory 'timestamp' field")
	}
	if ev.Event == "" {
		return nil, fmt.Errorf("audit event missing mandatory 'event' field")
	}
	return &ev, nil
}
