package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/thanos-io/objstore"
)

func testSigningKey(t testing.TB) string {
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

func TestDSSESignerProducesVerifiableCanonicalEnvelope(t *testing.T) {
	signer, err := newEd25519Signer(testSigningKey(t))
	if err != nil {
		t.Fatal(err)
	}
	statement := map[string]any{"z": "last", "a": "first"}
	envelope, err := signer.sign(statement)
	if err != nil {
		t.Fatal(err)
	}
	var decoded dsseEnvelope
	if err := json.Unmarshal(envelope, &decoded); err != nil {
		t.Fatal(err)
	}
	payload, err := base64.StdEncoding.DecodeString(decoded.Payload)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(payload), `{"a":"first","z":"last"}`; got != want {
		t.Fatalf("payload = %s, want %s", got, want)
	}
	signature, err := base64.StdEncoding.DecodeString(decoded.Signatures[0].Sig)
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(signer.publicKey, dssePAE(decoded.PayloadType, payload), signature) {
		t.Fatal("DSSE signature did not verify")
	}
	spki, _ := x509.MarshalPKIXPublicKey(signer.publicKey)
	wantID := sha256.Sum256(spki)
	if decoded.Signatures[0].KeyID != strings.ToLower(strings.TrimSpace(hexDigest(wantID[:]))) {
		t.Fatalf("unexpected key id %q", decoded.Signatures[0].KeyID)
	}
}

func TestAttestingBucketHashesExactBytesAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	a, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir: dir, PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: 4,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	bucket := newAttestingBucket(objstore.NewInMemBucket(), a)
	name := "signaldb/observations/01/data.parquet"
	payload := []byte("PAR1\x00exact bytes\xff")
	for range 2 {
		if err := bucket.Upload(context.Background(), name, bytes.NewReader(payload)); err != nil {
			t.Fatal(err)
		}
	}
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	lines := readJSONLines(t, filepath.Join(dir, "segments.jsonl"))
	if len(lines) != 1 {
		t.Fatalf("journal records = %d, want 1", len(lines))
	}
	wantDigest := sha256.Sum256(payload)
	if lines[0]["digest"] != hexDigest(wantDigest[:]) || lines[0]["byte_length"] != float64(len(payload)) {
		t.Fatalf("journal does not describe exact upload: %#v", lines[0])
	}
	if lines[0]["state"] != "ok" || lines[0]["checkpoint_inclusion"] == nil {
		t.Fatalf("journal record is not checkpointed ok: %#v", lines[0])
	}
}

func TestStartupRejectsRollbackBelowProtectedHighwater(t *testing.T) {
	dir := t.TempDir()
	highwater := filepath.Join(dir, "protected", "highwater.json")
	key := testSigningKey(t)
	a, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir: dir, PrivateKeyPath: key, HighWaterPath: highwater, QueueSize: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	a.enqueue(segmentUpload{name: "signaldb/observations/historical-rotation-01HZZ/data.parquet", digest: strings.Repeat("a", 64), size: 7})
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(dir, "segments.jsonl")
	raw, err := os.ReadFile(journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(journal, raw[:0], 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir: dir, PrivateKeyPath: key, HighWaterPath: highwater, QueueSize: 2,
	}); err == nil || !strings.Contains(err.Error(), "below protected highwater") {
		t.Fatalf("restart rollback error = %v", err)
	}
}

func TestStartupRejectsProtectedCheckpointInventoryRollback(t *testing.T) {
	dir := t.TempDir()
	cfg := SegmentAttestorConfig{
		EvidenceDir: dir, PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: 2,
	}
	a, err := NewSegmentAttestor(cfg)
	if err != nil {
		t.Fatal(err)
	}
	a.enqueue(segmentUpload{name: "signaldb/observations/rotation/data.parquet", digest: strings.Repeat("a", 64), size: 1})
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	checkpoints, err := filepath.Glob(filepath.Join(dir, "checkpoints", "*.dsse.json"))
	if err != nil || len(checkpoints) != 1 {
		t.Fatalf("checkpoints = %v, %v", checkpoints, err)
	}
	if err := os.Remove(checkpoints[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := NewSegmentAttestor(cfg); err == nil || !strings.Contains(err.Error(), "checkpoint inventory is below protected highwater") {
		t.Fatalf("checkpoint rollback error = %v", err)
	}
}

func TestStartupRejectsProtectedSegmentTipMutation(t *testing.T) {
	dir := t.TempDir()
	cfg := SegmentAttestorConfig{
		EvidenceDir: dir, PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: 2,
	}
	a, err := NewSegmentAttestor(cfg)
	if err != nil {
		t.Fatal(err)
	}
	a.enqueue(segmentUpload{name: "signaldb/observations/rotation/data.parquet", digest: strings.Repeat("a", 64), size: 1})
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(dir, "segments.jsonl")
	records := readJSONLines(t, journal)
	records[0]["digest"] = strings.Repeat("b", 64)
	raw, err := json.Marshal(records[0])
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(journal, append(raw, '\n'), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := NewSegmentAttestor(cfg); err == nil || !strings.Contains(err.Error(), "segment tip differs from protected highwater") {
		t.Fatalf("tip mutation error = %v", err)
	}
}

func TestStartupSequenceIgnoresHistoricalRotationIdentifiers(t *testing.T) {
	dir := t.TempDir()
	cfg := SegmentAttestorConfig{
		EvidenceDir: dir, PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: 2,
	}
	a, err := NewSegmentAttestor(cfg)
	if err != nil {
		t.Fatal(err)
	}
	a.enqueue(segmentUpload{name: "signaldb/observations/99999999999999999999/data.parquet", digest: strings.Repeat("a", 64), size: 1})
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	a, err = NewSegmentAttestor(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	a.enqueue(segmentUpload{name: "signaldb/observations/00000000000000000000/data.parquet", digest: strings.Repeat("b", 64), size: 1})
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	records := readJSONLines(t, filepath.Join(dir, "segments.jsonl"))
	if got := records[1]["sequence"]; got != float64(2) {
		t.Fatalf("sequence = %v, want 2", got)
	}
}

func TestConcurrentEnqueueAndWaitDuringCloseDoesNotPanic(t *testing.T) {
	dir := t.TempDir()
	a, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir: dir, PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: 4,
	})
	if err != nil {
		t.Fatal(err)
	}
	var callers sync.WaitGroup
	for worker := 0; worker < 8; worker++ {
		callers.Add(1)
		go func(worker int) {
			defer callers.Done()
			for i := 0; i < 100; i++ {
				a.enqueue(segmentUpload{name: fmt.Sprintf("signaldb/observations/%d-%d/data.parquet", worker, i), digest: strings.Repeat("a", 64), size: 1})
				ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond)
				_ = a.Wait(ctx)
				cancel()
			}
		}(worker)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	callers.Wait()
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestGenesisCapturesHistoricalSegmentsBeforeUploads(t *testing.T) {
	root := t.TempDir()
	evidence := filepath.Join(t.TempDir(), "evidence")
	highwater := filepath.Join(t.TempDir(), "protected", "highwater.json")
	historical := filepath.Join(root, "signaldb", "observations", "old-rotation", "data.parquet")
	if err := os.MkdirAll(filepath.Dir(historical), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(historical, []byte("historical"), 0o640); err != nil {
		t.Fatal(err)
	}
	a, err := NewSegmentAttestor(SegmentAttestorConfig{
		SegmentRoot: root, EvidenceDir: evidence, PrivateKeyPath: testSigningKey(t), HighWaterPath: highwater, QueueSize: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	high := readProtectedHighWater(t, highwater)
	if got, want := high.HistoricalSegments, []string{"signaldb/observations/old-rotation/data.parquet"}; !slices.Equal(got, want) {
		t.Fatalf("historical segments = %v, want %v", got, want)
	}
	if high.MaxSequence != 0 || high.JournalSize != 0 || high.LastSegmentID != "" || high.LastDigest != "" {
		t.Fatalf("genesis highwater is not empty: %+v", high)
	}
	a.enqueue(segmentUpload{name: "signaldb/observations/new-rotation/data.parquet", digest: strings.Repeat("a", 64), size: 1})
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	high = readProtectedHighWater(t, highwater)
	if !slices.Equal(high.HistoricalSegments, []string{"signaldb/observations/old-rotation/data.parquet"}) {
		t.Fatalf("historical baseline changed after upload: %v", high.HistoricalSegments)
	}
}

func TestRestartRejectsUnknownParquetOutsideGenesisAndJournal(t *testing.T) {
	root := t.TempDir()
	cfg := SegmentAttestorConfig{
		SegmentRoot: root, EvidenceDir: filepath.Join(t.TempDir(), "evidence"),
		PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(t.TempDir(), "protected", "highwater.json"), QueueSize: 2,
	}
	a, err := NewSegmentAttestor(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	unknown := filepath.Join(root, "signaldb", "observations", "unacknowledged", "data.parquet")
	if err := os.MkdirAll(filepath.Dir(unknown), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(unknown, []byte("unknown"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := NewSegmentAttestor(cfg); err == nil || !strings.Contains(err.Error(), "inventory differs") {
		t.Fatalf("unknown persisted segment error = %v", err)
	}
}

func TestSegmentInventoryFailsClosedOnFilesystemErrors(t *testing.T) {
	root := t.TempDir()
	scope := filepath.Join(root, "signaldb", "observations")
	block := filepath.Join(scope, "block")
	if err := os.MkdirAll(block, 0o750); err != nil {
		t.Fatal(err)
	}
	original := segmentReadDir
	t.Cleanup(func() { segmentReadDir = original })
	for _, denied := range []string{scope, block} {
		segmentReadDir = func(path string) ([]os.DirEntry, error) {
			if path == denied {
				return nil, os.ErrPermission
			}
			return original(path)
		}
		if _, err := segmentInventory(root); !errors.Is(err, os.ErrPermission) {
			t.Fatalf("inventory error for %s = %v", denied, err)
		}
	}
}

func TestSegmentInventoryRejectsMalformedAndSymlinkEntries(t *testing.T) {
	for name, setup := range map[string]func(string) error{
		"non-directory block": func(scope string) error {
			return os.WriteFile(filepath.Join(scope, "not-a-block"), []byte("bad"), 0o640)
		},
		"symlink block": func(scope string) error {
			target := filepath.Join(t.TempDir(), "target")
			if err := os.Mkdir(target, 0o750); err != nil {
				return err
			}
			return os.Symlink(target, filepath.Join(scope, "linked-block"))
		},
		"symlink parquet": func(scope string) error {
			block := filepath.Join(scope, "block")
			if err := os.Mkdir(block, 0o750); err != nil {
				return err
			}
			target := filepath.Join(t.TempDir(), "target.parquet")
			if err := os.WriteFile(target, []byte("PAR1"), 0o640); err != nil {
				return err
			}
			return os.Symlink(target, filepath.Join(block, "data.parquet"))
		},
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			scope := filepath.Join(root, "signaldb", "observations")
			if err := os.MkdirAll(scope, 0o750); err != nil {
				t.Fatal(err)
			}
			if err := setup(scope); err != nil {
				t.Fatal(err)
			}
			if _, err := segmentInventory(root); err == nil || !strings.Contains(err.Error(), "not a regular") {
				t.Fatalf("malformed inventory error = %v", err)
			}
		})
	}
}

func TestSegmentEvidenceInspectionPropagatesReadFailure(t *testing.T) {
	root := t.TempDir()
	original := segmentReadDir
	segmentReadDir = func(path string) ([]os.DirEntry, error) {
		if path == filepath.Join(root, "attestations") {
			return nil, os.ErrPermission
		}
		return original(path)
	}
	t.Cleanup(func() { segmentReadDir = original })
	if _, err := hasSegmentEvidence(root); !errors.Is(err, os.ErrPermission) {
		t.Fatalf("evidence inspection error = %v", err)
	}
}

func TestGenesisRejectsAttestorEvidenceWithoutProtectedState(t *testing.T) {
	for name, relative := range map[string]string{
		"journal":     "segments.jsonl",
		"errors":      "segments.errors.jsonl",
		"attestation": "attestations/00000000000000000001.dsse.json",
		"checkpoint":  "checkpoints/00000000-deadbeef.dsse.json",
	} {
		t.Run(name, func(t *testing.T) {
			evidence := t.TempDir()
			path := filepath.Join(evidence, relative)
			if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte("forged\n"), 0o640); err != nil {
				t.Fatal(err)
			}
			if _, err := NewSegmentAttestor(SegmentAttestorConfig{
				SegmentRoot: t.TempDir(), EvidenceDir: evidence, PrivateKeyPath: testSigningKey(t),
				HighWaterPath: filepath.Join(t.TempDir(), "protected", "highwater.json"), QueueSize: 2,
			}); err == nil || !strings.Contains(err.Error(), "without protected highwater") {
				t.Fatalf("genesis evidence error = %v", err)
			}
		})
	}
}

func TestHighWaterReplacementRejectsRegressedInventoryAndEqualTipMutation(t *testing.T) {
	dir := t.TempDir()
	cfg := SegmentAttestorConfig{
		SegmentRoot: filepath.Join(dir, "store"), EvidenceDir: filepath.Join(dir, "evidence"),
		PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: 2,
	}
	a, err := NewSegmentAttestor(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	record := segmentRecord{Sequence: 1, SegmentID: "signaldb/observations/rotation/data.parquet", Digest: strings.Repeat("a", 64)}
	a.enqueue(segmentUpload{name: record.SegmentID, digest: record.Digest, size: 1})
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	attestations, err := filepath.Glob(filepath.Join(cfg.EvidenceDir, "attestations", "*.dsse.json"))
	if err != nil || len(attestations) != 1 {
		t.Fatalf("attestations = %v, %v", attestations, err)
	}
	if err := os.Remove(attestations[0]); err != nil {
		t.Fatal(err)
	}
	if err := a.writeHighWater(record); err == nil || !strings.Contains(err.Error(), "attestation count") {
		t.Fatalf("inventory regression error = %v", err)
	}
	if err := os.WriteFile(attestations[0], []byte("restored"), 0o640); err != nil {
		t.Fatal(err)
	}
	record.Digest = strings.Repeat("b", 64)
	if err := a.writeHighWater(record); err == nil || !strings.Contains(err.Error(), "equal-sequence tip") {
		t.Fatalf("equal tip mutation error = %v", err)
	}
}

func TestSecondaryErrorBufferIsBoundedAndLossIsProtected(t *testing.T) {
	dir := t.TempDir()
	a, err := NewSegmentAttestor(SegmentAttestorConfig{
		SegmentRoot: filepath.Join(dir, "store"), EvidenceDir: filepath.Join(dir, "evidence"),
		PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"),
		QueueSize: 1, ErrorQueueSize: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	a.errorsMu.Lock()
	a.reportError("first", segmentUpload{name: "first"}, errors.New("first"))
	deadline := time.Now().Add(time.Second)
	for {
		a.errorMu.Lock()
		pending := len(a.pendingErrors)
		a.errorMu.Unlock()
		if pending == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("error worker did not begin first durable write")
		}
		time.Sleep(time.Millisecond)
	}
	for i := 0; i < 20; i++ {
		a.reportError("overflow", segmentUpload{name: fmt.Sprint(i)}, errors.New("overflow"))
	}
	a.errorMu.Lock()
	pending := len(a.pendingErrors)
	a.errorMu.Unlock()
	if pending != 2 {
		t.Fatalf("secondary pending errors = %d, want fixed capacity 2", pending)
	}
	if got := a.Status().ErrorQueueOverflows; got != 18 {
		t.Fatalf("aggregate lost errors = %d, want 18", got)
	}
	a.errorsMu.Unlock()
	if err := a.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	high := readProtectedHighWater(t, filepath.Join(dir, "protected", "highwater.json"))
	if high.LostErrorCount != 18 {
		t.Fatalf("protected lost error count = %d, want 18", high.LostErrorCount)
	}
}

func readProtectedHighWater(t *testing.T, path string) protectedHighWater {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var high protectedHighWater
	if err := json.Unmarshal(raw, &high); err != nil {
		t.Fatal(err)
	}
	return high
}

func readJSONLines(t *testing.T, path string) []map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var records []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var record map[string]any
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Fatal(err)
		}
		records = append(records, record)
	}
	return records
}
