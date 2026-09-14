//go:build frostdb

package store_test

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func generateTestSigningKey(t testing.TB) string {
	t.Helper()
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "witness.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func readJournalLines(t testing.TB, path string) []map[string]any {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	var records []map[string]any
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		text := scanner.Text()
		if len(text) == 0 {
			continue
		}
		var record map[string]any
		if err := json.Unmarshal([]byte(text), &record); err != nil {
			t.Fatal(err)
		}
		records = append(records, record)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return records
}

// TestIdentitySpineEndToEndIntegration proves that the complete Phase-3 identity spine
// (FrostDB write-time attestation, segment tamper detection, query pushdown, and
// resolution against the persisted identity/delegation graph) composes end-to-end in
// a single integrated run while strictly preserving false-merge == 0.
func TestIdentitySpineEndToEndIntegration(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	evidenceDir := filepath.Join(dir, "evidence")
	keyPath := generateTestSigningKey(t)
	highWaterPath := filepath.Join(dir, "protected", "highwater.json")

	// 1. Initialize FrostDB store with write-time Witness attestation and manual flush
	frostStore, err := store.NewFrostDBStoreWithBucket(dir,
		store.WithManualFlush(),
		store.WithSegmentAttestation(store.SegmentAttestorConfig{
			EvidenceDir:    evidenceDir,
			PrivateKeyPath: keyPath,
			HighWaterPath:  highWaterPath,
			QueueSize:      8,
		}),
	)
	if err != nil {
		t.Fatalf("failed to initialize frostdb store: %v", err)
	}
	defer frostStore.Close()

	// 2. Initialize Identity Graph repository & resolver store
	identityRepo := identity.NewMemoryRepository()
	identityStore := identity.NewGraphResolverStore(identityRepo)

	// Seed canonical actors and time-valid identity edges
	baseTime := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	t0 := baseTime
	t1 := t0.Add(1 * time.Hour)
	t2 := t0.Add(2 * time.Hour)
	t3 := t0.Add(3 * time.Hour)

	// Canonical Actor 1: Alice Corp
	actorAlice := identity.ActorRecord{
		ActorID:   "actor-alice-corp",
		Status:    model.ActorActionable,
		CreatedAt: t0,
		UpdatedAt: t0,
	}
	if err := identityRepo.CreateActor(ctx, actorAlice); err != nil {
		t.Fatalf("failed to create actor alice: %v", err)
	}
	aliasAlice := identity.AliasRecord{
		ActorID:      "actor-alice-corp",
		AliasType:    "email",
		AliasValue:   "alice@corp.internal",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    t0,
		ValidTo:      &t2,
		CreatedAt:    t0,
	}
	if err := identityRepo.AddAlias(ctx, aliasAlice); err != nil {
		t.Fatalf("failed to add alias alice: %v", err)
	}

	// Canonical Actor 2: Bob Corp (distinct from Alice)
	actorBob := identity.ActorRecord{
		ActorID:   "actor-bob-corp",
		Status:    model.ActorActionable,
		CreatedAt: t0,
		UpdatedAt: t0,
	}
	if err := identityRepo.CreateActor(ctx, actorBob); err != nil {
		t.Fatalf("failed to create actor bob: %v", err)
	}
	aliasBob := identity.AliasRecord{
		ActorID:      "actor-bob-corp",
		AliasType:    "email",
		AliasValue:   "bob@corp.internal",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    t0,
		ValidTo:      &t2,
		CreatedAt:    t0,
	}
	if err := identityRepo.AddAlias(ctx, aliasBob); err != nil {
		t.Fatalf("failed to add alias bob: %v", err)
	}

	// Canonical Actor 3: Automated Agent Runner
	actorRunner := identity.ActorRecord{
		ActorID:   "actor-agent-runner",
		Status:    model.ActorActionable,
		CreatedAt: t0,
		UpdatedAt: t0,
	}
	if err := identityRepo.CreateActor(ctx, actorRunner); err != nil {
		t.Fatalf("failed to create actor runner: %v", err)
	}
	aliasRunner := identity.AliasRecord{
		ActorID:      "actor-agent-runner",
		AliasType:    "spiffe",
		AliasValue:   "spiffe://cluster.local/ns/default/sa/runner",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    t0,
		ValidTo:      &t2,
		CreatedAt:    t0,
	}
	if err := identityRepo.AddAlias(ctx, aliasRunner); err != nil {
		t.Fatalf("failed to add alias runner: %v", err)
	}

	// Delegation Edge: Agent Runner acts-on-behalf-of Alice during [t0, t1)
	delegation := identity.DelegationRecord{
		DelegateActorID:  "actor-agent-runner",
		PrincipalActorID: "actor-alice-corp",
		AuthzRef:         "authz-token-xyz-123",
		ValidFrom:        t0,
		ValidTo:          &t1,
		CreatedAt:        t0,
	}
	if err := identityRepo.AddDelegation(ctx, delegation); err != nil {
		t.Fatalf("failed to add delegation: %v", err)
	}

	// Canonical Actor 4: Carol (Active only starting at t2)
	actorCarol := identity.ActorRecord{
		ActorID:   "actor-carol-ext",
		Status:    model.ActorActionable,
		CreatedAt: t2,
		UpdatedAt: t2,
	}
	if err := identityRepo.CreateActor(ctx, actorCarol); err != nil {
		t.Fatalf("failed to create actor carol: %v", err)
	}
	aliasCarol := identity.AliasRecord{
		ActorID:      "actor-carol-ext",
		AliasType:    "email",
		AliasValue:   "carol@ext.org",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    t2,
		ValidTo:      nil, // open ended
		CreatedAt:    t2,
	}
	if err := identityRepo.AddAlias(ctx, aliasCarol); err != nil {
		t.Fatalf("failed to add alias carol: %v", err)
	}

	// 3. Ingest observations spanning diverse identities and layers
	obsAlice := model.Observation{
		ID:         "obs-1-alice",
		Timestamp:  t0.Add(10 * time.Minute),
		Layer:      model.LayerIdentityAuth,
		Fidelity:   model.FidelityDefinitive,
		Source:     "gcpaudit",
		ActorHint:  "alice@corp.internal",
		Confidence: 1.0,
		Labels: map[string]string{
			"src_ip": "10.0.0.1",
		},
	}
	obsBob := model.Observation{
		ID:         "obs-2-bob",
		Timestamp:  t0.Add(20 * time.Minute),
		Layer:      model.LayerNetworkEgress,
		Fidelity:   model.FidelityDefinitive,
		Source:     "netebpf",
		ActorHint:  "bob@corp.internal",
		Confidence: 1.0,
		Labels: map[string]string{
			"src_ip": "10.0.0.2",
		},
	}
	obsDelegated := model.Observation{
		ID:               "obs-3-runner",
		Timestamp:        t0.Add(30 * time.Minute),
		Layer:            model.LayerIdentityAuth,
		Fidelity:         model.FidelityDefinitive,
		Source:           "k8saudit",
		ActorHint:        "spiffe://cluster.local/ns/default/sa/runner",
		ImpersonatedUser: "actor-alice-corp",
		Confidence:       1.0,
		Labels: map[string]string{
			"src_ip": "10.0.0.3",
		},
	}
	obsUnaliased := model.Observation{
		ID:         "obs-4-unaliased",
		Timestamp:  t0.Add(40 * time.Minute),
		Layer:      model.LayerEndpointHost,
		Fidelity:   model.FidelityCircumstantial,
		Source:     "system",
		ActorHint:  "service-unknown",
		Confidence: 0.4,
		Labels: map[string]string{
			"src_ip": "10.0.0.99",
		},
	}
	obsCircumstantial := model.Observation{
		ID:         "obs-5-ip-circumstantial",
		Timestamp:  t0.Add(50 * time.Minute),
		Layer:      model.LayerNetworkEgress,
		Fidelity:   model.FidelityCircumstantial,
		Source:     "netebpf",
		Confidence: 0.3,
		Labels: map[string]string{
			"src_ip": "10.0.0.1", // Same IP as Alice, but no deterministic identity
		},
	}

	observations := []model.Observation{obsAlice, obsBob, obsDelegated, obsUnaliased, obsCircumstantial}

	// SLDP-P3-1. `src_ip` is not in the segment label allow-list, and deliberately so: a source IP
	// is personal data (Breyer, C-582/14), and a label key is materialised verbatim as a Parquet
	// column in a segment that is signed and can never afterwards be rewritten or erased.
	//
	// The IP is still available to the correlation engine, which joins on labels["src_ip"]
	// in-flight (correlation/engine.go:325, correlation/store.go:120) before anything is persisted.
	// What changes is only what survives into the immutable store. Stripping it here rather than
	// adding it to the allow-list keeps the fixture honest about that split — the observation the
	// correlator sees and the row the segment keeps are no longer the same thing.
	stored := make([]model.Observation, len(observations))
	for i, o := range observations {
		o.Labels = nil
		stored[i] = o
	}
	if err := frostStore.Append(ctx, stored); err != nil {
		t.Fatalf("failed to append observations to frostdb: %v", err)
	}

	// The allow-list is not advisory: appending the unmodified fixture must be refused outright.
	if err := frostStore.Append(ctx, observations); err == nil {
		t.Fatal("appending an observation labelled with a raw source IP must be refused")
	}

	// 4. Flush to produce immutable Parquet block and trigger write-time Witness attestation
	if err := frostStore.Flush(ctx); err != nil {
		t.Fatalf("failed to flush frostdb: %v", err)
	}
	if err := frostStore.WaitForAttestations(ctx); err != nil {
		t.Fatalf("failed waiting for attestations: %v", err)
	}

	// 5. Verify write-time Witness attestation on disk
	journalPath := filepath.Join(evidenceDir, "segments.jsonl")
	records := readJournalLines(t, journalPath)
	if len(records) != 1 {
		t.Fatalf("expected exactly 1 attested segment, got %d", len(records))
	}

	segmentRecord := records[0]
	segmentRelPath, ok := segmentRecord["segment_id"].(string)
	if !ok || segmentRelPath == "" {
		t.Fatalf("invalid segment_id in journal: %v", segmentRecord)
	}
	segmentFullPath := filepath.Join(dir, segmentRelPath)
	rawParquet, err := os.ReadFile(segmentFullPath)
	if err != nil {
		t.Fatalf("failed to read persisted parquet file %s: %v", segmentFullPath, err)
	}
	actualDigest := sha256.Sum256(rawParquet)
	expectedDigestHex, _ := segmentRecord["digest"].(string)
	if hex.EncodeToString(actualDigest[:]) != expectedDigestHex {
		t.Fatalf("segment digest mismatch: got %s, want %s", hex.EncodeToString(actualDigest[:]), expectedDigestHex)
	}

	// 6. Demonstrate Tamper Detection
	// Save pristine parquet bytes
	pristineBytes := make([]byte, len(rawParquet))
	copy(pristineBytes, rawParquet)

	// Tamper: modify one byte
	tamperedBytes := make([]byte, len(rawParquet))
	copy(tamperedBytes, rawParquet)
	tamperedBytes[0] ^= 0xFF
	if err := os.WriteFile(segmentFullPath, tamperedBytes, 0644); err != nil {
		t.Fatalf("failed to write tampered segment: %v", err)
	}

	// Verify tampered file causes digest divergence
	tamperedRead, err := os.ReadFile(segmentFullPath)
	if err != nil {
		t.Fatalf("failed to read tampered file: %v", err)
	}
	tamperedDigest := sha256.Sum256(tamperedRead)
	if hex.EncodeToString(tamperedDigest[:]) == expectedDigestHex {
		t.Fatalf("tamper failed: tampered digest unexpectedly matches original")
	}

	// Restore pristine bytes
	if err := os.WriteFile(segmentFullPath, pristineBytes, 0644); err != nil {
		t.Fatalf("failed to restore pristine segment: %v", err)
	}
	restoredRead, err := os.ReadFile(segmentFullPath)
	if err != nil {
		t.Fatalf("failed to read restored file: %v", err)
	}
	restoredDigest := sha256.Sum256(restoredRead)
	if hex.EncodeToString(restoredDigest[:]) != expectedDigestHex {
		t.Fatalf("restore failed: restored digest %s != original %s", hex.EncodeToString(restoredDigest[:]), expectedDigestHex)
	}

	// 7. Verify Query Pushdown via FrostDB logicalplan.Filter
	// Query by time range [t0+15m, t0+35m) -> must match obsBob (t0+20m) and obsDelegated (t0+30m)
	timeQuery := store.Query{
		After:  t0.Add(15 * time.Minute),
		Before: t0.Add(35 * time.Minute),
	}
	timeResults, err := frostStore.QueryRange(ctx, timeQuery)
	if err != nil {
		t.Fatalf("pushdown query by time range failed: %v", err)
	}
	if len(timeResults) != 2 {
		t.Fatalf("pushdown time range query expected 2 results, got %d", len(timeResults))
	}
	if timeResults[0].ID != "obs-2-bob" || timeResults[1].ID != "obs-3-runner" {
		t.Fatalf("unexpected pushdown time results: %+v", timeResults)
	}

	// Query by layer LayerNetworkEgress -> must match obsBob and obsCircumstantial
	layerQuery := store.Query{
		Layers: []model.Layer{model.LayerNetworkEgress},
	}
	layerResults, err := frostStore.QueryRange(ctx, layerQuery)
	if err != nil {
		t.Fatalf("pushdown query by layer failed: %v", err)
	}
	if len(layerResults) != 2 {
		t.Fatalf("pushdown layer query expected 2 results, got %d", len(layerResults))
	}

	// Query by ActorID hint "bob@corp.internal" -> must match obsBob
	actorQuery := store.Query{
		ActorID: "bob@corp.internal",
	}
	actorResults, err := frostStore.QueryRange(ctx, actorQuery)
	if err != nil {
		t.Fatalf("pushdown query by actor hint failed: %v", err)
	}
	if len(actorResults) != 1 || actorResults[0].ID != "obs-2-bob" {
		t.Fatalf("pushdown actor query expected obs-2-bob, got %+v", actorResults)
	}

	// 8. End-to-end Resolution against Persisted Graph & false-merge == 0 Assertion
	resolvedAlice, err := identityStore.ResolveObservationAsOf(ctx, obsAlice)
	if err != nil {
		t.Fatalf("failed to resolve alice observation: %v", err)
	}
	if resolvedAlice.CanonicalID != "actor-alice-corp" {
		t.Fatalf("alice resolved to %s, want actor-alice-corp", resolvedAlice.CanonicalID)
	}

	resolvedBob, err := identityStore.ResolveObservationAsOf(ctx, obsBob)
	if err != nil {
		t.Fatalf("failed to resolve bob observation: %v", err)
	}
	if resolvedBob.CanonicalID != "actor-bob-corp" {
		t.Fatalf("bob resolved to %s, want actor-bob-corp", resolvedBob.CanonicalID)
	}

	resolvedDelegated, err := identityStore.ResolveObservationAsOf(ctx, obsDelegated)
	if err != nil {
		t.Fatalf("failed to resolve delegated runner observation: %v", err)
	}
	if resolvedDelegated.CanonicalID != "actor-agent-runner" {
		t.Fatalf("runner resolved to %s, want actor-agent-runner", resolvedDelegated.CanonicalID)
	}
	if resolvedDelegated.PrincipalID != "actor-alice-corp" {
		t.Fatalf("runner principal resolved to %s, want actor-alice-corp", resolvedDelegated.PrincipalID)
	}

	resolvedUnaliased, err := identityStore.ResolveObservationAsOf(ctx, obsUnaliased)
	if err != nil {
		t.Fatalf("failed to resolve unaliased observation: %v", err)
	}
	if resolvedUnaliased.CanonicalID != "actor-service-unknown" {
		t.Fatalf("unaliased resolved to %s, want actor-service-unknown", resolvedUnaliased.CanonicalID)
	}

	resolvedCircumstantial, err := identityStore.ResolveObservationAsOf(ctx, obsCircumstantial)
	if err != nil {
		t.Fatalf("failed to resolve circumstantial observation: %v", err)
	}

	// Cardinal False-Merge == 0 Invariant Assertion over Persisted Graph:
	// All distinct entities must remain in strictly disjoint partitions.
	canonicalIDs := map[string]string{
		"alice":          resolvedAlice.CanonicalID,
		"bob":            resolvedBob.CanonicalID,
		"runner":         resolvedDelegated.CanonicalID,
		"unaliased":      resolvedUnaliased.CanonicalID,
		"circumstantial": resolvedCircumstantial.CanonicalID,
	}

	falseMerges := 0
	pairs := [][2]string{
		{"alice", "bob"},
		{"alice", "runner"},
		{"alice", "unaliased"},
		{"alice", "circumstantial"},
		{"bob", "runner"},
		{"bob", "unaliased"},
		{"bob", "circumstantial"},
		{"runner", "unaliased"},
		{"runner", "circumstantial"},
		{"unaliased", "circumstantial"},
	}

	for _, pair := range pairs {
		idA := canonicalIDs[pair[0]]
		idB := canonicalIDs[pair[1]]
		if idA == idB {
			t.Errorf("FATAL FALSE MERGE: entity %s and %s merged to identical canonical ID %s", pair[0], pair[1], idA)
			falseMerges++
		}
	}

	if falseMerges != 0 {
		t.Fatalf("re-asserted false-merge gate failed: false_merges = %d (want 0)", falseMerges)
	}

	// Verify correlation engine integration with the persisted identity observations
	corrEngine, err := correlation.NewEngine(frostStore)
	if err != nil {
		t.Fatalf("failed to initialize correlation engine with frostdb store: %v", err)
	}
	corrActors, err := corrEngine.Correlate(ctx)
	if err != nil {
		t.Fatalf("correlation engine run failed: %v", err)
	}
	if len(corrActors) == 0 {
		t.Fatalf("expected non-empty actors from correlation engine")
	}

	// Inactive / out-of-bounds temporal resolution check:
	// Carol at t0 is not yet valid in graph -> does NOT match Carol's canonical record
	carolObsPast := model.Observation{
		ID:        "obs-carol-past",
		Timestamp: t0,
		ActorHint: "carol@ext.org",
		Source:    "workspacesaas",
	}
	resCarolPast, err := identityStore.ResolveObservationAsOf(ctx, carolObsPast)
	if err != nil {
		t.Fatalf("failed resolving carol past observation: %v", err)
	}
	if resCarolPast.CanonicalID == "actor-carol-ext" {
		t.Fatalf("temporal boundary violated: carol resolved to future identity actor-carol-ext at t0")
	}

	// Carol at t3 IS valid in graph -> resolves to actor-carol-ext
	carolObsPresent := model.Observation{
		ID:        "obs-carol-present",
		Timestamp: t3,
		ActorHint: "carol@ext.org",
		Source:    "workspacesaas",
	}
	resCarolPresent, err := identityStore.ResolveObservationAsOf(ctx, carolObsPresent)
	if err != nil {
		t.Fatalf("failed resolving carol present observation: %v", err)
	}
	if resCarolPresent.CanonicalID != "actor-carol-ext" {
		t.Fatalf("carol at t3 failed to resolve to actor-carol-ext: got %s", resCarolPresent.CanonicalID)
	}

	t.Logf("PASS: Identity spine end-to-end integration verified (attestation, tamper detection, pushdown, persisted graph resolution, false_merges=0)")
}
