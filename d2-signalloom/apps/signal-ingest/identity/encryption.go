package identity

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strconv"
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
	// ErrInvalidEnvelope is returned when an envelope payload is malformed, truncated, or carries an unknown version.
	ErrInvalidEnvelope = errors.New("invalid envelope: malformed header, truncated payload, or unknown version")
)

// EnvelopeVersion is the current envelope wire-format version byte.
//
// Wire format: [version:1][wrappedDEKLen:2 BE][wrappedDEK][body].
// The wrapped data key and the body are each independently AES-256-GCM sealed, so a bit flip in
// either region fails its own authentication tag. The length prefix is fixed-width, so the header
// cannot be confused with body bytes.
const EnvelopeVersion byte = 0x01

// envelopeDEKBytes is the size of the per-record data encryption key.
const envelopeDEKBytes = 32

// envelopeHeaderBytes is the fixed header size: one version byte plus a uint16 length.
const envelopeHeaderBytes = 3

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

// Encryptor provides encryption-at-rest and keyed pseudonymisation for sensitive identity and
// delegation fields.
//
// There is deliberately no Hash(string) string method. An unkeyed digest over a small, guessable
// identifier population (corporate emails, usernames, SPIFFE IDs from a known namespace) inverts
// by rainbow table, and a signature returning a bare string has nowhere to report a missing key.
// Pseudonym carries a tenant scope and an error return for exactly those two reasons.
type Encryptor interface {
	Encrypt(plaintext []byte) ([]byte, error)
	Decrypt(ciphertext []byte) ([]byte, error)

	// Pseudonym returns a keyed, tenant-scoped, deterministic pseudonym for value.
	Pseudonym(tenantID, value string) (string, error)

	// EncryptEnvelope seals plaintext under a fresh per-record data key wrapped by the root key.
	//
	// aad is additional authenticated data bound into both GCM seals. It is not optional in
	// practice: without it an envelope is a free-floating blob that decrypts correctly in any
	// row, so an attacker with UPDATE can move ciphertext between rows and the pseudonym column
	// will disagree with the plaintext with nothing checking. Callers pass a value that names
	// the row and column the ciphertext belongs to.
	EncryptEnvelope(plaintext, aad []byte) ([]byte, error)
	// DecryptEnvelope unwraps and opens an envelope produced by EncryptEnvelope. The same aad
	// must be supplied or the authentication tag fails.
	DecryptEnvelope(envelope, aad []byte) ([]byte, error)
}

// AliasEnvelopeAAD builds the additional authenticated data binding an alias ciphertext to its
// row and column.
//
// The pseudonym is itself HMAC(tenantKey, aliasValue), so binding to it binds the ciphertext to
// the tenant AND to the plaintext simultaneously. Copying row A's ciphertext into row B therefore
// fails the GCM tag rather than decrypting into a value that silently disagrees with B's
// pseudonym. Every component is length-prefixed so the concatenation is unambiguous.
func AliasEnvelopeAAD(actorID, aliasType, pseudonym string) []byte {
	parts := []string{"aliases.alias_value_encrypted", actorID, aliasType, pseudonym}
	out := []byte{EnvelopeVersion}
	for _, p := range parts {
		out = binary.BigEndian.AppendUint32(out, uint32(len(p)))
		out = append(out, p...)
	}
	return out
}

// AESGCMEncryptor implements Encryptor using authenticated AES-256-GCM for encryption at rest and
// an HKDF-derived keyed HMAC for pseudonymisation.
type AESGCMEncryptor struct {
	key     [32]byte
	keyring *PseudonymKeyRing
}

// NewAESGCMEncryptor constructs an AES-256-GCM encryptor with a pseudonym key ring at epoch 0.
func NewAESGCMEncryptor(key []byte) (*AESGCMEncryptor, error) {
	return NewAESGCMEncryptorWithEpoch(key, 0)
}

// NewAESGCMEncryptorWithEpoch constructs an AES-256-GCM encryptor whose pseudonym key ring is
// derived from the same root as the encryption key.
//
// KEY-INDEPENDENCE CAVEAT, stated plainly because the alternative is a comforting half-truth.
// HKDF domain separation means the derived pseudonym key is not the AES key, so neither leaks
// through the other by accident. It does NOT make them independent: they share a root. Anyone
// holding IDENTITY_ENCRYPTION_KEY can re-derive every tenant's pseudonym key and brute-force the
// whole identifier space, which for corporate emails and SPIFFE IDs is small and enumerable.
//
// A KMS-backed deployment should therefore set IDENTITY_PSEUDONYM_KEY to a SEPARATE key, which
// NewEncryptorWithDevOptIn honours via NewAESGCMEncryptorWithKeys. This constructor is the
// single-key configuration and is the weaker of the two.
func NewAESGCMEncryptorWithEpoch(key []byte, epoch uint32) (*AESGCMEncryptor, error) {
	return NewAESGCMEncryptorWithKeys(key, nil, epoch)
}

// NewAESGCMEncryptorWithKeys constructs an encryptor with an explicitly separate pseudonym root.
//
// If pseudonymKey is nil the pseudonym ring falls back to the encryption root — see the
// key-independence caveat on NewAESGCMEncryptorWithEpoch. If pseudonymKey is supplied it is used
// verbatim when 32 bytes, and stretched with SHA-256 otherwise. That use of sha256.Sum256 is key
// derivation, not identifier hashing: it never touches an alias value.
func NewAESGCMEncryptorWithKeys(key, pseudonymKey []byte, epoch uint32) (*AESGCMEncryptor, error) {
	if len(key) == 0 {
		return nil, ErrInvalidKey
	}
	stretch := func(b []byte) [32]byte {
		var out [32]byte
		if len(b) == 32 {
			copy(out[:], b)
			return out
		}
		return sha256.Sum256(b)
	}

	k := stretch(key)
	root := k
	if len(pseudonymKey) > 0 {
		root = stretch(pseudonymKey)
	}

	ring, err := NewPseudonymKeyRing(root[:], epoch)
	if err != nil {
		return nil, fmt.Errorf("failed to derive pseudonym key ring: %w", err)
	}
	if len(pseudonymKey) == 0 {
		slog.Warn("identity pseudonym key is derived from IDENTITY_ENCRYPTION_KEY; " +
			"set IDENTITY_PSEUDONYM_KEY to a separate KMS key so that compromise of the encryption key " +
			"does not also expose the pseudonymisation key")
	}
	return &AESGCMEncryptor{key: k, keyring: ring}, nil
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

// Pseudonym returns the keyed, tenant-and-epoch-scoped pseudonym for value.
func (e *AESGCMEncryptor) Pseudonym(tenantID, value string) (string, error) {
	return e.keyring.Pseudonym(tenantID, value)
}

// PseudonymEpoch returns the rotation epoch bound into this encryptor's pseudonyms.
func (e *AESGCMEncryptor) PseudonymEpoch() uint32 { return e.keyring.Epoch() }

// sealAAD encrypts plaintext with the supplied key and additional authenticated data.
// It builds the AEAD directly rather than going through AESGCMEncryptor so that wrapping a data
// key does not also construct an unused pseudonym key ring per record.
func sealAAD(key, plaintext, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
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
	return gcm.Seal(nonce, nonce, plaintext, aad), nil
}

// openAAD is the inverse of sealAAD.
func openAAD(key, ciphertext, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("failed to create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}
	if len(ciphertext) < gcm.NonceSize() {
		return nil, ErrInvalidCiphertext
	}
	nonce, data := ciphertext[:gcm.NonceSize()], ciphertext[gcm.NonceSize():]
	out, err := gcm.Open(nil, nonce, data, aad)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidCiphertext, err)
	}
	return out, nil
}

// wrappedDEKLen is the exact length of a wrapped data key: 12-byte nonce + 32-byte key + 16-byte
// GCM tag. Pinning it turns the 16-bit length field from an attacker-controlled value with one
// legal setting into a checked constant, which removes the length-confusion class entirely.
const wrappedDEKLen = 12 + envelopeDEKBytes + 16

// EncryptEnvelope seals plaintext under a fresh random data key, which is itself sealed under the
// root key. Both seals bind aad, so an envelope only opens in the context it was created for.
// Two calls with identical plaintext produce different envelopes: the data key and both nonces
// are fresh.
func (e *AESGCMEncryptor) EncryptEnvelope(plaintext, aad []byte) ([]byte, error) {
	// envelopeDEKBytes is load-bearing: AES-256 needs exactly 32 bytes, and a shorter constant
	// would be silently SHA-256-stretched by the cipher constructors rather than rejected.
	if envelopeDEKBytes != 32 {
		return nil, fmt.Errorf("%w: envelopeDEKBytes must be 32 for AES-256", ErrInvalidEnvelope)
	}

	dek := make([]byte, envelopeDEKBytes)
	if _, err := io.ReadFull(rand.Reader, dek); err != nil {
		return nil, fmt.Errorf("failed to generate data key: %w", err)
	}

	wrapped, err := sealAAD(e.key[:], dek, aad)
	if err != nil {
		return nil, fmt.Errorf("failed to wrap data key: %w", err)
	}
	if len(wrapped) != wrappedDEKLen {
		return nil, fmt.Errorf("%w: wrapped data key is %d bytes, expected %d", ErrInvalidEnvelope, len(wrapped), wrappedDEKLen)
	}

	body, err := sealAAD(dek, plaintext, aad)
	if err != nil {
		return nil, fmt.Errorf("failed to seal envelope body: %w", err)
	}

	out := make([]byte, 0, envelopeHeaderBytes+len(wrapped)+len(body))
	out = append(out, EnvelopeVersion)
	out = binary.BigEndian.AppendUint16(out, uint16(len(wrapped)))
	out = append(out, wrapped...)
	out = append(out, body...)
	return out, nil
}

// DecryptEnvelope unwraps the data key and opens the body. A tampered wrapped key, a tampered
// body, a truncated payload, an unrecognised version byte, a wrong length field, or a mismatched
// aad all fail closed with ErrInvalidEnvelope.
//
// Every failure path returns the same error class deliberately. Returning ErrInvalidEnvelope for
// header faults and ErrInvalidCiphertext for body faults would let a caller that checks only one
// of them miss the other — and body tampering is the likelier attack.
func (e *AESGCMEncryptor) DecryptEnvelope(envelope, aad []byte) ([]byte, error) {
	if len(envelope) < envelopeHeaderBytes {
		return nil, ErrInvalidEnvelope
	}
	if envelope[0] != EnvelopeVersion {
		return nil, fmt.Errorf("%w: version 0x%02x", ErrInvalidEnvelope, envelope[0])
	}
	wrappedLen := int(binary.BigEndian.Uint16(envelope[1:envelopeHeaderBytes]))
	if wrappedLen != wrappedDEKLen {
		return nil, fmt.Errorf("%w: wrapped key length %d, expected %d", ErrInvalidEnvelope, wrappedLen, wrappedDEKLen)
	}
	if len(envelope) <= envelopeHeaderBytes+wrappedLen {
		return nil, ErrInvalidEnvelope
	}

	wrapped := envelope[envelopeHeaderBytes : envelopeHeaderBytes+wrappedLen]
	body := envelope[envelopeHeaderBytes+wrappedLen:]

	dek, err := openAAD(e.key[:], wrapped, aad)
	if err != nil {
		return nil, fmt.Errorf("%w: data key unwrap failed: %v", ErrInvalidEnvelope, err)
	}
	plaintext, err := openAAD(dek, body, aad)
	if err != nil {
		return nil, fmt.Errorf("%w: body open failed: %v", ErrInvalidEnvelope, err)
	}
	return plaintext, nil
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
//
// Development mode weakens encryption at rest. It does NOT weaken pseudonymisation: the
// NoopEncryptor still computes real keyed HMAC pseudonyms, from an ephemeral per-process random
// key. That choice is deliberate. A passthrough pseudonym would be an unkeyed digest — exactly
// the defect this package was changed to remove — and a developer would have no way to tell the
// two apart by looking at a value. The ephemeral key means dev pseudonyms do not survive a
// restart, which is the honest signal that dev mode is not a persistence mode.
type NoopEncryptor struct {
	stopCh  chan struct{}
	mu      sync.Mutex
	closed  bool
	keyring *PseudonymKeyRing
}

// ephemeralKeyRing mints a per-process random pseudonym key ring for development mode.
// A failure of the system CSPRNG is unrecoverable and must not degrade to a weaker mode.
func ephemeralKeyRing() *PseudonymKeyRing {
	seed := make([]byte, MinPseudonymRootKeyBytes)
	if _, err := io.ReadFull(rand.Reader, seed); err != nil {
		panic(fmt.Sprintf("identity: system CSPRNG unavailable, refusing to pseudonymise: %v", err))
	}
	ring, err := NewPseudonymKeyRing(seed, 0)
	if err != nil {
		panic(fmt.Sprintf("identity: ephemeral pseudonym key ring rejected: %v", err))
	}
	return ring
}

// NewNoopEncryptor creates a NoopEncryptor and initiates a persistent warning loop.
func NewNoopEncryptor() *NoopEncryptor {
	n := &NoopEncryptor{
		stopCh:  make(chan struct{}),
		keyring: ephemeralKeyRing(),
	}
	n.startWarningLoop(30 * time.Second)
	return n
}

// NewNoopEncryptorWithInterval creates a NoopEncryptor with a custom warning interval.
func NewNoopEncryptorWithInterval(interval time.Duration) *NoopEncryptor {
	n := &NoopEncryptor{
		stopCh:  make(chan struct{}),
		keyring: ephemeralKeyRing(),
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

// Pseudonym computes a real keyed pseudonym even in development mode. See the NoopEncryptor
// doc comment for why passthrough is not offered here.
func (n *NoopEncryptor) Pseudonym(tenantID, value string) (string, error) {
	return n.keyring.Pseudonym(tenantID, value)
}

// EncryptEnvelope passes plaintext through unchanged in development mode.
func (n *NoopEncryptor) EncryptEnvelope(plaintext, _ []byte) ([]byte, error) {
	return n.Encrypt(plaintext)
}

// DecryptEnvelope passes ciphertext through unchanged in development mode, but refuses anything
// that looks like a real envelope.
//
// Without that refusal a dev-mode process reading production data would return the raw envelope
// bytes as the "alias value" — binary garbage with a 0x01 prefix — with exit 0 and no error. A
// wrong answer that reports success is worse than a failure.
func (n *NoopEncryptor) DecryptEnvelope(envelope, _ []byte) ([]byte, error) {
	if len(envelope) >= envelopeHeaderBytes && envelope[0] == EnvelopeVersion &&
		int(binary.BigEndian.Uint16(envelope[1:envelopeHeaderBytes])) == wrappedDEKLen {
		return nil, fmt.Errorf("%w: NoopEncryptor cannot open a real AES-GCM envelope; this process has no key", ErrInvalidEnvelope)
	}
	return n.Decrypt(envelope)
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
// The pseudonym rotation epoch is read from IDENTITY_PSEUDONYM_EPOCH, defaulting to 0.
func NewEncryptorWithDevOptIn(keyStr string, allowNoop bool) (Encryptor, error) {
	if keyStr == "" {
		if allowNoop {
			return NewNoopEncryptor(), nil
		}
		return nil, fmt.Errorf("%w (set IDENTITY_ENCRYPTION_KEY or explicitly opt-in with INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true)", ErrNoopEncryptionNotAllowed)
	}
	epoch, err := PseudonymEpochFromEnv()
	if err != nil {
		return nil, err
	}
	return NewAESGCMEncryptorWithKeys([]byte(keyStr), []byte(os.Getenv("IDENTITY_PSEUDONYM_KEY")), epoch)
}

// PseudonymEpochFromEnv reads the pseudonym rotation epoch from IDENTITY_PSEUDONYM_EPOCH.
//
// An unset variable means epoch 0. A set-but-unparseable variable is an error, not a silent
// fallback to 0: silently reverting to epoch 0 after a rotation would resurrect every
// pre-rotation pseudonym, which is precisely the failure rotation exists to prevent.
func PseudonymEpochFromEnv() (uint32, error) {
	raw := os.Getenv("IDENTITY_PSEUDONYM_EPOCH")
	if raw == "" {
		return 0, nil
	}
	v, err := strconv.ParseUint(raw, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("identity: IDENTITY_PSEUDONYM_EPOCH=%q is not a uint32: %w", raw, err)
	}
	return uint32(v), nil
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
