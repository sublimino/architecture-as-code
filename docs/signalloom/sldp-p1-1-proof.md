# SLDP-P1-1 Execution Proof — Signal-Ingest HTTP Authentication and Authorisation

## 1. Executive Summary

**Task ID:** `SLDP-P1-1`  
**Role:** Implementation  
**Status:** `PASS / Completed`  
**Target Component:** `d2-signalloom/apps/signal-ingest/api`, `d2-signalloom/apps/signal-ingest/main.go`  
**Base Ref:** `refs/heads/integration/sldp-v0.1.0`  

SLDP-P1-1 closes the critical live security exposure in `signal-ingest` where `main.go` constructed a bare `http.NewServeMux()` with zero middleware or authorization checks, serving the complete identity and delegation graph openly to any caller able to reach the port.

All HTTP routes (32 route bindings across 23 handler targets, including 4 Server-Sent Events streams and Prometheus `/metrics`) are now gated exclusively through `NewProtectedRouter` and `JWTAuthenticator`, enforcing:
1. **SPIFFE JWT-SVID Bearer Authentication**: Validated against configured trust domains, public keys (ES256/RS256), non-expired tokens, strict JSON claims, and constant-time signature comparison.
2. **Default-Deny Routing**: Unregistered routes and malformed/non-canonical paths return `403 Forbidden` and emit a fail-closed audit event.
3. **Per-Route and Per-Object Authorisation**: Distinct permissions for listing vs reading single entities (e.g. `actors:list` vs `actors:read`), with actor-scoped access validation.
4. **Principal-Derived Tenant Binding**: `TenantContext` injected into the request context solely from the authenticated SPIFFE principal's verified binding—never trusting client-supplied headers or query parameters.
5. **Bounded Enumeration & Shared Principal Budget**: Enforced page sizes (`limit` parameter clamped between 1 and `maxPageSize`, defaulting to `defaultPageSize`) and a global rate-limited enumeration request budget per principal across all listing routes.
6. **SSE Connection Lifecycles & Mid-Stream Expiry**: Server-Sent Events streams enforce write deadlines and context cancellation matching credential expiry (`ExpiresAt`), cleanly terminating connections and emitting `credential_expired` audit events.
7. **Fail-Closed Pseudonymous Audit Logging**: Auth and authz rejections record HMAC-SHA256 pseudonyms of principals and safe registered route templates without leaking credentials or request parameters, failing closed (returning 503) if audit persistence fails.

---

## 2. Deliverables Matrix

| Deliverable | Implementation Location | Verification Evidence |
|---|---|---|
| **Authentication Middleware & Default-Deny** | `api/auth.go:376-398` (`ProtectedRouter.ServeHTTP`) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials`, `TestProtectedRouterPermissionUnknownAndPreflightDenials` |
| **Sole Route-Registration Wrapper** | `api/auth.go:329-370` (`NewProtectedRouter`), `api/handlers.go:68-70` | `RegisterRoutes` removed from production handlers; test-only shim placed in `export_test.go` |
| **Per-Route & Per-Object Authorisation** | `api/auth.go:407-437` (`authorize`) | `TestActorReadDoesNotGrantActorEnumeration` |
| **Principal-Derived Tenant Binding** | `api/auth.go:80-93`, `api/auth.go:422` (`WithTenantContext`) | `TestProtectedRouterExportsTenantContext`, `TestRealJWTAuthenticatorProtectedRouterHTTPBoundary` |
| **Pagination Bounds & Principal Budget** | `api/auth.go:438-467` (`applyEnumeration`), `api/handlers.go:376,433,748` | `TestProtectedRouterSharedEnumerationBudget`, `TestEnumerationLimitCapsActualResponses` |
| **Hostile-Request Test Suite** | `api/auth_test.go:57-117` (`TestJWTAuthenticatorHostileCredentials`) | 17 hostile test cases covering missing, malformed, expired, cross-domain, tampered, duplicate header, unbound, and invalid JOSE |
| **Metrics Endpoint Posture Decision** | `api/auth.go:303-305`, `main.go:246-253` | Protected under `metrics:read` permission; documented decision below |
| **Threat Model Errata Note** | Proposal Appendix (Errata block) | Documented that encryption-at-rest does not prevent unauthenticated HTTP read exfiltration |
| **Startup Route Inventory Logging** | `api/auth.go:368` (`slog.Info`) | Observable log emission at boot for all 32 registered routes with method, route, permission, and enumeration status |
| **Fail-Closed Pseudonymous Audit Events** | `api/auth.go:468-490` (`deny`, `writeAudit`) | `TestAuthenticationAuditIsPseudonymousAndExcludesCredential`, `TestProtectedRouterFailsClosedWhenDenialAuditFails` |

---

## 3. Metrics Endpoint Security Posture Decision

**Decision:** Authenticate `/metrics` with `PermissionMetrics` (`metrics:read`).

**Rationale:**
Prometheus metrics endpoints frequently leak internal state, service topology, actor identities, and request volume trends through high-cardinality labels (such as agent IDs, SPIFFE IDs, and quarantine counters). Allowing unauthenticated scrapes would create an informational side-channel bypassing the tenant and identity isolation guarantees established in P1-1.

Under `ProtectedRouter`, `/metrics` requires a valid SPIFFE JWT-SVID possessing the `metrics:read` permission. Scrapers (such as Prometheus / OpenTelemetry collectors) must present their workload identity JWT-SVID.

---

## 4. Test Execution Evidence

### 4.1 Go API Test Suite (`go test -v ./api/...`)
```text
=== RUN   TestJWTAuthenticatorHostileCredentials
--- PASS: TestJWTAuthenticatorHostileCredentials (0.00s)
=== RUN   TestProtectedRouterDeniesEveryRouteWithoutCredentials
--- PASS: TestProtectedRouterDeniesEveryRouteWithoutCredentials (0.00s)
=== RUN   TestProtectedRouterPermissionUnknownAndPreflightDenials
--- PASS: TestProtectedRouterPermissionUnknownAndPreflightDenials (0.00s)
=== RUN   TestActorReadDoesNotGrantActorEnumeration
--- PASS: TestActorReadDoesNotGrantActorEnumeration (0.00s)
=== RUN   TestProtectedRouterExportsTenantContext
--- PASS: TestProtectedRouterExportsTenantContext (0.00s)
=== RUN   TestProtectedRouterSharedEnumerationBudget
--- PASS: TestProtectedRouterSharedEnumerationBudget (0.00s)
=== RUN   TestProtectedRouterSSEExpiresAndPreservesFlusher
--- PASS: TestProtectedRouterSSEExpiresAndPreservesFlusher (0.06s)
=== RUN   TestProtectedRouterFailsClosedWhenDenialAuditFails
--- PASS: TestProtectedRouterFailsClosedWhenDenialAuditFails (0.00s)
=== RUN   TestAuthenticationAuditIsPseudonymousAndExcludesCredential
--- PASS: TestAuthenticationAuditIsPseudonymousAndExcludesCredential (0.00s)
=== RUN   TestAuthenticationFailureAuditUsesRegisteredRouteTemplate
--- PASS: TestAuthenticationFailureAuditUsesRegisteredRouteTemplate (0.00s)
=== RUN   TestRealJWTAuthenticatorProtectedRouterHTTPBoundary
--- PASS: TestRealJWTAuthenticatorProtectedRouterHTTPBoundary (0.00s)
=== RUN   TestRealHTTPServerSSEClosesAtJWTExpiry
--- PASS: TestRealHTTPServerSSEClosesAtJWTExpiry (2.00s)
=== RUN   TestNakedMuxNegativeControlDetectsMissingAuthenticationMiddleware
--- PASS: TestNakedMuxNegativeControlDetectsMissingAuthenticationMiddleware (0.00s)
=== RUN   TestRouterRejectsInvalidOptionsAndRedirectBypass
--- PASS: TestRouterRejectsInvalidOptionsAndRedirectBypass (0.00s)
=== RUN   TestJWKSRejectsWeakRSAAndDuplicateKids
--- PASS: TestJWKSRejectsWeakRSAAndDuplicateKids (0.01s)
=== RUN   TestJWTPartsRejectDuplicateKeysAndTrailingJSON
--- PASS: TestJWTPartsRejectDuplicateKeysAndTrailingJSON (0.00s)
=== RUN   TestAuthConfigFromEnvFailsClosedWhenMissing
--- PASS: TestAuthConfigFromEnvFailsClosedWhenMissing (0.00s)
=== RUN   TestEnumerationLimitCapsActualResponses
--- PASS: TestEnumerationLimitCapsActualResponses (0.00s)
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api	7.352s
```

### 4.2 Full Signal-Ingest Module Suite (`go test ./...`)
```text
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest	0.013s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api	6.960s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit	0.157s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit	4.505s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors	1.471s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/agentnono	0.529s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/baoaudit	0.325s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/ebpf	0.600s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/gcpaudit	0.006s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/kagent	0.053s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf	0.004s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea	0.007s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/workspacesaas	0.035s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation	16.759s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity	0.376s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model	0.003s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pkg/fair	0.034s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store	1.739s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/transform	0.003s
```

### 4.3 Contract Tier 1 Suite (`make demo-signalloom-api-test TIER=contract`)
```text
56 passed, 2 warnings in 1.18s
```

### 4.4 Acceptance Spec Coverage (`bats test/acceptance-spec-coverage.bats`)
```text
acceptance-spec-coverage.bats
   the guard can read every project in playwright.config.ts1/7 ✓ the guard can read every project in playwright.config.ts
   every spec on disk has exactly one registry row, and every row has a...2/7 ✓ every spec on disk has exactly one registry row, and every row has a spec
   every registry runner is a known kind, and every non-CI row gives a ...3/7 ✓ every registry runner is a known kind, and every non-CI row gives a reason
   a spec matches a playwright project if and only if the registry says so4/7 ✓ a spec matches a playwright project if and only if the registry says so
   every ci: row names a stage that really runs that spec5/7 ✓ every ci: row names a stage that really runs that spec
   every spec a CI stage runs is registered as ci:6/7 ✓ every spec a CI stage runs is registered as ci:
   every make: row names a target whose recipe runs that spec7/7 ✓ every make: row names a target whose recipe runs that spec

7 tests, 0 failures
```

---

## 5. Security Invariants & Downstream Contracts

1. **Downstream Contract for Row-Level Security (P2-2)**:
   Handlers receiving authenticated requests retrieve the tenant binding via `api.TenantContextFromContext(r.Context())`. Handlers and SQL execution layers MUST query rows using `tc.TenantID`, never inspecting client headers (`X-Tenant-ID`) or query arguments.
2. **Fail-Closed Audit Invariant**:
   Authentication or authorization rejections and token expiry events write directly to `audit.AuditWriter`. If the audit sink is unreachable or fails, the handler immediately aborts with `503 Service Unavailable`, preventing unlogged unauthorized access attempts.
3. **Constant-Time Verification**:
   Cryptographic signature verification avoids timing side-channels through `subtle.ConstantTimeCompare` and standard PKCS#1 v1.5 / ECDSA verification routines.
