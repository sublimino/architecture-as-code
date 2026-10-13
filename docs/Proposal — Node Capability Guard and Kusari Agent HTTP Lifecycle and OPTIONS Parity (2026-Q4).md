# Proposal: Node Capability Guard and Kusari Agent HTTP Lifecycle and OPTIONS Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`, `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler_test.go`, `d2-signalloom/apps/kusari-agent/main.go`, `d2-signalloom/apps/kusari-agent/methods_test.go`

## Executive Summary

This proposal hardens HTTP request lifecycle handling and method dispatch across `node-capability-guard` and `kusari-agent`.
It introduces RFC 9110 Section 9.3.7 OPTIONS method handling across all exposed HTTP routes.
It ensures proper closing and draining of HTTP request bodies to eliminate socket leaks.
It enforces validation of AdmissionReview request identifiers in `node-capability-guard`.
It expands test suites across both services with comprehensive method matrix verification.

## Problem Statement

Security and protocol compliance reviews identified multiple HTTP lifecycle gaps:
1. In `node-capability-guard`, `HandleValidate` processes admission reviews without closing the request body.
This leads to descriptor leaks during high admission throughput.
2. In `node-capability-guard`, `HandleValidate` accepts requests with an empty or whitespace request UID.
Kubernetes admission webhooks require valid UIDs to correlate responses with mutating and validating requests.
3. In `node-capability-guard`, `/validate`, `/metrics`, and `/healthz` reject RFC 9110 OPTIONS requests with status 405.
4. In `kusari-agent`, `getOnly` and `postOnly` middleware reject RFC 9110 OPTIONS requests with status 405.
5. In `kusari-agent`, `/act/*` routes receive provocation requests without closing incoming request bodies.

## Technical Design

### Node Capability Guard Hardening

In `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`:
1. In `HandleValidate`, respond to `OPTIONS` requests with status 204 No Content and `Allow: POST, OPTIONS`.
2. Update non-matching method rejection to report `Allow: POST, OPTIONS`.
3. Ensure `r.Body.Close()` is deferred upon entry when `r.Body` is present.
4. Validate that `review.Request.UID` is non-empty after trimming whitespace, returning 400 Bad Request if missing.
5. In `HandleMetrics`, respond to `OPTIONS` requests with status 204 No Content and `Allow: GET, HEAD, OPTIONS`.
Update rejection header to `Allow: GET, HEAD, OPTIONS`.
6. In `HandleHealthz`, respond to `OPTIONS` requests with status 204 No Content and `Allow: GET, HEAD, OPTIONS`.
Update rejection header to `Allow: GET, HEAD, OPTIONS`.

### Kusari Agent Hardening

In `d2-signalloom/apps/kusari-agent/main.go`:
1. In `getOnly`, respond to `OPTIONS` requests with status 204 No Content and `Allow: GET, HEAD, OPTIONS`.
Update non-matching method rejection to report `Allow: GET, HEAD, OPTIONS`.
2. In `postOnly`, respond to `OPTIONS` requests with status 204 No Content and `Allow: POST, OPTIONS`.
Update non-matching method rejection to report `Allow: POST, OPTIONS`.
3. In `postOnly`, ensure `r.Body.Close()` is executed after request completion.

### Test Suite Extensions

1. Expand `handler_test.go` in `node-capability-guard` with OPTIONS method tests across all endpoints and missing UID validation.
2. Expand `methods_test.go` in `kusari-agent` with OPTIONS method verification across read-only and provocation routes.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/node-capability-guard/...`
2. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/kusari-agent/...`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — Node Capability Guard and Kusari Agent HTTP Lifecycle and OPTIONS Parity (2026-Q4).md"`
