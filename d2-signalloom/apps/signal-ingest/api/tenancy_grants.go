package api

import (
	"net/http"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Tenancy grants. Permissions in the ordinary sense, so a static key or a JWT binding names them
// explicitly, and api/auth.go (the router and the JWT path) needs no change.
const (
	// PermissionCrossTenantRead lets a principal read observations of every tenant, and untagged
	// observations, instead of only its own tenant's.
	PermissionCrossTenantRead Permission = "tenant:cross-read"
)

// ObservationTenantLabel is the only tenant attribution an observation carries.
const ObservationTenantLabel = "tenant_id"

// observationReadScope reports which tenant's observations the request's principal may read, or
// all=true for a principal holding PermissionCrossTenantRead. A request without a principal reads
// nothing: tenant "" matches no row, because an untagged row is cross-tenant only.
func observationReadScope(r *http.Request) (tenant string, all bool) {
	p, ok := PrincipalFromContext(r.Context())
	if !ok {
		return "", false
	}
	if p.Permissions[PermissionCrossTenantRead] {
		return "", true
	}
	return p.TenantID, false
}

// scopeObservations keeps the rows the scope may see, then applies limit (0 = no limit), so a page
// of other tenants' rows never starves the caller's own.
func scopeObservations(obs []model.Observation, tenant string, all bool, limit int) []model.Observation {
	out := obs
	if !all {
		out = make([]model.Observation, 0, len(obs))
		for _, o := range obs {
			if tenant != "" && o.Labels[ObservationTenantLabel] == tenant {
				out = append(out, o)
			}
		}
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}
