# Proposal: Signal Ingest Handlers, Authorization Queries, Store Stats, and Fleet Risk HEAD Body Suppression and Method Gates

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/signal-ingest`

## Executive Summary

This proposal hardens signal-ingest HTTP handlers and query endpoints.
It hardens actor authorization endpoints and estate-wide authorization queries.
It hardens store statistics, coverage reporting, and fleet risk handlers.
It enforces RFC 9110 Section 6.4.1 HEAD response body suppression across all direct handler invocations.
It enforces strict HTTP method gates with compliant Allow headers.
It eliminates body leaks and unvalidated verb acceptance on direct handler calls.

## Problem Statement

Automated security sweeps identified three protocol vulnerabilities in signal-ingest endpoints.
First, signal-ingest handlers in `api/handlers.go` omit explicit HTTP method verification on direct calls.
Endpoints including `handleStoreStats`, `handleCoverage`, `handleGetAgentRisk`, `handleGetFleetRisk`, and `handleSeed` accept non-matching verbs without returning HTTP 405 Method Not Allowed.
Second, actor authorization handlers in `api/authorization.go` lack method gating.
`handleGetActorAuthorization` and `handleQueryAuthorization` execute full database traversals on arbitrary HTTP methods.
Third, test suites in `api/stats_test.go`, `api/fleet_risk_coverage_test.go`, and `api/readyz_test.go` omit assertions for RFC 9110 HEAD response body suppression and method rejection.

## Technical Design

### Signal Ingest Core Handlers

The signal-ingest handlers implement strict HTTP method checking.
Read-only endpoints (`handleHealth`, `handleHealthz`, `handleReadyz`, `handleQueryObservations`, `handleListActors`, `handleGetActor`, `handleStoreStats`, `handleCoverage`, `handleStream`, `handleGetAgentRisk`, and `handleGetFleetRisk`) permit GET and HEAD only.
Invalid methods return HTTP 405 Method Not Allowed with header `Allow: GET, HEAD`.
Mutating endpoints (`handleIngestObservations`, `handleCorrelate`, and `handleSeed`) permit POST only.
Invalid methods return HTTP 405 Method Not Allowed with header `Allow: POST`.
All HEAD requests write HTTP headers and suppress response message bodies.

### Authorization Query Endpoints

`handleGetActorAuthorization` and `handleQueryAuthorization` gate incoming requests.
Requests with HTTP verbs other than GET and HEAD return status 405 with header `Allow: GET, HEAD`.
HEAD requests on authorization endpoints return status codes (200 OK or 403 Forbidden for quarantined actors) with zero body bytes.

### Test Harnesses and Assertions

Test suites in `handlers_test.go`, `stats_test.go`, `fleet_risk_coverage_test.go`, and `readyz_test.go` add assertions for method gating and HEAD body suppression.
The tests verify that invalid verbs yield status 405 with correct Allow headers.
The tests verify that HEAD requests return status codes and Content-Type headers with empty message bodies.

## Verification Strategy

Verification executes unit tests in `d2-signalloom/apps/signal-ingest/api`.
Tests assert status 405 and Allow headers for invalid HTTP verbs.
Tests assert zero-byte body length on HEAD requests.
Documentation tests confirm index synchronization via `bats test/docs-index-sync.bats` and `./scripts/docs-lint.sh`.
