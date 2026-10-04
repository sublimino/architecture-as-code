// Package tenancy is the single tenant-binding rule shared by the HTTP ingest path
// (api.bindWriteTenancy) and the in-process collector sink (collectors.BindTenant).
// SLAWS v2 D7: one binder, two paths, no divergence.
package tenancy

import (
	"errors"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Label is the observation label that names the owning tenant.
const Label = "tenant_id"

// ErrTenantMismatch is a write naming a tenant other than the writer's, or a writer with no
// tenant at all. Both paths surface this same value so callers can errors.Is it.
var ErrTenantMismatch = errors.New("tenant_mismatch")

// BindObservations enforces write tenancy on a batch in place.
//
// allowCrossTenant keeps every observation's tenant as sent (the HTTP cross_tenant_write
// grant). Otherwise tenantID must be non-empty; an untagged observation is stamped with it and
// one naming any other tenant refuses the whole batch before anything is mutated.
func BindObservations(tenantID string, allowCrossTenant bool, observations []model.Observation) error {
	if allowCrossTenant {
		return nil
	}
	if tenantID == "" {
		return ErrTenantMismatch
	}
	for i := range observations {
		if t, set := observations[i].Labels[Label]; set && t != tenantID {
			return ErrTenantMismatch
		}
	}
	for i := range observations {
		labels := make(map[string]string, len(observations[i].Labels)+1)
		for k, v := range observations[i].Labels {
			labels[k] = v
		}
		labels[Label] = tenantID
		observations[i].Labels = labels
	}
	return nil
}
