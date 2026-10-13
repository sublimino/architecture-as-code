# Proposal — Demo Runner ASGI, Fleet Consistency, Policy Compliance, Fleet Scan, and Telemetry HEAD Response Body Suppression (2026-Q4)

## Context

RFC 9110 Section 6.4.1 defines the semantics of HTTP HEAD requests.
A server must not return a message body in response to a HEAD request.
The response headers must match those returned for an equivalent GET request.
Previous hardening milestones eliminated body leakage across primary service endpoints.
However, gaps remain in auxiliary workloads, standalone runners, and telemetry handlers.

## Problem Statement

Adversarial exploration identified response body leakage on HEAD requests across five platform components.

First, `d2-signalloom/apps/fe-signalloom/src/demo_runner_main.py` runs a standalone SuperCred demo runner FastAPI application.
The application lacks ASGI middleware to suppress response bodies on HEAD requests.
Unmatched routes returning 404 and method rejections returning 405 stream body chunks into the ASGI response channel.

Second, `d2-signalloom/apps/fleet-manager/consistency.go` provides cross-plane consistency checks for agent fleets.
In `handleConsistency`, calls to `http.Error` return 405 Method Not Allowed and 404 Not Found for unknown agents.
In `serveHTTP`, calls to `http.Error` return 405 Method Not Allowed.
`http.Error` writes response bytes directly to the writer without checking the request method.
When invoked outside a wrapping middleware, these endpoints leak error text on HEAD requests.

Third, `d2-signalloom/apps/policy-engine/compliance.go` evaluates regulatory compliance policies.
In `handleScan`, non-POST requests return 405 Method Not Allowed with an `Allow: POST` header.
The handler encodes a JSON error payload directly into the response writer.
It does not check whether the client issued a HEAD request.

Fourth, `d2-signalloom/apps/policy-engine/pkg/compliance/fleet_scan.go` provides the `HandleScanFleet` endpoint.
Non-POST requests return 405 Method Not Allowed with an `Allow: POST` header.
The handler encodes a JSON error payload into the writer for all non-POST requests, including HEAD.

Fifth, `d2-signalloom/apps/fe-signalloom/pkg/telemetry/handler.go` streams container telemetry from cAdvisor.
When the response writer does not support `http.Flusher`, the handler invokes `http.Error` with plaintext.
This leaks error text on HEAD requests and diverges from structured JSON error envelopes.

## Proposed Changes

### Demo Runner ASGI Middleware

Wrap `demo_runner_main.app` with `HeadBodySuppressingMiddleware`.
The middleware intercepts ASGI `http.response.body` messages when the request method is HEAD.
It replaces body payloads with empty byte sequences.

### Fleet Consistency Error Handling

Update `handleConsistency` and `serveHTTP` in `consistency.go`.
Avoid calling `http.Error` directly.
Set status codes and headers explicitly.
Omit the message body when the request method is HEAD.

### Policy Engine Compliance Scan Method Gate

Update `handleScan` in `compliance.go`.
Conditionally encode the 405 error payload only when the request method is not HEAD.

### Compliance Fleet Scan Method Gate

Update `HandleScanFleet` in `pkg/compliance/fleet_scan.go`.
Conditionally encode the 405 error payload only when the request method is not HEAD.

### Telemetry Handler Streaming Error Formatting

Update `handleSSE` in `handler.go`.
Replace `http.Error` with `writeError`.
Ensure structured JSON error envelopes and suppress message bodies on HEAD requests.

## Verification Plan

Verify the changes with dedicated unit and contract test suites.
Test `demo_runner_main.py` via `test_head_response_suppression.py` and `test_demo_runner_main.py`.
Test `consistency.go` via `go test -v -run TestConsistency ./...`.
Test `compliance.go` via `go test -v -run TestComplianceScan ./...`.
Test `fleet_scan.go` via `go test -v -run TestHandleScanFleet_HTTP ./pkg/compliance`.
Test `handler.go` via `go test -v .` in `d2-signalloom/apps/fe-signalloom/pkg/telemetry`.
Run `scripts/docs-lint.sh` and `test/docs-index-sync.bats` to verify documentation integrity.
