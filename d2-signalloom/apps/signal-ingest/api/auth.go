package api

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	cryptorand "crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	apiaudit "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

type Permission string

const (
	PermissionHealth           Permission = "health:read"
	PermissionMetrics          Permission = "metrics:read"
	PermissionObservationRead  Permission = "observations:read"
	PermissionObservationWrite Permission = "observations:write"
	PermissionActorList        Permission = "actors:list"
	PermissionActorRead        Permission = "actors:read"
	PermissionActorWrite       Permission = "actors:write"
	PermissionDelegationWrite  Permission = "delegations:write"
	PermissionAnalysisRead     Permission = "analysis:read"
	PermissionAnalysisRun      Permission = "analysis:run"
	PermissionCollectorWrite   Permission = "collectors:write"
	PermissionAuditWrite       Permission = "audit:write"
	PermissionRiskRead         Permission = "risk:read"
	PermissionStream           Permission = "stream:read"
	// PermissionErasureRequest gates the GDPR Article 17 erasure route (SLDP-P3-2). It is
	// deliberately its own permission rather than folded into PermissionActorWrite: erasure
	// destroys forensic attribution, so the set of principals who may request it must be
	// narrowable independently of the set who may edit an actor.
	PermissionErasureRequest Permission = "erasure:request"
	// PermissionPrivacyExport gates GDPR Article 15 access and Article 20 data portability export routes (SLDP-P5-3).
	PermissionPrivacyExport Permission = "privacy:export"
	// PermissionPrivacyAdmin gates administrative DPO oversight and third-party data subject exports (SLDP-P5-3).
	PermissionPrivacyAdmin Permission = "privacy:admin"
)

var (
	ErrMissingCredential = errors.New("missing bearer JWT-SVID")
	ErrInvalidCredential = errors.New("invalid JWT-SVID")
	ErrUnboundPrincipal  = errors.New("verified SPIFFE subject has no trusted binding")
)

type PrincipalBinding struct {
	TenantID    string       `json:"tenant_id"`
	Permissions []Permission `json:"permissions"`
	ActorIDs    []string     `json:"actor_ids,omitempty"`
}
type AuthConfig struct {
	// TrustDomain scopes every key in Keys to exactly one SPIFFE trust domain.
	// SIGNAL_AUTH_JWKS must contain authorities for this domain only.
	Audience, TrustDomain string
	Keys                  map[string]any
	Bindings              map[string]PrincipalBinding
}
type Principal struct {
	Subject, TenantID string
	ExpiresAt         time.Time
	Permissions       map[Permission]bool
	ActorIDs          map[string]bool
}
type Authenticator interface {
	Authenticate(*http.Request) (Principal, error)
}

type TenantContext struct {
	TenantID  string
	Principal string
}
type tenantContextKey struct{}
type principalContextKey struct{}

func WithTenantContext(ctx context.Context, tc TenantContext) context.Context {
	return context.WithValue(ctx, tenantContextKey{}, tc)
}
func TenantContextFromContext(ctx context.Context) (TenantContext, bool) {
	tc, ok := ctx.Value(tenantContextKey{}).(TenantContext)
	return tc, ok
}
func PrincipalFromContext(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalContextKey{}).(Principal)
	return p, ok
}

type JWTAuthenticator struct {
	cfg AuthConfig
	now func() time.Time
}

func NewJWTAuthenticator(cfg AuthConfig) (*JWTAuthenticator, error) {
	if cfg.Audience == "" || cfg.TrustDomain == "" || len(cfg.Keys) == 0 || len(cfg.Bindings) == 0 {
		return nil, errors.New("audience, trust domain, trust keys, and principal bindings are required")
	}
	if !validTrustDomain(cfg.TrustDomain) {
		return nil, errors.New("invalid SPIFFE trust domain")
	}
	for subject, b := range cfg.Bindings {
		if !validSPIFFEForDomain(subject, cfg.TrustDomain) || b.TenantID == "" {
			return nil, fmt.Errorf("invalid binding for %q", subject)
		}
	}
	for kid, key := range cfg.Keys {
		if kid == "" {
			return nil, errors.New("key ID must not be empty")
		}
		switch k := key.(type) {
		case *ecdsa.PublicKey:
			if k.Curve != elliptic.P256() {
				return nil, fmt.Errorf("key %q must use P-256", kid)
			}
		case *rsa.PublicKey:
			if k.N == nil || k.N.BitLen() < 2048 || k.E < 3 || k.E%2 == 0 {
				return nil, fmt.Errorf("key %q must use RSA-2048 or stronger", kid)
			}
		default:
			return nil, fmt.Errorf("key %q has unsupported type", kid)
		}
	}
	return &JWTAuthenticator{cfg: cfg, now: time.Now}, nil
}

func (a *JWTAuthenticator) Authenticate(r *http.Request) (Principal, error) {
	values := r.Header.Values("Authorization")
	if len(values) != 1 {
		if len(values) == 0 {
			return Principal{}, ErrMissingCredential
		}
		return Principal{}, ErrInvalidCredential
	}
	h := values[0]
	if !strings.HasPrefix(h, "Bearer ") || len(h) == len("Bearer ") {
		return Principal{}, ErrMissingCredential
	}
	if len(h) > 16*1024 {
		return Principal{}, ErrInvalidCredential
	}
	parts := strings.Split(strings.TrimPrefix(h, "Bearer "), ".")
	if len(parts) != 3 {
		return Principal{}, ErrInvalidCredential
	}
	var header struct {
		Alg  string          `json:"alg"`
		Kid  string          `json:"kid"`
		Crit json.RawMessage `json:"crit"`
	}
	var claims struct {
		Subject   string      `json:"sub"`
		Audience  any         `json:"aud"`
		Expires   json.Number `json:"exp"`
		NotBefore json.Number `json:"nbf"`
	}
	if decodeJWTPart(parts[0], &header) != nil || decodeJWTPart(parts[1], &claims) != nil || header.Kid == "" || header.Crit != nil {
		return Principal{}, ErrInvalidCredential
	}
	key, ok := a.cfg.Keys[header.Kid]
	if !ok {
		return Principal{}, ErrInvalidCredential
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return Principal{}, ErrInvalidCredential
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !verifySignature(header.Alg, key, digest[:], sig) {
		return Principal{}, ErrInvalidCredential
	}
	now := a.now().Unix()
	exp, err := claims.Expires.Int64()
	nbf := int64(0)
	if claims.NotBefore != "" {
		nbf, err = claims.NotBefore.Int64()
	}
	if err != nil || exp <= now || nbf > now || !audienceContains(claims.Audience, a.cfg.Audience) || !validSPIFFEForDomain(claims.Subject, a.cfg.TrustDomain) {
		return Principal{}, ErrInvalidCredential
	}
	binding, ok := a.cfg.Bindings[claims.Subject]
	if !ok {
		return Principal{Subject: claims.Subject, ExpiresAt: time.Unix(exp, 0)}, ErrUnboundPrincipal
	}
	p := Principal{Subject: claims.Subject, TenantID: binding.TenantID, ExpiresAt: time.Unix(exp, 0), Permissions: map[Permission]bool{}, ActorIDs: map[string]bool{}}
	for _, permission := range binding.Permissions {
		p.Permissions[permission] = true
	}
	for _, actor := range binding.ActorIDs {
		p.ActorIDs[actor] = true
	}
	return p, nil
}

func decodeJWTPart(part string, out any) error {
	b, err := base64.RawURLEncoding.DecodeString(part)
	if err != nil {
		return err
	}
	if err := rejectDuplicateObjectKeys(b); err != nil {
		return err
	}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.UseNumber()
	if err := d.Decode(out); err != nil {
		return err
	}
	var trailing any
	if err := d.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("trailing JSON content")
	}
	return nil
}
func rejectDuplicateObjectKeys(b []byte) error {
	d := json.NewDecoder(strings.NewReader(string(b)))
	tok, err := d.Token()
	if err != nil || tok != json.Delim('{') {
		return errors.New("JWT part must be an object")
	}
	seen := map[string]bool{}
	for d.More() {
		tok, err = d.Token()
		key, ok := tok.(string)
		if err != nil || !ok || seen[key] {
			return errors.New("duplicate or invalid JSON key")
		}
		seen[key] = true
		var value json.RawMessage
		if err = d.Decode(&value); err != nil {
			return err
		}
	}
	_, err = d.Token()
	return err
}
func verifySignature(alg string, key any, digest, sig []byte) bool {
	switch k := key.(type) {
	case *ecdsa.PublicKey:
		if subtle.ConstantTimeCompare([]byte(alg), []byte("ES256")) != 1 || len(sig) != 64 {
			return false
		}
		return ecdsa.Verify(k, digest, new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
	case *rsa.PublicKey:
		if subtle.ConstantTimeCompare([]byte(alg), []byte("RS256")) != 1 {
			return false
		}
		return rsa.VerifyPKCS1v15(k, crypto.SHA256, digest, sig) == nil
	default:
		return false
	}
}
func validSPIFFEForDomain(subject, trustDomain string) bool {
	u, err := url.Parse(subject)
	return err == nil && u.Scheme == "spiffe" && u.Opaque == "" && u.User == nil && u.Host == trustDomain && u.RawQuery == "" && u.Fragment == ""
}
func validTrustDomain(trustDomain string) bool {
	u, err := url.Parse("spiffe://" + trustDomain)
	return err == nil && u.User == nil && u.Host == trustDomain && u.Hostname() == trustDomain && u.Port() == "" && u.Path == "" && u.RawQuery == "" && u.Fragment == ""
}
func audienceContains(raw any, expected string) bool {
	switch v := raw.(type) {
	case string:
		return v == expected
	case []any:
		for _, x := range v {
			if s, ok := x.(string); ok && s == expected {
				return true
			}
		}
	}
	return false
}

type routeDefinition struct {
	method, path, pattern string
	permission            Permission
	enumeration           bool
	actorScoped           bool
	handler               http.HandlerFunc
}
type RouteRequirement struct {
	Method, Path string
	Permission   Permission
	Enumeration  bool
}

func (h *Handlers) routeDefinitions(metrics http.Handler) []routeDefinition {
	r := []routeDefinition{
		{"GET", "/healthz", "GET /healthz", PermissionHealth, false, false, handleHealthz}, {"GET", "/health", "GET /health", PermissionHealth, false, false, h.handleHealth}, {"GET", "/api/v1/health", "GET /api/v1/health", PermissionHealth, false, false, h.handleHealth}, {"GET", "/readyz", "GET /readyz", PermissionHealth, false, false, h.handleReadyz},
		{"POST", "/api/v1/observations", "POST /api/v1/observations", PermissionObservationWrite, false, false, h.handleIngestObservations}, {"GET", "/api/v1/observations", "GET /api/v1/observations", PermissionObservationRead, true, false, h.handleQueryObservations},
		{"GET", "/api/v1/actors", "GET /api/v1/actors", PermissionActorList, true, false, h.handleListActors}, {"GET", "/api/v1/actors/{id}", "GET /api/v1/actors/{id}", PermissionActorRead, false, true, h.handleGetActor}, {"GET", "/api/v1/actors/{id}/authorization", "GET /api/v1/actors/{id}/authorization", PermissionActorRead, false, true, h.handleGetActorAuthorization}, {"GET", "/api/v1/authorization", "GET /api/v1/authorization", PermissionActorList, true, false, h.handleQueryAuthorization}, {"POST", "/api/v1/actors/{id}/promote", "POST /api/v1/actors/{id}/promote", PermissionActorWrite, false, true, h.handlePromoteActor},
		{"POST", "/api/v1/delegations", "POST /api/v1/delegations", PermissionDelegationWrite, false, false, h.handleCreateDelegation}, {"POST", "/api/v1/delegations/clamp", "POST /api/v1/delegations/clamp", PermissionDelegationWrite, false, false, h.handleClampDelegation}, {"POST", "/api/v1/delegations/revoke", "POST /api/v1/delegations/revoke", PermissionDelegationWrite, false, false, h.handleRevokeDelegations}, {"DELETE", "/api/v1/delegations", "DELETE /api/v1/delegations", PermissionDelegationWrite, false, false, h.handleClampDelegation},
		{"GET", "/api/v1/coverage", "GET /api/v1/coverage", PermissionAnalysisRead, false, false, handleCoverage}, {"POST", "/api/v1/correlate", "POST /api/v1/correlate", PermissionAnalysisRun, true, false, h.handleCorrelate}, {"POST", "/api/v1/collectors/seed", "POST /api/v1/collectors/seed", PermissionCollectorWrite, false, false, h.handleSeed}, {"GET", "/api/v1/store/stats", "GET /api/v1/store/stats", PermissionAnalysisRead, false, false, h.handleStoreStats},
		{"GET", "/api/v1/stream", "GET /api/v1/stream", PermissionStream, false, false, h.handleStream}, {"GET", "/api/v1/observations/stream", "GET /api/v1/observations/stream", PermissionStream, false, false, h.handleStream}, {"GET", "/stream", "GET /stream", PermissionStream, false, false, h.handleStream}, {"GET", "/observations/stream", "GET /observations/stream", PermissionStream, false, false, h.handleStream},
		{"POST", apiaudit.WebhookPath, "POST " + apiaudit.WebhookPath, PermissionAuditWrite, false, false, h.handleAuditWebhook}, {"POST", "/audit/webhook", "POST /audit/webhook", PermissionAuditWrite, false, false, h.handleAuditWebhook}, {"POST", apiaudit.GKEWebhookPath, "POST " + apiaudit.GKEWebhookPath, PermissionAuditWrite, false, false, h.handleGKECloudLogging}, {"POST", "/audit/gke", "POST /audit/gke", PermissionAuditWrite, false, false, h.handleGKECloudLogging}, {"POST", "/api/v1/audit/nono", "POST /api/v1/audit/nono", PermissionAuditWrite, false, false, h.handleNonoAudit}, {"POST", "/audit/nono", "POST /audit/nono", PermissionAuditWrite, false, false, h.handleNonoAudit},
		{"GET", "/api/v1/risk/agents/{id}", "GET /api/v1/risk/agents/{id}", PermissionRiskRead, false, true, h.handleGetAgentRisk}, {"GET", "/api/v1/risk/fleet", "GET /api/v1/risk/fleet", PermissionRiskRead, true, false, h.handleGetFleetRisk}, {"GET", "/v1/risk/agents/{id}", "GET /v1/risk/agents/{id}", PermissionRiskRead, false, true, h.handleGetAgentRisk}, {"GET", "/v1/risk/fleet", "GET /v1/risk/fleet", PermissionRiskRead, true, false, h.handleGetFleetRisk},
		// SLDP-P3-2. actorScoped is true so a principal may only request erasure of actors inside
		// its own binding; the subject is read from the path so the guard and the erased subject
		// cannot disagree. Registered here rather than on a bare mux because NewProtectedRouter is
		// the sole production route-registration boundary, and a gate reachable by an unregistered
		// route is not a gate.
		{"POST", "/api/v1/privacy/erasure/{id}", "POST /api/v1/privacy/erasure/{id}", PermissionErasureRequest, false, true, h.handleEraseSubject},
		// SLDP-P5-3. Data subject rights export under GDPR Article 15 (access) and Article 20 (portability).
		{"GET", "/api/v1/privacy/export/{id}", "GET /api/v1/privacy/export/{id}", PermissionPrivacyExport, false, true, h.handleExportSubject},
		{"GET", "/api/v1/actors/{id}/export", "GET /api/v1/actors/{id}/export", PermissionPrivacyExport, false, true, h.handleExportSubject},
	}
	if metrics != nil {
		r = append(r, routeDefinition{"GET", "/metrics", "GET /metrics", PermissionMetrics, false, false, metrics.ServeHTTP})
	}
	return r
}

type RouterOptions struct {
	DefaultPageSize, MaxPageSize, PrincipalBudget int
	BudgetWindow                                  time.Duration
}
type budgetEntry struct {
	used  int
	reset time.Time
}
type ProtectedRouter struct {
	mux        *http.ServeMux
	auth       Authenticator
	audit      audit.AuditWriter
	options    RouterOptions
	inventory  []RouteRequirement
	registered map[string]RouteRequirement
	mu         sync.Mutex
	budgets    map[string]budgetEntry
	auditKey   []byte
}

func NewProtectedRouter(h *Handlers, authn Authenticator, aw audit.AuditWriter, metrics http.Handler, opts RouterOptions) (*ProtectedRouter, error) {
	if h == nil || authn == nil || aw == nil || metrics == nil {
		return nil, errors.New("handlers, authenticator, audit writer, and metrics handler are required")
	}
	if !audit.GetAuditPosture(aw).Healthy {
		return nil, errors.New("healthy fail-closed audit writer is required")
	}
	if opts.DefaultPageSize <= 0 {
		opts.DefaultPageSize = 50
	}
	if opts.MaxPageSize <= 0 {
		opts.MaxPageSize = 100
	}
	if opts.PrincipalBudget <= 0 {
		opts.PrincipalBudget = 1000
	}
	if opts.BudgetWindow <= 0 {
		opts.BudgetWindow = time.Minute
	}
	if opts.DefaultPageSize > opts.MaxPageSize {
		return nil, errors.New("default page size must not exceed maximum page size")
	}
	auditKey := make([]byte, 32)
	if _, err := cryptorand.Read(auditKey); err != nil {
		return nil, fmt.Errorf("create audit pseudonym key: %w", err)
	}
	// The random HMAC key intentionally rotates on process restart: audit records
	// remain correlatable within one runtime without enabling offline dictionary
	// recovery of low-entropy SPIFFE subjects across retained audit history.
	p := &ProtectedRouter{mux: http.NewServeMux(), auth: authn, audit: aw, options: opts, registered: map[string]RouteRequirement{}, budgets: map[string]budgetEntry{}, auditKey: auditKey}
	for _, rd := range h.routeDefinitions(metrics) {
		p.register(rd)
	}
	return p, nil
}
func (p *ProtectedRouter) register(rd routeDefinition) {
	requirement := RouteRequirement{rd.method, rd.path, rd.permission, rd.enumeration}
	p.inventory = append(p.inventory, requirement)
	p.registered[rd.pattern] = requirement
	slog.Info("HTTP authorization route registered", "method", rd.method, "route", rd.path, "permission", rd.permission, "enumeration", rd.enumeration)
	p.mux.HandleFunc(rd.pattern, func(w http.ResponseWriter, r *http.Request) { p.authorize(rd, w, r) })
}
func (p *ProtectedRouter) Inventory() []RouteRequirement {
	out := make([]RouteRequirement, len(p.inventory))
	copy(out, p.inventory)
	return out
}
func (p *ProtectedRouter) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	principal, err := p.auth.Authenticate(r)
	if err != nil {
		status, outcome := http.StatusUnauthorized, "authentication_failed"
		if errors.Is(err, ErrUnboundPrincipal) {
			status, outcome = http.StatusForbidden, "principal_unbound"
		}
		route, method := p.safeAuditRoute(r)
		p.deny(w, r, principal, route, method, outcome, status)
		return
	}
	r = r.WithContext(context.WithValue(r.Context(), principalContextKey{}, principal))
	if path.Clean(r.URL.Path) != r.URL.Path {
		p.deny(w, r, principal, "unmatched", "UNMATCHED", "noncanonical_route", http.StatusForbidden)
		return
	}
	_, pattern := p.mux.Handler(r)
	if pattern == "" {
		p.deny(w, r, principal, "unmatched", "UNMATCHED", "unregistered_route", http.StatusForbidden)
		return
	}
	p.mux.ServeHTTP(w, r)
}
func (p *ProtectedRouter) safeAuditRoute(r *http.Request) (string, string) {
	_, pattern := p.mux.Handler(r)
	requirement, ok := p.registered[pattern]
	if !ok {
		return "unmatched", "UNMATCHED"
	}
	return requirement.Path, requirement.Method
}
func (p *ProtectedRouter) authorize(rd routeDefinition, w http.ResponseWriter, r *http.Request) {
	principal, ok := r.Context().Value(principalContextKey{}).(Principal)
	if !ok {
		p.deny(w, r, Principal{}, rd.path, rd.method, "principal_context_missing", http.StatusServiceUnavailable)
		return
	}
	if !principal.Permissions[rd.permission] || (rd.actorScoped && !principal.ActorIDs["*"] && !principal.ActorIDs[r.PathValue("id")]) {
		p.deny(w, r, principal, rd.path, rd.method, "authorization_denied", http.StatusForbidden)
		return
	}
	if rd.enumeration {
		if !p.applyEnumeration(w, r, principal, rd.path, rd.method) {
			return
		}
	}
	ctx := WithTenantContext(r.Context(), TenantContext{TenantID: principal.TenantID, Principal: principal.Subject})
	if !principal.ExpiresAt.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, principal.ExpiresAt)
		defer cancel()
		_ = http.NewResponseController(w).SetWriteDeadline(principal.ExpiresAt)
	}
	rd.handler(w, r.WithContext(ctx))
	if errors.Is(ctx.Err(), context.DeadlineExceeded) && rd.permission == PermissionStream {
		auditCtx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), time.Second)
		defer cancel()
		if err := p.writeAudit(auditCtx, principal, rd.path, rd.method, "credential_expired"); err != nil {
			slog.Error("SSE expiry audit failed", "route", rd.path, "error", err)
		}
	}
}
func (p *ProtectedRouter) applyEnumeration(w http.ResponseWriter, r *http.Request, principal Principal, route, method string) bool {
	limit := p.options.DefaultPageSize
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 || n > p.options.MaxPageSize {
			writeError(w, http.StatusBadRequest, "limit must be between 1 and "+strconv.Itoa(p.options.MaxPageSize))
			return false
		}
		limit = n
	} else {
		q := r.URL.Query()
		q.Set("limit", strconv.Itoa(limit))
		r.URL.RawQuery = q.Encode()
	}
	p.mu.Lock()
	now := time.Now()
	e := p.budgets[principal.Subject]
	if e.reset.IsZero() || !now.Before(e.reset) {
		e = budgetEntry{reset: now.Add(p.options.BudgetWindow)}
	}
	if e.used+limit > p.options.PrincipalBudget {
		p.mu.Unlock()
		p.deny(w, r, principal, route, method, "enumeration_budget_exceeded", http.StatusTooManyRequests)
		return false
	}
	e.used += limit
	p.budgets[principal.Subject] = e
	p.mu.Unlock()
	return true
}
func (p *ProtectedRouter) deny(w http.ResponseWriter, r *http.Request, principal Principal, route, method, outcome string, status int) {
	if err := p.writeAudit(r.Context(), principal, route, method, outcome); err != nil {
		writeError(w, http.StatusServiceUnavailable, "authorization audit unavailable")
		return
	}
	writeError(w, status, outcome)
}
func (p *ProtectedRouter) writeAudit(ctx context.Context, principal Principal, route, method, outcome string) error {
	subject := principal.Subject
	if subject == "" {
		subject = "anonymous"
	}
	mac := hmac.New(sha256.New, p.auditKey)
	_, _ = mac.Write([]byte(subject))
	detail, _ := json.Marshal(map[string]any{"category": "http_authorization_failure", "principal_pseudonym": fmt.Sprintf("%x", mac.Sum(nil)[:12]), "route": route, "method": method, "outcome": outcome, "pseudonym_rotation": "process_restart"})
	tenant := principal.TenantID
	if tenant == "" {
		tenant = "unknown"
	}
	// P1-1 deliberately reuses the existing legal actor_updated event because
	// adding a dedicated database event type requires an out-of-scope migration.
	return p.audit.WriteAuditEvent(ctx, audit.Event{TenantID: tenant, EventType: audit.EventActorUpdated, Detail: detail})
}

func AuthConfigFromEnv() (AuthConfig, error) {
	audience := os.Getenv("SIGNAL_AUTH_AUDIENCE")
	trustDomain := os.Getenv("SIGNAL_AUTH_TRUST_DOMAIN")
	jwks := os.Getenv("SIGNAL_AUTH_JWKS")
	bindingsRaw := os.Getenv("SIGNAL_AUTH_BINDINGS")
	if audience == "" || trustDomain == "" || jwks == "" || bindingsRaw == "" {
		return AuthConfig{}, errors.New("SIGNAL_AUTH_AUDIENCE, SIGNAL_AUTH_TRUST_DOMAIN, SIGNAL_AUTH_JWKS, and SIGNAL_AUTH_BINDINGS are required")
	}
	keys, err := parseJWKS(jwks)
	if err != nil {
		return AuthConfig{}, err
	}
	bindings := map[string]PrincipalBinding{}
	if err = json.Unmarshal([]byte(bindingsRaw), &bindings); err != nil {
		return AuthConfig{}, fmt.Errorf("parse bindings: %w", err)
	}
	return AuthConfig{Audience: audience, TrustDomain: trustDomain, Keys: keys, Bindings: bindings}, nil
}
func parseJWKS(raw string) (map[string]any, error) {
	var set struct {
		Keys []struct{ Kty, Kid, Crv, X, Y, N, E string }
	}
	if err := json.Unmarshal([]byte(raw), &set); err != nil {
		return nil, err
	}
	out := map[string]any{}
	for _, j := range set.Keys {
		if j.Kid == "" {
			return nil, errors.New("JWK kid required")
		}
		if _, exists := out[j.Kid]; exists {
			return nil, errors.New("duplicate JWK kid")
		}
		dec := base64.RawURLEncoding
		switch j.Kty {
		case "EC":
			xb, e1 := dec.DecodeString(j.X)
			yb, e2 := dec.DecodeString(j.Y)
			if j.Crv != "P-256" || e1 != nil || e2 != nil {
				return nil, errors.New("invalid EC JWK")
			}
			key := &ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(xb), Y: new(big.Int).SetBytes(yb)}
			if !key.Curve.IsOnCurve(key.X, key.Y) {
				return nil, errors.New("EC JWK point is off curve")
			}
			out[j.Kid] = key
		case "RSA":
			nb, e1 := dec.DecodeString(j.N)
			eb, e2 := dec.DecodeString(j.E)
			exponent := new(big.Int).SetBytes(eb)
			if e1 != nil || e2 != nil || new(big.Int).SetBytes(nb).BitLen() < 2048 || exponent.BitLen() > 31 {
				return nil, errors.New("invalid RSA JWK")
			}
			e := int(exponent.Int64())
			if e < 3 || e%2 == 0 {
				return nil, errors.New("invalid RSA exponent")
			}
			out[j.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(nb), E: e}
		default:
			return nil, errors.New("unsupported JWK type")
		}
	}
	if len(out) == 0 {
		return nil, errors.New("empty JWKS")
	}
	return out, nil
}
