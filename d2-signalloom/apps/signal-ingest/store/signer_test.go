package store

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store/verify"
	"github.com/thanos-io/objstore"
	"github.com/thanos-io/objstore/providers/filesystem"
)

type inTotoStatementPayload struct {
	Type          string          `json:"_type"`
	Subject       []any           `json:"subject"`
	PredicateType string          `json:"predicateType"`
	Predicate     json.RawMessage `json:"predicate"`
}

func writeTestECDSAKeyPEM(t testing.TB) (string, string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	privPath := filepath.Join(dir, "ecdsa-priv.pem")
	pubPath := filepath.Join(dir, "ecdsa-pub.pem")
	if err := os.WriteFile(privPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pubPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	return privPath, pubPath
}

func writeTestRSAKeyPEM(t testing.TB) (string, string) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	privDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	privPath := filepath.Join(dir, "rsa-priv.pem")
	pubPath := filepath.Join(dir, "rsa-pub.pem")
	if err := os.WriteFile(privPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pubPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	return privPath, pubPath
}

func TestSigner_LocalEd25519_CanonicalDSSEAndKeyID(t *testing.T) {
	privPath := testSigningKey(t)
	signer, err := NewLocalEd25519Signer(privPath, "projects/test/keys/ed25519/versions/1")
	if err != nil {
		t.Fatalf("NewLocalEd25519Signer failed: %v", err)
	}
	if signer.Algorithm() != "ed25519" {
		t.Fatalf("expected ed25519 algorithm, got %s", signer.Algorithm())
	}
	if signer.KeyVersion() != "projects/test/keys/ed25519/versions/1" {
		t.Fatalf("unexpected key version: %s", signer.KeyVersion())
	}
	statement := map[string]any{
		"_type":         inTotoStatementType,
		"subject":       []any{map[string]any{"name": "test-seg", "digest": map[string]any{"sha256": "abcdef"}}},
		"predicateType": segmentPredicateType,
		"predicate":     map[string]any{"schema_version": segmentSchema, "sequence": 1, "key_version": signer.KeyVersion()},
	}
	envelopeBytes, err := signer.Sign(context.Background(), statement)
	if err != nil {
		t.Fatalf("signing failed: %v", err)
	}
	var env dsseEnvelope
	if err := json.Unmarshal(envelopeBytes, &env); err != nil {
		t.Fatalf("unmarshal envelope: %v", err)
	}
	if len(env.Signatures) != 1 || env.Signatures[0].KeyID != signer.KeyID() {
		t.Fatalf("signature key ID mismatch: got %v, want %s", env.Signatures, signer.KeyID())
	}
}

func TestSigner_LocalECDSA_CanonicalDSSEAndKeyID(t *testing.T) {
	privPath, pubPath := writeTestECDSAKeyPEM(t)
	signer, err := NewLocalSignerFromPath(privPath, "projects/test/keys/ecdsa/versions/1")
	if err != nil {
		t.Fatalf("NewLocalSignerFromPath ECDSA failed: %v", err)
	}
	if signer.Algorithm() != "ecdsa-p256-sha256" {
		t.Fatalf("expected ecdsa-p256-sha256 algorithm, got %s", signer.Algorithm())
	}
	statement := map[string]any{
		"_type":         inTotoStatementType,
		"subject":       []any{map[string]any{"name": "test-ecdsa-seg", "digest": map[string]any{"sha256": "123456"}}},
		"predicateType": segmentPredicateType,
		"predicate":     map[string]any{"schema_version": segmentSchema, "sequence": 1, "key_version": signer.KeyVersion()},
	}
	envelopeBytes, err := signer.Sign(context.Background(), statement)
	if err != nil {
		t.Fatalf("ECDSA signing failed: %v", err)
	}
	if len(envelopeBytes) == 0 {
		t.Fatal("expected non-empty envelope bytes")
	}

	keyring, err := verify.LoadKeyring([]string{pubPath})
	if err != nil {
		t.Fatalf("LoadKeyring failed: %v", err)
	}
	if _, ok := keyring[signer.KeyID()]; !ok {
		t.Fatalf("keyring missing signer key ID %s", signer.KeyID())
	}
}

func TestSigner_LocalRSA_CanonicalDSSEAndKeyID(t *testing.T) {
	privPath, pubPath := writeTestRSAKeyPEM(t)
	signer, err := NewLocalSignerFromPath(privPath, "projects/test/keys/rsa/versions/1")
	if err != nil {
		t.Fatalf("NewLocalSignerFromPath RSA failed: %v", err)
	}
	statement := map[string]any{
		"_type":         inTotoStatementType,
		"subject":       []any{map[string]any{"name": "test-rsa-seg", "digest": map[string]any{"sha256": "789012"}}},
		"predicateType": segmentPredicateType,
		"predicate":     map[string]any{"schema_version": segmentSchema, "sequence": 1, "key_version": signer.KeyVersion()},
	}
	envelopeBytes, err := signer.Sign(context.Background(), statement)
	if err != nil {
		t.Fatalf("RSA signing failed: %v", err)
	}
	if len(envelopeBytes) == 0 {
		t.Fatal("expected non-empty envelope bytes")
	}

	keyring, err := verify.LoadKeyring([]string{pubPath})
	if err != nil {
		t.Fatalf("LoadKeyring failed: %v", err)
	}
	if _, ok := keyring[signer.KeyID()]; !ok {
		t.Fatalf("keyring missing signer key ID %s", signer.KeyID())
	}
}

func TestSigner_KMS_SuccessfulSigningAndVerification(t *testing.T) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyVersion := "projects/demo-bank/locations/europe-west1/keyRings/signalloom/cryptoKeys/segment-signer/cryptoKeyVersions/1"
	mockKMS := NewMockKMSClient()
	if err := mockKMS.AddKey(keyVersion, priv, "ecdsa-p256-sha256"); err != nil {
		t.Fatal(err)
	}

	kmsSigner, err := NewKMSSigner(context.Background(), KMSSignerConfig{
		Client:      mockKMS,
		KeyVersion:  keyVersion,
		Algorithm:   "ecdsa-p256-sha256",
		RateLimiter: NewTokenBucket(200.0, 50),
		RetryConfig: DefaultRetryConfig(),
	})
	if err != nil {
		t.Fatalf("NewKMSSigner failed: %v", err)
	}

	evidenceDir := t.TempDir()
	storeDir := t.TempDir()
	highWaterPath := filepath.Join(evidenceDir, "protected", "highwater.json")
	attestor, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir:   evidenceDir,
		Signer:        kmsSigner,
		HighWaterPath: highWaterPath,
		SegmentRoot:   storeDir,
		QueueSize:     16,
	})
	if err != nil {
		t.Fatalf("NewSegmentAttestor failed: %v", err)
	}
	defer attestor.Close()

	fsBucket, err := filesystem.NewBucket(storeDir)
	if err != nil {
		t.Fatalf("filesystem.NewBucket failed: %v", err)
	}
	defer fsBucket.Close()

	bucket := newAttestingBucket(fsBucket, attestor)
	name := "signaldb/observations/01/data.parquet"
	parquetData := []byte("PAR1\x00kms-signed-observations\x00PAR1")
	if err := bucket.Upload(context.Background(), name, bytes.NewReader(parquetData)); err != nil {
		t.Fatalf("upload failed: %v", err)
	}
	if err := attestor.Wait(context.Background()); err != nil {
		t.Fatalf("attestor wait failed: %v", err)
	}

	// Verify the journal record contains key_version
	records := readJSONLines(t, filepath.Join(evidenceDir, "segments.jsonl"))
	if len(records) != 1 {
		t.Fatalf("expected 1 journal record, got %d", len(records))
	}
	if records[0]["key_version"] != keyVersion {
		t.Fatalf("journal record key_version = %v, want %s", records[0]["key_version"], keyVersion)
	}
	if records[0]["signer_key_id"] != kmsSigner.KeyID() {
		t.Fatalf("journal record signer_key_id = %v, want %s", records[0]["signer_key_id"], kmsSigner.KeyID())
	}

	// Verify that the public key was retained in keys/
	retainedKeyPath := filepath.Join(evidenceDir, "keys", kmsSigner.KeyID()+".pem")
	if _, err := os.Stat(retainedKeyPath); err != nil {
		t.Fatalf("retained public key missing at %s: %v", retainedKeyPath, err)
	}

	// Verify using independent corpus verifier
	cfg := verify.Config{
		EvidenceDir:    evidenceDir,
		SegmentRoot:    storeDir,
		HighWaterPath:  highWaterPath,
		PublicKeyPaths: []string{retainedKeyPath},
	}
	res, err := verify.VerifyCorpus(context.Background(), cfg)
	if err != nil {
		t.Fatalf("verify.VerifyCorpus failed: %v", err)
	}
	if !res.SignaturesVerified || res.Segments != 1 {
		t.Fatalf("corpus verification invalid: %+v", res)
	}
}

func TestSigner_KMS_RateLimiting_TokenBucket(t *testing.T) {
	// 10 QPS with 1 burst
	tb := NewTokenBucket(10.0, 1)
	start := time.Now()
	// Consume 4 tokens: first is instant, remaining 3 should take ~300ms
	for i := 0; i < 4; i++ {
		if err := tb.Wait(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	elapsed := time.Since(start)
	if elapsed < 250*time.Millisecond {
		t.Fatalf("expected rate limiting to take at least 250ms for 4 tokens at 10 QPS, took %v", elapsed)
	}
}

func TestSigner_KMS_SharedTokenBucket_MultiProcess(t *testing.T) {
	stateFile := filepath.Join(t.TempDir(), "shared-bucket.json")
	// 20 QPS with burst 2
	bucket1, err := NewFileSharedTokenBucket(stateFile, 20.0, 2)
	if err != nil {
		t.Fatal(err)
	}
	bucket2, err := NewFileSharedTokenBucket(stateFile, 20.0, 2)
	if err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 3; i++ {
			if err := bucket1.Wait(context.Background()); err != nil {
				t.Errorf("bucket1 wait error: %v", err)
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 3; i++ {
			if err := bucket2.Wait(context.Background()); err != nil {
				t.Errorf("bucket2 wait error: %v", err)
			}
		}
	}()
	wg.Wait()
	elapsed := time.Since(start)
	// 6 total tokens at 20 QPS with burst 2 should take (6-2)/20 = 200ms minimum
	if elapsed < 150*time.Millisecond {
		t.Fatalf("expected shared rate limiting across processes to take >150ms, took %v", elapsed)
	}
}

func TestSigner_KMS_BoundedRetry_ExponentialBackoff(t *testing.T) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyVersion := "projects/demo-bank/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1"
	mockKMS := NewMockKMSClient()
	if err := mockKMS.AddKey(keyVersion, priv, "ecdsa-p256-sha256"); err != nil {
		t.Fatal(err)
	}

	// Inject 2 transient 429 quota errors
	mockKMS.SetTransientErrors(2, ErrKMSRateLimited)

	kmsSigner, err := NewKMSSigner(context.Background(), KMSSignerConfig{
		Client:      mockKMS,
		KeyVersion:  keyVersion,
		Algorithm:   "ecdsa-p256-sha256",
		RateLimiter: NewTokenBucket(1000.0, 100),
		RetryConfig: RetryConfig{
			MaxRetries:     4,
			InitialBackoff: 10 * time.Millisecond,
			MaxBackoff:     100 * time.Millisecond,
			Multiplier:     2.0,
			Jitter:         false,
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	statement := map[string]any{"test": "payload"}
	start := time.Now()
	envelopeBytes, err := kmsSigner.Sign(context.Background(), statement)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("expected retry to succeed after transient errors, got: %v", err)
	}
	if len(envelopeBytes) == 0 {
		t.Fatal("expected non-empty envelope bytes")
	}
	// 2 retries with backoff (10ms + 20ms = 30ms minimum)
	if elapsed < 25*time.Millisecond {
		t.Fatalf("expected backoff sleep, took %v", elapsed)
	}
}

func TestSigner_KMS_DisabledKey_FailClosed(t *testing.T) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyVersion := "projects/demo-bank/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/disabled"
	mockKMS := NewMockKMSClient()
	if err := mockKMS.AddKey(keyVersion, priv, "ecdsa-p256-sha256"); err != nil {
		t.Fatal(err)
	}
	_ = mockKMS.SetStatus(keyVersion, "DISABLED")

	// Initializing with a disabled key must fail closed
	_, err = NewKMSSigner(context.Background(), KMSSignerConfig{
		Client:     mockKMS,
		KeyVersion: keyVersion,
	})
	if !errors.Is(err, ErrKMSKeyDisabled) {
		t.Fatalf("expected ErrKMSKeyDisabled, got: %v", err)
	}
}

func TestSigner_KMS_Rotation_And_DestroyedKey_VerificationWithRetainedPublicMaterial(t *testing.T) {
	// Step 1: Create Key Version 1 (P-256)
	privV1, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	v1Ref := "projects/bank/locations/eu/keyRings/attest/cryptoKeys/seg/cryptoKeyVersions/1"
	mockKMS := NewMockKMSClient()
	if err := mockKMS.AddKey(v1Ref, privV1, "ecdsa-p256-sha256"); err != nil {
		t.Fatal(err)
	}

	signerV1, err := NewKMSSigner(context.Background(), KMSSignerConfig{
		Client:     mockKMS,
		KeyVersion: v1Ref,
	})
	if err != nil {
		t.Fatal(err)
	}

	evidenceDir := t.TempDir()
	storeDir := t.TempDir()
	highWaterPath := filepath.Join(evidenceDir, "protected", "highwater.json")

	fsBucket, err := filesystem.NewBucket(storeDir)
	if err != nil {
		t.Fatal(err)
	}
	defer fsBucket.Close()

	attestorV1, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir:   evidenceDir,
		Signer:        signerV1,
		HighWaterPath: highWaterPath,
		SegmentRoot:   storeDir,
	})
	if err != nil {
		t.Fatal(err)
	}

	bucketV1 := newAttestingBucket(fsBucket, attestorV1)
	if err := bucketV1.Upload(context.Background(), "signaldb/observations/01/data.parquet", strings.NewReader("seg-1-bytes")); err != nil {
		t.Fatal(err)
	}
	if err := attestorV1.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := attestorV1.Close(); err != nil {
		t.Fatal(err)
	}

	// Step 2: Rotate to Key Version 2 (P-256)
	privV2, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	v2Ref := "projects/bank/locations/eu/keyRings/attest/cryptoKeys/seg/cryptoKeyVersions/2"
	if err := mockKMS.AddKey(v2Ref, privV2, "ecdsa-p256-sha256"); err != nil {
		t.Fatal(err)
	}

	signerV2, err := NewKMSSigner(context.Background(), KMSSignerConfig{
		Client:     mockKMS,
		KeyVersion: v2Ref,
	})
	if err != nil {
		t.Fatal(err)
	}

	attestorV2, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir:   evidenceDir,
		Signer:        signerV2,
		HighWaterPath: highWaterPath,
		SegmentRoot:   storeDir,
	})
	if err != nil {
		t.Fatal(err)
	}

	bucketV2 := newAttestingBucket(fsBucket, attestorV2)
	if err := bucketV2.Upload(context.Background(), "signaldb/observations/02/data.parquet", strings.NewReader("seg-2-bytes")); err != nil {
		t.Fatal(err)
	}
	if err := attestorV2.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := attestorV2.Close(); err != nil {
		t.Fatal(err)
	}

	// Step 3: Destroy Key Version 1 in KMS (private key deleted from KMS HSM)
	if err := mockKMS.SetStatus(v1Ref, "DESTROYED"); err != nil {
		t.Fatal(err)
	}

	// Verify that signing with V1 now fails closed as DESTROYED
	_, err = signerV1.Sign(context.Background(), map[string]any{"data": "should-fail"})
	if err == nil {
		t.Fatal("expected signing with destroyed key version to fail")
	}

	// Step 4: Verify the entire historical corpus using retained public keys
	pubKeyPaths, err := filepath.Glob(filepath.Join(evidenceDir, "keys", "*.pem"))
	if err != nil || len(pubKeyPaths) < 2 {
		t.Fatalf("expected at least 2 retained public keys, found %v", pubKeyPaths)
	}

	cfg := verify.Config{
		EvidenceDir:    evidenceDir,
		SegmentRoot:    storeDir,
		HighWaterPath:  highWaterPath,
		PublicKeyPaths: pubKeyPaths,
	}
	result, err := verify.VerifyCorpus(context.Background(), cfg)
	if err != nil {
		t.Fatalf("corpus verification failed against destroyed key: %v", err)
	}
	if result.Segments != 2 || !result.SignaturesVerified {
		t.Fatalf("expected 2 verified segments, got result: %+v", result)
	}
}

func TestSigner_CrashWindow_NoSegmentLostOrUnsigned(t *testing.T) {
	privPath := testSigningKey(t)
	signer, err := NewLocalEd25519Signer(privPath, "local-v1")
	if err != nil {
		t.Fatal(err)
	}

	evidenceDir := t.TempDir()
	highWaterPath := filepath.Join(evidenceDir, "protected", "highwater.json")
	attestor, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir:   evidenceDir,
		Signer:        signer,
		HighWaterPath: highWaterPath,
		QueueSize:     32,
	})
	if err != nil {
		t.Fatal(err)
	}

	bucket := newAttestingBucket(objstore.NewInMemBucket(), attestor)
	// Enqueue 10 segments in quick succession
	for i := 0; i < 10; i++ {
		name := fmt.Sprintf("signaldb/observations/%02d/data.parquet", i+1)
		if err := bucket.Upload(context.Background(), name, strings.NewReader(fmt.Sprintf("data-%d", i))); err != nil {
			t.Fatal(err)
		}
	}

	// Immediate graceful Close() must drain and attest all 10 without loss
	if err := attestor.Close(); err != nil {
		t.Fatalf("close failed: %v", err)
	}

	records := readJSONLines(t, filepath.Join(evidenceDir, "segments.jsonl"))
	if len(records) != 10 {
		t.Fatalf("expected 10 attested segment records on drain, got %d", len(records))
	}
	for idx, rec := range records {
		if rec["state"] != "ok" || rec["attestation"] == "" {
			t.Fatalf("record %d was not completed ok: %+v", idx, rec)
		}
	}
}

func TestSigner_KeyVersionRecordedBeforeSigning(t *testing.T) {
	privPath := testSigningKey(t)
	expectedVersion := "urn:kms:bank:hsm-v4"
	signer, err := NewLocalEd25519Signer(privPath, expectedVersion)
	if err != nil {
		t.Fatal(err)
	}

	evidenceDir := t.TempDir()
	highWaterPath := filepath.Join(evidenceDir, "protected", "highwater.json")
	attestor, err := NewSegmentAttestor(SegmentAttestorConfig{
		EvidenceDir:   evidenceDir,
		Signer:        signer,
		HighWaterPath: highWaterPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer attestor.Close()

	bucket := newAttestingBucket(objstore.NewInMemBucket(), attestor)
	if err := bucket.Upload(context.Background(), "signaldb/observations/01/data.parquet", strings.NewReader("sample")); err != nil {
		t.Fatal(err)
	}
	if err := attestor.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}

	// Inspect the DSSE attestation envelope predicate directly
	attPath := filepath.Join(evidenceDir, "attestations", "00000000000000000001.dsse.json")
	envBytes, err := os.ReadFile(attPath)
	if err != nil {
		t.Fatal(err)
	}
	var env dsseEnvelope
	if err := json.Unmarshal(envBytes, &env); err != nil {
		t.Fatal(err)
	}
	payloadBytes, err := base64Decode(env.Payload)
	if err != nil {
		t.Fatal(err)
	}
	var stmt inTotoStatementPayload
	if err := json.Unmarshal(payloadBytes, &stmt); err != nil {
		t.Fatal(err)
	}
	var predicate map[string]any
	if err := json.Unmarshal(stmt.Predicate, &predicate); err != nil {
		t.Fatal(err)
	}
	if predicate["key_version"] != expectedVersion {
		t.Fatalf("predicate key_version = %v, want %s", predicate["key_version"], expectedVersion)
	}
	if predicate["signer_key_id"] != signer.KeyID() {
		t.Fatalf("predicate signer_key_id = %v, want %s", predicate["signer_key_id"], signer.KeyID())
	}
}

func base64Decode(s string) ([]byte, error) {
	return base64.StdEncoding.DecodeString(s)
}
