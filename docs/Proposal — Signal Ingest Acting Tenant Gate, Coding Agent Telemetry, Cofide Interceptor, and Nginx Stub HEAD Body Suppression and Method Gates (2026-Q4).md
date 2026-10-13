# Proposal — Signal Ingest Acting Tenant Gate, Coding Agent Telemetry, Cofide Interceptor, and Nginx Stub HEAD Body Suppression and Method Gates (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/signal-ingest`, `d2-signalloom/test/helpers`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, Acting Tenant Gate, SVID Attestation Interceptor

---

## 1. Problem Statement

HTTP services and test harness stubs must conform strictly to RFC 9110 Section 6.4.1.
A server must never send a message body in response to a HEAD request.
Endpoints must return status 405 with an `Allow` header listing permitted methods when an unsupported method arrives.
Servers must configure socket address reuse to prevent binding collisions during test execution.

Adversarial discovery identified four platform components with HEAD leaks, missing method gates, or socket configuration gaps:

1. **Acting Tenant Gate (`d2-signalloom/apps/signal-ingest/api/static_bearer.go`)**:
   `ActingTenantGate` wraps the protected router from outside `ProtectedRouter.ServeHTTP`.
   When a gateway key lacks an acting tenant or requests unauthorized wildcard access, it writes JSON errors directly to the raw `http.ResponseWriter`.
   On HEAD requests, these error responses emit body bytes, violating RFC 9110.

2. **Coding Agent Telemetry Handlers (`d2-signalloom/apps/signal-ingest/api/telemetry_handler.go`)**:
   `handleQueryCodingAgentTelemetry` and `handleAggregateCodingAgentTelemetry` rejected HEAD requests with status 405.
   Their `Allow` headers omitted `HEAD`, violating RFC 9110 Section 9.3.2.
   Both handlers bypassed `writeJSON` and directly invoked `json.NewEncoder`, skipping response body suppression checks.

3. **Cofide SVID Interceptor (`d2-signalloom/apps/signal-ingest/api/cofide_interceptor.go`)**:
   `CofideInterceptor.Wrap` and `HandlerFunc` failed to wrap the response writer with `headResponseWriter`.
   Its `deny` method directly encoded JSON failure objects without checking if the request method was HEAD.
   HEAD requests with missing, expired, or untrusted SVIDs leaked response bodies on 400, 401, and 403 errors.

4. **Dashboard Nginx Upstream Stub (`d2-signalloom/test/helpers/dashboard-nginx.bash`)**:
   The Python upstream test stub created an `http.server.HTTPServer` without setting `allow_reuse_address = True`.
   Rapid restarts risked port binding failures.
   The stub lacked an override for `send_error`, leaking HTML error bodies on HEAD requests.

---

## 2. Proposed Changes

### Signal Ingest Acting Tenant Gate

- Wrap `ActingTenantGate` in `headBodySuppressingMiddleware`.
- Ensure all 400 and 403 error responses suppress response bodies on HEAD requests.
- Add comprehensive unit tests in `static_bearer_test.go` covering HEAD body suppression on all rejection paths.

### Signal Ingest Coding Agent Telemetry

- Permit HEAD requests alongside GET on `/api/v1/telemetry/coding-agents` queries.
- Permit HEAD requests alongside GET and POST on `/api/v1/telemetry/coding-agents/aggregate`.
- Update `Allow` response headers to include `HEAD` (`Allow: GET, HEAD` and `Allow: GET, HEAD, POST`).
- Standardize JSON encoding on `writeJSON`, ensuring automatic HEAD body suppression.
- Update `telemetry_handler_test.go` to assert compliant `Allow` headers and 0-byte HEAD responses.

### Cofide SVID Attestation Interceptor

- Wrap the handler in `headBodySuppressingMiddleware` inside `CofideInterceptor.Wrap`.
- Add an explicit HEAD method check in `CofideInterceptor.deny` to prevent encoding JSON error payloads on HEAD requests.
- Author unit tests in `cofide_interceptor_test.go` confirming 0-byte error responses on HEAD requests for missing, forged, and valid credentials.

### Dashboard Nginx Upstream Stub

- Subclass `http.server.HTTPServer` with `allow_reuse_address = True` in `stub.py`.
- Implement `send_error` override returning JSON content type with 0-byte body on HEAD requests.

---

## 3. Verification Plan

- Run `CGO_ENABLED=0 go test -v ./api` in `d2-signalloom/apps/signal-ingest` to verify acting tenant, telemetry, and Cofide interceptor suites.
- Run `bats test/docs-index-sync.bats` to confirm proposal indexing.
- Run `./scripts/docs-lint.sh` to enforce markdown link, sentence length, and formatting rules.
