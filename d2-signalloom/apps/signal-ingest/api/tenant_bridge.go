package api

import (
	"context"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
)

// SLDP-P2-2: the single point at which an authenticated tenancy becomes a database tenant claim.
//
// This lives in api rather than in identity because api already imports identity; the reverse would
// not build. That constraint turns out to be the right shape anyway: identity has no way to reach
// an HTTP request, so there is no code path in the repository layer that could read a tenant out of
// one even by accident.
//
// The bridge is deliberately total and dumb. It reads the TenantContext that ProtectedRouter.
// authorize placed on the request context -- which it derived from the verified principal's
// TenantID and Subject -- and copies both fields verbatim. It consults no header, no query
// parameter, no path value and no body field. An attacker who sets X-Tenant-ID influences nothing
// here because nothing here reads the request at all; the only input is the context value that only
// the authenticated path writes.

// TenantClaimFromRequestContext derives the identity-layer tenant claim from the authenticated
// principal binding established by the authorization middleware.
//
// It returns ok=false when the context carries no TenantContext -- an unauthenticated path, or a
// handler reached without going through ProtectedRouter. That is a refusal, not a default: callers
// must treat it as "no tenant", and the repository's WithTenant will return ErrNoTenantClaim rather
// than running unscoped.
func TenantClaimFromRequestContext(ctx context.Context) (identity.TenantClaim, bool) {
	tc, ok := TenantContextFromContext(ctx)
	if !ok {
		return identity.TenantClaim{}, false
	}
	claim, err := identity.NewTenantClaim(tc.TenantID, tc.Principal)
	if err != nil {
		// A TenantContext with an empty tenant or an empty principal is not a claim we are willing
		// to guess at. Failing closed here is what keeps a half-populated principal from producing
		// a session that reads rows tagged with the empty string.
		return identity.TenantClaim{}, false
	}
	return claim, true
}

// WithIdentityTenantClaim copies the authenticated tenancy onto the context in the form the
// identity repository consumes, and returns the context unchanged when there is nothing to copy.
//
// Returning the context unchanged rather than one carrying a zero claim is deliberate: a zero claim
// on the context would make TenantClaimFromContext report ok=true for an empty tenant in some
// future refactor, and "present but empty" is the shape that turns a refusal into a silent
// unscoped read.
func WithIdentityTenantClaim(ctx context.Context) context.Context {
	claim, ok := TenantClaimFromRequestContext(ctx)
	if !ok {
		return ctx
	}
	return identity.WithTenantClaim(ctx, claim)
}
