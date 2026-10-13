# Proposal: Stun Sentinel and TC Controller Request Lifecycle and OPTIONS Method Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`, `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main_test.go`, `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main.go`, `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main_test.go`

## Executive Summary

This proposal hardens Tier 0 containment daemons and traffic control controllers against HTTP socket exhaustion and method rejection.
It introduces RFC 9110 Section 9.3.7 OPTIONS method dispatch across health, metrics, quarantine, stun, and trigger endpoints.
It ensures that preflight OPTIONS requests bypass bearer authentication in containment handlers.
It guarantees deferred request body closure across mutating containment and network isolation handlers.
It extends unit and contract test suites across `stun-sentinel` and `stun-tcctl`.

## Problem Statement

Protocol conformance reviews across host daemon surfaces revealed the following issues:
1. In `stun-sentinel`, `requireBearer` executes before route handlers and rejects preflight `OPTIONS` requests with status 401.
Standard preflight requests from monitoring or mesh proxies omit authorization credentials.
Rejecting preflight requests prevents discovery of supported verbs.
2. In `stun-sentinel`, `handleHealth`, `handleListSnapshots`, and `handleGetSnapshot` reject `OPTIONS` requests with status 405.
3. In `stun-sentinel`, mutating handlers `handleStun`, `handleResume`, and `handlePruneSnapshots` omit closing `r.Body`.
4. In `stun-tcctl`, `healthHandler`, `/metrics`, and `triggerHandler` reject `OPTIONS` requests with status 405.
5. In `stun-tcctl`, `triggerHandler` omits closing `r.Body` on mutating network isolation requests.

## Technical Design

### Stun Sentinel Hardening

In `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`:
1. In `requireBearer`, intercept HTTP `OPTIONS` requests and return status 204 No Content with `Allow: POST, OPTIONS`.
2. In `handleHealth`, `handleListSnapshots`, and `handleGetSnapshot`, respond to `OPTIONS` requests with status 204 No Content and `Allow: GET, HEAD, OPTIONS`.
Update method mismatch responses to advertise `Allow: GET, HEAD, OPTIONS`.
3. In `handleStun`, `handleResume`, and `handlePruneSnapshots`, respond to `OPTIONS` requests with status 204 No Content and `Allow: POST, OPTIONS`.
Update method mismatch responses to advertise `Allow: POST, OPTIONS`.
4. In `handleStun`, `handleResume`, and `handlePruneSnapshots`, defer closing `r.Body` when `r.Body != nil`.

### Stun TC Controller Hardening

In `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main.go`:
1. In `healthHandler` and the `/metrics` route handler, respond to `OPTIONS` requests with status 204 No Content and `Allow: GET, HEAD, OPTIONS`.
Update method mismatch responses to advertise `Allow: GET, HEAD, OPTIONS`.
2. In `triggerHandler`, respond to `OPTIONS` requests with status 204 No Content and `Allow: POST, OPTIONS`.
Update method mismatch responses to advertise `Allow: POST, OPTIONS`.
3. In `triggerHandler`, defer closing `r.Body` when `r.Body != nil`.

### Test Suite Extensions

1. Expand `main_test.go` in `cmd/stun-sentinel` to verify `OPTIONS` method handling across health, snapshot, stun, and resume endpoints.
2. Expand `main_test.go` in `cmd/stun-tcctl` to verify `OPTIONS` method handling across health, metrics, and isolation trigger endpoints.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/...`
2. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/...`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — Stun Sentinel and TC Controller Request Lifecycle and OPTIONS Method Parity (2026-Q4).md"`
