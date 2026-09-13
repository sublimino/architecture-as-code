// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/url"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// FixtureKeypair holds an in-memory CA and Workload SVID certificate for deterministic test fixtures.
type FixtureKeypair struct {
	CACert        *x509.Certificate
	CACertPEM     string
	CAKey         *ecdsa.PrivateKey
	WorkloadCert  *x509.Certificate
	WorkloadPEM   string
	WorkloadKey   *ecdsa.PrivateKey
	SPIFFEID      string
}

// GenerateTestKeypair generates a valid self-signed SPIRE CA and workload SVID certificate.
func GenerateTestKeypair(spiffeID string) (*FixtureKeypair, error) {
	if spiffeID == "" {
		spiffeID = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	}

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate CA key: %w", err)
	}

	spiffeURI, err := url.Parse(DefaultTrustDomain)
	if err != nil {
		return nil, err
	}

	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   "SPIRE CA",
			Organization: []string{"Signal Loom"},
		},
		URIs:                  []*url.URL{spiffeURI},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
	}

	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, fmt.Errorf("create CA cert: %w", err)
	}

	caCert, _ := x509.ParseCertificate(caDER)
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})

	workloadKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate workload key: %w", err)
	}

	workloadURI, err := url.Parse(spiffeID)
	if err != nil {
		return nil, err
	}

	workloadTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			CommonName:   spiffeID,
			Organization: []string{"Signal Loom"},
		},
		URIs:      []*url.URL{workloadURI},
		NotBefore: time.Now().Add(-1 * time.Hour),
		NotAfter:  time.Now().Add(12 * time.Hour),
		KeyUsage:  x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{
			x509.ExtKeyUsageClientAuth,
			x509.ExtKeyUsageServerAuth,
		},
	}

	workloadDER, err := x509.CreateCertificate(rand.Reader, workloadTemplate, caCert, &workloadKey.PublicKey, caKey)
	if err != nil {
		return nil, fmt.Errorf("create workload cert: %w", err)
	}

	workloadCert, _ := x509.ParseCertificate(workloadDER)
	workloadPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: workloadDER})

	return &FixtureKeypair{
		CACert:       caCert,
		CACertPEM:    string(caPEM),
		CAKey:        caKey,
		WorkloadCert: workloadCert,
		WorkloadPEM:  string(workloadPEM),
		WorkloadKey:  workloadKey,
		SPIFFEID:     spiffeID,
	}, nil
}

// SignPayload signs a byte payload using the fixture workload key and returns base64 DER signature.
func (kp *FixtureKeypair) SignPayload(payload []byte) (string, error) {
	digest := sha256.Sum256(payload)
	r, s, err := ecdsa.Sign(rand.Reader, kp.WorkloadKey, digest[:])
	if err != nil {
		return "", err
	}
	type ecdsaSignature struct {
		R, S *big.Int
	}
	der, err := asn1.Marshal(ecdsaSignature{R: r, S: s})
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

// GenerateSignedSession creates a hash-chained, cryptographically signed sequence of audit events.
func GenerateSignedSession(kp *FixtureKeypair, sessionID string, count int, baseTime time.Time) ([]*NonoAuditEvent, error) {
	if kp == nil {
		var err error
		kp, err = GenerateTestKeypair("")
		if err != nil {
			return nil, err
		}
	}
	if sessionID == "" {
		sessionID = fmt.Sprintf("audit-sess-agent-nono-evidenced-%d", baseTime.Unix())
	}

	var events []*NonoAuditEvent
	var prevDigest string

	for i := 1; i <= count; i++ {
		evTime := baseTime.Add(time.Duration(i*10) * time.Second)
		evType := "heartbeat"
		if i == 1 {
			evType = "nono_probe"
		} else if i == count {
			evType = "landlock_filesystem_containment"
		}

		event := &NonoAuditEvent{
			Timestamp:               evTime,
			AgentID:                 "agent-nono-evidenced",
			Name:                    "Demo Agent (Nono Evidenced)",
			Profile:                 "nono-evidenced",
			SPIFFEID:                kp.SPIFFEID,
			Status:                  "healthy",
			LifecycleState:          "active",
			HeartbeatSeq:            int64(i),
			NonoCapabilityAvailable: true,
			AuditSessionID:          sessionID,
			SessionID:               sessionID,
			Seq:                     int64(i),
			EventType:               evType,
			Event:                   evType,
			Landlock: LandlockStatus{
				Available:          true,
				Status:             "active",
				ABIVersion:         3,
				Enforced:           true,
				FilesystemEnforced: true,
				Restrictions:       []string{"/etc/shadow:deny", "/var/run/secrets:allow-ro"},
			},
			PrevDigest:        prevDigest,
			Certificate:       kp.WorkloadPEM,
			DelegationChainID: "chain-del-001",
		}

		if evType == "landlock_filesystem_containment" {
			event.Syscall = "openat"
			event.Path = "/etc/shadow"
			event.DenialReason = "Landlock filesystem containment rule violation (EACCES)"
		}

		payload := event.CanonicalPayload()
		h := sha256.New()
		if prevDigest != "" {
			h.Write([]byte(prevDigest))
		}
		h.Write(payload)
		digest := hex.EncodeToString(h.Sum(nil))
		event.Digest = digest
		prevDigest = digest

		sig, err := kp.SignPayload(payload)
		if err != nil {
			return nil, fmt.Errorf("sign fixture event %d: %w", i, err)
		}
		event.Signature = sig
		event.SignatureGitOID = ComputeGitOID(payload)

		events = append(events, event)
	}

	return events, nil
}

// GenerateTamperedSession returns a session with a deliberate hash chain break.
func GenerateTamperedSession(kp *FixtureKeypair, sessionID string, baseTime time.Time) ([]*NonoAuditEvent, error) {
	events, err := GenerateSignedSession(kp, sessionID, 3, baseTime)
	if err != nil {
		return nil, err
	}
	// Tamper event 2 payload while retaining old signature and digest
	events[1].Path = "/tampered/injected/payload"
	events[1].Digest = "0000000000000000000000000000000000000000000000000000000000000000"
	return events, nil
}

// AgentNonoFixtures returns standard Model observations derived from signed agent-nono sessions.
func AgentNonoFixtures(baseTime time.Time) []model.Observation {
	kp, err := GenerateTestKeypair("")
	if err != nil {
		return nil
	}
	sessionID := fmt.Sprintf("audit-sess-fixture-%d", baseTime.Unix())
	events, err := GenerateSignedSession(kp, sessionID, 4, baseTime)
	if err != nil {
		return nil
	}

	var observations []model.Observation
	for i, ev := range events {
		obs := model.Observation{
			ID:             fmt.Sprintf("nono-%s-%d", ev.AuditSessionID, ev.Seq),
			Timestamp:      ev.Timestamp,
			Layer:          model.LayerEndpointHost,
			Fidelity:       model.FidelityDefinitive,
			Source:         "agent-nono-evidenced",
			Confidence:     1.0,
			ActorHint:      ev.SPIFFEID,
			RawEvidenceRef: fmt.Sprintf("nono://session/%s/event/%d", ev.AuditSessionID, ev.Seq),
			SessionID:      ev.AuditSessionID,
			ActorID:        ev.AgentID,
			Description:    fmt.Sprintf("Nono Landlock audit session event #%d (%s)", ev.Seq, ev.EventType),
			Labels: map[string]string{
				"event_type":          ev.EventType,
				"spiffe_id":           ev.SPIFFEID,
				"agent_id":            ev.AgentID,
				"verification_status": string(StatusVerified),
				"hash_chain_digest":   ev.Digest,
				"prev_digest":         ev.PrevDigest,
				"signature_gitoid":    ev.SignatureGitOID,
				"landlock_status":     ev.Landlock.Status,
				"landlock_abi":        fmt.Sprintf("%d", ev.Landlock.ABIVersion),
				"nono_available":      fmt.Sprintf("%t", ev.NonoCapabilityAvailable),
				"delegation_chain_id": ev.DelegationChainID,
			},
		}
		if i == len(events)-1 {
			obs.Labels["syscall"] = ev.Syscall
			obs.Labels["path"] = ev.Path
			obs.Labels["denial_reason"] = ev.DenialReason
		}
		observations = append(observations, obs)
	}

	return observations
}

// GenerateFinalizedSignedSession returns a fully signed session whose terminal event is marked finalized.
func GenerateFinalizedSignedSession(kp *FixtureKeypair, sessionID string, count int, baseTime time.Time) ([]*NonoAuditEvent, error) {
	if count < 1 {
		count = 1
	}
	events, err := GenerateSignedSession(kp, sessionID, count, baseTime)
	if err != nil {
		return nil, err
	}

	// Mark the terminal event as finalized and resign it
	last := events[len(events)-1]
	last.LifecycleState = "finalized"
	last.EventType = "session_finalized"
	last.Event = "finalized"

	// Recompute canonical payload, digest, and signature for the finalized event
	payload := last.CanonicalPayload()
	h := sha256.New()
	if last.PrevDigest != "" {
		h.Write([]byte(last.PrevDigest))
	}
	h.Write(payload)
	last.Digest = hex.EncodeToString(h.Sum(nil))

	sig, err := kp.SignPayload(payload)
	if err != nil {
		return nil, fmt.Errorf("resign finalized terminal event: %w", err)
	}
	last.Signature = sig
	last.SignatureGitOID = ComputeGitOID(payload)

	return events, nil
}
