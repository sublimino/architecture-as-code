# Proposal — Olly Sentinel Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Olly Sentinel provides automated incident root cause analysis and triage within the Signal Loom platform.
The service exposes HTTP probe endpoints, Orbit proposal reviews, and approval gates for operator workflows.
These HTTP endpoints interface with automated health checkers, service mesh gateways, and cluster orchestrators.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS preflight handling across advertised resources.
Servers advertising supported methods must include OPTIONS in Allow headers on 405 Method Not Allowed responses.
In `olly-sentinel`, both probe endpoints and approval routes reject OPTIONS with 405 Method Not Allowed.
Furthermore, 405 responses advertise truncated Allow headers omitting OPTIONS.
Additionally, requests rejected with 405 or preflight OPTIONS do not drain inbound request bodies.
This omission risks socket descriptor desynchronization under high-throughput probe sweeps.
Finally, the existing middleware only suppresses response bodies on HEAD requests, omitting 204 No Content body suppression.

## Objectives
1. Support RFC 9110 Section 9.3.7 OPTIONS preflight returning 204 No Content with complete Allow headers.
2. Restore RFC 9110 Section 9.3.7 Allow header parity across all sentinel routes on 405 responses.
3. Drain inbound request bodies on preflight OPTIONS and error responses before completing the exchange.
4. Ensure response body suppression on 204 No Content, 304 Not Modified, and HEAD responses.
5. Update unit and contract tests to assert RFC 9110 compliant Allow headers.

## Proposed Changes

### 1. Enhanced Request Lifecycle and OPTIONS Middleware
We enhance `HeadBodySuppressingMiddleware` in `olly-replica/apps/sentinel/olly_sentinel/main.py`.
The middleware dynamically inspects registered application routes for matching paths.
For incoming OPTIONS requests, it drains the request body and returns 204 No Content with the complete Allow header.
For 405 Method Not Allowed responses, it replaces truncated headers with complete RFC 9110 Allow headers including OPTIONS.
For 204 and 304 responses, it ensures message bodies are suppressed.

### 2. Route Registration Parity
We ensure all Starlette route definitions in `build_app` align with dynamic method inspection.
The middleware handles OPTIONS transparently across both probe routes and Orbit approval routes.

### 3. Test Suite Verification
We update `olly-replica/apps/sentinel/tests/test_authz_ctx.py`.
We add assertions verifying OPTIONS preflight responses return 204 No Content with complete Allow headers.
We verify that 405 Method Not Allowed responses include OPTIONS and all permitted methods.
We test inbound request body draining and response body suppression.

## Verification Plan
We run pytest across all `test_authz_ctx.py` test cases.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
