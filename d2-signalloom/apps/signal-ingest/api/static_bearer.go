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
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// StaticBearerSunset is the date the static-bearer credential must be gone, as
// agreed when it was introduced. It is the single source of truth for the
// deadline: the deployed ConfigMap's SIGNAL_AUTH_STATIC_BEARER_EXPIRES and its
// signalloom.ai/expires annotation are asserted equal to it by
// TestStaticBearerDeployedExpiryMatchesSunset, and
// TestStaticBearerSunsetHasNotPassed fails once it is reached.
const StaticBearerSunset = "2026-11-12"

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
	keys     []staticKey
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
		a.keys = append(a.keys, staticKey{
			name:      cfg.Name,
			digest:    digest,
			subject:   cfg.Subject,
			binding:   PrincipalBinding{TenantID: cfg.TenantID, Permissions: cfg.Permissions, ActorIDs: cfg.ActorIDs},
			expiresAt: cfg.ExpiresAt,
		})
		slog.Warn("static key enabled; a shared secret authenticates one principal",
			"key", cfg.Name,
			"subject", cfg.Subject,
			"tenant", cfg.TenantID,
			"permissions", cfg.Permissions,
			"actor_ids", cfg.ActorIDs,
			"expires", cfg.ExpiresAt.UTC().Format(time.DateOnly),
			"remove_by", StaticBearerSunset)
	}
	return a, nil
}

func (c StaticBearerConfig) validate() error {
	if !staticKeyNamePattern.MatchString(c.Name) {
		return fmt.Errorf("static key name %q must match %s", c.Name, staticKeyNamePattern)
	}
	if strings.TrimSpace(c.Token) == "" {
		return errors.New("static bearer token must not be empty")
	}
	if len(c.Token) < minStaticBearerTokenLength {
		return fmt.Errorf("static bearer token must be at least %d bytes", minStaticBearerTokenLength)
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
	if c.ExpiresAt.IsZero() {
		return errors.New("static bearer credential must carry an expiry; an undated temporary credential is a permanent one")
	}
	// The sunset is enforced by the binary, not only by YAML: otherwise editing
	// the ConfigMap's expiry would extend a shared secret with no code change.
	sunset, err := time.Parse(time.DateOnly, StaticBearerSunset)
	if err != nil {
		return fmt.Errorf("StaticBearerSunset %q is not a date: %w", StaticBearerSunset, err)
	}
	if c.ExpiresAt.After(sunset) {
		return fmt.Errorf("static bearer expiry %s is later than the sunset %s; move the correlator to a JWT-SVID instead of extending it",
			c.ExpiresAt.UTC().Format(time.DateOnly), StaticBearerSunset)
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
	values := r.Header.Values("Authorization")
	if len(values) != 1 || !strings.HasPrefix(values[0], "Bearer ") {
		return a.delegate.Authenticate(r)
	}
	presented := sha256.Sum256([]byte(strings.TrimPrefix(values[0], "Bearer ")))
	// Compare against every key without stopping at a match, so the time taken says neither
	// which key nor whether any key matched.
	match := -1
	for i := range a.keys {
		if hmac.Equal(presented[:], a.keys[i].digest[:]) {
			match = i
		}
	}
	if match < 0 {
		return a.delegate.Authenticate(r)
	}
	k := a.keys[match]
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
	return p, nil
}
