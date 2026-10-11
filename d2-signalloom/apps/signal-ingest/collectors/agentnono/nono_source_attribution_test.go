// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// evidencedSPIFFE is the SPIFFE id the original agent-nono-evidenced workload
// presents. Its AgentID ("agent-nono-evidenced") is also the constant the
// collector used to hardcode for every source, which is exactly why a second
// agent's denials were mis-attributed (R8).
const evidencedSPIFFE = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"

// TestSourceDerivedFromEventIdentity pins the R8 fix: the projected
// Observation.Source is derived from the emitting agent's own identity, not a
// constant. Two distinct agents drive one denial each through the SAME
// collector; each resulting observation must carry a Source equal to its own
// agent_id, so a kusari denial reads as "agent-nono-kusari" and never bleeds
// into the evidenced agent's attribution.
//
// The assertion is per-observation (Source == its own agent_id label) rather
// than a fixed string, so it bites a regression in either direction: a
// hardcoded Source makes the kusari row's Source disagree with its agent_id.
func TestSourceDerivedFromEventIdentity(t *testing.T) {
	kusariKP, err := GenerateTestKeypair(kusariSPIFFE)
	if err != nil {
		t.Fatalf("generate kusari keypair: %v", err)
	}
	evidencedKP, err := GenerateTestKeypair(evidencedSPIFFE)
	if err != nil {
		t.Fatalf("generate evidenced keypair: %v", err)
	}

	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewCollector("live", sink, CollectorConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kusariKP.CACertPEM),
	})
	if err := col.Start(ctx); err != nil {
		t.Fatalf("collector Start failed: %v", err)
	}
	defer col.Stop()

	baseTime := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)

	kusariEv := newKusariDenialEvent(t, kusariKP, "audit-sess-kusari-attr-001", baseTime)

	evidencedEvents, err := GenerateSignedSession(evidencedKP, "audit-sess-evidenced-attr-001", 1, baseTime)
	if err != nil {
		t.Fatalf("generate evidenced session: %v", err)
	}
	evidencedEv := evidencedEvents[0]
	if evidencedEv.AgentID != "agent-nono-evidenced" {
		t.Fatalf("fixture precondition: evidenced AgentID want agent-nono-evidenced, got %q", evidencedEv.AgentID)
	}

	for _, ev := range []*NonoAuditEvent{kusariEv, evidencedEv} {
		data, err := json.Marshal(ev)
		if err != nil {
			t.Fatalf("marshal event: %v", err)
		}
		if err := col.IngestRawLine(ctx, data); err != nil {
			t.Fatalf("IngestRawLine failed: %v", err)
		}
	}

	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadUint64(&sink.count) < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := atomic.LoadUint64(&sink.count); got != 2 {
		t.Fatalf("expected 2 observations projected, got %d", got)
	}

	sink.mu.Lock()
	defer sink.mu.Unlock()

	seen := map[string]bool{}
	for _, obs := range sink.observations {
		agentID := obs.Labels["agent_id"]
		if agentID == "" {
			t.Fatalf("observation %s has empty agent_id label", obs.ID)
		}
		// The whole point of R8: Source tracks the event's own identity.
		if obs.Source != agentID {
			t.Errorf("observation %s: Source %q must equal its agent_id %q (R8: derive source from event identity)",
				obs.ID, obs.Source, agentID)
		}
		seen[obs.Source] = true
	}

	if !seen["agent-nono-kusari"] {
		t.Errorf("no observation attributed to agent-nono-kusari; sources seen: %v", seen)
	}
	if !seen["agent-nono-evidenced"] {
		t.Errorf("no observation attributed to agent-nono-evidenced; sources seen: %v", seen)
	}
}

// TestSourceFallsBackToConstantWhenIdentityAbsent proves the fallback leg: an
// event with no AgentID and no SPIFFE id must still produce a non-empty Source
// (Observation.Validate requires one), using the constant as a last resort.
func TestSourceFallsBackToConstantWhenIdentityAbsent(t *testing.T) {
	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewCollector("live", sink, CollectorConfig{})
	if err := col.Start(ctx); err != nil {
		t.Fatalf("collector Start failed: %v", err)
	}
	defer col.Stop()

	ev := &NonoAuditEvent{
		Timestamp:      time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC),
		AuditSessionID: "audit-sess-anon-001",
		Seq:            1,
		EventType:      "heartbeat",
		// AgentID and SPIFFEID deliberately empty.
	}
	if err := col.IngestEvent(ctx, ev); err != nil {
		t.Fatalf("IngestEvent failed: %v", err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadUint64(&sink.count) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := atomic.LoadUint64(&sink.count); got != 1 {
		t.Fatalf("expected 1 observation, got %d", got)
	}

	sink.mu.Lock()
	defer sink.mu.Unlock()
	if obs := sink.observations[0]; obs.Source != defaultNonoSource {
		t.Errorf("Source with no identity: want constant %q, got %q", defaultNonoSource, obs.Source)
	}
}

// TestLiveTailFileProjectsSignedDenialVerifiedViaEnvTrust proves the REAL audit
// path end to end: a running nono-enforced agent writes signed NonoAuditEvent
// JSON lines to its session log; the collector tails that file through its
// existing tailFileLoop seam, verifies the signature against a trust bundle
// sourced from the environment (the way the live registry adapter, which passes
// no trust material, is made to verify), and projects a VERIFIED denial
// observation attributed to the emitting agent.
//
// This is not a mock heartbeat: the event is written to a real file on disk and
// read back by the tail loop, exactly as a live nono audit stream arrives.
func TestLiveTailFileProjectsSignedDenialVerifiedViaEnvTrust(t *testing.T) {
	kp, err := GenerateTestKeypair(kusariSPIFFE)
	if err != nil {
		t.Fatalf("generate keypair: %v", err)
	}

	dir := t.TempDir()
	caPath := filepath.Join(dir, "spire-ca.pem")
	if err := os.WriteFile(caPath, []byte(kp.CACertPEM), 0o600); err != nil {
		t.Fatalf("write trust bundle: %v", err)
	}
	logPath := filepath.Join(dir, "nono-session.jsonl")

	baseTime := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)
	ev := newKusariDenialEvent(t, kp, "audit-sess-kusari-tail-001", baseTime)
	line, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal denial event: %v", err)
	}
	if err := os.WriteFile(logPath, append(line, '\n'), 0o600); err != nil {
		t.Fatalf("write session log: %v", err)
	}

	// The trust material reaches the collector ONLY through the environment —
	// the CollectorConfig carries no bundle, mirroring the live adapter.
	t.Setenv(EnvTrustBundlePath, caPath)
	t.Setenv(EnvTrustDomain, DefaultTrustDomain)

	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewCollector("live", sink, CollectorConfig{FilePath: logPath})
	if err := col.Start(ctx); err != nil {
		t.Fatalf("collector Start failed: %v", err)
	}
	defer col.Stop()

	deadline := time.Now().Add(3 * time.Second)
	for atomic.LoadUint64(&sink.count) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := atomic.LoadUint64(&sink.count); got != 1 {
		t.Fatalf("expected exactly 1 observation tailed from the session log, got %d", got)
	}

	sink.mu.Lock()
	obs := sink.observations[0]
	sink.mu.Unlock()

	if obs.Labels["verification_status"] != string(StatusVerified) {
		t.Errorf("tailed denial must verify via env trust bundle: want %s, got %q",
			StatusVerified, obs.Labels["verification_status"])
	}
	if obs.Source != "agent-nono-kusari" {
		t.Errorf("Source: want agent-nono-kusari, got %q", obs.Source)
	}
	if obs.Labels["denial_reason"] != "landlock_fs_read_denied" {
		t.Errorf("denial_reason: want landlock_fs_read_denied, got %q", obs.Labels["denial_reason"])
	}
	if obs.Labels["path"] != "/etc/shadow" {
		t.Errorf("path: want /etc/shadow, got %q", obs.Labels["path"])
	}
	if obs.Labels["syscall"] != "openat" {
		t.Errorf("syscall: want openat, got %q", obs.Labels["syscall"])
	}
}
