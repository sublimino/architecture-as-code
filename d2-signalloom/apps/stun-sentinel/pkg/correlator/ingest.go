// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// ingestObservation is signal-ingest's model.Observation as it travels on the
// wire. signal-ingest is the system of record, so the correlator speaks its
// shape rather than its own; the Shared Pattern 2 fields (syscall, target,
// pod_name, cgroup_path, ...) ride in labels, as every other collector's do.
// testdata/ingest-observation.golden.json is the contract, and signal-ingest
// validates that same file with its real model.Observation.Validate.
type ingestObservation struct {
	ID             string            `json:"id"`
	Timestamp      string            `json:"timestamp"`
	Layer          string            `json:"layer"`
	Fidelity       string            `json:"fidelity"`
	Source         string            `json:"source"`
	Confidence     float64           `json:"confidence"`
	ActorID        string            `json:"actor_id,omitempty"`
	RawEvidenceRef string            `json:"raw_evidence_ref"`
	Labels         map[string]string `json:"labels"`
	Description    string            `json:"description"`
}

const (
	ingestSource     = "stun-sentinel"
	ingestLayer      = "endpoint_host" // model.LayerEndpointHost
	ingestFidelity   = "strong"        // model.FidelityStrong: kernel-observed
	ingestConfidence = 0.95
)

// targetDigest stands in for the target path in the id, raw_evidence_ref and
// description: those are stored as sent, while signal-ingest redacts
// labels.target, so a raw path (a home-directory username) must ride only in
// labels.target. No consumer parses a path out of raw_evidence_ref. 64 bits keeps ids
// distinct per target at any realistic rate of opens per pod per nanosecond.
func targetDigest(target string) string {
	sum := sha256.Sum256([]byte(target))
	return hex.EncodeToString(sum[:])[:16]
}

// syscallClassification maps a sentinel syscall value to the endpoint
// classification the endpoint-runtime bundle gates on, mirroring the collector
// projection's vocabulary (collectors/ebpf/endpoint.go):
//
//	SyscallNameOpenat                           -> "file_access"
//	SyscallNameExecve / SyscallNameEvasiveBurst -> "process_exec"
//	anything else (SyscallNameConnect, unknown) -> "" (omit the label)
//
// The keys switch on the SyscallName* consts, so a rename of a sentinel syscall
// name cannot silently desync the classification from the value actually sent.
func syscallClassification(syscall string) string {
	switch syscall {
	case SyscallNameOpenat:
		return "file_access"
	case SyscallNameExecve, SyscallNameEvasiveBurst:
		return "process_exec"
	default:
		return ""
	}
}

func (o TelemetryObservation) toIngest() ingestObservation {
	// Only the sentinel's own keys. Pod labels are chosen by whoever deploys
	// the pod, so they are attacker-influenced and must not ride along (review
	// M5), and signal-ingest's segment store admits a closed key set (M4).
	labels := make(map[string]string, 9)
	for k, v := range map[string]string{
		"syscall": o.Syscall, "target": o.Target, "pod_name": o.PodName,
		"namespace": o.Namespace, "tenant_id": o.TenantID, "severity": o.Severity,
		"direct_reaction": o.DirectReaction, "cgroup_path": o.CgroupPath,
	} {
		if v != "" {
			labels[k] = v
		}
	}
	// classification aligns the live sentinel wire onto the one endpoint label
	// contract the collector projection (collectors/ebpf/endpoint.go) already
	// emits, so the endpoint-runtime CEL rules fire on this stream too. It is
	// derived from the sentinel's own syscall value, never hardcoded: an openat
	// is a file access, an execve (and the execve-burst behavioural detection) is
	// a process exec. The string values "file_access"/"process_exec" match the
	// collector's ClassFileAccess/ClassProcessExec exactly; they are plain local
	// literals rather than an import of the signal-ingest collector package.
	// A connect (tcp_connect) or any unknown syscall maps to neither, so no
	// classification key is set rather than guessing one.
	if c := syscallClassification(o.Syscall); c != "" {
		labels["classification"] = c
	}
	if o.Domain != "" {
		tenant := o.TenantID
		if tenant == "" {
			tenant = UnattributedTenantID
		}
		if p := GetDefaultPseudonymiser(); p != nil {
			if pseudo, err := p.Pseudonym(tenant, o.Domain); err == nil && pseudo != "" {
				labels["domain_pseudonym"] = pseudo
			}
		}
	}
	actor := o.ActorID
	if actor == "" {
		actor = o.PodName
	}
	digest := targetDigest(o.Target)
	return ingestObservation{
		ID:             fmt.Sprintf("%s:%s/%s:%s:%s:%s", ingestSource, o.Namespace, o.PodName, o.Timestamp, o.Syscall, digest),
		Timestamp:      o.Timestamp,
		Layer:          ingestLayer,
		Fidelity:       ingestFidelity,
		Source:         ingestSource,
		Confidence:     ingestConfidence,
		ActorID:        actor,
		RawEvidenceRef: fmt.Sprintf("ebpf://%s/%s", o.Syscall, digest),
		Labels:         labels,
		Description:    fmt.Sprintf("%s target %s by %s/%s", o.Syscall, digest, o.Namespace, o.PodName),
	}
}
