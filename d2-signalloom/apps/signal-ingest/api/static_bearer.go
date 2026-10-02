package api

// TEMPORARY — remove by StaticBearerSunset.
//
// This file exists for one reason: the stun-sentinel correlator posts its
// observations with a static bearer token compiled into its binary
// (DefaultBearerToken in d2-signalloom/apps/stun-sentinel/pkg/correlator/
// ebpf_correlator.go), and signal-ingest only accepts JWT-SVIDs. Every
// correlator POST is therefore a 401 and no observation lands.
//
// The agreed stopgap is to teach signal-ingest about exactly one static
// credential while the correlator is moved onto the JWT-SVID it already has a
// binding for. Everything here is built so the stopgap cannot quietly become
// permanent or quietly become broad:
//
//   - It is absent unless every SIGNAL_AUTH_STATIC_BEARER_* variable is set.
//     No variables means byte-identical behaviour to a build without this file.
//   - A partially configured credential refuses startup. There is no path by
//     which a missing principal or an empty token degrades to accept-anything.
//   - The credential carries one principal, one tenant and an explicit
//     permission list validated against the real vocabulary. It never consults
//     AuthConfig.Bindings, so it cannot inherit a JWT principal's scope.
//   - The subject may not be a SPIFFE ID, so an audit record produced by this
//     credential can never be mistaken for one produced by a verified SVID.
//   - It carries a deadline, enforced at request time, and
//     TestStaticBearerSunsetHasNotPassed fails once that deadline passes.
//
// Residual risk, accepted for this phase: this is a shared secret. Anything
// that can reach signal-ingest and knows the string can write observations and
// seed collectors for the configured tenant. It is not a secret in any real
// sense — the value is a literal in the correlator's source and therefore in
// git and in the image — so the bound is the scope and the deadline, not the
// confidentiality of the token.

import (
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
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

// minStaticBearerTokenLength rejects a token short enough to be guessed. The
// correlator's token is 25 bytes.
const minStaticBearerTokenLength = 16

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

// StaticBearerConfig is one static credential: the token, the single principal
// it maps to, and exactly the permissions that principal gets.
type StaticBearerConfig struct {
	Token       string
	Subject     string
	TenantID    string
	Permissions []Permission
	ActorIDs    []string
	ExpiresAt   time.Time
}

// StaticBearerAuthenticator accepts one configured token and delegates
// everything else, unchanged, to the JWT authenticator.
type StaticBearerAuthenticator struct {
	delegate Authenticator
	now      func() time.Time

	// digest is SHA-256 of the token. Holding the digest rather than the
	// plaintext means comparison is over two fixed-length values (so it leaks
	// neither content nor length through timing) and a struct dump cannot
	// disclose the secret.
	digest    [sha256.Size]byte
	binding   PrincipalBinding
	subject   string
	expiresAt time.Time
}

// NewStaticBearerAuthenticator validates cfg and wraps delegate. Any defect in
// cfg is an error: the caller is expected to refuse startup, never to continue
// without the gate it asked for.
func NewStaticBearerAuthenticator(cfg StaticBearerConfig, delegate Authenticator) (*StaticBearerAuthenticator, error) {
	if delegate == nil {
		return nil, errors.New("static bearer requires a delegate authenticator")
	}
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	slog.Warn("TEMPORARY static bearer credential enabled; a shared secret now authenticates one principal",
		"subject", cfg.Subject,
		"tenant", cfg.TenantID,
		"permissions", cfg.Permissions,
		"actor_ids", cfg.ActorIDs,
		"expires", cfg.ExpiresAt.UTC().Format(time.DateOnly),
		"remove_by", StaticBearerSunset,
		"replacement", "JWT-SVID for spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel")
	return &StaticBearerAuthenticator{
		delegate:  delegate,
		now:       time.Now,
		digest:    sha256.Sum256([]byte(cfg.Token)),
		subject:   cfg.Subject,
		binding:   PrincipalBinding{TenantID: cfg.TenantID, Permissions: cfg.Permissions, ActorIDs: cfg.ActorIDs},
		expiresAt: cfg.ExpiresAt,
	}, nil
}

func (c StaticBearerConfig) validate() error {
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
	if !hmac.Equal(presented[:], a.digest[:]) {
		return a.delegate.Authenticate(r)
	}
	if !a.now().Before(a.expiresAt) {
		return Principal{}, ErrStaticBearerExpired
	}
	// Fresh maps per request: a handler must not be able to widen a later
	// request's scope. Mirrors how JWTAuthenticator builds its principal.
	p := Principal{
		Subject:     a.subject,
		TenantID:    a.binding.TenantID,
		ExpiresAt:   a.expiresAt,
		Permissions: make(map[Permission]bool, len(a.binding.Permissions)),
		ActorIDs:    make(map[string]bool, len(a.binding.ActorIDs)),
	}
	for _, permission := range a.binding.Permissions {
		p.Permissions[permission] = true
	}
	for _, actor := range a.binding.ActorIDs {
		p.ActorIDs[actor] = true
	}
	return p, nil
}

// StaticBearerConfigFromEnv reads the SIGNAL_AUTH_STATIC_BEARER_* variables.
//
// It returns (nil, nil) when none of them is set — the shipped default, in
// which signal-ingest behaves exactly as it does without this file. If any one
// of them is set, all of the required ones must be present and valid, and
// anything else is an error for the caller to refuse startup on. There is
// deliberately no middle ground: a half-configured credential is a
// misconfiguration, not a reason to accept a weaker gate.
func StaticBearerConfigFromEnv() (*StaticBearerConfig, error) {
	token := os.Getenv("SIGNAL_AUTH_STATIC_BEARER_TOKEN")
	subject := os.Getenv("SIGNAL_AUTH_STATIC_BEARER_SUBJECT")
	tenant := os.Getenv("SIGNAL_AUTH_STATIC_BEARER_TENANT")
	permissions := os.Getenv("SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS")
	actors := os.Getenv("SIGNAL_AUTH_STATIC_BEARER_ACTORS")
	expires := os.Getenv("SIGNAL_AUTH_STATIC_BEARER_EXPIRES")

	if token == "" && subject == "" && tenant == "" && permissions == "" && actors == "" && expires == "" {
		return nil, nil
	}
	if expires == "" {
		return nil, errors.New("SIGNAL_AUTH_STATIC_BEARER_EXPIRES is required when any SIGNAL_AUTH_STATIC_BEARER_* variable is set")
	}
	expiresAt, err := time.Parse(time.DateOnly, expires)
	if err != nil {
		return nil, fmt.Errorf("SIGNAL_AUTH_STATIC_BEARER_EXPIRES must be a YYYY-MM-DD date, got %q", expires)
	}
	cfg := StaticBearerConfig{
		Token:       token,
		Subject:     subject,
		TenantID:    tenant,
		Permissions: parsePermissionList(permissions),
		ActorIDs:    splitAndTrim(actors),
		ExpiresAt:   expiresAt,
	}
	if err := cfg.validate(); err != nil {
		// cfg.validate never includes the token in its message, so this
		// wrapping cannot leak it either.
		return nil, fmt.Errorf("SIGNAL_AUTH_STATIC_BEARER_* configuration invalid: %w", err)
	}
	return &cfg, nil
}

func parsePermissionList(raw string) []Permission {
	parts := splitAndTrim(raw)
	out := make([]Permission, 0, len(parts))
	for _, p := range parts {
		out = append(out, Permission(p))
	}
	return out
}

func splitAndTrim(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}
