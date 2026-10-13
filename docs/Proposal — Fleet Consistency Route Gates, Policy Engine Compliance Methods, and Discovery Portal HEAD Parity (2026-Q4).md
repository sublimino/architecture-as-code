# Proposal — Fleet Consistency Route Gates, Policy Engine Compliance Methods, and Discovery Portal HEAD Parity (2026-Q4)

| Field | Value |
| :--- | :--- |
| Status | Proposed |
| Author | Platform Architecture & Reliability Engineering |
| Date | 2026-10-13 |
| Target Release | 2026-Q4 |
| Target Slices | `d2-signalloom`, `test/mocks`, `test/fixtures`, `scripts` |

## 1. Executive Summary

This proposal hardens HTTP method validation and probe semantics across platform services, test stubs, and mocks.
It eliminates protocol inconsistencies in discovery portal endpoints, fleet manager consistency reconcilers, and policy compliance handlers.
RFC 9110 requires an `Allow` header on every HTTP 405 Method Not Allowed response.
Health and readiness probes must support HEAD requests cleanly without emitting message bodies.
Test stubs and mocks must mirror production protocol semantics to prevent false test passes.

## 2. Problem Statement

Adversarial audit discovered six subtle protocol defects across platform components:
First, `fe-signalloom` discovery portal health and probe endpoints use `@app.get`.
This causes FastAPI to reject HEAD probes with 405 Method Not Allowed and return `Allow: GET`.
Second, `fleet-manager` consistency route `handleConsistency` rejects HEAD requests with `Allow: GET`.
Its `/metrics` handler lacks HTTP method validation and renders full text bodies on HEAD.
Its `handleAuditStream` endpoint rejects HEAD requests with `Allow: GET`.
Third, `policy-engine` compliance handlers `handleFrameworks` and `handleSummary` lack HTTP method validation.
They accept mutating verbs without rejection and emit complete JSON response bodies on HEAD requests.
Fourth, the Tetragon gRPC mock HTTP metrics endpoint lacks method gating and emits bodies on HEAD.
Fifth, `stub-surface-server.py` returns 404 or 501 instead of 405 with RFC 9110 Allow headers on mismatched verbs.
It also rejects HEAD requests on demo API routes with 404 and omits `allow_reuse_address`.
Sixth, `spa-server.py` omits `Allow: GET, HEAD` on 405 responses and lacks socket address reuse.

## 3. Proposed Hardening

### 3.1 Discovery Portal Probe HEAD Parity

The `fe-signalloom` discovery portal exposes `/health`, `/healthz`, `/api/health`, `/livez`, and `/readyz`.
We replace `@app.get` decorators with `@app.api_route(..., methods=["GET", "HEAD"])`.
This enables clean HEAD probe responses with empty bodies and advertises `Allow: GET, HEAD` on 405 rejections.

### 3.2 Fleet Manager Consistency and Stream Route Gates

In `d2-signalloom/apps/fleet-manager/consistency.go`:
We update `handleConsistency` to permit GET and HEAD verbs.
On 405 Method Not Allowed, it returns `Allow: GET, HEAD`.
HEAD requests return status and headers without JSON body serialization.
We update `consistencyMetrics.serveHTTP` to enforce GET and HEAD verbs.
Unsupported verbs return 405 with `Allow: GET, HEAD`.
In `audit_events.go`, `handleAuditStream` permits GET and HEAD.
HEAD requests write stream headers and return immediately without starting the event loop.

### 3.3 Policy Engine Compliance Frameworks and Summary Method Gates

In `d2-signalloom/apps/policy-engine/compliance.go`:
We add method validation to `handleFrameworks` and `handleSummary`.
Both handlers admit GET and HEAD verbs only.
Non-GET/HEAD verbs return 405 with `Allow: GET, HEAD` and standard JSON error envelopes.
HEAD requests write headers and status codes while suppressing body serialization.

### 3.4 Tetragon Mock Metrics Method Gates

In `test/mocks/tetragon_grpc_mock.go`:
We update `/metrics` to restrict incoming requests to GET and HEAD verbs.
Unsupported verbs return 405 Method Not Allowed with `Allow: GET, HEAD`.
HEAD requests write `Content-Type: text/plain; version=0.0.4; charset=utf-8` and suppress metrics text.

### 3.5 Stub Surface Server Method Gates and HEAD Parity

In `test/fixtures/user-surface-gate/stub-surface-server.py`:
We implement route-aware method validation with RFC 9110 `Allow` headers.
Token minting and run creation enforce POST and return `Allow: POST` on mismatch.
Status, step query, probe, and run detail routes enforce GET and HEAD and return `Allow: GET, HEAD`.
HEAD requests on demo routes return matching headers and suppress response bodies.
Unsupported HTTP verbs return 405 rather than 501.
We configure `allow_reuse_address = True` on the HTTP server.

### 3.6 Jev SPA Server Allow Header Alignment

In `scripts/jev-test-bot/spa-server.py`:
We update 405 responses to include `Allow: GET, HEAD`.
We handle unhandled HTTP verbs with 405 Method Not Allowed rather than 501.
We configure `allow_reuse_address = True` on the server instance.

## 4. Verification Plan

We verify all changes using unit and contract test suites in each component.
Tests assert status codes, `Allow` headers, `Content-Type` headers, and empty HEAD bodies.
Documentation linting confirms formatting and index synchronization.

## 5. Implementation Verification

Each component maintains automated regression tests:
- `fe-signalloom`: `pytest src/tests/test_health.py`
- `fleet-manager`: `go test ./apps/fleet-manager/...`
- `policy-engine`: `go test ./apps/policy-engine/...`
- `test/mocks`: `go test ./test/mocks/...`
- `user-surface-gate`: unit execution via Python test assertion
- `spa-server`: unit execution via Python test assertion

## 6. Impact and Rollback

All modifications are strictly backward-compatible.
Clients adhering to HTTP specifications observe standards-compliant headers and probe behaviors.
Rollback requires reverting the committed changes.
