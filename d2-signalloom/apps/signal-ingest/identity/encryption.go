package identity

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
)

var (
	// ErrInvalidCiphertext is returned when ciphertext is malformed or tampering is detected.
	ErrInvalidCiphertext = errors.New("invalid ciphertext: payload too short or authentication tag mismatch")
	// ErrInvalidKey is returned when the encryption key length is invalid.
	ErrInvalidKey = errors.New("invalid encryption key: must be non-empty")
)

// Encryptor provides encryption-at-rest and deterministic hashing for sensitive identity and delegation fields.
type Encryptor interface {
	Encrypt(plaintext []byte) ([]byte, error)
	Decrypt(ciphertext []byte) ([]byte, error)
	Hash(value string) string
}

// AESGCMEncryptor implements Encryptor using authenticated AES-256-GCM.
type AESGCMEncryptor struct {
	key [32]byte
}

// NewAESGCMEncryptor constructs an AES-256-GCM encryptor.
// If the provided key is not exactly 32 bytes, it derives a 32-byte key using SHA-256.
func NewAESGCMEncryptor(key []byte) (*AESGCMEncryptor, error) {
	if len(key) == 0 {
		return nil, ErrInvalidKey
	}
	var k [32]byte
	if len(key) == 32 {
		copy(k[:], key)
	} else {
		k = sha256.Sum256(key)
	}
	return &AESGCMEncryptor{key: k}, nil
}

// Encrypt encrypts plaintext using AES-256-GCM with a fresh 12-byte nonce prepended to the output.
func (e *AESGCMEncryptor) Encrypt(plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(e.key[:])
	if err != nil {
		return nil, fmt.Errorf("failed to create cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("failed to generate nonce: %w", err)
	}

	// Output format: [nonce (12 bytes)][ciphertext + auth tag]
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// Decrypt decrypts and verifies ciphertext with AES-256-GCM.
func (e *AESGCMEncryptor) Decrypt(ciphertext []byte) ([]byte, error) {
	block, err := aes.NewCipher(e.key[:])
	if err != nil {
		return nil, fmt.Errorf("failed to create cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}

	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, ErrInvalidCiphertext
	}

	nonce := ciphertext[:nonceSize]
	data := ciphertext[nonceSize:]

	plaintext, err := gcm.Open(nil, nonce, data, nil)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidCiphertext, err)
	}

	return plaintext, nil
}

// Hash produces a deterministic SHA-256 hex string for indexed lookup.
func (e *AESGCMEncryptor) Hash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// NoopEncryptor is a passthrough Encryptor for unencrypted environments or development.
type NoopEncryptor struct{}

func NewNoopEncryptor() *NoopEncryptor {
	return &NoopEncryptor{}
}

func (n *NoopEncryptor) Encrypt(plaintext []byte) ([]byte, error) {
	out := make([]byte, len(plaintext))
	copy(out, plaintext)
	return out, nil
}

func (n *NoopEncryptor) Decrypt(ciphertext []byte) ([]byte, error) {
	out := make([]byte, len(ciphertext))
	copy(out, ciphertext)
	return out, nil
}

func (n *NoopEncryptor) Hash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// NewEncryptorFromKeyString instantiates an Encryptor based on key configuration.
// If keyStr is empty, it returns a NoopEncryptor.
func NewEncryptorFromKeyString(keyStr string) (Encryptor, error) {
	if keyStr == "" {
		return NewNoopEncryptor(), nil
	}
	return NewAESGCMEncryptor([]byte(keyStr))
}
