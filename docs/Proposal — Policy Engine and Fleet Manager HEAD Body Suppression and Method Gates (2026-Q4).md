# Proposal: Policy Engine and Fleet Manager HEAD Body Suppression and Method Gates

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/policy-engine`, `d2-signalloom/apps/fleet-manager`

## Executive Summary

This proposal hardens policy-engine and fleet-manager HTTP handlers against protocol non-conformance.
It enforces RFC 9110 Section 6.4.1 response body suppression on all HEAD requests across direct and routed invocations.
It guarantees explicit HTTP method gates with RFC 9110 compliant `Allow` response headers.
It eliminates body leakage on error responses and expands test matrices to cover GET, POST, PUT, DELETE, and PATCH methods.

## Problem Statement

Automated security sweeps identified protocol non-conformance in policy-engine and fleet-manager services:
1. Handlers in `d2-signalloom/apps/policy-engine/handlers.go` and `d2-signalloom/apps/policy-engine/observations.go` emit JSON bodies on 405 errors. Direct HEAD calls bypass outer suppressing middleware.
2. In `d2-signalloom/apps/policy-engine/compliance.go`, `handleSummary` returns a JSON body on HTTP 404 when invoked with HEAD for an unrecorded tenant.
3. Mutating handlers in `d2-signalloom/apps/fleet-manager` write JSON bodies on direct HEAD invocations. `writeError` also writes bodies without inspecting request methods.
4. Unit test suites in both components lack systematic method matrix assertions (PUT, DELETE, PATCH) and explicit direct-invocation HEAD zero-byte body tests.

## Technical Design

### RFC 9110 Section 6.4.1 HEAD Body Suppression

All HTTP handlers ensure zero body bytes are returned for HEAD requests:
1. Direct handler method gates inspect `r.Method == http.MethodHead`. On 405 Method Not Allowed, handlers write the required headers (`Allow`, `Content-Type: application/json`, status 405) and return immediately without encoding a JSON error payload.
2. Handlers yielding successful status codes check for `http.MethodHead` before executing body serialization, ensuring zero response bytes and avoiding redundant computation.
3. In `compliance.go`, `handleSummary` checks `r.Method == http.MethodHead` on the 404 Not Found branch, returning status 404 with zero body bytes.
4. In `fleet-manager/main.go`, `writeError` verifies whether the response writer suppresses bodies before serializing an `ErrorResponse`.

### HTTP Method Validation and Allow Headers

1. All mutating routes enforce POST exclusivity and return status 405 with header `Allow: POST` on any other method (GET, PUT, DELETE, PATCH, HEAD).
2. Read routes enforce GET and HEAD exclusivity and return status 405 with header `Allow: GET, HEAD` on non-conforming methods (POST, PUT, DELETE, PATCH).

### Test Coverage

Test suites in `d2-signalloom/apps/policy-engine` and `d2-signalloom/apps/fleet-manager` expand:
1. Direct handler tests covering the full method matrix: GET, POST, PUT, DELETE, PATCH, and HEAD.
2. Assertions that direct and middleware-wrapped HEAD requests return exactly zero body bytes across 200, 404, and 405 status codes.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -C d2-signalloom/apps/policy-engine -v ./...`
2. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -C d2-signalloom/apps/fleet-manager -v ./...`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh`
