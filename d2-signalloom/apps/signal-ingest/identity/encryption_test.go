package identity

import (
	"bytes"
	"context"
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

func TestEncryption_DeterministicHash(t *testing.T) {
	enc, _ := NewAESGCMEncryptor([]byte("some-passphrase"))

	val := "spiffe://cluster.local/ns/prod/sa/deployer"
	hash1 := enc.Hash(val)
	hash2 := enc.Hash(val)

	if hash1 == "" {
		t.Fatal("hash should not be empty")
	}
	if hash1 != hash2 {
		t.Errorf("deterministic hash mismatch: %s vs %s", hash1, hash2)
	}
	if len(hash1) != 64 { // 256 bits = 64 hex chars
		t.Errorf("expected 64-char sha256 hex string, got len %d (%s)", len(hash1), hash1)
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
