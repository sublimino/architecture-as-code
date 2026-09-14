package identity

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestEncryption_AESGCM_RoundtripAndTamper(t *testing.T) {
	key := []byte("01234567890123456789012345678901") // 32-byte key
	enc, err := NewAESGCMEncryptor(key)
	if err != nil {
		t.Fatalf("NewAESGCMEncryptor: %v", err)
	}

	plaintext := []byte(`{"secret_token":"high-privilege-authz-9876","user":"alice"}`)

	ciphertext, err := enc.Encrypt(plaintext)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	if bytes.Equal(plaintext, ciphertext) {
		t.Fatal("ciphertext must not match plaintext")
	}

	decrypted, err := enc.Decrypt(ciphertext)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	if !bytes.Equal(plaintext, decrypted) {
		t.Fatalf("decrypted payload mismatch: got %s, want %s", decrypted, plaintext)
	}

	// Tamper test: mutate ciphertext byte
	tampered := make([]byte, len(ciphertext))
	copy(tampered, ciphertext)
	tampered[len(tampered)-1] ^= 0xFF

	_, err = enc.Decrypt(tampered)
	if err == nil {
		t.Fatal("expected error decrypting tampered ciphertext")
	}
	if !errors.Is(err, ErrInvalidCiphertext) {
		t.Errorf("expected ErrInvalidCiphertext, got: %v", err)
	}
}

// TestEncryption_DeterministicPseudonym replaces the former TestEncryption_DeterministicHash.
//
// The old test asserted determinism and a 64-character hex shape — both of which an UNKEYED
// sha256.Sum256 satisfies perfectly. It would have passed unchanged throughout the entire period
// the defect existed, which is why it is not sufficient on its own. Determinism is asserted here;
// non-invertibility is asserted in TestAliasPseudonym_ResistsDictionaryAttack.
func TestEncryption_DeterministicPseudonym(t *testing.T) {
	enc, err := NewAESGCMEncryptor([]byte("some-passphrase"))
	if err != nil {
		t.Fatalf("NewAESGCMEncryptor: %v", err)
	}

	val := "spiffe://cluster.local/ns/prod/sa/deployer"
	p1, err := enc.Pseudonym("tenant-a", val)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}
	p2, err := enc.Pseudonym("tenant-a", val)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}

	if p1 == "" {
		t.Fatal("pseudonym should not be empty")
	}
	if p1 != p2 {
		t.Errorf("deterministic pseudonym mismatch: %s vs %s", p1, p2)
	}
	if len(p1) != PseudonymHexLen {
		t.Errorf("expected %d-char hex string, got len %d (%s)", PseudonymHexLen, len(p1), p1)
	}
	if !IsPseudonym(p1) {
		t.Errorf("pseudonym %q does not have pseudonym shape", p1)
	}

	// The keyed pseudonym must differ from the unkeyed digest this change removed. If someone
	// reintroduces sha256.Sum256 as the pseudonym function, this assertion fails.
	unkeyed := sha256.Sum256([]byte(val))
	if p1 == hex.EncodeToString(unkeyed[:]) {
		t.Fatal("pseudonym equals the bare SHA-256 of the value; the key is not being used")
	}
}

func TestEncryption_MemoryRepositoryEncrypted(t *testing.T) {
	ctx := context.Background()
	enc, _ := NewAESGCMEncryptor([]byte("test-key-12345"))
	repo := NewMemoryRepository(enc)

	actor := ActorRecord{
		ActorID:   "actor-enc-test",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"confidential": "secret-payload"},
		CreatedAt: time.Now().UTC(),
	}

	if err := repo.CreateActor(ctx, actor); err != nil {
		t.Fatalf("CreateActor: %v", err)
	}

	got, err := repo.GetActor(ctx, actor.ActorID)
	if err != nil {
		t.Fatalf("GetActor: %v", err)
	}

	if got.Metadata["confidential"] != "secret-payload" {
		t.Errorf("metadata decrypted mismatch: got %v", got.Metadata)
	}
}

// TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey asserts that an empty key
// string fails closed in production mode (when no dev opt-in is configured).
func TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey(t *testing.T) {
	for _, env := range DevOptInEnvVars {
		t.Setenv(env, "")
	}

	enc, err := NewEncryptorFromKeyString("")
	if err == nil {
		t.Fatalf("expected error on empty key string in production mode, got encryptor: %T", enc)
	}
	if !errors.Is(err, ErrNoopEncryptionNotAllowed) {
		t.Errorf("expected ErrNoopEncryptionNotAllowed, got: %v", err)
	}
}

// TestNewEncryptorFromKeyString_DevelopmentOptInAllowed asserts that an empty key
// returns NoopEncryptor when explicitly opted-in via INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR.
func TestNewEncryptorFromKeyString_DevelopmentOptInAllowed(t *testing.T) {
	t.Setenv("INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR", "true")

	enc, err := NewEncryptorFromKeyString("")
	if err != nil {
		t.Fatalf("expected nil error when dev opt-in enabled, got: %v", err)
	}
	noop, ok := enc.(*NoopEncryptor)
	if !ok {
		t.Fatalf("expected *NoopEncryptor, got: %T", enc)
	}
	defer noop.Stop()

	posture := noop.Posture()
	if posture.Healthy {
		t.Errorf("expected NoopEncryptor posture Healthy to be false")
	}
	if posture.Mode != "passthrough_insecure" {
		t.Errorf("expected mode passthrough_insecure, got %s", posture.Mode)
	}
}

// TestNewEncryptorFromKeyString_ValidKeyAlwaysSucceeds asserts that providing a valid key
// instantiates AESGCMEncryptor regardless of dev opt-in flags.
func TestNewEncryptorFromKeyString_ValidKeyAlwaysSucceeds(t *testing.T) {
	t.Setenv("INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR", "")

	enc, err := NewEncryptorFromKeyString("01234567890123456789012345678901")
	if err != nil {
		t.Fatalf("unexpected error for valid key: %v", err)
	}
	aesEnc, ok := enc.(*AESGCMEncryptor)
	if !ok {
		t.Fatalf("expected *AESGCMEncryptor, got: %T", enc)
	}

	posture := aesEnc.Posture()
	if !posture.Healthy {
		t.Errorf("expected AESGCMEncryptor posture Healthy to be true")
	}
	if posture.Algorithm != "AES-256-GCM" {
		t.Errorf("expected algorithm AES-256-GCM, got %s", posture.Algorithm)
	}
}

// TestNoopEncryptor_PersistentWarningCycle asserts that the background warning ticker
// runs and terminates cleanly without leaking or hanging.
func TestNoopEncryptor_PersistentWarningCycle(t *testing.T) {
	noop := NewNoopEncryptorWithInterval(10 * time.Millisecond)
	time.Sleep(35 * time.Millisecond)
	noop.Stop()
	// Idempotent stop
	noop.Stop()
}

// TestGetEncryptionPosture asserts correct posture reporting across all encryptor implementations.
func TestGetEncryptionPosture(t *testing.T) {
	nilPosture := GetEncryptionPosture(nil)
	if nilPosture.Healthy || nilPosture.Mode != "unconfigured" {
		t.Errorf("unexpected posture for nil encryptor: %+v", nilPosture)
	}

	aesEnc, _ := NewAESGCMEncryptor([]byte("01234567890123456789012345678901"))
	aesPosture := GetEncryptionPosture(aesEnc)
	if !aesPosture.Healthy || aesPosture.Mode != "enforced" {
		t.Errorf("unexpected posture for AESGCM: %+v", aesPosture)
	}

	noop := NewNoopEncryptor()
	defer noop.Stop()
	noopPosture := GetEncryptionPosture(noop)
	if noopPosture.Healthy || !noopPosture.DevOptIn {
		t.Errorf("unexpected posture for Noop: %+v", noopPosture)
	}
}

// TestNewPostgresRepository_RefusesNilEncryptorInProduction asserts that NewPostgresRepository
// panics if a nil encryptor is supplied in production mode without dev opt-in.
func TestNewPostgresRepository_RefusesNilEncryptorInProduction(t *testing.T) {
	for _, env := range DevOptInEnvVars {
		t.Setenv(env, "")
	}

	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("expected panic when NewPostgresRepository is given nil encryptor in production mode")
		}
	}()

	_ = NewPostgresRepository(nil, nil)
}
