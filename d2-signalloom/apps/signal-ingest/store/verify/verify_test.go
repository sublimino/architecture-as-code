package verify

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestPubPEM(t testing.TB, dir, name string, pub any) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name+".pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestVerify_LoadKeyring_AllAlgorithms(t *testing.T) {
	dir := t.TempDir()

	// 1. Ed25519
	edPub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	edPath := writeTestPubPEM(t, dir, "ed25519", edPub)

	// 2. ECDSA P-256
	ecPriv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ecPath := writeTestPubPEM(t, dir, "ecdsa-p256", &ecPriv.PublicKey)

	// 3. RSA 2048
	rsaPriv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	rsaPath := writeTestPubPEM(t, dir, "rsa-2048", &rsaPriv.PublicKey)

	// Load individual paths
	keyring, err := LoadKeyring([]string{edPath, ecPath, rsaPath})
	if err != nil {
		t.Fatalf("LoadKeyring failed: %v", err)
	}
	if len(keyring) != 3 {
		t.Fatalf("expected 3 keys in keyring, got %d", len(keyring))
	}

	// Load directory
	dirKeyring, err := LoadKeyringFromDir(dir)
	if err != nil {
		t.Fatalf("LoadKeyringFromDir failed: %v", err)
	}
	if len(dirKeyring) != 3 {
		t.Fatalf("expected 3 keys in directory keyring, got %d", len(dirKeyring))
	}

	// Verify SPKI key IDs
	for _, pub := range []any{edPub, &ecPriv.PublicKey, &rsaPriv.PublicKey} {
		spki, _ := x509.MarshalPKIXPublicKey(pub)
		digest := sha256.Sum256(spki)
		expectedID := hex.EncodeToString(digest[:])
		if _, ok := keyring[expectedID]; !ok {
			t.Errorf("keyring missing expected key ID: %s", expectedID)
		}
	}
}

func TestVerify_DSSE_DualAlgorithmVerification(t *testing.T) {
	dir := t.TempDir()

	// Prepare payload and statement
	stmt := map[string]any{
		"_type":         statementType,
		"subject":       []any{map[string]any{"name": "test-seg", "digest": map[string]any{"sha256": "1234"}}},
		"predicateType": segmentPredicate,
		"predicate":     map[string]any{"schema_version": segmentSchema, "sequence": 1, "segment_id": "test-seg", "digest": "1234", "byte_length": 100, "signer_key_id": "placeholder", "state": "ok", "error": ""},
	}
	payload, _ := json.Marshal(stmt)
	pae := dssePAE(dssePayloadType, payload)

	// 1. Sign with ECDSA
	ecPriv, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	h := sha256.Sum256(pae)
	ecSig, _ := ecdsa.SignASN1(rand.Reader, ecPriv, h[:])
	ecPubDER, _ := x509.MarshalPKIXPublicKey(&ecPriv.PublicKey)
	ecDigest := sha256.Sum256(ecPubDER)
	ecKeyID := hex.EncodeToString(ecDigest[:])

	ecEnv := envelope{
		PayloadType: dssePayloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures:  []signature{{KeyID: ecKeyID, Sig: base64.StdEncoding.EncodeToString(ecSig)}},
	}
	ecEnvBytes, _ := json.Marshal(ecEnv)
	ecEnvPath := filepath.Join(dir, "ecdsa.dsse.json")
	_ = os.WriteFile(ecEnvPath, ecEnvBytes, 0o644)

	// 2. Sign with RSA
	rsaPriv, _ := rsa.GenerateKey(rand.Reader, 2048)
	rsaSig, _ := rsa.SignPSS(rand.Reader, rsaPriv, crypto.SHA256, h[:], nil)
	rsaPubDER, _ := x509.MarshalPKIXPublicKey(&rsaPriv.PublicKey)
	rsaDigest := sha256.Sum256(rsaPubDER)
	rsaKeyID := hex.EncodeToString(rsaDigest[:])

	rsaEnv := envelope{
		PayloadType: dssePayloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures:  []signature{{KeyID: rsaKeyID, Sig: base64.StdEncoding.EncodeToString(rsaSig)}},
	}
	rsaEnvBytes, _ := json.Marshal(rsaEnv)
	rsaEnvPath := filepath.Join(dir, "rsa.dsse.json")
	_ = os.WriteFile(rsaEnvPath, rsaEnvBytes, 0o644)

	// Build keyring
	keyring := Keyring{
		ecKeyID:  &ecPriv.PublicKey,
		rsaKeyID: &rsaPriv.PublicKey,
	}

	// Verify ECDSA envelope
	parsedStmt, signerID, err := verifyEnvelope(ecEnvPath, keyring)
	if err != nil || signerID != ecKeyID || parsedStmt.PredicateType != segmentPredicate {
		t.Fatalf("verifyEnvelope ECDSA failed: err=%v signerID=%s", err, signerID)
	}

	// Verify RSA envelope
	parsedStmt, signerID, err = verifyEnvelope(rsaEnvPath, keyring)
	if err != nil || signerID != rsaKeyID || parsedStmt.PredicateType != segmentPredicate {
		t.Fatalf("verifyEnvelope RSA failed: err=%v signerID=%s", err, signerID)
	}
}

func TestVerify_DSSE_RejectsUntrustedOrCorruptedSignature(t *testing.T) {
	dir := t.TempDir()
	payload := []byte(`{"test":"untrusted"}`)
	pae := dssePAE(dssePayloadType, payload)

	edPub, edPriv, _ := ed25519.GenerateKey(rand.Reader)
	sig := ed25519.Sign(edPriv, pae)
	spki, _ := x509.MarshalPKIXPublicKey(edPub)
	digest := sha256.Sum256(spki)
	keyID := hex.EncodeToString(digest[:])

	env := envelope{
		PayloadType: dssePayloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures:  []signature{{KeyID: keyID, Sig: base64.StdEncoding.EncodeToString(sig)}},
	}
	raw, _ := json.Marshal(env)
	envPath := filepath.Join(dir, "untrusted.dsse.json")
	_ = os.WriteFile(envPath, raw, 0o644)

	// Empty keyring should fail as untrusted
	emptyKeyring := make(Keyring)
	_, _, err := verifyEnvelope(envPath, emptyKeyring)
	if err == nil || !strings.Contains(err.Error(), "untrusted key") {
		t.Fatalf("expected untrusted key error, got %v", err)
	}

	// Corrupted signature should fail verification
	sig[0] ^= 0xff
	corruptedEnv := envelope{
		PayloadType: dssePayloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures:  []signature{{KeyID: keyID, Sig: base64.StdEncoding.EncodeToString(sig)}},
	}
	corruptedBytes, _ := json.Marshal(corruptedEnv)
	corruptedPath := filepath.Join(dir, "corrupted.dsse.json")
	_ = os.WriteFile(corruptedPath, corruptedBytes, 0o644)

	keyring := Keyring{keyID: edPub}
	_, _, err = verifyEnvelope(corruptedPath, keyring)
	if err == nil {
		t.Fatal("expected corrupted signature to fail verification")
	}
}
