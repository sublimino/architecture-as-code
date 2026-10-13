package main

// Caller authentication for the privileged fleet routes.
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
// No keys configured means every authenticated route answers 401: there is no
// anonymous mode. Public read-only routes (health, topology, consistency,
// metrics) are unchanged.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"strings"
)

// callerScope is one authenticated fleet capability a key can be granted.
type callerScope string

const (
	scopeStun    callerScope = "stun"
	scopeResume  callerScope = "resume"
	scopeRecover callerScope = "recover"
	scopeDeploy  callerScope = "deploy"
	scopeScan    callerScope = "scan"
	scopeReset   callerScope = "reset"
	scopeReport  callerScope = "report"
	scopeRead    callerScope = "read"
)

// The remote reporting path also requires coordinated manifest and bootstrap
// work that deliberately does not belong in this unit. base/deployment.yaml
// must declare a caller named warden whose FLEET_MANAGER_KEY_WARDEN comes from
// Secret key "warden" and whose FLEET_MANAGER_KEY_WARDEN_SCOPES is exactly
// "report". scripts/fleet-manager-caller-keys.sh must provision that named
// Secret key. The warden DaemonSet receives it from the remote-tenant overlay
// in a REMOTE cluster, and the key must carry ONLY report: it must never grant
// stun, resume, recover, deploy, scan, or reset authority over the hub. A
// remote cluster's key is the furthest-out credential in the system, so
// widening it would turn compromise at the least trusted edge into control of
// the central containment plane.
//
// base/deployment.yaml must also append read to the dashboard's currently exact
// FLEET_MANAGER_KEY_DASHBOARD_SCOPES value "stun,deploy,scan,reset", allowing
// the dashboard to list remote workloads. test/fleet-manager-caller-auth-manifest.bats
// pins that value with an exact grep -qx, so the manifest and BATS edits must
// land together rather than leaving a test that blesses the old authority.
//
// Until both the warden and dashboard wiring land, the gap is visibly
// fail-closed: GET /api/v1/fleet/workloads answers the dashboard with 403 and
// the warden cannot report at all. Neither failure silently weakens caller
// authentication.
var knownCallerScopes = map[callerScope]bool{
	scopeStun:    true,
	scopeResume:  true,
	scopeRecover: true,
	scopeDeploy:  true,
	scopeScan:    true,
	scopeReset:   true,
	scopeReport:  true,
	scopeRead:    true,
}

// callerKeyEnvPrefix names a key: FLEET_MANAGER_KEY_STUN_SENTINEL holds the
// stun-sentinel caller's key and FLEET_MANAGER_KEY_STUN_SENTINEL_SCOPES its
// comma-separated scopes. The key comes from a Secret (secretKeyRef), never
// a literal in a manifest.
const callerKeyEnvPrefix = "FLEET_MANAGER_KEY_"

// minCallerKeyLength rejects a key short enough to guess; matches signal-ingest's
// named static keys (32 bytes). The bootstrap script writes 44.
const minCallerKeyLength = 32

type callerKey struct {
	name   string
	digest [sha256.Size]byte
	scopes map[callerScope]bool
}

type callerKeys struct {
	keys []callerKey
	// disabled names callers that have scopes but no key in this process.
	disabled []string
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
	// Scopes are plain manifest values and keys are optional Secret refs, so a
	// caller whose Secret key is absent is disabled, not a reason to refuse
	// every other caller. It is named so the gap is visible.
	for k := range env {
		if base, ok := strings.CutSuffix(k, "_SCOPES"); ok {
			if _, has := env[base]; !has {
				ck.disabled = append(ck.disabled, strings.ToLower(strings.ReplaceAll(strings.TrimPrefix(base, callerKeyEnvPrefix), "_", "-")))
			}
		}
	}
	sort.Strings(ck.disabled)
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
	token := strings.TrimSpace(strings.TrimPrefix(values[0], "Bearer "))
	if token == "" {
		return nil, errNoCredential
	}
	presented := sha256.Sum256([]byte(token))
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

// require wraps an authenticated handler: 401 without a held key, 403 without
// the required scope.
func (c *callerKeys) require(scope callerScope, next http.HandlerFunc) http.HandlerFunc {
	return c.requireAny([]callerScope{scope}, next)
}

// requireAny is require for a route that more than one scope legitimately
// opens. The caller needs ANY ONE of them, not all.
//
// It exists for GET /api/v1/fleet/workloads, which has two rightful readers
// that share no other capability. The dashboard reads the registry to merge
// remote workloads into its fleet view and holds `read`; the remote warden
// reads it back to confirm what the hub believes about its own cluster and
// holds `report` and nothing else. Gating that route on `read` alone would
// make the warden's key insufficient for a route the remote contract gives it,
// and widening the warden key to `read` as well would hand the furthest-out
// credential in the system a second capability purely to satisfy a routing
// detail. Accepting either scope is the narrower of the two options.
//
// This is deliberately NOT available to any mutating route: every one of those
// is reachable by exactly one scope, and a disjunction there would be a way to
// grow a caller's authority without changing its key.
func (c *callerKeys) requireAny(scopes []callerScope, next http.HandlerFunc) http.HandlerFunc {
	// Formatted once at mount time rather than per request, and sorted so the
	// log attribute and the 403 body are stable across process restarts.
	names := make([]string, 0, len(scopes))
	for _, s := range scopes {
		names = append(names, string(s))
	}
	sort.Strings(names)
	scopeAttr := strings.Join(names, "|")

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			next(w, r)
			return
		}
		caller, err := c.authenticate(r)
		if err != nil {
			slog.Warn("fleet route refused", "path", r.URL.Path, "scope", scopeAttr, "reason", err.Error())
			w.Header().Set("WWW-Authenticate", `Bearer realm="fleet-manager"`)
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}
		granted := false
		for _, s := range scopes {
			if caller.scopes[s] {
				granted = true
				break
			}
		}
		if !granted {
			slog.Warn("fleet route refused", "path", r.URL.Path, "scope", scopeAttr, "caller", caller.name, "reason", "scope not granted")
			// The single-scope wording is preserved exactly: it is the message
			// every existing denial test and the denial matrix assert on, and a
			// route that admits one scope should not describe itself as a choice.
			if len(scopes) == 1 {
				writeError(w, http.StatusForbidden, fmt.Sprintf("caller %q is not granted %q", caller.name, scopes[0]))
			} else {
				writeError(w, http.StatusForbidden, fmt.Sprintf("caller %q is granted none of %q", caller.name, scopeAttr))
			}
			return
		}
		w.Header().Set(callerHeader, caller.name)
		slog.Info("fleet route authorised", "path", r.URL.Path, "scope", scopeAttr, "caller", caller.name)
		next(w, r)
	}
}


// CallerContext holds the role and team attributes of an authenticated caller.
type CallerContext struct {
	Role string
	Team string
}

// IsAnonymous returns true if the caller has no authenticated role or is explicitly anonymous.
func (c CallerContext) IsAnonymous() bool {
	return c.Role == "" || c.Role == "anonymous"
}

// IsAdmin returns true if the caller role is admin.
func (c CallerContext) IsAdmin() bool {
	return c.Role == "admin"
}

// ExtractCallerContext extracts user role and team from HTTP request headers or JWT claims.
// It checks headers X-User-Role (e.g. "admin", "compliance", "team-lead") and
// X-User-Team (e.g. "payments", "platform", "ml-ops", "sre") first.
// If headers are absent and Authorization contains a Bearer JWT, claims are extracted.
// Defaults to unauthenticated (empty role and team) if absent.
func ExtractCallerContext(r *http.Request) CallerContext {
	if r == nil {
		return CallerContext{}
	}

	role := strings.TrimSpace(r.Header.Get("X-User-Role"))
	team := strings.TrimSpace(r.Header.Get("X-User-Team"))

	if role == "" || team == "" {
		jwtRole, jwtTeam := extractJWTClaims(r.Header.Get("Authorization"))
		if role == "" {
			role = jwtRole
		}
		if team == "" {
			team = jwtTeam
		}
	}

	role = strings.ToLower(role)
	if role == "team_lead" {
		role = "team-lead"
	}
	team = strings.ToLower(team)

	return CallerContext{
		Role: role,
		Team: team,
	}
}

// extractJWTClaims parses a Bearer JWT token payload to extract role and team claims.
func extractJWTClaims(authHeader string) (string, string) {
	if !strings.HasPrefix(authHeader, "Bearer ") {
		return "", ""
	}
	token := strings.TrimSpace(strings.TrimPrefix(authHeader, "Bearer "))
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", ""
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		payloadBytes, err = base64.URLEncoding.DecodeString(parts[1])
		if err != nil {
			return "", ""
		}
	}

	var claims map[string]any
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return "", ""
	}

	var role, team string

	if rVal, ok := claims["role"].(string); ok && rVal != "" {
		role = rVal
	} else if rVal, ok := claims["user_role"].(string); ok && rVal != "" {
		role = rVal
	} else if rVal, ok := claims["x-user-role"].(string); ok && rVal != "" {
		role = rVal
	}

	if tVal, ok := claims["team"].(string); ok && tVal != "" {
		team = tVal
	} else if tVal, ok := claims["user_team"].(string); ok && tVal != "" {
		team = tVal
	} else if tVal, ok := claims["x-user-team"].(string); ok && tVal != "" {
		team = tVal
	}

	var groups []string
	switch g := claims["groups"].(type) {
	case []any:
		for _, item := range g {
			if s, ok := item.(string); ok {
				groups = append(groups, s)
			}
		}
	case []string:
		groups = append(groups, g...)
	case string:
		groups = append(groups, g)
	}

	if rList, ok := claims["roles"].([]any); ok {
		for _, item := range rList {
			if s, ok := item.(string); ok && role == "" {
				role = s
			}
		}
	}

	hasAdmin := false
	hasCompliance := false
	var teamFromGroup string

	for _, g := range groups {
		gClean := strings.TrimSpace(g)
		gLower := strings.ToLower(gClean)
		if gLower == "admin" {
			hasAdmin = true
		} else if gLower == "compliance" {
			hasCompliance = true
		} else if strings.HasPrefix(gLower, "team:") {
			if teamFromGroup == "" {
				teamFromGroup = strings.TrimPrefix(gClean, "team:")
				if teamFromGroup == "" {
					teamFromGroup = strings.TrimPrefix(gLower, "team:")
				}
			}
		} else if strings.HasPrefix(gLower, "team-") {
			if teamFromGroup == "" {
				teamFromGroup = strings.TrimPrefix(gClean, "team-")
				if teamFromGroup == "" {
					teamFromGroup = strings.TrimPrefix(gLower, "team-")
				}
			}
		}
	}

	if role == "" {
		if hasAdmin {
			role = "admin"
		} else if hasCompliance {
			role = "compliance"
		} else if teamFromGroup != "" {
			role = "team-lead"
		}
	}

	if team == "" && teamFromGroup != "" {
		team = teamFromGroup
	}

	return role, team
}
