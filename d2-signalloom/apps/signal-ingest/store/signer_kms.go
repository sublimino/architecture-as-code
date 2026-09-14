package store

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

var (
	ErrKMSKeyDisabled    = errors.New("kms: key version is disabled")
	ErrKMSKeyDestroyed   = errors.New("kms: key version is destroyed")
	ErrKMSRateLimited    = errors.New("kms: rate limit / quota exceeded (429)")
	ErrKMSUnavailable    = errors.New("kms: service temporarily unavailable (503)")
	ErrKMSKeyNotFound    = errors.New("kms: key version not found")
	ErrKMSNotConfigured  = errors.New("kms: client or key reference not configured")
)

// KMSClient defines the interface required to interact with an asymmetric Cloud KMS service.
type KMSClient interface {
	// GetPublicKey retrieves the public verification key for the specified KMS key version.
	GetPublicKey(ctx context.Context, keyVersion string) (crypto.PublicKey, error)

	// AsymmetricSign signs a precomputed digest using the designated non-exportable KMS key version.
	AsymmetricSign(ctx context.Context, keyVersion string, digest []byte, algorithm string) ([]byte, error)

	// KeyStatus returns the operational state of the key version (e.g. "ENABLED", "DISABLED", "DESTROYED").
	KeyStatus(ctx context.Context, keyVersion string) (string, error)
}

// KMSSignerConfig holds configuration for initializing a KMSSigner.
type KMSSignerConfig struct {
	Client      KMSClient
	KeyVersion  string
	Algorithm   string
	RateLimiter RateLimiter
	RetryConfig RetryConfig
}

// KMSSigner implements Signer for non-exportable hardware/cloud KMS keys.
// Key material is never present in the local process memory.
type KMSSigner struct {
	client      KMSClient
	keyVersion  string
	algorithm   string
	publicKey   crypto.PublicKey
	keyID       string
	rateLimiter RateLimiter
	retryConfig RetryConfig
	mu          sync.RWMutex
}

// NewKMSSigner initializes a new KMSSigner by resolving the public key and canonical key ID from KMS.
func NewKMSSigner(ctx context.Context, cfg KMSSignerConfig) (*KMSSigner, error) {
	if cfg.Client == nil {
		return nil, ErrKMSNotConfigured
	}
	if strings.TrimSpace(cfg.KeyVersion) == "" {
		return nil, errors.New("kms: key version identifier must not be empty")
	}
	status, err := cfg.Client.KeyStatus(ctx, cfg.KeyVersion)
	if err != nil {
		return nil, fmt.Errorf("kms: inspect key version status: %w", err)
	}
	if status == "DESTROYED" {
		return nil, ErrKMSKeyDestroyed
	}
	if status == "DISABLED" {
		return nil, ErrKMSKeyDisabled
	}
	pub, err := cfg.Client.GetPublicKey(ctx, cfg.KeyVersion)
	if err != nil {
		return nil, fmt.Errorf("kms: fetch public key for %s: %w", cfg.KeyVersion, err)
	}
	keyID, err := DeriveKeyID(pub)
	if err != nil {
		return nil, fmt.Errorf("kms: derive canonical key ID: %w", err)
	}
	algo := cfg.Algorithm
	if algo == "" {
		switch pub.(type) {
		case ed25519.PublicKey:
			algo = "ed25519"
		case *ecdsa.PublicKey:
			algo = "ecdsa-p256-sha256"
		case *rsa.PublicKey:
			algo = "rsa-pss-2048-sha256"
		default:
			algo = "ecdsa-p256-sha256"
		}
	}
	limiter := cfg.RateLimiter
	if limiter == nil {
		limiter = NewTokenBucket(100.0, 20)
	}
	retry := cfg.RetryConfig
	if retry.MaxRetries <= 0 {
		retry = DefaultRetryConfig()
	}
	return &KMSSigner{
		client:      cfg.Client,
		keyVersion:  cfg.KeyVersion,
		algorithm:   algo,
		publicKey:   pub,
		keyID:       keyID,
		rateLimiter: limiter,
		retryConfig: retry,
	}, nil
}

func (s *KMSSigner) KeyID() string               { return s.keyID }
func (s *KMSSigner) KeyVersion() string          { return s.keyVersion }
func (s *KMSSigner) PublicKey() crypto.PublicKey { return s.publicKey }
func (s *KMSSigner) Algorithm() string           { return s.algorithm }

// Sign formats the statement as canonical DSSE, generates the PAE digest,
// acquires a rate-limiting token, and invokes remote KMS signing with bounded exponential retry.
func (s *KMSSigner) Sign(ctx context.Context, statement map[string]any) ([]byte, error) {
	if ctx != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	payload, err := dsseMarshalStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal statement for KMS sign: %w", err)
	}
	pae := dssePAE(dssePayloadType, payload)
	digest := s.computeDigest(pae)

	// Rate limiting: respect QPS quota
	if s.rateLimiter != nil {
		if err := s.rateLimiter.Wait(ctx); err != nil {
			return nil, fmt.Errorf("kms rate limiter wait: %w", err)
		}
	}

	var signature []byte
	maxAttempts := s.retryConfig.MaxRetries
	if maxAttempts <= 0 {
		maxAttempts = 1
	}

	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		if ctx != nil && ctx.Err() != nil {
			return nil, ctx.Err()
		}
		signature, lastErr = s.client.AsymmetricSign(ctx, s.keyVersion, digest, s.algorithm)
		if lastErr == nil {
			return FormatDSSE(statement, s.keyID, signature)
		}
		if !isKMSRetryable(lastErr) {
			return nil, fmt.Errorf("kms sign non-retryable error: %w", lastErr)
		}
		// Calculate exponential backoff with jitter
		if attempt < maxAttempts-1 {
			waitDur := s.retryConfig.BackoffForAttempt(attempt)
			select {
			case <-time.After(waitDur):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
	}
	return nil, fmt.Errorf("kms sign exceeded %d retries; last error: %w", maxAttempts, lastErr)
}

func (s *KMSSigner) computeDigest(pae []byte) []byte {
	switch {
	case strings.Contains(s.algorithm, "p384") || strings.Contains(s.algorithm, "sha384"):
		h := sha512.Sum384(pae)
		return h[:]
	case strings.Contains(s.algorithm, "p521") || strings.Contains(s.algorithm, "sha512"):
		h := sha512.Sum512(pae)
		return h[:]
	case strings.Contains(s.algorithm, "ed25519"):
		// Ed25519 can sign raw PAE or SHA-512
		return pae
	default:
		h := sha256.Sum256(pae)
		return h[:]
	}
}

func isKMSRetryable(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, ErrKMSKeyDisabled) || errors.Is(err, ErrKMSKeyDestroyed) || errors.Is(err, ErrKMSKeyNotFound) {
		return false
	}
	if errors.Is(err, ErrKMSRateLimited) || errors.Is(err, ErrKMSUnavailable) {
		return true
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "429") || strings.Contains(msg, "quota") || strings.Contains(msg, "rate limit") ||
		strings.Contains(msg, "503") || strings.Contains(msg, "unavailable") || strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "temporary") || strings.Contains(msg, "timeout") {
		return true
	}
	return false
}

// MockKMSClient implements a full in-memory KMSClient for tests, simulations, and unit verification.
type MockKMSClient struct {
	mu           sync.RWMutex
	keys         map[string]*mockKeyRecord
	transientErr error
	transientN   int
	latency      time.Duration
}

type mockKeyRecord struct {
	privateKey crypto.PrivateKey
	publicKey  crypto.PublicKey
	algorithm  string
	status     string // "ENABLED", "DISABLED", "DESTROYED"
}

// NewMockKMSClient creates an empty MockKMSClient.
func NewMockKMSClient() *MockKMSClient {
	return &MockKMSClient{
		keys: make(map[string]*mockKeyRecord),
	}
}

// AddKey registers a key version in the mock KMS.
func (m *MockKMSClient) AddKey(keyVersion string, priv crypto.PrivateKey, algorithm string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	var pub crypto.PublicKey
	switch k := priv.(type) {
	case ed25519.PrivateKey:
		pub = k.Public()
	case *ecdsa.PrivateKey:
		pub = &k.PublicKey
	case *rsa.PrivateKey:
		pub = &k.PublicKey
	default:
		return fmt.Errorf("unsupported key type %T", priv)
	}
	m.keys[keyVersion] = &mockKeyRecord{
		privateKey: priv,
		publicKey:  pub,
		algorithm:  algorithm,
		status:     "ENABLED",
	}
	return nil
}

// SetStatus updates the operational state of a key version ("ENABLED", "DISABLED", "DESTROYED").
func (m *MockKMSClient) SetStatus(keyVersion string, status string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	rec, ok := m.keys[keyVersion]
	if !ok {
		return ErrKMSKeyNotFound
	}
	rec.status = status
	if status == "DESTROYED" {
		// destroy private key material while leaving record
		rec.privateKey = nil
	}
	return nil
}

// SetTransientErrors configures the mock KMS to return an error for the next N calls before succeeding.
func (m *MockKMSClient) SetTransientErrors(n int, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.transientN = n
	m.transientErr = err
}

// SetLatency injects a simulated network delay into KMS operations.
func (m *MockKMSClient) SetLatency(d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.latency = d
}

func (m *MockKMSClient) GetPublicKey(ctx context.Context, keyVersion string) (crypto.PublicKey, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.latency > 0 {
		time.Sleep(m.latency)
	}
	rec, ok := m.keys[keyVersion]
	if !ok {
		return nil, ErrKMSKeyNotFound
	}
	if rec.status == "DESTROYED" {
		// Public key can still be retained or fetched for verification, but if destroyed in KMS:
		return rec.publicKey, nil
	}
	return rec.publicKey, nil
}

func (m *MockKMSClient) KeyStatus(ctx context.Context, keyVersion string) (string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	rec, ok := m.keys[keyVersion]
	if !ok {
		return "", ErrKMSKeyNotFound
	}
	return rec.status, nil
}

func (m *MockKMSClient) AsymmetricSign(ctx context.Context, keyVersion string, digest []byte, algorithm string) ([]byte, error) {
	m.mu.Lock()
	if m.latency > 0 {
		time.Sleep(m.latency)
	}
	if m.transientN > 0 {
		m.transientN--
		err := m.transientErr
		if err == nil {
			err = ErrKMSRateLimited
		}
		m.mu.Unlock()
		return nil, err
	}
	rec, ok := m.keys[keyVersion]
	m.mu.Unlock()

	if !ok {
		return nil, ErrKMSKeyNotFound
	}
	if rec.status == "DISABLED" {
		return nil, ErrKMSKeyDisabled
	}
	if rec.status == "DESTROYED" || rec.privateKey == nil {
		return nil, ErrKMSKeyDestroyed
	}

	switch k := rec.privateKey.(type) {
	case ed25519.PrivateKey:
		return ed25519.Sign(k, digest), nil
	case *ecdsa.PrivateKey:
		return ecdsa.SignASN1(rand.Reader, k, digest)
	case *rsa.PrivateKey:
		return rsa.SignPSS(rand.Reader, k, crypto.SHA256, digest, nil)
	default:
		return nil, fmt.Errorf("unsupported key type %T", rec.privateKey)
	}
}
