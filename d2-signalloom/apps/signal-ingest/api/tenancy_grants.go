package api

import (
	"context"
	"net/http"
	"regexp"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/tenancy"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Tenancy grants. Permissions in the ordinary sense, so a static key or a JWT binding names them
// explicitly, and api/auth.go (the router and the JWT path) needs no change.
const (
	// PermissionCrossTenantRead lets a principal read observations of every tenant, and untagged
	// observations, instead of only its own tenant's.
	PermissionCrossTenantRead Permission = "tenant:cross-read"
	// PermissionCrossTenantWrite lets a principal write observations naming any tenant (or none),
	// as the stun-sentinel does for every workload it watches. Without it a principal's writes are
	// bound to its own tenant.
	PermissionCrossTenantWrite Permission = "tenant:cross-write"
	// PermissionActForTenant lets a gateway (fe-signalloom) act for the tenant it names in
	// ActingTenantHeader: the request is scoped to that tenant, never to the gateway's own. Only a
	// static key can hold it in practice; for every principal without it the header is ignored.
	PermissionActForTenant Permission = "tenant:act-for"
)

// ActingTenantHeader carries the verified user tenant a gateway acts for, or "*" for a superadmin
// (honoured only with PermissionCrossTenantRead as well).
const ActingTenantHeader = "X-SignalLoom-Acting-Tenant"

// ActingSubjectHeader carries the gateway's user subject. It grants nothing; it is logged on
// every all-tenants request so a superadmin read is attributable to a person.
const ActingSubjectHeader = "X-SignalLoom-Acting-Subject"

// actingTenantPattern is the tenant-id shape: ASCII only, so a look-alike cannot pass for another
// tenant, and no leading underscore, so the quarantine tenant cannot be acted for.
var actingTenantPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

// actingTenant reads ActingTenantHeader. It returns the tenant ("*" for all) or an error code for
// the 400 the gate answers with.
func actingTenant(r *http.Request) (string, string) {
	values := r.Header.Values(ActingTenantHeader)
	switch {
	case len(values) == 0 || (len(values) == 1 && values[0] == ""):
		return "", "acting_tenant_required"
	case len(values) > 1:
		return "", "acting_tenant_invalid"
	case values[0] == "*" || actingTenantPattern.MatchString(values[0]):
		return values[0], ""
	default:
		return "", "acting_tenant_invalid"
	}
}

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

// actorScope decides actor visibility for one request. An actor's tenant is the tenant of the
// observations it was correlated from: a scoped principal sees it only when its evidence chain is
// non-empty and every evidence observation is labelled with the principal's tenant. An actor with
// mixed, unknown or no evidence is cross-tenant only.
// The tenant of each evidence observation is resolved on demand, by ID, and memoised for the life
// of the scope. It used to be built by reading the WHOLE store into a map of every observation ID
// to its tenant, on every request that touched an actor — so answering "may this principal see
// these 3 actors?" materialised millions of rows to consult a few dozen of them. That is the same
// defect as api.Handlers.observationByID and it shared the same consequence: GET
// /api/v1/store/stats issued two full-store scans per request (this one and its own), and
// signal-ingest was OOM-killed 13 times at a 2 GiB limit on kind-osramp.
//
// Resolution is batched: filter() asks for every evidence ID of every actor in one query, so the
// cost is one store read per request rather than one per actor. Memoising the MISS as well as the
// hit matters — an unknown evidence ID means "not my tenant", and without a negative cache a
// missing row would be re-queried on every visibility check.
type actorScope struct {
	all      bool
	tenant   string
	resolver *obsTenantResolver
}

// obsTenantResolver answers "which tenant owns this observation ID?" for a bounded set of IDs.
type obsTenantResolver struct {
	ctx    context.Context
	store  store.SignalStore
	tenant map[string]string // observation ID -> tenant label; "" records a resolved absence
}

// resolve loads the tenant label for every id not already known. A nil error with an id still
// absent from the map cannot happen: every requested id is recorded, as a hit or as a "".
func (res *obsTenantResolver) resolve(ids []string) error {
	want := make([]string, 0, len(ids))
	for _, id := range ids {
		if _, known := res.tenant[id]; !known {
			want = append(want, id)
		}
	}
	if len(want) == 0 {
		return nil
	}
	rows, err := res.store.QueryRange(res.ctx, store.LookupIDs(want...))
	if err != nil {
		return err
	}
	for i := range rows {
		res.tenant[rows[i].ID] = rows[i].Labels[ObservationTenantLabel]
	}
	// Record the misses, so an ID the store does not hold is answered from the map next time
	// instead of re-querying. An absent observation is not owned by the caller's tenant, which
	// the "" sentinel says, because a real tenant label is never empty.
	for _, id := range want {
		if _, known := res.tenant[id]; !known {
			res.tenant[id] = ""
		}
	}
	return nil
}

func (h *Handlers) actorScopeFor(r *http.Request) (actorScope, error) {
	tenant, all := observationReadScope(r)
	s := actorScope{all: all, tenant: tenant}
	if all {
		// A cross-tenant reader sees every actor, so no evidence tenancy is ever consulted and
		// the store is not read at all.
		return s, nil
	}
	s.resolver = &obsTenantResolver{
		ctx:    r.Context(),
		store:  h.Store,
		tenant: make(map[string]string),
	}
	return s, nil
}

// evidenceIDs returns every observation ID the given actors cite.
func evidenceIDs(actors []*model.ProvisionalActor) []string {
	var ids []string
	for _, a := range actors {
		if a == nil {
			continue
		}
		for _, ev := range a.EvidenceChain {
			ids = append(ids, ev.ObservationID)
		}
	}
	return ids
}

func (s actorScope) visible(a *model.ProvisionalActor) (bool, error) {
	if a == nil {
		return false, nil
	}
	if s.all {
		return true, nil
	}
	if s.tenant == "" || len(a.EvidenceChain) == 0 {
		return false, nil
	}
	if err := s.resolver.resolve(evidenceIDs([]*model.ProvisionalActor{a})); err != nil {
		return false, err
	}
	for _, ev := range a.EvidenceChain {
		if s.resolver.tenant[ev.ObservationID] != s.tenant {
			return false, nil
		}
	}
	return true, nil
}

func (s actorScope) filter(actors []*model.ProvisionalActor) ([]*model.ProvisionalActor, error) {
	if s.all {
		return actors, nil
	}
	if s.tenant == "" {
		// Nothing is visible, so there is no evidence worth resolving.
		return []*model.ProvisionalActor{}, nil
	}
	// One store read for the whole page, not one per actor.
	if err := s.resolver.resolve(evidenceIDs(actors)); err != nil {
		return nil, err
	}
	out := make([]*model.ProvisionalActor, 0, len(actors))
	for _, a := range actors {
		ok, err := s.visible(a)
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, a)
		}
	}
	return out, nil
}

// scopedActors is Engine.GetActors as the request's principal may see it.
func (h *Handlers) scopedActors(r *http.Request) ([]*model.ProvisionalActor, error) {
	s, err := h.actorScopeFor(r)
	if err != nil {
		return nil, err
	}
	return s.filter(h.Engine.GetActors())
}

// scopedActor is Engine.GetActor as the request's principal may see it: an actor of another
// tenant is nil, exactly like an absent one, so the reply cannot confirm it exists.
func (h *Handlers) scopedActor(r *http.Request, id string) (*model.ProvisionalActor, error) {
	s, err := h.actorScopeFor(r)
	if err != nil {
		return nil, err
	}
	a := h.Engine.GetActor(id)
	ok, err := s.visible(a)
	if err != nil {
		return nil, err
	}
	if ok {
		return a, nil
	}
	return nil, nil
}

// errTenantMismatch is a write naming a tenant other than the writer's. It is the shared
// tenancy.ErrTenantMismatch so the HTTP path and the collector sink fail identically (SLAWS D7).
var errTenantMismatch = tenancy.ErrTenantMismatch

// bindWriteTenancy enforces write tenancy on a batch in place. A principal holding
// PermissionCrossTenantWrite keeps every observation's tenant as sent. Any other principal writes
// only its own tenant: an untagged observation is stamped with it, and one naming any other tenant
// (including the quarantine tenant, or a look-alike) refuses the whole batch. A request with no
// principal or no tenant writes nothing. The rule itself lives in package tenancy and is the same
// function collectors.BindTenant applies to in-process collectors.
func bindWriteTenancy(r *http.Request, observations []model.Observation) error {
	p, ok := PrincipalFromContext(r.Context())
	if !ok {
		return errTenantMismatch
	}
	return tenancy.BindObservations(p.TenantID, p.Permissions[PermissionCrossTenantWrite], observations)
}

// requireCrossTenantRead refuses a request over data that carries no tenant at all (the risk
// catalogue) unless its principal reads across tenants: 403 cross_tenant_read_required, never a
// silently partial or cross-tenant answer.
func requireCrossTenantRead(w http.ResponseWriter, r *http.Request) bool {
	if _, all := observationReadScope(r); all {
		return true
	}
	writeError(w, http.StatusForbidden, "cross_tenant_read_required")
	return false
}

// resolveAuditTenant extracts the tenant ID from the authenticated principal or tenant context,
// falling back to "tenant-demo" only when no tenant context exists (e.g. unauthenticated test harnesses).
func resolveAuditTenant(r *http.Request) string {
	if p, ok := PrincipalFromContext(r.Context()); ok && p.TenantID != "" {
		return p.TenantID
	}
	if tc, ok := TenantContextFromContext(r.Context()); ok && tc.TenantID != "" {
		return tc.TenantID
	}
	return "tenant-demo"
}
