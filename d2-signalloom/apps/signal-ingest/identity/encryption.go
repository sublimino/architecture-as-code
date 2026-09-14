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
	"log/slog"
	"os"
	"sync"
	"time"
)

var (
	// ErrInvalidCiphertext is returned when ciphertext is malformed or tampering is detected.
	ErrInvalidCiphertext = errors.New("invalid ciphertext: payload too short or authentication tag mismatch")
	// ErrInvalidKey is returned when the encryption key length is invalid.
	ErrInvalidKey = errors.New("invalid encryption key: must be non-empty")
	// ErrNoopEncryptionNotAllowed is returned when encryption is unconfigured and development mode is not explicitly enabled.
	ErrNoopEncryptionNotAllowed = errors.New("identity encryption key is missing or empty; passthrough NoopEncryptor is refused in production mode")
)

// DevOptInEnvVars lists the accepted environment variables for enabling insecure development passthrough.
var DevOptInEnvVars = []string{
	"INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR",
	"IDENTITY_ALLOW_NOOP_ENCRYPTOR",
	"SIGNAL_INGEST_ALLOW_NOOP_ENCRYPTOR",
}

// DevOptInAllowed checks if explicit development passthrough has been opted into via environment.
func DevOptInAllowed() bool {
	for _, env := range DevOptInEnvVars {
		val := os.Getenv(env)
		if val == "true" || val == "1" || val == "yes" {
			return true
		}
	}
	return false
}

// EncryptionPosture captures the runtime encryption state for health reporting.
type EncryptionPosture struct {
	Algorithm string `json:"algorithm"`
	Mode      string `json:"mode"`
	DevOptIn  bool   `json:"dev_opt_in"`
	Healthy   bool   `json:"healthy"`
}

// PostureAware is implemented by encryptors that can report their posture.
type PostureAware interface {
	Posture() EncryptionPosture
}

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

// Posture returns the security posture of the AESGCMEncryptor.
func (e *AESGCMEncryptor) Posture() EncryptionPosture {
	return EncryptionPosture{
		Algorithm: "AES-256-GCM",
		Mode:      "enforced",
		DevOptIn:  false,
		Healthy:   true,
	}
}

// NoopEncryptor is an unencrypted passthrough Encryptor gated behind explicit development opt-in.
// It emits persistent warnings throughout its lifecycle.
type NoopEncryptor struct {
	stopCh chan struct{}
	mu     sync.Mutex
	closed bool
}

// NewNoopEncryptor creates a NoopEncryptor and initiates a persistent warning loop.
func NewNoopEncryptor() *NoopEncryptor {
	n := &NoopEncryptor{
		stopCh: make(chan struct{}),
	}
	n.startWarningLoop(30 * time.Second)
	return n
}

// NewNoopEncryptorWithInterval creates a NoopEncryptor with a custom warning interval.
func NewNoopEncryptorWithInterval(interval time.Duration) *NoopEncryptor {
	n := &NoopEncryptor{
		stopCh: make(chan struct{}),
	}
	n.startWarningLoop(interval)
	return n
}

func (n *NoopEncryptor) startWarningLoop(interval time.Duration) {
	slog.Warn("SECURITY WARNING: running in development mode with NoopEncryptor (insecure passthrough encryption); identity graph data is NOT encrypted at rest")
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-n.stopCh:
				return
			case <-ticker.C:
				slog.Warn("SECURITY WARNING: running in development mode with NoopEncryptor (insecure passthrough encryption); identity graph data is NOT encrypted at rest")
			}
		}
	}()
}

// Stop terminates the periodic warning loop.
func (n *NoopEncryptor) Stop() {
	n.mu.Lock()
	defer n.mu.Unlock()
	if !n.closed {
		n.closed = true
		close(n.stopCh)
	}
}

// Close satisfies io.Closer by stopping the warning loop.
func (n *NoopEncryptor) Close() error {
	n.Stop()
	return nil
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

// Posture returns the security posture of the NoopEncryptor.
func (n *NoopEncryptor) Posture() EncryptionPosture {
	return EncryptionPosture{
		Algorithm: "NOOP-PASSTHROUGH",
		Mode:      "passthrough_insecure",
		DevOptIn:  true,
		Healthy:   false,
	}
}

// NewEncryptorFromKeyString instantiates an Encryptor based on key configuration.
// If keyStr is empty, it fails closed with an error unless an explicit development opt-in
// environment variable (such as INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true) is set.
func NewEncryptorFromKeyString(keyStr string) (Encryptor, error) {
	return NewEncryptorWithDevOptIn(keyStr, DevOptInAllowed())
}

// NewEncryptorWithDevOptIn instantiates an Encryptor with an explicit dev opt-in flag.
func NewEncryptorWithDevOptIn(keyStr string, allowNoop bool) (Encryptor, error) {
	if keyStr == "" {
		if allowNoop {
			return NewNoopEncryptor(), nil
		}
		return nil, fmt.Errorf("%w (set IDENTITY_ENCRYPTION_KEY or explicitly opt-in with INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true)", ErrNoopEncryptionNotAllowed)
	}
	return NewAESGCMEncryptor([]byte(keyStr))
}

// GetEncryptionPosture inspects any Encryptor and returns its effective security posture.
func GetEncryptionPosture(enc Encryptor) EncryptionPosture {
	if enc == nil {
		return EncryptionPosture{
			Algorithm: "NONE",
			Mode:      "unconfigured",
			DevOptIn:  false,
			Healthy:   false,
		}
	}
	if pa, ok := enc.(PostureAware); ok {
		return pa.Posture()
	}
	return EncryptionPosture{
		Algorithm: "CUSTOM",
		Mode:      "enforced",
		DevOptIn:  false,
		Healthy:   true,
	}
}
