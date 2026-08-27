// prod-deploy-gate: HMAC-SHA256 token generation and validation.
//
// Tokens encode a request ID and expiry timestamp, signed with a shared secret.
// Format: base64url(requestID + "|" + expiryUnixNano) + "." + base64url(hmac-sha256)
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

var (
	ErrTokenExpired  = errors.New("token expired")
	ErrTokenInvalid  = errors.New("token signature invalid")
	ErrTokenMalformed = errors.New("token malformed")
)

// GenerateToken creates an HMAC-SHA256 signed approval token.
// The token encodes the requestID and an expiry timestamp.
func GenerateToken(secret []byte, requestID string, ttl time.Duration) (string, error) {
	if len(secret) == 0 {
		return "", fmt.Errorf("secret must not be empty")
	}
	if requestID == "" {
		return "", fmt.Errorf("requestID must not be empty")
	}

	expiry := time.Now().Add(ttl).UnixNano()
	payload := fmt.Sprintf("%s|%d", requestID, expiry)
	payloadB64 := base64.RawURLEncoding.EncodeToString([]byte(payload))

	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payloadB64))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))

	return payloadB64 + "." + sig, nil
}

// ValidateToken verifies the HMAC signature and checks expiry.
// Returns the embedded requestID on success.
func ValidateToken(secret []byte, token string) (string, error) {
	if token == "" {
		return "", ErrTokenMalformed
	}

	parts := strings.SplitN(token, ".", 2)
	if len(parts) != 2 {
		return "", ErrTokenMalformed
	}

	payloadB64, sigB64 := parts[0], parts[1]

	// Verify HMAC.
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payloadB64))
	expectedSig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(sigB64), []byte(expectedSig)) {
		return "", ErrTokenInvalid
	}

	// Decode payload.
	payloadBytes, err := base64.RawURLEncoding.DecodeString(payloadB64)
	if err != nil {
		return "", ErrTokenMalformed
	}
	payload := string(payloadBytes)

	sepIdx := strings.LastIndex(payload, "|")
	if sepIdx < 0 {
		return "", ErrTokenMalformed
	}

	requestID := payload[:sepIdx]
	expiryStr := payload[sepIdx+1:]

	expiryNano, err := strconv.ParseInt(expiryStr, 10, 64)
	if err != nil {
		return "", ErrTokenMalformed
	}

	if time.Now().UnixNano() > expiryNano {
		return "", ErrTokenExpired
	}

	return requestID, nil
}
