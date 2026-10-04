package main

import (
	"crypto/subtle"
	"net/http"
	"strings"
)

// APIKeysEnv names the comma-separated list of accepted bearer keys.
//
// Unset or empty means the policy and observation APIs are unauthenticated,
// which is the pre-existing behaviour and what the in-cluster-only deployment
// relies on today. Setting it is how the dashboard dry-run surface is exposed
// beyond the cluster (SLAWS v2 §4.3). Keys arrive from a
// signal-ingest-key-<name> Secret as an env var; they never appear in argv, in
// a ConfigMap, or in a log line here — nothing in this file logs the key, the
// prefix of the key, or the number of keys configured, because each of those
// narrows an offline search.
const APIKeysEnv = "POLICY_API_KEYS"

// ParseAPIKeys splits the env value into keys, dropping empties so that a
// trailing comma or a blank entry cannot become a credential that matches an
// empty Authorization header.
func ParseAPIKeys(raw string) []string {
	var keys []string
	for _, part := range strings.Split(raw, ",") {
		if k := strings.TrimSpace(part); k != "" {
			keys = append(keys, k)
		}
	}
	return keys
}

// bearerToken extracts the credential from an Authorization header. The scheme
// match is case-insensitive per RFC 7235; the token itself is not touched.
func bearerToken(r *http.Request) (string, bool) {
	header := r.Header.Get("Authorization")
	if header == "" {
		return "", false
	}
	scheme, token, found := strings.Cut(header, " ")
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	if token == "" {
		return "", false
	}
	return token, true
}

// authorized reports whether the request carries one of the configured keys.
//
// With no keys configured every request is authorized: that is the documented
// unauthenticated mode, not a bypass. With keys configured, the comparison runs
// over EVERY key with no early return, so neither the verdict nor the matching
// key index is observable in the response time.
func authorized(r *http.Request, keys []string) bool {
	if len(keys) == 0 {
		return true
	}
	token, ok := bearerToken(r)
	if !ok {
		return false
	}
	match := 0
	for _, k := range keys {
		match |= subtle.ConstantTimeCompare([]byte(token), []byte(k))
	}
	return match == 1
}

// RequireAPIKey wraps a handler so that, when keys are configured, a request
// without a valid bearer token is refused with 401 before the handler runs.
//
// The refusal body is a fixed string: it does not say whether the key was
// absent, malformed or simply wrong, because distinguishing those is free
// oracle for an attacker enumerating keys.
func RequireAPIKey(keys []string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !authorized(r, keys) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="policy-engine"`)
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r)
	}
}
