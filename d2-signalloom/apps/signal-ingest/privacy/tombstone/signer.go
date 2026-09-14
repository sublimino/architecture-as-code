package tombstone

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
)

// Attestation plane constants. These mirror store/segment_attestor.go exactly, because a tombstone
// that needed a second DSSE dialect would need a second verifier, and two verifiers is one more
// place for the accepting one to be used by mistake.
const (
	dssePayloadType      = "application/vnd.in-toto+json"
	inTotoStatementType  = "https://in-toto.io/Statement/v1"
	tombstonePredicate   = "https://controlplane.io/attestations/signalloom-tombstone/v1"
	tombstoneSubjectName = "signalloom.tombstone"
)

var (
	// ErrNotEd25519 is returned when the configured signing key is not Ed25519.
	ErrNotEd25519 = errors.New("tombstone signing key is not Ed25519")

	// ErrSignatureInvalid is returned when an envelope fails verification.
	ErrSignatureInvalid = errors.New("tombstone attestation signature is invalid")

	// ErrKeyIDMismatch is returned when an envelope's keyid does not name the verifying key.
	//
	// It is distinct from ErrSignatureInvalid on purpose: "signed by a key I do not recognise" and
	// "signed by the right key over different bytes" are different incidents, and collapsing them
	// into one error makes the first read as tampering and the second read as key rotation.
	ErrKeyIDMismatch = errors.New("tombstone attestation keyid does not match the verifying key")

	// ErrUnsignableDocument is returned when a document fails the allow-list check at sign time.
	ErrUnsignableDocument = errors.New("refusing to sign a tombstone document that fails the field allow-list")
)

// DSSESignature is one signature over a DSSE payload.
type DSSESignature struct {
	KeyID string `json:"keyid"`
	Sig   string `json:"sig"`
}

// DSSEEnvelope is the signed wrapper. Shape matches store/segment_attestor.go.
type DSSEEnvelope struct {
	PayloadType string          `json:"payloadType"`
	Payload     string          `json:"payload"`
	Signatures  []DSSESignature `json:"signatures"`
}

// TombstoneSigner holds the authority to publish tombstones.
//
// # Signing authority
//
// Exactly one role may sign a tombstone: the Signal Loom evidence-plane signing identity, holding
// the Ed25519 key named by SIGNAL_TOMBSTONE_KEY. That authority is deliberately NOT the same
// identity as the dual-operator erasure-override registry (privacy.OperatorRegistry): operators
// authorise an erasure, the platform attests that it happened, and one key doing both would mean a
// single compromised operator could both grant themselves an override and mint the evidence that
// it was granted properly.
//
// It SHOULD also be a distinct key from the segment attestor's, even though the envelope format is
// identical, because the two statements have different meanings and different blast radii: a
// segment attestation says "these bytes were ingested", a tombstone says "this data is gone". A
// deployment that reuses one key for both is supported — the format is the same — but it loses the
// ability to revoke one claim class without invalidating the other, and that is a decision to take
// knowingly rather than by default.
//
// # What the signature does and does not prove
//
// It proves custody of the signing key at some point. It does not prove when, and it does not
// prove the erasure happened, because there is no external transparency anchor: Rekor is refused
// at apps/fe-signalloom/src/audit_anchor/anchor.py:407 and Archivista publication is optional. A
// holder of this key can mint a tombstone for an erasure that never occurred, or backdate one to
// any ErasedDay, and nothing outside the deployment can detect either. Forgery is detectable today
// only by parties inside the deployment comparing against the erasure audit trail — which is to
// say, by the same party that would have forged it.
//
// See docs/signalloom/tombstone-signing-authority.md.
type TombstoneSigner struct {
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	keyID      string
}

// TombstoneKeyEnvVar names the environment variable carrying the signing key path.
const TombstoneKeyEnvVar = "SIGNAL_TOMBSTONE_KEY"

// NewTombstoneSignerFromPEM builds a signer from PKCS#8 PEM bytes.
func NewTombstoneSignerFromPEM(raw []byte) (*TombstoneSigner, error) {
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("parse tombstone signing key: no PEM block")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse tombstone signing key: %w", err)
	}
	priv, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%w: got %T", ErrNotEd25519, parsed)
	}
	pub := priv.Public().(ed25519.PublicKey)
	spki, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return nil, fmt.Errorf("marshal tombstone public key: %w", err)
	}
	digest := sha256.Sum256(spki)
	return &TombstoneSigner{privateKey: priv, publicKey: pub, keyID: hex.EncodeToString(digest[:])}, nil
}

// NewTombstoneSigner builds a signer from a PKCS#8 PEM file.
func NewTombstoneSigner(path string) (*TombstoneSigner, error) {
	if path == "" {
		return nil, fmt.Errorf("tombstone signing key path is empty: set %s", TombstoneKeyEnvVar)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read tombstone signing key %s: %w", path, err)
	}
	return NewTombstoneSignerFromPEM(raw)
}

// KeyID returns the hex SHA-256 of the PKIX SPKI, the same key identifier rule the segment
// attestor uses.
func (s *TombstoneSigner) KeyID() string { return s.keyID }

// PublicKey returns the verification key.
func (s *TombstoneSigner) PublicKey() ed25519.PublicKey { return s.publicKey }

// Statement builds the in-toto statement for a tombstone.
//
// subject[0].name is the tombstone id — a random value — and never the data subject. The word
// "subject" means two unrelated things in in-toto and in GDPR, and that collision is exactly the
// kind of thing that puts a person's identifier into an attestation by accident.
func Statement(t Tombstone) (map[string]any, error) {
	if err := t.Validate(); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrUnsignableDocument, err)
	}
	raw, err := json.Marshal(t)
	if err != nil {
		return nil, fmt.Errorf("marshal tombstone: %w", err)
	}
	if err := ValidateDocument(raw); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrUnsignableDocument, err)
	}
	var predicate map[string]any
	if err := json.Unmarshal(raw, &predicate); err != nil {
		return nil, fmt.Errorf("re-read tombstone document: %w", err)
	}
	digest := sha256.Sum256(raw)
	return map[string]any{
		"_type": inTotoStatementType,
		"subject": []any{map[string]any{
			"name":   tombstoneSubjectName + "/" + t.TombstoneID,
			"digest": map[string]any{"sha256": hex.EncodeToString(digest[:])},
		}},
		"predicateType": tombstonePredicate,
		"predicate":     predicate,
	}, nil
}

// Sign produces a DSSE envelope over the tombstone's in-toto statement.
//
// The allow-list check inside Statement runs before any signature is produced, so signing cannot
// launder a forbidden field into attested evidence — which matters because an attested document is
// precisely the thing nobody is allowed to rewrite afterwards.
func (s *TombstoneSigner) Sign(t Tombstone) ([]byte, error) {
	statement, err := Statement(t)
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal tombstone statement: %w", err)
	}
	sig := ed25519.Sign(s.privateKey, dssePAE(dssePayloadType, payload))
	return json.Marshal(DSSEEnvelope{
		PayloadType: dssePayloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures: []DSSESignature{{
			KeyID: s.keyID,
			Sig:   base64.StdEncoding.EncodeToString(sig),
		}},
	})
}

// dssePAE is the DSSE Pre-Authentication Encoding, byte-identical to the segment attestor's.
func dssePAE(payloadType string, payload []byte) []byte {
	return []byte(fmt.Sprintf("DSSEv1 %d %s %d %s", len([]byte(payloadType)), payloadType, len(payload), payload))
}

// VerifyEnvelope checks an envelope against a public key and returns the embedded tombstone.
//
// It re-runs ValidateDocument on the verified predicate. Verifying the signature and then trusting
// the contents would mean a tombstone minted by an older or patched build could carry a forbidden
// field into a reader that believed the allow-list had already been enforced upstream.
func VerifyEnvelope(raw []byte, pub ed25519.PublicKey, expectKeyID string) (Tombstone, error) {
	var env DSSEEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return Tombstone{}, fmt.Errorf("parse DSSE envelope: %w", err)
	}
	if env.PayloadType != dssePayloadType {
		return Tombstone{}, fmt.Errorf("%w: payloadType %q", ErrSignatureInvalid, env.PayloadType)
	}
	if len(env.Signatures) != 1 {
		return Tombstone{}, fmt.Errorf("%w: %d signatures, want exactly 1", ErrSignatureInvalid, len(env.Signatures))
	}
	if expectKeyID != "" && env.Signatures[0].KeyID != expectKeyID {
		return Tombstone{}, fmt.Errorf("%w: envelope names %q, verifying with %q",
			ErrKeyIDMismatch, env.Signatures[0].KeyID, expectKeyID)
	}
	payload, err := base64.StdEncoding.DecodeString(env.Payload)
	if err != nil {
		return Tombstone{}, fmt.Errorf("%w: payload is not base64: %v", ErrSignatureInvalid, err)
	}
	sig, err := base64.StdEncoding.DecodeString(env.Signatures[0].Sig)
	if err != nil {
		return Tombstone{}, fmt.Errorf("%w: signature is not base64: %v", ErrSignatureInvalid, err)
	}
	if !ed25519.Verify(pub, dssePAE(env.PayloadType, payload), sig) {
		return Tombstone{}, ErrSignatureInvalid
	}
	var statement struct {
		Type          string          `json:"_type"`
		PredicateType string          `json:"predicateType"`
		Predicate     json.RawMessage `json:"predicate"`
	}
	if err := json.Unmarshal(payload, &statement); err != nil {
		return Tombstone{}, fmt.Errorf("parse in-toto statement: %w", err)
	}
	if statement.Type != inTotoStatementType {
		return Tombstone{}, fmt.Errorf("%w: statement _type %q", ErrSignatureInvalid, statement.Type)
	}
	if statement.PredicateType != tombstonePredicate {
		return Tombstone{}, fmt.Errorf("%w: predicateType %q", ErrSignatureInvalid, statement.PredicateType)
	}
	if err := ValidateDocument(statement.Predicate); err != nil {
		return Tombstone{}, fmt.Errorf("verified envelope carries an invalid tombstone: %w", err)
	}
	var t Tombstone
	if err := json.Unmarshal(statement.Predicate, &t); err != nil {
		return Tombstone{}, fmt.Errorf("parse tombstone predicate: %w", err)
	}
	if err := t.Validate(); err != nil {
		return Tombstone{}, fmt.Errorf("verified envelope carries an invalid tombstone: %w", err)
	}
	return t, nil
}
