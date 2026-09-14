package store

import (
	"context"
	"crypto"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// Signer abstracts signing DSSE attestation envelopes across local key files
// and remote non-exportable hardware/cloud KMS keys (e.g. Cloud KMS, AWS KMS, Vault).
// The call site never touches raw private key material.
type Signer interface {
	// KeyID returns the SPKI SHA-256 hex digest identifier of the public key.
	// This matches Signal Loom's canonical key ID derivation: hex(sha256(MarshalPKIXPublicKey(pub))).
	KeyID() string

	// KeyVersion returns the immutable key version identifier
	// (e.g. "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1" or "v1").
	KeyVersion() string

	// PublicKey returns the crypto.PublicKey corresponding to the signing key.
	PublicKey() crypto.PublicKey

	// Algorithm returns the signing algorithm identifier (e.g. "ed25519", "ecdsa-p256-sha256", "rsa-pss-2048-sha256").
	Algorithm() string

	// Sign receives an in-toto statement payload and returns the marshaled DSSE envelope bytes.
	// Implementations handle PAE formatting, hashing, signature generation, rate-limiting, and bounded retries.
	Sign(ctx context.Context, statement map[string]any) ([]byte, error)
}

// DeriveKeyID calculates the canonical SPKI SHA-256 hex digest for a public key.
func DeriveKeyID(pub crypto.PublicKey) (string, error) {
	if pub == nil {
		return "", errors.New("cannot derive key ID from nil public key")
	}
	spki, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return "", fmt.Errorf("marshal PKIX public key: %w", err)
	}
	digest := sha256.Sum256(spki)
	return hex.EncodeToString(digest[:]), nil
}

// FormatDSSE builds a canonical DSSE envelope from a statement and signature.
func FormatDSSE(statement map[string]any, keyID string, signature []byte) ([]byte, error) {
	payload, err := json.Marshal(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal signed statement: %w", err)
	}
	return json.Marshal(dsseEnvelope{
		PayloadType: dssePayloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures:  []dsseSignature{{KeyID: keyID, Sig: base64.StdEncoding.EncodeToString(signature)}},
	})
}

// RateLimiter controls the rate at which operations (such as remote KMS signing requests) are permitted.
type RateLimiter interface {
	// Wait blocks until a token is available or until ctx is cancelled.
	Wait(ctx context.Context) error
	// Allow returns true if a token is available immediately without blocking.
	Allow() bool
}

// TokenBucket implements an in-memory token bucket rate limiter.
type TokenBucket struct {
	rate       float64 // tokens per second
	burst      float64 // max bucket capacity
	tokens     float64
	lastUpdate time.Time
	mu         sync.Mutex
}

// NewTokenBucket creates a new TokenBucket rate limiter.
// rateLimit is tokens per second, burst is the maximum burst capacity.
func NewTokenBucket(rateLimit float64, burst int) *TokenBucket {
	if rateLimit <= 0 {
		rateLimit = 100.0 // default 100 QPS
	}
	if burst <= 0 {
		burst = 10
	}
	return &TokenBucket{
		rate:       rateLimit,
		burst:      float64(burst),
		tokens:     float64(burst),
		lastUpdate: time.Now(),
	}
}

func (tb *TokenBucket) updateTokens(now time.Time) {
	elapsed := now.Sub(tb.lastUpdate).Seconds()
	if elapsed > 0 {
		tb.tokens += elapsed * tb.rate
		if tb.tokens > tb.burst {
			tb.tokens = tb.burst
		}
		tb.lastUpdate = now
	}
}

// Allow reports whether an event may happen right now.
func (tb *TokenBucket) Allow() bool {
	tb.mu.Lock()
	defer tb.mu.Unlock()
	now := time.Now()
	tb.updateTokens(now)
	if tb.tokens >= 1.0 {
		tb.tokens -= 1.0
		return true
	}
	return false
}

// Wait blocks until a token is available or until the context expires.
func (tb *TokenBucket) Wait(ctx context.Context) error {
	for {
		tb.mu.Lock()
		now := time.Now()
		tb.updateTokens(now)
		if tb.tokens >= 1.0 {
			tb.tokens -= 1.0
			tb.mu.Unlock()
			return nil
		}
		// calculate sleep duration for 1 token
		needed := 1.0 - tb.tokens
		sleepSec := needed / tb.rate
		tb.mu.Unlock()

		sleepDuration := time.Duration(sleepSec * float64(time.Second))
		if sleepDuration <= 0 {
			sleepDuration = time.Millisecond
		}

		select {
		case <-time.After(sleepDuration):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// FileSharedTokenBucket implements a token bucket rate limiter shared across multiple OS processes
// using a state file synchronized with flock.
type FileSharedTokenBucket struct {
	filePath string
	rate     float64
	burst    float64
}

type fileBucketState struct {
	Tokens         float64 `json:"tokens"`
	LastUpdateUnix int64   `json:"last_update_unix_nano"`
}

// NewFileSharedTokenBucket creates a token bucket backed by a local state file.
func NewFileSharedTokenBucket(stateFilePath string, rateLimit float64, burst int) (*FileSharedTokenBucket, error) {
	if rateLimit <= 0 {
		rateLimit = 100.0
	}
	if burst <= 0 {
		burst = 10
	}
	if err := os.MkdirAll(filepath.Dir(stateFilePath), 0o750); err != nil {
		return nil, fmt.Errorf("create shared token bucket directory: %w", err)
	}
	return &FileSharedTokenBucket{
		filePath: stateFilePath,
		rate:     rateLimit,
		burst:    float64(burst),
	}, nil
}

func (fb *FileSharedTokenBucket) withLock(fn func(state *fileBucketState) (bool, time.Duration, error)) (bool, time.Duration, error) {
	f, err := os.OpenFile(fb.filePath, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return false, 0, fmt.Errorf("open bucket lock file: %w", err)
	}
	defer f.Close()

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return false, 0, fmt.Errorf("flock bucket: %w", err)
	}
	defer func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	}()

	var state fileBucketState
	info, err := f.Stat()
	if err == nil && info.Size() > 0 {
		data, readErr := os.ReadFile(fb.filePath)
		if readErr == nil {
			_ = json.Unmarshal(data, &state)
		}
	}
	now := time.Now()
	nowNano := now.UnixNano()
	if state.LastUpdateUnix == 0 {
		state.Tokens = fb.burst
		state.LastUpdateUnix = nowNano
	} else {
		elapsed := time.Duration(nowNano - state.LastUpdateUnix).Seconds()
		if elapsed > 0 {
			state.Tokens += elapsed * fb.rate
			if state.Tokens > fb.burst {
				state.Tokens = fb.burst
			}
			state.LastUpdateUnix = nowNano
		}
	}

	granted, waitDuration, err := fn(&state)
	if err != nil {
		return false, 0, err
	}

	raw, _ := json.Marshal(state)
	_ = f.Truncate(0)
	_, _ = f.Seek(0, 0)
	_, _ = f.Write(raw)
	_ = f.Sync()

	return granted, waitDuration, nil
}

// Allow attempts to consume 1 token immediately.
func (fb *FileSharedTokenBucket) Allow() bool {
	granted, _, err := fb.withLock(func(state *fileBucketState) (bool, time.Duration, error) {
		if state.Tokens >= 1.0 {
			state.Tokens -= 1.0
			return true, 0, nil
		}
		return false, 0, nil
	})
	return err == nil && granted
}

// Wait blocks until 1 token is available.
func (fb *FileSharedTokenBucket) Wait(ctx context.Context) error {
	for {
		granted, waitDuration, err := fb.withLock(func(state *fileBucketState) (bool, time.Duration, error) {
			if state.Tokens >= 1.0 {
				state.Tokens -= 1.0
				return true, 0, nil
			}
			needed := 1.0 - state.Tokens
			sleepSec := needed / fb.rate
			return false, time.Duration(sleepSec * float64(time.Second)), nil
		})
		if err != nil {
			return err
		}
		if granted {
			return nil
		}
		if waitDuration <= 0 {
			waitDuration = 5 * time.Millisecond
		}
		select {
		case <-time.After(waitDuration):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// RetryConfig specifies the bounded exponential backoff policy for KMS operations.
type RetryConfig struct {
	MaxRetries     int
	InitialBackoff time.Duration
	MaxBackoff     time.Duration
	Multiplier     float64
	Jitter         bool
}

// DefaultRetryConfig returns a standard production retry configuration for KMS signing.
func DefaultRetryConfig() RetryConfig {
	return RetryConfig{
		MaxRetries:     5,
		InitialBackoff: 25 * time.Millisecond,
		MaxBackoff:     1 * time.Second,
		Multiplier:     2.0,
		Jitter:         true,
	}
}

// BackoffForAttempt computes the wait duration for a given 0-indexed attempt.
func (rc RetryConfig) BackoffForAttempt(attempt int) time.Duration {
	if attempt < 0 {
		attempt = 0
	}
	multiplier := 1.0
	for i := 0; i < attempt; i++ {
		multiplier *= rc.Multiplier
	}
	backoff := time.Duration(float64(rc.InitialBackoff) * multiplier)
	if backoff > rc.MaxBackoff {
		backoff = rc.MaxBackoff
	}
	if rc.Jitter && backoff > 0 {
		// apply 0-50% positive jitter
		jitterFactor := 1.0 + (rand.Float64() * 0.5)
		backoff = time.Duration(float64(backoff) * jitterFactor)
	}
	return backoff
}
