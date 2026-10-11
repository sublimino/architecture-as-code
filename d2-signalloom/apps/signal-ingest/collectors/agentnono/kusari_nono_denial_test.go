// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// kusariSPIFFE is the SPIFFE id the agent-nono-kusari workload presents, matching
// the ServiceAccount SPIFFE annotation on its Deployment.
const kusariSPIFFE = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-kusari"

// signKusariEvent fills in the hash-chain digest and detached Ed... (ECDSA) SVID
// signature over an event's canonical payload, exactly as fixtures.go does for
// the evidenced agent. It must be called AFTER every canonical field
// (Syscall/Path/Seq/Timestamp/...) is set, because CanonicalPayload covers them.
func signKusariEvent(t *testing.T, kp *FixtureKeypair, ev *NonoAuditEvent) {
	t.Helper()
	payload := ev.CanonicalPayload()
	h := sha256.New()
	if ev.PrevDigest != "" {
		h.Write([]byte(ev.PrevDigest))
	}
	h.Write(payload)
	ev.Digest = hex.EncodeToString(h.Sum(nil))

	sig, err := kp.SignPayload(payload)
	if err != nil {
		t.Fatalf("sign kusari event: %v", err)
	}
	ev.Signature = sig
	ev.SignatureGitOID = ComputeGitOID(payload)
}

// newKusariDenialEvent builds a signed Landlock filesystem-containment denial for
// the kusari agent: openat(/etc/shadow) refused by the kusari-enforce.toml
// profile. This is the event a /act/read-shadow provocation produces when the
// enforce profile denies the read at the kernel.
func newKusariDenialEvent(t *testing.T, kp *FixtureKeypair, sessionID string, baseTime time.Time) *NonoAuditEvent {
	t.Helper()
	ev := &NonoAuditEvent{
		Timestamp:               baseTime,
		AgentID:                 "agent-nono-kusari",
		Name:                    "Kusari Agent (Nono Enforced)",
		Profile:                 "nono-kusari-enforced",
		SPIFFEID:                kp.SPIFFEID,
		Status:                  "healthy",
		LifecycleState:          "active",
		HeartbeatSeq:            1,
		NonoCapabilityAvailable: true,
		AuditSessionID:          sessionID,
		SessionID:               sessionID,
		Seq:                     1,
		EventType:               "landlock_filesystem_containment",
		Event:                   "landlock_filesystem_containment",
		Landlock: LandlockStatus{
			Available:          true,
			Status:             "active",
			ABIVersion:         3,
			Enforced:           true,
			FilesystemEnforced: true,
			Restrictions:       []string{"/etc/shadow:deny", "/etc/passwd:deny", "/dev/nvidiactl:deny"},
		},
		Syscall:           "openat",
		Path:              "/etc/shadow",
		DenialReason:      "landlock_fs_read_denied",
		Certificate:       kp.WorkloadPEM,
		DelegationChainID: "chain-del-kusari-001",
	}
	signKusariEvent(t, kp, ev)
	return ev
}

// TestKusariNonoDenialProjectsObservation drives a signed kusari Landlock denial
// event through the collector AS-IS and asserts the sink receives one observation
// carrying the syscall / path / denial_reason labels with the denial values.
func TestKusariNonoDenialProjectsObservation(t *testing.T) {
	kp, err := GenerateTestKeypair(kusariSPIFFE)
	if err != nil {
		t.Fatalf("generate keypair: %v", err)
	}

	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewCollector("live", sink, CollectorConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})
	if err := col.Start(ctx); err != nil {
		t.Fatalf("collector Start failed: %v", err)
	}
	defer col.Stop()

	baseTime := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)
	ev := newKusariDenialEvent(t, kp, "audit-sess-kusari-denial-001", baseTime)

	data, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal denial event: %v", err)
	}
	if err := col.IngestRawLine(ctx, data); err != nil {
		t.Fatalf("IngestRawLine failed: %v", err)
	}

	// Give the worker loop time to pop, verify, and project.
	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadUint64(&sink.count) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := atomic.LoadUint64(&sink.count); got != 1 {
		t.Fatalf("expected exactly 1 observation projected, got %d", got)
	}

	sink.mu.Lock()
	obs := sink.observations[0]
	sink.mu.Unlock()

	// The denial labels are the whole point: a detector keys on these.
	if obs.Labels["syscall"] != "openat" {
		t.Errorf("syscall label: want openat, got %q", obs.Labels["syscall"])
	}
	if obs.Labels["path"] != "/etc/shadow" {
		t.Errorf("path label: want /etc/shadow, got %q", obs.Labels["path"])
	}
	if obs.Labels["denial_reason"] != "landlock_fs_read_denied" {
		t.Errorf("denial_reason label: want landlock_fs_read_denied, got %q", obs.Labels["denial_reason"])
	}

	// A signed, trust-bundled event must verify, so the denial is trustworthy.
	if obs.Labels["verification_status"] != string(StatusVerified) {
		t.Errorf("verification_status: want %s, got %q", StatusVerified, obs.Labels["verification_status"])
	}
	if obs.ActorID != "agent-nono-kusari" {
		t.Errorf("actor_id: want agent-nono-kusari, got %q", obs.ActorID)
	}
	if obs.ActorHint != kusariSPIFFE {
		t.Errorf("actor_hint: want %s, got %q", kusariSPIFFE, obs.ActorHint)
	}
	if obs.Labels["agent_id"] != "agent-nono-kusari" {
		t.Errorf("agent_id label: want agent-nono-kusari, got %q", obs.Labels["agent_id"])
	}

	// KNOWN FINDING (not fixed here): collector.go hardcodes Source to
	// "agent-nono-evidenced" regardless of the emitting agent, so the kusari
	// denial is attributed to the evidenced source. Asserted so the test tracks
	// the behaviour the lead is recording rather than silently masking it.
	if obs.Source != "agent-nono-evidenced" {
		t.Errorf("source (hardcoded, known finding): want agent-nono-evidenced, got %q", obs.Source)
	}
}

// TestKusariForgedEventIsRejectedAndDoesNotProject proves the inverse: an event
// the verifier rejects must NOT project to an observation. The pure-Go external
// contract verifier (VerifyHostUpload) is the component that truly REJECTS —
// returning an error and no upload — so projection is gated on it. The control
// case proves the gate is not vacuous: a valid upload DOES project.
func TestKusariForgedEventIsRejectedAndDoesNotProject(t *testing.T) {
	valid := fixture(t, "valid-upload.v1.json")

	// project models the ingest contract: verify first, and only project
	// observations into the sink when the verifier accepts. A rejection yields
	// zero projections.
	project := func(sink *mockSink, data []byte, binding TrustedHostBinding) (int, error) {
		upload, err := VerifyHostUpload(data, binding)
		if err != nil {
			return 0, err // verifier rejected: nothing reaches the sink
		}
		projected := 0
		for i, assertion := range upload.AssertionEnvelope.Assertions {
			obs := &model.Observation{
				ID:      fmt.Sprintf("ext-%s-%d", upload.SessionID, upload.SequenceStart+uint64(i)),
				Source:  assertion.Source,
				ActorID: assertion.AgentID,
				Labels: map[string]string{
					"evidence_type":     assertion.EvidenceType,
					"observation_state": assertion.ObservationState,
					"host_id":           assertion.HostID,
				},
			}
			if err := sink.IngestObservation(context.Background(), obs); err != nil {
				return projected, err
			}
			projected++
		}
		return projected, nil
	}

	// Control: a valid upload with the trusted binding must project, otherwise
	// the negative assertions below would pass vacuously.
	t.Run("valid upload projects", func(t *testing.T) {
		sink := &mockSink{}
		n, err := project(sink, valid, testBinding())
		if err != nil {
			t.Fatalf("valid upload rejected: %v", err)
		}
		if n == 0 {
			t.Fatal("valid upload projected zero observations; gate is vacuous")
		}
		if got := atomic.LoadUint64(&sink.count); got != uint64(n) {
			t.Fatalf("sink recorded %d observations, project reported %d", got, n)
		}
	})

	// unknownEvidenceKey injects a key the strict (DisallowUnknownFields)
	// evidence contract does not permit, mirroring the existing contract suite.
	unknownEvidenceKey := bytes.Replace(valid,
		[]byte(`"observed_at":`),
		[]byte(`"private_path":"/secret","observed_at":`), 1)

	// wrongIdentity binds the upload to a different registered agent identity —
	// the contract's SPIFFE/registration anchor — so the signed assertions no
	// longer match their trusted binding.
	wrongIdentity := testBinding()
	wrongIdentity.AgentID = "agent-nono-kusari"

	forged := map[string]struct {
		data    []byte
		binding TrustedHostBinding
	}{
		// Signed payload mutated after signing: Ed25519 signature no longer matches.
		"bad signature":        {fixture(t, "tampered-upload.v1.json"), testBinding()},
		"unknown evidence key": {unknownEvidenceKey, testBinding()},
		"wrong spiffe binding": {valid, wrongIdentity},
	}

	for name, tc := range forged {
		t.Run(name, func(t *testing.T) {
			sink := &mockSink{}
			n, err := project(sink, tc.data, tc.binding)
			if err == nil {
				t.Fatalf("forged upload (%s) was accepted by the verifier", name)
			}
			if n != 0 {
				t.Fatalf("forged upload (%s) projected %d observations", name, n)
			}
			if got := atomic.LoadUint64(&sink.count); got != 0 {
				t.Fatalf("forged upload (%s) reached the sink: %d observations recorded", name, got)
			}
		})
	}
}
