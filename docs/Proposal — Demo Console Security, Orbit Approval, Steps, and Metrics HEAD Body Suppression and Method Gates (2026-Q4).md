# Proposal: Demo Console Security, Orbit Approval, Steps, and Metrics HEAD Body Suppression and Method Gates

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `tools/demo-console`

## Executive Summary

This proposal hardens the Estate 95 demo console HTTP routes.
It hardens security sandbox endpoints (`/api/security/scan`, `/api/security/status`, `/api/security/probe`).
It hardens Orbit approval endpoints (`/api/orbit/approve`, `/api/orbit/reject`, `/api/orbit/proposals`).
It hardens steps, metrics, cluster overview, pipeline, incidents, runs, and scoped terminal endpoints.
It enforces RFC 9110 Section 6.4.1 HEAD response body suppression across all direct handler calls and proxied endpoints.
It enforces strict HTTP method gates with compliant Allow headers (`Allow: GET, HEAD` or `Allow: POST`).
It standardizes terminal method rejection through canonical error helpers.

## Problem Statement

Protocol sweeps identified three resilience and contract gaps in demo console endpoints.
First, test coverage in `tools/demo-console/main_test.go` verifies only GET and HEAD against mutating POST routes (`/api/runs`, `/api/orbit/approve`, `/api/orbit/reject`, `/api/security/scan`, `/api/security/probe`).
It omits PUT, DELETE, PATCH, and OPTIONS method rejection checks.
Second, test coverage omits method rejection and HEAD body suppression assertions for `/api/pipeline/events`, `/api/incidents/{id}`, `/api/agent-card/live/{name}`, and `/api/runs/{id}/events`.
Third, `handleTerm` in `tools/demo-console/main.go` manually re-implements method rejection instead of using the canonical `methodNotAllowed` helper.
Fourth, test suites lack comprehensive verification of RFC 9110 Section 6.4.1 compliance on HEAD requests across error status codes (400, 403, 404, 405, 502, 503).

## Technical Design

### Method Gating and Allow Headers

The demo console handlers enforce strict HTTP method gates.
Read-only endpoints (`/api/steps`, `/api/cluster/overview`, `/api/incidents`, `/api/agent-card`, `/api/agent-card/live`, `/api/orbit/proposals`, `/api/eval-history`, `/api/pipeline/events`, `/api/pipeline/node/*`, `/api/metrics/query`, `/api/security/status`, `/api/health`, `/health`, `/healthz`, `/readyz`, `/ws/term`, `/api/runs/{id}/events`) permit GET and HEAD only.
Requests with any other method return HTTP 405 Method Not Allowed with header `Allow: GET, HEAD`.
Mutating endpoints (`/api/runs`, `/api/orbit/approve`, `/api/orbit/reject`, `/api/security/scan`, `/api/security/probe`) permit POST only.
Requests with any other method return HTTP 405 Method Not Allowed with header `Allow: POST`.

### RFC 9110 Section 6.4.1 HEAD Body Suppression

All responses to HEAD requests must not contain a message body.
The broker-level `headBodySuppressingMiddleware` wraps all routes registered on `newConsoleMux`.
All terminal error writers (`methodNotAllowed`, `writeError`, `clusterUnavailable`, `writeJSON`) explicitly verify `r.Method == http.MethodHead` and suppress message bodies.
Responses for status codes 200, 400, 403, 404, 405, 502, and 503 return zero body bytes while preserving Content-Type and framing headers.

### Terminal Handler Canonization

`handleTerm` in `tools/demo-console/main.go` calls the shared `methodNotAllowed(w, req, "GET, HEAD")` helper.
This guarantees uniform Content-Type (`text/plain; charset=utf-8`) and Allow headers across all console endpoints.

### Test Harnesses and Assertions

A comprehensive HTTP contract test suite in `tools/demo-console/main_test.go` exercises:
1. Method matrix testing (GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS) for all read-only and mutating endpoints.
2. Allow header validation matching RFC 9110 specifications.
3. RFC 9110 Section 6.4.1 zero-byte body length verification across all status codes on HEAD requests.
4. Parameterized subpath routing (`/api/incidents/{id}`, `/api/agent-card/{name}`, `/api/agent-card/live/{name}`, `/api/pipeline/node/{id}`, `/api/runs/{id}/events`).
5. Query parameter error states (missing `q` on `/api/metrics/query`).

## Verification Strategy

Verification runs unit and contract tests in `tools/demo-console`:
- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -C tools/demo-console -v ./...`
- `bats test/docs-index-sync.bats`
- `./scripts/docs-lint.sh`
