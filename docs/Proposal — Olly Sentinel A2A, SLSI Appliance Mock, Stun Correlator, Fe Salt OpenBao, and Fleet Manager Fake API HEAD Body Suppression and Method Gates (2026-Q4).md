# Proposal — Olly Sentinel A2A, SLSI Appliance Mock, Stun Correlator, Fe Salt OpenBao, and Fleet Manager Fake API HEAD Body Suppression and Method Gates (2026-Q4)

## Context

RFC 9110 Section 6.4.1 defines the semantics of HTTP HEAD requests.
A server must not return a message body in response to a HEAD request.
The response headers must match those returned for an equivalent GET request.
Previous hardening milestones eliminated body leakage across primary service endpoints.
However, gaps remain in A2A Starlette services, acceptance harnesses, and test doubles.

## Problem Statement

Adversarial exploration identified response body leakage on HEAD requests across five platform components.

First, `olly-replica/apps/sentinel/olly_sentinel/main.py` provides the Olly Sentinel Starlette application.
In `build_app`, routes for `/health`, `/healthz`, `/readyz`, and `/orbit/proposals` accept GET and HEAD.
However, the application lacks an ASGI middleware to suppress response bodies on HEAD requests.
Raw ASGI response messages emit payload bytes on the wire for HEAD requests.
In addition, 405 Method Not Allowed responses on `/orbit/approve` and `/orbit/reject` emit error bodies on HEAD.

Second, `test/acceptance/slsi-appliance.spec.ts` defines an ephemeral HTTP server for appliance acceptance tests.
The handler lacks method gating on `/api/v1/appliance/snapshots` and `/api/v1/appliance/rollback-report`.
Unsupported HTTP methods return 200 OK instead of 405 Method Not Allowed.
Furthermore, `/api/v1/telemetry/stream` writes `: connected\n\n` and leaks an active timer on HEAD.
All endpoints unconditionally write response bodies on HEAD requests.

Third, `d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator_test.go` provides a mock observation server.
The mock server in `TestDispatchObservation` invokes `http.Error` for non-POST methods.
It omits the RFC 9110 `Allow: POST` header.
It also emits plaintext error messages on HEAD requests.
On successful creation, it writes a JSON body without checking if the request method was HEAD.

Fourth, `d2-signalloom/apps/fe-signalloom/pkg/tenant/hash_test.go` defines a mock OpenBao secret server.
In `TestResolveSaltPrefersOpenBao`, the mock accepts any HTTP verb without method gating.
It uses `http.Error` with plaintext for 403 Forbidden responses.
It unconditionally writes secret payload bytes on HEAD requests.

Fifth, `d2-signalloom/apps/fleet-manager/rate_limit_test.go` defines `fakeAPIServer`.
The fake API server accepts any HTTP verb without method gating.
It lacks an `Allow: GET, HEAD` header for unsupported methods.
It unconditionally writes JSON pod representations to the response body on HEAD requests.

## Proposed Changes

### Olly Sentinel ASGI Middleware

Define `HeadBodySuppressingMiddleware` in `olly_sentinel/main.py`.
Wrap the Starlette application to intercept `http.response.body` messages when `scope["method"] == "HEAD"`.
Set `message["body"] = b""` to ensure zero response body bytes reach the wire.
Add test coverage in `tests/test_a2a_app.py` validating raw ASGI HEAD responses across all routes.

### SLSI Appliance Mock Method Gates and HEAD Suppression

Update the ephemeral HTTP server in `test/acceptance/slsi-appliance.spec.ts`.
Add method gating returning 405 with `Allow: GET, HEAD` on non-GET/HEAD verbs.
Suppress response bodies on HEAD requests across telemetry, snapshots, rollback reports, and fallback HTML.
Ensure telemetry streams do not emit initial connection comments or background timers on HEAD.
Add Playwright test assertions verifying HEAD status and 0-byte bodies.

### Stun Sentinel Correlator Mock Ingest Hardening

Update the mock observation server in `ebpf_correlator_test.go`.
Add explicit method check returning 405 with `Allow: POST` for non-POST methods.
Return structured JSON errors rather than plaintext.
Suppress response bodies on HEAD requests.
Add test assertions covering HEAD requests.

### Fe-Signalloom Tenant Hash Mock OpenBao Hardening

Update the mock OpenBao server in `hash_test.go`.
Gate methods on GET and HEAD, returning 405 with `Allow: GET, HEAD` on other verbs.
Emit OpenBao-standard JSON error payloads for 403 Forbidden responses.
Suppress response bodies on HEAD requests for both 200 OK and 403 Forbidden.
Add test assertions verifying HEAD response body suppression.

### Fleet Manager Fake API Server Hardening

Update `fakeAPIServer` in `rate_limit_test.go`.
Add method gating returning 405 with `Allow: GET, HEAD` for non-GET/HEAD verbs.
Suppress response bodies on HEAD requests.
Add test assertions verifying HEAD parity and method rejection.

## Verification Plan

1. Verify Olly Sentinel A2A tests pass with `uv run python -m pytest tests/test_a2a_app.py`.
2. Verify SLSI appliance acceptance tests pass with `bunx playwright test slsi-appliance.spec.ts`.
3. Verify stun sentinel correlator tests pass with `go test -v ./pkg/correlator`.
4. Verify tenant hash tests pass with `go test -v ./pkg/tenant`.
5. Verify fleet manager rate limit tests pass with `go test -v -run TestTheContainmentClientIsNotThrottledByClientGoDefaults .`.
6. Run `docs-lint.sh` and `test/docs-index-sync.bats` to verify documentation integrity.
