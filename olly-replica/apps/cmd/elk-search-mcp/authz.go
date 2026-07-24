// COIN token validation for the MCP JSON-RPC path. The sentinel attaches the
// bearer olly-authz minted (H2M -> M2M, OBO), and this verifies the HS256
// signature with the shared secret and that the called tool's EEMS scope is in
// the token's permitted_actions before the tool runs. This is the server half
// of the entitlement check the sentinel also does client-side.
//
// Only the /mcp transport (the agent path) is gated; the REST /tools/* handlers
// stay open for internal inspection (the console's node view calls them).
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

type authzClaims struct {
	Username         string           `json:"username"`
	AuthzCtxID       string           `json:"authz_ctx_id"`
	PermittedActions []map[string]any `json:"permitted_actions"`
	Exp              int64            `json:"exp"`
	Nbf              int64            `json:"nbf"`
}

// verifyToken checks the HS256 signature and exp/nbf, matching olly-authz's
// stdlib jwtutil (urlsafe base64, no padding, HMAC-SHA256 over header.payload).
func verifyToken(token, secret string) (*authzClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("malformed token")
	}
	signingInput := parts[0] + "." + parts[1]
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signingInput))
	expected := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(expected), []byte(parts[2])) {
		return nil, errors.New("bad signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("bad payload encoding")
	}
	var c authzClaims
	if err := json.Unmarshal(payload, &c); err != nil {
		return nil, errors.New("bad claims")
	}
	now := time.Now().Unix()
	if c.Exp != 0 && c.Exp < now {
		return nil, errors.New("token expired")
	}
	if c.Nbf != 0 && c.Nbf > now+5 {
		return nil, errors.New("token not yet valid")
	}
	return &c, nil
}

// allows reports whether the token permits an action (positive limit).
func (c *authzClaims) allows(scope string) bool {
	for _, pa := range c.PermittedActions {
		if a, _ := pa["action"].(string); a == scope {
			if l, ok := pa["limit"].(float64); ok {
				return l > 0
			}
			return true
		}
	}
	return false
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) >= 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

// authorize checks the COIN token on the request permits `scope`. Returns the
// authz_ctx_id (for audit) and an error on denial. No-op when authz is disabled.
func (s *server) authorize(r *http.Request, scope string) (string, error) {
	if !s.authzEnabled {
		return "", nil
	}
	tok := bearer(r)
	if tok == "" {
		return "", errors.New("no bearer token")
	}
	claims, err := verifyToken(tok, s.authzSecret)
	if err != nil {
		return "", err
	}
	if scope != "" && !claims.allows(scope) {
		return claims.AuthzCtxID, errors.New("token lacks scope " + scope)
	}
	return claims.AuthzCtxID, nil
}
