// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
)

const (
	// PseudonymDomain is the version-pinned domain-separation label bound into every derived
	// pseudonym key, matching signal-ingest's pseudonym.Domain.
	PseudonymDomain = "signalloom/identity/alias-pseudonym/v1"

	// MinPseudonymKeyBytes is the minimum accepted root key material length (32 bytes = 256 bits).
	MinPseudonymKeyBytes = 32

	// HexPseudonymLen is the length of a hex-encoded HMAC-SHA256 pseudonym.
	HexPseudonymLen = 64

	// SegmentPseudonymKeyEnv holds hex-encoded root key material for domain/SNI pseudonymisation.
	// Matches the key material minted by scripts/signal-segment-key.sh and read by signal-ingest.
	SegmentPseudonymKeyEnv = "SIGNAL_SEGMENT_PSEUDONYM_KEY"

	// SegmentPseudonymEpochEnv holds the rotation epoch. Absent means epoch 0.
	SegmentPseudonymEpochEnv = "SIGNAL_SEGMENT_PSEUDONYM_EPOCH"
)

var (
	// ErrPseudonymKeyRequired is a fail-closed refusal when key material is missing or too short.
	ErrPseudonymKeyRequired = fmt.Errorf(
		"correlator: pseudonym root key is required; set %s to at least %d bytes of hex-encoded key material",
		SegmentPseudonymKeyEnv, MinPseudonymKeyBytes)

	// ErrPseudonymTenantRequired is returned when no tenant scope is supplied.
	ErrPseudonymTenantRequired = errors.New(
		"correlator: pseudonym tenant identifier is required; an empty tenant would merge tenant correlation domains")

	// ErrPseudonymValueRequired is returned when the value to pseudonymise is empty.
	ErrPseudonymValueRequired = errors.New("correlator: pseudonym input value is required")
)

// Pseudonymiser converts domain names and SNI values into keyed HMAC pseudonyms.
// It follows the exact same semantic contract as signal-ingest's actor pseudonymisation:
// deterministic per (tenant, epoch, value), scoped by tenant and key-rotation epoch,
// and refusing to run below 32 bytes of key material.
type Pseudonymiser struct {
	root  []byte
	epoch uint32

	// derived caches tenant keys so HKDF runs once per tenant.
	derived sync.Map // map[string][]byte
}

// NewPseudonymiser constructs a Pseudonymiser from raw root key material and epoch.
// It fails closed: absent or under-length key material is an error, never a degraded mode.
func NewPseudonymiser(root []byte, epoch uint32) (*Pseudonymiser, error) {
	if len(root) < MinPseudonymKeyBytes {
		return nil, ErrPseudonymKeyRequired
	}
	cp := make([]byte, len(root))
	copy(cp, root)
	return &Pseudonymiser{root: cp, epoch: epoch}, nil
}

// NewPseudonymiserFromEnv builds a Pseudonymiser from the environment variables
// SIGNAL_SEGMENT_PSEUDONYM_KEY and SIGNAL_SEGMENT_PSEUDONYM_EPOCH.
func NewPseudonymiserFromEnv() (*Pseudonymiser, error) {
	raw := os.Getenv(SegmentPseudonymKeyEnv)
	if raw == "" {
		return nil, ErrPseudonymKeyRequired
	}
	root, err := hex.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("correlator: %s must be hex-encoded: %w", SegmentPseudonymKeyEnv, err)
	}
	if len(root) < MinPseudonymKeyBytes {
		return nil, ErrPseudonymKeyRequired
	}

	var epoch uint32
	if rawEpoch := os.Getenv(SegmentPseudonymEpochEnv); rawEpoch != "" {
		parsed, parseErr := strconv.ParseUint(rawEpoch, 10, 32)
		if parseErr != nil {
			return nil, fmt.Errorf("correlator: %s must be a uint32: %w", SegmentPseudonymEpochEnv, parseErr)
		}
		epoch = uint32(parsed)
	}

	return NewPseudonymiser(root, epoch)
}

// Epoch returns the rotation epoch bound into every pseudonym this instance produces.
func (p *Pseudonymiser) Epoch() uint32 { return p.epoch }

func derivePseudonymInfo(epoch uint32, tenantID string) []byte {
	domain := []byte(PseudonymDomain)
	tenant := []byte(tenantID)

	info := make([]byte, 0, 4+len(domain)+4+4+len(tenant))
	info = binary.BigEndian.AppendUint32(info, uint32(len(domain)))
	info = append(info, domain...)
	info = binary.BigEndian.AppendUint32(info, epoch)
	info = binary.BigEndian.AppendUint32(info, uint32(len(tenant)))
	info = append(info, tenant...)
	return info
}

func (p *Pseudonymiser) tenantKey(tenantID string) ([]byte, error) {
	if cached, ok := p.derived.Load(tenantID); ok {
		return cached.([]byte), nil
	}
	key, err := hkdf.Key(sha256.New, p.root, nil, string(derivePseudonymInfo(p.epoch, tenantID)), 32)
	if err != nil {
		return nil, fmt.Errorf("correlator: pseudonym key derivation failed: %w", err)
	}
	actual, _ := p.derived.LoadOrStore(tenantID, key)
	return actual.([]byte), nil
}

// Pseudonym returns the hex-encoded, tenant-and-epoch-scoped HMAC-SHA256 pseudonym for value.
// An empty input returns ("", nil). An empty tenant returns ErrPseudonymTenantRequired.
func (p *Pseudonymiser) Pseudonym(tenantID, value string) (string, error) {
	if value == "" {
		return "", nil
	}
	if tenantID == "" {
		return "", ErrPseudonymTenantRequired
	}
	key, err := p.tenantKey(tenantID)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// IsPseudonym reports whether s has the exact shape of a pseudonym produced by this package:
// HexPseudonymLen lowercase hex characters.
func IsPseudonym(s string) bool {
	if len(s) != HexPseudonymLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return false
	}
	return true
}

var (
	defaultPseudonymiserMu sync.RWMutex
	defaultPseudonymiser   *Pseudonymiser
)

// SetDefaultPseudonymiser sets the package-level default pseudonymiser used by toIngest().
func SetDefaultPseudonymiser(p *Pseudonymiser) {
	defaultPseudonymiserMu.Lock()
	defer defaultPseudonymiserMu.Unlock()
	defaultPseudonymiser = p
}

// GetDefaultPseudonymiser returns the active default pseudonymiser, lazily loading from env if needed.
func GetDefaultPseudonymiser() *Pseudonymiser {
	defaultPseudonymiserMu.RLock()
	p := defaultPseudonymiser
	defaultPseudonymiserMu.RUnlock()
	if p != nil {
		return p
	}
	defaultPseudonymiserMu.Lock()
	defer defaultPseudonymiserMu.Unlock()
	if defaultPseudonymiser != nil {
		return defaultPseudonymiser
	}
	if fromEnv, err := NewPseudonymiserFromEnv(); err == nil {
		defaultPseudonymiser = fromEnv
		return fromEnv
	}
	return nil
}
