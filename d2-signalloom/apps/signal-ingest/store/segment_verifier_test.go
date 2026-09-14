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
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	evidenceverify "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store/verify"
)

type verifierFixture struct {
	evidenceDir string
	segmentRoot string
	highWater   string
	publicKeys  []string
	privateKeys []string
}

func verifierKeyPair(t testing.TB, name string) (string, string) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	publicDER, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	privatePath := filepath.Join(dir, name+"-private.pem")
	publicPath := filepath.Join(dir, name+"-public.pem")
	if err := os.WriteFile(privatePath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(publicPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: publicDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	return privatePath, publicPath
}

func newVerifierFixture(t testing.TB, rotate bool) verifierFixture {
	t.Helper()
	root := t.TempDir()
	fixture := verifierFixture{
		evidenceDir: filepath.Join(root, "evidence"),
		segmentRoot: filepath.Join(root, "segments"),
		highWater:   filepath.Join(root, "protected", "highwater.json"),
	}
	privateKey, publicKey := verifierKeyPair(t, "first")
	fixture.publicKeys = append(fixture.publicKeys, publicKey)
	fixture.privateKeys = append(fixture.privateKeys, privateKey)
	writeVerifierSegment(t, fixture, privateKey, "block-1", []byte("first parquet bytes"))
	if rotate {
		privateKey, publicKey = verifierKeyPair(t, "second")
		fixture.publicKeys = append(fixture.publicKeys, publicKey)
		fixture.privateKeys = append(fixture.privateKeys, privateKey)
		writeVerifierSegment(t, fixture, privateKey, "block-2", []byte("second parquet bytes"))
	}
	return fixture
}

func mutateSignedCheckpoint(t testing.TB, fixture verifierFixture, index int, mutate func(map[string]any)) {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(fixture.evidenceDir, "checkpoints", fmt.Sprintf("%08d-*.dsse.json", index)))
	if err != nil || len(paths) != 1 {
		t.Fatalf("checkpoint fixture: %v %v", paths, err)
	}
	var envelope dsseEnvelope
	raw, err := os.ReadFile(paths[0])
	if err != nil || json.Unmarshal(raw, &envelope) != nil {
		t.Fatal("read checkpoint envelope")
	}
	payload, err := base64.StdEncoding.DecodeString(envelope.Payload)
	if err != nil {
		t.Fatal(err)
	}
	var statement map[string]any
	if err := json.Unmarshal(payload, &statement); err != nil {
		t.Fatal(err)
	}
	mutate(statement["predicate"].(map[string]any))
	signer, err := newEd25519Signer(fixture.privateKeys[index])
	if err != nil {
		t.Fatal(err)
	}
	raw, err = signer.sign(statement)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths[0], raw, 0o640); err != nil {
		t.Fatal(err)
	}
}

func mutateSignedAttestation(t testing.TB, fixture verifierFixture, mutate func(map[string]any, map[string]any)) {
	t.Helper()
	path := filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json")
	var envelope dsseEnvelope
	raw, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(raw, &envelope) != nil {
		t.Fatal("read segment envelope")
	}
	payload, _ := base64.StdEncoding.DecodeString(envelope.Payload)
	var statement map[string]any
	if err := json.Unmarshal(payload, &statement); err != nil {
		t.Fatal(err)
	}
	mutate(statement, statement["predicate"].(map[string]any))
	signer, err := newEd25519Signer(fixture.privateKeys[0])
	if err != nil {
		t.Fatal(err)
	}
	raw, err = signer.sign(statement)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o640); err != nil {
		t.Fatal(err)
	}
}

func emptyVerifierFixture(t testing.TB, historical bool) verifierFixture {
	t.Helper()
	root := t.TempDir()
	fixture := verifierFixture{evidenceDir: filepath.Join(root, "evidence"), segmentRoot: filepath.Join(root, "segments"), highWater: filepath.Join(root, "protected", "highwater.json")}
	privateKey, publicKey := verifierKeyPair(t, "empty")
	fixture.privateKeys = []string{privateKey}
	fixture.publicKeys = []string{publicKey}
	if historical {
		path := filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentScope), "historical", "data.parquet")
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("historical"), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	attestor, err := NewSegmentAttestor(SegmentAttestorConfig{EvidenceDir: fixture.evidenceDir, PrivateKeyPath: privateKey, HighWaterPath: fixture.highWater, SegmentRoot: fixture.segmentRoot})
	if err != nil {
		t.Fatal(err)
	}
	if err := attestor.Close(); err != nil {
		t.Fatal(err)
	}
	return fixture
}

func writeVerifierSegment(t testing.TB, fixture verifierFixture, privateKey, block string, contents []byte) {
	t.Helper()
	attestor, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir: fixture.evidenceDir, PrivateKeyPath: privateKey,
		HighWaterPath: fixture.highWater, SegmentRoot: fixture.segmentRoot,
	})
	if err != nil {
		t.Fatal(err)
	}
	segmentID := filepath.ToSlash(filepath.Join(segmentScope, block, "data.parquet"))
	segmentPath := filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentID))
	if err := os.MkdirAll(filepath.Dir(segmentPath), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(segmentPath, contents, 0o640); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(contents)
	if err := attestor.process(segmentUpload{name: segmentID, digest: hexDigest(digest[:]), size: int64(len(contents))}); err != nil {
		t.Fatal(err)
	}
	if err := attestor.Close(); err != nil {
		t.Fatal(err)
	}
}

func verifyFixture(t testing.TB, fixture verifierFixture, keys []string) (evidenceverify.Result, error) {
	t.Helper()
	return evidenceverify.VerifyCorpus(context.Background(), evidenceverify.Config{
		EvidenceDir: fixture.evidenceDir, SegmentRoot: fixture.segmentRoot,
		HighWaterPath: fixture.highWater, PublicKeyPaths: keys,
	})
}

func TestVerifyCorpusGeneratedByWriter(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	result, err := verifyFixture(t, fixture, fixture.publicKeys)
	if err != nil {
		t.Fatal(err)
	}
	if result.Segments != 1 || result.Checkpoints != 1 || result.MaxSequence != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if !result.SignaturesVerified || result.SemanticRedaction != evidenceverify.SemanticRedactionNotAssessed {
		t.Fatalf("verification status conflated: %+v", result)
	}
	if result.IntegrityScope != evidenceverify.IntegrityScopeComplete || result.UnattestedHistoricalSegments != 0 {
		t.Fatalf("unexpected integrity scope: %+v", result)
	}
}

func TestVerifySegmentIndependentOfJournal(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	result, err := evidenceverify.VerifySegment(context.Background(), evidenceverify.SegmentConfig{
		AttestationPath: filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json"),
		SegmentPath:     filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentScope), "block-1", "data.parquet"),
		PublicKeyPaths:  fixture.publicKeys,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.SignatureVerified || result.Digest == "" || result.SemanticRedaction != evidenceverify.SemanticRedactionNotAssessed {
		t.Fatalf("unexpected segment result: %+v", result)
	}
	if _, err := evidenceverify.VerifySegment(context.Background(), evidenceverify.SegmentConfig{
		AttestationPath: filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json"),
		SegmentPath:     filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentScope), "block-1", "data.parquet"),
	}); err == nil || !strings.Contains(err.Error(), "external public key") {
		t.Fatalf("expected external-key requirement, got %v", err)
	}
	if err := os.WriteFile(filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentScope), "block-1", "data.parquet"), []byte("first parquet byteZ"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := evidenceverify.VerifySegment(context.Background(), evidenceverify.SegmentConfig{
		AttestationPath: filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json"),
		SegmentPath:     filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentScope), "block-1", "data.parquet"),
		PublicKeyPaths:  fixture.publicKeys,
	}); err == nil || !strings.Contains(err.Error(), "digest mismatch") {
		t.Fatalf("expected independent segment tamper rejection, got %v", err)
	}
}

func TestVerifyRejectsTamperedSegment(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	path := filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentScope), "block-1", "data.parquet")
	if err := os.WriteFile(path, []byte("first parquet byteZ"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "digest") {
		t.Fatalf("expected digest rejection, got %v", err)
	}
}

func TestVerifyRejectsIntermediateSymlink(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	scope := filepath.Join(fixture.segmentRoot, "signaldb")
	relocated := filepath.Join(t.TempDir(), "signaldb")
	if err := os.Rename(scope, relocated); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(relocated, scope); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected intermediate symlink rejection, got %v", err)
	}
}

func TestVerifyRejectsIntermediateEvidenceSymlink(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	checkpoints := filepath.Join(fixture.evidenceDir, "checkpoints")
	relocated := filepath.Join(t.TempDir(), "checkpoints")
	if err := os.Rename(checkpoints, relocated); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(relocated, checkpoints); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected evidence symlink rejection, got %v", err)
	}
}

func TestVerifyRejectsOversizedEnvelope(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	path := filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json")
	if err := os.WriteFile(path, bytes.Repeat([]byte("x"), 4<<20+1), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "exceeds 4194304 bytes") {
		t.Fatalf("expected envelope size rejection, got %v", err)
	}
}

func TestVerifyRejectsTamperedCheckpoint(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	entries, err := filepath.Glob(filepath.Join(fixture.evidenceDir, "checkpoints", "*.dsse.json"))
	if err != nil || len(entries) != 1 {
		t.Fatalf("checkpoint fixture: %v %v", entries, err)
	}
	var envelope map[string]any
	raw, err := os.ReadFile(entries[0])
	if err != nil || json.Unmarshal(raw, &envelope) != nil {
		t.Fatal("read checkpoint envelope")
	}
	payload, _ := base64.StdEncoding.DecodeString(envelope["payload"].(string))
	payload = []byte(strings.Replace(string(payload), "segment_sequence", "tampered_sequence", 1))
	envelope["payload"] = base64.StdEncoding.EncodeToString(payload)
	raw, _ = json.Marshal(envelope)
	if err := os.WriteFile(entries[0], raw, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "signature") {
		t.Fatalf("expected signature rejection, got %v", err)
	}
}

func TestVerifyRejectsJournalSequenceDiscontinuity(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	path := filepath.Join(fixture.evidenceDir, "segments.jsonl")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	raw = []byte(strings.Replace(string(raw), `"sequence":1`, `"sequence":2`, 1))
	if err := os.WriteFile(path, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "position") {
		t.Fatalf("expected sequence rejection, got %v", err)
	}
}

func TestVerifyRejectsBrokenCheckpointChain(t *testing.T) {
	fixture := newVerifierFixture(t, true)
	mutateSignedCheckpoint(t, fixture, 1, func(predicate map[string]any) {
		predicate["prev_checkpoint_digest"] = strings.Repeat("0", 64)
	})
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "previous checkpoint digest") {
		t.Fatalf("expected chain rejection, got %v", err)
	}
}

func TestVerifyRejectsCheckpointCumulativeRowCount(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	mutateSignedCheckpoint(t, fixture, 0, func(predicate map[string]any) {
		predicate["cumulative_row_count"] = float64(2)
	})
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "row count") {
		t.Fatalf("expected cumulative row rejection, got %v", err)
	}
}

func TestVerifyRejectsCheckpointMerkleMismatch(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	mutateSignedCheckpoint(t, fixture, 0, func(predicate map[string]any) {
		predicate["merkle_root"] = strings.Repeat("f", 64)
	})
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "Merkle root") {
		t.Fatalf("expected Merkle rejection, got %v", err)
	}
}

func TestVerifyRejectsUnknownEnvelopeField(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	path := filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json")
	var envelope map[string]any
	raw, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(raw, &envelope) != nil {
		t.Fatal("read segment envelope")
	}
	envelope["unsupported"] = true
	raw, _ = json.Marshal(envelope)
	if err := os.WriteFile(path, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("expected strict schema rejection, got %v", err)
	}
}

func TestVerifyRejectsStrictJSONAmbiguity(t *testing.T) {
	t.Run("duplicate nested predicate key", func(t *testing.T) {
		fixture := newVerifierFixture(t, false)
		path := filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json")
		var envelope dsseEnvelope
		raw, _ := os.ReadFile(path)
		_ = json.Unmarshal(raw, &envelope)
		payload, _ := base64.StdEncoding.DecodeString(envelope.Payload)
		needle := `"schema_version":"` + segmentSchema + `"`
		payload = []byte(strings.Replace(string(payload), needle, needle+","+needle, 1))
		signer, _ := newEd25519Signer(fixture.privateKeys[0])
		envelope.Payload = base64.StdEncoding.EncodeToString(payload)
		envelope.Signatures[0].Sig = base64.StdEncoding.EncodeToString(ed25519.Sign(signer.privateKey, dssePAE(dssePayloadType, payload)))
		raw, _ = json.Marshal(envelope)
		_ = os.WriteFile(path, raw, 0o640)
		if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "duplicate JSON key") {
			t.Fatalf("expected duplicate-key rejection, got %v", err)
		}
	})
	t.Run("case alias", func(t *testing.T) {
		fixture := newVerifierFixture(t, false)
		path := filepath.Join(fixture.evidenceDir, "attestations", "00000000000000000001.dsse.json")
		raw, _ := os.ReadFile(path)
		raw = []byte(strings.Replace(string(raw), `"payloadType":`, `"PayloadType":`, 1))
		_ = os.WriteFile(path, raw, 0o640)
		if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "unknown field") {
			t.Fatalf("expected case-alias rejection, got %v", err)
		}
	})
}

func TestVerifyRejectsResignedUnknownSchemasAndMetadata(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(map[string]any, map[string]any)
	}{
		{"segment schema", func(_ map[string]any, predicate map[string]any) {
			predicate["schema_version"] = "signalloom.segment/v2"
		}},
		{"statement metadata", func(statement, _ map[string]any) { statement["metadata"] = true }},
		{"predicate metadata", func(_ map[string]any, predicate map[string]any) { predicate["metadata"] = true }},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newVerifierFixture(t, false)
			mutateSignedAttestation(t, fixture, test.mutate)
			if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil {
				t.Fatal("expected resigned schema or metadata rejection")
			}
		})
	}
	t.Run("checkpoint schema", func(t *testing.T) {
		fixture := newVerifierFixture(t, false)
		mutateSignedCheckpoint(t, fixture, 0, func(predicate map[string]any) { predicate["schema_version"] = "signalloom.audit.checkpoint/v2" })
		if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "unsupported schema") {
			t.Fatalf("expected resigned checkpoint schema rejection, got %v", err)
		}
	})
}

func TestVerifyRejectsMissingJournalTailBelowHighwater(t *testing.T) {
	fixture := newVerifierFixture(t, true)
	path := filepath.Join(fixture.evidenceDir, "segments.jsonl")
	raw, _ := os.ReadFile(path)
	lines := bytes.Split(raw, []byte("\n"))
	if err := os.WriteFile(path, append(lines[0], '\n'), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "highwater") {
		t.Fatalf("expected protected highwater rejection, got %v", err)
	}
}

func TestVerifyReportsEmptyAndHistoricalIntegrityScope(t *testing.T) {
	for _, historical := range []bool{false, true} {
		fixture := emptyVerifierFixture(t, historical)
		result, err := verifyFixture(t, fixture, fixture.publicKeys)
		if err != nil {
			t.Fatal(err)
		}
		wantHistorical := 0
		if historical {
			wantHistorical = 1
		}
		if result.IntegrityScope != evidenceverify.IntegrityScopePartial || result.UnattestedHistoricalSegments != wantHistorical || result.SignaturesVerified {
			t.Fatalf("unexpected partial scope: %+v", result)
		}
	}
}

func TestVerifyCLIActualCorpusAndTamper(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "segment-verify")
	build := exec.Command("go", "build", "-o", binary, "../cmd/segment-verify")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v: %s", err, output)
	}
	fixture := newVerifierFixture(t, false)
	args := []string{"-evidence-dir", fixture.evidenceDir, "-segment-root", fixture.segmentRoot, "-highwater", fixture.highWater, "-public-key", fixture.publicKeys[0]}
	command := exec.Command(binary, args...)
	command.Dir = t.TempDir() // Auditor executes without repository-relative files.
	output, err := command.CombinedOutput()
	if err != nil || !bytes.Contains(output, []byte(`"integrity_scope": "complete"`)) {
		t.Fatalf("valid CLI corpus: %v: %s", err, output)
	}
	segment := filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentScope), "block-1", "data.parquet")
	_ = os.WriteFile(segment, []byte("first parquet byteZ"), 0o640)
	if output, err = exec.Command(binary, args...).CombinedOutput(); err == nil || !bytes.Contains(output, []byte("digest mismatch")) {
		t.Fatalf("tampered CLI corpus: %v: %s", err, output)
	}
}

func TestVerifyCLIScopePolicy(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "segment-verify")
	if output, err := exec.Command("go", "build", "-o", binary, "../cmd/segment-verify").CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v: %s", err, output)
	}
	for _, historical := range []bool{false, true} {
		fixture := emptyVerifierFixture(t, historical)
		args := []string{"-evidence-dir", fixture.evidenceDir, "-segment-root", fixture.segmentRoot, "-highwater", fixture.highWater, "-public-key", fixture.publicKeys[0]}
		if output, err := exec.Command(binary, args...).CombinedOutput(); err == nil || !bytes.Contains(output, []byte("partial integrity scope")) {
			t.Fatalf("default partial policy: %v: %s", err, output)
		}
		args = append(args, "-audit-only")
		if output, err := exec.Command(binary, args...).CombinedOutput(); err != nil || !bytes.Contains(output, []byte(`"integrity_scope": "partial"`)) {
			t.Fatalf("audit-only partial report: %v: %s", err, output)
		}
	}
}

func TestVerifyRejectsHighwaterTipMutation(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	raw, err := os.ReadFile(fixture.highWater)
	if err != nil {
		t.Fatal(err)
	}
	var high map[string]any
	if err := json.Unmarshal(raw, &high); err != nil {
		t.Fatal(err)
	}
	high["last_digest"] = strings.Repeat("f", 64)
	raw, _ = json.Marshal(high)
	if err := os.WriteFile(fixture.highWater, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "highwater tip") {
		t.Fatalf("expected highwater tip rejection, got %v", err)
	}
}

func TestVerifyReportsLostErrorsAsPartial(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	raw, err := os.ReadFile(fixture.highWater)
	if err != nil {
		t.Fatal(err)
	}
	var high map[string]any
	if err := json.Unmarshal(raw, &high); err != nil {
		t.Fatal(err)
	}
	high["lost_error_count"] = 1
	raw, err = json.Marshal(high)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixture.highWater, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := verifyFixture(t, fixture, fixture.publicKeys)
	if err != nil || !result.SignaturesVerified || result.LostErrorCount != 1 || result.IntegrityScope != evidenceverify.IntegrityScopePartial {
		t.Fatalf("lost errors must not invalidate signatures or certify completeness: %+v, %v", result, err)
	}
}

func TestVerifyRejectsUnknownSchema(t *testing.T) {
	fixture := newVerifierFixture(t, false)
	raw, err := os.ReadFile(fixture.highWater)
	if err != nil {
		t.Fatal(err)
	}
	raw = []byte(strings.Replace(string(raw), highWaterSchema, "signalloom.segment.highwater/v2", 1))
	if err := os.WriteFile(fixture.highWater, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys); err == nil || !strings.Contains(err.Error(), "unsupported schema") {
		t.Fatalf("expected schema rejection, got %v", err)
	}
}

func TestVerifySupportsHistoricalKeyRotation(t *testing.T) {
	fixture := newVerifierFixture(t, true)
	// Destroy only disposable fixture private material; historical verification
	// requires retained public keys, never the retired private signing key.
	for _, privatePath := range fixture.privateKeys {
		if err := os.Remove(privatePath); err != nil {
			t.Fatal(err)
		}
	}
	result, err := verifyFixture(t, fixture, fixture.publicKeys)
	if err != nil {
		t.Fatal(err)
	}
	if result.Segments != 2 || result.Checkpoints != 2 || result.TrustedKeys != 2 {
		t.Fatalf("unexpected rotation result: %+v", result)
	}
	if _, err := verifyFixture(t, fixture, fixture.publicKeys[1:]); err == nil || !strings.Contains(err.Error(), "trusted key") {
		t.Fatalf("expected retired-key rejection, got %v", err)
	}
}

func BenchmarkVerify(b *testing.B) {
	b.Log("conditions: repeated in-process verification; filesystem cache uncontrolled; no cold-cache claim")
	for _, count := range []int{1, 100} {
		b.Run(fmt.Sprintf("segments=%d", count), func(b *testing.B) {
			fixture := benchmarkVerifierFixture(b, count)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := verifyFixture(b, fixture, fixture.publicKeys); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportMetric(float64(count), "segments/corpus")
			b.ReportMetric(float64(count*128), "segment_bytes/corpus")
		})
	}
}

func benchmarkVerifierFixture(t testing.TB, count int) verifierFixture {
	t.Helper()
	root := t.TempDir()
	fixture := verifierFixture{evidenceDir: filepath.Join(root, "evidence"), segmentRoot: filepath.Join(root, "segments"), highWater: filepath.Join(root, "protected", "highwater.json")}
	privateKey, publicKey := verifierKeyPair(t, "benchmark")
	fixture.privateKeys, fixture.publicKeys = []string{privateKey}, []string{publicKey}
	attestor, err := NewSegmentAttestor(SegmentAttestorConfig{EvidenceDir: fixture.evidenceDir, PrivateKeyPath: privateKey, HighWaterPath: fixture.highWater, SegmentRoot: fixture.segmentRoot})
	if err != nil {
		t.Fatal(err)
	}
	contents := bytes.Repeat([]byte("x"), 128)
	for i := 0; i < count; i++ {
		segmentID := filepath.ToSlash(filepath.Join(segmentScope, fmt.Sprintf("benchmark-%03d", i), "data.parquet"))
		path := filepath.Join(fixture.segmentRoot, filepath.FromSlash(segmentID))
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, contents, 0o640); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(contents)
		if err := attestor.process(segmentUpload{name: segmentID, digest: hexDigest(digest[:]), size: int64(len(contents))}); err != nil {
			t.Fatal(err)
		}
	}
	if err := attestor.Close(); err != nil {
		t.Fatal(err)
	}
	return fixture
}
