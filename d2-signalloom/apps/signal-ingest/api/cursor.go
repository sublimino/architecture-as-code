package api

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// CursorVersion is the current format version for opaque cursors.
const CursorVersion = 1

// ErrInvalidCursorMsg is the required 400 error message for any malformed, invalid, or cross-tenant cursor.
const ErrInvalidCursorMsg = "invalid 'cursor': pass the X-Next-Cursor value from the previous response unchanged"

// CursorPayload represents the JSON structure encoded inside the opaque cursor.
type CursorPayload struct {
	V     int    `json:"v"`
	T     string `json:"t"`
	ID    string `json:"id"`
	Scope string `json:"scope"`
}

// ParsedCursor holds the validated fields extracted from an opaque cursor.
type ParsedCursor struct {
	Timestamp time.Time
	ID        string
	Scope     string
}

// ComputeScopeDigest computes an opaque deterministic SHA-256 digest of the caller's tenant scope.
func ComputeScopeDigest(tenant string, all bool) string {
	var input string
	if all {
		input = "scope:all:*"
	} else {
		input = fmt.Sprintf("scope:tenant:%s", tenant)
	}
	h := sha256.Sum256([]byte(input))
	return hex.EncodeToString(h[:16])
}

// EncodeCursor produces a base64url-encoded JSON string representing the cursor.
func EncodeCursor(t time.Time, id string, scope string) string {
	payload := CursorPayload{
		V:     CursorVersion,
		T:     t.UTC().Format(time.RFC3339Nano),
		ID:    id,
		Scope: scope,
	}
	b, _ := json.Marshal(payload)
	return base64.RawURLEncoding.EncodeToString(b)
}

// ParseCursor decodes and validates a cursor string against the expected scope digest.
func ParseCursor(raw string, expectedScope string) (ParsedCursor, error) {
	if raw == "" {
		return ParsedCursor{}, errors.New("empty cursor")
	}

	var data []byte
	var err error
	data, err = base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		data, err = base64.URLEncoding.DecodeString(raw)
		if err != nil {
			data, err = base64.StdEncoding.DecodeString(raw)
			if err != nil {
				return ParsedCursor{}, errors.New(ErrInvalidCursorMsg)
			}
		}
	}

	var payload CursorPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return ParsedCursor{}, errors.New(ErrInvalidCursorMsg)
	}

	if payload.V != CursorVersion {
		return ParsedCursor{}, errors.New(ErrInvalidCursorMsg)
	}

	if payload.ID == "" {
		return ParsedCursor{}, errors.New(ErrInvalidCursorMsg)
	}

	if payload.Scope != expectedScope {
		return ParsedCursor{}, errors.New(ErrInvalidCursorMsg)
	}

	t, err := time.Parse(time.RFC3339Nano, payload.T)
	if err != nil {
		t, err = time.Parse(time.RFC3339, payload.T)
		if err != nil {
			return ParsedCursor{}, errors.New(ErrInvalidCursorMsg)
		}
	}

	return ParsedCursor{
		Timestamp: t.UTC(),
		ID:        payload.ID,
		Scope:     payload.Scope,
	}, nil
}
