# Proposal: Signal Loom Telemetry Request Lifecycle and OSRAMP Archiver Identifier Sanitization Hardening

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/pkg/telemetry`, `d2-osramp-apps/apps/archiver`

## Executive Summary

This proposal hardens the frontend telemetry service and the OSRAMP task archiver against protocol mismatches, resource leaks, and log injection.
The first service is `fe-signalloom/pkg/telemetry`.
The second service is `osramp-apps/archiver`.
The changes implement RFC 9110 Section 9.3.7 OPTIONS method handling across all telemetry endpoints.
They ensure preflight OPTIONS requests return HTTP 204 No Content without requiring recent cAdvisor scrapes.
They close and drain HTTP request bodies to prevent connection socket exhaustion.
They sanitize task identifiers, worker IDs, statuses, result types, algorithms, and SBOM IDs in the task archiver.
These sanitization steps prevent log injection, terminal poisoning, and database schema corruption.

## Problem Statement

Security evaluations revealed issues across frontend telemetry and task archival services:

1. In `fe-signalloom/pkg/telemetry`, `admit` rejects RFC 9110 OPTIONS requests with HTTP 405 Method Not Allowed.
Browser preflight requests fail because the service omits OPTIONS dispatch while advertising cross-origin headers.
Furthermore, unparsed incoming request bodies are never closed, causing TCP socket descriptor leaks.
2. In `fe-signalloom/pkg/telemetry`, `admit` rejects requests with HTTP 503 Service Unavailable when the collector is unready.
A preflight OPTIONS request queries endpoint capabilities and must succeed even before initial telemetry scrapes complete.
3. In `osramp-apps/archiver`, `processTaskResult`, `processTaskSignature`, and `processSBOMData` process untrusted NATS messages.
Identifiers such as `TaskID`, `Status`, `ResultType`, `Algorithm`, and `SBOMId` pass directly to `log.Printf` and PostgreSQL queries.
Malicious strings containing control characters, carriage returns, or newlines cause log injection and corrupted logs.
Unbounded identifier strings can also trigger unhandled database constraint errors.

## Proposed Changes

### 1. Signal Loom Telemetry RFC 9110 OPTIONS Parity and Request Draining

In `d2-signalloom/apps/fe-signalloom/pkg/telemetry/handler.go`:
- Intercept HTTP `OPTIONS` requests before the scrape freshness gate.
- Return HTTP 204 No Content with `Allow: GET, HEAD, OPTIONS` on OPTIONS preflight requests.
- Set CORS preflight headers `Access-Control-Allow-Origin: *`, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, and `Access-Control-Allow-Headers: Content-Type, Accept, Authorization`.
- Ensure zero response body bytes on OPTIONS responses.
- In `admit`, close and drain unconsumed request bodies using `io.LimitReader(r.Body, 4096)`.
- Preserve existing `Allow: GET, HEAD` header values on HTTP 405 responses for contract compatibility.

### 2. OSRAMP Task Archiver Identifier Sanitization and Length Bounding

In `d2-osramp-apps/apps/archiver/archiver.go`:
- Introduce `sanitizeTaskID` to strip whitespace, control characters, newlines, carriage returns, and invalid symbols from task identifiers.
- Introduce `sanitizeIdentifier` to sanitize worker IDs, statuses, result types, algorithms, and SBOM IDs.
- Bound identifier string lengths to database column limits.
- Apply sanitization in `processTaskResult`, `processTaskSignature`, and `processSBOMData` before logging and database operations.
- Preserve strict rejection of empty or whitespace-only keys to maintain schema integrity and test contracts.

## Verification Plan

Verify the changes with automated test suites:

- Run `go test -v .` in `d2-signalloom/apps/fe-signalloom/pkg/telemetry`.
- Run `go test -v .` in `d2-osramp-apps/apps/archiver`.
- Run `bats test/docs-index-sync.bats`.
- Run `scripts/docs-lint.sh`.
