package api

// Named static keys: inbound authentication for callers that cannot hold a JWT-SVID.
//
// Andy, 2026-10-02: "keep inbound authentication as simple as possible so we can do it from lots
// of different places … a bearer token with a long key is the simplest way … I specifically don't
// want the SPIRE server to run in the remote signal generating endpoint … we'll have to use a
// static key for now." So each caller gets its own key, and everything here is built so a key
// cannot quietly become broad:
//
//   - Absent unless SIGNAL_AUTH_STATIC_KEYS names keys (static_keys.go). No keys means
//     byte-identical behaviour to a build without this file.
//   - Each key carries one principal, one tenant and an explicit permission list validated
//     against the real vocabulary. It never consults AuthConfig.Bindings, so it cannot inherit a
//     JWT principal's scope. Keys are distinct: no shared names, no shared values.
//   - The subject may not be a SPIFFE ID, so an audit record produced by a key can never be
//     mistaken for one produced by a verified SVID.
//   - Every key carries a deadline, enforced at request time.
//   - The value is held only as a SHA-256 digest and is never logged; the key NAME is logged on
//     every authentication.
//
// Residual risk: a key is a shared secret. Anything that holds it and can reach signal-ingest acts
// as that key's principal until its expiry. The bound is the scope, the expiry and the Secret.

import (
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync/atomic"
	"time"
)

// MaxStaticKeyLifetime bounds every key's expiry from the moment it is loaded. Lead decision
// 2026-10-02 replacing the fixed global sunset (2026-11-12), which would have 401'd every caller on
// one day with no rotation path short of a code change: a key now lives at most 90 days, the
// issuer mints the expiry beside the value, and a rotation renews both.
const MaxStaticKeyLifetime = 90 * 24 * time.Hour

// StaticKeyExpiryWarning is how far ahead of expiry a key is warned about at load.
const StaticKeyExpiryWarning = 14 * 24 * time.Hour

// minStaticBearerTokenLength is the ingest-credential contract's floor: the token
// is ≥32 random bytes minted at bootstrap by scripts/sldc-ingest-bearer.sh. It
// also refuses the retired 25-byte public literal "sentinel-in-cluster-token",
// which was compiled into the correlator and so is in git and every image.
const minStaticBearerTokenLength = 32

// ErrStaticBearerExpired is returned when the configured token is presented
// after its deadline. It maps to 401 like any other bad credential.
var ErrStaticBearerExpired = errors.New("static bearer credential is past its configured expiry")

// KnownPermissions is every permission signal-ingest actually understands.
// An unknown permission grants nothing, which makes a typo in configuration
// silent; StaticBearerConfig validates against this set so it is loud instead.
// TestKnownPermissionsCoversEveryRoute keeps it in step with the routes.
var KnownPermissions = map[Permission]bool{
	PermissionHealth:           true,
	PermissionMetrics:          true,
	PermissionObservationRead:  true,
	PermissionObservationWrite: true,
	PermissionActorList:        true,
	PermissionActorRead:        true,
	PermissionActorWrite:       true,
	PermissionDelegationWrite:  true,
	PermissionAnalysisRead:     true,
	PermissionAnalysisRun:      true,
	PermissionCollectorWrite:   true,
	PermissionAuditWrite:       true,
	PermissionRiskRead:         true,
	PermissionStream:           true,
	PermissionErasureRequest:   true,
	PermissionPrivacyExport:    true,
	PermissionPrivacyAdmin:     true,
	PermissionCrossTenantRead:  true,
	PermissionCrossTenantWrite: true,
	PermissionActForTenant:     true,
	// SLAWS review API. Without these two entries StaticBearerConfig.validate refuses a
	// legitimate grant for the review routes and TestKnownPermissionsCoversEveryRoute fails: an
	// unknown permission grants nothing, so a key configured for policy:read would silently get
	// no access at all.
	PermissionPolicyRead:   true,
	PermissionPolicyReview: true,
}

// StaticBearerConfig is one named static key: its value, the single principal it maps to, and
// exactly the permissions that principal gets. One key per caller.
type StaticBearerConfig struct {
	Name        string
	Token       string
	Subject     string
	TenantID    string
	Permissions []Permission
	ActorIDs    []string
	ExpiresAt   time.Time
}

// staticKeyNamePattern keeps a key name usable as a file name, a Secret-name suffix and a log
// value: no separators, no traversal, no upper case.
var staticKeyNamePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{1,62}$`)

type staticKey struct {
	name string
	// digest is SHA-256 of the key value. Holding the digest rather than the plaintext means
	// comparison is over two fixed-length values (so it leaks neither content nor length through
	// timing) and a struct dump cannot disclose the secret.
	digest    [sha256.Size]byte
	binding   PrincipalBinding
	subject   string
	expiresAt time.Time
}

// StaticBearerAuthenticator accepts the configured named keys and delegates everything else,
// unchanged, to the JWT authenticator.
type StaticBearerAuthenticator struct {
	delegate Authenticator
	now      func() time.Time
	specs    []StaticKeySpec
	dir      string
	keys     atomic.Pointer[[]staticKey]
	onRevoke func(subject string)
	// loadedFp is the directory fingerprint Reload last read the keys from. WatchReload
	// compares each tick against it, so a swap that lands between the constructor's load
	// and the watcher's first tick is still seen; a baseline taken when the watcher starts
	// would silently adopt that swap as current and never reload.
	loadedFp atomic.Pointer[dirFingerprint]
}

// SetRevokeCallback registers a hook called when a key is revoked during Reload.
func (a *StaticBearerAuthenticator) SetRevokeCallback(cb func(subject string)) {
	a.onRevoke = cb
}

// NewStaticBearerAuthenticator is NewStaticKeyAuthenticator for a single key.
func NewStaticBearerAuthenticator(cfg StaticBearerConfig, delegate Authenticator) (*StaticBearerAuthenticator, error) {
	return NewStaticKeyAuthenticator([]StaticBearerConfig{cfg}, delegate)
}

// NewStaticKeyAuthenticator validates every key and wraps delegate. Any defect — an invalid key,
// two keys with one name, two keys with one value — is an error: the caller is expected to refuse
// startup, never to continue without the gate it asked for.
func NewStaticKeyAuthenticator(cfgs []StaticBearerConfig, delegate Authenticator) (*StaticBearerAuthenticator, error) {
	if delegate == nil {
		return nil, errors.New("static keys require a delegate authenticator")
	}
	if len(cfgs) == 0 {
		return nil, errors.New("static key authenticator configured with no keys")
	}
	a := &StaticBearerAuthenticator{delegate: delegate, now: time.Now}
	names := map[string]bool{}
	digests := map[[sha256.Size]byte]string{}
	var keys []staticKey
	for _, cfg := range cfgs {
		if err := cfg.validate(); err != nil {
			return nil, fmt.Errorf("static key %q: %w", cfg.Name, err)
		}
		if names[cfg.Name] {
			return nil, fmt.Errorf("static key %q is configured twice", cfg.Name)
		}
		names[cfg.Name] = true
		digest := sha256.Sum256([]byte(cfg.Token))
		if other, dup := digests[digest]; dup {
			return nil, fmt.Errorf("static keys %q and %q share one value; every caller needs its own key", other, cfg.Name)
		}
		digests[digest] = cfg.Name
		keys = append(keys, staticKey{
			name:      cfg.Name,
			digest:    digest,
			subject:   cfg.Subject,
			binding:   PrincipalBinding{TenantID: cfg.TenantID, Permissions: cfg.Permissions, ActorIDs: cfg.ActorIDs},
			expiresAt: cfg.ExpiresAt,
		})
		a.specs = append(a.specs, StaticKeySpec{
			Name:        cfg.Name,
			Subject:     cfg.Subject,
			Tenant:      cfg.TenantID,
			Permissions: cfg.Permissions,
			ActorIDs:    cfg.ActorIDs,
		})
		slog.Warn("static key enabled; a shared secret authenticates one principal",
			"key", cfg.Name,
			"subject", cfg.Subject,
			"tenant", cfg.TenantID,
			"permissions", cfg.Permissions,
			"actor_ids", cfg.ActorIDs,
			"expires", cfg.ExpiresAt.UTC().Format(time.DateOnly))
	}
	a.keys.Store(&keys)
	return a, nil
}

// NewStaticKeyAuthenticatorWithSpecs creates a StaticBearerAuthenticator from parsed specs and
// a directory path holding key secrets, loading the initial keys via Reload.
func NewStaticKeyAuthenticatorWithSpecs(specs []StaticKeySpec, dir string, delegate Authenticator) (*StaticBearerAuthenticator, error) {
	if delegate == nil {
		return nil, errors.New("static keys require a delegate authenticator")
	}
	if len(specs) == 0 {
		return nil, errors.New("static key authenticator configured with no keys")
	}
	a := &StaticBearerAuthenticator{
		delegate: delegate,
		now:      time.Now,
		specs:    specs,
		dir:      dir,
	}
	emptyKeys := []staticKey{}
	a.keys.Store(&emptyKeys)
	a.Reload(time.Now())
	return a, nil
}

func (c StaticBearerConfig) validate() error {
	if err := c.validateConfig(); err != nil {
		return err
	}
	return c.validateSecret(time.Now())
}

// validateConfig checks the reviewed, versioned half of a key (the ConfigMap spec).
func (c StaticBearerConfig) validateConfig() error {
	if !staticKeyNamePattern.MatchString(c.Name) {
		return fmt.Errorf("static key name %q must match %s", c.Name, staticKeyNamePattern)
	}
	if c.Subject == "" {
		return errors.New("static bearer token must name a principal")
	}
	// A static credential must never be able to present itself as a verified
	// SPIFFE identity, in an audit record or anywhere else.
	if strings.HasPrefix(strings.ToLower(c.Subject), "spiffe://") {
		return errors.New("static bearer principal must not be a SPIFFE ID; it is not a verified SVID")
	}
	if c.TenantID == "" {
		return errors.New("static bearer principal must name a tenant")
	}
	if len(c.Permissions) == 0 {
		return errors.New("static bearer principal must be granted at least one permission")
	}
	for _, p := range c.Permissions {
		if !KnownPermissions[p] {
			return fmt.Errorf("static bearer permission %q is not a signal-ingest permission", p)
		}
	}
	return nil
}

// validateSecret checks the minted half of a key (the Secret): the value and its expiry. The
// lifetime bound is enforced by the binary, so no Secret can make a key effectively permanent.
func (c StaticBearerConfig) validateSecret(now time.Time) error {
	if strings.TrimSpace(c.Token) == "" {
		return errors.New("static bearer token must not be empty")
	}
	if len(c.Token) < minStaticBearerTokenLength {
		return fmt.Errorf("static bearer token must be at least %d bytes", minStaticBearerTokenLength)
	}
	if c.ExpiresAt.IsZero() {
		return errors.New("static bearer credential must carry an expiry; an undated temporary credential is a permanent one")
	}
	if c.ExpiresAt.After(now.Add(MaxStaticKeyLifetime)) {
		return fmt.Errorf("static key expiry %s is more than 90 days away; rotate with a shorter expiry",
			c.ExpiresAt.UTC().Format(time.DateOnly))
	}
	return nil
}

// Authenticate honours the configured token on an exact match and otherwise
// returns the delegate's verdict unchanged.
//
// Precedence, in order:
//  1. Anything other than exactly one "Bearer <value>" Authorization header
//     goes to the delegate untouched. A duplicate header, a non-Bearer scheme
//     and a missing header therefore keep exactly the status they have today;
//     the static token cannot rescue a malformed request.
//  2. An exact match on the configured token yields the static principal,
//     unless the credential is past its deadline.
//  3. Every other value — including a malformed or expired JWT — goes to the
//     delegate untouched.
func (a *StaticBearerAuthenticator) Authenticate(r *http.Request) (Principal, error) {
	k, ok := a.match(r)
	if !ok {
		return a.delegate.Authenticate(r)
	}
	if !a.now().Before(k.expiresAt) {
		slog.Warn("static key refused: past its expiry", "key", k.name, "expired", k.expiresAt.UTC().Format(time.DateOnly))
		return Principal{}, ErrStaticBearerExpired
	}
	slog.Info("static key authenticated", "key", k.name, "subject", k.subject)
	// Fresh maps per request: a handler must not be able to widen a later
	// request's scope. Mirrors how JWTAuthenticator builds its principal.
	p := Principal{
		Subject:     k.subject,
		TenantID:    k.binding.TenantID,
		ExpiresAt:   k.expiresAt,
		Permissions: make(map[Permission]bool, len(k.binding.Permissions)),
		ActorIDs:    make(map[string]bool, len(k.binding.ActorIDs)),
	}
	for _, permission := range k.binding.Permissions {
		p.Permissions[permission] = true
	}
	for _, actor := range k.binding.ActorIDs {
		p.ActorIDs[actor] = true
	}
	if !p.Permissions[PermissionActForTenant] {
		return p, nil // ActingTenantHeader is ignored for every other key
	}

	// A gateway acts for the tenant it names. ActingTenantGate answers a missing or malformed
	// header with 400 before this runs; failing closed here keeps that true without the gate.
	acting, code := actingTenant(r)
	if code != "" {
		return Principal{}, ErrInvalidCredential
	}
	if acting == "*" {
		if !p.Permissions[PermissionCrossTenantRead] {
			return Principal{}, ErrInvalidCredential
		}
		// Reads across tenants; writes need a tenant, so with none they are refused.
		p.TenantID = ""
		slog.Info("static key acting for ALL tenants", "key", k.name,
			"user_subject", r.Header.Get(ActingSubjectHeader))
		return p, nil
	}
	// Acting for one tenant: the cross-read held for "*" must not leak into a scoped request.
	delete(p.Permissions, PermissionCrossTenantRead)
	p.TenantID = acting
	return p, nil
}

// match finds the key the request presents, comparing against every key without stopping at a
// match, so the time taken says neither which key nor whether any key matched.
func (a *StaticBearerAuthenticator) match(r *http.Request) (staticKey, bool) {
	values := r.Header.Values("Authorization")
	if len(values) != 1 || !strings.HasPrefix(values[0], "Bearer ") {
		return staticKey{}, false
	}
	presented := sha256.Sum256([]byte(strings.TrimPrefix(values[0], "Bearer ")))
	keysPtr := a.keys.Load()
	if keysPtr == nil {
		return staticKey{}, false
	}
	keys := *keysPtr
	match := -1
	for i := range keys {
		if hmac.Equal(presented[:], keys[i].digest[:]) {
			match = i
		}
	}
	if match < 0 {
		return staticKey{}, false
	}
	return keys[match], true
}

// ActingTenantGate answers, before authorization runs, the two refusals a gateway key's request
// can earn from its acting tenant: 400 for a missing or malformed ActingTenantHeader (never an
// unscoped read), and 403 cross_tenant_read_required for "*" from a key without cross-read. Every
// other request passes untouched; for keys without tenant:act-for the header is ignored.
func (a *StaticBearerAuthenticator) ActingTenantGate(next http.Handler) http.Handler {
	return headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		k, ok := a.match(r)
		if !ok || !k.grants(PermissionActForTenant) || !a.now().Before(k.expiresAt) {
			next.ServeHTTP(w, r)
			return
		}
		acting, code := actingTenant(r)
		if code != "" {
			slog.Warn("gateway request refused", "key", k.name, "reason", code)
			if r != nil && r.Body != nil {
				_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 4096))
				_ = r.Body.Close()
			}
			writeError(w, http.StatusBadRequest, code)
			return
		}
		if acting == "*" && !k.grants(PermissionCrossTenantRead) {
			slog.Warn("gateway request refused", "key", k.name, "reason", "cross_tenant_read_required")
			if r != nil && r.Body != nil {
				_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 4096))
				_ = r.Body.Close()
			}
			writeError(w, http.StatusForbidden, "cross_tenant_read_required")
			return
		}
		next.ServeHTTP(w, r)
	}))
}

func (k staticKey) grants(p Permission) bool {
	for _, have := range k.binding.Permissions {
		if have == p {
			return true
		}
	}
	return false
}
