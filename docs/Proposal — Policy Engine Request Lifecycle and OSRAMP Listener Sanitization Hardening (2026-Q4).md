# Proposal: Policy Engine Request Lifecycle and OSRAMP Listener Sanitization Hardening

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/policy-engine`, `d2-osramp-apps/apps/listener`

## Executive Summary

This proposal hardens the policy evaluation platform and the OSRAMP message listener against resource leakage, protocol mismatches, and path injection.
The first service is `policy-engine`.
The second service is `osramp-apps/listener`.
The changes prevent TCP socket descriptor leaks by closing and draining HTTP request bodies.
They implement RFC 9110 Section 9.3.7 OPTIONS method handling across all HTTP endpoints.
They sanitize message identifiers in the listener to prevent downstream directory traversal attacks.

## Problem Statement

Security evaluations revealed three issues across policy evaluation and task ingestion services:

1. In `policy-engine`, HTTP endpoints reject preflight RFC 9110 OPTIONS requests with HTTP 405 Method Not Allowed.
Clients probing endpoint capabilities receive error responses rather than HTTP 204 No Content with `Allow` headers.
2. In `policy-engine`, mutating POST endpoints process JSON request bodies without deferred closing and draining.
Unconsumed body bytes on persistent connections prevent TCP socket recycling and lead to socket exhaustion.
3. In `osramp-apps/listener`, `normalizeTaskMessage` accepts arbitrary task identifiers without validating path traversal sequences or control characters.
Malicious task identifiers containing relative path components or newlines can compromise downstream task storage.

## Proposed Changes

### 1. Policy Engine RFC 9110 OPTIONS Parity

In `d2-signalloom/apps/policy-engine`:
- In `main.go`, handle OPTIONS on `/health`, `/healthz`, and `/readyz` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- In `main.go`, handle OPTIONS on `/api/v1/evaluate` returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `handlers.go`, handle OPTIONS on `/api/v1/policies` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- In `handlers.go`, handle OPTIONS on `/api/v1/policies/evaluate`, `/api/v1/policies/bundles`, and `/api/v1/policies/rollback` returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `observations.go`, handle OPTIONS on `/api/v1/observations/evaluate` returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `compliance.go`, handle OPTIONS on `/api/v1/compliance/scan` returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `compliance.go`, handle OPTIONS on `/api/v1/compliance/frameworks` and `/api/v1/compliance/summary` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- Preserve existing Allow header values on HTTP 405 responses for test compatibility.

### 2. Policy Engine HTTP Request Body Draining

In `d2-signalloom/apps/policy-engine`:
- In `handleEvaluate`, `HandleEvaluatePolicies`, `HandleRegisterBundle`, `HandleRollback`, `HandleEvaluateObservation`, and `handleScan`, add deferred body closing.
- Drain up to 4096 bytes into `io.Discard` before closing each request body.

### 3. OSRAMP Listener Task Identifier Sanitization

In `d2-osramp-apps/apps/listener/listener.go`:
- In `normalizeTaskMessage`, validate `task.ID` against directory traversal sequences (`..`), slashes, backslashes, carriage returns, newlines, and null bytes.
- Replace invalid or empty identifiers with safe generated timestamps.
- Trim whitespace from `WorkerID`.

## Verification Plan

Verify the changes with automated test suites:
- Run `go test -v .` in `d2-signalloom/apps/policy-engine`.
- Run `go test -v .` in `d2-osramp-apps/apps/listener`.
- Run `bats test/docs-index-sync.bats`.
- Run `scripts/docs-lint.sh`.
