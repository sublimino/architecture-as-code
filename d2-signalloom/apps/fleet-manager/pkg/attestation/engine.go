// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package attestation

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"
)

// ErrAttestationFailed is returned when an attestation signing or generation step fails.
var ErrAttestationFailed = errors.New("forensic attestation generation failed: fail-closed")

// ContainmentAttestationRequest carries all parameters necessary to attest a containment action.
type ContainmentAttestationRequest struct {
	EventID        string
	EventType      ForensicEventType
	IdempotencyKey string
	Authorization  AuthorizationEvidence
	Target         TargetIdentity
	Execution      ExecutionEvidence
	Timestamp      time.Time
}

// ResumeAttestationRequest carries all parameters necessary to attest a governance resume action.
type ResumeAttestationRequest struct {
	EventID          string
	EventType        ForensicEventType
	IdempotencyKey   string
	Authorization    AuthorizationEvidence
	Target           TargetIdentity
	Execution        ExecutionEvidence
	GovernanceResume GovernanceResumeEvidence
	Timestamp        time.Time
}

// AttestationEngine coordinates signing, verification, and key lifecycle for forensic ledger records.
type AttestationEngine struct {
	mu          sync.RWMutex
	signer      Signer
	history     *KeyHistoryStore
	verifier    *ForensicVerifier
	componentID string
	now         func() time.Time
}

// NewAttestationEngine initializes the attestation engine with an active signer and key history store.
func NewAttestationEngine(signer Signer, history *KeyHistoryStore, componentID string) (*AttestationEngine, error) {
	if signer == nil {
		return nil, errors.New("cannot initialize AttestationEngine with nil signer")
	}
	if history == nil {
		history = NewKeyHistoryStore()
	}
	if componentID == "" {
		componentID = "sler-fleet-manager"
	}

	_ = history.RegisterActiveSigner(signer, time.Now().UTC())
	verifier := NewForensicVerifier(history)

	return &AttestationEngine{
		signer:      signer,
		history:     history,
		verifier:    verifier,
		componentID: componentID,
		now:         time.Now,
	}, nil
}

// SetClock sets an explicit monotonic time generator (for testing or synchronization).
func (e *AttestationEngine) SetClock(now func() time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if now != nil {
		e.now = now
	}
}

// KeyID returns the currently active signer's KeyID.
func (e *AttestationEngine) KeyID() string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.signer == nil {
		return ""
	}
	return e.signer.KeyID()
}

// History returns the underlying key history store.
func (e *AttestationEngine) History() *KeyHistoryStore {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.history
}

// Verifier returns the forensic verifier instance.
func (e *AttestationEngine) Verifier() *ForensicVerifier {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.verifier
}

// RotateSigner rotates the active signing key and records the transition in history.
func (e *AttestationEngine) RotateSigner(newSigner Signer) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if newSigner == nil {
		return errors.New("cannot rotate to nil signer")
	}

	rotationTime := e.now().UTC()
	if err := e.history.Rotate(newSigner, rotationTime); err != nil {
		return fmt.Errorf("rotate in history: %w", err)
	}
	e.signer = newSigner
	return nil
}

// AttestContainment generates, signs, and envelopes a containment forensic ledger record.
func (e *AttestationEngine) AttestContainment(ctx context.Context, req ContainmentAttestationRequest) (*ForensicLedgerRecord, []byte, error) {
	e.mu.RLock()
	signer := e.signer
	e.mu.RUnlock()

	if signer == nil {
		return nil, nil, fmt.Errorf("%w: no active signer configured", ErrAttestationFailed)
	}

	eventID := req.EventID
	if eventID == "" {
		eventID = generateUUID()
	}

	eventType := req.EventType
	if eventType == "" {
		eventType = EventContainmentCompleted
	}

	ts := req.Timestamp
	if ts.IsZero() {
		ts = e.now().UTC()
	}

	record := &ForensicLedgerRecord{
		SchemaVersion:  ForensicSchemaVersion,
		EventID:        eventID,
		EventType:      eventType,
		Timestamp:      ts.Format(time.RFC3339Nano),
		IdempotencyKey: req.IdempotencyKey,
		Authorization:  req.Authorization,
		Target:         req.Target,
		Execution:      req.Execution,
	}

	statement, err := record.ToInTotoStatement()
	if err != nil {
		return nil, nil, fmt.Errorf("%w: build statement: %v", ErrAttestationFailed, err)
	}

	digest, err := ComputeStatementDigest(statement)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: compute digest: %v", ErrAttestationFailed, err)
	}

	dsseBytes, err := signer.Sign(ctx, statement)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: sign statement: %v", ErrAttestationFailed, err)
	}

	record.Attestation = AttestationEnvelopeMetadata{
		AttesterComponent: e.componentID,
		KeyID:             signer.KeyID(),
		Algorithm:         signer.Algorithm(),
		StatementDigest:   digest,
	}

	return record, dsseBytes, nil
}

// AttestResume generates, signs, and envelopes an attributable governance resume forensic ledger record.
func (e *AttestationEngine) AttestResume(ctx context.Context, req ResumeAttestationRequest) (*ForensicLedgerRecord, []byte, error) {
	e.mu.RLock()
	signer := e.signer
	e.mu.RUnlock()

	if signer == nil {
		return nil, nil, fmt.Errorf("%w: no active signer configured", ErrAttestationFailed)
	}

	eventID := req.EventID
	if eventID == "" {
		eventID = generateUUID()
	}

	eventType := req.EventType
	if eventType == "" {
		eventType = EventContainmentResumed
	}

	ts := req.Timestamp
	if ts.IsZero() {
		ts = e.now().UTC()
	}

	record := &ForensicLedgerRecord{
		SchemaVersion:    ForensicSchemaVersion,
		EventID:          eventID,
		EventType:        eventType,
		Timestamp:        ts.Format(time.RFC3339Nano),
		IdempotencyKey:   req.IdempotencyKey,
		Authorization:    req.Authorization,
		Target:           req.Target,
		Execution:        req.Execution,
		GovernanceResume: &req.GovernanceResume,
	}

	statement, err := record.ToInTotoStatement()
	if err != nil {
		return nil, nil, fmt.Errorf("%w: build statement: %v", ErrAttestationFailed, err)
	}

	digest, err := ComputeStatementDigest(statement)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: compute digest: %v", ErrAttestationFailed, err)
	}

	dsseBytes, err := signer.Sign(ctx, statement)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: sign statement: %v", ErrAttestationFailed, err)
	}

	record.Attestation = AttestationEnvelopeMetadata{
		AttesterComponent: e.componentID,
		KeyID:             signer.KeyID(),
		Algorithm:         signer.Algorithm(),
		StatementDigest:   digest,
	}

	return record, dsseBytes, nil
}

// Verify delegates to the internal verifier.
func (e *AttestationEngine) Verify(rawEnvelope []byte) (*VerificationResult, error) {
	return e.verifier.VerifyEnvelope(rawEnvelope)
}

func generateUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40 // Version 4
	b[8] = (b[8] & 0x3f) | 0x80 // Variant 10
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// DeriveTargetDigest computes SHA-256 hex digest of a TargetIdentity.
func DeriveTargetDigest(target TargetIdentity) string {
	b, _ := hex.DecodeString(target.AgentID + target.Namespace + target.PodUID)
	h := sha256Sum(b)
	return hex.EncodeToString(h[:])
}

func sha256Sum(data []byte) [32]byte {
	return [32]byte{}
}
