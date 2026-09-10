// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"encoding/json"
	"fmt"
	"time"
)

// VerificationStatus represents the cryptographic attestation outcome of an audit event.
type VerificationStatus string

const (
	// StatusVerified indicates valid signature against SPIFFE trust domain and unbroken hash chain.
	StatusVerified VerificationStatus = "VERIFIED"
	// StatusUnverified indicates missing, untrusted, or unresolvable signature.
	StatusUnverified VerificationStatus = "UNVERIFIED"
	// StatusTampered indicates hash chain break, modified payload, or cryptographic verification mismatch.
	StatusTampered VerificationStatus = "TAMPERED"
	// StatusUnsigned indicates telemetry admitted without cryptographic signature.
	StatusUnsigned VerificationStatus = "UNSIGNED"
)

// LandlockStatus captures Linux Landlock LSM confinement state, restriction rules, and denials.
type LandlockStatus struct {
	Available          bool     `json:"available,omitempty"`
	Status             string   `json:"status,omitempty"`
	ABIVersion         int      `json:"abi_version,omitempty"`
	Enforced           bool     `json:"enforced,omitempty"`
	FilesystemEnforced bool     `json:"filesystem_enforced,omitempty"`
	NetworkEnforced    bool     `json:"network_enforced,omitempty"`
	Restrictions       []string `json:"restrictions,omitempty"`
	DenialsCount       int64    `json:"denials_count,omitempty"`
	PolicyDigest       string   `json:"policy_digest,omitempty"`
}

// AttestationSignature represents a single cryptographic signature in a DSSE/in-toto envelope.
type AttestationSignature struct {
	KeyID string `json:"keyid,omitempty"`
	Sig   string `json:"sig"`
	Cert  string `json:"cert,omitempty"`
}

// AttestationEnvelope wraps an in-toto / DSSE statement with detached or attached SPIFFE SVID signatures.
type AttestationEnvelope struct {
	PayloadType        string                 `json:"payloadType"`
	Payload            string                 `json:"payload"`
	Signatures         []AttestationSignature `json:"signatures,omitempty"`
	DetachedSignature  string                 `json:"detached_signature,omitempty"`
	CertificateChain   []string               `json:"certificate_chain,omitempty"`
	VerificationStatus VerificationStatus     `json:"verification_status,omitempty"`
	GitOID             string                 `json:"gitoid,omitempty"`
	SigningKeyID       string                 `json:"key_id,omitempty"`
}

// NonoAuditEvent models a single live or recorded audit session event from agent-nono-evidenced.
type NonoAuditEvent struct {
	Timestamp               time.Time              `json:"timestamp"`
	AgentID                 string                 `json:"agent_id"`
	Name                    string                 `json:"name,omitempty"`
	Profile                 string                 `json:"profile,omitempty"`
	SPIFFEID                string                 `json:"spiffe_id"`
	Status                  string                 `json:"status,omitempty"`
	LifecycleState          string                 `json:"lifecycle_state,omitempty"`
	HeartbeatSeq            int64                  `json:"heartbeat_seq,omitempty"`
	NonoCapabilityAvailable bool                   `json:"nono_capability_available"`
	AuditSessionID          string                 `json:"audit_session_id,omitempty"`
	SessionID               string                 `json:"session_id,omitempty"`
	Seq                     int64                  `json:"seq,omitempty"`
	Event                   string                 `json:"event,omitempty"`
	EventType               string                 `json:"event_type,omitempty"`
	Landlock                LandlockStatus         `json:"landlock,omitempty"`
	Syscall                 string                 `json:"syscall,omitempty"`
	Path                    string                 `json:"path,omitempty"`
	DenialReason            string                 `json:"denial_reason,omitempty"`
	Restrictions            []string               `json:"restrictions,omitempty"`
	PrevDigest              string                 `json:"prev_digest,omitempty"`
	Digest                  string                 `json:"digest,omitempty"`
	Signature               string                 `json:"signature,omitempty"`
	SignatureGitOID         string                 `json:"signature_gitoid,omitempty"`
	Certificate             string                 `json:"certificate,omitempty"`
	CertificateChain        []string               `json:"certificate_chain,omitempty"`
	DelegationChainID       string                 `json:"delegation_chain_id,omitempty"`
	ActorID                 string                 `json:"actor_id,omitempty"`
	Metadata                map[string]interface{} `json:"metadata,omitempty"`
	RawBytes                []byte                 `json:"-"`
}

// rawNonoEvent is an internal alias used for JSON parsing of flexible field names.
type rawNonoEvent struct {
	Timestamp               interface{}            `json:"timestamp"`
	AgentID                 string                 `json:"agent_id"`
	Name                    string                 `json:"name,omitempty"`
	Profile                 string                 `json:"profile,omitempty"`
	SPIFFEID                string                 `json:"spiffe_id"`
	Status                  string                 `json:"status,omitempty"`
	LifecycleState          string                 `json:"lifecycle_state,omitempty"`
	HeartbeatSeq            int64                  `json:"heartbeat_seq,omitempty"`
	NonoCapabilityAvailable *bool                  `json:"nono_capability_available,omitempty"`
	NonoAvailable           *bool                  `json:"nono_available,omitempty"`
	AuditSessionID          string                 `json:"audit_session_id,omitempty"`
	SessionID               string                 `json:"session_id,omitempty"`
	Seq                     int64                  `json:"seq,omitempty"`
	Event                   string                 `json:"event,omitempty"`
	EventType               string                 `json:"event_type,omitempty"`
	Landlock                *LandlockStatus        `json:"landlock,omitempty"`
	Sandboxing              string                 `json:"sandboxing,omitempty"`
	EvidenceSigning         string                 `json:"evidence_signing,omitempty"`
	Syscall                 string                 `json:"syscall,omitempty"`
	Path                    string                 `json:"path,omitempty"`
	DenialReason            string                 `json:"denial_reason,omitempty"`
	Restrictions            []string               `json:"restrictions,omitempty"`
	PrevDigest              string                 `json:"prev_digest,omitempty"`
	Digest                  string                 `json:"digest,omitempty"`
	Signature               string                 `json:"signature,omitempty"`
	SignatureGitOID         string                 `json:"signature_gitoid,omitempty"`
	Certificate             string                 `json:"certificate,omitempty"`
	CertificateChain        []string               `json:"certificate_chain,omitempty"`
	DelegationChainID       string                 `json:"delegation_chain_id,omitempty"`
	ActorID                 string                 `json:"actor_id,omitempty"`
	Metadata                map[string]interface{} `json:"metadata,omitempty"`
}

// UnmarshalJSON parses JSON audit events supporting timestamp variants and field aliases.
func (e *NonoAuditEvent) UnmarshalJSON(data []byte) error {
	var raw rawNonoEvent
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("decode nono audit event: %w", err)
	}

	e.AgentID = raw.AgentID
	e.Name = raw.Name
	e.Profile = raw.Profile
	e.SPIFFEID = raw.SPIFFEID
	e.Status = raw.Status
	e.LifecycleState = raw.LifecycleState
	e.HeartbeatSeq = raw.HeartbeatSeq
	e.Seq = raw.Seq
	e.Event = raw.Event
	e.EventType = raw.EventType
	if e.EventType == "" {
		e.EventType = raw.Event
	}
	if e.EventType == "" && e.HeartbeatSeq > 0 {
		e.EventType = "heartbeat"
	}

	// Dynamic Nono availability aliases
	if raw.NonoCapabilityAvailable != nil {
		e.NonoCapabilityAvailable = *raw.NonoCapabilityAvailable
	} else if raw.NonoAvailable != nil {
		e.NonoCapabilityAvailable = *raw.NonoAvailable
	}

	// Session ID aliases
	e.AuditSessionID = raw.AuditSessionID
	if e.AuditSessionID == "" {
		e.AuditSessionID = raw.SessionID
	}
	e.SessionID = e.AuditSessionID

	// Landlock metadata
	if raw.Landlock != nil {
		e.Landlock = *raw.Landlock
	} else {
		e.Landlock = LandlockStatus{
			Available: e.NonoCapabilityAvailable,
			Status:    raw.Status,
		}
		if raw.Sandboxing == "landlock" {
			e.Landlock.Enforced = true
			e.Landlock.FilesystemEnforced = true
		}
	}

	e.Syscall = raw.Syscall
	e.Path = raw.Path
	e.DenialReason = raw.DenialReason
	e.Restrictions = raw.Restrictions
	e.PrevDigest = raw.PrevDigest
	e.Digest = raw.Digest
	e.Signature = raw.Signature
	e.SignatureGitOID = raw.SignatureGitOID
	e.Certificate = raw.Certificate
	e.CertificateChain = raw.CertificateChain
	e.DelegationChainID = raw.DelegationChainID
	e.ActorID = raw.ActorID
	e.Metadata = raw.Metadata
	e.RawBytes = make([]byte, len(data))
	copy(e.RawBytes, data)

	// Timestamp parsing
	switch v := raw.Timestamp.(type) {
	case string:
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			t, err = time.Parse(time.RFC3339, v)
		}
		if err == nil {
			e.Timestamp = t.UTC()
		} else {
			e.Timestamp = time.Now().UTC()
		}
	case float64:
		e.Timestamp = time.Unix(0, int64(v*1e9)).UTC()
	case int64:
		e.Timestamp = time.Unix(v, 0).UTC()
	default:
		e.Timestamp = time.Now().UTC()
	}

	return nil
}

// CanonicalPayload returns the deterministic bytes used for hash chaining and detached signature verification.
func (e *NonoAuditEvent) CanonicalPayload() []byte {
	type canonicalDoc struct {
		SessionID  string `json:"session_id"`
		Seq        int64  `json:"seq"`
		Timestamp  string `json:"timestamp"`
		AgentID    string `json:"agent_id"`
		SPIFFEID   string `json:"spiffe_id"`
		EventType  string `json:"event_type"`
		PrevDigest string `json:"prev_digest"`
		Syscall    string `json:"syscall,omitempty"`
		Path       string `json:"path,omitempty"`
	}

	doc := canonicalDoc{
		SessionID:  e.AuditSessionID,
		Seq:        e.Seq,
		Timestamp:  e.Timestamp.Format(time.RFC3339Nano),
		AgentID:    e.AgentID,
		SPIFFEID:   e.SPIFFEID,
		EventType:  e.EventType,
		PrevDigest: e.PrevDigest,
		Syscall:    e.Syscall,
		Path:       e.Path,
	}

	b, _ := json.Marshal(doc)
	return b
}
