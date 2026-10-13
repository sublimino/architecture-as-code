# Proposal: Prod Deploy Gate Request Lifecycle and Cardvault Preflight OPTIONS Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/prod-deploy-gate/main.go`, `d2-signalloom/apps/prod-deploy-gate/main_test.go`, `d2-signalloom/apps/cardvault/main.go`, `d2-signalloom/apps/cardvault/main_test.go`

## Executive Summary

This proposal hardens production deployment gating and cardvault credential services against HTTP resource leaks and protocol non-compliance.
It enforces RFC 9110 Section 9.3.7 OPTIONS method handling across all endpoints.
It ensures that preflight OPTIONS requests bypass HTTP basic authentication checks in cardvault.
It guarantees deferred request body closure across production deployment gate handlers.
It extends contract and unit test suites across `prod-deploy-gate` and `cardvault`.

## Problem Statement

Protocol conformance reviews revealed the following lifecycle and method handling vulnerabilities:
1. In `prod-deploy-gate`, `handleGateRequest` and `handleGateApprove` omit closing `r.Body`.
Under HTTP keep-alive connections, unclosed request bodies cause persistent connection leaks.
2. In `prod-deploy-gate`, all endpoints return truncated `Allow` headers such as `POST` or `GET, HEAD`.
These headers fail to advertise `OPTIONS` support required by RFC 9110 Section 9.3.7.
3. In `cardvault`, `requireAuth` runs before route handlers and rejects preflight `OPTIONS` requests with status 401.
Standard cross-origin clients and API gateways send preflight `OPTIONS` requests without credentials.
Blocking preflight requests prevents discovery of supported methods.
4. In `cardvault`, route handlers advertise truncated `Allow` headers that omit `OPTIONS`.

## Technical Design

### Prod Deploy Gate Hardening

In `d2-signalloom/apps/prod-deploy-gate/main.go`:
1. In `handleGateRequest` and `handleGateApprove`, add deferred `r.Body.Close()` immediately after checking `r.Body != nil`.
2. In `handleGateRequest` and `handleGateApprove`, return `Allow: POST, OPTIONS` on `OPTIONS` and method mismatch responses.
3. In `handleGetGate`, `handleHealthz`, and `handleReadyz`, return `Allow: GET, HEAD, OPTIONS` on `OPTIONS` and method mismatch responses.

### Cardvault Hardening

In `d2-signalloom/apps/cardvault/main.go`:
1. In `requireAuth`, allow HTTP `OPTIONS` requests to bypass basic authentication and proceed directly to downstream handlers.
2. In `handleListCards` and `handleGetCard`, update `Allow` headers on `OPTIONS` and method mismatch responses to `GET, HEAD, OPTIONS`.
3. In `handleHealthz` and `handleReadyz`, update `Allow` headers on `OPTIONS` and method mismatch responses to `GET, HEAD, OPTIONS`.

### Test Suite Extensions

1. Expand `main_test.go` in `prod-deploy-gate` to verify `OPTIONS` method parity and updated `Allow` headers across all endpoints.
2. Expand `main_test.go` in `cardvault` to verify unauthenticated `OPTIONS` preflight requests on card and probe routes.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/prod-deploy-gate/...`
2. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/cardvault/...`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — Prod Deploy Gate Request Lifecycle and Cardvault Preflight OPTIONS Parity (2026-Q4).md"`
