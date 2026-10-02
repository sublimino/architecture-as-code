package main

// Caller authentication for the mutating fleet routes.
//
// Every route that changes the fleet (stun, resume, recover, deploy, scan,
// reset) used to answer anyone the NetworkPolicy let through. /recover thaws
// every stunned agent and never consulted the resume-token governance that
// guards /resume, so reaching fleet-manager was enough to undo all
// containment.
//
// Each caller now holds a named static bearer key, loaded from a Secret into
// the environment, granting a fixed set of scopes. The semantics mirror
// signal-ingest's static bearer (apps/signal-ingest/api/static_bearer.go):
// header-only, exactly one "Authorization: Bearer <key>", keys held as
// SHA-256 digests and compared with hmac.Equal over every configured key with
// no early exit, so timing reveals neither which key matched nor its length.
//
//	401 no key, a malformed or duplicate header, or a key nobody holds
//	403 a valid key whose caller lacks the route's scope
//
// No keys configured means every mutating route answers 401: there is no
// anonymous mode. Read-only routes (health, topology, consistency, metrics)
// are unchanged.

import (
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"strings"
)

// callerScope is one mutating capability a key can be granted.
type callerScope string

const (
	scopeStun    callerScope = "stun"
	scopeResume  callerScope = "resume"
	scopeRecover callerScope = "recover"
	scopeDeploy  callerScope = "deploy"
	scopeScan    callerScope = "scan"
	scopeReset   callerScope = "reset"
)

var knownCallerScopes = map[callerScope]bool{
	scopeStun: true, scopeResume: true, scopeRecover: true,
	scopeDeploy: true, scopeScan: true, scopeReset: true,
}

// callerKeyEnvPrefix names a key: FLEET_MANAGER_KEY_STUN_SENTINEL holds the
// stun-sentinel caller's key and FLEET_MANAGER_KEY_STUN_SENTINEL_SCOPES its
// comma-separated scopes. The key comes from a Secret (secretKeyRef), never
// a literal in a manifest.
const callerKeyEnvPrefix = "FLEET_MANAGER_KEY_"

// minCallerKeyLength rejects a key short enough to guess; matches signal-ingest.
const minCallerKeyLength = 16

type callerKey struct {
	name   string
	digest [sha256.Size]byte
	scopes map[callerScope]bool
}

type callerKeys struct {
	keys []callerKey
}

// loadCallerKeys reads every FLEET_MANAGER_KEY_<NAME> from environ. Any defect
// (no scopes, unknown scope, short key, two callers sharing a key) is an error
// for main to refuse startup on.
func loadCallerKeys(environ []string) (*callerKeys, error) {
	env := map[string]string{}
	for _, kv := range environ {
		if k, v, ok := strings.Cut(kv, "="); ok && strings.HasPrefix(k, callerKeyEnvPrefix) {
			env[k] = v
		}
	}
	var names []string
	for k := range env {
		if !strings.HasSuffix(k, "_SCOPES") {
			names = append(names, k)
		}
	}
	sort.Strings(names)

	ck := &callerKeys{}
	seen := map[[sha256.Size]byte]string{}
	for _, k := range names {
		name := strings.ToLower(strings.ReplaceAll(strings.TrimPrefix(k, callerKeyEnvPrefix), "_", "-"))
		key := env[k]
		if len(strings.TrimSpace(key)) < minCallerKeyLength {
			return nil, fmt.Errorf("%s: key must be at least %d bytes", k, minCallerKeyLength)
		}
		rawScopes, ok := env[k+"_SCOPES"]
		if !ok || strings.TrimSpace(rawScopes) == "" {
			return nil, fmt.Errorf("%s_SCOPES is required: a key with no scopes grants nothing and is a misconfiguration", k)
		}
		scopes := map[callerScope]bool{}
		for _, s := range strings.Split(rawScopes, ",") {
			s = strings.TrimSpace(s)
			if !knownCallerScopes[callerScope(s)] {
				return nil, fmt.Errorf("%s_SCOPES: %q is not a fleet-manager scope", k, s)
			}
			scopes[callerScope(s)] = true
		}
		digest := sha256.Sum256([]byte(key))
		if other, dup := seen[digest]; dup {
			return nil, fmt.Errorf("callers %s and %s share one key; every caller needs its own", other, name)
		}
		seen[digest] = name
		ck.keys = append(ck.keys, callerKey{name: name, digest: digest, scopes: scopes})
	}
	for k := range env {
		if base, ok := strings.CutSuffix(k, "_SCOPES"); ok {
			if _, has := env[base]; !has {
				return nil, fmt.Errorf("%s is set but %s is not", k, base)
			}
		}
	}
	return ck, nil
}

var (
	errNoCredential      = errors.New("missing or malformed bearer credential")
	errUnknownCredential = errors.New("unknown bearer credential")
)

// authenticate returns the caller holding the presented key.
func (c *callerKeys) authenticate(r *http.Request) (*callerKey, error) {
	values := r.Header.Values("Authorization")
	if len(values) != 1 || !strings.HasPrefix(values[0], "Bearer ") {
		return nil, errNoCredential
	}
	presented := sha256.Sum256([]byte(strings.TrimPrefix(values[0], "Bearer ")))
	var match *callerKey
	if c != nil {
		for i := range c.keys {
			if hmac.Equal(presented[:], c.keys[i].digest[:]) && match == nil {
				match = &c.keys[i]
			}
		}
	}
	if match == nil {
		return nil, errUnknownCredential
	}
	return match, nil
}

// callerHeader names the authenticated caller for audit on the response.
const callerHeader = "X-Fleet-Caller"

// require wraps a mutating handler: 401 without a held key, 403 without scope.
func (c *callerKeys) require(scope callerScope, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		caller, err := c.authenticate(r)
		if err != nil {
			slog.Warn("fleet route refused", "path", r.URL.Path, "scope", scope, "reason", err.Error())
			w.Header().Set("WWW-Authenticate", `Bearer realm="fleet-manager"`)
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}
		if !caller.scopes[scope] {
			slog.Warn("fleet route refused", "path", r.URL.Path, "scope", scope, "caller", caller.name, "reason", "scope not granted")
			writeError(w, http.StatusForbidden, fmt.Sprintf("caller %q is not granted %q", caller.name, scope))
			return
		}
		w.Header().Set(callerHeader, caller.name)
		slog.Info("fleet route authorised", "path", r.URL.Path, "scope", scope, "caller", caller.name)
		next(w, r)
	}
}
