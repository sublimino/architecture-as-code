//go:build frostdb

package store

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestFrostDBExplicitRotationsAttestRealParquetBytes(t *testing.T) {
	dir := t.TempDir()
	evidence := filepath.Join(dir, "evidence")
	s, err := NewFrostDBStoreWithBucket(dir,
		WithManualFlush(),
		WithSegmentAttestation(SegmentAttestorConfig{
			EvidenceDir: evidence, PrivateKeyPath: testSigningKey(t), HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: 8,
		}),
	)
	if err != nil {
		t.Fatal(err)
	}
	if s.attestor.cfg.SegmentRoot != dir {
		t.Fatal("attestor inventory must be bound to the decorated filesystem bucket")
	}
	for i := 0; i < 3; i++ {
		observation := model.Observation{ID: string(rune('a' + i)), Timestamp: time.Now().UTC(), Layer: model.LayerNetworkEgress, Source: "rotation-test"}
		if err := s.Append(context.Background(), []model.Observation{observation}); err != nil {
			t.Fatal(err)
		}
		if err := s.Flush(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.WaitForAttestations(context.Background()); err != nil {
		t.Fatal(err)
	}
	records := readJSONLines(t, filepath.Join(evidence, "segments.jsonl"))
	if len(records) != 3 {
		t.Fatalf("attestations = %d, want 3", len(records))
	}
	for _, record := range records {
		path := filepath.Join(dir, record["segment_id"].(string))
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(raw)
		if record["digest"] != hexDigest(digest[:]) || record["byte_length"] != float64(len(raw)) {
			t.Fatalf("persisted bytes disagree with journal for %s", path)
		}
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestGoEvidenceAcceptedThenMutationRejectedByPythonVerifier(t *testing.T) {
	proofDir := os.Getenv("SIGNAL_SEGMENT_PROOF_DIR")
	if proofDir == "" {
		proofDir = t.TempDir()
	}
	storeDir := envPath("SIGNAL_SEGMENT_STORE_DIR", filepath.Join(proofDir, "store"))
	evidence := envPath("SIGNAL_SEGMENT_EVIDENCE_DIR", filepath.Join(proofDir, "evidence"))
	highwater := envPath("SIGNAL_SEGMENT_HIGHWATER", filepath.Join(proofDir, "protected", "highwater.json"))
	privateKey := os.Getenv("SIGNAL_SEGMENT_SIGNING_KEY")
	if privateKey == "" {
		privateKey = testSigningKey(t)
	}
	publicKey := os.Getenv("SIGNAL_SEGMENT_PUBLIC_KEY")
	if publicKey == "" {
		publicKey = writeTestPublicKey(t, privateKey)
	}
	signer, err := newEd25519Signer(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(storeDir, 0o750); err != nil {
		t.Fatal(err)
	}
	s, err := NewFrostDBStoreWithBucket(storeDir,
		WithManualFlush(),
		WithSegmentAttestation(SegmentAttestorConfig{
			EvidenceDir: evidence, PrivateKeyPath: privateKey, HighWaterPath: highwater,
			ArchivistaURL: os.Getenv("ARCHIVISTA_URL"), RequireArchivista: os.Getenv("AUDIT_ANCHOR_REQUIRE_LOG") == "1", QueueSize: 2,
		}),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Append(context.Background(), []model.Observation{{ID: "cross-language", Timestamp: time.Now().UTC(), Layer: model.LayerNetworkEgress, Source: "test"}}); err != nil {
		t.Fatal(err)
	}
	if err := s.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := s.WaitForAttestations(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	verify := func() ([]byte, error) {
		args := []string{"-m", "audit_anchor.cli", "--public-key", publicKey, "--expected-key-id", signer.keyID, "--source", "segments", "--segment-journal", filepath.Join(evidence, "segments.jsonl"), "--segment-root", storeDir, "--protected-high-water", highwater}
		if os.Getenv("AUDIT_ANCHOR_REQUIRE_LOG") == "1" {
			args = append(args, "--require-archivista")
		}
		args = append(args, "verify", "--json")
		cmd := exec.Command("python3", args...)
		cmd.Env = append(os.Environ(), "PYTHONPATH="+filepath.Clean("../../fe-signalloom/src"), "AUDIT_ANCHOR_DIR="+filepath.Join(evidence, "checkpoints"))
		return cmd.CombinedOutput()
	}
	output, err := verify()
	if err != nil {
		t.Fatalf("Python rejected Go evidence: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), `"status": "intact"`) || !strings.Contains(string(output), `"unanchored_row_count": 0`) {
		t.Fatalf("Python did not report intact anchored evidence:\n%s", output)
	}
	records := readJSONLines(t, filepath.Join(evidence, "segments.jsonl"))
	segmentPath := filepath.Join(storeDir, records[0]["segment_id"].(string))
	raw, err := os.ReadFile(segmentPath)
	if err != nil {
		t.Fatal(err)
	}
	original := append([]byte(nil), raw...)
	defer func() {
		if err := os.WriteFile(segmentPath, original, 0o640); err != nil {
			t.Errorf("restore Parquet evidence: %v", err)
		}
	}()
	raw[len(raw)/2] ^= 0xff
	if err := os.WriteFile(segmentPath, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	output, err = verify()
	exit, ok := err.(*exec.ExitError)
	if !ok || exit.ExitCode() != 2 {
		t.Fatalf("Python mutation verdict = %v, want exit 2\n%s", err, output)
	}
	if err := os.WriteFile(segmentPath, original, 0o640); err != nil {
		t.Fatal(err)
	}
	output, err = verify()
	if err != nil || !strings.Contains(string(output), `"status": "intact"`) {
		t.Fatalf("Python rejected restored Go evidence: %v\n%s", err, output)
	}
}

func envPath(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func writeTestPublicKey(t *testing.T, privatePath string) string {
	t.Helper()
	raw, err := os.ReadFile(privatePath)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(raw)
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	publicDER, err := x509.MarshalPKIXPublicKey(parsed.(ed25519.PrivateKey).Public())
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "witness-pub.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: publicDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func BenchmarkFrostDBFlushAttestor(b *testing.B) {
	for _, enabled := range []bool{false, true} {
		name := "off"
		if enabled {
			name = "on"
		}
		b.Run(name, func(b *testing.B) {
			dir := b.TempDir()
			options := []FrostDBStoreOption{WithManualFlush()}
			if enabled {
				options = append(options, WithSegmentAttestation(SegmentAttestorConfig{
					EvidenceDir: filepath.Join(dir, "evidence"), PrivateKeyPath: testSigningKey(b),
					HighWaterPath: filepath.Join(dir, "protected", "highwater.json"), QueueSize: max(128, b.N),
				}))
			}
			s, err := NewFrostDBStoreWithBucket(dir, options...)
			if err != nil {
				b.Fatal(err)
			}
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				observation := model.Observation{ID: "benchmark", Timestamp: time.Now().UTC(), Layer: model.LayerNetworkEgress, Source: "benchmark"}
				if err := s.Append(context.Background(), []model.Observation{observation}); err != nil {
					b.Fatal(err)
				}
				if err := s.Flush(context.Background()); err != nil {
					b.Fatal(err)
				}
			}
			b.StopTimer()
			if err := s.WaitForAttestations(context.Background()); err != nil {
				b.Fatal(err)
			}
			if enabled {
				if status := s.attestor.Status(); status.QueueOverflows != 0 || status.ProcessingError != "" {
					b.Fatalf("benchmark did not measure complete attestations: %+v", status)
				}
			}
			if err := s.Close(); err != nil {
				b.Fatal(err)
			}
		})
	}
}
