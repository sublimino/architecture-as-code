package api

// Tenancy grants. Permissions in the ordinary sense, so a static key or a JWT binding names them
// explicitly, and api/auth.go (the router and the JWT path) needs no change.
const (
	// PermissionCrossTenantRead lets a principal read observations of every tenant, and untagged
	// observations, instead of only its own tenant's.
	PermissionCrossTenantRead Permission = "tenant:cross-read"
)
