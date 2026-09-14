// Package transform implements 3-tier cryptographic secret scrubbing and redaction.
package transform

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

var (
	// Tier 1: Sensitive auth patterns (Bearer tokens, passwords, private keys)
	bearerPattern    = regexp.MustCompile(`(?i)\b(Bearer\s+)[A-Za-z0-9_\-\.]{10,}`)
	jwtPattern       = regexp.MustCompile(`\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*\b`)
	pemHeaderPattern = regexp.MustCompile(`-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----`)

	// Sensitive label keys to scrub
	sensitiveKeys = map[string]bool{
		"password":         true,
		"token":            true,
		"secret":           true,
		"private_key":      true,
		"client_secret":    true,
		"session_token":    true,
		"authorization":    true,
		"api_key":          true,
		"access_token":     true,
	}
)

// SecretRedactor performs 3-tier secret scrubbing on observations.
type SecretRedactor struct{}

// NewSecretRedactor creates a new SecretRedactor.
func NewSecretRedactor() *SecretRedactor {
	return &SecretRedactor{}
}

// RedactObservation returns a sanitized copy of the observation with all sensitive data scrubbed.
func (r *SecretRedactor) RedactObservation(obs *model.Observation) *model.Observation {
	if obs == nil {
		return nil
	}

	sanitized := *obs
	sanitized.Description = r.RedactText(obs.Description)
	sanitized.RawEvidenceRef = r.RedactText(obs.RawEvidenceRef)
	sanitized.ActorHint = r.RedactText(obs.ActorHint)

	if obs.Labels != nil {
		sanitizedLabels := make(map[string]string, len(obs.Labels))
		for k, v := range obs.Labels {
			sanitizedLabels[k] = r.RedactLabel(k, v)
		}
		sanitized.Labels = sanitizedLabels
	}

	return &sanitized
}

// RedactLabel scrubs a label key/value pair according to 3-tier security rules.
func (r *SecretRedactor) RedactLabel(key string, val string) string {
	lowerKey := strings.ToLower(key)

	// Tier 3: Direct sensitive key match
	if sensitiveKeys[lowerKey] || strings.Contains(lowerKey, "password") || strings.Contains(lowerKey, "secret") {
		return r.hashRedact(val)
	}

	// Tier 1 & 2: Pattern-based scrubbing on value
	return r.RedactText(val)
}

// RedactText scrubs embedded tokens, JWTs, and PEM keys from text.
func (r *SecretRedactor) RedactText(text string) string {
	if text == "" {
		return ""
	}

	// Tier 1: Scrub PEM private keys
	text = pemHeaderPattern.ReplaceAllString(text, "[REDACTED_PEM_PRIVATE_KEY]")

	// Tier 1: Scrub Bearer tokens
	text = bearerPattern.ReplaceAllStringFunc(text, func(m string) string {
		parts := strings.SplitN(m, " ", 2)
		if len(parts) == 2 {
			return parts[0] + " " + r.hashRedact(parts[1])
		}
		return "[REDACTED_BEARER_TOKEN]"
	})

	// Tier 1: Scrub Raw JWTs
	text = jwtPattern.ReplaceAllStringFunc(text, func(m string) string {
		return r.hashRedact(m)
	})

	// Tier 4 (SLDP-P3-1): direct identifiers — email, IPv4, IPv6, Kubernetes subject, labelled
	// username. Tiers 1-3 only ever knew about secrets, so a person's email address or source IP
	// passed through untouched and into an immutable segment.
	text = redactIdentifiers(text, r.hashRedact)

	return text
}

func (r *SecretRedactor) hashRedact(val string) string {
	if val == "" {
		return "[REDACTED_EMPTY]"
	}
	h := sha256.Sum256([]byte(val))
	hashPrefix := hex.EncodeToString(h[:])[:8]
	return fmt.Sprintf("[REDACTED_SHA256:%s]", hashPrefix)
}
