// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package transform

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

var (
	// Cryptographic secret patterns
	bearerRegex     = regexp.MustCompile(`(?i)\b(Bearer\s+)[A-Za-z0-9_\-\.]{10,}`)
	jwtRegex        = regexp.MustCompile(`\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*\b`)
	pemKeyRegex     = regexp.MustCompile(`-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----`)
	awsAccessKey    = regexp.MustCompile(`\bAKIA[0-9A-Z]{16}\b`)
	githubPatRegex  = regexp.MustCompile(`\bghp_[A-Za-z0-9_]{36}\b`)
	vaultTokenRegex = regexp.MustCompile(`\b(s\.[A-Za-z0-9]{24}|hvs\.[A-Za-z0-9_\-]{24,})\b`)

	// Sensitive JSON and Map field names
	sensitiveFieldNames = map[string]bool{
		"password":       true,
		"secret":         true,
		"token":          true,
		"client_token":   true,
		"client_secret":  true,
		"private_key":    true,
		"cert":           true,
		"certificate":    true,
		"credential":     true,
		"credentials":    true,
		"session_token":  true,
		"authorization":  true,
		"api_key":        true,
		"access_token":   true,
		"master_key":     true,
		"encryption_key": true,
	}
)

// CryptographicSecretScrubber performs comprehensive multi-tier secret redaction and deterministic HMAC anonymization.
type CryptographicSecretScrubber struct {
	salt []byte
}

// ErrScrubberSaltRequired is returned when no pseudonymisation salt is configured.
//
// This constructor previously fell back to a hard-coded salt literal when none was supplied
// (removed by SLDP-P2-1; see docs/signalloom/sldp-p2-1-proof.md for the original value). A
// pseudonymisation secret committed to source is public, so every deployment that never set the
// variable shared one attacker-known key — and under GDPR Article 4(5) such a secret is not "kept
// separately". There is no safe default, so there is no default: an absent salt is an error.
//
// The literal is deliberately not repeated here. A grep for it is the check that this defect is
// gone, and a comment quoting it would satisfy that grep while proving nothing.
var ErrScrubberSaltRequired = errors.New("transform: pseudonymisation salt is required; refusing to fall back to a compiled-in default")

// MinScrubberSaltLen is the minimum accepted salt length. A one-character salt is a rounding
// error away from no salt at all.
const MinScrubberSaltLen = 16

// NewCryptographicSecretScrubber instantiates a secret scrubber with a dedicated cluster salt.
// It fails closed on an absent or trivially short salt rather than substituting a default.
func NewCryptographicSecretScrubber(salt string) (*CryptographicSecretScrubber, error) {
	if salt == "" {
		return nil, ErrScrubberSaltRequired
	}
	if len(salt) < MinScrubberSaltLen {
		return nil, fmt.Errorf("%w: salt must be at least %d characters, got %d", ErrScrubberSaltRequired, MinScrubberSaltLen, len(salt))
	}
	h := sha256.Sum256([]byte(salt))
	return &CryptographicSecretScrubber{
		salt: h[:],
	}, nil
}

// NewCryptographicSecretScrubberFromEnv builds a scrubber from SIGNAL_SCRUBBER_SALT.
// An unset variable is an error, not a default.
func NewCryptographicSecretScrubberFromEnv() (*CryptographicSecretScrubber, error) {
	return NewCryptographicSecretScrubber(os.Getenv("SIGNAL_SCRUBBER_SALT"))
}

// AnonymizeHMACHexLen is the number of hex characters retained from the HMAC digest.
//
// This was 16 (64 bits). Removing the committed default salt above closes the "attacker knows the
// key" hole, but a 64-bit pseudonym over a small enumerable identifier population is brute-forcible
// regardless of key secrecy, which would have made that fix cosmetic. 32 hex characters is 128
// bits — beyond brute force — while staying short enough to read in a log line.
const AnonymizeHMACHexLen = 32

// AnonymizeHMAC generates a deterministic HMAC-SHA256 hash for a token accessor or identifier.
//
// KNOWN GAP, recorded rather than silently left. Unlike identity.PseudonymKeyRing this digest has
// no tenant scope and no rotation epoch, so one tenant's scrubbed labels are comparable with
// another's. Closing that requires plumbing a tenant through the ingest transform hot path, which
// is a change to a different component than SLDP-P2-1 owns. See docs/signalloom/sldp-p2-1-proof.md.
func (cs *CryptographicSecretScrubber) AnonymizeHMAC(val string) string {
	if val == "" {
		return ""
	}
	mac := hmac.New(sha256.New, cs.salt)
	mac.Write([]byte(val))
	return fmt.Sprintf("hmac-%s", hex.EncodeToString(mac.Sum(nil))[:AnonymizeHMACHexLen])
}

// ScrubText applies regex-based scrubbing to string text.
func (cs *CryptographicSecretScrubber) ScrubText(input string) string {
	if input == "" {
		return ""
	}

	out := pemKeyRegex.ReplaceAllString(input, "[REDACTED_PRIVATE_KEY]")
	out = bearerRegex.ReplaceAllString(out, "$1[REDACTED_TOKEN]")
	out = jwtRegex.ReplaceAllString(out, "[REDACTED_JWT]")
	out = awsAccessKey.ReplaceAllString(out, "[REDACTED_AWS_KEY]")
	out = githubPatRegex.ReplaceAllString(out, "[REDACTED_GH_PAT]")
	out = vaultTokenRegex.ReplaceAllString(out, "[REDACTED_VAULT_TOKEN]")

	// SLDP-P3-1: direct identifiers. Every pattern above this line is a *secret*; none of them
	// matches an email address, an IP address or a username, so before this card a scrubbed
	// observation could still name a natural person. The replacement is the same keyed HMAC used
	// for token accessors, so repeated occurrences of one identifier stay comparable without being
	// readable.
	out = redactIdentifiers(out, cs.AnonymizeHMAC)
	return out
}

// ScrubMap recursively traverses a generic map and sanitizes all sensitive values.
func (cs *CryptographicSecretScrubber) ScrubMap(data map[string]interface{}) map[string]interface{} {
	if data == nil {
		return nil
	}

	scrubbed := make(map[string]interface{}, len(data))
	for k, v := range data {
		lowerKey := strings.ToLower(k)
		if sensitiveFieldNames[lowerKey] {
			if strVal, ok := v.(string); ok && strVal != "" {
				scrubbed[k] = cs.AnonymizeHMAC(strVal)
			} else {
				scrubbed[k] = "[REDACTED_SECRET]"
			}
			continue
		}

		switch typed := v.(type) {
		case string:
			scrubbed[k] = cs.ScrubText(typed)
		case map[string]interface{}:
			scrubbed[k] = cs.ScrubMap(typed)
		case []interface{}:
			scrubbed[k] = cs.ScrubSlice(typed)
		default:
			scrubbed[k] = v
		}
	}
	return scrubbed
}

// ScrubSlice traverses a slice and scrubs nested data.
func (cs *CryptographicSecretScrubber) ScrubSlice(slice []interface{}) []interface{} {
	if slice == nil {
		return nil
	}

	scrubbed := make([]interface{}, len(slice))
	for i, item := range slice {
		switch typed := item.(type) {
		case string:
			scrubbed[i] = cs.ScrubText(typed)
		case map[string]interface{}:
			scrubbed[i] = cs.ScrubMap(typed)
		case []interface{}:
			scrubbed[i] = cs.ScrubSlice(typed)
		default:
			scrubbed[i] = item
		}
	}
	return scrubbed
}

// ScrubObservation sanitizes all fields of a model.Observation.
func (cs *CryptographicSecretScrubber) ScrubObservation(obs *model.Observation) *model.Observation {
	if obs == nil {
		return nil
	}

	sanitized := *obs
	sanitized.Description = cs.ScrubText(obs.Description)
	sanitized.RawEvidenceRef = cs.ScrubText(obs.RawEvidenceRef)
	sanitized.ActorHint = cs.ScrubText(obs.ActorHint)

	if obs.Labels != nil {
		sanitizedLabels := make(map[string]string, len(obs.Labels))
		for k, v := range obs.Labels {
			lowerKey := strings.ToLower(k)
			if sensitiveFieldNames[lowerKey] {
				sanitizedLabels[k] = cs.AnonymizeHMAC(v)
			} else if lowerKey == "accessor" || lowerKey == "auth_accessor" {
				sanitizedLabels[k] = cs.AnonymizeHMAC(v)
			} else {
				sanitizedLabels[k] = cs.ScrubText(v)
			}
		}
		sanitized.Labels = sanitizedLabels
	}

	return &sanitized
}

// ScrubJSONPayload decodes, sanitizes, and re-encodes a raw JSON payload string.
func (cs *CryptographicSecretScrubber) ScrubJSONPayload(rawJSON []byte) ([]byte, error) {
	if len(rawJSON) == 0 {
		return rawJSON, nil
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(rawJSON, &parsed); err != nil {
		// Fallback to text scrubbing if not valid JSON object
		return []byte(cs.ScrubText(string(rawJSON))), nil
	}

	sanitized := cs.ScrubMap(parsed)
	return json.Marshal(sanitized)
}
