# Proposal: Signal Ingest Export, Delegations, Revocation, Promote, Erasure, Telemetry, and Policy HEAD Body Suppression and Method Gates

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/signal-ingest/api`

## Executive Summary

This proposal hardens signal-ingest export, delegations, revocation, promotion, privacy erasure, coding-agent telemetry, and policy review HTTP handlers.
It enforces RFC 9110 Section 6.4.1 HEAD response body suppression across all direct handler calls.
It adds missing HTTP method gates and RFC 9110 compliant Allow headers.
It eliminates 405 response body leaks on HEAD requests across mutating and read endpoints.

## Problem Statement

Automated security sweeps identified four protocol vulnerabilities across signal-ingest endpoints.
First, `handleExportSubject` in `api/export.go` lacks HTTP method gating.
It accepts non-GET and non-HEAD verbs without returning HTTP 405 Method Not Allowed.
Second, `handleExportSubject` lacks HEAD response body suppression, executing heavy cross-plane database scans on HEAD requests.
Third, mutating handlers (`handleCreateDelegation`, `handleClampDelegation`, `handleRevokeDelegations`, `handlePromoteActor`, `handleEraseSubject`, `handleCodingAgentTelemetry`, `handleCodingAgentOrdering`, and `handlePolicyReview`) emit response bodies on 405 rejections when invoked directly with HEAD.
Fourth, read handlers (`handleQueryCodingAgentTelemetry`, `handleAggregateCodingAgentTelemetry`, `handlePolicyFindings`, `handlePolicyDecisions`, and `handlePolicyRates`) omit direct-invocation HEAD response body suppression on successful queries.

## Technical Design

### HTTP Method Gating

All handlers enforce explicit HTTP method verification.
Read endpoints (`handleExportSubject`, `handleQueryCodingAgentTelemetry`, `handlePolicyFindings`, `handlePolicyDecisions`, `handlePolicyRates`) permit GET and HEAD only.
Invalid methods return HTTP 405 Method Not Allowed with header `Allow: GET, HEAD`.
`handleAggregateCodingAgentTelemetry` permits GET, HEAD, and POST, returning 405 with header `Allow: GET, HEAD, POST` on invalid verbs.
Mutating endpoints permit POST only (or POST and DELETE for delegation clamping), returning 405 with compliant Allow headers (`Allow: POST` or `Allow: POST, DELETE`).

### RFC 9110 Section 6.4.1 HEAD Response Body Suppression

All direct handler invocations check `r.Method == http.MethodHead`.
On method rejection (status 405), handlers write response headers (`Allow`, `Content-Type: application/json`, status 405) and return without writing an error body.
On successful read queries, handlers write response headers (`Content-Type: application/json`, status 200) and return zero body bytes without executing expensive backend data traversals.

### Test Harnesses and Assertions

Test suites across `export_test.go`, `delegations_test.go`, `telemetry_handler_test.go`, `policy_routes_test.go`, `erasure_test.go`, and `promote_test.go` add assertions for:
1. Rejection of invalid HTTP methods with status 405 and accurate Allow headers.
2. Verification of exactly zero response body bytes on HEAD requests across both success and 405 error paths.
3. Fast-path termination on HEAD requests for export endpoints.

## Verification Strategy

Verification runs unit tests in `d2-signalloom/apps/signal-ingest/api`:
- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -C d2-signalloom/apps/signal-ingest/api -v ./...`
- `bats test/docs-index-sync.bats`
- `./scripts/docs-lint.sh`
