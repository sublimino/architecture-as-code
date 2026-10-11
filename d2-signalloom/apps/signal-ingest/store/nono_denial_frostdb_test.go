// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/agentnono"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

const kusariSPIFFE = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-kusari"

// nonoDenialLabelKeys are the CEL-visible label keys the agentnono collector
// stamps on a Landlock denial observation (collector.go processEvent). The
// production default allow-list (store/label_allowlist.go) admits only
// "syscall" of these, so a frostdb-tagged store with the default list would
// REFUSE the whole batch. They are listed here, added to a copy of the default
// list for this proof, precisely to document which keys the default is missing:
// closing that gap is a store-owner change outside this lane.
var nonoDenialLabelKeys = []string{
	"event_type", "spiffe_id", "agent_id", "verification_status",
	"hash_chain_digest", "prev_digest", "signature_gitoid",
	"landlock_status", "landlock_abi", "nono_available",
	"delegation_chain_id", "syscall", "path", "denial_reason",
}

// signKusariDenial fills the hash-chain digest and detached SVID signature over
// the event's canonical payload, exactly as the agent-side evidence signer does.
// It must run after every canonical field is set.
func signKusariDenial(t *testing.T, kp *agentnono.FixtureKeypair, ev *agentnono.NonoAuditEvent) {
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
		t.Fatalf("sign kusari denial: %v", err)
	}
	ev.Signature = sig
	ev.SignatureGitOID = agentnono.ComputeGitOID(payload)
}

// TestNonoDenialPersistsToFrostDBEndToEnd is the headline proof that real nono
// output lands in the signals store, correctly attributed and CEL-visible.
//
// It constructs a signed Landlock DENIAL (openat /etc/shadow refused) and runs
// it through the ACTUAL pipeline a deployed signal-ingest uses:
//
//	agentnono.Collector (live, verifying) -> collectors.StoreSink -> FrostDBStore
//
// then QueryRanges the store back and asserts the stored row carries the denial
// evidence intact. The assertions read the values OUT OF THE STORE (not the
// input echo), so a label dropped on the way in, or a mis-derived source, fails.
func TestNonoDenialPersistsToFrostDBEndToEnd(t *testing.T) {
	// Extend the production default allow-list with the nono denial keys so the
	// immutable-segment store admits the denial evidence. See nonoDenialLabelKeys.
	allow := store.DefaultLabelAllowList()
	for _, k := range nonoDenialLabelKeys {
		allow[k] = struct{}{}
	}

	s, err := store.NewFrostDBStore(store.WithLabelAllowList(allow))
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	kp, err := agentnono.GenerateTestKeypair(kusariSPIFFE)
	if err != nil {
		t.Fatalf("generate keypair: %v", err)
	}

	baseTime := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)
	ev := &agentnono.NonoAuditEvent{
		Timestamp:               baseTime,
		AgentID:                 "agent-nono-kusari",
		Name:                    "Kusari Agent (Nono Enforced)",
		Profile:                 "nono-kusari-enforced",
		SPIFFEID:                kp.SPIFFEID,
		Status:                  "healthy",
		LifecycleState:          "active",
		HeartbeatSeq:            1,
		NonoCapabilityAvailable: true,
		AuditSessionID:          "audit-sess-kusari-store-001",
		SessionID:               "audit-sess-kusari-store-001",
		Seq:                     1,
		EventType:               "landlock_filesystem_containment",
		Event:                   "landlock_filesystem_containment",
		Landlock: agentnono.LandlockStatus{
			Available:          true,
			Status:             "active",
			ABIVersion:         3,
			Enforced:           true,
			FilesystemEnforced: true,
			Restrictions:       []string{"/etc/shadow:deny"},
		},
		Syscall:           "openat",
		Path:              "/etc/shadow",
		DenialReason:      "landlock_fs_read_denied",
		Certificate:       kp.WorkloadPEM,
		DelegationChainID: "chain-del-kusari-001",
	}
	signKusariDenial(t, kp, ev)

	sink := collectors.NewStoreSink(s)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := agentnono.NewCollector("live", sink, agentnono.CollectorConfig{
		TrustDomain:    agentnono.DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})
	if err := col.Start(ctx); err != nil {
		t.Fatalf("collector Start: %v", err)
	}
	defer col.Stop()

	data, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal denial event: %v", err)
	}
	if err := col.IngestRawLine(ctx, data); err != nil {
		t.Fatalf("IngestRawLine: %v", err)
	}

	q := store.Query{
		Layers: []model.Layer{model.LayerEndpointHost},
		After:  baseTime.Add(-time.Hour),
		Before: baseTime.Add(time.Hour),
		Limit:  16,
	}

	var rows []model.Observation
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		rows, err = s.QueryRange(ctx, q)
		if err != nil {
			t.Fatalf("QueryRange: %v", err)
		}
		if len(rows) >= 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	if len(rows) != 1 {
		t.Fatalf("expected exactly 1 endpoint_host observation persisted, got %d", len(rows))
	}
	got := rows[0]

	// Attribution: Source is derived from the emitting agent (R8), read back out
	// of the store's own `source` column.
	if got.Source != "agent-nono-kusari" {
		t.Errorf("stored Source: want agent-nono-kusari, got %q", got.Source)
	}
	// CEL-visible denial evidence, read back out of the stored labels.* columns.
	if got.Labels["denial_reason"] != "landlock_fs_read_denied" {
		t.Errorf("stored denial_reason: want landlock_fs_read_denied, got %q", got.Labels["denial_reason"])
	}
	if got.Labels["path"] != "/etc/shadow" {
		t.Errorf("stored path: want /etc/shadow, got %q", got.Labels["path"])
	}
	if got.Labels["syscall"] != "openat" {
		t.Errorf("stored syscall: want openat, got %q", got.Labels["syscall"])
	}
	if got.Labels["verification_status"] != string(agentnono.StatusVerified) {
		t.Errorf("stored verification_status: want %s, got %q",
			agentnono.StatusVerified, got.Labels["verification_status"])
	}
	if got.Labels["agent_id"] != "agent-nono-kusari" {
		t.Errorf("stored agent_id: want agent-nono-kusari, got %q", got.Labels["agent_id"])
	}
	if got.Layer != model.LayerEndpointHost {
		t.Errorf("stored layer: want %s, got %q", model.LayerEndpointHost, got.Layer)
	}
}
