# Proposal — ELK Search MCP Allow Headers, Telemetry HEAD Parity, and Demo Console Hardening (2026-Q4)

| Field | Value |
| :--- | :--- |
| Status | Proposed |
| Author | Platform Architecture & Reliability Engineering |
| Date | 2026-10-13 |
| Target Release | 2026-Q4 |
| Target Slices | `olly-replica`, `fe-signalloom`, `demo-console`, `triage-ci-worker` |

## 1. Executive Summary

This proposal hardens HTTP method validation and probe semantics across secondary services.
It eliminates protocol inconsistencies in search endpoints, telemetry handlers, and console controllers.
RFC 9110 requires an `Allow` header on every HTTP 405 response.
Health and readiness probes must support HEAD requests cleanly without emitting message bodies.
All probe endpoints must declare explicit UTF-8 text content types.

## 2. Problem Statement

Adversarial audit discovered six subtle protocol defects across peripheral services:
First, `elk-search-mcp` rejects non-POST requests without setting an `Allow: POST` header.
Its health and readiness handlers reject HEAD probes or write unexpected response bodies.
Second, `fe-signalloom` telemetry handlers reject HEAD requests on agent metrics endpoints.
The telemetry admission gate advertises only GET in its `Allow` header.
Third, `demo-console` action and security proxy endpoints reject non-POST requests without `Allow: POST`.
Fourth, `triage-ci-worker` health and probe handlers omit explicit `Content-Type` headers.
Fifth, `mapping-stub` service handlers in `olly-replica` omit HTTP method validation.
Sixth, `tenant-app` dependency and metrics endpoints allow unrestricted HTTP methods.

## 3. Proposed Hardening

### 3.1 ELK Search MCP Method Gates and Probes

The `elk-search-mcp` service implements log search and MCP tool calls.
We add `Allow: POST` headers to 405 Method Not Allowed responses.
We update probe handlers to admit GET and HEAD verbs explicitly.
We set `Content-Type: text/plain; charset=utf-8` on probe responses.
Responses to HEAD requests suppress body bytes while preserving status codes.

### 3.2 Signal Loom Telemetry HEAD Parity

The `fe-signalloom` telemetry handler parses and serves cAdvisor metrics.
We update `admit` to permit both GET and HEAD requests.
When rejecting unsupported verbs, `admit` returns `Allow: GET, HEAD`.
The JSON list and pod detail handlers suppress body serialization on HEAD requests.
Server-Sent Events endpoints handle HEAD requests cleanly without blocking streams.

### 3.3 Demo Console Allow Header Alignment

The `demo-console` binary controls demo flows and Olly Sentinel actions.
Handlers for `/api/runs`, `/api/orbit/approve`, and `/api/orbit/reject` reject non-POST requests.
We set `Allow: POST` on all 405 responses from these handlers.
Security handlers for `/api/security/scan` and `/api/security/probe` also set `Allow: POST`.

### 3.4 Triage CI Worker Probe Content-Type

The `triage-ci-worker` daemon evaluates GitHub check-run events.
We ensure health and readiness handlers set `Content-Type: text/plain; charset=utf-8`.
This prevents upstream reverse proxies from misinterpreting probe responses.

### 3.5 Olly Replica Mapping Stub and Tenant App Method Gates

The `mapping-stub` and `tenant-app` services simulate production topologies.
We add method checks to `/incidents`, `/events`, and `/metrics`.
Non-GET/HEAD verbs return 405 with `Allow: GET, HEAD`.
Probes set explicit text content types and suppress bodies on HEAD.

## 4. Verification Plan

We verify all changes using unit and contract tests in each repository slice.
Tests assert status codes, `Allow` headers, `Content-Type` headers, and empty HEAD bodies.
Documentation linting confirms formatting and index synchronization.

## 5. Implementation Verification

Each component maintains automated regression tests:
- `elk-search-mcp`: `go test ./apps/cmd/elk-search-mcp/...`
- `fe-signalloom` telemetry: `go test ./pkg/telemetry/...`
- `demo-console`: `go test ./tools/demo-console/...`
- `triage-ci-worker`: `go test ./apps/triage-ci-worker/...`
- `mapping-stub` and `tenant-app`: `go test ./apps/cmd/...`

## 6. Impact and Rollback

All modifications are strictly backward-compatible.
Clients adhering to HTTP specifications observe standards-compliant headers and probe behaviors.
Rollback requires reverting the committed changes.
